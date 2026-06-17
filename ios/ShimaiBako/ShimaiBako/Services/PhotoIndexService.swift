import Combine
import Foundation
import Photos

@MainActor
final class PhotoIndexService: ObservableObject {
    @Published private(set) var recordsByAssetID: [String: PhotoIndexRecord] = [:]
    @Published private(set) var indexSummary: PhotoIndexSummary = .empty
    @Published var errorMessage: String?

    private let store: any PhotoIndexStoring

    init(store: any PhotoIndexStoring = JSONPhotoIndexStore()) {
        self.store = store

        Task {
            await loadPersistedRecords()
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

    func category(for asset: PhotoAsset, ocrService: OCRService) -> PhotoCategory {
        record(for: asset, ocrService: ocrService).inferredCategory
    }

    func confidenceLabel(for asset: PhotoAsset, ocrService: OCRService) -> String {
        let confidence = record(for: asset, ocrService: ocrService).categoryConfidence
        return "\(Int((confidence * 100).rounded()))%"
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

    func matches(asset: PhotoAsset, query: String, ocrService: OCRService) -> Bool {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedQuery.isEmpty == false else {
            return true
        }

        let record = record(for: asset, ocrService: ocrService)
        let haystack = [
            asset.filename ?? "",
            asset.kindLabel,
            asset.dateLabel,
            asset.sizeLabel,
            asset.localIdentifier,
            asset.isFavorite ? "お気に入り" : "",
            record.searchableIndexText
        ]
        .joined(separator: " ")

        return haystack.localizedCaseInsensitiveContains(normalizedQuery)
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

    func rebuild(for assets: [PhotoAsset], ocrService: OCRService) async {
        guard assets.isEmpty == false else {
            return
        }

        var nextRecords = recordsByAssetID
        var changedRecords: [PhotoIndexRecord] = []

        for (index, asset) in assets.enumerated() {
            let record = makeRecord(for: asset, ocrService: ocrService)
            nextRecords[asset.id] = record
            changedRecords.append(record)

            if index.isMultiple(of: 500) {
                recordsByAssetID = nextRecords
                await Task.yield()
            }
        }

        recordsByAssetID = nextRecords
        refreshSummary()
        await persistRecords(changedRecords)
    }

    func update(asset: PhotoAsset, ocrService: OCRService) async {
        let record = makeRecord(for: asset, ocrService: ocrService)
        recordsByAssetID[asset.id] = record
        refreshSummary()
        await persistRecords([record])
    }

    func rebuildSearchIndex(for assets: [PhotoAsset], ocrService: OCRService) async {
        await rebuild(for: assets, ocrService: ocrService)
    }

    private func makeRecord(for asset: PhotoAsset, ocrService: OCRService) -> PhotoIndexRecord {
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

        let inference = CategoryInference.infer(asset: asset, ocrText: completedOCRText)
        let categoryUpdatedAt: Date
        if existingRecord?.inferredCategory == inference.category,
           existingRecord?.categoryConfidence == inference.confidence {
            categoryUpdatedAt = existingRecord?.categoryUpdatedAt ?? inference.updatedAt
        } else {
            categoryUpdatedAt = inference.updatedAt
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
            categoryUpdatedAt: categoryUpdatedAt,
            lastSeenAt: now,
            updatedAt: now
        )
    }

    private func loadPersistedRecords() async {
        do {
            let records = try await store.loadAll()
            recordsByAssetID = Dictionary(uniqueKeysWithValues: records.map { ($0.localIdentifier, $0) })
            refreshSummary()
        } catch {
            errorMessage = "インデックスを読み込めませんでした: \(error.localizedDescription)"
        }
    }

    private func persistRecords(_ records: [PhotoIndexRecord]) async {
        do {
            try await store.upsert(records)
            refreshSummary()
        } catch {
            errorMessage = "インデックスを保存できませんでした: \(error.localizedDescription)"
        }
    }

    private func refreshSummary() {
        indexSummary = PhotoIndexSummary(records: Array(recordsByAssetID.values))
    }
}
