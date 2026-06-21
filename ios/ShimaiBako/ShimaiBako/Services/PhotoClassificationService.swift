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
    #endif

    private static let readCandidateTag = "readCandidate"
}

private extension PhotoClassification {
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
        var tagSet = Set(tags)
        if enabled {
            tagSet.insert(tag)
        } else {
            tagSet.remove(tag)
        }
        return tagSet.sorted()
    }
}
