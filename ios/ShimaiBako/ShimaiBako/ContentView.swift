import SwiftUI

struct ContentView: View {
    @StateObject private var photoLibrary: PhotoLibraryService
    @StateObject private var ocrService: OCRService
    @StateObject private var indexService: PhotoIndexService
    @StateObject private var learningService: ManualCategoryLearningService
    @StateObject private var deviceSafety: DeviceSafetyService

    init() {
        let learningService = ManualCategoryLearningService()
        _photoLibrary = StateObject(wrappedValue: PhotoLibraryService())
        _ocrService = StateObject(wrappedValue: OCRService())
        _learningService = StateObject(wrappedValue: learningService)
        _indexService = StateObject(wrappedValue: PhotoIndexService(learningService: learningService))
        _deviceSafety = StateObject(wrappedValue: DeviceSafetyService())
    }

    var body: some View {
        HomeView(
            photoLibrary: photoLibrary,
            ocrService: ocrService,
            indexService: indexService,
            learningService: learningService,
            deviceSafety: deviceSafety
        )
            .task {
                await photoLibrary.prepare()
            }
            .tint(Color(red: 0.16, green: 0.42, blue: 0.75))
    }
}

#Preview {
    ContentView()
}
