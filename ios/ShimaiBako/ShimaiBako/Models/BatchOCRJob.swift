import Foundation

enum BatchOCRJobState: String, Codable, CaseIterable {
    case preparing
    case running
    case pausing
    case pausedBackground
    case pausedUser
    case cancelling
    case completed
    case failed

    var title: String {
        switch self {
        case .preparing:
            "準備中"
        case .running:
            "実行中"
        case .pausing:
            "一時停止準備中"
        case .pausedBackground:
            "一時停止中"
        case .pausedUser:
            "一時停止中"
        case .cancelling:
            "終了中"
        case .completed:
            "完了"
        case .failed:
            "失敗"
        }
    }

    var isActive: Bool {
        switch self {
        case .preparing, .running, .pausing, .cancelling:
            true
        case .pausedBackground, .pausedUser, .completed, .failed:
            false
        }
    }
}

enum BatchOCRItemState: String, Codable, CaseIterable {
    case pending
    case processing
    case completedText
    case completedNoText
    case failedRetryable
    case failedPermanent
    case skippedAlreadyOCRed

    var isTerminalForP1: Bool {
        switch self {
        case .pending, .processing, .failedRetryable:
            false
        case .completedText, .completedNoText, .failedPermanent, .skippedAlreadyOCRed:
            true
        }
    }
}

struct BatchOCRJob: Codable, Identifiable, Equatable {
    let id: String
    var state: BatchOCRJobState
    var requestedLimit: Int
    var plannedCount: Int
    var processedCount: Int
    var completedTextCount: Int
    var completedNoTextCount: Int
    var failedCount: Int
    var createdAt: Date
    var startedAt: Date?
    var updatedAt: Date
    var pausedReason: String?
    var filterSnapshot: String
    var recognitionProfileVersion: String

    var progress: Double {
        guard plannedCount > 0 else {
            return 0
        }

        return min(Double(processedCount) / Double(plannedCount), 1)
    }
}

struct BatchOCRItem: Codable, Identifiable, Equatable {
    var id: String {
        "\(jobID)-\(ordinal)"
    }

    let jobID: String
    let assetIdentifier: String
    let ordinal: Int
    var state: BatchOCRItemState
    var attemptCount: Int
    var sourceRevision: String
    var lastErrorCode: String?
    var updatedAt: Date
}

struct BatchOCRJobSnapshot: Codable, Equatable {
    var job: BatchOCRJob?
    var items: [BatchOCRItem]
}

struct BatchOCRTargetSelectionDiagnostics: Codable, Equatable {
    var selectedLimit: Int
    var candidateBeforeExclusion: Int
    var excludedAlreadyRead: Int
    var excludedCompletedNoText: Int
    var excludedInProgress: Int
    var excludedSearchDataOnly: Int
    var excludedStaleCache: Int
    var searchDataOnlyCandidateCount: Int
    var staleCacheCandidateCount: Int
    var failedRetryableCount: Int
    var failedPermanentCount: Int
    var finalTargetCount: Int
    var reasonIfZero: String?

    static let empty = BatchOCRTargetSelectionDiagnostics(
        selectedLimit: 0,
        candidateBeforeExclusion: 0,
        excludedAlreadyRead: 0,
        excludedCompletedNoText: 0,
        excludedInProgress: 0,
        excludedSearchDataOnly: 0,
        excludedStaleCache: 0,
        searchDataOnlyCandidateCount: 0,
        staleCacheCandidateCount: 0,
        failedRetryableCount: 0,
        failedPermanentCount: 0,
        finalTargetCount: 0,
        reasonIfZero: nil
    )
}

struct ReadStateRepairSummary: Codable, Equatable {
    var scannedCount: Int
    var repairedStaleCompletedCount: Int
    var repairedStaleProcessingCount: Int
    var preservedOCRResultCount: Int
    var preservedManualDataCount: Int
    var updatedIndexRecordCount: Int

    var message: String {
        "読取状態を再確認しました。OCR結果\(preservedOCRResultCount)件、手動分類など\(preservedManualDataCount)件は保持し、古い読取状態\(repairedStaleCompletedCount + repairedStaleProcessingCount)件を未読取扱いへ戻しました。"
    }
}

#if DEBUG
struct BatchOCRP1ValidationReport: Codable, Equatable {
    var startedAt: Date
    var finishedAt: Date
    var cases: [BatchOCRP1ValidationCaseResult]

    var passed: Bool {
        cases.allSatisfy(\.passed)
    }
}

struct BatchOCRP1ValidationCaseResult: Codable, Equatable, Identifiable {
    var id: String {
        name
    }

    var name: String
    var requestedLimit: Int
    var plannedCount: Int
    var processedCount: Int
    var completedTextCount: Int
    var completedNoTextCount: Int
    var failedCount: Int
    var ocrResultSaved: Bool
    var zeroJobCreated: Bool
    var passed: Bool
    var message: String
}

struct BatchOCRP2ValidationReport: Codable, Equatable {
    var startedAt: Date
    var finishedAt: Date
    var cases: [BatchOCRP2ValidationCaseResult]

    var passed: Bool {
        cases.allSatisfy(\.passed)
    }
}

struct BatchOCRP2ValidationCaseResult: Codable, Equatable, Identifiable {
    var id: String {
        name
    }

    var name: String
    var jobState: BatchOCRJobState?
    var plannedCount: Int
    var processedCount: Int
    var pendingCount: Int
    var processingCount: Int
    var completedTextCount: Int
    var completedNoTextCount: Int
    var failedCount: Int
    var passed: Bool
    var message: String
}

struct BatchOCRP3ValidationReport: Codable, Equatable {
    var startedAt: Date
    var finishedAt: Date
    var cases: [BatchOCRP3ValidationCaseResult]

    var passed: Bool {
        cases.allSatisfy(\.passed)
    }
}

struct BatchOCRP3ValidationCaseResult: Codable, Equatable, Identifiable {
    var id: String {
        name
    }

    var name: String
    var requestedLimit: Int
    var jobState: BatchOCRJobState?
    var plannedCount: Int
    var processedCount: Int
    var pendingCount: Int
    var processingCount: Int
    var completedTextCount: Int
    var completedNoTextCount: Int
    var failedCount: Int
    var passed: Bool
    var message: String
}

struct BatchOCRTargetSelectionValidationReport: Codable, Equatable {
    var startedAt: Date
    var finishedAt: Date
    var cases: [BatchOCRTargetSelectionValidationCaseResult]

    var passed: Bool {
        cases.allSatisfy(\.passed)
    }
}

struct BatchOCRTargetSelectionValidationCaseResult: Codable, Equatable, Identifiable {
    var id: String {
        name
    }

    var name: String
    var selectedLimit: Int
    var finalTargetCount: Int
    var searchDataOnlyCandidateCount: Int
    var staleCacheCandidateCount: Int
    var excludedAlreadyRead: Int
    var excludedCompletedNoText: Int
    var passed: Bool
    var message: String
}
#endif
