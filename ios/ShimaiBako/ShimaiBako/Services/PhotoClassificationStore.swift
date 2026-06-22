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
    private let fallbackFileURL: URL
    private let documentFallbackFileURL: URL
    private let cacheFallbackFileURL: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let supportBaseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? fileManager.temporaryDirectory
        let directoryURL = supportBaseURL.appendingPathComponent("ShimaiBako", isDirectory: true)
        fileURL = directoryURL.appendingPathComponent("photo_classifications.json")
        fallbackFileURL = supportBaseURL
            .appendingPathComponent("ShimaiBakoData", isDirectory: true)
            .appendingPathComponent("photo_classifications.json")
        documentFallbackFileURL = (fileManager.urls(for: .documentDirectory, in: .userDomainMask)
            .first ?? fileManager.temporaryDirectory)
            .appendingPathComponent("ShimaiBakoData", isDirectory: true)
            .appendingPathComponent("photo_classifications.json")
        cacheFallbackFileURL = (fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
            .first ?? fileManager.temporaryDirectory)
            .appendingPathComponent("ShimaiBakoData", isDirectory: true)
            .appendingPathComponent("photo_classifications.json")
    }

    func loadAll() async throws -> [PhotoClassification] {
        guard let readableURL = readableFileURL() else {
            return []
        }

        let data = try Data(contentsOf: readableURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(StoredClassifications.self, from: data).classifications
    }

    func saveAll(_ classifications: [PhotoClassification]) async throws {
        let payload = StoredClassifications(
            version: 1,
            classifications: classifications.sorted { $0.updatedAt > $1.updatedAt }
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(payload)

        var lastError: Error?
        for url in storageCandidateURLs() {
            do {
                try write(data, to: url)
                return
            } catch {
                lastError = error
            }
        }

        if let lastError {
            throw lastError
        }
    }

    func upsert(_ classification: PhotoClassification) async throws {
        var classificationsByID = Dictionary(uniqueKeysWithValues: try await loadAll().map { ($0.assetIdentifier, $0) })
        classificationsByID[classification.assetIdentifier] = classification
        try await saveAll(Array(classificationsByID.values))
    }

    private func readableFileURL() -> URL? {
        let existingURLs = storageCandidateURLs().filter { fileManager.fileExists(atPath: $0.path) }
        guard existingURLs.isEmpty == false else {
            return nil
        }

        return existingURLs.max { lhs, rhs in
            modificationDate(for: lhs) < modificationDate(for: rhs)
        }
    }

    private func write(_ data: Data, to url: URL) throws {
        let directoryURL = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    private func modificationDate(for url: URL) -> Date {
        ((try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date) ?? .distantPast
    }

    private func storageCandidateURLs() -> [URL] {
        [
            fileURL,
            fallbackFileURL,
            documentFallbackFileURL,
            cacheFallbackFileURL
        ]
    }
}
