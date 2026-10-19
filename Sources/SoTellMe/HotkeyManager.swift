import AppKit

/// Watches the user-configured keyboard shortcut (`keyboardBinding`), which
/// can be a key+modifiers combo, a bare function key, or modifier keys held
/// together. This is the main trigger for dictation; it's set from the
/// "Raccourci de dictée…" settings window and does nothing until one is
/// configured.
///
/// Each press fires `onPress` immediately (one press starts dictation, the
/// next one stops it); releasing the key does nothing.
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
        didSet { if isSuspended { modifiersActive = false } }
    }

    private var isRegistered = false

    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?

    /// For modifier-only bindings: whether the required modifiers are
    /// currently held (the press already fired).
    private var modifiersActive = false

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
        modifiersActive = false
    }

    private func installKeyboardMonitorsIfNeeded() {
        removeMonitors()
        guard isRegistered, keyboardBinding != nil else { return }

        let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged]
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
            guard event.type == .keyDown, !event.isARepeat,
                  event.keyCode == keyCode, activeModifiers == binding.modifierKeyCodes else { return }
            onPress?()
        } else {
            // Modifier-only binding: fires once when exactly the required
            // physical modifier keys become held; re-arms once released.
            if event.type == .keyDown {
                if modifiersActive {
                    modifiersActive = false
                    onCancel?()
                }
                return
            }
            guard event.type == .flagsChanged else { return }
            let isActive = !binding.modifierKeyCodes.isEmpty && activeModifiers == binding.modifierKeyCodes
            if isActive, !modifiersActive {
                modifiersActive = true
                onPress?()
            } else if !isActive {
                modifiersActive = false
            }
        }
    }
}
