import Foundation

@MainActor
protocol PhotoClassificationStoring {
    func loadAll() async throws -> [PhotoClassification]
    func saveAll(_ classifications: [PhotoClassification]) async throws
    func upsert(_ classification: PhotoClassification) async throws
}

@MainActor
final class JSONPhotoClassificationStore: PhotoClassificationStoring {
    private struct StoredClassifications: Codable {
        let version: Int
        var classifications: [PhotoClassification]
    }

    private let fileURL: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? fileManager.temporaryDirectory
        let directoryURL = baseURL.appendingPathComponent("ShimaiBako", isDirectory: true)
        fileURL = directoryURL.appendingPathComponent("photo_classifications.json")
    }

    func loadAll() async throws -> [PhotoClassification] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(StoredClassifications.self, from: data).classifications
    }

    func saveAll(_ classifications: [PhotoClassification]) async throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let payload = StoredClassifications(
            version: 1,
            classifications: classifications.sorted { $0.updatedAt > $1.updatedAt }
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(payload)
        try data.write(to: fileURL, options: [.atomic])
    }

    func upsert(_ classification: PhotoClassification) async throws {
        var classificationsByID = Dictionary(uniqueKeysWithValues: try await loadAll().map { ($0.assetIdentifier, $0) })
        classificationsByID[classification.assetIdentifier] = classification
        try await saveAll(Array(classificationsByID.values))
    }
}
