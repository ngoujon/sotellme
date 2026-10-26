import AppKit
import ApplicationServices
import AVFoundation
import ServiceManagement

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
    private let hotkeySettingsWindow = HotkeySettingsWindowController()
    private let audioRecorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let vocabCorrector = VocabCorrector()
    private let indicator = ListeningIndicator()
    private let textInserter = TextInserter()

    private var statusLineItem: NSMenuItem?
    private var accessibilityWarningItem: NSMenuItem?
    private var microphoneWarningItem: NSMenuItem?
    private var dictationItem: NSMenuItem?
    private var retryModelItem: NSMenuItem?
    private var copyLastItem: NSMenuItem?
    private var micMenu: NSMenu?
    private var hotkeyMenuItem: NSMenuItem?
    private var launchAtLoginItem: NSMenuItem?

    private var liveTranscriptionTimer: Timer?
    private var accessibilityPollTimer: Timer?
    private var isTranscribingPartial = false
    private var lastLiveSampleCount = 0
    private var lastTranscript = ""
    private var sessionTranscript = ""
    /// Text of the finished sentences of the current dictation, and how many
    /// audio samples they cover (see `startLiveTranscription`).
    private var committedText = ""
    private var committedSampleCount = 0

    /// Incremented on every new dictation. Async transcription results carry
    /// the session they were started for, so a slow result from a previous
    /// dictation can never be typed into the current one.
    private var session = 0

    /// Whether the latest shortcut press is the one that started the
    /// recording (so a modifier-only shortcut can still take it back, see
    /// `handleShortcutCancel`), as opposed to one that stopped a dictation.
    private var currentPressStartedRecording = false

    /// Below this peak amplitude, audio is treated as silence: Whisper is
    /// never invoked on it (it otherwise tends to hallucinate boilerplate
    /// like subtitle-credit text on near-silent input), and it's also used
    /// to decide whether a stopped recording's trailing audio holds new
    /// speech worth a final re-transcription pass.
    private static let silencePeakThreshold: Float = 0.02

    private static func peakAmplitude<C: Collection>(_ samples: C) -> Float where C.Element == Float {
        samples.reduce(into: Float(0)) { $0 = max($0, abs($1)) }
    }

    private static let sampleRate = 16000
    /// Live decodes run back-to-back: the timer only retries this often, and
    /// a decode starts once the previous one is done and at least
    /// `minNewSamplesPerTick` of new audio came in.
    private static let liveTickInterval: TimeInterval = 0.25
    private static let minNewSamplesPerTick = sampleRate * 3 / 10
    /// How many of the latest segments stay open to revision; older ones
    /// are committed. Keeping two (like WhisperKit's own streaming) gives a
    /// sentence the context of the next one before it's locked in.
    private static let unconfirmedSegmentCount = 2
    /// Whisper tends to hallucinate on very short clips.
    private static let minWindowSamples = sampleRate * 6 / 10

    private static let selectedMicDefaultsKey = "SoTellMe.selectedMicUID"

    private enum State {
        case loadingModel, modelFailed, idle, listening, transcribing
    }
    private var state: State = .loadingModel {
        didSet { refreshStatusUI() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupStatusItem()

        audioRecorder.preferredDeviceUID = UserDefaults.standard.string(forKey: Self.selectedMicDefaultsKey)
        audioRecorder.onLevel = { [weak self] level in
            DispatchQueue.main.async {
                self?.indicator.updateLevel(level)
            }
        }

        hotkeyManager.onPress = { [weak self] in self?.handleShortcutPress() }
        hotkeyManager.onCancel = { [weak self] in self?.handleShortcutCancel() }
        hotkeyManager.register()
        hotkeyManager.keyboardBinding = HotkeyBindingStore.load()

        hotkeySettingsWindow.onBindingChange = { [weak self] binding in
            self?.hotkeyManager.keyboardBinding = binding
            self?.refreshStatusUI()
        }
        hotkeySettingsWindow.onRecordingChange = { [weak self] isRecording in
            self?.hotkeyManager.isSuspended = isRecording
        }

        requestPermissions()
        loadModel()

        // Without a shortcut the app looks like it does nothing: walk the
        // user straight to setting one up on first launch.
        if hotkeyManager.keyboardBinding == nil {
            openHotkeySettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager.unregister()
    }

    private func loadModel() {
        state = .loadingModel
        Task {
            do {
                try await transcriber.loadModel()
                Log.info("Whisper model loaded")
                state = .idle
            } catch {
                Log.error("failed to load Whisper model: \(error)")
                state = .modelFailed
            }
        }
    }

    // MARK: Dock

    /// Clicking the Dock icon opens the shortcut settings — the app's only
    /// window — rather than doing nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            openHotkeySettings()
        }
        return true
    }

    /// Right-click menu on the Dock icon.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let dictation = addItem(to: menu, state == .listening ? "Arrêter la dictée" : "Démarrer la dictée", #selector(toggleDictationFromMenu))
        dictation.isEnabled = state == .idle || state == .listening
        addItem(to: menu, "Copier la dernière dictée", #selector(copyLastTranscript)).isEnabled = !lastTranscript.isEmpty
        menu.addItem(NSMenuItem.separator())
        addItem(to: menu, "Raccourci de dictée…", #selector(openHotkeySettings))
        return menu
    }

    /// A regular (Dock) app shows a menu bar when it's frontmost, so it
    /// needs at least the standard app menu (⌘Q, ⌘H…) and ⌘W to close the
    /// settings window.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "À propos de SoTellMe", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        addItem(to: appMenu, "Raccourci de dictée…", #selector(openHotkeySettings), key: ",")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Masquer SoTellMe", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quitter SoTellMe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let windowMenu = NSMenu(title: "Fenêtre")
        windowMenu.addItem(withTitle: "Fermer", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Placer dans le Dock", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let windowMenuItem = NSMenuItem()
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: Menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        statusLineItem = statusLine

        accessibilityWarningItem = addItem(to: menu, "⚠️ Autoriser l'Accessibilité (frappe du texte, raccourci)…", #selector(openAccessibilitySettings))
        microphoneWarningItem = addItem(to: menu, "⚠️ Autoriser l'accès au micro…", #selector(openMicrophoneSettings))
        retryModelItem = addItem(to: menu, "Réessayer de charger le modèle", #selector(retryModelLoad))

        menu.addItem(NSMenuItem.separator())

        dictationItem = addItem(to: menu, "Démarrer la dictée", #selector(toggleDictationFromMenu))
        copyLastItem = addItem(to: menu, "Copier la dernière dictée", #selector(copyLastTranscript))

        menu.addItem(NSMenuItem.separator())

        let micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        let micSubmenu = NSMenu()
        micItem.submenu = micSubmenu
        menu.addItem(micItem)
        micMenu = micSubmenu

        hotkeyMenuItem = addItem(to: menu, "Raccourci de dictée…", #selector(openHotkeySettings))
        launchAtLoginItem = addItem(to: menu, "Lancer au démarrage du Mac", #selector(toggleLaunchAtLogin))

        menu.addItem(NSMenuItem.separator())
        addItem(to: menu, "Ouvrir le journal", #selector(openLog))
        addItem(to: menu, "Redémarrer SoTellMe", #selector(restart))
        addItem(to: menu, "Quitter SoTellMe", #selector(quit), key: "q")
        statusItem.menu = menu

        refreshMicMenu()
        refreshStatusUI()
    }

    @discardableResult
    private func addItem(to menu: NSMenu, _ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === statusItem.menu {
            refreshMicMenu()
            refreshStatusUI()
        }
    }

    /// Single place that syncs the menu-bar icon and every state-dependent
    /// menu item with the current state, permissions and settings.
    private func refreshStatusUI() {
        let shortcut = hotkeyManager.keyboardBinding?.displayString
        let missingAccessibility = !AXIsProcessTrusted()
        let microphoneDenied = Self.microphoneDenied

        switch state {
        case .loadingModel:
            setIcon("hourglass")
            statusLineItem?.title = "Chargement du modèle Whisper… (1er lancement : téléchargement)"
        case .modelFailed:
            setIcon("exclamationmark.triangle")
            statusLineItem?.title = "Échec du chargement du modèle (voir le journal)"
        case .idle:
            setIcon(missingAccessibility || microphoneDenied ? "exclamationmark.triangle" : "mic")
            if let shortcut {
                statusLineItem?.title = "Prêt — \(shortcut) pour dicter"
            } else {
                statusLineItem?.title = "Prêt — aucun raccourci défini"
            }
        case .listening:
            setIcon("mic.fill")
            statusLineItem?.title = "Écoute en cours…"
        case .transcribing:
            setIcon("hourglass")
            statusLineItem?.title = "Transcription…"
        }

        accessibilityWarningItem?.isHidden = !missingAccessibility
        microphoneWarningItem?.isHidden = !microphoneDenied
        retryModelItem?.isHidden = state != .modelFailed

        dictationItem?.title = state == .listening ? "Arrêter la dictée" : "Démarrer la dictée"
        dictationItem?.isEnabled = state == .idle || state == .listening

        copyLastItem?.isEnabled = !lastTranscript.isEmpty

        hotkeyMenuItem?.title = "Raccourci de dictée (\(shortcut ?? "aucun"))…"

        switch SMAppService.mainApp.status {
        case .enabled: launchAtLoginItem?.state = .on
        case .requiresApproval: launchAtLoginItem?.state = .mixed
        default: launchAtLoginItem?.state = .off
        }
    }

    private func setIcon(_ systemSymbolName: String) {
        statusItem.button?.image = NSImage(systemSymbolName: systemSymbolName, accessibilityDescription: "SoTellMe")
    }

    private func refreshMicMenu() {
        guard let micMenu = micMenu else { return }
        micMenu.removeAllItems()

        let selectedUID = UserDefaults.standard.string(forKey: Self.selectedMicDefaultsKey)
        let devices = MicrophoneManager.availableInputDevices()
        // A remembered mic that's currently unplugged silently falls back to
        // the system default (see AudioRecorder), so show that honestly.
        let selectedIsAvailable = selectedUID.map { uid in devices.contains { $0.uid == uid } } ?? false

        let systemItem = NSMenuItem(title: "Micro par défaut du système", action: #selector(selectMic(_:)), keyEquivalent: "")
        systemItem.target = self
        systemItem.state = (selectedUID == nil || !selectedIsAvailable) ? .on : .off
        micMenu.addItem(systemItem)
        micMenu.addItem(NSMenuItem.separator())

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

    @objc private func openHotkeySettings() {
        hotkeySettingsWindow.show(currentBinding: hotkeyManager.keyboardBinding)
    }

    @objc private func toggleDictationFromMenu() {
        switch state {
        case .idle: startRecording()
        case .listening: stopRecordingAndTranscribe()
        default: break
        }
    }

    @objc private func copyLastTranscript() {
        copyToPasteboard(lastTranscript)
    }

    @objc private func retryModelLoad() {
        loadModel()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        } catch {
            Log.error("failed to toggle launch at login: \(error)")
            indicator.showMessage("Lancement au démarrage indisponible", detail: "Place SoTellMe.app dans /Applications puis réessaie.")
        }
        refreshStatusUI()
    }

    @objc private func openLog() {
        if !FileManager.default.fileExists(atPath: Log.fileURL.path) {
            FileManager.default.createFile(atPath: Log.fileURL.path, contents: nil)
        }
        NSWorkspace.shared.open(Log.fileURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func restart() {
        let bundlePath = Bundle.main.bundlePath
        let relaunch = Process()
        if bundlePath.hasSuffix(".app") {
            // `-n` forces a fresh instance instead of just activating this
            // (about to die) one.
            relaunch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            relaunch.arguments = ["-n", bundlePath]
        } else if let executablePath = Bundle.main.executablePath {
            relaunch.executableURL = URL(fileURLWithPath: executablePath)
        } else {
            return
        }
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    // MARK: Permissions

    private static var microphoneDenied: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return status == .denied || status == .restricted
    }

    /// Accessibility is needed both for the global keyboard shortcut monitor
    /// and to type the transcribed text; a rebuild can silently invalidate a
    /// previous grant, so this actively re-triggers the prompt. While it's
    /// missing, the status is polled so the shortcut starts working as soon
    /// as it's granted, without having to relaunch the app.
    private func requestPermissions() {
        let axOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(axOptions) {
            Log.error("missing permission: Accessibility")
            accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollAccessibility() }
            }
        }

        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async { self?.refreshStatusUI() }
            }
        }
    }

    private func pollAccessibility() {
        guard AXIsProcessTrusted() else { return }
        Log.info("Accessibility granted")
        accessibilityPollTimer?.invalidate()
        accessibilityPollTimer = nil
        hotkeyManager.reinstallMonitors()
        refreshStatusUI()
    }

    @objc private func openAccessibilitySettings() {
        openPrivacyPane("Privacy_Accessibility")
    }

    @objc private func openMicrophoneSettings() {
        openPrivacyPane("Privacy_Microphone")
    }

    private func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Shortcut

    /// One press starts dictation, the next one stops it.
    private func handleShortcutPress() {
        currentPressStartedRecording = false
        switch state {
        case .idle:
            currentPressStartedRecording = startRecording()
        case .listening:
            stopRecordingAndTranscribe()
        case .loadingModel:
            indicator.showMessage("Modèle en cours de chargement…", detail: "Le premier lancement peut prendre quelques minutes.")
        case .modelFailed:
            indicator.showMessage("Modèle indisponible", detail: "Menu SoTellMe → Réessayer de charger le modèle.")
        case .transcribing:
            break
        }
    }

    /// A modifier-only shortcut turned out to be part of an ordinary
    /// keyboard shortcut (e.g. ⌃⌥T): drop the dictation it just started.
    private func handleShortcutCancel() {
        guard currentPressStartedRecording, state == .listening else { return }
        currentPressStartedRecording = false
        session += 1
        stopLiveTranscription()
        _ = audioRecorder.stop()
        textInserter.update("")
        indicator.hide()
        state = .idle
    }

    // MARK: Dictation

    /// Returns whether recording actually started.
    @discardableResult
    private func startRecording() -> Bool {
        guard state == .idle else { return false }
        if Self.microphoneDenied {
            indicator.showMessage("Accès au micro refusé", detail: "Autorise SoTellMe dans Réglages › Confidentialité › Micro.")
            openMicrophoneSettings()
            return false
        }
        if !AXIsProcessTrusted() {
            indicator.showMessage("Accessibilité non autorisée", detail: "Nécessaire pour taper le texte. Menu SoTellMe → Autoriser.")
            return false
        }
        do {
            try audioRecorder.start()
        } catch {
            Log.error("failed to start recording: \(error)")
            indicator.showMessage("Impossible de démarrer le micro", detail: "Vérifie qu'un micro est branché (menu SoTellMe → Microphone).")
            return false
        }
        session += 1
        state = .listening
        textInserter.reset()
        sessionTranscript = ""
        committedText = ""
        committedSampleCount = 0
        lastLiveSampleCount = 0
        let stopHint = hotkeyManager.keyboardBinding.map { "Écoute… — \($0.displayString) pour terminer" } ?? "Écoute…"
        indicator.show(state: stopHint)
        NSSound(named: "Tink")?.play()
        startLiveTranscription()
        return true
    }

    /// Live (streaming) transcription. Whisper has no incremental decoder,
    /// so the audio is re-decoded as it grows — but only the part after the
    /// last *committed* point: whenever a decode returns several segments,
    /// all but the latest ones are finished sentences, so their text is locked in
    /// (`committedText`) and their audio is never decoded again
    /// (`committedSampleCount`). Each decode therefore stays a few seconds
    /// long however long the dictation runs, which keeps it fast enough to
    /// run back-to-back (the timer just retries as soon as the previous
    /// decode is done and there's new audio).
    private func startLiveTranscription() {
        liveTranscriptionTimer?.invalidate()
        liveTranscriptionTimer = Timer.scheduledTimer(withTimeInterval: Self.liveTickInterval, repeats: true) { [weak self] _ in
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
        guard snapshot.count - lastLiveSampleCount >= Self.minNewSamplesPerTick else { return }
        let windowStart = min(committedSampleCount, snapshot.count)
        let window = Array(snapshot[windowStart...])
        guard window.count >= Self.minWindowSamples else { return }

        guard Self.peakAmplitude(window) > Self.silencePeakThreshold else {
            // Nothing but silence since the last committed sentence: skip it
            // for good (keeping a short margin) so it's never decoded.
            if window.count > Self.sampleRate * 2 {
                committedSampleCount = snapshot.count - Self.sampleRate / 2
            }
            lastLiveSampleCount = snapshot.count
            return
        }

        isTranscribingPartial = true
        let tickSession = session
        Task {
            defer {
                if tickSession == session { isTranscribingPartial = false }
            }
            do {
                let segments = try await transcriber.transcribe(samples: window)
                guard tickSession == session, state == .listening else { return }
                // A repetition loop is usually just this tick's window
                // ending mid-word; the next tick won't have it, so skip
                // rather than type garbage (or commit it).
                guard !segments.contains(where: \.isRepetitionLoop) else { return }
                var pending = segments
                if segments.count > Self.unconfirmedSegmentCount {
                    let finished = Array(segments.dropLast(Self.unconfirmedSegmentCount))
                    commit(finished, endingAt: finished[finished.count - 1].end, windowStart: windowStart, windowCount: window.count)
                    pending = Array(segments.suffix(Self.unconfirmedSegmentCount))
                }
                showLive(Self.joined(committedText, clean(pending)))
                lastLiveSampleCount = snapshot.count
            } catch {
                Log.error("live transcription failed: \(error)")
            }
        }
    }

    private func commit(_ segments: [Transcriber.Segment], endingAt end: Float, windowStart: Int, windowCount: Int) {
        committedText = Self.joined(committedText, clean(segments))
        let endSample = windowStart + min(windowCount, Int(end * Float(Self.sampleRate)))
        committedSampleCount = max(committedSampleCount, endSample)
    }

    private func showLive(_ text: String) {
        indicator.updateTranscript(text)
        textInserter.update(text)
        sessionTranscript = text
    }

    private func clean(_ segments: [Transcriber.Segment]) -> String {
        let text = segments.map(\.text).joined(separator: " ")
        return vocabCorrector.apply(to: NoiseFilter.apply(to: text))
    }

    private static func joined(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }

    /// When stopping, only the not-yet-committed audio is decoded once more
    /// (the last live tick can be a fraction of a second stale, so the very
    /// last words may not have been through a live pass yet). If the audio
    /// since that last tick is silent, the live text is already final and
    /// the pass is skipped entirely.
    private func stopRecordingAndTranscribe() {
        guard state == .listening else { return }
        stopLiveTranscription()
        NSSound(named: "Pop")?.play()
        let samples = audioRecorder.stop()

        guard Self.peakAmplitude(samples) > Self.silencePeakThreshold else {
            indicator.showMessage("Aucune voix détectée", detail: "Vérifie le micro sélectionné dans le menu SoTellMe.", duration: 2)
            state = .idle
            return
        }

        let tail = samples[min(lastLiveSampleCount, samples.count)...]
        let hasNewSpeech = Self.peakAmplitude(tail) > Self.silencePeakThreshold
        if lastLiveSampleCount == 0 || hasNewSpeech {
            state = .transcribing
            indicator.updateLevel(0)
            runFinalTranscription(samples: Array(samples[min(committedSampleCount, samples.count)...]))
        } else {
            finishDictation()
        }
    }

    private func runFinalTranscription(samples: [Float]) {
        indicator.updateState("Finalisation…")
        let finalSession = session
        Task {
            do {
                let segments = try await transcriber.transcribe(samples: samples)
                guard finalSession == session else { return }
                showLive(Self.joined(committedText, clean(segments.filter { !$0.isRepetitionLoop })))
            } catch {
                Log.error("transcription failed: \(error)")
            }
            guard finalSession == session else { return }
            finishDictation()
        }
    }

    private func finishDictation() {
        if !sessionTranscript.isEmpty {
            lastTranscript = sessionTranscript
        }
        state = .idle
        if textInserter.lostFocus, !sessionTranscript.isEmpty {
            // The text couldn't be (fully) typed because the user switched
            // apps: don't lose it.
            copyToPasteboard(sessionTranscript)
            indicator.showMessage("Texte copié dans le presse-papiers", detail: "L'app active a changé pendant la dictée. Colle-le avec ⌘V.")
        } else {
            indicator.hide()
        }
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
