import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var photoLibrary: PhotoLibraryService
    @StateObject private var ocrService: OCRService
    @StateObject private var indexService: PhotoIndexService
    @StateObject private var learningService: ManualCategoryLearningService
    @StateObject private var accuracyImprovementService: AccuracyImprovementService
    @StateObject private var deviceSafety: DeviceSafetyService
    @StateObject private var ocrJobRunner: OCRJobRunner

    init() {
        let learningService = ManualCategoryLearningService()
        let photoLibrary = PhotoLibraryService()
        let ocrService = OCRService()
        let indexService = PhotoIndexService(learningService: learningService)
        let deviceSafety = DeviceSafetyService()
        _photoLibrary = StateObject(wrappedValue: photoLibrary)
        _ocrService = StateObject(wrappedValue: ocrService)
        _learningService = StateObject(wrappedValue: learningService)
        _indexService = StateObject(wrappedValue: indexService)
        _accuracyImprovementService = StateObject(wrappedValue: AccuracyImprovementService())
        _deviceSafety = StateObject(wrappedValue: deviceSafety)
        _ocrJobRunner = StateObject(wrappedValue: OCRJobRunner(
            photoLibrary: photoLibrary,
            ocrService: ocrService,
            indexService: indexService,
            deviceSafety: deviceSafety
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
            ocrJobRunner: ocrJobRunner
        )
            .task {
                await photoLibrary.prepare()
                await ocrJobRunner.prepare()
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
}

#Preview {
    ContentView()
}
