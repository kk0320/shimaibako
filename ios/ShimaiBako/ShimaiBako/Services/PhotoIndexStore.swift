import Foundation

nonisolated protocol PhotoIndexStoring: Sendable {
    func loadAll() async throws -> [PhotoIndexRecord]
    func saveAll(_ records: [PhotoIndexRecord]) async throws
    func upsert(_ records: [PhotoIndexRecord]) async throws
    func searchLocalIdentifiers(matching query: String) async throws -> Set<String>
    func categoryCounts() async throws -> [PhotoCategory: Int]
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
    nonisolated var searchableIndexText: String {
        [
            localIdentifier,
            creationDate.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? "",
            mediaTypeTitle,
            "\(pixelWidth) x \(pixelHeight)",
            isScreenshot ? "スクリーンショット スクショ screenshot" : "",
            inferredCategory.title,
            inferredCategory.shortTitle,
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
        categorizedCount = records.filter { $0.inferredCategory != .other }.count
    }
}
