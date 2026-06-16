import Foundation

enum OCRStatus: String, Codable, CaseIterable {
    case unprocessed
    case processing
    case completed
    case failed

    var title: String {
        switch self {
        case .unprocessed:
            "未処理"
        case .processing:
            "処理中"
        case .completed:
            "OCR済み"
        case .failed:
            "読み取り失敗"
        }
    }

    var shortTitle: String {
        switch self {
        case .unprocessed:
            "未処理"
        case .processing:
            "処理中"
        case .completed:
            "OCR済み"
        case .failed:
            "失敗"
        }
    }

    var systemImage: String {
        switch self {
        case .unprocessed:
            "text.viewfinder"
        case .processing:
            "hourglass"
        case .completed:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }
}

struct OCRResultRecord: Codable, Equatable, Identifiable {
    var id: String {
        photoLocalIdentifier
    }

    let photoLocalIdentifier: String
    var ocrText: String
    var ocrStatus: OCRStatus
    var ocrLanguage: String
    var processedAt: Date
    var errorMessage: String?

    var processedAtLabel: String {
        DateFormatter.localizedString(
            from: processedAt,
            dateStyle: .medium,
            timeStyle: .short
        )
    }
}

struct OCRSummary {
    let completedCount: Int
    let failedCount: Int
    let processingCount: Int
    let unprocessedCount: Int
}
