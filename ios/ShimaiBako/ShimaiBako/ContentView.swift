import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var photoLibrary: PhotoLibraryService
    @StateObject private var ocrService: OCRService
    @StateObject private var indexService: PhotoIndexService
    @StateObject private var learningService: ManualCategoryLearningService
    @StateObject private var accuracyImprovementService: AccuracyImprovementService
    @StateObject private var batchOCRJobService: BatchOCRJobService
    @StateObject private var deviceSafety: DeviceSafetyService

    init() {
        let learningService = ManualCategoryLearningService()
        _photoLibrary = StateObject(wrappedValue: PhotoLibraryService())
        _ocrService = StateObject(wrappedValue: OCRService())
        _learningService = StateObject(wrappedValue: learningService)
        _indexService = StateObject(wrappedValue: PhotoIndexService(learningService: learningService))
        _accuracyImprovementService = StateObject(wrappedValue: AccuracyImprovementService())
        _batchOCRJobService = StateObject(wrappedValue: BatchOCRJobService())
        _deviceSafety = StateObject(wrappedValue: DeviceSafetyService())
    }

    var body: some View {
        HomeView(
            photoLibrary: photoLibrary,
            ocrService: ocrService,
            indexService: indexService,
            learningService: learningService,
            accuracyImprovementService: accuracyImprovementService,
            batchOCRJobService: batchOCRJobService,
            deviceSafety: deviceSafety
        )
            .task {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-ShimaiBakoRunBatchOCRP1Validation") {
                    await batchOCRJobService.runP1ValidationSuite(ocrService: ocrService)
                }
                if ProcessInfo.processInfo.arguments.contains("-ShimaiBakoRunBatchOCRP2Validation") {
                    await batchOCRJobService.runP2ValidationSuite(ocrService: ocrService)
                }
                if ProcessInfo.processInfo.arguments.contains("-ShimaiBakoRunBatchOCRP3Validation") {
                    await batchOCRJobService.runP3ValidationSuite(ocrService: ocrService)
                }
                if ProcessInfo.processInfo.arguments.contains("-ShimaiBakoRunBatchOCRTargetSelectionValidation") {
                    await batchOCRJobService.runTargetSelectionValidationSuite()
                }
                #endif
                await photoLibrary.prepare()
            }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    photoLibrary.applicationDidBecomeActive()
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
}

#Preview {
    ContentView()
}
