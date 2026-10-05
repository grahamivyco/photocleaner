import SwiftUI

/// Darkroom palette: warm near-black, paper-coloured text, amber accent.
enum Theme {
    static let bg = Color(red: 0.082, green: 0.071, blue: 0.059)
    static let surface = Color(red: 0.129, green: 0.110, blue: 0.090)
    static let raised = Color(red: 0.180, green: 0.153, blue: 0.125)
    static let line = Color(red: 0.255, green: 0.220, blue: 0.180)
    static let ink = Color(red: 0.953, green: 0.922, blue: 0.867)
    static let muted = Color(red: 0.635, green: 0.596, blue: 0.533)
    static let amber = Color(red: 0.910, green: 0.640, blue: 0.240)
    static let keep = Color(red: 0.498, green: 0.714, blue: 0.522)
    static let toss = Color(red: 0.878, green: 0.420, blue: 0.310)

    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    static func label(_ size: CGFloat = 12, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

enum Format {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Small capsule button used across the app.
struct PillButtonStyle: ButtonStyle {
    var fill: Color = Theme.raised
    var text: Color = Theme.ink

    func makeBody(configuration: Configuration) -> some View {
        Pill(configuration: configuration, fill: fill, text: text)
    }

    private struct Pill: View {
        let configuration: ButtonStyleConfiguration
        let fill: Color
        let text: Color
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(Theme.label(13, weight: .semibold))
                .foregroundStyle(text)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Capsule().fill(fill.opacity(configuration.isPressed ? 0.75 : 1)))
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.4)
        }
    }
}
