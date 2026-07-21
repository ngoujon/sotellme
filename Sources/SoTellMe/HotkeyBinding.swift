import AppKit

/// A user-configurable trigger for starting/stopping dictation: either a
/// regular key held with modifiers (e.g. ⌘⇧D), a bare key (e.g. F5), or two
/// modifier keys held together with no regular key (e.g. ⌃⌥). This is the
/// only way to trigger dictation — see `HotkeyManager`.
struct HotkeyBinding: Codable, Equatable {
    /// `nil` means "modifiers only" (e.g. Control+Option held together).
    var keyCode: UInt16?
    /// The exact physical modifier keys required, by virtual keyCode — left
    /// and right Command/Option/Control/Shift are distinct entries here, not
    /// interchangeable, so a binding can require e.g. right Option without
    /// also triggering on left Option.
    var modifierKeyCodes: Set<UInt16>

    // MARK: Physical (device-specific) modifier keyCodes

    static let leftControl: UInt16 = 59
    static let rightControl: UInt16 = 62
    static let leftShift: UInt16 = 56
    static let rightShift: UInt16 = 60
    static let leftOption: UInt16 = 58
    static let rightOption: UInt16 = 61
    static let leftCommand: UInt16 = 55
    static let rightCommand: UInt16 = 54

    private static let displayOrder: [UInt16] = [
        leftControl, rightControl, leftOption, rightOption,
        leftShift, rightShift, leftCommand, rightCommand,
    ]

    private static let displaySymbols: [UInt16: String] = [
        leftControl: "⌃G", rightControl: "⌃D",
        leftOption: "⌥G", rightOption: "⌥D",
        leftShift: "⇧G", rightShift: "⇧D",
        leftCommand: "⌘G", rightCommand: "⌘D",
    ]

    /// Reads the physical (device-specific) modifier keys currently held
    /// from an event's raw modifier flags, distinguishing left/right
    /// Command, Option, Control, and Shift. `NSEvent.modifierFlags` only
    /// documents the coarse "either side" categories (`.command`, `.option`,
    /// …), but the underlying raw value also carries the same per-side bits
    /// macOS has exposed since the Carbon days (`NX_DEVICEL*KEYMASK` /
    /// `NX_DEVICER*KEYMASK` in IOLLEvent.h), so masking against those
    /// recovers which side is actually held.
    static func activeModifierKeyCodes(from event: NSEvent) -> Set<UInt16> {
        let raw = event.modifierFlags.rawValue
        var result: Set<UInt16> = []
        if raw & 0x0000_0001 != 0 { result.insert(leftControl) }
        if raw & 0x0000_2000 != 0 { result.insert(rightControl) }
        if raw & 0x0000_0002 != 0 { result.insert(leftShift) }
        if raw & 0x0000_0004 != 0 { result.insert(rightShift) }
        if raw & 0x0000_0008 != 0 { result.insert(leftCommand) }
        if raw & 0x0000_0010 != 0 { result.insert(rightCommand) }
        if raw & 0x0000_0020 != 0 { result.insert(leftOption) }
        if raw & 0x0000_0040 != 0 { result.insert(rightOption) }
        return result
    }

    var displayString: String {
        var s = ""
        for code in Self.displayOrder where modifierKeyCodes.contains(code) {
            s += Self.displaySymbols[code] ?? ""
        }
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
