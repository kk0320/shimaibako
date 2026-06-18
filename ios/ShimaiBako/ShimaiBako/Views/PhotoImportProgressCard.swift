import SwiftUI

struct PhotoImportProgressCard: View {
    @ObservedObject var photoLibrary: PhotoLibraryService
    @State private var showsRecoveryOptions = false
    @State private var showingResetConfirmation = false
    @State private var isResetting = false

    private var progress: PhotoImportProgress {
        photoLibrary.importProgress
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: iconName)
                    .font(.headline)
                    .foregroundStyle(iconColor)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 4) {
                    Text(progress.phase.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))

                    Text(progress.message ?? "元写真・元動画は削除・変更しません。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)
            }

            ProgressView(value: progress.progressFraction, total: 1)
                .tint(Color(red: 0.16, green: 0.42, blue: 0.75))

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8)
            ], alignment: .leading, spacing: 6) {
                ImportProgressInfo(title: "件数", value: progress.countTitle)
                ImportProgressInfo(title: "進捗", value: "\(Int((progress.progressFraction * 100).rounded()))%")
                ImportProgressInfo(title: "最終更新", value: progress.updatedAtTitle)
                ImportProgressInfo(title: "経過", value: progress.elapsedTitle)
                if let lastSuccessfulBatchEnd = progress.lastSuccessfulBatchEnd {
                    ImportProgressInfo(title: "最終完了", value: "\(lastSuccessfulBatchEnd)件")
                }
                if let lastPhaseTitle {
                    ImportProgressInfo(title: "最後の処理", value: lastPhaseTitle)
                }
                if let memoryWarningCount = progress.memoryWarningCount, memoryWarningCount > 0 {
                    ImportProgressInfo(title: "負荷警告", value: "\(memoryWarningCount)回")
                }
            }

            if photoLibrary.importAppearsStalled || progress.phase == .stale {
                Text("読み込みが進んでいない可能性があります。中止して軽量モードで再読み込みできます。")
                    .font(.caption)
                    .foregroundStyle(Color(red: 0.75, green: 0.24, blue: 0.18))
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 8) {
                if photoLibrary.isLoading {
                    Button(role: .destructive) {
                        photoLibrary.cancelLoading()
                    } label: {
                        Label("読み込みを中止", systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if photoLibrary.hasRecoverableImportState {
                    Button {
                        photoLibrary.resumeLoading()
                    } label: {
                        Label("続きから再開", systemImage: "play.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                DisclosureGroup(isExpanded: $showsRecoveryOptions) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("通常は使いません。読み込みが止まった時だけ、途中の読み込みジョブ状態を初期化します。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Button {
                            showingResetConfirmation = true
                        } label: {
                            Label(isResetting ? "リセット中" : "読み込み処理だけを初期化", systemImage: "arrow.counterclockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isResetting)
                    }
                    .padding(.top, 6)
                } label: {
                    Label("復旧オプション", systemImage: "wrench.and.screwdriver")
                        .font(.caption.weight(.semibold))
                }

                Button {
                    Task {
                        await photoLibrary.reloadLightMode()
                    }
                } label: {
                    Label("軽量モードで再読み込み", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(.white.opacity(0.80), in: RoundedRectangle(cornerRadius: 8))
        .alert("読み込み処理だけを初期化しますか？", isPresented: $showingResetConfirmation) {
            Button("キャンセル", role: .cancel) {}
            Button("読み込み処理を初期化", role: .destructive) {
                Task {
                    isResetting = true
                    photoLibrary.resetLoadingState()
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    isResetting = false
                }
            }
            .disabled(isResetting)
        } message: {
            Text("元写真・元動画は削除されません。OCR結果・手動分類・不要候補・メモ・タグは削除しません。読み込みジョブ状態だけをリセットします。")
        }
    }

    private var iconName: String {
        switch progress.phase {
        case .idle:
            "pause.circle"
        case .fetchingAssetList:
            "photo.stack"
        case .indexing:
            "list.bullet.rectangle"
        case .preparingThumbnails:
            "rectangle.stack"
        case .completed:
            "checkmark.circle.fill"
        case .cancelled:
            "xmark.circle"
        case .failed:
            "exclamationmark.triangle.fill"
        case .stale:
            "clock.badge.exclamationmark"
        case .paused:
            "pause.circle"
        }
    }

    private var iconColor: Color {
        switch progress.phase {
        case .completed:
            Color(red: 0.14, green: 0.55, blue: 0.32)
        case .failed, .stale:
            Color(red: 0.75, green: 0.24, blue: 0.18)
        case .cancelled, .paused:
            .secondary
        case .idle, .fetchingAssetList, .indexing, .preparingThumbnails:
            Color(red: 0.16, green: 0.42, blue: 0.75)
        }
    }

    private var lastPhaseTitle: String? {
        guard let phase = progress.lastPhase else {
            return nil
        }

        switch phase {
        case "photoFetch":
            return "写真一覧取得"
        case "sqliteMigration":
            return "SQLite移行"
        case "sqliteBatchInsert":
            return "インデックス保存"
        case "searchIndexPrepare":
            return "検索準備"
        case "countSnapshot":
            return "件数集計"
        case "gridSnapshot":
            return "一覧反映"
        case "finalization":
            return "完了処理"
        default:
            return phase
        }
    }
}

struct PhotoImportCompactStatusCard: View {
    @ObservedObject var photoLibrary: PhotoLibraryService

    private var progress: PhotoImportProgress {
        photoLibrary.importProgress
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: iconName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(iconColor)
                .frame(width: 18, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Text("元写真・元動画は削除・変更しません。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.white.opacity(0.74), in: RoundedRectangle(cornerRadius: 8))
    }

    private var title: String {
        switch progress.phase {
        case .completed:
            return "読み込み完了 \(progress.loadedCount)件"
        case .fetchingAssetList, .indexing, .preparingThumbnails:
            return "読み込み中 \(progress.countTitle)"
        case .paused:
            return "読み込みを一時停止中"
        case .cancelled:
            return "ユーザー操作で中止しました"
        case .failed:
            return "読み込みに失敗しました"
        case .stale:
            return "前回の読み込みが途中で停止"
        case .idle:
            return "読み込み待機中"
        }
    }

    private var iconName: String {
        switch progress.phase {
        case .completed:
            "checkmark.circle.fill"
        case .failed, .stale:
            "exclamationmark.triangle.fill"
        case .cancelled:
            "xmark.circle"
        case .paused, .idle:
            "pause.circle"
        case .fetchingAssetList, .indexing, .preparingThumbnails:
            "arrow.triangle.2.circlepath"
        }
    }

    private var iconColor: Color {
        switch progress.phase {
        case .completed:
            Color(red: 0.14, green: 0.55, blue: 0.32)
        case .failed, .stale:
            Color(red: 0.75, green: 0.24, blue: 0.18)
        case .cancelled, .paused, .idle:
            .secondary
        case .fetchingAssetList, .indexing, .preparingThumbnails:
            Color(red: 0.16, green: 0.42, blue: 0.75)
        }
    }
}

struct ImportRecoveryEmptyView: View {
    @ObservedObject var photoLibrary: PhotoLibraryService
    @State private var showingResetConfirmation = false
    @State private var isResetting = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(Color(red: 0.75, green: 0.24, blue: 0.18))

            VStack(spacing: 6) {
                Text("前回の読み込みが途中で止まりました")
                    .font(.headline)
                    .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))
                    .multilineTextAlignment(.center)

                Text("元写真・元動画は削除・変更されていません。読み込み状態だけをリセットできます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if photoLibrary.importProgress.loadedCount > 0 || photoLibrary.importProgress.totalCount > 0 {
                    Text("最後に完了した件数: \(photoLibrary.importProgress.loadedCount) / \(photoLibrary.importProgress.totalCount)件")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if let lastPhase = photoLibrary.importProgress.lastPhase {
                    Text("最後の処理: \(lastPhase)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            VStack(spacing: 8) {
                Button {
                    photoLibrary.resumeLoading()
                } label: {
                    Label("続きから再開", systemImage: "play.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    Task {
                        await photoLibrary.reloadLightMode()
                    }
                } label: {
                    Label("軽量モードで再読み込み", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    showingResetConfirmation = true
                } label: {
                    Label(isResetting ? "リセット中" : "読み込み処理だけを初期化", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isResetting)
            }
        }
        .padding(24)
        .alert("読み込み処理だけを初期化しますか？", isPresented: $showingResetConfirmation) {
            Button("キャンセル", role: .cancel) {}
            Button("読み込み処理を初期化", role: .destructive) {
                Task {
                    isResetting = true
                    photoLibrary.resetLoadingState()
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    isResetting = false
                }
            }
            .disabled(isResetting)
        } message: {
            Text("元写真・元動画は削除されません。OCR結果・手動分類・不要候補・メモ・タグは削除しません。読み込みジョブ状態だけをリセットします。")
        }
    }
}

private struct ImportProgressInfo: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color(red: 0.09, green: 0.18, blue: 0.30))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
    }
}
