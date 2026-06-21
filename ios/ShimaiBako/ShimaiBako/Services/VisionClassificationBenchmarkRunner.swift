#if DEBUG
import CryptoKit
import Combine
import Foundation
import ImageIO
import Photos
import UIKit
import Vision

struct VisionProbeVisualLabel: Codable, Hashable {
    let identifier: String
    let confidence: Float
}

struct VisionProbeScores: Codable, Hashable {
    let screenshotScore: Double
    let documentScore: Double
    let personScore: Double
    let foodScore: Double
    let landscapeScore: Double
    let buildingScore: Double
    let constructionSiteScore: Double
    let signScore: Double
    let whiteboardScore: Double
    let businessCardScore: Double
    let receiptScore: Double
    let ocrPriorityScore: Double
}

struct VisionClassificationProbeResult: Codable, Identifiable, Hashable {
    var id: String { assetIdentifierHash }

    let assetIdentifierHash: String
    let pixelWidth: Int
    let pixelHeight: Int
    let mediaType: String
    let mediaSubtypesRawValue: UInt
    let isScreenshot: Bool
    let hasCreationDate: Bool
    let topVisualLabels: [VisionProbeVisualLabel]
    let classifyRevision: Int
    let classifyElapsedMs: Double
    let faceCount: Int
    let hasFace: Bool
    let faceElapsedMs: Double
    let humanCount: Int
    let hasHuman: Bool
    let humanElapsedMs: Double
    let documentSegmentCount: Int
    let hasDocumentSegment: Bool
    let documentElapsedMs: Double
    let scores: VisionProbeScores
    let elapsedMs: Double
    let errorMessage: String?
}

struct VisionSupportedIdentifierSummary: Codable, Hashable {
    let generatedAt: Date
    let totalCount: Int
    let keywordMatches: [String: [String]]
    let unavailableReason: String?
}

struct VisionClassificationBenchmarkReport: Codable, Hashable {
    let runID: String
    let deviceName: String
    let photoAuthorizationStatus: String
    let totalAvailableImageCount: Int
    let requestedCount: Int
    let actualCount: Int
    let startedAt: Date
    let finishedAt: Date
    let averageMsPerAsset: Double
    let maxMsPerAsset: Double
    let failedCount: Int
    let screenshotCandidateCount: Int
    let faceDetectedCount: Int
    let humanDetectedCount: Int
    let likelyDocumentCount: Int
    let likelyBuildingCount: Int
    let likelySignCount: Int
    let likelyFoodCount: Int
    let likelyConstructionSiteCount: Int
    let supportedIdentifiers: VisionSupportedIdentifierSummary
    let outputDirectoryPath: String
    let results: [VisionClassificationProbeResult]
}

@MainActor
final class VisionClassificationBenchmarkRunner: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var latestReport: VisionClassificationBenchmarkReport?
    @Published private(set) var latestStatus: String?
    @Published private(set) var progressText: String?
    @Published private(set) var latestOutputDirectoryPath: String?
    @Published var errorMessage: String?

    private let fileManager: FileManager
    private let probeService: VisionClassificationProbeService

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.probeService = VisionClassificationProbeService()
    }

    func run(limit: Int) async {
        guard isRunning == false else {
            return
        }

        isRunning = true
        errorMessage = nil
        latestStatus = "Vision分類ベンチを準備しています"
        progressText = nil

        let requestedCount = max(1, min(limit, 100))
        let startedAt = Date()
        let runID = Self.runID(startedAt: startedAt, limit: requestedCount)
        let supportedSummary = Self.makeSupportedIdentifierSummary()
        let selection = fetchRecentImageAssets(limit: requestedCount)
        let assets = selection.assets
        var results: [VisionClassificationProbeResult] = []
        results.reserveCapacity(assets.count)

        for (index, asset) in assets.enumerated() {
            if Task.isCancelled {
                break
            }

            latestStatus = "解析中"
            progressText = "\(index + 1) / \(assets.count)件"

            let result = await probeService.analyze(asset: asset)
            results.append(result)
            await Task.yield()
        }

        let finishedAt = Date()
        let elapsedValues = results.map(\.elapsedMs)
        let average = elapsedValues.isEmpty ? 0 : elapsedValues.reduce(0, +) / Double(elapsedValues.count)
        let maxElapsed = elapsedValues.max() ?? 0
        let outputDirectory = outputDirectoryURL()
        let report = VisionClassificationBenchmarkReport(
            runID: runID,
            deviceName: Self.deviceName(),
            photoAuthorizationStatus: selection.authorizationStatus,
            totalAvailableImageCount: selection.totalAvailableImageCount,
            requestedCount: requestedCount,
            actualCount: results.count,
            startedAt: startedAt,
            finishedAt: finishedAt,
            averageMsPerAsset: average,
            maxMsPerAsset: maxElapsed,
            failedCount: results.filter { $0.errorMessage != nil }.count,
            screenshotCandidateCount: results.filter { $0.scores.screenshotScore >= 0.7 }.count,
            faceDetectedCount: results.filter(\.hasFace).count,
            humanDetectedCount: results.filter(\.hasHuman).count,
            likelyDocumentCount: results.filter { $0.scores.documentScore >= 0.55 }.count,
            likelyBuildingCount: results.filter { $0.scores.buildingScore >= 0.45 }.count,
            likelySignCount: results.filter { $0.scores.signScore >= 0.45 }.count,
            likelyFoodCount: results.filter { $0.scores.foodScore >= 0.45 }.count,
            likelyConstructionSiteCount: results.filter { $0.scores.constructionSiteScore >= 0.35 }.count,
            supportedIdentifiers: supportedSummary,
            outputDirectoryPath: outputDirectory.path,
            results: results
        )

        do {
            try write(report: report, to: outputDirectory)
            latestOutputDirectoryPath = outputDirectory.path
            latestStatus = "Vision分類ベンチが完了しました"
            latestReport = report
        } catch {
            errorMessage = "ベンチ結果の保存に失敗しました: \(error.localizedDescription)"
            latestStatus = "保存に失敗しました"
            latestReport = report
        }

        progressText = "\(results.count) / \(requestedCount)件"
        isRunning = false
    }

    func refreshSupportedIdentifiersOnly() {
        let summary = Self.makeSupportedIdentifierSummary()
        let outputDirectory = outputDirectoryURL()

        do {
            try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            try markdown(for: summary).write(
                to: outputDirectory.appendingPathComponent("supported_identifiers_summary.md"),
                atomically: true,
                encoding: .utf8
            )
            latestOutputDirectoryPath = outputDirectory.path
            latestStatus = "ラベル棚卸しを保存しました"
        } catch {
            errorMessage = "ラベル棚卸しの保存に失敗しました: \(error.localizedDescription)"
        }
    }

    private func fetchRecentImageAssets(limit: Int) -> (
        authorizationStatus: String,
        totalAvailableImageCount: Int,
        assets: [PHAsset]
    ) {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.fetchLimit = limit
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let countOptions = PHFetchOptions()
        countOptions.includeHiddenAssets = false
        let totalCount = PHAsset.fetchAssets(with: .image, options: countOptions).count
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(min(limit, result.count))
        result.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        return (Self.authorizationStatusTitle(status), totalCount, assets)
    }

    private func outputDirectoryURL() -> URL {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? fileManager.temporaryDirectory
        return baseURL
            .appendingPathComponent("ShimaiBako", isDirectory: true)
            .appendingPathComponent("vision_classification_benchmark", isDirectory: true)
    }

    private func write(report: VisionClassificationBenchmarkReport, to directory: URL) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)

        let jsonName = "\(report.runID).json"
        let markdownName = "\(report.runID).md"
        let csvName = "\(report.runID).csv"

        try data.write(to: directory.appendingPathComponent(jsonName), options: [.atomic])
        try data.write(to: directory.appendingPathComponent("vision_benchmark_latest.json"), options: [.atomic])

        try markdown(for: report).write(
            to: directory.appendingPathComponent(markdownName),
            atomically: true,
            encoding: .utf8
        )
        try markdown(for: report).write(
            to: directory.appendingPathComponent("vision_benchmark_latest.md"),
            atomically: true,
            encoding: .utf8
        )

        try csv(for: report).write(
            to: directory.appendingPathComponent(csvName),
            atomically: true,
            encoding: .utf8
        )
        try csv(for: report).write(
            to: directory.appendingPathComponent("vision_benchmark_latest.csv"),
            atomically: true,
            encoding: .utf8
        )

        try markdown(for: report.supportedIdentifiers).write(
            to: directory.appendingPathComponent("supported_identifiers_summary.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func markdown(for report: VisionClassificationBenchmarkReport) -> String {
        let topLabelExamples = report.results.prefix(10).map { result in
            let labels = result.topVisualLabels
                .map { "\($0.identifier) \(String(format: "%.2f", $0.confidence))" }
                .joined(separator: ", ")
            return "- \(result.assetIdentifierHash.prefix(12)): \(labels.isEmpty ? "ラベルなし" : labels)"
        }.joined(separator: "\n")

        return """
        # Vision Classification Benchmark

        ## Run
        - runID: \(report.runID)
        - device: \(report.deviceName)
        - photo authorization: \(report.photoAuthorizationStatus)
        - available image count: \(report.totalAvailableImageCount)
        - requested count: \(report.requestedCount)
        - actual count: \(report.actualCount)
        - average ms/asset: \(String(format: "%.1f", report.averageMsPerAsset))
        - max ms/asset: \(String(format: "%.1f", report.maxMsPerAsset))
        - failed: \(report.failedCount)

        ## Signals
        - screenshot detected: \(report.screenshotCandidateCount)
        - face detected: \(report.faceDetectedCount)
        - human detected: \(report.humanDetectedCount)
        - likely document: \(report.likelyDocumentCount)
        - likely building: \(report.likelyBuildingCount)
        - likely sign: \(report.likelySignCount)
        - likely food: \(report.likelyFoodCount)
        - likely construction site: \(report.likelyConstructionSiteCount)

        ## Top Label Examples
        \(topLabelExamples.isEmpty ? "- none" : topLabelExamples)

        ## Safety
        - image bodies are not saved
        - thumbnails are not saved
        - face images and face templates are not saved
        - Photos library assets are read only
        """
    }

    private func markdown(for summary: VisionSupportedIdentifierSummary) -> String {
        let matches = summary.keywordMatches.keys.sorted().map { keyword in
            let values = summary.keywordMatches[keyword] ?? []
            let joined = values.prefix(20).joined(separator: ", ")
            return "- \(keyword): \(values.count) match(es)\(joined.isEmpty ? "" : " / \(joined)")"
        }.joined(separator: "\n")

        return """
        # Supported Identifiers Summary

        - generatedAt: \(ISO8601DateFormatter().string(from: summary.generatedAt))
        - totalCount: \(summary.totalCount)
        - unavailableReason: \(summary.unavailableReason ?? "none")

        ## Keyword Matches
        \(matches.isEmpty ? "- none" : matches)
        """
    }

    private func csv(for report: VisionClassificationBenchmarkReport) -> String {
        var lines = [
            "assetHash,isScreenshot,faceCount,humanCount,topLabel1,topLabel1Confidence,documentScore,buildingScore,signScore,ocrPriorityScore,elapsedMs,error"
        ]

        for result in report.results {
            let topLabel = result.topVisualLabels.first
            let fields = [
                result.assetIdentifierHash,
                "\(result.isScreenshot)",
                "\(result.faceCount)",
                "\(result.humanCount)",
                Self.csvEscape(topLabel?.identifier ?? ""),
                topLabel.map { String(format: "%.4f", $0.confidence) } ?? "",
                String(format: "%.3f", result.scores.documentScore),
                String(format: "%.3f", result.scores.buildingScore),
                String(format: "%.3f", result.scores.signScore),
                String(format: "%.3f", result.scores.ocrPriorityScore),
                String(format: "%.1f", result.elapsedMs),
                Self.csvEscape(result.errorMessage ?? "")
            ]
            lines.append(fields.joined(separator: ","))
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func authorizationStatusTitle(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "notDetermined"
        case .restricted:
            return "restricted"
        case .denied:
            return "denied"
        case .authorized:
            return "authorized"
        case .limited:
            return "limited"
        @unknown default:
            return "unknown"
        }
    }

    private static func csvEscape(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private static func runID(startedAt: Date, limit: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return "\(formatter.string(from: startedAt))_vision_probe_\(limit)"
    }

    private static func deviceName() -> String {
        #if targetEnvironment(simulator)
        return "Simulator \(UIDevice.current.model)"
        #else
        return UIDevice.current.name
        #endif
    }

    private static func makeSupportedIdentifierSummary() -> VisionSupportedIdentifierSummary {
        let keywords = [
            "person", "face", "food", "meal", "dish", "landscape", "sky", "mountain",
            "sea", "building", "house", "architecture", "construction", "site", "sign",
            "billboard", "document", "paper", "receipt", "card", "whiteboard", "blackboard",
            "vehicle", "truck", "equipment"
        ]

        let request = VNClassifyImageRequest()
        guard let identifiers = try? request.supportedIdentifiers() else {
            return VisionSupportedIdentifierSummary(
                generatedAt: Date(),
                totalCount: 0,
                keywordMatches: [:],
                unavailableReason: "VNClassifyImageRequest.supportedIdentifiers() failed"
            )
        }

        var matches: [String: [String]] = [:]
        for keyword in keywords {
            let lowerKeyword = keyword.lowercased()
            matches[keyword] = identifiers
                .filter { $0.lowercased().contains(lowerKeyword) }
                .sorted()
        }

        return VisionSupportedIdentifierSummary(
            generatedAt: Date(),
            totalCount: identifiers.count,
            keywordMatches: matches,
            unavailableReason: nil
        )
    }
}

final class VisionClassificationProbeService {
    private let imageManager = PHImageManager.default()
    private let targetSize = CGSize(width: 640, height: 640)

    func analyze(asset: PHAsset) async -> VisionClassificationProbeResult {
        let overallStart = Date()
        let assetHash = Self.hashIdentifier(asset.localIdentifier)
        let isScreenshot = asset.mediaSubtypes.contains(.photoScreenshot)

        guard let image = await requestImage(for: asset), let cgImage = image.cgImage else {
            return VisionClassificationProbeResult(
                assetIdentifierHash: assetHash,
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight,
                mediaType: Self.mediaTypeTitle(asset.mediaType),
                mediaSubtypesRawValue: asset.mediaSubtypes.rawValue,
                isScreenshot: isScreenshot,
                hasCreationDate: asset.creationDate != nil,
                topVisualLabels: [],
                classifyRevision: 0,
                classifyElapsedMs: 0,
                faceCount: 0,
                hasFace: false,
                faceElapsedMs: 0,
                humanCount: 0,
                hasHuman: false,
                humanElapsedMs: 0,
                documentSegmentCount: 0,
                hasDocumentSegment: false,
                documentElapsedMs: 0,
                scores: Self.makeScores(
                    isScreenshot: isScreenshot,
                    labels: [],
                    faceCount: 0,
                    humanCount: 0,
                    documentSegmentCount: 0
                ),
                elapsedMs: Self.elapsedMs(since: overallStart),
                errorMessage: "画像を取得できませんでした"
            )
        }

        do {
            let vision = try performVision(cgImage: cgImage, orientation: CGImagePropertyOrientation(image.imageOrientation))
            let scores = Self.makeScores(
                isScreenshot: isScreenshot,
                labels: vision.labels,
                faceCount: vision.faceCount,
                humanCount: vision.humanCount,
                documentSegmentCount: vision.documentSegmentCount
            )

            return VisionClassificationProbeResult(
                assetIdentifierHash: assetHash,
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight,
                mediaType: Self.mediaTypeTitle(asset.mediaType),
                mediaSubtypesRawValue: asset.mediaSubtypes.rawValue,
                isScreenshot: isScreenshot,
                hasCreationDate: asset.creationDate != nil,
                topVisualLabels: vision.labels,
                classifyRevision: vision.classifyRevision,
                classifyElapsedMs: vision.classifyElapsedMs,
                faceCount: vision.faceCount,
                hasFace: vision.faceCount > 0,
                faceElapsedMs: vision.faceElapsedMs,
                humanCount: vision.humanCount,
                hasHuman: vision.humanCount > 0,
                humanElapsedMs: vision.humanElapsedMs,
                documentSegmentCount: vision.documentSegmentCount,
                hasDocumentSegment: vision.documentSegmentCount > 0,
                documentElapsedMs: vision.documentElapsedMs,
                scores: scores,
                elapsedMs: Self.elapsedMs(since: overallStart),
                errorMessage: nil
            )
        } catch {
            return VisionClassificationProbeResult(
                assetIdentifierHash: assetHash,
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight,
                mediaType: Self.mediaTypeTitle(asset.mediaType),
                mediaSubtypesRawValue: asset.mediaSubtypes.rawValue,
                isScreenshot: isScreenshot,
                hasCreationDate: asset.creationDate != nil,
                topVisualLabels: [],
                classifyRevision: 0,
                classifyElapsedMs: 0,
                faceCount: 0,
                hasFace: false,
                faceElapsedMs: 0,
                humanCount: 0,
                hasHuman: false,
                humanElapsedMs: 0,
                documentSegmentCount: 0,
                hasDocumentSegment: false,
                documentElapsedMs: 0,
                scores: Self.makeScores(
                    isScreenshot: isScreenshot,
                    labels: [],
                    faceCount: 0,
                    humanCount: 0,
                    documentSegmentCount: 0
                ),
                elapsedMs: Self.elapsedMs(since: overallStart),
                errorMessage: error.localizedDescription
            )
        }
    }

    private func requestImage(for asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false
            options.isSynchronous = false

            var didResume = false
            imageManager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let isCancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let hasError = info?[PHImageErrorKey] != nil
                let isInCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false

                guard didResume == false else {
                    return
                }

                if let image, isDegraded == false {
                    didResume = true
                    continuation.resume(returning: image)
                } else if isCancelled || hasError || isInCloud {
                    didResume = true
                    continuation.resume(returning: image)
                }
            }
        }
    }

    private func performVision(
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation
    ) throws -> (
        labels: [VisionProbeVisualLabel],
        classifyRevision: Int,
        classifyElapsedMs: Double,
        faceCount: Int,
        faceElapsedMs: Double,
        humanCount: Int,
        humanElapsedMs: Double,
        documentSegmentCount: Int,
        documentElapsedMs: Double
    ) {
        let classifyRequest = VNClassifyImageRequest()
        let classifyStart = Date()
        try VNImageRequestHandler(cgImage: cgImage, orientation: orientation).perform([classifyRequest])
        let classifyElapsed = Self.elapsedMs(since: classifyStart)
        let labels = (classifyRequest.results ?? [])
            .prefix(5)
            .map { VisionProbeVisualLabel(identifier: $0.identifier, confidence: $0.confidence) }

        let faceRequest = VNDetectFaceRectanglesRequest()
        let faceStart = Date()
        try VNImageRequestHandler(cgImage: cgImage, orientation: orientation).perform([faceRequest])
        let faceElapsed = Self.elapsedMs(since: faceStart)
        let faceCount = faceRequest.results?.count ?? 0

        let humanRequest = VNDetectHumanRectanglesRequest()
        let humanStart = Date()
        try VNImageRequestHandler(cgImage: cgImage, orientation: orientation).perform([humanRequest])
        let humanElapsed = Self.elapsedMs(since: humanStart)
        let humanCount = humanRequest.results?.count ?? 0

        var documentCount = 0
        var documentElapsed: Double = 0
        if #available(iOS 15.0, *) {
            let documentRequest = VNDetectDocumentSegmentationRequest()
            let documentStart = Date()
            try VNImageRequestHandler(cgImage: cgImage, orientation: orientation).perform([documentRequest])
            documentElapsed = Self.elapsedMs(since: documentStart)
            documentCount = documentRequest.results?.count ?? 0
        }

        return (
            labels: labels,
            classifyRevision: classifyRequest.revision,
            classifyElapsedMs: classifyElapsed,
            faceCount: faceCount,
            faceElapsedMs: faceElapsed,
            humanCount: humanCount,
            humanElapsedMs: humanElapsed,
            documentSegmentCount: documentCount,
            documentElapsedMs: documentElapsed
        )
    }

    private static func makeScores(
        isScreenshot: Bool,
        labels: [VisionProbeVisualLabel],
        faceCount: Int,
        humanCount: Int,
        documentSegmentCount: Int
    ) -> VisionProbeScores {
        let labelText = labels.map(\.identifier).joined(separator: " ").lowercased()

        let screenshotScore = isScreenshot ? 1.0 : 0.0
        let personScore = min(1.0, (faceCount > 0 ? 0.75 : 0.0) + (humanCount > 0 ? 0.65 : 0.0))
        let foodScore = keywordScore(labelText, keywords: ["food", "meal", "dish", "plate", "drink", "dessert", "cuisine"])
        let landscapeScore = keywordScore(labelText, keywords: ["landscape", "sky", "mountain", "sea", "beach", "forest", "river", "lake"])
        let buildingScore = keywordScore(labelText, keywords: ["building", "architecture", "house", "skyscraper", "structure", "tower", "city"])
        let constructionScore = keywordScore(labelText, keywords: ["construction", "site", "crane", "truck", "equipment", "machinery", "excavator"])
        let signScore = keywordScore(labelText, keywords: ["sign", "billboard", "poster", "traffic sign", "street sign", "display"])
        let whiteboardScore = keywordScore(labelText, keywords: ["whiteboard", "blackboard", "board", "presentation"])
        let businessCardScore = keywordScore(labelText, keywords: ["card", "business card", "text"])
        let receiptScore = keywordScore(labelText, keywords: ["receipt", "paper", "invoice", "document"])
        let documentLabelScore = keywordScore(labelText, keywords: ["document", "paper", "text", "book", "note", "receipt", "card"])
        let documentScore = max(documentLabelScore, documentSegmentCount > 0 ? 0.75 : 0.0)
        let ocrPriorityScore = min(
            1.0,
            max(documentScore, receiptScore, businessCardScore, whiteboardScore, signScore, screenshotScore * 0.8)
        )

        return VisionProbeScores(
            screenshotScore: screenshotScore,
            documentScore: documentScore,
            personScore: personScore,
            foodScore: foodScore,
            landscapeScore: landscapeScore,
            buildingScore: buildingScore,
            constructionSiteScore: constructionScore,
            signScore: signScore,
            whiteboardScore: whiteboardScore,
            businessCardScore: businessCardScore,
            receiptScore: receiptScore,
            ocrPriorityScore: ocrPriorityScore
        )
    }

    private static func keywordScore(_ text: String, keywords: [String]) -> Double {
        guard text.isEmpty == false else {
            return 0
        }

        let matchedCount = keywords.filter { text.contains($0) }.count
        guard matchedCount > 0 else {
            return 0
        }

        return min(1.0, 0.35 + Double(matchedCount) * 0.2)
    }

    private static func hashIdentifier(_ identifier: String) -> String {
        let digest = SHA256.hash(data: Data(identifier.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func mediaTypeTitle(_ mediaType: PHAssetMediaType) -> String {
        switch mediaType {
        case .image:
            return "image"
        case .video:
            return "video"
        case .audio:
            return "audio"
        case .unknown:
            return "unknown"
        @unknown default:
            return "unknown"
        }
    }

    private static func elapsedMs(since start: Date) -> Double {
        Date().timeIntervalSince(start) * 1000
    }
}

private extension CGImagePropertyOrientation {
    init(_ imageOrientation: UIImage.Orientation) {
        switch imageOrientation {
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
#else
import Combine

@MainActor
final class VisionClassificationBenchmarkRunner: ObservableObject {}
#endif
