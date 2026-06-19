import Combine
import Foundation

@MainActor
final class OCRProgressStore: ObservableObject {
    @Published private(set) var activeSnapshot: OCRProgressSnapshot?
    @Published private(set) var latestCompletedSummary: OCRProgressSnapshot?

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
    private var observedJobID: UUID?
    private var lastProcessedCount: Int?
    private var lastProgressAt: Date?

    func publish(job: OCRJob?, isRunning: Bool, force: Bool = false) {
        guard let job,
              let jobID = UUID(uuidString: job.id) else {
            if force {
                activeSnapshot = nil
                resetProgressHealth()
                #if DEBUG
                print("OCR_PROGRESS_STORE store=\(debugIdentifier) activeSnapshot=false snapshotCreated=false")
                #endif
            }
            return
        }

        let now = Date()
        let processed = min(job.processedCount, job.totalCount)
        let previousProcessed = observedJobID == jobID ? lastProcessedCount : nil
        let progressDelta = max(processed - (previousProcessed ?? processed), 0)
        if observedJobID != jobID {
            observedJobID = jobID
            lastProcessedCount = processed
            lastProgressAt = now
        } else if previousProcessed == nil || processed > (previousProcessed ?? 0) || job.state == .completed {
            lastProcessedCount = processed
            lastProgressAt = now
        } else if processed < (previousProcessed ?? 0) {
            lastProcessedCount = processed
            lastProgressAt = now
        }

        guard let nextSnapshot = OCRProgressSnapshot(
            job: job,
            isRunning: isRunning,
            lastProgressAt: lastProgressAt,
            lastProcessedCount: lastProcessedCount,
            progressDelta: progressDelta
        ) else {
            if force {
                activeSnapshot = nil
                resetProgressHealth()
                #if DEBUG
                print("OCR_PROGRESS_STORE store=\(debugIdentifier) activeSnapshot=false snapshotCreated=false")
                #endif
            }
            return
        }

        if nextSnapshot.state == .completed {
            latestCompletedSummary = nextSnapshot
            activeSnapshot = nil
            resetProgressHealth()
            #if DEBUG
            print("OCR_PROGRESS_STORE store=\(debugIdentifier) activeSnapshot=false latestCompletedSummary=true completed=\(nextSnapshot.completed) total=\(nextSnapshot.total)")
            #endif
            return
        }

        guard force || now.timeIntervalSince(lastPublishedAt) >= publishInterval else {
            return
        }

        lastPublishedAt = now
        activeSnapshot = nextSnapshot

        #if DEBUG
        print("OCR_PROGRESS_STORE store=\(debugIdentifier) activeSnapshot=true state=\(nextSnapshot.state.rawValue) completed=\(nextSnapshot.completed) total=\(nextSnapshot.total) progressDelta=\(nextSnapshot.progressDelta) snapshotCreated=true")
        #endif
    }

    private func resetProgressHealth() {
        observedJobID = nil
        lastProcessedCount = nil
        lastProgressAt = nil
    }
}
