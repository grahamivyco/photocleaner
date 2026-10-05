import Photos
import SwiftUI

struct RootView: View {
    @Environment(PhotoLibrary.self) private var library
    @Environment(ProgressStore.self) private var store
    @State private var session: ReviewSession?

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            switch library.access {
            case .unknown:
                Gate(icon: "shippingbox",
                     title: "Shoebox",
                     message: "Go through your photos one month at a time. Keep what matters, toss the rest.\nShoebox needs access to your Photos library. Nothing leaves this Mac.",
                     button: "Open my library") { Task { await library.requestAccess() } }
            case .denied:
                Gate(icon: "lock",
                     title: "No access to Photos",
                     message: "Open System Settings › Privacy & Security › Photos, turn on Shoebox, then reopen the app.",
                     button: "Open System Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
                }
            case .granted:
                if let session {
                    ReviewView(session: session) { deleted in
                        self.session = nil
                        if deleted { Task { await library.buildIndex() } }
                    }
                    .transition(.opacity)
                } else {
                    MonthListView { key in
                        withAnimation(.easeOut(duration: 0.2)) {
                            session = ReviewSession(month: key, store: store)
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
        .task {
            if library.access == .granted && library.months.isEmpty { await library.buildIndex() }
        }
    }
}

private struct Gate: View {
    let icon: String
    let title: String
    let message: String
    let button: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(Theme.amber)
            Text(title).font(Theme.display(40)).foregroundStyle(Theme.ink)
            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button(button, action: action)
                .buttonStyle(PillButtonStyle(fill: Theme.amber, text: Theme.bg))
                .padding(.top, 6)
        }
        .padding(40)
    }
}

/// Shown wherever the library drive is missing.
struct DriveBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.xmark")
            Text("Photos drive not connected. Plug it in to continue.")
            Spacer()
            Text(Config.libraryPath).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
        }
        .font(Theme.label(13))
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.toss.opacity(0.22)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.toss.opacity(0.5)))
    }
}
