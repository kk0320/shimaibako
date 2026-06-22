import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var photoLibrary: PhotoLibraryService
    @StateObject private var ocrService: OCRService
    @StateObject private var indexService: PhotoIndexService
    @StateObject private var learningService: ManualCategoryLearningService
    @StateObject private var classificationService: PhotoClassificationService
    @StateObject private var accuracyImprovementService: AccuracyImprovementService
    @StateObject private var batchOCRJobService: BatchOCRJobService
    @StateObject private var deviceSafety: DeviceSafetyService
    @StateObject private var deviceConditionMonitor: DeviceConditionMonitor

    init() {
        let learningService = ManualCategoryLearningService()
        _photoLibrary = StateObject(wrappedValue: PhotoLibraryService())
        _ocrService = StateObject(wrappedValue: OCRService())
        _learningService = StateObject(wrappedValue: learningService)
        _classificationService = StateObject(wrappedValue: PhotoClassificationService())
        _indexService = StateObject(wrappedValue: PhotoIndexService(learningService: learningService))
        _accuracyImprovementService = StateObject(wrappedValue: AccuracyImprovementService())
        _batchOCRJobService = StateObject(wrappedValue: BatchOCRJobService())
        _deviceSafety = StateObject(wrappedValue: DeviceSafetyService())
        _deviceConditionMonitor = StateObject(wrappedValue: DeviceConditionMonitor())
    }

    var body: some View {
        HomeView(
            photoLibrary: photoLibrary,
            ocrService: ocrService,
            indexService: indexService,
            learningService: learningService,
            classificationService: classificationService,
            accuracyImprovementService: accuracyImprovementService,
            batchOCRJobService: batchOCRJobService,
            deviceSafety: deviceSafety
        )
            .task {
                #if DEBUG
                let debugArguments = ProcessInfo.processInfo.arguments
                let debugEnvironment = ProcessInfo.processInfo.environment
                func hasDebugTrigger(_ argument: String, environmentKey: String) -> Bool {
                    debugArguments.contains(argument) || debugEnvironment[environmentKey] == "1"
                }

                if hasDebugTrigger("-ShimaiBakoRunBatchOCRP1Validation", environmentKey: "SHIMAIBAKO_RUN_BATCH_OCR_P1_VALIDATION") {
                    await batchOCRJobService.runP1ValidationSuite(ocrService: ocrService)
                }
                if hasDebugTrigger("-ShimaiBakoRunBatchOCRP2Validation", environmentKey: "SHIMAIBAKO_RUN_BATCH_OCR_P2_VALIDATION") {
                    await batchOCRJobService.runP2ValidationSuite(ocrService: ocrService)
                }
                if hasDebugTrigger("-ShimaiBakoRunBatchOCRP3Validation", environmentKey: "SHIMAIBAKO_RUN_BATCH_OCR_P3_VALIDATION") {
                    await batchOCRJobService.runP3ValidationSuite(ocrService: ocrService)
                }
                if hasDebugTrigger("-ShimaiBakoRunBatchOCRTargetSelectionValidation", environmentKey: "SHIMAIBAKO_RUN_BATCH_OCR_TARGET_SELECTION_VALIDATION") {
                    await batchOCRJobService.runTargetSelectionValidationSuite()
                }
                if hasDebugTrigger("-ShimaiBakoRunBatchOCRAutoContinueValidation", environmentKey: "SHIMAIBAKO_RUN_BATCH_OCR_AUTO_CONTINUE_VALIDATION") {
                    Task {
                        await batchOCRJobService.runAutoContinueValidationSuite(
                            photoLibrary: photoLibrary,
                            ocrService: ocrService,
                            indexService: indexService
                        )
                    }
                }
                if hasDebugTrigger("-ShimaiBakoRunBatchOCRAutoResumeValidation", environmentKey: "SHIMAIBAKO_RUN_BATCH_OCR_AUTO_RESUME_VALIDATION") {
                    Task {
                        await batchOCRJobService.runAutoResumeValidationSuite(
                            photoLibrary: photoLibrary,
                            ocrService: ocrService,
                            indexService: indexService,
                            deviceSafety: deviceSafety
                        )
                    }
                }
                if hasDebugTrigger("-ShimaiBakoRunReadCandidateOCR20Validation", environmentKey: "SHIMAIBAKO_RUN_READ_CANDIDATE_OCR20_VALIDATION") {
                    await batchOCRJobService.runReadCandidateHandoffValidation(ocrService: ocrService)
                }
                if hasDebugTrigger("-ShimaiBakoRunBatchOCRPersistenceValidation", environmentKey: "SHIMAIBAKO_RUN_BATCH_OCR_PERSISTENCE_VALIDATION") {
                    await batchOCRJobService.runPersistenceValidation()
                }
                if hasDebugTrigger("-ShimaiBakoRunClassificationSelfTest", environmentKey: "SHIMAIBAKO_RUN_CLASSIFICATION_SELF_TEST") {
                    let report = classificationService.runManualPrioritySelfTest()
                    print("LOCAL_IMAGE_CLASSIFICATION_SELFTEST \(report.passed ? "PASS" : "FAIL")")
                }
                #endif
                await photoLibrary.prepare()
                deviceConditionMonitor.start(deviceSafety: deviceSafety) {
                    await batchOCRJobService.checkAutoResumeIfPossible(
                        photoLibrary: photoLibrary,
                        ocrService: ocrService,
                        indexService: indexService,
                        deviceSafety: deviceSafety,
                        trigger: "deviceConditionMonitor"
                    )
                }
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-ShimaiBakoRunBatchOCRAutoContinueValidation") {
                    await waitForAutoContinueValidationReport()
                }
                if ProcessInfo.processInfo.arguments.contains("-ShimaiBakoRunBatchOCRAutoResumeValidation") {
                    await waitForAutoResumeValidationReport()
                }
                if ProcessInfo.processInfo.arguments.contains("-ShimaiBakoRunBatchOCRReadStateDiagnostics") {
                    if photoLibrary.canReadPhotos, photoLibrary.assets.isEmpty {
                        await photoLibrary.loadRecentAssets()
                    }
                    await waitForReadStateDiagnosticsInputs()
                    await batchOCRJobService.runReadStateDiagnostics(
                        assets: photoLibrary.assets,
                        ocrService: ocrService,
                        indexService: indexService
                    )
                }
                if ProcessInfo.processInfo.arguments.contains("-ShimaiBakoRunMetadataOnlyOrganizationValidation") {
                    if photoLibrary.canReadPhotos, photoLibrary.assets.isEmpty {
                        await photoLibrary.loadRecentAssets()
                    }
                    await waitForMetadataOnlyOrganizationValidationInputs()
                    let libraryTotalAssets = max(
                        photoLibrary.totalAssetCount,
                        indexService.indexedRecordCount,
                        photoLibrary.loadedAssetCount
                    )
                    let validationLimit = photoLibrary.readMode.limit ?? libraryTotalAssets
                    await classificationService.runMetadataOnlyOrganizationValidation(
                        assets: photoLibrary.assets,
                        indexService: indexService,
                        libraryTotalAssets: libraryTotalAssets,
                        validationLimit: validationLimit
                    )
                }
                #endif
            }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    photoLibrary.applicationDidBecomeActive()
                    batchOCRJobService.applicationDidBecomeActive()
                    Task {
                        await deviceConditionMonitor.checkNow(deviceSafety: deviceSafety) {
                            await batchOCRJobService.checkAutoResumeIfPossible(
                                photoLibrary: photoLibrary,
                                ocrService: ocrService,
                                indexService: indexService,
                                deviceSafety: deviceSafety,
                                trigger: "scenePhaseActive"
                            )
                        }
                    }
                case .background:
                    photoLibrary.applicationDidEnterBackground()
                    batchOCRJobService.pauseForBackground()
                case .inactive:
                    break
                @unknown default:
                    break
                }
            }
            .tint(Color(red: 0.16, green: 0.42, blue: 0.75))
    }

    #if DEBUG
    private func waitForAutoContinueValidationReport() async {
        for _ in 0..<80 {
            if batchOCRJobService.autoContinueValidationReport != nil {
                return
            }

            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private func waitForAutoResumeValidationReport() async {
        for _ in 0..<80 {
            if batchOCRJobService.autoResumeValidationReport != nil {
                return
            }

            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private func waitForReadStateDiagnosticsInputs() async {
        for _ in 0..<160 {
            if photoLibrary.isLoading == false, indexService.isIndexStorePreparing == false {
                return
            }

            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private func waitForMetadataOnlyOrganizationValidationInputs() async {
        for _ in 0..<240 {
            if photoLibrary.isLoading == false,
               indexService.isIndexStorePreparing == false,
               classificationService.isLoading == false {
                return
            }

            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }
    #endif
}

#Preview {
    ContentView()
}
