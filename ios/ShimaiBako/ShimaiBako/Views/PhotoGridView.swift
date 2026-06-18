import Photos
import Foundation
import SwiftUI

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
    @ObservedObject var indexService: PhotoIndexService
    @ObservedObject var learningService: ManualCategoryLearningService
    @ObservedObject var deviceSafety: DeviceSafetyService
    let mode: PhotoGridMode
    @Environment(\.scenePhase) private var scenePhase

    @State private var searchText: String
    @State private var selectedDisplayState: PhotoDisplayState = .active
    @State private var includeUnwantedInSearch = false
    @State private var selectedCategory: PhotoCategory = .all
    @State private var selectedScreenshotSubcategory: ScreenshotSubcategory = .all
    @State private var selectedBulkTarget: OCRBatchTarget = .visible
    @State private var visibleAssetLimit = 200
    @State private var selectedBulkLimit = 20
    @State private var effectiveSearchText: String
    @State private var searchDebounceTask: Task<Void, Never>?
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
    @State private var showingBulkSafety = false
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

    private var filteredAssets: [PhotoAsset] {
        photoLibrary.assets.filter { asset in
            displayStateIncludes(asset) &&
            categoryIncludes(asset) &&
            screenshotSubcategoryIncludes(asset) &&
            indexService.matches(asset: asset, query: effectiveSearchText, ocrService: ocrService)
        }
    }

    private var visibleAssets: [PhotoAsset] {
        Array(filteredAssets.prefix(visibleAssetLimit))
    }

    private var displayScopedAssets: [PhotoAsset] {
        photoLibrary.assets.filter(displayStateIncludes)
    }

    private var categoryCounts: [PhotoCategory: Int] {
        indexService.counts(for: displayScopedAssets, ocrService: ocrService)
    }

    private var screenshotSubcategoryCounts: [ScreenshotSubcategory: Int] {
        let screenshotAssets = displayScopedAssets.filter { asset in
            indexService.category(for: asset, ocrService: ocrService) == .screenshots
        }

        return indexService.screenshotSubcategoryCounts(for: screenshotAssets, ocrService: ocrService)
    }

    private var displayStateCounts: [PhotoDisplayState: Int] {
        indexService.displayStateCounts(for: photoLibrary.assets, ocrService: ocrService)
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
            asset.mediaType == .image &&
            indexService.status(for: asset, ocrService: ocrService) != .completed &&
            indexService.status(for: asset, ocrService: ocrService) != .processing
        }.count
    }

    private var bulkCandidates: [PhotoAsset] {
        Array(bulkTargetAssets.filter { asset in
            asset.mediaType == .image &&
            indexService.status(for: asset, ocrService: ocrService) != .completed &&
            indexService.status(for: asset, ocrService: ocrService) != .processing
        }.prefix(selectedBulkLimit))
    }

    private var visibleOCRClearTargets: [PhotoAsset] {
        filteredAssets.filter { asset in
            guard asset.mediaType == .image else {
                return false
            }

            let status = indexService.status(for: asset, ocrService: ocrService)
            return status == .completed || status == .failed
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

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                VStack(spacing: 12) {
                    statusHeader
                    if photoLibrary.shouldShowImportProgress {
                        PhotoImportProgressCard(photoLibrary: photoLibrary)
                    }
                    displayStateChips
                    searchOptions
                    categoryChips
                    if selectedCategory == .screenshots {
                        screenshotSubcategoryChips
                    }
                    bulkOCRControls
                    content
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            .navigationTitle(mode.title)
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
                    targetTitle: selectedBulkTarget.title,
                    candidateCount: bulkTargetCandidateCount,
                    runCount: pendingBulkTargets.count,
                    iCloudMode: photoLibrary.iCloudMode,
                    deviceSafety: deviceSafety,
                    onCancel: {
                        pendingBulkTargets = []
                        showingBulkSafety = false
                    },
                    onStart: {
                        let targets = pendingBulkTargets
                        pendingBulkTargets = []
                        showingBulkSafety = false
                        startBulkOCR(with: targets)
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
                Text("表示中の写真について、しまい箱に保存されたOCR文字だけを削除します。元写真・元動画は削除・変更されません。")
            }
            .task {
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
                presentDebugAssetIfNeeded()
                startDebugBulkOCRIfNeeded()
            }
            .onChange(of: photoLibrary.assets) {
                resetVisiblePage()
                presentDebugAssetIfNeeded()
                startDebugBulkOCRIfNeeded()
            }
            .onChange(of: searchText) {
                scheduleSearchUpdate()
            }
            .onChange(of: selectedDisplayState) {
                resetVisiblePage()
            }
            .onChange(of: selectedCategory) {
                resetVisiblePage()
            }
            .onChange(of: selectedScreenshotSubcategory) {
                resetVisiblePage()
            }
            .onChange(of: photoLibrary.latestLoadedBatch) {
                let batch = photoLibrary.latestLoadedBatch
                guard batch.isEmpty == false else {
                    return
                }

                Task {
                    await indexService.rebuild(for: batch, ocrService: ocrService)
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase != .active, isRunningBulkOCR {
                    cancelBulkOCR(reason: "アプリがバックグラウンドへ移行したため停止しました。")
                }
            }
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
            return "\(stateTitle)から検索結果 \(filteredAssets.count)件。検索は端末内だけで実行します。"
        }

        return "\(stateTitle) \(filteredAssets.count)件。不要候補や非表示はしまい箱内の表示状態です。"
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(PhotoCategory.allCases) { category in
                    Button {
                        selectedCategory = category
                        if category != .screenshots {
                            selectedScreenshotSubcategory = .all
                        }
                    } label: {
                        Label(
                            "\(category.shortTitle) \(categoryCounts[category, default: 0])",
                            systemImage: category.systemImage
                        )
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(selectedCategory == category ? Color(red: 0.16, green: 0.42, blue: 0.75) : .secondary)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var screenshotSubcategoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ScreenshotSubcategory.allCases) { subcategory in
                    Button {
                        selectedScreenshotSubcategory = subcategory
                    } label: {
                        Label(
                            "\(subcategory.shortTitle) \(screenshotSubcategoryCounts[subcategory, default: 0])",
                            systemImage: subcategory.systemImage
                        )
                        .labelStyle(.titleAndIcon)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(selectedScreenshotSubcategory == subcategory ? Color(red: 0.25, green: 0.43, blue: 0.57) : .secondary)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var displayStateChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(PhotoDisplayState.allCases) { state in
                    Button {
                        selectedDisplayState = state
                    } label: {
                        Label(
                            "\(state.chipTitle) \(displayStateCounts[state, default: 0])",
                            systemImage: state.systemImage
                        )
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(selectedDisplayState == state ? Color(red: 0.16, green: 0.42, blue: 0.75) : .secondary)
                }
            }
            .padding(.vertical, 2)
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
        if photoLibrary.hasRecoverableImportState && filteredAssets.isEmpty {
            ImportRecoveryEmptyView(photoLibrary: photoLibrary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if photoLibrary.isLoading && filteredAssets.isEmpty {
            VStack(spacing: 14) {
                ProgressView("読み込み中")
                Text("元写真・元動画は削除・変更しません。進まない場合は中止して軽量モードで再読み込みできます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredAssets.isEmpty {
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

                    if visibleAssets.count < filteredAssets.count {
                        Button {
                            visibleAssetLimit += 200
                        } label: {
                            Label("さらに表示 \(min(visibleAssetLimit + 200, filteredAssets.count)) / \(filteredAssets.count)件", systemImage: "chevron.down.circle")
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
                resetVisiblePage()
            }
        }
    }

    private var bulkOCRControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("OCR")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(bulkCandidates.isEmpty ? "未処理の対象写真はありません" : "\(selectedBulkTarget.title)から最大\(selectedBulkLimit)件")
                        .font(.caption)
                        .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

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
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isRunningBulkOCR)
                .accessibilityLabel("OCR対象を選択")

                Menu {
                    ForEach([20, 50, 100], id: \.self) { limit in
                        Button {
                            selectedBulkLimit = limit
                        } label: {
                            Label("最大\(limit)件", systemImage: selectedBulkLimit == limit ? "checkmark" : "circle")
                        }
                    }
                } label: {
                    Image(systemName: "number.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isRunningBulkOCR)
                .accessibilityLabel("OCR件数を選択")

                if isRunningBulkOCR {
                    Button(role: .cancel) {
                        cancelBulkOCR()
                    } label: {
                        Label(bulkCancellationRequested ? "停止中" : "キャンセル", systemImage: "xmark.circle")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(bulkCancellationRequested)
                } else {
                    Button {
                        presentBulkSafety()
                    } label: {
                        Label("まとめてOCR", systemImage: "text.viewfinder")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(bulkCandidates.isEmpty)
                }
            }

            if isRunningBulkOCR || bulkTotal > 0 {
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
                .disabled(isRunningBulkOCR)

                Text("現在の検索・カテゴリで表示中の写真だけが対象です。元写真・元動画は削除・変更されません。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(.white.opacity(0.76), in: RoundedRectangle(cornerRadius: 8))
    }

    private func presentBulkSafety() {
        let targets = bulkCandidates
        guard targets.isEmpty == false,
              isRunningBulkOCR == false,
              bulkOCRTask == nil else {
            return
        }

        deviceSafety.refresh()
        pendingBulkTargets = targets
        showingBulkSafety = true
    }

    private func startBulkOCR(with targets: [PhotoAsset]) {
        guard targets.isEmpty == false,
              isRunningBulkOCR == false,
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

            if let blockingReason = deviceSafety.blockingReasonForLargeWork {
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
            if result?.ocrStatus == .completed {
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

private struct OCRBatchSafetyView: View {
    let targetTitle: String
    let candidateCount: Int
    let runCount: Int
    let iCloudMode: ICloudPhotoMode
    @ObservedObject var deviceSafety: DeviceSafetyService
    let onCancel: () -> Void
    let onStart: () -> Void

    private var noticeTitle: String {
        if candidateCount >= 100 {
            return "段階実行を強く推奨"
        }

        if candidateCount >= 21 {
            return "対象が多めです"
        }

        return "OCR開始前の確認"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(noticeTitle, systemImage: "text.viewfinder")
                            .font(.title3.bold())
                            .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))

                        Text("\(targetTitle)の候補\(candidateCount)件から、今回は最大\(runCount)件だけ処理します。全件OCRは行いません。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

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
                    .disabled(runCount == 0 || deviceSafety.blockingReasonForLargeWork != nil)
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

private struct PhotoThumbnailView: View {
    @ObservedObject var photoLibrary: PhotoLibraryService
    @ObservedObject var ocrService: OCRService
    let asset: PhotoAsset
    let displayState: PhotoDisplayState

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let image = photoLibrary.cachedThumbnail(for: asset) {
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
            photoLibrary.requestThumbnail(for: asset, targetSize: CGSize(width: 360, height: 360))
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
