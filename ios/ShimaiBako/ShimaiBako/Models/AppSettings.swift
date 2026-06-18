import Foundation

enum PhotoReadMode: String, CaseIterable, Identifiable, Codable {
    case light
    case standard
    case expanded
    case large
    case full

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .light:
            "軽量"
        case .standard:
            "標準"
        case .expanded:
            "多め"
        case .large:
            "大量"
        case .full:
            "フル"
        }
    }

    var limit: Int? {
        switch self {
        case .light:
            100
        case .standard:
            500
        case .expanded:
            2_000
        case .large:
            10_000
        case .full:
            nil
        }
    }

    var limitTitle: String {
        if let limit {
            return "直近\(limit)件"
        }

        return "全件"
    }

    var description: String {
        switch self {
        case .light:
            "まず試すための最小読み込み"
        case .standard:
            "日常利用向けの標準読み込み"
        case .expanded:
            "多めに探したいときの読み込み"
        case .large:
            "端末状態を確認して使う大量読み込み"
        case .full:
            "全件を対象にする慎重運用モード"
        }
    }

    var isLargeScale: Bool {
        self == .large || self == .full
    }
}

enum PhotoImportPhase: String, Codable, Equatable {
    case idle
    case fetchingAssetList
    case indexing
    case preparingThumbnails
    case completed
    case cancelled
    case failed
    case stale
    case paused

    var title: String {
        switch self {
        case .idle:
            "待機中"
        case .fetchingAssetList:
            "写真一覧を取得中"
        case .indexing:
            "インデックス作成中"
        case .preparingThumbnails:
            "サムネイル準備中"
        case .completed:
            "完了"
        case .cancelled:
            "キャンセル"
        case .failed:
            "失敗"
        case .stale:
            "前回の読み込みが途中で停止"
        case .paused:
            "一時停止"
        }
    }

    var isActive: Bool {
        switch self {
        case .fetchingAssetList, .indexing, .preparingThumbnails:
            true
        case .idle, .completed, .cancelled, .failed, .stale, .paused:
            false
        }
    }
}

enum PhotoImportInterruptionReason: String, Codable, Equatable {
    case userCancelled
    case taskCancelled
    case pausedByViewLifecycle
    case pausedByAppLifecycle
    case pausedByMemoryPressure
    case staleJob

    var message: String {
        switch self {
        case .userCancelled:
            "ユーザー操作で中止しました"
        case .taskCancelled:
            "読み込みタスクが中断されました。続きから再開できます"
        case .pausedByViewLifecycle:
            "画面切替では読み込みを継続しています"
        case .pausedByAppLifecycle:
            "アプリの状態変化により一時停止しました"
        case .pausedByMemoryPressure:
            "端末の負荷が高いため一時停止しました"
        case .staleJob:
            "前回の読み込みが途中で止まりました"
        }
    }
}

struct PhotoImportProgress: Codable, Equatable {
    var phase: PhotoImportPhase
    var readMode: PhotoReadMode
    var loadedCount: Int
    var totalCount: Int
    var startedAt: Date?
    var updatedAt: Date?
    var finishedAt: Date?
    var message: String?
    var interruptionReason: PhotoImportInterruptionReason?
    var latestLoadedIdentifiers: [String]?
    var lastSuccessfulBatchEnd: Int?
    var lastPhase: String?
    var lastErrorSummary: String?
    var lastExitReasonCandidate: String?
    var batchStart: Int?
    var batchEnd: Int?
    var batchSize: Int?
    var elapsedMilliseconds: Int?
    var memoryWarningCount: Int?

    static let idle = PhotoImportProgress(
        phase: .idle,
        readMode: .light,
        loadedCount: 0,
        totalCount: 0,
        startedAt: nil,
        updatedAt: nil,
        finishedAt: nil,
        message: nil,
        interruptionReason: nil,
        latestLoadedIdentifiers: [],
        lastSuccessfulBatchEnd: nil,
        lastPhase: nil,
        lastErrorSummary: nil,
        lastExitReasonCandidate: nil,
        batchStart: nil,
        batchEnd: nil,
        batchSize: nil,
        elapsedMilliseconds: nil,
        memoryWarningCount: nil
    )

    var progressFraction: Double {
        guard totalCount > 0 else {
            return 0
        }

        return min(max(Double(loadedCount) / Double(totalCount), 0), 1)
    }

    var countTitle: String {
        if totalCount > 0 {
            return "\(loadedCount) / \(totalCount)件"
        }

        return "\(loadedCount)件"
    }

    var updatedAtTitle: String {
        guard let updatedAt else {
            return "-"
        }

        return DateFormatter.localizedString(from: updatedAt, dateStyle: .none, timeStyle: .medium)
    }

    var elapsedTitle: String {
        guard let startedAt else {
            return "-"
        }

        let end = finishedAt ?? Date()
        let seconds = max(Int(end.timeIntervalSince(startedAt)), 0)
        if seconds < 60 {
            return "\(seconds)秒"
        }

        return "\(seconds / 60)分\(seconds % 60)秒"
    }

    func isStale(referenceDate: Date = Date(), threshold: TimeInterval = 180) -> Bool {
        guard phase.isActive else {
            return false
        }

        let lastUpdate = updatedAt ?? startedAt ?? .distantPast
        return referenceDate.timeIntervalSince(lastUpdate) >= threshold
    }

    func markedStale(at date: Date = Date()) -> PhotoImportProgress {
        var progress = self
        progress.phase = .stale
        progress.finishedAt = date
        progress.updatedAt = date
        progress.message = PhotoImportInterruptionReason.staleJob.message
        progress.interruptionReason = .staleJob
        progress.lastExitReasonCandidate = PhotoImportInterruptionReason.staleJob.rawValue
        return progress
    }
}

enum ICloudPhotoMode: String, CaseIterable, Identifiable, Codable {
    case offlinePreferred
    case allowDownload

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .offlinePreferred:
            "オフライン優先"
        case .allowDownload:
            "iCloud取得を許可"
        }
    }

    var description: String {
        switch self {
        case .offlinePreferred:
            "端末内にある画像だけを優先し、iCloud取得をできるだけ避けます。"
        case .allowDownload:
            "OCR時に必要な画像をiCloud写真から取得できます。通信量に注意してください。"
        }
    }

    var allowsNetworkAccess: Bool {
        self == .allowDownload
    }
}

enum OCRBatchTarget: String, CaseIterable, Identifiable, Codable {
    case visible
    case screenshots
    case documentCandidates
    case unprocessed

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .visible:
            "表示中"
        case .screenshots:
            "スクショのみ"
        case .documentCandidates:
            "書類候補のみ"
        case .unprocessed:
            "未OCRのみ"
        }
    }

    var description: String {
        switch self {
        case .visible:
            "現在の検索・カテゴリ表示に含まれる写真を対象にします。"
        case .screenshots:
            "スクリーンショットだけを対象にします。"
        case .documentCandidates:
            "書類写真候補だけを対象にします。"
        case .unprocessed:
            "読み込み済み写真のうち未OCRの画像を対象にします。"
        }
    }
}

enum AccuracyImprovementSchedule: String, CaseIterable, Identifiable, Codable {
    case manualOnly
    case nightAttempt

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .manualOnly:
            "手動のみ"
        case .nightAttempt:
            "夜間に自動実行を試みる"
        }
    }

    var description: String {
        switch self {
        case .manualOnly:
            "ユーザーが押した時だけ少しずつ処理します。"
        case .nightAttempt:
            "iOSの判断に従って、夜間や充電中の実行を将来試みます。指定時刻に必ず動くものではありません。"
        }
    }
}

enum AccuracyImprovementRunState: Equatable {
    case idle
    case running
    case completed
    case interrupted
    case failed

    var title: String {
        switch self {
        case .idle:
            "待機中"
        case .running:
            "処理中"
        case .completed:
            "完了"
        case .interrupted:
            "中断"
        case .failed:
            "失敗"
        }
    }
}
