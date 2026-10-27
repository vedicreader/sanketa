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

    /// The enabled chords of the system's own shortcuts (Spotlight, input sources, screenshots), as macOS lists them.
    public static func systemChords() -> Set<Chord> {
        var out: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&out) == noErr, let list = out?.takeRetainedValue() as? [[String: Any]] else { return [] }
        let bits: [(Int, Modifier)] = [(controlKey, .ctrl), (optionKey, .opt), (shiftKey, .shift), (cmdKey, .cmd)]
        return Set(list.compactMap { d -> Chord? in
            guard d[kHISymbolicHotKeyEnabled as String] as? Bool ?? true, let code = d[kHISymbolicHotKeyCode as String] as? Int,
                  let m = d[kHISymbolicHotKeyModifiers as String] as? Int, let key = PanelModel.keyNames[code] else { return nil }
            return Chord(mods: Set(bits.filter { m & $0.0 != 0 }.map(\.1)), key: key)
        })
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
