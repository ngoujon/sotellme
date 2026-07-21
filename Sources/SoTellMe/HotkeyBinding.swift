import AppKit

/// A user-configurable trigger for starting/stopping dictation: either a
/// regular key held with modifiers (e.g. ⌘⇧D), a bare key (e.g. F5), or two
/// modifier keys held together with no regular key (e.g. ⌃⌥). This is always
/// *in addition to* the built-in middle-click, never a replacement for it.
struct HotkeyBinding: Codable, Equatable {
    /// `nil` means "modifiers only" (e.g. Control+Option held together).
    var keyCode: UInt16?
    var modifiers: UInt

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers)
    }

    var displayString: String {
        var s = ""
        let flags = modifierFlags
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        if let keyCode {
            s += Self.keyName(for: keyCode)
        }
        return s
    }

    private static func keyName(for keyCode: UInt16) -> String {
        let map: [UInt16: String] = [
            0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
            34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O",
            35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V",
            13: "W", 7: "X", 16: "Y", 6: "Z",
            18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7",
            28: "8", 25: "9", 29: "0",
            49: "Espace", 36: "Retour", 48: "Tab", 53: "Échap", 51: "Suppr",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        return map[keyCode] ?? "Touche \(keyCode)"
    }
}

enum HotkeyBindingStore {
    private static let defaultsKey = "SoTellMe.hotkeyBinding"

    static func load() -> HotkeyBinding? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(HotkeyBinding.self, from: data)
    }

    static func save(_ binding: HotkeyBinding?) {
        guard let binding else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            return
        }
        if let data = try? JSONEncoder().encode(binding) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
