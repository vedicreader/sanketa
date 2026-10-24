import AppKit
import Carbon.HIToolbox
import SanketaCore

/// Global hotkeys via Carbon `RegisterEventHotKey`; no input monitoring involved.
@MainActor public final class HotkeyCenter {
    static var handlers: [UInt32: () -> Void] = [:]
    static var nextID: UInt32 = 1
    static var installed = false
    var refs: [UInt32: EventHotKeyRef] = [:]

    public init() {}

    /// False when the combination is already taken (by this or another app).
    @discardableResult
    public func register(_ h: Hotkey, handler: @escaping () -> Void) -> Bool {
        Self.install()
        let id = Self.nextID
        Self.nextID += 1
        var ref: EventHotKeyRef?
        let st = RegisterEventHotKey(h.keyCode, h.carbonModifiers, EventHotKeyID(signature: OSType(0x534B_5441), id: id),
                                     GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
        guard st == noErr, let ref else { return false }
        refs[id] = ref
        Self.handlers[id] = handler
        return true
    }

    public func unregisterAll() {
        for (id, r) in refs { UnregisterEventHotKey(r); Self.handlers[id] = nil }
        refs = [:]
    }

    static func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            MainActor.assumeIsolated { HotkeyCenter.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
