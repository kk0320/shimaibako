import CoreGraphics

enum OCRConfiguration {
    nonisolated static let recognitionLanguages = ["ja-JP", "en-US"]
    nonisolated static let recognitionLanguageTitle = "日本語+英語"
    nonisolated static let recognitionQualityTitle = "高精度"
    nonisolated static let batchLimit = 20
    nonisolated static let maxRecognitionImageLongSide: CGFloat = 1800
    nonisolated static let maxRecognitionImageLongSideTitle = "長辺1800px目安"
}
