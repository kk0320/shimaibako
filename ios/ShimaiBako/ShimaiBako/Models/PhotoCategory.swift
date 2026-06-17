import Foundation
import Photos

enum PhotoCategory: String, CaseIterable, Identifiable, Codable {
    case all
    case uncategorized
    case screenshots
    case documentCandidate
    case receiptCandidate
    case businessCardCandidate
    case signboardCandidate
    case whiteboardCandidate
    case constructionCandidate
    case travelCandidate
    case flowerPlantCandidate
    case seasonalNatureCandidate
    case buildingCityCandidate
    case shrineTempleHistoricCandidate
    case artExhibitionCandidate
    case foodCandidate
    case petAnimalCandidate
    case peopleCandidate
    case videos
    case other

    var id: String {
        rawValue
    }

    nonisolated var title: String {
        switch self {
        case .all:
            "すべて"
        case .uncategorized:
            "未分類"
        case .screenshots:
            "スクショ"
        case .documentCandidate:
            "書類写真候補"
        case .receiptCandidate:
            "領収書候補"
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
        case .flowerPlantCandidate:
            "花・植物候補"
        case .seasonalNatureCandidate:
            "桜・紅葉候補"
        case .buildingCityCandidate:
            "建物・街並み候補"
        case .shrineTempleHistoricCandidate:
            "神社・寺・史跡候補"
        case .artExhibitionCandidate:
            "芸術品・展示候補"
        case .foodCandidate:
            "食べ物候補"
        case .petAnimalCandidate:
            "ペット・動物候補"
        case .peopleCandidate:
            "人物写真候補"
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
        case .receiptCandidate:
            "領収"
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
        case .flowerPlantCandidate:
            "植物"
        case .seasonalNatureCandidate:
            "桜紅葉"
        case .buildingCityCandidate:
            "建物"
        case .shrineTempleHistoricCandidate:
            "神社寺"
        case .artExhibitionCandidate:
            "展示"
        case .foodCandidate:
            "食べ物"
        case .petAnimalCandidate:
            "動物"
        case .peopleCandidate:
            "人物"
        case .uncategorized:
            "未分類"
        default:
            title
        }
    }

    nonisolated var systemImage: String {
        switch self {
        case .all:
            "square.grid.2x2"
        case .uncategorized:
            "tray"
        case .screenshots:
            "iphone"
        case .documentCandidate:
            "doc.text"
        case .receiptCandidate:
            "receipt"
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
        case .flowerPlantCandidate:
            "leaf"
        case .seasonalNatureCandidate:
            "camera.macro"
        case .buildingCityCandidate:
            "building.2"
        case .shrineTempleHistoricCandidate:
            "building.columns"
        case .artExhibitionCandidate:
            "photo.artframe"
        case .foodCandidate:
            "fork.knife"
        case .petAnimalCandidate:
            "pawprint"
        case .peopleCandidate:
            "person.2"
        case .videos:
            "video"
        case .other:
            "archivebox"
        }
    }

    nonisolated var isPrimaryChip: Bool {
        switch self {
        case .all, .uncategorized, .screenshots, .documentCandidate, .receiptCandidate:
            true
        default:
            false
        }
    }
}

enum ScreenshotSubcategory: String, CaseIterable, Identifiable, Codable {
    case all
    case memoIdeaCandidate
    case webResearchCandidate
    case reservationTicketCandidate
    case mapLocationCandidate
    case shoppingReceiptCandidate
    case appSettingsErrorCandidate
    case chatSNSCandidate
    case workDocumentCandidate
    case otherScreenshot

    var id: String {
        rawValue
    }

    nonisolated var title: String {
        switch self {
        case .all:
            "すべてのスクショ"
        case .memoIdeaCandidate:
            "アイデア・メモ候補"
        case .webResearchCandidate:
            "Web記事・調べ物候補"
        case .reservationTicketCandidate:
            "予約・チケット候補"
        case .mapLocationCandidate:
            "地図・場所候補"
        case .shoppingReceiptCandidate:
            "買い物・領収候補"
        case .appSettingsErrorCandidate:
            "アプリ設定・エラー候補"
        case .chatSNSCandidate:
            "チャット・SNS候補"
        case .workDocumentCandidate:
            "仕事・資料候補"
        case .otherScreenshot:
            "その他スクショ"
        }
    }

    nonisolated var shortTitle: String {
        switch self {
        case .all:
            "すべて"
        case .memoIdeaCandidate:
            "メモ"
        case .webResearchCandidate:
            "調べ物"
        case .reservationTicketCandidate:
            "予約"
        case .mapLocationCandidate:
            "地図"
        case .shoppingReceiptCandidate:
            "買い物"
        case .appSettingsErrorCandidate:
            "設定"
        case .chatSNSCandidate:
            "SNS"
        case .workDocumentCandidate:
            "仕事"
        case .otherScreenshot:
            "その他"
        }
    }

    nonisolated var systemImage: String {
        switch self {
        case .all:
            "iphone"
        case .memoIdeaCandidate:
            "note.text"
        case .webResearchCandidate:
            "safari"
        case .reservationTicketCandidate:
            "ticket"
        case .mapLocationCandidate:
            "map"
        case .shoppingReceiptCandidate:
            "cart"
        case .appSettingsErrorCandidate:
            "gearshape"
        case .chatSNSCandidate:
            "message"
        case .workDocumentCandidate:
            "briefcase"
        case .otherScreenshot:
            "rectangle.on.rectangle"
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

struct ScreenshotSubcategoryInferenceResult: Codable, Equatable {
    let photoLocalIdentifier: String
    var subcategory: ScreenshotSubcategory
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
    var categoryReason: String?
    var categoryUpdatedAt: Date
    var screenshotSubcategory: ScreenshotSubcategory?
    var screenshotSubcategoryConfidence: Double?
    var screenshotSubcategoryReason: String?
    var screenshotSubcategoryUpdatedAt: Date?
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
        categoryReason: String?,
        categoryUpdatedAt: Date,
        screenshotSubcategory: ScreenshotSubcategory?,
        screenshotSubcategoryConfidence: Double?,
        screenshotSubcategoryReason: String?,
        screenshotSubcategoryUpdatedAt: Date?,
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
        self.categoryReason = categoryReason
        self.categoryUpdatedAt = categoryUpdatedAt
        self.screenshotSubcategory = screenshotSubcategory
        self.screenshotSubcategoryConfidence = screenshotSubcategoryConfidence
        self.screenshotSubcategoryReason = screenshotSubcategoryReason
        self.screenshotSubcategoryUpdatedAt = screenshotSubcategoryUpdatedAt
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
        case categoryReason
        case hasOCRText
        case categoryUpdatedAt
        case screenshotSubcategory
        case screenshotSubcategoryConfidence
        case screenshotSubcategoryReason
        case screenshotSubcategoryUpdatedAt
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
        inferredCategory = try container.decodeIfPresent(PhotoCategory.self, forKey: .inferredCategory) ?? .uncategorized
        categoryConfidence = try container.decodeIfPresent(Double.self, forKey: .categoryConfidence) ?? 0
        categoryReason = try container.decodeIfPresent(String.self, forKey: .categoryReason)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? now
        categoryUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .categoryUpdatedAt) ?? updatedAt
        screenshotSubcategory = try container.decodeIfPresent(ScreenshotSubcategory.self, forKey: .screenshotSubcategory)
        screenshotSubcategoryConfidence = try container.decodeIfPresent(Double.self, forKey: .screenshotSubcategoryConfidence)
        screenshotSubcategoryReason = try container.decodeIfPresent(String.self, forKey: .screenshotSubcategoryReason)
        screenshotSubcategoryUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .screenshotSubcategoryUpdatedAt)
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
        try container.encodeIfPresent(categoryReason, forKey: .categoryReason)
        try container.encode(hasOCRText, forKey: .hasOCRText)
        try container.encode(categoryUpdatedAt, forKey: .categoryUpdatedAt)
        try container.encodeIfPresent(screenshotSubcategory, forKey: .screenshotSubcategory)
        try container.encodeIfPresent(screenshotSubcategoryConfidence, forKey: .screenshotSubcategoryConfidence)
        try container.encodeIfPresent(screenshotSubcategoryReason, forKey: .screenshotSubcategoryReason)
        try container.encodeIfPresent(screenshotSubcategoryUpdatedAt, forKey: .screenshotSubcategoryUpdatedAt)
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
        let normalizedText = normalized(ocrText)

        if asset.mediaType == .video {
            return result(asset: asset, category: .videos, confidence: 0.95, reason: "メディア種別")
        }

        if asset.isScreenshot {
            return result(asset: asset, category: .screenshots, confidence: 0.90, reason: "PhotoKitスクリーンショット")
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

        if containsAny(normalizedText, keywords: ["契約", "申請", "見積", "納品", "書類", "資料", "報告書", "pdf"]) {
            return result(asset: asset, category: .documentCandidate, confidence: 0.78, reason: "OCRテキスト")
        }

        if containsAny(normalizedText, keywords: ["看板", "入口", "出口", "営業中", "案内", "注意", "駐車場"]) {
            return result(asset: asset, category: .signboardCandidate, confidence: 0.74, reason: "OCRテキスト")
        }

        if containsAny(normalizedText, keywords: ["旅行", "ホテル", "空港", "搭乗", "新幹線", "駅", "観光"]) {
            return result(asset: asset, category: .travelCandidate, confidence: 0.72, reason: "OCRテキスト")
        }

        if containsAny(normalizedText, keywords: ["神社", "寺", "史跡", "城", "文化財", "鳥居", "temple", "shrine", "historic"]) {
            return result(asset: asset, category: .shrineTempleHistoricCandidate, confidence: 0.48, reason: "OCR候補")
        }

        if containsAny(normalizedText, keywords: ["展示", "美術館", "博物館", "作品", "絵画", "彫刻", "gallery", "museum", "exhibition", "art"]) {
            return result(asset: asset, category: .artExhibitionCandidate, confidence: 0.46, reason: "OCR候補")
        }

        if containsAny(normalizedText, keywords: ["花", "植物", "庭", "公園", "flower", "plant", "garden"]) {
            return result(asset: asset, category: .flowerPlantCandidate, confidence: 0.42, reason: "OCR候補")
        }

        if containsAny(normalizedText, keywords: ["桜", "紅葉", "花見", "さくら", "もみじ", "cherry blossom", "autumn leaves"]) {
            return result(asset: asset, category: .seasonalNatureCandidate, confidence: 0.42, reason: "OCR候補")
        }

        if containsAny(normalizedText, keywords: ["ビル", "建物", "街", "通り", "駅前", "building", "city", "street"]) {
            return result(asset: asset, category: .buildingCityCandidate, confidence: 0.40, reason: "OCR候補")
        }

        if containsAny(normalizedText, keywords: ["料理", "食事", "ランチ", "カフェ", "レストラン", "food", "restaurant", "menu"]) {
            return result(asset: asset, category: .foodCandidate, confidence: 0.40, reason: "OCR候補")
        }

        if containsAny(normalizedText, keywords: ["犬", "猫", "ペット", "動物", "dog", "cat", "pet", "animal"]) {
            return result(asset: asset, category: .petAnimalCandidate, confidence: 0.40, reason: "OCR候補")
        }

        if containsAny(normalizedText, keywords: ["人物", "家族", "集合写真", "portrait", "profile", "selfie"]) {
            return result(asset: asset, category: .peopleCandidate, confidence: 0.38, reason: "OCR候補")
        }

        if asset.mediaType == .image && looksDocumentLike(asset) {
            return result(asset: asset, category: .documentCandidate, confidence: 0.36, reason: "縦横比")
        }

        return result(asset: asset, category: .uncategorized, confidence: 0.20, reason: "未判定")
    }

    nonisolated static func inferScreenshotSubcategory(
        asset: PhotoAsset,
        ocrText: String?
    ) -> ScreenshotSubcategoryInferenceResult? {
        guard asset.isScreenshot else {
            return nil
        }

        let normalizedText = normalized(ocrText)

        if containsAny(normalizedText, keywords: ["メモ", "todo", "やること", "アイデア", "note", "idea", "checklist"]) {
            return screenshotResult(asset: asset, subcategory: .memoIdeaCandidate, confidence: 0.78, reason: "OCRテキスト")
        }

        if containsAny(normalizedText, keywords: ["http", "https", "www", "検索", "記事", "ニュース", "safari", "wikipedia", "browser"]) {
            return screenshotResult(asset: asset, subcategory: .webResearchCandidate, confidence: 0.78, reason: "OCRテキスト")
        }

        if containsAny(normalizedText, keywords: ["予約", "チケット", "qr", "入場", "座席", "便", "ホテル", "confirmation", "ticket", "booking"]) {
            return screenshotResult(asset: asset, subcategory: .reservationTicketCandidate, confidence: 0.80, reason: "OCRテキスト")
        }

        if containsAny(normalizedText, keywords: ["地図", "経路", "徒歩", "駅", "住所", "map", "route", "station"]) {
            return screenshotResult(asset: asset, subcategory: .mapLocationCandidate, confidence: 0.78, reason: "OCRテキスト")
        }

        if containsAny(normalizedText, keywords: ["注文", "購入", "合計", "送料", "領収", "請求", "amazon", "楽天", "¥", "円", "order", "receipt"]) {
            return screenshotResult(asset: asset, subcategory: .shoppingReceiptCandidate, confidence: 0.82, reason: "OCRテキスト")
        }

        if containsAny(normalizedText, keywords: ["設定", "エラー", "ログイン", "パスワード", "通知", "権限", "error", "settings", "login"]) {
            return screenshotResult(asset: asset, subcategory: .appSettingsErrorCandidate, confidence: 0.76, reason: "OCRテキスト")
        }

        if containsAny(normalizedText, keywords: ["line", "メッセージ", "dm", "投稿", "コメント", "返信", "chat", "message", "post"]) {
            return screenshotResult(asset: asset, subcategory: .chatSNSCandidate, confidence: 0.76, reason: "OCRテキスト")
        }

        if containsAny(normalizedText, keywords: ["会議", "資料", "請求", "見積", "契約", "pdf", "excel", "powerpoint", "meeting", "document"]) {
            return screenshotResult(asset: asset, subcategory: .workDocumentCandidate, confidence: 0.76, reason: "OCRテキスト")
        }

        return screenshotResult(asset: asset, subcategory: .otherScreenshot, confidence: 0.30, reason: "該当語なし")
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

    private nonisolated static func screenshotResult(
        asset: PhotoAsset,
        subcategory: ScreenshotSubcategory,
        confidence: Double,
        reason: String
    ) -> ScreenshotSubcategoryInferenceResult {
        ScreenshotSubcategoryInferenceResult(
            photoLocalIdentifier: asset.localIdentifier,
            subcategory: subcategory,
            confidence: confidence,
            reason: reason,
            updatedAt: Date()
        )
    }

    private nonisolated static func normalized(_ text: String?) -> String {
        (text ?? "").lowercased()
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
