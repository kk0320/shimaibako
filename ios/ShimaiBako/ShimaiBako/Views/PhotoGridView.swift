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
    @ObservedObject var deviceSafety: DeviceSafetyService
    let mode: PhotoGridMode
    @Environment(\.scenePhase) private var scenePhase

    @State private var searchText: String
    @State private var selectedCategory: PhotoCategory = .all
    @State private var selectedBulkTarget: OCRBatchTarget = .visible
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
        deviceSafety: DeviceSafetyService,
        mode: PhotoGridMode
    ) {
        self.photoLibrary = photoLibrary
        self.ocrService = ocrService
        self.indexService = indexService
        self.deviceSafety = deviceSafety
        self.mode = mode
        _searchText = State(initialValue: mode == .search ? Self.debugInitialSearchText : "")
    }

    private var filteredAssets: [PhotoAsset] {
        photoLibrary.assets.filter { asset in
            categoryIncludes(asset) && indexService.matches(asset: asset, query: searchText, ocrService: ocrService)
        }
    }

    private var categoryCounts: [PhotoCategory: Int] {
        indexService.counts(for: photoLibrary.assets, ocrService: ocrService)
    }

    private var bulkTargetAssets: [PhotoAsset] {
        switch selectedBulkTarget {
        case .visible:
            filteredAssets
        case .screenshots:
            photoLibrary.assets.filter { $0.isScreenshot }
        case .documentCandidates:
            photoLibrary.assets.filter {
                indexService.category(for: $0, ocrService: ocrService) == .documentCandidate
            }
        case .unprocessed:
            photoLibrary.assets
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
        }.prefix(OCRConfiguration.batchLimit))
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
                    categoryChips
                    bulkOCRControls
                    content
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            .navigationTitle(mode.title)
            .searchable(text: $searchText, prompt: "日付・種類・OCRで検索")
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
                    asset: asset
                )
            }
            .sheet(item: $debugPresentedAsset) { asset in
                NavigationStack {
                    PhotoDetailView(
                        photoLibrary: photoLibrary,
                        ocrService: ocrService,
                        indexService: indexService,
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
                Text("表示中の写真について、しまい箱に保存されたOCR文字だけを削除します。写真本体は削除・変更されません。")
            }
            .task {
                if photoLibrary.canReadPhotos && photoLibrary.assets.isEmpty {
                    await photoLibrary.loadRecentAssets()
                }

                await indexService.rebuild(for: photoLibrary.assets, ocrService: ocrService)
                presentDebugAssetIfNeeded()
                startDebugBulkOCRIfNeeded()
            }
            .onChange(of: photoLibrary.assets) {
                Task {
                    await indexService.rebuild(for: photoLibrary.assets, ocrService: ocrService)
                }

                presentDebugAssetIfNeeded()
                startDebugBulkOCRIfNeeded()
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
            }

            Spacer()
        }
        .padding(12)
        .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(PhotoCategory.allCases) { category in
                    Button {
                        selectedCategory = category
                    } label: {
                        Label(
                            "\(category.shortTitle) \(categoryCounts[category, default: 0])",
                            systemImage: category.systemImage
                        )
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(selectedCategory == category ? Color(red: 0.16, green: 0.42, blue: 0.75) : .secondary)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func categoryIncludes(_ asset: PhotoAsset) -> Bool {
        guard selectedCategory != .all else {
            return true
        }

        return indexService.category(for: asset, ocrService: ocrService) == selectedCategory
    }

    @ViewBuilder
    private var content: some View {
        if photoLibrary.isLoading {
            ProgressView("読み込み中")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredAssets.isEmpty {
            ContentUnavailableView(
                searchText.isEmpty ? "写真がありません" : "見つかりません",
                systemImage: searchText.isEmpty ? "photo.on.rectangle.angled" : "magnifyingglass",
                description: Text(searchText.isEmpty ? "許可された写真があるとここに表示されます。" : "検索条件を変えてください。")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(filteredAssets) { asset in
                        NavigationLink(value: asset) {
                            PhotoThumbnailView(photoLibrary: photoLibrary, ocrService: ocrService, asset: asset)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 24)
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

                    Text(bulkCandidates.isEmpty ? "未処理の対象写真はありません" : "\(selectedBulkTarget.title)から最大\(OCRConfiguration.batchLimit)件")
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

                Text("現在の検索・カテゴリで表示中の写真だけが対象です。写真本体は削除・変更されません。")
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

private struct PhotoThumbnailView: View {
    @ObservedObject var photoLibrary: PhotoLibraryService
    @ObservedObject var ocrService: OCRService
    let asset: PhotoAsset

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

            if asset.mediaType == .image {
                VStack {
                    HStack {
                        Spacer()
                        ocrBadge
                    }
                    Spacer()
                }
                .padding(6)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onAppear {
            photoLibrary.requestThumbnail(for: asset, targetSize: CGSize(width: 360, height: 360))
        }
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
