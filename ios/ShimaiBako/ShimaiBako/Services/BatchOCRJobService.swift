import Combine
import Foundation
import Photos
import UIKit

@MainActor
final class BatchOCRJobService: ObservableObject {
    @Published private(set) var currentJob: BatchOCRJob?
    @Published private(set) var items: [BatchOCRItem] = []
    @Published private(set) var currentSeries: BatchOCRSeries?
    @Published private(set) var isAutoContinueEnabled: Bool
    @Published private(set) var message: String?
    @Published private(set) var latestTargetDiagnostics: BatchOCRTargetSelectionDiagnostics?
    @Published var errorMessage: String?
    #if DEBUG
    @Published private(set) var p1ValidationReport: BatchOCRP1ValidationReport?
    @Published private(set) var p2ValidationReport: BatchOCRP2ValidationReport?
    @Published private(set) var p3ValidationReport: BatchOCRP3ValidationReport?
    @Published private(set) var targetSelectionValidationReport: BatchOCRTargetSelectionValidationReport?
    @Published private(set) var readStateDiagnosticsReport: BatchOCRReadStateDiagnosticsReport?
    @Published private(set) var autoContinueValidationReport: BatchOCRAutoContinueValidationReport?
    @Published private(set) var latestAutoContinueDecisionLog: String?
    @Published private(set) var isRunningP1Validation = false
    @Published private(set) var isRunningP2Validation = false
    @Published private(set) var isRunningP3Validation = false
    @Published private(set) var isRunningTargetSelectionValidation = false
    @Published private(set) var isRunningReadStateDiagnostics = false
    @Published private(set) var isRunningAutoContinueValidation = false
    #endif

    private let fileManager: FileManager
    private let userDefaults: UserDefaults
    private let fileName = "batch_ocr_jobs.json"
    private let autoContinueKey = "shimaibako.batchOCR.autoContinue2000"
    private let allowedRequestedLimits = [20, 50, 100, 500, 2_000]
    private let autoContinueBatchLimit = 2_000
    private let autoContinueRecommendedCapacityBytes: Int64 = 2_000_000_000
    private let staleProcessingInterval: TimeInterval = 180
    #if DEBUG
    private let validationReportFileName = "batch_ocr_p1_validation_report.json"
    private let p2ValidationReportFileName = "batch_ocr_p2_validation_report.json"
    private let p3ValidationReportFileName = "batch_ocr_p3_validation_report.json"
    private let targetSelectionValidationReportFileName = "batch_ocr_target_selection_validation_report.json"
    private let readStateDiagnosticsReportFileName = "batch_ocr_read_state_diagnostics_report.json"
    private let autoContinueValidationReportFileName = "batch_ocr_auto_continue_validation_report.json"
    #endif
    private var runTask: Task<Void, Never>?
    private var lastPublishedAt = Date.distantPast
    private var pauseTargetState: BatchOCRJobState = .pausedBackground
    private var isAppActive = true

    private var autoContinueIsEnabled: Bool {
        isAutoContinueEnabled
    }

    init(fileManager: FileManager = .default, userDefaults: UserDefaults = .standard) {
        self.fileManager = fileManager
        self.userDefaults = userDefaults
        isAutoContinueEnabled = userDefaults.bool(forKey: autoContinueKey)
        loadSnapshot()
        normalizeInterruptedJob()
    }

    var isRunning: Bool {
        currentJob?.state.isActive == true
    }

    var canStartNewJob: Bool {
        guard let state = currentJob?.state else {
            return true
        }

        switch state {
        case .preparing, .running, .pausing, .pausedBackground, .pausedUser, .cancelling:
            return false
        case .completed, .failed:
            return true
        }
    }

    var canResumeCurrentJob: Bool {
        guard let job = currentJob else {
            return canPrepareNextAutoBatch
        }

        let canResumeJob = (job.state == .pausedBackground || job.state == .pausedUser)
            && items.contains { $0.state == .pending || $0.state == .failedRetryable }
        return canResumeJob || canPrepareNextAutoBatch
    }

    var canPrepareNextAutoBatch: Bool {
        guard isAutoContinueEnabled,
              let series = currentSeries,
              series.batchLimit == autoContinueBatchLimit else {
            return false
        }

        switch series.state {
        case .waitingForNextBatch, .pausedDeviceCondition, .pausedUser:
            return true
        case .idle, .running, .completedNoMoreTargets, .failed:
            return false
        }
    }

    var remainingCount: Int {
        guard let currentJob else {
            return 0
        }

        return max(currentJob.plannedCount - currentJob.processedCount, 0)
    }

    private var activeJobTargetCount: Int {
        guard currentJob?.state.isActive == true else {
            return 0
        }

        return items.filter { item in
            item.state == .pending || item.state == .processing
        }.count
    }

    private var pausedJobPendingTargetCount: Int {
        guard currentJob?.state == .pausedBackground || currentJob?.state == .pausedUser else {
            return 0
        }

        return items.filter { item in
            item.state == .pending || item.state == .failedRetryable || item.state == .processing
        }.count
    }

    private var staleProcessingTargetCount: Int {
        let now = Date()
        return items.filter { item in
            guard item.state == .processing else {
                return false
            }

            guard currentJob?.state.isActive == true else {
                return true
            }

            return now.timeIntervalSince(item.updatedAt) > staleProcessingInterval
        }.count
    }

    private var orphanProcessingTargetCount: Int {
        guard let jobID = currentJob?.id else {
            return items.filter { $0.state == .processing }.count
        }

        return items.filter { item in
            item.state == .processing && item.jobID != jobID
        }.count
    }

    private var invalidOrStaleJobCount: Int {
        guard let job = currentJob else {
            return 0
        }

        return isInvalidOrStaleJob(job) ? 1 : 0
    }

    var activeStatusTitle: String {
        guard let currentJob else {
            return "待機中"
        }

        switch currentJob.state {
        case .completed:
            return currentJob.processedCount >= currentJob.plannedCount ? "読取が完了しました" : "読取処理を終了しました"
        case .failed:
            return "読取を完了できませんでした"
        case .pausedBackground, .pausedUser:
            return "読取は一時停止中です"
        case .preparing:
            return "読取を準備しています"
        case .running:
            return "文字を読み取っています"
        case .pausing:
            return "読取を一時停止しています"
        case .cancelling:
            return "読取を終了しています"
        }
    }

    var autoContinueStatusTitle: String {
        guard isAutoContinueEnabled else {
            return "自動継続 OFF"
        }

        guard let currentSeries else {
            return "自動継続 ON"
        }

        return "自動継続 ON / \(currentSeries.state.title)"
    }

    var autoContinueRemainingEstimateTitle: String? {
        guard let remainingEstimate = currentSeries?.remainingEstimate else {
            return nil
        }

        return "未読取の残り 約\(remainingEstimate)件"
    }

    func setAutoContinueEnabled(_ enabled: Bool) {
        isAutoContinueEnabled = enabled
        userDefaults.set(enabled, forKey: autoContinueKey)

        if enabled {
            ensureSeries(state: currentSeries?.state ?? .idle, pausedReason: currentSeries?.pausedReason)
        } else if var series = currentSeries {
            series.autoContinueEnabled = false
            series.state = .pausedUser
            series.pausedReason = "ユーザー操作で自動継続をOFFにしました。"
            series.updatedAt = Date()
            currentSeries = series
        }

        Task {
            await saveSnapshot()
        }
    }

    func applicationDidBecomeActive() {
        isAppActive = true
    }

    func start(
        requestedLimit: Int,
        assets: [PhotoAsset],
        photoLibrary: PhotoLibraryService,
        ocrService: OCRService,
        indexService: PhotoIndexService,
        deviceSafety: DeviceSafetyService? = nil
    ) async {
        guard allowedRequestedLimits.contains(requestedLimit) else {
            message = "この件数は現在の読取対象ではありません。"
            return
        }

        guard canStartNewJob else {
            message = "読取ジョブを実行中です。"
            return
        }

        deviceSafety?.refresh()
        if requestedLimit >= 500, let blockingReason = deviceSafety?.blockingReasonForLargeWork {
            message = blockingReason
            return
        }

        let selection = await makeSelection(
            requestedLimit: requestedLimit,
            ocrService: ocrService,
            indexService: indexService
        )
        latestTargetDiagnostics = selection.diagnostics

        guard selection.candidates.isEmpty == false else {
            currentJob = nil
            items = []
            message = selection.diagnostics.reasonIfZero ?? "新しく読み取る写真はありません"
            await saveSnapshot()
            return
        }

        let now = Date()
        let jobID = UUID().uuidString
        if requestedLimit == autoContinueBatchLimit, isAutoContinueEnabled {
            updateSeriesForStartingJob(jobID: jobID, remainingEstimate: selection.diagnostics.photoDBTotalCount, resetTotal: true)
        } else if requestedLimit != autoContinueBatchLimit {
            currentSeries = nil
        }
        await createJob(
            jobID: jobID,
            requestedLimit: requestedLimit,
            candidateDescriptors: selection.candidates,
            filterSnapshot: "読取タブ: SQLiteインデックスから未読取候補を最大\(requestedLimit)件",
            createdAt: now
        )

        let resolvedAssets = photoLibrary.assets(for: selection.candidates.map(\.assetIdentifier))
        let assetByIdentifier = Dictionary(uniqueKeysWithValues: resolvedAssets.map { ($0.localIdentifier, $0) })
        runTask = Task { [weak self] in
            await self?.run(
                jobID: jobID,
                assetByIdentifier: assetByIdentifier,
                photoLibrary: photoLibrary,
                ocrService: ocrService,
                indexService: indexService,
                deviceSafety: deviceSafety
            )
        }
    }

    func refreshTargetDiagnostics(
        requestedLimit: Int,
        assets: [PhotoAsset],
        ocrService: OCRService,
        indexService: PhotoIndexService
    ) async {
        let selection = await makeSelection(
            requestedLimit: requestedLimit,
            ocrService: ocrService,
            indexService: indexService
        )
        latestTargetDiagnostics = selection.diagnostics
        message = selection.diagnostics.reasonIfZero
    }

    @discardableResult
    func repairInvalidReadJobState() async -> Int {
        guard let job = currentJob else {
            return 0
        }

        guard isInvalidOrStaleJob(job) else {
            return 0
        }

        currentJob = nil
        items = []
        runTask?.cancel()
        runTask = nil
        message = "古い読取ジョブ状態を整理しました。読取結果は削除していません。"
        latestTargetDiagnostics = nil
        await saveSnapshot()
        return 1
    }

    #if DEBUG
    func runP1ValidationSuite(ocrService: OCRService) async {
        guard isRunningP1Validation == false else {
            return
        }

        isRunningP1Validation = true
        defer {
            isRunningP1Validation = false
        }

        let startedAt = Date()
        var results: [BatchOCRP1ValidationCaseResult] = []
        results.append(await runZeroTargetValidation())
        for limit in [20, 50, 100] {
            results.append(await runP1Validation(limit: limit, ocrService: ocrService))
        }

        let report = BatchOCRP1ValidationReport(
            startedAt: startedAt,
            finishedAt: Date(),
            cases: results
        )
        p1ValidationReport = report
        message = report.passed ? "BatchOCR P1検証が完了しました。" : "BatchOCR P1検証で確認が必要です。"
        await saveValidationReport(report)
    }

    func runP2ValidationSuite(ocrService: OCRService) async {
        guard isRunningP2Validation == false else {
            return
        }

        isRunningP2Validation = true
        defer {
            isRunningP2Validation = false
        }

        let startedAt = Date()
        var results: [BatchOCRP2ValidationCaseResult] = []
        let pauseResumeResults = await runP2PauseResumeValidation(ocrService: ocrService)
        results.append(contentsOf: pauseResumeResults)
        results.append(await runP2ProcessingRecoveryValidation())
        results.append(await runP2FinishPausedJobValidation(ocrService: ocrService))

        let report = BatchOCRP2ValidationReport(
            startedAt: startedAt,
            finishedAt: Date(),
            cases: results
        )
        p2ValidationReport = report
        message = report.passed ? "BatchOCR P2検証が完了しました。" : "BatchOCR P2検証で確認が必要です。"
        await saveP2ValidationReport(report)
    }

    func runP3ValidationSuite(ocrService: OCRService) async {
        guard isRunningP3Validation == false else {
            return
        }

        isRunningP3Validation = true
        defer {
            isRunningP3Validation = false
        }

        let startedAt = Date()
        var results: [BatchOCRP3ValidationCaseResult] = []
        results.append(await runP3CompletionValidation(limit: 500, ocrService: ocrService))
        results.append(await runP3CompletionValidation(limit: 2_000, ocrService: ocrService))
        results.append(await runP3PauseResumeValidation(limit: 500, completedBeforePause: 128, ocrService: ocrService))
        results.append(await runP3PauseResumeValidation(limit: 2_000, completedBeforePause: 375, ocrService: ocrService))

        let report = BatchOCRP3ValidationReport(
            startedAt: startedAt,
            finishedAt: Date(),
            cases: results
        )
        p3ValidationReport = report
        message = report.passed ? "BatchOCR P3検証が完了しました。" : "BatchOCR P3検証で確認が必要です。"
        await saveP3ValidationReport(report)
    }

    func runP3CompletionValidationOnly(limit: Int, ocrService: OCRService) async {
        guard isRunningP3Validation == false else {
            return
        }

        isRunningP3Validation = true
        defer {
            isRunningP3Validation = false
        }

        let startedAt = Date()
        let result = await runP3CompletionValidation(limit: limit, ocrService: ocrService)
        let report = BatchOCRP3ValidationReport(
            startedAt: startedAt,
            finishedAt: Date(),
            cases: [result]
        )
        p3ValidationReport = report
        message = report.passed ? "BatchOCR P3検証が完了しました。" : "BatchOCR P3検証で確認が必要です。"
        await saveP3ValidationReport(report)
    }

    func runP3PauseResumeValidationOnly(limit: Int, ocrService: OCRService) async {
        guard isRunningP3Validation == false else {
            return
        }

        isRunningP3Validation = true
        defer {
            isRunningP3Validation = false
        }

        let startedAt = Date()
        let completedBeforePause = limit == 500 ? 128 : 375
        let result = await runP3PauseResumeValidation(limit: limit, completedBeforePause: completedBeforePause, ocrService: ocrService)
        let report = BatchOCRP3ValidationReport(
            startedAt: startedAt,
            finishedAt: Date(),
            cases: [result]
        )
        p3ValidationReport = report
        message = report.passed ? "BatchOCR P3検証が完了しました。" : "BatchOCR P3検証で確認が必要です。"
        await saveP3ValidationReport(report)
    }

    func runTargetSelectionValidationSuite() async {
        guard isRunningTargetSelectionValidation == false else {
            return
        }

        isRunningTargetSelectionValidation = true
        defer {
            isRunningTargetSelectionValidation = false
        }

        let startedAt = Date()
        let cases = [
            targetSelectionCase(
                name: "検索データのみ写真の対象化テスト",
                requestedLimit: 500,
                totalCount: 2_000,
                evidenceProvider: { index in
                    BatchOCRReadEvidence(
                        assetIdentifier: "debug-search-only-\(index)",
                        ocrResult: nil,
                        indexStatus: .unprocessed,
                        indexText: "",
                        indexHasOCRMetadata: false,
                        indexExists: true,
                        isServiceProcessing: false,
                        isActiveInJob: false
                    )
                },
                expectedFinalTargetCount: 500,
                expectedSearchDataOnlyCandidateCount: 2_000,
                expectedStaleCacheCandidateCount: 0,
                expectedExcludedAlreadyRead: 0,
                expectedExcludedCompletedNoText: 0
            ),
            targetSelectionCase(
                name: "pageLimit leakage test: 2,000件抽出",
                requestedLimit: 2_000,
                totalCount: 2_800,
                evidenceProvider: { index in
                    BatchOCRReadEvidence.searchDataOnly("debug-page-limit-\(index)")
                },
                expectedFinalTargetCount: 2_000,
                expectedSearchDataOnlyCandidateCount: 2_800,
                expectedStaleCacheCandidateCount: 0,
                expectedExcludedAlreadyRead: 0,
                expectedExcludedCompletedNoText: 0
            ),
            targetSelectionCase(
                name: "キャッシュ削除なし500件対象抽出テスト",
                requestedLimit: 500,
                totalCount: 2_400,
                evidenceProvider: { index in
                    if index < 12 {
                        return BatchOCRReadEvidence.completedText("debug-read-\(index)")
                    } else if index < 15 {
                        return BatchOCRReadEvidence.completedNoText("debug-no-text-\(index)")
                    } else if index < 20 {
                        return BatchOCRReadEvidence.staleCompleted("debug-stale-\(index)")
                    }
                    return BatchOCRReadEvidence.searchDataOnly("debug-candidate-\(index)")
                },
                expectedFinalTargetCount: 500,
                expectedSearchDataOnlyCandidateCount: 2_380,
                expectedStaleCacheCandidateCount: 5,
                expectedExcludedAlreadyRead: 12,
                expectedExcludedCompletedNoText: 3
            ),
            targetSelectionCase(
                name: "キャッシュ削除なし2,000件対象抽出テスト",
                requestedLimit: 2_000,
                totalCount: 3_200,
                evidenceProvider: { index in
                    if index < 40 {
                        return BatchOCRReadEvidence.completedText("debug-read-\(index)")
                    } else if index < 60 {
                        return BatchOCRReadEvidence.completedNoText("debug-no-text-\(index)")
                    } else if index < 75 {
                        return BatchOCRReadEvidence.staleCompleted("debug-stale-\(index)")
                    }
                    return BatchOCRReadEvidence.searchDataOnly("debug-candidate-\(index)")
                },
                expectedFinalTargetCount: 2_000,
                expectedSearchDataOnlyCandidateCount: 3_125,
                expectedStaleCacheCandidateCount: 15,
                expectedExcludedAlreadyRead: 40,
                expectedExcludedCompletedNoText: 20
            ),
            targetSelectionCase(
                name: "0件対象テスト",
                requestedLimit: 500,
                totalCount: 100,
                evidenceProvider: { index in
                    index.isMultiple(of: 2) ?
                        BatchOCRReadEvidence.completedText("debug-read-\(index)") :
                        BatchOCRReadEvidence.completedNoText("debug-no-text-\(index)")
                },
                expectedFinalTargetCount: 0,
                expectedSearchDataOnlyCandidateCount: 0,
                expectedStaleCacheCandidateCount: 0,
                expectedExcludedAlreadyRead: 50,
                expectedExcludedCompletedNoText: 50
            )
        ]

        let report = BatchOCRTargetSelectionValidationReport(
            startedAt: startedAt,
            finishedAt: Date(),
            cases: cases
        )
        targetSelectionValidationReport = report
        message = report.passed ? "対象抽出検証が完了しました。" : "対象抽出検証で確認が必要です。"
        await saveTargetSelectionValidationReport(report)
    }

    func runReadStateDiagnostics(
        assets: [PhotoAsset],
        ocrService: OCRService,
        indexService: PhotoIndexService
    ) async {
        guard isRunningReadStateDiagnostics == false else {
            return
        }

        isRunningReadStateDiagnostics = true
        defer {
            isRunningReadStateDiagnostics = false
        }

        let limits = [20, 50, 100, 500, 2_000]
        var limitDiagnostics: [BatchOCRLimitDiagnostics] = []

        for limit in limits {
            let selection = await makeSelection(
                requestedLimit: limit,
                ocrService: ocrService,
                indexService: indexService
            )
            limitDiagnostics.append(
                BatchOCRLimitDiagnostics(
                    selectedLimit: limit,
                    targetCount: selection.candidates.count,
                    diagnostics: selection.diagnostics
                )
            )
        }

        let fullSelection = await makeSelection(
            requestedLimit: max(indexService.indexedRecordCount, 1),
            ocrService: ocrService,
            indexService: indexService
        )
        let fullDiagnostics = fullSelection.diagnostics

        let report = BatchOCRReadStateDiagnosticsReport(
            generatedAt: Date(),
            photoDatabaseCount: indexService.indexedRecordCount,
            searchDataCount: indexService.indexedRecordCount,
            readResultCacheCount: ocrService.storedCompletedCount + ocrService.storedFailedCount,
            ocrTextCount: ocrService.storedCompletedTextCount,
            completedNoTextCount: ocrService.storedCompletedNoTextCount,
            failedCount: ocrService.storedFailedCount,
            failedRetryableCount: fullDiagnostics.failedRetryableCount,
            failedPermanentCount: fullDiagnostics.failedPermanentCount,
            searchDataOnlyCount: fullDiagnostics.searchDataOnlyCandidateCount,
            unreadCandidateCount: fullDiagnostics.finalTargetCount,
            activeJobTargetCount: activeJobTargetCount,
            activeRunningJobTargets: activeJobTargetCount,
            pausedJobPendingTargets: pausedJobPendingTargetCount,
            staleProcessingTargets: staleProcessingTargetCount,
            orphanProcessingTargets: orphanProcessingTargetCount,
            invalidOrStaleJobCount: invalidOrStaleJobCount,
            limitDiagnostics: limitDiagnostics
        )

        readStateDiagnosticsReport = report
        latestTargetDiagnostics = limitDiagnostics.first(where: { $0.selectedLimit == 500 })?.diagnostics ?? limitDiagnostics.last?.diagnostics
        message = "読取状態診断が完了しました。"
        await saveReadStateDiagnosticsReport(report)
    }

    func runAutoContinueValidationSuite(
        photoLibrary: PhotoLibraryService,
        ocrService: OCRService,
        indexService: PhotoIndexService
    ) async {
        guard isRunningAutoContinueValidation == false else {
            return
        }

        isRunningAutoContinueValidation = true
        defer {
            isRunningAutoContinueValidation = false
        }

        await clearDebugValidationStateIfNeeded()
        let startedAt = Date()
        var results: [BatchOCRAutoContinueValidationCaseResult] = []
        results.append(
            await runAutoContinueCreatesNextBatchValidation(
                photoLibrary: photoLibrary,
                ocrService: ocrService,
                indexService: indexService,
                deviceSnapshot: .normal,
                name: "自動継続ON: 2,000件完了後に次の2,000件を作る"
            )
        )
        results.append(
            await runAutoContinueCreatesNextBatchValidation(
                photoLibrary: photoLibrary,
                ocrService: ocrService,
                indexService: indexService,
                deviceSnapshot: .fair,
                name: "自動継続ON: thermal fairでは低速次job作成"
            )
        )
        results.append(
            await runAutoContinueOffValidation(
                photoLibrary: photoLibrary,
                ocrService: ocrService,
                indexService: indexService
            )
        )
        results.append(
            await runAutoContinueNoTargetsValidation(
                photoLibrary: photoLibrary,
                ocrService: ocrService,
                indexService: indexService
            )
        )
        results.append(
            await runAutoContinuePausedForThermalValidation(
                photoLibrary: photoLibrary,
                ocrService: ocrService,
                indexService: indexService
            )
        )
        results.append(
            await runAutoContinuePausedForLowPowerValidation(
                photoLibrary: photoLibrary,
                ocrService: ocrService,
                indexService: indexService
            )
        )
        results.append(await runAutoContinueExistingJobValidation())

        let report = BatchOCRAutoContinueValidationReport(
            startedAt: startedAt,
            finishedAt: Date(),
            cases: results
        )
        autoContinueValidationReport = report
        message = report.passed ? "自動継続検証が完了しました。" : "自動継続検証で確認が必要です。"
        currentJob = nil
        items = []
        if isAutoContinueEnabled == false {
            currentSeries = nil
        }
        await saveAutoContinueValidationReport(report)
        await saveSnapshot()
    }

    @discardableResult
    func runP1Validation(limit: Int, ocrService: OCRService) async -> BatchOCRP1ValidationCaseResult {
        guard [20, 50, 100].contains(limit) else {
            return BatchOCRP1ValidationCaseResult(
                name: "\(limit)件",
                requestedLimit: limit,
                plannedCount: 0,
                processedCount: 0,
                completedTextCount: 0,
                completedNoTextCount: 0,
                failedCount: 0,
                ocrResultSaved: false,
                zeroJobCreated: false,
                passed: false,
                message: "P1対象外の件数です。"
            )
        }

        guard canStartNewJob else {
            return BatchOCRP1ValidationCaseResult(
                name: "\(limit)件",
                requestedLimit: limit,
                plannedCount: 0,
                processedCount: 0,
                completedTextCount: 0,
                completedNoTextCount: 0,
                failedCount: 0,
                ocrResultSaved: false,
                zeroJobCreated: false,
                passed: false,
                message: "読取ジョブを実行中です。"
            )
        }

        let runID = UUID().uuidString
        let now = Date()
        let identifiers = (0..<limit).map { index in
            "debug-batch-ocr-p1-\(limit)-\(runID)-\(index)"
        }
        let descriptors = identifiers.map { identifier in
            BatchOCRCandidateDescriptor(
                assetIdentifier: identifier,
                sourceRevision: "debug-validation"
            )
        }
        let jobID = "debug-batch-ocr-p1-\(runID)"

        await createJob(
            jobID: jobID,
            requestedLimit: limit,
            candidateDescriptors: descriptors,
            filterSnapshot: "DEBUG: BatchOCR P1 \(limit)件検証",
            createdAt: now
        )

        guard var job = currentJob, job.id == jobID else {
            return BatchOCRP1ValidationCaseResult(
                name: "\(limit)件",
                requestedLimit: limit,
                plannedCount: 0,
                processedCount: 0,
                completedTextCount: 0,
                completedNoTextCount: 0,
                failedCount: 0,
                ocrResultSaved: false,
                zeroJobCreated: false,
                passed: false,
                message: "検証ジョブを作成できませんでした。"
            )
        }

        job.state = .running
        job.startedAt = job.startedAt ?? Date()
        job.updatedAt = Date()
        currentJob = job
        await saveSnapshot()
        publish(job, force: true)

        var savedResultCount = 0
        for index in items.indices {
            guard currentJob?.id == jobID else {
                break
            }

            items[index].state = .processing
            items[index].attemptCount += 1
            items[index].updatedAt = Date()
            await saveSnapshot()

            let identifier = items[index].assetIdentifier
            let text: String
            if index.isMultiple(of: 5) {
                text = "テキストは見つかりませんでした。"
                items[index].state = .completedNoText
            } else {
                text = "BatchOCR P1 validation \(limit) \(index)"
                items[index].state = .completedText
            }
            items[index].lastErrorCode = nil
            items[index].updatedAt = Date()

            await ocrService.saveValidationResult(localIdentifier: identifier, text: text)
            if ocrService.validationResultExists(localIdentifier: identifier) {
                savedResultCount += 1
            }
            await updateCountsAndPersist(jobID: jobID, forcePublish: index == items.index(before: items.endIndex))
            await Task.yield()
        }

        await finish(jobID: jobID)

        let completedJob = currentJob
        let passed = completedJob?.state == .completed
            && completedJob?.plannedCount ?? 0 <= limit
            && completedJob?.plannedCount == limit
            && completedJob?.processedCount == limit
            && savedResultCount == limit
        let result = BatchOCRP1ValidationCaseResult(
            name: "\(limit)件",
            requestedLimit: limit,
            plannedCount: completedJob?.plannedCount ?? 0,
            processedCount: completedJob?.processedCount ?? 0,
            completedTextCount: completedJob?.completedTextCount ?? 0,
            completedNoTextCount: completedJob?.completedNoTextCount ?? 0,
            failedCount: completedJob?.failedCount ?? 0,
            ocrResultSaved: savedResultCount == limit,
            zeroJobCreated: false,
            passed: passed,
            message: passed ? "\(limit)件検証PASS" : "\(limit)件検証FAIL"
        )

        await ocrService.clearValidationResults(localIdentifiers: identifiers)

        return result
    }

    @discardableResult
    func runZeroTargetValidation() async -> BatchOCRP1ValidationCaseResult {
        guard canStartNewJob else {
            return BatchOCRP1ValidationCaseResult(
                name: "0件対象",
                requestedLimit: 0,
                plannedCount: currentJob?.plannedCount ?? 0,
                processedCount: currentJob?.processedCount ?? 0,
                completedTextCount: currentJob?.completedTextCount ?? 0,
                completedNoTextCount: currentJob?.completedNoTextCount ?? 0,
                failedCount: currentJob?.failedCount ?? 0,
                ocrResultSaved: false,
                zeroJobCreated: currentJob != nil,
                passed: false,
                message: "読取ジョブを実行中です。"
            )
        }

        currentJob = nil
        items = []
        message = "新しく読み取る写真はありません"
        errorMessage = nil
        await saveSnapshot()

        let zeroJobCreated = currentJob != nil || items.isEmpty == false
        let passed = zeroJobCreated == false
        return BatchOCRP1ValidationCaseResult(
            name: "0件対象",
            requestedLimit: 0,
            plannedCount: 0,
            processedCount: 0,
            completedTextCount: 0,
            completedNoTextCount: 0,
            failedCount: 0,
            ocrResultSaved: false,
            zeroJobCreated: zeroJobCreated,
            passed: passed,
            message: passed ? "0件対象検証PASS" : "0件対象でジョブが作成されました。"
        )
    }

    private func runP2PauseResumeValidation(ocrService: OCRService) async -> [BatchOCRP2ValidationCaseResult] {
        guard canStartNewJob else {
            return [
                p2Result(
                    name: "P2: pausedBackground",
                    passed: false,
                    message: "読取ジョブを実行中です。"
                ),
                p2Result(
                    name: "P2: 続き再開",
                    passed: false,
                    message: "読取ジョブを実行中です。"
                )
            ]
        }

        let runID = UUID().uuidString
        let identifiers = (0..<100).map { index in
            "debug-batch-ocr-p2-resume-\(runID)-\(index)"
        }
        let jobID = "debug-batch-ocr-p2-resume-\(runID)"
        await createDebugJob(jobID: jobID, requestedLimit: 100, identifiers: identifiers, filterSnapshot: "DEBUG: BatchOCR P2 中断再開検証")
        await completeDebugItems(jobID: jobID, maximumCount: 37, ocrService: ocrService)

        if let processingIndex = items.firstIndex(where: { $0.state == .pending }) {
            items[processingIndex].state = .processing
            items[processingIndex].updatedAt = Date()
            await updateCountsAndPersist(jobID: jobID, forcePublish: true)
        }

        await pause(jobID: jobID, reason: "アプリがバックグラウンドへ移行したため", state: .pausedBackground)
        let pausePassed = currentJob?.state == .pausedBackground
            && currentJob?.processedCount == 37
            && items.contains(where: { $0.state == .processing }) == false
            && items.filter({ $0.state == .pending }).count == 63

        let pauseResult = p2Result(
            name: "P2: pausedBackground",
            passed: pausePassed,
            message: pausePassed ? "途中停止PASS" : "途中停止FAIL"
        )

        if var job = currentJob, job.id == jobID {
            job.state = .running
            job.pausedReason = nil
            job.updatedAt = Date()
            currentJob = job
            await saveSnapshot()
        }
        await completeDebugItems(jobID: jobID, maximumCount: 100, ocrService: ocrService)
        await finish(jobID: jobID)

        let resumePassed = currentJob?.state == .completed
            && currentJob?.processedCount == 100
            && currentJob?.completedTextCount == 80
            && currentJob?.completedNoTextCount == 20

        let resumeResult = p2Result(
            name: "P2: 続き再開",
            passed: resumePassed,
            message: resumePassed ? "続き再開PASS" : "続き再開FAIL"
        )

        await ocrService.clearValidationResults(localIdentifiers: identifiers)
        return [pauseResult, resumeResult]
    }

    private func runP2ProcessingRecoveryValidation() async -> BatchOCRP2ValidationCaseResult {
        guard canStartNewJob else {
            return p2Result(
                name: "P2: processing復旧",
                passed: false,
                message: "読取ジョブを実行中です。"
            )
        }

        let runID = UUID().uuidString
        let identifiers = (0..<10).map { index in
            "debug-batch-ocr-p2-recovery-\(runID)-\(index)"
        }
        await createDebugJob(
            jobID: "debug-batch-ocr-p2-recovery-\(runID)",
            requestedLimit: 10,
            identifiers: identifiers,
            filterSnapshot: "DEBUG: BatchOCR P2 processing復旧検証"
        )

        if var job = currentJob {
            job.state = .running
            job.updatedAt = Date()
            currentJob = job
        }
        if items.indices.contains(0) {
            items[0].state = .processing
            items[0].updatedAt = Date()
        }
        normalizeInterruptedJob()

        let passed = currentJob?.state == .pausedBackground
            && items.first?.state == .pending
            && items.contains(where: { $0.state == .processing }) == false

        let result = p2Result(
            name: "P2: processing復旧",
            passed: passed,
            message: passed ? "processing復旧PASS" : "processing復旧FAIL"
        )

        currentJob = nil
        items = []
        await saveSnapshot()

        return result
    }

    private func runP2FinishPausedJobValidation(ocrService: OCRService) async -> BatchOCRP2ValidationCaseResult {
        guard canStartNewJob else {
            return p2Result(
                name: "P2: この処理を終了",
                passed: false,
                message: "読取ジョブを実行中です。"
            )
        }

        let runID = UUID().uuidString
        let identifiers = (0..<100).map { index in
            "debug-batch-ocr-p2-finish-\(runID)-\(index)"
        }
        let jobID = "debug-batch-ocr-p2-finish-\(runID)"
        await createDebugJob(jobID: jobID, requestedLimit: 100, identifiers: identifiers, filterSnapshot: "DEBUG: BatchOCR P2 終了検証")
        await completeDebugItems(jobID: jobID, maximumCount: 25, ocrService: ocrService)
        await pause(jobID: jobID, reason: "ユーザー操作で一時停止しました。", state: .pausedUser)
        await finishPausedJob()

        let passed = currentJob?.state == .completed
            && currentJob?.processedCount == 25
            && items.filter({ $0.state == .pending }).count == 75
            && currentJob?.pausedReason?.contains("完了済みの読取結果は保存") == true

        await ocrService.clearValidationResults(localIdentifiers: identifiers)

        return p2Result(
            name: "P2: この処理を終了",
            passed: passed,
            message: passed ? "終了検証PASS" : "終了検証FAIL"
        )
    }

    private func runP3CompletionValidation(limit: Int, ocrService: OCRService) async -> BatchOCRP3ValidationCaseResult {
        guard canStartNewJob else {
            return p3Result(
                name: "P3: \(limit)件読取検証",
                requestedLimit: limit,
                passed: false,
                message: "読取ジョブを実行中です。"
            )
        }

        let runID = UUID().uuidString
        let identifiers = (0..<limit).map { index in
            "debug-batch-ocr-p3-complete-\(limit)-\(runID)-\(index)"
        }
        let jobID = "debug-batch-ocr-p3-complete-\(limit)-\(runID)"
        await createDebugJob(
            jobID: jobID,
            requestedLimit: limit,
            identifiers: identifiers,
            filterSnapshot: "DEBUG: BatchOCR P3 \(limit)件読取検証"
        )
        await completeDebugItems(jobID: jobID, maximumCount: limit, ocrService: ocrService)
        await finish(jobID: jobID)

        let passed = currentJob?.state == .completed
            && currentJob?.requestedLimit == limit
            && currentJob?.plannedCount == limit
            && currentJob?.processedCount == limit
            && currentJob?.processedCount ?? 0 <= limit

        await ocrService.clearValidationResults(localIdentifiers: identifiers)

        return p3Result(
            name: "P3: \(limit)件読取検証",
            requestedLimit: limit,
            passed: passed,
            message: passed ? "\(limit)件読取PASS" : "\(limit)件読取FAIL"
        )
    }

    private func runP3PauseResumeValidation(limit: Int, completedBeforePause: Int, ocrService: OCRService) async -> BatchOCRP3ValidationCaseResult {
        guard canStartNewJob else {
            return p3Result(
                name: "P3: \(limit)件中断・再開検証",
                requestedLimit: limit,
                passed: false,
                message: "読取ジョブを実行中です。"
            )
        }

        let runID = UUID().uuidString
        let identifiers = (0..<limit).map { index in
            "debug-batch-ocr-p3-resume-\(limit)-\(runID)-\(index)"
        }
        let jobID = "debug-batch-ocr-p3-resume-\(limit)-\(runID)"
        await createDebugJob(
            jobID: jobID,
            requestedLimit: limit,
            identifiers: identifiers,
            filterSnapshot: "DEBUG: BatchOCR P3 \(limit)件中断再開検証"
        )
        await completeDebugItems(jobID: jobID, maximumCount: completedBeforePause, ocrService: ocrService)
        if let processingIndex = items.firstIndex(where: { $0.state == .pending }) {
            items[processingIndex].state = .processing
            items[processingIndex].updatedAt = Date()
            await updateCountsAndPersist(jobID: jobID, forcePublish: true)
        }

        await pause(jobID: jobID, reason: "アプリがバックグラウンドへ移行したため", state: .pausedBackground)
        let pausedCorrectly = currentJob?.state == .pausedBackground
            && currentJob?.processedCount == completedBeforePause
            && items.contains(where: { $0.state == .processing }) == false

        if var job = currentJob, job.id == jobID {
            job.state = .running
            job.pausedReason = nil
            job.updatedAt = Date()
            currentJob = job
            await saveSnapshot()
        }
        await completeDebugItems(jobID: jobID, maximumCount: limit, ocrService: ocrService)
        await finish(jobID: jobID)

        let passed = pausedCorrectly
            && currentJob?.state == .completed
            && currentJob?.requestedLimit == limit
            && currentJob?.plannedCount == limit
            && currentJob?.processedCount == limit

        await ocrService.clearValidationResults(localIdentifiers: identifiers)

        return p3Result(
            name: "P3: \(limit)件中断・再開検証",
            requestedLimit: limit,
            passed: passed,
            message: passed ? "\(limit)件中断・再開PASS" : "\(limit)件中断・再開FAIL"
        )
    }

    private func createDebugJob(
        jobID: String,
        requestedLimit: Int,
        identifiers: [String],
        filterSnapshot: String
    ) async {
        let descriptors = identifiers.map { identifier in
            BatchOCRCandidateDescriptor(assetIdentifier: identifier, sourceRevision: "debug-validation")
        }
        await createJob(
            jobID: jobID,
            requestedLimit: requestedLimit,
            candidateDescriptors: descriptors,
            filterSnapshot: filterSnapshot,
            createdAt: Date()
        )
        if var job = currentJob, job.id == jobID {
            job.state = .running
            job.startedAt = job.startedAt ?? Date()
            job.updatedAt = Date()
            currentJob = job
            await saveSnapshot()
            publish(job, force: true)
        }
    }

    private func completeDebugItems(jobID: String, maximumCount: Int, ocrService: OCRService) async {
        var completedInThisCall = 0
        var completedIdentifiers: [String] = []
        completedIdentifiers.reserveCapacity(maximumCount)

        for index in items.indices where completedInThisCall < maximumCount {
            guard currentJob?.id == jobID, items[index].state == .pending else {
                continue
            }

            items[index].state = .processing
            items[index].attemptCount += 1
            items[index].updatedAt = Date()

            let identifier = items[index].assetIdentifier
            let ordinal = items[index].ordinal
            if ordinal.isMultiple(of: 5) {
                items[index].state = .completedNoText
            } else {
                items[index].state = .completedText
            }
            items[index].lastErrorCode = nil
            items[index].updatedAt = Date()
            completedIdentifiers.append(identifier)
            completedInThisCall += 1

            if completedInThisCall.isMultiple(of: 100) || completedInThisCall == maximumCount {
                await updateCountsAndPersist(jobID: jobID, forcePublish: completedInThisCall == maximumCount)
            }
        }

        _ = await ocrService.saveValidationResults(localIdentifiers: completedIdentifiers) { index in
            let identifier = completedIdentifiers[index]
            guard let item = items.first(where: { $0.assetIdentifier == identifier }) else {
                return "BatchOCR validation"
            }
            return item.state == .completedNoText ? "テキストは見つかりませんでした。" : "BatchOCR validation \(item.ordinal)"
        }
    }

    private func runAutoContinueCreatesNextBatchValidation(
        photoLibrary: PhotoLibraryService,
        ocrService: OCRService,
        indexService: PhotoIndexService,
        deviceSnapshot: BatchOCRAutoContinueDeviceSnapshot,
        name: String
    ) async -> BatchOCRAutoContinueValidationCaseResult {
        await clearDebugValidationStateIfNeeded()
        guard canStartNewJob else {
            return autoContinueResult(
                name: name,
                passed: false,
                message: "読取ジョブを実行中です。"
            )
        }

        let previousAuto = isAutoContinueEnabled
        setAutoContinueEnabled(true)
        let runID = UUID().uuidString
        let firstIdentifiers = (0..<2_000).map { "debug-auto-first-\(runID)-\($0)" }
        let nextIdentifiers = (0..<2_000).map { "debug-auto-next-\(runID)-\($0)" }
        let firstJobID = "debug-auto-first-\(runID)"
        updateSeriesForStartingJob(jobID: firstJobID, remainingEstimate: 4_000, resetTotal: true)
        await createDebugJob(
            jobID: firstJobID,
            requestedLimit: autoContinueBatchLimit,
            identifiers: firstIdentifiers,
            filterSnapshot: "DEBUG: 自動継続1本目"
        )
        await completeDebugItems(jobID: firstJobID, maximumCount: 2_000, ocrService: ocrService)
        let selection = debugAutoContinueSelection(identifiers: nextIdentifiers)

        await finish(
            jobID: firstJobID,
            photoLibrary: photoLibrary,
            ocrService: ocrService,
            indexService: indexService,
            autoContinueSelectionOverride: selection,
            shouldStartAutoContinueJob: false,
            deviceSnapshotOverride: deviceSnapshot
        )

        let passed = currentJob?.id != firstJobID
            && currentJob?.requestedLimit == autoContinueBatchLimit
            && currentJob?.plannedCount == autoContinueBatchLimit
            && currentSeries?.state == .running

        let result = autoContinueResult(
            name: name,
            passed: passed,
            message: passed ? "次の2,000件ジョブ作成PASS" : "次のジョブ作成状態が期待と異なります"
        )
        await ocrService.clearValidationResults(localIdentifiers: firstIdentifiers + nextIdentifiers)
        setAutoContinueEnabled(previousAuto)
        return result
    }

    private func runAutoContinueOffValidation(
        photoLibrary: PhotoLibraryService,
        ocrService: OCRService,
        indexService: PhotoIndexService
    ) async -> BatchOCRAutoContinueValidationCaseResult {
        await clearDebugValidationStateIfNeeded()
        guard canStartNewJob else {
            return autoContinueResult(
                name: "自動継続OFF: 次jobを作らない",
                passed: false,
                message: "読取ジョブを実行中です。"
            )
        }

        let previousAuto = isAutoContinueEnabled
        setAutoContinueEnabled(false)
        let runID = UUID().uuidString
        let firstIdentifiers = (0..<2_000).map { "debug-auto-off-first-\(runID)-\($0)" }
        let nextIdentifiers = (0..<2_000).map { "debug-auto-off-next-\(runID)-\($0)" }
        let firstJobID = "debug-auto-off-first-\(runID)"
        await createDebugJob(
            jobID: firstJobID,
            requestedLimit: autoContinueBatchLimit,
            identifiers: firstIdentifiers,
            filterSnapshot: "DEBUG: 自動継続OFF検証"
        )
        await completeDebugItems(jobID: firstJobID, maximumCount: 2_000, ocrService: ocrService)
        await finish(
            jobID: firstJobID,
            photoLibrary: photoLibrary,
            ocrService: ocrService,
            indexService: indexService,
            autoContinueSelectionOverride: debugAutoContinueSelection(identifiers: nextIdentifiers),
            shouldStartAutoContinueJob: false,
            deviceSnapshotOverride: .normal
        )

        let passed = currentJob?.id == firstJobID
            && currentJob?.state == .completed
            && currentJob?.plannedCount == autoContinueBatchLimit

        let result = autoContinueResult(
            name: "自動継続OFF: 次jobを作らない",
            passed: passed,
            message: passed ? "OFF時の停止PASS" : "OFFなのに次jobが作られた可能性があります"
        )
        await ocrService.clearValidationResults(localIdentifiers: firstIdentifiers + nextIdentifiers)
        setAutoContinueEnabled(previousAuto)
        return result
    }

    private func runAutoContinueNoTargetsValidation(
        photoLibrary: PhotoLibraryService,
        ocrService: OCRService,
        indexService: PhotoIndexService
    ) async -> BatchOCRAutoContinueValidationCaseResult {
        await clearDebugValidationStateIfNeeded()
        let previousAuto = isAutoContinueEnabled
        setAutoContinueEnabled(true)
        let runID = UUID().uuidString
        let firstIdentifiers = (0..<2_000).map { "debug-auto-none-first-\(runID)-\($0)" }
        let firstJobID = "debug-auto-none-first-\(runID)"
        updateSeriesForStartingJob(jobID: firstJobID, remainingEstimate: 2_000, resetTotal: true)
        await createDebugJob(
            jobID: firstJobID,
            requestedLimit: autoContinueBatchLimit,
            identifiers: firstIdentifiers,
            filterSnapshot: "DEBUG: 自動継続0件検証"
        )
        await completeDebugItems(jobID: firstJobID, maximumCount: 2_000, ocrService: ocrService)
        await finish(
            jobID: firstJobID,
            photoLibrary: photoLibrary,
            ocrService: ocrService,
            indexService: indexService,
            autoContinueSelectionOverride: debugAutoContinueSelection(identifiers: []),
            shouldStartAutoContinueJob: false,
            deviceSnapshotOverride: .normal
        )

        let passed = currentJob?.id == firstJobID
            && currentSeries?.state == .completedNoMoreTargets
            && items.isEmpty == false

        let result = autoContinueResult(
            name: "自動継続: 未読取0件で停止",
            passed: passed,
            message: passed ? "0件ジョブ未作成PASS" : "0件ジョブが作られた可能性があります"
        )
        await ocrService.clearValidationResults(localIdentifiers: firstIdentifiers)
        setAutoContinueEnabled(previousAuto)
        return result
    }

    private func runAutoContinuePausedForThermalValidation(
        photoLibrary: PhotoLibraryService,
        ocrService: OCRService,
        indexService: PhotoIndexService
    ) async -> BatchOCRAutoContinueValidationCaseResult {
        await clearDebugValidationStateIfNeeded()
        let previousAuto = isAutoContinueEnabled
        setAutoContinueEnabled(true)
        let runID = UUID().uuidString
        let firstIdentifiers = (0..<2_000).map { "debug-auto-thermal-first-\(runID)-\($0)" }
        let nextIdentifiers = (0..<2_000).map { "debug-auto-thermal-next-\(runID)-\($0)" }
        let firstJobID = "debug-auto-thermal-first-\(runID)"
        updateSeriesForStartingJob(jobID: firstJobID, remainingEstimate: 4_000, resetTotal: true)
        await createDebugJob(
            jobID: firstJobID,
            requestedLimit: autoContinueBatchLimit,
            identifiers: firstIdentifiers,
            filterSnapshot: "DEBUG: 自動継続発熱検証"
        )
        await completeDebugItems(jobID: firstJobID, maximumCount: 2_000, ocrService: ocrService)
        await finish(
            jobID: firstJobID,
            photoLibrary: photoLibrary,
            ocrService: ocrService,
            indexService: indexService,
            autoContinueSelectionOverride: debugAutoContinueSelection(identifiers: nextIdentifiers),
            shouldStartAutoContinueJob: false,
            deviceSnapshotOverride: .serious
        )

        let passed = currentSeries?.state == .pausedDeviceCondition
            && currentSeries?.pausedReason?.contains("端末温度") == true

        let result = autoContinueResult(
            name: "自動継続: thermal seriousで停止",
            passed: passed,
            message: passed ? "発熱一時停止PASS" : "発熱時の一時停止状態が期待と異なります"
        )
        await ocrService.clearValidationResults(localIdentifiers: firstIdentifiers + nextIdentifiers)
        setAutoContinueEnabled(previousAuto)
        return result
    }

    private func runAutoContinuePausedForLowPowerValidation(
        photoLibrary: PhotoLibraryService,
        ocrService: OCRService,
        indexService: PhotoIndexService
    ) async -> BatchOCRAutoContinueValidationCaseResult {
        await clearDebugValidationStateIfNeeded()
        let previousAuto = isAutoContinueEnabled
        setAutoContinueEnabled(true)
        let runID = UUID().uuidString
        let firstIdentifiers = (0..<2_000).map { "debug-auto-low-first-\(runID)-\($0)" }
        let nextIdentifiers = (0..<2_000).map { "debug-auto-low-next-\(runID)-\($0)" }
        let firstJobID = "debug-auto-low-first-\(runID)"
        updateSeriesForStartingJob(jobID: firstJobID, remainingEstimate: 4_000, resetTotal: true)
        await createDebugJob(
            jobID: firstJobID,
            requestedLimit: autoContinueBatchLimit,
            identifiers: firstIdentifiers,
            filterSnapshot: "DEBUG: 自動継続低電力検証"
        )
        await completeDebugItems(jobID: firstJobID, maximumCount: 2_000, ocrService: ocrService)
        await finish(
            jobID: firstJobID,
            photoLibrary: photoLibrary,
            ocrService: ocrService,
            indexService: indexService,
            autoContinueSelectionOverride: debugAutoContinueSelection(identifiers: nextIdentifiers),
            shouldStartAutoContinueJob: false,
            deviceSnapshotOverride: .lowPower
        )

        let passed = currentSeries?.state == .pausedDeviceCondition
            && currentSeries?.pausedReason?.contains("低電力") == true

        let result = autoContinueResult(
            name: "自動継続: low powerで停止",
            passed: passed,
            message: passed ? "低電力一時停止PASS" : "低電力時の一時停止状態が期待と異なります"
        )
        await ocrService.clearValidationResults(localIdentifiers: firstIdentifiers + nextIdentifiers)
        setAutoContinueEnabled(previousAuto)
        return result
    }

    private func runAutoContinueExistingJobValidation() async -> BatchOCRAutoContinueValidationCaseResult {
        await clearDebugValidationStateIfNeeded()
        guard canStartNewJob else {
            return autoContinueResult(
                name: "自動継続: 途中jobがある場合は既存jobを再開",
                passed: false,
                message: "読取ジョブを実行中です。"
            )
        }

        let previousAuto = isAutoContinueEnabled
        setAutoContinueEnabled(true)
        let runID = UUID().uuidString
        let identifiers = (0..<2_000).map { "debug-auto-existing-\(runID)-\($0)" }
        let jobID = "debug-auto-existing-\(runID)"
        await createDebugJob(
            jobID: jobID,
            requestedLimit: autoContinueBatchLimit,
            identifiers: identifiers,
            filterSnapshot: "DEBUG: 自動継続途中job検証"
        )
        await pause(jobID: jobID, reason: "アプリがバックグラウンドへ移行したため", state: .pausedBackground)
        recordAutoContinueDecision(
            completedJob: nil,
            remainingCandidates: nil,
            deviceSnapshot: .normal,
            decision: "pause",
            reason: "existing paused job has priority"
        )

        let passed = currentJob?.id == jobID
            && currentJob?.state == .pausedBackground
            && canResumeCurrentJob
            && currentJob?.plannedCount == autoContinueBatchLimit

        let result = autoContinueResult(
            name: "自動継続: 途中jobがある場合は既存jobを再開",
            passed: passed,
            message: passed ? "既存job優先PASS" : "既存job再開状態が期待と異なります"
        )
        setAutoContinueEnabled(previousAuto)
        return result
    }

    private func autoContinueResult(name: String, passed: Bool, message: String) -> BatchOCRAutoContinueValidationCaseResult {
        BatchOCRAutoContinueValidationCaseResult(
            name: name,
            seriesState: currentSeries?.state,
            autoContinueEnabled: isAutoContinueEnabled,
            nextJobCreated: currentJob?.filterSnapshot == "読取タブ: 自動継続で次の2,000件を固定"
                && currentJob?.requestedLimit == autoContinueBatchLimit
                && currentJob?.plannedCount == autoContinueBatchLimit,
            plannedCount: currentJob?.plannedCount ?? 0,
            decisionLog: latestAutoContinueDecisionLog ?? "",
            passed: passed,
            message: message
        )
    }

    private func debugAutoContinueSelection(identifiers: [String]) -> BatchOCRTargetSelection {
        var diagnostics = BatchOCRTargetSelectionDiagnostics.empty
        diagnostics.selectedLimit = autoContinueBatchLimit
        diagnostics.photoDBTotalCount = identifiers.count
        diagnostics.batchCandidateScanLimit = autoContinueBatchLimit
        diagnostics.batchCandidateSource = "sqliteUnreadQuery"
        diagnostics.effectiveFetchLimit = autoContinueBatchLimit
        diagnostics.candidateBeforeExclusion = identifiers.count
        diagnostics.candidateAfterPaging = identifiers.count
        diagnostics.finalTargetCount = min(identifiers.count, autoContinueBatchLimit)
        diagnostics.reasonIfZero = identifiers.isEmpty ? "新しく読み取る写真はありません" : nil

        return BatchOCRTargetSelection(
            candidates: identifiers.prefix(autoContinueBatchLimit).map {
                BatchOCRCandidateDescriptor(assetIdentifier: $0, sourceRevision: "debug-auto-continue")
            },
            diagnostics: diagnostics
        )
    }

    private func clearDebugValidationStateIfNeeded() async {
        latestAutoContinueDecisionLog = nil
        let isDebugJob = currentJob?.filterSnapshot.hasPrefix("DEBUG:") == true
        let isAutoContinueValidationJob = currentJob?.filterSnapshot == "読取タブ: 自動継続で次の2,000件を固定"
            && currentJob?.requestedLimit == autoContinueBatchLimit
            && currentSeries != nil
        guard isDebugJob || isAutoContinueValidationJob else {
            return
        }

        currentJob = nil
        items = []
        currentSeries = nil
        runTask?.cancel()
        runTask = nil
        await saveSnapshot()
    }

    private func p2Result(name: String, passed: Bool, message: String) -> BatchOCRP2ValidationCaseResult {
        BatchOCRP2ValidationCaseResult(
            name: name,
            jobState: currentJob?.state,
            plannedCount: currentJob?.plannedCount ?? 0,
            processedCount: currentJob?.processedCount ?? 0,
            pendingCount: items.filter { $0.state == .pending }.count,
            processingCount: items.filter { $0.state == .processing }.count,
            completedTextCount: currentJob?.completedTextCount ?? 0,
            completedNoTextCount: currentJob?.completedNoTextCount ?? 0,
            failedCount: currentJob?.failedCount ?? 0,
            passed: passed,
            message: message
        )
    }

    private func p3Result(name: String, requestedLimit: Int, passed: Bool, message: String) -> BatchOCRP3ValidationCaseResult {
        BatchOCRP3ValidationCaseResult(
            name: name,
            requestedLimit: requestedLimit,
            jobState: currentJob?.state,
            plannedCount: currentJob?.plannedCount ?? 0,
            processedCount: currentJob?.processedCount ?? 0,
            pendingCount: items.filter { $0.state == .pending }.count,
            processingCount: items.filter { $0.state == .processing }.count,
            completedTextCount: currentJob?.completedTextCount ?? 0,
            completedNoTextCount: currentJob?.completedNoTextCount ?? 0,
            failedCount: currentJob?.failedCount ?? 0,
            passed: passed,
            message: message
        )
    }
    #endif

    func pauseForBackground() {
        isAppActive = false
        requestPause(targetState: .pausedBackground, reason: "アプリがバックグラウンドへ移行したため")
        if var series = currentSeries, series.autoContinueEnabled {
            series.state = .pausedDeviceCondition
            series.pausedReason = "アプリがバックグラウンドへ移行したため、自動継続を一時停止しています。"
            series.updatedAt = Date()
            currentSeries = series
            Task {
                await saveSnapshot()
            }
        }
    }

    func pauseByUser() {
        requestPause(targetState: .pausedUser, reason: "ユーザー操作で一時停止しました。")
        if var series = currentSeries, series.autoContinueEnabled {
            series.state = .pausedUser
            series.pausedReason = "ユーザー操作で自動継続を一時停止しました。"
            series.updatedAt = Date()
            currentSeries = series
            Task {
                await saveSnapshot()
            }
        }
    }

    func resumePausedJob(
        assets: [PhotoAsset],
        photoLibrary: PhotoLibraryService,
        ocrService: OCRService,
        indexService: PhotoIndexService,
        deviceSafety: DeviceSafetyService? = nil
    ) async {
        if currentJob == nil, canPrepareNextAutoBatch {
            await prepareNextAutoContinueBatch(
                photoLibrary: photoLibrary,
                ocrService: ocrService,
                indexService: indexService,
                deviceSafety: deviceSafety
            )
            return
        }

        if let job = currentJob,
           job.state != .pausedBackground,
           job.state != .pausedUser,
           canPrepareNextAutoBatch {
            await prepareNextAutoContinueBatch(
                photoLibrary: photoLibrary,
                ocrService: ocrService,
                indexService: indexService,
                deviceSafety: deviceSafety
            )
            return
        }

        guard let job = currentJob,
              (job.state == .pausedBackground || job.state == .pausedUser) else {
            message = "再開できる読取ジョブはありません。"
            return
        }

        let resumableItems = items.filter { $0.state == .pending || $0.state == .failedRetryable }
        guard resumableItems.isEmpty == false else {
            if job.requestedLimit == autoContinueBatchLimit, canPrepareNextAutoBatch {
                await prepareNextAutoContinueBatch(
                    photoLibrary: photoLibrary,
                    ocrService: ocrService,
                    indexService: indexService,
                    deviceSafety: deviceSafety
                )
            } else {
                await finish(
                    jobID: job.id,
                    photoLibrary: photoLibrary,
                    ocrService: ocrService,
                    indexService: indexService,
                    deviceSafety: deviceSafety
                )
            }
            return
        }

        let targetIdentifiers = items
            .filter { $0.state == .pending || $0.state == .failedRetryable }
            .map(\.assetIdentifier)
        let resolvedAssets = photoLibrary.assets(for: targetIdentifiers)
        let assetByIdentifier = Dictionary(uniqueKeysWithValues: resolvedAssets.map { ($0.localIdentifier, $0) })
        var nextJob = job
        nextJob.state = .running
        nextJob.pausedReason = nil
        nextJob.updatedAt = Date()
        currentJob = nextJob
        message = nil
        errorMessage = nil
        await saveSnapshot()
        publish(nextJob, force: true)

        let jobID = job.id
        runTask = Task { [weak self] in
            await self?.run(
                jobID: jobID,
                assetByIdentifier: assetByIdentifier,
                photoLibrary: photoLibrary,
                ocrService: ocrService,
                indexService: indexService,
                deviceSafety: deviceSafety
            )
        }
    }

    func finishPausedJob() async {
        guard var job = currentJob else {
            return
        }

        guard job.state == .pausedBackground || job.state == .pausedUser || job.state == .pausing else {
            return
        }

        runTask?.cancel()
        runTask = nil
        job.state = .cancelling
        job.pausedReason = "未処理分を終了しています。"
        job.updatedAt = Date()
        currentJob = job
        await saveSnapshot()

        job = recalculated(job)
        job.state = .completed
        job.pausedReason = "ユーザー操作で読取処理を終了しました。完了済みの読取結果は保存されています。"
        job.updatedAt = Date()
        currentJob = job
        if var series = currentSeries {
            series.state = .pausedUser
            series.pausedReason = "ユーザー操作で自動継続を停止しました。"
            series.updatedAt = Date()
            currentSeries = series
        }
        message = "読取処理を終了しました。完了済みの読取結果は保存されています。"
        await saveSnapshot()
        publish(job, force: true)
    }

    private func requestPause(targetState: BatchOCRJobState, reason: String) {
        guard var job = currentJob, job.state.isActive else {
            return
        }

        pauseTargetState = targetState
        job.state = .pausing
        job.pausedReason = reason
        job.updatedAt = Date()
        currentJob = recalculated(job)
        runTask?.cancel()

        Task {
            await saveSnapshot()
            publish(currentJob, force: true)
        }
    }

    private func run(
        jobID: String,
        assetByIdentifier: [String: PhotoAsset],
        photoLibrary: PhotoLibraryService,
        ocrService: OCRService,
        indexService: PhotoIndexService,
        deviceSafety: DeviceSafetyService?
    ) async {
        guard var job = currentJob, job.id == jobID else {
            return
        }

        job.state = .running
        job.startedAt = job.startedAt ?? Date()
        job.updatedAt = Date()
        currentJob = job
        await saveSnapshot()
        publish(job, force: true)

        for index in items.indices {
            guard Task.isCancelled == false,
                  currentJob?.id == jobID,
                  currentJob?.state == .running else {
                await pause(jobID: jobID, reason: currentJob?.pausedReason ?? "読取を一時停止しました。", state: pauseTargetState)
                return
            }

            if items[index].state == .failedRetryable {
                items[index].state = .pending
                items[index].updatedAt = Date()
            }

            guard items[index].state == .pending else {
                continue
            }

            let identifier = items[index].assetIdentifier
            let now = Date()
            items[index].state = .processing
            items[index].attemptCount += 1
            items[index].updatedAt = now
            await saveSnapshot()

            guard let asset = assetByIdentifier[identifier] else {
                items[index].state = .failedPermanent
                items[index].lastErrorCode = "asset_not_available"
                items[index].updatedAt = Date()
                await updateCountsAndPersist(jobID: jobID, forcePublish: false)
                continue
            }

            if ocrService.isProcessing(asset) {
                items[index].state = .skippedAlreadyOCRed
                items[index].updatedAt = Date()
                await updateCountsAndPersist(jobID: jobID, forcePublish: false)
                continue
            }

            if let storedResult = ocrService.result(for: asset),
               storedResult.ocrStatus == .completed || storedResult.ocrStatus == .processing {
                items[index].state = .skippedAlreadyOCRed
                items[index].updatedAt = Date()
                await updateCountsAndPersist(jobID: jobID, forcePublish: false)
                continue
            }

            guard let image = await photoLibrary.requestDisplayImage(for: asset) else {
                await ocrService.markFailure(asset: asset, message: "画像を取得できませんでした。")
                await indexService.update(asset: asset, ocrService: ocrService)
                items[index].state = .failedPermanent
                items[index].lastErrorCode = "image_unavailable"
                items[index].updatedAt = Date()
                await updateCountsAndPersist(jobID: jobID, forcePublish: false)
                continue
            }

            guard Task.isCancelled == false,
                  currentJob?.id == jobID,
                  currentJob?.state == .running else {
                items[index].state = .pending
                items[index].updatedAt = Date()
                await pause(jobID: jobID, reason: currentJob?.pausedReason ?? "読取を一時停止しました。", state: pauseTargetState)
                return
            }

            let result = await ocrService.recognize(asset: asset, image: image)
            await indexService.update(asset: asset, ocrService: ocrService)

            guard Task.isCancelled == false,
                  currentJob?.id == jobID,
                  currentJob?.state == .running else {
                items[index].state = .pending
                items[index].updatedAt = Date()
                await pause(jobID: jobID, reason: currentJob?.pausedReason ?? "読取を一時停止しました。", state: pauseTargetState)
                return
            }

            if let result, result.ocrStatus == .completed {
                items[index].state = isNoTextResult(result) ? .completedNoText : .completedText
                items[index].lastErrorCode = nil
            } else {
                items[index].state = .failedPermanent
                items[index].lastErrorCode = result?.errorMessage ?? "recognition_failed"
            }
            items[index].updatedAt = Date()
            await updateCountsAndPersist(jobID: jobID, forcePublish: false)

            await throttleForLargeBatchIfNeeded(deviceSafety: deviceSafety)

            deviceSafety?.refresh()
            if let blockingReason = pauseReasonForRunningLargeBatch(deviceSafety: deviceSafety) {
                await pause(jobID: jobID, reason: blockingReason, state: .pausedBackground)
                return
            }

            await Task.yield()
        }

        await finish(
            jobID: jobID,
            photoLibrary: photoLibrary,
            ocrService: ocrService,
            indexService: indexService,
            deviceSafety: deviceSafety
        )
    }

    private func pause(jobID: String, reason: String, state: BatchOCRJobState) async {
        guard var job = currentJob, job.id == jobID else {
            return
        }

        guard job.state == .running || job.state == .pausing else {
            return
        }

        for index in items.indices where items[index].state == .processing {
            items[index].state = .pending
            items[index].updatedAt = Date()
        }

        job.state = state
        job.pausedReason = reason
        job.updatedAt = Date()
        currentJob = recalculated(job)
        runTask = nil
        await saveSnapshot()
        publish(currentJob, force: true)
    }

    private func finish(
        jobID: String,
        photoLibrary: PhotoLibraryService? = nil,
        ocrService: OCRService? = nil,
        indexService: PhotoIndexService? = nil,
        deviceSafety: DeviceSafetyService? = nil,
        autoContinueSelectionOverride: BatchOCRTargetSelection? = nil,
        shouldStartAutoContinueJob: Bool = true,
        deviceSnapshotOverride: BatchOCRAutoContinueDeviceSnapshot? = nil
    ) async {
        guard var job = currentJob, job.id == jobID else {
            return
        }

        job = recalculated(job)
        job.state = job.failedCount == job.plannedCount ? .failed : .completed
        job.pausedReason = job.state == .failed ? "すべての対象で読取に失敗しました。" : nil
        job.updatedAt = Date()
        currentJob = job
        message = job.state == .completed ? "読取が完了しました" : job.pausedReason
        runTask = nil
        await saveSnapshot()
        publish(job, force: true)

        if job.state == .completed,
           job.requestedLimit == autoContinueBatchLimit,
           photoLibrary != nil,
           ocrService != nil,
           indexService != nil {
            await handleAutoContinueAfterCompletion(
                completedJob: job,
                photoLibrary: photoLibrary!,
                ocrService: ocrService!,
                indexService: indexService!,
                deviceSafety: deviceSafety,
                selectionOverride: autoContinueSelectionOverride,
                shouldStartJob: shouldStartAutoContinueJob,
                deviceSnapshotOverride: deviceSnapshotOverride
            )
        }
    }

    private func handleAutoContinueAfterCompletion(
        completedJob: BatchOCRJob,
        photoLibrary: PhotoLibraryService,
        ocrService: OCRService,
        indexService: PhotoIndexService,
        deviceSafety: DeviceSafetyService?,
        selectionOverride: BatchOCRTargetSelection? = nil,
        shouldStartJob: Bool = true,
        deviceSnapshotOverride: BatchOCRAutoContinueDeviceSnapshot? = nil
    ) async {
        guard completedJob.requestedLimit == autoContinueBatchLimit else {
            recordAutoContinueDecision(
                completedJob: completedJob,
                remainingCandidates: nil,
                deviceSnapshot: autoContinueDeviceSnapshot(deviceSafety: deviceSafety, override: deviceSnapshotOverride),
                decision: "skip",
                reason: "completed job is not 2,000 limit"
            )
            return
        }

        guard autoContinueIsEnabled else {
            recordAutoContinueDecision(
                completedJob: completedJob,
                remainingCandidates: nil,
                deviceSnapshot: autoContinueDeviceSnapshot(deviceSafety: deviceSafety, override: deviceSnapshotOverride),
                decision: "skip",
                reason: "autoContinueEnabled is false"
            )
            return
        }

        var series = currentSeries ?? makeSeries(state: .running)
        series.autoContinueEnabled = true
        series.lastJobID = completedJob.id
        series.totalProcessedInSeries += completedJob.processedCount
        series.updatedAt = Date()
        currentSeries = series

        guard isAppActive else {
            pauseSeriesForDeviceCondition("アプリがバックグラウンドへ移行したため、自動継続を一時停止しています。")
            recordAutoContinueDecision(
                completedJob: completedJob,
                remainingCandidates: nil,
                deviceSnapshot: autoContinueDeviceSnapshot(deviceSafety: deviceSafety, override: deviceSnapshotOverride),
                decision: "pause",
                reason: "app is not active"
            )
            return
        }

        let deviceSnapshot = autoContinueDeviceSnapshot(deviceSafety: deviceSafety, override: deviceSnapshotOverride)
        if let pauseReason = pauseReasonForAutoContinue(snapshot: deviceSnapshot) {
            pauseSeriesForDeviceCondition(pauseReason)
            message = "2,000件の読取が完了しました。端末の状態を見て一時停止しています。"
            recordAutoContinueDecision(
                completedJob: completedJob,
                remainingCandidates: nil,
                deviceSnapshot: deviceSnapshot,
                decision: "pause",
                reason: pauseReason
            )
            await saveSnapshot()
            return
        }

        await prepareNextAutoContinueBatch(
            photoLibrary: photoLibrary,
            ocrService: ocrService,
            indexService: indexService,
            deviceSafety: deviceSafety,
            completedJob: completedJob,
            selectionOverride: selectionOverride,
            shouldStartJob: shouldStartJob,
            deviceSnapshotOverride: deviceSnapshot
        )
    }

    private func prepareNextAutoContinueBatch(
        photoLibrary: PhotoLibraryService,
        ocrService: OCRService,
        indexService: PhotoIndexService,
        deviceSafety: DeviceSafetyService?,
        completedJob: BatchOCRJob? = nil,
        selectionOverride: BatchOCRTargetSelection? = nil,
        shouldStartJob: Bool = true,
        deviceSnapshotOverride: BatchOCRAutoContinueDeviceSnapshot? = nil
    ) async {
        let deviceSnapshot = autoContinueDeviceSnapshot(deviceSafety: deviceSafety, override: deviceSnapshotOverride)
        guard autoContinueIsEnabled else {
            recordAutoContinueDecision(
                completedJob: completedJob,
                remainingCandidates: nil,
                deviceSnapshot: deviceSnapshot,
                decision: "skip",
                reason: "autoContinueEnabled is false"
            )
            return
        }

        if let state = currentJob?.state,
           state == .preparing || state == .running || state == .pausing || state == .pausedBackground || state == .pausedUser || state == .cancelling {
            recordAutoContinueDecision(
                completedJob: completedJob,
                remainingCandidates: nil,
                deviceSnapshot: deviceSnapshot,
                decision: "pause",
                reason: "another job is active"
            )
            return
        }

        guard isAppActive else {
            pauseSeriesForDeviceCondition("アプリがバックグラウンドへ移行したため、自動継続を一時停止しています。")
            recordAutoContinueDecision(
                completedJob: completedJob,
                remainingCandidates: nil,
                deviceSnapshot: deviceSnapshot,
                decision: "pause",
                reason: "app is not active"
            )
            return
        }

        if let pauseReason = pauseReasonForAutoContinue(snapshot: deviceSnapshot) {
            pauseSeriesForDeviceCondition(pauseReason)
            message = "端末の状態を見て一時停止しています。続きから再開できます。"
            recordAutoContinueDecision(
                completedJob: completedJob,
                remainingCandidates: nil,
                deviceSnapshot: deviceSnapshot,
                decision: "pause",
                reason: pauseReason
            )
            await saveSnapshot()
            return
        }

        ensureSeries(state: .waitingForNextBatch, pausedReason: nil)
        message = "端末の状態が良いため、次の2,000件を準備しています。"
        await saveSnapshot()

        let selection = if let selectionOverride {
            selectionOverride
        } else {
            await makeSelection(
                requestedLimit: autoContinueBatchLimit,
                ocrService: ocrService,
                indexService: indexService
            )
        }
        latestTargetDiagnostics = selection.diagnostics

        guard selection.candidates.isEmpty == false else {
            var series = currentSeries ?? makeSeries(state: .completedNoMoreTargets)
            series.state = .completedNoMoreTargets
            series.remainingEstimate = 0
            series.pausedReason = nil
            series.updatedAt = Date()
            currentSeries = series
            message = "未読取の写真はありません。すべての読取が完了しています。"
            recordAutoContinueDecision(
                completedJob: completedJob,
                remainingCandidates: 0,
                deviceSnapshot: deviceSnapshot,
                decision: "stopNoTargets",
                reason: "no unread candidates"
            )
            await saveSnapshot()
            return
        }

        let now = Date()
        let jobID = UUID().uuidString
        updateSeriesForStartingJob(
            jobID: jobID,
            remainingEstimate: max(selection.diagnostics.photoDBTotalCount - selection.diagnostics.excludedAlreadyRead - selection.diagnostics.excludedCompletedNoText, selection.diagnostics.finalTargetCount)
        )
        await createJob(
            jobID: jobID,
            requestedLimit: autoContinueBatchLimit,
            candidateDescriptors: selection.candidates,
            filterSnapshot: "読取タブ: 自動継続で次の2,000件を固定",
            createdAt: now
        )

        recordAutoContinueDecision(
            completedJob: completedJob,
            remainingCandidates: selection.candidates.count,
            deviceSnapshot: deviceSnapshot,
            decision: "startNextBatch",
            reason: "created next 2,000 batch"
        )

        guard shouldStartJob else {
            return
        }

        let resolvedAssets = photoLibrary.assets(for: selection.candidates.map(\.assetIdentifier))
        let assetByIdentifier = Dictionary(uniqueKeysWithValues: resolvedAssets.map { ($0.localIdentifier, $0) })
        runTask = Task { [weak self] in
            await self?.run(
                jobID: jobID,
                assetByIdentifier: assetByIdentifier,
                photoLibrary: photoLibrary,
                ocrService: ocrService,
                indexService: indexService,
                deviceSafety: deviceSafety
            )
        }
    }

    private func ensureSeries(state: BatchOCRSeriesState, pausedReason: String?) {
        var series = currentSeries ?? makeSeries(state: state)
        series.autoContinueEnabled = isAutoContinueEnabled
        series.batchLimit = autoContinueBatchLimit
        series.state = state
        series.pausedReason = pausedReason
        series.updatedAt = Date()
        currentSeries = series
    }

    private func updateSeriesForStartingJob(jobID: String, remainingEstimate: Int?, resetTotal: Bool = false) {
        var series = currentSeries ?? makeSeries(state: .running)
        series.autoContinueEnabled = isAutoContinueEnabled
        series.batchLimit = autoContinueBatchLimit
        series.state = .running
        series.lastJobID = jobID
        if resetTotal {
            series.totalProcessedInSeries = 0
        }
        series.remainingEstimate = remainingEstimate
        series.pausedReason = nil
        series.updatedAt = Date()
        currentSeries = series
    }

    private func makeSeries(state: BatchOCRSeriesState) -> BatchOCRSeries {
        let now = Date()
        return BatchOCRSeries(
            id: UUID().uuidString,
            state: state,
            autoContinueEnabled: isAutoContinueEnabled,
            batchLimit: autoContinueBatchLimit,
            createdAt: now,
            updatedAt: now,
            lastJobID: nil,
            totalProcessedInSeries: 0,
            remainingEstimate: nil,
            pausedReason: nil
        )
    }

    private func pauseSeriesForDeviceCondition(_ reason: String) {
        var series = currentSeries ?? makeSeries(state: .pausedDeviceCondition)
        series.autoContinueEnabled = isAutoContinueEnabled
        series.batchLimit = autoContinueBatchLimit
        series.state = .pausedDeviceCondition
        series.pausedReason = reason
        series.updatedAt = Date()
        currentSeries = series
    }

    private func recordAutoContinueDecision(
        completedJob: BatchOCRJob?,
        remainingCandidates: Int?,
        deviceSnapshot: BatchOCRAutoContinueDeviceSnapshot,
        decision: String,
        reason: String
    ) {
        let freeStorage = deviceSnapshot.availableCapacityBytes.map(String.init) ?? "unknown"
        let log = [
            "AUTO_CONTINUE decision",
            "enabled=\(autoContinueIsEnabled)",
            "seriesEnabled=\(currentSeries?.autoContinueEnabled ?? false)",
            "completedJobID=\(completedJob?.id ?? "-")",
            "requestedLimit=\(completedJob?.requestedLimit ?? 0)",
            "remainingCandidates=\(remainingCandidates.map(String.init) ?? "unknown")",
            "thermal=\(title(for: deviceSnapshot.thermalState))",
            "lowPower=\(deviceSnapshot.isLowPowerModeEnabled)",
            "freeStorage=\(freeStorage)",
            "appState=\(isAppActive ? "active" : "notActive")",
            "existingJobState=\(currentJob?.state.rawValue ?? "none")",
            "decision=\(decision)",
            "reason=\(reason)"
        ].joined(separator: "\n")

        #if DEBUG
        latestAutoContinueDecisionLog = log
        print(log)
        #endif
    }

    private func autoContinueDeviceSnapshot(
        deviceSafety: DeviceSafetyService?,
        override: BatchOCRAutoContinueDeviceSnapshot? = nil
    ) -> BatchOCRAutoContinueDeviceSnapshot {
        if let override {
            return override
        }

        deviceSafety?.refresh()

        if let deviceSafety {
            return BatchOCRAutoContinueDeviceSnapshot(
                thermalState: deviceSafety.thermalState,
                isLowPowerModeEnabled: deviceSafety.isLowPowerModeEnabled,
                availableCapacityBytes: deviceSafety.availableCapacityBytes,
                batteryLevel: deviceSafety.batteryLevel,
                batteryState: deviceSafety.batteryState
            )
        }

        return BatchOCRAutoContinueDeviceSnapshot(
            thermalState: ProcessInfo.processInfo.thermalState,
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            availableCapacityBytes: nil,
            batteryLevel: UIDevice.current.batteryLevel,
            batteryState: UIDevice.current.batteryState
        )
    }

    private func title(for thermalState: ProcessInfo.ThermalState) -> String {
        switch thermalState {
        case .nominal:
            return "nominal"
        case .fair:
            return "fair"
        case .serious:
            return "serious"
        case .critical:
            return "critical"
        @unknown default:
            return "unknown"
        }
    }

    private func pauseReasonForAutoContinue(deviceSafety: DeviceSafetyService?) -> String? {
        pauseReasonForAutoContinue(snapshot: autoContinueDeviceSnapshot(deviceSafety: deviceSafety))
    }

    private func pauseReasonForAutoContinue(snapshot: BatchOCRAutoContinueDeviceSnapshot) -> String? {
        if snapshot.thermalState == .serious {
            return "端末温度が高いため、自動継続を一時停止しています。"
        }

        if snapshot.thermalState == .critical {
            return "端末保護のため、自動継続を停止しました。続きから再開できます。"
        }

        if snapshot.isLowPowerModeEnabled {
            return "低電力モードのため一時停止しています。"
        }

        if let availableCapacityBytes = snapshot.availableCapacityBytes,
           availableCapacityBytes < autoContinueRecommendedCapacityBytes {
            return "空き容量が2GB未満のため、自動継続を一時停止しています。"
        }

        if snapshot.batteryLevel >= 0,
           snapshot.batteryLevel < 0.5,
           snapshot.batteryState != .charging,
           snapshot.batteryState != .full {
            return "バッテリー残量が50%未満のため、自動継続を一時停止しています。"
        }

        return nil
    }

    private func pauseReasonForRunningLargeBatch(deviceSafety: DeviceSafetyService?) -> String? {
        guard currentJob?.requestedLimit == autoContinueBatchLimit else {
            return deviceSafety?.blockingReasonForLargeWork
        }

        deviceSafety?.refresh()

        guard let deviceSafety else {
            return nil
        }

        if deviceSafety.thermalState == .serious {
            return "端末温度が高いため、現在の1件を保存して一時停止しました。"
        }

        if deviceSafety.thermalState == .critical {
            return "端末保護のため読取を停止しました。続きから再開できます。"
        }

        if deviceSafety.isLowPowerModeEnabled {
            return "低電力モードのため読取を一時停止しています。"
        }

        if let availableCapacityBytes = deviceSafety.availableCapacityBytes,
           availableCapacityBytes < 1_000_000_000 {
            return "保存容量が1GB未満のため、読取を一時停止しています。"
        }

        return nil
    }

    private func throttleForLargeBatchIfNeeded(deviceSafety: DeviceSafetyService?) async {
        guard currentJob?.requestedLimit == autoContinueBatchLimit else {
            return
        }

        let thermalState = deviceSafety?.thermalState ?? ProcessInfo.processInfo.thermalState
        let nanoseconds: UInt64
        switch thermalState {
        case .nominal:
            nanoseconds = 350_000_000
        case .fair:
            nanoseconds = 1_500_000_000
        case .serious, .critical:
            nanoseconds = 0
        @unknown default:
            nanoseconds = 800_000_000
        }

        guard nanoseconds > 0 else {
            return
        }

        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    private func updateCountsAndPersist(jobID: String, forcePublish: Bool) async {
        guard var job = currentJob, job.id == jobID else {
            return
        }

        job = recalculated(job)
        job.updatedAt = Date()
        currentJob = job
        await saveSnapshot()
        publish(job, force: forcePublish)
    }

    private func createJob(
        jobID: String,
        requestedLimit: Int,
        candidateDescriptors: [BatchOCRCandidateDescriptor],
        filterSnapshot: String,
        createdAt: Date
    ) async {
        let job = BatchOCRJob(
            id: jobID,
            state: .preparing,
            requestedLimit: requestedLimit,
            plannedCount: candidateDescriptors.count,
            processedCount: 0,
            completedTextCount: 0,
            completedNoTextCount: 0,
            failedCount: 0,
            createdAt: createdAt,
            startedAt: nil,
            updatedAt: createdAt,
            pausedReason: nil,
            filterSnapshot: filterSnapshot,
            recognitionProfileVersion: "\(OCRConfiguration.recognitionQualityTitle) \(OCRConfiguration.recognitionLanguageTitle)"
        )
        let nextItems = candidateDescriptors.enumerated().map { index, descriptor in
            BatchOCRItem(
                jobID: jobID,
                assetIdentifier: descriptor.assetIdentifier,
                ordinal: index,
                state: .pending,
                attemptCount: 0,
                sourceRevision: descriptor.sourceRevision,
                lastErrorCode: nil,
                updatedAt: createdAt
            )
        }

        currentJob = job
        items = nextItems
        message = nil
        errorMessage = nil
        await saveSnapshot()
        publish(job, force: true)
    }

    private func makeSelection(
        requestedLimit: Int,
        ocrService: OCRService,
        indexService: PhotoIndexService
    ) async -> BatchOCRTargetSelection {
        let recoveredProcessingCount = await recoverStaleProcessingLocksIfNeeded()
        let candidateRecords = await indexService.batchOCRCandidateRecords(limit: requestedLimit)
        let activeIdentifiers = activeInProgressIdentifiers()
        let failedPermanentCount = items.filter { $0.state == .failedPermanent }.count

        var candidates: [BatchOCRCandidateDescriptor] = []
        candidates.reserveCapacity(min(requestedLimit, candidateRecords.count))
        var diagnostics = BatchOCRTargetSelectionDiagnostics.empty
        diagnostics.selectedLimit = requestedLimit
        diagnostics.photoDBTotalCount = indexService.indexedRecordCount
        diagnostics.batchCandidateScanLimit = requestedLimit
        diagnostics.batchCandidateSource = "sqliteUnreadQuery"
        diagnostics.effectiveFetchLimit = requestedLimit
        diagnostics.failedPermanentCount = failedPermanentCount
        diagnostics.excludedFailedPermanent = failedPermanentCount
        diagnostics.staleInProgressRecovered = recoveredProcessingCount
        diagnostics.activeRunningJobTargets = activeJobTargetCount
        diagnostics.pausedJobPendingTargets = pausedJobPendingTargetCount
        diagnostics.staleProcessingTargets = staleProcessingTargetCount
        diagnostics.orphanProcessingTargets = orphanProcessingTargetCount

        for record in candidateRecords {
            diagnostics.candidateBeforeExclusion += 1
            let evidence = BatchOCRReadEvidence(
                assetIdentifier: record.localIdentifier,
                ocrResult: ocrService.result(localIdentifier: record.localIdentifier),
                indexStatus: record.ocrStatus,
                indexText: record.ocrText,
                indexHasOCRMetadata: record.hasOCRMetadata,
                indexExists: true,
                isServiceProcessing: ocrService.isProcessing(localIdentifier: record.localIdentifier),
                isActiveInJob: activeIdentifiers.contains(record.localIdentifier)
            )
            let decision = readDecision(for: evidence)

            switch decision {
            case .target:
                appendCandidate(record, to: &candidates, requestedLimit: requestedLimit)
            case .searchDataOnlyTarget:
                diagnostics.searchDataOnlyCandidateCount += 1
                appendCandidate(record, to: &candidates, requestedLimit: requestedLimit)
            case .staleCacheTarget:
                diagnostics.staleCacheCandidateCount += 1
                appendCandidate(record, to: &candidates, requestedLimit: requestedLimit)
            case .failedRetryableTarget:
                diagnostics.failedRetryableCount += 1
                appendCandidate(record, to: &candidates, requestedLimit: requestedLimit)
            case .alreadyRead:
                diagnostics.excludedAlreadyRead += 1
            case .completedNoText:
                diagnostics.excludedCompletedNoText += 1
            case .inProgress:
                diagnostics.excludedInProgress += 1
            }
        }

        diagnostics.candidateAfterPaging = candidateRecords.count
        diagnostics.finalTargetCount = candidates.count
        diagnostics.reasonIfZero = reasonIfZero(for: diagnostics)

        return BatchOCRTargetSelection(candidates: candidates, diagnostics: diagnostics)
    }

    private func appendCandidate(_ record: PhotoIndexRecord, to candidates: inout [BatchOCRCandidateDescriptor], requestedLimit: Int) {
        guard candidates.count < requestedLimit else {
            return
        }

        candidates.append(
            BatchOCRCandidateDescriptor(
                assetIdentifier: record.localIdentifier,
                sourceRevision: sourceRevision(for: record)
            )
        )
    }

    private func reasonIfZero(for diagnostics: BatchOCRTargetSelectionDiagnostics) -> String? {
        guard diagnostics.finalTargetCount == 0 else {
            return nil
        }

        if diagnostics.candidateBeforeExclusion == 0 {
            return "新しく読み取る写真はありません"
        }

        if diagnostics.excludedAlreadyRead + diagnostics.excludedCompletedNoText >= diagnostics.candidateBeforeExclusion {
            return "新しく読み取る写真はありません。すでに読取済み、または文字なし判定済みです。"
        }

        if diagnostics.excludedInProgress > 0 {
            return "新しく読み取る写真はありません。現在処理中の写真を除外しています。"
        }

        return "新しく読み取る写真はありません"
    }

    private func recalculated(_ job: BatchOCRJob) -> BatchOCRJob {
        var nextJob = job
        nextJob.processedCount = items.filter { $0.state.isTerminalForP1 }.count
        nextJob.completedTextCount = items.filter { $0.state == .completedText }.count
        nextJob.completedNoTextCount = items.filter { $0.state == .completedNoText }.count
        nextJob.failedCount = items.filter { $0.state == .failedRetryable || $0.state == .failedPermanent }.count
        return nextJob
    }

    private func isNoTextResult(_ result: OCRResultRecord) -> Bool {
        OCRService.isNoTextResult(result)
    }

    private func readDecision(for evidence: BatchOCRReadEvidence) -> BatchOCRReadDecision {
        if evidence.isActiveInJob || evidence.isServiceProcessing {
            return .inProgress
        }

        if let result = evidence.ocrResult {
            switch result.ocrStatus {
            case .completed:
                return OCRService.isNoTextResult(result) ? .completedNoText : .alreadyRead
            case .processing:
                return .inProgress
            case .failed:
                return .failedRetryableTarget
            case .unprocessed:
                break
            }
        }

        guard evidence.indexExists else {
            return .target
        }

        switch evidence.indexStatus {
        case .completed:
            let trimmedText = evidence.indexText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedText.isEmpty == false && trimmedText != "テキストは見つかりませんでした。" {
                return .alreadyRead
            }

            if trimmedText == "テキストは見つかりませんでした。" || evidence.indexHasOCRMetadata {
                return .completedNoText
            }

            return .staleCacheTarget
        case .processing:
            return .staleCacheTarget
        case .failed:
            return .failedRetryableTarget
        case .unprocessed, .none:
            return .searchDataOnlyTarget
        }
    }

    #if DEBUG
    private func targetSelectionCase(
        name: String,
        requestedLimit: Int,
        totalCount: Int,
        evidenceProvider: (Int) -> BatchOCRReadEvidence,
        expectedFinalTargetCount: Int,
        expectedSearchDataOnlyCandidateCount: Int,
        expectedStaleCacheCandidateCount: Int,
        expectedExcludedAlreadyRead: Int,
        expectedExcludedCompletedNoText: Int
    ) -> BatchOCRTargetSelectionValidationCaseResult {
        let diagnostics = syntheticDiagnostics(
            requestedLimit: requestedLimit,
            totalCount: totalCount,
            evidenceProvider: evidenceProvider
        )
        let passed = diagnostics.finalTargetCount == expectedFinalTargetCount &&
            diagnostics.searchDataOnlyCandidateCount == expectedSearchDataOnlyCandidateCount &&
            diagnostics.staleCacheCandidateCount == expectedStaleCacheCandidateCount &&
            diagnostics.excludedAlreadyRead == expectedExcludedAlreadyRead &&
            diagnostics.excludedCompletedNoText == expectedExcludedCompletedNoText

        return BatchOCRTargetSelectionValidationCaseResult(
            name: name,
            selectedLimit: requestedLimit,
            finalTargetCount: diagnostics.finalTargetCount,
            searchDataOnlyCandidateCount: diagnostics.searchDataOnlyCandidateCount,
            staleCacheCandidateCount: diagnostics.staleCacheCandidateCount,
            excludedAlreadyRead: diagnostics.excludedAlreadyRead,
            excludedCompletedNoText: diagnostics.excludedCompletedNoText,
            passed: passed,
            message: passed ? "PASS" : "対象抽出の内訳が期待と異なります"
        )
    }

    private func syntheticDiagnostics(
        requestedLimit: Int,
        totalCount: Int,
        evidenceProvider: (Int) -> BatchOCRReadEvidence
    ) -> BatchOCRTargetSelectionDiagnostics {
        var diagnostics = BatchOCRTargetSelectionDiagnostics.empty
        diagnostics.selectedLimit = requestedLimit

        for index in 0..<totalCount {
            diagnostics.candidateBeforeExclusion += 1
            let decision = readDecision(for: evidenceProvider(index))

            switch decision {
            case .target:
                diagnostics.finalTargetCount = min(diagnostics.finalTargetCount + 1, requestedLimit)
            case .searchDataOnlyTarget:
                diagnostics.searchDataOnlyCandidateCount += 1
                diagnostics.finalTargetCount = min(diagnostics.finalTargetCount + 1, requestedLimit)
            case .staleCacheTarget:
                diagnostics.staleCacheCandidateCount += 1
                diagnostics.finalTargetCount = min(diagnostics.finalTargetCount + 1, requestedLimit)
            case .failedRetryableTarget:
                diagnostics.failedRetryableCount += 1
                diagnostics.finalTargetCount = min(diagnostics.finalTargetCount + 1, requestedLimit)
            case .alreadyRead:
                diagnostics.excludedAlreadyRead += 1
            case .completedNoText:
                diagnostics.excludedCompletedNoText += 1
            case .inProgress:
                diagnostics.excludedInProgress += 1
            }
        }

        diagnostics.reasonIfZero = reasonIfZero(for: diagnostics)
        return diagnostics
    }
    #endif

    private func isInvalidOrStaleJob(_ job: BatchOCRJob) -> Bool {
        let invalidLimit = allowedRequestedLimits.contains(job.requestedLimit) == false
        let invalidEmptyJob = job.plannedCount == 0
        let staleFullOCRText = job.filterSnapshot.contains("全数") ||
            job.filterSnapshot.localizedCaseInsensitiveContains("full OCR") ||
            job.filterSnapshot.localizedCaseInsensitiveContains("smart full")

        return invalidLimit || invalidEmptyJob || staleFullOCRText
    }

    private func activeInProgressIdentifiers() -> Set<String> {
        guard currentJob?.state.isActive == true else {
            return []
        }

        return Set(items.filter { item in
            item.state == .pending || item.state == .processing
        }.map(\.assetIdentifier))
    }

    @discardableResult
    private func recoverStaleProcessingLocksIfNeeded() async -> Int {
        guard items.isEmpty == false else {
            return 0
        }

        let now = Date()
        let currentJobID = currentJob?.id
        let hasActiveJob = currentJob?.state.isActive == true
        var recovered = 0

        for index in items.indices where items[index].state == .processing {
            let isOrphan = currentJobID == nil || items[index].jobID != currentJobID
            let isInactiveJob = hasActiveJob == false
            let isOld = now.timeIntervalSince(items[index].updatedAt) > staleProcessingInterval
            guard isOrphan || isInactiveJob || isOld else {
                continue
            }

            items[index].state = .pending
            items[index].updatedAt = now
            recovered += 1
        }

        guard recovered > 0 else {
            return 0
        }

        if var job = currentJob, job.state == .running || job.state == .pausing || job.state == .cancelling {
            job.state = .pausedBackground
            job.pausedReason = "古い読取処理状態を復旧しました。続きから再開できます。"
            job.updatedAt = now
            currentJob = recalculated(job)
        }

        await saveSnapshot()
        return recovered
    }

    private func sourceRevision(for asset: PhotoAsset) -> String {
        [
            "\(asset.pixelWidth)x\(asset.pixelHeight)",
            asset.creationDate.map { String(Int($0.timeIntervalSince1970)) } ?? "date-none",
            "\(asset.mediaType.rawValue)",
            "\(asset.mediaSubtypes.rawValue)"
        ].joined(separator: ":")
    }

    private func sourceRevision(for record: PhotoIndexRecord) -> String {
        [
            "\(record.pixelWidth)x\(record.pixelHeight)",
            record.creationDate.map { String(Int($0.timeIntervalSince1970)) } ?? "date-none",
            "\(record.mediaTypeRawValue)",
            "\(record.mediaSubtypesRawValue)"
        ].joined(separator: ":")
    }

    private func publish(_ job: BatchOCRJob?, force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastPublishedAt) >= 1 else {
            return
        }

        lastPublishedAt = now
        currentJob = job
    }

    private func loadSnapshot() {
        let url = storeURL()
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let snapshot = try JSONDecoder().decode(BatchOCRJobSnapshot.self, from: data)
            currentJob = snapshot.job
            items = snapshot.items
            if var series = snapshot.series {
                series.autoContinueEnabled = isAutoContinueEnabled
                currentSeries = series
            } else {
                currentSeries = nil
            }
        } catch {
            errorMessage = "読取ジョブ状態を読み込めませんでした: \(error.localizedDescription)"
        }
    }

    private func normalizeInterruptedJob() {
        guard var job = currentJob else {
            return
        }

        guard job.state == .preparing || job.state == .running || job.state == .pausing || job.state == .cancelling else {
            return
        }

        for index in items.indices where items[index].state == .processing {
            items[index].state = .pending
            items[index].updatedAt = Date()
        }

        job.state = .pausedBackground
        job.pausedReason = "前回の読取処理が中断されました。続きから再開できます。"
        job.updatedAt = Date()
        currentJob = recalculated(job)
        if var series = currentSeries, series.autoContinueEnabled {
            series.state = .pausedDeviceCondition
            series.pausedReason = "前回の読取処理が中断されました。続きから再開できます。"
            series.updatedAt = Date()
            currentSeries = series
        }
        runTask = nil

        Task {
            await saveSnapshot()
        }
    }

    private func saveSnapshot() async {
        let url = storeURL()
        do {
            let directoryURL = url.deletingLastPathComponent()
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let snapshot = BatchOCRJobSnapshot(job: currentJob, items: items, series: currentSeries)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: [.atomic])
        } catch {
            errorMessage = "読取ジョブ状態を保存できませんでした: \(error.localizedDescription)"
        }
    }

    #if DEBUG
    private func saveValidationReport(_ report: BatchOCRP1ValidationReport) async {
        let url = validationReportURL()
        do {
            let directoryURL = url.deletingLastPathComponent()
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            try data.write(to: url, options: [.atomic])
        } catch {
            errorMessage = "BatchOCR P1検証結果を保存できませんでした: \(error.localizedDescription)"
        }
    }

    private func saveP2ValidationReport(_ report: BatchOCRP2ValidationReport) async {
        let url = p2ValidationReportURL()
        do {
            let directoryURL = url.deletingLastPathComponent()
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            try data.write(to: url, options: [.atomic])
        } catch {
            errorMessage = "BatchOCR P2検証結果を保存できませんでした: \(error.localizedDescription)"
        }
    }

    private func saveP3ValidationReport(_ report: BatchOCRP3ValidationReport) async {
        let url = p3ValidationReportURL()
        do {
            let directoryURL = url.deletingLastPathComponent()
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            try data.write(to: url, options: [.atomic])
        } catch {
            errorMessage = "BatchOCR P3検証結果を保存できませんでした: \(error.localizedDescription)"
        }
    }

    private func saveTargetSelectionValidationReport(_ report: BatchOCRTargetSelectionValidationReport) async {
        let url = targetSelectionValidationReportURL()
        do {
            let directoryURL = url.deletingLastPathComponent()
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            try data.write(to: url, options: [.atomic])
        } catch {
            errorMessage = "対象抽出検証結果を保存できませんでした: \(error.localizedDescription)"
        }
    }

    private func saveReadStateDiagnosticsReport(_ report: BatchOCRReadStateDiagnosticsReport) async {
        let url = readStateDiagnosticsReportURL()
        do {
            let directoryURL = url.deletingLastPathComponent()
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            try data.write(to: url, options: [.atomic])
        } catch {
            errorMessage = "読取状態診断結果を保存できませんでした: \(error.localizedDescription)"
        }
    }

    private func saveAutoContinueValidationReport(_ report: BatchOCRAutoContinueValidationReport) async {
        let url = autoContinueValidationReportURL()
        do {
            let directoryURL = url.deletingLastPathComponent()
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            try data.write(to: url, options: [.atomic])
        } catch {
            errorMessage = "自動継続検証結果を保存できませんでした: \(error.localizedDescription)"
        }
    }

    private func validationReportURL() -> URL {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? fileManager.temporaryDirectory
        return baseURL
            .appendingPathComponent("ShimaiBako", isDirectory: true)
            .appendingPathComponent(validationReportFileName)
    }

    private func p2ValidationReportURL() -> URL {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? fileManager.temporaryDirectory
        return baseURL
            .appendingPathComponent("ShimaiBako", isDirectory: true)
            .appendingPathComponent(p2ValidationReportFileName)
    }

    private func p3ValidationReportURL() -> URL {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? fileManager.temporaryDirectory
        return baseURL
            .appendingPathComponent("ShimaiBako", isDirectory: true)
            .appendingPathComponent(p3ValidationReportFileName)
    }

    private func targetSelectionValidationReportURL() -> URL {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? fileManager.temporaryDirectory
        return baseURL
            .appendingPathComponent("ShimaiBako", isDirectory: true)
            .appendingPathComponent(targetSelectionValidationReportFileName)
    }

    private func readStateDiagnosticsReportURL() -> URL {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? fileManager.temporaryDirectory
        return baseURL
            .appendingPathComponent("ShimaiBako", isDirectory: true)
            .appendingPathComponent(readStateDiagnosticsReportFileName)
    }

    private func autoContinueValidationReportURL() -> URL {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? fileManager.temporaryDirectory
        return baseURL
            .appendingPathComponent("ShimaiBako", isDirectory: true)
            .appendingPathComponent(autoContinueValidationReportFileName)
    }
    #endif

    private func storeURL() -> URL {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? fileManager.temporaryDirectory
        return baseURL
            .appendingPathComponent("ShimaiBako", isDirectory: true)
            .appendingPathComponent(fileName)
    }
}

private struct BatchOCRAutoContinueDeviceSnapshot {
    var thermalState: ProcessInfo.ThermalState
    var isLowPowerModeEnabled: Bool
    var availableCapacityBytes: Int64?
    var batteryLevel: Float
    var batteryState: UIDevice.BatteryState

    static let normal = BatchOCRAutoContinueDeviceSnapshot(
        thermalState: .nominal,
        isLowPowerModeEnabled: false,
        availableCapacityBytes: 4_000_000_000,
        batteryLevel: 0.8,
        batteryState: .charging
    )

    static let fair = BatchOCRAutoContinueDeviceSnapshot(
        thermalState: .fair,
        isLowPowerModeEnabled: false,
        availableCapacityBytes: 4_000_000_000,
        batteryLevel: 0.8,
        batteryState: .charging
    )

    static let serious = BatchOCRAutoContinueDeviceSnapshot(
        thermalState: .serious,
        isLowPowerModeEnabled: false,
        availableCapacityBytes: 4_000_000_000,
        batteryLevel: 0.8,
        batteryState: .charging
    )

    static let lowPower = BatchOCRAutoContinueDeviceSnapshot(
        thermalState: .nominal,
        isLowPowerModeEnabled: true,
        availableCapacityBytes: 4_000_000_000,
        batteryLevel: 0.8,
        batteryState: .charging
    )
}

private struct BatchOCRCandidateDescriptor {
    let assetIdentifier: String
    let sourceRevision: String
}

private struct BatchOCRTargetSelection {
    var candidates: [BatchOCRCandidateDescriptor]
    var diagnostics: BatchOCRTargetSelectionDiagnostics
}

private enum BatchOCRReadDecision {
    case target
    case searchDataOnlyTarget
    case staleCacheTarget
    case failedRetryableTarget
    case alreadyRead
    case completedNoText
    case inProgress
}

private struct BatchOCRReadEvidence {
    var assetIdentifier: String
    var ocrResult: OCRResultRecord?
    var indexStatus: OCRStatus?
    var indexText: String
    var indexHasOCRMetadata: Bool
    var indexExists: Bool
    var isServiceProcessing: Bool
    var isActiveInJob: Bool

    #if DEBUG
    static func completedText(_ identifier: String) -> BatchOCRReadEvidence {
        BatchOCRReadEvidence(
            assetIdentifier: identifier,
            ocrResult: OCRResultRecord(
                photoLocalIdentifier: identifier,
                ocrText: "検証用テキスト",
                ocrStatus: .completed,
                ocrLanguage: OCRConfiguration.recognitionLanguages.joined(separator: ","),
                processedAt: Date(),
                errorMessage: nil
            ),
            indexStatus: .completed,
            indexText: "検証用テキスト",
            indexHasOCRMetadata: true,
            indexExists: true,
            isServiceProcessing: false,
            isActiveInJob: false
        )
    }

    static func completedNoText(_ identifier: String) -> BatchOCRReadEvidence {
        BatchOCRReadEvidence(
            assetIdentifier: identifier,
            ocrResult: OCRResultRecord(
                photoLocalIdentifier: identifier,
                ocrText: "テキストは見つかりませんでした。",
                ocrStatus: .completed,
                ocrLanguage: OCRConfiguration.recognitionLanguages.joined(separator: ","),
                processedAt: Date(),
                errorMessage: nil
            ),
            indexStatus: .completed,
            indexText: "テキストは見つかりませんでした。",
            indexHasOCRMetadata: true,
            indexExists: true,
            isServiceProcessing: false,
            isActiveInJob: false
        )
    }

    static func staleCompleted(_ identifier: String) -> BatchOCRReadEvidence {
        BatchOCRReadEvidence(
            assetIdentifier: identifier,
            ocrResult: nil,
            indexStatus: .completed,
            indexText: "",
            indexHasOCRMetadata: false,
            indexExists: true,
            isServiceProcessing: false,
            isActiveInJob: false
        )
    }

    static func searchDataOnly(_ identifier: String) -> BatchOCRReadEvidence {
        BatchOCRReadEvidence(
            assetIdentifier: identifier,
            ocrResult: nil,
            indexStatus: .unprocessed,
            indexText: "",
            indexHasOCRMetadata: false,
            indexExists: true,
            isServiceProcessing: false,
            isActiveInJob: false
        )
    }
    #endif
}

private extension PhotoIndexRecord {
    var hasOCRMetadata: Bool {
        ocrProcessedAt != nil ||
            ocrLanguage != nil ||
            ocrErrorMessage != nil
    }
}
