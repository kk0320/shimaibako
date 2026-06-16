import Photos
import SwiftUI
import UIKit

struct PhotoDetailView: View {
    @ObservedObject var photoLibrary: PhotoLibraryService
    @ObservedObject var ocrService: OCRService
    let asset: PhotoAsset

    @State private var displayImage: UIImage?
    @State private var isLoadingImage = false

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
                    }
                    .padding(16)
                    .background(.white.opacity(0.80), in: RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 10) {
                        SafetyRow(title: "写真は外部送信しません", systemImage: "lock.shield.fill")
                        SafetyRow(title: "削除・移動・編集は行いません", systemImage: "hand.raised.fill")
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
        }
    }

    private var ocrPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("端末内OCR", systemImage: "text.viewfinder")
                    .font(.headline)
                    .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))

                Spacer()
            }

            Text("この写真を1枚だけ端末内で読み取ります。外部OCR APIは使いません。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                Task {
                    if let displayImage {
                        await ocrService.recognize(asset: asset, image: displayImage)
                    }
                }
            } label: {
                Label(ocrService.isProcessing(asset) ? "OCR中" : "この写真をOCR", systemImage: "doc.text.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(displayImage == nil || asset.mediaType != .image || ocrService.isProcessing(asset))

            if let text = ocrService.text(for: asset) {
                Text(text)
                    .font(.body)
                    .foregroundStyle(Color(red: 0.09, green: 0.18, blue: 0.30))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 8))
            } else if let errorMessage = ocrService.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            } else {
                Text(asset.mediaType == .image ? "OCR結果はここに表示されます。" : "動画はOCR対象外です。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.white.opacity(0.76), in: RoundedRectangle(cornerRadius: 8))
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
