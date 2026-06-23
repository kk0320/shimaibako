import Photos
import SwiftUI

private enum HomeTab: Hashable {
    case photos
    case organization
    case search
    case read
    case settings
}

struct HomeView: View {
    @ObservedObject var photoLibrary: PhotoLibraryService
    @ObservedObject var ocrService: OCRService
    @ObservedObject var indexService: PhotoIndexService
    @ObservedObject var learningService: ManualCategoryLearningService
    @ObservedObject var classificationService: PhotoClassificationService
    @ObservedObject var accuracyImprovementService: AccuracyImprovementService
    @ObservedObject var batchOCRJobService: BatchOCRJobService
    @ObservedObject var deviceSafety: DeviceSafetyService
    @State private var selectedTab = HomeTab.initialSelection
    @State private var readCandidateSelection: ReadCandidateSelection? = .initialSelection
    @State private var isCheckingMetadataAutoRun = false

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

            OrganizationView(
                photoLibrary: photoLibrary,
                ocrService: ocrService,
                indexService: indexService,
                learningService: learningService,
                classificationService: classificationService,
                batchOCRJobService: batchOCRJobService
            ) { selection in
                readCandidateSelection = selection
                selectedTab = .read
            }
                .tabItem {
                    Label("整理", systemImage: "square.grid.2x2")
                }
                .tag(HomeTab.organization)

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
                classificationService: classificationService,
                batchOCRJobService: batchOCRJobService,
                deviceSafety: deviceSafety,
                readCandidateSelection: readCandidateSelection
            ) {
                readCandidateSelection = nil
            }
                .tabItem {
                    Label("読取", systemImage: "text.viewfinder")
                }
                .tag(HomeTab.read)

            SettingsView(
                photoLibrary: photoLibrary,
                ocrService: ocrService,
                indexService: indexService,
                learningService: learningService,
                classificationService: classificationService,
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
        .task {
            await maybeRunAutomaticMetadataOrganization(reason: "initial")
        }
        .onChange(of: photoLibrary.isLoading) { _, isLoading in
            guard isLoading == false else {
                return
            }

            Task {
                await maybeRunAutomaticMetadataOrganization(reason: "photoLoadingCompleted")
            }
        }
        .onChange(of: indexService.indexedRecordCount) { _, _ in
            Task {
                await maybeRunAutomaticMetadataOrganization(reason: "photoIndexUpdated")
            }
        }
        .onChange(of: indexService.isIndexStorePreparing) { _, isPreparing in
            guard isPreparing == false else {
                return
            }

            Task {
                await maybeRunAutomaticMetadataOrganization(reason: "photoIndexReady")
            }
        }
    }

    private func maybeRunAutomaticMetadataOrganization(reason _: String) async {
        #if DEBUG
        if Self.shouldSkipAutomaticMetadataOrganizationForDebugValidation {
            return
        }
        #endif

        guard isCheckingMetadataAutoRun == false else {
            return
        }
        guard photoLibrary.canReadPhotos,
              photoLibrary.isLoading == false,
              indexService.isIndexStorePreparing == false,
              classificationService.isLoading == false,
              classificationService.isUpdatingMetadata == false else {
            return
        }

        isCheckingMetadataAutoRun = true
        defer { isCheckingMetadataAutoRun = false }

        let libraryTotalCount = max(
            indexService.indexedRecordCount,
            photoLibrary.totalAssetCount,
            photoLibrary.loadedAssetCount,
            classificationService.summary.totalCount
        )

        let indexSource = await indexService.organizationMetadataSource(limit: 1)
        if indexSource.totalCount > 0,
           classificationService.shouldRunAutomaticMetadataOrganization(
               libraryTotalAssets: max(libraryTotalCount, indexSource.totalCount),
               sourceTotalAssets: indexSource.totalCount
           ) {
            await classificationService.updateMetadataOnlyFromPhotoIndexPages(
                indexService: indexService,
                libraryTotalAssets: max(libraryTotalCount, indexSource.totalCount),
                trigger: .automatic
            )
            return
        }

        if photoLibrary.assets.isEmpty == false,
           classificationService.shouldRunAutomaticMetadataOrganization(
               libraryTotalAssets: max(libraryTotalCount, photoLibrary.assets.count),
               sourceTotalAssets: photoLibrary.assets.count
           ) {
            await classificationService.updateMetadataOnly(
                assets: photoLibrary.assets,
                indexService: indexService,
                trigger: .automatic,
                libraryTotalAssets: max(libraryTotalCount, photoLibrary.assets.count),
                metadataSource: "photoLibraryAssets"
            )
            return
        }

        let metadataAssets = await photoLibrary.organizationMetadataAssets(limit: 100)
        guard metadataAssets.isEmpty == false,
              classificationService.shouldRunAutomaticMetadataOrganization(
                  libraryTotalAssets: max(libraryTotalCount, photoLibrary.totalAssetCount, metadataAssets.count),
                  sourceTotalAssets: metadataAssets.count
              ) else {
            return
        }

        await classificationService.updateMetadataOnly(
            assets: metadataAssets,
            indexService: indexService,
            trigger: .automatic,
            libraryTotalAssets: max(libraryTotalCount, photoLibrary.totalAssetCount, metadataAssets.count),
            metadataSource: "photoKitMetadata"
        )
    }
}

private extension HomeTab {
    static var initialSelection: HomeTab {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments

        if arguments.contains("-ShimaiBakoOpenSearchTab") {
            return .search
        }

        if arguments.contains("-ShimaiBakoOpenOrganizationTab") {
            return .organization
        }

        if arguments.contains("-ShimaiBakoHandoffReadCandidatesToReadTab") {
            return .read
        }

        if arguments.contains("-ShimaiBakoOpenOrganizationScreenshotsFolder") ||
            arguments.contains("-ShimaiBakoOpenOrganizationReadCandidatesFolder") ||
            arguments.contains("-ShimaiBakoOpenOrganizationNeedsReviewFolder") ||
            arguments.contains("-ShimaiBakoOpenOrganizationUnorganizedFolder") {
            return .organization
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

#if DEBUG
private extension HomeView {
    static var shouldSkipAutomaticMetadataOrganizationForDebugValidation: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-ShimaiBakoRunMetadataOnlyOrganizationValidation") ||
            arguments.contains("-ShimaiBakoRunMetadataOnlyOrganizationAutoRunValidation")
    }
}
#endif

private extension Optional where Wrapped == ReadCandidateSelection {
    static var initialSelection: ReadCandidateSelection? {
        #if DEBUG
        ReadCandidateSelection.initialFromLaunchArguments
        #else
        nil
        #endif
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
