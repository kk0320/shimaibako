import Combine
import Foundation
import Photos
import UIKit

@MainActor
final class OCRJobRunner: ObservableObject {
    @Published private(set) var snapshot: OCRJobSnapshot = .empty
    @Published private(set) var isPreparingJob = false
    @Published var errorMessage: String?

    private let store: OCRJobStore
    private weak var photoLibrary: PhotoLibraryService?
    private weak var ocrService: OCRService?
    private weak var indexService: PhotoIndexService?
    private weak var deviceSafety: DeviceSafetyService?
    private var runTask: Task<Void, Never>?
    private var pauseRequestedReason: String?
    private var cancelRequested = false
    private var memoryWarningObserver: NSObjectProtocol?
    private var didReceiveMemoryWarning = false
    private var allowsNetworkAccessForCurrentRun = false
    private var lastSnapshotPublishedAt = Date.distantPast
    private let snapshotThrottleInterval: TimeInterval = 0.5

    init(
        store: OCRJobStore = OCRJobStore(),
        photoLibrary: PhotoLibraryService,
        ocrService: OCRService,
        indexService: PhotoIndexService,
        deviceSafety: DeviceSafetyService
    ) {
        self.store = store
        self.photoLibrary = photoLibrary
        self.ocrService = ocrService
        self.indexService = indexService
        self.deviceSafety = deviceSafety

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

    func prepare() async {
        do {
            try await store.recoverInterruptedItems()
            let job = try await store.activeJob()
            snapshot = OCRJobSnapshot(job: job, isRunning: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startJob(scope: OCRJobScope, qualityMode: OCRJobQualityMode, identifiers: [String], records: [PhotoIndexRecord]) async {
        guard isRunning == false else {
            errorMessage = "OCRジョブを実行中です。"
            return
        }

        isPreparingJob = true
        defer {
            isPreparingJob = false
        }

        let inputs = jobItemInputs(scope: scope, identifiers: identifiers, records: records)
        guard inputs.isEmpty == false else {
            errorMessage = "OCR対象がありません。OCR済み、文字なし判定済み、動画は対象から除外しています。"
            return
        }

        do {
            let job = try await store.createJob(scope: scope, qualityMode: qualityMode, items: inputs)
            snapshot = OCRJobSnapshot(job: job, isRunning: false)
            allowsNetworkAccessForCurrentRun = false
            resume()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func pause(reason: String = "ユーザー操作で一時停止しました") {
        guard snapshot.job?.state == .running || isRunning else {
            return
        }

        pauseRequestedReason = reason
        runTask?.cancel()
    }

    func resume(allowNetworkAccess: Bool = false) {
        guard let job = snapshot.job,
              job.state == .pending || job.state == .paused || job.state == .running,
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
                snapshot = OCRJobSnapshot(job: updatedJob, isRunning: false)
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
                snapshot = OCRJobSnapshot(job: updated, isRunning: false)
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
                snapshot = OCRJobSnapshot(job: updated, isRunning: false)
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

            while Task.isCancelled == false && cancelRequested == false {
                if let pauseReason = blockingPauseReason() ?? pauseRequestedReason {
                    let pausedJob = try await store.setJobState(.paused, jobID: jobID, pausedReason: pauseReason)
                    publish(job: pausedJob, force: true, isRunning: false)
                    runTask = nil
                    return
                }

                guard let item = try await store.pendingItem(jobID: jobID) else {
                    let completedJob = try await store.setJobState(.completed, jobID: jobID, pausedReason: nil)
                    publish(job: completedJob, force: true, isRunning: false)
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
                let pausedJob = try await store.setJobState(.paused, jobID: jobID, pausedReason: pauseRequestedReason)
                publish(job: pausedJob, force: true, isRunning: false)
            } else if cancelRequested {
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

        try await store.startItem(item, state: .fetchingImage)
        guard let asset = photoLibrary.asset(for: item.assetIdentifier) else {
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
            try await store.startItem(item, state: .recognizing)
            let result = await ocrService.recognize(asset: asset, image: image)
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
        let now = Date()
        guard force || now.timeIntervalSince(lastSnapshotPublishedAt) > snapshotThrottleInterval else {
            return
        }

        lastSnapshotPublishedAt = now
        snapshot = OCRJobSnapshot(job: job, isRunning: isRunning)
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

        if let blockingReason = deviceSafety.blockingReasonForLargeWork {
            return blockingReason
        }

        return nil
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
        let job = try await store.setJobState(.running, jobID: jobID, pausedReason: message)
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
}
