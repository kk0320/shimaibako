import Foundation

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
            "スマート全数OCR"
        case .fullAccurate:
            "全数高精度OCR"
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
            "スマート全数"
        case .fullAccurate:
            "高精度全数"
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
