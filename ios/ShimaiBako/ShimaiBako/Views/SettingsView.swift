import Photos
import SwiftUI
import UIKit

struct SettingsView: View {
    @ObservedObject var photoLibrary: PhotoLibraryService
    @ObservedObject var ocrService: OCRService
    @Environment(\.openURL) private var openURL

    private var ocrSummary: OCRSummary {
        ocrService.summary(for: photoLibrary.assets)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("しまい箱")
                                .font(.title.bold())
                                .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))

                            Text("端末内で写真を探すためのローカルアプリです。")
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            DetailInfoRow(title: "写真アクセス", value: photoLibrary.statusTitle)
                            DetailInfoRow(title: "読み込み上限", value: photoLibrary.readLimitTitle)
                            DetailInfoRow(title: "OCR済み件数", value: "\(ocrService.storedCompletedCount)件")
                            DetailInfoRow(title: "OCR未処理件数", value: "\(ocrSummary.unprocessedCount)件")
                            DetailInfoRow(title: "OCR失敗件数", value: "\(ocrService.storedFailedCount)件")
                            DetailInfoRow(title: "外部送信", value: "なし")
                            DetailInfoRow(title: "保存先", value: "端末内")
                            DetailInfoRow(title: "写真操作", value: "読み取り専用")
                        }
                        .padding(16)
                        .background(.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 8))

                        ocrSettingsCard

                        permissionCard

                        VStack(alignment: .leading, spacing: 14) {
                            SettingsSafetyRow(title: "写真は外部送信しません", systemImage: "lock.shield.fill")
                            SettingsSafetyRow(title: "写真は読み取り専用で扱います", systemImage: "eye.fill")
                            SettingsSafetyRow(title: "削除・移動・リネームは行いません", systemImage: "checkmark.shield.fill")
                            SettingsSafetyRow(title: "検索は端末内で実行します", systemImage: "iphone")
                        }
                        .padding(16)
                        .background(.white.opacity(0.76), in: RoundedRectangle(cornerRadius: 8))

                        if showsSettingsActions {
                            settingsButton
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 140)
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                if photoLibrary.canReadPhotos && photoLibrary.assets.isEmpty {
                    await photoLibrary.loadRecentAssets()
                }
            }
        }
    }

    private var ocrSettingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("OCR設定", systemImage: "text.viewfinder")
                .font(.headline)
                .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))

            DetailInfoRow(title: "OCR言語", value: OCRConfiguration.recognitionLanguageTitle)
            DetailInfoRow(title: "OCR精度", value: OCRConfiguration.recognitionQualityTitle)
            DetailInfoRow(title: "まとめてOCR上限", value: "\(OCRConfiguration.batchLimit)件")
            DetailInfoRow(title: "OCR画像サイズ", value: OCRConfiguration.maxRecognitionImageLongSideTitle)
            DetailInfoRow(title: "OCR結果件数", value: "\(ocrService.resultsByAssetID.count)件")
            DetailInfoRow(title: "OCR結果キャッシュ", value: "端末内JSON")

            Text("OCR結果だけを端末内に保存します。写真本体は保存・削除しません。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(permissionTitle, systemImage: permissionIcon)
                .font(.headline)
                .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))

            Text(permissionDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.76), in: RoundedRectangle(cornerRadius: 8))
    }

    private var settingsButton: some View {
        VStack(spacing: 10) {
            if photoLibrary.authorizationStatus == .limited {
                Button {
                    photoLibrary.presentLimitedLibraryPicker()
                } label: {
                    Label("写真の選択を変更", systemImage: "person.crop.rectangle.stack")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            if photoLibrary.authorizationStatus == .limited {
                Button {
                    openSystemSettings()
                } label: {
                    Label(settingsButtonTitle, systemImage: "gearshape")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    openSystemSettings()
                } label: {
                    Label(settingsButtonTitle, systemImage: "gearshape")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var showsSettingsActions: Bool {
        switch photoLibrary.authorizationStatus {
        case .authorized:
            false
        case .notDetermined, .limited, .denied, .restricted:
            true
        @unknown default:
            true
        }
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
    }

    private var permissionTitle: String {
        switch photoLibrary.authorizationStatus {
        case .notDetermined:
            "写真アクセスは未確認です"
        case .authorized:
            "写真を読み取り可能です"
        case .limited:
            "選択した写真のみ利用中"
        case .denied:
            "写真アクセスが拒否されています"
        case .restricted:
            "写真アクセスが制限されています"
        @unknown default:
            "写真アクセス状態を確認できません"
        }
    }

    private var permissionDescription: String {
        switch photoLibrary.authorizationStatus {
        case .notDetermined:
            "写真タブで許可すると、直近の写真を読み取り専用で表示します。"
        case .authorized:
            "許可された範囲から直近の写真を読み込み、検索とOCRを端末内で実行します。"
        case .limited:
            "限定アクセス中です。必要に応じて、利用できる写真の選択を変更できます。"
        case .denied:
            "設定アプリで写真アクセスを許可すると、写真の読み込みを再開できます。"
        case .restricted:
            "端末や管理設定により写真アクセスが制限されています。設定を確認してください。"
        @unknown default:
            "しばらくしてからもう一度確認してください。"
        }
    }

    private var permissionIcon: String {
        switch photoLibrary.authorizationStatus {
        case .authorized:
            "checkmark.shield.fill"
        case .limited:
            "person.crop.rectangle.stack"
        case .denied:
            "xmark.shield.fill"
        case .restricted:
            "lock.trianglebadge.exclamationmark.fill"
        case .notDetermined:
            "questionmark.circle.fill"
        @unknown default:
            "exclamationmark.triangle.fill"
        }
    }

    private var settingsButtonTitle: String {
        switch photoLibrary.authorizationStatus {
        case .denied:
            "設定で写真アクセスを許可"
        case .restricted:
            "設定を確認"
        default:
            "写真アクセス設定を開く"
        }
    }
}

private struct SettingsSafetyRow: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: systemImage)
                .font(.callout.weight(.semibold))
                .frame(width: 18, alignment: .center)

            Text(title)
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
        }
        .foregroundStyle(Color(red: 0.10, green: 0.24, blue: 0.42))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DetailInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Spacer(minLength: 16)

            Text(value)
                .font(.subheadline)
                .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
    }
}
