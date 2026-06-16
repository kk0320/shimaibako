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
    let mode: PhotoGridMode

    @State private var searchText: String
    @State private var selectedFilter: PhotoFilter = .all
    @State private var debugPresentedAsset: PhotoAsset?
    @State private var didPresentDebugAsset = false
    @State private var isRunningBulkOCR = false
    @State private var bulkTotal = 0
    @State private var bulkCompleted = 0
    @State private var bulkFailed = 0

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    init(photoLibrary: PhotoLibraryService, ocrService: OCRService, mode: PhotoGridMode) {
        self.photoLibrary = photoLibrary
        self.ocrService = ocrService
        self.mode = mode
        _searchText = State(initialValue: mode == .search ? Self.debugInitialSearchText : "")
    }

    private var filteredAssets: [PhotoAsset] {
        photoLibrary.assets.filter { asset in
            selectedFilter.includes(asset) && asset.matches(searchText, ocrText: ocrService.searchText(for: asset))
        }
    }

    private var bulkCandidates: [PhotoAsset] {
        Array(filteredAssets.filter { asset in
            asset.mediaType == .image &&
            ocrService.status(for: asset) != .completed &&
            ocrService.status(for: asset) != .processing
        }.prefix(20))
    }

    private var bulkProcessingCount: Int {
        isRunningBulkOCR ? max(bulkTotal - bulkCompleted - bulkFailed, 0) : 0
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                VStack(spacing: 12) {
                    statusHeader
                    filterPicker
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
                PhotoDetailView(photoLibrary: photoLibrary, ocrService: ocrService, asset: asset)
            }
            .sheet(item: $debugPresentedAsset) { asset in
                NavigationStack {
                    PhotoDetailView(
                        photoLibrary: photoLibrary,
                        ocrService: ocrService,
                        asset: asset,
                        automaticallyRunOCR: shouldRunOCRForDebug
                    )
                }
            }
            .task {
                if photoLibrary.canReadPhotos && photoLibrary.assets.isEmpty {
                    await photoLibrary.loadRecentAssets()
                }

                presentDebugAssetIfNeeded()
            }
            .onChange(of: photoLibrary.assets) {
                presentDebugAssetIfNeeded()
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

                Text("写真は外部送信しません。最大100件を読み取り専用で表示します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()
        }
        .padding(12)
        .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
    }

    private var filterPicker: some View {
        Picker("表示", selection: $selectedFilter) {
            ForEach(PhotoFilter.allCases) { filter in
                Text(filter.title).tag(filter)
            }
        }
        .pickerStyle(.segmented)
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

                    Text(bulkCandidates.isEmpty ? "未処理の表示写真はありません" : "表示中の写真を最大20件まで読み取ります")
                        .font(.caption)
                        .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Button {
                    Task {
                        await runBulkOCR()
                    }
                } label: {
                    Label("まとめてOCR", systemImage: "text.viewfinder")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isRunningBulkOCR || bulkCandidates.isEmpty)
            }

            if isRunningBulkOCR || bulkTotal > 0 {
                HStack(spacing: 10) {
                    Label("処理中 \(bulkProcessingCount)", systemImage: "hourglass")
                    Label("完了 \(bulkCompleted)", systemImage: "checkmark.circle")
                    Label("失敗 \(bulkFailed)", systemImage: "exclamationmark.triangle")
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            }
        }
        .padding(12)
        .background(.white.opacity(0.76), in: RoundedRectangle(cornerRadius: 8))
    }

    private func runBulkOCR() async {
        let targets = bulkCandidates
        guard targets.isEmpty == false else {
            return
        }

        isRunningBulkOCR = true
        bulkTotal = targets.count
        bulkCompleted = 0
        bulkFailed = 0

        for asset in targets {
            guard Task.isCancelled == false else {
                break
            }

            guard let image = await photoLibrary.requestDisplayImage(for: asset) else {
                await ocrService.markFailure(asset: asset, message: "画像を読み込めませんでした。")
                bulkFailed += 1
                continue
            }

            let result = await ocrService.recognize(asset: asset, image: image)
            if result?.ocrStatus == .completed {
                bulkCompleted += 1
            } else {
                bulkFailed += 1
            }
        }

        isRunningBulkOCR = false
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

        return Label(status.shortTitle, systemImage: status.systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(statusColor(status).opacity(0.82), in: Capsule())
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
