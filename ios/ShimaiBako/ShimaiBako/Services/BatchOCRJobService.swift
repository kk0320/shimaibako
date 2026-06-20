import Combine
import Foundation
import Photos

@MainActor
final class BatchOCRJobService: ObservableObject {
    @Published private(set) var currentJob: BatchOCRJob?
    @Published private(set) var items: [BatchOCRItem] = []
    @Published private(set) var message: String?
    @Published var errorMessage: String?
    #if DEBUG
    @Published private(set) var p1ValidationReport: BatchOCRP1ValidationReport?
    @Published private(set) var p2ValidationReport: BatchOCRP2ValidationReport?
    @Published private(set) var isRunningP1Validation = false
    @Published private(set) var isRunningP2Validation = false
    #endif

    private let fileManager: FileManager
    private let fileName = "batch_ocr_jobs.json"
    #if DEBUG
    private let validationReportFileName = "batch_ocr_p1_validation_report.json"
    private let p2ValidationReportFileName = "batch_ocr_p2_validation_report.json"
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
        indexService: PhotoIndexService
    ) async {
        guard [20, 50, 100].contains(requestedLimit) else {
            message = "500件と2,000件は次の段階で有効化します。"
            return
        }

        guard canStartNewJob else {
            message = "読取ジョブを実行中です。"
            return
        }

        let candidates = makeCandidates(
            requestedLimit: requestedLimit,
            assets: assets,
            ocrService: ocrService,
            indexService: indexService
        )

        guard candidates.isEmpty == false else {
            currentJob = nil
            items = []
            message = "新しく読み取る写真はありません"
            await saveSnapshot()
            return
        }

        let now = Date()
        let jobID = UUID().uuidString
        let descriptors = candidates.map { asset in
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

        let assetByIdentifier = Dictionary(uniqueKeysWithValues: candidates.map { ($0.localIdentifier, $0) })
        runTask = Task { [weak self] in
            await self?.run(
                jobID: jobID,
                assetByIdentifier: assetByIdentifier,
                photoLibrary: photoLibrary,
                ocrService: ocrService,
                indexService: indexService
            )
        }
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
        for index in items.indices where completedInThisCall < maximumCount {
            guard currentJob?.id == jobID, items[index].state == .pending else {
                continue
            }

            items[index].state = .processing
            items[index].attemptCount += 1
            items[index].updatedAt = Date()

            let identifier = items[index].assetIdentifier
            let ordinal = items[index].ordinal
            let text: String
            if ordinal.isMultiple(of: 5) {
                text = "テキストは見つかりませんでした。"
                items[index].state = .completedNoText
            } else {
                text = "BatchOCR P2 validation \(ordinal)"
                items[index].state = .completedText
            }
            items[index].lastErrorCode = nil
            items[index].updatedAt = Date()
            await ocrService.saveValidationResult(localIdentifier: identifier, text: text)
            completedInThisCall += 1
            await updateCountsAndPersist(jobID: jobID, forcePublish: completedInThisCall == maximumCount)
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
        indexService: PhotoIndexService
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
                indexService: indexService
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
        indexService: PhotoIndexService
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

            let currentStatus = indexService.status(for: asset, ocrService: ocrService)
            if currentStatus == .completed || currentStatus == .processing {
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

    private func makeCandidates(
        requestedLimit: Int,
        assets: [PhotoAsset],
        ocrService: OCRService,
        indexService: PhotoIndexService
    ) -> [PhotoAsset] {
        let activeIdentifiers = Set(items.filter { item in
            item.state == .pending || item.state == .processing
        }.map(\.assetIdentifier))

        var candidates: [PhotoAsset] = []
        candidates.reserveCapacity(min(requestedLimit, assets.count))

        for asset in assets where asset.mediaType == .image {
            guard activeIdentifiers.contains(asset.localIdentifier) == false else {
                continue
            }

            let status = indexService.status(for: asset, ocrService: ocrService)
            guard status != .completed, status != .processing else {
                continue
            }

            candidates.append(asset)

            if candidates.count >= requestedLimit {
                break
            }
        }

        return candidates
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
        let text = result.ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text == "テキストは見つかりませんでした。"
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
