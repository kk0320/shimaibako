import Foundation
import Photos

enum AspectRatioBucket: String, Codable, CaseIterable {
    case portrait
    case landscape
    case square
    case tallDocument
    case wide
    case unknown

    nonisolated static func bucket(width: Int, height: Int) -> AspectRatioBucket {
        guard width > 0, height > 0 else {
            return .unknown
        }

        let longSide = Double(max(width, height))
        let shortSide = Double(min(width, height))
        let ratio = longSide / shortSide

        if ratio < 1.10 {
            return .square
        }

        if ratio > 1.80 {
            return width > height ? .wide : .tallDocument
        }

        return width > height ? .landscape : .portrait
    }
}

struct ManualCategoryLearningExample: Codable, Equatable, Identifiable {
    var id: String {
        sourceLocalIdentifier
    }

    let sourceLocalIdentifier: String
    var correctedCategory: PhotoCategory
    var correctedScreenshotSubcategory: ScreenshotSubcategory?
    var normalizedKeywords: [String]
    var isScreenshot: Bool
    var mediaTypeRawValue: Int
    var aspectRatioBucket: AspectRatioBucket
    var originalAutoCategory: PhotoCategory
    var createdAt: Date
    var updatedAt: Date
    var useCount: Int

    var categoryKey: String {
        if let correctedScreenshotSubcategory {
            return "\(correctedCategory.rawValue):\(correctedScreenshotSubcategory.rawValue)"
        }

        return correctedCategory.rawValue
    }
}

struct ManualCategoryLearningSuggestion: Equatable {
    var category: PhotoCategory?
    var screenshotSubcategory: ScreenshotSubcategory?
    var confidence: Double
    var reason: String
    var matchedKeywordCount: Int
}

enum ManualCategoryLearningConfiguration {
    nonisolated static let totalLimit = 800
    nonisolated static let perCategoryLimit = 80
    nonisolated static let keywordLimit = 20
    nonisolated static let candidateLimit = 60
}

enum ManualCategoryKeywordExtractor {
    private nonisolated static let knownKeywords = [
        "領収書", "レシート", "receipt", "合計", "税込", "請求", "支払",
        "名刺", "電話", "email", "会社", "部署",
        "ホワイトボード", "会議", "todo", "課題", "打合せ",
        "工事", "施工", "現場", "点検", "配管", "修繕",
        "契約", "申請", "見積", "納品", "書類", "資料", "報告書", "pdf",
        "看板", "入口", "出口", "営業中", "案内", "注意", "駐車場",
        "旅行", "ホテル", "空港", "搭乗", "新幹線", "駅", "観光",
        "神社", "寺", "史跡", "城", "文化財", "鳥居", "temple", "shrine",
        "展示", "美術館", "博物館", "作品", "gallery", "museum",
        "花", "植物", "庭", "公園", "flower", "plant", "garden",
        "桜", "紅葉", "花見", "さくら", "もみじ",
        "ビル", "建物", "街", "通り", "building", "city", "street",
        "料理", "食事", "ランチ", "カフェ", "レストラン", "food", "menu",
        "犬", "猫", "ペット", "動物", "dog", "cat", "animal",
        "人物", "家族", "集合写真", "portrait", "selfie",
        "メモ", "やること", "アイデア", "note", "idea", "checklist",
        "http", "https", "www", "検索", "記事", "ニュース", "safari", "wikipedia",
        "予約", "チケット", "qr", "入場", "座席", "confirmation", "ticket", "booking",
        "地図", "経路", "徒歩", "住所", "map", "route", "station",
        "注文", "購入", "送料", "amazon", "楽天", "円", "order",
        "設定", "エラー", "ログイン", "パスワード", "通知", "権限", "error", "settings", "login",
        "line", "メッセージ", "dm", "投稿", "コメント", "返信", "chat", "message", "post",
        "excel", "powerpoint", "meeting", "document"
    ]

    nonisolated static func keywords(from text: String?, limit: Int = ManualCategoryLearningConfiguration.keywordLimit) -> [String] {
        let normalizedText = normalize(text ?? "")
        guard normalizedText.isEmpty == false else {
            return []
        }

        var keywords: [String] = []
        var seen = Set<String>()

        for keyword in knownKeywords where normalizedText.localizedCaseInsensitiveContains(keyword) {
            let normalizedKeyword = normalize(keyword)
            if seen.insert(normalizedKeyword).inserted {
                keywords.append(normalizedKeyword)
            }
        }

        let separators = CharacterSet.alphanumerics.inverted
        let tokens = normalizedText
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 && $0.count <= 24 }

        for token in tokens where seen.insert(token).inserted {
            keywords.append(token)

            if keywords.count >= limit {
                return Array(keywords.prefix(limit))
            }
        }

        if keywords.isEmpty {
            let fallback = String(normalizedText.prefix(24)).trimmingCharacters(in: .whitespacesAndNewlines)
            if fallback.isEmpty == false {
                keywords.append(fallback)
            }
        }

        return Array(keywords.prefix(limit))
    }

    nonisolated static func normalize(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
