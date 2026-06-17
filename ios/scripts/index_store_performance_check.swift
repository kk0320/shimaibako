import Foundation

struct DummyIndexPayload: Codable {
    let version: Int
    var records: [DummyIndexRecord]
}

struct DummyIndexRecord: Codable {
    let localIdentifier: String
    let creationDate: Date
    let mediaType: String
    let mediaSubtypes: UInt
    let pixelWidth: Int
    let pixelHeight: Int
    let isScreenshot: Bool
    let ocrStatus: String
    let ocrText: String
    let ocrLanguage: String
    let ocrProcessedAt: Date?
    let ocrErrorMessage: String?
    let inferredCategory: String
    let categoryConfidence: Double
    let categoryReason: String
    let categoryUpdatedAt: Date
    let screenshotSubcategory: String?
    let screenshotSubcategoryConfidence: Double?
    let screenshotSubcategoryReason: String?
    let screenshotSubcategoryUpdatedAt: Date?
    let lastSeenAt: Date

    var searchableText: String {
        [
            localIdentifier,
            mediaType,
            isScreenshot ? "スクショ スクリーンショット" : "",
            inferredCategory,
            categoryReason,
            screenshotSubcategory ?? "",
            screenshotSubcategoryReason ?? "",
            "\(pixelWidth) x \(pixelHeight)",
            ocrText
        ]
        .joined(separator: " ")
    }
}

@discardableResult
func measure<T>(_ label: String, work: () throws -> T) rethrows -> T {
    let start = CFAbsoluteTimeGetCurrent()
    let result = try work()
    let elapsed = CFAbsoluteTimeGetCurrent() - start
    print("\(label): \(String(format: "%.3f", elapsed))秒")
    return result
}

let recordCount = 30_000
let outputURL = URL(fileURLWithPath: "/tmp/shimaibako_index_performance.json")
let baseDate = Date()

let records = measure("ダミー索引生成 \(recordCount)件") {
    (0..<recordCount).map { index in
        let category: String
        let ocrText: String
        let screenshotSubcategory: String?
        let screenshotSubcategoryReason: String?

        switch index % 11 {
        case 0:
            category = "receiptCandidate"
            ocrText = "領収書 合計 税込 東京 \(index)"
            screenshotSubcategory = nil
            screenshotSubcategoryReason = nil
        case 1:
            category = "documentCandidate"
            ocrText = "工事 報告書 点検 配管 \(index)"
            screenshotSubcategory = nil
            screenshotSubcategoryReason = nil
        case 2:
            category = "businessCardCandidate"
            ocrText = "名刺 電話 email 会社 \(index)"
            screenshotSubcategory = nil
            screenshotSubcategoryReason = nil
        case 3:
            category = "whiteboardCandidate"
            ocrText = "ホワイトボード 会議 課題 \(index)"
            screenshotSubcategory = nil
            screenshotSubcategoryReason = nil
        case 4:
            category = "signboardCandidate"
            ocrText = "看板 入口 案内 \(index)"
            screenshotSubcategory = nil
            screenshotSubcategoryReason = nil
        default:
            if index.isMultiple(of: 7) {
                category = "screenshots"
                ocrText = index.isMultiple(of: 2) ? "地図 駅 住所 東京 \(index)" : "メモ TODO アイデア \(index)"
                screenshotSubcategory = index.isMultiple(of: 2) ? "mapLocationCandidate" : "memoIdeaCandidate"
                screenshotSubcategoryReason = "OCRテキスト"
            } else {
                category = index.isMultiple(of: 5) ? "flowerPlantCandidate" : "uncategorized"
                ocrText = index.isMultiple(of: 5) ? "花 公園 写真 \(index)" : ""
                screenshotSubcategory = nil
                screenshotSubcategoryReason = nil
            }
        }

        return DummyIndexRecord(
            localIdentifier: "dummy-\(index)",
            creationDate: baseDate.addingTimeInterval(TimeInterval(-index * 60)),
            mediaType: index.isMultiple(of: 13) ? "video" : "image",
            mediaSubtypes: index.isMultiple(of: 7) ? 1 : 0,
            pixelWidth: 1179 + (index % 5) * 100,
            pixelHeight: 2556 + (index % 3) * 120,
            isScreenshot: index.isMultiple(of: 7),
            ocrStatus: ocrText.isEmpty ? "unprocessed" : "completed",
            ocrText: ocrText,
            ocrLanguage: "ja-JP,en-US",
            ocrProcessedAt: ocrText.isEmpty ? nil : baseDate,
            ocrErrorMessage: nil,
            inferredCategory: category,
            categoryConfidence: ocrText.isEmpty ? 0.25 : 0.82,
            categoryReason: ocrText.isEmpty ? "未判定" : "OCRテキスト",
            categoryUpdatedAt: baseDate,
            screenshotSubcategory: screenshotSubcategory,
            screenshotSubcategoryConfidence: screenshotSubcategory == nil ? nil : 0.78,
            screenshotSubcategoryReason: screenshotSubcategoryReason,
            screenshotSubcategoryUpdatedAt: screenshotSubcategory == nil ? nil : baseDate,
            lastSeenAt: baseDate
        )
    }
}

let payload = DummyIndexPayload(version: 2, records: records)

let encodedData = try measure("JSONエンコード") {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(payload)
}

try measure("JSON書き込み") {
    try encodedData.write(to: outputURL, options: [.atomic])
}

let decodedPayload = try measure("JSON読み込みとデコード") {
    let data = try Data(contentsOf: outputURL)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(DummyIndexPayload.self, from: data)
}

for query in ["領収書", "工事", "東京", "電話番号"] {
    let matches = measure("LIKE相当検索 \(query)") {
        decodedPayload.records.filter {
            $0.searchableText.localizedCaseInsensitiveContains(query)
        }
    }

    print("  該当: \(matches.count)件")
}

for query in ["地図", "メモ", "flowerPlantCandidate"] {
    let matches = measure("細分類検索 \(query)") {
        decodedPayload.records.filter {
            $0.searchableText.localizedCaseInsensitiveContains(query)
        }
    }

    print("  該当: \(matches.count)件")
}

let categoryCounts = measure("カテゴリ集計") {
    Dictionary(grouping: decodedPayload.records, by: \.inferredCategory)
        .mapValues(\.count)
}

print("カテゴリ種類: \(categoryCounts.count)")
print("一時ファイル: \(outputURL.path)")
