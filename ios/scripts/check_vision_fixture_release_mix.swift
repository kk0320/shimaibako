#!/usr/bin/env swift

import Foundation

let repositoryRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let projectFile = repositoryRoot.appendingPathComponent("ios/ShimaiBako/ShimaiBako.xcodeproj/project.pbxproj")

var failures: [String] = []

if let projectText = try? String(contentsOf: projectFile, encoding: .utf8) {
    let forbiddenProjectTokens = [
        "fixtures/vision_benchmark",
        "p09_synthetic_manifest.json",
        "synthetic_receipt",
        "synthetic_businessCard",
        "synthetic_chatScreenshot"
    ]

    for token in forbiddenProjectTokens where projectText.contains(token) {
        failures.append("Xcode project references development fixture token: \(token)")
    }
} else {
    failures.append("Unable to read Xcode project file at \(projectFile.path)")
}

if let appPathIndex = CommandLine.arguments.firstIndex(of: "--app-path"),
   CommandLine.arguments.indices.contains(appPathIndex + 1) {
    let appURL = URL(fileURLWithPath: CommandLine.arguments[appPathIndex + 1])
    if let enumerator = FileManager.default.enumerator(at: appURL, includingPropertiesForKeys: nil) {
        for case let fileURL as URL in enumerator {
            let path = fileURL.path
            if path.contains("fixtures/vision_benchmark") ||
                path.contains("p09_synthetic_manifest.json") ||
                path.contains("synthetic_receipt") ||
                path.contains("synthetic_businessCard") ||
                path.contains("synthetic_chatScreenshot") {
                failures.append("App bundle contains development fixture file: \(path)")
            }
        }
    } else {
        failures.append("Unable to inspect app bundle at \(appURL.path)")
    }
}

if failures.isEmpty {
    print("PASS: Vision fixture files are not referenced by the Xcode project or inspected app bundle.")
} else {
    print("FAIL: Vision fixture release mix check failed.")
    for failure in failures {
        print("- \(failure)")
    }
    exit(1)
}
