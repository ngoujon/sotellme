import AppKit

/// Watches the user-configured keyboard shortcut (`keyboardBinding`), which
/// can be a key+modifiers combo, a bare function key, or modifier keys held
/// together. This is the main trigger for dictation; it's set from the
/// "Raccourci de dictée…" settings window and does nothing until one is
/// configured.
///
/// Push-to-talk: pressing the shortcut fires `onPress` (dictation starts),
/// releasing it fires `onRelease` (dictation stops).
///
/// For modifier-only bindings (e.g. ⌃⌥), pressing any regular key while the
/// modifiers are still held means the user is typing an ordinary shortcut
/// (⌃⌥T…), not dictating, so the press is taken back via `onCancel`.
///
/// Global keyboard monitoring (`.keyDown`/`.flagsChanged`) requires the app
/// be trusted for Accessibility, which SoTellMe already requests to type
/// transcribed text — so no extra permission prompt is needed for this.
final class HotkeyManager {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onCancel: (() -> Void)?

    /// The keyboard shortcut that drives dictation. `nil` disables the
    /// trigger entirely.
    var keyboardBinding: HotkeyBinding? {
        didSet { installKeyboardMonitorsIfNeeded() }
    }

    /// While `true`, key events are ignored — set while the settings window
    /// records a new shortcut, so pressing the current one there doesn't
    /// also start a dictation.
    var isSuspended = false {
        didSet { if isSuspended { isHeld = false } }
    }

    private var isRegistered = false

    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?

    /// Whether the shortcut is currently held (the press already fired and
    /// the release hasn't yet).
    private var isHeld = false

    func register() {
        isRegistered = true
        installKeyboardMonitorsIfNeeded()
    }

    func unregister() {
        isRegistered = false
        removeMonitors()
    }

    /// Re-creates the event monitors. Needed after Accessibility is granted
    /// while the app is running: monitors installed while untrusted never
    /// start receiving events on their own.
    func reinstallMonitors() {
        installKeyboardMonitorsIfNeeded()
    }

    private func removeMonitors() {
        for monitor in [globalKeyMonitor, localKeyMonitor] {
            if let monitor = monitor { NSEvent.removeMonitor(monitor) }
        }
        globalKeyMonitor = nil
        localKeyMonitor = nil
        isHeld = false
    }

    private func installKeyboardMonitorsIfNeeded() {
        removeMonitors()
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
        guard !isSuspended, let binding = keyboardBinding else { return }
        let activeModifiers = HotkeyBinding.activeModifierKeyCodes(from: event)

        if let keyCode = binding.keyCode {
            // The release is the key itself going up, whatever modifiers
            // were let go of first.
            guard event.type != .flagsChanged, event.keyCode == keyCode else { return }
            if event.type == .keyDown {
                guard !event.isARepeat, !isHeld, activeModifiers == binding.modifierKeyCodes else { return }
                isHeld = true
                onPress?()
            } else if event.type == .keyUp, isHeld {
                isHeld = false
                onRelease?()
            }
        } else {
            // Modifier-only binding: pressed once exactly the required
            // physical modifier keys are held, released as soon as they no
            // longer are.
            if event.type == .keyDown {
                if isHeld {
                    isHeld = false
                    onCancel?()
                }
                return
            }
            guard event.type == .flagsChanged else { return }
            let isActive = !binding.modifierKeyCodes.isEmpty && activeModifiers == binding.modifierKeyCodes
            if isActive, !isHeld {
                isHeld = true
                onPress?()
            } else if !isActive, isHeld {
                isHeld = false
                onRelease?()
            }
        }
    }
}
