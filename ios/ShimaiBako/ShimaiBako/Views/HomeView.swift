import Photos
import SwiftUI

private enum HomeTab: Hashable {
    case photos
    case search
    case settings
}

struct HomeView: View {
    @ObservedObject var photoLibrary: PhotoLibraryService
    @ObservedObject var ocrService: OCRService
    @State private var selectedTab = HomeTab.initialSelection

    var body: some View {
        TabView(selection: $selectedTab) {
            PhotoAccessRootView(photoLibrary: photoLibrary, ocrService: ocrService)
                .tabItem {
                    Label("写真", systemImage: "photo.on.rectangle")
                }
                .tag(HomeTab.photos)

            PhotoGridView(photoLibrary: photoLibrary, ocrService: ocrService, mode: .search)
                .tabItem {
                    Label("検索", systemImage: "magnifyingglass")
                }
                .tag(HomeTab.search)

            SettingsView(photoLibrary: photoLibrary, ocrService: ocrService)
                .tabItem {
                    Label("設定", systemImage: "gearshape")
                }
                .tag(HomeTab.settings)
        }
    }
}

private extension HomeTab {
    static var initialSelection: HomeTab {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments

        if arguments.contains("-ShimaiBakoOpenSearchTab") {
            return .search
        }

        if arguments.contains("-ShimaiBakoOpenSettingsTab") {
            return .settings
        }
        #endif

        return .photos
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
