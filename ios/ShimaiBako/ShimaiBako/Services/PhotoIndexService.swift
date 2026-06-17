import Combine
import Foundation
import Photos

@MainActor
final class PhotoIndexService: ObservableObject {
    @Published private(set) var recordsByAssetID: [String: PhotoIndexRecord] = [:]
    @Published var errorMessage: String?

    private let store: PhotoIndexStore

    init(store: PhotoIndexStore = PhotoIndexStore()) {
        self.store = store

        Task {
            await loadPersistedRecords()
        }
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

    func rebuild(for assets: [PhotoAsset], ocrService: OCRService) async {
        guard assets.isEmpty == false else {
            return
        }

        var nextRecords = recordsByAssetID

        for (index, asset) in assets.enumerated() {
            nextRecords[asset.id] = makeRecord(for: asset, ocrService: ocrService)

            if index.isMultiple(of: 500) {
                await Task.yield()
            }
        }

        recordsByAssetID = nextRecords
        await persistRecords()
    }

    func update(asset: PhotoAsset, ocrService: OCRService) async {
        recordsByAssetID[asset.id] = makeRecord(for: asset, ocrService: ocrService)
        await persistRecords()
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

    private func makeRecord(for asset: PhotoAsset, ocrService: OCRService) -> PhotoIndexRecord {
        let ocrText = ocrService.searchText(for: asset)
        let inference = CategoryInference.infer(asset: asset, ocrText: ocrText)

        return PhotoIndexRecord(
            localIdentifier: asset.localIdentifier,
            creationDate: asset.creationDate,
            mediaTypeRawValue: asset.mediaType.rawValue,
            mediaSubtypesRawValue: asset.mediaSubtypes.rawValue,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            isScreenshot: asset.isScreenshot,
            inferredCategory: inference.category,
            categoryConfidence: inference.confidence,
            ocrStatus: ocrService.status(for: asset),
            hasOCRText: ocrText.isEmpty == false,
            updatedAt: Date()
        )
    }

    private func loadPersistedRecords() async {
        do {
            let records = try await store.load()
            recordsByAssetID = Dictionary(uniqueKeysWithValues: records.map { ($0.localIdentifier, $0) })
        } catch {
            errorMessage = "インデックスを読み込めませんでした: \(error.localizedDescription)"
        }
    }

    private func persistRecords() async {
        do {
            try await store.save(Array(recordsByAssetID.values))
        } catch {
            errorMessage = "インデックスを保存できませんでした: \(error.localizedDescription)"
        }
    }
}
