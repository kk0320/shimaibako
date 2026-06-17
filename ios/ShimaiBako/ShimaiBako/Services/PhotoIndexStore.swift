import Foundation

actor PhotoIndexStore {
    private struct StoredIndex: Codable {
        let version: Int
        var records: [PhotoIndexRecord]
    }

    private let fileURL: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? fileManager.temporaryDirectory
        let directoryURL = baseURL.appendingPathComponent("ShimaiBako", isDirectory: true)
        fileURL = directoryURL.appendingPathComponent("photo_index.json")
    }

    func load() async throws -> [PhotoIndexRecord] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return try decoder.decode(StoredIndex.self, from: data).records
    }

    func save(_ records: [PhotoIndexRecord]) async throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let payload = StoredIndex(
            version: 1,
            records: records.sorted { $0.updatedAt > $1.updatedAt }
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(payload)
        try data.write(to: fileURL, options: [.atomic])
    }
}
