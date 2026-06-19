import Foundation

enum QuickOCRLimit: Int, CaseIterable, Identifiable, Sendable, Equatable {
    case twenty = 20
    case fifty = 50
    case oneHundred = 100

    nonisolated var id: Int {
        rawValue
    }

    nonisolated var title: String {
        switch self {
        case .twenty:
            "最大20件"
        case .fifty:
            "最大50件"
        case .oneHundred:
            "最大100件"
        }
    }

    nonisolated var compactTitle: String {
        switch self {
        case .twenty:
            "20件"
        case .fifty:
            "50件"
        case .oneHundred:
            "100件"
        }
    }

    nonisolated var scope: OCRJobScope {
        switch self {
        case .twenty:
            .visibleLimit20
        case .fifty:
            .visibleLimit50
        case .oneHundred:
            .visibleLimit100
        }
    }
}

nonisolated struct FilterSnapshot: Sendable, Equatable {
    var query: String
    var displayState: PhotoDisplayState
    var includeUnwantedWhenActive: Bool
    var category: PhotoCategory
    var screenshotSubcategory: ScreenshotSubcategory

    func pageRequest(limit: Int, offset: Int = 0) -> PhotoIndexPageRequest {
        PhotoIndexPageRequest(
            query: query,
            displayState: displayState,
            includeUnwantedWhenActive: includeUnwantedWhenActive,
            category: category,
            screenshotSubcategory: screenshotSubcategory,
            limit: limit,
            offset: offset
        )
    }
}

nonisolated struct SmartOCROptions: Sendable, Equatable {
    var prioritizeTextLikeImages = true
    var allowICloudDownload = false
}

enum OCRWorkloadClass: Sendable, Equatable {
    case small
    case medium
    case large
    case longRunning
    case heavy
}

enum OCRExecutionPlan: Sendable, Equatable {
    case quick(filter: FilterSnapshot, limit: QuickOCRLimit)
    case filteredAll(filter: FilterSnapshot)
    case smartLibrary(libraryRevision: Int64, options: SmartOCROptions)
    case accuracyReview(sourceJobID: String?)

    nonisolated var title: String {
        switch self {
        case .quick(_, let limit):
            "表示中の候補からOCR（\(limit.compactTitle)）"
        case .filteredAll:
            "現在の絞り込み結果すべて"
        case .smartLibrary:
            "スマート全数OCR（推奨）"
        case .accuracyReview:
            "検索精度をさらに上げる"
        }
    }

    nonisolated var debugKind: String {
        switch self {
        case .quick:
            "quick"
        case .filteredAll:
            "filteredAll"
        case .smartLibrary:
            "smartLibrary"
        case .accuracyReview:
            "accuracyReview"
        }
    }

    nonisolated var workloadClass: OCRWorkloadClass {
        switch self {
        case .quick(_, let limit):
            limit.rawValue <= 20 ? .small : .medium
        case .filteredAll:
            .large
        case .smartLibrary:
            .longRunning
        case .accuracyReview:
            .heavy
        }
    }

    nonisolated var jobScope: OCRJobScope {
        switch self {
        case .quick(_, let limit):
            limit.scope
        case .filteredAll:
            .currentFilterAll
        case .smartLibrary:
            .smartFull
        case .accuracyReview:
            .fullAccurate
        }
    }

    nonisolated var qualityMode: OCRJobQualityMode {
        switch self {
        case .accuracyReview:
            .accurate
        case .quick, .filteredAll, .smartLibrary:
            .standard
        }
    }

    nonisolated var isQuick: Bool {
        if case .quick = self {
            return true
        }
        return false
    }
}

enum OCRJobScope: String, Codable, CaseIterable, Identifiable {
    case visibleLimit20
    case visibleLimit50
    case visibleLimit100
    case currentFilterAll
    case smartFull
    case fullAccurate

    nonisolated var id: String {
        rawValue
    }

    nonisolated var title: String {
        switch self {
        case .visibleLimit20:
            "表示中から最大20件"
        case .visibleLimit50:
            "表示中から最大50件"
        case .visibleLimit100:
            "表示中から最大100件"
        case .currentFilterAll:
            "現在の絞り込み結果すべて"
        case .smartFull:
            "スマート全数OCR（推奨）"
        case .fullAccurate:
            "全数高精度OCR（上級者向け）"
        }
    }

    nonisolated var compactTitle: String {
        switch self {
        case .visibleLimit20:
            "20件"
        case .visibleLimit50:
            "50件"
        case .visibleLimit100:
            "100件"
        case .currentFilterAll:
            "絞り込み全件"
        case .smartFull:
            "推奨全数"
        case .fullAccurate:
            "高精度全数"
        }
    }

    nonisolated var description: String {
        switch self {
        case .visibleLimit20, .visibleLimit50, .visibleLimit100:
            "表示中の候補を少しだけOCRします"
        case .currentFilterAll:
            "現在の検索・カテゴリで絞り込んだ写真を段階的にOCRします"
        case .smartFull:
            "スクショ・書類を優先し、端末状態に合わせて少しずつOCRします"
        case .fullAccurate:
            "非常に時間がかかり、発熱・バッテリー消費が大きくなります"
        }
    }

    nonisolated var isPersistentFullScope: Bool {
        switch self {
        case .visibleLimit20, .visibleLimit50, .visibleLimit100:
            false
        case .currentFilterAll, .smartFull, .fullAccurate:
            true
        }
    }

    nonisolated var quickLimit: Int? {
        switch self {
        case .visibleLimit20:
            20
        case .visibleLimit50:
            50
        case .visibleLimit100:
            100
        case .currentFilterAll, .smartFull, .fullAccurate:
            nil
        }
    }
}

enum OCRJobQualityMode: String, Codable {
    case standard
    case accurate

    nonisolated var title: String {
        switch self {
        case .standard:
            "標準"
        case .accurate:
            "高精度"
        }
    }
}

enum OCRJobState: String, Codable {
    case pending
    case running
    case paused
    case completed
    case cancelled
    case failed

    nonisolated var title: String {
        switch self {
        case .pending:
            "待機中"
        case .running:
            "OCR実行中"
        case .paused:
            "一時停止"
        case .completed:
            "完了"
        case .cancelled:
            "終了"
        case .failed:
            "失敗"
        }
    }

    nonisolated var isActive: Bool {
        self == .pending || self == .running || self == .paused
    }
}

enum OCRJobItemState: String, Codable {
    case pending
    case fetchingImage
    case recognizing
    case completedText
    case completedNoText
    case cloudPending
    case retryableFailure
    case permanentFailure
    case skipped
    case cancelled

    nonisolated var title: String {
        switch self {
        case .pending:
            "待機中"
        case .fetchingImage:
            "画像取得中"
        case .recognizing:
            "OCR中"
        case .completedText:
            "文字あり"
        case .completedNoText:
            "文字なし"
        case .cloudPending:
            "iCloud待ち"
        case .retryableFailure:
            "再試行待ち"
        case .permanentFailure:
            "失敗"
        case .skipped:
            "スキップ"
        case .cancelled:
            "終了"
        }
    }

    nonisolated var isTerminal: Bool {
        switch self {
        case .completedText, .completedNoText, .cloudPending, .permanentFailure, .skipped, .cancelled:
            true
        case .pending, .fetchingImage, .recognizing, .retryableFailure:
            false
        }
    }
}

struct OCRJob: Codable, Equatable, Identifiable {
    var id: String
    var scope: OCRJobScope
    var qualityMode: OCRJobQualityMode
    var state: OCRJobState
    var createdAt: Date
    var updatedAt: Date
    var totalCount: Int
    var completedCount: Int
    var textFoundCount: Int
    var noTextCount: Int
    var skippedCount: Int
    var cloudPendingCount: Int
    var failedCount: Int
    var pausedReason: String?

    nonisolated var processedCount: Int {
        completedCount + skippedCount + cloudPendingCount + failedCount
    }

    nonisolated var progress: Double {
        guard totalCount > 0 else {
            return 0
        }

        return min(Double(processedCount) / Double(totalCount), 1)
    }

    nonisolated var updatedAtLabel: String {
        DateFormatter.localizedString(from: updatedAt, dateStyle: .none, timeStyle: .short)
    }
}

struct OCRJobItem: Codable, Equatable, Identifiable {
    nonisolated var id: String {
        "\(jobID)|\(assetIdentifier)"
    }

    var jobID: String
    var assetIdentifier: String
    var priority: Int
    var state: OCRJobItemState
    var attemptCount: Int
    var nextRetryAt: Date?
    var sourceFingerprint: String
    var lastErrorCode: String?
    var startedAt: Date?
    var completedAt: Date?
}

struct PersistentOCRResult: Codable, Equatable, Identifiable {
    nonisolated var id: String {
        assetIdentifier
    }

    var assetIdentifier: String
    var rawText: String
    var normalizedText: String
    var resultState: OCRJobItemState
    var engineVersion: String
    var recognitionProfileVersion: String
    var sourceFingerprint: String
    var updatedAt: Date
}

struct OCRJobItemInput: Equatable {
    var assetIdentifier: String
    var priority: Int
    var sourceFingerprint: String
}

struct OCRJobSnapshot: Equatable {
    var job: OCRJob?
    var isRunning: Bool

    static let empty = OCRJobSnapshot(job: nil, isRunning: false)
}
