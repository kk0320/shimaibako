import Photos
import SwiftUI

struct HomeView: View {
    @ObservedObject var photoLibrary: PhotoLibraryService
    @ObservedObject var ocrService: OCRService

    var body: some View {
        TabView {
            PhotoAccessRootView(photoLibrary: photoLibrary, ocrService: ocrService)
                .tabItem {
                    Label("写真", systemImage: "photo.on.rectangle")
                }

            PhotoGridView(photoLibrary: photoLibrary, ocrService: ocrService, mode: .search)
                .tabItem {
                    Label("検索", systemImage: "magnifyingglass")
                }

            SettingsView(photoLibrary: photoLibrary)
                .tabItem {
                    Label("設定", systemImage: "gearshape")
                }
        }
    }
}

private struct PhotoAccessRootView: View {
    @ObservedObject var photoLibrary: PhotoLibraryService
    @ObservedObject var ocrService: OCRService

    var body: some View {
        switch photoLibrary.authorizationStatus {
        case .authorized, .limited:
            PhotoGridView(photoLibrary: photoLibrary, ocrService: ocrService, mode: .library)
        case .notDetermined, .denied, .restricted:
            PermissionView(photoLibrary: photoLibrary)
        @unknown default:
            PermissionView(photoLibrary: photoLibrary)
        }
    }
}
