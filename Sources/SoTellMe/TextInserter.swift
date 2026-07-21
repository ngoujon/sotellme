import AppKit

/// Inserts transcribed text into whatever app is currently focused, by
/// staging it on the pasteboard and simulating Cmd+V, then restoring the
/// user's previous clipboard contents.
final class TextInserter {
    private static let kVKCommand: CGKeyCode = 0x37
    private static let kVKANSI_V: CGKeyCode = 0x09

    func insert(_ text: String) {
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let changeCountAfterWrite = pasteboard.changeCount

        simulatePaste()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard let previous = previousContents else { return }
            if pasteboard.changeCount == changeCountAfterWrite {
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
        }
    }

    private func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)

        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: Self.kVKCommand, keyDown: true)
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: Self.kVKANSI_V, keyDown: true)
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: Self.kVKANSI_V, keyDown: false)
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: Self.kVKCommand, keyDown: false)

        vDown?.flags = .maskCommand
        vUp?.flags = .maskCommand

        cmdDown?.post(tap: .cghidEventTap)
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)
    }
}
