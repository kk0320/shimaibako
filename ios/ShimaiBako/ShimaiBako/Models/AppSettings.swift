import Foundation

enum PhotoReadMode: String, CaseIterable, Identifiable, Codable {
    case light
    case standard
    case expanded
    case large
    case full

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .light:
            "軽量"
        case .standard:
            "標準"
        case .expanded:
            "多め"
        case .large:
            "大量"
        case .full:
            "フル"
        }
    }

    var limit: Int? {
        switch self {
        case .light:
            100
        case .standard:
            500
        case .expanded:
            2_000
        case .large:
            10_000
        case .full:
            nil
        }
    }

    var limitTitle: String {
        if let limit {
            return "直近\(limit)件"
        }

        return "全件"
    }

    var description: String {
        switch self {
        case .light:
            "まず試すための最小読み込み"
        case .standard:
            "日常利用向けの標準読み込み"
        case .expanded:
            "多めに探したいときの読み込み"
        case .large:
            "端末状態を確認して使う大量読み込み"
        case .full:
            "全件を対象にする慎重運用モード"
        }
    }

    var isLargeScale: Bool {
        self == .large || self == .full
    }
}

enum ICloudPhotoMode: String, CaseIterable, Identifiable, Codable {
    case offlinePreferred
    case allowDownload

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .offlinePreferred:
            "オフライン優先"
        case .allowDownload:
            "iCloud取得を許可"
        }
    }

    var description: String {
        switch self {
        case .offlinePreferred:
            "端末内にある画像だけを優先し、iCloud取得をできるだけ避けます。"
        case .allowDownload:
            "OCR時に必要な画像をiCloud写真から取得できます。通信量に注意してください。"
        }
    }

    var allowsNetworkAccess: Bool {
        self == .allowDownload
    }
}

enum OCRBatchTarget: String, CaseIterable, Identifiable, Codable {
    case visible
    case screenshots
    case documentCandidates
    case unprocessed

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .visible:
            "表示中"
        case .screenshots:
            "スクショのみ"
        case .documentCandidates:
            "書類候補のみ"
        case .unprocessed:
            "未OCRのみ"
        }
    }

    var description: String {
        switch self {
        case .visible:
            "現在の検索・カテゴリ表示に含まれる写真を対象にします。"
        case .screenshots:
            "スクリーンショットだけを対象にします。"
        case .documentCandidates:
            "書類写真候補だけを対象にします。"
        case .unprocessed:
            "読み込み済み写真のうち未OCRの画像を対象にします。"
        }
    }
}

enum AccuracyImprovementSchedule: String, CaseIterable, Identifiable, Codable {
    case manualOnly
    case nightAttempt

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .manualOnly:
            "手動のみ"
        case .nightAttempt:
            "夜間に自動実行を試みる"
        }
    }

    var description: String {
        switch self {
        case .manualOnly:
            "ユーザーが押した時だけ少しずつ処理します。"
        case .nightAttempt:
            "iOSの判断に従って、夜間や充電中の実行を将来試みます。指定時刻に必ず動くものではありません。"
        }
    }
}

enum AccuracyImprovementRunState: Equatable {
    case idle
    case running
    case completed
    case interrupted
    case failed

    var title: String {
        switch self {
        case .idle:
            "待機中"
        case .running:
            "処理中"
        case .completed:
            "完了"
        case .interrupted:
            "中断"
        case .failed:
            "失敗"
        }
    }
}
