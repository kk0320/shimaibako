#if DEBUG
import Foundation

enum VisionBenchmarkGroundTruthTag: String, CaseIterable, Codable, Identifiable, Hashable {
    case screenshot
    case document
    case drawing
    case businessCard
    case receipt
    case sign
    case whiteboard
    case building
    case constructionSite
    case person
    case vehicleHeavyEquipment
    case materialEquipment
    case food
    case landscape
    case ocrNeeded
    case other
    case unknown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenshot:
            return "スクショ"
        case .document:
            return "書類"
        case .drawing:
            return "図面"
        case .businessCard:
            return "名刺"
        case .receipt:
            return "レシート"
        case .sign:
            return "看板"
        case .whiteboard:
            return "白板"
        case .building:
            return "建物"
        case .constructionSite:
            return "工事現場"
        case .person:
            return "人物"
        case .vehicleHeavyEquipment:
            return "車両・重機"
        case .materialEquipment:
            return "資材・設備"
        case .food:
            return "食べ物"
        case .landscape:
            return "風景"
        case .ocrNeeded:
            return "OCR必要"
        case .other:
            return "その他"
        case .unknown:
            return "判定不能"
        }
    }
}

struct VisionBenchmarkGroundTruthEntry: Codable, Hashable {
    let assetIdentifierHash: String
    var tags: Set<VisionBenchmarkGroundTruthTag>
    var note: String
    var createdAt: Date
    var updatedAt: Date
}

struct VisionBenchmarkGroundTruthTagSummary: Codable, Hashable, Identifiable {
    var id: String { tag.rawValue }

    let tag: VisionBenchmarkGroundTruthTag
    let count: Int
}

struct VisionBenchmarkGroundTruthSummary: Codable, Hashable {
    let reviewedCount: Int
    let evaluableCount: Int
    let unknownCount: Int
    let tagSummaries: [VisionBenchmarkGroundTruthTagSummary]
}

struct VisionBenchmarkEvaluationMetric: Codable, Hashable, Identifiable {
    var id: String { tag.rawValue }

    let tag: VisionBenchmarkGroundTruthTag
    let truePositive: Int
    let falsePositive: Int
    let falseNegative: Int
    let support: Int

    var precision: Double {
        let denominator = truePositive + falsePositive
        guard denominator > 0 else {
            return 0
        }
        return Double(truePositive) / Double(denominator)
    }

    var recall: Double {
        let denominator = truePositive + falseNegative
        guard denominator > 0 else {
            return 0
        }
        return Double(truePositive) / Double(denominator)
    }
}

struct VisionBenchmarkGroundTruthEvaluation: Codable, Hashable {
    let labeledAssetCount: Int
    let evaluatedAt: Date
    let metrics: [VisionBenchmarkEvaluationMetric]
}

final class VisionBenchmarkGroundTruthStore {
    private let fileManager: FileManager
    private let fileURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? fileManager.temporaryDirectory
        self.fileURL = baseURL
            .appendingPathComponent("ShimaiBako", isDirectory: true)
            .appendingPathComponent("vision_benchmark_ground_truth.json")
    }

    func load() -> [String: VisionBenchmarkGroundTruthEntry] {
        guard let data = try? Data(contentsOf: fileURL) else {
            return [:]
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let entries = try? decoder.decode([VisionBenchmarkGroundTruthEntry].self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: entries.map { ($0.assetIdentifierHash, $0) })
    }

    func save(_ entriesByHash: [String: VisionBenchmarkGroundTruthEntry]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let entries = entriesByHash.values.sorted { lhs, rhs in
            lhs.assetIdentifierHash < rhs.assetIdentifierHash
        }
        let data = try encoder.encode(entries)
        try data.write(to: fileURL, options: [.atomic])
    }
}

enum VisionBenchmarkGroundTruthEvaluator {
    static let evaluatedTags: [VisionBenchmarkGroundTruthTag] = [
        .screenshot,
        .document,
        .drawing,
        .businessCard,
        .receipt,
        .sign,
        .whiteboard,
        .building,
        .constructionSite,
        .person,
        .vehicleHeavyEquipment,
        .materialEquipment,
        .food,
        .landscape,
        .ocrNeeded
    ]

    static func evaluate(
        results: [VisionClassificationProbeResult],
        entriesByHash: [String: VisionBenchmarkGroundTruthEntry]
    ) -> VisionBenchmarkGroundTruthEvaluation {
        let labeledResults = results.filter { result in
            guard let entry = entriesByHash[result.assetIdentifierHash] else {
                return false
            }
            return entry.tags.contains(.unknown) == false && entry.tags.isEmpty == false
        }

        let metrics = evaluatedTags.map { tag in
            var truePositive = 0
            var falsePositive = 0
            var falseNegative = 0
            var support = 0

            for result in labeledResults {
                let expected = entriesByHash[result.assetIdentifierHash]?.tags.contains(tag) ?? false
                let predicted = result.predictedGroundTruthTags.contains(tag)
                if expected {
                    support += 1
                }

                if expected && predicted {
                    truePositive += 1
                } else if expected == false && predicted {
                    falsePositive += 1
                } else if expected && predicted == false {
                    falseNegative += 1
                }
            }

            return VisionBenchmarkEvaluationMetric(
                tag: tag,
                truePositive: truePositive,
                falsePositive: falsePositive,
                falseNegative: falseNegative,
                support: support
            )
        }

        return VisionBenchmarkGroundTruthEvaluation(
            labeledAssetCount: labeledResults.count,
            evaluatedAt: Date(),
            metrics: metrics
        )
    }

    static func summarize(entriesByHash: [String: VisionBenchmarkGroundTruthEntry]) -> VisionBenchmarkGroundTruthSummary {
        let reviewedEntries = entriesByHash.values.filter { $0.tags.isEmpty == false }
        let evaluableEntries = reviewedEntries.filter { $0.tags.contains(.unknown) == false }
        let unknownCount = reviewedEntries.filter { $0.tags.contains(.unknown) }.count
        let tagSummaries = VisionBenchmarkGroundTruthTag.allCases.map { tag in
            VisionBenchmarkGroundTruthTagSummary(
                tag: tag,
                count: reviewedEntries.filter { $0.tags.contains(tag) }.count
            )
        }

        return VisionBenchmarkGroundTruthSummary(
            reviewedCount: reviewedEntries.count,
            evaluableCount: evaluableEntries.count,
            unknownCount: unknownCount,
            tagSummaries: tagSummaries
        )
    }
}

extension VisionClassificationProbeResult {
    var predictedGroundTruthTags: Set<VisionBenchmarkGroundTruthTag> {
        var tags: Set<VisionBenchmarkGroundTruthTag> = []

        if scores.screenshotScore >= 0.7 {
            tags.insert(.screenshot)
        }
        if scores.documentScore >= 0.55 {
            tags.insert(.document)
        }
        if scores.businessCardScore >= 0.45 {
            tags.insert(.businessCard)
        }
        if scores.receiptScore >= 0.45 {
            tags.insert(.receipt)
        }
        if scores.signScore >= 0.45 {
            tags.insert(.sign)
        }
        if scores.whiteboardScore >= 0.45 {
            tags.insert(.whiteboard)
        }
        if scores.buildingScore >= 0.45 {
            tags.insert(.building)
        }
        if scores.constructionSiteScore >= 0.35 {
            tags.insert(.constructionSite)
        }
        if scores.personScore >= 0.55 {
            tags.insert(.person)
        }
        if scores.vehicleHeavyEquipmentScore >= 0.45 {
            tags.insert(.vehicleHeavyEquipment)
        }
        if scores.materialEquipmentScore >= 0.45 {
            tags.insert(.materialEquipment)
        }
        if scores.foodScore >= 0.45 {
            tags.insert(.food)
        }
        if scores.landscapeScore >= 0.45 {
            tags.insert(.landscape)
        }
        if scores.ocrPriorityScore >= 0.75 {
            tags.insert(.ocrNeeded)
        }

        return tags
    }
}
#endif
