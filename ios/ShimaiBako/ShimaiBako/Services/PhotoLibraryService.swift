import Combine
import Foundation
import Photos
import PhotosUI
import UIKit

@MainActor
final class PhotoLibraryService: ObservableObject {
    @Published private(set) var authorizationStatus: PHAuthorizationStatus
    @Published private(set) var assets: [PhotoAsset] = []
    @Published private(set) var thumbnails: [String: UIImage] = [:]
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let imageManager = PHCachingImageManager()
    private let fetchLimit = 100
    private let assumesAuthorizedForDebugRun: Bool

    init() {
        #if DEBUG
        assumesAuthorizedForDebugRun = ProcessInfo.processInfo.arguments.contains("-ShimaiBakoAssumePhotosAuthorized")
        #else
        assumesAuthorizedForDebugRun = false
        #endif

        authorizationStatus = assumesAuthorizedForDebugRun ? .authorized : PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    var canReadPhotos: Bool {
        assumesAuthorizedForDebugRun || authorizationStatus == .authorized || authorizationStatus == .limited
    }

    var readLimitTitle: String {
        "直近\(fetchLimit)件"
    }

    var statusTitle: String {
        switch authorizationStatus {
        case .notDetermined:
            "未確認"
        case .authorized:
            "すべての写真を読み取り可能"
        case .limited:
            "選択した写真のみ読み取り可能"
        case .denied:
            "アクセスが拒否されています"
        case .restricted:
            "アクセスが制限されています"
        @unknown default:
            "不明"
        }
    }

    func prepare() async {
        refreshAuthorizationStatus()
    }

    func refreshAuthorizationStatus() {
        guard assumesAuthorizedForDebugRun == false else {
            authorizationStatus = .authorized
            return
        }

        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func requestAuthorization() async {
        let status = await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }

        authorizationStatus = status
    }

    func presentLimitedLibraryPicker() {
        guard authorizationStatus == .limited,
              assumesAuthorizedForDebugRun == false else {
            return
        }

        guard let viewController = Self.activeViewController() else {
            errorMessage = "写真の選択画面を開けませんでした。"
            return
        }

        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: viewController)

        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            refreshAuthorizationStatus()
            await loadRecentAssets()
        }
    }

    func loadRecentAssets() async {
        guard canReadPhotos else {
            assets = []
            thumbnails = [:]
            return
        }

        isLoading = true
        errorMessage = nil

        let options = PHFetchOptions()
        options.fetchLimit = fetchLimit
        options.includeHiddenAssets = false
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let result = PHAsset.fetchAssets(with: options)
        var nextAssets: [PhotoAsset] = []
        nextAssets.reserveCapacity(min(result.count, fetchLimit))

        result.enumerateObjects { asset, _, _ in
            nextAssets.append(PhotoAsset(asset: asset))
        }

        assets = nextAssets
        isLoading = false
    }

    func cachedThumbnail(for asset: PhotoAsset) -> UIImage? {
        thumbnails[asset.id]
    }

    func requestThumbnail(for asset: PhotoAsset, targetSize: CGSize) {
        guard thumbnails[asset.id] == nil else {
            return
        }

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false

        imageManager.requestImage(
            for: asset.asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { [weak self] image, _ in
            guard let image else {
                return
            }

            Task { @MainActor in
                self?.thumbnails[asset.id] = image
            }
        }
    }

    func requestDisplayImage(for asset: PhotoAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false

            var didResume = false

            imageManager.requestImage(
                for: asset.asset,
                targetSize: CGSize(width: 1800, height: 1800),
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let isCancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let hasError = info?[PHImageErrorKey] != nil

                guard didResume == false else {
                    return
                }

                if let image, isDegraded == false {
                    didResume = true
                    continuation.resume(returning: image)
                } else if isCancelled || hasError {
                    didResume = true
                    continuation.resume(returning: image)
                }
            }
        }
    }

    private static func activeViewController() -> UIViewController? {
        let rootViewController = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .rootViewController

        return rootViewController?.topMostPresentedViewController()
    }
}

private extension UIViewController {
    func topMostPresentedViewController() -> UIViewController {
        if let navigationController = self as? UINavigationController,
           let visibleViewController = navigationController.visibleViewController {
            return visibleViewController.topMostPresentedViewController()
        }

        if let tabBarController = self as? UITabBarController,
           let selectedViewController = tabBarController.selectedViewController {
            return selectedViewController.topMostPresentedViewController()
        }

        if let presentedViewController {
            return presentedViewController.topMostPresentedViewController()
        }

        return self
    }
}
