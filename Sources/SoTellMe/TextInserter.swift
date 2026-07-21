import AppKit

/// Types transcribed text directly into whatever app is currently focused,
/// live as the dictation progresses. Each call to `update(_:)` reconciles
/// the text already typed on screen with a new (possibly revised) transcript
/// by deleting only the diverging suffix (simulated Delete key) and typing
/// only the new suffix (simulated Unicode keystrokes) — instead of pasting
/// the whole text once at the end.
final class TextInserter {
    private static let kVKDelete: CGKeyCode = 0x33
    private static let unicodeChunkSize = 20

    private var lastTyped: String = ""

    /// Call once when a new dictation starts, before any `update` calls.
    func reset() {
        lastTyped = ""
    }

    /// Reconciles what's already typed on screen with `text`.
    func update(_ text: String) {
        guard text != lastTyped else { return }

        let common = commonPrefixLength(lastTyped, text)
        let deleteCount = lastTyped.count - common
        if deleteCount > 0 {
            deleteCharacters(deleteCount)
        }
        let suffix = String(text.dropFirst(common))
        if !suffix.isEmpty {
            typeText(suffix)
        }
        lastTyped = text
    }

    private func commonPrefixLength(_ a: String, _ b: String) -> Int {
        var count = 0
        for (ca, cb) in zip(a, b) {
            guard ca == cb else { break }
            count += 1
        }
        return count
    }

    private func deleteCharacters(_ count: Int) {
        let source = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<count {
            let down = CGEvent(keyboardEventSource: source, virtualKey: Self.kVKDelete, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: Self.kVKDelete, keyDown: false)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    /// Posts synthetic keystrokes carrying an arbitrary Unicode string
    /// (accented French characters included) rather than mapping characters
    /// to virtual key codes, chunked because CGEvent's Unicode string buffer
    /// has a limited capacity per event.
    private func typeText(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        let utf16 = Array(text.utf16)
        var offset = 0
        while offset < utf16.count {
            let end = min(offset + Self.unicodeChunkSize, utf16.count)
            let chunk = Array(utf16[offset..<end])
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            down?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            up?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
            offset = end
        }
    }
}
