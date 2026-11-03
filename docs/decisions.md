# Decisions

This page lists the choices that a maintainer must know. Each entry gives the choice, the reason, the date, and the place in the code.
The rules for tests, the panel and the text are in [CONTRIBUTING.md](../CONTRIBUTING.md). The build and the release are in [development.md](development.md). The user view is in [guide.md](guide.md). This page does not say those things again.
The first designs and plans (24 to 27 October 2026) are in the git history under `docs/superpowers/`.

## The app

- **A native Swift app for macOS 26 on Apple silicon.** Why: it gets the glass look, cheap reads of the process table, and Apple's on-device model. (24 Oct 2026) `Package.swift`.
- **The core works with no model and no Python.** Packs, layers, menu keys, tmux keys and plain search need nothing more. A model only picks from entries that Sanketa loaded. (24 Oct 2026) `Sources/SanketaCore/`.
- **Accessibility is the one permission.** Sanketa reads menu keys and window titles with it. It never records keys. A hold reads only which modifier keys are down, and the time since the last key press, never the key. The chord field is the one place that reads a key, and only in its own field. (24 and 27 Oct 2026) `AXReader.swift`, `HoldDetector.swift`.
- **The Accessibility grant goes with the code signature.** Thus `make app` signs the real bundle with the Apple Development identity, so the grant stays after a rebuild. A dev build and the Homebrew copy each get their own grant. If the grant does not work, run `tccutil reset Accessibility dev.sanketa.Sanketa`, then grant it one time. (25 Oct 2026) `Makefile`.

## Layers

- **Layers come from the process table and tmux.** Sanketa walks the process tree of the terminal with `sysctl`. It asks tmux for the active pane with `list-clients` on the default socket only. Other sockets and tmux in tmux are a known limit. (24 Oct 2026) `LayerResolver.swift`, `Tmux.swift`, `SysctlProcesses.swift`.
- **A check runs each second, and only while a terminal is in front.** The panel changes only when the stack of layers changes. `pollInterval` sets the time. (24 Oct 2026) `ContextMonitor.swift`.
- **A pack can match the command line.** `match` looks for text in the full argv, because some tools run as `python3`, such as ramabana. (24 Oct 2026) `Pack.swift`.
- **Remote layers come from the window title.** A small fish or bash script on the host puts a tag in the title, and tmux passes it on. The fallback asks over ssh, but only on an open ControlMaster link, so it never asks for a password. No daemon and no open port. (24 Oct 2026) `scripts/remote/`, `RemoteTag.swift`, `RemoteQuery.swift`.

## Better ways

- **Rules only, no model.** In the bench, each model broke 3 to 14 of 20 rewrites. Each command gets one rewrite at most. A rule fires only when its rewrite is safe. Each good example runs in real fish or bash, and the output must be the same as the output of the old command. (24 Oct 2026, the user's choice) `Detectors.swift`, `ShellLex.swift`.
- **History stays on this Mac, and the read is small.** Sanketa reads the last 4 MB of each file and checks the file with `stat` each minute. fish writes its file again by rename, so `stat` works better than a file watch. (24 Oct 2026) `History.swift`, `CoachMonitor.swift`.
- **One card.** A better way shows in the tip slot. It is not a second card, and it is never a notification. (24 Oct 2026) `Coach.swift`.

## Search and models

- **Find first, then let a model pick.** Local search finds up to 40 entries. The model gives back only refs from that list, under a fixed schema. It never writes text that the user sees. A pick list that is the first refs in order counts as no pick. (24 Oct 2026) `Retrieval.swift`, `SmartSearch.swift`.
- **The order of models.** First the on-device MLX model, then Apple Intelligence, then an OpenAI server (off by default), then plain search. Gemma 4 E4B is the best on-device model. Qwen3.5 is for a Mac with less memory. Core ML and LiteRT are not used: Core ML is slow to load, and LiteRT's fixed schema output is broken for Gemma. (24 and 25 Oct 2026) `Config.swift`, `ModelCatalog.swift`.
- **A model downloads only when the user asks.** Each file is pinned to one Hugging Face commit, with its size and SHA-256. The files go to a `.partial` folder first. The model unloads after one minute with no search. (24 Oct 2026) `ModelInstaller.swift`, `ModelCatalog.swift`, `IdleHolder.swift`.
- **MLX needs `xcodebuild`.** SwiftPM cannot build the Metal shaders of MLX. `make app` uses `xcodebuild`. A build from `swift build` has no MLX. (24 Oct 2026) `Makefile`.
- **Apple Intelligence needs three fixes.** Use `includeSchemaInPrompt: false`, or it gives empty lists. Call `prewarm()` when a search starts. Make a new session for each call. (24 Oct 2026) `AppleFMChooser.swift`.
- **The API key goes in the Keychain through `SecItem` only.** Never use the `security` tool. A key goes only to its own host. Shell history, titles and layer names never leave this Mac. (24 Oct 2026) `KeyStore.swift`, `APIKey.swift`.
- **Config names.** New keys use snake_case, such as `hold_delay`. The old top-level keys stay camelCase, such as `pollInterval`. (24 Oct 2026) `Config.swift`.

## Vault

- **Hybrid search uses the vault server over stdio.** Sanketa starts `vishalakshi-mcp` as a child and calls `federate` to search and `note` to save. It does not use HTTP, because that server always listens on port 8000. It does not encode the query in Swift, because that needs 512 MB of weights and the tokens could be different. Keyword search in Swift is the fallback. (26 Oct 2026) `MCPClient.swift`, `VaultHybrid.swift`, `VaultSearch.swift`.
- **Only two keys save.** ⌘S saves the query and ⌘D saves the clipboard. Each save gets a new key, so a save never replaces a note. (26 Oct 2026) `SearchModel.swift`, `VaultHybrid.swift`.

## Held keys

- **A global key wins.** An AeroSpace key comes before the app. The app row that uses the same chord gets a line through it. (27 Oct 2026) `ComboView.swift`.
- **One panel, and a thin bar for AeroSpace.** The user chose one panel, not two windows that fight to be on top. The AeroSpace bar lets clicks go through. (27 Oct 2026) `AeroBarController.swift`.
- **Free keys come from rules, not a model.** The order is: the same modifiers, near the keys of the same group, the left hand first, then the first letter of a word of the action. (27 Oct 2026) `KeySuggest.swift`.
- **A key change is safe and can be undone.** Sanketa asks before it writes, keeps `<file>.sanketa-bak`, and offers Undo. The writers keep comments, order and format. For Leela, it writes only into `keys`, never into `_defaults`, and it refuses the `+` key, because Leela splits chords on `+`. For AeroSpace, it runs `aerospace reload-config`. (27 Oct 2026) `KeyWriters.swift`, `Chord.swift`.
