import Combine
import Foundation
import Photos
import UIKit

private enum LocalDataDeletionTarget: CaseIterable {
    case futureImageFeatureCache

    var fileName: String {
        switch self {
        case .futureImageFeatureCache:
            "future_image_feature_cache.json"
        }
    }
}

@MainActor
final class AccuracyImprovementService: ObservableObject {
    @Published private(set) var state: AccuracyImprovementRunState = .idle
    @Published private(set) var totalCount = 0
    @Published private(set) var completedCount = 0
    @Published private(set) var failedCount = 0
    @Published private(set) var interruptedCount = 0
    @Published private(set) var manualProtectedCount = 0
    @Published private(set) var interruptedReason: String?
    @Published private(set) var lastRunAt: Date?
    @Published private(set) var runStartedAt: Date?
    @Published private(set) var runEndedAt: Date?
    @Published private(set) var lastResultTitle: String = "未実行"
    @Published private(set) var lastExecutionModeTitle: String = "未実行"
    @Published private(set) var lastSummary: String = "まだ実行していません"
    @Published var isEnabled: Bool {
        didSet {
            userDefaults.set(isEnabled, forKey: Self.isEnabledKey)
        }
    }
    @Published var schedule: AccuracyImprovementSchedule {
        didSet {
            userDefaults.set(schedule.rawValue, forKey: Self.scheduleKey)
        }
    }
    @Published var errorMessage: String?

    private static let isEnabledKey = "accuracyImprovement.isEnabled"
    private static let scheduleKey = "accuracyImprovement.schedule"
    private static let lastRunAtKey = "accuracyImprovement.lastRunAt"
    private static let runStartedAtKey = "accuracyImprovement.runStartedAt"
    private static let runEndedAtKey = "accuracyImprovement.runEndedAt"
    private static let lastResultTitleKey = "accuracyImprovement.lastResultTitle"
    private static let lastExecutionModeTitleKey = "accuracyImprovement.lastExecutionModeTitle"
    private static let lastSummaryKey = "accuracyImprovement.lastSummary"
    private static let totalCountKey = "accuracyImprovement.totalCount"
    private static let completedCountKey = "accuracyImprovement.completedCount"
    private static let failedCountKey = "accuracyImprovement.failedCount"
    private static let interruptedCountKey = "accuracyImprovement.interruptedCount"
    private static let manualProtectedCountKey = "accuracyImprovement.manualProtectedCount"
    private static let interruptedReasonKey = "accuracyImprovement.interruptedReason"
    private static let maxRunCount = 50
    private static let minimumCapacityBytes: Int64 = 1_000_000_000

    private let userDefaults: UserDefaults
    private let fileManager: FileManager
    private var runTask: Task<Void, Never>?
    private var cancellationRequested = false

    init(userDefaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.userDefaults = userDefaults
        self.fileManager = fileManager
        isEnabled = userDefaults.object(forKey: Self.isEnabledKey) as? Bool ?? false
        let storedSchedule = userDefaults.string(forKey: Self.scheduleKey)
        schedule = storedSchedule.flatMap(AccuracyImprovementSchedule.init(rawValue:)) ?? .manualOnly
        lastRunAt = userDefaults.object(forKey: Self.lastRunAtKey) as? Date
        runStartedAt = userDefaults.object(forKey: Self.runStartedAtKey) as? Date
        runEndedAt = userDefaults.object(forKey: Self.runEndedAtKey) as? Date
        lastResultTitle = userDefaults.string(forKey: Self.lastResultTitleKey) ?? "未実行"
        lastExecutionModeTitle = userDefaults.string(forKey: Self.lastExecutionModeTitleKey) ?? "未実行"
        lastSummary = userDefaults.string(forKey: Self.lastSummaryKey) ?? "まだ実行していません"
        totalCount = userDefaults.integer(forKey: Self.totalCountKey)
        completedCount = userDefaults.integer(forKey: Self.completedCountKey)
        failedCount = userDefaults.integer(forKey: Self.failedCountKey)
        interruptedCount = userDefaults.integer(forKey: Self.interruptedCountKey)
        manualProtectedCount = userDefaults.integer(forKey: Self.manualProtectedCountKey)
        interruptedReason = userDefaults.string(forKey: Self.interruptedReasonKey)
    }

    var maxRunCount: Int {
        Self.maxRunCount
    }

    var recommendedTimeRangeTitle: String {
        "23:00〜6:00"
    }

    var nextAttemptTitle: String {
        switch schedule {
        case .manualOnly:
            "手動実行のみ"
        case .nightAttempt:
            "夜間に実行を試みます"
        }
    }

    var lastRunTitle: String {
        guard let lastRunAt else {
            return "未実行"
        }

        return DateFormatter.shimaiBakoDateTime.string(from: lastRunAt)
    }

    var runStartedTitle: String {
        guard let runStartedAt else {
            return "未記録"
        }

        return DateFormatter.shimaiBakoDateTime.string(from: runStartedAt)
    }

    var runEndedTitle: String {
        guard let runEndedAt else {
            return state == .running ? "処理中" : "未記録"
        }

        return DateFormatter.shimaiBakoDateTime.string(from: runEndedAt)
    }

    var progressCompletedCount: Int {
        completedCount + failedCount + manualProtectedCount
    }

    var canStartManualRun: Bool {
        isEnabled && state != .running
    }

    func updateIsEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    func updateSchedule(_ nextSchedule: AccuracyImprovementSchedule) {
        schedule = nextSchedule
    }

    func startSmallRun(
        assets: [PhotoAsset],
        ocrService: OCRService,
        indexService: PhotoIndexService,
        deviceSafety: DeviceSafetyService
    ) {
        guard runTask == nil, state != .running else {
            return
        }

        beginRun(modeTitle: "手動実行")
        guard isEnabled else {
            finishInterrupted(reason: "精度向上モードがオフです。")
            return
        }

        deviceSafety.refresh()
        if let blockingReason = blockingReason(deviceSafety: deviceSafety) {
            finishInterrupted(reason: blockingReason)
            return
        }

        let targets = selectTargets(from: assets, ocrService: ocrService, indexService: indexService)
        guard targets.isEmpty == false else {
            totalCount = 0
            completedCount = 0
            failedCount = 0
            interruptedCount = 0
            manualProtectedCount = 0
            interruptedReason = nil
            state = .completed
            finishCompleted(summary: "対象写真はありませんでした。")
            return
        }

        runTask = Task {
            await run(targets: targets, ocrService: ocrService, indexService: indexService, deviceSafety: deviceSafety)
        }
    }

    func cancel(reason: String = "ユーザー操作でキャンセルしました。") {
        guard state == .running else {
            return
        }

        cancellationRequested = true
        interruptedReason = reason
        runTask?.cancel()
    }

    func clearImprovementData() async {
        cancel(reason: "精度向上データ削除のため停止しました。")
        runTask = nil
        cancellationRequested = false
        state = .idle
        totalCount = 0
        completedCount = 0
        failedCount = 0
        interruptedCount = 0
        manualProtectedCount = 0
        interruptedReason = nil
        lastRunAt = nil
        runStartedAt = nil
        runEndedAt = nil
        lastResultTitle = "未実行"
        lastExecutionModeTitle = "未実行"
        lastSummary = "処理履歴を削除しました"
        persistRunState()

        removeLocalDataFile(.futureImageFeatureCache)
    }

    private func run(
        targets: [PhotoAsset],
        ocrService: OCRService,
        indexService: PhotoIndexService,
        deviceSafety: DeviceSafetyService
    ) async {
        state = .running
        totalCount = targets.count
        completedCount = 0
        failedCount = 0
        interruptedCount = 0
        manualProtectedCount = 0
        interruptedReason = nil
        cancellationRequested = false

        defer {
            runTask = nil
            cancellationRequested = false
        }

        for asset in targets {
            deviceSafety.refresh()

            if let reason = blockingReason(deviceSafety: deviceSafety) {
                interruptedReason = reason
                interruptedCount = remainingCount
                finishInterrupted(reason: reason)
                return
            }

            if cancellationRequested || Task.isCancelled {
                let reason = interruptedReason ?? "ユーザー操作でキャンセルしました。"
                interruptedReason = reason
                interruptedCount = remainingCount
                finishInterrupted(reason: reason)
                return
            }

            if indexService.hasManualClassification(for: asset) {
                manualProtectedCount += 1
                persistRunState()
                await Task.yield()
                continue
            }

            await indexService.update(asset: asset, ocrService: ocrService)
            completedCount += 1
            persistRunState()
            await Task.yield()
        }

        finishCompleted(summary: "完了: \(completedCount)件を再判定しました。手動分類保護: \(manualProtectedCount)件。")
    }

    private func selectTargets(
        from assets: [PhotoAsset],
        ocrService: OCRService,
        indexService: PhotoIndexService
    ) -> [PhotoAsset] {
        let imageAssets = assets.filter { $0.mediaType == .image }
        guard imageAssets.isEmpty == false else {
            return []
        }

        var selected: [PhotoAsset] = []
        var seen = Set<String>()

        func append(_ candidates: [PhotoAsset]) {
            for asset in candidates where selected.count < Self.maxRunCount {
                if seen.insert(asset.localIdentifier).inserted {
                    selected.append(asset)
                }
            }
        }

        append(imageAssets.filter { asset in
            indexService.category(for: asset, ocrService: ocrService) == .uncategorized
        })
        append(imageAssets.filter { asset in
            indexService.status(for: asset, ocrService: ocrService) == .completed
        })
        append(imageAssets.filter(\.isScreenshot))
        append(imageAssets)

        return selected
    }

    private func blockingReason(deviceSafety: DeviceSafetyService) -> String? {
        if deviceSafety.thermalState == .serious || deviceSafety.thermalState == .critical {
            return "端末温度が高いため中断しました。"
        }

        if deviceSafety.isLowPowerModeEnabled {
            return "低電力モード中のため中断しました。"
        }

        if deviceSafety.batteryLevel >= 0,
           deviceSafety.batteryLevel < 0.5,
           deviceSafety.batteryState != .charging,
           deviceSafety.batteryState != .full {
            return "バッテリー残量が50%未満で充電中ではないため中断しました。"
        }

        if let availableCapacityBytes = deviceSafety.availableCapacityBytes,
           availableCapacityBytes < Self.minimumCapacityBytes {
            return "保存容量が1GB未満のため中断しました。"
        }

        return nil
    }

    private var remainingCount: Int {
        max(totalCount - completedCount - failedCount - manualProtectedCount, 0)
    }

    private func beginRun(modeTitle: String) {
        let now = Date()
        state = .running
        totalCount = 0
        completedCount = 0
        failedCount = 0
        interruptedCount = 0
        manualProtectedCount = 0
        interruptedReason = nil
        runStartedAt = now
        runEndedAt = nil
        lastResultTitle = AccuracyImprovementRunState.running.title
        lastExecutionModeTitle = modeTitle
        lastSummary = "処理中です。"
        persistRunState()
    }

    private func finishInterrupted(reason: String) {
        interruptedReason = reason
        state = .interrupted
        finishRun(summary: "中断: \(reason)")
    }

    private func finishCompleted(summary: String) {
        state = .completed
        finishRun(summary: summary)
    }

    private func finishRun(summary: String) {
        let now = Date()
        lastRunAt = now
        runEndedAt = now
        lastResultTitle = state.title
        lastSummary = summary
        persistRunState()
    }

    private func persistRunState() {
        if let lastRunAt {
            userDefaults.set(lastRunAt, forKey: Self.lastRunAtKey)
        } else {
            userDefaults.removeObject(forKey: Self.lastRunAtKey)
        }

        if let runStartedAt {
            userDefaults.set(runStartedAt, forKey: Self.runStartedAtKey)
        } else {
            userDefaults.removeObject(forKey: Self.runStartedAtKey)
        }

        if let runEndedAt {
            userDefaults.set(runEndedAt, forKey: Self.runEndedAtKey)
        } else {
            userDefaults.removeObject(forKey: Self.runEndedAtKey)
        }

        userDefaults.set(lastResultTitle, forKey: Self.lastResultTitleKey)
        userDefaults.set(lastExecutionModeTitle, forKey: Self.lastExecutionModeTitleKey)
        userDefaults.set(lastSummary, forKey: Self.lastSummaryKey)
        userDefaults.set(totalCount, forKey: Self.totalCountKey)
        userDefaults.set(completedCount, forKey: Self.completedCountKey)
        userDefaults.set(failedCount, forKey: Self.failedCountKey)
        userDefaults.set(interruptedCount, forKey: Self.interruptedCountKey)
        userDefaults.set(manualProtectedCount, forKey: Self.manualProtectedCountKey)

        if let interruptedReason {
            userDefaults.set(interruptedReason, forKey: Self.interruptedReasonKey)
        } else {
            userDefaults.removeObject(forKey: Self.interruptedReasonKey)
        }
    }

    private func applicationSupportDirectory() -> URL {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? fileManager.temporaryDirectory
        return baseURL.appendingPathComponent("ShimaiBako", isDirectory: true)
    }

    private func removeLocalDataFile(_ target: LocalDataDeletionTarget) {
        let directoryURL = applicationSupportDirectory().standardizedFileURL
        let fileURL = directoryURL
            .appendingPathComponent(target.fileName)
            .standardizedFileURL

        guard fileURL.deletingLastPathComponent().path == directoryURL.path else {
            errorMessage = "削除対象がアプリ内データ保存先の外にあるため中止しました。"
            return
        }

        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }

        do {
            try fileManager.removeItem(at: fileURL)
        } catch {
            errorMessage = "精度向上データを削除できませんでした: \(error.localizedDescription)"
        }
    }
}

private extension DateFormatter {
    static let shimaiBakoDateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "ja_JP")
        return formatter
    }()
}
