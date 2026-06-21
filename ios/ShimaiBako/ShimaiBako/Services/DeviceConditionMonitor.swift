import Combine
import Foundation
import UIKit

@MainActor
final class DeviceConditionMonitor: ObservableObject {
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var nextCheckAt: Date?

    private var cancellables: Set<AnyCancellable> = []
    private var timerTask: Task<Void, Never>?
    private var isStarted = false
    private let intervalNanoseconds: UInt64 = 60_000_000_000

    func start(
        deviceSafety: DeviceSafetyService,
        onChange: @escaping @MainActor () async -> Void
    ) {
        guard isStarted == false else {
            return
        }

        isStarted = true
        UIDevice.current.isBatteryMonitoringEnabled = true

        let notificationNames: [Notification.Name] = [
            UIDevice.batteryLevelDidChangeNotification,
            UIDevice.batteryStateDidChangeNotification,
            Notification.Name("NSProcessInfoPowerStateDidChange"),
            Notification.Name("NSProcessInfoThermalStateDidChange")
        ]

        for name in notificationNames {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self, weak deviceSafety] _ in
                    Task { @MainActor in
                        guard let self, let deviceSafety else {
                            return
                        }

                        await self.checkNow(deviceSafety: deviceSafety, onChange: onChange)
                    }
                }
                .store(in: &cancellables)
        }

        let intervalNanoseconds = self.intervalNanoseconds
        timerTask = Task { [weak self, weak deviceSafety] in
            while Task.isCancelled == false {
                try? await Task.sleep(nanoseconds: intervalNanoseconds)
                guard Task.isCancelled == false else {
                    return
                }

                guard let self, let deviceSafety else {
                    return
                }

                await self.checkNow(deviceSafety: deviceSafety, onChange: onChange)
            }
        }
    }

    func checkNow(
        deviceSafety: DeviceSafetyService,
        onChange: @escaping @MainActor () async -> Void
    ) async {
        deviceSafety.refresh()
        let now = Date()
        lastCheckedAt = now
        nextCheckAt = now.addingTimeInterval(60)
        await onChange()
    }

    deinit {
        timerTask?.cancel()
    }
}
