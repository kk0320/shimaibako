import Combine
import Foundation

nonisolated protocol PhotoIndexStoring: Sendable {
    func loadAll() async throws -> [PhotoIndexRecord]
    func loadPage(limit: Int, offset: Int) async throws -> [PhotoIndexRecord]
    func localIdentifierPage(matching request: PhotoIndexPageRequest) async throws -> PhotoIndexPage
    func saveAll(_ records: [PhotoIndexRecord]) async throws
    func upsert(_ records: [PhotoIndexRecord]) async throws
    func clearOCRResult(localIdentifier: String) async throws
    func clearOCRResults(localIdentifiers: [String]) async throws
    func clearAllOCRResults() async throws
    func resetCategory(localIdentifier: String) async throws
    func resetCategories(localIdentifiers: [String]) async throws
    func resetAllCategories() async throws
    func searchLocalIdentifiers(matching query: String) async throws -> Set<String>
    func displayStateCounts() async throws -> [PhotoDisplayState: Int]
    func categoryCounts(displayState: PhotoDisplayState?) async throws -> [PhotoCategory: Int]
    func screenshotSubcategoryCounts(displayState: PhotoDisplayState?) async throws -> [ScreenshotSubcategory: Int]
    func summary() async throws -> PhotoIndexSummary
}

nonisolated struct PhotoIndexPageRequest: Equatable, Sendable {
    var query: String
    var displayState: PhotoDisplayState
    var includeUnwantedWhenActive: Bool
    var category: PhotoCategory
    var screenshotSubcategory: ScreenshotSubcategory
    var limit: Int
    var offset: Int

    var normalizedLimit: Int {
        max(limit, 1)
    }

    var normalizedOffset: Int {
        max(offset, 0)
    }
}

nonisolated struct PhotoIndexPage: Equatable, Sendable {
    var localIdentifiers: [String]
    var totalCount: Int
}

nonisolated struct FilterCountsSnapshot: Equatable, Sendable {
    var revision: Int
    var categoryScope: PhotoDisplayState
    var displayStateCounts: [PhotoDisplayState: Int]?
    var categoryCounts: [PhotoCategory: Int]?
    var screenshotSubcategoryCounts: [ScreenshotSubcategory: Int]?
    var isPreparing: Bool

    static let empty = FilterCountsSnapshot(
        revision: 0,
        categoryScope: .active,
        displayStateCounts: nil,
        categoryCounts: nil,
        screenshotSubcategoryCounts: nil,
        isPreparing: true
    )

    static func preparing(revision: Int, categoryScope: PhotoDisplayState) -> FilterCountsSnapshot {
        FilterCountsSnapshot(
            revision: revision,
            categoryScope: categoryScope,
            displayStateCounts: nil,
            categoryCounts: nil,
            screenshotSubcategoryCounts: nil,
            isPreparing: true
        )
    }
}

@MainActor
final class IndexProgressStore: ObservableObject {
    static let shared = IndexProgressStore()

    @Published private(set) var statusText: String?
    @Published private(set) var isPreparing = false

    private init() {}

    func update(statusText: String?) {
        self.statusText = statusText
        isPreparing = statusText != nil
    }
}

extension PhotoIndexStoring {
    func categoryCounts() async throws -> [PhotoCategory: Int] {
        try await categoryCounts(displayState: nil)
    }

    func screenshotSubcategoryCounts() async throws -> [ScreenshotSubcategory: Int] {
        try await screenshotSubcategoryCounts(displayState: nil)
    }
}

actor JSONPhotoIndexStore: PhotoIndexStoring {
    private struct StoredIndex: Codable {
        let version: Int
        var records: [PhotoIndexRecord]
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private var cachedRecords: [String: PhotoIndexRecord]?

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? fileManager.temporaryDirectory
        let directoryURL = baseURL.appendingPathComponent("ShimaiBako", isDirectory: true)
        fileURL = directoryURL.appendingPathComponent("photo_index.json")
    }

    func loadAll() async throws -> [PhotoIndexRecord] {
        if let cachedRecords {
            return Array(cachedRecords.values)
        }

        guard fileManager.fileExists(atPath: fileURL.path) else {
            cachedRecords = [:]
            return []
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            let records = try decoder.decode(StoredIndex.self, from: data).records
            cachedRecords = Dictionary(uniqueKeysWithValues: records.map { ($0.localIdentifier, $0) })
            return records
        } catch {
            try? backupCorruptIndexFile()
            cachedRecords = [:]
            return []
        }
    }

    func loadPage(limit: Int, offset: Int) async throws -> [PhotoIndexRecord] {
        let records = try await loadAll()
            .sorted { lhs, rhs in
                switch (lhs.creationDate, rhs.creationDate) {
                case let (lhsDate?, rhsDate?):
                    if lhsDate == rhsDate {
                        return lhs.localIdentifier > rhs.localIdentifier
                    }
                    return lhsDate > rhsDate
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                case (.none, .none):
                    return lhs.localIdentifier > rhs.localIdentifier
                }
            }
        return Array(records.dropFirst(max(offset, 0)).prefix(max(limit, 1)))
    }

    func localIdentifierPage(matching request: PhotoIndexPageRequest) async throws -> PhotoIndexPage {
        let tokens = normalizedSearchTokens(in: request.query)
        let records = try await loadAll()
            .filter { record in
                guard displayStateMatches(record.displayState, request: request) else {
                    return false
                }

                guard request.category == .all || record.inferredCategory == request.category else {
                    return false
                }

                if request.category == .screenshots,
                   request.screenshotSubcategory != .all {
                    guard record.isScreenshot,
                          (record.screenshotSubcategory ?? .otherScreenshot) == request.screenshotSubcategory else {
                        return false
                    }
                }

                guard tokens.isEmpty == false else {
                    return true
                }

                let haystack = normalizedSearchText(record.searchableIndexText)
                return tokens.allSatisfy { haystack.contains($0) }
            }
            .sorted { lhs, rhs in
                switch (lhs.creationDate, rhs.creationDate) {
                case let (lhsDate?, rhsDate?):
                    if lhsDate == rhsDate {
                        return lhs.localIdentifier > rhs.localIdentifier
                    }
                    return lhsDate > rhsDate
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                case (.none, .none):
                    return lhs.localIdentifier > rhs.localIdentifier
                }
            }

        let page = records
            .dropFirst(request.normalizedOffset)
            .prefix(request.normalizedLimit)
            .map(\.localIdentifier)
        return PhotoIndexPage(localIdentifiers: Array(page), totalCount: records.count)
    }

    func saveAll(_ records: [PhotoIndexRecord]) async throws {
        cachedRecords = Dictionary(uniqueKeysWithValues: records.map { ($0.localIdentifier, $0) })
        try write(records)
    }

    func upsert(_ records: [PhotoIndexRecord]) async throws {
        var nextRecords = Dictionary(uniqueKeysWithValues: try await loadAll().map { ($0.localIdentifier, $0) })

        for record in records {
            nextRecords[record.localIdentifier] = record
        }

        cachedRecords = nextRecords
        try write(Array(nextRecords.values))
    }

    func clearOCRResult(localIdentifier: String) async throws {
        try await clearOCRResults(localIdentifiers: [localIdentifier])
    }

    func clearOCRResults(localIdentifiers: [String]) async throws {
        let identifiers = Set(localIdentifiers)
        guard identifiers.isEmpty == false else {
            return
        }

        let now = Date()
        let records = try await loadAll().map { record in
            identifiers.contains(record.localIdentifier) ? record.clearingOCR(at: now) : record
        }

        try await saveAll(records)
    }

    func clearAllOCRResults() async throws {
        let now = Date()
        let records = try await loadAll().map { $0.clearingOCR(at: now) }
        try await saveAll(records)
    }

    func resetCategory(localIdentifier: String) async throws {
        try await resetCategories(localIdentifiers: [localIdentifier])
    }

    func resetCategories(localIdentifiers: [String]) async throws {
        let identifiers = Set(localIdentifiers)
        guard identifiers.isEmpty == false else {
            return
        }

        let now = Date()
        let records = try await loadAll().map { record in
            identifiers.contains(record.localIdentifier) ? record.resettingCategory(at: now) : record
        }

        try await saveAll(records)
    }

    func resetAllCategories() async throws {
        let now = Date()
        let records = try await loadAll().map { $0.resettingCategory(at: now) }
        try await saveAll(records)
    }

    func searchLocalIdentifiers(matching query: String) async throws -> Set<String> {
        let tokens = normalizedSearchTokens(in: query)
        guard tokens.isEmpty == false else {
            return Set(try await loadAll().map(\.localIdentifier))
        }

        return Set(try await loadAll().compactMap { record in
            let haystack = normalizedSearchText(record.searchableIndexText)
            return tokens.allSatisfy { haystack.contains($0) } ? record.localIdentifier : nil
        })
    }

    func displayStateCounts() async throws -> [PhotoDisplayState: Int] {
        var counts = Dictionary(uniqueKeysWithValues: PhotoDisplayState.allCases.map { ($0, 0) })
        let records = try await loadAll()

        for record in records {
            counts[record.displayState, default: 0] += 1
        }

        return counts
    }

    func categoryCounts(displayState: PhotoDisplayState?) async throws -> [PhotoCategory: Int] {
        var counts = Dictionary(uniqueKeysWithValues: PhotoCategory.allCases.map { ($0, 0) })
        let records = try await loadAll().filter { record in
            guard let displayState else {
                return true
            }

            return record.displayState == displayState
        }
        counts[.all] = records.count

        for record in records {
            counts[record.inferredCategory, default: 0] += 1
        }

        return counts
    }

    func screenshotSubcategoryCounts(displayState: PhotoDisplayState?) async throws -> [ScreenshotSubcategory: Int] {
        var counts = Dictionary(uniqueKeysWithValues: ScreenshotSubcategory.allCases.map { ($0, 0) })
        let records = try await loadAll().filter { record in
            guard record.isScreenshot else {
                return false
            }

            guard let displayState else {
                return true
            }

            return record.displayState == displayState
        }
        counts[.all] = records.count

        for record in records {
            let subcategory = record.screenshotSubcategory ?? .otherScreenshot
            counts[subcategory, default: 0] += 1
        }

        return counts
    }

    func summary() async throws -> PhotoIndexSummary {
        PhotoIndexSummary(records: try await loadAll())
    }

    private func write(_ records: [PhotoIndexRecord]) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let payload = StoredIndex(
            version: 2,
            records: records.sorted { $0.updatedAt > $1.updatedAt }
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(payload)
        let temporaryURL = directoryURL.appendingPathComponent("photo_index.tmp-\(UUID().uuidString).json")

        do {
            try data.write(to: temporaryURL, options: [.atomic])

            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(
                    fileURL,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try fileManager.moveItem(at: temporaryURL, to: fileURL)
            }
        } catch {
            throw error
        }
    }

    private func backupCorruptIndexFile() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backupName = "photo_index.json.corrupt-\(formatter.string(from: Date()))-\(UUID().uuidString)"
        let backupURL = fileURL.deletingLastPathComponent().appendingPathComponent(backupName)

        try fileManager.moveItem(at: fileURL, to: backupURL)
    }

    private func normalizedSearchTokens(in query: String) -> [String] {
        normalizedSearchText(query)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { $0.isEmpty == false }
    }

    private func normalizedSearchText(_ text: String) -> String {
        let widthAdjusted = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        let kanaAdjusted = widthAdjusted.applyingTransform(.hiraganaToKatakana, reverse: false) ?? widthAdjusted
        return kanaAdjusted
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "ja_JP"))
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func displayStateMatches(_ state: PhotoDisplayState, request: PhotoIndexPageRequest) -> Bool {
        if request.includeUnwantedWhenActive,
           request.displayState == .active {
            return state == .active || state == .unwanted
        }

        return state == request.displayState
    }
}

extension PhotoIndexRecord {
    nonisolated func clearingOCR(at date: Date = Date()) -> PhotoIndexRecord {
        var record = self
        record.ocrStatus = .unprocessed
        record.ocrText = ""
        record.ocrLanguage = nil
        record.ocrProcessedAt = nil
        record.ocrErrorMessage = nil
        record.updatedAt = date
        return record
    }

    nonisolated func resettingCategory(at date: Date = Date()) -> PhotoIndexRecord {
        var record = self
        record.inferredCategory = .uncategorized
        record.categoryConfidence = 0
        record.categoryReason = "未分類に戻しました"
        record.categoryUpdatedAt = date
        record.manualCategory = nil
        record.manualScreenshotSubcategory = nil
        record.manualCategoryUpdatedAt = nil
        record.screenshotSubcategory = nil
        record.screenshotSubcategoryConfidence = nil
        record.screenshotSubcategoryReason = nil
        record.screenshotSubcategoryUpdatedAt = nil
        record.updatedAt = date
        return record
    }

    nonisolated var searchableIndexText: String {
        [
            localIdentifier,
            creationDate.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? "",
            mediaTypeTitle,
            "\(pixelWidth) x \(pixelHeight)",
            isScreenshot ? "スクリーンショット スクショ screenshot" : "",
            inferredCategory.title,
            inferredCategory.shortTitle,
            categoryReason ?? "",
            manualCategory == nil ? "" : "手動分類",
            screenshotSubcategory?.title ?? "",
            screenshotSubcategory?.shortTitle ?? "",
            screenshotSubcategoryReason ?? "",
            displayState.title,
            userMemo,
            userTags.joined(separator: " "),
            ocrText
        ]
        .joined(separator: " ")
    }

    nonisolated var mediaTypeTitle: String {
        switch mediaTypeRawValue {
        case 1:
            "画像 写真"
        case 2:
            "動画"
        default:
            "その他"
        }
    }
}

extension PhotoIndexSummary {
    nonisolated init(records: [PhotoIndexRecord], loadedImageCount: Int? = nil) {
        indexedCount = records.count
        completedOCRCount = records.filter { $0.ocrStatus == .completed }.count
        failedOCRCount = records.filter { $0.ocrStatus == .failed }.count
        processingOCRCount = records.filter { $0.ocrStatus == .processing }.count

        let baseCount = loadedImageCount ?? records.filter { $0.mediaTypeRawValue == 1 }.count
        unprocessedOCRCount = max(baseCount - completedOCRCount - failedOCRCount - processingOCRCount, 0)
        categorizedCount = records.filter { $0.inferredCategory != .uncategorized }.count
    }
}
