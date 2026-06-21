import Combine
import Foundation

@MainActor
final class PhotoClassificationService: ObservableObject {
    @Published private(set) var recordsByAssetID: [String: PhotoClassification] = [:]
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let store: PhotoClassificationStoring

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
            manualCount: records.filter { $0.manualCategory != nil }.count,
            screenshotCount: count(.screenshot, in: records),
            readCandidateCount: count(.readCandidate, in: records),
            needsReviewCount: count(.needsReview, in: records),
            unorganizedCount: count(.unorganized, in: records)
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
}
