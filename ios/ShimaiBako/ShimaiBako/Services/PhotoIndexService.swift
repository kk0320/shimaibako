import Combine
import Foundation
import Photos

nonisolated struct OrganizationMetadataSourceSnapshot: Equatable, Sendable {
    var records: [PhotoIndexRecord]
    var totalCount: Int
    var metadataSource: String
    var sqliteTotalCount: Int
    var photoIndexTotalCount: Int
    var sourceUnavailableReason: String?
}

@MainActor
final class PhotoIndexService: ObservableObject {
    @Published private(set) var recordsByAssetID: [String: PhotoIndexRecord] = [:]
    @Published private(set) var indexSummary: PhotoIndexSummary = .empty
    @Published private(set) var filterCountsSnapshot: FilterCountsSnapshot = .empty
    @Published var errorMessage: String?

    private let store: any PhotoIndexStoring
    private let learningService: ManualCategoryLearningService
    private let progressStore: IndexProgressStore
    private(set) var displayStateCountCache: [PhotoDisplayState: Int] = .emptyDisplayStateCounts
    private(set) var categoryCountCache: [PhotoCategory: Int] = .emptyCategoryCounts
    private(set) var screenshotSubcategoryCountCache: [ScreenshotSubcategory: Int] = .emptyScreenshotSubcategoryCounts
    private(set) var categoryCountCacheByDisplayState: [PhotoDisplayState: [PhotoCategory: Int]] = [:]
    private(set) var screenshotSubcategoryCountCacheByDisplayState: [PhotoDisplayState: [ScreenshotSubcategory: Int]] = [:]
    private(set) var indexStoreStatusText: String?
    private(set) var isIndexStorePreparing = false
    private var migrationObserver: NSObjectProtocol?
    private var filterCountsRevision = 0
    private var recordCacheOrder: [String] = []
    private let maximumCachedRecords = 1_500

    init(
        store: any PhotoIndexStoring = SQLitePhotoIndexStore(),
        learningService: ManualCategoryLearningService,
        progressStore: IndexProgressStore? = nil
    ) {
        self.store = store
        self.learningService = learningService
        self.progressStore = progressStore ?? .shared
        migrationObserver = NotificationCenter.default.addObserver(
            forName: SQLitePhotoIndexStore.migrationProgressNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let completed = notification.userInfo?["completed"] as? Int ?? 0
            let total = notification.userInfo?["total"] as? Int ?? 0
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                self.isIndexStorePreparing = true
                self.indexStoreStatusText = "旧インデックスをSQLiteへ移行中 \(completed) / \(total)件"
                self.progressStore.update(statusText: self.indexStoreStatusText)
            }
        }

        Task {
            await loadPersistedRecords()
        }
    }

    deinit {
        if let migrationObserver {
            NotificationCenter.default.removeObserver(migrationObserver)
        }
    }

    var indexedRecordCount: Int {
        indexSummary.indexedCount
    }

    var completedOCRCount: Int {
        indexSummary.completedOCRCount
    }

    var unprocessedOCRCount: Int {
        indexSummary.unprocessedOCRCount
    }

    var categorizedCount: Int {
        indexSummary.categorizedCount
    }

    func record(for asset: PhotoAsset, ocrService: OCRService) -> PhotoIndexRecord {
        if let record = recordsByAssetID[asset.id] {
            return record
        }

        return makeRecord(for: asset, ocrService: ocrService)
    }

    func recordsByLocalIdentifier(localIdentifiers: [String]) async -> [String: PhotoIndexRecord] {
        guard localIdentifiers.isEmpty == false else {
            return [:]
        }

        var nextRecords: [String: PhotoIndexRecord] = [:]
        let chunkSize = 500

        for startIndex in stride(from: 0, to: localIdentifiers.count, by: chunkSize) {
            let endIndex = min(startIndex + chunkSize, localIdentifiers.count)
            let chunk = Array(localIdentifiers[startIndex..<endIndex])

            do {
                let records = try await store.records(localIdentifiers: chunk)
                updateRecordCache(with: records)
                for record in records {
                    nextRecords[record.localIdentifier] = record
                }
            } catch {
                errorMessage = "表示用インデックスを読み込めませんでした: \(error.localizedDescription)"
            }

            await Task.yield()
        }

        return nextRecords
    }

    func category(for asset: PhotoAsset, ocrService: OCRService) -> PhotoCategory {
        record(for: asset, ocrService: ocrService).inferredCategory
    }

    func confidenceLabel(for asset: PhotoAsset, ocrService: OCRService) -> String {
        let confidence = record(for: asset, ocrService: ocrService).categoryConfidence
        return "\(Int((confidence * 100).rounded()))%"
    }

    func categoryReason(for asset: PhotoAsset, ocrService: OCRService) -> String {
        record(for: asset, ocrService: ocrService).categoryReason ?? "メタデータとOCR結果から候補分類しています"
    }

    func screenshotSubcategory(for asset: PhotoAsset, ocrService: OCRService) -> ScreenshotSubcategory? {
        record(for: asset, ocrService: ocrService).screenshotSubcategory
    }

    func screenshotSubcategoryConfidenceLabel(for asset: PhotoAsset, ocrService: OCRService) -> String? {
        guard let confidence = record(for: asset, ocrService: ocrService).screenshotSubcategoryConfidence else {
            return nil
        }

        return "\(Int((confidence * 100).rounded()))%"
    }

    func screenshotSubcategoryReason(for asset: PhotoAsset, ocrService: OCRService) -> String? {
        record(for: asset, ocrService: ocrService).screenshotSubcategoryReason
    }

    func ocrText(for asset: PhotoAsset, ocrService: OCRService) -> String {
        let record = record(for: asset, ocrService: ocrService)
        guard record.ocrStatus == .completed else {
            return ""
        }

        return record.ocrText
    }

    func status(for asset: PhotoAsset, ocrService: OCRService) -> OCRStatus {
        if ocrService.isProcessing(asset) {
            return .processing
        }

        return record(for: asset, ocrService: ocrService).ocrStatus
    }

    func hasManualClassification(for asset: PhotoAsset) -> Bool {
        guard let record = recordsByAssetID[asset.id] else {
            return false
        }

        return record.manualCategory != nil || record.manualScreenshotSubcategory != nil
    }

    func displayState(for asset: PhotoAsset, ocrService: OCRService) -> PhotoDisplayState {
        record(for: asset, ocrService: ocrService).displayState
    }

    func displayStateCounts(for assets: [PhotoAsset], ocrService: OCRService) -> [PhotoDisplayState: Int] {
        if displayStateCountCache.values.reduce(0, +) > 0 {
            return displayStateCountCache
        }

        var counts = Dictionary(uniqueKeysWithValues: PhotoDisplayState.allCases.map { ($0, 0) })

        for asset in assets {
            let state = displayState(for: asset, ocrService: ocrService)
            counts[state, default: 0] += 1
        }

        return counts
    }

    func cachedCategoryCounts(displayState: PhotoDisplayState? = nil) -> [PhotoCategory: Int] {
        guard let displayState else {
            return categoryCountCache
        }

        return categoryCountCacheByDisplayState[displayState] ?? .emptyCategoryCounts
    }

    func cachedScreenshotSubcategoryCounts(displayState: PhotoDisplayState? = nil) -> [ScreenshotSubcategory: Int] {
        guard let displayState else {
            return screenshotSubcategoryCountCache
        }

        return screenshotSubcategoryCountCacheByDisplayState[displayState] ?? .emptyScreenshotSubcategoryCounts
    }

    func filterCountsSnapshot(for scope: PhotoDisplayState) -> FilterCountsSnapshot {
        if filterCountsSnapshot.categoryScope == scope {
            return filterCountsSnapshot
        }

        return .preparing(revision: filterCountsSnapshot.revision, categoryScope: scope)
    }

    func refreshFilterCountsSnapshot(scope: PhotoDisplayState) async {
        filterCountsRevision += 1
        let revision = filterCountsRevision
        filterCountsSnapshot = .preparing(revision: revision, categoryScope: scope)

        do {
            let snapshot = try await PerformanceTelemetry.measure(.fetchFilterCounts, "scope=\(scope.rawValue)") {
                let displayCounts = try await store.displayStateCounts()
                let categoryCounts = try await store.categoryCounts(displayState: scope)
                let screenshotCounts = try await store.screenshotSubcategoryCounts(displayState: scope)
                return FilterCountsSnapshot(
                    revision: revision,
                    categoryScope: scope,
                    displayStateCounts: displayCounts,
                    categoryCounts: categoryCounts,
                    screenshotSubcategoryCounts: screenshotCounts,
                    isPreparing: false
                )
            }

            guard revision == filterCountsRevision else {
                return
            }

            displayStateCountCache = snapshot.displayStateCounts ?? .emptyDisplayStateCounts
            categoryCountsByReplacing(scope: scope, categoryCounts: snapshot.categoryCounts, screenshotCounts: snapshot.screenshotSubcategoryCounts)
            filterCountsSnapshot = snapshot
        } catch {
            guard revision == filterCountsRevision else {
                return
            }

            errorMessage = "件数を読み込めませんでした: \(error.localizedDescription)"
            filterCountsSnapshot = .preparing(revision: revision, categoryScope: scope)
        }
    }

    func page(matching request: PhotoIndexPageRequest) async -> PhotoIndexPage {
        do {
            let page = try await PerformanceTelemetry.measure(.fetchPhotoPage, "limit=\(request.normalizedLimit) offset=\(request.normalizedOffset)") {
                try await store.localIdentifierPage(matching: request)
            }
            await cacheRecords(localIdentifiers: page.localIdentifiers)
            return page
        } catch {
            errorMessage = "写真一覧を読み込めませんでした: \(error.localizedDescription)"
            return PhotoIndexPage(localIdentifiers: [], totalCount: 0)
        }
    }

    func batchOCRCandidateRecords(limit: Int) async -> [PhotoIndexRecord] {
        do {
            return try await store.batchOCRCandidateRecords(limit: limit)
        } catch {
            errorMessage = "読取対象候補を読み込めませんでした: \(error.localizedDescription)"
            return []
        }
    }

    func batchOCRCandidateCount() async -> Int {
        do {
            return try await store.batchOCRCandidateCount()
        } catch {
            errorMessage = "読取対象候補数を読み込めませんでした: \(error.localizedDescription)"
            return 0
        }
    }

    func organizationMetadataSource(limit: Int, offset: Int = 0) async -> OrganizationMetadataSourceSnapshot {
        do {
            let summary = try await store.summary()
            let records = try await store.loadPage(limit: max(limit, 1), offset: max(offset, 0))
            updateRecordCache(with: records)
            let totalCount = summary.indexedCount
            return OrganizationMetadataSourceSnapshot(
                records: records,
                totalCount: totalCount,
                metadataSource: "sqlitePhotoIndex",
                sqliteTotalCount: totalCount,
                photoIndexTotalCount: totalCount,
                sourceUnavailableReason: totalCount == 0 ? "photoIndexNotReady" : nil
            )
        } catch {
            errorMessage = "整理用メタデータを読み込めませんでした: \(error.localizedDescription)"
            return OrganizationMetadataSourceSnapshot(
                records: [],
                totalCount: indexSummary.indexedCount,
                metadataSource: "unavailable",
                sqliteTotalCount: 0,
                photoIndexTotalCount: indexSummary.indexedCount,
                sourceUnavailableReason: "metadataSourceUnavailable"
            )
        }
    }

    func setDisplayState(
        _ state: PhotoDisplayState,
        for asset: PhotoAsset,
        ocrService: OCRService
    ) async {
        var record = makeRecord(for: asset, ocrService: ocrService)
        let now = Date()
        record.displayState = state
        record.displayStateUpdatedAt = now
        record.updatedAt = now
        recordsByAssetID[asset.id] = record
        refreshSummary()
        await persistRecords([record])
    }

    func setMemoAndTags(
        for asset: PhotoAsset,
        memo: String,
        tags: [String],
        ocrService: OCRService
    ) async {
        var record = makeRecord(for: asset, ocrService: ocrService)
        let cleanedTags = cleanedUserTags(tags)
        let cleanedMemo = memo.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()

        record.userMemo = cleanedMemo
        record.userTags = cleanedTags
        record.updatedAt = now
        recordsByAssetID[asset.id] = record
        refreshSummary()
        await persistRecords([record])
    }

    func matches(asset: PhotoAsset, query: String, ocrService: OCRService) -> Bool {
        searchMatch(asset: asset, query: query, ocrService: ocrService).isMatch
    }

    func searchMatch(asset: PhotoAsset, query: String, ocrService: OCRService) -> PhotoSearchMatch {
        let tokens = normalizedSearchTokens(in: query)
        guard tokens.isEmpty == false else {
            return .empty
        }

        let record = record(for: asset, ocrService: ocrService)
        let fieldTexts: [(PhotoSearchMatchedField, String)] = [
            (.ocrText, record.ocrStatus == .completed ? record.ocrText : ""),
            (.category, [
                record.inferredCategory.title,
                record.inferredCategory.shortTitle,
                record.categoryReason ?? ""
            ].joined(separator: " ")),
            (.screenshotSubcategory, [
                record.screenshotSubcategory?.title ?? "",
                record.screenshotSubcategory?.shortTitle ?? "",
                record.screenshotSubcategoryReason ?? ""
            ].joined(separator: " ")),
            (.manualCategory, [
                record.manualCategory?.title ?? "",
                record.manualCategory?.shortTitle ?? "",
                record.manualScreenshotSubcategory?.title ?? "",
                record.manualCategory == nil && record.manualScreenshotSubcategory == nil ? "" : "手動分類"
            ].joined(separator: " ")),
            (.memo, record.userMemo),
            (.tags, record.userTags.joined(separator: " ")),
            (.date, [
                asset.dateLabel,
                record.creationDate.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? ""
            ].joined(separator: " ")),
            (.metadata, [
                asset.filename ?? "",
                asset.kindLabel,
                asset.sizeLabel,
                asset.localIdentifier,
                asset.isFavorite ? "お気に入り" : "",
                record.displayState.title
            ].joined(separator: " "))
        ]

        let normalizedFields = fieldTexts.map { field, text in
            (field, text, normalizedSearchText(text))
        }

        var matchedFields: Set<PhotoSearchMatchedField> = []
        for token in tokens {
            let fieldsForToken = normalizedFields.filter { _, _, normalizedText in
                normalizedText.contains(token)
            }

            guard fieldsForToken.isEmpty == false else {
                return PhotoSearchMatch(isMatch: false, matchedFields: [], ocrSnippet: nil)
            }

            for fieldMatch in fieldsForToken {
                matchedFields.insert(fieldMatch.0)
            }
        }

        let orderedFields = PhotoSearchMatchedField.allCases.filter { matchedFields.contains($0) }
        let snippet = matchedFields.contains(.ocrText) ? shortOCRSnippet(from: record.ocrText) : nil
        return PhotoSearchMatch(isMatch: true, matchedFields: orderedFields, ocrSnippet: snippet)
    }

    func summary(for assets: [PhotoAsset], ocrService: OCRService) -> PhotoIndexSummary {
        let imageAssets = assets.filter { $0.mediaType == .image }
        let records = imageAssets.map { record(for: $0, ocrService: ocrService) }
        return PhotoIndexSummary(records: records, loadedImageCount: imageAssets.count)
    }

    func counts(for assets: [PhotoAsset], ocrService: OCRService) -> [PhotoCategory: Int] {
        var counts = Dictionary(uniqueKeysWithValues: PhotoCategory.allCases.map { ($0, 0) })
        counts[.all] = assets.count

        for asset in assets {
            let category = category(for: asset, ocrService: ocrService)
            counts[category, default: 0] += 1
        }

        return counts
    }

    func screenshotSubcategoryCounts(for assets: [PhotoAsset], ocrService: OCRService) -> [ScreenshotSubcategory: Int] {
        var counts = Dictionary(uniqueKeysWithValues: ScreenshotSubcategory.allCases.map { ($0, 0) })
        let screenshotAssets = assets.filter(\.isScreenshot)
        counts[.all] = screenshotAssets.count

        for asset in screenshotAssets {
            let subcategory = screenshotSubcategory(for: asset, ocrService: ocrService) ?? .otherScreenshot
            counts[subcategory, default: 0] += 1
        }

        return counts
    }

    func rebuild(for assets: [PhotoAsset], ocrService: OCRService) async {
        guard assets.isEmpty == false else {
            return
        }

        await cacheRecords(localIdentifiers: assets.map(\.localIdentifier))
        var changedRecords: [PhotoIndexRecord] = []
        changedRecords.reserveCapacity(assets.count)

        for (index, asset) in assets.enumerated() {
            let record = makeRecord(for: asset, ocrService: ocrService)
            recordsByAssetID[asset.id] = record
            recordCacheOrder.removeAll { $0 == asset.id }
            recordCacheOrder.append(asset.id)
            changedRecords.append(record)

            if index.isMultiple(of: 500) {
                await Task.yield()
            }
        }

        trimRecordCacheIfNeeded()
        await persistRecords(changedRecords, refreshStats: assets.count < 50)
    }

    func update(asset: PhotoAsset, ocrService: OCRService) async {
        let record = makeRecord(for: asset, ocrService: ocrService)
        recordsByAssetID[asset.id] = record
        refreshSummary()
        await persistRecords([record])
    }

    func setManualCategory(for asset: PhotoAsset, category: PhotoCategory, ocrService: OCRService) async {
        guard category != .all else {
            return
        }

        let ocrText = ocrText(for: asset, ocrService: ocrService)
        let automaticCategory = CategoryInference.infer(asset: asset, ocrText: ocrText).category
        var record = makeRecord(for: asset, ocrService: ocrService, preservingManual: false, usingLearning: false)
        let now = Date()

        record.inferredCategory = category
        record.categoryConfidence = 1.0
        record.categoryReason = "手動分類"
        record.categoryUpdatedAt = now
        record.manualCategory = category
        record.manualCategoryUpdatedAt = now

        if category != .screenshots {
            record.manualScreenshotSubcategory = nil
            record.screenshotSubcategory = nil
            record.screenshotSubcategoryConfidence = nil
            record.screenshotSubcategoryReason = nil
            record.screenshotSubcategoryUpdatedAt = nil
        }

        record.updatedAt = now
        recordsByAssetID[asset.id] = record
        refreshSummary()
        await persistRecords([record])

        await learningService.recordManualCorrection(
            asset: asset,
            ocrText: ocrText,
            correctedCategory: category,
            correctedScreenshotSubcategory: record.manualScreenshotSubcategory,
            originalAutoCategory: automaticCategory
        )
    }

    func setManualScreenshotSubcategory(
        for asset: PhotoAsset,
        subcategory: ScreenshotSubcategory,
        ocrService: OCRService
    ) async {
        guard asset.isScreenshot, subcategory != .all else {
            return
        }

        let ocrText = ocrText(for: asset, ocrService: ocrService)
        let automaticCategory = CategoryInference.infer(asset: asset, ocrText: ocrText).category
        var record = makeRecord(for: asset, ocrService: ocrService, preservingManual: true, usingLearning: false)
        let now = Date()

        record.inferredCategory = .screenshots
        record.categoryConfidence = 1.0
        record.categoryReason = "手動分類"
        record.categoryUpdatedAt = now
        record.manualCategory = .screenshots
        record.manualScreenshotSubcategory = subcategory
        record.manualCategoryUpdatedAt = now
        record.screenshotSubcategory = subcategory
        record.screenshotSubcategoryConfidence = 1.0
        record.screenshotSubcategoryReason = "手動分類"
        record.screenshotSubcategoryUpdatedAt = now
        record.updatedAt = now

        recordsByAssetID[asset.id] = record
        refreshSummary()
        await persistRecords([record])

        await learningService.recordManualCorrection(
            asset: asset,
            ocrText: ocrText,
            correctedCategory: .screenshots,
            correctedScreenshotSubcategory: subcategory,
            originalAutoCategory: automaticCategory
        )
    }

    func restoreAutomaticCategory(for asset: PhotoAsset, ocrService: OCRService) async {
        await learningService.removeExample(localIdentifier: asset.localIdentifier)

        let record = makeRecord(for: asset, ocrService: ocrService, preservingManual: false, usingLearning: false)
        recordsByAssetID[asset.id] = record
        refreshSummary()
        await persistRecords([record])
    }

    func rebuildSearchIndex(for assets: [PhotoAsset], ocrService: OCRService) async {
        await rebuild(for: assets, ocrService: ocrService)
    }

    func repairReadState(for assets: [PhotoAsset], ocrService: OCRService) async -> ReadStateRepairSummary {
        let imageAssets = assets.filter { $0.mediaType == .image }
        guard imageAssets.isEmpty == false else {
            return ReadStateRepairSummary(
                scannedCount: 0,
                repairedStaleCompletedCount: 0,
                repairedStaleProcessingCount: 0,
                preservedOCRResultCount: 0,
                preservedManualDataCount: 0,
                updatedIndexRecordCount: 0
            )
        }

        let recordsByIdentifier = await recordsByLocalIdentifier(localIdentifiers: imageAssets.map(\.localIdentifier))
        var changedRecords: [PhotoIndexRecord] = []
        var repairedStaleCompletedCount = 0
        var repairedStaleProcessingCount = 0
        var preservedOCRResultCount = 0
        var preservedManualDataCount = 0

        for (index, asset) in imageAssets.enumerated() {
            let existingRecord = recordsByIdentifier[asset.localIdentifier] ?? recordsByAssetID[asset.id]
            let ocrResult = ocrService.result(for: asset)

            if preservesManualData(existingRecord) {
                preservedManualDataCount += 1
            }

            if let existingRecord {
                recordsByAssetID[asset.id] = existingRecord
            }

            if let ocrResult {
                if ocrResult.ocrStatus == .completed || ocrResult.ocrStatus == .failed {
                    preservedOCRResultCount += 1
                }

                let record = makeRecord(for: asset, ocrService: ocrService)
                if existingRecord != record {
                    recordsByAssetID[asset.id] = record
                    changedRecords.append(record)
                }
            } else if let existingRecord, isStaleCompletedOCRRecord(existingRecord) {
                let record = existingRecord.clearingOCR()
                recordsByAssetID[asset.id] = record
                changedRecords.append(record)
                repairedStaleCompletedCount += 1
            } else if let existingRecord, isStaleProcessingOCRRecord(existingRecord, ocrService: ocrService, asset: asset) {
                let record = existingRecord.clearingOCR()
                recordsByAssetID[asset.id] = record
                changedRecords.append(record)
                repairedStaleProcessingCount += 1
            }

            if index.isMultiple(of: 500) {
                await Task.yield()
            }
        }

        if changedRecords.isEmpty == false {
            refreshSummary()
            await persistRecords(changedRecords)
        } else {
            do {
                try await refreshStoreStats()
            } catch {
                errorMessage = "読取状態を再確認できませんでした: \(error.localizedDescription)"
            }
        }

        return ReadStateRepairSummary(
            scannedCount: imageAssets.count,
            repairedStaleCompletedCount: repairedStaleCompletedCount,
            repairedStaleProcessingCount: repairedStaleProcessingCount,
            preservedOCRResultCount: preservedOCRResultCount,
            preservedManualDataCount: preservedManualDataCount,
            updatedIndexRecordCount: changedRecords.count
        )
    }

    func clearOCRResult(localIdentifier: String) async {
        let now = Date()
        if let record = recordsByAssetID[localIdentifier] {
            recordsByAssetID[localIdentifier] = record.clearingOCR(at: now)
            refreshSummary()
        }

        do {
            try await store.clearOCRResult(localIdentifier: localIdentifier)
        } catch {
            errorMessage = "OCR結果を削除できませんでした: \(error.localizedDescription)"
        }
    }

    func clearOCRResult(for asset: PhotoAsset, ocrService: OCRService) async {
        await ocrService.clearResult(for: asset)

        let record = makeClearedOCRRecord(for: asset)
        recordsByAssetID[asset.id] = record
        refreshSummary()
        await persistRecords([record])
    }

    func clearOCRResults(localIdentifiers: [String]) async {
        let identifiers = Set(localIdentifiers)
        guard identifiers.isEmpty == false else {
            return
        }

        let now = Date()
        for identifier in identifiers {
            if let record = recordsByAssetID[identifier] {
                recordsByAssetID[identifier] = record.clearingOCR(at: now)
            }
        }

        refreshSummary()

        do {
            try await store.clearOCRResults(localIdentifiers: Array(identifiers))
        } catch {
            errorMessage = "OCR結果を削除できませんでした: \(error.localizedDescription)"
        }
    }

    func clearOCRResults(for assets: [PhotoAsset], ocrService: OCRService) async {
        let imageAssets = assets.filter { $0.mediaType == .image }
        guard imageAssets.isEmpty == false else {
            return
        }

        await ocrService.clearResults(for: imageAssets)

        let records = imageAssets.map { makeClearedOCRRecord(for: $0) }
        for record in records {
            recordsByAssetID[record.localIdentifier] = record
        }

        refreshSummary()
        await persistRecords(records)
    }

    func clearAllOCRResults(ocrService: OCRService) async {
        await clearAllOCRResults(for: [], ocrService: ocrService)
    }

    func clearAllOCRResults(for assets: [PhotoAsset], ocrService: OCRService) async {
        await ocrService.clearAllResults()

        let now = Date()
        recordsByAssetID = recordsByAssetID.mapValues { $0.clearingOCR(at: now) }

        for asset in assets where asset.mediaType == .image {
            recordsByAssetID[asset.id] = makeClearedOCRRecord(for: asset)
        }

        refreshSummary()
        do {
            try await store.clearAllOCRResults()
            try await refreshStoreStats()
        } catch {
            errorMessage = "OCR結果を削除できませんでした: \(error.localizedDescription)"
        }
    }

    func resetCategory(localIdentifier: String) async {
        await learningService.removeExample(localIdentifier: localIdentifier)

        let now = Date()
        if let record = recordsByAssetID[localIdentifier] {
            recordsByAssetID[localIdentifier] = record.resettingCategory(at: now)
            refreshSummary()
        }

        do {
            try await store.resetCategory(localIdentifier: localIdentifier)
        } catch {
            errorMessage = "分類をリセットできませんでした: \(error.localizedDescription)"
        }
    }

    func resetCategory(for asset: PhotoAsset, ocrService: OCRService) async {
        await learningService.removeExample(localIdentifier: asset.localIdentifier)

        let record = (recordsByAssetID[asset.id] ?? makeRecord(for: asset, ocrService: ocrService))
            .resettingCategory()
        recordsByAssetID[asset.id] = record
        refreshSummary()
        await persistRecords([record])
    }

    func rebuildCategory(for asset: PhotoAsset, ocrService: OCRService) async {
        let record = makeRecord(for: asset, ocrService: ocrService)
        recordsByAssetID[asset.id] = record
        refreshSummary()
        await persistRecords([record])
    }

    func rebuildCategories(for assets: [PhotoAsset], ocrService: OCRService) async {
        guard assets.isEmpty == false else {
            return
        }

        var records: [PhotoIndexRecord] = []
        records.reserveCapacity(assets.count)

        for (index, asset) in assets.enumerated() {
            let record = makeRecord(for: asset, ocrService: ocrService)
            recordsByAssetID[asset.id] = record
            records.append(record)

            if index.isMultiple(of: 500) {
                refreshSummary()
                await Task.yield()
            }
        }

        refreshSummary()
        await persistRecords(records)
    }

    func rebuildAllCategories(for assets: [PhotoAsset], ocrService: OCRService) async {
        await rebuildCategories(for: assets, ocrService: ocrService)
    }

    private func makeRecord(
        for asset: PhotoAsset,
        ocrService: OCRService,
        preservingManual: Bool = true,
        usingLearning: Bool = true
    ) -> PhotoIndexRecord {
        let existingRecord = recordsByAssetID[asset.id]
        let ocrResult = ocrService.result(for: asset)

        let status: OCRStatus
        if ocrService.isProcessing(asset) {
            status = .processing
        } else {
            status = ocrResult?.ocrStatus ?? existingRecord?.ocrStatus ?? .unprocessed
        }

        let completedOCRText: String
        if status == .completed {
            completedOCRText = ocrResult?.ocrText ?? existingRecord?.ocrText ?? ""
        } else {
            completedOCRText = ""
        }

        let automaticInference = CategoryInference.infer(asset: asset, ocrText: completedOCRText)
        let automaticScreenshotInference = CategoryInference.inferScreenshotSubcategory(asset: asset, ocrText: completedOCRText)
        var inference = automaticInference
        var screenshotInference = automaticScreenshotInference
        let manualCategory = preservingManual ? existingRecord?.manualCategory : nil
        var manualScreenshotSubcategory = preservingManual ? existingRecord?.manualScreenshotSubcategory : nil

        if let manualCategory {
            inference = CategoryInferenceResult(
                photoLocalIdentifier: asset.localIdentifier,
                category: manualCategory,
                confidence: 1.0,
                reason: "手動分類",
                updatedAt: existingRecord?.manualCategoryUpdatedAt ?? Date()
            )

            if asset.isScreenshot, let manualScreenshotSubcategory {
                screenshotInference = ScreenshotSubcategoryInferenceResult(
                    photoLocalIdentifier: asset.localIdentifier,
                    subcategory: manualScreenshotSubcategory,
                    confidence: 1.0,
                    reason: "手動分類",
                    updatedAt: existingRecord?.manualCategoryUpdatedAt ?? Date()
                )
            } else if manualCategory != .screenshots {
                manualScreenshotSubcategory = nil
                screenshotInference = nil
            }
        } else if usingLearning,
                  let suggestion = learningService.suggestion(
                    for: asset,
                    ocrText: completedOCRText,
                    automaticCategory: automaticInference.category,
                    automaticConfidence: automaticInference.confidence,
                    automaticScreenshotSubcategory: automaticScreenshotInference?.subcategory
                  ) {
            if let suggestedCategory = suggestion.category {
                inference = CategoryInferenceResult(
                    photoLocalIdentifier: asset.localIdentifier,
                    category: suggestedCategory,
                    confidence: suggestion.confidence,
                    reason: suggestion.reason,
                    updatedAt: Date()
                )
            }

            if asset.isScreenshot, let suggestedSubcategory = suggestion.screenshotSubcategory {
                screenshotInference = ScreenshotSubcategoryInferenceResult(
                    photoLocalIdentifier: asset.localIdentifier,
                    subcategory: suggestedSubcategory,
                    confidence: suggestion.confidence,
                    reason: suggestion.reason,
                    updatedAt: Date()
                )
            }
        }

        let categoryUpdatedAt: Date
        if existingRecord?.inferredCategory == inference.category,
           existingRecord?.categoryConfidence == inference.confidence,
           existingRecord?.categoryReason == inference.reason {
            categoryUpdatedAt = existingRecord?.categoryUpdatedAt ?? inference.updatedAt
        } else {
            categoryUpdatedAt = inference.updatedAt
        }

        let screenshotSubcategoryUpdatedAt: Date?
        if existingRecord?.screenshotSubcategory == screenshotInference?.subcategory,
           existingRecord?.screenshotSubcategoryConfidence == screenshotInference?.confidence,
           existingRecord?.screenshotSubcategoryReason == screenshotInference?.reason {
            screenshotSubcategoryUpdatedAt = existingRecord?.screenshotSubcategoryUpdatedAt ?? screenshotInference?.updatedAt
        } else {
            screenshotSubcategoryUpdatedAt = screenshotInference?.updatedAt
        }

        let now = Date()

        return PhotoIndexRecord(
            localIdentifier: asset.localIdentifier,
            creationDate: asset.creationDate,
            mediaTypeRawValue: asset.mediaType.rawValue,
            mediaSubtypesRawValue: asset.mediaSubtypes.rawValue,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            isScreenshot: asset.isScreenshot,
            ocrStatus: status,
            ocrText: completedOCRText,
            ocrLanguage: ocrResult?.ocrLanguage ?? existingRecord?.ocrLanguage,
            ocrProcessedAt: ocrResult?.processedAt ?? existingRecord?.ocrProcessedAt,
            ocrErrorMessage: ocrResult?.errorMessage ?? existingRecord?.ocrErrorMessage,
            inferredCategory: inference.category,
            categoryConfidence: inference.confidence,
            categoryReason: inference.reason,
            categoryUpdatedAt: categoryUpdatedAt,
            manualCategory: manualCategory,
            manualScreenshotSubcategory: manualScreenshotSubcategory,
            manualCategoryUpdatedAt: preservingManual ? existingRecord?.manualCategoryUpdatedAt : nil,
            screenshotSubcategory: screenshotInference?.subcategory,
            screenshotSubcategoryConfidence: screenshotInference?.confidence,
            screenshotSubcategoryReason: screenshotInference?.reason,
            screenshotSubcategoryUpdatedAt: screenshotSubcategoryUpdatedAt,
            displayState: existingRecord?.displayState ?? .active,
            displayStateUpdatedAt: existingRecord?.displayStateUpdatedAt,
            userMemo: existingRecord?.userMemo ?? "",
            userTags: existingRecord?.userTags ?? [],
            lastSeenAt: now,
            updatedAt: now
        )
    }

    private func makeClearedOCRRecord(for asset: PhotoAsset) -> PhotoIndexRecord {
        let existingRecord = recordsByAssetID[asset.id]
        let automaticInference = CategoryInference.infer(asset: asset, ocrText: nil)
        let automaticScreenshotInference = CategoryInference.inferScreenshotSubcategory(asset: asset, ocrText: nil)
        let inference: CategoryInferenceResult
        let screenshotInference: ScreenshotSubcategoryInferenceResult?

        if let manualCategory = existingRecord?.manualCategory {
            inference = CategoryInferenceResult(
                photoLocalIdentifier: asset.localIdentifier,
                category: manualCategory,
                confidence: 1.0,
                reason: "手動分類",
                updatedAt: existingRecord?.manualCategoryUpdatedAt ?? Date()
            )

            if asset.isScreenshot, let manualScreenshotSubcategory = existingRecord?.manualScreenshotSubcategory {
                screenshotInference = ScreenshotSubcategoryInferenceResult(
                    photoLocalIdentifier: asset.localIdentifier,
                    subcategory: manualScreenshotSubcategory,
                    confidence: 1.0,
                    reason: "手動分類",
                    updatedAt: existingRecord?.manualCategoryUpdatedAt ?? Date()
                )
            } else {
                screenshotInference = automaticScreenshotInference
            }
        } else {
            inference = automaticInference
            screenshotInference = automaticScreenshotInference
        }

        let now = Date()

        return PhotoIndexRecord(
            localIdentifier: asset.localIdentifier,
            creationDate: asset.creationDate,
            mediaTypeRawValue: asset.mediaType.rawValue,
            mediaSubtypesRawValue: asset.mediaSubtypes.rawValue,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            isScreenshot: asset.isScreenshot,
            ocrStatus: .unprocessed,
            ocrText: "",
            ocrLanguage: nil,
            ocrProcessedAt: nil,
            ocrErrorMessage: nil,
            inferredCategory: inference.category,
            categoryConfidence: inference.confidence,
            categoryReason: inference.reason,
            categoryUpdatedAt: inference.updatedAt,
            manualCategory: existingRecord?.manualCategory,
            manualScreenshotSubcategory: existingRecord?.manualScreenshotSubcategory,
            manualCategoryUpdatedAt: existingRecord?.manualCategoryUpdatedAt,
            screenshotSubcategory: screenshotInference?.subcategory,
            screenshotSubcategoryConfidence: screenshotInference?.confidence,
            screenshotSubcategoryReason: screenshotInference?.reason,
            screenshotSubcategoryUpdatedAt: screenshotInference?.updatedAt,
            displayState: existingRecord?.displayState ?? .active,
            displayStateUpdatedAt: existingRecord?.displayStateUpdatedAt,
            userMemo: existingRecord?.userMemo ?? "",
            userTags: existingRecord?.userTags ?? [],
            lastSeenAt: now,
            updatedAt: now
        )
    }

    private func isStaleCompletedOCRRecord(_ record: PhotoIndexRecord) -> Bool {
        guard record.ocrStatus == .completed else {
            return false
        }

        let text = record.ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty else {
            return false
        }

        return record.ocrProcessedAt == nil &&
            record.ocrLanguage == nil &&
            record.ocrErrorMessage == nil
    }

    private func isStaleProcessingOCRRecord(
        _ record: PhotoIndexRecord,
        ocrService: OCRService,
        asset: PhotoAsset
    ) -> Bool {
        record.ocrStatus == .processing && ocrService.isProcessing(asset) == false
    }

    private func preservesManualData(_ record: PhotoIndexRecord?) -> Bool {
        guard let record else {
            return false
        }

        return record.manualCategory != nil ||
            record.manualScreenshotSubcategory != nil ||
            record.userMemo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ||
            record.userTags.isEmpty == false ||
            record.displayState != .active
    }

    private func cleanedUserTags(_ tags: [String]) -> [String] {
        var seen: Set<String> = []
        var cleaned: [String] = []

        for tag in tags {
            let value = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.isEmpty == false else {
                continue
            }

            let key = normalizedSearchText(value)
            guard seen.contains(key) == false else {
                continue
            }

            seen.insert(key)
            cleaned.append(value)

            if cleaned.count >= 30 {
                break
            }
        }

        return cleaned
    }

    private func normalizedSearchTokens(in query: String) -> [String] {
        normalizedSearchText(query)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { $0.isEmpty == false }
    }

    private func normalizedSearchText(_ text: String) -> String {
        let widthAdjusted = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        let kanaAdjusted = widthAdjusted.applyingTransform(.hiraganaToKatakana, reverse: false) ?? widthAdjusted
        return kanaAdjusted
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "ja_JP"))
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shortOCRSnippet(from text: String) -> String? {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard collapsed.isEmpty == false else {
            return nil
        }

        if collapsed.count <= 84 {
            return collapsed
        }

        return String(collapsed.prefix(84)) + "..."
    }

    private func loadPersistedRecords() async {
        do {
            isIndexStorePreparing = true
            indexStoreStatusText = "検索インデックスを準備しています"
            progressStore.update(statusText: indexStoreStatusText)
            let records = try await store.loadPage(limit: 500, offset: 0)
            recordsByAssetID = [:]
            recordCacheOrder = []
            updateRecordCache(with: records)
            try await refreshStoreStats()
            indexStoreStatusText = nil
            isIndexStorePreparing = false
            progressStore.update(statusText: nil)
        } catch {
            isIndexStorePreparing = false
            progressStore.update(statusText: nil)
            errorMessage = "インデックスを読み込めませんでした: \(error.localizedDescription)"
        }
    }

    private func persistRecords(_ records: [PhotoIndexRecord], refreshStats: Bool = true) async {
        do {
            try await store.upsert(records)
            if refreshStats {
                try await refreshStoreStats()
            }
        } catch {
            errorMessage = "インデックスを保存できませんでした: \(error.localizedDescription)"
        }
    }

    private func refreshStoreStats() async throws {
        indexSummary = try await store.summary()
        displayStateCountCache = try await store.displayStateCounts()
        categoryCountCache = try await store.categoryCounts(displayState: nil)
        screenshotSubcategoryCountCache = try await store.screenshotSubcategoryCounts(displayState: nil)

        var nextCategoryCounts: [PhotoDisplayState: [PhotoCategory: Int]] = [:]
        var nextScreenshotCounts: [PhotoDisplayState: [ScreenshotSubcategory: Int]] = [:]
        for state in PhotoDisplayState.allCases {
            nextCategoryCounts[state] = try await store.categoryCounts(displayState: state)
            nextScreenshotCounts[state] = try await store.screenshotSubcategoryCounts(displayState: state)
        }

        categoryCountCacheByDisplayState = nextCategoryCounts
        screenshotSubcategoryCountCacheByDisplayState = nextScreenshotCounts

        let scope = filterCountsSnapshot.categoryScope
        filterCountsRevision += 1
        filterCountsSnapshot = FilterCountsSnapshot(
            revision: filterCountsRevision,
            categoryScope: scope,
            displayStateCounts: displayStateCountCache,
            categoryCounts: categoryCountCacheByDisplayState[scope] ?? .emptyCategoryCounts,
            screenshotSubcategoryCounts: screenshotSubcategoryCountCacheByDisplayState[scope] ?? .emptyScreenshotSubcategoryCounts,
            isPreparing: false
        )
    }

    private func categoryCountsByReplacing(
        scope: PhotoDisplayState,
        categoryCounts: [PhotoCategory: Int]?,
        screenshotCounts: [ScreenshotSubcategory: Int]?
    ) {
        if let categoryCounts {
            categoryCountCacheByDisplayState[scope] = categoryCounts
        }

        if let screenshotCounts {
            screenshotSubcategoryCountCacheByDisplayState[scope] = screenshotCounts
        }
    }

    private func cacheRecords(localIdentifiers: [String]) async {
        do {
            let records = try await store.records(localIdentifiers: localIdentifiers)
            updateRecordCache(with: records)
        } catch {
            errorMessage = "表示用インデックスを読み込めませんでした: \(error.localizedDescription)"
        }
    }

    private func updateRecordCache(with records: [PhotoIndexRecord]) {
        guard records.isEmpty == false else {
            return
        }

        for record in records {
            recordsByAssetID[record.localIdentifier] = record
            recordCacheOrder.removeAll { $0 == record.localIdentifier }
            recordCacheOrder.append(record.localIdentifier)
        }

        trimRecordCacheIfNeeded()
    }

    private func trimRecordCacheIfNeeded() {
        guard recordCacheOrder.count > maximumCachedRecords else {
            return
        }

        let overflow = recordCacheOrder.count - maximumCachedRecords
        let identifiersToRemove = recordCacheOrder.prefix(overflow)
        for identifier in identifiersToRemove {
            recordsByAssetID.removeValue(forKey: identifier)
        }
        recordCacheOrder.removeFirst(overflow)
    }

    private func refreshSummary() {
        indexSummary = PhotoIndexSummary(records: Array(recordsByAssetID.values))
    }
}

private extension Dictionary where Key == PhotoDisplayState, Value == Int {
    static var emptyDisplayStateCounts: [PhotoDisplayState: Int] {
        Dictionary(uniqueKeysWithValues: PhotoDisplayState.allCases.map { ($0, 0) })
    }
}

private extension Dictionary where Key == PhotoCategory, Value == Int {
    static var emptyCategoryCounts: [PhotoCategory: Int] {
        Dictionary(uniqueKeysWithValues: PhotoCategory.allCases.map { ($0, 0) })
    }
}

private extension Dictionary where Key == ScreenshotSubcategory, Value == Int {
    static var emptyScreenshotSubcategoryCounts: [ScreenshotSubcategory: Int] {
        Dictionary(uniqueKeysWithValues: ScreenshotSubcategory.allCases.map { ($0, 0) })
    }
}
