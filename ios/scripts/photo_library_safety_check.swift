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
let scriptURL = rootURL.appendingPathComponent("ios/scripts")
let infoPlistURL = rootURL.appendingPathComponent("ios/ShimaiBako/Info.plist")
let projectURL = rootURL.appendingPathComponent("ios/ShimaiBako/ShimaiBako.xcodeproj/project.pbxproj")
let serviceURL = appSourceURL.appendingPathComponent("Services/AccuracyImprovementService.swift")
let indexServiceURL = appSourceURL.appendingPathComponent("Services/PhotoIndexService.swift")
let settingsURL = appSourceURL.appendingPathComponent("Views/SettingsView.swift")

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

let appFiles = try swiftFiles(in: appSourceURL)
let nonSafetyScriptFiles = (try? swiftFiles(in: scriptURL))?
    .filter {
        $0.relativePath.hasSuffix("photo_library_safety_check.swift") == false &&
        $0.relativePath.hasSuffix("accuracy_improvement_safety_check.swift") == false
    } ?? []
let scannedCodeFiles = appFiles + nonSafetyScriptFiles

let service = try String(contentsOf: serviceURL, encoding: .utf8)
let indexService = try String(contentsOf: indexServiceURL, encoding: .utf8)
let settings = try String(contentsOf: settingsURL, encoding: .utf8)
let infoPlist = try String(contentsOf: infoPlistURL, encoding: .utf8)
let projectFile = (try? String(contentsOf: projectURL, encoding: .utf8)) ?? ""

let forbiddenPhotoMutationPatterns = [
    "PHPhotoLibrary.shared().performChanges",
    "performChanges(",
    "PHAssetChangeRequest.deleteAssets",
    "PHAssetChangeRequest",
    "PHAssetCollectionChangeRequest",
    "PHAssetCreationRequest",
    "deleteAssets",
    "removeAssets",
    "UIImageWriteToSavedPhotosAlbum",
    "UISaveVideoAtPathToSavedPhotosAlbum",
    "creationRequestForAsset"
]
let photoMutationMatches = lineMatches(files: scannedCodeFiles, patterns: forbiddenPhotoMutationPatterns)

let photoLibraryUsageMatches = lineMatches(files: appFiles, patterns: ["PHPhotoLibrary"])
let allowedPhotoLibraryUsage = photoLibraryUsageMatches.allSatisfy { line in
    line.contains("authorizationStatus") ||
    line.contains("requestAuthorization") ||
    line.contains("presentLimitedLibraryPicker")
}

let photoMetadataMatches = lineMatches(files: appFiles, patterns: [
    "init(for: PHAsset)",
    "asset.creationDate",
    "asset.isFavorite",
    "location"
])
let metadataWrites = photoMetadataMatches.filter { line in
    line.contains("=") &&
    line.contains("self.creationDate = asset.creationDate") == false &&
    line.contains("self.isFavorite = asset.isFavorite") == false
}

let removeItemMatches = lineMatches(files: appFiles, patterns: ["removeItem"])
let destructiveKeywordMatches = lineMatches(files: appFiles, patterns: [
    "func clear",
    "func reset",
    "func remove",
    "clearAll",
    "removeValue",
    "removeObject",
    "resetting",
    "clearingOCR",
    "trash"
])
let ambiguousUITextMatches = lineMatches(files: appFiles.filter { $0.relativePath.contains("/Views/") }, patterns: [
    "写真を削除",
    "動画を削除",
    "すべて削除",
    "完全削除",
    "データを全部消す"
])

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
    && clearBody.contains("PhotoIndex") == false
    && clearBody.contains("PHAsset") == false
    && accuracyDeleteAlert.contains("await learningService.clearAll()")
    && accuracyDeleteAlert.contains("await accuracyImprovementService.clearImprovementData()")
    && accuracyDeleteAlert.contains("clearAllOCRResults") == false
    && accuracyDeleteAlert.contains("clearResult") == false
    && accuracyDeleteAlert.contains("resetCategory") == false
    && accuracyDeleteAlert.contains("元写真・元動画、OCR結果、手動分類、写真アプリ側のデータは削除されません")

let manualClassificationIsProtected =
    service.contains("indexService.hasManualClassification(for: asset)")
    && service.contains("manualProtectedCount += 1")
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

let plistHasReadUsage = infoPlist.contains("NSPhotoLibraryUsageDescription")
let plistHasAddUsage = infoPlist.contains("NSPhotoLibraryAddUsageDescription")
let plistUsageIsClear =
    infoPlist.contains("元写真・元動画は削除・変更せず")
    && infoPlist.contains("外部送信しません")
let projectHasEntitlements =
    projectFile.contains("CODE_SIGN_ENTITLEMENTS") ||
    projectFile.contains("SystemCapabilities") ||
    projectFile.contains("com.apple.developer.icloud") ||
    projectFile.contains("com.apple.security.application-groups")

var checks: [Check] = [
    check(
        "禁止PhotoKit書き込み/削除APIなし",
        passed: photoMutationMatches.isEmpty,
        details: photoMutationMatches
    ),
    check(
        "PHPhotoLibrary利用は認可/限定アクセス導線のみ",
        passed: allowedPhotoLibraryUsage,
        details: allowedPhotoLibraryUsage ? photoLibraryUsageMatches : photoLibraryUsageMatches
    ),
    check(
        "PHAssetメタデータは読み取りのみ",
        passed: metadataWrites.isEmpty,
        details: metadataWrites
    ),
    check(
        "写真追加権限なし",
        passed: plistHasReadUsage && plistHasAddUsage == false
    ),
    check(
        "写真権限文言は非破壊方針を明記",
        passed: plistUsageIsClear
    ),
    check(
        "Photos/iCloud/App Groups系entitlementなし",
        passed: projectHasEntitlements == false
    ),
    check(
        "精度向上データ削除はOCR/手動分類/PHAssetを対象にしない",
        passed: accuracyDeleteDoesNotTouchProtectedData
    ),
    check(
        "OCR結果はインデックス再構築で保持",
        passed: ocrIsPreservedByIndexRebuild
    ),
    check(
        "手動分類は自動再判定より優先",
        passed: manualClassificationIsProtected
    ),
    check(
        "削除/初期化UIに曖昧な写真削除文言なし",
        passed: ambiguousUITextMatches.isEmpty,
        details: ambiguousUITextMatches
    )
]

if removeItemMatches.isEmpty {
    checks.append(Check(name: "FileManager.removeItem使用なし", severity: .pass, details: []))
} else if removeItemIsRestricted {
    checks.append(Check(
        name: "FileManager.removeItemはアプリ内許可済みキャッシュに限定",
        severity: .warning,
        details: removeItemMatches
    ))
} else {
    checks.append(Check(
        name: "FileManager.removeItemの対象境界",
        severity: .fail,
        details: removeItemMatches
    ))
}

checks.append(Check(
    name: "削除/初期化/リセット候補の棚卸し",
    severity: .warning,
    details: Array(destructiveKeywordMatches.prefix(80))
))

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
        print("写真ライブラリ全体安全チェック: PASS")
    } else {
        print("写真ライブラリ全体安全チェック: PASS with WARNING \(warnings.joined(separator: ", "))")
    }
} else {
    print("写真ライブラリ全体安全チェック: FAIL \(failed.joined(separator: ", "))")
    exit(1)
}
