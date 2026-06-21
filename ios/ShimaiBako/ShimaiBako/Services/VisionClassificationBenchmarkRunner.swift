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

enum VisionClassificationProbeMode: String, CaseIterable, Codable, Identifiable {
    case full
    case gated

    var id: String { rawValue }

    var title: String {
        switch self {
        case .full:
            return "fullProbe"
        case .gated:
            return "gatedProbe"
        }
    }

    var runIDComponent: String {
        switch self {
        case .full:
            return "full"
        case .gated:
            return "gated"
        }
    }
}

enum VisionBenchmarkReviewQueueKind: String, CaseIterable, Identifiable {
    case all
    case ocrPriority
    case building
    case constructionSite
    case sign
    case whiteboard
    case document

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "最新ベンチ"
        case .ocrPriority:
            return "OCR優先候補"
        case .building:
            return "建物候補"
        case .constructionSite:
            return "工事現場候補"
        case .sign:
            return "看板候補"
        case .whiteboard:
            return "白板候補"
        case .document:
            return "書類候補"
        }
    }
}

struct VisionProbeTimingBreakdown: Codable, Hashable {
    let imageRequestMs: Double
    let classifyImageMs: Double
    let faceDetectionMs: Double
    let humanDetectionMs: Double
    let documentSegmentationMs: Double
    let visualFeatureMs: Double
    let scoringMs: Double
    let totalElapsedMs: Double

    static let empty = VisionProbeTimingBreakdown(
        imageRequestMs: 0,
        classifyImageMs: 0,
        faceDetectionMs: 0,
        humanDetectionMs: 0,
        documentSegmentationMs: 0,
        visualFeatureMs: 0,
        scoringMs: 0,
        totalElapsedMs: 0
    )
}

struct VisionProbeScores: Codable, Hashable {
    let screenshotScore: Double
    let documentLabelScore: Double
    let documentVisualScore: Double
    let documentSegmentationScore: Double
    let documentScoreWithoutSegmentation: Double
    let documentScore: Double
    let personScore: Double
    let foodScore: Double
    let landscapeScore: Double
    let buildingScore: Double
    let constructionSiteScore: Double
    let vehicleHeavyEquipmentScore: Double
    let materialEquipmentScore: Double
    let signScore: Double
    let whiteboardScore: Double
    let businessCardScore: Double
    let receiptScore: Double
    let ocrPriorityScore: Double
}

enum ClassificationImageSource: Hashable {
    case photoAsset(localIdentifier: String)
    case fileURL(URL)
}

struct ClassificationMetadata: Codable, Hashable {
    let isScreenshot: Bool?
    let pixelWidth: Int
    let pixelHeight: Int
    let orientation: String

    static func fileImage(pixelWidth: Int, pixelHeight: Int, isScreenshot: Bool?) -> ClassificationMetadata {
        ClassificationMetadata(
            isScreenshot: isScreenshot,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            orientation: "up"
        )
    }
}

struct ExpectedClassification: Codable, Hashable {
    let formatTags: [String]
    let contentTags: [String]
    let ocrNeeded: Bool
}

struct FixtureProvenance: Codable, Hashable {
    let layer: String
    let split: String
    let source: String
    let licenseID: String?
    let approved: Bool
    let reviewNote: String?
}

struct ClassificationSample: Identifiable, Hashable {
    let id: String
    let imageSource: ClassificationImageSource
    let metadata: ClassificationMetadata
    let expected: ExpectedClassification?
    let provenance: FixtureProvenance?
}

struct VisionClassificationProbeResult: Codable, Identifiable, Hashable {
    var id: String { assetIdentifierHash }

    let assetIdentifierHash: String
    let bucketName: String
    let probeMode: String
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
    let timing: VisionProbeTimingBreakdown
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
    let probeMode: String
    let probeModeTitle: String
    let deviceName: String
    let photoAuthorizationStatus: String
    let totalAvailableImageCount: Int
    let requestedCount: Int
    let actualCount: Int
    let startedAt: Date
    let finishedAt: Date
    let averageMsPerAsset: Double
    let maxMsPerAsset: Double
    let averageImageRequestMs: Double
    let averageClassifyImageMs: Double
    let averageFaceDetectionMs: Double
    let averageHumanDetectionMs: Double
    let averageDocumentSegmentationMs: Double
    let averageVisualFeatureMs: Double
    let averageScoringMs: Double
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
    let likelyVehicleHeavyEquipmentCount: Int
    let likelyMaterialEquipmentCount: Int
    let groundTruthEvaluation: VisionBenchmarkGroundTruthEvaluation?
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
    @Published private(set) var groundTruthEntries: [String: VisionBenchmarkGroundTruthEntry]
    @Published private(set) var latestGroundTruthEvaluation: VisionBenchmarkGroundTruthEvaluation?
    @Published private(set) var reviewQueueResults: [VisionClassificationProbeResult] = []
    @Published private(set) var reviewQueueTitle = "未作成"
    @Published private(set) var reviewIndex = 0
    @Published private(set) var latestEvaluationExportPath: String?
    @Published var errorMessage: String?

    private let fileManager: FileManager
    private let probeService: VisionClassificationProbeService
    private let groundTruthStore: VisionBenchmarkGroundTruthStore
    private var latestReviewAssetsByHash: [String: PHAsset] = [:]

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.probeService = VisionClassificationProbeService()
        self.groundTruthStore = VisionBenchmarkGroundTruthStore(fileManager: fileManager)
        self.groundTruthEntries = groundTruthStore.load()
    }

    var currentReviewResult: VisionClassificationProbeResult? {
        guard reviewQueueResults.indices.contains(reviewIndex) else {
            return nil
        }
        return reviewQueueResults[reviewIndex]
    }

    var reviewQueueCount: Int {
        reviewQueueResults.count
    }

    var currentReviewNumber: Int {
        guard reviewQueueResults.isEmpty == false else {
            return 0
        }
        return reviewIndex + 1
    }

    var reviewQueueLabeledCount: Int {
        reviewQueueResults.filter { result in
            guard let entry = groundTruthEntries[result.assetIdentifierHash] else {
                return false
            }
            return entry.tags.isEmpty == false
        }.count
    }

    var reviewQueueUnlabeledCount: Int {
        max(0, reviewQueueResults.count - reviewQueueLabeledCount)
    }

    var groundTruthSummary: VisionBenchmarkGroundTruthSummary {
        VisionBenchmarkGroundTruthEvaluator.summarize(entriesByHash: groundTruthEntries)
    }

    func run(
        limit: Int,
        bucket: VisionClassificationBenchmarkBucket = .allRecent,
        mode: VisionClassificationProbeMode = .full
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
        let runID = Self.runID(startedAt: startedAt, limit: requestedCount, bucket: bucket, mode: mode)
        let supportedSummary = Self.makeSupportedIdentifierSummary()
        let selection = fetchImageAssets(limit: requestedCount, bucket: bucket)
        let assets = selection.assets
        latestReviewAssetsByHash = Dictionary(
            uniqueKeysWithValues: assets.map { (Self.hashIdentifier($0.localIdentifier), $0) }
        )
        var results: [VisionClassificationProbeResult] = []
        results.reserveCapacity(assets.count)

        for (index, asset) in assets.enumerated() {
            if Task.isCancelled {
                break
            }

            latestStatus = "解析中"
            progressText = "\(index + 1) / \(assets.count)件"

            let result = await probeService.analyze(asset: asset, bucketName: bucket.rawValue, mode: mode)
            results.append(result)
            await Task.yield()
        }

        let finishedAt = Date()
        let elapsedValues = results.map(\.elapsedMs)
        let average = elapsedValues.isEmpty ? 0 : elapsedValues.reduce(0, +) / Double(elapsedValues.count)
        let maxElapsed = elapsedValues.max() ?? 0
        let outputDirectory = outputDirectoryURL()
        let evaluation = VisionBenchmarkGroundTruthEvaluator.evaluate(
            results: results,
            entriesByHash: groundTruthEntries
        )
        let report = VisionClassificationBenchmarkReport(
            runID: runID,
            bucketName: bucket.rawValue,
            bucketTitle: bucket.title,
            probeMode: mode.rawValue,
            probeModeTitle: mode.title,
            deviceName: Self.deviceName(),
            photoAuthorizationStatus: selection.authorizationStatus,
            totalAvailableImageCount: selection.totalAvailableImageCount,
            requestedCount: requestedCount,
            actualCount: results.count,
            startedAt: startedAt,
            finishedAt: finishedAt,
            averageMsPerAsset: average,
            maxMsPerAsset: maxElapsed,
            averageImageRequestMs: Self.average(results.map(\.timing.imageRequestMs)),
            averageClassifyImageMs: Self.average(results.map(\.timing.classifyImageMs)),
            averageFaceDetectionMs: Self.average(results.map(\.timing.faceDetectionMs)),
            averageHumanDetectionMs: Self.average(results.map(\.timing.humanDetectionMs)),
            averageDocumentSegmentationMs: Self.average(results.map(\.timing.documentSegmentationMs)),
            averageVisualFeatureMs: Self.average(results.map(\.timing.visualFeatureMs)),
            averageScoringMs: Self.average(results.map(\.timing.scoringMs)),
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
            likelyVehicleHeavyEquipmentCount: results.filter { $0.scores.vehicleHeavyEquipmentScore >= 0.45 }.count,
            likelyMaterialEquipmentCount: results.filter { $0.scores.materialEquipmentScore >= 0.45 }.count,
            groundTruthEvaluation: evaluation,
            supportedIdentifiers: supportedSummary,
            outputDirectoryPath: outputDirectory.path,
            results: results
        )

        do {
            try write(report: report, to: outputDirectory)
            latestOutputDirectoryPath = outputDirectory.path
            latestStatus = "Vision分類ベンチが完了しました"
            latestReport = report
            latestGroundTruthEvaluation = evaluation
        } catch {
            errorMessage = "ベンチ結果の保存に失敗しました: \(error.localizedDescription)"
            latestStatus = "保存に失敗しました"
            latestReport = report
            latestGroundTruthEvaluation = evaluation
        }

        progressText = "\(results.count) / \(requestedCount)件"
        isRunning = false
    }

    func runReviewQueue(
        title: String,
        limit: Int,
        bucket: VisionClassificationBenchmarkBucket,
        mode: VisionClassificationProbeMode
    ) async {
        await run(limit: limit, bucket: bucket, mode: mode)
        prepareReviewQueue(kind: .all, limit: limit, titleOverride: title)
    }

    func prepareReviewQueue(
        kind: VisionBenchmarkReviewQueueKind,
        limit: Int = 20,
        titleOverride: String? = nil
    ) {
        guard let latestReport else {
            latestStatus = "先にVision分類ベンチを実行してください"
            return
        }

        let matchedResults = latestReport.results.filter { result in
            Self.result(result, matches: kind)
        }
        let queue = Array(matchedResults.prefix(max(1, limit)))
        reviewQueueResults = queue
        reviewIndex = 0
        reviewQueueTitle = titleOverride ?? "\(kind.title)\(min(limit, matchedResults.count))件"

        if queue.isEmpty {
            latestStatus = "\(kind.title)は見つかりませんでした。別のキューか直近100件を試してください"
        } else {
            latestStatus = "\(reviewQueueTitle)を作成しました"
        }
    }

    func moveToNextReviewItem() {
        guard reviewQueueResults.isEmpty == false else {
            return
        }
        reviewIndex = min(reviewIndex + 1, reviewQueueResults.count - 1)
    }

    func moveToPreviousReviewItem() {
        guard reviewQueueResults.isEmpty == false else {
            return
        }
        reviewIndex = max(reviewIndex - 1, 0)
    }

    func saveCurrentReviewAndAdvance() {
        latestStatus = "正解ラベルを保存しました"
        moveToNextReviewItem()
    }

    func skipCurrentReviewItem() {
        latestStatus = "この写真をスキップしました"
        moveToNextReviewItem()
    }

    func markCurrentReviewUnknown() {
        guard let currentReviewResult else {
            return
        }
        setGroundTruthTags([.unknown], for: currentReviewResult)
        moveToNextReviewItem()
    }

    func clearGroundTruthTags(for result: VisionClassificationProbeResult) {
        setGroundTruthTags([], for: result)
    }

    func evaluateLatestGroundTruth() {
        recomputeGroundTruthEvaluation()
        if latestGroundTruthEvaluation?.labeledAssetCount == 0 {
            latestStatus = "正解ラベルがないため評価できません"
        } else {
            latestStatus = "ラベル済みデータで評価しました"
        }
    }

    func exportLatestGroundTruthEvaluation() {
        guard let latestReport else {
            latestStatus = "先にVision分類ベンチを実行してください"
            return
        }

        let evaluation = VisionBenchmarkGroundTruthEvaluator.evaluate(
            results: latestReport.results,
            entriesByHash: groundTruthEntries
        )
        latestGroundTruthEvaluation = evaluation

        let outputDirectory = outputDirectoryURL()
        let runID = Self.p08RunID()
        let entries = groundTruthEntries.values.sorted { lhs, rhs in
            lhs.assetIdentifierHash < rhs.assetIdentifierHash
        }
        let summary = groundTruthSummary

        do {
            try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let groundTruthData = try encoder.encode(entries)
            try groundTruthData.write(
                to: outputDirectory.appendingPathComponent("p08_ground_truth_export_\(runID).json"),
                options: [.atomic]
            )

            try groundTruthSummaryMarkdown(summary: summary, evaluation: evaluation).write(
                to: outputDirectory.appendingPathComponent("p08_ground_truth_summary_\(runID).md"),
                atomically: true,
                encoding: .utf8
            )
            try p08EvaluationMarkdown(evaluation: evaluation, report: latestReport).write(
                to: outputDirectory.appendingPathComponent("p08_evaluation_\(runID).md"),
                atomically: true,
                encoding: .utf8
            )
            try p08EvaluationCSV(evaluation: evaluation).write(
                to: outputDirectory.appendingPathComponent("p08_evaluation_\(runID).csv"),
                atomically: true,
                encoding: .utf8
            )
            try reviewQueueSummaryMarkdown(report: latestReport).write(
                to: outputDirectory.appendingPathComponent("p08_review_queue_summary_\(runID).md"),
                atomically: true,
                encoding: .utf8
            )

            latestOutputDirectoryPath = outputDirectory.path
            latestEvaluationExportPath = outputDirectory.path
            latestStatus = evaluation.labeledAssetCount == 0
                ? "正解ラベルがないため評価は空でexportしました"
                : "P0.8評価結果をexportしました"
        } catch {
            errorMessage = "P0.8評価結果のexportに失敗しました: \(error.localizedDescription)"
        }
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

    func isGroundTruthTagSelected(
        _ tag: VisionBenchmarkGroundTruthTag,
        for result: VisionClassificationProbeResult
    ) -> Bool {
        groundTruthEntries[result.assetIdentifierHash]?.tags.contains(tag) ?? false
    }

    func toggleGroundTruthTag(
        _ tag: VisionBenchmarkGroundTruthTag,
        for result: VisionClassificationProbeResult
    ) {
        var entries = groundTruthEntries
        let now = Date()
        var entry = entries[result.assetIdentifierHash] ?? VisionBenchmarkGroundTruthEntry(
            assetIdentifierHash: result.assetIdentifierHash,
            tags: [],
            note: "",
            createdAt: now,
            updatedAt: now
        )

        if entry.tags.contains(tag) {
            entry.tags.remove(tag)
        } else if tag == .unknown {
            entry.tags = [.unknown]
        } else {
            entry.tags.remove(.unknown)
            entry.tags.insert(tag)
        }
        entry.updatedAt = now

        if entry.tags.isEmpty {
            entries.removeValue(forKey: result.assetIdentifierHash)
        } else {
            entries[result.assetIdentifierHash] = entry
        }

        do {
            try groundTruthStore.save(entries)
            groundTruthEntries = entries
            recomputeGroundTruthEvaluation()
            latestStatus = "正解ラベルを保存しました"
        } catch {
            errorMessage = "正解ラベルの保存に失敗しました: \(error.localizedDescription)"
        }
    }

    private func setGroundTruthTags(
        _ tags: Set<VisionBenchmarkGroundTruthTag>,
        for result: VisionClassificationProbeResult
    ) {
        var entries = groundTruthEntries
        let now = Date()

        if tags.isEmpty {
            entries.removeValue(forKey: result.assetIdentifierHash)
        } else {
            let existing = entries[result.assetIdentifierHash]
            entries[result.assetIdentifierHash] = VisionBenchmarkGroundTruthEntry(
                assetIdentifierHash: result.assetIdentifierHash,
                tags: tags,
                note: existing?.note ?? "",
                createdAt: existing?.createdAt ?? now,
                updatedAt: now
            )
        }

        do {
            try groundTruthStore.save(entries)
            groundTruthEntries = entries
            recomputeGroundTruthEvaluation()
            latestStatus = tags.isEmpty ? "正解ラベルをクリアしました" : "正解ラベルを保存しました"
        } catch {
            errorMessage = "正解ラベルの保存に失敗しました: \(error.localizedDescription)"
        }
    }

    func thumbnail(for result: VisionClassificationProbeResult) async -> UIImage? {
        guard let asset = latestReviewAssetsByHash[result.assetIdentifierHash] else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false
            options.isSynchronous = false

            var didResume = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 120, height: 120),
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                guard didResume == false else {
                    return
                }
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let isCancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let hasError = info?[PHImageErrorKey] != nil

                if let image, isDegraded == false {
                    didResume = true
                    continuation.resume(returning: image)
                } else if isCancelled || hasError {
                    didResume = true
                    continuation.resume(returning: image)
                }
            }
        }
    }

    private func recomputeGroundTruthEvaluation() {
        guard let latestReport else {
            latestGroundTruthEvaluation = nil
            return
        }

        let evaluation = VisionBenchmarkGroundTruthEvaluator.evaluate(
            results: latestReport.results,
            entriesByHash: groundTruthEntries
        )
        latestGroundTruthEvaluation = evaluation
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
        let groundTruthData = try encoder.encode(
            groundTruthEntries.values.sorted { lhs, rhs in
                lhs.assetIdentifierHash < rhs.assetIdentifierHash
            }
        )

        let jsonName = "\(report.runID).json"
        let markdownName = "\(report.runID).md"
        let csvName = "\(report.runID).csv"

        try data.write(to: directory.appendingPathComponent(jsonName), options: [.atomic])
        try data.write(to: directory.appendingPathComponent("vision_benchmark_latest.json"), options: [.atomic])
        try data.write(
            to: directory.appendingPathComponent("p06_results_\(report.runID).json"),
            options: [.atomic]
        )
        try groundTruthData.write(
            to: directory.appendingPathComponent("p06_ground_truth_\(report.runID).json"),
            options: [.atomic]
        )

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
        try markdown(for: report).write(
            to: directory.appendingPathComponent("p06_summary_\(report.runID).md"),
            atomically: true,
            encoding: .utf8
        )
        try timingMarkdown(for: report).write(
            to: directory.appendingPathComponent("p06_timing_breakdown_\(report.runID).md"),
            atomically: true,
            encoding: .utf8
        )
        try evaluationMarkdown(for: report).write(
            to: directory.appendingPathComponent("p06_evaluation_\(report.runID).md"),
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
        try csv(for: report).write(
            to: directory.appendingPathComponent("p06_results_\(report.runID).csv"),
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
        - probeMode: \(report.probeModeTitle)
        - device: \(report.deviceName)
        - photo authorization: \(report.photoAuthorizationStatus)
        - available image count: \(report.totalAvailableImageCount)
        - requested count: \(report.requestedCount)
        - actual count: \(report.actualCount)
        - average ms/asset: \(String(format: "%.1f", report.averageMsPerAsset))
        - max ms/asset: \(String(format: "%.1f", report.maxMsPerAsset))
        - failed: \(report.failedCount)

        ## Timing Breakdown
        - imageRequestMs avg: \(String(format: "%.1f", report.averageImageRequestMs))
        - classifyImageMs avg: \(String(format: "%.1f", report.averageClassifyImageMs))
        - faceDetectionMs avg: \(String(format: "%.1f", report.averageFaceDetectionMs))
        - humanDetectionMs avg: \(String(format: "%.1f", report.averageHumanDetectionMs))
        - documentSegmentationMs avg: \(String(format: "%.1f", report.averageDocumentSegmentationMs))
        - visualFeatureMs avg: \(String(format: "%.1f", report.averageVisualFeatureMs))
        - scoringMs avg: \(String(format: "%.1f", report.averageScoringMs))

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
        - likely vehicle/heavy equipment: \(report.likelyVehicleHeavyEquipmentCount)
        - likely material/equipment: \(report.likelyMaterialEquipmentCount)

        ## Ground Truth Evaluation
        \(groundTruthEvaluationMarkdown(report.groundTruthEvaluation))

        ## Top Label Examples
        \(topLabelExamples.isEmpty ? "- none" : topLabelExamples)

        ## Safety
        - image bodies are not saved
        - thumbnails are not saved
        - face images and face templates are not saved
        - Photos library assets are read only
        """
    }

    private func groundTruthEvaluationMarkdown(_ evaluation: VisionBenchmarkGroundTruthEvaluation?) -> String {
        guard let evaluation else {
            return "- labeled assets: 0\n- evaluation: none"
        }

        let lines = evaluation.metrics.map { metric in
            "- \(metric.tag.rawValue): support \(metric.support), TP \(metric.truePositive), FP \(metric.falsePositive), FN \(metric.falseNegative), precision \(String(format: "%.2f", metric.precision)), recall \(String(format: "%.2f", metric.recall))"
        }
        .joined(separator: "\n")

        return """
        - labeled assets: \(evaluation.labeledAssetCount)
        \(lines.isEmpty ? "- metrics: none" : lines)
        """
    }

    private func timingMarkdown(for report: VisionClassificationBenchmarkReport) -> String {
        """
        # P0.6 Timing Breakdown

        - runID: \(report.runID)
        - bucket: \(report.bucketTitle)
        - probeMode: \(report.probeModeTitle)
        - actualCount: \(report.actualCount)
        - averageTotalMs: \(String(format: "%.1f", report.averageMsPerAsset))
        - averageImageRequestMs: \(String(format: "%.1f", report.averageImageRequestMs))
        - averageClassifyImageMs: \(String(format: "%.1f", report.averageClassifyImageMs))
        - averageFaceDetectionMs: \(String(format: "%.1f", report.averageFaceDetectionMs))
        - averageHumanDetectionMs: \(String(format: "%.1f", report.averageHumanDetectionMs))
        - averageDocumentSegmentationMs: \(String(format: "%.1f", report.averageDocumentSegmentationMs))
        - averageVisualFeatureMs: \(String(format: "%.1f", report.averageVisualFeatureMs))
        - averageScoringMs: \(String(format: "%.1f", report.averageScoringMs))

        ## Notes
        - gatedProbe skips image loading and heavy Vision requests for screenshots.
        - fullProbe runs image classification, face rectangles, human rectangles, document segmentation, visual metrics, and scoring.
        - Images and thumbnails are not written to evidence.
        """
    }

    private func evaluationMarkdown(for report: VisionClassificationBenchmarkReport) -> String {
        """
        # P0.6 Ground Truth Evaluation

        - runID: \(report.runID)
        - bucket: \(report.bucketTitle)
        - probeMode: \(report.probeModeTitle)

        ## Metrics
        \(groundTruthEvaluationMarkdown(report.groundTruthEvaluation))

        ## Safety
        - ground truth stores hashed asset identifiers and labels only.
        - image bodies, thumbnails, face images, and face templates are not saved.
        """
    }

    private func groundTruthSummaryMarkdown(
        summary: VisionBenchmarkGroundTruthSummary,
        evaluation: VisionBenchmarkGroundTruthEvaluation
    ) -> String {
        let tagLines = summary.tagSummaries.map { item in
            "- \(item.tag.title): \(item.count)"
        }.joined(separator: "\n")

        return """
        # P0.8 Ground Truth Summary

        - reviewedCount: \(summary.reviewedCount)
        - evaluableCount: \(summary.evaluableCount)
        - unknownCount: \(summary.unknownCount)
        - evaluatedAt: \(ISO8601DateFormatter().string(from: evaluation.evaluatedAt))

        ## Tags
        \(tagLines.isEmpty ? "- none" : tagLines)

        ## Notes
        - asset identifiers are hashed.
        - image bodies and thumbnails are not exported.
        - face images and face templates are not exported.
        """
    }

    private func p08EvaluationMarkdown(
        evaluation: VisionBenchmarkGroundTruthEvaluation,
        report: VisionClassificationBenchmarkReport
    ) -> String {
        """
        # P0.8 Ground Truth Evaluation

        - sourceRunID: \(report.runID)
        - bucket: \(report.bucketTitle)
        - probeMode: \(report.probeModeTitle)
        - labeledAssets: \(evaluation.labeledAssetCount)
        - evaluatedAt: \(ISO8601DateFormatter().string(from: evaluation.evaluatedAt))

        ## Metrics
        \(groundTruthEvaluationMarkdown(evaluation))

        ## Empty Label Handling
        \(evaluation.labeledAssetCount == 0 ? "- 正解ラベルがないためprecision / recallは参考値なしです。" : "- ラベル済みデータで再評価しました。")

        ## Safety
        - 画像本体は出力しません。
        - サムネイル本体は出力しません。
        - 顔画像/顔テンプレートは出力しません。
        """
    }

    private func p08EvaluationCSV(evaluation: VisionBenchmarkGroundTruthEvaluation) -> String {
        var lines = [
            "tag,support,truePositive,falsePositive,falseNegative,precision,recall"
        ]
        for metric in evaluation.metrics {
            lines.append([
                Self.csvEscape(metric.tag.rawValue),
                "\(metric.support)",
                "\(metric.truePositive)",
                "\(metric.falsePositive)",
                "\(metric.falseNegative)",
                String(format: "%.4f", metric.precision),
                String(format: "%.4f", metric.recall)
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func reviewQueueSummaryMarkdown(report: VisionClassificationBenchmarkReport) -> String {
        let queueLines = reviewQueueResults.enumerated().map { index, result in
            let predicted = result.predictedGroundTruthTags.map(\.rawValue).sorted().joined(separator: "|")
            let labels = groundTruthEntries[result.assetIdentifierHash]?.tags.map(\.rawValue).sorted().joined(separator: "|") ?? ""
            return "- \(index + 1). \(result.assetIdentifierHash.prefix(12)) predicted=\(predicted.isEmpty ? "none" : predicted) labels=\(labels.isEmpty ? "none" : labels)"
        }.joined(separator: "\n")

        return """
        # P0.8 Review Queue Summary

        - sourceRunID: \(report.runID)
        - queueTitle: \(reviewQueueTitle)
        - queueCount: \(reviewQueueResults.count)
        - labeledInQueue: \(reviewQueueLabeledCount)
        - unlabeledInQueue: \(reviewQueueUnlabeledCount)

        ## Items
        \(queueLines.isEmpty ? "- none" : queueLines)

        ## Safety
        - asset identifiers are hashed.
        - no image or thumbnail data is exported.
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
                "probeMode",
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
                "documentSegmentationScore",
                "documentScoreWithoutSegmentation",
                "documentScore",
                "screenshotScore",
                "buildingScore",
                "constructionSiteScore",
                "vehicleHeavyEquipmentScore",
                "materialEquipmentScore",
                "signScore",
                "whiteboardScore",
                "receiptScore",
                "businessCardScore",
                "ocrPriorityScore",
                "imageRequestMs",
                "classifyImageMs",
                "faceDetectionMs",
                "humanDetectionMs",
                "documentSegmentationMs",
                "visualFeatureMs",
                "scoringMs",
                "elapsedMs",
                "predictedTags",
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
                Self.csvEscape(result.probeMode),
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
                String(format: "%.3f", result.scores.documentSegmentationScore),
                String(format: "%.3f", result.scores.documentScoreWithoutSegmentation),
                String(format: "%.3f", result.scores.documentScore),
                String(format: "%.3f", result.scores.screenshotScore),
                String(format: "%.3f", result.scores.buildingScore),
                String(format: "%.3f", result.scores.constructionSiteScore),
                String(format: "%.3f", result.scores.vehicleHeavyEquipmentScore),
                String(format: "%.3f", result.scores.materialEquipmentScore),
                String(format: "%.3f", result.scores.signScore),
                String(format: "%.3f", result.scores.whiteboardScore),
                String(format: "%.3f", result.scores.receiptScore),
                String(format: "%.3f", result.scores.businessCardScore),
                String(format: "%.3f", result.scores.ocrPriorityScore),
                String(format: "%.1f", result.timing.imageRequestMs),
                String(format: "%.1f", result.timing.classifyImageMs),
                String(format: "%.1f", result.timing.faceDetectionMs),
                String(format: "%.1f", result.timing.humanDetectionMs),
                String(format: "%.1f", result.timing.documentSegmentationMs),
                String(format: "%.1f", result.timing.visualFeatureMs),
                String(format: "%.1f", result.timing.scoringMs),
                String(format: "%.1f", result.elapsedMs),
                Self.csvEscape(result.predictedGroundTruthTags.map(\.rawValue).sorted().joined(separator: "|")),
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
        bucket: VisionClassificationBenchmarkBucket,
        mode: VisionClassificationProbeMode
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return "\(formatter.string(from: startedAt))_vision_probe_\(bucket.runIDComponent)_\(mode.runIDComponent)_\(limit)"
    }

    private static func p08RunID() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return "\(formatter.string(from: Date()))_p08_ground_truth"
    }

    private static func deviceName() -> String {
        #if targetEnvironment(simulator)
        return "Simulator \(UIDevice.current.model)"
        #else
        return UIDevice.current.name
        #endif
    }

    private static func hashIdentifier(_ identifier: String) -> String {
        let digest = SHA256.hash(data: Data(identifier.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func average(_ values: [Double]) -> Double {
        guard values.isEmpty == false else {
            return 0
        }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func result(
        _ result: VisionClassificationProbeResult,
        matches kind: VisionBenchmarkReviewQueueKind
    ) -> Bool {
        switch kind {
        case .all:
            return true
        case .ocrPriority:
            return result.scores.ocrPriorityScore >= 0.75
        case .building:
            return result.scores.buildingScore >= 0.45
        case .constructionSite:
            return result.scores.constructionSiteScore >= 0.35
        case .sign:
            return result.scores.signScore >= 0.45
        case .whiteboard:
            return result.scores.whiteboardScore >= 0.45
        case .document:
            return result.scores.documentScore >= 0.55
        }
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

    func analyze(
        asset: PHAsset,
        bucketName: String,
        mode: VisionClassificationProbeMode
    ) async -> VisionClassificationProbeResult {
        let overallStart = Date()
        let assetHash = Self.hashIdentifier(asset.localIdentifier)
        let isScreenshot = asset.mediaSubtypes.contains(.photoScreenshot)

        if mode == .gated, isScreenshot {
            let scoringStart = Date()
            let scores = Self.makeScores(
                isScreenshot: true,
                labels: [],
                faceCount: 0,
                humanCount: 0,
                documentSegmentCount: 0,
                visualMetrics: .empty,
                forceScreenshotFastPath: true
            )
            let elapsed = Self.elapsedMs(since: overallStart)
            return Self.makeResult(
                asset: asset,
                assetHash: assetHash,
                bucketName: bucketName,
                mode: mode,
                isScreenshot: true,
                labels: [],
                classifyRevision: 0,
                classifyElapsedMs: 0,
                faceCount: 0,
                faceElapsedMs: 0,
                humanCount: 0,
                humanElapsedMs: 0,
                documentSegmentCount: 0,
                documentElapsedMs: 0,
                scores: scores,
                timing: VisionProbeTimingBreakdown(
                    imageRequestMs: 0,
                    classifyImageMs: 0,
                    faceDetectionMs: 0,
                    humanDetectionMs: 0,
                    documentSegmentationMs: 0,
                    visualFeatureMs: 0,
                    scoringMs: Self.elapsedMs(since: scoringStart),
                    totalElapsedMs: elapsed
                ),
                elapsedMs: elapsed,
                errorMessage: nil
            )
        }

        let imageResult = await requestImage(for: asset)
        guard let image = imageResult.image, let cgImage = image.cgImage else {
            let scoringStart = Date()
            let scores = Self.makeScores(
                isScreenshot: isScreenshot,
                labels: [],
                faceCount: 0,
                humanCount: 0,
                documentSegmentCount: 0,
                visualMetrics: .empty
            )
            let elapsed = Self.elapsedMs(since: overallStart)
            return Self.makeResult(
                asset: asset,
                assetHash: assetHash,
                bucketName: bucketName,
                mode: mode,
                isScreenshot: isScreenshot,
                labels: [],
                classifyRevision: 0,
                classifyElapsedMs: 0,
                faceCount: 0,
                faceElapsedMs: 0,
                humanCount: 0,
                humanElapsedMs: 0,
                documentSegmentCount: 0,
                documentElapsedMs: 0,
                scores: scores,
                timing: VisionProbeTimingBreakdown(
                    imageRequestMs: imageResult.elapsedMs,
                    classifyImageMs: 0,
                    faceDetectionMs: 0,
                    humanDetectionMs: 0,
                    documentSegmentationMs: 0,
                    visualFeatureMs: 0,
                    scoringMs: Self.elapsedMs(since: scoringStart),
                    totalElapsedMs: elapsed
                ),
                elapsedMs: elapsed,
                errorMessage: "画像を取得できませんでした"
            )
        }

        do {
            let vision = try performVision(cgImage: cgImage, orientation: CGImagePropertyOrientation(image.imageOrientation))
            let visualStart = Date()
            let visualMetrics = Self.makeVisualMetrics(cgImage: cgImage)
            let visualElapsed = Self.elapsedMs(since: visualStart)
            let scoringStart = Date()
            let scores = Self.makeScores(
                isScreenshot: isScreenshot,
                labels: vision.labels,
                faceCount: vision.faceCount,
                humanCount: vision.humanCount,
                documentSegmentCount: vision.documentSegmentCount,
                visualMetrics: visualMetrics
            )
            let scoringElapsed = Self.elapsedMs(since: scoringStart)
            let elapsed = Self.elapsedMs(since: overallStart)

            return Self.makeResult(
                asset: asset,
                assetHash: assetHash,
                bucketName: bucketName,
                mode: mode,
                isScreenshot: isScreenshot,
                labels: vision.labels,
                classifyRevision: vision.classifyRevision,
                classifyElapsedMs: vision.classifyElapsedMs,
                faceCount: vision.faceCount,
                faceElapsedMs: vision.faceElapsedMs,
                humanCount: vision.humanCount,
                humanElapsedMs: vision.humanElapsedMs,
                documentSegmentCount: vision.documentSegmentCount,
                documentElapsedMs: vision.documentElapsedMs,
                scores: scores,
                timing: VisionProbeTimingBreakdown(
                    imageRequestMs: imageResult.elapsedMs,
                    classifyImageMs: vision.classifyElapsedMs,
                    faceDetectionMs: vision.faceElapsedMs,
                    humanDetectionMs: vision.humanElapsedMs,
                    documentSegmentationMs: vision.documentElapsedMs,
                    visualFeatureMs: visualElapsed,
                    scoringMs: scoringElapsed,
                    totalElapsedMs: elapsed
                ),
                elapsedMs: elapsed,
                errorMessage: nil
            )
        } catch {
            let scoringStart = Date()
            let scores = Self.makeScores(
                    isScreenshot: isScreenshot,
                    labels: [],
                    faceCount: 0,
                    humanCount: 0,
                    documentSegmentCount: 0,
                    visualMetrics: .empty
            )
            let elapsed = Self.elapsedMs(since: overallStart)
            return Self.makeResult(
                asset: asset,
                assetHash: assetHash,
                bucketName: bucketName,
                mode: mode,
                isScreenshot: isScreenshot,
                labels: [],
                classifyRevision: 0,
                classifyElapsedMs: 0,
                faceCount: 0,
                faceElapsedMs: 0,
                humanCount: 0,
                humanElapsedMs: 0,
                documentSegmentCount: 0,
                documentElapsedMs: 0,
                scores: scores,
                timing: VisionProbeTimingBreakdown(
                    imageRequestMs: imageResult.elapsedMs,
                    classifyImageMs: 0,
                    faceDetectionMs: 0,
                    humanDetectionMs: 0,
                    documentSegmentationMs: 0,
                    visualFeatureMs: 0,
                    scoringMs: Self.elapsedMs(since: scoringStart),
                    totalElapsedMs: elapsed
                ),
                elapsedMs: elapsed,
                errorMessage: error.localizedDescription
            )
        }
    }

    func analyze(
        sample: ClassificationSample,
        bucketName: String,
        mode: VisionClassificationProbeMode
    ) async -> VisionClassificationProbeResult {
        let overallStart = Date()
        let sampleHash = Self.hashIdentifier(sample.id)
        let isScreenshot = sample.metadata.isScreenshot ?? false

        guard case let .fileURL(fileURL) = sample.imageSource else {
            let scoringStart = Date()
            let scores = Self.makeScores(
                isScreenshot: isScreenshot,
                labels: [],
                faceCount: 0,
                humanCount: 0,
                documentSegmentCount: 0,
                visualMetrics: .empty
            )
            let elapsed = Self.elapsedMs(since: overallStart)
            return Self.makeResult(
                assetIdentifierHash: sampleHash,
                bucketName: bucketName,
                mode: mode,
                pixelWidth: sample.metadata.pixelWidth,
                pixelHeight: sample.metadata.pixelHeight,
                mediaType: "fileImage",
                mediaSubtypesRawValue: 0,
                isScreenshot: isScreenshot,
                hasCreationDate: false,
                labels: [],
                classifyRevision: 0,
                classifyElapsedMs: 0,
                faceCount: 0,
                faceElapsedMs: 0,
                humanCount: 0,
                humanElapsedMs: 0,
                documentSegmentCount: 0,
                documentElapsedMs: 0,
                scores: scores,
                timing: VisionProbeTimingBreakdown(
                    imageRequestMs: 0,
                    classifyImageMs: 0,
                    faceDetectionMs: 0,
                    humanDetectionMs: 0,
                    documentSegmentationMs: 0,
                    visualFeatureMs: 0,
                    scoringMs: Self.elapsedMs(since: scoringStart),
                    totalElapsedMs: elapsed
                ),
                elapsedMs: elapsed,
                errorMessage: "File benchmark requires fileURL imageSource"
            )
        }

        if mode == .gated, isScreenshot {
            let scoringStart = Date()
            let scores = Self.makeScores(
                isScreenshot: true,
                labels: [],
                faceCount: 0,
                humanCount: 0,
                documentSegmentCount: 0,
                visualMetrics: .empty,
                forceScreenshotFastPath: true
            )
            let elapsed = Self.elapsedMs(since: overallStart)
            return Self.makeResult(
                assetIdentifierHash: sampleHash,
                bucketName: bucketName,
                mode: mode,
                pixelWidth: sample.metadata.pixelWidth,
                pixelHeight: sample.metadata.pixelHeight,
                mediaType: "fileImage",
                mediaSubtypesRawValue: 0,
                isScreenshot: true,
                hasCreationDate: false,
                labels: [],
                classifyRevision: 0,
                classifyElapsedMs: 0,
                faceCount: 0,
                faceElapsedMs: 0,
                humanCount: 0,
                humanElapsedMs: 0,
                documentSegmentCount: 0,
                documentElapsedMs: 0,
                scores: scores,
                timing: VisionProbeTimingBreakdown(
                    imageRequestMs: 0,
                    classifyImageMs: 0,
                    faceDetectionMs: 0,
                    humanDetectionMs: 0,
                    documentSegmentationMs: 0,
                    visualFeatureMs: 0,
                    scoringMs: Self.elapsedMs(since: scoringStart),
                    totalElapsedMs: elapsed
                ),
                elapsedMs: elapsed,
                errorMessage: nil
            )
        }

        let imageStart = Date()
        guard
            let imageData = try? Data(contentsOf: fileURL),
            let image = UIImage(data: imageData),
            let cgImage = image.cgImage
        else {
            let scoringStart = Date()
            let scores = Self.makeScores(
                isScreenshot: isScreenshot,
                labels: [],
                faceCount: 0,
                humanCount: 0,
                documentSegmentCount: 0,
                visualMetrics: .empty
            )
            let elapsed = Self.elapsedMs(since: overallStart)
            return Self.makeResult(
                assetIdentifierHash: sampleHash,
                bucketName: bucketName,
                mode: mode,
                pixelWidth: sample.metadata.pixelWidth,
                pixelHeight: sample.metadata.pixelHeight,
                mediaType: "fileImage",
                mediaSubtypesRawValue: 0,
                isScreenshot: isScreenshot,
                hasCreationDate: false,
                labels: [],
                classifyRevision: 0,
                classifyElapsedMs: 0,
                faceCount: 0,
                faceElapsedMs: 0,
                humanCount: 0,
                humanElapsedMs: 0,
                documentSegmentCount: 0,
                documentElapsedMs: 0,
                scores: scores,
                timing: VisionProbeTimingBreakdown(
                    imageRequestMs: Self.elapsedMs(since: imageStart),
                    classifyImageMs: 0,
                    faceDetectionMs: 0,
                    humanDetectionMs: 0,
                    documentSegmentationMs: 0,
                    visualFeatureMs: 0,
                    scoringMs: Self.elapsedMs(since: scoringStart),
                    totalElapsedMs: elapsed
                ),
                elapsedMs: elapsed,
                errorMessage: "fixture画像を読み込めませんでした"
            )
        }

        let imageElapsed = Self.elapsedMs(since: imageStart)
        do {
            let vision = try performVision(cgImage: cgImage, orientation: .up)
            let visualStart = Date()
            let visualMetrics = Self.makeVisualMetrics(cgImage: cgImage)
            let visualElapsed = Self.elapsedMs(since: visualStart)
            let scoringStart = Date()
            let scores = Self.makeScores(
                isScreenshot: isScreenshot,
                labels: vision.labels,
                faceCount: vision.faceCount,
                humanCount: vision.humanCount,
                documentSegmentCount: vision.documentSegmentCount,
                visualMetrics: visualMetrics
            )
            let scoringElapsed = Self.elapsedMs(since: scoringStart)
            let elapsed = Self.elapsedMs(since: overallStart)

            return Self.makeResult(
                assetIdentifierHash: sampleHash,
                bucketName: bucketName,
                mode: mode,
                pixelWidth: cgImage.width,
                pixelHeight: cgImage.height,
                mediaType: "fileImage",
                mediaSubtypesRawValue: 0,
                isScreenshot: isScreenshot,
                hasCreationDate: false,
                labels: vision.labels,
                classifyRevision: vision.classifyRevision,
                classifyElapsedMs: vision.classifyElapsedMs,
                faceCount: vision.faceCount,
                faceElapsedMs: vision.faceElapsedMs,
                humanCount: vision.humanCount,
                humanElapsedMs: vision.humanElapsedMs,
                documentSegmentCount: vision.documentSegmentCount,
                documentElapsedMs: vision.documentElapsedMs,
                scores: scores,
                timing: VisionProbeTimingBreakdown(
                    imageRequestMs: imageElapsed,
                    classifyImageMs: vision.classifyElapsedMs,
                    faceDetectionMs: vision.faceElapsedMs,
                    humanDetectionMs: vision.humanElapsedMs,
                    documentSegmentationMs: vision.documentElapsedMs,
                    visualFeatureMs: visualElapsed,
                    scoringMs: scoringElapsed,
                    totalElapsedMs: elapsed
                ),
                elapsedMs: elapsed,
                errorMessage: nil
            )
        } catch {
            let scoringStart = Date()
            let scores = Self.makeScores(
                isScreenshot: isScreenshot,
                labels: [],
                faceCount: 0,
                humanCount: 0,
                documentSegmentCount: 0,
                visualMetrics: .empty
            )
            let elapsed = Self.elapsedMs(since: overallStart)
            return Self.makeResult(
                assetIdentifierHash: sampleHash,
                bucketName: bucketName,
                mode: mode,
                pixelWidth: cgImage.width,
                pixelHeight: cgImage.height,
                mediaType: "fileImage",
                mediaSubtypesRawValue: 0,
                isScreenshot: isScreenshot,
                hasCreationDate: false,
                labels: [],
                classifyRevision: 0,
                classifyElapsedMs: 0,
                faceCount: 0,
                faceElapsedMs: 0,
                humanCount: 0,
                humanElapsedMs: 0,
                documentSegmentCount: 0,
                documentElapsedMs: 0,
                scores: scores,
                timing: VisionProbeTimingBreakdown(
                    imageRequestMs: imageElapsed,
                    classifyImageMs: 0,
                    faceDetectionMs: 0,
                    humanDetectionMs: 0,
                    documentSegmentationMs: 0,
                    visualFeatureMs: 0,
                    scoringMs: Self.elapsedMs(since: scoringStart),
                    totalElapsedMs: elapsed
                ),
                elapsedMs: elapsed,
                errorMessage: error.localizedDescription
            )
        }
    }

    private func requestImage(for asset: PHAsset) async -> (image: UIImage?, elapsedMs: Double) {
        let start = Date()
        return await withCheckedContinuation { (continuation: CheckedContinuation<(UIImage?, Double), Never>) in
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
                    continuation.resume(returning: (image, Self.elapsedMs(since: start)))
                } else if isCancelled || hasError || isInCloud {
                    didResume = true
                    continuation.resume(returning: (image, Self.elapsedMs(since: start)))
                }
            }
        }
    }

    private static func makeResult(
        asset: PHAsset,
        assetHash: String,
        bucketName: String,
        mode: VisionClassificationProbeMode,
        isScreenshot: Bool,
        labels: [VisionProbeVisualLabel],
        classifyRevision: Int,
        classifyElapsedMs: Double,
        faceCount: Int,
        faceElapsedMs: Double,
        humanCount: Int,
        humanElapsedMs: Double,
        documentSegmentCount: Int,
        documentElapsedMs: Double,
        scores: VisionProbeScores,
        timing: VisionProbeTimingBreakdown,
        elapsedMs: Double,
        errorMessage: String?
    ) -> VisionClassificationProbeResult {
        VisionClassificationProbeResult(
            assetIdentifierHash: assetHash,
            bucketName: bucketName,
            probeMode: mode.rawValue,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            mediaType: Self.mediaTypeTitle(asset.mediaType),
            mediaSubtypesRawValue: asset.mediaSubtypes.rawValue,
            isScreenshot: isScreenshot,
            hasCreationDate: asset.creationDate != nil,
            topVisualLabels: labels,
            classifyRevision: classifyRevision,
            classifyElapsedMs: classifyElapsedMs,
            faceCount: faceCount,
            hasFace: faceCount > 0,
            faceElapsedMs: faceElapsedMs,
            humanCount: humanCount,
            hasHuman: humanCount > 0,
            humanElapsedMs: humanElapsedMs,
            documentSegmentCount: documentSegmentCount,
            hasDocumentSegment: documentSegmentCount > 0,
            documentElapsedMs: documentElapsedMs,
            scores: scores,
            timing: timing,
            elapsedMs: elapsedMs,
            errorMessage: errorMessage
        )
    }

    private static func makeResult(
        assetIdentifierHash: String,
        bucketName: String,
        mode: VisionClassificationProbeMode,
        pixelWidth: Int,
        pixelHeight: Int,
        mediaType: String,
        mediaSubtypesRawValue: UInt,
        isScreenshot: Bool,
        hasCreationDate: Bool,
        labels: [VisionProbeVisualLabel],
        classifyRevision: Int,
        classifyElapsedMs: Double,
        faceCount: Int,
        faceElapsedMs: Double,
        humanCount: Int,
        humanElapsedMs: Double,
        documentSegmentCount: Int,
        documentElapsedMs: Double,
        scores: VisionProbeScores,
        timing: VisionProbeTimingBreakdown,
        elapsedMs: Double,
        errorMessage: String?
    ) -> VisionClassificationProbeResult {
        VisionClassificationProbeResult(
            assetIdentifierHash: assetIdentifierHash,
            bucketName: bucketName,
            probeMode: mode.rawValue,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            mediaType: mediaType,
            mediaSubtypesRawValue: mediaSubtypesRawValue,
            isScreenshot: isScreenshot,
            hasCreationDate: hasCreationDate,
            topVisualLabels: labels,
            classifyRevision: classifyRevision,
            classifyElapsedMs: classifyElapsedMs,
            faceCount: faceCount,
            hasFace: faceCount > 0,
            faceElapsedMs: faceElapsedMs,
            humanCount: humanCount,
            hasHuman: humanCount > 0,
            humanElapsedMs: humanElapsedMs,
            documentSegmentCount: documentSegmentCount,
            hasDocumentSegment: documentSegmentCount > 0,
            documentElapsedMs: documentElapsedMs,
            scores: scores,
            timing: timing,
            elapsedMs: elapsedMs,
            errorMessage: errorMessage
        )
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
        visualMetrics: VisionProbeVisualMetrics,
        forceScreenshotFastPath: Bool = false
    ) -> VisionProbeScores {
        let screenshotScore = isScreenshot ? 1.0 : 0.0
        if forceScreenshotFastPath {
            return VisionProbeScores(
                screenshotScore: 1.0,
                documentLabelScore: 0,
                documentVisualScore: 0,
                documentSegmentationScore: 0,
                documentScoreWithoutSegmentation: 0,
                documentScore: 0,
                personScore: 0,
                foodScore: 0,
                landscapeScore: 0,
                buildingScore: 0,
                constructionSiteScore: 0,
                vehicleHeavyEquipmentScore: 0,
                materialEquipmentScore: 0,
                signScore: 0,
                whiteboardScore: 0,
                businessCardScore: 0,
                receiptScore: 0,
                ocrPriorityScore: 0.85
            )
        }

        let personScore = min(1.0, (faceCount > 0 ? 0.75 : 0.0) + (humanCount > 0 ? 0.65 : 0.0))
        let foodScore = VisionClassificationTaxonomy.score(labels: labels, matching: VisionClassificationTaxonomy.foodLabels)
        let landscapeScore = VisionClassificationTaxonomy.score(labels: labels, matching: VisionClassificationTaxonomy.landscapeLabels)
        let buildingScore = VisionClassificationTaxonomy.score(labels: labels, matching: VisionClassificationTaxonomy.buildingLabels)
        let vehicleHeavyEquipmentScore = VisionClassificationTaxonomy.score(
            labels: labels,
            matching: VisionClassificationTaxonomy.vehicleHeavyEquipmentLabels
        )
        let materialEquipmentScore = VisionClassificationTaxonomy.score(
            labels: labels,
            matching: VisionClassificationTaxonomy.materialEquipmentLabels
        )
        let constructionScore = max(
            VisionClassificationTaxonomy.score(labels: labels, matching: VisionClassificationTaxonomy.constructionSiteLabels),
            vehicleHeavyEquipmentScore * 0.35
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
        let documentSegmentationScore = documentSegmentCount > 0 ? 0.08 : 0.0
        let documentScoreWithoutSegmentation = max(
            documentLabelScore,
            max(receiptScore, businessCardScore),
            documentVisualScore * 0.45
        )
        let unsuppressedDocumentScore = max(
            documentScoreWithoutSegmentation,
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
            documentSegmentationScore: documentSegmentationScore,
            documentScoreWithoutSegmentation: documentScoreWithoutSegmentation,
            documentScore: documentScore,
            personScore: personScore,
            foodScore: foodScore,
            landscapeScore: landscapeScore,
            buildingScore: buildingScore,
            constructionSiteScore: constructionScore,
            vehicleHeavyEquipmentScore: vehicleHeavyEquipmentScore,
            materialEquipmentScore: materialEquipmentScore,
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

    private static func average(_ values: [Double]) -> Double {
        guard values.isEmpty == false else {
            return 0
        }
        return values.reduce(0, +) / Double(values.count)
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
