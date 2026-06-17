import Combine
import Foundation
import Photos

@MainActor
final class ManualCategoryLearningService: ObservableObject {
    @Published private(set) var examplesBySourceID: [String: ManualCategoryLearningExample] = [:]
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.isEnabledKey)
        }
    }
    @Published var errorMessage: String?

    private struct StoredLearningData: Codable {
        let version: Int
        var examples: [ManualCategoryLearningExample]
    }

    private static let isEnabledKey = "manualCategoryLearningEnabled"
    private let fileURL: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        isEnabled = UserDefaults.standard.object(forKey: Self.isEnabledKey) as? Bool ?? true

        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? fileManager.temporaryDirectory
        let directoryURL = baseURL.appendingPathComponent("ShimaiBako", isDirectory: true)
        fileURL = directoryURL.appendingPathComponent("manual_category_learning.json")

        Task {
            await load()
        }
    }

    var exampleCount: Int {
        examplesBySourceID.count
    }

    var totalLimit: Int {
        ManualCategoryLearningConfiguration.totalLimit
    }

    var perCategoryLimit: Int {
        ManualCategoryLearningConfiguration.perCategoryLimit
    }

    func updateIsEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    func recordManualCorrection(
        asset: PhotoAsset,
        ocrText: String,
        correctedCategory: PhotoCategory,
        correctedScreenshotSubcategory: ScreenshotSubcategory?,
        originalAutoCategory: PhotoCategory
    ) async {
        guard isEnabled else {
            return
        }

        let now = Date()
        let keywords = ManualCategoryKeywordExtractor.keywords(from: ocrText)
        let existing = examplesBySourceID[asset.localIdentifier]

        let example = ManualCategoryLearningExample(
            sourceLocalIdentifier: asset.localIdentifier,
            correctedCategory: correctedCategory,
            correctedScreenshotSubcategory: correctedScreenshotSubcategory,
            normalizedKeywords: keywords,
            isScreenshot: asset.isScreenshot,
            mediaTypeRawValue: asset.mediaType.rawValue,
            aspectRatioBucket: AspectRatioBucket.bucket(width: asset.pixelWidth, height: asset.pixelHeight),
            originalAutoCategory: originalAutoCategory,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            useCount: existing?.useCount ?? 0
        )

        examplesBySourceID[asset.localIdentifier] = example
        trimIfNeeded()
        await save()
    }

    func removeExample(localIdentifier: String) async {
        guard examplesBySourceID.removeValue(forKey: localIdentifier) != nil else {
            return
        }

        await save()
    }

    func clearAll() async {
        examplesBySourceID = [:]
        await save()
    }

    func suggestion(
        for asset: PhotoAsset,
        ocrText: String,
        automaticCategory: PhotoCategory,
        automaticConfidence: Double,
        automaticScreenshotSubcategory: ScreenshotSubcategory?
    ) -> ManualCategoryLearningSuggestion? {
        guard isEnabled, examplesBySourceID.isEmpty == false else {
            return nil
        }

        let keywords = Set(ManualCategoryKeywordExtractor.keywords(from: ocrText))
        let aspectRatioBucket = AspectRatioBucket.bucket(width: asset.pixelWidth, height: asset.pixelHeight)
        let candidates = candidateExamples(
            keywords: keywords,
            isScreenshot: asset.isScreenshot,
            mediaTypeRawValue: asset.mediaType.rawValue,
            aspectRatioBucket: aspectRatioBucket
        )

        guard candidates.isEmpty == false else {
            return nil
        }

        let scored = candidates.compactMap { example -> (example: ManualCategoryLearningExample, score: Double, matchedKeywordCount: Int)? in
            let exampleKeywords = Set(example.normalizedKeywords)
            let matchedKeywordCount = keywords.intersection(exampleKeywords).count
            var score = 0.0

            if matchedKeywordCount > 0 {
                score += min(0.50, Double(matchedKeywordCount) * 0.16)
            }

            if example.isScreenshot == asset.isScreenshot {
                score += 0.22
            }

            if example.mediaTypeRawValue == asset.mediaType.rawValue {
                score += 0.16
            }

            if example.aspectRatioBucket == aspectRatioBucket {
                score += 0.10
            }

            score += min(0.08, Double(example.useCount) * 0.01)

            guard score >= 0.58 else {
                return nil
            }

            return (example, score, matchedKeywordCount)
        }
        .sorted { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.example.updatedAt > rhs.example.updatedAt
            }

            return lhs.score > rhs.score
        }

        guard let best = scored.first else {
            return nil
        }

        if automaticConfidence >= 0.78, best.score < 0.86 {
            return nil
        }

        if best.example.correctedCategory == automaticCategory,
           best.example.correctedScreenshotSubcategory == automaticScreenshotSubcategory {
            return nil
        }

        return ManualCategoryLearningSuggestion(
            category: best.example.correctedCategory,
            screenshotSubcategory: best.example.correctedScreenshotSubcategory,
            confidence: min(0.72, max(0.55, best.score)),
            reason: "手動分類傾向を参考",
            matchedKeywordCount: best.matchedKeywordCount
        )
    }

    func markSuggestionUsed(sourceLocalIdentifier: String) async {
        guard var example = examplesBySourceID[sourceLocalIdentifier] else {
            return
        }

        example.useCount += 1
        example.updatedAt = Date()
        examplesBySourceID[sourceLocalIdentifier] = example
        await save()
    }

    private func candidateExamples(
        keywords: Set<String>,
        isScreenshot: Bool,
        mediaTypeRawValue: Int,
        aspectRatioBucket: AspectRatioBucket
    ) -> [ManualCategoryLearningExample] {
        examplesBySourceID.values
            .filter { example in
                let keywordMatch = keywords.isEmpty == false &&
                    Set(example.normalizedKeywords).isDisjoint(with: keywords) == false
                let metadataMatch = example.isScreenshot == isScreenshot &&
                    example.mediaTypeRawValue == mediaTypeRawValue
                let shapeMatch = example.aspectRatioBucket == aspectRatioBucket

                return keywordMatch || (metadataMatch && shapeMatch)
            }
            .sorted { lhs, rhs in
                if lhs.useCount == rhs.useCount {
                    return lhs.updatedAt > rhs.updatedAt
                }

                return lhs.useCount > rhs.useCount
            }
            .prefix(ManualCategoryLearningConfiguration.candidateLimit)
            .map { $0 }
    }

    private func trimIfNeeded() {
        var examples = Array(examplesBySourceID.values)

        let grouped = Dictionary(grouping: examples, by: \.categoryKey)
        for categoryExamples in grouped.values where categoryExamples.count > perCategoryLimit {
            let overflow = categoryExamples
                .sorted(by: sortForPruning)
                .prefix(categoryExamples.count - perCategoryLimit)

            for example in overflow {
                examplesBySourceID.removeValue(forKey: example.sourceLocalIdentifier)
            }
        }

        examples = Array(examplesBySourceID.values)
        guard examples.count > totalLimit else {
            return
        }

        let overflow = examples
            .sorted(by: sortForPruning)
            .prefix(examples.count - totalLimit)

        for example in overflow {
            examplesBySourceID.removeValue(forKey: example.sourceLocalIdentifier)
        }
    }

    private func sortForPruning(
        _ lhs: ManualCategoryLearningExample,
        _ rhs: ManualCategoryLearningExample
    ) -> Bool {
        if lhs.useCount == rhs.useCount {
            return lhs.updatedAt < rhs.updatedAt
        }

        return lhs.useCount < rhs.useCount
    }

    private func load() async {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            examplesBySourceID = [:]
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload = try decoder.decode(StoredLearningData.self, from: data)
            examplesBySourceID = Dictionary(uniqueKeysWithValues: payload.examples.map { ($0.sourceLocalIdentifier, $0) })
            trimIfNeeded()
        } catch {
            errorMessage = "分類傾向学習データを読み込めませんでした: \(error.localizedDescription)"
        }
    }

    private func save() async {
        do {
            let directoryURL = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            let payload = StoredLearningData(
                version: 1,
                examples: examplesBySourceID.values.sorted { $0.updatedAt > $1.updatedAt }
            )

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

            let data = try encoder.encode(payload)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            errorMessage = "分類傾向学習データを保存できませんでした: \(error.localizedDescription)"
        }
    }
}
