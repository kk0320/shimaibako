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

enum FullOCRStartResult: Sendable, Equatable {
    case started(jobID: UUID)
    case blocked(message: String)
    case failed(message: String)

    nonisolated var message: String? {
        switch self {
        case .started:
            nil
        case .blocked(let message), .failed(let message):
            message
        }
    }

    nonisolated var debugTitle: String {
        switch self {
        case .started(let jobID):
            "started:\(jobID.uuidString)"
        case .blocked(let message):
            "blocked:\(message)"
        case .failed(let message):
            "failed:\(message)"
        }
    }
}

struct FullOCRStartDiagnostics: Equatable {
    var lastStartTappedAt: Date?
    var lastStartPlan: String?
    var lastStartResult: String?
    var lastCreatedJobID: String?
    var lastPersistedJobID: String?
    var lastTerminalState: String?
    var lastError: String?
    var lastWorkerStartAt: Date?

    static let empty = FullOCRStartDiagnostics()
}

enum OCRJobDatabaseStatus: String, Equatable {
    case unknown
    case preparing
    case ready
    case missingTable
    case repairFailed

    nonisolated var title: String {
        switch self {
        case .unknown:
            "未確認"
        case .preparing:
            "準備中"
        case .ready:
            "ready"
        case .missingTable:
            "missingTable"
        case .repairFailed:
            "repairFailed"
        }
    }
}

struct OCRJobDatabaseDiagnostics: Equatable {
    var status: OCRJobDatabaseStatus
    var lastError: String?
    var lastMigrationAt: Date?
    var ocrJobsTableExists: Bool
    var ocrJobItemsTableExists: Bool

    static let unknown = OCRJobDatabaseDiagnostics(
        status: .unknown,
        lastError: nil,
        lastMigrationAt: nil,
        ocrJobsTableExists: false,
        ocrJobItemsTableExists: false
    )

    static func preparing(previous: OCRJobDatabaseDiagnostics) -> OCRJobDatabaseDiagnostics {
        OCRJobDatabaseDiagnostics(
            status: .preparing,
            lastError: previous.lastError,
            lastMigrationAt: previous.lastMigrationAt,
            ocrJobsTableExists: previous.ocrJobsTableExists,
            ocrJobItemsTableExists: previous.ocrJobItemsTableExists
        )
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
    case preparing
    case pending
    case running
    case throttled
    case finalizing
    case paused
    case pausedThermal
    case pausedUser
    case cancelling
    case completed
    case cancelled
    case failed

    nonisolated var title: String {
        switch self {
        case .preparing:
            "準備中"
        case .pending:
            "待機中"
        case .running:
            "OCR実行中"
        case .throttled:
            "ゆっくり処理中"
        case .finalizing:
            "検索へ反映中"
        case .paused:
            "一時停止"
        case .pausedThermal:
            "温度上昇で一時停止"
        case .pausedUser:
            "ユーザー操作で一時停止"
        case .cancelling:
            "終了処理中"
        case .completed:
            "完了"
        case .cancelled:
            "終了"
        case .failed:
            "失敗"
        }
    }

    nonisolated var isActive: Bool {
        switch self {
        case .preparing, .pending, .running, .throttled, .finalizing, .paused, .pausedThermal, .pausedUser, .cancelling:
            true
        case .completed, .cancelled, .failed:
            false
        }
    }

    nonisolated var expectsWorkerHeartbeat: Bool {
        switch self {
        case .preparing, .pending, .running, .throttled, .finalizing, .cancelling:
            true
        case .paused, .pausedThermal, .pausedUser, .completed, .cancelled, .failed:
            false
        }
    }
}

enum OCRCurrentPhase: String, Codable, Sendable, Equatable {
    case selectingTargets
    case requestingImage
    case recognizingText
    case savingResult
    case finalizingResults
    case waitingForTemperature
    case waitingForICloud

    nonisolated var title: String {
        switch self {
        case .selectingTargets:
            "対象を確認中"
        case .requestingImage:
            "画像を読み込み中"
        case .recognizingText:
            "文字を認識中"
        case .savingResult:
            "結果を保存中"
        case .finalizingResults:
            "OCR結果を検索に反映しています"
        case .waitingForTemperature:
            "温度低下を待機中"
        case .waitingForICloud:
            "iCloud取得待ち"
        }
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
    var currentPhase: OCRCurrentPhase?
    var currentAssetIdentifier: String?
    var startedAt: Date?
    var lastHeartbeatAt: Date
    var totalCount: Int
    var completedCount: Int
    var textFoundCount: Int
    var noTextCount: Int
    var skippedCount: Int
    var cloudPendingCount: Int
    var failedCount: Int
    var pausedReason: String?

    nonisolated var succeededCount: Int {
        textFoundCount + noTextCount
    }

    nonisolated var processedCount: Int {
        succeededCount + failedCount
    }

    nonisolated var terminalCount: Int {
        succeededCount + skippedCount + cloudPendingCount + failedCount
    }

    nonisolated var remainingCount: Int {
        max(totalCount - processedCount, 0)
    }

    nonisolated var isInvalidEmptyCompletedJob: Bool {
        state == .completed &&
        totalCount == 0 &&
        textFoundCount == 0 &&
        noTextCount == 0 &&
        skippedCount == 0 &&
        cloudPendingCount == 0 &&
        failedCount == 0
    }

    nonisolated var isInvalidEmptyTerminalJob: Bool {
        switch state {
        case .completed, .cancelled, .failed:
            totalCount == 0 && terminalCount == 0
        case .preparing, .pending, .running, .throttled, .finalizing, .paused, .pausedThermal, .pausedUser, .cancelling:
            false
        }
    }

    nonisolated func isStaleEmptyActiveJob(referenceDate: Date = Date(), threshold: TimeInterval = 180) -> Bool {
        state.isActive &&
        totalCount == 0 &&
        referenceDate.timeIntervalSince(updatedAt) >= threshold
    }

    nonisolated var isValidCompletedSummary: Bool {
        state == .completed &&
        totalCount > 0 &&
        terminalCount >= totalCount
    }

    nonisolated var shouldBlockQuickOCR: Bool {
        switch state {
        case .preparing, .pending, .running, .throttled, .finalizing, .cancelling:
            true
        case .paused, .pausedThermal, .pausedUser, .completed, .cancelled, .failed:
            false
        }
    }

    nonisolated func isDisplayableProgressJob(referenceDate: Date = Date()) -> Bool {
        if isInvalidEmptyTerminalJob || isStaleEmptyActiveJob(referenceDate: referenceDate) {
            return false
        }

        if state == .completed {
            return isValidCompletedSummary
        }

        if totalCount == 0 {
            switch state {
            case .preparing, .pending:
                return true
            case .running, .throttled, .finalizing, .paused, .pausedThermal, .pausedUser, .cancelling, .cancelled, .failed, .completed:
                return false
            }
        }

        return true
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

struct OCRProgressSnapshot: Equatable, Sendable {
    enum State: String, Sendable {
        case preparing
        case running
        case throttled
        case finalizing
        case pausedThermal
        case pausedUser
        case cancelling
        case completed
        case failed
    }

    let jobID: UUID
    let scopeTitle: String
    let state: State
    let phase: OCRCurrentPhase?
    let completed: Int
    let succeeded: Int
    let remaining: Int
    let total: Int
    let textFound: Int
    let noText: Int
    let failed: Int
    let cloudPending: Int
    let skipped: Int
    let startedAt: Date
    let updatedAt: Date
    let lastHeartbeatAt: Date
    let pausedReason: String?
    let itemsPerMinute: Double?
    let estimatedRemainingSeconds: TimeInterval?
    let lastProgressAt: Date
    let lastProcessedCount: Int
    let progressDelta: Int

    var fractionCompleted: Double {
        guard total > 0 else {
            return 0
        }
        return min(max(Double(completed) / Double(total), 0), 1)
    }

    var percentText: String {
        "\(Int((fractionCompleted * 100).rounded()))%"
    }

    var heartbeatAge: TimeInterval {
        Date().timeIntervalSince(lastHeartbeatAt)
    }

    var heartbeatStatusText: String {
        workerResponseText
    }

    var workerResponseText: String {
        guard expectsWorkerHeartbeat else {
            switch state {
            case .completed:
                return "OCR完了"
            case .pausedThermal, .pausedUser:
                return "一時停止中"
            case .failed:
                return "停止中"
            default:
                return "待機中"
            }
        }

        let age = heartbeatAge
        if age <= 5 {
            return "正常"
        }
        if age <= 15 {
            return "現在の1件を処理しています"
        }
        if age <= 30 {
            return "処理状況を確認しています"
        }
        return "進捗更新が停止しています"
    }

    var showsStaleHeartbeatWarning: Bool {
        expectsWorkerHeartbeat && heartbeatAge > 30
    }

    var progressStalledSeconds: TimeInterval {
        max(Date().timeIntervalSince(lastProgressAt), 0)
    }

    var progressStatusText: String {
        guard expectsWorkerHeartbeat else {
            switch state {
            case .completed:
                return "完了"
            case .pausedThermal, .pausedUser:
                return "一時停止中"
            case .failed:
                return "停止中"
            default:
                return "待機中"
            }
        }

        if progressDelta > 0 || progressStalledSeconds <= 10 {
            return "正常"
        }
        if progressStalledSeconds <= 30 {
            return "確認中"
        }
        if progressStalledSeconds <= 60 {
            return "進捗待ち"
        }
        return "停止中"
    }

    var showsStaleProgressWarning: Bool {
        expectsWorkerHeartbeat && progressStalledSeconds > 60
    }

    var stateTitle: String {
        switch state {
        case .preparing:
            "準備中"
        case .running:
            "OCR実行中"
        case .throttled:
            "温度を見ながらゆっくり処理中"
        case .finalizing:
            "OCR結果を検索に反映中"
        case .pausedThermal:
            "端末を冷ますため一時停止中"
        case .pausedUser:
            "ユーザー操作で一時停止中"
        case .cancelling:
            "終了処理中"
        case .completed:
            "完了"
        case .failed:
            "失敗"
        }
    }

    var shouldBlockQuickOCR: Bool {
        switch state {
        case .preparing, .running, .throttled, .finalizing, .cancelling:
            true
        case .pausedThermal, .pausedUser, .completed, .failed:
            false
        }
    }

    var phaseTitle: String {
        phase?.title ?? "待機中"
    }

    private var expectsWorkerHeartbeat: Bool {
        switch state {
        case .preparing, .running, .throttled, .finalizing, .cancelling:
            true
        case .pausedThermal, .pausedUser, .completed, .failed:
            false
        }
    }

    init?(
        job: OCRJob,
        isRunning: Bool,
        lastProgressAt: Date? = nil,
        lastProcessedCount: Int? = nil,
        progressDelta: Int = 0
    ) {
        guard job.isDisplayableProgressJob() else {
            #if DEBUG
            if job.isInvalidEmptyCompletedJob {
                print("OCR_JOB_IGNORED reason=invalidEmptyCompletedJob jobID=\(job.id)")
            } else if job.isInvalidEmptyTerminalJob {
                print("OCR_JOB_IGNORED reason=invalidEmptyTerminalJob jobID=\(job.id) state=\(job.state.rawValue)")
            } else if job.isStaleEmptyActiveJob() {
                print("OCR_JOB_IGNORED reason=staleEmptyActiveJob jobID=\(job.id) state=\(job.state.rawValue)")
            }
            #endif
            return nil
        }

        guard let uuid = UUID(uuidString: job.id) else {
            return nil
        }

        let processed = job.state == .completed ? job.terminalCount : job.processedCount
        jobID = uuid
        scopeTitle = job.scope.compactTitle
        state = Self.snapshotState(for: job, isRunning: isRunning)
        phase = job.currentPhase
        completed = min(processed, job.totalCount)
        succeeded = job.succeededCount
        remaining = job.remainingCount
        total = job.totalCount
        textFound = job.textFoundCount
        noText = job.noTextCount
        failed = job.failedCount
        cloudPending = job.cloudPendingCount
        skipped = job.skippedCount
        startedAt = job.startedAt ?? job.createdAt
        updatedAt = job.updatedAt
        lastHeartbeatAt = job.lastHeartbeatAt
        pausedReason = job.pausedReason
        self.lastProcessedCount = lastProcessedCount ?? processed
        self.lastProgressAt = lastProgressAt ?? job.updatedAt
        self.progressDelta = max(progressDelta, 0)

        let elapsed = max(job.updatedAt.timeIntervalSince(startedAt), 1)
        if processed > 0 {
            let perSecond = Double(processed) / elapsed
            itemsPerMinute = perSecond * 60
            let remaining = max(job.totalCount - processed, 0)
            estimatedRemainingSeconds = perSecond > 0 ? Double(remaining) / perSecond : nil
        } else {
            itemsPerMinute = nil
            estimatedRemainingSeconds = nil
        }
    }

    private static func snapshotState(for job: OCRJob, isRunning: Bool) -> State {
        switch job.state {
        case .preparing, .pending:
            return isRunning ? .running : .preparing
        case .running:
            return isRunning ? .running : .preparing
        case .throttled:
            return .throttled
        case .finalizing:
            return .finalizing
        case .pausedThermal:
            return .pausedThermal
        case .pausedUser:
            return .pausedUser
        case .paused:
            if let reason = job.pausedReason,
               reason.contains("温度") || reason.contains("低電力") || reason.contains("メモリ") {
                return .pausedThermal
            }
            return .pausedUser
        case .cancelling:
            return .cancelling
        case .completed:
            return .completed
        case .cancelled, .failed:
            return .failed
        }
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
