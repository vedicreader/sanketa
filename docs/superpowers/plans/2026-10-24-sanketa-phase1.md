# Sanketa Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A signed macOS 26 menu-bar app showing a floating glass panel. The panel lists shortcuts and tips for each layer of what the user is in (app → terminal → shell → tmux → program, including remote hosts), with a search hotkey and tip cards.

**Architecture:** A SwiftPM package with three targets:
- `SanketaCore`: pure, unit-tested logic (packs, process-snapshot queries, layer resolution, tmux and remote-title parsing, menu-key formatting, search, tip state, config).
- `SanketaSystem`: thin macOS I/O (sysctl, Accessibility, NSWorkspace monitoring).
- `Sanketa`: the AppKit/SwiftUI app (NSPanel with NSGlassEffectView, status item, Carbon hotkey).

A Makefile assembles and signs `build/Sanketa.app`. Bundled TOML packs ship in `Contents/Resources/Packs`.

**Tech Stack:** Swift 6.2 toolchain (Xcode 26, macOS 26.5 SDK), language mode v5, Swift Testing, SwiftUI + AppKit, Carbon `RegisterEventHotKey`, ApplicationServices AX API, `dduan/TOMLDecoder` (pin to its latest release tag when adding; check whether it decodes from `String` or `Data` and adapt `PackLibrary.decode`).

**Spec:** `docs/superpowers/specs/2026-10-24-sanketa-design.md`

## Global Constraints

- Platform: macOS 26, Apple Silicon. `platforms: [.macOS(.v26)]`.
- Permissions: Accessibility only. No input monitoring, no keystroke observation, no notifications, no sounds, no network. The only network-adjacent call is `ssh` over an *existing* ControlMaster connection with `BatchMode=yes` (Task 11).
- The panel must never take focus from the terminal except in search mode, which the user starts with the hotkey. Esc hands focus back.
- Idle CPU target: well under 1%. Poll process state every `pollInterval` (default 1.0 s) only while a terminal is frontmost. Push UI updates only when the layer stack changes.
- No Python runtime and no LLM in phase 1.
- Terminal bundle ids (defaults, configurable): `app.conterm.Conterm`, `com.mitchellh.ghostty`, `com.apple.Terminal`, `com.googlecode.iterm2`.
- User packs: `~/.config/sanketa/packs/*.toml`. Config: `~/.config/sanketa/config.toml`. State: `~/Library/Application Support/Sanketa/`.
- Bundle id `dev.sanketa.Sanketa`, `LSUIElement = YES`. Signed with the user's Apple Development identity (`SIGN_ID ?= Apple Development`), hardened runtime.
- Bundled pack content must be accurate. Prefer fewer correct entries over many dubious ones. Verify against local `man` pages.
- Look: neat, minimal, its own style. Glass stays readable over any background.
- Every external command runs through `CommandRunning` with a timeout (default 1.0 s). A hung tool must never freeze the UI.
- External binaries are resolved by absolute path: tmux from the running tmux process's executable path (`ProcInfo.path`), ssh at `/usr/bin/ssh`. An app launched from Finder has no Homebrew `PATH`.

## Review Focus

1. **Terminal with several tabs or splits, each with its own tty.** The panel should follow the focused one, not a random one. Pinned by `chooseTTYPrefersTitleMatch` and `chooseTTYFallsBackToNewest` (Task 4).
2. **Malformed or partial user pack TOML.** That one pack is skipped and its error shown in the panel footer. Other packs still load and nothing crashes. Pinned by `loadSkipsBadPackAndReportsError` (Task 1).
3. **tmux server gone, binary missing, or a command that hangs.** Fall back to a bare `tmux` layer within the timeout. Pinned by `runnerTimesOut` (Task 3) and `resolveTmuxWithNoClientsShowsBareTmux` (Task 4).
4. **Apps with huge menus (Excel) or apps that don't answer AX (hung or Electron).** The read is capped (0.5 s messaging timeout, 2000 items, depth 4) and the panel shows what it got. Pinned by `walkRespectsCaps` (Task 5). The AX timeout is checked in the Task 8 smoke run.
5. **Accessibility not granted, or revoked.** Process-based terminal layers still show (sysctl needs no permission). A one-line "Grant Accessibility" row appears and opens System Settings. Pinned by `resolveWithoutTitleStillResolves` (Task 4). The row is checked in Task 8.

---

## File Structure

```
sanketa/
  Package.swift
  Makefile
  README.md
  Resources/Info.plist
  Resources/AppIcon.icns                  (Task 12)
  Resources/Packs/*.toml                  (bundled packs, Task 10)
  docs/packs.md                           (pack format for LLM authoring, Task 10)
  scripts/remote/sanketa.fish             (Task 11)
  scripts/remote/sanketa.bash             (Task 11)
  scripts/remote/tmux.conf                (Task 11)
  scripts/remote-setup.sh                 (Task 11)
  Sources/SanketaCore/
    Pack.swift            Pack, KeyEntry, Tip, PackMode models + decoding defaults
    PackLibrary.swift     loading dirs, merge rules, lookup by process/argv/bundle id
    Process.swift         ProcInfo, ProcessSnapshot (pure queries)
    CommandRunner.swift   CommandRunning protocol + ProcessRunner (Foundation.Process, timeout)
    Tmux.swift            TmuxClient, parsing list-clients/list-keys/prefix, live merge, TmuxQuery
    RemoteTag.swift       parse/strip the ⟦sanketa …⟧ title tag
    Layer.swift           Layer, LayerKind, TerminalContext
    LayerResolver.swift   tty choice + layer stack resolution
    MenuKeys.swift        MenuShortcut, modifier/key formatting, menu → Pack
    Search.swift          SearchItem, scoring, ranking
    TipStore.swift        TipMark persistence + weighted pick
    Config.swift          Config, Hotkey parsing
  Sources/SanketaSystem/
    SysctlProcesses.swift snapshot from sysctl KERN_PROC_ALL + KERN_PROCARGS2 + proc_pidpath
    AXReader.swift        menu-bar walk, focused-window title, trust check
    ContextMonitor.swift  NSWorkspace + polling → published Context
  Sources/Sanketa/
    main.swift            app entry, --dump-context / --dump-menus CLI modes
    AppDelegate.swift     status item, wiring
    PanelController.swift NSPanel + NSGlassEffectView host, frame autosave, search focus
    HotkeyCenter.swift    Carbon RegisterEventHotKey
    Theme.swift
    Views/PanelView.swift, LayerSection.swift, KeyChip.swift, TipCard.swift, SearchField.swift
  Tests/SanketaCoreTests/
    Fixtures/  (toml packs, tmux outputs, process snapshots as JSON)
    *Tests.swift
```

---

### Task 1: Package scaffold, pack model and pack library

**Files:**
- Create: `Package.swift`, `.gitignore` (`.build/`, `build/`), `Sources/SanketaCore/Pack.swift`, `Sources/SanketaCore/PackLibrary.swift`
- Create: `Sources/SanketaSystem/Placeholder.swift`, `Sources/Sanketa/main.swift` (prints "sanketa" for now) so all targets build
- Test: `Tests/SanketaCoreTests/PackTests.swift`, `Tests/SanketaCoreTests/Fixtures/packs/{bundled,user}/…`

**Interfaces:**
- Produces:
  - `public struct KeyEntry: Codable, Hashable { keys: String; action: String; group: String?; command: String? }`. `command` is used only by tmux live merge.
  - `public struct Tip: Codable, Hashable { title: String; snippet: String; explain: String; tags: [String] }`
  - `public enum PackMode: String, Codable { case extend, replace }`
  - `public struct Pack: Codable, Hashable { id: String; name: String; processes: [String]; match: [String]; apps: [String]; prefix: String?; mode: PackMode; keys: [KeyEntry]; tips: [Tip] }`. Every field except `id` and `name` is optional in TOML, with defaults `[]`, nil and `.extend`. Write `init(from:)` with `decodeIfPresent`.
  - `public struct PackLoadError: Hashable { file: String; message: String }`
  - `public struct PackLibrary { packs: [String: Pack]; errors: [PackLoadError] }`
  - `PackLibrary.load(bundled: URL, user: URL?) -> PackLibrary`
  - `PackLibrary.decode(_ data: Data) throws -> Pack`
  - `PackLibrary.merge(_ base: Pack, _ overlay: Pack) -> Pack`
  - `func pack(process name: String, argv: [String]) -> Pack?`
  - `func pack(bundleID: String) -> Pack?`

Merge rules: `overlay.mode == .replace` → overlay. `.extend` → overlay keys replace base keys with the same `keys` string, others are appended. Tips are handled the same way, keyed by `title`. `processes`, `match` and `apps` are unioned. `name` and `prefix` come from the overlay when set.

Lookup: `pack(process:argv:)` first returns a pack where any `match` string is a substring of `argv.joined(separator: " ")`. Failing that, it returns the pack whose `processes` contains `name` exactly. `match` goes first so that a `python` pack can't hide ramabana. Iterate packs sorted by `id` for deterministic ties. `pack(bundleID:)` matches `apps`.

- [ ] **Step 1:** `git init`. Write `Package.swift`:
  - tools 6.2, `.macOS(.v26)`
  - targets `SanketaCore` (dep TOMLDecoder), `SanketaSystem` (dep Core), executable `Sanketa` (dep both), test `SanketaCoreTests` with `resources: [.copy("Fixtures")]`
  - `swiftSettings: [.swiftLanguageMode(.v5)]` on every target
- [ ] **Step 2: Write failing tests:**
  - `decodeMinimalPack`: only `id`/`name` → empty arrays, `.extend`
  - `decodeFullPack`: the spec's tmux example → `keys[0].keys == "prefix %"`, `prefix == "C-b"`, `tips[0].tags == ["loops","files"]`
  - `mergeExtendReplacesSameKeysAndAppends`
  - `mergeReplaceDropsBase`
  - `lookupArgvBeforeProcess`: with both a pack `processes=["python3"]` and a pack `match=["ramabana"]`, `name "python3"` and argv `["python3","/Users/x/.local/bin/ramabana"]` → the ramabana pack. A plain `python3` argv → the python pack.
  - `lookupByBundleID`
  - `loadSkipsBadPackAndReportsError`: fixture user dir with one valid file and one with invalid TOML → valid pack present, `errors.count == 1`, `errors[0].file` ends in the bad filename
- [ ] **Step 3:** `swift test` → the new tests fail.
- [ ] **Step 4:** Implement `Pack.swift` and `PackLibrary.swift`. Load every `*.toml`, sorted by name: bundled first, then user files merged over them by `id`.
- [ ] **Step 5:** `swift test` → pass.
- [ ] **Step 6:** Commit `feat: package scaffold and pack library`.

### Task 2: Process snapshot and command runner

**Files:**
- Create: `Sources/SanketaCore/Process.swift`, `Sources/SanketaCore/CommandRunner.swift`, `Sources/SanketaSystem/SysctlProcesses.swift` (delete Placeholder)
- Test: `Tests/SanketaCoreTests/ProcessTests.swift`, `Fixtures/snapshots/*.json`

**Interfaces:**
- Produces:
  - `public struct ProcInfo: Codable, Hashable { pid: Int32; ppid: Int32; pgid: Int32; tty: String?; tpgid: Int32; name: String; argv: [String]; start: Double; path: String? }`. `tty` is like `"ttys003"`; `tpgid` is the foreground process group of its tty; `start` is the epoch start time.
  - `public struct ProcessSnapshot { init(_ procs: [ProcInfo]) }` with:
    - `proc(_ pid: Int32) -> ProcInfo?`
    - `children(of: Int32) -> [ProcInfo]`
    - `ttys(under pid: Int32) -> [String]`: ttys of all descendants, unique, in first-seen order
    - `foreground(tty: String) -> ProcInfo?`: procs with `tty == t && pgid == tpgid`; prefer `pid == pgid`, else highest `start`
    - `chain(from: ProcInfo, until stop: (ProcInfo) -> Bool) -> [ProcInfo]`: walks `ppid` upward, innermost first, excluding the stopping proc
  - `public protocol CommandRunning { func run(_ path: String, _ args: [String], timeout: TimeInterval) -> String? }`. Returns stdout on exit 0 and nil on failure or timeout.
  - `public struct ProcessRunner: CommandRunning`. It reads stdout as it arrives (e.g. `readabilityHandler` or a reader thread) so output above the 64 KB pipe buffer can't deadlock. On timeout it terminates the child.
  - `SanketaSystem.SysctlProcesses.snapshot() -> ProcessSnapshot`. Sources:
    - `sysctl([CTL_KERN, KERN_PROC, KERN_PROC_ALL])` for the process list
    - tty from `devname(e_tdev, S_IFCHR)`, mapped to nil when `e_tdev == NODEV` or the result is `"??"`
    - `start` from `kp_proc.p_un.__p_starttime`
    - `name` is the `proc_pidpath` basename when available, otherwise `p_comm` (which is cut to 16 characters)
    - argv from `KERN_PROCARGS2` (failures → `[]`)
  - `chain` stops at pid ≤ 1 and guards against cycles with a visited set.

- [ ] **Step 1: Write failing tests** against fixture `conterm_tmux_htop.json`. The fixture's process tree:
  - Conterm 100
  - fish 200 on ttys001
  - tmux client 300 on ttys001, fg
  - tmux server 400, no tty
  - fish 500 on ttys005
  - htop 600 on ttys005, fg

  Tests:
  - `ttysUnderTerminal == ["ttys001"]`. The server is detached, so ttys005 is not under Conterm.
  - `foregroundOnTTY` → tmux 300 / htop 600
  - `chainStopsAtTerminal`: from htop with stop `pid == 400` → `[htop, fish]`
  - `runnerReturnsStdout`: `/bin/echo hi` → `"hi\n"`
  - `runnerTimesOut`: `/bin/sleep 5` with timeout 0.2 → nil within 1 s
  - `runnerNonZeroIsNil`: `/usr/bin/false`
  - `runnerLargeOutput`: `/bin/sh -c 'head -c 200000 /dev/zero | tr "\\0" a'` → 200000 characters
- [ ] **Step 2:** `swift test` → fail.
- [ ] **Step 3:** Implement `Process.swift`, `CommandRunner.swift`, `SysctlProcesses.swift`.
- [ ] **Step 4:** `swift test` → pass. Then add a throwaway check in `main.swift` printing `SysctlProcesses.snapshot().ttys(under: getppid())`. `swift run Sanketa` from a terminal should print this terminal's tty. Remove the check.
- [ ] **Step 5:** Commit `feat: process snapshot and command runner`.

### Task 3: tmux parsing, live bindings and remote tag

**Files:**
- Create: `Sources/SanketaCore/Tmux.swift`, `Sources/SanketaCore/RemoteTag.swift`
- Test: `Tests/SanketaCoreTests/TmuxTests.swift`, `RemoteTagTests.swift`, `Fixtures/tmux/{list-clients.txt,list-keys.txt}` (capture `list-keys` from the real local tmux)

**Interfaces:**
- Consumes: `CommandRunning`, `KeyEntry`, `Pack`
- Produces:
  - `public struct TmuxClient: Hashable { clientTTY: String; paneTTY: String; paneCommand: String }`. TTYs have `/dev/` stripped.
  - `Tmux.clientsFormat = "#{client_tty}\t#{pane_tty}\t#{pane_current_command}"`
  - `Tmux.parseClients(_: String) -> [TmuxClient]`
  - `Tmux.parseKeys(_: String) -> [KeyEntry]`: tables `prefix` → keys `"prefix <k>"`; `root` → `<k>`, skipping `Mouse*`/`Wheel*` keys. `action` and `command` are the bound command text. `group` is `"Live bindings"`.
  - `Tmux.mergeLive(_ pack: Pack, live: [KeyEntry]) -> Pack`:
    - for each live entry, a pack entry with an equal `command` takes the live `keys` and keeps its own `action`/`group`
    - live entries with no match are appended
    - pack entries that have a `command` but no live match are dropped
    - pack entries without `command` are kept
  - `public protocol TmuxQuerying { func clients(tmux: String) -> [TmuxClient]; func liveKeys(tmux: String) -> (prefix: String?, keys: [KeyEntry]) }`
  - `public struct TmuxQuery: TmuxQuerying { init(runner: CommandRunning) }`. It runs `list-clients -F`, `list-keys` and `show -gv prefix`, each with a 1 s timeout.
  - `public struct RemoteTag: Hashable { host: String; layers: [String] }`
  - `RemoteTag.parse(_ title: String) -> (tag: RemoteTag?, rest: String)`. Grammar: `⟦sanketa host=H layers=L(,L)*⟧`, with H in `[A-Za-z0-9._-]{1,64}`, L in `[A-Za-z0-9._+-]{1,32}`, and at most 8 layers. Anything not matching gives a nil tag and the original title. `rest` is the title with the tag and one following space removed. Layer order in the tag is outermost first.

- [ ] **Step 1: Write failing tests:**
  - `parseClientsStripsDev`
  - `parseKeysPrefixAndRoot`: the fixture contains `bind-key -T prefix % split-window -h` → `KeyEntry(keys: "prefix %", command: "split-window -h")`. Mouse keys are absent.
  - `parseKeysRepeatFlagAndEscapes`: `bind-key -r -T prefix Up select-pane -U` → keys `"prefix Up"`. `bind-key -T prefix \\" split-window` → keys `"prefix \""`. Escaped `\\;` and `\\#` keys are unescaped the same way.
  - `mergeLiveUsesUserKeysWithBundledLabel`: bundled `{keys:"prefix %", action:"Split left/right", command:"split-window -h"}`, live `prefix |` → `split-window -h` → result has `keys "prefix |"`, `action "Split left/right"`
  - `mergeLiveDropsUnbound`
  - `remoteTagParses`: `"⟦sanketa host=gpubox layers=fish,tmux,htop⟧ ~/w"` → host `gpubox`, layers `[fish,tmux,htop]`, rest `"~/w"`
  - `remoteTagRejectsGarbage`: bad host chars, 9 layers, a missing closing bracket → nil, title unchanged
- [ ] **Step 2:** `swift test` → fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `swift test` → pass.
- [ ] **Step 5:** Commit `feat: tmux parsing and remote title tag`.

### Task 4: Layer resolution

**Files:**
- Create: `Sources/SanketaCore/Layer.swift`, `Sources/SanketaCore/LayerResolver.swift`
- Test: `Tests/SanketaCoreTests/LayerResolverTests.swift` (fake `TmuxQuerying`, fixture snapshots)

**Interfaces:**
- Consumes: `ProcessSnapshot`, `PackLibrary`, `TmuxQuerying`, `RemoteTag`
- Produces:
  - `public enum LayerKind: String { case app, terminal, shell, multiplexer, program, remote }`
  - `public struct Layer: Hashable, Identifiable { kind: LayerKind; name: String; packID: String?; host: String?; id: String }`. `id` is `"\(host ?? "local")/\(packID ?? name)"`.
  - `public struct TerminalContext { pid: Int32; bundleID: String; appName: String; windowTitle: String? }`
  - `public struct LayerResolver { init(library: PackLibrary, tmux: TmuxQuerying, remote: RemoteQuerying?) }` with:
    - `chooseTTY(_ s: ProcessSnapshot, terminalPID: Int32, title: String?) -> String?`
    - `resolve(_ s: ProcessSnapshot, terminal: TerminalContext) -> [Layer]`: innermost first, the terminal last
    - `resolveApp(bundleID: String, name: String) -> [Layer]`: one `.app` layer with `packID "app:\(bundleID)"`
  - `public protocol RemoteQuerying { func paneCommand(sshArgv: [String]) -> String? }` (implemented in Task 11)

`chooseTTY` algorithm:
1. Take the candidate ttys under the terminal pid.
2. If there is one, return it.
3. Otherwise score each candidate's foreground proc: +2 if the window title (remote tag stripped) contains the proc's `name`. Ties go to the highest `start`.
4. With no title, return the tty whose foreground proc has the highest `start`.

`resolve` algorithm:
1. Pick the tty. If there is none, return just the terminal layer.
2. Take that tty's foreground proc and walk its `chain` up to the terminal pid. Drop `login`.
3. Map each proc in the chain to a layer, innermost first:
   - **Shells** (`fish`, `bash`, `zsh`, `sh`) → `.shell`.
   - **`tmux`** → `.multiplexer`. Find the client whose `clientTTY` is this tty. Resolve its `paneTTY` foreground chain, stopping at the first proc named `tmux` with no tty (the server), and place those layers *before* the tmux layer. With no client, keep a bare tmux layer.
   - **`ssh`/`mosh-client`** → if the title has a `RemoteTag`, emit its layers reversed (innermost first) with `host` set, then a `.remote` layer named after the host. Otherwise, if `remote?.paneCommand` returns something, emit that program layer and a host `.remote` layer. Otherwise emit a single `.remote` layer named from argv: the last non-option argument.
   - **Anything else** → `.program`.
4. `packID` comes from `library.pack(process:argv:)?.id`.
5. Append a `.terminal` layer for the app with `packID "app:\(bundleID)"`.
6. Dedupe by `id`, keeping the first.

- [ ] **Step 1: Write failing tests:**
  - `resolveTmuxHtop`: Task 2 fixture, fake tmux client `ttys001 → ttys005` → names `[htop, fish, tmux, Conterm]`. The inner and outer fish are deduped to one.
  - `resolveTmuxWithNoClientsShowsBareTmux` → `[tmux, fish, Conterm]`
  - `resolveRamabanaByArgv`: `python3` proc with ramabana argv and a pack `match=["ramabana"]` → layer `packID "ramabana"`
  - `resolveRemoteTag`: local chain `ssh ← fish`, title `"⟦sanketa host=gpubox layers=fish,tmux,htop⟧ htop"` → `[htop@gpubox, tmux@gpubox, fish@gpubox, gpubox(.remote), fish, Conterm]`
  - `resolveSshWithoutTag` → `.remote` named `gpubox` from argv `["ssh","-p","22","gpubox"]`
  - `chooseTTYPrefersTitleMatch`: two ttys, fg `htop` (older) and `vim` (newer), title `"htop"` → htop's tty
  - `chooseTTYFallsBackToNewest`: no title → the vim tty
  - `resolveWithoutTitleStillResolves`: nil title, single tty → full chain
- [ ] **Step 2:** `swift test` → fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `swift test` → pass.
- [ ] **Step 5:** Commit `feat: layer resolution`.

### Task 5: Menu shortcuts (formatting core + AX reader)

**Files:**
- Create: `Sources/SanketaCore/MenuKeys.swift`, `Sources/SanketaSystem/AXReader.swift`
- Test: `Tests/SanketaCoreTests/MenuKeysTests.swift`

**Interfaces:**
- Produces:
  - `public struct MenuShortcut: Hashable { path: [String]; keys: String }`
  - `MenuKeys.format(char: String?, virtualKey: Int?, modifiers: Int) -> String?`. AX modifier bits: shift=1, option=2, control=4, noCommand=8. Output order is `⌃⌥⇧⌘` followed by the key, with letters uppercased.
    - Virtual keys used when `char` is empty: 36 `↩`, 48 `⇥`, 49 `Space`, 51 `⌫`, 53 `⎋`, 117 `⌦`, 123 `←`, 124 `→`, 125 `↓`, 126 `↑`.
    - F1–F12: 122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111.
    - AppKit private-use function-key characters (`0xF700`–`0xF8FF`, e.g. `NSUpArrowFunctionKey` 0xF700, `NSF1FunctionKey` 0xF704) map to the same symbols.
    - `MenuKeys.format(…, glyph: Int?)` also accepts `AXMenuItemCmdGlyph` values for the common glyphs (return, tab, delete, escape, arrows, F-keys). The builder takes the table from `Carbon` `kMenu*Glyph` constants.
    - Returns nil when there is no char, known vkey or known glyph.
  - `public protocol MenuNode { var title: String? { get }; var shortcut: String? { get }; var children: [MenuNode] { get } }` and `MenuKeys.walk(_ topMenus: [MenuNode], maxDepth: Int = 4, maxItems: Int = 2000) -> [MenuShortcut]`: a pure capped walker that `AXReader` feeds lazily-loaded AX nodes into
  - `MenuKeys.pack(bundleID: String, name: String, shortcuts: [MenuShortcut]) -> Pack`: `id "app:\(bundleID)"`, `keys` with `action = path.dropFirst().joined(" › ")` and `group = path[0]`
  - `SanketaSystem.AXReader`:
    - `static var isTrusted: Bool`
    - `static func promptForTrust()`
    - `static func menuShortcuts(pid: pid_t) -> [MenuShortcut]`: skips the Apple menu (index 0), uses `AXUIElementSetMessagingTimeout(…, 0.5)`, depth ≤ 4, ≤ 2000 items. It reads `AXTitle`, `AXMenuItemCmdChar`, `AXMenuItemCmdVirtualKey` and `AXMenuItemCmdModifiers`.
    - `static func focusedWindowTitle(pid: pid_t) -> String?`

- [ ] **Step 1: Write failing tests:**
  - `formatCmdShiftS` (mods 1, char "s" → `"⇧⌘S"`)
  - `formatCtrlOptNoCmd` (mods 4|2|8, "t" → `"⌃⌥T"`)
  - `formatVirtualKeyArrow` (mods 0, char "", vkey 126 → `"⌘↑"`)
  - `formatNothingIsNil`
  - `formatPrivateUseArrow` (char `"\u{F700}"` → `"⌘↑"`)
  - `menuPackGroups`: 3 shortcuts across 2 top menus → 3 keys, groups preserved, action `"Font › Bold"` for path `["Format","Font","Bold"]`
  - `walkRespectsCaps`: a fake tree with 5000 items and depth 6 → at most 2000 shortcuts, none deeper than 4
- [ ] **Step 2:** `swift test` → fail.
- [ ] **Step 3:** Implement `MenuKeys.swift` and `AXReader.swift`.
- [ ] **Step 4:** `swift test` → pass.
- [ ] **Step 5:** Commit `feat: menu shortcut reading`.

### Task 6: Search and tip store

**Files:**
- Create: `Sources/SanketaCore/Search.swift`, `Sources/SanketaCore/TipStore.swift`
- Test: `Tests/SanketaCoreTests/SearchTests.swift`, `TipStoreTests.swift`

**Interfaces:**
- Consumes: `Pack`
- Produces:
  - `public enum ItemKind: String, Codable { case key, tip, suggestion }`. `suggestion` is reserved for phase 2 coaching cards; `TipCard` must render it like `tip`.
  - `public protocol SearchProviding { func results(_ query: String, _ items: [SearchItem], context: [String]) -> [SearchItem] }` with `public struct LocalSearch: SearchProviding` wrapping `Search.rank`. The app depends only on the protocol, so phase 2 can plug in a Foundation Models backend.
  - `public struct SearchItem: Hashable, Identifiable { packID; packName; kind: ItemKind; title: String; detail: String; explain: String?; tags: [String]; id: String }`. `title` is the key action or tip title; `detail` is the keys or snippet; `id` is `"\(packID)|\(kind)|\(title)"`.
  - `SearchItem.items(from: Pack) -> [SearchItem]`
  - `Search.score(_ query: String, _ item: SearchItem) -> Int?`
  - `Search.rank(_ query: String, _ items: [SearchItem], context: [String], limit: Int = 50) -> [SearchItem]`. `context` is the pack ids, innermost first.
  - `public enum TipMark: String, Codable { case known, less }`
  - `public final class TipStore { init(url: URL) }` with:
    - `mark(_ id: String) -> TipMark?`
    - `set(_ id: String, _ mark: TipMark?)`: persists atomically as JSON
    - `pick(from: [SearchItem], count: Int, seed: UInt64) -> [SearchItem]`: excludes `.known`, weights `.less` at 0.25 and everything else at 1, deterministic SplitMix64 from the seed, no repeats

Scoring:
- Case-insensitive.
- Every whitespace-separated query token must match somewhere in title, detail, tags or packName.
- Per token: word-prefix match in title = 30, substring in title = 20, substring elsewhere = 10, subsequence in title = 3.
- The score is the sum. Nil if any token fails.
- `rank` sorts by (index of `packID` in `context`, or ∞), then by score descending. An empty query returns context items in context order.

- [ ] **Step 1: Write failing tests:**
  - `splitPaneFindsTmux`
  - `allTokensRequired` ("split banana" → nil)
  - `contextPacksRankFirst`: the same match in fish and in tmux, with context `["tmux"]` → tmux first
  - `emptyQueryReturnsContext`
  - `tipStorePersistsAcrossInstances`
  - `pickExcludesKnown`
  - `pickDeterministicForSeed`
  - `pickLessIsRarer`: 4 items with one marked `.less`, `count: 1`, over 1000 seeds → the `.less` item is picked under 40% as often as the average normal item
- [ ] **Step 2:** `swift test` → fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `swift test` → pass.
- [ ] **Step 5:** Commit `feat: search and tip store`.

### Task 7: Config and hotkey parsing

**Files:**
- Create: `Sources/SanketaCore/Config.swift`
- Test: `Tests/SanketaCoreTests/ConfigTests.swift`

**Interfaces:**
- Produces:
  - `public struct Config: Codable, Equatable { hotkey: String; terminals: [String]; pollInterval: Double; tipRotateSeconds: Double }`. Defaults: `"ctrl+opt+k"`, the four terminal bundle ids from Global Constraints, `1.0`, `120`. Write a custom `init(from:)` with `decodeIfPresent`, so missing keys take defaults. Numbers accept TOML integers or floats (try `Double`, fall back to `Int`). Unknown keys are ignored, so phase 2 can add an `[llm]` table. `config.toml` is the settings surface, reached from the status menu's Open Config (a planner's call instead of a settings window).
  - `Config.load(_ url: URL) -> (Config, String?)`: a missing file gives defaults and a nil error; bad TOML gives defaults and an error message.
  - `public struct Hotkey: Equatable { keyCode: UInt32; carbonModifiers: UInt32 }`
  - `Hotkey.parse(_ s: String) -> Hotkey?`. Tokens are separated by `+` and case-insensitive.
    - Modifiers: `cmd` = 256, `shift` = 512, `opt`/`alt` = 2048, `ctrl` = 4096.
    - Key: `a`–`z`, `0`–`9`, `space`, `f1`–`f12`, `/`, `.`, `,`, mapped with `Carbon.HIToolbox` `kVK_*` constants.
    - Exactly one non-modifier key is required.

- [ ] **Step 1: Write failing tests:**
  - `defaultsWhenMissing`
  - `partialConfigKeepsDefaults` (only `hotkey` set)
  - `badTomlReturnsError`
  - `integerPollIntervalAccepted` (`pollInterval = 2` → `2.0`)
  - `parseCtrlOptK` → `keyCode == UInt32(kVK_ANSI_K)`, mods 6144
  - `parseRejectsTwoKeys`
  - `parseRejectsNoKey`
- [ ] **Step 2:** `swift test` → fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `swift test` → pass.
- [ ] **Step 5:** Commit `feat: config and hotkey parsing`.

### Task 8: Context monitor, CLI dump modes, app bundle and signing

**Files:**
- Create: `Sources/SanketaSystem/ContextMonitor.swift`, `Makefile`, `Resources/Info.plist`
- Modify: `Sources/Sanketa/main.swift`

**Interfaces:**
- Consumes: everything in Core, plus `SysctlProcesses` and `AXReader`
- Produces:
  - `public struct Context: Equatable { appName: String; bundleID: String; layers: [Layer]; packs: [Pack]; axTrusted: Bool }`. `packs` holds, per layer, the resolved pack:
    - library packs
    - the menu pack for terminal/app layers, merged with any user pack whose `apps` contains the bundle id
    - the tmux pack after `Tmux.mergeLive`
  - `@MainActor public final class ContextMonitor: ObservableObject` with:
    - `@Published context: Context`
    - `init(config: Config, library: PackLibrary)`
    - `start()`
    - `reload(library:)`
  - `public struct ContextEngine: Sendable { init(config: Config, library: PackLibrary); func compute(pid: pid_t, bundleID: String, appName: String) -> Context }`: synchronous and nonisolated. The monitor calls it on its background queue, and the CLI calls it directly.
  - `--dump-context [--out FILE]`: spins `RunLoop.main.run(until: Date()+3)` (not `sleep`) so `frontmostApplication` updates, then prints the layers and pack ids for the frontmost app, to FILE if given.
  - Accessibility is granted per responsible app. Run dumps through `open -W build/Sanketa.app --args --dump-context --out /tmp/sk.txt` so Sanketa's own grant applies, not Terminal's.
  - `--dump-menus <bundleID>`: prints the menu shortcuts.

Monitor behaviour:
- Observe `NSWorkspace.didActivateApplicationNotification` and ignore Sanketa's own bundle id.
- Do the work on a serial background queue.
- Poll every `pollInterval` only while the frontmost bundle id is in `config.terminals`.
- Assign `context` only when it changes.
- Cache menu packs per pid for 60 s.
- Cache tmux live keys per tmux binary path for 30 s.

Makefile targets:
- `test`: `swift test`
- `app`: `swift build -c release`, then assemble `build/Sanketa.app`:
  - `Contents/MacOS/Sanketa`
  - `Info.plist` with `CFBundleIdentifier dev.sanketa.Sanketa`, `LSUIElement`, `LSMinimumSystemVersion 26.0`, `NSAccessibilityUsageDescription`
  - `Resources/Packs`, and `AppIcon.icns` if present
  - then `codesign --force --options runtime --timestamp=none --sign "$(SIGN_ID)" build/Sanketa.app`
- `run`: `open build/Sanketa.app`
- `install`: copy to `~/Applications`
- `verify`: `codesign --verify --deep --strict build/Sanketa.app && codesign -dv build/Sanketa.app`

Bundled packs are found at `Bundle.main.resourceURL/Packs`. When running via `swift run`, fall back to `<repo>/Resources/Packs`, located from `#filePath`.

- [ ] **Step 1:** Implement `ContextMonitor.swift` (with `ContextEngine`) and the CLI modes. Pure logic is already tested; this task is glue. Add `--dump-ax <bundleID>`, which prints the focused window's AX attribute names and values (title, document, any pid or tty-like attribute) two levels deep.
- [ ] **Step 2:** Create a placeholder `Resources/Packs/tmux.toml` holding the spec example, so dumps show something before Task 10.
- [ ] **Step 3:** `make test` → all pass. Run `make app verify`. Expected: `valid on disk` and an `Authority=Apple Development: …` line. If no identity is found, stop and report; do not fall back to ad-hoc signing silently.
- [ ] **Step 4: Smoke test.**
  - Grant Accessibility to `build/Sanketa.app`. That needs the user, so ask once.
  - In Terminal.app, run `tmux new -d -s sk`, then `tmux send-keys -t sk htop Enter`, then attach with `tmux attach -t sk`.
  - From a second window, run `open -W build/Sanketa.app --args --dump-context --out /tmp/sk.txt` and focus the tmux window within 3 s.
  - Expected in `/tmp/sk.txt`: `htop`, `fish`, `tmux`, `Terminal` (outer fish deduped).
  - Run `--dump-ax app.conterm.Conterm` with Conterm focused. Record in the task report what its AX tree exposes for the focused pane. If it exposes a tty or pid, use it in `chooseTTY` ahead of the title heuristic.
  - Then run `--dump-menus com.apple.Terminal` → contains `⌘T`.
  - Then `--dump-menus` for a hung or slow app (any Electron app) → returns within 3 s.
- [ ] **Step 5:** Commit `feat: context monitor, CLI dumps, signed app bundle`.

### Task 9: Glass panel UI, status item, search hotkey and tip cards

**Files:**
- Create: `Sources/Sanketa/AppDelegate.swift`, `PanelController.swift`, `HotkeyCenter.swift`, `Theme.swift`, `Views/PanelView.swift`, `Views/LayerSection.swift`, `Views/KeyChip.swift`, `Views/TipCard.swift`, `Views/SearchField.swift`
- Modify: `Sources/Sanketa/main.swift` (start the app when there are no CLI flags)

**Interfaces:**
- Consumes: `ContextMonitor`, `Search`, `SearchItem`, `TipStore`, `Config`, `Hotkey`, `AXReader`
- Produces:
  - `PanelController.show()`, `toggle()`, `beginSearch(previousApp: NSRunningApplication?)`, `endSearch()`
  - `HotkeyCenter.register(_ h: Hotkey, handler: @escaping () -> Void) -> Bool`. A false return (the combination is taken) shows a footer note naming `config.toml`.

Panel:
- An `NSPanel` subclass with `canBecomeKey = true`.
- Style mask `[.nonactivatingPanel, .titled, .fullSizeContentView, .resizable]`, titlebar hidden and transparent, `isMovableByWindowBackground`.
- `level = .floating`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`, `hidesOnDeactivate = false`, `becomesKeyOnlyIfNeeded = true`.
- `isOpaque = false`, `backgroundColor = .clear`. Content is an `NSGlassEffectView` whose `contentView` is an `NSHostingView(PanelView)`.
- Set the default frame (340×520, right edge of the main screen) first, then `setFrameAutosaveName("SanketaPanel")`, so a saved position wins.
- Shown at launch.

Layout (Theme is the builder's call within this):
- **Header:** a breadcrumb of layer chips, innermost first. Remote layers carry a host chip.
- **One tip card:** `TipStore.pick` over the current context's tips and keys. Seed changes on context change and every `tipRotateSeconds`. Buttons "I know this" and "Show less".
- **One collapsible section per layer:** rows of action text on the left and a `KeyChip` on the right, grouped by `group`. Tip rows show the snippet in mono with a copy button.
- **Footer** appears only when needed: "Grant Accessibility", pack load errors (count, hover for files), and a hotkey conflict note.
- **Theme:** SF Pro text, SF Mono key chips with hairline borders, one accent (saffron `#E8A33D`), small-caps section headers, generous spacing. Keep it readable on glass over both light and dark backgrounds.

Search mode:
1. The hotkey records `NSWorkspace.shared.frontmostApplication`, shows the panel, makes it key and focuses `SearchField`.
2. Results come from a `SearchProviding` (`LocalSearch`) over all library items plus context packs, with the context ids taken from the current layers.
3. ↑/↓ move through results. ↩ copies the item's `detail`.
4. Esc clears the search, calls `makeFirstResponder(nil)`, `orderOut(nil)`, `orderFrontRegardless()` and `previousApp?.activate()`. Don't call `resignKey()` directly; AppKit calls it.

Status item menu: Show/Hide Panel, Search (with the hotkey shown), Reload Packs, Open Packs Folder (creates `~/.config/sanketa/packs`), Open Config, Grant Accessibility…, Quit.

- [ ] **Step 1:** Implement.
- [ ] **Step 2:** Run `make test app run`. Check by hand, recording results in the task report:
  - (a) Panel floats, drags and keeps its position after relaunch.
  - (b) Typing in the terminal while the panel is visible never moves focus. Confirm by typing continuously for 30 s while switching tmux panes.
  - (c) Switching tmux pane to htop updates the sections within about 1 s.
  - (d) The hotkey opens search. "split" finds the tmux split entry. Esc returns focus to the terminal and typing resumes there.
  - (e) Activity Monitor shows Sanketa under 1% CPU while idle with a terminal frontmost.
  - (f) Excel or Word, if installed (otherwise Pages), shows menu shortcuts.
- [ ] **Step 3:** Commit `feat: glass panel, search hotkey, tip cards`.

### Task 10: Bundled packs and pack-format docs

**Files:**
- Create: `Resources/Packs/{tmux,fish,bash,htop,vim,git,grep,awk,find,sed,pipes,nvtop,nvidia-smi}.toml`, `docs/packs.md`
- Test: `Tests/SanketaCoreTests/BundledPacksTests.swift`

**Interfaces:**
- Consumes: `PackLibrary`

Content rules:
- Each pack has 10–40 keys and/or 5–20 tips.
- tmux entries carry `command` matching `tmux list-keys` defaults, so live merge works.
- fish tips cover `for`, `if`/`test`, `string` (split, replace, match), `math`, `set -l/-g/-x`, `**` globbing, command substitution `(cmd)`, `and`/`or`, and `psub`.
- bash tips cover `for`, `while read`, `[[ ]]`, parameter expansion, `$(…)`, and `set -euo pipefail`.
- grep, awk, find, sed and pipes tips cover everyday data handling and file finding, e.g.:
  - `grep -rn`, `-c`, `-v`, `-o`
  - `awk '{print $2}'`, `-F`, sums
  - `find -name -mtime -exec`, `fd` if present
  - `sort | uniq -c | sort -rn`
  - `xargs`, `tee`
- htop entries are its key commands (F-keys, `/`, `\`, `t`, `H`, `K`, `u`, `P`/`M`/`T`, `s`, `l`, `space`/`c`/`U`) from `man htop`.
- `processes` cover the real binary names (`nvim`, `vim`, `vi` for vim; `nvtop`; `htop`).
- `nvidia-smi` is a tips-only pack with `processes = ["nvidia-smi"]`.
- Verify every key against the local man page (`man tmux`, `man htop`, `man fish`/fish docs, `man grep`). For nvtop and nvidia-smi, which aren't local, include only well-established basics.
- `docs/packs.md`: the full schema, matching rules (`processes`, `match` against argv, `apps` for GUI bundle ids), extend/replace, where user packs live, and a complete example for ramabana. It is written so an LLM can produce a valid pack from it.

- [ ] **Step 1: Write failing tests:**
  - `allBundledPacksParse` (zero errors). Locate `Resources/Packs` from `#filePath`; it is not a test resource.
  - `bundledIDsUniqueAndMatchFilename`
  - `everyPackHasContent`
  - `tmuxPackHasCommands`: every tmux key has a non-nil `command`
- [ ] **Step 2:** `swift test` → fail (packs missing).
- [ ] **Step 3:** Write the packs and `docs/packs.md`.
- [ ] **Step 4:** `swift test` → pass. Also confirm `--dump-context` in tmux shows live bindings merged with bundled labels.
- [ ] **Step 5:** Commit `feat: bundled packs and pack format docs`.

### Task 11: Remote hosts (title tag scripts + ControlMaster fallback)

**Files:**
- Create: `scripts/remote/sanketa.fish`, `scripts/remote/sanketa.bash`, `scripts/remote/tmux.conf`, `scripts/remote-setup.sh`, `Sources/SanketaCore/RemoteQuery.swift`
- Modify: `Sources/SanketaSystem/ContextMonitor.swift` (pass `RemoteQuery` to `LayerResolver`)
- Test: `Tests/SanketaCoreTests/RemoteQueryTests.swift`

**Interfaces:**
- Consumes: `RemoteQuerying` (Task 4), `CommandRunning`
- Produces: `public struct RemoteQuery: RemoteQuerying { init(runner: CommandRunning, cacheSeconds: Double = 5) }`
  - `paneCommand(sshArgv:)` parses the destination from argv (last non-option argument, skipping the values of `-p -l -i -o -J -F`).
  - It runs `/usr/bin/ssh -o BatchMode=yes -O check <dest>` with a 1 s timeout. Only if that succeeds does it run `/usr/bin/ssh -o BatchMode=yes <dest> tmux display -p "'#{pane_current_command}'"` with a 2 s timeout. The format is passed as one argv element *containing* single quotes, because ssh joins arguments into a remote shell line and an unquoted `#` starts a comment there.
  - Results are cached per destination.

Remote scripts:
- `sanketa.fish` first runs `functions -q __sanketa_default_title; or functions -c fish_title __sanketa_default_title`, then redefines `fish_title`. It prints `⟦sanketa host=(hostname -s) layers=…⟧ ` followed by the default fish title.
  - The layers start with `fish`.
  - `tmux` is added when `$TMUX` is set.
  - Then the current command's first word when one is running (`status current-command`, unless it is `fish`).
  - Tokens are restricted to the tag grammar; disallowed characters become `_`.
- `sanketa.bash` does the same for bash, using `PROMPT_COMMAND` plus a `DEBUG` trap emitting `\e]0;…\a`.
- `tmux.conf` contains `set -g set-titles on`, `set -g set-titles-string '#{pane_title}'` and `set -g allow-rename on`.
- `make remote-setup HOST=…` runs `scripts/remote-setup.sh HOST`. This stands in for the spec's `sanketa remote-setup` command (a planner's call: a repo script needs no CLI parsing in the app).
- `remote-setup.sh HOST`:
  - `scp`s the three files to `~/.config/sanketa/remote/` on HOST.
  - Appends idempotent `source` lines to `~/.config/fish/conf.d/sanketa.fish` (as a file copy), `~/.bashrc` and `~/.tmux.conf`, guarded by a marker comment.
  - Prints what changed.
  - It never runs without the user explicitly invoking it.

- [ ] **Step 1: Write failing tests** with a fake runner:
  - `destinationParsing` (`["ssh","-p","22","-i","k","me@gpubox"]` → `me@gpubox`)
  - `noControlMasterNoQuery`: check fails → nil, and the second command is never run
  - `queriesWhenMasterExists`: the fake runner sees the last argument exactly `'#{pane_current_command}'`, quotes included
  - `cachesPerDestination`: two calls → one query
- [ ] **Step 2:** `swift test` → fail.
- [ ] **Step 3:** Implement `RemoteQuery.swift`, the scripts and the setup script.
- [ ] **Step 4:** `swift test` → pass. Run a local simulation without touching the Linux laptop:
  - `cp /bin/sleep /tmp/sk/ssh`
  - in a Terminal window, run `fish -c "printf '\e]0;⟦sanketa host=gpubox layers=fish,tmux,htop⟧ htop\a'; /tmp/sk/ssh 600"`
  - `--dump-context` while that window is focused → `htop@gpubox, tmux@gpubox, fish@gpubox, gpubox, fish, Terminal`
  - check the fish snippet locally with `fish -c 'source scripts/remote/sanketa.fish; fish_title'` → prints a well-formed tag
- [ ] **Step 5:** Commit `feat: remote host layers`. Running `remote-setup.sh` against the real laptop is the user's call; mention it in the final report.

### Task 12: Logo, app icon and README

**Files:**
- Create: `design/logo/` (candidates and the chosen source), `Resources/AppIcon.icns`, `README.md`
- Modify: `Resources/Info.plist` (`CFBundleIconFile AppIcon`)

Steps:
- [ ] **Step 1:** Check `ramabana --help` for a non-interactive prompt or image-generation mode, and how to select model `gpt6-astra`. Generate 4 candidates at 1024×1024 into `design/logo/`.
  - Brief: a minimal macOS app icon (rounded square per the macOS 26 icon grid) for "Sanketa" (Sanskrit for hint or signal), suggesting a glass pane with a key or signal mark, in a saffron accent (`#E8A33D`), with no text.
  - If ramabana can't generate images non-interactively, stop and report. Don't substitute another tool without asking.
- [ ] **Step 2:** Pick the strongest candidate as the default and note why. Keep all four; the user will choose at the end.
- [ ] **Step 3:** Build the iconset with `sips` (16–1024 at @1x/@2x), then `iconutil -c icns` → `Resources/AppIcon.icns`. Run `make app verify`; the icon shows in Finder.
- [ ] **Step 4:** Write `README.md`, following the `write-prose` skill: what it is, install (`make app install`), granting Accessibility, the hotkey, user packs (link `docs/packs.md`), remote setup, and the limits:
  - non-default tmux sockets and nested tmux
  - iTerm2 sessions under a re-parented `iTermServer` may not resolve beyond the app layer
  - remote layers need the title snippet or a ControlMaster
  - tty choice in multi-tab terminals is heuristic
- [ ] **Step 5:** Commit `feat: app icon and README`.
