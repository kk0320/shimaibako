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
    let ocrProgressStore: OCRProgressStore
    @ObservedObject var ocrJobRunner: OCRJobRunner
    let mode: PhotoGridMode
    @Environment(\.scenePhase) private var scenePhase

    @State private var searchText: String
    @State private var selectedDisplayState: PhotoDisplayState = .active
    @State private var includeUnwantedInSearch = false
    @State private var selectedCategory: PhotoCategory = .all
    @State private var selectedScreenshotSubcategory: ScreenshotSubcategory = .all
    @State private var selectedQuickOCRLimit: QuickOCRLimit = .twenty
    @State private var selectedBulkTarget: OCRBatchTarget = .visible
    @State private var visibleAssetLimit = 200
    @AppStorage("shimaibako.ocrBatchLimit") private var selectedBulkLimit = 20
    @AppStorage("shimaibako.photoGridShowsCategoryFilters") private var showsCategoryFilters = false
    @AppStorage("shimaibako.photoGridShowsOCRDetails") private var showsOCRDetails = false
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
    @State private var isRunningBulkOCR = false
    @State private var bulkOCRTask: Task<Void, Never>?
    @State private var bulkCancellationRequested = false
    @State private var bulkWasCancelled = false
    @State private var bulkInterruptedReason: String?
    @State private var bulkTotal = 0
    @State private var bulkCompleted = 0
    @State private var bulkFailed = 0
    @State private var didStartDebugBulkOCR = false
    @State private var pendingBulkTargets: [PhotoAsset] = []
    @State private var pendingBulkCandidateCount = 0
    @State private var showingBulkSafety = false
    @State private var pendingPersistentOCRPlan: OCRExecutionPlan?
    @State private var pendingPersistentOCRCandidateCount = 0
    @State private var showingPersistentOCRSafety = false
    @State private var showingVisibleOCRClearConfirmation = false

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
        ocrProgressStore: OCRProgressStore,
        ocrJobRunner: OCRJobRunner,
        mode: PhotoGridMode
    ) {
        self.photoLibrary = photoLibrary
        self.ocrService = ocrService
        self.indexService = indexService
        self.learningService = learningService
        self.deviceSafety = deviceSafety
        self.ocrProgressStore = ocrProgressStore
        self.ocrJobRunner = ocrJobRunner
        self.mode = mode
        let initialSearchText = mode == .search ? Self.debugInitialSearchText : ""
        _searchText = State(initialValue: initialSearchText)
        _effectiveSearchText = State(initialValue: initialSearchText)
    }

    private var filteredAssets: [PhotoAsset] {
        pageAssets
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

    private var displayScopedAssets: [PhotoAsset] {
        pageAssets
    }

    private var resultTotalCount: Int {
        if pageTotalCount > 0 {
            return pageTotalCount
        }

        return pageAssets.count
    }

    private var currentFilterSnapshot: FilterSnapshot {
        FilterSnapshot(
            query: effectiveSearchText,
            displayState: selectedDisplayState,
            includeUnwantedWhenActive: mode == .search && includeUnwantedInSearch,
            category: selectedCategory,
            screenshotSubcategory: selectedScreenshotSubcategory
        )
    }

    private var bulkTargetAssets: [PhotoAsset] {
        switch selectedBulkTarget {
        case .visible:
            filteredAssets
        case .screenshots:
            displayScopedAssets.filter { $0.isScreenshot }
        case .documentCandidates:
            displayScopedAssets.filter {
                indexService.category(for: $0, ocrService: ocrService) == .documentCandidate
            }
        case .unprocessed:
            displayScopedAssets
        }
    }

    private var bulkTargetCandidateCount: Int {
        bulkTargetAssets.filter { asset in
            asset.mediaType == .image
        }.count
    }

    private var bulkEligibleTargets: [PhotoAsset] {
        bulkTargetAssets.filter { asset in
            let status = indexService.status(for: asset, ocrService: ocrService)
            return asset.mediaType == .image &&
            status != .completed &&
            status != .completedNoText &&
            status != .skipped &&
            status != .processing
        }
    }

    private var bulkCandidates: [PhotoAsset] {
        Array(bulkEligibleTargets.prefix(selectedQuickOCRLimit.rawValue))
    }

    private var isBulkOCRBusy: Bool {
        isRunningBulkOCR || bulkOCRTask != nil
    }

    private var isPersistentOCRBlockingBatch: Bool {
        ocrJobRunner.isRunning ||
        ocrJobRunner.isPreparingJob ||
        (ocrJobRunner.activeJob?.state.isActive ?? false)
    }

    private var visibleOCRClearTargets: [PhotoAsset] {
        filteredAssets.filter { asset in
            guard asset.mediaType == .image else {
                return false
            }

            let status = indexService.status(for: asset, ocrService: ocrService)
            return status == .completed || status == .completedNoText || status == .cloudPending || status == .skipped || status == .failed
        }
    }

    private var bulkProcessingCount: Int {
        isRunningBulkOCR ? max(bulkTotal - bulkCompleted - bulkFailed, 0) : 0
    }

    private var bulkStatusText: String {
        if isRunningBulkOCR && bulkCancellationRequested {
            return "キャンセル中です。処理中の写真が終わると停止します。"
        }

        if isRunningBulkOCR {
            return "対象\(bulkTotal)件を読み取り中です。"
        }

        if let bulkInterruptedReason {
            return "中断しました。\(bulkInterruptedReason)"
        }

        if bulkWasCancelled {
            return "キャンセル済みです。完了分は保存済みです。"
        }

        if bulkTotal > 0 {
            return "まとめてOCRが完了しました。"
        }

        return ""
    }

    private var shouldShowCompactBulkStatus: Bool {
        isRunningBulkOCR || bulkTotal > 0 || bulkInterruptedReason != nil || bulkWasCancelled
    }

    private var compactBulkStatusText: String {
        let processedCount = min(bulkCompleted + bulkFailed, bulkTotal)

        if isRunningBulkOCR && bulkCancellationRequested {
            return "停止中 \(processedCount)/\(bulkTotal)"
        }

        if isRunningBulkOCR {
            return "処理中 \(processedCount)/\(bulkTotal)"
        }

        if bulkInterruptedReason != nil {
            return "中断 \(processedCount)/\(bulkTotal)"
        }

        if bulkWasCancelled {
            return "中止 \(processedCount)/\(bulkTotal)"
        }

        if bulkTotal > 0 {
            return "完了 \(bulkCompleted)/\(bulkTotal)"
        }

        return ""
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                VStack(spacing: 12) {
                    topStatusSection
                    IndexStoreStatusContainer()
                    importStatusSection
                    displayStateChips
                    searchOptions
                    categoryFilterSection
                    if mode == .library {
                        bulkOCRControls
                        persistentOCRProgressSection
                    }
                    content
                        .layoutPriority(1)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "日付・種類・カテゴリ・OCRで検索")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            await photoLibrary.loadRecentAssets()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("再読み込み")
                }
            }
            .refreshable {
                await photoLibrary.loadRecentAssets()
            }
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
                        asset: asset,
                        automaticallyRunOCR: shouldRunOCRForDebug
                    )
                }
            }
            .sheet(isPresented: $showingBulkSafety) {
                OCRBatchSafetyView(
                    filter: currentFilterSnapshot,
                    targetTitle: selectedBulkTarget.title,
                    candidateCount: pendingBulkCandidateCount,
                    eligibleCount: pendingBulkTargets.count,
                    selectedLimit: $selectedQuickOCRLimit,
                    iCloudMode: photoLibrary.iCloudMode,
                    deviceSafety: deviceSafety,
                    isRunningOCR: isBulkOCRBusy,
                    onCancel: {
                        pendingBulkTargets = []
                        pendingBulkCandidateCount = 0
                        showingBulkSafety = false
                    },
                    onStart: {
                        selectedBulkLimit = selectedQuickOCRLimit.rawValue
                        let targets = Array(pendingBulkTargets.prefix(selectedQuickOCRLimit.rawValue))
                        pendingBulkTargets = []
                        pendingBulkCandidateCount = 0
                        showingBulkSafety = false
                        startBulkOCR(with: targets)
                    }
                )
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showingPersistentOCRSafety) {
                OCRPersistentJobSafetyView(
                    plan: pendingPersistentOCRPlan ?? .smartLibrary(
                        libraryRevision: Int64(indexService.indexedRecordCount),
                        options: SmartOCROptions()
                    ),
                    candidateCount: pendingPersistentOCRCandidateCount,
                    iCloudMode: photoLibrary.iCloudMode,
                    deviceSafety: deviceSafety,
                    isRunningOCR: ocrJobRunner.isRunning,
                    onCancel: {
                        clearPendingPersistentOCR()
                    },
                    onUseSmart: {
                        let plan = OCRExecutionPlan.smartLibrary(
                            libraryRevision: Int64(indexService.indexedRecordCount),
                            options: SmartOCROptions()
                        )
                        clearPendingPersistentOCR()
                        startPersistentOCR(plan: plan)
                    },
                    onStart: {
                        let plan = pendingPersistentOCRPlan ?? .smartLibrary(
                            libraryRevision: Int64(indexService.indexedRecordCount),
                            options: SmartOCROptions()
                        )
                        clearPendingPersistentOCR()
                        startPersistentOCR(plan: plan)
                    }
                )
                .presentationDetents([.medium, .large])
            }
            .alert("表示中のOCR結果を削除しますか？", isPresented: $showingVisibleOCRClearConfirmation) {
                Button("キャンセル", role: .cancel) {}
                Button("OCR結果を削除", role: .destructive) {
                    Task {
                        await clearVisibleOCRResults()
                    }
                }
            } message: {
                Text("写真アプリの元写真・元動画は削除されません。しまい箱内のOCR結果だけを削除します。手動分類、不要候補、メモ、タグは削除されません。")
            }
            .task {
                if let savedLimit = QuickOCRLimit(rawValue: selectedBulkLimit) {
                    selectedQuickOCRLimit = savedLimit
                } else {
                    selectedBulkLimit = selectedQuickOCRLimit.rawValue
                }
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
                startDebugBulkOCRIfNeeded()
            }
            .onChange(of: photoLibrary.assets) {
                applyAssetIndex()
                if pageIdentifiers.isEmpty {
                    fetchGridPage(reset: true)
                }
                presentDebugAssetIfNeeded()
                startDebugBulkOCRIfNeeded()
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
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase != .active, isRunningBulkOCR {
                    cancelBulkOCR(reason: "アプリがバックグラウンドへ移行したため停止しました。")
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

    private var shouldRunOCRForDebug: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-ShimaiBakoRunOCR")
        #else
        false
        #endif
    }

    private var shouldRunBulkOCRForDebug: Bool {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-ShimaiBakoRunBulkOCR") || arguments.contains("-ShimaiBakoRunBatchOCR")
        #else
        false
        #endif
    }

    private static var debugBulkOCRCancellationDelay: UInt64? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments

        if let argumentIndex = arguments.firstIndex(of: "-ShimaiBakoCancelBulkOCRAfterSeconds") {
            let valueIndex = arguments.index(after: argumentIndex)
            if valueIndex < arguments.endIndex,
               let seconds = Double(arguments[valueIndex]),
               seconds >= 0 {
                return UInt64(seconds * 1_000_000_000)
            }
        }
        #endif

        return nil
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

    private func startDebugBulkOCRIfNeeded() {
        guard shouldRunBulkOCRForDebug,
              didStartDebugBulkOCR == false,
              bulkCandidates.isEmpty == false else {
            return
        }

        didStartDebugBulkOCR = true
        startBulkOCR(with: bulkCandidates)

        if let delay = Self.debugBulkOCRCancellationDelay {
            Task {
                try? await Task.sleep(nanoseconds: delay)
                cancelBulkOCR()
            }
        }
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

    private var bulkOCRControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("OCR")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 30, alignment: .leading)

                Menu {
                    ForEach(OCRBatchTarget.allCases) { target in
                        Button {
                            selectedBulkTarget = target
                        } label: {
                            Label(target.title, systemImage: selectedBulkTarget == target ? "checkmark" : "circle")
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isBulkOCRBusy)
                .accessibilityLabel("OCR対象を選択")

                Menu {
                    ForEach(QuickOCRLimit.allCases) { limit in
                        Button {
                            selectedQuickOCRLimit = limit
                            selectedBulkLimit = limit.rawValue
                        } label: {
                            Label(limit.title, systemImage: selectedQuickOCRLimit == limit ? "checkmark" : "circle")
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "number.circle")
                            .font(.caption.weight(.semibold))
                        Text(selectedQuickOCRLimit.compactTitle)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(minWidth: 50)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isBulkOCRBusy || isPersistentOCRBlockingBatch)
                .accessibilityLabel("OCR件数を選択")

                if isRunningBulkOCR {
                    Button(role: .cancel) {
                        cancelBulkOCR()
                    } label: {
                        Label(bulkCancellationRequested ? "停止中" : "キャンセル", systemImage: "xmark.circle")
                            .labelStyle(.titleAndIcon)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(bulkCancellationRequested)
                } else {
                    Button {
                        presentOCRStart()
                    } label: {
                        Label("まとめてOCR", systemImage: "text.viewfinder")
                            .labelStyle(.titleAndIcon)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isBulkOCRBusy || isPersistentOCRBlockingBatch)
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showsOCRDetails.toggle()
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(showsOCRDetails ? "隠す" : "詳細")
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Image(systemName: showsOCRDetails ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.bold))
                    }
                    .frame(minWidth: 44)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(showsOCRDetails ? "OCR詳細を隠す" : "OCR詳細を表示")
            }
            .frame(height: 36)
            .padding(.horizontal, 2)

            if showsOCRDetails {
                bulkOCRDetails
            } else if shouldShowCompactBulkStatus {
                bulkOCRCompactStatus
            }
        }
        .padding(12)
        .background(.white.opacity(0.76), in: RoundedRectangle(cornerRadius: 8))
    }

    private var bulkOCRCompactStatus: some View {
        HStack(spacing: 8) {
            Label(compactBulkStatusText, systemImage: bulkCompactStatusIcon)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            if let bulkInterruptedReason {
                Text(bulkInterruptedReason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
    }

    private var bulkCompactStatusIcon: String {
        if isRunningBulkOCR && bulkCancellationRequested {
            return "xmark.circle"
        }

        if isRunningBulkOCR {
            return "text.viewfinder"
        }

        if bulkInterruptedReason != nil {
            return "pause.circle"
        }

        if bulkWasCancelled {
            return "xmark.circle"
        }

        return "checkmark.circle"
    }

    private var bulkOCRDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isRunningBulkOCR || bulkTotal > 0 || bulkInterruptedReason != nil || bulkWasCancelled {
                bulkOCRProgressDetails
            } else {
                Text("現在の検索・カテゴリで表示中の写真だけが対象です。元写真・元動画は削除・変更されません。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            fullOCRManagementSection

            if visibleOCRClearTargets.isEmpty == false {
                Divider()

                Button(role: .destructive) {
                    showingVisibleOCRClearConfirmation = true
                } label: {
                    Label("表示中のOCR結果を削除", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isBulkOCRBusy)

                Text("現在の検索・カテゴリで表示中の写真だけが対象です。元写真・元動画は削除・変更されません。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var fullOCRManagementSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("全数OCR", systemImage: "rectangle.stack.badge.play")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))

                Spacer(minLength: 0)

                Menu {
                    fullOCRManagementMenuItems
                } label: {
                    Label("全数OCRを管理", systemImage: "ellipsis.circle")
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isBulkOCRBusy)
            }

            if isPersistentOCRBlockingBatch {
                Text("全数OCRを実行中です。まとめてOCRは待機していますが、全数OCRの管理は続けられます。")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color(red: 0.75, green: 0.37, blue: 0.08))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("全数OCRは専用確認画面から開始します。まとめてOCRは最大100件までで、全数OCRは開始しません。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var fullOCRManagementMenuItems: some View {
        if ocrJobRunner.isRunning || ocrJobRunner.isPreparingJob {
            Button {
                ocrJobRunner.pause()
            } label: {
                Label("一時停止", systemImage: "pause.circle")
            }
        } else if let job = ocrJobRunner.activeJob,
                  job.state.isActive {
            Button {
                ocrJobRunner.resume()
            } label: {
                Label("続きから再開", systemImage: "play.circle")
            }
        } else {
            Button {
                presentPersistentOCRStart(plan: .filteredAll(filter: currentFilterSnapshot))
            } label: {
                Label("現在の絞り込み結果すべて", systemImage: "line.3.horizontal.decrease.circle")
            }

            Button {
                presentPersistentOCRStart(
                    plan: .smartLibrary(
                        libraryRevision: Int64(indexService.indexedRecordCount),
                        options: SmartOCROptions()
                    )
                )
            } label: {
                Label("スマート全数OCR（推奨）", systemImage: "bolt.badge.checkmark")
            }

            Divider()

            Button {
                presentPersistentOCRStart(plan: .accuracyReview(sourceJobID: nil))
            } label: {
                Label("検索精度をさらに上げる", systemImage: "slider.horizontal.3")
            }
        }

        if let job = ocrJobRunner.activeJob,
           job.state.isActive || job.state == .failed {
            Divider()

            Button(role: .destructive) {
                ocrJobRunner.cancel()
            } label: {
                Label("残りの処理を終了", systemImage: "stop.circle")
            }
        }
    }

    private var bulkOCRProgressDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(bulkStatusText)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8)
            ], alignment: .leading, spacing: 6) {
                BulkProgressLabel(title: "対象", value: bulkTotal, systemImage: "scope")
                BulkProgressLabel(title: "処理中", value: bulkProcessingCount, systemImage: "hourglass")
                BulkProgressLabel(title: "完了", value: bulkCompleted, systemImage: "checkmark.circle")
                BulkProgressLabel(title: "失敗", value: bulkFailed, systemImage: "exclamationmark.triangle")

                if bulkWasCancelled {
                    Label("キャンセル済み", systemImage: "xmark.circle")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }

                if bulkInterruptedReason != nil {
                    Label("中断", systemImage: "pause.circle")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
        }
    }

    @ViewBuilder
    private var persistentOCRProgressSection: some View {
        VStack(spacing: 6) {
            CompactFullOCRProgressView(
                progressStore: ocrProgressStore,
                onShowDetails: {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showsOCRDetails = true
                    }
                },
                onPause: {
                    ocrJobRunner.pause()
                },
                onResume: {
                    ocrJobRunner.resume()
                },
                onCancel: {
                    ocrJobRunner.cancel()
                },
                onRetryFailures: {
                    ocrJobRunner.retryFailures()
                },
                onResumeCloudPending: {
                    ocrJobRunner.resumeCloudPendingWithNetworkAccess()
                }
            )

            #if DEBUG
            OCRProgressDebugView(
                progressStore: ocrProgressStore,
                activeJob: ocrJobRunner.activeJob,
                isRunning: ocrJobRunner.isRunning,
                isPreparing: ocrJobRunner.isPreparingJob
            )
            #endif
        }
    }

    private func presentOCRStart() {
        selectedBulkLimit = selectedQuickOCRLimit.rawValue
        #if DEBUG
        logOCRPlan(.quick(filter: currentFilterSnapshot, limit: selectedQuickOCRLimit), candidateCount: bulkTargetCandidateCount, jobType: "quick")
        #endif
        presentBulkSafety()
    }

    private func presentPersistentOCRStart(plan: OCRExecutionPlan) {
        guard plan.isQuick == false,
              ocrJobRunner.isRunning == false,
              ocrJobRunner.isPreparingJob == false else {
            return
        }

        deviceSafety.refresh()
        pendingPersistentOCRPlan = plan
        pendingPersistentOCRCandidateCount = estimatedCandidateCount(for: plan)
        showingPersistentOCRSafety = true

        #if DEBUG
        logOCRPlan(plan, candidateCount: pendingPersistentOCRCandidateCount, jobType: "persistent")
        #endif
    }

    private func startPersistentOCR(plan: OCRExecutionPlan) {
        Task {
            await ocrJobRunner.startJob(plan: plan)
        }
    }

    private func estimatedCandidateCount(for plan: OCRExecutionPlan) -> Int {
        switch plan {
        case .quick:
            return pendingBulkCandidateCount
        case .filteredAll:
            return resultTotalCount
        case .smartLibrary:
            return max(indexService.indexSummary.unprocessedOCRCount, indexService.indexedRecordCount)
        case .accuracyReview:
            return indexService.indexedRecordCount
        }
    }

    private func clearPendingPersistentOCR() {
        pendingPersistentOCRPlan = nil
        pendingPersistentOCRCandidateCount = 0
        showingPersistentOCRSafety = false
    }

    #if DEBUG
    private func logOCRPlan(_ plan: OCRExecutionPlan, candidateCount: Int, jobType: String) {
        print("OCR_PLAN kind=\(plan.debugKind) candidateCount=\(candidateCount) workloadClass=\(plan.workloadClass) thermalState=\(deviceSafety.thermalStateTitle) jobType=\(jobType)")
    }
    #endif

    private func presentBulkSafety() {
        let candidateCount = bulkTargetCandidateCount
        let targets = bulkEligibleTargets
        guard isBulkOCRBusy == false,
              bulkOCRTask == nil else {
            return
        }

        deviceSafety.refresh()
        pendingBulkTargets = targets
        pendingBulkCandidateCount = candidateCount
        showingBulkSafety = true
    }

    private func startBulkOCR(with targets: [PhotoAsset]) {
        guard targets.isEmpty == false,
              isBulkOCRBusy == false,
              bulkOCRTask == nil else {
            return
        }

        bulkOCRTask = Task {
            await runBulkOCR(targets: targets)
        }
    }

    private func cancelBulkOCR(reason: String? = nil) {
        guard isRunningBulkOCR else {
            return
        }

        if let reason {
            bulkInterruptedReason = reason
        }

        bulkCancellationRequested = true
        bulkOCRTask?.cancel()
    }

    private func runBulkOCR(targets: [PhotoAsset]) async {
        isRunningBulkOCR = true
        bulkCancellationRequested = false
        bulkWasCancelled = false
        bulkInterruptedReason = nil
        bulkTotal = targets.count
        bulkCompleted = 0
        bulkFailed = 0

        defer {
            if bulkCancellationRequested || Task.isCancelled {
                bulkWasCancelled = true
            }

            bulkCancellationRequested = false
            isRunningBulkOCR = false
            bulkOCRTask = nil
        }

        for asset in targets {
            deviceSafety.refresh()

            let workloadClass: OCRWorkloadClass = bulkTotal <= QuickOCRLimit.twenty.rawValue ? .small : .medium
            if let blockingReason = deviceSafety.blockingReason(for: workloadClass) {
                bulkInterruptedReason = blockingReason
                break
            }

            guard Task.isCancelled == false,
                  bulkCancellationRequested == false else {
                bulkWasCancelled = true
                break
            }

            guard let image = await photoLibrary.requestDisplayImage(for: asset) else {
                if Task.isCancelled || bulkCancellationRequested {
                    bulkWasCancelled = true
                    break
                }

                await ocrService.markFailure(asset: asset, message: imageLoadFailureMessage)
                await indexService.update(asset: asset, ocrService: ocrService)
                bulkFailed += 1
                continue
            }

            if Task.isCancelled || bulkCancellationRequested {
                bulkWasCancelled = true
                break
            }

            let result = await ocrService.recognize(asset: asset, image: image)
            if result?.ocrStatus == .completed || result?.ocrStatus == .completedNoText {
                bulkCompleted += 1
            } else {
                bulkFailed += 1
            }

            await indexService.update(asset: asset, ocrService: ocrService)

            if Task.isCancelled || bulkCancellationRequested {
                bulkWasCancelled = true
                break
            }
        }
    }

    private func clearVisibleOCRResults() async {
        guard isRunningBulkOCR == false else {
            return
        }

        let targets = visibleOCRClearTargets
        guard targets.isEmpty == false else {
            return
        }

        await indexService.clearOCRResults(for: targets, ocrService: ocrService)
        bulkTotal = 0
        bulkCompleted = 0
        bulkFailed = 0
        bulkWasCancelled = false
        bulkInterruptedReason = nil
    }

    private var imageLoadFailureMessage: String {
        switch photoLibrary.iCloudMode {
        case .offlinePreferred:
            "画像を読み込めませんでした。iCloud上の写真は、設定でiCloud取得を許可するとOCRできます。"
        case .allowDownload:
            "画像を読み込めませんでした。iCloud取得、通信状態、端末状態を確認してください。"
        }
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

private struct BulkProgressLabel: View {
    let title: String
    let value: Int
    let systemImage: String

    var body: some View {
        Label("\(title) \(value)", systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
    }
}

private struct OCRPersistentJobSafetyView: View {
    let plan: OCRExecutionPlan
    let candidateCount: Int
    let iCloudMode: ICloudPhotoMode
    @ObservedObject var deviceSafety: DeviceSafetyService
    let isRunningOCR: Bool
    let onCancel: () -> Void
    let onUseSmart: () -> Void
    let onStart: () -> Void

    private var isAccuracyReview: Bool {
        if case .accuracyReview = plan {
            return true
        }
        return false
    }

    private var countRows: [(String, String)] {
        switch plan {
        case .filteredAll:
            [
                ("現在の絞り込み結果", "\(candidateCount)件"),
                ("OCR済み・処理済みを除外", "開始時に確認"),
                ("今回の対象", "該当分を段階処理")
            ]
        case .smartLibrary:
            [
                ("検索対象の静止画", "\(candidateCount)件"),
                ("OCR済み・処理済み", "開始時に除外"),
                ("今回の対象", "未処理分を段階処理")
            ]
        case .accuracyReview:
            [
                ("対象候補", "\(candidateCount)件"),
                ("処理内容", "精度不足候補を再確認"),
                ("今回の対象", "開始時に確認")
            ]
        case .quick:
            []
        }
    }

    private var leadingDescription: String {
        switch plan {
        case .filteredAll:
            "現在の検索・カテゴリ・表示状態で絞り込んだ写真を、永続ジョブとして段階的にOCRします。"
        case .smartLibrary:
            "スクリーンショットや書類を優先し、端末の状態に合わせて少しずつOCRします。"
        case .accuracyReview:
            "スマート全数OCR後に検索精度をさらに上げたい場合の上級者向け処理です。"
        case .quick:
            ""
        }
    }

    private var blockingReason: String? {
        if isRunningOCR {
            return "OCRジョブを実行中です。"
        }

        if candidateCount == 0 {
            return "OCR対象がありません。"
        }

        return deviceSafety.blockingReason(for: plan.workloadClass)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(plan.title, systemImage: "text.viewfinder")
                            .font(.headline)
                            .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))

                        Text(leadingDescription)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(countRows, id: \.0) { row in
                                OCRBatchCountRow(title: row.0, value: row.1)
                            }
                        }
                        .padding(10)
                        .background(.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        switch plan {
                        case .smartLibrary:
                            SafetyBullet("スマート全数OCRはスクショ・書類を優先し、端末状態に合わせて少しずつOCRします。")
                        case .filteredAll:
                            SafetyBullet("現在の絞り込み結果だけを対象にします。")
                        case .accuracyReview:
                            SafetyBullet("全数高精度OCR相当の重い処理は上級者向けです。")
                            SafetyBullet("通常はスマート全数OCRを先に実行してください。")
                        case .quick:
                            EmptyView()
                        }
                        SafetyBullet("全数OCRは長時間実行され、端末が発熱する場合があります。")
                        SafetyBullet("充電中かつ涼しく安定した場所での実行をおすすめします。")
                        SafetyBullet("端末の温度が高い場合、処理は自動的に減速または一時停止します。")
                        SafetyBullet("OCR結果は端末内で扱います。")
                        SafetyBullet("元写真・元動画は削除・変更されません。")
                        SafetyBullet("最初は端末内にある画像を優先し、iCloud上の写真は待機扱いにします。")
                    }

                    Text("iCloud写真をご利用中で画像が端末上にない場合、iOSがAppleのiCloudから画像を取得することがあります。現在の設定: \(iCloudMode.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("端末状態")
                            .font(.subheadline.weight(.semibold))

                        ForEach(deviceSafety.notices) { notice in
                            Label(notice.message, systemImage: notice.level == .blocking ? "exclamationmark.triangle.fill" : "info.circle")
                                .font(.caption)
                                .foregroundStyle(notice.level == .blocking ? .red : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(12)
                    .background(.white.opacity(0.76), in: RoundedRectangle(cornerRadius: 8))

                    if let blockingReason {
                        Text(blockingReason)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if isAccuracyReview {
                        Button {
                            onUseSmart()
                        } label: {
                            Label("スマート全数OCRに変更", systemImage: "bolt.badge.checkmark")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(blockingReason != nil)
                    }
                }
                .padding(16)
            }
            .background(AppBackground())
            .navigationTitle("全数OCR確認")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル", action: onCancel)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(isAccuracyReview ? "上級者向けOCRを開始" : "開始", action: onStart)
                        .disabled(blockingReason != nil)
                }
            }
            .onAppear {
                deviceSafety.refresh()
            }
        }
    }
}

private struct OCRBatchSafetyView: View {
    let filter: FilterSnapshot
    let targetTitle: String
    let candidateCount: Int
    let eligibleCount: Int
    @Binding var selectedLimit: QuickOCRLimit
    let iCloudMode: ICloudPhotoMode
    @ObservedObject var deviceSafety: DeviceSafetyService
    let isRunningOCR: Bool
    let onCancel: () -> Void
    let onStart: () -> Void

    private var executionPlan: OCRExecutionPlan {
        .quick(filter: filter, limit: selectedLimit)
    }

    private var runCount: Int {
        min(eligibleCount, selectedLimit.rawValue)
    }

    private var noticeTitle: String {
        if runCount >= 100 {
            return "段階実行を強く推奨"
        }

        if runCount >= 21 {
            return "対象が多めです"
        }

        return "OCR開始前の確認"
    }

    private var startDisabledReason: String? {
        if isRunningOCR {
            return "OCRを実行中です"
        }

        if candidateCount == 0 {
            return "OCR対象がありません"
        }

        if eligibleCount == 0 {
            return "OCR済みまたは処理中の写真を除外したため、対象がありません"
        }

        if runCount == 0 {
            return "OCR対象を確認しています"
        }

        if let blockingReason = deviceSafety.blockingReason(for: executionPlan.workloadClass) {
            return blockingReason
        }

        return nil
    }

    private var canStart: Bool {
        startDisabledReason == nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(noticeTitle, systemImage: "text.viewfinder")
                            .font(.title3.bold())
                            .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))

                        Text("\(targetTitle)の候補から、今回は最大\(runCount)件だけ処理します。この画面では全数OCRは開始しません。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Label("OCRする件数", systemImage: "number.circle")
                            .font(.headline)

                        if eligibleCount <= QuickOCRLimit.twenty.rawValue {
                            Text("未処理の\(eligibleCount)件をOCRします")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
                        } else {
                            VStack(spacing: 8) {
                                ForEach(QuickOCRLimit.allCases) { limit in
                                    Button {
                                        selectedLimit = limit
                                    } label: {
                                        HStack {
                                            Image(systemName: selectedLimit == limit ? "largecircle.fill.circle" : "circle")
                                                .frame(width: 20)
                                            Text("現在の絞り込み結果から\(limit.title)")
                                                .font(.callout.weight(.medium))
                                            Spacer()
                                        }
                                        .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))
                                        .padding(10)
                                        .background(.white.opacity(selectedLimit == limit ? 0.92 : 0.72), in: RoundedRectangle(cornerRadius: 8))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        Label("OCR済みと処理中の写真は除外します", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 6) {
                            OCRBatchCountRow(title: "候補", value: "\(candidateCount)件")
                            OCRBatchCountRow(title: "OCR済み/処理中を除外後", value: "\(eligibleCount)件")
                            OCRBatchCountRow(title: "今回処理", value: "\(runCount)件")
                        }
                        .padding(10)
                        .background(.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))

                        if let startDisabledReason {
                            Label(startDisabledReason, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color(red: 0.75, green: 0.24, blue: 0.18))
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(red: 1.0, green: 0.94, blue: 0.90), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding(14)
                    .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 10) {
                        SafetyBullet("OCRは端末内で実行されます")
                        SafetyBullet("写真は外部送信しません")
                        SafetyBullet("処理中は発熱やバッテリー消費が増える場合があります")
                        SafetyBullet("iCloud上の写真は取得に時間がかかる場合があります")
                        SafetyBullet("途中でキャンセルしても、完了済みのOCR結果は保存されます")

                        if iCloudMode == .allowDownload {
                            SafetyBullet("iCloud取得ONのため通信量が増える場合があります")
                        }
                    }
                    .padding(14)
                    .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 10) {
                        Label("端末状態", systemImage: "iphone.gen3")
                            .font(.headline)

                        ForEach(deviceSafety.notices) { notice in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: icon(for: notice.level))
                                    .frame(width: 18)
                                    .foregroundStyle(color(for: notice.level))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(notice.title)
                                        .font(.caption.weight(.semibold))
                                    Text(notice.message)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(14)
                    .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(18)
            }
            .navigationTitle("OCR確認")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("戻る") {
                        onCancel()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("開始") {
                        onStart()
                    }
                    .disabled(canStart == false)
                }
            }
            .onAppear {
                deviceSafety.refresh()
            }
        }
    }

    private func icon(for level: SafetyLevel) -> String {
        switch level {
        case .normal:
            "checkmark.circle.fill"
        case .warning:
            "exclamationmark.triangle.fill"
        case .blocking:
            "xmark.octagon.fill"
        }
    }

    private func color(for level: SafetyLevel) -> Color {
        switch level {
        case .normal:
            Color(red: 0.14, green: 0.55, blue: 0.32)
        case .warning:
            Color(red: 0.75, green: 0.50, blue: 0.12)
        case .blocking:
            Color(red: 0.75, green: 0.24, blue: 0.18)
        }
    }
}

private struct OCRBatchCountRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Spacer(minLength: 8)

            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }
}

private struct SafetyBullet: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Color(red: 0.16, green: 0.42, blue: 0.75))
                .frame(width: 16)

            Text(text)
                .font(.caption)
                .foregroundStyle(Color(red: 0.09, green: 0.18, blue: 0.30))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct CompactFullOCRProgressView: View {
    @ObservedObject var progressStore: OCRProgressStore
    let onShowDetails: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onCancel: () -> Void
    let onRetryFailures: () -> Void
    let onResumeCloudPending: () -> Void

    var body: some View {
        if let snapshot = progressStore.activeSnapshot {
            progressContent(snapshot)
        }
    }

    private func progressContent(_ snapshot: OCRProgressSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(title(for: snapshot), systemImage: icon(for: snapshot.state))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(titleColor(for: snapshot))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                Spacer(minLength: 0)

                Button(action: onShowDetails) {
                    Text("詳細")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            ProgressView(value: snapshot.fractionCompleted)
                .tint(Color(red: 0.16, green: 0.42, blue: 0.75))

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(snapshot.completed) / \(snapshot.total)件")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))
                Text(snapshot.percentText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)

                Text(speedSummary(snapshot))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                Text("文字あり \(snapshot.textFound)件・文字なし \(snapshot.noText)件・失敗 \(snapshot.failed)件")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 0)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("現在: \(snapshot.phaseTitle)", systemImage: "waveform.path.ecg")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 0)

                Label(snapshot.heartbeatStatusText, systemImage: heartbeatIcon(for: snapshot.heartbeatAge))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(snapshot.heartbeatAge > 30 ? Color(red: 0.75, green: 0.24, blue: 0.18) : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            if snapshot.heartbeatAge > 30 {
                Text("完了済みの結果は保存されています。処理を再接続するか、いったん停止できます。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(statusDetail(for: snapshot))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                switch snapshot.state {
                case .running, .throttled:
                    Button("一時停止", role: .cancel, action: onPause)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                case .preparing, .pausedThermal, .pausedUser, .failed:
                    Button(snapshot.state == .failed ? "再開" : "再開を試す", action: onResume)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                case .cancelling, .completed:
                    EmptyView()
                }

                Button("このまま終了", role: .destructive, action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(snapshot.state == .completed || snapshot.state == .cancelling)

                if snapshot.failed > 0 && snapshot.state != .running && snapshot.state != .throttled {
                    Button("失敗分を再試行", action: onRetryFailures)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }

                if snapshot.cloudPending > 0 && snapshot.state != .running && snapshot.state != .throttled {
                    Button("iCloud取得を許可して再開", action: onResumeCloudPending)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }

                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
    }

    private func title(for snapshot: OCRProgressSnapshot) -> String {
        switch snapshot.state {
        case .preparing:
            "全数OCRを準備中"
        case .running:
            "全数OCR 実行中"
        case .throttled:
            "温度を見ながらゆっくり処理中"
        case .pausedThermal:
            "端末を冷ますため一時停止中"
        case .pausedUser:
            "全数OCRは一時停止中"
        case .cancelling:
            "全数OCRを終了しています"
        case .completed:
            "全数OCRが完了しました"
        case .failed:
            "全数OCRを継続できませんでした"
        }
    }

    private func titleColor(for snapshot: OCRProgressSnapshot) -> Color {
        switch snapshot.state {
        case .pausedThermal, .failed:
            Color(red: 0.75, green: 0.24, blue: 0.18)
        case .throttled:
            Color(red: 0.75, green: 0.37, blue: 0.08)
        default:
            Color(red: 0.07, green: 0.18, blue: 0.31)
        }
    }

    private func statusDetail(for snapshot: OCRProgressSnapshot) -> String {
        switch snapshot.state {
        case .preparing:
            "対象写真を確認しています。元写真・元動画は削除・変更しません。"
        case .running:
            "OCR結果は端末内で扱います。まとめてOCRは全数OCRの完了まで待機します。"
        case .throttled:
            "端末の状態に合わせてペースを落としています。"
        case .pausedThermal:
            "完了済みの\(snapshot.completed)件は保存されています。端末が冷めたら続きから再開できます。"
        case .pausedUser:
            "続きから再開できます。完了済みのOCR結果は保存されています。"
        case .cancelling:
            "未処理分だけを止めています。完了済みのOCR結果は残ります。"
        case .completed:
            "OCR結果を確認できます。元写真・元動画は削除・変更していません。"
        case .failed:
            snapshot.pausedReason ?? "詳細から状態を確認し、必要なら再開できます。"
        }
    }

    private func icon(for state: OCRProgressSnapshot.State) -> String {
        switch state {
        case .preparing:
            "clock.arrow.circlepath"
        case .running:
            "text.viewfinder"
        case .throttled:
            "tortoise.fill"
        case .pausedThermal:
            "thermometer.medium"
        case .pausedUser:
            "pause.circle"
        case .cancelling:
            "stop.circle"
        case .completed:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }

    private func heartbeatIcon(for age: TimeInterval) -> String {
        age > 30 ? "exclamationmark.triangle.fill" : "dot.radiowaves.left.and.right"
    }

    private func speedSummary(_ snapshot: OCRProgressSnapshot) -> String {
        let speed = speedText(snapshot.itemsPerMinute)
        let remaining = remainingText(snapshot.estimatedRemainingSeconds)
        return "\(speed)・残り\(remaining)"
    }

    private func speedText(_ itemsPerMinute: Double?) -> String {
        guard let itemsPerMinute else {
            return "計測中"
        }
        return String(format: "%.1f件/分", itemsPerMinute)
    }

    private func remainingText(_ seconds: TimeInterval?) -> String {
        guard let seconds else {
            return "計測中"
        }
        if seconds < 60 {
            return "\(Int(seconds.rounded()))秒"
        }
        if seconds < 3600 {
            return "\(Int((seconds / 60).rounded()))分"
        }
        return "\(Int((seconds / 3600).rounded()))時間"
    }
}

#if DEBUG
private struct OCRProgressDebugView: View {
    @ObservedObject var progressStore: OCRProgressStore
    let activeJob: OCRJob?
    let isRunning: Bool
    let isPreparing: Bool

    var body: some View {
        let snapshot = progressStore.activeSnapshot
        Text("OCR debug: store: \(progressStore.debugIdentifier) / activeSnapshot: \(snapshot == nil ? "nil" : "present") / activeJob: \(activeJob == nil ? "none" : "true") / jobState: \(activeJob?.state.rawValue ?? "none") / observer: \(observerState) / lastHeartbeat: \(heartbeatText(snapshot))")
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .minimumScaleFactor(0.72)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
            .onAppear {
                logPhotoTab(snapshot)
            }
            .onChange(of: snapshot) { _, newValue in
                logPhotoTab(newValue)
            }
    }

    private var observerState: String {
        if isRunning {
            return "running"
        }
        if isPreparing {
            return "preparing"
        }
        return "idle"
    }

    private func heartbeatText(_ snapshot: OCRProgressSnapshot?) -> String {
        guard let snapshot else {
            return "-"
        }
        return String(format: "%.1fs", snapshot.heartbeatAge)
    }

    private func logPhotoTab(_ snapshot: OCRProgressSnapshot?) {
        let state = snapshot?.state.rawValue ?? "none"
        print("OCR_PHOTO_TAB store=\(progressStore.debugIdentifier) activeSnapshot=\(snapshot != nil) state=\(state) activeJob=\(activeJob != nil) observer=\(observerState)")
    }
}
#endif

private struct OCRJobMetric: View {
    let title: String
    let value: Int
    var suffix: String = "件"

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("\(value)\(suffix)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OCRJobTextMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(value)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SearchMatchSummaryView: View {
    let match: PhotoSearchMatch
    let status: OCRStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if match.matchedFields.isEmpty {
                Text(status == .unprocessed ? "OCRすると文字検索しやすくなります" : "一致情報を確認中")
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
        case .completedNoText, .skipped:
            Color(red: 0.36, green: 0.42, blue: 0.48)
        case .cloudPending:
            Color(red: 0.16, green: 0.42, blue: 0.75)
        case .failed:
            Color(red: 0.75, green: 0.24, blue: 0.18)
        }
    }
}
