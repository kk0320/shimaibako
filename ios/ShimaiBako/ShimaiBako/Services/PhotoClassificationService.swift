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
    @Published private(set) var metadataOrganizationRunTrigger: MetadataOrganizationRunTrigger?
    @Published private(set) var lastMetadataOrganizationRunResult: MetadataOrganizationRunResult = .empty
    @Published var errorMessage: String?
    #if DEBUG
    @Published private(set) var selfTestReport: PhotoClassificationSelfTestReport?
    @Published private(set) var metadataValidationReport: MetadataOnlyOrganizationValidationReport?
    #endif

    private let store: PhotoClassificationStoring
    private let userDefaults: UserDefaults
    private var shouldCancelMetadataUpdate = false
    private let automaticRunSignatureKey = "shimaibako.metadataOrganization.lastAutomaticRunSignature"
    private let automaticRunResultKey = "shimaibako.metadataOrganization.lastAutomaticRunResult"
    private let automaticRunAtKey = "shimaibako.metadataOrganization.lastAutomaticRunAt"
    private let metadataClassifierVersion = "p2-metadata-v1"

    init(store: PhotoClassificationStoring? = nil, userDefaults: UserDefaults = .standard) {
        self.store = store ?? JSONPhotoClassificationStore()
        self.userDefaults = userDefaults

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

    func liveReadCandidateCount(indexService: PhotoIndexService) async -> Int {
        let records = await liveReadCandidateRecords(indexService: indexService)
        return records.count
    }

    func liveReadCandidateIdentifierPage(
        indexService: PhotoIndexService,
        limit: Int,
        offset: Int
    ) async -> [String] {
        let records = await liveReadCandidateRecords(indexService: indexService)
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
        indexService: PhotoIndexService,
        trigger: MetadataOrganizationRunTrigger = .manual,
        libraryTotalAssets: Int? = nil,
        metadataSource: String = "photoLibraryAssets"
    ) async {
        guard isUpdatingMetadata == false else {
            return
        }

        guard assets.isEmpty == false else {
            lastUpdateSummary = .empty
            errorMessage = "写真情報の準備中です。少し待ってからもう一度お試しください。"
            return
        }

        isUpdatingMetadata = true
        metadataOrganizationRunTrigger = trigger
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
        finishMetadataOrganizationRun(
            trigger: trigger,
            metadataSource: metadataSource,
            libraryTotalAssets: max(libraryTotalAssets ?? assets.count, assets.count),
            sourceTotalAssets: assets.count,
            processedAssets: updateSummary.processedCount,
            result: shouldCancelMetadataUpdate ? "cancelled" : "completed"
        )
        isUpdatingMetadata = false
    }

    func updateMetadataOnly(
        indexRecords: [PhotoIndexRecord],
        trigger: MetadataOrganizationRunTrigger = .manual,
        libraryTotalAssets: Int? = nil,
        metadataSource: String = "sqlitePhotoIndex"
    ) async {
        guard isUpdatingMetadata == false else {
            return
        }

        guard indexRecords.isEmpty == false else {
            lastUpdateSummary = .empty
            errorMessage = "写真情報の準備中です。少し待ってからもう一度お試しください。"
            return
        }

        isUpdatingMetadata = true
        metadataOrganizationRunTrigger = trigger
        shouldCancelMetadataUpdate = false
        metadataUpdateProcessedCount = 0
        metadataUpdateTotalCount = indexRecords.count
        errorMessage = nil

        var nextRecordsByID = recordsByAssetID
        var updateSummary = PhotoClassificationUpdateSummary(
            processedCount: 0,
            totalCount: indexRecords.count,
            screenshotCount: 0,
            readCandidateCount: 0,
            needsReviewCount: 0,
            unorganizedCount: 0,
            manualProtectedCount: 0
        )
        var lastPublishedAt = Date.distantPast

        for (index, indexRecord) in indexRecords.enumerated() {
            if shouldCancelMetadataUpdate {
                break
            }

            var record = nextRecordsByID[indexRecord.localIdentifier] ?? PhotoClassification(assetIdentifier: indexRecord.localIdentifier)
            record.applyMetadataOnly(
                asset: nil,
                indexRecord: indexRecord,
                isScreenshot: indexRecord.isScreenshot,
                updatedAt: Date()
            )
            nextRecordsByID[indexRecord.localIdentifier] = record

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
            if now.timeIntervalSince(lastPublishedAt) >= 1 || index == indexRecords.count - 1 {
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
        finishMetadataOrganizationRun(
            trigger: trigger,
            metadataSource: metadataSource,
            libraryTotalAssets: max(libraryTotalAssets ?? indexRecords.count, indexRecords.count),
            sourceTotalAssets: indexRecords.count,
            processedAssets: updateSummary.processedCount,
            result: shouldCancelMetadataUpdate ? "cancelled" : "completed"
        )
        isUpdatingMetadata = false
    }

    @discardableResult
    func updateMetadataOnlyFromPhotoIndexPages(
        indexService: PhotoIndexService,
        libraryTotalAssets: Int,
        trigger: MetadataOrganizationRunTrigger,
        pageSize: Int = 500,
        limit: Int? = nil
    ) async -> MetadataOrganizationRunResult {
        guard isUpdatingMetadata == false else {
            return lastMetadataOrganizationRunResult
        }

        let normalizedPageSize = max(pageSize, 1)
        let firstPage = await indexService.organizationMetadataSource(limit: normalizedPageSize, offset: 0)
        let sourceTotalAssets = firstPage.totalCount
        let targetTotal = min(limit ?? sourceTotalAssets, sourceTotalAssets)

        guard sourceTotalAssets > 0, firstPage.records.isEmpty == false, targetTotal > 0 else {
            lastUpdateSummary = .empty
            errorMessage = "写真情報の準備中です。少し待ってからもう一度お試しください。"
            let result = MetadataOrganizationRunResult(
                trigger: trigger,
                metadataSource: firstPage.metadataSource,
                libraryTotalAssets: max(libraryTotalAssets, sourceTotalAssets),
                sourceTotalAssets: sourceTotalAssets,
                processedAssets: 0,
                result: "skipped",
                message: firstPage.sourceUnavailableReason ?? "metadataSourceUnavailable",
                finishedAt: Date()
            )
            lastMetadataOrganizationRunResult = result
            return result
        }

        isUpdatingMetadata = true
        metadataOrganizationRunTrigger = trigger
        shouldCancelMetadataUpdate = false
        metadataUpdateProcessedCount = 0
        metadataUpdateTotalCount = targetTotal
        errorMessage = nil

        var nextRecordsByID = recordsByAssetID
        var updateSummary = PhotoClassificationUpdateSummary(
            processedCount: 0,
            totalCount: targetTotal,
            screenshotCount: 0,
            readCandidateCount: 0,
            needsReviewCount: 0,
            unorganizedCount: 0,
            manualProtectedCount: 0
        )
        var lastPublishedAt = Date.distantPast
        var offset = 0
        var currentPage = firstPage.records

        while updateSummary.processedCount < targetTotal, currentPage.isEmpty == false {
            for indexRecord in currentPage {
                if shouldCancelMetadataUpdate || updateSummary.processedCount >= targetTotal {
                    break
                }

                var record = nextRecordsByID[indexRecord.localIdentifier] ?? PhotoClassification(assetIdentifier: indexRecord.localIdentifier)
                record.applyMetadataOnly(
                    asset: nil,
                    indexRecord: indexRecord,
                    isScreenshot: indexRecord.isScreenshot,
                    updatedAt: Date()
                )
                nextRecordsByID[indexRecord.localIdentifier] = record
                updateSummary.processedCount += 1
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
                if now.timeIntervalSince(lastPublishedAt) >= 1 || updateSummary.processedCount == targetTotal {
                    recordsByAssetID = nextRecordsByID
                    metadataUpdateProcessedCount = updateSummary.processedCount
                    lastUpdateSummary = updateSummary
                    lastPublishedAt = now
                    await Task.yield()
                }
            }

            offset += currentPage.count
            guard shouldCancelMetadataUpdate == false, updateSummary.processedCount < targetTotal else {
                break
            }

            currentPage = await indexService.organizationMetadataSource(
                limit: normalizedPageSize,
                offset: offset
            ).records
        }

        recordsByAssetID = nextRecordsByID
        metadataUpdateProcessedCount = updateSummary.processedCount
        lastUpdateSummary = updateSummary
        lastMetadataUpdatedAt = Date()
        await saveAll()

        let resultText = shouldCancelMetadataUpdate ? "cancelled" : "completed"
        finishMetadataOrganizationRun(
            trigger: trigger,
            metadataSource: firstPage.metadataSource,
            libraryTotalAssets: max(libraryTotalAssets, sourceTotalAssets),
            sourceTotalAssets: sourceTotalAssets,
            processedAssets: updateSummary.processedCount,
            result: resultText
        )
        isUpdatingMetadata = false
        return lastMetadataOrganizationRunResult
    }

    func cancelMetadataUpdate() {
        shouldCancelMetadataUpdate = true
    }

    func shouldRunAutomaticMetadataOrganization(
        libraryTotalAssets: Int,
        sourceTotalAssets: Int
    ) -> Bool {
        guard isUpdatingMetadata == false, isLoading == false else {
            return false
        }

        let normalizedLibraryTotal = max(libraryTotalAssets, sourceTotalAssets)
        guard normalizedLibraryTotal > 0, sourceTotalAssets > 0 else {
            return false
        }

        let signature = automaticRunSignature(
            libraryTotalAssets: normalizedLibraryTotal,
            sourceTotalAssets: sourceTotalAssets
        )
        if userDefaults.string(forKey: automaticRunSignatureKey) == signature {
            return false
        }

        if recordsByAssetID.isEmpty {
            return true
        }

        if summary.totalCount < min(normalizedLibraryTotal, sourceTotalAssets) {
            return true
        }

        return userDefaults.string(forKey: automaticRunResultKey) != "completed"
    }

    func markAutomaticMetadataOrganizationCompletedIfNeeded(
        libraryTotalAssets: Int,
        sourceTotalAssets: Int,
        result: String
    ) {
        let normalizedLibraryTotal = max(libraryTotalAssets, sourceTotalAssets)
        guard normalizedLibraryTotal > 0, sourceTotalAssets > 0 else {
            return
        }

        userDefaults.set(
            automaticRunSignature(libraryTotalAssets: normalizedLibraryTotal, sourceTotalAssets: sourceTotalAssets),
            forKey: automaticRunSignatureKey
        )
        userDefaults.set(result, forKey: automaticRunResultKey)
        userDefaults.set(Date().timeIntervalSince1970, forKey: automaticRunAtKey)
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

    private func finishMetadataOrganizationRun(
        trigger: MetadataOrganizationRunTrigger,
        metadataSource: String,
        libraryTotalAssets: Int,
        sourceTotalAssets: Int,
        processedAssets: Int,
        result: String
    ) {
        let message: String
        switch result {
        case "completed":
            message = "軽量整理が完了しました"
        case "cancelled":
            message = "軽量整理を中止しました"
        default:
            message = "軽量整理を実行できませんでした"
        }

        lastMetadataOrganizationRunResult = MetadataOrganizationRunResult(
            trigger: trigger,
            metadataSource: metadataSource,
            libraryTotalAssets: libraryTotalAssets,
            sourceTotalAssets: sourceTotalAssets,
            processedAssets: processedAssets,
            result: result,
            message: message,
            finishedAt: Date()
        )
        metadataOrganizationRunTrigger = nil

        if trigger == .automatic {
            markAutomaticMetadataOrganizationCompletedIfNeeded(
                libraryTotalAssets: libraryTotalAssets,
                sourceTotalAssets: sourceTotalAssets,
                result: result
            )
        }
    }

    private func automaticRunSignature(libraryTotalAssets: Int, sourceTotalAssets: Int) -> String {
        "\(metadataClassifierVersion)|library:\(libraryTotalAssets)|source:\(sourceTotalAssets)"
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

    private func liveReadCandidateRecords(indexService: PhotoIndexService) async -> [PhotoClassification] {
        let records = virtualFolderRecords(for: .readCandidates)
        let indexRecords = await indexService.recordsByLocalIdentifier(localIdentifiers: records.map(\.assetIdentifier))
        return records.filter { record in
            guard record.isIncluded(in: .readCandidates) else {
                return false
            }

            guard let indexRecord = indexRecords[record.assetIdentifier] else {
                return true
            }

            return indexRecord.isActionableReadCandidate
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
        indexRecords: [PhotoIndexRecord],
        indexService: PhotoIndexService,
        libraryTotalAssets: Int,
        validationLimit: Int,
        metadataSource: String,
        metadataSourceFallbacksTried: [String],
        photoLibraryAssetsCount: Int,
        photoIndexTotalCount: Int,
        sqliteTotalCount: Int,
        sourceUnavailableReason: String?,
        autoRunEligible: Bool = false,
        autoRunTriggered: Bool = false,
        manualRunTriggered: Bool = true
    ) async -> MetadataOnlyOrganizationValidationReport {
        let manualReport = runManualPrioritySelfTest()
        if indexRecords.isEmpty == false {
            await updateMetadataOnly(
                indexRecords: indexRecords,
                trigger: autoRunTriggered ? .automatic : .validation,
                libraryTotalAssets: libraryTotalAssets,
                metadataSource: metadataSource
            )
        } else {
            await updateMetadataOnly(
                assets: assets,
                indexService: indexService,
                trigger: autoRunTriggered ? .automatic : .validation,
                libraryTotalAssets: libraryTotalAssets,
                metadataSource: metadataSource
            )
        }

        let summary = self.summary
        let processedSourceCount = indexRecords.isEmpty ? assets.count : indexRecords.count
        let normalizedLibraryTotalAssets = max(
            libraryTotalAssets,
            photoIndexTotalCount,
            sqliteTotalCount,
            assets.count,
            summary.totalCount
        )
        var failureReasons: [String] = []
        if processedSourceCount == 0 {
            failureReasons.append(sourceUnavailableReason ?? "metadataSourceUnavailable")
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
            autoRunEligible: autoRunEligible,
            autoRunTriggered: autoRunTriggered,
            manualRunTriggered: manualRunTriggered,
            metadataOrganizationInProgress: isUpdatingMetadata,
            totalAssets: processedSourceCount,
            libraryTotalAssets: normalizedLibraryTotalAssets,
            validationLimit: validationLimit,
            processedAssets: lastUpdateSummary.processedCount,
            metadataSource: metadataSource,
            metadataSourceFallbacksTried: metadataSourceFallbacksTried,
            photoLibraryAssetsCount: photoLibraryAssetsCount,
            photoIndexTotalCount: photoIndexTotalCount,
            sqliteTotalCount: sqliteTotalCount,
            sourceUnavailableReason: sourceUnavailableReason,
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
        print("METADATA_ORGANIZATION_VALIDATION \(report.result) metadataSource=\(report.metadataSource) libraryTotalAssets=\(report.libraryTotalAssets) validationLimit=\(report.validationLimit) processedAssets=\(report.processedAssets) classified=\(report.classifiedCount) screenshot=\(report.screenshotCount) readCandidate=\(report.readCandidateCount) unorganized=\(report.unorganizedCount)")
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

private extension PhotoIndexRecord {
    var isActionableReadCandidate: Bool {
        switch ocrStatus {
        case .unprocessed, .failed:
            true
        case .processing, .completed:
            false
        }
    }
}
