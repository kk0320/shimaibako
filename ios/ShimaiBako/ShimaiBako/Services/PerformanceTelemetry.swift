import Foundation
import OSLog

nonisolated enum PerformanceEvent: String {
    case searchIndexBatch = "SearchIndexBatch"
    case searchIndexSave = "SearchIndexSave"
    case publishIndexProgress = "PublishIndexProgress"
    case fetchFilterCounts = "FetchFilterCounts"
    case fetchPhotoPage = "FetchPhotoPage"
    case executeSearch = "ExecuteSearch"
    case thumbnailRequest = "ThumbnailRequest"
    case thumbnailResult = "ThumbnailResult"
    case applyGridSnapshot = "ApplyGridSnapshot"
}

nonisolated enum PerformanceTelemetry {
    private static let logger = Logger(subsystem: "com.kk0320.ShimaiBako", category: "Performance")

    static func mark(_ event: PerformanceEvent, _ message: String = "") {
        if message.isEmpty {
            logger.info("\(event.rawValue, privacy: .public)")
        } else {
            logger.info("\(event.rawValue, privacy: .public): \(message, privacy: .public)")
        }
    }

    static func measure<T>(_ event: PerformanceEvent, _ message: String = "", operation: () throws -> T) rethrows -> T {
        let start = ContinuousClock.now
        let result = try operation()
        let elapsed = start.duration(to: .now)
        mark(event, "\(message) \(millisecondsString(for: elapsed))")
        return result
    }

    static func measure<T>(_ event: PerformanceEvent, _ message: String = "", operation: () async throws -> T) async rethrows -> T {
        let start = ContinuousClock.now
        let result = try await operation()
        let elapsed = start.duration(to: .now)
        mark(event, "\(message) \(millisecondsString(for: elapsed))")
        return result
    }

    private static func millisecondsString(for duration: Duration) -> String {
        let components = duration.components
        let milliseconds = (components.seconds * 1_000) + (components.attoseconds / 1_000_000_000_000_000)
        return "\(milliseconds)ms"
    }
}
