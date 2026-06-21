import Foundation

enum PhotoClassificationAnalysisState: String, CaseIterable, Identifiable, Codable {
    case notAnalyzed
    case metadataOnly
    case autoClassified
    case manualClassified
    case needsReview
    case failed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notAnalyzed:
            "未解析"
        case .metadataOnly:
            "メタデータのみ"
        case .autoClassified:
            "自動分類済み"
        case .manualClassified:
            "手動分類済み"
        case .needsReview:
            "要確認"
        case .failed:
            "分類失敗"
        }
    }
}

enum ImageClassificationCategory: String, CaseIterable, Identifiable, Codable {
    case screenshot
    case readCandidate
    case needsReview
    case unorganized
    case receiptCandidate
    case businessCardCandidate
    case documentCandidate
    case signCandidate
    case whiteboardCandidate
    case drawingCandidate
    case buildingCandidate
    case constructionSiteCandidate
    case vehicleHeavyEquipmentCandidate
    case materialEquipmentCandidate
    case foodCandidate
    case landscapeCandidate
    case personCandidate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenshot:
            "スクショ"
        case .readCandidate:
            "読取候補"
        case .needsReview:
            "要確認"
        case .unorganized:
            "未整理"
        case .receiptCandidate:
            "レシート候補"
        case .businessCardCandidate:
            "名刺候補"
        case .documentCandidate:
            "書類候補"
        case .signCandidate:
            "看板候補"
        case .whiteboardCandidate:
            "白板候補"
        case .drawingCandidate:
            "図面候補"
        case .buildingCandidate:
            "建物候補"
        case .constructionSiteCandidate:
            "工事現場候補"
        case .vehicleHeavyEquipmentCandidate:
            "車両・重機候補"
        case .materialEquipmentCandidate:
            "資材・設備候補"
        case .foodCandidate:
            "食べ物候補"
        case .landscapeCandidate:
            "風景候補"
        case .personCandidate:
            "人物候補"
        }
    }

    var isPublicInitialCategory: Bool {
        switch self {
        case .screenshot, .readCandidate, .needsReview, .unorganized:
            true
        default:
            false
        }
    }
}

enum ClassificationConfidenceBand: String, CaseIterable, Identifiable, Codable {
    case unknown
    case low
    case medium
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unknown:
            "未評価"
        case .low:
            "低"
        case .medium:
            "中"
        case .high:
            "高"
        }
    }
}

struct PhotoClassification: Identifiable, Codable, Hashable {
    var id: String { assetIdentifier }

    let assetIdentifier: String
    var schemaVersion: Int
    var classifierVersion: String
    var analysisState: PhotoClassificationAnalysisState

    var autoPrimaryCategory: ImageClassificationCategory?
    var manualCategory: ImageClassificationCategory?
    var resolvedCategory: ImageClassificationCategory?

    var formatTags: [String]
    var contentTags: [String]

    var screenshotScore: Double
    var documentScore: Double
    var personScore: Double
    var ocrPriorityScore: Double
    var buildingScore: Double
    var constructionSiteScore: Double
    var signScore: Double
    var whiteboardScore: Double
    var drawingScore: Double
    var receiptScore: Double
    var businessCardScore: Double

    var confidenceBand: ClassificationConfidenceBand
    var scoreMargin: Double

    var isScreenshot: Bool
    var containsPerson: Bool
    var faceCount: Int

    var createdAt: Date
    var updatedAt: Date
    var manualUpdatedAt: Date?

    init(
        assetIdentifier: String,
        schemaVersion: Int = 1,
        classifierVersion: String = "p1-foundation",
        analysisState: PhotoClassificationAnalysisState = .notAnalyzed,
        autoPrimaryCategory: ImageClassificationCategory? = nil,
        manualCategory: ImageClassificationCategory? = nil,
        formatTags: [String] = [],
        contentTags: [String] = [],
        screenshotScore: Double = 0,
        documentScore: Double = 0,
        personScore: Double = 0,
        ocrPriorityScore: Double = 0,
        buildingScore: Double = 0,
        constructionSiteScore: Double = 0,
        signScore: Double = 0,
        whiteboardScore: Double = 0,
        drawingScore: Double = 0,
        receiptScore: Double = 0,
        businessCardScore: Double = 0,
        confidenceBand: ClassificationConfidenceBand = .unknown,
        scoreMargin: Double = 0,
        isScreenshot: Bool = false,
        containsPerson: Bool = false,
        faceCount: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        manualUpdatedAt: Date? = nil
    ) {
        self.assetIdentifier = assetIdentifier
        self.schemaVersion = schemaVersion
        self.classifierVersion = classifierVersion
        self.analysisState = analysisState
        self.autoPrimaryCategory = autoPrimaryCategory
        self.manualCategory = manualCategory
        self.resolvedCategory = manualCategory ?? autoPrimaryCategory
        self.formatTags = formatTags
        self.contentTags = contentTags
        self.screenshotScore = screenshotScore
        self.documentScore = documentScore
        self.personScore = personScore
        self.ocrPriorityScore = ocrPriorityScore
        self.buildingScore = buildingScore
        self.constructionSiteScore = constructionSiteScore
        self.signScore = signScore
        self.whiteboardScore = whiteboardScore
        self.drawingScore = drawingScore
        self.receiptScore = receiptScore
        self.businessCardScore = businessCardScore
        self.confidenceBand = confidenceBand
        self.scoreMargin = scoreMargin
        self.isScreenshot = isScreenshot
        self.containsPerson = containsPerson
        self.faceCount = faceCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.manualUpdatedAt = manualUpdatedAt
    }

    mutating func applyAutomaticCategory(_ category: ImageClassificationCategory?, updatedAt date: Date = Date()) {
        self.autoPrimaryCategory = category
        self.resolvedCategory = manualCategory ?? autoPrimaryCategory
        if manualCategory == nil {
            self.analysisState = category == nil ? .notAnalyzed : .autoClassified
        }
        self.updatedAt = date
    }

    mutating func applyManualCategory(_ category: ImageClassificationCategory?, updatedAt date: Date = Date()) {
        self.manualCategory = category
        self.manualUpdatedAt = date
        self.resolvedCategory = manualCategory ?? autoPrimaryCategory
        self.analysisState = category == nil ? analysisState : .manualClassified
        self.updatedAt = date
    }
}

struct PhotoClassificationSummary {
    let totalCount: Int
    let classifiedCount: Int
    let manualCount: Int
    let screenshotCount: Int
    let readCandidateCount: Int
    let needsReviewCount: Int
    let unorganizedCount: Int
}

struct PhotoClassificationUpdateSummary: Equatable {
    var processedCount: Int
    var totalCount: Int
    var screenshotCount: Int
    var readCandidateCount: Int
    var needsReviewCount: Int
    var unorganizedCount: Int
    var manualProtectedCount: Int

    static let empty = PhotoClassificationUpdateSummary(
        processedCount: 0,
        totalCount: 0,
        screenshotCount: 0,
        readCandidateCount: 0,
        needsReviewCount: 0,
        unorganizedCount: 0,
        manualProtectedCount: 0
    )
}

#if DEBUG
struct PhotoClassificationSelfTestReport: Equatable {
    var manualOverridesAutomatic: Bool
    var automaticUsedWhenManualMissing: Bool
    var metadataRefreshKeepsManual: Bool

    var passed: Bool {
        manualOverridesAutomatic && automaticUsedWhenManualMissing && metadataRefreshKeepsManual
    }

    var message: String {
        passed ? "手動分類優先セルフテスト PASS" : "手動分類優先セルフテストで確認が必要です"
    }
}
#endif
