import AppKit

/// A small window for recording the keyboard shortcut that triggers
/// dictation. Supports a single key, a key+modifiers combo, or two modifier
/// keys held together with no regular key (e.g. ⌃⌥) — left and right
/// Command/Option/Control/Shift are recorded as distinct keys.
final class HotkeySettingsWindowController: NSObject, NSWindowDelegate {
    /// Called whenever the binding changes (new value, or `nil` on clear).
    var onBindingChange: ((HotkeyBinding?) -> Void)?
    /// Called with `true` when recording a new shortcut starts and `false`
    /// when it ends, so the live hotkey can be paused meanwhile.
    var onRecordingChange: ((Bool) -> Void)?

    private var window: NSWindow?
    private var currentLabel: NSTextField?
    private var messageLabel: NSTextField?
    private var recordButton: NSButton?

    private var isRecording = false
    private var peakModifierKeyCodes: Set<UInt16> = []
    private var recordingMonitor: Any?

    func show(currentBinding: HotkeyBinding?) {
        if window == nil {
            buildWindow()
        }
        updateCurrentLabel(currentBinding)
        showMessage(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildWindow() {
        let rect = NSRect(x: 0, y: 0, width: 400, height: 250)
        let w = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Raccourci de dictée"
        w.isReleasedWhenClosed = false
        w.delegate = self

        let content = NSView(frame: rect)

        let info = NSTextField(wrappingLabelWithString: "Choisis le raccourci qui déclenche la dictée : une combinaison (ex. ⌘⇧D), une touche F1–F20, ou deux touches de modification maintenues ensemble (ex. ⌃⌥). Les touches de gauche et de droite (G/D) sont distinguées.")
        info.frame = NSRect(x: 20, y: 178, width: 360, height: 56)
        info.font = .systemFont(ofSize: 11)
        info.textColor = .secondaryLabelColor

        let usage = NSTextField(wrappingLabelWithString: "Maintiens le raccourci enfoncé pendant que tu parles, relâche-le pour arrêter la dictée. Le texte s'écrit en temps réel pendant que tu parles.")
        usage.frame = NSRect(x: 20, y: 140, width: 360, height: 32)
        usage.font = .systemFont(ofSize: 11)
        usage.textColor = .secondaryLabelColor

        let current = NSTextField(labelWithString: "")
        current.frame = NSRect(x: 20, y: 102, width: 360, height: 26)
        current.font = .systemFont(ofSize: 18, weight: .semibold)
        current.alignment = .center

        let message = NSTextField(wrappingLabelWithString: "")
        message.frame = NSRect(x: 20, y: 62, width: 360, height: 34)
        message.font = .systemFont(ofSize: 11)
        message.alignment = .center

        let record = NSButton(title: "Enregistrer un raccourci…", target: self, action: #selector(toggleRecording))
        record.frame = NSRect(x: 20, y: 20, width: 240, height: 32)
        record.bezelStyle = .rounded
        record.keyEquivalent = "\r"

        let clear = NSButton(title: "Effacer", target: self, action: #selector(clearBinding))
        clear.frame = NSRect(x: 270, y: 20, width: 110, height: 32)
        clear.bezelStyle = .rounded

        content.addSubview(info)
        content.addSubview(usage)
        content.addSubview(current)
        content.addSubview(message)
        content.addSubview(record)
        content.addSubview(clear)
        w.contentView = content

        window = w
        currentLabel = current
        messageLabel = message
        recordButton = record
    }

    private func updateCurrentLabel(_ binding: HotkeyBinding?) {
        currentLabel?.stringValue = binding?.displayString ?? "Aucun raccourci défini"
    }

    private func showMessage(_ text: String?, isError: Bool = false) {
        messageLabel?.stringValue = text ?? ""
        messageLabel?.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    @objc private func toggleRecording() {
        if isRecording {
            stopRecording(cancelled: true)
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        peakModifierKeyCodes = []
        onRecordingChange?(true)
        recordButton?.title = "Annuler"
        currentLabel?.stringValue = "…"
        showMessage("Appuie sur le raccourci voulu (Échap pour annuler).")
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handleRecordingEvent(event)
            return nil
        }
    }

    private func handleRecordingEvent(_ event: NSEvent) {
        let activeModifiers = HotkeyBinding.activeModifierKeyCodes(from: event)
        switch event.type {
        case .keyDown:
            if event.keyCode == 53 {
                stopRecording(cancelled: true)
                return
            }
            finalize(HotkeyBinding(keyCode: event.keyCode, modifierKeyCodes: activeModifiers))
        case .flagsChanged:
            peakModifierKeyCodes.formUnion(activeModifiers)
            if activeModifiers.isEmpty, !peakModifierKeyCodes.isEmpty {
                finalize(HotkeyBinding(keyCode: nil, modifierKeyCodes: peakModifierKeyCodes))
            }
        default:
            break
        }
    }

    private func finalize(_ binding: HotkeyBinding) {
        if let problem = binding.problem {
            // Stay in recording mode so the user can directly try another one.
            peakModifierKeyCodes = []
            currentLabel?.stringValue = "…"
            showMessage(problem, isError: true)
            return
        }
        stopRecording(cancelled: false)
        HotkeyBindingStore.save(binding)
        updateCurrentLabel(binding)
        showMessage("Raccourci enregistré ✓")
        onBindingChange?(binding)
    }

    private func stopRecording(cancelled: Bool) {
        guard isRecording else { return }
        isRecording = false
        if let monitor = recordingMonitor {
            NSEvent.removeMonitor(monitor)
        }
        recordingMonitor = nil
        recordButton?.title = "Enregistrer un raccourci…"
        if cancelled {
            updateCurrentLabel(HotkeyBindingStore.load())
            showMessage(nil)
        }
        onRecordingChange?(false)
    }

    @objc private func clearBinding() {
        stopRecording(cancelled: true)
        HotkeyBindingStore.save(nil)
        updateCurrentLabel(nil)
        showMessage("Sans raccourci, la dictée se lance depuis le menu SoTellMe.")
        onBindingChange?(nil)
    }

    func windowWillClose(_ notification: Notification) {
        stopRecording(cancelled: true)
    }
}
