import AVKit
import Photos
import PhotosUI
import SwiftUI

/// Full-size view of one item. `playTick` increments when the user presses space.
struct MediaCard: View {
    let asset: PHAsset
    let playTick: Int

    var body: some View {
        if asset.mediaType == .video {
            VideoCard(asset: asset, playTick: playTick)
        } else if asset.mediaSubtypes.contains(.photoLive) {
            LiveCard(asset: asset, playTick: playTick)
        } else {
            AssetImage(asset: asset)
        }
    }
}

struct AssetImage: View {
    let asset: PHAsset
    var targetSize: CGSize = Config.previewPixels
    var fill = false
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: fill ? .fill : .fit)
            } else {
                ProgressView().controlSize(.small).tint(Theme.muted)
            }
        }
        .task(id: asset.localIdentifier) {
            for await img in MediaLoader.images(for: asset, targetSize: targetSize, fill: fill) {
                image = img
            }
        }
    }
}

struct AssetThumbnail: View {
    let asset: PHAsset

    var body: some View {
        Color.clear
            .overlay(AssetImage(asset: asset, targetSize: CGSize(width: 360, height: 360), fill: true))
            .clipped()
    }
}

// MARK: - Video

@MainActor @Observable
final class VideoController {
    var player: AVPlayer?
    var isPlaying = false
    var isLoading = false
    var progress: Double = 0
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var stopped = false

    func toggle(_ asset: PHAsset) async {
        if let player {
            if isPlaying {
                player.pause()
                isPlaying = false
            } else {
                if progress >= 0.999 { _ = await player.seek(to: .zero) }
                player.play()
                isPlaying = true
            }
            return
        }
        guard !isLoading else { return }
        isLoading = true
        let item = await MediaLoader.playerItem(for: asset)
        isLoading = false
        guard let item, !stopped else { return }

        let p = AVPlayer(playerItem: item)
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
                                                 queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, let d = self.player?.currentItem?.duration, d.isNumeric, d.seconds > 0 else { return }
                self.progress = min(1, time.seconds / d.seconds)
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
                self?.progress = 1
            }
        }
        player = p
        p.play()
        isPlaying = true
    }

    func stop() {
        stopped = true
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        player = nil
        isPlaying = false
    }
}

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        v.player = player
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
    }
}

struct VideoCard: View {
    let asset: PHAsset
    let playTick: Int
    @State private var controller = VideoController()

    var body: some View {
        ZStack {
            if let player = controller.player {
                PlayerSurface(player: player)
            } else {
                AssetImage(asset: asset)
            }

            // Transparent layer so a click anywhere toggles playback.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { Task { await controller.toggle(asset) } }

            if !controller.isPlaying {
                ZStack {
                    Circle().fill(.black.opacity(0.45)).frame(width: 72, height: 72)
                    if controller.isLoading {
                        ProgressView().controlSize(.regular).tint(Theme.ink)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .offset(x: 2)
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if controller.player != nil {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.ink.opacity(0.18))
                        Capsule().fill(Theme.amber).frame(width: geo.size.width * controller.progress)
                    }
                }
                .frame(height: 3)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
                .allowsHitTesting(false)
            }
        }
        .onChange(of: playTick) { Task { await controller.toggle(asset) } }
        .onDisappear { controller.stop() }
    }
}

// MARK: - Live Photo

struct LivePhotoSurface: NSViewRepresentable {
    let livePhoto: PHLivePhoto
    let tick: Int

    final class Coordinator { var lastTick: Int? }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PHLivePhotoView {
        let v = PHLivePhotoView()
        v.livePhoto = livePhoto
        return v
    }

    func updateNSView(_ v: PHLivePhotoView, context: Context) {
        if v.livePhoto !== livePhoto { v.livePhoto = livePhoto }
        if context.coordinator.lastTick != tick {
            context.coordinator.lastTick = tick
            DispatchQueue.main.async { v.startPlayback(with: .full) }
        }
    }
}

struct LiveCard: View {
    let asset: PHAsset
    let playTick: Int
    @State private var livePhoto: PHLivePhoto?
    @State private var localTick = 0
    @State private var loading = false

    var body: some View {
        ZStack {
            if let livePhoto {
                LivePhotoSurface(livePhoto: livePhoto, tick: localTick)
            } else {
                AssetImage(asset: asset)
            }
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { play() }
        }
        .overlay(alignment: .topLeading) {
            Label("LIVE", systemImage: "livephoto")
                .font(Theme.label(11, weight: .bold))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(.black.opacity(0.45)))
                .padding(14)
                .opacity(loading ? 0.5 : 1)
                .allowsHitTesting(false)
        }
        .onChange(of: playTick) { play() }
    }

    private func play() {
        if livePhoto != nil {
            localTick += 1
            return
        }
        guard !loading else { return }
        loading = true
        Task {
            livePhoto = await MediaLoader.livePhoto(for: asset)
            loading = false
            localTick += 1
        }
    }
}
