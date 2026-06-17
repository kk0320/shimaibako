import Combine
import Foundation
import UIKit

enum SafetyLevel {
    case normal
    case warning
    case blocking
}

struct DeviceSafetyNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let level: SafetyLevel
}

@MainActor
final class DeviceSafetyService: ObservableObject {
    @Published private(set) var batteryLevel: Float = UIDevice.current.batteryLevel
    @Published private(set) var batteryState: UIDevice.BatteryState = UIDevice.current.batteryState
    @Published private(set) var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published private(set) var thermalState = ProcessInfo.processInfo.thermalState
    @Published private(set) var availableCapacityBytes: Int64?

    private let minimumCapacityBytes: Int64 = 1_000_000_000
    private let recommendedCapacityBytes: Int64 = 2_000_000_000

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        refresh()
    }

    var batteryTitle: String {
        guard batteryLevel >= 0 else {
            return "バッテリー残量を確認できません"
        }

        let percent = Int((batteryLevel * 100).rounded())
        return "\(percent)% / \(batteryStateTitle)"
    }

    var batteryStateTitle: String {
        switch batteryState {
        case .charging:
            "充電中"
        case .full:
            "充電完了"
        case .unplugged:
            "充電なし"
        case .unknown:
            "状態不明"
        @unknown default:
            "状態不明"
        }
    }

    var thermalStateTitle: String {
        switch thermalState {
        case .nominal:
            "通常"
        case .fair:
            "やや高め"
        case .serious:
            "高温"
        case .critical:
            "危険"
        @unknown default:
            "不明"
        }
    }

    var availableCapacityTitle: String {
        guard let availableCapacityBytes else {
            return "空き容量を確認できません"
        }

        return ByteCountFormatter.string(fromByteCount: availableCapacityBytes, countStyle: .file)
    }

    var blockingReasonForLargeWork: String? {
        if thermalState == .serious || thermalState == .critical {
            return "端末温度が高いため、大量処理を中断してください。"
        }

        if let availableCapacityBytes, availableCapacityBytes < minimumCapacityBytes {
            return "保存容量が1GB未満のため、処理を開始できません。"
        }

        return nil
    }

    var notices: [DeviceSafetyNotice] {
        var nextNotices: [DeviceSafetyNotice] = []

        if batteryLevel >= 0,
           batteryLevel < 0.5,
           batteryState != .charging,
           batteryState != .full {
            nextNotices.append(DeviceSafetyNotice(
                title: "バッテリー注意",
                message: "50%以上、または充電中での使用を推奨します。",
                level: .warning
            ))
        }

        if isLowPowerModeEnabled {
            nextNotices.append(DeviceSafetyNotice(
                title: "低電力モード",
                message: "低電力モード中は大量OCRを避けてください。",
                level: .warning
            ))
        }

        if thermalState == .serious || thermalState == .critical {
            nextNotices.append(DeviceSafetyNotice(
                title: "発熱注意",
                message: "端末温度が高いため、大量処理は開始しないでください。",
                level: .blocking
            ))
        } else if thermalState == .fair {
            nextNotices.append(DeviceSafetyNotice(
                title: "発熱注意",
                message: "端末が温かくなっています。処理量を抑えることを推奨します。",
                level: .warning
            ))
        }

        if let availableCapacityBytes {
            if availableCapacityBytes < minimumCapacityBytes {
                nextNotices.append(DeviceSafetyNotice(
                    title: "保存容量不足",
                    message: "空き容量が1GB未満です。処理を開始しません。",
                    level: .blocking
                ))
            } else if availableCapacityBytes < recommendedCapacityBytes {
                nextNotices.append(DeviceSafetyNotice(
                    title: "保存容量注意",
                    message: "空き容量は2GB以上を推奨します。",
                    level: .warning
                ))
            }
        }

        if nextNotices.isEmpty {
            nextNotices.append(DeviceSafetyNotice(
                title: "端末状態",
                message: "大量処理を開始できる状態です。",
                level: .normal
            ))
        }

        return nextNotices
    }

    func refresh() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        batteryLevel = UIDevice.current.batteryLevel
        batteryState = UIDevice.current.batteryState
        isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        thermalState = ProcessInfo.processInfo.thermalState
        availableCapacityBytes = Self.currentAvailableCapacity()
    }

    private static func currentAvailableCapacity() -> Int64? {
        let fileManager = FileManager.default
        guard let url = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }

        let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ])

        if let importantUsage = values?.volumeAvailableCapacityForImportantUsage {
            return importantUsage
        }

        if let capacity = values?.volumeAvailableCapacity {
            return Int64(capacity)
        }

        return nil
    }
}
