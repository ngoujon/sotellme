import AppKit

/// A small window for recording an optional keyboard shortcut (in addition
/// to the always-available middle-click) to start/stop dictation. Supports
/// a single key, a key+modifiers combo, or two modifier keys held together
/// with no regular key (e.g. ⌃⌥).
final class HotkeySettingsWindowController: NSObject, NSWindowDelegate {
    /// Called whenever the binding changes (new value, or `nil` on clear).
    var onBindingChange: ((HotkeyBinding?) -> Void)?

    private var window: NSWindow?
    private var currentLabel: NSTextField?
    private var recordButton: NSButton?

    private var isRecording = false
    private var peakModifiers: NSEvent.ModifierFlags = []
    private var recordingMonitor: Any?

    func show(currentBinding: HotkeyBinding?) {
        if window == nil {
            buildWindow()
        }
        updateCurrentLabel(currentBinding)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildWindow() {
        let rect = NSRect(x: 0, y: 0, width: 380, height: 180)
        let w = NSWindow(contentRect: rect, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Raccourci de dictée"
        w.isReleasedWhenClosed = false
        w.delegate = self

        let content = NSView(frame: rect)

        let info = NSTextField(wrappingLabelWithString: "Le clic molette reste toujours actif. Tu peux définir en plus un raccourci clavier : une touche seule, une combinaison (ex. ⌘⇧D), ou deux touches de modification maintenues ensemble (ex. ⌃⌥).")
        info.frame = NSRect(x: 20, y: 108, width: 340, height: 55)
        info.font = .systemFont(ofSize: 11)
        info.textColor = .secondaryLabelColor

        let current = NSTextField(labelWithString: "")
        current.frame = NSRect(x: 20, y: 76, width: 340, height: 24)
        current.font = .systemFont(ofSize: 16, weight: .semibold)
        current.alignment = .center

        let record = NSButton(title: "Enregistrer un raccourci…", target: self, action: #selector(toggleRecording))
        record.frame = NSRect(x: 30, y: 24, width: 200, height: 32)
        record.bezelStyle = .rounded

        let clear = NSButton(title: "Effacer", target: self, action: #selector(clearBinding))
        clear.frame = NSRect(x: 240, y: 24, width: 110, height: 32)
        clear.bezelStyle = .rounded

        content.addSubview(info)
        content.addSubview(current)
        content.addSubview(record)
        content.addSubview(clear)
        w.contentView = content

        window = w
        currentLabel = current
        recordButton = record
    }

    private func updateCurrentLabel(_ binding: HotkeyBinding?) {
        currentLabel?.stringValue = binding?.displayString ?? "Aucun raccourci clavier défini"
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
        peakModifiers = []
        recordButton?.title = "Appuie sur une touche (Échap pour annuler)…"
        currentLabel?.stringValue = "…"
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handleRecordingEvent(event)
            return nil
        }
    }

    private func handleRecordingEvent(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch event.type {
        case .keyDown:
            if event.keyCode == 53 {
                stopRecording(cancelled: true)
                return
            }
            finalize(HotkeyBinding(keyCode: event.keyCode, modifiers: mods.rawValue))
        case .flagsChanged:
            peakModifiers.formUnion(mods)
            if mods.isEmpty, !peakModifiers.isEmpty {
                finalize(HotkeyBinding(keyCode: nil, modifiers: peakModifiers.rawValue))
            }
        default:
            break
        }
    }

    private func finalize(_ binding: HotkeyBinding) {
        stopRecording(cancelled: false)
        HotkeyBindingStore.save(binding)
        updateCurrentLabel(binding)
        onBindingChange?(binding)
    }

    private func stopRecording(cancelled: Bool) {
        isRecording = false
        if let monitor = recordingMonitor {
            NSEvent.removeMonitor(monitor)
        }
        recordingMonitor = nil
        recordButton?.title = "Enregistrer un raccourci…"
        if cancelled {
            updateCurrentLabel(HotkeyBindingStore.load())
        }
    }

    @objc private func clearBinding() {
        HotkeyBindingStore.save(nil)
        updateCurrentLabel(nil)
        onBindingChange?(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if isRecording {
            stopRecording(cancelled: true)
        }
    }
}
