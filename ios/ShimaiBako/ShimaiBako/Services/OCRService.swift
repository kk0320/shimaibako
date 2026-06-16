import Combine
import ImageIO
import UIKit
import Vision

@MainActor
final class OCRService: ObservableObject {
    @Published private(set) var recognizedTextByAssetID: [String: String] = [:]
    @Published private(set) var processingAssetIDs: Set<String> = []
    @Published var errorMessage: String?

    func text(for asset: PhotoAsset) -> String? {
        recognizedTextByAssetID[asset.id]
    }

    func isProcessing(_ asset: PhotoAsset) -> Bool {
        processingAssetIDs.contains(asset.id)
    }

    func recognize(asset: PhotoAsset, image: UIImage) async {
        guard processingAssetIDs.contains(asset.id) == false else {
            return
        }

        processingAssetIDs.insert(asset.id)
        errorMessage = nil

        do {
            let text = try await Self.recognizeText(in: image)
            recognizedTextByAssetID[asset.id] = text.isEmpty ? "テキストは見つかりませんでした。" : text
        } catch {
            errorMessage = "OCRに失敗しました: \(error.localizedDescription)"
        }

        processingAssetIDs.remove(asset.id)
    }

    private nonisolated static func recognizeText(in image: UIImage) async throws -> String {
        guard let cgImage = image.cgImage else {
            throw OCRError.imageConversionFailed
        }

        let orientation = CGImagePropertyOrientation(image.imageOrientation)

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
                request.recognitionLanguages = ["ja-JP", "en-US"]
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
}

enum OCRError: LocalizedError {
    case imageConversionFailed

    var errorDescription: String? {
        switch self {
        case .imageConversionFailed:
            "画像を読み込めませんでした。"
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
