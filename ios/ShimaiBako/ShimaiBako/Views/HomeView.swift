import Photos
import SwiftUI

private enum HomeTab: Hashable {
    case photos
    case search
    case read
    case settings
}

struct HomeView: View {
    @ObservedObject var photoLibrary: PhotoLibraryService
    @ObservedObject var ocrService: OCRService
    @ObservedObject var indexService: PhotoIndexService
    @ObservedObject var learningService: ManualCategoryLearningService
    @ObservedObject var accuracyImprovementService: AccuracyImprovementService
    @ObservedObject var batchOCRJobService: BatchOCRJobService
    @ObservedObject var deviceSafety: DeviceSafetyService
    @State private var selectedTab = HomeTab.initialSelection

    var body: some View {
        TabView(selection: $selectedTab) {
            PhotoAccessRootView(
                photoLibrary: photoLibrary,
                ocrService: ocrService,
                indexService: indexService,
                learningService: learningService,
                deviceSafety: deviceSafety
            )
                .tabItem {
                    Label("写真", systemImage: "photo.on.rectangle")
                }
                .tag(HomeTab.photos)

            PhotoGridView(
                photoLibrary: photoLibrary,
                ocrService: ocrService,
                indexService: indexService,
                learningService: learningService,
                deviceSafety: deviceSafety,
                mode: .search
            )
                .tabItem {
                    Label("検索", systemImage: "magnifyingglass")
                }
                .tag(HomeTab.search)

            ReadView(
                photoLibrary: photoLibrary,
                ocrService: ocrService,
                indexService: indexService,
                batchOCRJobService: batchOCRJobService,
                deviceSafety: deviceSafety
            )
                .tabItem {
                    Label("読取", systemImage: "text.viewfinder")
                }
                .tag(HomeTab.read)

            SettingsView(
                photoLibrary: photoLibrary,
                ocrService: ocrService,
                indexService: indexService,
                learningService: learningService,
                accuracyImprovementService: accuracyImprovementService,
                batchOCRJobService: batchOCRJobService,
                deviceSafety: deviceSafety
            )
                .tabItem {
                    Label("設定", systemImage: "gearshape")
                }
                .tag(HomeTab.settings)
        }
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarBackground(Color(red: 0.93, green: 0.98, blue: 1.00), for: .tabBar)
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

        if arguments.contains("-ShimaiBakoOpenReadTab") {
            return .read
        }
        #endif

        return .photos
    }
}

private struct PhotoAccessRootView: View {
    @ObservedObject var photoLibrary: PhotoLibraryService
    @ObservedObject var ocrService: OCRService
    @ObservedObject var indexService: PhotoIndexService
    @ObservedObject var learningService: ManualCategoryLearningService
    @ObservedObject var deviceSafety: DeviceSafetyService

    var body: some View {
        switch photoLibrary.authorizationStatus {
        case .authorized, .limited:
            PhotoGridView(
                photoLibrary: photoLibrary,
                ocrService: ocrService,
                indexService: indexService,
                learningService: learningService,
                deviceSafety: deviceSafety,
                mode: .library
            )
        case .notDetermined, .denied, .restricted:
            PermissionView(photoLibrary: photoLibrary)
        @unknown default:
            PermissionView(photoLibrary: photoLibrary)
        }
    }
}
