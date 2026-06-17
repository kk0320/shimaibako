import Foundation

enum Severity: String {
    case pass = "PASS"
    case warning = "WARNING"
    case fail = "FAIL"
}

struct Check {
    let name: String
    let severity: Severity
    let details: [String]
}

struct SourceFile {
    let url: URL
    let relativePath: String
    let text: String
}

let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let appSourceURL = rootURL.appendingPathComponent("ios/ShimaiBako/ShimaiBako")
let serviceURL = appSourceURL.appendingPathComponent("Services/AccuracyImprovementService.swift")
let indexServiceURL = appSourceURL.appendingPathComponent("Services/PhotoIndexService.swift")
let settingsURL = appSourceURL.appendingPathComponent("Views/SettingsView.swift")
let photoLibraryServiceURL = appSourceURL.appendingPathComponent("Services/PhotoLibraryService.swift")

func swiftFiles(in directoryURL: URL) throws -> [SourceFile] {
    guard let enumerator = FileManager.default.enumerator(
        at: directoryURL,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }

    var files: [SourceFile] = []
    for case let fileURL as URL in enumerator {
        guard fileURL.pathExtension == "swift" else {
            continue
        }

        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let relativePath = fileURL.path.replacingOccurrences(of: rootURL.path + "/", with: "")
        files.append(SourceFile(url: fileURL, relativePath: relativePath, text: text))
    }

    return files.sorted { $0.relativePath < $1.relativePath }
}

func lineMatches(files: [SourceFile], patterns: [String]) -> [String] {
    var matches: [String] = []

    for file in files {
        let lines = file.text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            let lineText = String(line)
            if patterns.contains(where: { lineText.contains($0) }) {
                matches.append("\(file.relativePath):\(index + 1): \(lineText.trimmingCharacters(in: .whitespaces))")
            }
        }
    }

    return matches
}

func body(of functionName: String, in source: String) -> String {
    guard let startRange = source.range(of: "func \(functionName)") else {
        return ""
    }

    let tail = source[startRange.lowerBound...]
    guard let openBrace = tail.firstIndex(of: "{") else {
        return ""
    }

    var depth = 0
    var current = openBrace

    while current < source.endIndex {
        let character = source[current]
        if character == "{" {
            depth += 1
        } else if character == "}" {
            depth -= 1
            if depth == 0 {
                return String(source[openBrace...current])
            }
        }

        current = source.index(after: current)
    }

    return ""
}

func snippet(startingAt marker: String, endingBefore endMarker: String, in source: String) -> String {
    guard let startRange = source.range(of: marker) else {
        return ""
    }

    let tail = source[startRange.lowerBound...]
    guard let endRange = tail.range(of: endMarker) else {
        return String(tail)
    }

    return String(tail[..<endRange.lowerBound])
}

func check(_ name: String, passed: Bool, details: [String] = []) -> Check {
    Check(name: name, severity: passed ? .pass : .fail, details: details)
}

let sourceFiles = try swiftFiles(in: appSourceURL)
let service = try String(contentsOf: serviceURL, encoding: .utf8)
let indexService = try String(contentsOf: indexServiceURL, encoding: .utf8)
let settings = try String(contentsOf: settingsURL, encoding: .utf8)
let photoLibraryService = try String(contentsOf: photoLibraryServiceURL, encoding: .utf8)

let fatalPhotoMutationPatterns = [
    "PHPhotoLibrary.shared().performChanges",
    "performChanges(",
    "PHAssetChangeRequest.deleteAssets",
    "PHAssetChangeRequest",
    "PHAssetCollectionChangeRequest",
    "deleteAssets",
    "removeAssets",
    "PHAssetCreationRequest",
    "UIImageWriteToSavedPhotosAlbum"
]
let photoMutationMatches = lineMatches(files: sourceFiles, patterns: fatalPhotoMutationPatterns)
let removeItemMatches = lineMatches(files: sourceFiles, patterns: ["removeItem"])
let cleanupMatches = lineMatches(files: sourceFiles, patterns: ["cleanup", "purge"])

let clearBody = body(of: "clearImprovementData", in: service)
let removeLocalDataBody = body(of: "removeLocalDataFile", in: service)
let makeRecordBody = body(of: "makeRecord", in: indexService)
let accuracyDeleteAlert = snippet(
    startingAt: ".alert(\"精度向上データを削除しますか？\"",
    endingBefore: ".task",
    in: settings
)

let removeItemIsRestricted =
    removeItemMatches.count == 1
    && removeItemMatches.first?.contains("AccuracyImprovementService.swift") == true
    && service.contains("private enum LocalDataDeletionTarget")
    && service.contains("case futureImageFeatureCache")
    && service.contains("future_image_feature_cache.json")
    && clearBody.contains("removeLocalDataFile(.futureImageFeatureCache)")
    && removeLocalDataBody.contains("applicationSupportDirectory()")
    && removeLocalDataBody.contains("target.fileName")
    && removeLocalDataBody.contains("fileURL.deletingLastPathComponent().path == directoryURL.path")
    && removeLocalDataBody.contains("removeItem(at: fileURL)")
    && removeLocalDataBody.contains("PHAsset") == false
    && removeLocalDataBody.contains("localIdentifier") == false
    && removeLocalDataBody.contains("ocr") == false
    && removeLocalDataBody.contains("manual") == false

let accuracyDeleteDoesNotTouchProtectedData =
    clearBody.contains("removeLocalDataFile(.futureImageFeatureCache)")
    && clearBody.contains("処理履歴を削除しました")
    && clearBody.contains("clearResult") == false
    && clearBody.contains("clearOCR") == false
    && clearBody.contains("clearAllOCR") == false
    && clearBody.contains("resetCategory") == false
    && clearBody.contains("resetAll") == false
    && clearBody.contains("PhotoIndex") == false
    && clearBody.contains("PHAsset") == false
    && accuracyDeleteAlert.contains("await learningService.clearAll()")
    && accuracyDeleteAlert.contains("await accuracyImprovementService.clearImprovementData()")
    && accuracyDeleteAlert.contains("clearAllOCRResults") == false
    && accuracyDeleteAlert.contains("clearResult") == false
    && accuracyDeleteAlert.contains("resetCategory") == false
    && accuracyDeleteAlert.contains("元写真・元動画、OCR結果、手動分類、写真アプリ側のデータは削除されません")

let manualProtectionIsExplicit =
    service.contains("indexService.hasManualClassification(for: asset)")
    && service.contains("manualProtectedCount += 1")
    && service.contains("continue")
    && indexService.contains("func hasManualClassification(for asset: PhotoAsset) -> Bool")
    && indexService.contains("record.manualCategory != nil || record.manualScreenshotSubcategory != nil")
    && makeRecordBody.contains("let manualCategory = preservingManual ? existingRecord?.manualCategory : nil")
    && makeRecordBody.contains("reason: \"手動分類\"")

let ocrIsPreservedByIndexRebuild =
    makeRecordBody.contains("ocrResult?.ocrText ?? existingRecord?.ocrText ?? \"\"")
    && makeRecordBody.contains("ocrResult?.ocrLanguage ?? existingRecord?.ocrLanguage")
    && makeRecordBody.contains("ocrResult?.processedAt ?? existingRecord?.ocrProcessedAt")
    && makeRecordBody.contains("ocrResult?.errorMessage ?? existingRecord?.ocrErrorMessage")
    && indexService.contains("func rebuildSearchIndex(for assets: [PhotoAsset], ocrService: OCRService) async")
    && indexService.contains("await rebuild(for: assets, ocrService: ocrService)")

var checks: [Check] = [
    check(
        "写真ライブラリ変更APIなし",
        passed: photoMutationMatches.isEmpty,
        details: photoMutationMatches
    ),
    check(
        "最大50件制限",
        passed: service.contains("private static let maxRunCount = 50")
            && service.contains("selected.count < Self.maxRunCount")
    ),
    check(
        "キャンセル中断",
        passed: service.contains("cancellationRequested || Task.isCancelled")
            && service.contains("ユーザー操作でキャンセルしました。")
    ),
    check(
        "手動分類保護",
        passed: manualProtectionIsExplicit
    ),
    check(
        "OCR結果保護",
        passed: ocrIsPreservedByIndexRebuild
            && accuracyDeleteAlert.contains("clearAllOCRResults") == false
            && clearBody.contains("clearResult") == false
            && clearBody.contains("clearOCR") == false
    ),
    check(
        "低電力モード中断",
        passed: service.contains("deviceSafety.isLowPowerModeEnabled")
            && service.contains("低電力モード中のため中断しました。")
    ),
    check(
        "バッテリー不足中断",
        passed: service.contains("deviceSafety.batteryLevel < 0.5")
            && service.contains("バッテリー残量が50%未満")
    ),
    check(
        "保存容量不足中断",
        passed: service.contains("private static let minimumCapacityBytes: Int64 = 1_000_000_000")
            && service.contains("保存容量が1GB未満")
    ),
    check(
        "精度向上データ削除の対象境界",
        passed: accuracyDeleteDoesNotTouchProtectedData
    ),
    check(
        "実機検証用履歴表示",
        passed: settings.contains("開始日時")
            && settings.contains("終了日時")
            && settings.contains("実行結果")
            && settings.contains("実行モード")
            && settings.contains("手動分類保護")
    )
]

if removeItemMatches.isEmpty {
    checks.append(Check(name: "removeItem使用なし", severity: .pass, details: []))
} else if removeItemIsRestricted {
    checks.append(Check(
        name: "removeItemはアプリ内の許可済みローカルデータに限定",
        severity: .warning,
        details: removeItemMatches
    ))
} else {
    checks.append(Check(
        name: "removeItemの対象境界",
        severity: .fail,
        details: removeItemMatches
    ))
}

if cleanupMatches.isEmpty {
    checks.append(Check(name: "cleanup/purge処理なし", severity: .pass, details: []))
} else {
    checks.append(Check(
        name: "cleanup/purge表現あり",
        severity: .warning,
        details: cleanupMatches
    ))
}

var failed: [String] = []
var warnings: [String] = []

for check in checks {
    print("\(check.severity.rawValue): \(check.name)")
    for detail in check.details {
        print("  - \(detail)")
    }

    switch check.severity {
    case .pass:
        break
    case .warning:
        warnings.append(check.name)
    case .fail:
        failed.append(check.name)
    }
}

if failed.isEmpty {
    if warnings.isEmpty {
        print("精度向上モード安全チェック: PASS")
    } else {
        print("精度向上モード安全チェック: PASS with WARNING \(warnings.joined(separator: ", "))")
    }
} else {
    print("精度向上モード安全チェック: FAIL \(failed.joined(separator: ", "))")
    exit(1)
}
