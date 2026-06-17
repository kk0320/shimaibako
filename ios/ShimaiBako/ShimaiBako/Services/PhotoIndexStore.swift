import Foundation

nonisolated protocol PhotoIndexStoring: Sendable {
    func loadAll() async throws -> [PhotoIndexRecord]
    func saveAll(_ records: [PhotoIndexRecord]) async throws
    func upsert(_ records: [PhotoIndexRecord]) async throws
    func clearOCRResult(localIdentifier: String) async throws
    func clearOCRResults(localIdentifiers: [String]) async throws
    func clearAllOCRResults() async throws
    func resetCategory(localIdentifier: String) async throws
    func resetCategories(localIdentifiers: [String]) async throws
    func resetAllCategories() async throws
    func searchLocalIdentifiers(matching query: String) async throws -> Set<String>
    func categoryCounts() async throws -> [PhotoCategory: Int]
    func screenshotSubcategoryCounts() async throws -> [ScreenshotSubcategory: Int]
    func summary() async throws -> PhotoIndexSummary
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

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let records = try decoder.decode(StoredIndex.self, from: data).records
        cachedRecords = Dictionary(uniqueKeysWithValues: records.map { ($0.localIdentifier, $0) })
        return records
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
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedQuery.isEmpty == false else {
            return Set(try await loadAll().map(\.localIdentifier))
        }

        return Set(try await loadAll().compactMap { record in
            record.searchableIndexText.localizedCaseInsensitiveContains(normalizedQuery) ? record.localIdentifier : nil
        })
    }

    func categoryCounts() async throws -> [PhotoCategory: Int] {
        var counts = Dictionary(uniqueKeysWithValues: PhotoCategory.allCases.map { ($0, 0) })
        let records = try await loadAll()
        counts[.all] = records.count

        for record in records {
            counts[record.inferredCategory, default: 0] += 1
        }

        return counts
    }

    func screenshotSubcategoryCounts() async throws -> [ScreenshotSubcategory: Int] {
        var counts = Dictionary(uniqueKeysWithValues: ScreenshotSubcategory.allCases.map { ($0, 0) })
        let records = try await loadAll().filter(\.isScreenshot)
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
        try data.write(to: fileURL, options: [.atomic])
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
