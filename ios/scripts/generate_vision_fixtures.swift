#!/usr/bin/env swift

import AppKit
import Foundation
import CoreImage

struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

struct Manifest: Encodable {
    let generatorVersion: String
    let seed: Int
    let generatedAt: String
    let fixtures: [Fixture]
}

struct Fixture: Encodable {
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
    let metadata: Metadata
    let assertions: Assertions
    let generation: Generation
    let provenance: Provenance
}

struct Metadata: Encodable {
    let isScreenshot: Bool?
    let width: Int
    let height: Int
}

struct Assertions: Encodable {
    let requiredTags: [String]
    let allowedAlternateTags: [String]
    let forbiddenTags: [String]
    let minimumScores: [String: Double]
    let relativeAssertions: [String]
}

struct Generation: Encodable {
    let rotation: Double
    let blurRadius: Double
    let perspectiveAmount: Double
    let backgroundType: String
}

struct Provenance: Encodable {
    let source: String
    let licenseID: String?
    let approved: Bool
    let reviewNote: String?
}

enum TemplateKind: String, CaseIterable {
    case receipt
    case businessCard
    case document
    case drawing
    case sign
    case whiteboard
    case chatScreenshot
    case appScreenshot
    case buildingLike
    case constructionLike
}

struct Variant {
    let name: String
    let rotation: Double
    let blurRadius: Double
    let shadow: Bool
    let lowContrast: Bool
    let backgroundType: String
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let fixtureRoot = root.appendingPathComponent("fixtures/vision_benchmark", isDirectory: true)
let syntheticRoot = fixtureRoot.appendingPathComponent("synthetic", isDirectory: true)
let manifestRoot = fixtureRoot.appendingPathComponent("manifests", isDirectory: true)
try FileManager.default.createDirectory(at: syntheticRoot, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: manifestRoot, withIntermediateDirectories: true)

let seed = 90421
var rng = SeededRandomNumberGenerator(seed: UInt64(seed))
let variants = [
    Variant(name: "clean", rotation: 0, blurRadius: 0, shadow: false, lowContrast: false, backgroundType: "plain"),
    Variant(name: "rotated", rotation: -4, blurRadius: 0, shadow: false, lowContrast: false, backgroundType: "plain"),
    Variant(name: "blur", rotation: 0, blurRadius: 1.4, shadow: false, lowContrast: false, backgroundType: "plain"),
    Variant(name: "shadow", rotation: 0, blurRadius: 0, shadow: true, lowContrast: false, backgroundType: "deskShadow"),
    Variant(name: "low_contrast", rotation: 0, blurRadius: 0, shadow: false, lowContrast: true, backgroundType: "lowContrast")
]

var fixtures: [Fixture] = []
let imageSize = CGSize(width: 900, height: 1200)

for kind in TemplateKind.allCases {
    let selectedVariants = kind == .buildingLike || kind == .constructionLike ? Array(variants.prefix(3)) : variants
    for (index, variant) in selectedVariants.enumerated() {
        if kind == .chatScreenshot || kind == .appScreenshot {
            for mode in ["metadataAware", "imageOnly"] {
                let fixture = try writeFixture(
                    kind: kind,
                    variant: variant,
                    index: index + 1,
                    mode: mode,
                    size: CGSize(width: 900, height: 1200),
                    rng: &rng
                )
                fixtures.append(fixture)
            }
        } else {
            let fixture = try writeFixture(
                kind: kind,
                variant: variant,
                index: index + 1,
                mode: "fileOnly",
                size: imageSize,
                rng: &rng
            )
            fixtures.append(fixture)
        }
    }
}

let manifest = Manifest(
    generatorVersion: "p09-synthetic-fixtures-1",
    seed: seed,
    generatedAt: ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_766_000_000)),
    fixtures: fixtures
)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let manifestData = try encoder.encode(manifest)
try manifestData.write(to: manifestRoot.appendingPathComponent("p09_synthetic_manifest.json"), options: .atomic)

let sourcesTemplate = """
fixture_id,local_file,sha256,title,creator,source_page_url,original_file_url,license_id,license_version,license_url,license_verified_at,license_asserted_by,retrieved_at,retrieval_query,retrieval_tool,category,expected_labels,modifications,attribution_text,redistribution_allowed,repository_policy,contains_people,contains_personal_data,contains_trademark,reviewer,review_note,approved
example_fixture,example.png,,Example title,,,,CC0,1.0,,YYYY-MM-DD,reviewer,YYYY-MM-DD,query,manual,document,"document;ocrNeeded",crop,,true,exclude_until_approved,false,false,false,,,false
"""
try sourcesTemplate.write(to: manifestRoot.appendingPathComponent("external_sources_template.csv"), atomically: true, encoding: .utf8)

let readme = """
# Vision Benchmark Fixtures

These files are development-only contract fixtures for the DEBUG Vision benchmark. Do not add this directory to the iOS target or Copy Bundle Resources.

Synthetic fixtures use fictional names, fictional companies, fictional UI, and locally generated shapes. They are not product accuracy evidence for real-world building, construction, heavy equipment, business card, or receipt classification.
"""
try readme.write(to: fixtureRoot.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

print("Generated \(fixtures.count) fixtures at \(fixtureRoot.path)")

func writeFixture(
    kind: TemplateKind,
    variant: Variant,
    index: Int,
    mode: String,
    size: CGSize,
    rng: inout SeededRandomNumberGenerator
) throws -> Fixture {
    let suffix = String(format: "%03d", index)
    let fixtureId = "synthetic_\(kind.rawValue)_\(variant.name)_\(mode)_\(suffix)"
    let fileName = "\(fixtureId).png"
    let image = drawFixture(kind: kind, variant: variant, size: size, rng: &rng)
    let finalImage = variant.blurRadius > 0 ? blurred(image: image, radius: variant.blurRadius) : image
    try writePNG(finalImage, to: syntheticRoot.appendingPathComponent(fileName))

    let expectedTags = expectedFormatTags(kind: kind)
    let metadataScreenshot: Bool?
    if kind == .chatScreenshot || kind == .appScreenshot {
        metadataScreenshot = mode == "metadataAware" ? true : nil
    } else {
        metadataScreenshot = false
    }

    return Fixture(
        fixtureId: fixtureId,
        file: fileName,
        layer: "contract",
        split: "development",
        category: kind.rawValue,
        variant: variant.name,
        evaluationMode: mode,
        expectedFormatTags: expectedTags,
        expectedContentTags: [],
        expectedOCRNeeded: true,
        metadata: Metadata(isScreenshot: metadataScreenshot, width: Int(size.width), height: Int(size.height)),
        assertions: assertions(kind: kind, mode: mode),
        generation: Generation(
            rotation: variant.rotation,
            blurRadius: variant.blurRadius,
            perspectiveAmount: variant.name == "rotated" ? 0.1 : 0,
            backgroundType: variant.backgroundType
        ),
        provenance: Provenance(
            source: "localSynthetic",
            licenseID: "project-generated",
            approved: true,
            reviewNote: "Contract fixture generated locally; not real-world accuracy evidence."
        )
    )
}

func expectedFormatTags(kind: TemplateKind) -> [String] {
    switch kind {
    case .receipt: return ["receipt", "document"]
    case .businessCard: return ["businessCard", "document"]
    case .document: return ["document"]
    case .drawing: return ["document", "ocrNeeded"]
    case .sign: return ["sign", "ocrNeeded"]
    case .whiteboard: return ["whiteboard", "ocrNeeded"]
    case .chatScreenshot, .appScreenshot: return ["screenshot", "ocrNeeded"]
    case .buildingLike: return ["buildingLike"]
    case .constructionLike: return ["constructionLike"]
    }
}

func assertions(kind: TemplateKind, mode: String) -> Assertions {
    switch kind {
    case .chatScreenshot, .appScreenshot:
        return Assertions(
            requiredTags: mode == "metadataAware" ? ["screenshot", "ocrNeeded"] : ["ocrNeeded"],
            allowedAlternateTags: ["document"],
            forbiddenTags: ["receipt"],
            minimumScores: ["ocrPriorityScore": mode == "metadataAware" ? 0.8 : 0.2],
            relativeAssertions: mode == "metadataAware" ? ["screenshotScore > documentScore"] : []
        )
    case .receipt:
        return Assertions(requiredTags: ["ocrNeeded"], allowedAlternateTags: ["receipt", "document"], forbiddenTags: ["screenshot"], minimumScores: ["ocrPriorityScore": 0.2], relativeAssertions: ["documentScore > foodScore"])
    case .businessCard:
        return Assertions(requiredTags: ["ocrNeeded"], allowedAlternateTags: ["businessCard", "document"], forbiddenTags: ["screenshot"], minimumScores: ["ocrPriorityScore": 0.2], relativeAssertions: ["documentScore > landscapeScore"])
    case .document, .drawing:
        return Assertions(requiredTags: ["ocrNeeded"], allowedAlternateTags: ["document"], forbiddenTags: ["screenshot"], minimumScores: ["documentVisualScore": 0.2], relativeAssertions: ["documentScore > foodScore"])
    case .sign, .whiteboard:
        return Assertions(requiredTags: ["ocrNeeded"], allowedAlternateTags: ["sign", "whiteboard", "document"], forbiddenTags: ["screenshot"], minimumScores: ["ocrPriorityScore": 0.2], relativeAssertions: [])
    case .buildingLike, .constructionLike:
        return Assertions(requiredTags: [], allowedAlternateTags: ["buildingLike", "constructionLike"], forbiddenTags: ["screenshot"], minimumScores: [:], relativeAssertions: [])
    }
}

func drawFixture(kind: TemplateKind, variant: Variant, size: CGSize, rng: inout SeededRandomNumberGenerator) -> NSImage {
    let image = NSImage(size: size)
    image.lockFocus()
    let bounds = CGRect(origin: .zero, size: size)
    let background = variant.lowContrast ? NSColor(calibratedWhite: 0.92, alpha: 1) : NSColor(calibratedWhite: 0.98, alpha: 1)
    background.setFill()
    bounds.fill()

    if variant.shadow {
        NSColor(calibratedWhite: 0.78, alpha: 1).setFill()
        CGRect(x: 95, y: 70, width: size.width - 170, height: size.height - 160).fill()
    }

    let context = NSGraphicsContext.current?.cgContext
    context?.saveGState()
    context?.translateBy(x: size.width / 2, y: size.height / 2)
    context?.rotate(by: variant.rotation * .pi / 180)
    context?.translateBy(x: -size.width / 2, y: -size.height / 2)

    switch kind {
    case .receipt:
        drawReceipt(lowContrast: variant.lowContrast, size: size)
    case .businessCard:
        drawBusinessCard(lowContrast: variant.lowContrast, size: size)
    case .document:
        drawDocument(title: "Fictional Project Note", lowContrast: variant.lowContrast, size: size)
    case .drawing:
        drawDrawing(lowContrast: variant.lowContrast, size: size)
    case .sign:
        drawSign(lowContrast: variant.lowContrast, size: size)
    case .whiteboard:
        drawWhiteboard(lowContrast: variant.lowContrast, size: size)
    case .chatScreenshot:
        drawChatScreenshot(lowContrast: variant.lowContrast, size: size)
    case .appScreenshot:
        drawAppScreenshot(lowContrast: variant.lowContrast, size: size)
    case .buildingLike:
        drawBuildingLike(lowContrast: variant.lowContrast, size: size)
    case .constructionLike:
        drawConstructionLike(lowContrast: variant.lowContrast, size: size)
    }

    context?.restoreGState()
    image.unlockFocus()
    return image
}

func drawReceipt(lowContrast: Bool, size: CGSize) {
    paperRect(size).fillWhite(stroke: true)
    drawCentered("SAMPLE RECEIPT", y: 1010, size: 34, lowContrast: lowContrast)
    drawText(["Fictional Store 2525", "Aoba Test Street", "ITEM ALPHA      1,200", "ITEM BETA         860", "TAX              206", "TOTAL          2,266", "THANK YOU"], x: 170, y: 900, size: 26, lowContrast: lowContrast)
}

func drawBusinessCard(lowContrast: Bool, size: CGSize) {
    paperRect(size).fillWhite(stroke: true)
    drawText(["Aoba Sample Works", "Mika Testname", "Design Research", "mail: sample@example.invalid", "tel: 000-0000-0000"], x: 170, y: 860, size: 30, lowContrast: lowContrast)
    NSColor.systemBlue.withAlphaComponent(0.7).setFill()
    CGRect(x: 610, y: 760, width: 90, height: 90).fill()
}

func drawDocument(title: String, lowContrast: Bool, size: CGSize) {
    paperRect(size).fillWhite(stroke: true)
    drawText([title, "1. Scope", "2. Safety notes", "3. Local processing", "4. Review checklist"], x: 160, y: 930, size: 28, lowContrast: lowContrast)
    for row in 0..<6 {
        NSColor(calibratedWhite: lowContrast ? 0.7 : 0.3, alpha: 1).setStroke()
        NSBezierPath.strokeLine(from: CGPoint(x: 160, y: 590 - row * 52), to: CGPoint(x: 720, y: 590 - row * 52))
    }
}

func drawDrawing(lowContrast: Bool, size: CGSize) {
    paperRect(size).fillWhite(stroke: true)
    drawText(["PLAN A-01", "ROOM", "ENTRY", "WALL", "NOTE"], x: 170, y: 940, size: 24, lowContrast: lowContrast)
    NSColor(calibratedWhite: lowContrast ? 0.6 : 0.15, alpha: 1).setStroke()
    let path = NSBezierPath()
    path.lineWidth = 5
    path.move(to: CGPoint(x: 220, y: 240))
    path.line(to: CGPoint(x: 660, y: 240))
    path.line(to: CGPoint(x: 660, y: 720))
    path.line(to: CGPoint(x: 220, y: 720))
    path.close()
    path.stroke()
    NSBezierPath(rect: CGRect(x: 340, y: 390, width: 180, height: 170)).stroke()
}

func drawSign(lowContrast: Bool, size: CGSize) {
    NSColor(calibratedRed: 0.10, green: 0.18, blue: 0.28, alpha: 1).setFill()
    CGRect(x: 0, y: 0, width: size.width, height: size.height).fill()
    NSColor.white.setFill()
    CGRect(x: 120, y: 390, width: 660, height: 360).fill()
    drawCentered("SAFETY NOTICE", y: 600, size: 52, lowContrast: lowContrast)
    drawCentered("LOCAL TEST AREA", y: 520, size: 34, lowContrast: lowContrast)
}

func drawWhiteboard(lowContrast: Bool, size: CGSize) {
    NSColor(calibratedWhite: 0.88, alpha: 1).setFill()
    CGRect(x: 80, y: 180, width: 740, height: 790).fill()
    NSColor(calibratedWhite: 0.35, alpha: 1).setStroke()
    NSBezierPath(rect: CGRect(x: 80, y: 180, width: 740, height: 790)).stroke()
    drawText(["TODAY", "- idea", "- todo", "- route", "- next"], x: 170, y: 820, size: 38, lowContrast: lowContrast)
    NSColor.systemGreen.setStroke()
    let path = NSBezierPath()
    path.lineWidth = 8
    path.move(to: CGPoint(x: 500, y: 660))
    path.curve(to: CGPoint(x: 690, y: 520), controlPoint1: CGPoint(x: 590, y: 710), controlPoint2: CGPoint(x: 660, y: 660))
    path.stroke()
}

func drawChatScreenshot(lowContrast: Bool, size: CGSize) {
    drawScreenshotChrome(title: "Fictional Chat", size: size)
    bubble("memo idea", x: 130, y: 820, width: 360, incoming: true, lowContrast: lowContrast)
    bubble("TODO check list", x: 380, y: 690, width: 390, incoming: false, lowContrast: lowContrast)
    bubble("map route station", x: 130, y: 560, width: 420, incoming: true, lowContrast: lowContrast)
}

func drawAppScreenshot(lowContrast: Bool, size: CGSize) {
    drawScreenshotChrome(title: "Sample Settings", size: size)
    drawText(["Settings", "Notifications", "Permission", "Login", "Error log", "Version 1.0"], x: 150, y: 860, size: 36, lowContrast: lowContrast)
    for row in 0..<5 {
        NSColor(calibratedWhite: 0.88, alpha: 1).setFill()
        CGRect(x: 130, y: 760 - row * 110, width: 640, height: 72).fill()
    }
}

func drawBuildingLike(lowContrast: Bool, size: CGSize) {
    NSColor(calibratedRed: 0.60, green: 0.78, blue: 0.94, alpha: 1).setFill()
    CGRect(x: 0, y: 0, width: size.width, height: size.height).fill()
    NSColor(calibratedWhite: 0.78, alpha: 1).setFill()
    CGRect(x: 230, y: 180, width: 440, height: 760).fill()
    NSColor(calibratedWhite: lowContrast ? 0.7 : 0.2, alpha: 1).setStroke()
    for x in stride(from: 280, through: 610, by: 80) {
        for y in stride(from: 260, through: 840, by: 110) {
            NSBezierPath(rect: CGRect(x: x, y: y, width: 42, height: 58)).stroke()
        }
    }
}

func drawConstructionLike(lowContrast: Bool, size: CGSize) {
    NSColor(calibratedRed: 0.83, green: 0.78, blue: 0.68, alpha: 1).setFill()
    CGRect(x: 0, y: 0, width: size.width, height: size.height).fill()
    NSColor.systemOrange.setFill()
    CGRect(x: 120, y: 230, width: 640, height: 90).fill()
    NSColor(calibratedWhite: 0.2, alpha: 1).setStroke()
    let crane = NSBezierPath()
    crane.lineWidth = 8
    crane.move(to: CGPoint(x: 250, y: 300))
    crane.line(to: CGPoint(x: 250, y: 880))
    crane.line(to: CGPoint(x: 700, y: 880))
    crane.stroke()
    drawText(["SITE TEST", "AREA 03"], x: 360, y: 700, size: 34, lowContrast: lowContrast)
}

func drawScreenshotChrome(title: String, size: CGSize) {
    NSColor(calibratedWhite: 0.95, alpha: 1).setFill()
    CGRect(origin: .zero, size: size).fill()
    NSColor(calibratedWhite: 0.1, alpha: 1).setFill()
    CGRect(x: 0, y: size.height - 72, width: size.width, height: 72).fill()
    drawCentered(title, y: Int(size.height - 55), size: 28, lowContrast: false, color: .white)
}

func bubble(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, incoming: Bool, lowContrast: Bool) {
    let color = incoming ? NSColor(calibratedWhite: 0.86, alpha: 1) : NSColor(calibratedRed: 0.68, green: 0.86, blue: 1.0, alpha: 1)
    color.setFill()
    NSBezierPath(roundedRect: CGRect(x: x, y: y, width: width, height: 78), xRadius: 22, yRadius: 22).fill()
    drawText([text], x: x + 26, y: y + 22, size: 28, lowContrast: lowContrast)
}

func paperRect(_ size: CGSize) -> CGRect {
    CGRect(x: 120, y: 100, width: size.width - 240, height: size.height - 200)
}

func drawText(_ lines: [String], x: CGFloat, y: CGFloat, size: CGFloat, lowContrast: Bool) {
    for (offset, line) in lines.enumerated() {
        drawString(line, x: x, y: y - CGFloat(offset) * (size + 18), size: size, lowContrast: lowContrast)
    }
}

func drawCentered(_ text: String, y: Int, size: CGFloat, lowContrast: Bool, color: NSColor? = nil) {
    let attrs = textAttributes(size: size, lowContrast: lowContrast, color: color)
    let attributed = NSAttributedString(string: text, attributes: attrs)
    let width = attributed.size().width
    attributed.draw(at: CGPoint(x: (900 - width) / 2, y: CGFloat(y)))
}

func drawString(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat, lowContrast: Bool) {
    NSAttributedString(string: text, attributes: textAttributes(size: size, lowContrast: lowContrast)).draw(at: CGPoint(x: x, y: y))
}

func textAttributes(size: CGFloat, lowContrast: Bool, color: NSColor? = nil) -> [NSAttributedString.Key: Any] {
    [
        .font: NSFont.monospacedSystemFont(ofSize: size, weight: .semibold),
        .foregroundColor: color ?? NSColor(calibratedWhite: lowContrast ? 0.42 : 0.08, alpha: 1)
    ]
}

func blurred(image: NSImage, radius: Double) -> NSImage {
    guard let tiff = image.tiffRepresentation,
          let ciImage = CIImage(data: tiff),
          let filter = CIFilter(name: "CIGaussianBlur") else {
        return image
    }
    filter.setValue(ciImage, forKey: kCIInputImageKey)
    filter.setValue(radius, forKey: kCIInputRadiusKey)
    let context = CIContext()
    guard let output = filter.outputImage,
          let cgImage = context.createCGImage(output, from: ciImage.extent) else {
        return image
    }
    return NSImage(cgImage: cgImage, size: image.size)
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "FixtureGenerator", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG変換に失敗しました"])
    }
    try png.write(to: url, options: .atomic)
}

extension CGRect {
    func fillWhite(stroke: Bool) {
        NSColor.white.setFill()
        fill()
        if stroke {
            NSColor(calibratedWhite: 0.75, alpha: 1).setStroke()
            NSBezierPath(rect: self).stroke()
        }
    }
}
