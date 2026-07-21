import AppKit

/// Detects two gestures — a quick tap vs. a hold past `holdThreshold` — on
/// two independent triggers:
/// - the mouse middle button (clic molette), always active, needs no special
///   permission on macOS (unlike keyboard global monitoring, see below);
/// - an optional user-configured keyboard shortcut (`keyboardBinding`),
///   which can be a key+modifiers combo, a bare key, or two modifiers held
///   together — set from the "Raccourci de dictée…" settings window.
///
/// Both triggers drive the same `onTap` / `onHoldStart` / `onHoldEnd`
/// closures: a tap toggles listening on/off, a hold does push-to-talk.
///
/// Global keyboard monitoring (`.keyDown`/`.flagsChanged`) requires the app
/// be trusted for Accessibility, which SoTellMe already requests to paste
/// transcribed text — so no extra permission prompt is needed for this.
final class HotkeyManager {
    var onTap: (() -> Void)?
    var onHoldStart: (() -> Void)?
    var onHoldEnd: (() -> Void)?

    /// The optional keyboard shortcut, in addition to the always-active
    /// middle-click. `nil` disables the keyboard trigger entirely.
    var keyboardBinding: HotkeyBinding? {
        didSet { installKeyboardMonitorsIfNeeded() }
    }

    /// Middle mouse button (scroll-wheel click).
    private static let middleButtonNumber = 2
    private static let holdThreshold: TimeInterval = 0.35

    private var isRegistered = false

    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?

    private var isDown = false
    private var holdCommitted = false
    private var holdTimer: Timer?

    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?

    private var keyIsDown = false
    private var keyHoldCommitted = false
    private var keyHoldTimer: Timer?
    private var modifiersActive = false

    func register() {
        isRegistered = true
        let mask: NSEvent.EventTypeMask = [.otherMouseDown, .otherMouseUp]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleMouseEvent(event)
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleMouseEvent(event)
            return event
        }
        installKeyboardMonitorsIfNeeded()
    }

    func unregister() {
        isRegistered = false
        for monitor in [globalMouseMonitor, localMouseMonitor, globalKeyMonitor, localKeyMonitor] {
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
        globalMouseMonitor = nil
        localMouseMonitor = nil
        globalKeyMonitor = nil
        localKeyMonitor = nil
        holdTimer?.invalidate()
        holdTimer = nil
        keyHoldTimer?.invalidate()
        keyHoldTimer = nil
    }

    // MARK: Mouse

    private func handleMouseEvent(_ event: NSEvent) {
        guard event.buttonNumber == Self.middleButtonNumber else { return }

        switch event.type {
        case .otherMouseDown:
            guard !isDown else { return }
            isDown = true
            holdCommitted = false
            holdTimer?.invalidate()
            holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdThreshold, repeats: false) { [weak self] _ in
                self?.commitHold()
            }
        case .otherMouseUp:
            guard isDown else { return }
            isDown = false
            holdTimer?.invalidate()
            holdTimer = nil
            if holdCommitted {
                holdCommitted = false
                onHoldEnd?()
            } else {
                onTap?()
            }
        default:
            break
        }
    }

    private func commitHold() {
        guard isDown else { return }
        holdCommitted = true
        onHoldStart?()
    }

    // MARK: Keyboard

    private func installKeyboardMonitorsIfNeeded() {
        for monitor in [globalKeyMonitor, localKeyMonitor] {
            if let monitor = monitor { NSEvent.removeMonitor(monitor) }
        }
        globalKeyMonitor = nil
        localKeyMonitor = nil
        keyIsDown = false
        keyHoldCommitted = false
        modifiersActive = false
        keyHoldTimer?.invalidate()
        keyHoldTimer = nil

        guard isRegistered, keyboardBinding != nil else { return }

        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleKeyEvent(event)
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleKeyEvent(event)
            return event
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        guard let binding = keyboardBinding else { return }
        let relevantModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])

        if let keyCode = binding.keyCode {
            switch event.type {
            case .keyDown:
                guard !event.isARepeat, event.keyCode == keyCode, relevantModifiers == binding.modifierFlags else { return }
                beginKeyPress()
            case .keyUp:
                guard event.keyCode == keyCode else { return }
                endKeyPress()
            default:
                break
            }
        } else {
            // Modifier-only binding: the gesture is "down" while every
            // required modifier is held (and nothing else), "up" once any of
            // them is released.
            guard event.type == .flagsChanged else { return }
            let isActive = !binding.modifierFlags.isEmpty && relevantModifiers == binding.modifierFlags
            if isActive, !modifiersActive {
                modifiersActive = true
                beginKeyPress()
            } else if !isActive, modifiersActive {
                modifiersActive = false
                endKeyPress()
            }
        }
    }

    private func beginKeyPress() {
        guard !keyIsDown else { return }
        keyIsDown = true
        keyHoldCommitted = false
        keyHoldTimer?.invalidate()
        keyHoldTimer = Timer.scheduledTimer(withTimeInterval: Self.holdThreshold, repeats: false) { [weak self] _ in
            self?.commitKeyHold()
        }
    }

    private func endKeyPress() {
        guard keyIsDown else { return }
        keyIsDown = false
        keyHoldTimer?.invalidate()
        keyHoldTimer = nil
        if keyHoldCommitted {
            keyHoldCommitted = false
            onHoldEnd?()
        } else {
            onTap?()
        }
    }

    private func commitKeyHold() {
        guard keyIsDown else { return }
        keyHoldCommitted = true
        onHoldStart?()
    }
}
