import Foundation
import Photos

enum PhotoCategory: String, CaseIterable, Identifiable, Codable {
    case all
    case screenshots
    case receiptCandidate
    case documentCandidate
    case businessCardCandidate
    case signboardCandidate
    case whiteboardCandidate
    case constructionCandidate
    case travelCandidate
    case videos
    case other

    var id: String {
        rawValue
    }

    nonisolated var title: String {
        switch self {
        case .all:
            "すべて"
        case .screenshots:
            "スクショ"
        case .receiptCandidate:
            "領収書候補"
        case .documentCandidate:
            "書類写真候補"
        case .businessCardCandidate:
            "名刺候補"
        case .signboardCandidate:
            "看板候補"
        case .whiteboardCandidate:
            "ホワイトボード候補"
        case .constructionCandidate:
            "工事写真候補"
        case .travelCandidate:
            "旅行写真候補"
        case .videos:
            "動画"
        case .other:
            "その他"
        }
    }

    nonisolated var shortTitle: String {
        switch self {
        case .documentCandidate:
            "書類"
        case .businessCardCandidate:
            "名刺"
        case .signboardCandidate:
            "看板"
        case .whiteboardCandidate:
            "白板"
        case .constructionCandidate:
            "工事"
        case .travelCandidate:
            "旅行"
        default:
            title
        }
    }

    nonisolated var systemImage: String {
        switch self {
        case .all:
            "square.grid.2x2"
        case .screenshots:
            "iphone"
        case .receiptCandidate:
            "receipt"
        case .documentCandidate:
            "doc.text"
        case .businessCardCandidate:
            "person.text.rectangle"
        case .signboardCandidate:
            "signpost.right"
        case .whiteboardCandidate:
            "rectangle.and.pencil.and.ellipsis"
        case .constructionCandidate:
            "hammer"
        case .travelCandidate:
            "airplane"
        case .videos:
            "video"
        case .other:
            "tray"
        }
    }
}

struct CategoryInferenceResult: Codable, Equatable {
    let photoLocalIdentifier: String
    var category: PhotoCategory
    var confidence: Double
    var reason: String
    var updatedAt: Date
}

struct PhotoIndexRecord: Codable, Equatable, Identifiable {
    var id: String {
        localIdentifier
    }

    let localIdentifier: String
    var creationDate: Date?
    var mediaTypeRawValue: Int
    var mediaSubtypesRawValue: UInt
    var pixelWidth: Int
    var pixelHeight: Int
    var isScreenshot: Bool
    var ocrStatus: OCRStatus
    var ocrText: String
    var ocrLanguage: String?
    var ocrProcessedAt: Date?
    var ocrErrorMessage: String?
    var inferredCategory: PhotoCategory
    var categoryConfidence: Double
    var categoryUpdatedAt: Date
    var lastSeenAt: Date
    var updatedAt: Date

    var hasOCRText: Bool {
        ocrStatus == .completed && ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    init(
        localIdentifier: String,
        creationDate: Date?,
        mediaTypeRawValue: Int,
        mediaSubtypesRawValue: UInt,
        pixelWidth: Int,
        pixelHeight: Int,
        isScreenshot: Bool,
        ocrStatus: OCRStatus,
        ocrText: String,
        ocrLanguage: String?,
        ocrProcessedAt: Date?,
        ocrErrorMessage: String?,
        inferredCategory: PhotoCategory,
        categoryConfidence: Double,
        categoryUpdatedAt: Date,
        lastSeenAt: Date,
        updatedAt: Date
    ) {
        self.localIdentifier = localIdentifier
        self.creationDate = creationDate
        self.mediaTypeRawValue = mediaTypeRawValue
        self.mediaSubtypesRawValue = mediaSubtypesRawValue
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isScreenshot = isScreenshot
        self.ocrStatus = ocrStatus
        self.ocrText = ocrText
        self.ocrLanguage = ocrLanguage
        self.ocrProcessedAt = ocrProcessedAt
        self.ocrErrorMessage = ocrErrorMessage
        self.inferredCategory = inferredCategory
        self.categoryConfidence = categoryConfidence
        self.categoryUpdatedAt = categoryUpdatedAt
        self.lastSeenAt = lastSeenAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case localIdentifier
        case creationDate
        case mediaTypeRawValue
        case mediaSubtypesRawValue
        case pixelWidth
        case pixelHeight
        case isScreenshot
        case ocrStatus
        case ocrText
        case ocrLanguage
        case ocrProcessedAt
        case ocrErrorMessage
        case inferredCategory
        case categoryConfidence
        case hasOCRText
        case categoryUpdatedAt
        case lastSeenAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let now = Date()

        localIdentifier = try container.decode(String.self, forKey: .localIdentifier)
        creationDate = try container.decodeIfPresent(Date.self, forKey: .creationDate)
        mediaTypeRawValue = try container.decode(Int.self, forKey: .mediaTypeRawValue)
        mediaSubtypesRawValue = try container.decode(UInt.self, forKey: .mediaSubtypesRawValue)
        pixelWidth = try container.decode(Int.self, forKey: .pixelWidth)
        pixelHeight = try container.decode(Int.self, forKey: .pixelHeight)
        isScreenshot = try container.decode(Bool.self, forKey: .isScreenshot)
        ocrStatus = try container.decodeIfPresent(OCRStatus.self, forKey: .ocrStatus) ?? .unprocessed
        ocrText = try container.decodeIfPresent(String.self, forKey: .ocrText) ?? ""
        ocrLanguage = try container.decodeIfPresent(String.self, forKey: .ocrLanguage)
        ocrProcessedAt = try container.decodeIfPresent(Date.self, forKey: .ocrProcessedAt)
        ocrErrorMessage = try container.decodeIfPresent(String.self, forKey: .ocrErrorMessage)
        inferredCategory = try container.decodeIfPresent(PhotoCategory.self, forKey: .inferredCategory) ?? .other
        categoryConfidence = try container.decodeIfPresent(Double.self, forKey: .categoryConfidence) ?? 0
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? now
        categoryUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .categoryUpdatedAt) ?? updatedAt
        lastSeenAt = try container.decodeIfPresent(Date.self, forKey: .lastSeenAt) ?? updatedAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(localIdentifier, forKey: .localIdentifier)
        try container.encodeIfPresent(creationDate, forKey: .creationDate)
        try container.encode(mediaTypeRawValue, forKey: .mediaTypeRawValue)
        try container.encode(mediaSubtypesRawValue, forKey: .mediaSubtypesRawValue)
        try container.encode(pixelWidth, forKey: .pixelWidth)
        try container.encode(pixelHeight, forKey: .pixelHeight)
        try container.encode(isScreenshot, forKey: .isScreenshot)
        try container.encode(ocrStatus, forKey: .ocrStatus)
        try container.encode(ocrText, forKey: .ocrText)
        try container.encodeIfPresent(ocrLanguage, forKey: .ocrLanguage)
        try container.encodeIfPresent(ocrProcessedAt, forKey: .ocrProcessedAt)
        try container.encodeIfPresent(ocrErrorMessage, forKey: .ocrErrorMessage)
        try container.encode(inferredCategory, forKey: .inferredCategory)
        try container.encode(categoryConfidence, forKey: .categoryConfidence)
        try container.encode(hasOCRText, forKey: .hasOCRText)
        try container.encode(categoryUpdatedAt, forKey: .categoryUpdatedAt)
        try container.encode(lastSeenAt, forKey: .lastSeenAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

struct PhotoIndexSummary: Equatable {
    var indexedCount: Int
    var completedOCRCount: Int
    var failedOCRCount: Int
    var processingOCRCount: Int
    var unprocessedOCRCount: Int
    var categorizedCount: Int

    static let empty = PhotoIndexSummary(
        indexedCount: 0,
        completedOCRCount: 0,
        failedOCRCount: 0,
        processingOCRCount: 0,
        unprocessedOCRCount: 0,
        categorizedCount: 0
    )
}

enum CategoryInference {
    nonisolated static func infer(asset: PhotoAsset, ocrText: String?) -> CategoryInferenceResult {
        let normalizedText = (ocrText ?? "").lowercased()

        if asset.mediaType == .video {
            return result(asset: asset, category: .videos, confidence: 0.95, reason: "動画種別")
        }

        if containsAny(normalizedText, keywords: ["領収書", "レシート", "receipt", "合計", "税込", "請求額", "支払"]) {
            return result(asset: asset, category: .receiptCandidate, confidence: 0.88, reason: "OCRテキスト")
        }

        if containsAny(normalizedText, keywords: ["名刺", "tel", "電話", "email", "@", "会社", "代表", "部署"]) {
            return result(asset: asset, category: .businessCardCandidate, confidence: 0.82, reason: "OCRテキスト")
        }

        if containsAny(normalizedText, keywords: ["ホワイトボード", "議題", "todo", "課題", "会議", "打合せ"]) {
            return result(asset: asset, category: .whiteboardCandidate, confidence: 0.80, reason: "OCRテキスト")
        }

        if containsAny(normalizedText, keywords: ["工事", "施工", "現場", "点検", "配管", "建設", "修繕"]) {
            return result(asset: asset, category: .constructionCandidate, confidence: 0.80, reason: "OCRテキスト")
        }

        if containsAny(normalizedText, keywords: ["看板", "入口", "出口", "営業中", "案内", "注意", "駐車場"]) {
            return result(asset: asset, category: .signboardCandidate, confidence: 0.74, reason: "OCRテキスト")
        }

        if containsAny(normalizedText, keywords: ["旅行", "ホテル", "空港", "搭乗", "新幹線", "駅", "観光"]) {
            return result(asset: asset, category: .travelCandidate, confidence: 0.72, reason: "OCRテキスト")
        }

        if containsAny(normalizedText, keywords: ["契約", "申請", "見積", "納品", "書類", "資料", "報告書", "pdf"]) {
            return result(asset: asset, category: .documentCandidate, confidence: 0.78, reason: "OCRテキスト")
        }

        if asset.isScreenshot {
            return result(asset: asset, category: .screenshots, confidence: 0.72, reason: "スクリーンショット")
        }

        if asset.mediaType == .image && looksDocumentLike(asset) {
            return result(asset: asset, category: .documentCandidate, confidence: 0.36, reason: "縦横比")
        }

        return result(asset: asset, category: .other, confidence: 0.25, reason: "軽量分類")
    }

    private nonisolated static func result(
        asset: PhotoAsset,
        category: PhotoCategory,
        confidence: Double,
        reason: String
    ) -> CategoryInferenceResult {
        CategoryInferenceResult(
            photoLocalIdentifier: asset.localIdentifier,
            category: category,
            confidence: confidence,
            reason: reason,
            updatedAt: Date()
        )
    }

    private nonisolated static func containsAny(_ text: String, keywords: [String]) -> Bool {
        keywords.contains { text.localizedCaseInsensitiveContains($0) }
    }

    private nonisolated static func looksDocumentLike(_ asset: PhotoAsset) -> Bool {
        guard asset.pixelWidth > 0, asset.pixelHeight > 0 else {
            return false
        }

        let longSide = Double(max(asset.pixelWidth, asset.pixelHeight))
        let shortSide = Double(min(asset.pixelWidth, asset.pixelHeight))
        let ratio = longSide / shortSide

        return ratio > 1.25 && ratio < 1.65
    }
}
