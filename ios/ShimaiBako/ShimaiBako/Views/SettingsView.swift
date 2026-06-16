import SwiftUI
import UIKit

struct SettingsView: View {
    @ObservedObject var photoLibrary: PhotoLibraryService
    @Environment(\.openURL) private var openURL

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
                            DetailInfoRow(title: "読み込み上限", value: "直近100件")
                            DetailInfoRow(title: "外部送信", value: "なし")
                        }
                        .padding(16)
                        .background(.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 8))

                        VStack(alignment: .leading, spacing: 14) {
                            SettingsSafetyRow(title: "写真は外部送信しません", systemImage: "lock.shield.fill")
                            SettingsSafetyRow(title: "写真は読み取り専用で扱います", systemImage: "eye.fill")
                            SettingsSafetyRow(title: "削除・移動・リネームは行いません", systemImage: "checkmark.shield.fill")
                            SettingsSafetyRow(title: "検索は端末内で実行します", systemImage: "iphone")
                        }
                        .padding(16)
                        .background(.white.opacity(0.76), in: RoundedRectangle(cornerRadius: 8))

                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                openURL(url)
                            }
                        } label: {
                            Label("写真アクセス設定を開く", systemImage: "gearshape")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("設定")
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
        }
    }
}
