import AVFoundation
import AppKit
import Photos

/// Read-only access to pixels and video. Never writes to the library.
enum MediaLoader {
    static let manager = PHCachingImageManager()

    static func imageOptions(fast: Bool) -> PHImageRequestOptions {
        let opts = PHImageRequestOptions()
        opts.deliveryMode = fast ? .fastFormat : .opportunistic
        opts.resizeMode = .fast
        opts.isNetworkAccessAllowed = true
        return opts
    }

    /// Yields a quick low-res image first, then the sharp one.
    static func images(for asset: PHAsset, targetSize: CGSize, fill: Bool = false, fast: Bool = false) -> AsyncStream<NSImage> {
        AsyncStream { cont in
            let id = manager.requestImage(for: asset,
                                          targetSize: targetSize,
                                          contentMode: fill ? .aspectFill : .aspectFit,
                                          options: imageOptions(fast: fast)) { image, info in
                if let image { cont.yield(image) }
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                if !degraded || cancelled || info?[PHImageErrorKey] != nil { cont.finish() }
            }
            cont.onTermination = { _ in manager.cancelImageRequest(id) }
        }
    }

    static func preheat(_ assets: [PHAsset]) {
        guard !assets.isEmpty else { return }
        manager.startCachingImages(for: assets, targetSize: Config.previewPixels,
                                   contentMode: .aspectFit, options: imageOptions(fast: false))
    }

    static func stopPreheat(_ assets: [PHAsset]) {
        guard !assets.isEmpty else { return }
        manager.stopCachingImages(for: assets, targetSize: Config.previewPixels,
                                  contentMode: .aspectFit, options: imageOptions(fast: false))
    }

    static func playerItem(for asset: PHAsset) async -> AVPlayerItem? {
        await withCheckedContinuation { cont in
            let opts = PHVideoRequestOptions()
            opts.isNetworkAccessAllowed = true
            opts.deliveryMode = .automatic
            manager.requestPlayerItem(forVideo: asset, options: opts) { item, _ in
                cont.resume(returning: item)
            }
        }
    }

    static func livePhoto(for asset: PHAsset) async -> PHLivePhoto? {
        await withCheckedContinuation { cont in
            let opts = PHLivePhotoRequestOptions()
            opts.isNetworkAccessAllowed = true
            opts.deliveryMode = .highQualityFormat
            var resumed = false
            manager.requestLivePhoto(for: asset, targetSize: Config.previewPixels,
                                     contentMode: .aspectFit, options: opts) { photo, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !resumed, !degraded || photo == nil else { return }
                resumed = true
                cont.resume(returning: photo)
            }
        }
    }
}
