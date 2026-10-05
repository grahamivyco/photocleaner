import SwiftUI

@main
struct ShoeboxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var library = PhotoLibrary()
    @State private var store = ProgressStore()

    var body: some Scene {
        Window("Shoebox", id: "main") {
            RootView()
                .environment(library)
                .environment(store)
                .preferredColorScheme(.dark)
                .tint(Theme.amber)
                .frame(minWidth: 900, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 860)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
