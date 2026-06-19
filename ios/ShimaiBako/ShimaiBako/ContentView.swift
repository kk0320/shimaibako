import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var photoLibrary: PhotoLibraryService
    @StateObject private var ocrService: OCRService
    @StateObject private var indexService: PhotoIndexService
    @StateObject private var learningService: ManualCategoryLearningService
    @StateObject private var accuracyImprovementService: AccuracyImprovementService
    @StateObject private var deviceSafety: DeviceSafetyService
    @StateObject private var ocrProgressStore: OCRProgressStore
    @StateObject private var ocrJobRunner: OCRJobRunner

    init() {
        let learningService = ManualCategoryLearningService()
        let photoLibrary = PhotoLibraryService()
        let ocrService = OCRService()
        let indexService = PhotoIndexService(learningService: learningService)
        let deviceSafety = DeviceSafetyService()
        let ocrProgressStore = OCRProgressStore()
        _photoLibrary = StateObject(wrappedValue: photoLibrary)
        _ocrService = StateObject(wrappedValue: ocrService)
        _learningService = StateObject(wrappedValue: learningService)
        _indexService = StateObject(wrappedValue: indexService)
        _accuracyImprovementService = StateObject(wrappedValue: AccuracyImprovementService())
        _deviceSafety = StateObject(wrappedValue: deviceSafety)
        _ocrProgressStore = StateObject(wrappedValue: ocrProgressStore)
        _ocrJobRunner = StateObject(wrappedValue: OCRJobRunner(
            photoLibrary: photoLibrary,
            ocrService: ocrService,
            indexService: indexService,
            deviceSafety: deviceSafety,
            progressStore: ocrProgressStore
        ))
    }

    var body: some View {
        HomeView(
            photoLibrary: photoLibrary,
            ocrService: ocrService,
            indexService: indexService,
            learningService: learningService,
            accuracyImprovementService: accuracyImprovementService,
            deviceSafety: deviceSafety,
            ocrProgressStore: ocrProgressStore,
            ocrJobRunner: ocrJobRunner
        )
            .task {
                await photoLibrary.prepare()
                await ocrJobRunner.prepare()
                #if DEBUG
                await runDebugLaunchActionsIfNeeded()
                #endif
            }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    photoLibrary.applicationDidBecomeActive()
                case .background:
                    photoLibrary.applicationDidEnterBackground()
                    ocrJobRunner.applicationDidEnterBackground()
                case .inactive:
                    break
                @unknown default:
                    break
                }
            }
            .tint(Color(red: 0.16, green: 0.42, blue: 0.75))
    }

    #if DEBUG
    private func runDebugLaunchActionsIfNeeded() async {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-ShimaiBakoCreateLargeLibraryFixture") {
            let count = debugIntegerArgument(
                named: "-ShimaiBakoLargeLibraryFixtureCount",
                defaultValue: 30_000,
                arguments: arguments
            )
            await indexService.createDebugLargeLibraryFixture(totalCount: count)
        }

        if arguments.contains("-ShimaiBakoStartDummyFullOCR") {
            let count = debugIntegerArgument(
                named: "-ShimaiBakoDummyFullOCRCount",
                defaultValue: 30_000,
                arguments: arguments
            )
            let delayMilliseconds = debugIntegerArgument(
                named: "-ShimaiBakoDummyFullOCRDelayMilliseconds",
                defaultValue: 2,
                arguments: arguments
            )
            ocrJobRunner.startDebugDummyFullOCRProgress(
                totalCount: count,
                itemDelayNanoseconds: UInt64(max(delayMilliseconds, 0)) * 1_000_000
            )
        }
    }

    private func debugIntegerArgument(named name: String, defaultValue: Int, arguments: [String]) -> Int {
        guard let index = arguments.firstIndex(of: name),
              arguments.indices.contains(index + 1),
              let value = Int(arguments[index + 1]) else {
            return defaultValue
        }

        return value
    }
    #endif
}

#Preview {
    ContentView()
}
