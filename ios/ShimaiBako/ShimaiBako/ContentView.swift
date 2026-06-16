import SwiftUI

struct ContentView: View {
    @StateObject private var photoLibrary = PhotoLibraryService()

    var body: some View {
        HomeView(photoLibrary: photoLibrary)
            .task {
                await photoLibrary.prepare()
            }
            .tint(Color(red: 0.16, green: 0.42, blue: 0.75))
    }
}

#Preview {
    ContentView()
}
