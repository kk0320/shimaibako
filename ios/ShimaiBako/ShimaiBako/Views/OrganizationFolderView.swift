import Photos
import SwiftUI
import UIKit

struct OrganizationFolderView: View {
    @ObservedObject var photoLibrary: PhotoLibraryService
    @ObservedObject var ocrService: OCRService
    @ObservedObject var indexService: PhotoIndexService
    @ObservedObject var learningService: ManualCategoryLearningService
    @ObservedObject var classificationService: PhotoClassificationService
    let folder: OrganizationVirtualFolder
    let onReadCandidateHandoff: (ReadCandidateSelection) -> Void

    @State private var loadedIdentifiers: [String] = []
    @State private var assetsByID: [String: PhotoAsset] = [:]
    @State private var totalCount = 0
    @State private var scanOffset = 0
    @State private var isLoading = false
    @State private var didLoadInitialPage = false
    @State private var hasMore = true

    private let pageSize = 100
    private let scanPageSize = 500
    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    private var libraryTotalCount: Int {
        max(
            indexService.indexedRecordCount,
            photoLibrary.totalAssetCount,
            photoLibrary.loadedAssetCount,
            classificationService.summary.totalCount
        )
    }

    private var loadedAssets: [PhotoAsset] {
        loadedIdentifiers.compactMap { assetsByID[$0] }
    }

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header

                    if loadedAssets.isEmpty && isLoading == false {
                        emptyCard
                    }

                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(loadedAssets) { asset in
                            NavigationLink {
                                PhotoDetailView(
                                    photoLibrary: photoLibrary,
                                    ocrService: ocrService,
                                    indexService: indexService,
                                    learningService: learningService,
                                    asset: asset
                                )
                            } label: {
                                OrganizationFolderThumbnailView(
                                    photoLibrary: photoLibrary,
                                    asset: asset
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding(.vertical, 16)
                    } else if hasMore {
                        Button {
                            Task {
                                await loadNextPage()
                            }
                        } label: {
                            Label("さらに表示", systemImage: "chevron.down.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    Text("この一覧はしまい箱内だけの仮想フォルダです。元写真・元動画は移動・変更しません。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 120)
            }
        }
        .navigationTitle(folder.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard didLoadInitialPage == false else {
                return
            }

            didLoadInitialPage = true
            await reload()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("整理 > \(folder.title)")
                .font(.title3.bold())
                .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))

            Text(folder.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Label("\(loadedAssets.count) / \(totalCount)件表示", systemImage: "photo.on.rectangle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(red: 0.16, green: 0.42, blue: 0.75))

                if folder == .unorganized {
                    Text("100件ずつ表示")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.white.opacity(0.72), in: Capsule())
                }
            }

            if folder == .readCandidates {
                VStack(alignment: .leading, spacing: 8) {
                    Text("スクショなど、文字検索に役立つ可能性が高い写真です。すでに読取済みの写真はこの候補から外れます。元写真・元動画は変更されません。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ReadCandidateFolderInfoRow(title: "候補", value: "\(totalCount)件")
                    ReadCandidateFolderInfoRow(title: "対象", value: "スクショなどの未読取候補")

                    Button {
                        onReadCandidateHandoff(
                            .organizationReadCandidates(candidateCount: totalCount)
                        )
                    } label: {
                        Label("読取タブで確認", systemImage: "text.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.top, 4)
            }
        }
        .padding(14)
        .background(.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.black.opacity(0.06))
        )
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("このフォルダにはまだ写真がありません", systemImage: "tray")
                .font(.headline)
            Text("軽量整理を更新すると、この仮想フォルダに写真が表示される場合があります。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.black.opacity(0.06))
        )
    }

    private func reload() async {
        loadedIdentifiers = []
        assetsByID = [:]
        scanOffset = 0
        hasMore = true
        if folder == .readCandidates {
            totalCount = await classificationService.liveReadCandidateCount(indexService: indexService)
        } else {
            totalCount = classificationService.organizationVirtualFolderCount(
                folder,
                libraryTotalCount: libraryTotalCount
            )
        }
        await loadNextPage()
    }

    private func loadNextPage() async {
        guard isLoading == false, hasMore else {
            return
        }

        isLoading = true
        defer { isLoading = false }

        let identifiers: [String]
        if folder == .unorganized {
            identifiers = await nextUnorganizedIdentifiers()
        } else if folder == .readCandidates {
            identifiers = await classificationService.liveReadCandidateIdentifierPage(
                indexService: indexService,
                limit: pageSize,
                offset: loadedIdentifiers.count
            )
            hasMore = loadedIdentifiers.count + identifiers.count < totalCount
        } else {
            identifiers = classificationService.organizationVirtualFolderIdentifierPage(
                folder,
                limit: pageSize,
                offset: loadedIdentifiers.count
            )
            hasMore = loadedIdentifiers.count + identifiers.count < totalCount
        }

        appendAssets(for: identifiers)
        if identifiers.isEmpty {
            hasMore = false
        }
    }

    private func nextUnorganizedIdentifiers() async -> [String] {
        var nextIdentifiers: [String] = []
        var localScanOffset = scanOffset

        while nextIdentifiers.count < pageSize {
            let page = await indexService.page(
                matching: PhotoIndexPageRequest(
                    query: "",
                    displayState: .active,
                    includeUnwantedWhenActive: false,
                    category: .all,
                    screenshotSubcategory: .all,
                    limit: scanPageSize,
                    offset: localScanOffset
                )
            )

            guard page.localIdentifiers.isEmpty == false else {
                break
            }

            localScanOffset += page.localIdentifiers.count
            let filtered = page.localIdentifiers.filter {
                classificationService.isIdentifierInVirtualFolder($0, folder: .unorganized)
            }
            nextIdentifiers.append(contentsOf: filtered.prefix(pageSize - nextIdentifiers.count))

            if localScanOffset >= page.totalCount {
                break
            }
        }

        if nextIdentifiers.isEmpty,
           localScanOffset == 0,
           photoLibrary.assets.isEmpty == false {
            let fallbackIdentifiers = photoLibrary.assets
                .map(\.localIdentifier)
                .filter { classificationService.isIdentifierInVirtualFolder($0, folder: .unorganized) }
            nextIdentifiers = Array(fallbackIdentifiers.prefix(pageSize))
            scanOffset = fallbackIdentifiers.count
            hasMore = false
            return nextIdentifiers
        }

        scanOffset = localScanOffset
        let indexedLimit = max(indexService.indexedRecordCount, loadedIdentifiers.count + nextIdentifiers.count)
        hasMore = loadedIdentifiers.count + nextIdentifiers.count < totalCount && scanOffset < indexedLimit
        return nextIdentifiers
    }

    private func appendAssets(for identifiers: [String]) {
        guard identifiers.isEmpty == false else {
            return
        }

        var seenIdentifiers = Set(loadedIdentifiers)
        let uniqueIdentifiers = identifiers.filter { seenIdentifiers.insert($0).inserted }
        let assets = photoLibrary.assets(for: uniqueIdentifiers)
        for asset in assets {
            assetsByID[asset.localIdentifier] = asset
        }
        loadedIdentifiers.append(contentsOf: assets.map(\.localIdentifier))
    }
}

private struct ReadCandidateFolderInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))
        }
    }
}

private struct OrganizationFolderThumbnailView: View {
    @ObservedObject var photoLibrary: PhotoLibraryService
    let asset: PhotoAsset
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

            Text(asset.kindLabel)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(.black.opacity(0.48), in: Capsule())
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
}
