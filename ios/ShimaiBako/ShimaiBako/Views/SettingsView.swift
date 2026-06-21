import Photos
import SwiftUI
import UIKit

struct SettingsView: View {
    @ObservedObject var photoLibrary: PhotoLibraryService
    @ObservedObject var ocrService: OCRService
    @ObservedObject var indexService: PhotoIndexService
    @ObservedObject var learningService: ManualCategoryLearningService
    @ObservedObject var accuracyImprovementService: AccuracyImprovementService
    @ObservedObject var batchOCRJobService: BatchOCRJobService
    @ObservedObject var deviceSafety: DeviceSafetyService
    @ObservedObject var visionClassificationBenchmarkRunner: VisionClassificationBenchmarkRunner
    @ObservedObject var visionFixtureBenchmarkRunner: VisionFixtureBenchmarkRunner
    @Environment(\.openURL) private var openURL
    @State private var pendingReadMode: PhotoReadMode?
    @State private var showingLargeModeSafety = false
    @State private var showingClearAllOCRConfirmation = false
    @State private var showingClearLearningConfirmation = false
    @State private var showingClearAccuracyDataConfirmation = false
    @State private var showingResetLoadingConfirmation = false
    @State private var isResettingLoadingState = false
    @State private var isRepairingReadState = false
    @State private var readStateRepairMessage: String?

    private var indexSummary: PhotoIndexSummary {
        indexService.indexSummary
    }

    private var categoryCounts: [PhotoCategory: Int] {
        indexService.cachedCategoryCounts()
    }

    private var screenshotSubcategoryCounts: [ScreenshotSubcategory: Int] {
        indexService.cachedScreenshotSubcategoryCounts()
    }

    private var ocrCacheCount: Int {
        indexService.indexSummary.completedOCRCount + indexService.indexSummary.failedOCRCount
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        summaryCard
                        IndexStoreStatusContainer()
                        if photoLibrary.shouldShowImportProgress || photoLibrary.shouldShowCompletedImportSummary {
                            PhotoImportProgressCard(photoLibrary: photoLibrary)
                        }
                        loadingModeCard
                        largeLibraryGuideCard
                        iCloudSettingsCard
                        categoryCountsCard
                        learningSettingsCard
                        accuracyImprovementCard
                        ocrSettingsCard
                        cacheMaintenanceCard
                        #if DEBUG
                        visionClassificationBenchmarkCard
                        #endif
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
            .alert("読取結果キャッシュを削除しますか？", isPresented: $showingClearAllOCRConfirmation) {
                Button("キャンセル", role: .cancel) {}
                Button("読取結果キャッシュを削除", role: .destructive) {
                    Task {
                        await indexService.clearAllOCRResults(for: photoLibrary.assets, ocrService: ocrService)
                    }
                }
            } message: {
                Text("しまい箱に保存された読取文字キャッシュを一括で削除します。元写真・元動画は削除・変更されません。削除後、読取文字検索には出なくなります。必要な写真は再読取できます。")
            }
            .alert("分類傾向学習データを削除しますか？", isPresented: $showingClearLearningConfirmation) {
                Button("キャンセル", role: .cancel) {}
                Button("学習データを削除", role: .destructive) {
                    Task {
                        await learningService.clearAll()
                    }
                }
            } message: {
                Text("削除されるのは、手動で直した分類から作った軽量な分類傾向データだけです。元写真・元動画、読取結果、手動分類は削除されません。")
            }
            .alert("精度向上データを削除しますか？", isPresented: $showingClearAccuracyDataConfirmation) {
                Button("キャンセル", role: .cancel) {}
                Button("精度向上データを削除", role: .destructive) {
                    Task {
                        await learningService.clearAll()
                        await accuracyImprovementService.clearImprovementData()
                    }
                }
            } message: {
                Text("分類傾向学習データ、将来の画像特徴量データ、精度向上モードの処理履歴だけを削除します。元写真・元動画、読取結果、手動分類、写真アプリ側のデータは削除されません。")
            }
            .alert("読み込み処理だけを初期化しますか？", isPresented: $showingResetLoadingConfirmation) {
                Button("キャンセル", role: .cancel) {}
                Button("読み込み処理を初期化", role: .destructive) {
                    Task {
                        isResettingLoadingState = true
                        photoLibrary.resetLoadingState()
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        isResettingLoadingState = false
                    }
                }
                .disabled(isResettingLoadingState)
            } message: {
                Text("元写真・元動画は削除されません。読取結果・手動分類・不要候補・メモ・タグは削除しません。読み込みジョブ状態だけをリセットします。")
            }
            .task {
                if photoLibrary.canReadPhotos &&
                    photoLibrary.assets.isEmpty &&
                    photoLibrary.hasRecoverableImportState == false {
                    await photoLibrary.loadRecentAssets()
                }

                if photoLibrary.latestLoadedBatch.isEmpty == false {
                    await indexService.rebuild(for: photoLibrary.latestLoadedBatch, ocrService: ocrService)
                } else if photoLibrary.assets.isEmpty == false {
                    await indexService.rebuild(for: photoLibrary.assets, ocrService: ocrService)
                }
                deviceSafety.refresh()
            }
            .onChange(of: photoLibrary.latestLoadedBatch) {
                let batch = photoLibrary.latestLoadedBatch
                guard batch.isEmpty == false else {
                    return
                }

                Task {
                    await indexService.rebuild(for: batch, ocrService: ocrService)
                }
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
            DetailInfoRow(title: "読取済み件数", value: "\(indexSummary.completedOCRCount)件")
            DetailInfoRow(title: "未読取件数", value: "\(indexSummary.unprocessedOCRCount)件")
            DetailInfoRow(title: "読取失敗件数", value: "\(indexSummary.failedOCRCount)件")
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

            Text("3万枚など大量写真では、まず軽量/標準モードを推奨します。元写真・元動画は表示時だけ読み取ります。")
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

                Button {
                    showingResetLoadingConfirmation = true
                } label: {
                    Label(isResettingLoadingState ? "初期化中" : "読み込み状態をリセット", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isResettingLoadingState)
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
            SafetyBullet("読取は必要なカテゴリから段階的に実行してください")
            SafetyBullet("iCloud写真の取得を許可すると通信が発生する場合があります")
            SafetyBullet("元写真・元動画は外部送信せず、変更もしません")
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

            Text("iCloud取得はApple/iCloud写真からの取得です。外部の読取サービスには送信しません。モバイル通信量に注意してください。")
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

            Divider()

            Label("スクショ細分類", systemImage: "rectangle.stack.badge.person.crop")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))

            Text("スクショは記録・メモ用途として別枠で候補分類します。元写真・元動画は移動しません。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8)
            ], alignment: .leading, spacing: 8) {
                ForEach(ScreenshotSubcategory.allCases) { subcategory in
                    Label("\(subcategory.shortTitle) \(screenshotSubcategoryCounts[subcategory, default: 0])", systemImage: subcategory.systemImage)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color(red: 0.09, green: 0.18, blue: 0.30))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
    }

    private var ocrSettingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("読取設定", systemImage: "text.viewfinder")
                .font(.headline)
                .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))

            DetailInfoRow(title: "読取言語", value: OCRConfiguration.recognitionLanguageTitle)
            DetailInfoRow(title: "読取精度", value: OCRConfiguration.recognitionQualityTitle)
            DetailInfoRow(title: "読取上限", value: "20 / 50 / 100 / 500 / 2,000件")
            DetailInfoRow(title: "画像サイズ", value: OCRConfiguration.maxRecognitionImageLongSideTitle)
            DetailInfoRow(title: "読取済み件数", value: "\(indexSummary.completedOCRCount)件")
            DetailInfoRow(title: "インデックス保存先", value: "端末内")
            DetailInfoRow(title: "保存内容", value: "検索インデックスのみ")

            Text("読取結果、分類結果、検索用メタデータだけを端末内に保存します。元写真・元動画やサムネイル本体は保存しません。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("読取は読取タブで必要な件数だけ段階的に実行します。発熱やバッテリー消費を避けるため、ライブラリ全体の自動読取は行いません。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
    }

    private var learningSettingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("分類傾向学習", systemImage: "slider.horizontal.3")
                .font(.headline)
                .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))

            Toggle(isOn: Binding(
                get: { learningService.isEnabled },
                set: { learningService.updateIsEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("分類傾向学習")
                        .font(.subheadline.weight(.semibold))
                    Text(learningService.isEnabled ? "オン" : "オフ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            DetailInfoRow(title: "学習データ件数", value: "\(learningService.exampleCount)件")
            DetailInfoRow(title: "全体上限", value: "\(learningService.totalLimit)件")
            DetailInfoRow(title: "1分類あたり", value: "\(learningService.perCategoryLimit)件")

            Text("手動で直した分類を端末内で記録し、似たキーワードやスクショの分類候補に反映します。元写真・元動画は保存・送信しません。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("学習は候補分類の補助です。手動分類がある写真では、手動分類を自動判定より優先します。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(role: .destructive) {
                showingClearLearningConfirmation = true
            } label: {
                Label("学習データを削除", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(learningService.exampleCount == 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
    }

    private var accuracyImprovementCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("精度向上モード", systemImage: "sparkles")
                .font(.headline)
                .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))

            Text("夜間や充電中に、分類の精度を少しずつ高めます。元写真・元動画は外部送信せず、端末内で処理します。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: Binding(
                get: { accuracyImprovementService.isEnabled },
                set: { accuracyImprovementService.updateIsEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("精度向上モード")
                        .font(.subheadline.weight(.semibold))
                    Text(accuracyImprovementService.isEnabled ? "オン" : "オフ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("実行タイミング")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(red: 0.09, green: 0.18, blue: 0.30))

                ForEach(AccuracyImprovementSchedule.allCases) { schedule in
                    Button {
                        accuracyImprovementService.updateSchedule(schedule)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: accuracyImprovementService.schedule == schedule ? "checkmark.circle.fill" : "circle")
                                .frame(width: 18)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(schedule.title)
                                    .font(.subheadline.weight(.semibold))
                                Text(schedule.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(red: 0.09, green: 0.18, blue: 0.30))
                }
            }

            DetailInfoRow(title: "推奨時間帯", value: accuracyImprovementService.recommendedTimeRangeTitle)
            DetailInfoRow(title: "現在の状態", value: accuracyImprovementService.state.title)
            DetailInfoRow(title: "最終実行", value: accuracyImprovementService.lastRunTitle)
            DetailInfoRow(title: "開始日時", value: accuracyImprovementService.runStartedTitle)
            DetailInfoRow(title: "終了日時", value: accuracyImprovementService.runEndedTitle)
            DetailInfoRow(title: "実行結果", value: accuracyImprovementService.lastResultTitle)
            DetailInfoRow(title: "実行モード", value: accuracyImprovementService.lastExecutionModeTitle)
            DetailInfoRow(title: "次回試行", value: accuracyImprovementService.nextAttemptTitle)
            DetailInfoRow(title: "1回の上限", value: "\(accuracyImprovementService.maxRunCount)件")
            DetailInfoRow(title: "iCloud取得", value: photoLibrary.iCloudMode.title)

            VStack(alignment: .leading, spacing: 8) {
                Text("実行条件")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(red: 0.09, green: 0.18, blue: 0.30))

                SafetyBullet("充電中またはバッテリー50%以上")
                SafetyBullet("低電力モードOFF")
                SafetyBullet("発熱状態が通常またはやや高め")
                SafetyBullet("空き容量2GB以上推奨")
                SafetyBullet("Wi-Fi推奨")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("iCloud取得")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(red: 0.09, green: 0.18, blue: 0.30))

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
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(red: 0.09, green: 0.18, blue: 0.30))
                }
            }

            ForEach(deviceSafety.notices) { notice in
                SafetyNoticeRow(notice: notice)
            }

            if accuracyImprovementService.state == .running || accuracyImprovementService.totalCount > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    DetailInfoRow(title: "対象件数", value: "\(accuracyImprovementService.totalCount)件")
                    DetailInfoRow(title: "完了件数", value: "\(accuracyImprovementService.completedCount)件")
                    DetailInfoRow(title: "失敗件数", value: "\(accuracyImprovementService.failedCount)件")
                    DetailInfoRow(title: "中断件数", value: "\(accuracyImprovementService.interruptedCount)件")
                    DetailInfoRow(title: "手動分類保護", value: "\(accuracyImprovementService.manualProtectedCount)件")

                    ProgressView(
                        value: Double(accuracyImprovementService.progressCompletedCount),
                        total: Double(max(accuracyImprovementService.totalCount, 1))
                    )
                    .tint(Color(red: 0.16, green: 0.42, blue: 0.75))

                    if let reason = accuracyImprovementService.interruptedReason {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(Color(red: 0.75, green: 0.24, blue: 0.18))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .background(.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
            }

            Text(accuracyImprovementService.lastSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if accuracyImprovementService.state == .running {
                Button(role: .destructive) {
                    accuracyImprovementService.cancel()
                } label: {
                    Label("キャンセル", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    deviceSafety.refresh()
                    accuracyImprovementService.startSmallRun(
                        assets: photoLibrary.assets,
                        ocrService: ocrService,
                        indexService: indexService,
                        deviceSafety: deviceSafety
                    )
                } label: {
                    Label("今すぐ少しだけ実行", systemImage: "play.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(accuracyImprovementService.canStartManualRun == false || photoLibrary.assets.isEmpty)
            }

            Button(role: .destructive) {
                showingClearAccuracyDataConfirmation = true
            } label: {
                Label("精度向上データを削除", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Text("夜間自動実行はiOSの判断により、必ず指定時刻に実行されるとは限りません。初期実装では手動実行を中心にしています。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
    }

    private var cacheMaintenanceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("保存データの整理", systemImage: "internaldrive")
                .font(.headline)
                .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))

            DetailInfoRow(title: "読取結果キャッシュ件数", value: "\(ocrCacheCount)件")
            DetailInfoRow(title: "検索インデックス件数", value: "\(indexService.indexedRecordCount)件")
            DetailInfoRow(title: "保存先", value: "端末内")

            Text("これらはしまい箱内のデータだけを整理します。元写真・元動画は削除されません。写真アプリ側の写真、動画、アルバム、iCloud写真も変更しません。")
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

            Button {
                Task {
                    isRepairingReadState = true
                    let repairSummary = await indexService.repairReadState(for: photoLibrary.assets, ocrService: ocrService)
                    let repairedJobCount = await batchOCRJobService.repairInvalidReadJobState()
                    readStateRepairMessage = "\(repairSummary.message) 古い読取ジョブ状態\(repairedJobCount)件を整理しました。"
                    isRepairingReadState = false
                }
            } label: {
                Label("読取状態を再確認", systemImage: "checklist")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(photoLibrary.assets.isEmpty || isRepairingReadState)

            if isRepairingReadState {
                Label("読取状態を確認しています", systemImage: "hourglass")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if let readStateRepairMessage {
                Text(readStateRepairMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Task {
                    await indexService.rebuildAllCategories(for: photoLibrary.assets, ocrService: ocrService)
                }
            } label: {
                Label("分類を再構築", systemImage: "folder.badge.gearshape")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(photoLibrary.assets.isEmpty)

            Button(role: .destructive) {
                showingClearAllOCRConfirmation = true
            } label: {
                Label("読取結果キャッシュを削除", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(ocrCacheCount == 0)

            Text("読取状態を再確認しても、読取結果、検索インデックス、手動分類、不要候補、メモ、タグは削除しません。読取結果キャッシュ削除は、読取文字を消したい場合だけ使います。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
    }

    #if DEBUG
    private var visionClassificationBenchmarkCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Vision分類ベンチ", systemImage: "eye")
                .font(.headline)
                .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))

            Text("DEBUGビルド限定です。Vision標準機能で分類材料だけを測ります。画像本体、サムネイル、顔画像、顔テンプレートは保存しません。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    visionBenchmarkButton(title: "直近100 full", limit: 100, bucket: .allRecent, mode: .full, prominent: true)
                    visionBenchmarkButton(title: "直近100 gated", limit: 100, bucket: .allRecent, mode: .gated, prominent: false)
                }

                HStack(spacing: 8) {
                    visionBenchmarkButton(title: "スクショ full", limit: 20, bucket: .screenshot, mode: .full, prominent: false)
                    visionBenchmarkButton(title: "スクショ gated", limit: 20, bucket: .screenshot, mode: .gated, prominent: false)
                }

                HStack(spacing: 8) {
                    visionBenchmarkButton(title: "非スクショ full", limit: 20, bucket: .nonScreenshot, mode: .full, prominent: false)
                    visionBenchmarkButton(title: "非スクショ gated", limit: 20, bucket: .nonScreenshot, mode: .gated, prominent: false)
                }
            }

            visionFixtureBenchmarkControls

            visionReviewQueueControls

            Button {
                visionClassificationBenchmarkRunner.refreshSupportedIdentifiersOnly()
            } label: {
                Label("ラベル棚卸しを保存", systemImage: "list.bullet.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(visionClassificationBenchmarkRunner.isRunning)

            if visionClassificationBenchmarkRunner.isRunning {
                Label(visionClassificationBenchmarkRunner.progressText ?? "実行中", systemImage: "hourglass")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if let status = visionClassificationBenchmarkRunner.latestStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let report = visionClassificationBenchmarkRunner.latestReport {
                VStack(alignment: .leading, spacing: 6) {
                    DetailInfoRow(title: "最終実行", value: DateFormatter.localizedString(from: report.finishedAt, dateStyle: .short, timeStyle: .short))
                    DetailInfoRow(title: "Bucket", value: report.bucketTitle)
                    DetailInfoRow(title: "Mode", value: report.probeModeTitle)
                    DetailInfoRow(title: "件数", value: "\(report.actualCount) / \(report.requestedCount)件")
                    DetailInfoRow(title: "平均", value: "\(String(format: "%.1f", report.averageMsPerAsset)) ms/件")
                    DetailInfoRow(title: "画像取得", value: "\(String(format: "%.1f", report.averageImageRequestMs)) ms/件")
                    DetailInfoRow(title: "分類", value: "\(String(format: "%.1f", report.averageClassifyImageMs)) ms/件")
                    DetailInfoRow(title: "書類seg", value: "\(String(format: "%.1f", report.averageDocumentSegmentationMs)) ms/件")
                    DetailInfoRow(title: "失敗", value: "\(report.failedCount)件")
                    DetailInfoRow(title: "スクショ候補", value: "\(report.screenshotCandidateCount)件")
                    DetailInfoRow(title: "人物候補", value: "\(max(report.faceDetectedCount, report.humanDetectedCount))件")
                    DetailInfoRow(title: "書類segmentation", value: "\(report.documentSegmentationDetectedCount)件")
                    DetailInfoRow(title: "書類label", value: "\(report.documentLabelCandidateCount)件")
                    DetailInfoRow(title: "最終書類候補", value: "\(report.finalDocumentCandidateCount)件")
                    DetailInfoRow(title: "建物候補", value: "\(report.likelyBuildingCount)件")
                    DetailInfoRow(title: "看板候補", value: "\(report.likelySignCount)件")
                    DetailInfoRow(title: "OCR優先候補", value: "\(report.ocrPriorityCandidateCount)件")
                    DetailInfoRow(title: "正解ラベル", value: "\(report.groundTruthEvaluation?.labeledAssetCount ?? 0)件")
                    DetailInfoRow(title: "ラベル数", value: "\(report.supportedIdentifiers.totalCount)件")
                }
                .padding(.top, 4)

                visionGroundTruthReview(report: report)
            }

            if let outputPath = visionClassificationBenchmarkRunner.latestOutputDirectoryPath {
                Text("保存先: \(outputPath)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let errorMessage = visionClassificationBenchmarkRunner.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(Color(red: 0.75, green: 0.24, blue: 0.18))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
    }

    private var visionFixtureBenchmarkControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            Label("File fixture benchmark", systemImage: "doc.viewfinder")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))

            Text("ローカル合成fixtureだけを読み、Vision requestとscore経路を確認します。fixture画像は開発用で、製品Bundleには含めません。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Task {
                    await visionFixtureBenchmarkRunner.runSyntheticFixtureBenchmark()
                }
            } label: {
                Label("合成fixtureを実行", systemImage: "play.rectangle")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(visionClassificationBenchmarkRunner.isRunning || visionFixtureBenchmarkRunner.isRunning)

            if visionFixtureBenchmarkRunner.isRunning {
                Label(visionFixtureBenchmarkRunner.latestStatus ?? "合成fixtureを実行中", systemImage: "hourglass")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else if let status = visionFixtureBenchmarkRunner.latestStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if visionFixtureBenchmarkRunner.latestTotalCount > 0 {
                HStack(spacing: 8) {
                    DetailInfoRow(title: "Fixture", value: "\(visionFixtureBenchmarkRunner.latestTotalCount)件")
                    DetailInfoRow(title: "PASS", value: "\(visionFixtureBenchmarkRunner.latestPassCount)件")
                    DetailInfoRow(title: "FAIL", value: "\(visionFixtureBenchmarkRunner.latestFailCount)件")
                }
            }

            if let outputPath = visionFixtureBenchmarkRunner.latestOutputDirectoryPath {
                Text("保存先: \(outputPath)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let errorMessage = visionFixtureBenchmarkRunner.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(Color(red: 0.75, green: 0.24, blue: 0.18))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func visionBenchmarkButton(
        title: String,
        limit: Int,
        bucket: VisionClassificationBenchmarkBucket,
        mode: VisionClassificationProbeMode,
        prominent: Bool
    ) -> some View {
        Group {
            if prominent {
                visionBenchmarkBaseButton(title: title, limit: limit, bucket: bucket, mode: mode)
                    .buttonStyle(.borderedProminent)
            } else {
                visionBenchmarkBaseButton(title: title, limit: limit, bucket: bucket, mode: mode)
                    .buttonStyle(.bordered)
            }
        }
        .disabled(visionClassificationBenchmarkRunner.isRunning)
    }

    private func visionBenchmarkBaseButton(
        title: String,
        limit: Int,
        bucket: VisionClassificationBenchmarkBucket,
        mode: VisionClassificationProbeMode
    ) -> some View {
        Button {
            Task {
                await visionClassificationBenchmarkRunner.run(limit: limit, bucket: bucket, mode: mode)
            }
        } label: {
            Label(title, systemImage: "play.circle")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
        }
    }

    private var visionReviewQueueControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            Label("レビュー対象キュー", systemImage: "square.stack.3d.up")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))

            Text("人間が正解ラベルを付けるためのDEBUGキューです。画像本体やサムネイル本体は保存しません。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    visionReviewRunButton(title: "直近20", limit: 20, bucket: .allRecent, mode: .gated)
                    visionReviewRunButton(title: "直近50", limit: 50, bucket: .allRecent, mode: .gated)
                    visionReviewRunButton(title: "直近100", limit: 100, bucket: .allRecent, mode: .gated)
                }

                HStack(spacing: 8) {
                    visionReviewRunButton(title: "スクショ20", limit: 20, bucket: .screenshot, mode: .gated)
                    visionReviewRunButton(title: "非スクショ20", limit: 20, bucket: .nonScreenshot, mode: .full)
                }
            }

            if visionClassificationBenchmarkRunner.latestReport != nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        visionFilteredQueueButton(title: "OCR優先20", kind: .ocrPriority)
                        visionFilteredQueueButton(title: "建物20", kind: .building)
                        visionFilteredQueueButton(title: "工事20", kind: .constructionSite)
                        visionFilteredQueueButton(title: "看板20", kind: .sign)
                        visionFilteredQueueButton(title: "白板20", kind: .whiteboard)
                        visionFilteredQueueButton(title: "書類20", kind: .document)
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 40)
                .clipped()
            } else {
                Text("候補別キューは、先に直近100件などのベンチを実行すると作れます。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func visionReviewRunButton(
        title: String,
        limit: Int,
        bucket: VisionClassificationBenchmarkBucket,
        mode: VisionClassificationProbeMode
    ) -> some View {
        Button {
            Task {
                await visionClassificationBenchmarkRunner.runReviewQueue(
                    title: title,
                    limit: limit,
                    bucket: bucket,
                    mode: mode
                )
            }
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(visionClassificationBenchmarkRunner.isRunning)
    }

    private func visionFilteredQueueButton(
        title: String,
        kind: VisionBenchmarkReviewQueueKind
    ) -> some View {
        Button {
            visionClassificationBenchmarkRunner.prepareReviewQueue(kind: kind, limit: 20)
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.bordered)
        .disabled(visionClassificationBenchmarkRunner.isRunning)
    }

    @ViewBuilder
    private func visionGroundTruthReview(report: VisionClassificationBenchmarkReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            Label("正解ラベルレビュー", systemImage: "checklist")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))

            Text("保存するのはハッシュ化IDと正解ラベルだけです。サムネイルは表示のみで、画像本体・サムネイル本体・顔画像・顔テンプレートは保存しません。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            visionGroundTruthSummary

            DetailInfoRow(title: "現在のキュー", value: visionClassificationBenchmarkRunner.reviewQueueTitle)
            DetailInfoRow(title: "レビュー済み", value: "\(visionClassificationBenchmarkRunner.reviewQueueLabeledCount) / \(visionClassificationBenchmarkRunner.reviewQueueCount)件")
            DetailInfoRow(title: "未ラベル", value: "\(visionClassificationBenchmarkRunner.reviewQueueUnlabeledCount)件")

            if visionClassificationBenchmarkRunner.reviewQueueCount == 0 {
                Text("レビュー対象キューがありません。上の「レビュー対象キュー」から直近20件などを作成してください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let current = visionClassificationBenchmarkRunner.currentReviewResult {
                VisionGroundTruthReviewCard(
                    result: current,
                    runner: visionClassificationBenchmarkRunner
                )
            }

            HStack(spacing: 8) {
                Button {
                    visionClassificationBenchmarkRunner.evaluateLatestGroundTruth()
                } label: {
                    Label("ラベル済みデータで評価", systemImage: "chart.bar.doc.horizontal")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    visionClassificationBenchmarkRunner.exportLatestGroundTruthEvaluation()
                } label: {
                    Label("評価をexport", systemImage: "square.and.arrow.down")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            if visionClassificationBenchmarkRunner.latestGroundTruthEvaluation?.labeledAssetCount == 0 {
                Text("正解ラベルがないため評価できません。20〜50件ほど手動ラベルを付けるとprecision / recallを確認できます。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 8)
    }

    private var visionGroundTruthSummary: some View {
        let summary = visionClassificationBenchmarkRunner.groundTruthSummary
        let visibleTags: [VisionBenchmarkGroundTruthTag] = [
            .screenshot,
            .ocrNeeded,
            .document,
            .receipt,
            .sign,
            .whiteboard,
            .building,
            .constructionSite,
            .unknown
        ]

        return VStack(alignment: .leading, spacing: 6) {
            DetailInfoRow(title: "合計レビュー済み", value: "\(summary.reviewedCount)件")
            DetailInfoRow(title: "評価対象", value: "\(summary.evaluableCount)件")

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 6)], spacing: 6) {
                ForEach(visibleTags) { tag in
                    let count = summary.tagSummaries.first { $0.tag == tag }?.count ?? 0
                    Text("\(tag.title): \(count)")
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity)
                        .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(Color(red: 0.09, green: 0.18, blue: 0.30))
                }
            }
        }
    }
    #endif

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

            Text("読取は端末内処理です。元写真・元動画は外部送信せず、変更もしません。大量写真では軽量/標準モードから始めてください。")
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
        SafetyPolicyCard()
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
            if photoLibrary.latestLoadedBatch.isEmpty == false {
                await indexService.rebuild(for: photoLibrary.latestLoadedBatch, ocrService: ocrService)
            }
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
            "許可された範囲から写真を読み込み、検索と読取を端末内で実行します。"
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
                        SafetyBullet("元写真・元動画は変更しませんが、大規模処理前は念のためバックアップを推奨します")
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

#if DEBUG
private struct VisionGroundTruthReviewCard: View {
    let result: VisionClassificationProbeResult
    @ObservedObject var runner: VisionClassificationBenchmarkRunner
    @State private var thumbnail: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(
                    "\(runner.currentReviewNumber) / \(runner.reviewQueueCount)件",
                    systemImage: "photo.on.rectangle"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(red: 0.07, green: 0.18, blue: 0.31))

                Spacer()

                Text(runner.isGroundTruthTagSelected(.unknown, for: result) ? "判定不能" : "レビュー中")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.75), in: Capsule())
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 10) {
                Group {
                    if let thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.black.opacity(0.08))
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 4) {
                    Text(String(result.assetIdentifierHash.prefix(12)))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)

                    Text(result.topVisualLabels.prefix(5).map { label in
                        "\(label.identifier) \(String(format: "%.2f", label.confidence))"
                    }.joined(separator: ", ").isEmpty ? "ラベルなし" : result.topVisualLabels.prefix(5).map { label in
                        "\(label.identifier) \(String(format: "%.2f", label.confidence))"
                    }.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(Color(red: 0.09, green: 0.18, blue: 0.30))
                        .lineLimit(3)

                    Text("推定: \(predictedTagsText)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    Text("screenshot \(result.isScreenshot ? "true" : "false") / OCR \(String(format: "%.2f", result.scores.ocrPriorityScore)) / doc \(String(format: "%.2f", result.scores.documentScore)) / building \(String(format: "%.2f", result.scores.buildingScore))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(VisionBenchmarkGroundTruthTag.allCases) { tag in
                        Button {
                            runner.toggleGroundTruthTag(tag, for: result)
                        } label: {
                            Text(tag.title)
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .foregroundStyle(isSelected(tag) ? .white : Color(red: 0.09, green: 0.18, blue: 0.30))
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(isSelected(tag) ? Color(red: 0.16, green: 0.42, blue: 0.75) : Color.white.opacity(0.9))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 30)
            .clipped()

            HStack(spacing: 8) {
                Button {
                    runner.moveToPreviousReviewItem()
                } label: {
                    Label("前へ", systemImage: "chevron.left")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    runner.skipCurrentReviewItem()
                } label: {
                    Label("スキップ", systemImage: "forward")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    runner.saveCurrentReviewAndAdvance()
                } label: {
                    Label("保存して次へ", systemImage: "checkmark")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            HStack(spacing: 8) {
                Button {
                    runner.markCurrentReviewUnknown()
                } label: {
                    Label("判定不能", systemImage: "questionmark.circle")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    runner.clearGroundTruthTags(for: result)
                } label: {
                    Label("ラベルをクリア", systemImage: "eraser")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
        .task(id: result.assetIdentifierHash) {
            thumbnail = await runner.thumbnail(for: result)
        }
    }

    private func isSelected(_ tag: VisionBenchmarkGroundTruthTag) -> Bool {
        runner.isGroundTruthTagSelected(tag, for: result)
    }

    private var predictedTagsText: String {
        let tags = result.predictedGroundTruthTags.map(\.title).sorted()
        return tags.isEmpty ? "なし" : tags.joined(separator: "、")
    }
}
#endif
