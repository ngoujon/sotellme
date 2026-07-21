import AppKit

/// Detects two gestures — a quick tap vs. a hold past `holdThreshold` — on
/// the user-configured keyboard shortcut (`keyboardBinding`), which can be a
/// key+modifiers combo, a bare key, or two modifiers held together. This is
/// the only trigger for dictation; it's set from the "Raccourci de dictée…"
/// settings window and does nothing until one is configured.
///
/// A tap toggles listening on/off, a hold does push-to-talk, driving
/// `onTap` / `onHoldStart` / `onHoldEnd`.
///
/// Global keyboard monitoring (`.keyDown`/`.flagsChanged`) requires the app
/// be trusted for Accessibility, which SoTellMe already requests to paste
/// transcribed text — so no extra permission prompt is needed for this.
final class HotkeyManager {
    var onTap: (() -> Void)?
    var onHoldStart: (() -> Void)?
    var onHoldEnd: (() -> Void)?

    /// The keyboard shortcut that drives dictation. `nil` disables the
    /// trigger entirely (no way to start dictation until one is set).
    var keyboardBinding: HotkeyBinding? {
        didSet { installKeyboardMonitorsIfNeeded() }
    }

    private static let holdThreshold: TimeInterval = 0.35

    private var isRegistered = false

    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?

    private var keyIsDown = false
    private var keyHoldCommitted = false
    private var keyHoldTimer: Timer?
    private var modifiersActive = false

    func register() {
        isRegistered = true
        installKeyboardMonitorsIfNeeded()
    }

    func unregister() {
        isRegistered = false
        for monitor in [globalKeyMonitor, localKeyMonitor] {
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
        globalKeyMonitor = nil
        localKeyMonitor = nil
        keyHoldTimer?.invalidate()
        keyHoldTimer = nil
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
        let activeModifiers = HotkeyBinding.activeModifierKeyCodes(from: event)

        if let keyCode = binding.keyCode {
            switch event.type {
            case .keyDown:
                guard !event.isARepeat, event.keyCode == keyCode, activeModifiers == binding.modifierKeyCodes else { return }
                beginKeyPress()
            case .keyUp:
                guard event.keyCode == keyCode else { return }
                endKeyPress()
            default:
                break
            }
        } else {
            // Modifier-only binding: the gesture is "down" while exactly the
            // required physical modifier keys are held, "up" once that's no
            // longer true.
            guard event.type == .flagsChanged else { return }
            let isActive = !binding.modifierKeyCodes.isEmpty && activeModifiers == binding.modifierKeyCodes
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
