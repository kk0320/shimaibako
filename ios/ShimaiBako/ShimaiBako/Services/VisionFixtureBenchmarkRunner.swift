#if DEBUG
import Combine
import CryptoKit
import Foundation
import UIKit
import Vision

private struct VisionFixtureManifest: Codable {
    let generatorVersion: String
    let seed: Int
    let generatedAt: String
    let fixtures: [VisionFixtureDefinition]
}

private struct VisionFixtureDefinition: Codable, Identifiable {
    let fixtureId: String
    let file: String
    let layer: String
    let split: String
    let category: String
    let variant: String
    let evaluationMode: String
    let expectedFormatTags: [String]
    let expectedContentTags: [String]
    let expectedOCRNeeded: Bool
    let metadata: VisionFixtureMetadata
    let assertions: VisionFixtureAssertions
    let generation: VisionFixtureGeneration
    let provenance: VisionFixtureProvenance

    var id: String { fixtureId }
}

private struct VisionFixtureMetadata: Codable {
    let isScreenshot: Bool?
    let width: Int
    let height: Int
}

private struct VisionFixtureAssertions: Codable {
    let requiredTags: [String]
    let allowedAlternateTags: [String]
    let forbiddenTags: [String]
    let minimumScores: [String: Double]
    let relativeAssertions: [String]
}

private struct VisionFixtureGeneration: Codable {
    let rotation: Double
    let blurRadius: Double
    let perspectiveAmount: Double
    let backgroundType: String
}

private struct VisionFixtureProvenance: Codable {
    let source: String
    let licenseID: String?
    let approved: Bool
    let reviewNote: String?
}

private struct VisionFixtureEnvironment: Codable {
    let deviceModel: String
    let osVersion: String
    let appBuild: String
    let visionRevision: Int
    let supportedIdentifiersHash: String
    let taxonomyVersion: String
    let scoringVersion: String
    let probeVersion: String
    let runAt: Date
}

private struct VisionFixtureAssertionResult: Codable {
    let assertion: String
    let passed: Bool
    let actualValue: String
}

private struct VisionFixtureItemResult: Codable {
    let fixtureId: String
    let fixtureSHA256: String
    let category: String
    let variant: String
    let evaluationMode: String
    let expectedTags: [String]
    let requiredAssertions: [String]
    let actualTopLabels: [VisionProbeVisualLabel]
    let actualScores: VisionProbeScores
    let predictedTags: [String]
    let ocrPriorityScore: Double
    let assertionResults: [VisionFixtureAssertionResult]
    let processingTimeMs: Double
    let environment: VisionFixtureEnvironment
    let result: String
    let reviewNote: String?
    let errorMessage: String?
}

private struct VisionFixtureReport: Codable {
    let runID: String
    let manifestGeneratorVersion: String
    let seed: Int
    let totalCount: Int
    let passedCount: Int
    let failedCount: Int
    let metadataAwareScreenshotCount: Int
    let imageOnlyScreenshotCount: Int
    let environment: VisionFixtureEnvironment
    let results: [VisionFixtureItemResult]
}

@MainActor
final class VisionFixtureBenchmarkRunner: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var latestStatus: String?
    @Published private(set) var latestOutputDirectoryPath: String?
    @Published private(set) var latestPassCount = 0
    @Published private(set) var latestFailCount = 0
    @Published private(set) var latestTotalCount = 0
    @Published private(set) var errorMessage: String?

    private let probeService = VisionClassificationProbeService()

    func runSyntheticFixtureBenchmark() async {
        guard isRunning == false else { return }

        isRunning = true
        errorMessage = nil
        latestStatus = "合成fixtureを準備しています"
        latestPassCount = 0
        latestFailCount = 0
        latestTotalCount = 0

        do {
            let root = Self.fixtureInputRootURL()
            let manifestURL = Self.resolveManifestURL(root: root)
            let imageRoot = Self.resolveImageRootURL(root: root)
            print("VISION_FIXTURE_BENCHMARK step=start root=\(root.path) manifest=\(manifestURL.path) imageRoot=\(imageRoot.path)")
            let manifestData = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(VisionFixtureManifest.self, from: manifestData)
            print("VISION_FIXTURE_BENCHMARK step=manifestLoaded fixtureCount=\(manifest.fixtures.count)")
            let runID = Self.runID()
            let outputDirectory = try Self.outputDirectoryURL()
            let environmentBase = Self.makeEnvironment(visionRevision: 0)
            var results: [VisionFixtureItemResult] = []

            for (index, fixture) in manifest.fixtures.enumerated() {
                latestStatus = "合成fixture \(index + 1) / \(manifest.fixtures.count)件を評価中"
                let fileURL = imageRoot.appendingPathComponent(fixture.file)
                let fileData = try Data(contentsOf: fileURL)
                let sha256 = Self.sha256Hex(fileData)
                let expected = ExpectedClassification(
                    formatTags: fixture.expectedFormatTags,
                    contentTags: fixture.expectedContentTags,
                    ocrNeeded: fixture.expectedOCRNeeded
                )
                let provenance = FixtureProvenance(
                    layer: fixture.layer,
                    split: fixture.split,
                    source: fixture.provenance.source,
                    licenseID: fixture.provenance.licenseID,
                    approved: fixture.provenance.approved,
                    reviewNote: fixture.provenance.reviewNote
                )
                let sample = ClassificationSample(
                    id: fixture.fixtureId,
                    imageSource: .fileURL(fileURL),
                    metadata: .fileImage(
                        pixelWidth: fixture.metadata.width,
                        pixelHeight: fixture.metadata.height,
                        isScreenshot: fixture.metadata.isScreenshot
                    ),
                    expected: expected,
                    provenance: provenance
                )
                let mode = fixture.evaluationMode == "metadataAware" ? VisionClassificationProbeMode.gated : .full
                let probeResult = await probeService.analyze(
                    sample: sample,
                    bucketName: fixture.category,
                    mode: mode
                )
                let environment = Self.makeEnvironment(visionRevision: probeResult.classifyRevision)
                let predictedTags = Self.predictedTags(from: probeResult)
                let assertionResults = Self.evaluateAssertions(
                    fixture.assertions,
                    predictedTags: predictedTags,
                    scores: probeResult.scores
                )
                let passed = probeResult.errorMessage == nil && assertionResults.allSatisfy(\.passed)
                let item = VisionFixtureItemResult(
                    fixtureId: fixture.fixtureId,
                    fixtureSHA256: sha256,
                    category: fixture.category,
                    variant: fixture.variant,
                    evaluationMode: fixture.evaluationMode,
                    expectedTags: fixture.expectedFormatTags + fixture.expectedContentTags,
                    requiredAssertions: Self.assertionTitles(from: fixture.assertions),
                    actualTopLabels: probeResult.topVisualLabels,
                    actualScores: probeResult.scores,
                    predictedTags: predictedTags,
                    ocrPriorityScore: probeResult.scores.ocrPriorityScore,
                    assertionResults: assertionResults,
                    processingTimeMs: probeResult.elapsedMs,
                    environment: environment,
                    result: passed ? "PASS" : "FAIL",
                    reviewNote: fixture.provenance.reviewNote,
                    errorMessage: probeResult.errorMessage
                )
                results.append(item)
            }

            let passedCount = results.filter { $0.result == "PASS" }.count
            let failedCount = results.count - passedCount
            let report = VisionFixtureReport(
                runID: runID,
                manifestGeneratorVersion: manifest.generatorVersion,
                seed: manifest.seed,
                totalCount: results.count,
                passedCount: passedCount,
                failedCount: failedCount,
                metadataAwareScreenshotCount: results.filter { $0.evaluationMode == "metadataAware" }.count,
                imageOnlyScreenshotCount: results.filter { $0.evaluationMode == "imageOnly" }.count,
                environment: environmentBase,
                results: results
            )

            try Self.writeOutputs(report: report, to: outputDirectory)
            latestPassCount = passedCount
            latestFailCount = failedCount
            latestTotalCount = results.count
            latestOutputDirectoryPath = outputDirectory.path
            latestStatus = "合成fixture \(results.count)件を評価しました。PASS \(passedCount) / FAIL \(failedCount)"
            print("VISION_FIXTURE_BENCHMARK step=completed total=\(results.count) pass=\(passedCount) fail=\(failedCount) output=\(outputDirectory.path)")
        } catch {
            errorMessage = error.localizedDescription
            latestStatus = "合成fixtureベンチに失敗しました"
            print("VISION_FIXTURE_BENCHMARK step=failed error=\(error.localizedDescription)")
            try? Self.writeErrorOutput(message: error.localizedDescription)
        }

        isRunning = false
    }

    static func fixtureInputRootURL() -> URL {
        applicationSupportRoot()
            .appendingPathComponent("vision_fixture_benchmark", isDirectory: true)
    }

    private static func resolveManifestURL(root: URL) -> URL {
        let nested = root.appendingPathComponent("manifests/p09_synthetic_manifest.json")
        if FileManager.default.fileExists(atPath: nested.path) {
            return nested
        }
        return root.appendingPathComponent("p09_synthetic_manifest.json")
    }

    private static func resolveImageRootURL(root: URL) -> URL {
        let nested = root.appendingPathComponent("synthetic", isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: nested.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return nested
        }
        return root
    }

    private static func outputDirectoryURL() throws -> URL {
        let applicationSupportURL = applicationSupportRoot()
            .appendingPathComponent("vision_classification_benchmark", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: applicationSupportURL, withIntermediateDirectories: true)
            return applicationSupportURL
        } catch {
            let cacheURL = cachesRoot()
                .appendingPathComponent("vision_classification_benchmark", isDirectory: true)
            try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
            return cacheURL
        }
    }

    private static func applicationSupportRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ShimaiBako", isDirectory: true)
    }

    private static func cachesRoot() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ShimaiBako", isDirectory: true)
    }

    private static func writeOutputs(report: VisionFixtureReport, to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(report)
        try jsonData.write(to: directory.appendingPathComponent("p09_fixture_results_\(report.runID).json"), options: .atomic)
        try csv(for: report).write(
            to: directory.appendingPathComponent("p09_fixture_results_\(report.runID).csv"),
            atomically: true,
            encoding: .utf8
        )
        try summaryMarkdown(for: report).write(
            to: directory.appendingPathComponent("p09_fixture_summary_\(report.runID).md"),
            atomically: true,
            encoding: .utf8
        )
        try assertionsMarkdown(for: report).write(
            to: directory.appendingPathComponent("p09_fixture_assertions_\(report.runID).md"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func writeErrorOutput(message: String) throws {
        let directory = try outputDirectoryURL()
        let filename = "p09_fixture_error_\(runID()).md"
        let body = """
        # P0.9 File-based Vision Fixture Benchmark Error

        - Run at: \(Date())
        - Error: \(message)

        This file records a DEBUG fixture benchmark setup failure. It does not contain production photo bodies or thumbnails.
        """
        try body.write(to: directory.appendingPathComponent(filename), atomically: true, encoding: .utf8)
    }

    private static func csv(for report: VisionFixtureReport) -> String {
        var lines = [
            "fixtureId,fixtureSHA256,category,variant,evaluationMode,result,ocrPriorityScore,processingTimeMs,predictedTags,topLabels,errorMessage"
        ]
        for item in report.results {
            let topLabels = item.actualTopLabels
                .map { "\($0.identifier):\(String(format: "%.3f", $0.confidence))" }
                .joined(separator: "|")
            let columns = [
                item.fixtureId,
                item.fixtureSHA256,
                item.category,
                item.variant,
                item.evaluationMode,
                item.result,
                String(format: "%.3f", item.ocrPriorityScore),
                String(format: "%.1f", item.processingTimeMs),
                item.predictedTags.joined(separator: "|"),
                topLabels,
                item.errorMessage ?? ""
            ]
            lines.append(columns.map(csvEscape).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func summaryMarkdown(for report: VisionFixtureReport) -> String {
        """
        # P0.9 File-based Vision Fixture Benchmark

        - Run ID: \(report.runID)
        - Fixture count: \(report.totalCount)
        - PASS: \(report.passedCount)
        - FAIL: \(report.failedCount)
        - Metadata-aware screenshot fixtures: \(report.metadataAwareScreenshotCount)
        - Image-only screenshot fixtures: \(report.imageOnlyScreenshotCount)
        - Device: \(report.environment.deviceModel)
        - OS: \(report.environment.osVersion)
        - App build: \(report.environment.appBuild)
        - Vision revision: \(report.environment.visionRevision)
        - Supported identifiers hash: \(report.environment.supportedIdentifiersHash)
        - Taxonomy version: \(report.environment.taxonomyVersion)
        - Scoring version: \(report.environment.scoringVersion)
        - Probe version: \(report.environment.probeVersion)

        ## Safety

        This benchmark reads development fixture files from the app sandbox and writes JSON/CSV/Markdown evidence only. It does not save production photo bodies, thumbnails, face images, or face templates.

        ## Results

        | Fixture | Mode | Result | OCR priority | Predicted tags |
        | --- | --- | --- | ---: | --- |
        \(report.results.map { "| \($0.fixtureId) | \($0.evaluationMode) | \($0.result) | \(String(format: "%.3f", $0.ocrPriorityScore)) | \($0.predictedTags.joined(separator: " ")) |" }.joined(separator: "\n"))
        """
    }

    private static func assertionsMarkdown(for report: VisionFixtureReport) -> String {
        var markdown = "# P0.9 Semantic Assertions\n\n"
        for item in report.results {
            markdown += "## \(item.fixtureId) (\(item.result))\n\n"
            markdown += "- SHA256: `\(item.fixtureSHA256)`\n"
            markdown += "- Expected tags: \(item.expectedTags.joined(separator: ", "))\n"
            let predictedTags = item.predictedTags.isEmpty ? "(none)" : item.predictedTags.joined(separator: ", ")
            markdown += "- Predicted tags: \(predictedTags)\n"
            markdown += "- OCR priority: \(String(format: "%.3f", item.ocrPriorityScore))\n\n"
            for assertion in item.assertionResults {
                markdown += "- \(assertion.passed ? "PASS" : "FAIL"): \(assertion.assertion) (`\(assertion.actualValue)`)\n"
            }
            if let errorMessage = item.errorMessage {
                markdown += "- Error: \(errorMessage)\n"
            }
            markdown += "\n"
        }
        return markdown
    }

    private static func evaluateAssertions(
        _ assertions: VisionFixtureAssertions,
        predictedTags: [String],
        scores: VisionProbeScores
    ) -> [VisionFixtureAssertionResult] {
        var results: [VisionFixtureAssertionResult] = []
        let predicted = Set(predictedTags)

        for tag in assertions.requiredTags {
            let passed = predicted.contains(tag)
            results.append(VisionFixtureAssertionResult(
                assertion: "requiredTags contains \(tag)",
                passed: passed,
                actualValue: predictedTags.joined(separator: "|")
            ))
        }

        for tag in assertions.forbiddenTags {
            let passed = predicted.contains(tag) == false
            results.append(VisionFixtureAssertionResult(
                assertion: "forbiddenTags excludes \(tag)",
                passed: passed,
                actualValue: predictedTags.joined(separator: "|")
            ))
        }

        for (scoreName, minimum) in assertions.minimumScores {
            let value = scoreValue(scoreName, scores: scores)
            results.append(VisionFixtureAssertionResult(
                assertion: "\(scoreName) >= \(minimum)",
                passed: value >= minimum,
                actualValue: String(format: "%.3f", value)
            ))
        }

        for expression in assertions.relativeAssertions {
            let parts = expression.split(separator: " ").map(String.init)
            guard parts.count == 3, parts[1] == ">" else {
                results.append(VisionFixtureAssertionResult(
                    assertion: expression,
                    passed: false,
                    actualValue: "unsupported"
                ))
                continue
            }
            let left = scoreValue(parts[0], scores: scores)
            let right = scoreValue(parts[2], scores: scores)
            results.append(VisionFixtureAssertionResult(
                assertion: expression,
                passed: left > right,
                actualValue: "\(String(format: "%.3f", left)) > \(String(format: "%.3f", right))"
            ))
        }

        return results
    }

    private static func predictedTags(from result: VisionClassificationProbeResult) -> [String] {
        var tags: [String] = []
        let scores = result.scores
        if scores.screenshotScore >= 0.75 { tags.append("screenshot") }
        if scores.receiptScore >= 0.35 { tags.append("receipt") }
        if scores.businessCardScore >= 0.3 { tags.append("businessCard") }
        if scores.documentScore >= 0.45 { tags.append("document") }
        if scores.signScore >= 0.35 { tags.append("sign") }
        if scores.whiteboardScore >= 0.35 { tags.append("whiteboard") }
        if scores.buildingScore >= 0.4 { tags.append("buildingLike") }
        if scores.constructionSiteScore >= 0.35 { tags.append("constructionLike") }
        if scores.vehicleHeavyEquipmentScore >= 0.35 { tags.append("vehicleHeavyEquipmentLike") }
        if scores.materialEquipmentScore >= 0.35 { tags.append("materialEquipmentLike") }
        if scores.foodScore >= 0.45 { tags.append("foodLike") }
        if scores.landscapeScore >= 0.45 { tags.append("landscapeLike") }
        if scores.personScore >= 0.45 { tags.append("personLike") }
        if scores.ocrPriorityScore >= 0.65 { tags.append("ocrNeeded") }
        return tags
    }

    private static func assertionTitles(from assertions: VisionFixtureAssertions) -> [String] {
        assertions.requiredTags.map { "required:\($0)" } +
            assertions.forbiddenTags.map { "forbidden:\($0)" } +
            assertions.minimumScores.map { "\($0.key)>=\($0.value)" } +
            assertions.relativeAssertions
    }

    private static func scoreValue(_ name: String, scores: VisionProbeScores) -> Double {
        switch name {
        case "screenshotScore": return scores.screenshotScore
        case "documentLabelScore": return scores.documentLabelScore
        case "documentVisualScore": return scores.documentVisualScore
        case "documentSegmentationScore": return scores.documentSegmentationScore
        case "documentScoreWithoutSegmentation": return scores.documentScoreWithoutSegmentation
        case "documentScore": return scores.documentScore
        case "personScore": return scores.personScore
        case "foodScore": return scores.foodScore
        case "landscapeScore": return scores.landscapeScore
        case "buildingScore": return scores.buildingScore
        case "constructionSiteScore": return scores.constructionSiteScore
        case "vehicleHeavyEquipmentScore": return scores.vehicleHeavyEquipmentScore
        case "materialEquipmentScore": return scores.materialEquipmentScore
        case "signScore": return scores.signScore
        case "whiteboardScore": return scores.whiteboardScore
        case "businessCardScore": return scores.businessCardScore
        case "receiptScore": return scores.receiptScore
        case "ocrPriorityScore": return scores.ocrPriorityScore
        default: return 0
        }
    }

    private static func makeEnvironment(visionRevision: Int) -> VisionFixtureEnvironment {
        VisionFixtureEnvironment(
            deviceModel: UIDevice.current.model,
            osVersion: UIDevice.current.systemVersion,
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            visionRevision: visionRevision,
            supportedIdentifiersHash: supportedIdentifiersHash(),
            taxonomyVersion: "p09-taxonomy-1",
            scoringVersion: "p09-scoring-1",
            probeVersion: "p09-file-probe-1",
            runAt: Date()
        )
    }

    private static func supportedIdentifiersHash() -> String {
        let request = VNClassifyImageRequest()
        let identifiers = (try? request.supportedIdentifiers()) ?? []
        return sha256Hex(Data(identifiers.sorted().joined(separator: "\n").utf8))
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func runID() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return "p09_\(formatter.string(from: Date()))"
    }

    private static func csvEscape(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}
#else
import Combine

@MainActor
final class VisionFixtureBenchmarkRunner: ObservableObject {}
#endif
