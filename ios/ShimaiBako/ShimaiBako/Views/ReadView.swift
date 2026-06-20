import SwiftUI

struct ReadView: View {
    @ObservedObject var photoLibrary: PhotoLibraryService
    @ObservedObject var ocrService: OCRService
    @ObservedObject var indexService: PhotoIndexService
    @ObservedObject var deviceSafety: DeviceSafetyService

    @State private var selectedLimit: ReadBatchLimit = .oneHundred

    private var summary: PhotoIndexSummary {
        indexService.indexSummary
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
                        jobPlaceholderCard
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
            ReadMetricCard(title: "文字あり", value: "\(summary.completedOCRCount)件", systemImage: "doc.text.magnifyingglass")
            ReadMetricCard(title: "文字なし", value: "準備中", systemImage: "doc")
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
                } label: {
                    Label("まとめて文字を読み取る", systemImage: "play.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(true)

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

            Text("BatchOCRJobの永続化後に有効化します。写真タブでは読取処理を開始しません。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
    }

    private var jobPlaceholderCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("中断中ジョブ", systemImage: "pause.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))

            Text("中断中の読取ジョブはありません。今後のBatchOCRJobでは、バックグラウンド移行時に一時停止し、ここから続きだけ再開できます。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
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
