import Photos
import Foundation
import SwiftUI
import UIKit

enum PhotoGridMode {
    case library
    case search

    var title: String {
        switch self {
        case .library:
            "写真"
        case .search:
            "検索"
        }
    }
}

struct PhotoGridView: View {
    @ObservedObject var photoLibrary: PhotoLibraryService
    @ObservedObject var ocrService: OCRService
    let indexService: PhotoIndexService
    @ObservedObject var learningService: ManualCategoryLearningService
    @ObservedObject var deviceSafety: DeviceSafetyService
    let mode: PhotoGridMode

    @State private var searchText: String
    @State private var selectedDisplayState: PhotoDisplayState = .active
    @State private var includeUnwantedInSearch = false
    @State private var selectedCategory: PhotoCategory = .all
    @State private var selectedScreenshotSubcategory: ScreenshotSubcategory = .all
    @State private var visibleAssetLimit = 200
    @AppStorage("shimaibako.photoGridShowsCategoryFilters") private var showsCategoryFilters = false
    @State private var effectiveSearchText: String
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var pageFetchTask: Task<Void, Never>?
    @State private var pageGeneration = 0
    @State private var pageIdentifiers: [String] = []
    @State private var pageTotalCount = 0
    @State private var isFetchingPage = false
    @State private var assetByID: [String: PhotoAsset] = [:]
    @State private var debugPresentedAsset: PhotoAsset?
    @State private var didPresentDebugAsset = false

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    init(
        photoLibrary: PhotoLibraryService,
        ocrService: OCRService,
        indexService: PhotoIndexService,
        learningService: ManualCategoryLearningService,
        deviceSafety: DeviceSafetyService,
        mode: PhotoGridMode
    ) {
        self.photoLibrary = photoLibrary
        self.ocrService = ocrService
        self.indexService = indexService
        self.learningService = learningService
        self.deviceSafety = deviceSafety
        self.mode = mode
        let initialSearchText = mode == .search ? Self.debugInitialSearchText : ""
        _searchText = State(initialValue: initialSearchText)
        _effectiveSearchText = State(initialValue: initialSearchText)
    }

    private var visibleAssets: [PhotoAsset] {
        pageAssets
    }

    private var pageAssets: [PhotoAsset] {
        let assets = pageIdentifiers.compactMap { assetByID[$0] }
        if assets.isEmpty,
           pageIdentifiers.isEmpty,
           photoLibrary.assets.isEmpty == false,
           indexService.indexedRecordCount == 0,
           effectiveSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Array(photoLibrary.assets.prefix(visibleAssetLimit))
        }

        return assets
    }

    private var resultTotalCount: Int {
        if pageTotalCount > 0 {
            return pageTotalCount
        }

        return pageAssets.count
    }

    @ViewBuilder
    private var readGuidance: some View {
        if mode == .library {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "text.viewfinder")
                    .foregroundStyle(Color(red: 0.16, green: 0.42, blue: 0.75))
                    .frame(width: 18)

                Text("文字検索用の読取は「読取」タブで実行できます。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
        } else if indexService.indexSummary.unprocessedOCRCount > 0 {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "text.magnifyingglass")
                    .foregroundStyle(Color(red: 0.16, green: 0.42, blue: 0.75))
                    .frame(width: 18)

                Text("未読取の写真があります。文字検索の精度を上げるには、読取タブで文字を読み取ってください。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                VStack(spacing: 12) {
                    topStatusSection
                    importStatusSection
                    displayStateChips
                    searchOptions
                    categoryFilterSection
                    readGuidance
                    content
                        .layoutPriority(1)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "日付・種類・カテゴリ・読取文字で検索")
            .navigationDestination(for: PhotoAsset.self) { asset in
                PhotoDetailView(
                    photoLibrary: photoLibrary,
                    ocrService: ocrService,
                    indexService: indexService,
                    learningService: learningService,
                    asset: asset
                )
            }
            .sheet(item: $debugPresentedAsset) { asset in
                NavigationStack {
                    PhotoDetailView(
                        photoLibrary: photoLibrary,
                        ocrService: ocrService,
                        indexService: indexService,
                        learningService: learningService,
                        asset: asset
                    )
                }
            }
            .task {
                applyAssetIndex()
                if photoLibrary.canReadPhotos &&
                    photoLibrary.assets.isEmpty &&
                    photoLibrary.hasRecoverableImportState == false {
                    await photoLibrary.loadRecentAssets()
                }

                if photoLibrary.latestLoadedBatch.isEmpty == false {
                    await indexService.rebuild(for: photoLibrary.latestLoadedBatch, ocrService: ocrService)
                } else if photoLibrary.assets.isEmpty == false {
                    await indexService.rebuild(
                        for: Array(photoLibrary.assets.prefix(visibleAssetLimit)),
                        ocrService: ocrService
                    )
                }
                await indexService.refreshFilterCountsSnapshot(scope: selectedDisplayState)
                fetchGridPage(reset: true)
                presentDebugAssetIfNeeded()
            }
            .onChange(of: photoLibrary.assets) {
                applyAssetIndex()
                if pageIdentifiers.isEmpty {
                    fetchGridPage(reset: true)
                }
                presentDebugAssetIfNeeded()
            }
            .onChange(of: searchText) {
                scheduleSearchUpdate()
            }
            .onChange(of: includeUnwantedInSearch) {
                fetchGridPage(reset: true)
            }
            .onChange(of: selectedDisplayState) {
                Task {
                    await indexService.refreshFilterCountsSnapshot(scope: selectedDisplayState)
                }
                fetchGridPage(reset: true)
            }
            .onChange(of: selectedCategory) {
                fetchGridPage(reset: true)
            }
            .onChange(of: selectedScreenshotSubcategory) {
                fetchGridPage(reset: true)
            }
            .onChange(of: photoLibrary.latestLoadedBatch) {
                let batch = photoLibrary.latestLoadedBatch
                guard batch.isEmpty == false else {
                    return
                }

                Task {
                    await indexService.rebuild(for: batch, ocrService: ocrService)
                    if shouldRefreshGridAfterImportBatch {
                        await indexService.refreshFilterCountsSnapshot(scope: selectedDisplayState)
                        fetchGridPage(reset: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var topStatusSection: some View {
        switch mode {
        case .library:
            statusHeader
        case .search:
            if photoLibrary.shouldShowImportProgress {
                PhotoImportCompactStatusCard(photoLibrary: photoLibrary)
            }
        }
    }

    @ViewBuilder
    private var importStatusSection: some View {
        switch mode {
        case .library:
            if photoLibrary.shouldShowImportProgress {
                PhotoImportProgressCard(photoLibrary: photoLibrary)
            } else if photoLibrary.shouldShowCompletedImportSummary {
                PhotoImportCompactStatusCard(photoLibrary: photoLibrary)
            }
        case .search:
            EmptyView()
        }
    }

    private var shouldPresentFirstAssetForDebug: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-ShimaiBakoOpenFirstPhoto")
        #else
        false
        #endif
    }

    private static var debugInitialSearchText: String {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments

        if let argumentIndex = arguments.firstIndex(of: "-ShimaiBakoInitialSearchText") {
            let valueIndex = arguments.index(after: argumentIndex)
            if valueIndex < arguments.endIndex {
                return arguments[valueIndex]
            }
        }
        #endif

        return ""
    }

    private func presentDebugAssetIfNeeded() {
        guard shouldPresentFirstAssetForDebug,
              didPresentDebugAsset == false,
              let asset = photoLibrary.assets.first else {
            return
        }

        didPresentDebugAsset = true
        debugPresentedAsset = asset
    }

    private var statusHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: photoLibrary.authorizationStatus == .limited ? "person.crop.rectangle.stack" : "lock.shield.fill")
                .foregroundStyle(Color(red: 0.16, green: 0.42, blue: 0.75))

            VStack(alignment: .leading, spacing: 3) {
                Text(photoLibrary.statusTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))

                Text("写真は外部送信しません。\(photoLibrary.readLimitTitle)を読み取り専用で表示します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Text(statusDetailText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()
        }
        .padding(12)
        .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
    }

    private var statusDetailText: String {
        let stateTitle = selectedDisplayState.title
        let searchIsActive = effectiveSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false

        if searchIsActive {
            return "\(stateTitle)から検索結果 \(resultTotalCount)件。検索は端末内だけで実行します。"
        }

        return "\(stateTitle) \(resultTotalCount)件。不要候補や非表示はしまい箱内の表示状態です。"
    }

    private var categoryChips: some View {
        CategoryChipRow(
            indexService: indexService,
            selectedDisplayState: selectedDisplayState,
            selectedCategory: $selectedCategory,
            selectedScreenshotSubcategory: $selectedScreenshotSubcategory
        )
    }

    private var screenshotSubcategoryChips: some View {
        ScreenshotSubcategoryChipRow(
            indexService: indexService,
            selectedDisplayState: selectedDisplayState,
            selectedScreenshotSubcategory: $selectedScreenshotSubcategory
        )
    }

    private var displayStateChips: some View {
        DisplayStateChipRow(indexService: indexService, selectedDisplayState: $selectedDisplayState)
    }

    private var categoryFilterSection: some View {
        VStack(spacing: showsCategoryFilters ? 6 : 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    showsCategoryFilters.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Label(showsCategoryFilters ? "カテゴリを隠す" : "カテゴリを表示", systemImage: "line.3.horizontal.decrease.circle")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    Spacer(minLength: 8)

                    Text(selectedCategory.shortTitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    Image(systemName: showsCategoryFilters ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                }
                .frame(height: 32)
                .padding(.horizontal, 10)
                .foregroundStyle(Color(red: 0.13, green: 0.22, blue: 0.34))
                .background(.white.opacity(0.76), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showsCategoryFilters ? "カテゴリを隠す" : "カテゴリを表示")

            if showsCategoryFilters {
                VStack(spacing: 4) {
                    categoryChips
                    if selectedCategory == .screenshots {
                        screenshotSubcategoryChips
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private var searchOptions: some View {
        if mode == .search {
            Toggle(isOn: $includeUnwantedInSearch) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("不要候補も検索に含める")
                        .font(.caption.weight(.semibold))

                    Text("元写真・元動画は削除されません。しまい箱内の表示状態だけを切り替えます。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .padding(10)
            .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func displayStateIncludes(_ asset: PhotoAsset) -> Bool {
        let state = indexService.displayState(for: asset, ocrService: ocrService)

        if mode == .search,
           selectedDisplayState == .active,
           includeUnwantedInSearch {
            return state == .active || state == .unwanted
        }

        return state == selectedDisplayState
    }

    private func categoryIncludes(_ asset: PhotoAsset) -> Bool {
        guard selectedCategory != .all else {
            return true
        }

        return indexService.category(for: asset, ocrService: ocrService) == selectedCategory
    }

    private func screenshotSubcategoryIncludes(_ asset: PhotoAsset) -> Bool {
        guard selectedCategory == .screenshots,
              selectedScreenshotSubcategory != .all else {
            return true
        }

        let subcategory = indexService.screenshotSubcategory(for: asset, ocrService: ocrService) ?? .otherScreenshot
        return subcategory == selectedScreenshotSubcategory
    }

    @ViewBuilder
    private var content: some View {
        if photoLibrary.hasRecoverableImportState && visibleAssets.isEmpty {
            ImportRecoveryEmptyView(photoLibrary: photoLibrary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if (photoLibrary.isLoading || isFetchingPage) && visibleAssets.isEmpty {
            VStack(spacing: 14) {
                ProgressView(isFetchingPage ? "写真一覧を準備中" : "読み込み中")
                Text("元写真・元動画は削除・変更しません。進まない場合は中止して軽量モードで再読み込みできます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visibleAssets.isEmpty {
            ContentUnavailableView(
                effectiveSearchText.isEmpty ? "写真がありません" : "見つかりません",
                systemImage: effectiveSearchText.isEmpty ? "photo.on.rectangle.angled" : "magnifyingglass",
                description: Text(effectiveSearchText.isEmpty ? "許可された写真があるとここに表示されます。" : "検索条件を変えてください。")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 12) {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(visibleAssets) { asset in
                            NavigationLink(value: asset) {
                                VStack(alignment: .leading, spacing: 5) {
                                    PhotoThumbnailView(
                                        photoLibrary: photoLibrary,
                                        ocrService: ocrService,
                                        asset: asset,
                                        displayState: indexService.displayState(for: asset, ocrService: ocrService)
                                    )

                                    if shouldShowSearchMatch {
                                        SearchMatchSummaryView(
                                            match: indexService.searchMatch(asset: asset, query: effectiveSearchText, ocrService: ocrService),
                                            status: indexService.status(for: asset, ocrService: ocrService)
                                        )
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if visibleAssets.count < resultTotalCount {
                        Button {
                            fetchGridPage(reset: false)
                        } label: {
                            Label("さらに表示 \(min(visibleAssetLimit + 200, resultTotalCount)) / \(resultTotalCount)件", systemImage: "chevron.down.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.top, 4)
                    }
                }
                .padding(.bottom, 24)
            }
        }
    }

    private var shouldShowSearchMatch: Bool {
        mode == .search && effectiveSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func resetVisiblePage() {
        visibleAssetLimit = 200
    }

    private func applyAssetIndex() {
        var nextIndex = assetByID
        for asset in photoLibrary.assets {
            nextIndex[asset.id] = asset
        }
        assetByID = trimmedAssetIndex(nextIndex)
    }

    private var shouldRefreshGridAfterImportBatch: Bool {
        if pageIdentifiers.isEmpty || visibleAssets.isEmpty {
            return true
        }

        if photoLibrary.loadedAssetCount <= 200 {
            return true
        }

        if photoLibrary.importProgress.phase == .completed {
            return true
        }

        return photoLibrary.loadedAssetCount.isMultiple(of: 500)
    }

    private func trimmedAssetIndex(_ index: [String: PhotoAsset]) -> [String: PhotoAsset] {
        let pinnedIdentifiers = Set(pageIdentifiers)
            .union(photoLibrary.assets.map(\.id))
            .union(photoLibrary.latestLoadedBatch.map(\.id))
        var trimmed = index.filter { pinnedIdentifiers.contains($0.key) }

        if trimmed.count > 900 {
            trimmed = Dictionary(uniqueKeysWithValues: trimmed.prefix(900).map { ($0.key, $0.value) })
        }

        return trimmed
    }

    private func scheduleSearchUpdate() {
        searchDebounceTask?.cancel()
        let nextText = searchText
        searchDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard Task.isCancelled == false else {
                return
            }

            await MainActor.run {
                effectiveSearchText = nextText
                fetchGridPage(reset: true)
            }
        }
    }

    private func fetchGridPage(reset: Bool) {
        if reset {
            resetVisiblePage()
        } else {
            visibleAssetLimit += 200
        }

        pageGeneration += 1
        let generation = pageGeneration
        let request = PhotoIndexPageRequest(
            query: effectiveSearchText,
            displayState: selectedDisplayState,
            includeUnwantedWhenActive: mode == .search && includeUnwantedInSearch,
            category: selectedCategory,
            screenshotSubcategory: selectedScreenshotSubcategory,
            limit: visibleAssetLimit,
            offset: 0
        )

        pageFetchTask?.cancel()
        isFetchingPage = true
        pageFetchTask = Task {
            let page = await indexService.page(matching: request)
            guard Task.isCancelled == false else {
                finishPageFetchIfCurrent(generation)
                return
            }

            let resolvedAssets = photoLibrary.assets(for: page.localIdentifiers)
            guard Task.isCancelled == false else {
                finishPageFetchIfCurrent(generation)
                return
            }

            await MainActor.run {
                guard generation == pageGeneration else {
                    return
                }

                PerformanceTelemetry.mark(.applyGridSnapshot, "items=\(page.localIdentifiers.count) total=\(page.totalCount)")
                var nextIndex = assetByID
                for asset in resolvedAssets {
                    nextIndex[asset.id] = asset
                }
                pageIdentifiers = resolvedAssets.map(\.id)
                assetByID = trimmedAssetIndex(nextIndex)
                pageTotalCount = page.totalCount
                isFetchingPage = false
            }
        }
    }

    @MainActor
    private func finishPageFetchIfCurrent(_ generation: Int) {
        guard generation == pageGeneration else {
            return
        }

        isFetchingPage = false
    }

}

private struct DisplayStateChipRow: View {
    @ObservedObject var indexService: PhotoIndexService
    @Binding var selectedDisplayState: PhotoDisplayState

    var body: some View {
        HorizontalChipScroll {
            ForEach(PhotoDisplayState.allCases) { state in
                FilterChipButton(
                    title: "\(state.chipTitle) \(countText(indexService.filterCountsSnapshot.displayStateCounts?[state]))",
                    systemImage: state.systemImage,
                    isSelected: selectedDisplayState == state
                ) {
                    selectedDisplayState = state
                }
            }
        }
    }

    private func countText(_ count: Int?) -> String {
        count.map(String.init) ?? "—"
    }
}

private struct CategoryChipRow: View {
    @ObservedObject var indexService: PhotoIndexService
    let selectedDisplayState: PhotoDisplayState
    @Binding var selectedCategory: PhotoCategory
    @Binding var selectedScreenshotSubcategory: ScreenshotSubcategory

    var body: some View {
        let snapshot = indexService.filterCountsSnapshot(for: selectedDisplayState)
        HorizontalChipScroll {
            ForEach(PhotoCategory.allCases) { category in
                FilterChipButton(
                    title: "\(category.shortTitle) \(countText(snapshot.categoryCounts?[category]))",
                    systemImage: category.systemImage,
                    isSelected: selectedCategory == category
                ) {
                    selectedCategory = category
                    if category != .screenshots {
                        selectedScreenshotSubcategory = .all
                    }
                }
            }
        }
    }

    private func countText(_ count: Int?) -> String {
        count.map(String.init) ?? "—"
    }
}

private struct ScreenshotSubcategoryChipRow: View {
    @ObservedObject var indexService: PhotoIndexService
    let selectedDisplayState: PhotoDisplayState
    @Binding var selectedScreenshotSubcategory: ScreenshotSubcategory

    var body: some View {
        let snapshot = indexService.filterCountsSnapshot(for: selectedDisplayState)
        HorizontalChipScroll(height: 40) {
            ForEach(ScreenshotSubcategory.allCases) { subcategory in
                FilterChipButton(
                    title: "\(subcategory.shortTitle) \(countText(snapshot.screenshotSubcategoryCounts?[subcategory]))",
                    systemImage: subcategory.systemImage,
                    isSelected: selectedScreenshotSubcategory == subcategory,
                    font: .caption2.weight(.semibold)
                ) {
                    selectedScreenshotSubcategory = subcategory
                }
            }
        }
    }

    private func countText(_ count: Int?) -> String {
        count.map(String.init) ?? "—"
    }
}

private struct HorizontalChipScroll<Content: View>: View {
    var height: CGFloat = 44
    private let content: Content

    init(height: CGFloat = 44, @ViewBuilder content: () -> Content) {
        self.height = height
        self.content = content()
    }

    var body: some View {
        LockedHorizontalScrollView(height: height) {
            HStack(spacing: 8) {
                content
            }
            .padding(.horizontal, 2)
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(height: height)
        .clipped()
    }
}

private struct LockedHorizontalScrollView<Content: View>: UIViewRepresentable {
    let height: CGFloat
    private let content: Content

    init(height: CGFloat, @ViewBuilder content: () -> Content) {
        self.height = height
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(content: content)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.alwaysBounceVertical = false
        scrollView.isDirectionalLockEnabled = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        scrollView.delegate = context.coordinator

        let hostedView = context.coordinator.hostingController.view!
        hostedView.backgroundColor = .clear
        hostedView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(hostedView)

        NSLayoutConstraint.activate([
            hostedView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            hostedView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            hostedView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            hostedView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            hostedView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.hostingController.rootView = content
        scrollView.alwaysBounceVertical = false
        scrollView.contentOffset.y = 0
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let hostingController: UIHostingController<Content>

        init(content: Content) {
            hostingController = UIHostingController(rootView: content)
            super.init()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            if scrollView.contentOffset.y != 0 {
                scrollView.contentOffset.y = 0
            }
        }
    }
}

private struct FilterChipButton: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    var font: Font = .caption.weight(.semibold)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .font(font)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 11)
                .frame(height: 32)
                .foregroundStyle(isSelected ? .white : Color(red: 0.13, green: 0.22, blue: 0.34))
                .background(
                    Capsule()
                        .fill(isSelected ? Color(red: 0.16, green: 0.42, blue: 0.75) : Color.white.opacity(0.78))
                )
                .overlay(
                    Capsule()
                        .stroke(isSelected ? Color(red: 0.16, green: 0.42, blue: 0.75) : Color.gray.opacity(0.28), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct SearchMatchSummaryView: View {
    let match: PhotoSearchMatch
    let status: OCRStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if match.matchedFields.isEmpty {
                Text(status == .unprocessed ? "読取すると文字検索しやすくなります" : "一致情報を確認中")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            } else {
                Text(match.matchedFields.map(\.title).joined(separator: "・"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            if let snippet = match.ocrSnippet {
                Text(snippet)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct IndexStoreStatusContainer: View {
    @ObservedObject private var progressStore = IndexProgressStore.shared

    var body: some View {
        if let statusText = progressStore.statusText {
            IndexStoreStatusCard(statusText: statusText)
        }
    }
}

private struct IndexStoreStatusCard: View {
    let statusText: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ProgressView()
                .controlSize(.small)

            VStack(alignment: .leading, spacing: 3) {
                Text(statusText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))

                Text("元写真・元動画は削除・変更しません。旧JSONは移行元として残します。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct PhotoThumbnailView: View {
    @ObservedObject var photoLibrary: PhotoLibraryService
    @ObservedObject var ocrService: OCRService
    let asset: PhotoAsset
    let displayState: PhotoDisplayState
    @State private var thumbnailImage: UIImage?

    private let thumbnailSize = CGSize(width: 360, height: 360)

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let image = thumbnailImage ?? photoLibrary.cachedThumbnail(for: asset) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(Color.white.opacity(0.78))
                        .overlay {
                            Image(systemName: asset.mediaType == .video ? "video.fill" : "photo")
                                .font(.title2)
                                .foregroundStyle(Color(red: 0.16, green: 0.42, blue: 0.75).opacity(0.7))
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            HStack(spacing: 4) {
                Text(asset.kindLabel)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)

                if asset.isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.caption2)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(.black.opacity(0.48), in: Capsule())
            .padding(6)

            VStack {
                HStack(alignment: .top) {
                    if displayState != .active {
                        displayStateBadge
                    }

                    Spacer()

                    if asset.mediaType == .image {
                        ocrBadge
                    }
                }

                Spacer()
            }
            .padding(6)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onAppear {
            if let image = photoLibrary.cachedThumbnail(for: asset) {
                thumbnailImage = image
            } else {
                photoLibrary.requestThumbnail(for: asset, targetSize: thumbnailSize) { image in
                    thumbnailImage = image
                }
            }
        }
        .onDisappear {
            photoLibrary.cancelThumbnailRequest(for: asset, targetSize: thumbnailSize)
        }
    }

    private var displayStateBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: displayState.systemImage)
                .font(.caption2.weight(.semibold))

            Text(displayState.chipTitle)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(Color(red: 0.25, green: 0.33, blue: 0.42).opacity(0.82), in: Capsule())
        .accessibilityLabel(displayState.title)
    }

    private var ocrBadge: some View {
        let status = ocrService.status(for: asset)

        return HStack(spacing: 3) {
            Image(systemName: status.systemImage)
                .font(.caption2.weight(.semibold))

            Text(status.badgeTitle)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
            .foregroundStyle(.white)
            .lineLimit(1)
            .frame(minWidth: 34, maxWidth: 44)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(statusColor(status).opacity(0.82), in: Capsule())
            .accessibilityLabel(status.title)
    }

    private func statusColor(_ status: OCRStatus) -> Color {
        switch status {
        case .unprocessed:
            .gray
        case .processing:
            Color(red: 0.16, green: 0.42, blue: 0.75)
        case .completed:
            Color(red: 0.14, green: 0.55, blue: 0.32)
        case .failed:
            Color(red: 0.75, green: 0.24, blue: 0.18)
        }
    }
}
