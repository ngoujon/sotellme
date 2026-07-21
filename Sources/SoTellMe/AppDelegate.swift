import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let hotkeyManager = HotkeyManager()
    private let audioRecorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let vocabCorrector = VocabCorrector()
    private let indicator = ListeningIndicator()
    private let textInserter = TextInserter()

    private enum State {
        case loadingModel, idle, listening, transcribing
    }
    private var state: State = .loadingModel

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        hotkeyManager.onHotkeyPressed = { [weak self] in
            self?.toggleRecording()
        }
        hotkeyManager.register()

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
        menu.addItem(NSMenuItem(title: "SoTellMe — F5 pour dicter", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quitter", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
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
            indicator.show(state: "Écoute…")
            setIcon("mic.fill")
        } catch {
            NSLog("SoTellMe: failed to start recording: \(error)")
        }
    }

    private func stopRecordingAndTranscribe() {
        let samples = audioRecorder.stop()
        state = .transcribing
        indicator.updateState("Transcription…")
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
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    textInserter.insert(text)
                }
            } catch {
                NSLog("SoTellMe: transcription failed: \(error)")
            }
        }
    }
}
