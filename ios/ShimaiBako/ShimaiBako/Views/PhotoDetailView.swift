import Photos
import SwiftUI
import UIKit

struct PhotoDetailView: View {
    @ObservedObject var photoLibrary: PhotoLibraryService
    @ObservedObject var ocrService: OCRService
    @ObservedObject var indexService: PhotoIndexService
    let asset: PhotoAsset
    let automaticallyRunOCR: Bool

    @State private var displayImage: UIImage?
    @State private var isLoadingImage = false
    @State private var didRunAutomaticOCR = false

    init(
        photoLibrary: PhotoLibraryService,
        ocrService: OCRService,
        indexService: PhotoIndexService,
        asset: PhotoAsset,
        automaticallyRunOCR: Bool = false
    ) {
        self.photoLibrary = photoLibrary
        self.ocrService = ocrService
        self.indexService = indexService
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
                        DetailRow(
                            title: "仮想フォルダ",
                            value: "\(indexService.category(for: asset, ocrService: ocrService).title) / 信頼度 \(indexService.confidenceLabel(for: asset, ocrService: ocrService))"
                        )
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
        }
        .navigationTitle("詳細")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: asset.id) {
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
        case .completed, .failed:
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
