import Combine
import Foundation
import Photos

@MainActor
final class PhotoIndexService: ObservableObject {
    @Published private(set) var recordsByAssetID: [String: PhotoIndexRecord] = [:]
    @Published private(set) var indexSummary: PhotoIndexSummary = .empty
    @Published var errorMessage: String?

    private let store: any PhotoIndexStoring
    private let learningService: ManualCategoryLearningService

    init(
        store: any PhotoIndexStoring = JSONPhotoIndexStore(),
        learningService: ManualCategoryLearningService
    ) {
        self.store = store
        self.learningService = learningService

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
        var counts = Dictionary(uniqueKeysWithValues: PhotoDisplayState.allCases.map { ($0, 0) })

        for asset in assets {
            let state = displayState(for: asset, ocrService: ocrService)
            counts[state, default: 0] += 1
        }

        return counts
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
        var nextRecords = recordsByAssetID.mapValues { $0.clearingOCR(at: now) }

        for asset in assets where asset.mediaType == .image {
            nextRecords[asset.id] = makeClearedOCRRecord(for: asset)
        }

        recordsByAssetID = nextRecords
        refreshSummary()
        await persistAllRecords(Array(nextRecords.values))
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

    private func persistAllRecords(_ records: [PhotoIndexRecord]) async {
        do {
            try await store.saveAll(records)
            refreshSummary()
        } catch {
            errorMessage = "インデックスを保存できませんでした: \(error.localizedDescription)"
        }
    }

    private func refreshSummary() {
        indexSummary = PhotoIndexSummary(records: Array(recordsByAssetID.values))
    }
}
