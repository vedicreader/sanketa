import Foundation
import SanketaCore

/// What the "Use OpenAI" and "Use On-Device Model" status-menu items do. The app gives the outside world (the config,
/// the key lookup, the key box, the Keychain and the model picker); tests give fakes. Each change goes to config.toml
/// and to the running app at once.
@MainActor public final class LLMToggles {
    public struct World {
        /// the current `[llm]`
        public var config: () -> LLMConfig
        /// sets `[llm]` in the running app and rebuilds the router
        public var apply: (LLMConfig) -> Void
        /// writes one `[llm]` key to config.toml; the value is TOML text
        public var save: (_ key: String, _ value: String) -> Void
        /// where the key for the server is: the environment, the login shell, else the Keychain for its host
        public var keySource: () async -> KeySource?
        /// the key box; the typed text, or nil on Cancel
        public var askKey: () -> String?
        /// checks the typed key and writes it to the Keychain for the server's host; nil when saved, else why not
        public var saveKey: (String) -> String?
        /// the models that are downloaded
        public var installed: () -> Set<MLXModelChoice>
        public var memory: UInt64
        /// shows the model choice (download or use), with no download
        public var showPicker: () -> Void

        public init(config: @escaping () -> LLMConfig, apply: @escaping (LLMConfig) -> Void, save: @escaping (String, String) -> Void,
                    keySource: @escaping () async -> KeySource?, askKey: @escaping () -> String?, saveKey: @escaping (String) -> String?,
                    installed: @escaping () -> Set<MLXModelChoice>, memory: UInt64 = ProcessInfo.processInfo.physicalMemory,
                    showPicker: @escaping () -> Void) {
            self.config = config; self.apply = apply; self.save = save; self.keySource = keySource; self.askKey = askKey
            self.saveKey = saveKey; self.installed = installed; self.memory = memory; self.showPicker = showPicker
        }
    }

    /// `busy`: a flow from an earlier click still runs, so this click does nothing.
    public enum OpenAIResult: Equatable { case on(KeySource), off, cancelled, notSaved(String), busy }
    public enum OnDeviceResult: Equatable { case on(MLXModelChoice), off, needsModel, notEnoughMemory }

    let world: World
    /// where the key came from when OpenAI went on; the menu shows it
    public private(set) var keySource: KeySource?
    /// true while a "Use OpenAI" flow runs (the key lookup or the key box)
    public private(set) var openAIBusy = false

    public init(_ world: World) { self.world = world }

    /// On: the key is looked up first. With a key, OpenAI goes on. With none, the key box opens; Save stores the key
    /// in the Keychain and turns OpenAI on, Cancel leaves it off. The key is never shown or logged.
    public func setOpenAI(_ on: Bool) async -> OpenAIResult {
        guard !openAIBusy else { return .busy }
        openAIBusy = true
        defer { openAIBusy = false }
        guard on else {
            set { $0.openai = false }
            world.save("openai", "false")
            keySource = nil
            return .off
        }
        if let s = await world.keySource() { return turnOnOpenAI(s) }
        guard let typed = world.askKey() else { return .cancelled }
        if let why = world.saveKey(typed) { return .notSaved(why) }
        return turnOnOpenAI(.keychain)
    }

    /// While OpenAI is on (such as at launch), finds where the key is, for the menu's key line.
    public func findKeySource() async {
        guard world.config().openai else { return }
        keySource = await world.keySource()
    }

    func turnOnOpenAI(_ s: KeySource) -> OpenAIResult {
        keySource = s
        set { $0.openai = true }
        world.save("openai", "true")
        return .on(s)
    }

    /// On: the chosen model when it is downloaded and fits, else another downloaded model that fits. With none, the
    /// model choice opens and the model stays off: nothing downloads until the user chooses a download. Below the
    /// memory floor nothing changes.
    public func setOnDevice(_ on: Bool) -> OnDeviceResult {
        guard on else {
            set { $0.onDevice = false }
            world.save("on_device", "false")
            return .off
        }
        guard MLXModelChoice.anyFits(memory: world.memory) else { return .notEnoughMemory }
        let fits = world.installed().filter { world.memory >= $0.minMemory }
        let chosen = world.config().mlxModel
        guard let m = fits.contains(chosen) ? chosen : MLXModelChoice.allCases.first(where: fits.contains) else {
            world.showPicker()
            return .needsModel
        }
        set { $0.onDevice = true; $0.mlxModel = m }
        world.save("mlx_model", "\"\(m.rawValue)\"")
        world.save("on_device", "true")
        return .on(m)
    }

    func set(_ change: (inout LLMConfig) -> Void) {
        var c = world.config()
        change(&c)
        world.apply(c)
    }

    // MARK: menu lines

    public static let useOpenAI = "Use OpenAI", useOnDevice = "Use On-Device Model"

    /// "Key: environment", "Key: login shell" or "Key: Keychain".
    public static func keyLine(_ s: KeySource) -> String {
        switch s {
        case .environment: "Key: environment"
        case .shell: "Key: login shell"
        case .keychain: "Key: Keychain"
        }
    }

    /// "Use OpenAI" with a check mark when on, then where the key is, while it is on and known.
    public static func openAILines(config: LLMConfig, source: KeySource?) -> [MenuLine] {
        var out = [MenuLine(useOpenAI, checked: config.openai)]
        if config.openai, let source { out.append(MenuLine(keyLine(source), enabled: false)) }
        return out
    }

    /// The on-device items of the status menu: the toggle, a note line under it (nil: no line) and if the model list
    /// opens. The list follows the toggle; below the memory floor it stays open, so "Remove Downloaded Models" can be
    /// reached, and the note says why the toggle is off.
    public struct OnDeviceItems: Equatable { public var toggle: MenuLine; public var note: String?; public var pickerEnabled: Bool }

    public static func onDeviceItems(config: LLMConfig, memory: UInt64) -> OnDeviceItems {
        let (line, note) = onDeviceLine(config: config, memory: memory)
        return OnDeviceItems(toggle: line, note: note, pickerEnabled: config.onDevice || note != nil)
    }

    /// "Use On-Device Model" with a check mark when on. On a Mac below the memory floor it is off and disabled, and the
    /// second value is the note to show with it.
    public static func onDeviceLine(config: LLMConfig, memory: UInt64) -> (line: MenuLine, note: String?) {
        guard MLXModelChoice.anyFits(memory: memory) else {
            return (MenuLine(useOnDevice, enabled: false), MLXModelChoice.notEnoughMemory)
        }
        return (MenuLine(useOnDevice, checked: config.onDevice), nil)
    }
}
