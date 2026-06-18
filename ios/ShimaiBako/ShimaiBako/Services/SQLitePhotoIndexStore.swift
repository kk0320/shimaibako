import Foundation
import SQLite3

actor SQLitePhotoIndexStore: PhotoIndexStoring {
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
            try execute("DELETE FROM photo_tags")
            try execute("DELETE FROM photo_texts")
            try execute("DELETE FROM photo_records")
            for record in records {
                try upsertRecord(record)
            }
            try execute("COMMIT")
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

        let conditions = tokens.map { _ in "normalized_search_text LIKE ?" }.joined(separator: " AND ")
        let bindings = tokens.map { "%\($0)%" }
        return Set(try identifiers(whereClause: conditions, bindings: bindings))
    }

    func categoryCounts() async throws -> [PhotoCategory: Int] {
        try openIfNeeded()
        try await migrateLegacyJSONIfNeeded()

        var counts = Dictionary(uniqueKeysWithValues: PhotoCategory.allCases.map { ($0, 0) })
        counts[.all] = try scalarInt("SELECT COUNT(*) FROM photo_records")

        let grouped = try groupedStringCounts(sql: "SELECT category, COUNT(*) FROM photo_records GROUP BY category")
        for (rawValue, count) in grouped {
            if let category = PhotoCategory(rawValue: rawValue) {
                counts[category] = count
            }
        }
        return counts
    }

    func screenshotSubcategoryCounts() async throws -> [ScreenshotSubcategory: Int] {
        try openIfNeeded()
        try await migrateLegacyJSONIfNeeded()

        var counts = Dictionary(uniqueKeysWithValues: ScreenshotSubcategory.allCases.map { ($0, 0) })
        counts[.all] = try scalarInt("SELECT COUNT(*) FROM photo_records WHERE is_screenshot = 1")

        let grouped = try groupedStringCounts(
            sql: "SELECT screenshot_category, COUNT(*) FROM photo_records WHERE is_screenshot = 1 GROUP BY screenshot_category"
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
        try execute("CREATE INDEX IF NOT EXISTS idx_photo_screenshot_category ON photo_records(screenshot_category)")
        try execute("CREATE INDEX IF NOT EXISTS idx_photo_has_ocr ON photo_records(has_ocr)")
        try execute("CREATE INDEX IF NOT EXISTS idx_photo_ocr_status ON photo_records(ocr_status)")
        try execute("CREATE INDEX IF NOT EXISTS idx_photo_classification_status ON photo_records(classification_status)")
        try execute("CREATE INDEX IF NOT EXISTS idx_photo_tags_normalized ON photo_tags(normalized_tag)")
    }

    private func migrateLegacyJSONIfNeeded() async throws {
        guard didMigrateLegacyJSON == false else {
            return
        }

        didMigrateLegacyJSON = true
        guard try scalarInt("SELECT COUNT(*) FROM photo_records") == 0 else {
            return
        }

        let legacyRecords = try await legacyStore.loadAll()
        guard legacyRecords.isEmpty == false else {
            return
        }

        let batchSize = 500
        var index = 0
        while index < legacyRecords.count {
            let upperBound = min(index + batchSize, legacyRecords.count)
            try await upsert(Array(legacyRecords[index..<upperBound]))
            index = upperBound
        }
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
            has_ocr,
            ocr_status,
            classification_status,
            analysis_version,
            memo,
            updated_at,
            last_seen_at,
            normalized_search_text
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            try bindInt(statement, 12, record.hasOCRText ? 1 : 0)
            try bindText(statement, 13, record.ocrStatus.rawValue)
            try bindText(statement, 14, record.inferredCategory == .uncategorized ? "pending" : "classified")
            try bindInt(statement, 15, 1)
            try bindText(statement, 16, record.userMemo)
            try bindDate(statement, 17, record.updatedAt)
            try bindDate(statement, 18, record.lastSeenAt)
            try bindText(statement, 19, normalizedText)
            try stepDone(statement)
        }

        try upsertText(record)
        try upsertTags(record)
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

    private func identifiers(whereClause: String?, bindings: [String]) throws -> [String] {
        var sql = "SELECT asset_identifier FROM photo_records"
        if let whereClause {
            sql += " WHERE \(whereClause)"
        }
        sql += " ORDER BY creation_date DESC, asset_identifier DESC"

        var identifiers: [String] = []
        try withStatement(sql) { statement in
            for (index, binding) in bindings.enumerated() {
                try bindText(statement, Int32(index + 1), binding)
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

    private func groupedStringCounts(sql: String) throws -> [(String, Int)] {
        var rows: [(String, Int)] = []
        try withStatement(sql) { statement in
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
