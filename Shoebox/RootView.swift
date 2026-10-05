import Photos
import SwiftUI

struct RootView: View {
    @Environment(PhotoLibrary.self) private var library
    @Environment(ProgressStore.self) private var store
    @State private var session: ReviewSession?
    @State private var opening: MonthKey?

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            switch library.access {
            case .notDetermined, .requesting, .denied, .restricted:
                AccessGate()
            case .authorized, .limited:
                if let session {
                    ReviewView(session: session) { deleted in
                        if deleted { library.invalidate(session.month) }
                        self.session = nil
                    }
                    .transition(.opacity)
                } else {
                    MonthListView { key in
                        guard opening == nil else { return }
                        opening = key
                        Task {
                            let s = await ReviewSession.open(month: key, store: store)
                            guard opening == key else { return }
                            withAnimation(.easeOut(duration: 0.2)) {
                                session = s
                                opening = nil
                            }
                        }
                    }
                    .transition(.opacity)
                    .overlay {
                        if let opening {
                            OpeningOverlay(month: opening) { self.opening = nil }
                        }
                    }
                }
            }
        }
        .task { library.start() }
    }
}

private struct OpeningOverlay: View {
    let month: MonthKey
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Theme.bg.opacity(0.75).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                Text("Opening \(month.title)…").font(Theme.display(20)).foregroundStyle(Theme.ink)
                Button("Cancel", action: onCancel).buttonStyle(PillButtonStyle())
            }
            .padding(28)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
        }
    }
}

/// Shown until Shoebox can read Photos. Always says what the permission is and what to do.
private struct AccessGate: View {
    @Environment(PhotoLibrary.self) private var library

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(Theme.amber)
            Text("Shoebox").font(Theme.display(40)).foregroundStyle(Theme.ink)
            AccessBadge()
            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            HStack(spacing: 12) {
                switch library.access {
                case .notDetermined:
                    Button("Allow access to Photos") { Task { await library.requestAccess() } }
                        .buttonStyle(PillButtonStyle(fill: Theme.amber, text: Theme.bg))
                case .requesting:
                    ProgressView().controlSize(.small)
                    Button("Open System Settings", action: openSettings)
                        .buttonStyle(PillButtonStyle())
                default:
                    Button("Open System Settings", action: openSettings)
                        .buttonStyle(PillButtonStyle(fill: Theme.amber, text: Theme.bg))
                    Button("Check again") { library.refreshAccess() }
                        .buttonStyle(PillButtonStyle())
                }
            }
            .padding(.top, 6)
        }
        .padding(40)
    }

    private var icon: String {
        switch library.access {
        case .denied, .restricted: return "lock"
        default: return "shippingbox"
        }
    }

    private var message: String {
        switch library.access {
        case .notDetermined:
            return "Shoebox needs to read your Photos library to show it one month at a time. Nothing leaves this Mac. Click the button, then Allow when macOS asks."
        case .requesting:
            return "Waiting for your answer. macOS should be showing a box asking about Photos. It may be behind this window. If no box appears, open System Settings › Privacy & Security › Photos and turn on Shoebox."
        case .denied:
            return "Open System Settings › Privacy & Security › Photos and turn on Shoebox. Then come back here. If Shoebox is already on, turn it off and on again. After a rebuild in Xcode, macOS can treat Shoebox as a new app."
        case .restricted:
            return "Photos access is blocked on this Mac by Screen Time or a management profile, so Shoebox can't ask for it. Check Screen Time › Content & Privacy."
        default:
            return ""
        }
    }

    private func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
    }
}

/// "Photos access: …" pill, used on the gate and the months screen.
struct AccessBadge: View {
    @Environment(PhotoLibrary.self) private var library

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("Photos access: \(label)")
        }
        .font(Theme.label(12, weight: .semibold))
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().stroke(Theme.line))
    }

    private var label: String {
        switch library.access {
        case .notDetermined: return "not asked yet"
        case .requesting: return "waiting for your answer"
        case .authorized: return "allowed"
        case .limited: return "allowed (limited)"
        case .denied: return "denied"
        case .restricted: return "blocked by Screen Time or a profile"
        }
    }

    private var color: Color {
        switch library.access {
        case .authorized, .limited: return Theme.keep
        case .notDetermined, .requesting: return Theme.amber
        case .denied, .restricted: return Theme.toss
        }
    }
}

/// Shown wherever the library drive is missing.
struct DriveBanner: View {
    @Environment(PhotoLibrary.self) private var library

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.xmark")
            VStack(alignment: .leading, spacing: 2) {
                Text("Photos drive not connected. Plug it in to continue.")
                Text(Config.libraryPath).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("My library is somewhere else now") { library.requireDrive = false }
                .buttonStyle(PillButtonStyle())
                .help("Use whatever library Photos has set as its System Photo Library")
        }
        .font(Theme.label(13))
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.toss.opacity(0.22)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.toss.opacity(0.5)))
    }
}
