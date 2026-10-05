import Photos
import SwiftUI

struct ReviewView: View {
    @Environment(PhotoLibrary.self) private var library
    let session: ReviewSession
    /// Called with `true` if items were deleted.
    let onExit: (Bool) -> Void

    @State private var monitor = InputMonitor()
    @State private var offset: CGFloat = 0
    @State private var flash: Flash?
    @State private var playTick = 0
    @State private var preheated: [PHAsset] = []

    private var canInput: Bool { library.driveConnected && !session.isComplete }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            progressLine
            if !library.driveConnected {
                DriveBanner().padding(.horizontal, 28).padding(.top, 12)
            }
            if session.isComplete {
                SummaryView(session: session,
                            driveConnected: library.driveConnected,
                            onUndo: undo,
                            onDone: onExit)
            } else {
                stage
                infoLine
                controls
            }
        }
        .onAppear {
            monitor.onKeep = { decide(.keep) }
            monitor.onToss = { decide(.toss) }
            monitor.onUndo = { undo() }
            monitor.onPlay = { playTick += 1 }
            monitor.onDrag = { travel in
                if travel == 0 {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { offset = 0 }
                } else {
                    offset = travel * 1.4
                }
            }
            monitor.start()
            preheat()
        }
        .onDisappear {
            monitor.stop()
            MediaLoader.manager.stopCachingImagesForAllAssets()
        }
        .onChange(of: canInput, initial: true) { monitor.isEnabled = canInput }
    }

    // MARK: Actions

    private func decide(_ d: Decision) {
        guard canInput else { return }
        withAnimation(.easeOut(duration: 0.14)) {
            session.decide(d)
            offset = 0
        }
        flash = Flash(kind: d == .keep ? .kept : .tossed)
        preheat()
    }

    private func undo() {
        guard session.canUndo, library.driveConnected else { return }
        withAnimation(.easeOut(duration: 0.14)) {
            session.undo()
            offset = 0
        }
        flash = Flash(kind: .undone)
        preheat()
    }

    private func preheat() {
        let n = session.assets.count
        let start = min(session.index + 1, n)
        let next = Array(session.assets[start..<min(start + 6, n)])
        MediaLoader.stopPreheat(preheated.filter { !next.contains($0) })
        MediaLoader.preheat(next)
        preheated = next
    }

    // MARK: Pieces

    private var topBar: some View {
        HStack(alignment: .center) {
            Button {
                onExit(false)
            } label: {
                Label("Months", systemImage: "chevron.left")
            }
            .buttonStyle(PillButtonStyle())
            .help("Back to all months. Your choices so far are saved.")

            Spacer()

            VStack(spacing: 2) {
                Text(session.month.title).font(Theme.display(24)).foregroundStyle(Theme.ink)
                Text("\(session.assets.count) items").font(Theme.label(11)).foregroundStyle(Theme.muted)
            }

            Spacer()

            HStack(spacing: 10) {
                Chip(value: "\(session.remaining)", label: "left", color: Theme.ink)
                Chip(value: "\(session.markedCount) · \(Format.bytes(session.markedBytes))",
                     label: "to free", color: Theme.toss)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var progressLine: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.line)
                Rectangle().fill(Theme.amber)
                    .frame(width: geo.size.width * Double(session.decidedCount) / Double(max(session.assets.count, 1)))
                    .animation(.easeOut(duration: 0.2), value: session.decidedCount)
            }
        }
        .frame(height: 2)
    }

    private var stage: some View {
        ZStack {
            if let asset = session.current {
                MediaCard(asset: asset, playTick: playTick)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(alignment: offset >= 0 ? .topLeading : .topTrailing) { stamp }
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
                    .offset(x: offset)
                    .rotationEffect(.degrees(Double(offset / 45)), anchor: .bottom)
                    .id(asset.localIdentifier)
                    .transition(.opacity)
                    .simultaneousGesture(drag)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
        .padding(.top, 22)
        .overlay(alignment: .top) {
            if let flash {
                FlashPill(kind: flash.kind)
                    .padding(.top, 34)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    .id(flash.id)
            }
        }
        .animation(.easeOut(duration: 0.15), value: flash)
        .task(id: flash) {
            guard flash != nil else { return }
            try? await Task.sleep(for: .milliseconds(650))
            flash = nil
        }
    }

    @ViewBuilder private var stamp: some View {
        if offset != 0 {
            let keep = offset > 0
            Text(keep ? "KEEP" : "TOSS")
                .font(Theme.display(30, weight: .heavy))
                .kerning(3)
                .foregroundStyle(keep ? Theme.keep : Theme.toss)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(keep ? Theme.keep : Theme.toss, lineWidth: 3))
                .rotationEffect(.degrees(keep ? -12 : 12))
                .padding(26)
                .opacity(min(1, abs(offset) / Config.swipeThreshold))
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { v in
                guard canInput else { return }
                offset = v.translation.width
            }
            .onEnded { v in
                if v.translation.width > Config.swipeThreshold {
                    decide(.keep)
                } else if v.translation.width < -Config.swipeThreshold {
                    decide(.toss)
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { offset = 0 }
                }
            }
    }

    private var infoLine: some View {
        HStack(spacing: 14) {
            if let asset = session.current {
                Text(asset.creationDate?.formatted(date: .complete, time: .shortened) ?? "No date")
                Dot()
                Text(kind(of: asset))
                Dot()
                Text(session.info[asset.localIdentifier].map { Format.bytes($0.size) } ?? "…")
                if let name = session.info[asset.localIdentifier]?.filename {
                    Dot()
                    Text(name).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text("\(session.index + 1) of \(session.assets.count)")
            }
        }
        .font(Theme.label(12))
        .foregroundStyle(Theme.muted)
        .padding(.horizontal, 44)
        .padding(.top, 14)
    }

    private func kind(of asset: PHAsset) -> String {
        if asset.mediaType == .video { return "Video · \(Format.duration(asset.duration))" }
        if asset.mediaSubtypes.contains(.photoLive) { return "Live Photo" }
        if asset.mediaSubtypes.contains(.photoScreenshot) { return "Screenshot" }
        return "Photo"
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Button { decide(.toss) } label: {
                Label("Toss", systemImage: "arrow.left")
                    .frame(width: 120)
            }
            .buttonStyle(PillButtonStyle(fill: Theme.toss.opacity(0.9), text: Theme.bg))

            Button { undo() } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(PillButtonStyle())
            .disabled(!session.canUndo)

            Button { decide(.keep) } label: {
                Label("Keep", systemImage: "arrow.right")
                    .labelStyle(TrailingIconLabelStyle())
                    .frame(width: 120)
            }
            .buttonStyle(PillButtonStyle(fill: Theme.keep.opacity(0.9), text: Theme.bg))
        }
        .disabled(!library.driveConnected)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .safeAreaInset(edge: .bottom) {
            Text("← toss   ·   → keep   ·   space plays   ·   ⌘Z undo   ·   two-finger swipe works too")
                .font(Theme.label(11))
                .foregroundStyle(Theme.muted.opacity(0.75))
                .padding(.bottom, 14)
        }
    }
}

// MARK: - Small views

struct Flash: Equatable {
    enum Kind { case kept, tossed, undone }
    let kind: Kind
    let id = UUID()
}

private struct FlashPill: View {
    let kind: Flash.Kind

    private var style: (text: String, icon: String, color: Color) {
        switch kind {
        case .kept: return ("Kept", "checkmark", Theme.keep)
        case .tossed: return ("Marked to toss", "trash", Theme.toss)
        case .undone: return ("Undone", "arrow.uturn.backward", Theme.amber)
        }
    }

    var body: some View {
        Label(style.text, systemImage: style.icon)
            .font(Theme.label(13, weight: .bold))
            .foregroundStyle(Theme.bg)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Capsule().fill(style.color))
            .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
    }
}

private struct Chip: View {
    let value: String
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Text(value).font(Theme.label(13, weight: .bold)).foregroundStyle(color).monospacedDigit()
            Text(label).font(Theme.label(12)).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().stroke(Theme.line))
    }
}

private struct Dot: View {
    var body: some View { Circle().fill(Theme.line).frame(width: 3, height: 3) }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.title
            configuration.icon
        }
    }
}
