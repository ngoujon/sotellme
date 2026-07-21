import Carbon
import AppKit

/// Global hotkey capture for F5, using the Carbon Event Manager.
/// No Accessibility/Input Monitoring permission is required for this API.
final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    var onHotkeyPressed: (() -> Void)?

    private static let hotKeyID = EventHotKeyID(signature: OSType(0x53544D45), id: 1) // 'STME'

    func register() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(GetApplicationEventTarget(), { _, eventRef, userData -> OSStatus in
            guard let eventRef = eventRef, let userData = userData else { return noErr }

            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                eventRef,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr, hotKeyID.id == HotkeyManager.hotKeyID.id else { return noErr }

            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            manager.onHotkeyPressed?()
            return noErr
        }, 1, &eventType, selfPtr, &eventHandler)

        RegisterEventHotKey(
            UInt32(kVK_F5),
            0,
            Self.hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    func unregister() {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler = eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }
}
