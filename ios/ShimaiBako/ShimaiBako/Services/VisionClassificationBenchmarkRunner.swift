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

enum VisionClassificationBenchmarkBucket: String, CaseIterable, Codable, Identifiable {
    case allRecent
    case screenshot
    case nonScreenshot
    case portrait
    case landscape
    case ocrTextAvailable
    case ocrTextMissing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allRecent:
            return "直近"
        case .screenshot:
            return "スクショ"
        case .nonScreenshot:
            return "スクショ以外"
        case .portrait:
            return "縦長"
        case .landscape:
            return "横長"
        case .ocrTextAvailable:
            return "読取済み"
        case .ocrTextMissing:
            return "読取なし"
        }
    }

    var runIDComponent: String {
        switch self {
        case .allRecent:
            return "recent"
        case .screenshot:
            return "screenshot"
        case .nonScreenshot:
            return "non_screenshot"
        case .portrait:
            return "portrait"
        case .landscape:
            return "landscape"
        case .ocrTextAvailable:
            return "ocr_available"
        case .ocrTextMissing:
            return "ocr_missing"
        }
    }
}

struct VisionProbeScores: Codable, Hashable {
    let screenshotScore: Double
    let documentLabelScore: Double
    let documentVisualScore: Double
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
    let bucketName: String
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
    let taxonomyMatches: [String: [String]]
    let unavailableReason: String?
}

struct VisionClassificationBenchmarkReport: Codable, Hashable {
    let runID: String
    let bucketName: String
    let bucketTitle: String
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
    let nonScreenshotCount: Int
    let screenshotCandidateCount: Int
    let faceDetectedCount: Int
    let humanDetectedCount: Int
    let documentSegmentationDetectedCount: Int
    let documentLabelCandidateCount: Int
    let finalDocumentCandidateCount: Int
    let ocrPriorityCandidateCount: Int
    let likelyDocumentCount: Int
    let likelyBuildingCount: Int
    let likelySignCount: Int
    let likelyWhiteboardCount: Int
    let likelyReceiptCount: Int
    let likelyBusinessCardCount: Int
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

    func run(
        limit: Int,
        bucket: VisionClassificationBenchmarkBucket = .allRecent
    ) async {
        guard isRunning == false else {
            return
        }

        isRunning = true
        errorMessage = nil
        latestStatus = "Vision分類ベンチを準備しています"
        progressText = nil

        let requestedCount = max(1, min(limit, 100))
        let startedAt = Date()
        let runID = Self.runID(startedAt: startedAt, limit: requestedCount, bucket: bucket)
        let supportedSummary = Self.makeSupportedIdentifierSummary()
        let selection = fetchImageAssets(limit: requestedCount, bucket: bucket)
        let assets = selection.assets
        var results: [VisionClassificationProbeResult] = []
        results.reserveCapacity(assets.count)

        for (index, asset) in assets.enumerated() {
            if Task.isCancelled {
                break
            }

            latestStatus = "解析中"
            progressText = "\(index + 1) / \(assets.count)件"

            let result = await probeService.analyze(asset: asset, bucketName: bucket.rawValue)
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
            bucketName: bucket.rawValue,
            bucketTitle: bucket.title,
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
            nonScreenshotCount: results.filter { $0.isScreenshot == false }.count,
            screenshotCandidateCount: results.filter { $0.scores.screenshotScore >= 0.7 }.count,
            faceDetectedCount: results.filter(\.hasFace).count,
            humanDetectedCount: results.filter(\.hasHuman).count,
            documentSegmentationDetectedCount: results.filter(\.hasDocumentSegment).count,
            documentLabelCandidateCount: results.filter { $0.scores.documentLabelScore >= 0.45 }.count,
            finalDocumentCandidateCount: results.filter { $0.scores.documentScore >= 0.55 }.count,
            ocrPriorityCandidateCount: results.filter { $0.scores.ocrPriorityScore >= 0.75 }.count,
            likelyDocumentCount: results.filter { $0.scores.documentScore >= 0.55 }.count,
            likelyBuildingCount: results.filter { $0.scores.buildingScore >= 0.45 }.count,
            likelySignCount: results.filter { $0.scores.signScore >= 0.45 }.count,
            likelyWhiteboardCount: results.filter { $0.scores.whiteboardScore >= 0.45 }.count,
            likelyReceiptCount: results.filter { $0.scores.receiptScore >= 0.45 }.count,
            likelyBusinessCardCount: results.filter { $0.scores.businessCardScore >= 0.45 }.count,
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

    private func fetchImageAssets(
        limit: Int,
        bucket: VisionClassificationBenchmarkBucket
    ) -> (
        authorizationStatus: String,
        totalAvailableImageCount: Int,
        assets: [PHAsset]
    ) {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.fetchLimit = bucket == .allRecent ? limit : max(2000, limit)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let countOptions = PHFetchOptions()
        countOptions.includeHiddenAssets = false
        let totalCount = PHAsset.fetchAssets(with: .image, options: countOptions).count
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(min(limit, result.count))
        result.enumerateObjects { asset, _, stop in
            guard assets.count < limit else {
                stop.pointee = true
                return
            }

            guard Self.asset(asset, matches: bucket) else {
                return
            }

            assets.append(asset)
        }
        return (Self.authorizationStatusTitle(status), totalCount, assets)
    }

    private static func asset(_ asset: PHAsset, matches bucket: VisionClassificationBenchmarkBucket) -> Bool {
        let isScreenshot = asset.mediaSubtypes.contains(.photoScreenshot)
        switch bucket {
        case .allRecent:
            return true
        case .screenshot:
            return isScreenshot
        case .nonScreenshot:
            return isScreenshot == false
        case .portrait:
            return asset.pixelHeight > asset.pixelWidth
        case .landscape:
            return asset.pixelWidth >= asset.pixelHeight
        case .ocrTextAvailable, .ocrTextMissing:
            return true
        }
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
        - bucketName: \(report.bucketName)
        - bucketTitle: \(report.bucketTitle)
        - device: \(report.deviceName)
        - photo authorization: \(report.photoAuthorizationStatus)
        - available image count: \(report.totalAvailableImageCount)
        - requested count: \(report.requestedCount)
        - actual count: \(report.actualCount)
        - average ms/asset: \(String(format: "%.1f", report.averageMsPerAsset))
        - max ms/asset: \(String(format: "%.1f", report.maxMsPerAsset))
        - failed: \(report.failedCount)

        ## Signals
        - screenshots: \(report.screenshotCandidateCount)
        - nonScreenshots: \(report.nonScreenshotCount)
        - face detected: \(report.faceDetectedCount)
        - human detected: \(report.humanDetectedCount)
        - documentSegmentationDetected: \(report.documentSegmentationDetectedCount)
        - documentLabelCandidate: \(report.documentLabelCandidateCount)
        - finalDocumentCandidate: \(report.finalDocumentCandidateCount)
        - screenshotCandidate: \(report.screenshotCandidateCount)
        - ocrPriorityCandidate: \(report.ocrPriorityCandidateCount)
        - likely building: \(report.likelyBuildingCount)
        - likely construction site: \(report.likelyConstructionSiteCount)
        - likely sign: \(report.likelySignCount)
        - likely food: \(report.likelyFoodCount)
        - likely whiteboard: \(report.likelyWhiteboardCount)
        - likely receipt: \(report.likelyReceiptCount)
        - likely business card: \(report.likelyBusinessCardCount)

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
        let taxonomyMatches = summary.taxonomyMatches.keys.sorted().map { key in
            let values = summary.taxonomyMatches[key] ?? []
            let joined = values.joined(separator: ", ")
            return "- \(key): \(values.count)\(joined.isEmpty ? "" : " / \(joined)")"
        }.joined(separator: "\n")

        return """
        # Supported Identifiers Summary

        - generatedAt: \(ISO8601DateFormatter().string(from: summary.generatedAt))
        - totalCount: \(summary.totalCount)
        - unavailableReason: \(summary.unavailableReason ?? "none")

        ## Keyword Matches
        \(matches.isEmpty ? "- none" : matches)

        ## Taxonomy Matches
        \(taxonomyMatches.isEmpty ? "- none" : taxonomyMatches)
        """
    }

    private func csv(for report: VisionClassificationBenchmarkReport) -> String {
        var lines = [
            [
                "assetHash",
                "bucketName",
                "isScreenshot",
                "pixelWidth",
                "pixelHeight",
                "topLabel1",
                "topLabel1Confidence",
                "topLabel2",
                "topLabel2Confidence",
                "topLabel3",
                "topLabel3Confidence",
                "hasFace",
                "hasHuman",
                "hasDocumentSegmentation",
                "documentLabelScore",
                "documentVisualScore",
                "documentScore",
                "screenshotScore",
                "buildingScore",
                "constructionSiteScore",
                "signScore",
                "whiteboardScore",
                "receiptScore",
                "businessCardScore",
                "ocrPriorityScore",
                "elapsedMs",
                "expectedFormatTags",
                "expectedContentTags",
                "reviewNote",
                "error"
            ].joined(separator: ",")
        ]

        for result in report.results {
            let labels = result.topVisualLabels
            let fields = [
                result.assetIdentifierHash,
                Self.csvEscape(result.bucketName),
                "\(result.isScreenshot)",
                "\(result.pixelWidth)",
                "\(result.pixelHeight)",
                Self.csvEscape(labels[safe: 0]?.identifier ?? ""),
                labels[safe: 0].map { String(format: "%.4f", $0.confidence) } ?? "",
                Self.csvEscape(labels[safe: 1]?.identifier ?? ""),
                labels[safe: 1].map { String(format: "%.4f", $0.confidence) } ?? "",
                Self.csvEscape(labels[safe: 2]?.identifier ?? ""),
                labels[safe: 2].map { String(format: "%.4f", $0.confidence) } ?? "",
                "\(result.hasFace)",
                "\(result.hasHuman)",
                "\(result.hasDocumentSegment)",
                String(format: "%.3f", result.scores.documentLabelScore),
                String(format: "%.3f", result.scores.documentVisualScore),
                String(format: "%.3f", result.scores.documentScore),
                String(format: "%.3f", result.scores.screenshotScore),
                String(format: "%.3f", result.scores.buildingScore),
                String(format: "%.3f", result.scores.constructionSiteScore),
                String(format: "%.3f", result.scores.signScore),
                String(format: "%.3f", result.scores.whiteboardScore),
                String(format: "%.3f", result.scores.receiptScore),
                String(format: "%.3f", result.scores.businessCardScore),
                String(format: "%.3f", result.scores.ocrPriorityScore),
                String(format: "%.1f", result.elapsedMs),
                "",
                "",
                "",
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

    private static func runID(
        startedAt: Date,
        limit: Int,
        bucket: VisionClassificationBenchmarkBucket
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return "\(formatter.string(from: startedAt))_vision_probe_\(bucket.runIDComponent)_\(limit)"
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
                taxonomyMatches: [:],
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
            taxonomyMatches: VisionClassificationTaxonomy.supportedIdentifierMatches(from: identifiers),
            unavailableReason: nil
        )
    }
}

private struct VisionProbeVisualMetrics {
    let brightPixelRatio: Double
    let aspectRatio: Double

    static let empty = VisionProbeVisualMetrics(brightPixelRatio: 0, aspectRatio: 1)
}

final class VisionClassificationProbeService {
    private let imageManager = PHImageManager.default()
    private let targetSize = CGSize(width: 640, height: 640)

    func analyze(asset: PHAsset, bucketName: String) async -> VisionClassificationProbeResult {
        let overallStart = Date()
        let assetHash = Self.hashIdentifier(asset.localIdentifier)
        let isScreenshot = asset.mediaSubtypes.contains(.photoScreenshot)

        guard let image = await requestImage(for: asset), let cgImage = image.cgImage else {
            return VisionClassificationProbeResult(
                assetIdentifierHash: assetHash,
                bucketName: bucketName,
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
                    documentSegmentCount: 0,
                    visualMetrics: .empty
                ),
                elapsedMs: Self.elapsedMs(since: overallStart),
                errorMessage: "画像を取得できませんでした"
            )
        }

        do {
            let vision = try performVision(cgImage: cgImage, orientation: CGImagePropertyOrientation(image.imageOrientation))
            let visualMetrics = Self.makeVisualMetrics(cgImage: cgImage)
            let scores = Self.makeScores(
                isScreenshot: isScreenshot,
                labels: vision.labels,
                faceCount: vision.faceCount,
                humanCount: vision.humanCount,
                documentSegmentCount: vision.documentSegmentCount,
                visualMetrics: visualMetrics
            )

            return VisionClassificationProbeResult(
                assetIdentifierHash: assetHash,
                bucketName: bucketName,
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
                bucketName: bucketName,
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
                    documentSegmentCount: 0,
                    visualMetrics: .empty
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
        documentSegmentCount: Int,
        visualMetrics: VisionProbeVisualMetrics
    ) -> VisionProbeScores {
        let screenshotScore = isScreenshot ? 1.0 : 0.0
        let personScore = min(1.0, (faceCount > 0 ? 0.75 : 0.0) + (humanCount > 0 ? 0.65 : 0.0))
        let foodScore = VisionClassificationTaxonomy.score(labels: labels, matching: VisionClassificationTaxonomy.foodLabels)
        let landscapeScore = VisionClassificationTaxonomy.score(labels: labels, matching: VisionClassificationTaxonomy.landscapeLabels)
        let buildingScore = VisionClassificationTaxonomy.score(labels: labels, matching: VisionClassificationTaxonomy.buildingLabels)
        let constructionScore = max(
            VisionClassificationTaxonomy.score(labels: labels, matching: VisionClassificationTaxonomy.constructionSiteLabels),
            VisionClassificationTaxonomy.score(labels: labels, matching: VisionClassificationTaxonomy.vehicleHeavyEquipmentLabels) * 0.35
        )
        let signScore = VisionClassificationTaxonomy.score(labels: labels, matching: VisionClassificationTaxonomy.signLabels)
        let whiteboardScore = VisionClassificationTaxonomy.score(labels: labels, matching: VisionClassificationTaxonomy.whiteboardLabels)
        let receiptScore = VisionClassificationTaxonomy.score(labels: labels, matching: VisionClassificationTaxonomy.receiptLabels)
        let businessCardScore = VisionClassificationTaxonomy.score(labels: labels, matching: VisionClassificationTaxonomy.businessCardLabels) * 0.75
        let documentLabelScore = max(
            VisionClassificationTaxonomy.score(labels: labels, matching: VisionClassificationTaxonomy.documentLabels),
            max(receiptScore, businessCardScore) * 0.8
        )
        let documentVisualScore = Self.documentVisualScore(from: visualMetrics)
        let documentSegmentationScore = documentSegmentCount > 0 ? 0.35 : 0.0
        let unsuppressedDocumentScore = max(
            documentLabelScore,
            max(receiptScore, businessCardScore),
            min(1.0, documentSegmentationScore + documentVisualScore * 0.45)
        )
        let documentScore = isScreenshot
            ? min(0.35, max(documentLabelScore * 0.5, documentVisualScore * 0.4))
            : unsuppressedDocumentScore
        let ocrPriorityScore = min(
            1.0,
            max(
                receiptScore,
                businessCardScore,
                documentScore * 0.9,
                signScore * 0.9,
                whiteboardScore * 0.9,
                screenshotScore * 0.85,
                buildingScore > 0.45 && signScore > 0.35 ? 0.75 : 0.1
            )
        )

        return VisionProbeScores(
            screenshotScore: screenshotScore,
            documentLabelScore: documentLabelScore,
            documentVisualScore: documentVisualScore,
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

    private static func documentVisualScore(from metrics: VisionProbeVisualMetrics) -> Double {
        let brightScore: Double
        switch metrics.brightPixelRatio {
        case 0.78...:
            brightScore = 0.45
        case 0.62..<0.78:
            brightScore = 0.3
        case 0.48..<0.62:
            brightScore = 0.15
        default:
            brightScore = 0
        }

        let ratio = metrics.aspectRatio
        let ratioScore = (0.62...1.62).contains(ratio) ? 0.25 : 0.05
        return min(1.0, brightScore + ratioScore)
    }

    private static func makeVisualMetrics(cgImage: CGImage) -> VisionProbeVisualMetrics {
        let sampleWidth = 24
        let sampleHeight = 24
        let bytesPerPixel = 4
        let bytesPerRow = sampleWidth * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: sampleHeight * bytesPerRow)

        guard let context = CGContext(
            data: &pixels,
            width: sampleWidth,
            height: sampleHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return VisionProbeVisualMetrics(
                brightPixelRatio: 0,
                aspectRatio: Double(cgImage.width) / Double(max(cgImage.height, 1))
            )
        }

        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))

        var brightCount = 0
        for offset in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            let red = Double(pixels[offset])
            let green = Double(pixels[offset + 1])
            let blue = Double(pixels[offset + 2])
            let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            if luminance >= 218 {
                brightCount += 1
            }
        }

        return VisionProbeVisualMetrics(
            brightPixelRatio: Double(brightCount) / Double(sampleWidth * sampleHeight),
            aspectRatio: Double(cgImage.width) / Double(max(cgImage.height, 1))
        )
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

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
#else
import Combine

@MainActor
final class VisionClassificationBenchmarkRunner: ObservableObject {}
#endif
