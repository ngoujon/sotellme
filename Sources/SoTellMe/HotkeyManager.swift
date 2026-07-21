import Carbon
import AppKit
import IOKit.hid

/// Detects two gestures on the Globe/Fn key (🌐):
/// - a quick tap (press + release before `holdThreshold`, no other key in
///   between) → `onTap`, meant to toggle listening on/off.
/// - a hold (still down past `holdThreshold`) → `onHoldStart` the moment the
///   threshold is crossed, then `onHoldEnd` on release, for push-to-talk.
///
/// The Globe key is modifier-only: it never produces a regular keyDown, only
/// `flagsChanged` events, so it can't be captured via Carbon's
/// `RegisterEventHotKey`. This requires the Input Monitoring permission
/// (Réglages Système > Confidentialité et sécurité > Surveillance des entrées).
final class HotkeyManager {
    var onTap: (() -> Void)?
    var onHoldStart: (() -> Void)?
    var onHoldEnd: (() -> Void)?

    private static let functionKeyCode: UInt16 = UInt16(kVK_Function)
    private static let holdThreshold: TimeInterval = 0.35

    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?

    private var isDown = false
    private var otherKeyPressedDuringHold = false
    private var holdCommitted = false
    private var holdTimer: Timer?

    /// Whether macOS currently grants this app permission to observe global
    /// keyboard events. `false`/undetermined means the Globe key monitor
    /// below will silently never fire.
    static func hasInputMonitoringAccess() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Triggers the system permission prompt if the user has never been
    /// asked. No-ops (returns immediately) if already granted or denied.
    static func requestInputMonitoringAccessIfNeeded() {
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeUnknown {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
    }

    func register() {
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
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
        holdTimer?.invalidate()
        holdTimer = nil
    }

    private func handleOtherKeyDown() {
        if isDown {
            otherKeyPressedDuringHold = true
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        NSLog("SoTellMe: flagsChanged keyCode=\(event.keyCode) function=\(event.modifierFlags.contains(.function)) inputMonitoring=\(Self.hasInputMonitoringAccess())")
        guard event.keyCode == Self.functionKeyCode else { return }

        if event.modifierFlags.contains(.function) {
            guard !isDown else { return }
            isDown = true
            otherKeyPressedDuringHold = false
            holdCommitted = false
            holdTimer?.invalidate()
            holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdThreshold, repeats: false) { [weak self] _ in
                self?.commitHold()
            }
            return
        }

        guard isDown else { return }
        isDown = false
        holdTimer?.invalidate()
        holdTimer = nil

        if holdCommitted {
            holdCommitted = false
            onHoldEnd?()
        } else if !otherKeyPressedDuringHold {
            onTap?()
        }
        otherKeyPressedDuringHold = false
    }

    private func commitHold() {
        guard isDown, !otherKeyPressedDuringHold else { return }
        holdCommitted = true
        onHoldStart?()
    }
}
