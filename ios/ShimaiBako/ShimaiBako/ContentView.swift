import SwiftUI

struct ContentView: View {
    @StateObject private var photoLibrary = PhotoLibraryService()
    @StateObject private var ocrService = OCRService()
    @StateObject private var indexService = PhotoIndexService()
    @StateObject private var deviceSafety = DeviceSafetyService()

    var body: some View {
        HomeView(
            photoLibrary: photoLibrary,
            ocrService: ocrService,
            indexService: indexService,
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
