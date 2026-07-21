import AppKit
import ApplicationServices

/// `@MainActor` isolation matters here beyond documentation: every `Task { }`
/// started from a method on this class inherits the actor context it was
/// created in, so keeping the whole delegate on the main actor guarantees
/// those tasks resume on the main thread after each `await`. Without it,
/// AppKit calls made after an `await` (e.g. `indicator.hide()` in
/// `stopRecordingAndTranscribe()`) can land on a background thread and crash
/// — this happened repeatedly (SIGTRAP in `NSWindow` ordering) before this
/// annotation was added.
@MainActor
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
    private var lastLiveSampleCount = 0

    /// Below this peak amplitude, audio is treated as silence: Whisper is
    /// never invoked on it (it otherwise tends to hallucinate boilerplate
    /// like subtitle-credit text on near-silent input), and it's also used
    /// to decide whether a stopped recording's trailing audio holds new
    /// speech worth a final re-transcription pass.
    private static let silencePeakThreshold: Float = 0.02

    /// Below this many trailing samples (~0.35s) with no audible level, a
    /// final re-transcription pass is skipped since the last live tick
    /// almost certainly already covers everything that was said.
    private static let finalPassSkipSampleThreshold = 5600

    private static func peakAmplitude<C: Collection>(_ samples: C) -> Float where C.Element == Float {
        samples.reduce(into: Float(0)) { $0 = max($0, abs($1)) }
    }

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
                Log.error("failed to load Whisper model: \(error)")
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
            Log.error("missing permissions: \(missing.joined(separator: ", "))")
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
            lastLiveSampleCount = 0
            indicator.show(state: "Écoute…")
            setIcon("mic.fill")
            NSSound(named: "Tink")?.play()
            startLiveTranscription()
        } catch {
            Log.error("failed to start recording: \(error)")
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
            // Timer always fires on the run loop it was scheduled on (main,
            // since this is called from @MainActor code); this just asserts
            // that known fact to the compiler.
            MainActor.assumeIsolated { self?.transcribePartial() }
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
        guard Self.peakAmplitude(snapshot) > Self.silencePeakThreshold else { return }

        isTranscribingPartial = true
        Task {
            defer { isTranscribingPartial = false }
            do {
                let rawText = try await transcriber.transcribe(samples: snapshot)
                let text = vocabCorrector.apply(to: rawText)
                guard state == .listening else { return }
                indicator.updateTranscript(text)
                textInserter.update(text)
                lastLiveSampleCount = snapshot.count
            } catch {
                Log.error("live transcription failed: \(error)")
            }
        }
    }

    /// The final pass re-transcribes the *complete* stopped-recording buffer
    /// because the last live tick can be up to 1.2s stale — if you keep
    /// talking right up until release, those last words may never have been
    /// through a live pass. But when there's no meaningful new audio since
    /// that last tick (silence, or a natural pause before releasing), the
    /// live text is already final — re-decoding would just reproduce the
    /// same text, so it's skipped to avoid the visible "Transcription…" wait.
    private func stopRecordingAndTranscribe() {
        stopLiveTranscription()
        NSSound(named: "Pop")?.play()
        let samples = audioRecorder.stop()

        guard Self.peakAmplitude(samples) > Self.silencePeakThreshold else {
            indicator.hide()
            state = .idle
            setIcon("mic")
            return
        }

        let tail = samples[min(lastLiveSampleCount, samples.count)...]
        let tailPeak = Self.peakAmplitude(tail)
        let hasNewSpeech = tail.count > Self.finalPassSkipSampleThreshold || tailPeak > Self.silencePeakThreshold
        guard lastLiveSampleCount > 0, !hasNewSpeech else {
            state = .transcribing
            indicator.updateLevel(0)
            setIcon("hourglass")
            runFinalTranscription(samples: samples)
            return
        }

        indicator.hide()
        state = .idle
        setIcon("mic")
    }

    private func runFinalTranscription(samples: [Float]) {
        indicator.updateState("Transcription…")
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
                Log.error("transcription failed: \(error)")
            }
        }
    }
}
