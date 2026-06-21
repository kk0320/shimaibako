import SwiftUI

struct OrganizationView: View {
    @ObservedObject var photoLibrary: PhotoLibraryService
    @ObservedObject var indexService: PhotoIndexService
    @ObservedObject var classificationService: PhotoClassificationService

    private var summary: PhotoClassificationSummary {
        classificationService.summary
    }

    private var loadedScreenshotCount: Int {
        photoLibrary.assets.filter(\.isScreenshot).count
    }

    private var loadedUnorganizedCount: Int {
        max(0, photoLibrary.loadedAssetCount - summary.totalCount)
    }

    private var totalCountForDisplay: Int {
        max(photoLibrary.loadedAssetCount, summary.totalCount)
    }

    private var classifiedProgressTitle: String {
        "\(summary.classifiedCount) / \(max(totalCountForDisplay, 0))件"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        statusCard
                        metadataUpdateCard
                        availableClassificationsCard
                        evaluationNoticeCard
                        dataPolicyCard
                        #if DEBUG
                        manualPrioritySelfTestCard
                        #endif
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 120)
                }
            }
            .navigationTitle("整理")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("画像認識で自動整理")
                .font(.title2.bold())
                .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))

            Text("現在は分類データの土台だけを用意しています。整理タブを開いても画像認識や大量処理は開始しません。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("自動整理状況", systemImage: "square.grid.2x2")
                .font(.headline)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                OrganizationMetricTile(
                    title: "分類済み",
                    value: classifiedProgressTitle,
                    caption: "読み込み済み範囲"
                )
                OrganizationMetricTile(
                    title: "全体件数",
                    value: "\(totalCountForDisplay)件",
                    caption: "現在の対象範囲"
                )
                OrganizationMetricTile(
                    title: "スクショ",
                    value: "\(max(summary.screenshotCount, loadedScreenshotCount))件",
                    caption: "メタデータ判定"
                )
                OrganizationMetricTile(
                    title: "読取候補",
                    value: "\(summary.readCandidateCount)件",
                    caption: "今後の候補枠"
                )
                OrganizationMetricTile(
                    title: "要確認",
                    value: "\(summary.needsReviewCount)件",
                    caption: "人が見直す候補"
                )
                OrganizationMetricTile(
                    title: "未整理",
                    value: "\(max(summary.unorganizedCount, loadedUnorganizedCount))件",
                    caption: "読み込み済み範囲"
                )
            }

            if classificationService.isLoading {
                Label("分類データを読み込んでいます", systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage = classificationService.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.black.opacity(0.06))
        )
    }

    private var metadataUpdateCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("軽量整理", systemImage: "arrow.triangle.2.circlepath")
                .font(.headline)

            Text("スクショなど、写真のメタデータだけで分かる範囲を整理します。画像認識や読取は実行しません。元写真・元動画は変更しません。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if classificationService.isUpdatingMetadata {
                VStack(alignment: .leading, spacing: 8) {
                    Text("軽量整理中...")
                        .font(.caption.weight(.semibold))
                    ProgressView(
                        value: Double(classificationService.metadataUpdateProcessedCount),
                        total: Double(max(classificationService.metadataUpdateTotalCount, 1))
                    )
                    .tint(Color(red: 0.16, green: 0.42, blue: 0.75))
                    Text("処理済み \(classificationService.metadataUpdateProcessedCount) / \(classificationService.metadataUpdateTotalCount)件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if classificationService.lastUpdateSummary.processedCount > 0 {
                let updateSummary = classificationService.lastUpdateSummary
                VStack(alignment: .leading, spacing: 6) {
                    Text("前回更新")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color(red: 0.09, green: 0.18, blue: 0.30))
                    Text("処理済み \(updateSummary.processedCount)件 / スクショ \(updateSummary.screenshotCount)件 / 読取候補 \(updateSummary.readCandidateCount)件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("手動分類保護 \(updateSummary.manualProtectedCount)件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let lastMetadataUpdatedAt = classificationService.lastMetadataUpdatedAt {
                Text("最終更新: \(DateFormatter.localizedString(from: lastMetadataUpdatedAt, dateStyle: .short, timeStyle: .short))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button {
                    Task {
                        await classificationService.updateMetadataOnly(
                            assets: photoLibrary.assets,
                            indexService: indexService
                        )
                    }
                } label: {
                    Label("軽量整理を更新", systemImage: "play.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(classificationService.isUpdatingMetadata || photoLibrary.assets.isEmpty)

                if classificationService.isUpdatingMetadata {
                    Button(role: .cancel) {
                        classificationService.cancelMetadataUpdate()
                    } label: {
                        Label("中止", systemImage: "xmark.circle")
                            .labelStyle(.iconOnly)
                            .frame(width: 42)
                    }
                    .buttonStyle(.bordered)
                }
            }

            if photoLibrary.assets.isEmpty {
                Text("写真タブで写真を読み込むと、読み込み済み範囲を軽量整理できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.black.opacity(0.06))
        )
    }

    private var availableClassificationsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("現在利用できる分類", systemImage: "checkmark.seal")
                .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                OrganizationScopeRow(title: "スクショ", detail: "写真アプリのスクショ情報を使う軽量な分類です。")
                OrganizationScopeRow(title: "読取候補", detail: "文字がありそうな写真を、将来の読取候補として扱う枠です。")
                OrganizationScopeRow(title: "要確認", detail: "自動で断定せず、人が見直すための安全な置き場です。")
            }
        }
        .padding(16)
        .background(.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.black.opacity(0.06))
        )
    }

    private var evaluationNoticeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("評価中の分類", systemImage: "exclamationmark.triangle")
                .font(.headline)

            Text("建物・工事現場・看板・白板・図面・名刺・レシートなどの分類は評価中です。十分な検証が終わるまで、通常表示の自動フォルダとしては出しません。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Color.yellow.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.yellow.opacity(0.28))
        )
    }

    private var dataPolicyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("保存する分類データ", systemImage: "lock.doc")
                .font(.headline)

            Text("保存するのは分類カテゴリ、タグ、スコア、状態、更新日時、バージョン、写真の識別子だけです。元写真・元動画、サムネイル本体、顔画像、顔テンプレートは保存しません。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("手動分類がある場合は、自動分類より必ず優先します。")
                .font(.caption)
                .foregroundStyle(Color(red: 0.16, green: 0.42, blue: 0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.black.opacity(0.06))
        )
    }

    #if DEBUG
    private var manualPrioritySelfTestCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("手動分類優先セルフテスト", systemImage: "checkmark.shield")
                .font(.headline)

            Text("自動分類より手動分類が優先されることを、軽量なモデル操作だけで確認します。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let report = classificationService.selfTestReport {
                Text(report.message)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(report.passed ? Color(red: 0.16, green: 0.42, blue: 0.75) : .red)
            }

            Button {
                classificationService.runManualPrioritySelfTest()
            } label: {
                Label("セルフテストを実行", systemImage: "play.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .background(.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.black.opacity(0.06))
        )
    }
    #endif
}

private struct OrganizationMetricTile: View {
    let title: String
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.headline)
                .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
        .padding(12)
        .background(Color(red: 0.95, green: 0.98, blue: 1.0), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct OrganizationScopeRow: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color(red: 0.16, green: 0.42, blue: 0.75))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
