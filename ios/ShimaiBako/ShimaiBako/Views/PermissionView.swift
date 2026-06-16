import Photos
import SwiftUI
import UIKit

struct PermissionView: View {
    @ObservedObject var photoLibrary: PhotoLibraryService
    @Environment(\.openURL) private var openURL
    @State private var isRequestingAccess = false

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                ScrollView {
                    VStack(spacing: 22) {
                        Image(systemName: "archivebox.fill")
                            .font(.system(size: 64, weight: .semibold))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.20, green: 0.45, blue: 0.78),
                                        Color(red: 0.33, green: 0.70, blue: 0.86)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .padding(.top, 28)

                        VStack(spacing: 8) {
                            Text("しまい箱")
                                .font(.largeTitle.bold())
                                .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))

                            Text("写真を読み取り専用で扱い、端末内で検索します。")
                                .font(.body)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 14) {
                            SafetyRow(title: "写真は外部送信しません", systemImage: "lock.shield.fill")
                            SafetyRow(title: "読み取り専用で扱います", systemImage: "eye.fill")
                            SafetyRow(title: "端末内で検索します", systemImage: "magnifyingglass")
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 8))

                        VStack(spacing: 10) {
                            Text("現在の状態: \(photoLibrary.statusTitle)")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(Color(red: 0.10, green: 0.24, blue: 0.42))

                            accessButton
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity)
                        .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .padding(20)
                }
            }
            .navigationTitle("写真アクセス")
        }
    }

    @ViewBuilder
    private var accessButton: some View {
        switch photoLibrary.authorizationStatus {
        case .notDetermined:
            Button {
                Task {
                    isRequestingAccess = true
                    await photoLibrary.requestAuthorization()
                    isRequestingAccess = false
                }
            } label: {
                Label("写真へのアクセスを許可", systemImage: "photo.badge.checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRequestingAccess)
        case .denied, .restricted:
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            } label: {
                Label("設定を開く", systemImage: "gearshape")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        case .authorized, .limited:
            Button {
                Task {
                    await photoLibrary.loadRecentAssets()
                }
            } label: {
                Label("写真を読み込む", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        @unknown default:
            EmptyView()
        }
    }
}

struct SafetyRow: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.callout.weight(.medium))
            .foregroundStyle(Color(red: 0.10, green: 0.24, blue: 0.42))
    }
}
