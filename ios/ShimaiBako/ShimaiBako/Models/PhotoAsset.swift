import Foundation
import Photos

struct PhotoAsset: Identifiable, Hashable {
    let id: String
    let localIdentifier: String
    let filename: String?
    let creationDate: Date?
    let mediaType: PHAssetMediaType
    let mediaSubtypes: PHAssetMediaSubtype
    let pixelWidth: Int
    let pixelHeight: Int
    let isFavorite: Bool
    let isScreenshot: Bool
    let asset: PHAsset

    init(asset: PHAsset, includeFilename: Bool = false) {
        self.id = asset.localIdentifier
        self.localIdentifier = asset.localIdentifier
        self.filename = includeFilename ? PHAssetResource.assetResources(for: asset).first?.originalFilename : nil
        self.creationDate = asset.creationDate
        self.mediaType = asset.mediaType
        self.mediaSubtypes = asset.mediaSubtypes
        self.pixelWidth = asset.pixelWidth
        self.pixelHeight = asset.pixelHeight
        self.isFavorite = asset.isFavorite
        self.isScreenshot = asset.mediaSubtypes.contains(.photoScreenshot)
        self.asset = asset
    }

    var kindLabel: String {
        switch mediaType {
        case .image:
            isScreenshot ? "スクリーンショット" : "写真"
        case .video:
            "動画"
        default:
            "その他"
        }
    }

    var dateLabel: String {
        guard let creationDate else {
            return "日付なし"
        }

        return DateFormatter.localizedString(
            from: creationDate,
            dateStyle: .medium,
            timeStyle: .short
        )
    }

    var sizeLabel: String {
        "\(pixelWidth) x \(pixelHeight)"
    }

    func matches(_ query: String, ocrText: String = "", categoryTitle: String = "") -> Bool {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedQuery.isEmpty == false else {
            return true
        }

        let haystack = [
            filename ?? "",
            kindLabel,
            dateLabel,
            sizeLabel,
            localIdentifier,
            isFavorite ? "お気に入り" : "",
            categoryTitle,
            ocrText
        ]
        .joined(separator: " ")

        return haystack.localizedCaseInsensitiveContains(normalizedQuery)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: PhotoAsset, rhs: PhotoAsset) -> Bool {
        lhs.id == rhs.id
    }
}

enum PhotoFilter: String, CaseIterable, Identifiable {
    case all
    case images
    case screenshots
    case videos

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .all:
            "すべて"
        case .images:
            "写真"
        case .screenshots:
            "スクショ"
        case .videos:
            "動画"
        }
    }

    func includes(_ asset: PhotoAsset) -> Bool {
        switch self {
        case .all:
            true
        case .images:
            asset.mediaType == .image && asset.isScreenshot == false
        case .screenshots:
            asset.isScreenshot
        case .videos:
            asset.mediaType == .video
        }
    }
}
