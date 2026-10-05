import AppKit

/// Arrow keys, space, ⌘Z and two-finger horizontal trackpad swipes, active only on the review screen.
@MainActor
final class InputMonitor {
    var onKeep: () -> Void = {}
    var onToss: () -> Void = {}
    var onUndo: () -> Void = {}
    var onPlay: () -> Void = {}
    /// Live finger travel in points while a swipe is in progress (0 when it ends).
    var onDrag: (CGFloat) -> Void = { _ in }
    var isEnabled = true

    private var monitor: Any?
    private var travel: CGFloat = 0
    private var fired = false

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            let consumed = MainActor.assumeIsolated { self.handle(event) }
            return consumed ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ e: NSEvent) -> Bool {
        guard isEnabled else { return false }
        if e.type == .keyDown { return handleKey(e) }
        if e.type == .scrollWheel { return handleScroll(e) }
        return false
    }

    private func handleKey(_ e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            if e.charactersIgnoringModifiers?.lowercased() == "z" && !flags.contains(.shift) {
                onUndo()
                return true
            }
            return false
        }
        switch e.keyCode {
        case 124, 123, 49:
            // Ignore auto-repeat so holding an arrow can't race through a month.
            if e.isARepeat { return true }
            switch e.keyCode {
            case 124: onKeep()
            case 123: onToss()
            default: onPlay()
            }
            return true
        default:
            return false
        }
    }

    private func handleScroll(_ e: NSEvent) -> Bool {
        guard e.hasPreciseScrollingDeltas else { return false }
        if !e.momentumPhase.isEmpty { return true }

        if e.phase.contains(.began) {
            travel = 0
            fired = false
        }
        if e.phase.contains(.changed), !fired, abs(e.scrollingDeltaX) >= abs(e.scrollingDeltaY) {
            // Positive = fingers moved right, whatever the natural-scrolling setting.
            travel += e.isDirectionInvertedFromDevice ? e.scrollingDeltaX : -e.scrollingDeltaX
            if travel > Config.swipeThreshold {
                fired = true
                onKeep()
            } else if travel < -Config.swipeThreshold {
                fired = true
                onToss()
            } else {
                onDrag(travel)
            }
        }
        if e.phase.contains(.ended) || e.phase.contains(.cancelled) {
            travel = 0
            if !fired { onDrag(0) }
        }
        return true
    }
}
