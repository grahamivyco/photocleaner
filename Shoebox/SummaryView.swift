import Photos
import SwiftUI

/// End of a month: review what's marked, rescue anything, then confirm.
struct SummaryView: View {
    let session: ReviewSession
    let driveConnected: Bool
    let onUndo: () -> Void
    let onDone: (Bool) -> Void

    @State private var confirming = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        let marked = session.markedAssets
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 6) {
                    Text(session.assets.isEmpty ? "Nothing in \(session.month.title)" : "\(session.month.title) reviewed")
                        .font(Theme.display(34))
                        .foregroundStyle(Theme.ink)
                    HStack(spacing: 18) {
                        Text("\(session.keptCount) kept").foregroundStyle(Theme.keep)
                        Text("\(marked.count) to toss").foregroundStyle(Theme.toss)
                        Text("frees \(Format.bytes(session.markedBytes))").foregroundStyle(Theme.amber)
                    }
                    .font(Theme.label(15, weight: .semibold))
                }
                .padding(.top, 30)

                if !marked.isEmpty {
                    Text("Click anything below to keep it instead.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 116, maximum: 160), spacing: 10)], spacing: 10) {
                        ForEach(marked, id: \.localIdentifier) { asset in
                            Button {
                                withAnimation(.easeOut(duration: 0.15)) { session.keepInstead(asset) }
                            } label: {
                                AssetThumbnail(asset: asset)
                                    .aspectRatio(1, contentMode: .fill)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(alignment: .bottomLeading) {
                                        if asset.mediaType == .video {
                                            Image(systemName: "video.fill")
                                                .font(.system(size: 10))
                                                .foregroundStyle(Theme.ink)
                                                .padding(6)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .help("Keep this one")
                        }
                    }
                    .padding(.horizontal, 40)
                }

                HStack(spacing: 12) {
                    Button { onUndo() } label: { Label("Undo last", systemImage: "arrow.uturn.backward") }
                        .buttonStyle(PillButtonStyle())
                        .disabled(!session.canUndo || working)
                    Button { onDone(false) } label: { Text("Back to months") }
                        .buttonStyle(PillButtonStyle())
                        .disabled(working)
                    if marked.isEmpty {
                        Button { Task { await finish() } } label: { Label("Mark month done", systemImage: "checkmark") }
                            .buttonStyle(PillButtonStyle(fill: Theme.keep, text: Theme.bg))
                            .disabled(working || !driveConnected)
                    } else {
                        Button { confirming = true } label: {
                            Label("Move \(marked.count) to Recently Deleted", systemImage: "trash")
                        }
                        .buttonStyle(PillButtonStyle(fill: Theme.toss, text: Theme.bg))
                        .disabled(working || !driveConnected)
                    }
                }

                if working { ProgressView().controlSize(.small) }
                if let error {
                    Text(error).font(.system(size: 13)).foregroundStyle(Theme.toss)
                }

                if !marked.isEmpty {
                    Text("Items stay in Photos › Recently Deleted for 30 days. With iCloud Photos on, they also leave your iPhone and iCloud.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 40)
        }
        .confirmationDialog("Move \(marked.count) items (\(Format.bytes(session.markedBytes))) to Recently Deleted?",
                            isPresented: $confirming) {
            Button("Move to Recently Deleted", role: .destructive) { Task { await finish() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can recover them from Recently Deleted in Photos for 30 days.")
        }
    }

    private func finish() async {
        working = true
        error = nil
        do {
            try await session.deleteMarked()
            onDone(true)
        } catch {
            working = false
            self.error = "Nothing was deleted. \(error.localizedDescription)"
        }
    }
}
