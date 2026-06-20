import SwiftUI
import UIKit

struct ReadView: View {
    @ObservedObject var photoLibrary: PhotoLibraryService
    @ObservedObject var ocrService: OCRService
    @ObservedObject var indexService: PhotoIndexService
    @ObservedObject var batchOCRJobService: BatchOCRJobService
    @ObservedObject var deviceSafety: DeviceSafetyService

    @State private var selectedLimit: ReadBatchLimit = .oneHundred
    @State private var showsTwoThousandConfirmation = false

    private var summary: PhotoIndexSummary {
        indexService.indexSummary
    }

    private var startDisabledReason: String? {
        if batchOCRJobService.canResumeCurrentJob {
            return "一時停止中の読取があります"
        }

        if batchOCRJobService.isRunning {
            return "読取を実行中です"
        }

        if selectedLimit.requiresLargeWorkSafety,
           let blockingReason = deviceSafety.blockingReasonForLargeWork {
            return blockingReason
        }

        if photoLibrary.canReadPhotos == false {
            return "写真アクセスを許可してください"
        }

        if photoLibrary.assets.isEmpty {
            return "読み込み済み写真がありません"
        }

        return nil
    }

    private var canStartReading: Bool {
        startDisabledReason == nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        headerCard
                        metricsGrid
                        batchLimitCard
                        targetDiagnosticsCard
                        jobStatusCard
                        #if DEBUG
                        readStateDiagnosticsCard
                        debugValidationCard
                        #endif
                        IndexStoreStatusContainer()
                        safetyCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 96)
                }
            }
            .navigationTitle("文字を読み取る")
            .navigationBarTitleDisplayMode(.inline)
            .alert("2,000件の読取を開始しますか？", isPresented: $showsTwoThousandConfirmation) {
                Button("キャンセル", role: .cancel) {}
                Button("2,000件を開始") {
                    Task {
                        await startSelectedLimit()
                    }
                }
            } message: {
                Text("2,000件の読取は時間がかかります。端末の温度や電池残量により、自動的に一時停止する場合があります。元写真・元動画は変更されません。")
            }
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("読取", systemImage: "text.viewfinder")
                .font(.headline)
                .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))

            Text("写真内の文字を端末内で読み取り、あとから検索できるようにします。元写真・元動画は変更されません。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
    }

    private var metricsGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10)
            ],
            alignment: .leading,
            spacing: 10
        ) {
            ReadMetricCard(title: "読取済み", value: "\(summary.completedOCRCount)件", systemImage: "checkmark.circle")
            ReadMetricCard(title: "未読取", value: "\(summary.unprocessedOCRCount)件", systemImage: "text.viewfinder")
            ReadMetricCard(title: "文字あり", value: "\(ocrService.storedCompletedTextCount)件", systemImage: "doc.text.magnifyingglass")
            ReadMetricCard(title: "文字なし", value: "\(ocrService.storedCompletedNoTextCount)件", systemImage: "doc")
            ReadMetricCard(title: "失敗", value: "\(summary.failedOCRCount)件", systemImage: "exclamationmark.triangle")
            ReadMetricCard(title: "検索データ", value: "\(summary.indexedCount)件", systemImage: "magnifyingglass")
        }
    }

    private var batchLimitCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("まとめて文字を読み取る")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))

                Text("選択した上限まで対象を固定して処理します。2,000件を超えて自動継続しません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ReadBatchLimit.allCases) { limit in
                        ReadLimitChip(
                            title: limit.title,
                            systemImage: limit.systemImage,
                            isSelected: selectedLimit == limit
                        ) {
                            selectedLimit = limit
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(height: 44)
            .clipped()

            HStack(spacing: 10) {
                Button {
                    deviceSafety.refresh()
                    if selectedLimit == .twoThousand {
                        showsTwoThousandConfirmation = true
                    } else {
                        Task {
                            await startSelectedLimit()
                        }
                    }
                } label: {
                    Label("まとめて文字を読み取る", systemImage: "play.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(canStartReading == false)

                Menu {
                    Button("続きから再開") {}
                        .disabled(true)
                    Button("失敗分の再試行") {}
                        .disabled(true)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(width: 38, height: 34)
                }
                .buttonStyle(.bordered)
                .disabled(true)
            }

            if let startDisabledReason {
                Label(startDisabledReason, systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("写真タブでは読取処理を開始しません。読取タブから選択した上限までだけ処理します。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let message = batchOCRJobService.message {
                Label(message, systemImage: "checkmark.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(red: 0.16, green: 0.42, blue: 0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let errorMessage = batchOCRJobService.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(red: 0.75, green: 0.24, blue: 0.18))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var targetDiagnosticsCard: some View {
        if let diagnostics = batchOCRJobService.latestTargetDiagnostics {
            VStack(alignment: .leading, spacing: 8) {
                Label("対象抽出", systemImage: "line.3.horizontal.decrease.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))

                VStack(alignment: .leading, spacing: 5) {
                    ReadJobRow(title: "選択上限", value: "\(diagnostics.selectedLimit)件")
                    ReadJobRow(title: "候補", value: "\(diagnostics.candidateBeforeExclusion)件")
                    ReadJobRow(title: "読取済み除外", value: "\(diagnostics.excludedAlreadyRead)件")
                    ReadJobRow(title: "文字なし除外", value: "\(diagnostics.excludedCompletedNoText)件")
                    ReadJobRow(title: "処理中除外", value: "\(diagnostics.excludedInProgress)件")
                    ReadJobRow(title: "失敗確定除外", value: "\(diagnostics.excludedFailedPermanent)件")
                    ReadJobRow(title: "検索データのみ", value: "\(diagnostics.searchDataOnlyCandidateCount)件")
                    ReadJobRow(title: "古い状態を候補へ戻す", value: "\(diagnostics.staleCacheCandidateCount)件")
                    ReadJobRow(title: "今回対象", value: "\(diagnostics.finalTargetCount)件")
                }

                if let reason = diagnostics.reasonIfZero {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var jobStatusCard: some View {
        if let job = batchOCRJobService.currentJob {
            VStack(alignment: .leading, spacing: 10) {
                Label(batchOCRJobService.activeStatusTitle, systemImage: icon(for: job.state))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))

                ProgressView(value: job.progress)
                    .tint(Color(red: 0.16, green: 0.42, blue: 0.75))

                VStack(alignment: .leading, spacing: 6) {
                    ReadJobRow(title: "処理済み", value: "\(job.processedCount) / \(job.plannedCount)件")
                    ReadJobRow(title: "残り", value: "\(batchOCRJobService.remainingCount)件")
                    ReadJobRow(title: "文字あり", value: "\(job.completedTextCount)件")
                    ReadJobRow(title: "文字なし", value: "\(job.completedNoTextCount)件")
                    ReadJobRow(title: "失敗", value: "\(job.failedCount)件")
                    ReadJobRow(title: "上限", value: "\(job.requestedLimit)件")
                }

                if let pausedReason = job.pausedReason {
                    Text(pausedReason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if job.state == .running || job.state == .preparing {
                    HStack(spacing: 10) {
                        Button("一時停止") {
                            batchOCRJobService.pauseByUser()
                        }
                        .buttonStyle(.bordered)

                        Text("完了済みの読取結果は保存されます。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else if job.state == .pausedBackground || job.state == .pausedUser {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("完了済みの読取結果は保存されています。未処理分だけ続きから再開できます。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 10) {
                            Button {
                                Task {
                                    await batchOCRJobService.resumePausedJob(
                                        assets: photoLibrary.assets,
                                        photoLibrary: photoLibrary,
                                        ocrService: ocrService,
                                        indexService: indexService,
                                        deviceSafety: deviceSafety
                                    )
                                }
                            } label: {
                                Label("続きから再開", systemImage: "play.circle")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(batchOCRJobService.canResumeCurrentJob == false)

                            Button(role: .destructive) {
                                Task {
                                    await batchOCRJobService.finishPausedJob()
                                }
                            } label: {
                                Text("この処理を終了")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("最新の読取ジョブ", systemImage: "tray")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))

                Text("読取ジョブはまだありません。読取を開始すると、状態、対象件数、処理済み件数、文字あり、文字なし、失敗件数がここに表示されます。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    #if DEBUG
    private var readStateDiagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("読取状態診断", systemImage: "stethoscope")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))

            Text("DEBUGビルド限定です。読取対象の内訳だけを確認します。OCR結果、検索データ、分類、メモ、タグは削除しません。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    Task {
                        await batchOCRJobService.runReadStateDiagnostics(
                            assets: photoLibrary.assets,
                            ocrService: ocrService,
                            indexService: indexService
                        )
                    }
                } label: {
                    Label("診断する", systemImage: "waveform.path.ecg")
                }
                .buttonStyle(.borderedProminent)
                .disabled(batchOCRJobService.isRunningReadStateDiagnostics)

                Button {
                    if let text = batchOCRJobService.readStateDiagnosticsReport?.textReport {
                        UIPasteboard.general.string = text
                    }
                } label: {
                    Label("診断結果をコピー", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .disabled(batchOCRJobService.readStateDiagnosticsReport == nil)
            }

            if batchOCRJobService.isRunningReadStateDiagnostics {
                Label("診断中です", systemImage: "hourglass")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if let report = batchOCRJobService.readStateDiagnosticsReport {
                VStack(alignment: .leading, spacing: 6) {
                    ReadJobRow(title: "写真DB件数", value: "\(report.photoDatabaseCount)件")
                    ReadJobRow(title: "検索データ件数", value: "\(report.searchDataCount)件")
                    ReadJobRow(title: "読取結果キャッシュ件数", value: "\(report.readResultCacheCount)件")
                    ReadJobRow(title: "OCR本文あり件数", value: "\(report.ocrTextCount)件")
                    ReadJobRow(title: "文字なし判定済み件数", value: "\(report.completedNoTextCount)件")
                    ReadJobRow(title: "失敗件数", value: "\(report.failedCount)件")
                    ReadJobRow(title: "failedRetryable件数", value: "\(report.failedRetryableCount)件")
                    ReadJobRow(title: "failedPermanent件数", value: "\(report.failedPermanentCount)件")
                    ReadJobRow(title: "検索データだけある件数", value: "\(report.searchDataOnlyCount)件")
                    ReadJobRow(title: "未読取候補件数", value: "\(report.unreadCandidateCount)件")
                    ReadJobRow(title: "処理中ジョブ対象件数", value: "\(report.activeJobTargetCount)件")
                    ReadJobRow(title: "無効/古いジョブ件数", value: "\(report.invalidOrStaleJobCount)件")
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(report.limitDiagnostics) { limit in
                        ReadJobRow(title: "\(limit.selectedLimit)件選択時の対象数", value: "\(limit.targetCount)件")
                    }
                }

                if let primary = report.limitDiagnostics.first(where: { $0.selectedLimit == 2_000 })?.diagnostics {
                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("2,000件選択時の除外内訳")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ReadJobRow(title: "candidateBeforeExclusion", value: "\(primary.candidateBeforeExclusion)")
                        ReadJobRow(title: "excludedAlreadyRead", value: "\(primary.excludedAlreadyRead)")
                        ReadJobRow(title: "excludedCompletedNoText", value: "\(primary.excludedCompletedNoText)")
                        ReadJobRow(title: "excludedInProgress", value: "\(primary.excludedInProgress)")
                        ReadJobRow(title: "excludedSearchDataOnly", value: "\(primary.excludedSearchDataOnly)")
                        ReadJobRow(title: "excludedFailedPermanent", value: "\(primary.excludedFailedPermanent)")
                        ReadJobRow(title: "failedRetryableCount", value: "\(primary.failedRetryableCount)")
                        ReadJobRow(title: "finalTargetCount", value: "\(primary.finalTargetCount)")

                        if let reason = primary.reasonIfZero {
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
    }

    private var debugValidationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("BatchOCR検証", systemImage: "wrench.and.screwdriver")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))

            Text("DEBUGビルド限定です。合成IDだけを使い、元写真・元動画は変更しません。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ],
                spacing: 8
            ) {
                Button("20件読取を検証") {
                    Task {
                        _ = await batchOCRJobService.runP1Validation(limit: 20, ocrService: ocrService)
                    }
                }
                .buttonStyle(.bordered)

                Button("50件読取を検証") {
                    Task {
                        _ = await batchOCRJobService.runP1Validation(limit: 50, ocrService: ocrService)
                    }
                }
                .buttonStyle(.bordered)

                Button("100件読取を検証") {
                    Task {
                        _ = await batchOCRJobService.runP1Validation(limit: 100, ocrService: ocrService)
                    }
                }
                .buttonStyle(.bordered)

                Button("0件対象テスト") {
                    Task {
                        _ = await batchOCRJobService.runZeroTargetValidation()
                    }
                }
                .buttonStyle(.bordered)

                Button("500件読取を検証") {
                    Task {
                        await batchOCRJobService.runP3CompletionValidationOnly(limit: 500, ocrService: ocrService)
                    }
                }
                .buttonStyle(.bordered)

                Button("2,000件読取を検証") {
                    Task {
                        await batchOCRJobService.runP3CompletionValidationOnly(limit: 2_000, ocrService: ocrService)
                    }
                }
                .buttonStyle(.bordered)

                Button("500件中断・再開") {
                    Task {
                        await batchOCRJobService.runP3PauseResumeValidationOnly(limit: 500, ocrService: ocrService)
                    }
                }
                .buttonStyle(.bordered)

                Button("2,000件中断・再開") {
                    Task {
                        await batchOCRJobService.runP3PauseResumeValidationOnly(limit: 2_000, ocrService: ocrService)
                    }
                }
                .buttonStyle(.bordered)

                Button("対象抽出診断") {
                    Task {
                        await batchOCRJobService.refreshTargetDiagnostics(
                            requestedLimit: selectedLimit.rawValue,
                            assets: photoLibrary.assets,
                            ocrService: ocrService,
                            indexService: indexService
                        )
                    }
                }
                .buttonStyle(.bordered)

                Button("読取状態再確認テスト") {
                    Task {
                        _ = await indexService.repairReadState(for: photoLibrary.assets, ocrService: ocrService)
                        _ = await batchOCRJobService.repairInvalidReadJobState()
                        await batchOCRJobService.refreshTargetDiagnostics(
                            requestedLimit: selectedLimit.rawValue,
                            assets: photoLibrary.assets,
                            ocrService: ocrService,
                            indexService: indexService
                        )
                    }
                }
                .buttonStyle(.bordered)
            }
            .disabled(batchOCRJobService.isRunningP1Validation || batchOCRJobService.isRunningP2Validation || batchOCRJobService.isRunningP3Validation || batchOCRJobService.isRunningTargetSelectionValidation || batchOCRJobService.isRunning || batchOCRJobService.canStartNewJob == false)

            Button {
                Task {
                    await batchOCRJobService.runP1ValidationSuite(ocrService: ocrService)
                }
            } label: {
                Label("P1検証をまとめて実行", systemImage: "play.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(batchOCRJobService.isRunningP1Validation || batchOCRJobService.isRunningTargetSelectionValidation || batchOCRJobService.isRunning || batchOCRJobService.canStartNewJob == false)

            Button {
                Task {
                    await batchOCRJobService.runP2ValidationSuite(ocrService: ocrService)
                }
            } label: {
                Label("P2中断・再開検証を実行", systemImage: "arrow.clockwise.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(batchOCRJobService.isRunningP2Validation || batchOCRJobService.isRunningP3Validation || batchOCRJobService.isRunningTargetSelectionValidation || batchOCRJobService.isRunning || batchOCRJobService.canStartNewJob == false)

            Button {
                Task {
                    await batchOCRJobService.runP3ValidationSuite(ocrService: ocrService)
                }
            } label: {
                Label("P3 500/2,000件検証を実行", systemImage: "rectangle.stack.badge.play")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(batchOCRJobService.isRunningP1Validation || batchOCRJobService.isRunningP2Validation || batchOCRJobService.isRunningP3Validation || batchOCRJobService.isRunningTargetSelectionValidation || batchOCRJobService.isRunning || batchOCRJobService.canStartNewJob == false)

            Button {
                Task {
                    await batchOCRJobService.runTargetSelectionValidationSuite()
                }
            } label: {
                Label("対象抽出検証を実行", systemImage: "checklist.checked")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(batchOCRJobService.isRunningTargetSelectionValidation || batchOCRJobService.isRunning || batchOCRJobService.canStartNewJob == false)

            if batchOCRJobService.isRunningP1Validation {
                Label("検証中です", systemImage: "hourglass")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if batchOCRJobService.isRunningP2Validation {
                Label("P2検証中です", systemImage: "hourglass")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if batchOCRJobService.isRunningP3Validation {
                Label("P3検証中です", systemImage: "hourglass")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if batchOCRJobService.isRunningTargetSelectionValidation {
                Label("対象抽出検証中です", systemImage: "hourglass")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if let report = batchOCRJobService.p1ValidationReport {
                VStack(alignment: .leading, spacing: 6) {
                    Label(report.passed ? "最新検証: PASS" : "最新検証: 確認が必要", systemImage: report.passed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(report.passed ? Color(red: 0.07, green: 0.38, blue: 0.24) : Color(red: 0.75, green: 0.24, blue: 0.18))

                    ForEach(report.cases) { result in
                        ReadJobRow(
                            title: result.name,
                            value: result.passed ? "PASS" : "FAIL"
                        )
                    }
                }
                .padding(.top, 4)
            }

            if let report = batchOCRJobService.p2ValidationReport {
                VStack(alignment: .leading, spacing: 6) {
                    Label(report.passed ? "P2検証: PASS" : "P2検証: 確認が必要", systemImage: report.passed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(report.passed ? Color(red: 0.07, green: 0.38, blue: 0.24) : Color(red: 0.75, green: 0.24, blue: 0.18))

                    ForEach(report.cases) { result in
                        ReadJobRow(
                            title: result.name,
                            value: result.passed ? "PASS" : "FAIL"
                        )
                    }
                }
                .padding(.top, 4)
            }

            if let report = batchOCRJobService.p3ValidationReport {
                VStack(alignment: .leading, spacing: 6) {
                    Label(report.passed ? "P3検証: PASS" : "P3検証: 確認が必要", systemImage: report.passed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(report.passed ? Color(red: 0.07, green: 0.38, blue: 0.24) : Color(red: 0.75, green: 0.24, blue: 0.18))

                    ForEach(report.cases) { result in
                        ReadJobRow(
                            title: result.name,
                            value: result.passed ? "PASS" : "FAIL"
                        )
                    }
                }
                .padding(.top, 4)
            }

            if let report = batchOCRJobService.targetSelectionValidationReport {
                VStack(alignment: .leading, spacing: 6) {
                    Label(report.passed ? "対象抽出検証: PASS" : "対象抽出検証: 確認が必要", systemImage: report.passed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(report.passed ? Color(red: 0.07, green: 0.38, blue: 0.24) : Color(red: 0.75, green: 0.24, blue: 0.18))

                    ForEach(report.cases) { result in
                        ReadJobRow(
                            title: result.name,
                            value: result.passed ? "PASS" : "FAIL"
                        )
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
    }
    #endif

    private func icon(for state: BatchOCRJobState) -> String {
        switch state {
        case .preparing:
            "clock"
        case .running:
            "text.viewfinder"
        case .pausing, .pausedBackground, .pausedUser:
            "pause.circle"
        case .cancelling:
            "stop.circle"
        case .completed:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }

    private func startSelectedLimit() async {
        await batchOCRJobService.start(
            requestedLimit: selectedLimit.rawValue,
            assets: photoLibrary.assets,
            photoLibrary: photoLibrary,
            ocrService: ocrService,
            indexService: indexService,
            deviceSafety: deviceSafety
        )
    }

    private var safetyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("安全方針", systemImage: "lock.shield")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))

            ReadSafetyBullet("読取は端末内で実行します")
            ReadSafetyBullet("元写真・元動画は削除・変更されません")
            ReadSafetyBullet("外部APIや外部送信は使いません")
            ReadSafetyBullet("2,000件は長時間の処理として扱います")

            if let blockingReason = deviceSafety.blockingReasonForLargeWork {
                Text(blockingReason)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(red: 0.75, green: 0.24, blue: 0.18))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
        .onAppear {
            deviceSafety.refresh()
        }
    }
}

private enum ReadBatchLimit: Int, CaseIterable, Identifiable {
    case twenty = 20
    case fifty = 50
    case oneHundred = 100
    case fiveHundred = 500
    case twoThousand = 2_000

    var id: Int {
        rawValue
    }

    var title: String {
        switch self {
        case .twenty:
            "20件"
        case .fifty:
            "50件"
        case .oneHundred:
            "100件 おすすめ"
        case .fiveHundred:
            "500件 多め"
        case .twoThousand:
            "2,000件 長時間"
        }
    }

    var systemImage: String {
        switch self {
        case .twenty, .fifty, .oneHundred:
            "text.viewfinder"
        case .fiveHundred:
            "rectangle.stack"
        case .twoThousand:
            "clock.badge.exclamationmark"
        }
    }

    var requiresLargeWorkSafety: Bool {
        rawValue >= 500
    }
}

private struct ReadMetricCard: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(red: 0.16, green: 0.42, blue: 0.75))
                .frame(width: 22, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ReadLimitChip: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .frame(width: 16)

                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .foregroundStyle(isSelected ? .white : Color(red: 0.07, green: 0.18, blue: 0.31))
            .background(
                isSelected ? Color(red: 0.16, green: 0.42, blue: 0.75) : Color.white.opacity(0.82),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .stroke(isSelected ? Color.clear : Color(red: 0.76, green: 0.84, blue: 0.90), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct ReadJobRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }
}

private struct ReadSafetyBullet: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Color(red: 0.07, green: 0.38, blue: 0.24))
                .frame(width: 16)

            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
