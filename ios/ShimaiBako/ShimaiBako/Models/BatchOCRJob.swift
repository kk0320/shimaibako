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
    var series: BatchOCRSeries?
}

enum BatchOCRSeriesState: String, Codable, CaseIterable {
    case idle
    case running
    case waitingForNextBatch
    case pausedDeviceCondition
    case pausedUser
    case completedNoMoreTargets
    case failed

    var title: String {
        switch self {
        case .idle:
            "待機中"
        case .running:
            "自動継続中"
        case .waitingForNextBatch:
            "次の2,000件を準備中"
        case .pausedDeviceCondition:
            "端末状態により一時停止中"
        case .pausedUser:
            "一時停止中"
        case .completedNoMoreTargets:
            "未読取候補なし"
        case .failed:
            "確認が必要"
        }
    }
}

struct BatchOCRSeries: Codable, Identifiable, Equatable {
    let id: String
    var state: BatchOCRSeriesState
    var autoContinueEnabled: Bool
    var batchLimit: Int
    var createdAt: Date
    var updatedAt: Date
    var lastJobID: String?
    var totalProcessedInSeries: Int
    var remainingEstimate: Int?
    var pausedReason: String?
}

struct BatchOCRTargetSelectionDiagnostics: Codable, Equatable {
    var selectedLimit: Int
    var photoDBTotalCount: Int
    var batchCandidateScanLimit: Int
    var batchCandidateSource: String
    var effectiveFetchLimit: Int
    var candidateBeforeExclusion: Int
    var candidateAfterPaging: Int
    var excludedAlreadyRead: Int
    var excludedCompletedNoText: Int
    var excludedInProgress: Int
    var excludedSearchDataOnly: Int
    var excludedFailedPermanent: Int
    var excludedStaleCache: Int
    var searchDataOnlyCandidateCount: Int
    var staleCacheCandidateCount: Int
    var failedRetryableCount: Int
    var failedPermanentCount: Int
    var staleInProgressRecovered: Int
    var activeRunningJobTargets: Int
    var pausedJobPendingTargets: Int
    var staleProcessingTargets: Int
    var orphanProcessingTargets: Int
    var finalTargetCount: Int
    var reasonIfZero: String?

    static let empty = BatchOCRTargetSelectionDiagnostics(
        selectedLimit: 0,
        photoDBTotalCount: 0,
        batchCandidateScanLimit: 0,
        batchCandidateSource: "",
        effectiveFetchLimit: 0,
        candidateBeforeExclusion: 0,
        candidateAfterPaging: 0,
        excludedAlreadyRead: 0,
        excludedCompletedNoText: 0,
        excludedInProgress: 0,
        excludedSearchDataOnly: 0,
        excludedFailedPermanent: 0,
        excludedStaleCache: 0,
        searchDataOnlyCandidateCount: 0,
        staleCacheCandidateCount: 0,
        failedRetryableCount: 0,
        failedPermanentCount: 0,
        staleInProgressRecovered: 0,
        activeRunningJobTargets: 0,
        pausedJobPendingTargets: 0,
        staleProcessingTargets: 0,
        orphanProcessingTargets: 0,
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

struct BatchOCRLimitDiagnostics: Codable, Equatable, Identifiable {
    var id: Int {
        selectedLimit
    }

    var selectedLimit: Int
    var targetCount: Int
    var diagnostics: BatchOCRTargetSelectionDiagnostics
}

struct BatchOCRReadStateDiagnosticsReport: Codable, Equatable {
    var generatedAt: Date
    var photoDatabaseCount: Int
    var searchDataCount: Int
    var readResultCacheCount: Int
    var ocrTextCount: Int
    var completedNoTextCount: Int
    var failedCount: Int
    var failedRetryableCount: Int
    var failedPermanentCount: Int
    var searchDataOnlyCount: Int
    var unreadCandidateCount: Int
    var activeJobTargetCount: Int
    var activeRunningJobTargets: Int
    var pausedJobPendingTargets: Int
    var staleProcessingTargets: Int
    var orphanProcessingTargets: Int
    var invalidOrStaleJobCount: Int
    var limitDiagnostics: [BatchOCRLimitDiagnostics]

    var textReport: String {
        var lines = [
            "読取状態診断",
            "作成日時: \(Self.format(generatedAt))",
            "写真DB: \(photoDatabaseCount)",
            "検索データ: \(searchDataCount)",
            "読取結果キャッシュ: \(readResultCacheCount)",
            "OCR本文あり: \(ocrTextCount)",
            "文字なし判定済み: \(completedNoTextCount)",
            "失敗: \(failedCount)",
            "failedRetryable: \(failedRetryableCount)",
            "failedPermanent: \(failedPermanentCount)",
            "検索データのみ: \(searchDataOnlyCount)",
            "未読取候補: \(unreadCandidateCount)",
            "処理中ジョブ対象: \(activeJobTargetCount)",
            "activeRunningJobTargets: \(activeRunningJobTargets)",
            "pausedJobPendingTargets: \(pausedJobPendingTargets)",
            "staleProcessingTargets: \(staleProcessingTargets)",
            "orphanProcessingTargets: \(orphanProcessingTargets)",
            "無効/古いジョブ: \(invalidOrStaleJobCount)"
        ]

        for limit in limitDiagnostics.sorted(by: { $0.selectedLimit < $1.selectedLimit }) {
            lines.append("")
            lines.append("\(limit.selectedLimit)件選択時の対象数: \(limit.targetCount)")
            lines.append("photoDBTotalCount: \(limit.diagnostics.photoDBTotalCount)")
            lines.append("batchCandidateSource: \(limit.diagnostics.batchCandidateSource)")
            lines.append("requestedLimit: \(limit.diagnostics.selectedLimit)")
            lines.append("effectiveFetchLimit: \(limit.diagnostics.effectiveFetchLimit)")
            lines.append("candidateBeforeExclusion: \(limit.diagnostics.candidateBeforeExclusion)")
            lines.append("candidateAfterPaging: \(limit.diagnostics.candidateAfterPaging)")
            lines.append("excludedAlreadyRead: \(limit.diagnostics.excludedAlreadyRead)")
            lines.append("excludedCompletedNoText: \(limit.diagnostics.excludedCompletedNoText)")
            lines.append("excludedInProgress: \(limit.diagnostics.excludedInProgress)")
            lines.append("excludedSearchDataOnly: \(limit.diagnostics.excludedSearchDataOnly)")
            lines.append("excludedFailedPermanent: \(limit.diagnostics.excludedFailedPermanent)")
            lines.append("failedRetryableCount: \(limit.diagnostics.failedRetryableCount)")
            lines.append("staleInProgressRecovered: \(limit.diagnostics.staleInProgressRecovered)")
            lines.append("activeRunningJobTargets: \(limit.diagnostics.activeRunningJobTargets)")
            lines.append("pausedJobPendingTargets: \(limit.diagnostics.pausedJobPendingTargets)")
            lines.append("staleProcessingTargets: \(limit.diagnostics.staleProcessingTargets)")
            lines.append("orphanProcessingTargets: \(limit.diagnostics.orphanProcessingTargets)")
            lines.append("finalTargetCount: \(limit.diagnostics.finalTargetCount)")
            lines.append("reasonIfZero: \(limit.diagnostics.reasonIfZero ?? "-")")
        }

        return lines.joined(separator: "\n")
    }

    private static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

struct BatchOCRAutoContinueValidationReport: Codable, Equatable {
    var startedAt: Date
    var finishedAt: Date
    var cases: [BatchOCRAutoContinueValidationCaseResult]

    var passed: Bool {
        cases.allSatisfy(\.passed)
    }
}

struct BatchOCRAutoContinueValidationCaseResult: Codable, Equatable, Identifiable {
    var id: String {
        name
    }

    var name: String
    var seriesState: BatchOCRSeriesState?
    var autoContinueEnabled: Bool
    var nextJobCreated: Bool
    var plannedCount: Int
    var passed: Bool
    var message: String
}
#endif
