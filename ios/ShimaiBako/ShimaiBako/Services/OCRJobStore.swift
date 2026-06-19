import Foundation
import SQLite3

actor OCRJobStore {
    private enum StoreError: LocalizedError {
        case openFailed(String)
        case prepareFailed(String)
        case bindFailed(String)
        case stepFailed(String)

        var errorDescription: String? {
            switch self {
            case .openFailed(let message):
                "OCRジョブDBを開けませんでした: \(message)"
            case .prepareFailed(let message):
                "OCRジョブDBを準備できませんでした: \(message)"
            case .bindFailed(let message):
                "OCRジョブDBへ値を設定できませんでした: \(message)"
            case .stepFailed(let message):
                "OCRジョブDBを更新できませんでした: \(message)"
            }
        }
    }

    private let databaseURL: URL
    private let fileManager: FileManager
    private var database: OpaquePointer?
    private var didOpen = false
    private var didPrepareDatabase = false
    private var lastMigrationAt: Date?

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? fileManager.temporaryDirectory
        let directoryURL = baseURL.appendingPathComponent("ShimaiBako", isDirectory: true)
        databaseURL = directoryURL.appendingPathComponent("ocr_jobs.sqlite")
    }

    #if DEBUG
    nonisolated var debugIdentifier: String {
        String(ObjectIdentifier(self).hashValue)
    }

    nonisolated var persistentStorePath: String {
        databaseURL.path
    }
    #endif

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    func prepareDatabaseIfNeeded() async throws -> OCRJobDatabaseDiagnostics {
        try prepareDatabaseIfNeededSync()
        return try databaseDiagnosticsSync(status: .ready, lastError: nil)
    }

    func databaseDiagnostics() async -> OCRJobDatabaseDiagnostics {
        do {
            try openConnectionIfNeeded()
            let jobsExists = try tableExists("ocr_jobs")
            let itemsExists = try tableExists("ocr_job_items")
            let status: OCRJobDatabaseStatus
            if didPrepareDatabase, jobsExists, itemsExists {
                status = .ready
            } else if jobsExists == false || itemsExists == false {
                status = .missingTable
            } else {
                status = .unknown
            }
            return try databaseDiagnosticsSync(status: status, lastError: nil)
        } catch {
            return OCRJobDatabaseDiagnostics(
                status: isMissingTableError(error) ? .missingTable : .repairFailed,
                lastError: error.localizedDescription,
                lastMigrationAt: lastMigrationAt,
                ocrJobsTableExists: false,
                ocrJobItemsTableExists: false
            )
        }
    }

    func recoverInterruptedItems() async throws {
        try openIfNeeded()
        try execute("""
        UPDATE ocr_job_items
        SET state = ?, started_at = NULL
        WHERE state IN (?, ?)
        """, bindings: [
            .text(OCRJobItemState.pending.rawValue),
            .text(OCRJobItemState.fetchingImage.rawValue),
            .text(OCRJobItemState.recognizing.rawValue)
        ])

        try execute("""
        UPDATE ocr_jobs
        SET state = ?, paused_reason = ?, current_phase = ?, last_heartbeat_at = ?, updated_at = ?
        WHERE state IN (?, ?, ?, ?)
        """, bindings: [
            .text(OCRJobState.paused.rawValue),
            .text("前回のOCR処理が中断されました。続きから再開できます。"),
            .text(OCRCurrentPhase.selectingTargets.rawValue),
            .date(Date()),
            .date(Date()),
            .text(OCRJobState.preparing.rawValue),
            .text(OCRJobState.throttled.rawValue),
            .text(OCRJobState.running.rawValue),
            .text(OCRJobState.finalizing.rawValue)
        ])
    }

    func activeJob() async throws -> OCRJob? {
        try openIfNeeded()
        return try jobs(
            whereClause: "state IN (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            bindings: [
                .text(OCRJobState.preparing.rawValue),
                .text(OCRJobState.pending.rawValue),
                .text(OCRJobState.running.rawValue),
                .text(OCRJobState.paused.rawValue),
                .text(OCRJobState.throttled.rawValue),
                .text(OCRJobState.finalizing.rawValue),
                .text(OCRJobState.pausedThermal.rawValue),
                .text(OCRJobState.pausedUser.rawValue),
                .text(OCRJobState.cancelling.rawValue)
            ],
            orderAndLimit: "ORDER BY updated_at DESC LIMIT 1"
        ).first
    }

    func createJob(scope: OCRJobScope, qualityMode: OCRJobQualityMode, items: [OCRJobItemInput]) async throws -> OCRJob {
        try await createJob(scope: scope, qualityMode: qualityMode, items: items, initialState: .pending, plannedCount: items.count)
    }

    func createPreparingJob(scope: OCRJobScope, qualityMode: OCRJobQualityMode) async throws -> OCRJob {
        try await createJob(scope: scope, qualityMode: qualityMode, items: [], initialState: .preparing, plannedCount: 0)
    }

    private func createJob(
        scope: OCRJobScope,
        qualityMode: OCRJobQualityMode,
        items: [OCRJobItemInput],
        initialState: OCRJobState,
        plannedCount: Int
    ) async throws -> OCRJob {
        try openIfNeeded()
        let now = Date()
        let job = OCRJob(
            id: UUID().uuidString,
            scope: scope,
            qualityMode: qualityMode,
            state: initialState,
            createdAt: now,
            updatedAt: now,
            currentPhase: .selectingTargets,
            currentAssetIdentifier: nil,
            startedAt: nil,
            lastHeartbeatAt: now,
            totalCount: plannedCount,
            completedCount: 0,
            textFoundCount: 0,
            noTextCount: 0,
            skippedCount: 0,
            cloudPendingCount: 0,
            failedCount: 0,
            pausedReason: nil
        )

        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try upsertJob(job)
            for input in items {
                let item = OCRJobItem(
                    jobID: job.id,
                    assetIdentifier: input.assetIdentifier,
                    priority: input.priority,
                    state: .pending,
                    attemptCount: 0,
                    nextRetryAt: nil,
                    sourceFingerprint: input.sourceFingerprint,
                    lastErrorCode: nil,
                    startedAt: nil,
                    completedAt: nil
                )
                try upsertItem(item)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }

        return job
    }

    func replaceItems(jobID: String, items: [OCRJobItemInput]) async throws -> OCRJob? {
        try openIfNeeded()
        let now = Date()
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try execute("DELETE FROM ocr_job_items WHERE job_identifier = ?", bindings: [.text(jobID)])
            for input in items {
                let item = OCRJobItem(
                    jobID: jobID,
                    assetIdentifier: input.assetIdentifier,
                    priority: input.priority,
                    state: .pending,
                    attemptCount: 0,
                    nextRetryAt: nil,
                    sourceFingerprint: input.sourceFingerprint,
                    lastErrorCode: nil,
                    startedAt: nil,
                    completedAt: nil
                )
                try upsertItem(item)
            }
            try execute("""
            UPDATE ocr_jobs
            SET state = ?, total_count = ?, current_phase = ?, last_heartbeat_at = ?, updated_at = ?
            WHERE job_identifier = ?
            """, bindings: [
                .text(OCRJobState.pending.rawValue),
                .int(items.count),
                .text(OCRCurrentPhase.selectingTargets.rawValue),
                .date(now),
                .date(now),
                .text(jobID)
            ])
            let job = try recomputeJobCounts(jobID: jobID, forcedState: .pending, pausedReason: nil)
            try execute("COMMIT")
            return job
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func job(id: String) async throws -> OCRJob? {
        try openIfNeeded()
        return try jobs(whereClause: "job_identifier = ?", bindings: [.text(id)], orderAndLimit: "LIMIT 1").first
    }

    func pendingItem(jobID: String) async throws -> OCRJobItem? {
        try openIfNeeded()
        return try items(
            whereClause: "job_identifier = ? AND state IN (?, ?)",
            bindings: [
                .text(jobID),
                .text(OCRJobItemState.pending.rawValue),
                .text(OCRJobItemState.retryableFailure.rawValue)
            ],
            orderAndLimit: "ORDER BY priority ASC, attempt_count ASC, asset_identifier ASC LIMIT 1"
        ).first
    }

    func setJobState(_ state: OCRJobState, jobID: String, pausedReason: String? = nil) async throws -> OCRJob? {
        try openIfNeeded()
        let now = Date()
        let startedAtAssignment = state == .running || state == .throttled ? ", started_at = COALESCE(started_at, ?)" : ""
        let startedAtBindings: [BindingValue] = state == .running || state == .throttled ? [.date(now)] : []
        let clearsWorkerState = state == .completed || state == .cancelled || state == .failed
        let workerStateAssignment = clearsWorkerState ? ", current_phase = NULL, current_asset_identifier = NULL" : ""
        try execute("""
        UPDATE ocr_jobs
        SET state = ?, paused_reason = ?, updated_at = ?, last_heartbeat_at = ?\(startedAtAssignment)\(workerStateAssignment)
        WHERE job_identifier = ?
        """, bindings: [
            .text(state.rawValue),
            .nullableText(pausedReason),
            .date(now),
            .date(now)
        ] + startedAtBindings + [
            .text(jobID)
        ])
        return try await job(id: jobID)
    }

    func completeJob(jobID: String) async throws -> OCRJob? {
        try openIfNeeded()
        let now = Date()
        try execute("""
        UPDATE ocr_jobs
        SET state = ?, paused_reason = NULL, current_phase = NULL, current_asset_identifier = NULL, last_heartbeat_at = ?, updated_at = ?
        WHERE job_identifier = ?
        """, bindings: [
            .text(OCRJobState.completed.rawValue),
            .date(now),
            .date(now),
            .text(jobID)
        ])
        return try recomputeJobCounts(jobID: jobID, forcedState: .completed, pausedReason: nil)
    }

    func updateHeartbeat(
        jobID: String,
        phase: OCRCurrentPhase,
        assetIdentifier: String? = nil,
        state: OCRJobState? = nil,
        pausedReason: String? = nil
    ) async throws -> OCRJob? {
        try openIfNeeded()
        let now = Date()
        var assignments = "current_phase = ?, current_asset_identifier = ?, last_heartbeat_at = ?, updated_at = ?"
        var bindings: [BindingValue] = [
            .text(phase.rawValue),
            .nullableText(assetIdentifier),
            .date(now),
            .date(now)
        ]
        if let state {
            assignments += ", state = ?"
            bindings.append(.text(state.rawValue))
        }
        if let pausedReason {
            assignments += ", paused_reason = ?"
            bindings.append(.nullableText(pausedReason))
        }
        bindings.append(.text(jobID))
        try execute("""
        UPDATE ocr_jobs
        SET \(assignments)
        WHERE job_identifier = ?
        """, bindings: bindings)
        return try await job(id: jobID)
    }

    func startItem(_ item: OCRJobItem, state: OCRJobItemState) async throws {
        try openIfNeeded()
        try execute("""
        UPDATE ocr_job_items
        SET state = ?, attempt_count = attempt_count + 1, started_at = ?, last_error = NULL
        WHERE job_identifier = ? AND asset_identifier = ?
        """, bindings: [
            .text(state.rawValue),
            .date(Date()),
            .text(item.jobID),
            .text(item.assetIdentifier)
        ])
    }

    func finishItem(
        jobID: String,
        assetIdentifier: String,
        state: OCRJobItemState,
        errorCode: String? = nil,
        nextRetryAt: Date? = nil
    ) async throws -> OCRJob? {
        try openIfNeeded()
        try execute("""
        UPDATE ocr_job_items
        SET state = ?, last_error = ?, next_retry_at = ?, completed_at = ?
        WHERE job_identifier = ? AND asset_identifier = ?
        """, bindings: [
            .text(state.rawValue),
            .nullableText(errorCode),
            .nullableDate(nextRetryAt),
            .date(Date()),
            .text(jobID),
            .text(assetIdentifier)
        ])

        return try recomputeJobCounts(jobID: jobID)
    }

    func upsertResult(_ result: PersistentOCRResult) async throws {
        try openIfNeeded()
        try withStatement("""
        INSERT OR REPLACE INTO ocr_results (
            asset_identifier,
            raw_text,
            normalized_text,
            result_state,
            engine_version,
            recognition_profile_version,
            source_fingerprint,
            updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """) { statement in
            try bindText(statement, 1, result.assetIdentifier)
            try bindText(statement, 2, result.rawText)
            try bindText(statement, 3, result.normalizedText)
            try bindText(statement, 4, result.resultState.rawValue)
            try bindText(statement, 5, result.engineVersion)
            try bindText(statement, 6, result.recognitionProfileVersion)
            try bindText(statement, 7, result.sourceFingerprint)
            try bindDate(statement, 8, result.updatedAt)
            try stepDone(statement)
        }
    }

    func cancelJob(jobID: String) async throws -> OCRJob? {
        try openIfNeeded()
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try execute("""
            UPDATE ocr_job_items
            SET state = ?, completed_at = ?
            WHERE job_identifier = ? AND state IN (?, ?, ?, ?)
            """, bindings: [
                .text(OCRJobItemState.cancelled.rawValue),
                .date(Date()),
                .text(jobID),
                .text(OCRJobItemState.pending.rawValue),
                .text(OCRJobItemState.retryableFailure.rawValue),
                .text(OCRJobItemState.fetchingImage.rawValue),
                .text(OCRJobItemState.recognizing.rawValue)
            ])
            let job = try recomputeJobCounts(jobID: jobID, forcedState: .cancelled, pausedReason: "ユーザー操作で終了しました")
            try execute("COMMIT")
            return job
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func retryFailures(jobID: String) async throws -> OCRJob? {
        try openIfNeeded()
        try execute("""
        UPDATE ocr_job_items
        SET state = ?, next_retry_at = NULL, last_error = NULL, completed_at = NULL
        WHERE job_identifier = ? AND state IN (?, ?)
        """, bindings: [
            .text(OCRJobItemState.pending.rawValue),
            .text(jobID),
            .text(OCRJobItemState.retryableFailure.rawValue),
            .text(OCRJobItemState.permanentFailure.rawValue)
        ])

        return try recomputeJobCounts(jobID: jobID, forcedState: .pending, pausedReason: nil)
    }

    func retryCloudPending(jobID: String) async throws -> OCRJob? {
        try openIfNeeded()
        try execute("""
        UPDATE ocr_job_items
        SET state = ?, last_error = NULL, completed_at = NULL
        WHERE job_identifier = ? AND state = ?
        """, bindings: [
            .text(OCRJobItemState.pending.rawValue),
            .text(jobID),
            .text(OCRJobItemState.cloudPending.rawValue)
        ])

        return try recomputeJobCounts(jobID: jobID, forcedState: .pending, pausedReason: nil)
    }

    private func recomputeJobCounts(
        jobID: String,
        forcedState: OCRJobState? = nil,
        pausedReason: String? = nil
    ) throws -> OCRJob? {
        guard var job = try jobs(whereClause: "job_identifier = ?", bindings: [.text(jobID)], orderAndLimit: "LIMIT 1").first else {
            return nil
        }

        let counts = try itemStateCounts(jobID: jobID)
        job.textFoundCount = counts[.completedText, default: 0]
        job.noTextCount = counts[.completedNoText, default: 0]
        job.skippedCount = counts[.skipped, default: 0]
        job.cloudPendingCount = counts[.cloudPending, default: 0]
        job.failedCount = counts[.retryableFailure, default: 0] + counts[.permanentFailure, default: 0]
        job.completedCount = job.succeededCount
        job.updatedAt = Date()
        job.pausedReason = pausedReason

        if let forcedState {
            job.state = forcedState
            if forcedState.isActive == false {
                job.currentPhase = nil
                job.currentAssetIdentifier = nil
            }
        } else if job.terminalCount >= job.totalCount {
            job.state = .completed
            job.pausedReason = nil
            job.currentPhase = nil
            job.currentAssetIdentifier = nil
        } else if job.state == .pending {
            job.state = .running
        }

        try upsertJob(job)
        return job
    }

    private func itemStateCounts(jobID: String) throws -> [OCRJobItemState: Int] {
        var counts: [OCRJobItemState: Int] = [:]
        try withStatement("""
        SELECT state, COUNT(*)
        FROM ocr_job_items
        WHERE job_identifier = ?
        GROUP BY state
        """) { statement in
            try bindText(statement, 1, jobID)
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let rawPointer = sqlite3_column_text(statement, 0),
                      let state = OCRJobItemState(rawValue: String(cString: rawPointer)) else {
                    continue
                }
                counts[state] = Int(sqlite3_column_int64(statement, 1))
            }
        }
        return counts
    }

    private func openIfNeeded() throws {
        try prepareDatabaseIfNeededSync()
    }

    private func openConnectionIfNeeded() throws {
        guard didOpen == false else {
            return
        }

        let directoryURL = databaseURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

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
    }

    private func prepareDatabaseIfNeededSync() throws {
        try openConnectionIfNeeded()

        if didPrepareDatabase {
            let jobsExists = try tableExists("ocr_jobs")
            let itemsExists = try tableExists("ocr_job_items")
            if jobsExists, itemsExists {
                return
            }
            didPrepareDatabase = false
        }

        do {
            try createSchema()
            let jobsExists = try tableExists("ocr_jobs")
            let itemsExists = try tableExists("ocr_job_items")
            guard jobsExists, itemsExists else {
                throw StoreError.prepareFailed("required tables missing: ocr_jobs=\(jobsExists), ocr_job_items=\(itemsExists)")
            }
            didPrepareDatabase = true
            lastMigrationAt = Date()
        } catch {
            didPrepareDatabase = false
            throw error
        }
    }

    private func databaseDiagnosticsSync(status: OCRJobDatabaseStatus, lastError: String?) throws -> OCRJobDatabaseDiagnostics {
        let jobsExists = try tableExists("ocr_jobs")
        let itemsExists = try tableExists("ocr_job_items")
        let resolvedStatus: OCRJobDatabaseStatus
        if status == .repairFailed {
            resolvedStatus = .repairFailed
        } else if jobsExists, itemsExists {
            resolvedStatus = status
        } else {
            resolvedStatus = .missingTable
        }
        return OCRJobDatabaseDiagnostics(
            status: resolvedStatus,
            lastError: lastError,
            lastMigrationAt: lastMigrationAt,
            ocrJobsTableExists: jobsExists,
            ocrJobItemsTableExists: itemsExists
        )
    }

    private func createSchema() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS ocr_jobs (
            job_identifier TEXT PRIMARY KEY NOT NULL,
            scope TEXT NOT NULL,
            quality_mode TEXT NOT NULL,
            state TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            current_phase TEXT,
            current_asset_identifier TEXT,
            started_at REAL,
            last_heartbeat_at REAL,
            total_count INTEGER NOT NULL,
            completed_count INTEGER NOT NULL,
            text_found_count INTEGER NOT NULL,
            no_text_count INTEGER NOT NULL,
            skipped_count INTEGER NOT NULL,
            cloud_pending_count INTEGER NOT NULL,
            failed_count INTEGER NOT NULL,
            paused_reason TEXT
        )
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS ocr_job_items (
            job_identifier TEXT NOT NULL,
            asset_identifier TEXT NOT NULL,
            priority INTEGER NOT NULL,
            state TEXT NOT NULL,
            attempt_count INTEGER NOT NULL,
            next_retry_at REAL,
            source_fingerprint TEXT NOT NULL,
            last_error TEXT,
            started_at REAL,
            completed_at REAL,
            PRIMARY KEY (job_identifier, asset_identifier)
        )
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS ocr_results (
            asset_identifier TEXT PRIMARY KEY NOT NULL,
            raw_text TEXT NOT NULL,
            normalized_text TEXT NOT NULL,
            result_state TEXT NOT NULL,
            engine_version TEXT NOT NULL,
            recognition_profile_version TEXT NOT NULL,
            source_fingerprint TEXT NOT NULL,
            updated_at REAL NOT NULL
        )
        """)

        try migrateExistingSchema()

        try execute("CREATE INDEX IF NOT EXISTS idx_ocr_jobs_state ON ocr_jobs(state, updated_at)")
        try execute("CREATE INDEX IF NOT EXISTS idx_ocr_items_state ON ocr_job_items(job_identifier, state, priority)")
        try execute("CREATE INDEX IF NOT EXISTS idx_ocr_job_items_asset ON ocr_job_items(asset_identifier)")
        try execute("CREATE INDEX IF NOT EXISTS idx_ocr_results_state ON ocr_results(result_state)")
    }

    private func migrateExistingSchema() throws {
        try addColumnIfMissing(table: "ocr_jobs", column: "job_identifier", definition: "TEXT NOT NULL DEFAULT ''")
        try addColumnIfMissing(table: "ocr_jobs", column: "scope", definition: "TEXT NOT NULL DEFAULT '\(OCRJobScope.smartFull.rawValue)'")
        try addColumnIfMissing(table: "ocr_jobs", column: "quality_mode", definition: "TEXT NOT NULL DEFAULT '\(OCRJobQualityMode.standard.rawValue)'")
        try addColumnIfMissing(table: "ocr_jobs", column: "state", definition: "TEXT NOT NULL DEFAULT '\(OCRJobState.pending.rawValue)'")
        try addColumnIfMissing(table: "ocr_jobs", column: "created_at", definition: "REAL NOT NULL DEFAULT 0")
        try addColumnIfMissing(table: "ocr_jobs", column: "updated_at", definition: "REAL NOT NULL DEFAULT 0")
        try addColumnIfMissing(table: "ocr_jobs", column: "current_phase", definition: "TEXT")
        try addColumnIfMissing(table: "ocr_jobs", column: "current_asset_identifier", definition: "TEXT")
        try addColumnIfMissing(table: "ocr_jobs", column: "started_at", definition: "REAL")
        try addColumnIfMissing(table: "ocr_jobs", column: "last_heartbeat_at", definition: "REAL")
        try addColumnIfMissing(table: "ocr_jobs", column: "total_count", definition: "INTEGER NOT NULL DEFAULT 0")
        try addColumnIfMissing(table: "ocr_jobs", column: "completed_count", definition: "INTEGER NOT NULL DEFAULT 0")
        try addColumnIfMissing(table: "ocr_jobs", column: "text_found_count", definition: "INTEGER NOT NULL DEFAULT 0")
        try addColumnIfMissing(table: "ocr_jobs", column: "no_text_count", definition: "INTEGER NOT NULL DEFAULT 0")
        try addColumnIfMissing(table: "ocr_jobs", column: "skipped_count", definition: "INTEGER NOT NULL DEFAULT 0")
        try addColumnIfMissing(table: "ocr_jobs", column: "cloud_pending_count", definition: "INTEGER NOT NULL DEFAULT 0")
        try addColumnIfMissing(table: "ocr_jobs", column: "failed_count", definition: "INTEGER NOT NULL DEFAULT 0")
        try addColumnIfMissing(table: "ocr_jobs", column: "paused_reason", definition: "TEXT")

        try addColumnIfMissing(table: "ocr_job_items", column: "job_identifier", definition: "TEXT NOT NULL DEFAULT ''")
        try addColumnIfMissing(table: "ocr_job_items", column: "asset_identifier", definition: "TEXT NOT NULL DEFAULT ''")
        try addColumnIfMissing(table: "ocr_job_items", column: "priority", definition: "INTEGER NOT NULL DEFAULT 0")
        try addColumnIfMissing(table: "ocr_job_items", column: "state", definition: "TEXT NOT NULL DEFAULT '\(OCRJobItemState.pending.rawValue)'")
        try addColumnIfMissing(table: "ocr_job_items", column: "attempt_count", definition: "INTEGER NOT NULL DEFAULT 0")
        try addColumnIfMissing(table: "ocr_job_items", column: "next_retry_at", definition: "REAL")
        try addColumnIfMissing(table: "ocr_job_items", column: "source_fingerprint", definition: "TEXT NOT NULL DEFAULT ''")
        try addColumnIfMissing(table: "ocr_job_items", column: "last_error", definition: "TEXT")
        try addColumnIfMissing(table: "ocr_job_items", column: "started_at", definition: "REAL")
        try addColumnIfMissing(table: "ocr_job_items", column: "completed_at", definition: "REAL")

        try addColumnIfMissing(table: "ocr_results", column: "asset_identifier", definition: "TEXT NOT NULL DEFAULT ''")
        try addColumnIfMissing(table: "ocr_results", column: "raw_text", definition: "TEXT NOT NULL DEFAULT ''")
        try addColumnIfMissing(table: "ocr_results", column: "normalized_text", definition: "TEXT NOT NULL DEFAULT ''")
        try addColumnIfMissing(table: "ocr_results", column: "result_state", definition: "TEXT NOT NULL DEFAULT '\(OCRJobItemState.completedText.rawValue)'")
        try addColumnIfMissing(table: "ocr_results", column: "engine_version", definition: "TEXT NOT NULL DEFAULT ''")
        try addColumnIfMissing(table: "ocr_results", column: "recognition_profile_version", definition: "TEXT NOT NULL DEFAULT ''")
        try addColumnIfMissing(table: "ocr_results", column: "source_fingerprint", definition: "TEXT NOT NULL DEFAULT ''")
        try addColumnIfMissing(table: "ocr_results", column: "updated_at", definition: "REAL NOT NULL DEFAULT 0")
    }

    private func upsertJob(_ job: OCRJob) throws {
        try withStatement("""
        INSERT OR REPLACE INTO ocr_jobs (
            job_identifier,
            scope,
            quality_mode,
            state,
            created_at,
            updated_at,
            current_phase,
            current_asset_identifier,
            started_at,
            last_heartbeat_at,
            total_count,
            completed_count,
            text_found_count,
            no_text_count,
            skipped_count,
            cloud_pending_count,
            failed_count,
            paused_reason
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """) { statement in
            try bindText(statement, 1, job.id)
            try bindText(statement, 2, job.scope.rawValue)
            try bindText(statement, 3, job.qualityMode.rawValue)
            try bindText(statement, 4, job.state.rawValue)
            try bindDate(statement, 5, job.createdAt)
            try bindDate(statement, 6, job.updatedAt)
            try bindNullableText(statement, 7, job.currentPhase?.rawValue)
            try bindNullableText(statement, 8, job.currentAssetIdentifier)
            try bindNullableDate(statement, 9, job.startedAt)
            try bindDate(statement, 10, job.lastHeartbeatAt)
            try bindInt(statement, 11, job.totalCount)
            try bindInt(statement, 12, job.completedCount)
            try bindInt(statement, 13, job.textFoundCount)
            try bindInt(statement, 14, job.noTextCount)
            try bindInt(statement, 15, job.skippedCount)
            try bindInt(statement, 16, job.cloudPendingCount)
            try bindInt(statement, 17, job.failedCount)
            try bindNullableText(statement, 18, job.pausedReason)
            try stepDone(statement)
        }
    }

    private func upsertItem(_ item: OCRJobItem) throws {
        try withStatement("""
        INSERT OR REPLACE INTO ocr_job_items (
            job_identifier,
            asset_identifier,
            priority,
            state,
            attempt_count,
            next_retry_at,
            source_fingerprint,
            last_error,
            started_at,
            completed_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """) { statement in
            try bindText(statement, 1, item.jobID)
            try bindText(statement, 2, item.assetIdentifier)
            try bindInt(statement, 3, item.priority)
            try bindText(statement, 4, item.state.rawValue)
            try bindInt(statement, 5, item.attemptCount)
            try bindNullableDate(statement, 6, item.nextRetryAt)
            try bindText(statement, 7, item.sourceFingerprint)
            try bindNullableText(statement, 8, item.lastErrorCode)
            try bindNullableDate(statement, 9, item.startedAt)
            try bindNullableDate(statement, 10, item.completedAt)
            try stepDone(statement)
        }
    }

    private func jobs(whereClause: String?, bindings: [BindingValue], orderAndLimit: String) throws -> [OCRJob] {
        var sql = "SELECT job_identifier, scope, quality_mode, state, created_at, updated_at, current_phase, current_asset_identifier, started_at, last_heartbeat_at, total_count, completed_count, text_found_count, no_text_count, skipped_count, cloud_pending_count, failed_count, paused_reason FROM ocr_jobs"
        if let whereClause {
            sql += " WHERE \(whereClause)"
        }
        sql += " \(orderAndLimit)"

        var jobs: [OCRJob] = []
        try withStatement(sql) { statement in
            try bind(bindings, to: statement)
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let id = text(statement, 0),
                      let scope = text(statement, 1).flatMap(OCRJobScope.init(rawValue:)),
                      let qualityMode = text(statement, 2).flatMap(OCRJobQualityMode.init(rawValue:)),
                      let state = text(statement, 3).flatMap(OCRJobState.init(rawValue:)) else {
                    continue
                }

                jobs.append(OCRJob(
                    id: id,
                    scope: scope,
                    qualityMode: qualityMode,
                    state: state,
                    createdAt: date(statement, 4) ?? Date(),
                    updatedAt: date(statement, 5) ?? Date(),
                    currentPhase: text(statement, 6).flatMap(OCRCurrentPhase.init(rawValue:)),
                    currentAssetIdentifier: text(statement, 7),
                    startedAt: date(statement, 8),
                    lastHeartbeatAt: date(statement, 9) ?? date(statement, 5) ?? Date(),
                    totalCount: int(statement, 10),
                    completedCount: int(statement, 11),
                    textFoundCount: int(statement, 12),
                    noTextCount: int(statement, 13),
                    skippedCount: int(statement, 14),
                    cloudPendingCount: int(statement, 15),
                    failedCount: int(statement, 16),
                    pausedReason: text(statement, 17)
                ))
            }
        }
        return jobs
    }

    private func items(whereClause: String?, bindings: [BindingValue], orderAndLimit: String) throws -> [OCRJobItem] {
        var sql = "SELECT job_identifier, asset_identifier, priority, state, attempt_count, next_retry_at, source_fingerprint, last_error, started_at, completed_at FROM ocr_job_items"
        if let whereClause {
            sql += " WHERE \(whereClause)"
        }
        sql += " \(orderAndLimit)"

        var items: [OCRJobItem] = []
        try withStatement(sql) { statement in
            try bind(bindings, to: statement)
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let jobID = text(statement, 0),
                      let assetIdentifier = text(statement, 1),
                      let state = text(statement, 3).flatMap(OCRJobItemState.init(rawValue:)),
                      let sourceFingerprint = text(statement, 6) else {
                    continue
                }

                items.append(OCRJobItem(
                    jobID: jobID,
                    assetIdentifier: assetIdentifier,
                    priority: int(statement, 2),
                    state: state,
                    attemptCount: int(statement, 4),
                    nextRetryAt: date(statement, 5),
                    sourceFingerprint: sourceFingerprint,
                    lastErrorCode: text(statement, 7),
                    startedAt: date(statement, 8),
                    completedAt: date(statement, 9)
                ))
            }
        }
        return items
    }

    private enum BindingValue {
        case text(String)
        case nullableText(String?)
        case int(Int)
        case date(Date)
        case nullableDate(Date?)
    }

    private func addColumnIfMissing(table: String, column: String, definition: String) throws {
        let columns = try tableColumns(table)
        guard columns.contains(column) == false else {
            return
        }
        try execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
    }

    private func tableColumns(_ table: String) throws -> Set<String> {
        var columns = Set<String>()
        try withStatement("PRAGMA table_info(\(table))") { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                if let rawPointer = sqlite3_column_text(statement, 1) {
                    columns.insert(String(cString: rawPointer))
                }
            }
        }
        return columns
    }

    private func tableExists(_ table: String) throws -> Bool {
        var exists = false
        try withStatement("""
        SELECT name FROM sqlite_master
        WHERE type = 'table' AND name = ?
        LIMIT 1
        """) { statement in
            try bindText(statement, 1, table)
            exists = sqlite3_step(statement) == SQLITE_ROW
        }
        return exists
    }

    private func isMissingTableError(_ error: Error) -> Bool {
        error.localizedDescription.localizedCaseInsensitiveContains("no such table")
    }

    private func execute(_ sql: String, bindings: [BindingValue] = []) throws {
        try withStatement(sql) { statement in
            try bind(bindings, to: statement)
            try stepDone(statement)
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

    private func bind(_ values: [BindingValue], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let value):
                try bindText(statement, index, value)
            case .nullableText(let value):
                try bindNullableText(statement, index, value)
            case .int(let value):
                try bindInt(statement, index, value)
            case .date(let value):
                try bindDate(statement, index, value)
            case .nullableDate(let value):
                try bindNullableDate(statement, index, value)
            }
        }
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

    private func bindInt(_ statement: OpaquePointer, _ index: Int32, _ value: Int) throws {
        guard sqlite3_bind_int64(statement, index, sqlite3_int64(value)) == SQLITE_OK else {
            throw StoreError.bindFailed(databaseMessage)
        }
    }

    private func bindDate(_ statement: OpaquePointer, _ index: Int32, _ value: Date) throws {
        guard sqlite3_bind_double(statement, index, value.timeIntervalSince1970) == SQLITE_OK else {
            throw StoreError.bindFailed(databaseMessage)
        }
    }

    private func bindNullableDate(_ statement: OpaquePointer, _ index: Int32, _ value: Date?) throws {
        guard let value else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
                throw StoreError.bindFailed(databaseMessage)
            }
            return
        }

        try bindDate(statement, index, value)
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let rawPointer = sqlite3_column_text(statement, column) else {
            return nil
        }
        return String(cString: rawPointer)
    }

    private func int(_ statement: OpaquePointer, _ column: Int32) -> Int {
        Int(sqlite3_column_int64(statement, column))
    }

    private func date(_ statement: OpaquePointer, _ column: Int32) -> Date? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
            return nil
        }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
    }
}

nonisolated(unsafe) private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
