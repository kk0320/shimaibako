import Combine
import ImageIO
import Photos
import UIKit
import Vision

@MainActor
final class OCRService: ObservableObject {
    @Published private(set) var resultsByAssetID: [String: OCRResultRecord] = [:]
    @Published private(set) var processingAssetIDs: Set<String> = []
    @Published var errorMessage: String?

    private let resultStore: OCRResultStore

    init(resultStore: OCRResultStore = OCRResultStore()) {
        self.resultStore = resultStore

        Task {
            await loadPersistedResults()
        }
    }

    var storedCompletedCount: Int {
        resultsByAssetID.values.filter { $0.ocrStatus == .completed }.count
    }

    var storedCompletedTextCount: Int {
        resultsByAssetID.values.filter { result in
            result.ocrStatus == .completed && Self.isNoTextResult(result) == false
        }.count
    }

    var storedCompletedNoTextCount: Int {
        resultsByAssetID.values.filter { result in
            result.ocrStatus == .completed && Self.isNoTextResult(result)
        }.count
    }

    var storedFailedCount: Int {
        resultsByAssetID.values.filter { $0.ocrStatus == .failed }.count
    }

    func result(for asset: PhotoAsset) -> OCRResultRecord? {
        resultsByAssetID[asset.id]
    }

    func text(for asset: PhotoAsset) -> String? {
        resultsByAssetID[asset.id]?.ocrText
    }

    func isProcessing(_ asset: PhotoAsset) -> Bool {
        processingAssetIDs.contains(asset.id)
    }

    func status(for asset: PhotoAsset) -> OCRStatus {
        if processingAssetIDs.contains(asset.id) {
            return .processing
        }

        return resultsByAssetID[asset.id]?.ocrStatus ?? .unprocessed
    }

    func searchText(for asset: PhotoAsset) -> String {
        guard resultsByAssetID[asset.id]?.ocrStatus == .completed else {
            return ""
        }

        return resultsByAssetID[asset.id]?.ocrText ?? ""
    }

    func summary(for assets: [PhotoAsset]) -> OCRSummary {
        let imageAssets = assets.filter { $0.mediaType == .image }

        return OCRSummary(
            completedCount: imageAssets.filter { status(for: $0) == .completed }.count,
            failedCount: imageAssets.filter { status(for: $0) == .failed }.count,
            processingCount: imageAssets.filter { status(for: $0) == .processing }.count,
            unprocessedCount: imageAssets.filter { status(for: $0) == .unprocessed }.count
        )
    }

    @discardableResult
    func recognize(asset: PhotoAsset, image: UIImage) async -> OCRResultRecord? {
        guard processingAssetIDs.contains(asset.id) == false else {
            return resultsByAssetID[asset.id]
        }

        processingAssetIDs.insert(asset.id)
        errorMessage = nil

        let language = OCRConfiguration.recognitionLanguages.joined(separator: ",")
        resultsByAssetID[asset.id] = OCRResultRecord(
            photoLocalIdentifier: asset.localIdentifier,
            ocrText: resultsByAssetID[asset.id]?.ocrText ?? "",
            ocrStatus: .processing,
            ocrLanguage: language,
            processedAt: Date(),
            errorMessage: nil
        )
        await persistResults()

        let finalResult: OCRResultRecord

        do {
            let text = try await Self.recognizeText(in: image)
            finalResult = OCRResultRecord(
                photoLocalIdentifier: asset.localIdentifier,
                ocrText: text.isEmpty ? "テキストは見つかりませんでした。" : text,
                ocrStatus: .completed,
                ocrLanguage: language,
                processedAt: Date(),
                errorMessage: nil
            )
        } catch {
            finalResult = OCRResultRecord(
                photoLocalIdentifier: asset.localIdentifier,
                ocrText: "",
                ocrStatus: .failed,
                ocrLanguage: language,
                processedAt: Date(),
                errorMessage: error.localizedDescription
            )
            errorMessage = "OCRに失敗しました: \(error.localizedDescription)"
        }

        resultsByAssetID[asset.id] = finalResult
        processingAssetIDs.remove(asset.id)
        await persistResults()

        return finalResult
    }

    @discardableResult
    func markFailure(asset: PhotoAsset, message: String) async -> OCRResultRecord {
        let result = OCRResultRecord(
            photoLocalIdentifier: asset.localIdentifier,
            ocrText: "",
            ocrStatus: .failed,
            ocrLanguage: OCRConfiguration.recognitionLanguages.joined(separator: ","),
            processedAt: Date(),
            errorMessage: message
        )

        resultsByAssetID[asset.id] = result
        processingAssetIDs.remove(asset.id)
        await persistResults()

        return result
    }

    func clearResult(for asset: PhotoAsset) async {
        await clearResult(localIdentifier: asset.localIdentifier)
    }

    func clearResult(localIdentifier: String) async {
        resultsByAssetID.removeValue(forKey: localIdentifier)
        processingAssetIDs.remove(localIdentifier)
        await persistResults()
    }

    func clearResults(for assets: [PhotoAsset]) async {
        await clearResults(localIdentifiers: assets.map(\.localIdentifier))
    }

    func clearResults(localIdentifiers: [String]) async {
        let identifiers = Set(localIdentifiers)
        guard identifiers.isEmpty == false else {
            return
        }

        resultsByAssetID = resultsByAssetID.filter { identifiers.contains($0.key) == false }
        processingAssetIDs.subtract(identifiers)
        await persistResults()
    }

    func clearAllResults() async {
        resultsByAssetID = [:]
        processingAssetIDs = []
        await persistResults()
    }

    private func loadPersistedResults() async {
        do {
            let results = try await resultStore.load()
            var loadedResults = Dictionary(uniqueKeysWithValues: results.map { ($0.photoLocalIdentifier, $0) })
            var shouldPersist = false

            for result in loadedResults.values where result.ocrStatus == .processing {
                loadedResults[result.photoLocalIdentifier] = OCRResultRecord(
                    photoLocalIdentifier: result.photoLocalIdentifier,
                    ocrText: result.ocrText,
                    ocrStatus: .failed,
                    ocrLanguage: result.ocrLanguage,
                    processedAt: Date(),
                    errorMessage: "前回のOCR処理が完了しませんでした。"
                )
                shouldPersist = true
            }

            resultsByAssetID = loadedResults

            if shouldPersist {
                await persistResults()
            }
        } catch {
            errorMessage = "OCR結果を読み込めませんでした: \(error.localizedDescription)"
        }
    }

    private func persistResults() async {
        do {
            try await resultStore.save(Array(resultsByAssetID.values))
        } catch {
            errorMessage = "OCR結果を保存できませんでした: \(error.localizedDescription)"
        }
    }

    private nonisolated static func isNoTextResult(_ result: OCRResultRecord) -> Bool {
        let text = result.ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text == "テキストは見つかりませんでした。"
    }

    private nonisolated static func recognizeText(in image: UIImage) async throws -> String {
        let preparedImage = try preparedImageForRecognition(image)

        guard let cgImage = preparedImage.cgImage else {
            throw OCRError.imageConversionFailed
        }

        let orientation = CGImagePropertyOrientation(preparedImage.imageOrientation)

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var didFinish = false

                func finish(_ result: Result<String, Error>) {
                    guard didFinish == false else {
                        return
                    }

                    didFinish = true

                    switch result {
                    case .success(let text):
                        continuation.resume(returning: text)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }

                let request = VNRecognizeTextRequest { request, error in
                    if let error {
                        finish(.failure(error))
                        return
                    }

                    let observations = request.results as? [VNRecognizedTextObservation] ?? []
                    let lines = observations.compactMap { observation in
                        observation.topCandidates(1).first?.string
                    }

                    finish(.success(lines.joined(separator: "\n")))
                }

                request.recognitionLevel = .accurate
                request.recognitionLanguages = OCRConfiguration.recognitionLanguages
                request.usesLanguageCorrection = true

                let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])

                do {
                    try handler.perform([request])
                } catch {
                    finish(.failure(error))
                }
            }
        }
    }

    private nonisolated static func preparedImageForRecognition(_ image: UIImage) throws -> UIImage {
        guard let cgImage = image.cgImage else {
            throw OCRError.imageConversionFailed
        }

        let pixelWidth = CGFloat(cgImage.width)
        let pixelHeight = CGFloat(cgImage.height)

        guard pixelWidth > 0, pixelHeight > 0 else {
            throw OCRError.invalidImageSize
        }

        let longSide = max(pixelWidth, pixelHeight)
        let maxLongSide = OCRConfiguration.maxRecognitionImageLongSide

        guard longSide > maxLongSide else {
            return image
        }

        let resizeScale = maxLongSide / longSide
        let targetWidth = max(1, Int((pixelWidth * resizeScale).rounded()))
        let targetHeight = max(1, Int((pixelHeight * resizeScale).rounded()))
        let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)

        guard let colorSpace,
              let context = CGContext(
                data: nil,
                width: targetWidth,
                height: targetHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw OCRError.imageConversionFailed
        }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        guard let resizedImage = context.makeImage() else {
            throw OCRError.imageConversionFailed
        }

        return UIImage(cgImage: resizedImage, scale: 1, orientation: image.imageOrientation)
    }
}

enum OCRError: LocalizedError {
    case imageConversionFailed
    case invalidImageSize

    var errorDescription: String? {
        switch self {
        case .imageConversionFailed:
            "画像を読み込めませんでした。"
        case .invalidImageSize:
            "画像サイズを確認できませんでした。"
        }
    }
}

private extension CGImagePropertyOrientation {
    nonisolated init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up:
            self = .up
        case .upMirrored:
            self = .upMirrored
        case .down:
            self = .down
        case .downMirrored:
            self = .downMirrored
        case .left:
            self = .left
        case .leftMirrored:
            self = .leftMirrored
        case .right:
            self = .right
        case .rightMirrored:
            self = .rightMirrored
        @unknown default:
            self = .up
        }
    }
}
