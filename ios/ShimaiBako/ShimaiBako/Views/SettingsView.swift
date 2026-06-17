import Photos
import SwiftUI
import UIKit

struct SettingsView: View {
    @ObservedObject var photoLibrary: PhotoLibraryService
    @ObservedObject var ocrService: OCRService
    @ObservedObject var indexService: PhotoIndexService
    @ObservedObject var deviceSafety: DeviceSafetyService
    @Environment(\.openURL) private var openURL
    @State private var pendingReadMode: PhotoReadMode?
    @State private var showingLargeModeSafety = false

    private var indexSummary: PhotoIndexSummary {
        indexService.summary(for: photoLibrary.assets, ocrService: ocrService)
    }

    private var categoryCounts: [PhotoCategory: Int] {
        indexService.counts(for: photoLibrary.assets, ocrService: ocrService)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        summaryCard
                        loadingModeCard
                        largeLibraryGuideCard
                        iCloudSettingsCard
                        categoryCountsCard
                        ocrSettingsCard
                        deviceSafetyCard
                        permissionCard
                        safetyPolicyCard

                        if showsSettingsActions {
                            settingsButton
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 140)
                }
                .safeAreaInset(edge: .bottom) {
                    Color.clear.frame(height: 96)
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingLargeModeSafety) {
                LargeModeSafetyView(
                    mode: pendingReadMode ?? .large,
                    iCloudMode: photoLibrary.iCloudMode,
                    deviceSafety: deviceSafety,
                    onLightMode: {
                        showingLargeModeSafety = false
                        pendingReadMode = nil
                        applyReadMode(.light)
                    },
                    onContinue: {
                        let mode = pendingReadMode ?? .large
                        showingLargeModeSafety = false
                        pendingReadMode = nil
                        applyReadMode(mode)
                    }
                )
                .presentationDetents([.large])
            }
            .task {
                if photoLibrary.canReadPhotos && photoLibrary.assets.isEmpty {
                    await photoLibrary.loadRecentAssets()
                }

                await indexService.rebuild(for: photoLibrary.assets, ocrService: ocrService)
                deviceSafety.refresh()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("しまい箱")
                .font(.title.bold())
                .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))

            Text("端末内で写真を探すためのローカルアプリです。")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailInfoRow(title: "写真アクセス", value: photoLibrary.statusTitle)
            DetailInfoRow(title: "読み込みモード", value: photoLibrary.readMode.title)
            DetailInfoRow(title: "読み込み上限", value: photoLibrary.readLimitTitle)
            DetailInfoRow(title: "読み込み済み", value: photoLibrary.loadingSummaryTitle)
            DetailInfoRow(title: "iCloud取得", value: photoLibrary.iCloudMode.title)
            DetailInfoRow(title: "インデックス件数", value: "\(indexService.indexedRecordCount)件")
            DetailInfoRow(title: "OCR済み件数", value: "\(indexSummary.completedOCRCount)件")
            DetailInfoRow(title: "OCR未処理件数", value: "\(indexSummary.unprocessedOCRCount)件")
            DetailInfoRow(title: "OCR失敗件数", value: "\(indexSummary.failedOCRCount)件")
            DetailInfoRow(title: "分類済み件数", value: "\(indexSummary.categorizedCount)件")
            DetailInfoRow(title: "外部送信", value: "なし")
            DetailInfoRow(title: "保存先", value: "端末内")
            DetailInfoRow(title: "写真操作", value: "読み取り専用")
        }
        .padding(16)
        .background(.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 8))
    }

    private var loadingModeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("読み込みモード", systemImage: "photo.stack")
                .font(.headline)
                .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))

            Text("3万枚など大量写真では、まず軽量/標準モードを推奨します。写真本体は表示時だけ取得します。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(PhotoReadMode.allCases) { mode in
                Button {
                    selectReadMode(mode)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: photoLibrary.readMode == mode ? "checkmark.circle.fill" : "circle")
                            .frame(width: 18)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(mode.title) / \(mode.limitTitle)")
                                .font(.subheadline.weight(.semibold))
                            Text(mode.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(red: 0.09, green: 0.18, blue: 0.30))
            }

            if photoLibrary.readMode.isLargeScale {
                Text("大量/フルモード中です。発熱、バッテリー、保存容量を確認しながら使ってください。")
                    .font(.caption)
                    .foregroundStyle(Color(red: 0.75, green: 0.24, blue: 0.18))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
    }

    private var largeLibraryGuideCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("大量写真の進め方", systemImage: "list.bullet.clipboard")
                .font(.headline)
                .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))

            SafetyBullet("3万枚など大量写真では、まず軽量/標準モードで確認してください")
            SafetyBullet("全件モードは時間がかかる場合があります")
            SafetyBullet("OCRは必要なカテゴリから段階的に実行してください")
            SafetyBullet("iCloud写真の取得を許可すると通信が発生する場合があります")
            SafetyBullet("写真本体は外部送信せず、変更もしません")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
    }

    private var iCloudSettingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("iCloud写真", systemImage: "icloud")
                .font(.headline)
                .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))

            ForEach(ICloudPhotoMode.allCases) { mode in
                Button {
                    photoLibrary.updateICloudMode(mode)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: photoLibrary.iCloudMode == mode ? "checkmark.circle.fill" : "circle")
                            .frame(width: 18)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.title)
                                .font(.subheadline.weight(.semibold))
                            Text(mode.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(red: 0.09, green: 0.18, blue: 0.30))
            }

            Text("iCloud取得はApple/iCloud写真からの取得です。外部OCRサービスには送信しません。モバイル通信量に注意してください。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
    }

    private var categoryCountsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("仮想フォルダ", systemImage: "folder")
                .font(.headline)
                .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))

            Text("分類はしまい箱内の仮想フォルダです。写真アプリ側にアルバムやフォルダは作りません。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8)
            ], alignment: .leading, spacing: 8) {
                ForEach(PhotoCategory.allCases) { category in
                    Label("\(category.shortTitle) \(categoryCounts[category, default: 0])", systemImage: category.systemImage)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color(red: 0.09, green: 0.18, blue: 0.30))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
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
            DetailInfoRow(title: "OCR結果件数", value: "\(indexSummary.completedOCRCount)件")
            DetailInfoRow(title: "インデックス保存先", value: "端末内")
            DetailInfoRow(title: "保存内容", value: "検索インデックスのみ")

            Text("OCR結果、分類結果、検索用メタデータだけを端末内に保存します。写真本体やサムネイル本体は保存しません。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("OCRは必要な写真から段階的に実行します。発熱やバッテリー消費を避けるため、全件OCRは初期運用では行いません。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Task {
                    await indexService.rebuildSearchIndex(for: photoLibrary.assets, ocrService: ocrService)
                }
            } label: {
                Label("検索インデックスを再構築", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(photoLibrary.assets.isEmpty)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
    }

    private var deviceSafetyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("大量処理の安全確認", systemImage: "gauge")
                .font(.headline)
                .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))

            DetailInfoRow(title: "バッテリー", value: deviceSafety.batteryTitle)
            DetailInfoRow(title: "低電力モード", value: deviceSafety.isLowPowerModeEnabled ? "オン" : "オフ")
            DetailInfoRow(title: "発熱状態", value: deviceSafety.thermalStateTitle)
            DetailInfoRow(title: "保存容量", value: deviceSafety.availableCapacityTitle)

            ForEach(deviceSafety.notices) { notice in
                SafetyNoticeRow(notice: notice)
            }

            Text("OCRは端末内処理です。写真は外部送信せず、写真本体も変更しません。大量写真では軽量/標準モードから始めてください。")
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

    private var safetyPolicyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsSafetyRow(title: "写真は外部送信しません", systemImage: "lock.shield.fill")
            SettingsSafetyRow(title: "写真は読み取り専用で扱います", systemImage: "eye.fill")
            SettingsSafetyRow(title: "削除・移動・リネームは行いません", systemImage: "checkmark.shield.fill")
            SettingsSafetyRow(title: "検索は端末内で実行します", systemImage: "iphone")
        }
        .padding(16)
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

    private func selectReadMode(_ mode: PhotoReadMode) {
        guard mode != photoLibrary.readMode else {
            return
        }

        if mode.isLargeScale {
            deviceSafety.refresh()
            pendingReadMode = mode
            showingLargeModeSafety = true
        } else {
            applyReadMode(mode)
        }
    }

    private func applyReadMode(_ mode: PhotoReadMode) {
        Task {
            await photoLibrary.updateReadMode(mode)
            await indexService.rebuild(for: photoLibrary.assets, ocrService: ocrService)
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
            "写真タブで許可すると、設定した読み込みモードの範囲で読み取り専用表示します。"
        case .authorized:
            "許可された範囲から写真を読み込み、検索とOCRを端末内で実行します。"
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

private struct LargeModeSafetyView: View {
    let mode: PhotoReadMode
    let iCloudMode: ICloudPhotoMode
    @ObservedObject var deviceSafety: DeviceSafetyService
    let onLightMode: () -> Void
    let onContinue: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("\(mode.title)モードの確認", systemImage: "exclamationmark.triangle.fill")
                            .font(.title3.bold())
                            .foregroundStyle(Color(red: 0.75, green: 0.24, blue: 0.18))

                        Text("\(mode.limitTitle)を対象にします。3万枚規模では端末状態を確認しながら段階的に使ってください。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        SafetyBullet("バッテリー残量が50%以上、または充電中に使用してください")
                        SafetyBullet("大量の写真を処理すると端末が発熱する場合があります")
                        SafetyBullet("iCloud写真を取得する場合は通信量が増える場合があります")
                        SafetyBullet("写真本体は変更しませんが、大規模処理前は念のためバックアップを推奨します")
                        SafetyBullet("処理中はメモリを使用するため、他のアプリの動作が重くなる場合があります")
                        SafetyBullet("保存容量が不足している場合、処理を中断します")
                        SafetyBullet("最初は軽量/標準モードで試すことを推奨します")

                        if iCloudMode == .allowDownload {
                            SafetyBullet("iCloud取得ONです。モバイル通信量に注意してください")
                        }
                    }
                    .padding(14)
                    .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 10) {
                        Label("現在の端末状態", systemImage: "iphone.gen3")
                            .font(.headline)

                        DetailInfoRow(title: "バッテリー", value: deviceSafety.batteryTitle)
                        DetailInfoRow(title: "低電力モード", value: deviceSafety.isLowPowerModeEnabled ? "オン" : "オフ")
                        DetailInfoRow(title: "発熱状態", value: deviceSafety.thermalStateTitle)
                        DetailInfoRow(title: "保存容量", value: deviceSafety.availableCapacityTitle)

                        ForEach(deviceSafety.notices) { notice in
                            SafetyNoticeRow(notice: notice)
                        }
                    }
                    .padding(14)
                    .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(18)
            }
            .navigationTitle("安全確認")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Button {
                        onLightMode()
                    } label: {
                        Text("軽量モードに戻る")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        onContinue()
                    } label: {
                        Text("理解して全件モードを使う")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(deviceSafety.blockingReasonForLargeWork != nil)
                }
                .padding(16)
                .background(.ultraThinMaterial)
            }
            .onAppear {
                deviceSafety.refresh()
            }
        }
    }
}

private struct SafetyNoticeRow: View {
    let notice: DeviceSafetyNotice

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(red: 0.09, green: 0.18, blue: 0.30))

                Text(notice.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var icon: String {
        switch notice.level {
        case .normal:
            "checkmark.circle.fill"
        case .warning:
            "exclamationmark.triangle.fill"
        case .blocking:
            "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch notice.level {
        case .normal:
            Color(red: 0.14, green: 0.55, blue: 0.32)
        case .warning:
            Color(red: 0.75, green: 0.50, blue: 0.12)
        case .blocking:
            Color(red: 0.75, green: 0.24, blue: 0.18)
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

private struct SafetyBullet: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Color(red: 0.16, green: 0.42, blue: 0.75))
                .frame(width: 16)

            Text(text)
                .font(.caption)
                .foregroundStyle(Color(red: 0.09, green: 0.18, blue: 0.30))
                .fixedSize(horizontal: false, vertical: true)
        }
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
