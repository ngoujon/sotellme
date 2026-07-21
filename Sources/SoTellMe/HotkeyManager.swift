import Carbon
import AppKit

/// Detects a solo tap of the Globe/Fn key (🌐) to toggle dictation.
///
/// The Globe key is modifier-only: it never produces a regular keyDown, only
/// `flagsChanged` events, so it can't be captured via Carbon's
/// `RegisterEventHotKey`. Instead we watch `flagsChanged` for keyCode 0x3F
/// (kVK_Function) and treat a quick down-then-up with no other key pressed
/// in between as a "tap". This requires the Input Monitoring permission
/// (Réglages Système > Confidentialité et sécurité > Surveillance des entrées).
final class HotkeyManager {
    var onHotkeyPressed: (() -> Void)?

    private static let functionKeyCode: UInt16 = UInt16(kVK_Function)
    private static let maxTapDuration: TimeInterval = 1.0

    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?

    private var functionKeyDownAt: Date?
    private var otherKeyPressedDuringHold = false

    func register() {
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleOtherKeyDown()
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleOtherKeyDown()
            return event
        }
    }

    func unregister() {
        for monitor in [globalFlagsMonitor, localFlagsMonitor, globalKeyMonitor, localKeyMonitor] {
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
        globalFlagsMonitor = nil
        localFlagsMonitor = nil
        globalKeyMonitor = nil
        localKeyMonitor = nil
    }

    private func handleOtherKeyDown() {
        if functionKeyDownAt != nil {
            otherKeyPressedDuringHold = true
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard event.keyCode == Self.functionKeyCode else { return }

        if event.modifierFlags.contains(.function) {
            functionKeyDownAt = Date()
            otherKeyPressedDuringHold = false
            return
        }

        defer {
            functionKeyDownAt = nil
            otherKeyPressedDuringHold = false
        }

        guard let downAt = functionKeyDownAt else { return }
        let heldDuration = Date().timeIntervalSince(downAt)
        guard !otherKeyPressedDuringHold, heldDuration < Self.maxTapDuration else { return }

        onHotkeyPressed?()
    }
}
