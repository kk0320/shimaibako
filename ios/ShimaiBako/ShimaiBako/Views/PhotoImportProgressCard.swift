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
