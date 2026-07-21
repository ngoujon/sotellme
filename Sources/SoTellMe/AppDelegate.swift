import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let hotkeyManager = HotkeyManager()
    private let audioRecorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let vocabCorrector = VocabCorrector()
    private let indicator = ListeningIndicator()
    private let textInserter = TextInserter()
    private var micMenu: NSMenu?
    private var permissionWarningItem: NSMenuItem?
    private var liveTranscriptionTimer: Timer?
    private var isTranscribingPartial = false

    private static let selectedMicDefaultsKey = "SoTellMe.selectedMicUID"

    private enum State {
        case loadingModel, idle, listening, transcribing
    }
    private var state: State = .loadingModel

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        audioRecorder.preferredDeviceUID = UserDefaults.standard.string(forKey: Self.selectedMicDefaultsKey)
        audioRecorder.onLevel = { [weak self] level in
            DispatchQueue.main.async {
                self?.indicator.updateLevel(level)
            }
        }

        hotkeyManager.onTap = { [weak self] in
            self?.toggleRecording()
        }
        hotkeyManager.onHoldStart = { [weak self] in
            guard let self, self.state == .idle else { return }
            self.startRecording()
        }
        hotkeyManager.onHoldEnd = { [weak self] in
            guard let self, self.state == .listening else { return }
            self.stopRecordingAndTranscribe()
        }
        hotkeyManager.register()
        checkPermissions()

        Task {
            do {
                try await transcriber.loadModel()
                state = .idle
                setIcon("mic")
            } catch {
                NSLog("SoTellMe: failed to load Whisper model: \(error)")
                setIcon("exclamationmark.triangle")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager.unregister()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon("hourglass")

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "SoTellMe — clic molette pour dicter", action: nil, keyEquivalent: ""))

        let warningItem = NSMenuItem(title: "⚠️ Permissions manquantes…", action: #selector(openPrivacySettings), keyEquivalent: "")
        warningItem.target = self
        warningItem.isHidden = true
        menu.addItem(warningItem)
        permissionWarningItem = warningItem

        menu.addItem(NSMenuItem.separator())

        let micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        let micSubmenu = NSMenu()
        micItem.submenu = micSubmenu
        menu.addItem(micItem)
        micMenu = micSubmenu
        refreshMicMenu()

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quitter", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === statusItem.menu {
            refreshMicMenu()
            refreshPermissionWarning()
        }
    }

    @objc private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Accessibility is pinned by code-signature hash for ad-hoc-signed apps,
    /// so a rebuild can silently invalidate a previously granted permission
    /// without macOS re-prompting. This actively re-triggers the prompt (or
    /// surfaces a menu warning if already denied) instead of failing
    /// silently. The middle-click hotkey itself needs no special permission,
    /// but Accessibility is still required to paste the transcribed text.
    private func checkPermissions() {
        let axOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(axOptions)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refreshPermissionWarning()
        }
    }

    private func refreshPermissionWarning() {
        var missing: [String] = []
        if !AXIsProcessTrusted() {
            missing.append("Accessibilité")
        }
        permissionWarningItem?.isHidden = missing.isEmpty
        if !missing.isEmpty {
            permissionWarningItem?.title = "⚠️ Autoriser : \(missing.joined(separator: ", "))…"
            NSLog("SoTellMe: missing permissions: \(missing.joined(separator: ", "))")
        }
    }

    private func refreshMicMenu() {
        guard let micMenu = micMenu else { return }
        micMenu.removeAllItems()

        let selectedUID = UserDefaults.standard.string(forKey: Self.selectedMicDefaultsKey)

        let systemItem = NSMenuItem(title: "Micro par défaut du système", action: #selector(selectMic(_:)), keyEquivalent: "")
        systemItem.target = self
        systemItem.state = (selectedUID == nil) ? .on : .off
        micMenu.addItem(systemItem)
        micMenu.addItem(NSMenuItem.separator())

        let devices = MicrophoneManager.availableInputDevices()
        if devices.isEmpty {
            let emptyItem = NSMenuItem(title: "Aucun micro détecté", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            micMenu.addItem(emptyItem)
        }
        for device in devices {
            let item = NSMenuItem(title: device.name, action: #selector(selectMic(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            item.state = (device.uid == selectedUID) ? .on : .off
            micMenu.addItem(item)
        }
    }

    @objc private func selectMic(_ sender: NSMenuItem) {
        let uid = sender.representedObject as? String
        UserDefaults.standard.set(uid, forKey: Self.selectedMicDefaultsKey)
        audioRecorder.preferredDeviceUID = uid
        refreshMicMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func setIcon(_ systemSymbolName: String) {
        statusItem.button?.image = NSImage(systemSymbolName: systemSymbolName, accessibilityDescription: "SoTellMe")
    }

    private func toggleRecording() {
        switch state {
        case .loadingModel, .transcribing:
            return
        case .idle:
            startRecording()
        case .listening:
            stopRecordingAndTranscribe()
        }
    }

    private func startRecording() {
        do {
            try audioRecorder.start()
            state = .listening
            textInserter.reset()
            indicator.show(state: "Écoute…")
            setIcon("mic.fill")
            NSSound(named: "Tink")?.play()
            startLiveTranscription()
        } catch {
            NSLog("SoTellMe: failed to start recording: \(error)")
        }
    }

    /// Periodically re-transcribes the audio captured so far so the HUD (and
    /// the focused app, via live keystrokes) show a progressively-refined
    /// preview while the user is still talking (Whisper has no true
    /// incremental decode, so this re-runs on the growing buffer; ticks are
    /// skipped while one is already in flight).
    private func startLiveTranscription() {
        liveTranscriptionTimer?.invalidate()
        liveTranscriptionTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            self?.transcribePartial()
        }
    }

    private func stopLiveTranscription() {
        liveTranscriptionTimer?.invalidate()
        liveTranscriptionTimer = nil
        isTranscribingPartial = false
    }

    private func transcribePartial() {
        guard state == .listening, !isTranscribingPartial else { return }
        let snapshot = audioRecorder.currentSamples()
        guard snapshot.count > 16000 else { return }

        isTranscribingPartial = true
        Task {
            defer { isTranscribingPartial = false }
            do {
                let rawText = try await transcriber.transcribe(samples: snapshot)
                let text = vocabCorrector.apply(to: rawText)
                guard state == .listening else { return }
                indicator.updateTranscript(text)
                textInserter.update(text)
            } catch {
                NSLog("SoTellMe: live transcription failed: \(error)")
            }
        }
    }

    private func stopRecordingAndTranscribe() {
        stopLiveTranscription()
        NSSound(named: "Pop")?.play()
        let samples = audioRecorder.stop()
        state = .transcribing
        indicator.updateState("Transcription…")
        indicator.updateLevel(0)
        setIcon("hourglass")

        Task {
            defer {
                indicator.hide()
                state = .idle
                setIcon("mic")
            }
            do {
                let rawText = try await transcriber.transcribe(samples: samples)
                let text = vocabCorrector.apply(to: rawText)
                textInserter.update(text)
            } catch {
                NSLog("SoTellMe: transcription failed: \(error)")
            }
        }
    }
}
