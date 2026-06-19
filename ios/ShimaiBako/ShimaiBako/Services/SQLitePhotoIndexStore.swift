import Foundation
import SQLite3

actor SQLitePhotoIndexStore: PhotoIndexStoring {
    nonisolated static let migrationProgressNotification = Notification.Name("SQLitePhotoIndexStoreMigrationProgress")
    private static let schemaVersion = 1
    private static let searchIndexVersion = 1
    private static let searchIndexStateID = "current"

    private enum StoreError: LocalizedError {
        case openFailed(String)
        case prepareFailed(String)
        case stepFailed(String)
        case bindFailed(String)

        var errorDescription: String? {
            switch self {
            case .openFailed(let message):
                "データベースを開けませんでした: \(message)"
            case .prepareFailed(let message):
                "データベース処理を準備できませんでした: \(message)"
            case .stepFailed(let message):
                "データベース処理に失敗しました: \(message)"
            case .bindFailed(let message):
                "データベースへの値設定に失敗しました: \(message)"
            }
        }
    }

    private let databaseURL: URL
    private let legacyStore: JSONPhotoIndexStore
    private var database: OpaquePointer?
    private var didOpen = false
    private var didMigrateLegacyJSON = false

    init(fileManager: FileManager = .default, legacyStore: JSONPhotoIndexStore = JSONPhotoIndexStore()) {
        self.legacyStore = legacyStore

        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? fileManager.temporaryDirectory
        let directoryURL = baseURL.appendingPathComponent("ShimaiBako", isDirectory: true)
        databaseURL = directoryURL.appendingPathComponent("photo_index.sqlite")
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    func loadAll() async throws -> [PhotoIndexRecord] {
        try openIfNeeded()
        try await migrateLegacyJSONIfNeeded()

        let rows = try records(whereClause: nil, bindings: [])
        return rows
    }

    func saveAll(_ records: [PhotoIndexRecord]) async throws {
        try openIfNeeded()

        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try execute("DELETE FROM search_documents")
            try execute("DELETE FROM photo_tags")
            try execute("DELETE FROM photo_texts")
            try execute("DELETE FROM photo_records")
            for record in records {
                try upsertRecord(record)
            }
            try execute("COMMIT")
            try updateSearchIndexPreparationState(
                totalCount: records.count,
                completedCount: records.count,
                state: .completed,
                lastProcessedAssetIdentifier: records.last?.localIdentifier,
                lastOperation: "保存完了",
                completedAt: Date()
            )
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func upsert(_ records: [PhotoIndexRecord]) async throws {
        try openIfNeeded()
        guard records.isEmpty == false else {
            return
        }

        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            for record in records {
                try upsertRecord(record)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func clearOCRResult(localIdentifier: String) async throws {
        try await clearOCRResults(localIdentifiers: [localIdentifier])
    }

    func clearOCRResults(localIdentifiers: [String]) async throws {
        try openIfNeeded()
        guard localIdentifiers.isEmpty == false else {
            return
        }

        let now = Date()
        var changedRecords: [PhotoIndexRecord] = []
        for identifier in localIdentifiers {
            if let record = try record(localIdentifier: identifier) {
                changedRecords.append(record.clearingOCR(at: now))
            }
        }
        try await upsert(changedRecords)
    }

    func clearAllOCRResults() async throws {
        let now = Date()
        let records = try await loadAll().map { $0.clearingOCR(at: now) }
        try await upsert(records)
    }

    func resetCategory(localIdentifier: String) async throws {
        try await resetCategories(localIdentifiers: [localIdentifier])
    }

    func resetCategories(localIdentifiers: [String]) async throws {
        try openIfNeeded()
        guard localIdentifiers.isEmpty == false else {
            return
        }

        let now = Date()
        var changedRecords: [PhotoIndexRecord] = []
        for identifier in localIdentifiers {
            if let record = try record(localIdentifier: identifier) {
                changedRecords.append(record.resettingCategory(at: now))
            }
        }
        try await upsert(changedRecords)
    }

    func resetAllCategories() async throws {
        let now = Date()
        let records = try await loadAll().map { $0.resettingCategory(at: now) }
        try await upsert(records)
    }

    func searchLocalIdentifiers(matching query: String) async throws -> Set<String> {
        try openIfNeeded()
        try await migrateLegacyJSONIfNeeded()

        let tokens = normalizedSearchTokens(in: query)
        guard tokens.isEmpty == false else {
            return Set(try identifiers(whereClause: nil, bindings: []))
        }

        let conditions = tokens.map { _ in "s.normalized_text LIKE ?" }.joined(separator: " AND ")
        let bindings = tokens.map { "%\($0)%" }
        return Set(try identifiers(
            whereClause: conditions,
            bindings: bindings,
            joins: "JOIN search_documents s ON s.asset_identifier = photo_records.asset_identifier"
        ))
    }

    func localIdentifierPage(matching request: PhotoIndexPageRequest) async throws -> PhotoIndexPage {
        try openIfNeeded()
        try await migrateLegacyJSONIfNeeded()

        return try PerformanceTelemetry.measure(.executeSearch, "limit=\(request.normalizedLimit) offset=\(request.normalizedOffset)") {
            let queryPlan = pageQueryPlan(for: request)
            let total = try scalarInt(queryPlan.countSQL, bindings: queryPlan.bindings)
            let identifiers = try identifiers(
                whereClause: queryPlan.whereClause,
                bindings: queryPlan.bindings,
                joins: queryPlan.joins,
                orderAndLimit: "ORDER BY photo_records.creation_date DESC, photo_records.asset_identifier DESC LIMIT ? OFFSET ?",
                limitBindings: [request.normalizedLimit, request.normalizedOffset]
            )
            return PhotoIndexPage(localIdentifiers: identifiers, totalCount: total)
        }
    }

    func displayStateCounts() async throws -> [PhotoDisplayState: Int] {
        try openIfNeeded()
        try await migrateLegacyJSONIfNeeded()

        var counts = Dictionary(uniqueKeysWithValues: PhotoDisplayState.allCases.map { ($0, 0) })
        let grouped = try groupedStringCounts(sql: "SELECT display_state, COUNT(*) FROM photo_records GROUP BY display_state")
        for (rawValue, count) in grouped {
            if let state = PhotoDisplayState(rawValue: rawValue) {
                counts[state] = count
            }
        }
        return counts
    }

    func categoryCounts(displayState: PhotoDisplayState?) async throws -> [PhotoCategory: Int] {
        try openIfNeeded()
        try await migrateLegacyJSONIfNeeded()

        var counts = Dictionary(uniqueKeysWithValues: PhotoCategory.allCases.map { ($0, 0) })
        if let displayState {
            counts[.all] = try scalarInt(
                "SELECT COUNT(*) FROM photo_records WHERE display_state = ?",
                bindings: [displayState.rawValue]
            )

            let grouped = try groupedStringCounts(
                sql: "SELECT category, COUNT(*) FROM photo_records WHERE display_state = ? GROUP BY category",
                bindings: [displayState.rawValue]
            )
            for (rawValue, count) in grouped {
                if let category = PhotoCategory(rawValue: rawValue) {
                    counts[category] = count
                }
            }
            return counts
        }

        counts[.all] = try scalarInt("SELECT COUNT(*) FROM photo_records")
        let grouped = try groupedStringCounts(sql: "SELECT category, COUNT(*) FROM photo_records GROUP BY category")
        for (rawValue, count) in grouped {
            if let category = PhotoCategory(rawValue: rawValue) {
                counts[category] = count
            }
        }
        return counts
    }

    func screenshotSubcategoryCounts(displayState: PhotoDisplayState?) async throws -> [ScreenshotSubcategory: Int] {
        try openIfNeeded()
        try await migrateLegacyJSONIfNeeded()

        var counts = Dictionary(uniqueKeysWithValues: ScreenshotSubcategory.allCases.map { ($0, 0) })
        if let displayState {
            counts[.all] = try scalarInt(
                "SELECT COUNT(*) FROM photo_records WHERE is_screenshot = 1 AND display_state = ?",
                bindings: [displayState.rawValue]
            )

            let grouped = try groupedStringCounts(
                sql: "SELECT COALESCE(screenshot_category, ?), COUNT(*) FROM photo_records WHERE is_screenshot = 1 AND display_state = ? GROUP BY COALESCE(screenshot_category, ?)",
                bindings: [ScreenshotSubcategory.otherScreenshot.rawValue, displayState.rawValue, ScreenshotSubcategory.otherScreenshot.rawValue]
            )
            for (rawValue, count) in grouped {
                if let subcategory = ScreenshotSubcategory(rawValue: rawValue) {
                    counts[subcategory] = count
                }
            }
            return counts
        }

        counts[.all] = try scalarInt("SELECT COUNT(*) FROM photo_records WHERE is_screenshot = 1")
        let grouped = try groupedStringCounts(
            sql: "SELECT COALESCE(screenshot_category, ?), COUNT(*) FROM photo_records WHERE is_screenshot = 1 GROUP BY COALESCE(screenshot_category, ?)",
            bindings: [ScreenshotSubcategory.otherScreenshot.rawValue, ScreenshotSubcategory.otherScreenshot.rawValue]
        )
        for (rawValue, count) in grouped {
            if let subcategory = ScreenshotSubcategory(rawValue: rawValue) {
                counts[subcategory] = count
            }
        }
        return counts
    }

    func summary() async throws -> PhotoIndexSummary {
        try openIfNeeded()
        try await migrateLegacyJSONIfNeeded()

        return PhotoIndexSummary(
            indexedCount: try scalarInt("SELECT COUNT(*) FROM photo_records"),
            completedOCRCount: try scalarInt("SELECT COUNT(*) FROM photo_records WHERE ocr_status = ?", bindings: [OCRStatus.completed.rawValue]),
            failedOCRCount: try scalarInt("SELECT COUNT(*) FROM photo_records WHERE ocr_status = ?", bindings: [OCRStatus.failed.rawValue]),
            processingOCRCount: try scalarInt("SELECT COUNT(*) FROM photo_records WHERE ocr_status = ?", bindings: [OCRStatus.processing.rawValue]),
            unprocessedOCRCount: try scalarInt("SELECT COUNT(*) FROM photo_records WHERE media_type = 1 AND ocr_status = ?", bindings: [OCRStatus.unprocessed.rawValue]),
            categorizedCount: try scalarInt("SELECT COUNT(*) FROM photo_records WHERE category != ?", bindings: [PhotoCategory.uncategorized.rawValue])
        )
    }

    func searchIndexPreparationState() async throws -> SearchIndexPreparationState {
        try openIfNeeded()
        return try currentSearchIndexPreparationState()
    }

    func prepareSearchIndexIfNeeded() async throws -> SearchIndexPreparationState {
        try openIfNeeded()
        didMigrateLegacyJSON = false
        try await migrateLegacyJSONIfNeeded(forceSearchBackfill: true)
        return try currentSearchIndexPreparationState()
    }

    func loadPage(limit: Int, offset: Int) async throws -> [PhotoIndexRecord] {
        try openIfNeeded()
        try await migrateLegacyJSONIfNeeded()

        return try records(
            whereClause: nil,
            bindings: [],
            orderAndLimit: "ORDER BY creation_date DESC, asset_identifier DESC LIMIT ? OFFSET ?",
            limitBindings: [max(limit, 1), max(offset, 0)]
        )
    }

    func records(localIdentifiers: [String]) async throws -> [PhotoIndexRecord] {
        try openIfNeeded()
        try await migrateLegacyJSONIfNeeded()

        guard localIdentifiers.isEmpty == false else {
            return []
        }

        let placeholders = Array(repeating: "?", count: localIdentifiers.count).joined(separator: ",")
        return try records(
            whereClause: "asset_identifier IN (\(placeholders))",
            bindings: localIdentifiers,
            orderAndLimit: "ORDER BY creation_date DESC, asset_identifier DESC"
        )
    }

    private func openIfNeeded() throws {
        guard didOpen == false else {
            return
        }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw StoreError.openFailed(message)
        }

        database = handle
        didOpen = true
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
        try createSchema()
    }

    private func createSchema() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS photo_records (
            asset_identifier TEXT PRIMARY KEY NOT NULL,
            record_json BLOB NOT NULL,
            creation_date REAL,
            media_type INTEGER NOT NULL,
            media_subtype INTEGER NOT NULL,
            pixel_width INTEGER NOT NULL,
            pixel_height INTEGER NOT NULL,
            display_state TEXT NOT NULL,
            category TEXT NOT NULL,
            screenshot_category TEXT,
            manual_category TEXT,
            is_screenshot INTEGER NOT NULL DEFAULT 0,
            has_ocr INTEGER NOT NULL,
            ocr_status TEXT NOT NULL,
            classification_status TEXT NOT NULL,
            analysis_version INTEGER NOT NULL,
            memo TEXT NOT NULL,
            updated_at REAL NOT NULL,
            last_seen_at REAL NOT NULL,
            normalized_search_text TEXT NOT NULL
        )
        """)
        try addColumnIfNeeded(table: "photo_records", column: "is_screenshot", definition: "INTEGER NOT NULL DEFAULT 0")

        try execute("""
        CREATE TABLE IF NOT EXISTS photo_texts (
            asset_identifier TEXT PRIMARY KEY NOT NULL,
            ocr_text TEXT NOT NULL,
            normalized_search_text TEXT NOT NULL
        )
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS photo_tags (
            asset_identifier TEXT NOT NULL,
            tag TEXT NOT NULL,
            normalized_tag TEXT NOT NULL,
            PRIMARY KEY (asset_identifier, normalized_tag)
        )
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS search_documents (
            asset_identifier TEXT PRIMARY KEY NOT NULL,
            normalized_text TEXT NOT NULL,
            index_version INTEGER NOT NULL,
            source_revision REAL NOT NULL,
            indexed_at REAL NOT NULL
        )
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS search_index_preparation_state (
            id TEXT PRIMARY KEY NOT NULL,
            library_revision INTEGER NOT NULL,
            total_count INTEGER NOT NULL,
            completed_count INTEGER NOT NULL,
            state TEXT NOT NULL,
            started_at REAL,
            updated_at REAL,
            completed_at REAL,
            last_processed_asset_identifier TEXT,
            last_operation TEXT,
            last_error TEXT,
            schema_version INTEGER NOT NULL,
            index_version INTEGER NOT NULL
        )
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS processing_jobs (
            job_identifier TEXT PRIMARY KEY NOT NULL,
            job_type TEXT NOT NULL,
            status TEXT NOT NULL,
            total_count INTEGER NOT NULL,
            completed_count INTEGER NOT NULL,
            failed_count INTEGER NOT NULL,
            cancelled_count INTEGER NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        )
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS processing_job_items (
            job_identifier TEXT NOT NULL,
            asset_identifier TEXT NOT NULL,
            status TEXT NOT NULL,
            attempt_count INTEGER NOT NULL,
            last_error TEXT,
            PRIMARY KEY (job_identifier, asset_identifier)
        )
        """)

        try execute("CREATE INDEX IF NOT EXISTS idx_photo_creation_date ON photo_records(creation_date DESC, asset_identifier)")
        try execute("CREATE INDEX IF NOT EXISTS idx_photo_display_state ON photo_records(display_state)")
        try execute("CREATE INDEX IF NOT EXISTS idx_photo_category ON photo_records(category)")
        try execute("CREATE INDEX IF NOT EXISTS idx_photo_is_screenshot ON photo_records(is_screenshot)")
        try execute("CREATE INDEX IF NOT EXISTS idx_photo_screenshot_category ON photo_records(screenshot_category)")
        try execute("CREATE INDEX IF NOT EXISTS idx_photo_has_ocr ON photo_records(has_ocr)")
        try execute("CREATE INDEX IF NOT EXISTS idx_photo_ocr_status ON photo_records(ocr_status)")
        try execute("CREATE INDEX IF NOT EXISTS idx_photo_classification_status ON photo_records(classification_status)")
        try execute("CREATE INDEX IF NOT EXISTS idx_photo_tags_normalized ON photo_tags(normalized_tag)")
        try execute("CREATE INDEX IF NOT EXISTS idx_search_documents_text ON search_documents(normalized_text)")
        try execute("CREATE INDEX IF NOT EXISTS idx_search_documents_revision ON search_documents(index_version, source_revision)")
    }

    private func migrateLegacyJSONIfNeeded(forceSearchBackfill: Bool = false) async throws {
        guard didMigrateLegacyJSON == false else {
            return
        }

        didMigrateLegacyJSON = true
        let recordCount = try scalarInt("SELECT COUNT(*) FROM photo_records")
        guard recordCount == 0 else {
            try reconcileSearchIndexPreparationState(
                totalCount: recordCount,
                forceSearchBackfill: forceSearchBackfill
            )
            return
        }

        let legacyRecords = try await legacyStore.loadAll()
        guard legacyRecords.isEmpty == false else {
            try saveSearchIndexPreparationState(.empty)
            return
        }

        let batchSize = 200
        var index = 0
        try saveSearchIndexPreparationState(SearchIndexPreparationState(
            libraryRevision: Int64(legacyRecords.count),
            totalCount: legacyRecords.count,
            completedCount: 0,
            state: .running,
            startedAt: Date(),
            updatedAt: Date(),
            completedAt: nil,
            lastProcessedAssetIdentifier: nil,
            lastOperation: "旧JSON移行",
            lastError: nil,
            schemaVersion: Self.schemaVersion,
            indexVersion: Self.searchIndexVersion
        ))
        postMigrationProgress(completed: 0, total: legacyRecords.count)
        while index < legacyRecords.count {
            let upperBound = min(index + batchSize, legacyRecords.count)
            try await PerformanceTelemetry.measure(.searchIndexBatch, "legacy=\(index)-\(upperBound)") {
                try await upsert(Array(legacyRecords[index..<upperBound]))
            }
            index = upperBound
            try updateSearchIndexPreparationState(
                totalCount: legacyRecords.count,
                completedCount: index,
                state: .running,
                lastProcessedAssetIdentifier: legacyRecords[index - 1].localIdentifier,
                lastOperation: "旧JSON移行"
            )
            postMigrationProgress(completed: index, total: legacyRecords.count)
        }

        try updateSearchIndexPreparationState(
            totalCount: legacyRecords.count,
            completedCount: legacyRecords.count,
            state: .completed,
            lastProcessedAssetIdentifier: legacyRecords.last?.localIdentifier,
            lastOperation: "完了",
            completedAt: Date()
        )
    }

    private func reconcileSearchIndexPreparationState(totalCount: Int, forceSearchBackfill: Bool) throws {
        let searchDocumentCount = try scalarInt("SELECT COUNT(*) FROM search_documents")
        var state = try currentSearchIndexPreparationState()
        if searchDocumentCount >= totalCount {
            if state.state == .completed,
               state.totalCount == totalCount,
               state.completedCount >= totalCount,
               state.schemaVersion == Self.schemaVersion,
               state.indexVersion == Self.searchIndexVersion {
                return
            }

            try updateSearchIndexPreparationState(
                totalCount: totalCount,
                completedCount: totalCount,
                state: .completed,
                lastProcessedAssetIdentifier: nil,
                lastOperation: "完了",
                completedAt: Date()
            )
            return
        }

        if state.isStale() {
            state.state = .paused
            state.updatedAt = Date()
            state.lastOperation = state.lastOperation ?? "インデックス保存"
            state.lastError = "前回の検索インデックス準備が一定時間更新されませんでした。"
            try saveSearchIndexPreparationState(state)
            return
        }

        let shouldBackfill = forceSearchBackfill || (searchDocumentCount == 0 && state.state == .notStarted)
        guard shouldBackfill else {
            if state.state == .notStarted {
                try updateSearchIndexPreparationState(
                    totalCount: totalCount,
                    completedCount: searchDocumentCount,
                    state: .paused,
                    lastProcessedAssetIdentifier: nil,
                    lastOperation: "再開待ち",
                    lastError: nil
                )
            }
            return
        }

        try backfillSearchDocuments(totalCount: totalCount, alreadyIndexedCount: searchDocumentCount)
    }

    private func backfillSearchDocuments(totalCount: Int, alreadyIndexedCount: Int) throws {
        let batchSize = 200
        var completed = min(alreadyIndexedCount, totalCount)
        try updateSearchIndexPreparationState(
            totalCount: totalCount,
            completedCount: completed,
            state: .running,
            lastProcessedAssetIdentifier: nil,
            lastOperation: "インデックス保存"
        )
        postMigrationProgress(completed: completed, total: totalCount)

        while completed < totalCount {
            let records = try records(
                whereClause: "asset_identifier NOT IN (SELECT asset_identifier FROM search_documents)",
                bindings: [],
                orderAndLimit: "ORDER BY creation_date DESC, asset_identifier DESC LIMIT ?",
                limitBindings: [batchSize]
            )
            guard records.isEmpty == false else {
                completed = totalCount
                break
            }

            let upperBound = min(completed + records.count, totalCount)
            try PerformanceTelemetry.measure(.searchIndexBatch, "backfill=\(completed)-\(upperBound)") {
                try execute("BEGIN IMMEDIATE TRANSACTION")
                do {
                    for record in records {
                        try upsertRecord(record)
                    }
                    try execute("COMMIT")
                } catch {
                    try? execute("ROLLBACK")
                    throw error
                }
            }
            completed = upperBound
            try updateSearchIndexPreparationState(
                totalCount: totalCount,
                completedCount: completed,
                state: .running,
                lastProcessedAssetIdentifier: records.last?.localIdentifier,
                lastOperation: "インデックス保存"
            )
            postMigrationProgress(completed: completed, total: totalCount)
        }

        try updateSearchIndexPreparationState(
            totalCount: totalCount,
            completedCount: totalCount,
            state: .completed,
            lastProcessedAssetIdentifier: nil,
            lastOperation: "完了",
            completedAt: Date()
        )
    }

    private func currentSearchIndexPreparationState() throws -> SearchIndexPreparationState {
        var storedState: SearchIndexPreparationState?
        try withStatement("""
        SELECT
            library_revision,
            total_count,
            completed_count,
            state,
            started_at,
            updated_at,
            completed_at,
            last_processed_asset_identifier,
            last_operation,
            last_error,
            schema_version,
            index_version
        FROM search_index_preparation_state
        WHERE id = ?
        """) { statement in
            try bindText(statement, 1, Self.searchIndexStateID)
            if sqlite3_step(statement) == SQLITE_ROW {
                storedState = SearchIndexPreparationState(
                    libraryRevision: Int64(sqlite3_column_int64(statement, 0)),
                    totalCount: Int(sqlite3_column_int64(statement, 1)),
                    completedCount: Int(sqlite3_column_int64(statement, 2)),
                    state: SearchIndexPreparationState.State(rawValue: columnText(statement, 3) ?? "") ?? .notStarted,
                    startedAt: columnDate(statement, 4),
                    updatedAt: columnDate(statement, 5),
                    completedAt: columnDate(statement, 6),
                    lastProcessedAssetIdentifier: columnText(statement, 7),
                    lastOperation: columnText(statement, 8),
                    lastError: columnText(statement, 9),
                    schemaVersion: Int(sqlite3_column_int64(statement, 10)),
                    indexVersion: Int(sqlite3_column_int64(statement, 11))
                )
            }
        }

        if let storedState {
            return storedState
        }

        let totalCount = try scalarInt("SELECT COUNT(*) FROM photo_records")
        let searchDocumentCount = try scalarInt("SELECT COUNT(*) FROM search_documents")
        if totalCount > 0, searchDocumentCount >= totalCount {
            let now = Date()
            return SearchIndexPreparationState(
                libraryRevision: Int64(totalCount),
                totalCount: totalCount,
                completedCount: totalCount,
                state: .completed,
                startedAt: now,
                updatedAt: now,
                completedAt: now,
                lastProcessedAssetIdentifier: nil,
                lastOperation: "完了",
                lastError: nil,
                schemaVersion: Self.schemaVersion,
                indexVersion: Self.searchIndexVersion
            )
        }

        var state = SearchIndexPreparationState.empty
        state.libraryRevision = Int64(totalCount)
        state.totalCount = totalCount
        state.completedCount = min(searchDocumentCount, totalCount)
        state.schemaVersion = Self.schemaVersion
        state.indexVersion = Self.searchIndexVersion
        return state
    }

    private func updateSearchIndexPreparationState(
        totalCount: Int,
        completedCount: Int,
        state: SearchIndexPreparationState.State,
        lastProcessedAssetIdentifier: String?,
        lastOperation: String?,
        lastError: String? = nil,
        completedAt: Date? = nil
    ) throws {
        let now = Date()
        var nextState = try currentSearchIndexPreparationState()
        nextState.libraryRevision = Int64(totalCount)
        nextState.totalCount = totalCount
        nextState.completedCount = completedCount
        nextState.state = state
        nextState.startedAt = nextState.startedAt ?? now
        nextState.updatedAt = now
        nextState.completedAt = completedAt
        nextState.lastProcessedAssetIdentifier = lastProcessedAssetIdentifier ?? nextState.lastProcessedAssetIdentifier
        nextState.lastOperation = lastOperation
        nextState.lastError = lastError
        nextState.schemaVersion = Self.schemaVersion
        nextState.indexVersion = Self.searchIndexVersion
        try saveSearchIndexPreparationState(nextState)
    }

    private func saveSearchIndexPreparationState(_ state: SearchIndexPreparationState) throws {
        try withStatement("""
        INSERT OR REPLACE INTO search_index_preparation_state (
            id,
            library_revision,
            total_count,
            completed_count,
            state,
            started_at,
            updated_at,
            completed_at,
            last_processed_asset_identifier,
            last_operation,
            last_error,
            schema_version,
            index_version
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """) { statement in
            try bindText(statement, 1, Self.searchIndexStateID)
            try bindInt64(statement, 2, state.libraryRevision)
            try bindInt(statement, 3, state.totalCount)
            try bindInt(statement, 4, state.completedCount)
            try bindText(statement, 5, state.state.rawValue)
            try bindDate(statement, 6, state.startedAt)
            try bindDate(statement, 7, state.updatedAt)
            try bindDate(statement, 8, state.completedAt)
            try bindNullableText(statement, 9, state.lastProcessedAssetIdentifier)
            try bindNullableText(statement, 10, state.lastOperation)
            try bindNullableText(statement, 11, state.lastError)
            try bindInt(statement, 12, state.schemaVersion)
            try bindInt(statement, 13, state.indexVersion)
            try stepDone(statement)
        }
    }

    private func postMigrationProgress(completed: Int, total: Int) {
        NotificationCenter.default.post(
            name: Self.migrationProgressNotification,
            object: nil,
            userInfo: [
                "completed": completed,
                "total": total
            ]
        )
        PerformanceTelemetry.mark(.publishIndexProgress, "\(completed)/\(total)")
    }

    private func upsertRecord(_ record: PhotoIndexRecord) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        let normalizedText = normalizedSearchText(record.searchableIndexText)

        try withStatement("""
        INSERT OR REPLACE INTO photo_records (
            asset_identifier,
            record_json,
            creation_date,
            media_type,
            media_subtype,
            pixel_width,
            pixel_height,
            display_state,
            category,
            screenshot_category,
            manual_category,
            is_screenshot,
            has_ocr,
            ocr_status,
            classification_status,
            analysis_version,
            memo,
            updated_at,
            last_seen_at,
            normalized_search_text
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """) { statement in
            try bindText(statement, 1, record.localIdentifier)
            try bindBlob(statement, 2, data)
            try bindDate(statement, 3, record.creationDate)
            try bindInt(statement, 4, record.mediaTypeRawValue)
            try bindInt(statement, 5, Int(record.mediaSubtypesRawValue))
            try bindInt(statement, 6, record.pixelWidth)
            try bindInt(statement, 7, record.pixelHeight)
            try bindText(statement, 8, record.displayState.rawValue)
            try bindText(statement, 9, record.inferredCategory.rawValue)
            try bindNullableText(statement, 10, record.screenshotSubcategory?.rawValue)
            try bindNullableText(statement, 11, record.manualCategory?.rawValue)
            try bindInt(statement, 12, record.isScreenshot ? 1 : 0)
            try bindInt(statement, 13, record.hasOCRText ? 1 : 0)
            try bindText(statement, 14, record.ocrStatus.rawValue)
            try bindText(statement, 15, record.inferredCategory == .uncategorized ? "pending" : "classified")
            try bindInt(statement, 16, 1)
            try bindText(statement, 17, record.userMemo)
            try bindDate(statement, 18, record.updatedAt)
            try bindDate(statement, 19, record.lastSeenAt)
            try bindText(statement, 20, normalizedText)
            try stepDone(statement)
        }

        try upsertText(record)
        try upsertTags(record)
        try upsertSearchDocument(record, normalizedText: normalizedText)
    }

    private func upsertSearchDocument(_ record: PhotoIndexRecord, normalizedText: String) throws {
        try withStatement("""
        INSERT OR REPLACE INTO search_documents (
            asset_identifier,
            normalized_text,
            index_version,
            source_revision,
            indexed_at
        ) VALUES (?, ?, ?, ?, ?)
        """) { statement in
            try bindText(statement, 1, record.localIdentifier)
            try bindText(statement, 2, normalizedText)
            try bindInt(statement, 3, 1)
            try bindDate(statement, 4, record.updatedAt)
            try bindDate(statement, 5, Date())
            try stepDone(statement)
        }
    }

    private func upsertText(_ record: PhotoIndexRecord) throws {
        if record.ocrStatus == .completed, record.ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            try withStatement("""
            INSERT OR REPLACE INTO photo_texts (
                asset_identifier,
                ocr_text,
                normalized_search_text
            ) VALUES (?, ?, ?)
            """) { statement in
                try bindText(statement, 1, record.localIdentifier)
                try bindText(statement, 2, record.ocrText)
                try bindText(statement, 3, normalizedSearchText(record.ocrText))
                try stepDone(statement)
            }
        } else {
            try withStatement("DELETE FROM photo_texts WHERE asset_identifier = ?") { statement in
                try bindText(statement, 1, record.localIdentifier)
                try stepDone(statement)
            }
        }
    }

    private func upsertTags(_ record: PhotoIndexRecord) throws {
        try withStatement("DELETE FROM photo_tags WHERE asset_identifier = ?") { statement in
            try bindText(statement, 1, record.localIdentifier)
            try stepDone(statement)
        }

        for tag in record.userTags {
            let normalized = normalizedSearchText(tag)
            guard normalized.isEmpty == false else {
                continue
            }

            try withStatement("""
            INSERT OR REPLACE INTO photo_tags (
                asset_identifier,
                tag,
                normalized_tag
            ) VALUES (?, ?, ?)
            """) { statement in
                try bindText(statement, 1, record.localIdentifier)
                try bindText(statement, 2, tag)
                try bindText(statement, 3, normalized)
                try stepDone(statement)
            }
        }
    }

    private func record(localIdentifier: String) throws -> PhotoIndexRecord? {
        try records(whereClause: "asset_identifier = ?", bindings: [localIdentifier]).first
    }

    private struct PageQueryPlan {
        var joins: String
        var whereClause: String?
        var bindings: [String]
        var countSQL: String
    }

    private func pageQueryPlan(for request: PhotoIndexPageRequest) -> PageQueryPlan {
        var joins = ""
        var clauses: [String] = []
        var bindings: [String] = []

        if request.includeUnwantedWhenActive,
           request.displayState == .active {
            clauses.append("photo_records.display_state IN (?, ?)")
            bindings.append(PhotoDisplayState.active.rawValue)
            bindings.append(PhotoDisplayState.unwanted.rawValue)
        } else {
            clauses.append("photo_records.display_state = ?")
            bindings.append(request.displayState.rawValue)
        }

        if request.category != .all {
            clauses.append("photo_records.category = ?")
            bindings.append(request.category.rawValue)
        }

        if request.category == .screenshots,
           request.screenshotSubcategory != .all {
            clauses.append("photo_records.is_screenshot = 1")
            clauses.append("COALESCE(photo_records.screenshot_category, ?) = ?")
            bindings.append(ScreenshotSubcategory.otherScreenshot.rawValue)
            bindings.append(request.screenshotSubcategory.rawValue)
        }

        let tokens = normalizedSearchTokens(in: request.query)
        if tokens.isEmpty == false {
            joins = "JOIN search_documents s ON s.asset_identifier = photo_records.asset_identifier"
            for token in tokens {
                clauses.append("s.normalized_text LIKE ?")
                bindings.append("%\(token)%")
            }
        }

        let whereClause = clauses.isEmpty ? nil : clauses.joined(separator: " AND ")
        var countSQL = "SELECT COUNT(*) FROM photo_records"
        if joins.isEmpty == false {
            countSQL += " \(joins)"
        }
        if let whereClause {
            countSQL += " WHERE \(whereClause)"
        }

        return PageQueryPlan(joins: joins, whereClause: whereClause, bindings: bindings, countSQL: countSQL)
    }

    private func identifiers(
        whereClause: String?,
        bindings: [String],
        joins: String = "",
        orderAndLimit: String = "ORDER BY photo_records.creation_date DESC, photo_records.asset_identifier DESC",
        limitBindings: [Int] = []
    ) throws -> [String] {
        var sql = "SELECT photo_records.asset_identifier FROM photo_records"
        if joins.isEmpty == false {
            sql += " \(joins)"
        }
        if let whereClause {
            sql += " WHERE \(whereClause)"
        }
        sql += " \(orderAndLimit)"

        var identifiers: [String] = []
        try withStatement(sql) { statement in
            for (index, binding) in bindings.enumerated() {
                try bindText(statement, Int32(index + 1), binding)
            }

            let offset = bindings.count
            for (index, binding) in limitBindings.enumerated() {
                try bindInt(statement, Int32(offset + index + 1), binding)
            }

            while sqlite3_step(statement) == SQLITE_ROW {
                guard let rawPointer = sqlite3_column_text(statement, 0) else {
                    continue
                }
                identifiers.append(String(cString: rawPointer))
            }
        }
        return identifiers
    }

    private func records(
        whereClause: String?,
        bindings: [String],
        orderAndLimit: String = "ORDER BY updated_at DESC",
        limitBindings: [Int] = []
    ) throws -> [PhotoIndexRecord] {
        var sql = "SELECT record_json FROM photo_records"
        if let whereClause {
            sql += " WHERE \(whereClause)"
        }
        sql += " \(orderAndLimit)"

        var records: [PhotoIndexRecord] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        try withStatement(sql) { statement in
            for (index, binding) in bindings.enumerated() {
                try bindText(statement, Int32(index + 1), binding)
            }

            let offset = bindings.count
            for (index, binding) in limitBindings.enumerated() {
                try bindInt(statement, Int32(offset + index + 1), binding)
            }

            while sqlite3_step(statement) == SQLITE_ROW {
                let bytes = sqlite3_column_blob(statement, 0)
                let count = Int(sqlite3_column_bytes(statement, 0))
                guard let bytes, count > 0 else {
                    continue
                }

                let data = Data(bytes: bytes, count: count)
                records.append(try decoder.decode(PhotoIndexRecord.self, from: data))
            }
        }

        return records
    }

    private func scalarInt(_ sql: String, bindings: [String] = []) throws -> Int {
        var value = 0
        try withStatement(sql) { statement in
            for (index, binding) in bindings.enumerated() {
                try bindText(statement, Int32(index + 1), binding)
            }

            if sqlite3_step(statement) == SQLITE_ROW {
                value = Int(sqlite3_column_int64(statement, 0))
            }
        }
        return value
    }

    private func groupedStringCounts(sql: String, bindings: [String] = []) throws -> [(String, Int)] {
        var rows: [(String, Int)] = []
        try withStatement(sql) { statement in
            for (index, binding) in bindings.enumerated() {
                try bindText(statement, Int32(index + 1), binding)
            }

            while sqlite3_step(statement) == SQLITE_ROW {
                guard let rawPointer = sqlite3_column_text(statement, 0) else {
                    continue
                }

                rows.append((String(cString: rawPointer), Int(sqlite3_column_int64(statement, 1))))
            }
        }
        return rows
    }

    private func execute(_ sql: String) throws {
        guard let database else {
            throw StoreError.openFailed("database not open")
        }

        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(database, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(error)
            throw StoreError.stepFailed(message)
        }
    }

    private func addColumnIfNeeded(table: String, column: String, definition: String) throws {
        guard try tableHasColumn(table: table, column: column) == false else {
            return
        }

        try execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
    }

    private func tableHasColumn(table: String, column: String) throws -> Bool {
        var exists = false
        try withStatement("PRAGMA table_info(\(table))") { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let rawPointer = sqlite3_column_text(statement, 1) else {
                    continue
                }

                if String(cString: rawPointer) == column {
                    exists = true
                    break
                }
            }
        }
        return exists
    }

    private func withStatement(_ sql: String, _ body: (OpaquePointer) throws -> Void) throws {
        guard let database else {
            throw StoreError.openFailed("database not open")
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw StoreError.prepareFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer {
            sqlite3_finalize(statement)
        }

        try body(statement)
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw StoreError.stepFailed(databaseMessage)
        }
    }

    private var databaseMessage: String {
        guard let database else {
            return "database not open"
        }

        return String(cString: sqlite3_errmsg(database))
    }

    private func bindText(_ statement: OpaquePointer, _ index: Int32, _ value: String) throws {
        guard sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT) == SQLITE_OK else {
            throw StoreError.bindFailed(databaseMessage)
        }
    }

    private func bindNullableText(_ statement: OpaquePointer, _ index: Int32, _ value: String?) throws {
        guard let value else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
                throw StoreError.bindFailed(databaseMessage)
            }
            return
        }

        try bindText(statement, index, value)
    }

    private func bindBlob(_ statement: OpaquePointer, _ index: Int32, _ value: Data) throws {
        try value.withUnsafeBytes { buffer in
            guard sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(value.count), SQLITE_TRANSIENT) == SQLITE_OK else {
                throw StoreError.bindFailed(databaseMessage)
            }
        }
    }

    private func bindInt(_ statement: OpaquePointer, _ index: Int32, _ value: Int) throws {
        guard sqlite3_bind_int64(statement, index, sqlite3_int64(value)) == SQLITE_OK else {
            throw StoreError.bindFailed(databaseMessage)
        }
    }

    private func bindInt64(_ statement: OpaquePointer, _ index: Int32, _ value: Int64) throws {
        guard sqlite3_bind_int64(statement, index, sqlite3_int64(value)) == SQLITE_OK else {
            throw StoreError.bindFailed(databaseMessage)
        }
    }

    private func bindDate(_ statement: OpaquePointer, _ index: Int32, _ value: Date?) throws {
        guard let value else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
                throw StoreError.bindFailed(databaseMessage)
            }
            return
        }

        guard sqlite3_bind_double(statement, index, value.timeIntervalSince1970) == SQLITE_OK else {
            throw StoreError.bindFailed(databaseMessage)
        }
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let rawPointer = sqlite3_column_text(statement, index) else {
            return nil
        }

        return String(cString: rawPointer)
    }

    private func columnDate(_ statement: OpaquePointer, _ index: Int32) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }

        return Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
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
}

nonisolated(unsafe) private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
