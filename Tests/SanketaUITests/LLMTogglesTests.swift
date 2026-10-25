import Foundation
import Testing
@testable import SanketaCore
@testable import SanketaUI

/// The "Use OpenAI" and "Use On-Device Model" toggles with a fake world: no key box, Keychain or menu shows.
@MainActor struct LLMTogglesTests {
    @MainActor final class Fake {
        var config = LLMConfig()
        var saved: [String: String] = [:]
        var source: KeySource?
        var typed: String?            // nil: the user clicks Cancel
        var boxes = 0, pickers = 0, lookups = 0
        var keychain: [String] = []
        var installed: Set<MLXModelChoice> = []
        var memory: UInt64 = 16 << 30

        func toggles() -> LLMToggles {
            LLMToggles(.init(config: { self.config }, apply: { self.config = $0 }, save: { self.saved[$0] = $1 },
                             keySource: { self.lookups += 1; return self.source },
                             askKey: { self.boxes += 1; return self.typed },
                             saveKey: { t in
                                 guard !t.isEmpty, !t.contains(" ") else { return "The key is empty, or it has spaces or control characters in it." }
                                 self.keychain.append(t); return nil
                             },
                             installed: { self.installed }, memory: memory, showPicker: { self.pickers += 1 }))
        }
    }

    @Test func keyInTheEnvironmentTurnsOpenAIOnWithoutTheBox() async {
        let f = Fake()
        f.source = .environment
        let t = f.toggles()
        #expect(await t.setOpenAI(true) == .on(.environment))
        #expect(f.config.openai && f.saved["openai"] == "true" && f.boxes == 0 && f.keychain.isEmpty)
        #expect(LLMToggles.openAILines(config: f.config, source: t.keySource).map(\.title) == ["Use OpenAI", "Key: environment"])
        #expect(LLMToggles.openAILines(config: f.config, source: t.keySource)[0].checked)
        #expect(await t.setOpenAI(false) == .off)
        #expect(!f.config.openai && f.saved["openai"] == "false" && t.keySource == nil)
        #expect(LLMToggles.openAILines(config: f.config, source: t.keySource).map(\.title) == ["Use OpenAI"])
    }

    @Test func noKeyOpensTheBoxAndSaveStoresItInTheKeychain() async {
        let f = Fake()
        f.typed = "sk-test-123"
        let t = f.toggles()
        #expect(await t.setOpenAI(true) == .on(.keychain))
        #expect(f.boxes == 1 && f.keychain == ["sk-test-123"] && f.config.openai)
        #expect(LLMToggles.openAILines(config: f.config, source: t.keySource).last?.title == "Key: Keychain")
        #expect(!f.saved.values.contains { $0.contains("sk-test") }, "the key never goes to config.toml")
    }

    @Test func cancelOrABadKeyLeavesOpenAIOff() async {
        let f = Fake()
        let t = f.toggles()
        #expect(await t.setOpenAI(true) == .cancelled)
        #expect(f.boxes == 1 && !f.config.openai && f.saved.isEmpty && f.keychain.isEmpty)
        f.typed = "has space"
        #expect(await t.setOpenAI(true) == .notSaved("The key is empty, or it has spaces or control characters in it."))
        #expect(!f.config.openai && f.keychain.isEmpty)
    }

    @Test func onDeviceWithNoModelShowsTheChoiceAndDownloadsNothing() {
        let f = Fake()
        let t = f.toggles()
        #expect(t.setOnDevice(true) == .needsModel)
        #expect(f.pickers == 1 && !f.config.onDevice && f.saved.isEmpty)
        // a downloaded model: on at once
        f.installed = [.qwen2b]
        #expect(t.setOnDevice(true) == .on(.qwen2b))
        #expect(f.config.onDevice && f.config.mlxModel == .qwen2b && f.saved["on_device"] == "true" && f.saved["mlx_model"] == "\"qwen3.5-2b\"")
        #expect(LLMToggles.onDeviceLine(config: f.config, memory: f.memory).line.checked)
        #expect(t.setOnDevice(false) == .off && !f.config.onDevice && f.saved["on_device"] == "false")
    }

    @Test func onDevicePrefersTheChosenModelThatFits() {
        let f = Fake()
        f.installed = [.gemma4e4b, .qwen4b]
        f.config.mlxModel = .qwen4b
        #expect(f.toggles().setOnDevice(true) == .on(.qwen4b))
        let small = Fake()
        small.memory = 8 << 30
        small.installed = [.gemma4e4b]
        small.config.mlxModel = .gemma4e4b
        #expect(small.toggles().setOnDevice(true) == .needsModel, "Gemma does not fit in 8 GB")
    }

    @Test func belowTheMemoryFloorTheToggleIsOff() {
        let f = Fake()
        f.memory = 4 << 30
        f.installed = [.qwen2b]
        #expect(f.toggles().setOnDevice(true) == .notEnoughMemory)
        #expect(!f.config.onDevice && f.pickers == 0 && f.saved.isEmpty)
        let (line, note) = LLMToggles.onDeviceLine(config: f.config, memory: f.memory)
        #expect(!line.enabled && !line.checked && note == "This Mac does not have enough memory for an on-device model. Search uses plain search.")
        #expect(LLMToggles.onDeviceLine(config: f.config, memory: 8 << 30).line.enabled)
    }

    /// Below the floor the note shows as its own line, and the model list stays open so Remove can be reached.
    @Test func belowTheFloorTheNoteShowsAndRemoveIsReachable() {
        let off = LLMConfig()
        let small = LLMToggles.onDeviceItems(config: off, memory: 4 << 30)
        #expect(!small.toggle.enabled && small.note == MLXModelChoice.notEnoughMemory && small.pickerEnabled)
        let picker = StatusMenus.onDeviceLines(on: false, selected: .qwen2b, installed: [.qwen2b], progress: nil, mlxReady: true,
                                               memory: 4 << 30)
        #expect(picker.map(\.title) == [MLXModelChoice.notEnoughMemory, "Remove Downloaded Models"] && picker[1].enabled)
        // enough memory: no note; the list follows the toggle
        let big = LLMToggles.onDeviceItems(config: off, memory: 16 << 30)
        #expect(big.toggle.enabled && big.note == nil && !big.pickerEnabled)
        var on = off
        on.onDevice = true
        #expect(LLMToggles.onDeviceItems(config: on, memory: 16 << 30).pickerEnabled)
    }
}
