import AppKit

/// Detects two gestures on the mouse middle button (clic molette):
/// - a quick tap (press + release before `holdThreshold`) → `onTap`, meant to
///   toggle listening on/off.
/// - a hold (still down past `holdThreshold`) → `onHoldStart` the moment the
///   threshold is crossed, then `onHoldEnd` on release, for push-to-talk.
///
/// Unlike the Globe/Fn key (which only produces `flagsChanged` and requires
/// the fragile, TCC-code-signature-pinned Input Monitoring permission), a
/// global mouse-button monitor needs no special permission on macOS, so this
/// works even while Input Monitoring/Accessibility grants are unstable.
final class HotkeyManager {
    var onTap: (() -> Void)?
    var onHoldStart: (() -> Void)?
    var onHoldEnd: (() -> Void)?

    /// Middle mouse button (scroll-wheel click).
    private static let middleButtonNumber = 2
    private static let holdThreshold: TimeInterval = 0.35

    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?

    private var isDown = false
    private var holdCommitted = false
    private var holdTimer: Timer?

    func register() {
        let mask: NSEvent.EventTypeMask = [.otherMouseDown, .otherMouseUp]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleMouseEvent(event)
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleMouseEvent(event)
            return event
        }
    }

    func unregister() {
        for monitor in [globalMouseMonitor, localMouseMonitor] {
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
        globalMouseMonitor = nil
        localMouseMonitor = nil
        holdTimer?.invalidate()
        holdTimer = nil
    }

    private func handleMouseEvent(_ event: NSEvent) {
        guard event.buttonNumber == Self.middleButtonNumber else { return }

        switch event.type {
        case .otherMouseDown:
            guard !isDown else { return }
            isDown = true
            holdCommitted = false
            holdTimer?.invalidate()
            holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdThreshold, repeats: false) { [weak self] _ in
                self?.commitHold()
            }
        case .otherMouseUp:
            guard isDown else { return }
            isDown = false
            holdTimer?.invalidate()
            holdTimer = nil
            if holdCommitted {
                holdCommitted = false
                onHoldEnd?()
            } else {
                onTap?()
            }
        default:
            break
        }
    }

    private func commitHold() {
        guard isDown else { return }
        holdCommitted = true
        onHoldStart?()
    }
}
