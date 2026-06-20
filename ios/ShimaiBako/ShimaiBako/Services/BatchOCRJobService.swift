import Combine
import Foundation
import Photos

@MainActor
final class BatchOCRJobService: ObservableObject {
    @Published private(set) var currentJob: BatchOCRJob?
    @Published private(set) var items: [BatchOCRItem] = []
    @Published private(set) var message: String?
    @Published private(set) var latestTargetDiagnostics: BatchOCRTargetSelectionDiagnostics?
    @Published var errorMessage: String?
    #if DEBUG
    @Published private(set) var p1ValidationReport: BatchOCRP1ValidationReport?
    @Published private(set) var p2ValidationReport: BatchOCRP2ValidationReport?
    @Published private(set) var p3ValidationReport: BatchOCRP3ValidationReport?
    @Published private(set) var targetSelectionValidationReport: BatchOCRTargetSelectionValidationReport?
    @Published private(set) var readStateDiagnosticsReport: BatchOCRReadStateDiagnosticsReport?
    @Published private(set) var isRunningP1Validation = false
    @Published private(set) var isRunningP2Validation = false
    @Published private(set) var isRunningP3Validation = false
    @Published private(set) var isRunningTargetSelectionValidation = false
    @Published private(set) var isRunningReadStateDiagnostics = false
    #endif

    private let fileManager: FileManager
    private let fileName = "batch_ocr_jobs.json"
    private let allowedRequestedLimits = [20, 50, 100, 500, 2_000]
    #if DEBUG
    private let validationReportFileName = "batch_ocr_p1_validation_report.json"
    private let p2ValidationReportFileName = "batch_ocr_p2_validation_report.json"
    private let p3ValidationReportFileName = "batch_ocr_p3_validation_report.json"
    private let targetSelectionValidationReportFileName = "batch_ocr_target_selection_validation_report.json"
    private let readStateDiagnosticsReportFileName = "batch_ocr_read_state_diagnostics_report.json"
    #endif
    private var runTask: Task<Void, Never>?
    private var lastPublishedAt = Date.distantPast
    private var pauseTargetState: BatchOCRJobState = .pausedBackground

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
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
            return false
        }

        return (job.state == .pausedBackground || job.state == .pausedUser)
            && items.contains { $0.state == .pending || $0.state == .failedRetryable }
    }

    var remainingCount: Int {
        guard let currentJob else {
            return 0
        }

        return max(currentJob.plannedCount - currentJob.processedCount, 0)
    }

    private var activeJobTargetCount: Int {
        items.filter { item in
            item.state == .pending || item.state == .processing
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
            assets: assets,
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
        let descriptors = selection.candidates.map { asset in
            BatchOCRCandidateDescriptor(
                assetIdentifier: asset.localIdentifier,
                sourceRevision: sourceRevision(for: asset)
            )
        }
        await createJob(
            jobID: jobID,
            requestedLimit: requestedLimit,
            candidateDescriptors: descriptors,
            filterSnapshot: "読取タブ: 読み込み済み写真から未読取候補を最大\(requestedLimit)件",
            createdAt: now
        )

        let assetByIdentifier = Dictionary(uniqueKeysWithValues: selection.candidates.map { ($0.localIdentifier, $0) })
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
            assets: assets,
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
                assets: assets,
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
            requestedLimit: max(assets.filter { $0.mediaType == .image }.count, 1),
            assets: assets,
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
            invalidOrStaleJobCount: invalidOrStaleJobCount,
            limitDiagnostics: limitDiagnostics
        )

        readStateDiagnosticsReport = report
        latestTargetDiagnostics = limitDiagnostics.first(where: { $0.selectedLimit == 500 })?.diagnostics ?? limitDiagnostics.last?.diagnostics
        message = "読取状態診断が完了しました。"
        await saveReadStateDiagnosticsReport(report)
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
        requestPause(targetState: .pausedBackground, reason: "アプリがバックグラウンドへ移行したため")
    }

    func pauseByUser() {
        requestPause(targetState: .pausedUser, reason: "ユーザー操作で一時停止しました。")
    }

    func resumePausedJob(
        assets: [PhotoAsset],
        photoLibrary: PhotoLibraryService,
        ocrService: OCRService,
        indexService: PhotoIndexService,
        deviceSafety: DeviceSafetyService? = nil
    ) async {
        guard let job = currentJob,
              (job.state == .pausedBackground || job.state == .pausedUser) else {
            message = "再開できる読取ジョブはありません。"
            return
        }

        let resumableItems = items.filter { $0.state == .pending || $0.state == .failedRetryable }
        guard resumableItems.isEmpty == false else {
            await finish(jobID: job.id)
            return
        }

        let assetByIdentifier = Dictionary(uniqueKeysWithValues: assets.map { ($0.localIdentifier, $0) })
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

            deviceSafety?.refresh()
            if let blockingReason = deviceSafety?.blockingReasonForLargeWork {
                await pause(jobID: jobID, reason: blockingReason, state: .pausedBackground)
                return
            }

            await Task.yield()
        }

        await finish(jobID: jobID)
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

    private func finish(jobID: String) async {
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
        assets: [PhotoAsset],
        ocrService: OCRService,
        indexService: PhotoIndexService
    ) async -> BatchOCRTargetSelection {
        let imageAssets = assets.filter { $0.mediaType == .image }
        let recordsByIdentifier = await indexService.recordsByLocalIdentifier(
            localIdentifiers: imageAssets.map(\.localIdentifier)
        )
        let activeIdentifiers = Set(items.filter { item in
            item.state == .pending || item.state == .processing
        }.map(\.assetIdentifier))
        let failedPermanentCount = items.filter { $0.state == .failedPermanent }.count

        var candidates: [PhotoAsset] = []
        candidates.reserveCapacity(min(requestedLimit, assets.count))
        var diagnostics = BatchOCRTargetSelectionDiagnostics.empty
        diagnostics.selectedLimit = requestedLimit
        diagnostics.failedPermanentCount = failedPermanentCount
        diagnostics.excludedFailedPermanent = failedPermanentCount

        for asset in imageAssets {
            diagnostics.candidateBeforeExclusion += 1
            let record = recordsByIdentifier[asset.localIdentifier]
            let evidence = BatchOCRReadEvidence(
                assetIdentifier: asset.localIdentifier,
                ocrResult: ocrService.result(for: asset),
                indexStatus: record?.ocrStatus,
                indexText: record?.ocrText ?? "",
                indexHasOCRMetadata: record?.hasOCRMetadata ?? false,
                indexExists: record != nil,
                isServiceProcessing: ocrService.isProcessing(asset),
                isActiveInJob: activeIdentifiers.contains(asset.localIdentifier)
            )
            let decision = readDecision(for: evidence)

            switch decision {
            case .target:
                appendCandidate(asset, to: &candidates, requestedLimit: requestedLimit)
            case .searchDataOnlyTarget:
                diagnostics.searchDataOnlyCandidateCount += 1
                appendCandidate(asset, to: &candidates, requestedLimit: requestedLimit)
            case .staleCacheTarget:
                diagnostics.staleCacheCandidateCount += 1
                appendCandidate(asset, to: &candidates, requestedLimit: requestedLimit)
            case .failedRetryableTarget:
                diagnostics.failedRetryableCount += 1
                appendCandidate(asset, to: &candidates, requestedLimit: requestedLimit)
            case .alreadyRead:
                diagnostics.excludedAlreadyRead += 1
            case .completedNoText:
                diagnostics.excludedCompletedNoText += 1
            case .inProgress:
                diagnostics.excludedInProgress += 1
            }
        }

        diagnostics.finalTargetCount = candidates.count
        diagnostics.reasonIfZero = reasonIfZero(for: diagnostics)

        return BatchOCRTargetSelection(candidates: candidates, diagnostics: diagnostics)
    }

    private func appendCandidate(_ asset: PhotoAsset, to candidates: inout [PhotoAsset], requestedLimit: Int) {
        guard candidates.count < requestedLimit else {
            return
        }

        candidates.append(asset)
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

    private func sourceRevision(for asset: PhotoAsset) -> String {
        [
            "\(asset.pixelWidth)x\(asset.pixelHeight)",
            asset.creationDate.map { String(Int($0.timeIntervalSince1970)) } ?? "date-none",
            "\(asset.mediaType.rawValue)",
            "\(asset.mediaSubtypes.rawValue)"
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
            let snapshot = BatchOCRJobSnapshot(job: currentJob, items: items)
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
    #endif

    private func storeURL() -> URL {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? fileManager.temporaryDirectory
        return baseURL
            .appendingPathComponent("ShimaiBako", isDirectory: true)
            .appendingPathComponent(fileName)
    }
}

private struct BatchOCRCandidateDescriptor {
    let assetIdentifier: String
    let sourceRevision: String
}

private struct BatchOCRTargetSelection {
    var candidates: [PhotoAsset]
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
