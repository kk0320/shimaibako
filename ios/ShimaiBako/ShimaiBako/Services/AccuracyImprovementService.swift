import Combine
import Foundation
import Photos
import UIKit

@MainActor
final class AccuracyImprovementService: ObservableObject {
    @Published private(set) var state: AccuracyImprovementRunState = .idle
    @Published private(set) var totalCount = 0
    @Published private(set) var completedCount = 0
    @Published private(set) var failedCount = 0
    @Published private(set) var interruptedCount = 0
    @Published private(set) var interruptedReason: String?
    @Published private(set) var lastRunAt: Date?
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
    private static let lastSummaryKey = "accuracyImprovement.lastSummary"
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
        lastSummary = userDefaults.string(forKey: Self.lastSummaryKey) ?? "まだ実行していません"
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
            interruptedReason = nil
            state = .completed
            saveRunSummary("対象写真はありませんでした。")
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
        interruptedReason = nil
        lastRunAt = nil
        lastSummary = "処理履歴を削除しました"
        userDefaults.removeObject(forKey: Self.lastRunAtKey)
        userDefaults.set(lastSummary, forKey: Self.lastSummaryKey)

        let featureURL = applicationSupportDirectory()
            .appendingPathComponent("future_image_feature_cache.json")
        if fileManager.fileExists(atPath: featureURL.path) {
            do {
                try fileManager.removeItem(at: featureURL)
            } catch {
                errorMessage = "精度向上データを削除できませんでした: \(error.localizedDescription)"
            }
        }
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
                interruptedCount = totalCount - completedCount - failedCount
                state = .interrupted
                saveRunSummary("中断: \(reason)")
                return
            }

            if cancellationRequested || Task.isCancelled {
                let reason = interruptedReason ?? "ユーザー操作でキャンセルしました。"
                interruptedReason = reason
                interruptedCount = totalCount - completedCount - failedCount
                state = .interrupted
                saveRunSummary("中断: \(reason)")
                return
            }

            await indexService.update(asset: asset, ocrService: ocrService)
            completedCount += 1
            await Task.yield()
        }

        state = .completed
        saveRunSummary("完了: \(completedCount)件を再判定しました。")
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

    private func finishInterrupted(reason: String) {
        totalCount = 0
        completedCount = 0
        failedCount = 0
        interruptedCount = 0
        interruptedReason = reason
        state = .interrupted
        saveRunSummary("中断: \(reason)")
    }

    private func saveRunSummary(_ summary: String) {
        let now = Date()
        lastRunAt = now
        lastSummary = summary
        userDefaults.set(now, forKey: Self.lastRunAtKey)
        userDefaults.set(summary, forKey: Self.lastSummaryKey)
    }

    private func applicationSupportDirectory() -> URL {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? fileManager.temporaryDirectory
        return baseURL.appendingPathComponent("ShimaiBako", isDirectory: true)
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
