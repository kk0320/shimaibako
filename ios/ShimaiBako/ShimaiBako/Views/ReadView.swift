import SwiftUI

struct ReadView: View {
    @ObservedObject var photoLibrary: PhotoLibraryService
    @ObservedObject var ocrService: OCRService
    @ObservedObject var indexService: PhotoIndexService
    @ObservedObject var batchOCRJobService: BatchOCRJobService
    @ObservedObject var deviceSafety: DeviceSafetyService

    @State private var selectedLimit: ReadBatchLimit = .oneHundred

    private var summary: PhotoIndexSummary {
        indexService.indexSummary
    }

    private var startDisabledReason: String? {
        if batchOCRJobService.isRunning {
            return "読取を実行中です"
        }

        if selectedLimit.isEnabledInP1 == false {
            return "500件と2,000件はP3で有効化します"
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
                        jobStatusCard
                        #if DEBUG
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
                    Task {
                        await batchOCRJobService.start(
                            requestedLimit: selectedLimit.rawValue,
                            assets: photoLibrary.assets,
                            photoLibrary: photoLibrary,
                            ocrService: ocrService,
                            indexService: indexService
                        )
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
                        Button("一時停止") {}
                            .buttonStyle(.bordered)
                            .disabled(true)

                        Text("P2で続きから再開に対応します。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
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
    private var debugValidationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("BatchOCR P1検証", systemImage: "wrench.and.screwdriver")
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
            }
            .disabled(batchOCRJobService.isRunningP1Validation || batchOCRJobService.isRunning)

            Button {
                Task {
                    await batchOCRJobService.runP1ValidationSuite(ocrService: ocrService)
                }
            } label: {
                Label("P1検証をまとめて実行", systemImage: "play.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(batchOCRJobService.isRunningP1Validation || batchOCRJobService.isRunning)

            if batchOCRJobService.isRunningP1Validation {
                Label("検証中です", systemImage: "hourglass")
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

    var isEnabledInP1: Bool {
        switch self {
        case .twenty, .fifty, .oneHundred:
            true
        case .fiveHundred, .twoThousand:
            false
        }
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
