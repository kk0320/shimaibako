import Foundation

struct FixtureReport: Decodable {
    let runID: String
    let totalCount: Int
    let passedCount: Int
    let failedCount: Int
    let environment: Environment
    let results: [FixtureResult]
}

struct Environment: Decodable {
    let deviceModel: String
    let osVersion: String
    let appBuild: String
    let visionRevision: Int
    let supportedIdentifiersHash: String
    let taxonomyVersion: String
    let scoringVersion: String
    let probeVersion: String
    let runAt: String
}

struct FixtureResult: Decodable {
    let fixtureId: String
    let category: String
    let variant: String
    let evaluationMode: String
    let expectedTags: [String]
    let requiredAssertions: [String]
    let actualTopLabels: [VisualLabel]
    let actualScores: Scores
    let predictedTags: [String]
    let ocrPriorityScore: Double
    let assertionResults: [AssertionResult]
    let processingTimeMs: Double
    let environment: Environment
    let result: String
    let reviewNote: String?
    let errorMessage: String?
}

struct VisualLabel: Decodable {
    let identifier: String
    let confidence: Double
}

struct Scores: Decodable {
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

struct AssertionResult: Decodable {
    let assertion: String
    let passed: Bool
    let actualValue: String
}

struct AnalyzedFixture {
    let sourceReport: String
    let fixture: FixtureResult
    let environmentName: String
    let contractAssertions: [AssertionResult]
    let signalAssertions: [AssertionResult]
    let failedAssertions: [AssertionResult]
    let failReason: String
    let contractPass: Bool
    let signalPass: Bool
    let overallPass: Bool
    let ocrPriorityPass: Bool?
    let categorySignalPass: Bool
    let reviewNote: String
}

let repositoryRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let evidenceDirectory = repositoryRoot.appendingPathComponent("evidence/vision_classification_benchmark", isDirectory: true)
let decoder = JSONDecoder()

let inputURLs = try FileManager.default.contentsOfDirectory(
    at: evidenceDirectory,
    includingPropertiesForKeys: nil
)
    .filter { $0.lastPathComponent.hasPrefix("p09_fixture_results_") && $0.pathExtension == "json" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

guard inputURLs.isEmpty == false else {
    throw NSError(domain: "P10VisionFixtureAnalysis", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "No p09 fixture result JSON files found in \(evidenceDirectory.path)"
    ])
}

let reports = try inputURLs.map { url -> FixtureReport in
    let data = try Data(contentsOf: url)
    return try decoder.decode(FixtureReport.self, from: data)
}

let analyses = reports.flatMap { report in
    let environmentName = inferEnvironmentName(report)
    return report.results.map { fixture -> AnalyzedFixture in
        let contractAssertions = fixture.assertionResults.filter {
            isContractAssertion($0.assertion, fixture: fixture)
        }
        let signalAssertions = fixture.assertionResults.filter {
            isContractAssertion($0.assertion, fixture: fixture) == false
        }
        let failedAssertions = fixture.assertionResults.filter { $0.passed == false }
        let contractPass = fixture.errorMessage == nil && contractAssertions.allSatisfy(\.passed)
        let signalPass = fixture.errorMessage == nil && signalAssertions.allSatisfy(\.passed)
        let ocrPriorityPass = evaluateOCRPriorityPass(fixture)
        let categorySignalPass = evaluateCategorySignalPass(fixture)
        let overallPass = contractPass && signalPass
        let failReason = classifyFailReason(
            fixture: fixture,
            failedAssertions: failedAssertions,
            contractPass: contractPass,
            signalPass: signalPass,
            categorySignalPass: categorySignalPass
        )
        return AnalyzedFixture(
            sourceReport: report.runID,
            fixture: fixture,
            environmentName: environmentName,
            contractAssertions: contractAssertions,
            signalAssertions: signalAssertions,
            failedAssertions: failedAssertions,
            failReason: failReason,
            contractPass: contractPass,
            signalPass: signalPass,
            overallPass: overallPass,
            ocrPriorityPass: ocrPriorityPass,
            categorySignalPass: categorySignalPass,
            reviewNote: reviewNote(fixture: fixture, failReason: failReason)
        )
    }
}

let timestamp = timestampString()
let jsonURL = evidenceDirectory.appendingPathComponent("p10_failure_analysis_\(timestamp).json")
let csvURL = evidenceDirectory.appendingPathComponent("p10_failure_analysis_\(timestamp).csv")
let markdownURL = evidenceDirectory.appendingPathComponent("p10_failure_analysis_\(timestamp).md")
let goNoGoURL = evidenceDirectory.appendingPathComponent("p10_go_no_go_\(timestamp).md")

try jsonData(for: analyses, reports: reports).write(to: jsonURL, options: .atomic)
try csv(for: analyses).write(to: csvURL, atomically: true, encoding: .utf8)
try markdown(for: analyses, reports: reports).write(to: markdownURL, atomically: true, encoding: .utf8)
try goNoGoMarkdown(for: analyses).write(to: goNoGoURL, atomically: true, encoding: .utf8)

print("Wrote \(jsonURL.path)")
print("Wrote \(csvURL.path)")
print("Wrote \(markdownURL.path)")
print("Wrote \(goNoGoURL.path)")

func inferEnvironmentName(_ report: FixtureReport) -> String {
    let espressoCount = report.results.filter {
        ($0.errorMessage ?? "").localizedCaseInsensitiveContains("espresso")
    }.count
    if espressoCount > 0 {
        return "Simulator"
    }
    return "K Phone"
}

func isContractAssertion(_ assertion: String, fixture: FixtureResult) -> Bool {
    if fixture.evaluationMode == "metadataAware" && isScreenshotCategory(fixture.category) {
        return true
    }
    if assertion == "forbiddenTags excludes screenshot" {
        return true
    }
    return false
}

func evaluateOCRPriorityPass(_ fixture: FixtureResult) -> Bool? {
    if isScreenshotCategory(fixture.category) {
        return fixture.actualScores.screenshotScore >= 0.75 || fixture.actualScores.ocrPriorityScore >= 0.8
    }
    if ["receipt", "businessCard", "document", "drawing", "sign", "whiteboard"].contains(fixture.category) {
        return fixture.actualScores.ocrPriorityScore >= 0.2
    }
    return nil
}

func evaluateCategorySignalPass(_ fixture: FixtureResult) -> Bool {
    let predicted = Set(fixture.predictedTags)
    switch fixture.category {
    case "chatScreenshot", "appScreenshot":
        return predicted.contains("screenshot") || fixture.actualScores.screenshotScore >= 0.75
    case "receipt":
        return predicted.contains("receipt")
    case "businessCard":
        return predicted.contains("businessCard")
    case "document":
        return predicted.contains("document")
    case "drawing":
        return topLabels(fixture).contains { ["diagram", "sketch", "drawing", "plan"].contains($0) }
    case "sign":
        return predicted.contains("sign")
    case "whiteboard":
        return predicted.contains("whiteboard")
    case "buildingLike":
        return predicted.contains("buildingLike")
    case "constructionLike":
        return predicted.contains("constructionLike")
    default:
        return false
    }
}

func classifyFailReason(
    fixture: FixtureResult,
    failedAssertions: [AssertionResult],
    contractPass: Bool,
    signalPass: Bool,
    categorySignalPass: Bool
) -> String {
    if failedAssertions.isEmpty && fixture.errorMessage == nil {
        return "pass"
    }

    if let errorMessage = fixture.errorMessage {
        if errorMessage.localizedCaseInsensitiveContains("espresso") {
            return "espressoContextError"
        }
        if errorMessage.localizedCaseInsensitiveContains("unsupported") {
            return "unsupportedEnvironment"
        }
        return "visionRuntimeError"
    }

    if contractPass == false {
        if fixture.evaluationMode == "metadataAware", fixture.actualScores.screenshotScore == 0 {
            return "metadataMissing"
        }
        return "wrongPredictedTag"
    }

    let failedNames = failedAssertions.map(\.assertion)
    if failedNames.allSatisfy({ $0 == "requiredTags contains ocrNeeded" }),
       fixture.actualScores.ocrPriorityScore >= 0.2 {
        return "assertionTooStrict"
    }

    if failedNames.contains(where: { $0.contains(">=") }) {
        return "scoreBelowThreshold"
    }

    if categorySignalPass == false {
        let labels = topLabels(fixture)
        if expectedLabelTerms(for: fixture.category).isDisjoint(with: Set(labels)) {
            return "visionLabelMissing"
        }
        return "wrongPredictedTag"
    }

    if ["blur", "shadow", "low_contrast", "rotated"].contains(fixture.variant) {
        return "fixtureTooSynthetic"
    }

    if signalPass == false {
        return "scoreBelowThreshold"
    }

    return "unknown"
}

func topLabels(_ fixture: FixtureResult) -> [String] {
    fixture.actualTopLabels.map { $0.identifier.lowercased() }
}

func expectedLabelTerms(for category: String) -> Set<String> {
    switch category {
    case "receipt": return ["receipt", "document", "printed_page"]
    case "businessCard": return ["business_card", "business card", "document", "printed_page"]
    case "document": return ["document", "printed_page", "paper"]
    case "drawing": return ["diagram", "sketch", "drawing", "plan", "document"]
    case "sign": return ["sign", "poster", "billboard", "text"]
    case "whiteboard": return ["whiteboard", "blackboard", "document"]
    case "buildingLike": return ["building", "house", "architecture"]
    case "constructionLike": return ["construction", "building", "crane", "excavator"]
    case "chatScreenshot", "appScreenshot": return ["screenshot", "software", "document"]
    default: return []
    }
}

func isScreenshotCategory(_ category: String) -> Bool {
    category == "chatScreenshot" || category == "appScreenshot"
}

func reviewNote(fixture: FixtureResult, failReason: String) -> String {
    switch failReason {
    case "pass":
        return "No P0.10 action required."
    case "assertionTooStrict":
        return "Required tag threshold is stricter than the useful OCR priority signal; treat as signal calibration, not engine failure."
    case "visionLabelMissing":
        return "Vision did not expose the expected category label; improve fixture realism or keep this category out of product UI."
    case "scoreBelowThreshold":
        return "Observed score stayed below the semantic threshold; consider threshold calibration after real holdout data."
    case "wrongPredictedTag":
        return "Predicted tag set does not match the expected semantic category."
    case "fixtureTooSynthetic":
        return "Fixture variant may be too synthetic or visually weak for Vision classification."
    case "espressoContextError":
        return "Simulator Vision runtime failed; use K Phone as the primary benchmark environment."
    case "metadataMissing":
        return "Metadata-aware contract did not receive or apply expected screenshot metadata."
    default:
        return "Review manually before using this signal in product UI."
    }
}

func csv(for analyses: [AnalyzedFixture]) -> String {
    let header = [
        "fixtureId",
        "sourceReport",
        "category",
        "variant",
        "mode",
        "expectedTags",
        "predictedTags",
        "requiredAssertions",
        "failedAssertions",
        "failReason",
        "contractPass",
        "signalPass",
        "overallPass",
        "ocrPriorityPass",
        "categorySignalPass",
        "topLabels",
        "scores",
        "ocrPriorityScore",
        "environment",
        "deviceModel",
        "osVersion",
        "visionRevision",
        "elapsedMs",
        "reviewNote"
    ]
    var lines = [header.map(csvEscape).joined(separator: ",")]
    for analysis in analyses {
        let item = analysis.fixture
        let columns = [
            item.fixtureId,
            analysis.sourceReport,
            item.category,
            item.variant,
            item.evaluationMode,
            item.expectedTags.joined(separator: "|"),
            item.predictedTags.joined(separator: "|"),
            item.requiredAssertions.joined(separator: "|"),
            analysis.failedAssertions.map(\.assertion).joined(separator: "|"),
            analysis.failReason,
            String(analysis.contractPass),
            String(analysis.signalPass),
            String(analysis.overallPass),
            analysis.ocrPriorityPass.map(String.init) ?? "n/a",
            String(analysis.categorySignalPass),
            item.actualTopLabels.map { "\($0.identifier):\(format($0.confidence))" }.joined(separator: "|"),
            scoreSummary(item.actualScores),
            format(item.ocrPriorityScore),
            analysis.environmentName,
            item.environment.deviceModel,
            item.environment.osVersion,
            String(item.environment.visionRevision),
            format(item.processingTimeMs),
            analysis.reviewNote
        ]
        lines.append(columns.map(csvEscape).joined(separator: ","))
    }
    return lines.joined(separator: "\n") + "\n"
}

func jsonData(for analyses: [AnalyzedFixture], reports: [FixtureReport]) throws -> Data {
    let rows: [[String: Any]] = analyses.map { analysis in
        let item = analysis.fixture
        return [
            "fixtureId": item.fixtureId,
            "sourceReport": analysis.sourceReport,
            "category": item.category,
            "variant": item.variant,
            "mode": item.evaluationMode,
            "expectedTags": item.expectedTags,
            "predictedTags": item.predictedTags,
            "requiredAssertions": item.requiredAssertions,
            "failedAssertions": analysis.failedAssertions.map(\.assertion),
            "failReason": analysis.failReason,
            "contractPass": analysis.contractPass,
            "signalPass": analysis.signalPass,
            "overallPass": analysis.overallPass,
            "ocrPriorityPass": analysis.ocrPriorityPass.map { $0 as Any } ?? NSNull(),
            "categorySignalPass": analysis.categorySignalPass,
            "topLabels": item.actualTopLabels.map {
                ["identifier": $0.identifier, "confidence": $0.confidence]
            },
            "scores": [
                "screenshotScore": item.actualScores.screenshotScore,
                "documentScore": item.actualScores.documentScore,
                "receiptScore": item.actualScores.receiptScore,
                "businessCardScore": item.actualScores.businessCardScore,
                "signScore": item.actualScores.signScore,
                "whiteboardScore": item.actualScores.whiteboardScore,
                "buildingScore": item.actualScores.buildingScore,
                "constructionSiteScore": item.actualScores.constructionSiteScore,
                "ocrPriorityScore": item.actualScores.ocrPriorityScore
            ],
            "ocrPriorityScore": item.ocrPriorityScore,
            "environment": analysis.environmentName,
            "deviceModel": item.environment.deviceModel,
            "osVersion": item.environment.osVersion,
            "visionRevision": item.environment.visionRevision,
            "elapsedMs": item.processingTimeMs,
            "reviewNote": analysis.reviewNote,
            "errorMessage": item.errorMessage.map { $0 as Any } ?? NSNull()
        ]
    }
    let object: [String: Any] = [
        "generatedAt": ISO8601DateFormatter().string(from: Date()),
        "sourceReports": reports.map(\.runID),
        "rows": rows
    ]
    return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
}

func markdown(for analyses: [AnalyzedFixture], reports: [FixtureReport]) -> String {
    let kPhone = analyses.filter { $0.environmentName == "K Phone" }
    let simulator = analyses.filter { $0.environmentName == "Simulator" }
    var markdown = "# P0.10 Vision Fixture Failure Analysis\n\n"
    markdown += "- Generated at: \(ISO8601DateFormatter().string(from: Date()))\n"
    markdown += "- Source reports: \(reports.map(\.runID).joined(separator: ", "))\n"
    markdown += "- K Phone rows: \(kPhone.count)\n"
    markdown += "- Simulator rows: \(simulator.count)\n"
    markdown += "- Safety: analysis reads benchmark JSON only; no production photo bodies, thumbnails, face images, or face templates are saved.\n\n"

    markdown += "## Overall\n\n"
    markdown += summaryTable(title: "By environment", groups: Dictionary(grouping: analyses, by: \.environmentName))
    markdown += "\n"
    markdown += summaryTable(title: "By mode", groups: Dictionary(grouping: analyses, by: { $0.fixture.evaluationMode }))
    markdown += "\n"
    markdown += summaryTable(title: "By fail reason", groups: Dictionary(grouping: analyses, by: \.failReason))
    markdown += "\n"

    markdown += "## Category Summary\n\n"
    markdown += categorySummary(for: kPhone, title: "K Phone primary result")
    markdown += "\n"
    markdown += categorySummary(for: simulator, title: "Simulator smoke result")
    markdown += "\n"

    markdown += "## Contract / Signal Split\n\n"
    markdown += "| Environment | contractPass | signalPass | overallPass | ocrPriorityPass | categorySignalPass |\n"
    markdown += "| --- | ---: | ---: | ---: | ---: | ---: |\n"
    for (environment, rows) in Dictionary(grouping: analyses, by: \.environmentName).sorted(by: { $0.key < $1.key }) {
        markdown += "| \(environment) | \(rows.filter(\.contractPass).count)/\(rows.count) | \(rows.filter(\.signalPass).count)/\(rows.count) | \(rows.filter(\.overallPass).count)/\(rows.count) | \(rows.filter { $0.ocrPriorityPass == true }.count)/\(rows.filter { $0.ocrPriorityPass != nil }.count) | \(rows.filter(\.categorySignalPass).count)/\(rows.count) |\n"
    }
    markdown += "\n"

    markdown += "## Fixture Detail (K Phone Primary)\n\n"
    for (category, rows) in Dictionary(grouping: kPhone, by: { $0.fixture.category }).sorted(by: { $0.key < $1.key }) {
        markdown += "### \(category)\n\n"
        for row in rows.sorted(by: { $0.fixture.fixtureId < $1.fixture.fixtureId }) {
            let item = row.fixture
            let failed = row.failedAssertions.map(\.assertion).joined(separator: "; ")
            markdown += "- \(item.variant) / \(item.evaluationMode): \(row.overallPass ? "PASS" : "FAIL") \(row.failReason)"
            markdown += " / contract=\(row.contractPass) signal=\(row.signalPass) ocr=\(row.ocrPriorityPass.map(String.init) ?? "n/a") category=\(row.categorySignalPass)"
            if failed.isEmpty == false {
                markdown += " / failed: \(failed)"
            }
            markdown += "\n"
        }
        markdown += "\n"
    }

    markdown += "## K Phone vs Simulator\n\n"
    markdown += "| Fixture | K Phone | Simulator | Classification |\n"
    markdown += "| --- | --- | --- | --- |\n"
    let byFixture = Dictionary(grouping: analyses, by: { $0.fixture.fixtureId })
    for fixtureId in byFixture.keys.sorted() {
        let rows = byFixture[fixtureId] ?? []
        let k = rows.first { $0.environmentName == "K Phone" }
        let s = rows.first { $0.environmentName == "Simulator" }
        let classification: String
        if k?.overallPass == true && s?.overallPass == false {
            classification = "K Phone passes; Simulator-only failure"
        } else if k?.overallPass == false && s?.overallPass == false {
            classification = "Both fail"
        } else if k?.overallPass == true && s?.overallPass == true {
            classification = "Both pass"
        } else {
            classification = "Needs review"
        }
        markdown += "| \(fixtureId) | \(k?.failReason ?? "missing") | \(s?.failReason ?? "missing") | \(classification) |\n"
    }
    markdown += "\n"

    markdown += "## Fixture Improvement Candidates\n\n"
    markdown += fixtureImprovementNotes()
    markdown += "\n"

    markdown += "## Evaluation Policy\n\n"
    markdown += "- K Phone is the primary environment for Vision fixture benchmark judgment.\n"
    markdown += "- Simulator remains useful for build/install/launch and metadataAware smoke checks.\n"
    markdown += "- Simulator `espressoContextError` is treated as an environment limitation unless K Phone shows the same failure.\n"
    markdown += "- Contract assertion failures are implementation regression candidates.\n"
    markdown += "- Signal assertion failures are Vision behavior, fixture realism, or threshold calibration candidates.\n"
    markdown += "- Synthetic fixture signal failures do not by themselves make the entire product concept No-Go.\n"
    return markdown
}

func goNoGoMarkdown(for analyses: [AnalyzedFixture]) -> String {
    let kPhone = analyses.filter { $0.environmentName == "K Phone" }
    let metadataAware = kPhone.filter { $0.fixture.evaluationMode == "metadataAware" }
    let ocrRows = kPhone.filter { $0.ocrPriorityPass != nil }
    let categoryRows = kPhone.filter { ["receipt", "businessCard", "document", "sign", "whiteboard", "drawing"].contains($0.fixture.category) }
    let metadataPass = metadataAware.allSatisfy(\.contractPass)
    let ocrPassCount = ocrRows.filter { $0.ocrPriorityPass == true }.count
    let categoryPassCount = categoryRows.filter(\.categorySignalPass).count
    return """
    # P0.10 Vision Classification Go/No-Go

    - Generated at: \(ISO8601DateFormatter().string(from: Date()))
    - Primary environment: K Phone
    - metadataAware screenshot contract: \(metadataPass ? "PASS" : "FAIL") (\(metadataAware.filter(\.contractPass).count)/\(metadataAware.count))
    - OCR priority signal: \(ocrPassCount)/\(ocrRows.count)
    - Product category signal for receipt/businessCard/document/sign/whiteboard/drawing: \(categoryPassCount)/\(categoryRows.count)

    ## Engine Go

    Decision: yes.

    Reasons:

    - File-based benchmark runs and emits JSON/CSV/Markdown evidence.
    - metadataAware screenshot contract passes on K Phone.
    - Release fixture mix check is part of the validation path.
    - The benchmark reads development fixture files only and does not save production photo bodies.

    ## Workflow Go

    Decision: screenshot/OCR candidate only yes.

    Reasons:

    - Screenshot fast path is stable when metadata is available.
    - OCR priority can be treated separately from exact category folders.
    - Synthetic fixture failures in category naming do not block using a conservative read-candidate queue later.

    ## Category Go

    Decision: no.

    Reasons:

    - receipt/businessCard/document/sign/whiteboard/drawing category signals are not stable enough in the synthetic fixture set.
    - imageOnly/fileOnly results are too sensitive to fixture realism and environment.
    - Product category folders need in-domain holdout data before public UI.

    ## Product Go

    Decision: no.

    Reasons:

    - Organizing tab implementation is still out of scope.
    - ClassificationJob production storage is still out of scope.
    - Read tab OCR candidate linkage is still out of scope.

    ## Initial Organizing Scope

    Public UI candidates:

    - スクショ
    - 読取候補
    - 要確認

    Do not expose as public automatic folders yet:

    - レシート自動フォルダ
    - 名刺自動フォルダ
    - 書類自動フォルダ
    - 看板自動フォルダ
    - 白板自動フォルダ
    - 建物自動フォルダ
    - 工事現場自動フォルダ
    - 図面自動フォルダ
    - 車両・重機自動フォルダ
    - 資材・設備自動フォルダ

    ## Safety

    - No PhotoKit write/delete API is used by this analysis.
    - No production photo bodies, thumbnails, face images, or face templates are saved.
    - BatchOCR and read tab behavior are not changed.
    """
}

func summaryTable(title: String, groups: [String: [AnalyzedFixture]]) -> String {
    var markdown = "### \(title)\n\n"
    markdown += "| Group | Rows | overallPass | contractPass | signalPass | FAIL reasons |\n"
    markdown += "| --- | ---: | ---: | ---: | ---: | --- |\n"
    for (key, rows) in groups.sorted(by: { $0.key < $1.key }) {
        let reasons = Dictionary(grouping: rows, by: \.failReason)
            .mapValues(\.count)
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: " ")
        markdown += "| \(key) | \(rows.count) | \(rows.filter(\.overallPass).count) | \(rows.filter(\.contractPass).count) | \(rows.filter(\.signalPass).count) | \(reasons) |\n"
    }
    return markdown
}

func categorySummary(for rows: [AnalyzedFixture], title: String) -> String {
    var markdown = "### \(title)\n\n"
    markdown += "| Category | Rows | overallPass | contractPass | signalPass | ocrPriorityPass | categorySignalPass | Main fail reasons |\n"
    markdown += "| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |\n"
    for (category, categoryRows) in Dictionary(grouping: rows, by: { $0.fixture.category }).sorted(by: { $0.key < $1.key }) {
        let ocrRelevant = categoryRows.filter { $0.ocrPriorityPass != nil }
        let reasons = Dictionary(grouping: categoryRows, by: \.failReason)
            .mapValues(\.count)
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: " ")
        markdown += "| \(category) | \(categoryRows.count) | \(categoryRows.filter(\.overallPass).count) | \(categoryRows.filter(\.contractPass).count) | \(categoryRows.filter(\.signalPass).count) | \(ocrRelevant.filter { $0.ocrPriorityPass == true }.count)/\(ocrRelevant.count) | \(categoryRows.filter(\.categorySignalPass).count) | \(reasons) |\n"
    }
    return markdown
}

func fixtureImprovementNotes() -> String {
    """
    - receipt: add stronger paper background, receipt-like line items, date, tax, total amount, and mild perspective. Current fixtures often behave as generic document/OCR candidates rather than receipt folders.
    - businessCard: add clearer business-card composition: name block, company block, phone, email, logo-like shape, and more whitespace.
    - document: keep as OCR priority candidate, but category signal needs real scanned/photographed paper examples.
    - sign: add environmental context such as sign frame, wall/pole, larger lettering, and realistic outdoor contrast.
    - whiteboard: add board frame, marker strokes, glossy surface, and room context.
    - drawing: add blueprint/diagram conventions such as grid, dimension lines, title block, and handwritten annotation.
    - buildingLike/constructionLike: current synthetic fixtures pass K Phone contracts but still need in-domain holdout before product folders.
    """
}

func scoreSummary(_ scores: Scores) -> String {
    [
        "screenshot:\(format(scores.screenshotScore))",
        "document:\(format(scores.documentScore))",
        "receipt:\(format(scores.receiptScore))",
        "businessCard:\(format(scores.businessCardScore))",
        "sign:\(format(scores.signScore))",
        "whiteboard:\(format(scores.whiteboardScore))",
        "building:\(format(scores.buildingScore))",
        "construction:\(format(scores.constructionSiteScore))",
        "ocrPriority:\(format(scores.ocrPriorityScore))"
    ].joined(separator: "|")
}

func format(_ value: Double) -> String {
    String(format: "%.3f", value)
}

func timestampString() -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd_HHmmss"
    return formatter.string(from: Date())
}

func csvEscape(_ value: String) -> String {
    "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
}
