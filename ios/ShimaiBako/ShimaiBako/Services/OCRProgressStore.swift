import Combine
import Foundation

@MainActor
final class OCRProgressStore: ObservableObject {
    @Published private(set) var activeSnapshot: OCRProgressSnapshot?

    #if DEBUG
    var debugIdentifier: String {
        String(ObjectIdentifier(self).hashValue)
    }
    #endif

    var snapshot: OCRProgressSnapshot? {
        activeSnapshot
    }

    private var lastPublishedAt = Date.distantPast
    private let publishInterval: TimeInterval = 1.0

    func publish(job: OCRJob?, isRunning: Bool, force: Bool = false) {
        guard let job,
              let nextSnapshot = OCRProgressSnapshot(job: job, isRunning: isRunning) else {
            if force {
                activeSnapshot = nil
                #if DEBUG
                print("OCR_PROGRESS_STORE store=\(debugIdentifier) activeSnapshot=false snapshotCreated=false")
                #endif
            }
            return
        }

        let now = Date()
        guard force || now.timeIntervalSince(lastPublishedAt) >= publishInterval else {
            return
        }

        lastPublishedAt = now
        activeSnapshot = nextSnapshot

        #if DEBUG
        print("OCR_PROGRESS_STORE store=\(debugIdentifier) activeSnapshot=true state=\(nextSnapshot.state.rawValue) completed=\(nextSnapshot.completed) total=\(nextSnapshot.total) snapshotCreated=true")
        #endif
    }
}
