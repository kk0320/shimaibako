import Combine
import Foundation

@MainActor
final class OCRProgressStore: ObservableObject {
    @Published private(set) var activeSnapshot: OCRProgressSnapshot?

    var snapshot: OCRProgressSnapshot? {
        activeSnapshot
    }

    private var lastPublishedAt = Date.distantPast
    private let publishInterval: TimeInterval = 0.5

    func publish(job: OCRJob?, isRunning: Bool, force: Bool = false) {
        guard let job,
              let nextSnapshot = OCRProgressSnapshot(job: job, isRunning: isRunning) else {
            if force {
                activeSnapshot = nil
            }
            return
        }

        let now = Date()
        guard force || now.timeIntervalSince(lastPublishedAt) >= publishInterval else {
            return
        }

        lastPublishedAt = now
        activeSnapshot = nextSnapshot
    }
}
