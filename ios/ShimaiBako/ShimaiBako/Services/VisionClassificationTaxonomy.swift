#if DEBUG
import Foundation

enum VisionClassificationTaxonomy {
    static let personLabels: Set<String> = []
    static let foodLabels: Set<String> = [
        "food",
        "seafood"
    ]
    static let landscapeLabels: Set<String> = [
        "blue_sky",
        "mountain",
        "night_sky",
        "sky"
    ]
    static let buildingLabels: Set<String> = [
        "building",
        "house_single",
        "lighthouse",
        "skyscraper"
    ]
    static let constructionSiteLabels: Set<String> = [
        "crane_construction"
    ]
    static let signLabels: Set<String> = [
        "billboards",
        "sign",
        "street_sign"
    ]
    static let whiteboardLabels: Set<String> = [
        "whiteboard"
    ]
    static let documentLabels: Set<String> = [
        "document",
        "newspaper"
    ]
    static let receiptLabels: Set<String> = [
        "receipt"
    ]
    static let businessCardLabels: Set<String> = [
        "credit_card"
    ]
    static let vehicleHeavyEquipmentLabels: Set<String> = [
        "engine_vehicle",
        "firetruck",
        "semi_truck",
        "truck",
        "vehicle"
    ]
    static let materialEquipmentLabels: Set<String> = [
        "optical_equipment",
        "road_safety_equipment",
        "sports_equipment"
    ]

    static let plannedButUnsupportedLabels: [String] = [
        "architecture",
        "blackboard",
        "business_card",
        "construction",
        "drawing",
        "excavator",
        "face",
        "heavy_equipment",
        "landscape",
        "person",
        "poster",
        "site"
    ]

    static func score(labels: [VisionProbeVisualLabel], matching candidates: Set<String>) -> Double {
        labels.reduce(0) { best, label in
            let normalized = label.identifier.lowercased()
            guard candidates.contains(normalized) else {
                return best
            }
            return max(best, Double(label.confidence))
        }
    }

    static func matchedLabels(
        labels: [VisionProbeVisualLabel],
        matching candidates: Set<String>
    ) -> [String] {
        labels
            .map { $0.identifier.lowercased() }
            .filter { candidates.contains($0) }
    }

    static func supportedIdentifierMatches(from identifiers: [String]) -> [String: [String]] {
        let categories: [(String, Set<String>)] = [
            ("personLabels", personLabels),
            ("foodLabels", foodLabels),
            ("landscapeLabels", landscapeLabels),
            ("buildingLabels", buildingLabels),
            ("constructionSiteLabels", constructionSiteLabels),
            ("signLabels", signLabels),
            ("whiteboardLabels", whiteboardLabels),
            ("documentLabels", documentLabels),
            ("receiptLabels", receiptLabels),
            ("businessCardLabels", businessCardLabels),
            ("vehicleHeavyEquipmentLabels", vehicleHeavyEquipmentLabels),
            ("materialEquipmentLabels", materialEquipmentLabels)
        ]

        let supportedSet = Set(identifiers.map { $0.lowercased() })
        var matches: [String: [String]] = [:]
        for (name, labels) in categories {
            matches[name] = labels
                .filter { supportedSet.contains($0) }
                .sorted()
        }
        matches["plannedButUnsupportedLabels"] = plannedButUnsupportedLabels
            .filter { supportedSet.contains($0) == false }
            .sorted()
        return matches
    }
}
#endif
