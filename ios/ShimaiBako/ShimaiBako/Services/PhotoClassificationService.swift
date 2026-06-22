import Combine
import Foundation

@MainActor
final class PhotoClassificationService: ObservableObject {
    @Published private(set) var recordsByAssetID: [String: PhotoClassification] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var isUpdatingMetadata = false
    @Published private(set) var metadataUpdateProcessedCount = 0
    @Published private(set) var metadataUpdateTotalCount = 0
    @Published private(set) var lastUpdateSummary: PhotoClassificationUpdateSummary = .empty
    @Published private(set) var lastMetadataUpdatedAt: Date?
    @Published var errorMessage: String?
    #if DEBUG
    @Published private(set) var selfTestReport: PhotoClassificationSelfTestReport?
    @Published private(set) var metadataValidationReport: MetadataOnlyOrganizationValidationReport?
    #endif

    private let store: PhotoClassificationStoring
    private var shouldCancelMetadataUpdate = false

    init(store: PhotoClassificationStoring? = nil) {
        self.store = store ?? JSONPhotoClassificationStore()

        Task {
            await load()
        }
    }

    var recordCount: Int {
        recordsByAssetID.count
    }

    var summary: PhotoClassificationSummary {
        let records = Array(recordsByAssetID.values)
        return PhotoClassificationSummary(
            totalCount: records.count,
            classifiedCount: records.filter { $0.resolvedCategory != nil }.count,
            manualCount: records.filter { $0.manualCategory != nil }.count,
            screenshotCount: records.filter { $0.isScreenshot || $0.resolvedCategory == .screenshot }.count,
            readCandidateCount: records.filter { $0.contentTags.contains(Self.readCandidateTag) || $0.resolvedCategory == .readCandidate }.count,
            needsReviewCount: count(.needsReview, in: records),
            unorganizedCount: records.filter { $0.resolvedCategory == nil || $0.resolvedCategory == .unorganized }.count
        )
    }

    func classification(for assetIdentifier: String) -> PhotoClassification? {
        recordsByAssetID[assetIdentifier]
    }

    func organizationVirtualFolderCount(
        _ folder: OrganizationVirtualFolder,
        libraryTotalCount: Int
    ) -> Int {
        switch folder {
        case .unorganized:
            return max(virtualFolderRecords(for: folder).count, libraryTotalCount - summary.classifiedCount)
        case .screenshots, .readCandidates, .needsReview:
            return virtualFolderRecords(for: folder).count
        }
    }

    func organizationVirtualFolderIdentifierPage(
        _ folder: OrganizationVirtualFolder,
        limit: Int,
        offset: Int
    ) -> [String] {
        let records = virtualFolderRecords(for: folder)
        return Array(records.dropFirst(max(offset, 0)).prefix(max(limit, 1))).map(\.assetIdentifier)
    }

    func isIdentifierInVirtualFolder(
        _ assetIdentifier: String,
        folder: OrganizationVirtualFolder
    ) -> Bool {
        guard let record = recordsByAssetID[assetIdentifier] else {
            return folder == .unorganized
        }

        return record.isIncluded(in: folder)
    }

    func upsert(_ classification: PhotoClassification) async {
        var normalized = classification
        normalized.resolvedCategory = normalized.manualCategory ?? normalized.autoPrimaryCategory
        normalized.updatedAt = Date()
        recordsByAssetID[normalized.assetIdentifier] = normalized
        await saveAll()
    }

    func applyManualCategory(
        _ category: ImageClassificationCategory?,
        assetIdentifier: String
    ) async {
        var record = recordsByAssetID[assetIdentifier] ?? PhotoClassification(assetIdentifier: assetIdentifier)
        record.applyManualCategory(category)
        recordsByAssetID[assetIdentifier] = record
        await saveAll()
    }

    func updateMetadataOnly(
        assets: [PhotoAsset],
        indexService: PhotoIndexService
    ) async {
        guard isUpdatingMetadata == false else {
            return
        }

        guard assets.isEmpty == false else {
            lastUpdateSummary = .empty
            errorMessage = "軽量整理できる読み込み済み写真がありません。"
            return
        }

        isUpdatingMetadata = true
        shouldCancelMetadataUpdate = false
        metadataUpdateProcessedCount = 0
        metadataUpdateTotalCount = assets.count
        errorMessage = nil

        let identifiers = assets.map(\.localIdentifier)
        let indexRecords = await indexService.recordsByLocalIdentifier(localIdentifiers: identifiers)
        var nextRecordsByID = recordsByAssetID
        var updateSummary = PhotoClassificationUpdateSummary(
            processedCount: 0,
            totalCount: assets.count,
            screenshotCount: 0,
            readCandidateCount: 0,
            needsReviewCount: 0,
            unorganizedCount: 0,
            manualProtectedCount: 0
        )
        var lastPublishedAt = Date.distantPast

        for (index, asset) in assets.enumerated() {
            if shouldCancelMetadataUpdate {
                break
            }

            var record = nextRecordsByID[asset.localIdentifier] ?? PhotoClassification(assetIdentifier: asset.localIdentifier)
            let indexRecord = indexRecords[asset.localIdentifier]
            record.applyMetadataOnly(
                asset: asset,
                indexRecord: indexRecord,
                updatedAt: Date()
            )
            nextRecordsByID[asset.localIdentifier] = record

            updateSummary.processedCount = index + 1
            updateSummary.manualProtectedCount += record.manualCategory == nil ? 0 : 1
            if record.isScreenshot || record.resolvedCategory == .screenshot {
                updateSummary.screenshotCount += 1
            }
            if record.contentTags.contains(Self.readCandidateTag) || record.resolvedCategory == .readCandidate {
                updateSummary.readCandidateCount += 1
            }
            if record.resolvedCategory == .needsReview {
                updateSummary.needsReviewCount += 1
            }
            if record.resolvedCategory == nil || record.resolvedCategory == .unorganized {
                updateSummary.unorganizedCount += 1
            }

            let now = Date()
            if now.timeIntervalSince(lastPublishedAt) >= 1 || index == assets.count - 1 {
                recordsByAssetID = nextRecordsByID
                metadataUpdateProcessedCount = updateSummary.processedCount
                lastUpdateSummary = updateSummary
                lastPublishedAt = now
                await Task.yield()
            }
        }

        recordsByAssetID = nextRecordsByID
        metadataUpdateProcessedCount = updateSummary.processedCount
        lastUpdateSummary = updateSummary
        lastMetadataUpdatedAt = Date()
        await saveAll()
        isUpdatingMetadata = false
    }

    func cancelMetadataUpdate() {
        shouldCancelMetadataUpdate = true
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let records = try await store.loadAll()
            recordsByAssetID = Dictionary(uniqueKeysWithValues: records.map { record in
                var normalized = record
                normalized.resolvedCategory = normalized.manualCategory ?? normalized.autoPrimaryCategory
                return (normalized.assetIdentifier, normalized)
            })
        } catch {
            errorMessage = "分類データを読み込めませんでした: \(error.localizedDescription)"
        }
    }

    private func saveAll() async {
        do {
            try await store.saveAll(Array(recordsByAssetID.values))
        } catch {
            errorMessage = "分類データを保存できませんでした: \(error.localizedDescription)"
        }
    }

    private func count(
        _ category: ImageClassificationCategory,
        in records: [PhotoClassification]
    ) -> Int {
        records.filter { $0.resolvedCategory == category }.count
    }

    private func virtualFolderRecords(for folder: OrganizationVirtualFolder) -> [PhotoClassification] {
        recordsByAssetID.values
            .filter { $0.isIncluded(in: folder) }
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.assetIdentifier > rhs.assetIdentifier
                }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    #if DEBUG
    @discardableResult
    func runManualPrioritySelfTest() -> PhotoClassificationSelfTestReport {
        var manualRecord = PhotoClassification(assetIdentifier: "debug-manual-priority")
        manualRecord.applyAutomaticCategory(.screenshot)
        manualRecord.applyManualCategory(.buildingCandidate)

        var automaticRecord = PhotoClassification(assetIdentifier: "debug-automatic-priority")
        automaticRecord.applyAutomaticCategory(.screenshot)

        var refreshRecord = manualRecord
        refreshRecord.applyMetadataOnly(
            asset: nil,
            indexRecord: nil,
            isScreenshot: true,
            updatedAt: Date()
        )

        let report = PhotoClassificationSelfTestReport(
            manualOverridesAutomatic: manualRecord.resolvedCategory == .buildingCandidate,
            automaticUsedWhenManualMissing: automaticRecord.resolvedCategory == .screenshot,
            metadataRefreshKeepsManual: refreshRecord.manualCategory == .buildingCandidate &&
                refreshRecord.resolvedCategory == .buildingCandidate
        )
        selfTestReport = report
        return report
    }

    @discardableResult
    func runMetadataOnlyOrganizationValidation(
        assets: [PhotoAsset],
        indexService: PhotoIndexService,
        libraryTotalAssets: Int,
        validationLimit: Int
    ) async -> MetadataOnlyOrganizationValidationReport {
        let manualReport = runManualPrioritySelfTest()
        await updateMetadataOnly(assets: assets, indexService: indexService)

        let summary = self.summary
        let normalizedLibraryTotalAssets = max(libraryTotalAssets, assets.count, summary.totalCount)
        var failureReasons: [String] = []
        if assets.isEmpty {
            failureReasons.append("totalAssets is 0")
        }
        if summary.totalCount == 0 {
            failureReasons.append("summaryTotalCount is 0")
        }
        if summary.classifiedCount < 0 ||
            summary.screenshotCount < 0 ||
            summary.readCandidateCount < 0 ||
            summary.needsReviewCount < 0 ||
            summary.unorganizedCount < 0 {
            failureReasons.append("summary contains negative count")
        }
        if summary.classifiedCount > summary.totalCount {
            failureReasons.append("classifiedCount exceeds summaryTotalCount")
        }
        if summary.screenshotCount > summary.totalCount {
            failureReasons.append("screenshotCount exceeds summaryTotalCount")
        }
        if summary.readCandidateCount > summary.totalCount {
            failureReasons.append("readCandidateCount exceeds summaryTotalCount")
        }
        if summary.needsReviewCount > summary.totalCount {
            failureReasons.append("needsReviewCount exceeds summaryTotalCount")
        }
        if summary.unorganizedCount > summary.totalCount {
            failureReasons.append("unorganizedCount exceeds summaryTotalCount")
        }
        if manualReport.passed == false {
            failureReasons.append("manualPrioritySelfTest failed")
        }

        let report = MetadataOnlyOrganizationValidationReport(
            generatedAt: Date(),
            totalAssets: assets.count,
            libraryTotalAssets: normalizedLibraryTotalAssets,
            validationLimit: validationLimit,
            processedAssets: lastUpdateSummary.processedCount,
            classificationStoreTotal: recordsByAssetID.count,
            summaryTotalAssets: normalizedLibraryTotalAssets,
            summaryClassifiedCount: summary.classifiedCount,
            summaryTotalCount: summary.totalCount,
            classifiedCount: summary.classifiedCount,
            screenshotCount: summary.screenshotCount,
            readCandidateCount: summary.readCandidateCount,
            needsReviewCount: summary.needsReviewCount,
            unorganizedCount: summary.unorganizedCount,
            updatedClassifications: lastUpdateSummary.processedCount,
            skippedManualClassifications: lastUpdateSummary.manualProtectedCount,
            usedVision: false,
            usedImageBody: false,
            usedThumbnailBody: false,
            usedPhotoKitWriteAPI: false,
            manualPrioritySelfTest: manualReport.passed ? "PASS" : "FAIL",
            result: failureReasons.isEmpty ? "PASS" : "FAIL",
            failureReasons: failureReasons
        )

        metadataValidationReport = report
        await saveMetadataValidationReport(report)
        print("METADATA_ORGANIZATION_VALIDATION \(report.result) libraryTotalAssets=\(report.libraryTotalAssets) validationLimit=\(report.validationLimit) processedAssets=\(report.processedAssets) classified=\(report.classifiedCount) screenshot=\(report.screenshotCount) readCandidate=\(report.readCandidateCount) unorganized=\(report.unorganizedCount)")
        return report
    }
    #endif

    private static let readCandidateTag = "readCandidate"

    #if DEBUG
    private func saveMetadataValidationReport(_ report: MetadataOnlyOrganizationValidationReport) async {
        let urls = metadataValidationReportURLs()
        var lastError: Error?

        for url in urls {
            do {
                let directoryURL = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

                let data = try encoder.encode(report)
                try data.write(to: url, options: [.atomic])
                print("METADATA_ORGANIZATION_VALIDATION_REPORT_SAVED path=\(url.path)")
                return
            } catch {
                lastError = error
            }
        }

        if let lastError {
            errorMessage = "軽量整理検証結果を保存できませんでした: \(lastError.localizedDescription)"
            print("METADATA_ORGANIZATION_VALIDATION_REPORT_SAVE_FAILED error=\(lastError.localizedDescription)")
        } else {
            errorMessage = "軽量整理検証結果を保存できませんでした。"
            print("METADATA_ORGANIZATION_VALIDATION_REPORT_SAVE_FAILED error=unknown")
        }
    }

    private func metadataValidationReportURLs() -> [URL] {
        let supportBaseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        let documentBaseURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        let cacheBaseURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return [
            supportBaseURL
                .appendingPathComponent("ShimaiBako", isDirectory: true)
                .appendingPathComponent("debug_metadata_organization_validation.json"),
            supportBaseURL
                .appendingPathComponent("ShimaiBakoData", isDirectory: true)
                .appendingPathComponent("debug_metadata_organization_validation.json"),
            documentBaseURL
                .appendingPathComponent("ShimaiBakoData", isDirectory: true)
                .appendingPathComponent("debug_metadata_organization_validation.json"),
            cacheBaseURL
                .appendingPathComponent("ShimaiBakoData", isDirectory: true)
                .appendingPathComponent("debug_metadata_organization_validation.json")
        ]
    }
    #endif
}

private extension PhotoClassification {
    func isIncluded(in folder: OrganizationVirtualFolder) -> Bool {
        switch folder {
        case .screenshots:
            isScreenshot || formatTags.contains("screenshot") || resolvedCategory == .screenshot
        case .readCandidates:
            contentTags.contains("readCandidate") || resolvedCategory == .readCandidate
        case .needsReview:
            analysisState == .needsReview || resolvedCategory == .needsReview
        case .unorganized:
            resolvedCategory == nil || resolvedCategory == .unorganized || analysisState == .notAnalyzed
        }
    }

    mutating func applyMetadataOnly(
        asset: PhotoAsset,
        indexRecord: PhotoIndexRecord?,
        updatedAt date: Date = Date()
    ) {
        applyMetadataOnly(
            asset: asset,
            indexRecord: indexRecord,
            isScreenshot: asset.isScreenshot,
            updatedAt: date
        )
    }

    mutating func applyMetadataOnly(
        asset _: PhotoAsset?,
        indexRecord: PhotoIndexRecord?,
        isScreenshot: Bool,
        updatedAt date: Date
    ) {
        self.classifierVersion = "p2-metadata-v1"
        self.analysisState = manualCategory == nil ? .metadataOnly : .manualClassified
        self.isScreenshot = isScreenshot
        self.containsPerson = false
        self.faceCount = 0
        self.screenshotScore = isScreenshot ? 1.0 : 0.0
        self.documentScore = 0.0
        self.ocrPriorityScore = isMetadataReadCandidate(indexRecord: indexRecord, isScreenshot: isScreenshot) ? 0.85 : 0.0
        self.confidenceBand = isScreenshot ? .high : .unknown
        self.scoreMargin = isScreenshot ? 1.0 : 0.0
        self.formatTags = updatedTags(formatTags, tag: "screenshot", enabled: isScreenshot)
        self.contentTags = updatedTags(contentTags, tag: "readCandidate", enabled: ocrPriorityScore > 0)

        let nextAutomaticCategory: ImageClassificationCategory? = isScreenshot ? .screenshot : nil
        self.autoPrimaryCategory = nextAutomaticCategory
        self.resolvedCategory = manualCategory ?? autoPrimaryCategory
        self.updatedAt = date
    }

    private func isMetadataReadCandidate(indexRecord: PhotoIndexRecord?, isScreenshot: Bool) -> Bool {
        guard isScreenshot else {
            return false
        }

        guard let indexRecord else {
            return true
        }

        return indexRecord.ocrStatus == .unprocessed
    }

    private func updatedTags(_ tags: [String], tag: String, enabled: Bool) -> [String] {
        var nextTags = Set(tags)
        if enabled {
            nextTags.insert(tag)
        } else {
            nextTags.remove(tag)
        }

        return Array(nextTags).sorted()
    }
}
