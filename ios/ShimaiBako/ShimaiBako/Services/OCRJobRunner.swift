import Combine
import Foundation
import Photos
import UIKit

@MainActor
final class OCRJobRunner: ObservableObject {
    @Published private(set) var snapshot: OCRJobSnapshot = .empty
    @Published private(set) var isPreparingJob = false
    @Published private(set) var startDiagnostics: FullOCRStartDiagnostics = .empty
    @Published var errorMessage: String?
    let progressStore: OCRProgressStore

    private let store: OCRJobStore
    private weak var photoLibrary: PhotoLibraryService?
    private weak var ocrService: OCRService?
    private weak var indexService: PhotoIndexService?
    private weak var deviceSafety: DeviceSafetyService?
    private var runTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var pauseRequestedReason: String?
    private var cancelRequested = false
    private var memoryWarningObserver: NSObjectProtocol?
    private var didReceiveMemoryWarning = false
    private var allowsNetworkAccessForCurrentRun = false
    private var lastSnapshotPublishedAt = Date.distantPast
    private let snapshotThrottleInterval: TimeInterval = 0.5
    private var currentPhase: OCRCurrentPhase = .selectingTargets
    private var currentAssetIdentifier: String?
    private var activeTraceID: String?

    init(
        store: OCRJobStore = OCRJobStore(),
        photoLibrary: PhotoLibraryService,
        ocrService: OCRService,
        indexService: PhotoIndexService,
        deviceSafety: DeviceSafetyService,
        progressStore: OCRProgressStore
    ) {
        self.store = store
        self.photoLibrary = photoLibrary
        self.ocrService = ocrService
        self.indexService = indexService
        self.deviceSafety = deviceSafety
        self.progressStore = progressStore

        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.didReceiveMemoryWarning = true
                self?.pause(reason: "メモリ負荷が高いため一時停止しました")
            }
        }

        Task {
            await prepare()
        }
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    var isRunning: Bool {
        snapshot.isRunning
    }

    var activeJob: OCRJob? {
        snapshot.job
    }

    #if DEBUG
    var coordinatorDebugIdentifier: String {
        String(ObjectIdentifier(self).hashValue)
    }

    var repositoryDebugIdentifier: String {
        store.debugIdentifier
    }

    var persistentStorePath: String {
        store.persistentStorePath
    }
    #endif

    private var debugCoordinatorID: String {
        #if DEBUG
        coordinatorDebugIdentifier
        #else
        "-"
        #endif
    }

    private var debugProgressStoreID: String {
        #if DEBUG
        progressStore.debugIdentifier
        #else
        "-"
        #endif
    }

    private var debugRepositoryID: String {
        #if DEBUG
        repositoryDebugIdentifier
        #else
        "-"
        #endif
    }

    private var debugPersistentStoreURL: String {
        #if DEBUG
        persistentStorePath
        #else
        "-"
        #endif
    }

    func startJob(plan: OCRExecutionPlan) async -> FullOCRStartResult {
        let traceID = Self.shortTraceID()
        updateStartDiagnostics {
            $0.lastStartTappedAt = Date()
            $0.lastStartPlan = plan.debugKind
            $0.lastStartResult = "starting"
            $0.lastCreatedJobID = nil
            $0.lastPersistedJobID = nil
            $0.lastTerminalState = nil
            $0.lastError = nil
            $0.lastWorkerStartAt = nil
        }
        trace(traceID, "tapped", "plan=\(plan.debugKind)")
        trace(
            traceID,
            "coordinatorReceived",
            "plan=\(plan.debugKind) coordinatorID=\(debugCoordinatorID) progressStoreID=\(debugProgressStoreID) repositoryID=\(debugRepositoryID) persistentStoreURL=\(debugPersistentStoreURL)"
        )

        guard plan.isQuick == false else {
            return blockedStart("クイックOCRはまとめてOCRの経路で実行してください。", traceID: traceID)
        }

        guard isRunning == false,
              isPreparingJob == false,
              snapshot.job?.state.isActive != true else {
            return blockedStart("OCRジョブを実行中です。", traceID: traceID)
        }

        do {
            if let existingJob = try await store.activeJob(),
               existingJob.state.isActive {
                return blockedStart("未完了の全数OCRジョブがあります。管理メニューから再開または終了してください。", traceID: traceID)
            }
        } catch {
            return failedStart("OCRジョブDBを確認できませんでした: \(error.localizedDescription)", traceID: traceID)
        }

        if let deviceSafety {
            deviceSafety.refresh()
            if let blockingReason = deviceSafety.blockingReason(for: plan.workloadClass) {
                return blockedStart(blockingReason, traceID: traceID)
            }
        }

        #if DEBUG
        logPlan(plan, jobType: "persistent")
        #endif

        isPreparingJob = true

        do {
            let preparingJob = try await store.createPreparingJob(scope: plan.jobScope, qualityMode: plan.qualityMode)
            updateStartDiagnostics {
                $0.lastCreatedJobID = preparingJob.id
            }
            trace(traceID, "jobInserted", "jobID=\(preparingJob.id)")
            trace(traceID, "contextSaved", "jobID=\(preparingJob.id)")

            guard let verifiedJob = try await store.job(id: preparingJob.id) else {
                isPreparingJob = false
                return failedStart("OCRジョブを保存できませんでした。", traceID: traceID)
            }
            guard verifiedJob.state == .preparing else {
                isPreparingJob = false
                return failedStart("OCRジョブの保存状態を確認できませんでした。", traceID: traceID)
            }

            let activeJob = try await store.activeJob()
            guard activeJob?.id == verifiedJob.id else {
                isPreparingJob = false
                let activeID = activeJob?.id ?? "none"
                return failedStart("OCRジョブをactive状態として確認できませんでした。active=\(activeID)", traceID: traceID)
            }

            updateStartDiagnostics {
                $0.lastPersistedJobID = verifiedJob.id
                $0.lastStartResult = "started"
            }
            trace(traceID, "jobVerified", "jobID=\(verifiedJob.id) state=\(verifiedJob.state.rawValue) active=true")
            publish(job: verifiedJob, force: true, isRunning: false)
            trace(traceID, "snapshotPublished", "state=\(verifiedJob.state.rawValue) activeSnapshot=\(progressStore.activeSnapshot != nil)")
            #if DEBUG
            print("OCR_START plan=\(plan.debugKind) jobCreated=true snapshotPublished=\(progressStore.activeSnapshot != nil) store=\(progressStore.debugIdentifier) coordinator=\(coordinatorDebugIdentifier) repository=\(repositoryDebugIdentifier)")
            #endif

            await Task.yield()
            activeTraceID = traceID
            Task { [weak self] in
                await self?.preparePersistentJobItems(plan: plan, jobID: verifiedJob.id, traceID: traceID)
            }
            guard let uuid = UUID(uuidString: verifiedJob.id) else {
                return .started(jobID: UUID())
            }
            return .started(jobID: uuid)
        } catch {
            isPreparingJob = false
            return failedStart(error.localizedDescription, traceID: traceID)
        }
    }

    private func preparePersistentJobItems(plan: OCRExecutionPlan, jobID: String, traceID: String) async {
        updateStartDiagnostics {
            $0.lastWorkerStartAt = Date()
        }
        trace(traceID, "workerStarted", "jobID=\(jobID)")

        do {
            guard let indexService else {
                let failedJob = try await store.setJobState(
                    .failed,
                    jobID: jobID,
                    pausedReason: "検索インデックスを確認できませんでした。"
                )
                updateStartDiagnostics {
                    $0.lastStartResult = "failed"
                    $0.lastTerminalState = failedJob?.state.rawValue ?? "failed"
                    $0.lastError = "検索インデックスを確認できませんでした。"
                }
                publish(job: failedJob, force: true, isRunning: false)
                errorMessage = "検索インデックスを確認できませんでした。"
                isPreparingJob = false
                trace(traceID, "workerFailed", "message=missingIndexService")
                return
            }

            let request = pageRequest(for: plan)
            let identifiers = await indexService.localIdentifiersForOCRJob(matching: request)
            let records = await indexService.recordsForOCRJob(localIdentifiers: identifiers)
            let inputs = jobItemInputs(scope: plan.jobScope, identifiers: identifiers, records: records)
            guard inputs.isEmpty == false else {
                let message = "OCR対象がありません。OCR済み、文字なし判定済み、動画は対象から除外しています。"
                let failedJob = try await store.setJobState(
                    .failed,
                    jobID: jobID,
                    pausedReason: message
                )
                updateStartDiagnostics {
                    $0.lastStartResult = "failed"
                    $0.lastTerminalState = failedJob?.state.rawValue ?? "failed"
                    $0.lastError = message
                }
                publish(job: failedJob, force: true, isRunning: false)
                errorMessage = message
                isPreparingJob = false
                trace(traceID, "workerFailed", "message=noTargets")
                return
            }

            let job = try await store.replaceItems(jobID: jobID, items: inputs)
            publish(job: job, force: true, isRunning: false)
            trace(traceID, "itemsPrepared", "jobID=\(jobID) itemCount=\(inputs.count)")
            allowsNetworkAccessForCurrentRun = false
            isPreparingJob = false
            resume()
        } catch {
            isPreparingJob = false
            let failedJob = try? await store.setJobState(.failed, jobID: jobID, pausedReason: error.localizedDescription)
            publish(job: failedJob ?? snapshot.job, force: true, isRunning: false)
            updateStartDiagnostics {
                $0.lastStartResult = "failed"
                $0.lastTerminalState = failedJob?.state.rawValue ?? "failed"
                $0.lastError = error.localizedDescription
            }
            errorMessage = error.localizedDescription
            trace(traceID, "workerFailed", "message=\(error.localizedDescription)")
        }
    }

    private func updateStartDiagnostics(_ update: (inout FullOCRStartDiagnostics) -> Void) {
        var next = startDiagnostics
        update(&next)
        startDiagnostics = next
    }

    private func blockedStart(_ message: String, traceID: String) -> FullOCRStartResult {
        errorMessage = message
        updateStartDiagnostics {
            $0.lastStartResult = "blocked"
            $0.lastError = message
        }
        trace(traceID, "blocked", "message=\(message)")
        return .blocked(message: message)
    }

    private func failedStart(_ message: String, traceID: String) -> FullOCRStartResult {
        errorMessage = message
        updateStartDiagnostics {
            $0.lastStartResult = "failed"
            $0.lastTerminalState = "failed"
            $0.lastError = message
        }
        trace(traceID, "failed", "message=\(message)")
        return .failed(message: message)
    }

    func prepare() async {
        do {
            try await store.recoverInterruptedItems()
            let job = try await store.activeJob()
            publish(job: job, force: true, isRunning: false)
            #if DEBUG
            let state = job?.state.rawValue ?? "none"
            print("OCR_PROGRESS_STORE restore activeJob=\(job != nil) state=\(state) snapshotCreated=\(progressStore.activeSnapshot != nil) store=\(progressStore.debugIdentifier)")
            #endif
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startJob(scope: OCRJobScope, qualityMode: OCRJobQualityMode, identifiers: [String], records: [PhotoIndexRecord]) async {
        await startJob(scope: scope, qualityMode: qualityMode, identifiers: identifiers, records: records, managesPreparingState: true)
    }

    private func startJob(
        scope: OCRJobScope,
        qualityMode: OCRJobQualityMode,
        identifiers: [String],
        records: [PhotoIndexRecord],
        managesPreparingState: Bool
    ) async {
        guard isRunning == false else {
            errorMessage = "OCRジョブを実行中です。"
            return
        }

        if managesPreparingState {
            isPreparingJob = true
        }
        defer {
            if managesPreparingState {
                isPreparingJob = false
            }
        }

        let inputs = jobItemInputs(scope: scope, identifiers: identifiers, records: records)
        guard inputs.isEmpty == false else {
            errorMessage = "OCR対象がありません。OCR済み、文字なし判定済み、動画は対象から除外しています。"
            return
        }

        do {
            let job = try await store.createJob(scope: scope, qualityMode: qualityMode, items: inputs)
            publish(job: job, force: true, isRunning: false)
            allowsNetworkAccessForCurrentRun = false
            resume()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func pageRequest(for plan: OCRExecutionPlan) -> PhotoIndexPageRequest {
        switch plan {
        case .quick(let filter, let limit):
            filter.pageRequest(limit: limit.rawValue)
        case .filteredAll(let filter):
            filter.pageRequest(limit: 100_000)
        case .smartLibrary, .accuracyReview:
            PhotoIndexPageRequest(
                query: "",
                displayState: .active,
                includeUnwantedWhenActive: false,
                category: .all,
                screenshotSubcategory: .all,
                limit: 100_000,
                offset: 0
            )
        }
    }

    #if DEBUG
    private func logPlan(_ plan: OCRExecutionPlan, jobType: String) {
        let thermal = deviceSafety?.thermalStateTitle ?? "unknown"
        print("OCR_PLAN kind=\(plan.debugKind) workloadClass=\(plan.workloadClass) thermalState=\(thermal) jobType=\(jobType)")
    }
    #endif

    func pause(reason: String = "ユーザー操作で一時停止しました") {
        guard snapshot.job?.state == .running || isRunning else {
            return
        }

        pauseRequestedReason = reason
        runTask?.cancel()
    }

    func resume(allowNetworkAccess: Bool = false) {
        guard let job = snapshot.job,
              job.state == .pending ||
              job.state == .paused ||
              job.state == .pausedThermal ||
              job.state == .pausedUser ||
              job.state == .running ||
              job.state == .throttled,
              runTask == nil else {
            return
        }

        allowsNetworkAccessForCurrentRun = allowNetworkAccess
        cancelRequested = false
        pauseRequestedReason = nil
        didReceiveMemoryWarning = false
        runTask = Task { [weak self] in
            await self?.run(jobID: job.id)
        }
    }

    func cancel() {
        guard let job = snapshot.job else {
            return
        }

        cancelRequested = true
        runTask?.cancel()

        Task {
            do {
                let updatedJob = try await store.cancelJob(jobID: job.id)
                publish(job: updatedJob, force: true, isRunning: false)
                runTask = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func retryFailures() {
        guard let job = snapshot.job,
              isRunning == false else {
            return
        }

        Task {
            do {
                let updated = try await store.retryFailures(jobID: job.id)
                publish(job: updated, force: true, isRunning: false)
                resume()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func resumeCloudPendingWithNetworkAccess() {
        guard let job = snapshot.job,
              job.cloudPendingCount > 0,
              isRunning == false else {
            return
        }

        Task {
            do {
                let updated = try await store.retryCloudPending(jobID: job.id)
                publish(job: updated, force: true, isRunning: false)
                resume(allowNetworkAccess: true)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func applicationDidEnterBackground() {
        pause(reason: "アプリの状態変化により一時停止しました")
    }

    private func run(jobID: String) async {
        do {
            let runningJob = try await store.setJobState(.running, jobID: jobID, pausedReason: nil)
            publish(job: runningJob, force: true, isRunning: true)
            startHeartbeat(jobID: jobID)

            while Task.isCancelled == false && cancelRequested == false {
                if let pauseReason = blockingPauseReason() ?? pauseRequestedReason {
                    let pausedState: OCRJobState = pauseReason == pauseRequestedReason ? .pausedUser : .pausedThermal
                    let pausedJob = try await store.updateHeartbeat(
                        jobID: jobID,
                        phase: pauseReason == pauseRequestedReason ? currentPhase : .waitingForTemperature,
                        assetIdentifier: currentAssetIdentifier,
                        state: pausedState,
                        pausedReason: pauseReason
                    )
                    publish(job: pausedJob, force: true, isRunning: false)
                    stopHeartbeat()
                    runTask = nil
                    return
                }

                guard let item = try await store.pendingItem(jobID: jobID) else {
                    let completedJob = try await store.setJobState(.completed, jobID: jobID, pausedReason: nil)
                    publish(job: completedJob, force: true, isRunning: false)
                    stopHeartbeat()
                    runTask = nil
                    return
                }

                try await process(item: item)
                if let updatedJob = try await store.job(id: jobID) {
                    publish(job: updatedJob, force: false, isRunning: true)
                }
                try await applyThermalBackoffIfNeeded(jobID: jobID)
                await Task.yield()
            }

            if let pauseRequestedReason {
                let pausedJob = try await store.updateHeartbeat(
                    jobID: jobID,
                    phase: currentPhase,
                    assetIdentifier: currentAssetIdentifier,
                    state: .pausedUser,
                    pausedReason: pauseRequestedReason
                )
                publish(job: pausedJob, force: true, isRunning: false)
            } else if cancelRequested {
                let cancellingJob = try? await store.setJobState(.cancelling, jobID: jobID, pausedReason: "終了処理中です。")
                publish(job: cancellingJob, force: true, isRunning: false)
                let cancelledJob = try await store.cancelJob(jobID: jobID)
                publish(job: cancelledJob, force: true, isRunning: false)
            } else {
                let pausedJob = try await store.setJobState(
                    .paused,
                    jobID: jobID,
                    pausedReason: "読み込みタスクが中断されました。続きから再開できます。"
                )
                publish(job: pausedJob, force: true, isRunning: false)
            }
        } catch {
            errorMessage = error.localizedDescription
            if let job = snapshot.job {
                let failedJob = try? await store.setJobState(.failed, jobID: job.id, pausedReason: error.localizedDescription)
                publish(job: failedJob ?? job, force: true, isRunning: false)
            }
        }

        stopHeartbeat()
        runTask = nil
    }

    private func process(item: OCRJobItem) async throws {
        guard let photoLibrary,
              let ocrService,
              let indexService else {
            _ = try await store.finishItem(
                jobID: item.jobID,
                assetIdentifier: item.assetIdentifier,
                state: .retryableFailure,
                errorCode: "内部サービスを参照できませんでした。"
            )
            return
        }

        try await setPhase(.requestingImage, jobID: item.jobID, assetIdentifier: item.assetIdentifier)
        try await store.startItem(item, state: .fetchingImage)
        guard let asset = photoLibrary.asset(for: item.assetIdentifier) else {
            try await setPhase(.savingResult, jobID: item.jobID, assetIdentifier: item.assetIdentifier)
            _ = try await store.finishItem(
                jobID: item.jobID,
                assetIdentifier: item.assetIdentifier,
                state: .skipped,
                errorCode: "写真を参照できませんでした。"
            )
            return
        }

        guard asset.mediaType == .image else {
            await ocrService.markSkipped(asset: asset, message: "動画はOCR対象外です。")
            try await setPhase(.savingResult, jobID: item.jobID, assetIdentifier: item.assetIdentifier)
            await indexService.persistOCRJobResult(for: asset, ocrService: ocrService)
            _ = try await store.finishItem(
                jobID: item.jobID,
                assetIdentifier: item.assetIdentifier,
                state: .skipped,
                errorCode: nil
            )
            return
        }

        if ocrService.status(for: asset).isOCRTerminal {
            try await setPhase(.savingResult, jobID: item.jobID, assetIdentifier: item.assetIdentifier)
            _ = try await store.finishItem(
                jobID: item.jobID,
                assetIdentifier: item.assetIdentifier,
                state: .skipped,
                errorCode: "OCR済みまたは文字なし判定済みです。"
            )
            return
        }

        switch await photoLibrary.requestOCRImage(for: asset, allowsNetworkAccess: allowsNetworkAccessForCurrentRun) {
        case .image(let image):
            try await setPhase(.recognizingText, jobID: item.jobID, assetIdentifier: item.assetIdentifier)
            try await store.startItem(item, state: .recognizing)
            let result = await ocrService.recognize(asset: asset, image: image)
            try await setPhase(.savingResult, jobID: item.jobID, assetIdentifier: item.assetIdentifier)
            await indexService.persistOCRJobResult(for: asset, ocrService: ocrService)
            let itemState = itemState(for: result, attemptCount: item.attemptCount + 1)
            try await store.upsertResult(persistentResult(for: asset, result: result, itemState: itemState, fingerprint: item.sourceFingerprint))
            _ = try await store.finishItem(
                jobID: item.jobID,
                assetIdentifier: item.assetIdentifier,
                state: itemState,
                errorCode: result?.errorMessage
            )
        case .cloudPending:
            try await setPhase(.waitingForICloud, jobID: item.jobID, assetIdentifier: item.assetIdentifier)
            let result = await ocrService.markCloudPending(
                asset: asset,
                message: "iCloud上の写真です。iCloud取得を許可すると再試行できます。"
            )
            await indexService.persistOCRJobResult(for: asset, ocrService: ocrService)
            try await store.upsertResult(persistentResult(for: asset, result: result, itemState: .cloudPending, fingerprint: item.sourceFingerprint))
            _ = try await store.finishItem(
                jobID: item.jobID,
                assetIdentifier: item.assetIdentifier,
                state: .cloudPending,
                errorCode: "iCloud上の写真です。"
            )
        case .failed(let message):
            try await setPhase(.savingResult, jobID: item.jobID, assetIdentifier: item.assetIdentifier)
            let result = await ocrService.markFailure(asset: asset, message: message)
            await indexService.persistOCRJobResult(for: asset, ocrService: ocrService)
            let state: OCRJobItemState = item.attemptCount >= 1 ? .permanentFailure : .retryableFailure
            try await store.upsertResult(persistentResult(for: asset, result: result, itemState: state, fingerprint: item.sourceFingerprint))
            _ = try await store.finishItem(
                jobID: item.jobID,
                assetIdentifier: item.assetIdentifier,
                state: state,
                errorCode: message
            )
        }
    }

    private func publish(job: OCRJob?, force: Bool, isRunning: Bool) {
        progressStore.publish(job: job, isRunning: isRunning, force: force)

        let shouldPublishRunnerSnapshot = force ||
            snapshot.job?.id != job?.id ||
            snapshot.job?.state != job?.state ||
            snapshot.job?.pausedReason != job?.pausedReason ||
            snapshot.isRunning != isRunning
        guard shouldPublishRunnerSnapshot else {
            return
        }

        lastSnapshotPublishedAt = Date()
        snapshot = OCRJobSnapshot(job: job, isRunning: isRunning)
        if let job,
           job.state.isActive == false {
            updateStartDiagnostics {
                $0.lastTerminalState = job.state.rawValue
            }
            if job.state == .failed {
                updateStartDiagnostics {
                    $0.lastStartResult = "failed"
                    $0.lastError = job.pausedReason
                }
            }
        }

        #if DEBUG
        if let job {
            let phase = job.currentPhase?.rawValue ?? "none"
            let heartbeat = ISO8601DateFormatter().string(from: job.lastHeartbeatAt)
            print("OCR_JOB state=\(job.state.rawValue) completed=\(job.completedCount) total=\(job.totalCount) phase=\(phase) heartbeat=\(heartbeat) failed=\(job.failedCount) skipped=\(job.skippedCount) cloudPending=\(job.cloudPendingCount)")
        }
        #endif
    }

    private func setPhase(_ phase: OCRCurrentPhase, jobID: String, assetIdentifier: String?) async throws {
        currentPhase = phase
        currentAssetIdentifier = assetIdentifier
        let job = try await store.updateHeartbeat(jobID: jobID, phase: phase, assetIdentifier: assetIdentifier)
        publish(job: job, force: false, isRunning: true)
    }

    private func startHeartbeat(jobID: String) {
        stopHeartbeat()
        currentPhase = snapshot.job?.currentPhase ?? .selectingTargets
        currentAssetIdentifier = snapshot.job?.currentAssetIdentifier
        heartbeatTask = Task { [weak self] in
            while Task.isCancelled == false {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard Task.isCancelled == false else {
                    return
                }
                await self?.sendHeartbeat(jobID: jobID)
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private func sendHeartbeat(jobID: String) async {
        do {
            let job = try await store.updateHeartbeat(jobID: jobID, phase: currentPhase, assetIdentifier: currentAssetIdentifier)
            publish(job: job, force: false, isRunning: true)
            if let activeTraceID,
               let job {
                trace(activeTraceID, "heartbeat", "completed=\(job.completedCount) total=\(job.totalCount)")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func blockingPauseReason() -> String? {
        guard let deviceSafety else {
            return nil
        }

        deviceSafety.refresh()

        if didReceiveMemoryWarning {
            return "メモリ負荷が高いため一時停止しました"
        }

        if deviceSafety.isLowPowerModeEnabled {
            return "低電力モードのためOCRを一時停止しています"
        }

        if deviceSafety.thermalState == .critical {
            return "端末保護のためOCRを停止しました。続きから再開できます。"
        }

        if deviceSafety.thermalState == .serious {
            return "端末の温度が高いため一時停止しています。続きから再開できます。"
        }

        let workloadClass: OCRWorkloadClass = snapshot.job.map { workloadClassForScope($0.scope) } ?? .large
        if let blockingReason = deviceSafety.blockingReason(for: workloadClass) {
            return blockingReason
        }

        return nil
    }

    private func workloadClassForScope(_ scope: OCRJobScope) -> OCRWorkloadClass {
        switch scope {
        case .visibleLimit20:
            .small
        case .visibleLimit50, .visibleLimit100:
            .medium
        case .currentFilterAll:
            .large
        case .smartFull:
            .longRunning
        case .fullAccurate:
            .heavy
        }
    }

    private func applyThermalBackoffIfNeeded(jobID: String) async throws {
        guard let deviceSafety else {
            return
        }

        deviceSafety.refresh()
        guard deviceSafety.thermalState == .fair else {
            return
        }

        let message = "端末の温度を見ながらゆっくり処理しています"
        let job = try await store.updateHeartbeat(
            jobID: jobID,
            phase: .waitingForTemperature,
            assetIdentifier: currentAssetIdentifier,
            state: .throttled,
            pausedReason: message
        )
        publish(job: job, force: true, isRunning: true)

        let scope = job?.scope ?? snapshot.job?.scope
        let delay: UInt64 = scope == .fullAccurate ? 3_000_000_000 : 1_500_000_000
        try? await Task.sleep(nanoseconds: delay)
    }

    private func itemState(for result: OCRResultRecord?, attemptCount: Int) -> OCRJobItemState {
        guard let result else {
            return attemptCount > 1 ? .permanentFailure : .retryableFailure
        }

        switch result.ocrStatus {
        case .completed:
            return result.ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .completedNoText : .completedText
        case .completedNoText:
            return .completedNoText
        case .cloudPending:
            return .cloudPending
        case .skipped:
            return .skipped
        case .failed:
            return attemptCount > 1 ? .permanentFailure : .retryableFailure
        case .unprocessed, .processing:
            return .retryableFailure
        }
    }

    private func persistentResult(
        for asset: PhotoAsset,
        result: OCRResultRecord?,
        itemState: OCRJobItemState,
        fingerprint: String
    ) -> PersistentOCRResult {
        let rawText = result?.ocrText ?? ""
        return PersistentOCRResult(
            assetIdentifier: asset.localIdentifier,
            rawText: rawText,
            normalizedText: normalizedSearchText(rawText),
            resultState: itemState,
            engineVersion: "Vision",
            recognitionProfileVersion: OCRConfiguration.recognitionLanguageTitle,
            sourceFingerprint: fingerprint,
            updatedAt: Date()
        )
    }

    private func jobItemInputs(
        scope: OCRJobScope,
        identifiers: [String],
        records: [PhotoIndexRecord]
    ) -> [OCRJobItemInput] {
        let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.localIdentifier, $0) })
        var seen: Set<String> = []
        var inputs: [OCRJobItemInput] = []
        inputs.reserveCapacity(identifiers.count)

        for identifier in identifiers where seen.insert(identifier).inserted {
            guard let record = recordsByID[identifier],
                  record.mediaTypeRawValue == PHAssetMediaType.image.rawValue,
                  shouldInclude(record) else {
                continue
            }

            inputs.append(OCRJobItemInput(
                assetIdentifier: identifier,
                priority: priority(for: record, scope: scope),
                sourceFingerprint: sourceFingerprint(for: record)
            ))
        }

        return inputs.sorted {
            if $0.priority == $1.priority {
                return $0.assetIdentifier > $1.assetIdentifier
            }
            return $0.priority < $1.priority
        }
    }

    private func shouldInclude(_ record: PhotoIndexRecord) -> Bool {
        switch record.ocrStatus {
        case .completed, .completedNoText, .processing, .skipped:
            return false
        case .unprocessed, .cloudPending, .failed:
            return true
        }
    }

    private func priority(for record: PhotoIndexRecord, scope: OCRJobScope) -> Int {
        if scope == .currentFilterAll {
            return 500
        }

        if record.isScreenshot {
            return 100
        }

        switch record.inferredCategory {
        case .documentCandidate:
            return 200
        case .receiptCandidate:
            return 220
        case .businessCardCandidate:
            return 240
        case .whiteboardCandidate:
            return 260
        case .signboardCandidate:
            return 280
        case .constructionCandidate:
            return 320
        case .uncategorized:
            return 700
        default:
            return 800
        }
    }

    private func sourceFingerprint(for record: PhotoIndexRecord) -> String {
        let createdAt = record.creationDate?.timeIntervalSince1970 ?? 0
        return "\(record.pixelWidth)x\(record.pixelHeight)-\(Int(createdAt))-\(record.mediaSubtypesRawValue)"
    }

    private func normalizedSearchText(_ text: String) -> String {
        let widthAdjusted = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        let kanaAdjusted = widthAdjusted.applyingTransform(.hiraganaToKatakana, reverse: false) ?? widthAdjusted
        return kanaAdjusted
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "ja_JP"))
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func shortTraceID() -> String {
        String(UUID().uuidString.prefix(8))
    }

    private func trace(_ traceID: String, _ step: String, _ details: String = "") {
        #if DEBUG
        if details.isEmpty {
            print("FULL_OCR trace=\(traceID) step=\(step)")
        } else {
            print("FULL_OCR trace=\(traceID) step=\(step) \(details)")
        }
        #endif
    }
}
