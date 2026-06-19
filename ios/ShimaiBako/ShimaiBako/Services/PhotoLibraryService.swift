import Combine
import Foundation
import Photos
import PhotosUI
import UIKit

enum OCRImageRequestOutcome {
    case image(UIImage)
    case cloudPending
    case failed(String)
}

@MainActor
final class PhotoLibraryService: ObservableObject {
    @Published private(set) var authorizationStatus: PHAuthorizationStatus
    @Published private(set) var assets: [PhotoAsset] = []
    @Published private(set) var latestLoadedBatch: [PhotoAsset] = []
    @Published private(set) var readMode: PhotoReadMode
    @Published private(set) var iCloudMode: ICloudPhotoMode
    @Published private(set) var totalAssetCount = 0
    @Published private(set) var loadedAssetCount = 0
    @Published private(set) var isLoading = false
    @Published private(set) var importProgress: PhotoImportProgress
    @Published var errorMessage: String?

    private lazy var imageManager = PHCachingImageManager()
    private let userDefaults: UserDefaults
    private let assumesAuthorizedForDebugRun: Bool
    private let skipsPhotoKitReadsForDebugRun: Bool
    private let readModeKey = "shimaibako.photoReadMode"
    private let iCloudModeKey = "shimaibako.iCloudPhotoMode"
    private let importProgressKey = "shimaibako.photoImportProgress"
    private var loadGeneration = 0
    private var cancellationRequested = false
    private var importTask: Task<Void, Never>?
    private var backgroundTaskIdentifier: UIBackgroundTaskIdentifier = .invalid
    private var thumbnails: [String: UIImage] = [:]
    private var thumbnailRequests: [String: PHImageRequestID] = [:]
    private var memoryWarningObserver: NSObjectProtocol?
    private var memoryWarningCount = 0
    private let batchSize = 100
    private let firstPaintLimit = 200
    private let largeScaleRetainedAssetLimit = 500

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        #if DEBUG
        let launchArguments = ProcessInfo.processInfo.arguments
        assumesAuthorizedForDebugRun = launchArguments.contains("-ShimaiBakoAssumePhotosAuthorized")
        skipsPhotoKitReadsForDebugRun = launchArguments.contains("-ShimaiBakoSkipPhotoKitReads")
        #else
        assumesAuthorizedForDebugRun = false
        skipsPhotoKitReadsForDebugRun = false
        #endif

        let storedReadMode = userDefaults.string(forKey: readModeKey)
        let initialReadMode = storedReadMode.flatMap(PhotoReadMode.init(rawValue:)) ?? .light
        readMode = initialReadMode

        let storedICloudMode = userDefaults.string(forKey: iCloudModeKey)
        iCloudMode = storedICloudMode.flatMap(ICloudPhotoMode.init(rawValue:)) ?? .offlinePreferred

        importProgress = Self.loadImportProgress(from: userDefaults, key: importProgressKey, fallbackReadMode: initialReadMode)

        authorizationStatus = assumesAuthorizedForDebugRun ? .authorized : PHPhotoLibrary.authorizationStatus(for: .readWrite)

        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleMemoryWarning()
            }
        }

        recoverStaleImportIfNeeded()
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    var canReadPhotos: Bool {
        assumesAuthorizedForDebugRun || authorizationStatus == .authorized || authorizationStatus == .limited
    }

    var readLimitTitle: String {
        readMode.limitTitle
    }

    var loadingSummaryTitle: String {
        if totalAssetCount > 0 {
            return "\(loadedAssetCount) / \(totalAssetCount)件"
        }

        return "\(loadedAssetCount)件"
    }

    var hasRecoverableImportState: Bool {
        importProgress.phase == .stale || importProgress.phase == .failed || importProgress.phase == .paused || importProgress.phase == .cancelled
    }

    var importAppearsStalled: Bool {
        importProgress.isStale()
    }

    var shouldShowImportProgress: Bool {
        isLoading || hasRecoverableImportState
    }

    var shouldShowCompletedImportSummary: Bool {
        importProgress.phase == .completed && importProgress.readMode.isLargeScale
    }

    private var retainedAssetLimit: Int {
        if readMode.isLargeScale {
            return largeScaleRetainedAssetLimit
        }

        return readMode.limit ?? largeScaleRetainedAssetLimit
    }

    var statusTitle: String {
        switch authorizationStatus {
        case .notDetermined:
            "未確認"
        case .authorized:
            "すべての写真を読み取り可能"
        case .limited:
            "選択した写真のみ利用中"
        case .denied:
            "アクセスが拒否されています"
        case .restricted:
            "アクセスが制限されています"
        @unknown default:
            "不明"
        }
    }

    func prepare() async {
        refreshAuthorizationStatus()
        recoverStaleImportIfNeeded()
    }

    func refreshAuthorizationStatus() {
        guard assumesAuthorizedForDebugRun == false else {
            authorizationStatus = .authorized
            return
        }

        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func requestAuthorization() async {
        guard assumesAuthorizedForDebugRun == false else {
            authorizationStatus = .authorized
            return
        }

        let status = await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }

        authorizationStatus = status
    }

    func updateReadMode(_ nextMode: PhotoReadMode) async {
        readMode = nextMode
        userDefaults.set(nextMode.rawValue, forKey: readModeKey)
        if hasRecoverableImportState {
            resetLoadingState()
        }
        await loadRecentAssets()
    }

    func updateICloudMode(_ nextMode: ICloudPhotoMode) {
        iCloudMode = nextMode
        userDefaults.set(nextMode.rawValue, forKey: iCloudModeKey)
    }

    func assets(for localIdentifiers: [String]) -> [PhotoAsset] {
        guard localIdentifiers.isEmpty == false else {
            return []
        }

        guard skipsPhotoKitReadsForDebugRun == false else {
            return []
        }

        let cachedAssets = Dictionary(uniqueKeysWithValues: assets.map { ($0.localIdentifier, $0) })
        var resolvedByID = cachedAssets
        let missingIdentifiers = localIdentifiers.filter { cachedAssets[$0] == nil }

        if missingIdentifiers.isEmpty == false {
            let result = PHAsset.fetchAssets(withLocalIdentifiers: missingIdentifiers, options: nil)
            let includeFilename = readMode == .light || readMode == .standard
            result.enumerateObjects { asset, _, _ in
                let photoAsset = PhotoAsset(asset: asset, includeFilename: includeFilename)
                resolvedByID[photoAsset.localIdentifier] = photoAsset
            }
        }

        return localIdentifiers.compactMap { resolvedByID[$0] }
    }

    func asset(for localIdentifier: String) -> PhotoAsset? {
        assets(for: [localIdentifier]).first
    }

    func presentLimitedLibraryPicker() {
        guard authorizationStatus == .limited,
              assumesAuthorizedForDebugRun == false else {
            return
        }

        guard let viewController = Self.activeViewController() else {
            errorMessage = "写真の選択画面を開けませんでした。"
            return
        }

        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: viewController)

        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            refreshAuthorizationStatus()
            await loadRecentAssets()
        }
    }

    func loadRecentAssets() async {
        startLoading(resume: false)
    }

    func resumeLoading() {
        startLoading(resume: true)
    }

    private func startLoading(resume: Bool) {
        if skipsPhotoKitReadsForDebugRun {
            completeDebugImportWithoutPhotoKit()
            return
        }

        recoverStaleImportIfNeeded()

        guard resume || importProgress.phase != .stale else {
            return
        }

        guard canReadPhotos else {
            cancelLoading()
            assets = []
            latestLoadedBatch = []
            clearThumbnailPipeline()
            totalAssetCount = 0
            loadedAssetCount = 0
            importProgress = .idle
            persistImportProgress()
            return
        }

        if isLoading, importProgress.readMode == readMode {
            return
        }

        loadGeneration += 1
        let generation = loadGeneration
        cancellationRequested = false
        importTask?.cancel()
        isLoading = true
        errorMessage = nil
        latestLoadedBatch = []
        if resume == false {
            loadedAssetCount = 0
            totalAssetCount = 0
                clearThumbnailPipeline()
        }

        importTask = Task { [weak self] in
            await self?.runImport(generation: generation, resume: resume)
        }
    }

    private func completeDebugImportWithoutPhotoKit() {
        loadGeneration += 1
        cancellationRequested = false
        importTask?.cancel()
        importTask = nil
        isLoading = false
        errorMessage = nil
        latestLoadedBatch = []
        assets = []
        totalAssetCount = 0
        loadedAssetCount = 0
        clearThumbnailPipeline()
        endBackgroundTaskIfNeeded()
        let now = Date()
        updateImportProgress(
            phase: .completed,
            readMode: readMode,
            loadedCount: 0,
            totalCount: 0,
            startedAt: now,
            finishedAt: now,
            message: "検証用インデックスを表示しています",
            interruptionReason: nil,
            latestLoadedIdentifiers: [],
            lastSuccessfulBatchEnd: 0,
            lastPhase: "debugFixture",
            lastExitReasonCandidate: nil,
            batchStart: nil,
            batchEnd: nil,
            batchSize: nil,
            elapsedMilliseconds: 0,
            memoryWarningCount: memoryWarningCount
        )
    }

    func cancelLoading() {
        guard isLoading || importProgress.phase.isActive || hasRecoverableImportState else {
            return
        }

        cancellationRequested = true
        loadGeneration += 1
        importTask?.cancel()
        importTask = nil
        isLoading = false
        endBackgroundTaskIfNeeded()
        updateImportProgress(
            phase: .cancelled,
            readMode: readMode,
            loadedCount: loadedAssetCount,
            totalCount: max(totalAssetCount, importProgress.totalCount),
            startedAt: importProgress.startedAt,
            finishedAt: Date(),
            message: PhotoImportInterruptionReason.userCancelled.message,
            interruptionReason: .userCancelled,
            latestLoadedIdentifiers: importProgress.latestLoadedIdentifiers,
            lastSuccessfulBatchEnd: loadedAssetCount,
            lastPhase: importProgress.lastPhase,
            lastExitReasonCandidate: PhotoImportInterruptionReason.userCancelled.rawValue,
            memoryWarningCount: memoryWarningCount
        )
    }

    func resetLoadingState() {
        cancellationRequested = true
        loadGeneration += 1
        importTask?.cancel()
        importTask = nil
        isLoading = false
        errorMessage = nil
        latestLoadedBatch = []
        endBackgroundTaskIfNeeded()
        updateImportProgress(
            phase: .idle,
            readMode: readMode,
            loadedCount: loadedAssetCount,
            totalCount: totalAssetCount,
            startedAt: nil,
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
            memoryWarningCount: memoryWarningCount
        )
    }

    func reloadLightMode() async {
        resetLoadingState()
        readMode = .light
        userDefaults.set(PhotoReadMode.light.rawValue, forKey: readModeKey)
        await loadRecentAssets()
    }

    func applicationDidEnterBackground() {
        guard isLoading else {
            return
        }

        beginBackgroundTaskIfNeeded()
    }

    func applicationDidBecomeActive() {
        endBackgroundTaskIfNeeded()

        if importProgress.phase == .paused,
           importProgress.interruptionReason == .pausedByAppLifecycle,
           canReadPhotos {
            resumeLoading()
        }
    }

    private func runImport(generation: Int, resume: Bool) async {
        let now = Date()
        var retainedAssets = resume ? assets : []
        var loadedCount = resume ? min(importProgress.loadedCount, importProgress.totalCount) : 0
        let shouldIncludeFilename = readMode == .light || readMode == .standard
        let importStartedAt = importProgress.startedAt ?? now
        let wallClockStart = Date()

        if resume == false {
            updateImportProgress(
                phase: .fetchingAssetList,
                readMode: readMode,
                loadedCount: 0,
                totalCount: 0,
                startedAt: now,
                finishedAt: nil,
                message: "画面切替では読み込みを継続しています",
                interruptionReason: nil,
                latestLoadedIdentifiers: [],
                lastPhase: "photoFetch",
                lastExitReasonCandidate: nil,
                memoryWarningCount: memoryWarningCount
            )
        } else {
            updateImportProgress(
                phase: .fetchingAssetList,
                readMode: readMode,
                loadedCount: loadedCount,
                totalCount: max(totalAssetCount, importProgress.totalCount),
                startedAt: importStartedAt,
                finishedAt: nil,
                message: "続きから再開しています",
                interruptionReason: nil,
                latestLoadedIdentifiers: importProgress.latestLoadedIdentifiers,
                lastSuccessfulBatchEnd: importProgress.lastSuccessfulBatchEnd,
                lastPhase: "photoFetch",
                lastExitReasonCandidate: nil,
                memoryWarningCount: memoryWarningCount
            )
        }

        let options = PHFetchOptions()
        if let limit = readMode.limit {
            options.fetchLimit = limit
        }
        options.includeHiddenAssets = false
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let totalOptions = PHFetchOptions()
        totalOptions.includeHiddenAssets = false
        totalAssetCount = PHAsset.fetchAssets(with: totalOptions).count

        let result = PHAsset.fetchAssets(with: options)
        let expectedCount = readMode.limit.map { min(result.count, $0) } ?? result.count
        let resumeStartIndex = resume ? min(loadedCount, expectedCount) : 0
        retainedAssets = Array(retainedAssets.prefix(retainedAssetLimit))

        updateImportProgress(
            phase: .indexing,
            readMode: readMode,
            loadedCount: loadedCount,
            totalCount: expectedCount,
            startedAt: importStartedAt,
            finishedAt: nil,
            message: "画面切替では読み込みを継続しています",
            interruptionReason: nil,
            latestLoadedIdentifiers: importProgress.latestLoadedIdentifiers,
            lastSuccessfulBatchEnd: importProgress.lastSuccessfulBatchEnd,
            lastPhase: "sqliteBatchInsert",
            batchStart: resumeStartIndex,
            batchEnd: resumeStartIndex,
            batchSize: batchSize,
            memoryWarningCount: memoryWarningCount
        )

        var currentBatch: [PhotoAsset] = []
        currentBatch.reserveCapacity(batchSize)

        for index in resumeStartIndex..<result.count {
            guard generation == loadGeneration else {
                return
            }

            if Task.isCancelled {
                markImportPausedIfCurrent(
                    generation: generation,
                    loadedCount: loadedCount,
                    totalCount: expectedCount,
                    reason: .taskCancelled
                )
                return
            }

            if cancellationRequested {
                markImportCancelledIfCurrent(
                    generation: generation,
                    loadedCount: loadedCount,
                    totalCount: expectedCount
                )
                return
            }

            let asset = result.object(at: index)
            let photoAsset = PhotoAsset(asset: asset, includeFilename: shouldIncludeFilename)
            currentBatch.append(photoAsset)
            loadedCount = index + 1

            if retainedAssets.count < retainedAssetLimit {
                retainedAssets.append(photoAsset)
            }

            if currentBatch.count >= batchSize || loadedCount == firstPaintLimit {
                publishLoadedAssets(
                    retainedAssets,
                    batch: currentBatch,
                    loadedCount: loadedCount,
                    expectedCount: expectedCount,
                    generation: generation,
                    batchStart: max(loadedCount - currentBatch.count, 0),
                    batchEnd: loadedCount,
                    elapsedMilliseconds: Int(Date().timeIntervalSince(wallClockStart) * 1000)
                )
                currentBatch = []
                await Task.yield()
            }
        }

        guard generation == loadGeneration else {
            return
        }

        publishLoadedAssets(
            retainedAssets,
            batch: currentBatch,
            loadedCount: loadedCount,
            expectedCount: expectedCount,
            generation: generation,
            batchStart: max(loadedCount - currentBatch.count, 0),
            batchEnd: loadedCount,
            elapsedMilliseconds: Int(Date().timeIntervalSince(wallClockStart) * 1000)
        )

        isLoading = false
        importTask = nil
        endBackgroundTaskIfNeeded()
        updateImportProgress(
            phase: .completed,
            readMode: readMode,
            loadedCount: loadedCount,
            totalCount: expectedCount,
            startedAt: importStartedAt,
            finishedAt: Date(),
            message: "読み込みが完了しました",
            interruptionReason: nil,
            latestLoadedIdentifiers: importProgress.latestLoadedIdentifiers,
            lastSuccessfulBatchEnd: loadedCount,
            lastPhase: "finalization",
            batchStart: nil,
            batchEnd: nil,
            batchSize: nil,
            elapsedMilliseconds: Int(Date().timeIntervalSince(wallClockStart) * 1000),
            memoryWarningCount: memoryWarningCount
        )
    }

    func cachedThumbnail(for asset: PhotoAsset) -> UIImage? {
        thumbnails[asset.id]
    }

    func requestThumbnail(for asset: PhotoAsset, targetSize: CGSize, completion: ((UIImage?) -> Void)? = nil) {
        if let image = thumbnails[asset.id] {
            PerformanceTelemetry.mark(.thumbnailRequest, "cache-hit")
            completion?(image)
            return
        }

        let requestKey = thumbnailRequestKey(for: asset, targetSize: targetSize)
        guard thumbnailRequests[requestKey] == nil else {
            PerformanceTelemetry.mark(.thumbnailRequest, "in-flight")
            return
        }

        PerformanceTelemetry.mark(.thumbnailRequest, "start")
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false

        let requestID = imageManager.requestImage(
            for: asset.asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { [weak self] image, _ in
            guard let image else {
                return
            }

            Task { @MainActor in
                self?.thumbnailRequests[requestKey] = nil
                self?.thumbnails[asset.id] = image
                PerformanceTelemetry.mark(.thumbnailResult, "completed")
                completion?(image)
            }
        }
        thumbnailRequests[requestKey] = requestID
    }

    func cancelThumbnailRequest(for asset: PhotoAsset, targetSize: CGSize) {
        let requestKey = thumbnailRequestKey(for: asset, targetSize: targetSize)
        guard let requestID = thumbnailRequests.removeValue(forKey: requestKey) else {
            return
        }

        imageManager.cancelImageRequest(requestID)
        PerformanceTelemetry.mark(.thumbnailResult, "cancelled")
    }

    func requestDisplayImage(for asset: PhotoAsset) async -> UIImage? {
        let allowsNetworkAccess = iCloudMode.allowsNetworkAccess

        return await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = allowsNetworkAccess

            var didResume = false

            imageManager.requestImage(
                for: asset.asset,
                targetSize: CGSize(width: 1800, height: 1800),
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let isCancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let hasError = info?[PHImageErrorKey] != nil
                let isInCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false

                guard didResume == false else {
                    return
                }

                if let image, isDegraded == false {
                    didResume = true
                    continuation.resume(returning: image)
                } else if isCancelled || hasError || (isInCloud && allowsNetworkAccess == false) {
                    if isInCloud && allowsNetworkAccess == false {
                        Task { @MainActor in
                            self.errorMessage = "iCloud上の写真です。OCRするには設定でiCloud取得を許可してください。"
                        }
                    }

                    didResume = true
                    continuation.resume(returning: image)
                }
            }
        }
    }

    func requestOCRImage(for asset: PhotoAsset, allowsNetworkAccess: Bool) async -> OCRImageRequestOutcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<OCRImageRequestOutcome, Never>) in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = allowsNetworkAccess

            var didResume = false

            imageManager.requestImage(
                for: asset.asset,
                targetSize: CGSize(width: 1800, height: 1800),
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let isCancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let error = info?[PHImageErrorKey] as? Error
                let isInCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false

                guard didResume == false else {
                    return
                }

                if let image, isDegraded == false {
                    didResume = true
                    continuation.resume(returning: .image(image))
                } else if isInCloud && allowsNetworkAccess == false {
                    didResume = true
                    continuation.resume(returning: .cloudPending)
                } else if isCancelled {
                    didResume = true
                    continuation.resume(returning: .failed("画像取得がキャンセルされました。"))
                } else if let error {
                    didResume = true
                    continuation.resume(returning: .failed(error.localizedDescription))
                }
            }
        }
    }

    private func publishLoadedAssets(
        _ retainedAssets: [PhotoAsset],
        batch: [PhotoAsset],
        loadedCount: Int,
        expectedCount: Int,
        generation: Int,
        batchStart: Int?,
        batchEnd: Int?,
        elapsedMilliseconds: Int?
    ) {
        guard generation == loadGeneration else {
            return
        }

        assets = retainedAssets
        loadedAssetCount = loadedCount

        if batch.isEmpty == false {
            latestLoadedBatch = batch
        }

        updateImportProgress(
            phase: .indexing,
            readMode: readMode,
            loadedCount: loadedCount,
            totalCount: expectedCount,
            startedAt: importProgress.startedAt,
            finishedAt: nil,
            message: "画面切替では読み込みを継続しています",
            interruptionReason: nil,
            latestLoadedIdentifiers: batch.isEmpty ? importProgress.latestLoadedIdentifiers : batch.map(\.localIdentifier),
            lastSuccessfulBatchEnd: loadedCount,
            lastPhase: "sqliteBatchInsert",
            batchStart: batchStart,
            batchEnd: batchEnd,
            batchSize: batch.count,
            elapsedMilliseconds: elapsedMilliseconds,
            memoryWarningCount: memoryWarningCount
        )
    }

    private func clearThumbnailPipeline() {
        for requestID in thumbnailRequests.values {
            imageManager.cancelImageRequest(requestID)
        }
        thumbnailRequests = [:]
        thumbnails = [:]
    }

    private func handleMemoryWarning() {
        memoryWarningCount += 1
        clearThumbnailPipeline()
        imageManager.stopCachingImagesForAllAssets()

        guard isLoading else {
            return
        }

        markImportPausedIfCurrent(
            generation: loadGeneration,
            loadedCount: loadedAssetCount,
            totalCount: max(totalAssetCount, importProgress.totalCount),
            reason: .pausedByMemoryPressure
        )
    }

    private func thumbnailRequestKey(for asset: PhotoAsset, targetSize: CGSize) -> String {
        "\(asset.id)|\(Int(targetSize.width.rounded()))x\(Int(targetSize.height.rounded()))|aspectFill"
    }

    private func markImportCancelledIfCurrent(generation: Int, loadedCount: Int, totalCount: Int) {
        guard generation == loadGeneration else {
            return
        }

        isLoading = false
        importTask = nil
        endBackgroundTaskIfNeeded()
        updateImportProgress(
            phase: .cancelled,
            readMode: readMode,
            loadedCount: loadedCount,
            totalCount: totalCount,
            startedAt: importProgress.startedAt,
            finishedAt: Date(),
            message: PhotoImportInterruptionReason.userCancelled.message,
            interruptionReason: .userCancelled,
            latestLoadedIdentifiers: importProgress.latestLoadedIdentifiers
        )
    }

    private func markImportPausedIfCurrent(
        generation: Int,
        loadedCount: Int,
        totalCount: Int,
        reason: PhotoImportInterruptionReason
    ) {
        guard generation == loadGeneration else {
            return
        }

        isLoading = false
        importTask = nil
        endBackgroundTaskIfNeeded()
        updateImportProgress(
            phase: .paused,
            readMode: readMode,
            loadedCount: loadedCount,
            totalCount: totalCount,
            startedAt: importProgress.startedAt,
            finishedAt: Date(),
            message: reason.message,
            interruptionReason: reason,
            latestLoadedIdentifiers: importProgress.latestLoadedIdentifiers,
            lastSuccessfulBatchEnd: loadedCount,
            lastPhase: importProgress.lastPhase,
            lastExitReasonCandidate: reason.rawValue,
            memoryWarningCount: memoryWarningCount
        )
    }

    private func recoverStaleImportIfNeeded() {
        guard importProgress.phase.isActive,
              isLoading == false || importProgress.isStale() else {
            return
        }

        isLoading = false
        cancellationRequested = true
        loadGeneration += 1
        importTask?.cancel()
        importTask = nil
        endBackgroundTaskIfNeeded()
        importProgress = importProgress.markedStale()
        persistImportProgress()
    }

    private func beginBackgroundTaskIfNeeded() {
        guard backgroundTaskIdentifier == .invalid else {
            return
        }

        backgroundTaskIdentifier = UIApplication.shared.beginBackgroundTask(withName: "ShimaiBakoPhotoImport") { [weak self] in
            Task { @MainActor in
                self?.pauseLoadingForAppLifecycle()
            }
        }
    }

    private func pauseLoadingForAppLifecycle() {
        guard isLoading else {
            endBackgroundTaskIfNeeded()
            return
        }

        loadGeneration += 1
        importTask?.cancel()
        importTask = nil
        isLoading = false
        updateImportProgress(
            phase: .paused,
            readMode: readMode,
            loadedCount: loadedAssetCount,
            totalCount: max(totalAssetCount, importProgress.totalCount),
            startedAt: importProgress.startedAt,
            finishedAt: Date(),
            message: PhotoImportInterruptionReason.pausedByAppLifecycle.message,
            interruptionReason: .pausedByAppLifecycle,
            latestLoadedIdentifiers: importProgress.latestLoadedIdentifiers,
            lastSuccessfulBatchEnd: loadedAssetCount,
            lastPhase: importProgress.lastPhase,
            lastExitReasonCandidate: PhotoImportInterruptionReason.pausedByAppLifecycle.rawValue,
            memoryWarningCount: memoryWarningCount
        )
        endBackgroundTaskIfNeeded()
    }

    private func endBackgroundTaskIfNeeded() {
        guard backgroundTaskIdentifier != .invalid else {
            return
        }

        UIApplication.shared.endBackgroundTask(backgroundTaskIdentifier)
        backgroundTaskIdentifier = .invalid
    }

    private func updateImportProgress(
        phase: PhotoImportPhase,
        readMode: PhotoReadMode,
        loadedCount: Int,
        totalCount: Int,
        startedAt: Date?,
        finishedAt: Date?,
        message: String?,
        interruptionReason: PhotoImportInterruptionReason?,
        latestLoadedIdentifiers: [String]?,
        lastSuccessfulBatchEnd: Int? = nil,
        lastPhase: String? = nil,
        lastErrorSummary: String? = nil,
        lastExitReasonCandidate: String? = nil,
        batchStart: Int? = nil,
        batchEnd: Int? = nil,
        batchSize: Int? = nil,
        elapsedMilliseconds: Int? = nil,
        memoryWarningCount: Int? = nil
    ) {
        importProgress = PhotoImportProgress(
            phase: phase,
            readMode: readMode,
            loadedCount: loadedCount,
            totalCount: totalCount,
            startedAt: startedAt,
            updatedAt: Date(),
            finishedAt: finishedAt,
            message: message,
            interruptionReason: interruptionReason,
            latestLoadedIdentifiers: latestLoadedIdentifiers ?? importProgress.latestLoadedIdentifiers,
            lastSuccessfulBatchEnd: lastSuccessfulBatchEnd ?? importProgress.lastSuccessfulBatchEnd,
            lastPhase: lastPhase ?? importProgress.lastPhase,
            lastErrorSummary: lastErrorSummary,
            lastExitReasonCandidate: lastExitReasonCandidate ?? interruptionReason?.rawValue ?? importProgress.lastExitReasonCandidate,
            batchStart: batchStart,
            batchEnd: batchEnd,
            batchSize: batchSize,
            elapsedMilliseconds: elapsedMilliseconds ?? importProgress.elapsedMilliseconds,
            memoryWarningCount: memoryWarningCount ?? importProgress.memoryWarningCount
        )
        persistImportProgress()
    }

    private func persistImportProgress() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        if let data = try? encoder.encode(importProgress) {
            userDefaults.set(data, forKey: importProgressKey)
        }
    }

    private static func loadImportProgress(
        from userDefaults: UserDefaults,
        key: String,
        fallbackReadMode: PhotoReadMode
    ) -> PhotoImportProgress {
        guard let data = userDefaults.data(forKey: key) else {
            var progress = PhotoImportProgress.idle
            progress.readMode = fallbackReadMode
            return progress
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let progress = try? decoder.decode(PhotoImportProgress.self, from: data) else {
            var fallback = PhotoImportProgress.idle
            fallback.readMode = fallbackReadMode
            return fallback
        }

        return progress
    }

    private static func activeViewController() -> UIViewController? {
        let rootViewController = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .rootViewController

        return rootViewController?.topMostPresentedViewController()
    }
}

private extension UIViewController {
    func topMostPresentedViewController() -> UIViewController {
        if let navigationController = self as? UINavigationController,
           let visibleViewController = navigationController.visibleViewController {
            return visibleViewController.topMostPresentedViewController()
        }

        if let tabBarController = self as? UITabBarController,
           let selectedViewController = tabBarController.selectedViewController {
            return selectedViewController.topMostPresentedViewController()
        }

        if let presentedViewController {
            return presentedViewController.topMostPresentedViewController()
        }

        return self
    }
}
