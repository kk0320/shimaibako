import Photos
import SwiftUI
import UIKit

struct PhotoDetailView: View {
    @ObservedObject var photoLibrary: PhotoLibraryService
    @ObservedObject var ocrService: OCRService
    @ObservedObject var indexService: PhotoIndexService
    @ObservedObject var learningService: ManualCategoryLearningService
    let asset: PhotoAsset
    let automaticallyRunOCR: Bool

    @State private var displayImage: UIImage?
    @State private var isLoadingImage = false
    @State private var didRunAutomaticOCR = false
    @State private var showingClearOCRConfirmation = false
    @State private var showingResetCategoryConfirmation = false
    @State private var showingMoveToUnwantedConfirmation = false
    @State private var undoDisplayStateChange: PhotoStateMutation?
    @State private var memoDraft = ""
    @State private var tagsDraft = ""

    init(
        photoLibrary: PhotoLibraryService,
        ocrService: OCRService,
        indexService: PhotoIndexService,
        learningService: ManualCategoryLearningService,
        asset: PhotoAsset,
        automaticallyRunOCR: Bool = false
    ) {
        self.photoLibrary = photoLibrary
        self.ocrService = ocrService
        self.indexService = indexService
        self.learningService = learningService
        self.asset = asset
        self.automaticallyRunOCR = automaticallyRunOCR
    }

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    imagePreview

                    VStack(alignment: .leading, spacing: 12) {
                        Text(asset.filename ?? "名前なし")
                            .font(.headline)
                            .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))
                            .lineLimit(2)

                        DetailRow(title: "種類", value: asset.kindLabel)
                        DetailRow(title: "日付", value: asset.dateLabel)
                        DetailRow(title: "サイズ", value: asset.sizeLabel)
                        DetailRow(title: "内部ID", value: asset.localIdentifier)
                        DetailRow(title: "表示状態", value: indexService.displayState(for: asset, ocrService: ocrService).title)
                        DetailRow(
                            title: "推定カテゴリ",
                            value: "\(indexService.category(for: asset, ocrService: ocrService).title) / 信頼度 \(indexService.confidenceLabel(for: asset, ocrService: ocrService))"
                        )
                        DetailRow(title: "分類種別", value: categorySourceTitle)
                        DetailRow(title: "分類理由", value: indexService.categoryReason(for: asset, ocrService: ocrService))

                        if let screenshotSubcategory = indexService.screenshotSubcategory(for: asset, ocrService: ocrService) {
                            DetailRow(
                                title: "スクショ分類",
                                value: "\(screenshotSubcategory.title) / 信頼度 \(indexService.screenshotSubcategoryConfidenceLabel(for: asset, ocrService: ocrService) ?? "-")"
                            )

                            if let reason = indexService.screenshotSubcategoryReason(for: asset, ocrService: ocrService) {
                                DetailRow(title: "スクショ分類理由", value: reason)
                            }
                        }

                        Text("分類はしまい箱内の仮想フォルダです。写真アプリ側のアルバムや元写真・元動画は変更しません。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        manualCategoryControls
                        displayStateControls
                        memoAndTagControls
                    }
                    .padding(16)
                    .background(.white.opacity(0.80), in: RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 10) {
                        SafetyRow(title: "写真は外部送信しません", systemImage: "lock.shield.fill")
                        SafetyRow(title: "削除・移動・編集は行いません", systemImage: "hand.raised.fill")
                        SafetyRow(title: "分類はしまい箱内の仮想フォルダです", systemImage: "folder.badge.gearshape")
                    }
                    .padding(16)
                    .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))

                    ocrPanel
                }
                .padding(16)
            }

            if let undoDisplayStateChange {
                displayStateUndoToast(undoDisplayStateChange)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .navigationTitle("詳細")
        .navigationBarTitleDisplayMode(.inline)
        .alert("OCR結果を削除しますか？", isPresented: $showingClearOCRConfirmation) {
            Button("キャンセル", role: .cancel) {}
            Button("OCR結果を削除", role: .destructive) {
                Task {
                    await clearOCRResult()
                }
            }
        } message: {
            Text("元写真・元動画は削除・変更されません。しまい箱に保存されたOCR文字だけを削除し、この写真を未処理に戻します。")
        }
        .alert("分類を未分類に戻しますか？", isPresented: $showingResetCategoryConfirmation) {
            Button("キャンセル", role: .cancel) {}
            Button("未分類に戻す", role: .destructive) {
                Task {
                    await indexService.resetCategory(for: asset, ocrService: ocrService)
                }
            }
        } message: {
            Text("元写真・元動画は変更されません。しまい箱内の仮想フォルダ分類だけを未分類に戻します。")
        }
        .alert("不要候補へ移動しますか？", isPresented: $showingMoveToUnwantedConfirmation) {
            Button("キャンセル", role: .cancel) {}
            Button("不要候補へ移動") {
                Task {
                    await setDisplayStateWithUndo(.unwanted)
                }
            }
        } message: {
            Text("しまい箱の通常表示から外します。元写真・元動画は削除されません。写真アプリ側のデータは変更しません。")
        }
        .task(id: asset.id) {
            loadMemoAndTags()
            isLoadingImage = true
            displayImage = await photoLibrary.requestDisplayImage(for: asset)
            isLoadingImage = false

            if automaticallyRunOCR {
                await runOCRIfPossible()
            }
        }
    }

    private func runOCRIfPossible() async {
        guard let displayImage,
              asset.mediaType == .image,
              ocrService.isProcessing(asset) == false else {
            return
        }

        if automaticallyRunOCR {
            guard didRunAutomaticOCR == false else {
                return
            }

            didRunAutomaticOCR = true
        }

        await ocrService.recognize(asset: asset, image: displayImage)
        await indexService.update(asset: asset, ocrService: ocrService)
    }

    private func clearOCRResult() async {
        guard ocrService.isProcessing(asset) == false else {
            return
        }

        await indexService.clearOCRResult(for: asset, ocrService: ocrService)
    }

    private var categorySourceTitle: String {
        let record = indexService.record(for: asset, ocrService: ocrService)

        if record.manualCategory != nil {
            return "手動分類"
        }

        if record.categoryReason == "手動分類傾向を参考" ||
            record.screenshotSubcategoryReason == "手動分類傾向を参考" {
            return "手動分類傾向を参考"
        }

        return "自動判定"
    }

    private var manualCategoryChoices: [PhotoCategory] {
        PhotoCategory.allCases.filter { category in
            category != .all && (asset.isScreenshot || category != .screenshots)
        }
    }

    private var manualCategoryControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Menu {
                ForEach(manualCategoryChoices) { category in
                    Button {
                        Task {
                            await indexService.setManualCategory(for: asset, category: category, ocrService: ocrService)
                        }
                    } label: {
                        Label(category.title, systemImage: category.systemImage)
                    }
                }
            } label: {
                Label("分類を手動変更", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if asset.isScreenshot {
                Menu {
                    ForEach(ScreenshotSubcategory.allCases.filter { $0 != .all }) { subcategory in
                        Button {
                            Task {
                                await indexService.setManualScreenshotSubcategory(for: asset, subcategory: subcategory, ocrService: ocrService)
                            }
                        } label: {
                            Label(subcategory.title, systemImage: subcategory.systemImage)
                        }
                    }
                } label: {
                    Label("スクショ分類を手動変更", systemImage: "rectangle.stack.badge.person.crop")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            HStack(spacing: 8) {
                Button {
                    Task {
                        await indexService.restoreAutomaticCategory(for: asset, ocrService: ocrService)
                    }
                } label: {
                    Label("自動判定に戻す", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    showingResetCategoryConfirmation = true
                } label: {
                    Label("未分類に戻す", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text(learningService.isEnabled ? "手動で直した分類は、端末内の軽量な分類傾向として保存されます。" : "分類傾向学習はオフです。手動分類そのものは保存されます。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var displayStateControls: some View {
        let state = indexService.displayState(for: asset, ocrService: ocrService)

        return VStack(alignment: .leading, spacing: 8) {
            Divider()

            Label("しまい箱内の表示状態", systemImage: state.systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text("不要候補や非表示は、しまい箱内の表示状態です。元写真・元動画は削除されません。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if state != .active {
                Button {
                    Task {
                        await setDisplayStateWithUndo(.active)
                    }
                } label: {
                    Label("通常表示に戻す", systemImage: "arrow.uturn.backward.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            if state != .unwanted {
                Button {
                    showingMoveToUnwantedConfirmation = true
                } label: {
                    Label("不要候補へ移動", systemImage: "tray.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func displayStateUndoToast(_ change: PhotoStateMutation) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color(red: 0.14, green: 0.55, blue: 0.32))

            VStack(alignment: .leading, spacing: 2) {
                Text("\(change.after.chipTitle)に変更しました")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))

                Text("写真アプリには影響しません。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button("元に戻す") {
                Task {
                    await undoDisplayState(change)
                }
            }
            .font(.caption.weight(.semibold))
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }

    private func setDisplayStateWithUndo(_ state: PhotoDisplayState) async {
        let previous = indexService.displayState(for: asset, ocrService: ocrService)
        guard previous != state else {
            return
        }

        await indexService.setDisplayState(state, for: asset, ocrService: ocrService)
        withAnimation(.easeInOut(duration: 0.2)) {
            undoDisplayStateChange = PhotoStateMutation(
                assetIdentifiers: [asset.localIdentifier],
                before: previous,
                after: state
            )
        }
    }

    private func undoDisplayState(_ change: PhotoStateMutation) async {
        await indexService.setDisplayState(change.before, for: asset, ocrService: ocrService)
        withAnimation(.easeInOut(duration: 0.2)) {
            undoDisplayStateChange = nil
        }
    }

    private var memoAndTagControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            Label("しまい箱メモ・タグ", systemImage: "tag")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField("メモを入力", text: $memoDraft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)

            TextField("タグをスペースまたはカンマで入力", text: $tagsDraft)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)

            Button {
                Task {
                    await indexService.setMemoAndTags(
                        for: asset,
                        memo: memoDraft,
                        tags: parsedTags,
                        ocrService: ocrService
                    )
                    loadMemoAndTags()
                }
            } label: {
                Label("メモ・タグを保存", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Text("検索用のメモ・タグをしまい箱内に保存します。元写真・元動画は変更しません。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var parsedTags: [String] {
        tagsDraft
            .components(separatedBy: CharacterSet(charactersIn: " ,、\n\t"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }

    private func loadMemoAndTags() {
        let record = indexService.record(for: asset, ocrService: ocrService)
        memoDraft = record.userMemo
        tagsDraft = record.userTags.joined(separator: " ")
    }

    private var ocrPanel: some View {
        let status = ocrService.status(for: asset)
        let result = ocrService.result(for: asset)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("端末内OCR", systemImage: "text.viewfinder")
                    .font(.headline)
                    .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))

                Spacer()

                Label(status.title, systemImage: status.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor(status))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            Text("この写真を1枚だけ端末内で読み取ります。外部OCR APIは使いません。")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                OCRInfoRow(title: "状態", value: status.title)

                if let result {
                    OCRInfoRow(title: "処理日時", value: result.processedAtLabel)
                    OCRInfoRow(title: "言語", value: result.ocrLanguage)

                    if let errorMessage = result.errorMessage, errorMessage.isEmpty == false {
                        OCRInfoRow(title: "失敗理由", value: errorMessage)
                    }
                }
            }
            .padding(12)
            .background(.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))

            Button {
                Task {
                    await runOCRIfPossible()
                }
            } label: {
                Label(ocrButtonTitle(for: status), systemImage: "doc.text.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(displayImage == nil || asset.mediaType != .image || ocrService.isProcessing(asset))

            if status == .completed || status == .completedNoText || status == .cloudPending || status == .skipped || status == .failed {
                Button(role: .destructive) {
                    showingClearOCRConfirmation = true
                } label: {
                    Label("OCR結果を削除", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(ocrService.isProcessing(asset))

                Text("削除するのはしまい箱内のOCR文字だけです。元写真・元動画は削除・変更されません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if status == .processing {
                ProgressView("OCR処理中")
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let result, result.ocrStatus == .completed {
                Text(result.ocrText)
                    .font(.body)
                    .foregroundStyle(Color(red: 0.09, green: 0.18, blue: 0.30))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 8))
            } else if let result, result.ocrStatus == .completedNoText {
                Text("文字は見つかりませんでした。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let result, result.ocrStatus == .cloudPending {
                Text(result.errorMessage ?? "iCloud上の写真です。iCloud取得を許可すると再試行できます。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let result, result.ocrStatus == .skipped {
                Text(result.errorMessage ?? "この写真はOCR対象から除外されました。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let result, result.ocrStatus == .failed {
                Text(result.errorMessage ?? "読み取りに失敗しました。")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(asset.mediaType == .image ? "OCR結果はここに表示されます。" : "動画はOCR対象外です。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.white.opacity(0.76), in: RoundedRectangle(cornerRadius: 8))
    }

    private func ocrButtonTitle(for status: OCRStatus) -> String {
        switch status {
        case .unprocessed:
            "この写真をOCR"
        case .processing:
            "OCR中"
        case .completed, .completedNoText, .cloudPending, .skipped, .failed:
            "再OCR"
        }
    }

    private func statusColor(_ status: OCRStatus) -> Color {
        switch status {
        case .unprocessed:
            .secondary
        case .processing:
            Color(red: 0.16, green: 0.42, blue: 0.75)
        case .completed:
            Color(red: 0.14, green: 0.55, blue: 0.32)
        case .completedNoText, .skipped:
            Color(red: 0.36, green: 0.42, blue: 0.48)
        case .cloudPending:
            Color(red: 0.16, green: 0.42, blue: 0.75)
        case .failed:
            Color(red: 0.75, green: 0.24, blue: 0.18)
        }
    }

    @ViewBuilder
    private var imagePreview: some View {
        if let displayImage {
            Image(uiImage: displayImage)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.08), radius: 14, x: 0, y: 8)
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(.white.opacity(0.80))
                .frame(height: 260)
                .overlay {
                    if isLoadingImage {
                        ProgressView("読み込み中")
                    } else {
                        Image(systemName: asset.mediaType == .video ? "video.fill" : "photo")
                            .font(.largeTitle)
                            .foregroundStyle(Color(red: 0.16, green: 0.42, blue: 0.75))
                    }
                }
        }
    }
}

private struct PhotoStateMutation: Equatable, Sendable {
    let assetIdentifiers: [String]
    let before: PhotoDisplayState
    let after: PhotoDisplayState
}

private struct DetailRow: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.subheadline)
                .foregroundStyle(Color(red: 0.09, green: 0.18, blue: 0.30))
                .textSelection(.enabled)
        }
    }
}

private struct OCRInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)

            Text(value)
                .font(.caption)
                .foregroundStyle(Color(red: 0.09, green: 0.18, blue: 0.30))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
    }
}
