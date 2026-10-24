# Sanketa Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sanketa coaches better shell idioms from local fish and bash history in its one tip slot, and adds natural-language search that lets a model choose only among loaded entries: MLX Qwen3.5 on device, then Apple Foundation Models, then an opt-in OpenAI-compatible server, then plain search.

**Architecture:**
- `SanketaCore` gains pure code with no model imports: history parsing, a shell lexer, 13 rule detectors and the coach aggregation, loose retrieval, the prompt, grounding, the `Choosing`/`OnDeviceChooser` protocols, `ModelRouter`, `SmartSearch`, `SmartSuggest`, the OpenAI model-list rule and the model catalog.
- New `SanketaAI` target (Foundation and system frameworks only): `AppleFMChooser`, `OpenAIChooser`, `ModelList` fetch, `KeyStore`/`KeychainStore`, `APIKey` lookup, `ModelInstaller`.
- New `SanketaMLX` target (the only one that imports MLX): `MLXChooser` and its idle-unload holder.
- `SanketaSystem` gains `CoachMonitor`. `SanketaUI` gets the coaching card in the tip slot and async NL search in `SearchModel`. The app wires the status menu, Copy Debug Info and the `--dump-coach`, `--ask` and `--install-model` CLI modes.

**Tech Stack:** Swift 6.2 / Xcode 26 (SDK macOS 26.5), language mode v5, Swift Testing, FoundationModels, Security (`SecItem*`), CryptoKit (`SHA256`), `URLSession`. New packages (only in `SanketaMLX`): `https://github.com/ml-explore/mlx-swift-lm` exact `3.32.3` (products `MLXLLM`, `MLXLMCommon`, `MLXGuidedGeneration`) and `https://github.com/huggingface/swift-transformers` exact `1.3.5` (product `Tokenizers`).

**Spec:** `docs/superpowers/specs/2026-10-24-sanketa-design.md` (goals 8, 9, anti-goals) and the addendum `docs/superpowers/specs/2026-10-24-sanketa-phase2-design.md` (decisions, verified API facts, exactly what leaves the machine). Model evidence: `.superpowers/phase2/model-bench.md` (git-ignored). Builds on v0.1.1 on `main`. Run phase 2 on a new branch `phase2` from `main`.

**Status:** every task is executable now. Task 10 has a hard prerequisite (the Metal toolchain, open question 1) and a stop rule.

## Global Constraints

- Platform macOS 26, Apple Silicon; `platforms: [.macOS(.v26)]`; Swift tools 6.2; `.swiftLanguageMode(.v5)` on every target; Swift Testing (`import Testing`).
- Permissions: Accessibility only. No input monitoring, no notifications, no sounds.
- Network: only (a) the opt-in OpenAI-compatible POST and `GET /models` when `[llm] openai = true`, and (b) the user-started model download from `huggingface.co`. The addendum's "Exactly what leaves the machine" list is binding. History, coaching results, window or document titles, layer and process names and `app:` items never leave the machine.
- Shell history is read locally only: never written, copied into the repo, logged or used as a fixture. **Agents must not read the user's real history.** Verify with `--dump-coach` (detector ids and counts only), never `--dump-coach --full`. Tests make their own history files in temp dirs.
- **Tests never read the user's real `~/.config/sanketa`, history, Keychain items or environment key.** Pass paths, env dictionaries, shells and stores in. The MLX live tests may read the model folder (weights only), overridable with `SANKETA_MODEL_DIR`.
- Endpoint security (binding): never copy, rename or re-sign a binary; never spoof argv[0]; spawn only real, unmodified programs. Never run `codesign` or `security` from an agent; the Keychain is used only through `SecItem*` in app code.
- The panel never takes focus except in hotkey-started search mode or a user-chosen menu item (the key box). No popups: model failures give at most one muted line under the search results.
- Idle CPU well under 1%: no model call while idle; history `stat`ed every 60 s; model suggestions at most once per 600 s; the model is called only for queries of 3 or more words, 600 ms after the last keystroke, cancelling any call in flight; the MLX model unloads after 60 s idle.
- The model never invents entries: it returns refs only, under constrained decoding, and `Grounding.resolve` checks them again.
- Prompt budget: candidate lines ≤ 6000 characters in total, each ≤ 160; recent commands ≤ 10, each ≤ 120 characters.
- Every external command goes through `CommandRunning` with a timeout. Binaries by absolute path: fish `/opt/homebrew/bin/fish`, bash `/bin/bash`. Tests run fish with `--no-config` and bash with `--norc --noprofile`.
- Config: new tables `[coach]` and `[llm]` with snake_case keys. Older top-level keys stay as they are.
- Testing directive (binding): real functional tests (real files, real fish/bash, real `ProcessRunner` children, real `URLProtocol`-served bytes, the live model tests gated on availability). No code-shape assertions.
- Prose in README and UI strings: ASD-STE100, grade 9 or below (`ProseTests.docIsGradeNineOrBelow` checks README).
- Commits: one terse STE line, no body, no AI credit. Stage files explicitly (`git add <paths>`), never `git add -A`. Agents cannot run `rm`, `kill`, `pkill` or `killall`; move files to `/tmp/sanketa-trash` instead.
- Existing test helpers in `SanketaCoreTests` are global: `tempDir() throws -> URL`, `tempDir(_ files:)`, `run(_:_:input:)`, `repoRoot`. Reuse them; do not redefine them.

## Review Focus

1. **A rewrite that changes what the command does** (multi-file grep, `sort -n`, `cut` on lines without the delimiter, `ls DIR`, hidden files under `**`). The user expects no suggestion rather than a wrong one. Pinned by `noRewriteForUnsafeInput` and `rewriteIsEquivalentInRealShell` (Task 4).
2. **A huge, truncated or non-UTF-8 history file, or a missing one.** Expect a bounded read, broken bytes tolerated, no error shown. Pinned by `readsTailOfHugeFile`, `invalidUTF8DoesNotCrash`, `missingFilesGiveEmpty` (Task 2).
3. **No usable model: Apple Intelligence off, the MLX model not downloaded, the metallib missing, or a model that errors or hangs.** Plain results show at once with one muted note. Pinned by `smartSearchFallsBackOnError`, `smartSearchTimesOut`, `routerOrder` (Task 6), `unavailableFMDegrades` (Task 7), `notInstalledIsUnavailable` and `missingMetallibIsUnavailable` (Task 12).
4. **A model download that stops halfway, or a file with the wrong bytes.** The model must not count as installed, and a later run must start clean. Pinned by `badHashLeavesNothingInstalled` and `interruptedDownloadIsNotInstalled` (Task 11).
5. **The API key or private data leaving through the wrong path.** The key must never show in Copy Debug Info, stderr or the request body; history and menu items must never be in the POST. Pinned by `remoteChooserNeverSeesMenuItems` (Task 6), `bodyIsExactlyWhatLeaves` (Task 8), `keyNeverInDebugInfo` (Task 13).

---

## File Structure

```
Package.swift                         (modify, T7, T10) SanketaAI, SanketaMLX, SanketaAITests, SanketaMLXTests
Makefile                              (modify, T10, T13) xcodebuild bundle, test-mlx; release notes text
.github/workflows/build.yml           (modify, T10) Metal toolchain step
Sources/SanketaCore/
  Config.swift          (modify) CoachConfig, LLMConfig, table-aware setting/save
  History.swift         Shell, HistoryEntry, FishHistory, BashHistory, HistoryFile, HistoryCache
  ShellLex.swift        Word, Substitution, ShellCommand, ShellLex
  Detectors.swift       Rewrite, Detector, Detectors.all + stage helpers
  Coach.swift           Coaching, Coach.rewrites/analyze
  Retrieval.swift       Retrieval, ChoicePrompt, Grounding
  SmartSearch.swift     ModelStatus, ChoiceError, Choosing, OnDeviceChooser, ModelRouter, SmartResult, SmartSearch, SmartSuggest
  OpenAIModels.swift    OpenAIModels.chatCapable/cheapest
  ModelCatalog.swift    ModelFile, ModelSpec, ModelCatalog
Sources/SanketaAI/
  AppleFMChooser.swift, OpenAIChooser.swift (OpenAIRequest, OpenAIChooser, ModelList)
  KeyStore.swift (KeyStore, KeychainStore, MemoryKeyStore), APIKey.swift, ModelInstaller.swift
Sources/SanketaMLX/
  MLXChooser.swift, IdleHolder.swift
Sources/SanketaSystem/
  CoachMonitor.swift, DebugInfo.swift (modify)
Sources/SanketaUI/
  PanelModel.swift (modify), SearchModel.swift (modify), PanelController.swift (modify),
  Views/TipCard.swift (modify), Views/PanelView.swift (modify), KeyBox.swift
Sources/Sanketa/
  AppDelegate.swift (modify), main.swift (modify)
Tests/SanketaCoreTests/
  ConfigTests.swift (modify), Support/Shells.swift, HistoryTests.swift, ShellLexTests.swift,
  DetectorExamples.swift, DetectorTests.swift, CoachTests.swift, RetrievalTests.swift,
  SmartSearchTests.swift, OpenAIModelsTests.swift, Support/Choosers.swift
Tests/SanketaAITests/
  AppleFMChooserTests.swift, OpenAIChooserTests.swift, APIKeyTests.swift, ModelInstallerTests.swift, Support/StubProtocol.swift
Tests/SanketaMLXTests/
  IdleHolderTests.swift, MLXChooserTests.swift
Tests/SanketaSystemTests/
  CoachMonitorTests.swift, DebugInfoTests.swift (modify), AskCLITests.swift
Tests/SanketaUITests/
  CoachCardTests.swift, SmartSearchModelTests.swift
README.md (modify)
```

---

### Task 1: `[coach]` and `[llm]` config tables

**Files:**
- Modify: `Sources/SanketaCore/Config.swift`
- Test: `Tests/SanketaCoreTests/ConfigTests.swift`

**Interfaces:**
- Consumes: `Config`, `Config.load(_:) -> (Config, String?)`, `Config.setting(_:_:in:)`, `Config.save(_:_:to:)`, `PackLint.describe`.
- Produces:
  - `public enum MLXModelChoice: String, Codable, CaseIterable, Sendable { case qwen4b = "qwen3.5-4b", qwen2b = "qwen3.5-2b" }`
  - `public struct CoachConfig: Codable, Equatable, Sendable { enabled = true; fishHistory = "~/.local/share/fish/fish_history"; bashHistory = "~/.bash_history"; maxEntries = 5000 }`, TOML keys `enabled`, `fish_history`, `bash_history`, `max_entries`; `var fishURL: URL`, `var bashURL: URL` with `~` expanded.
  - `public struct LLMConfig: Codable, Equatable, Sendable`, TOML keys and defaults:
    - `on_device = true` (MLX tier), `mlx_model = "qwen3.5-4b"`, `apple_fm = true`, `suggest = true`
    - `openai = false`, `openai_model = ""` (empty means "cheapest, chosen at runtime"), `base_url = "https://api.openai.com/v1"`, `api_key_env = "OPENAI_API_KEY"`
    - `timeout_seconds = 5`
    - Swift names: `onDevice`, `mlxModel: MLXModelChoice`, `appleFM`, `suggest`, `openai`, `openaiModel`, `baseURL: String`, `apiKeyEnv`, `timeoutSeconds: Double`.
  - Both structs have `public init()` with the defaults above and `public var` fields.
  - `Config` gains `coach: CoachConfig` and `llm: LLMConfig` (`decodeIfPresent`). Each nested struct has its own `init(from:)`, so a partial table keeps its defaults. Numbers accept TOML int or float, like `num(_:_:)`. An unknown `mlx_model` value is an error (defaults returned with the message).
  - `Config.setting(_ key: String, _ value: String, in text: String, table: String? = nil) -> String`. With `table`, the key is replaced inside `[table]` (up to the next `[` line), else appended at the end of that table; when the table is missing, `\n[table]\nkey = value` is appended at the end. Without `table`, the current behaviour stays.
  - `Config.save(_ key:_ value:to:table: String? = nil) throws`.

- [ ] **Step 1: Write failing tests:**
  - `llmDefaultsKeepOpenAIOff`: empty file → `llm.openai == false`, `llm.onDevice == true`, `llm.appleFM == true`, `llm.openaiModel == ""`, `llm.baseURL == "https://api.openai.com/v1"`, `coach.enabled == true`
  - `llmTableParses`: `"[llm]\nopenai = true\nopenai_model = \"gpt-x\"\nbase_url = \"http://localhost:11434/v1\"\nmlx_model = \"qwen3.5-2b\""` → those values; `suggest == true`
  - `integerTimeoutAccepted`: `"[llm]\ntimeout_seconds = 3"` → `3.0`
  - `coachPathsExpandTilde`: default `fishURL.path == NSHomeDirectory() + "/.local/share/fish/fish_history"` (no file read)
  - `badLLMTypeReturnsError`: `"[llm]\nopenai = \"yes\""` and `"[llm]\nmlx_model = \"huge\""` → defaults and a non-nil error
  - `tableSettingReplacesInsideTable`: text `"hotkey = \"x\"\n[llm]\nopenai = true\nopenai_model = \"a\"\n[coach]\nenabled = true\n"`, `setting("openai_model", "\"b\"", in:, table: "llm")` → only that line changes; `setting("base_url", "\"u\"", …, table: "llm")` inserts after `openai_model` and before `[coach]`; `setting("openai_model", "\"b\"", in: "hotkey = \"x\"\n", table: "llm")` ends with `"\n[llm]\nopenai_model = \"b\"\n"`; the result of each loads through `Config.load` with the new value
  - `saveWithTableWritesFile`: `Config.save("openai_model", "\"m\"", to: tempDir()/config.toml, table: "llm")` then `Config.load` → `llm.openaiModel == "m"`
- [ ] **Step 2:** `swift test --filter ConfigTests` → the new tests fail.
- [ ] **Step 3:** Implement in `Config.swift`. Extend `CodingKeys` with `coach`, `llm`. Update the `openConfig()` template in `AppDelegate.swift` with commented `[coach]` and `[llm]` blocks showing every default.
- [ ] **Step 4:** `swift test` → all pass.
- [ ] **Step 5:** Commit: `git add Sources/SanketaCore/Config.swift Sources/Sanketa/AppDelegate.swift Tests/SanketaCoreTests/ConfigTests.swift && git commit -m "Add coach and llm config tables"`

### Task 2: Shell history reading

**Files:**
- Create: `Sources/SanketaCore/History.swift`, `Tests/SanketaCoreTests/Support/Shells.swift`
- Test: `Tests/SanketaCoreTests/HistoryTests.swift`

**Interfaces:**
- Produces:
  - `public enum Shell: String, Codable, Hashable, Sendable, CaseIterable { case fish, bash }`
  - `public struct HistoryEntry: Hashable, Sendable { command: String; when: Date?; shell: Shell }`
  - `FishHistory.parse(_ text: String) -> [HistoryEntry]`:
    - `- cmd: ` starts an entry. Unescape in one left-to-right pass: `\\` → `\`, `\n` → newline, any other `\x` kept.
    - `  when: N` sets the date. `  paths:`, `    - …`, `  added_when: …`, unknown keys and lines before the first `- cmd:` are ignored. No `when` → `nil`.
  - `BashHistory.parse(_ text: String) -> [HistoryEntry]`: a line matching `^#\d+$` dates the next command line; blank lines skipped; each other line is one command.
  - `HistoryFile.readTail(_ url: URL, maxBytes: Int = 4_000_000) -> String?`: nil when missing or unreadable; when larger than `maxBytes`, seek to `size - maxBytes` and drop through the first `\n`; decode with `String(decoding:as: UTF8.self)`.
  - `public final class HistoryCache: @unchecked Sendable { init(); func entries(fish: URL?, bash: URL?, maxEntries: Int) -> [HistoryEntry]; private(set) var generation: Int }`: fish entries then bash entries, each in file order and capped to its last `maxEntries`; a file is re-read only when `(modificationDate, size)` changes; `generation` increments only when the result changed; guarded by an `NSLock`.
  - Test support in `Shells.swift`:
    - `runFish(_ script: String, in dir: URL) -> String?`: `ProcessRunner().run("/opt/homebrew/bin/fish", ["--no-config", "-c", "cd '<dir>'; <script>"], timeout: 5)`
    - `runBash(_ script: String, in dir: URL) -> String?`: `/bin/bash --norc --noprofile -c …`
    - `writeFishHistory(_ commands: [String], in dir: URL) -> URL`: runs `/usr/bin/env XDG_DATA_HOME=<dir> XDG_CONFIG_HOME=<dir> /opt/homebrew/bin/fish --no-config -c "set -g fish_history sktest; history append <each command fish-single-quoted>; history save"`; returns `<dir>/fish/sktest_history`.

- [ ] **Step 1: Write failing tests:**
  - `fishParsesRealFishOutput`: `writeFishHistory(["cat a.log | grep 404 | wc -l", "for f in (ls *.txt)\necho $f\nend", "echo a\\b"])` → 3 entries with exactly those commands, every `when` within 120 s of now, `shell == .fish`
  - `fishIgnoresPathsAndAddedWhen`: `"- cmd: ls\n  when: 1792000000\n  paths:\n    - /tmp\n  added_when: 1792000001\n- cmd: pwd\n  when: 1792000002\n"` → `["ls","pwd"]`, first `when == Date(timeIntervalSince1970: 1792000000)`
  - `bashParsesRealBashOutput`: `runBash("set -o history; history -s 'sort x | uniq'; history -s 'ps aux | grep node'; history -w h", in: dir)` → parse `dir/h` → exactly those two, `when == nil`
  - `bashTimestampsApply`: `"#1792000000\nls -la\npwd\n"` → `ls -la` dated, `pwd` nil
  - `missingFilesGiveEmpty`: `HistoryCache().entries(fish: dir/"nope", bash: dir/"nope2", maxEntries: 10) == []`
  - `readsTailOfHugeFile`: 20 MB of `- cmd: echo N\n  when: N\n` → `readTail` `utf8.count <= 4_000_000`; first parsed command matches `^echo \d+$`; read and parse in < 1 s
  - `invalidUTF8DoesNotCrash`: bytes of `- cmd: ls \xFF\xFE\n  when: 1\n- cmd: pwd\n  when: 2\n` → 2 entries, the second `pwd`
  - `truncatedLastEntryKept`: `"- cmd: ls\n  when: 1\n- cmd: git st"` → last is `git st`, `when == nil`
  - `cacheReReadsOnlyOnChange`: two calls, no change → same `generation`; real fish appends `git status` → `generation` increments and `git status` is last
  - `maxEntriesKeepsNewest`: 10 fish entries, `maxEntries: 3` → the last 3
- [ ] **Step 2:** `swift test --filter HistoryTests` → fail.
- [ ] **Step 3:** Implement `History.swift` and `Shells.swift`.
- [ ] **Step 4:** `swift test` → pass.
- [ ] **Step 5:** Commit: `git add Sources/SanketaCore/History.swift Tests/SanketaCoreTests/Support/Shells.swift Tests/SanketaCoreTests/HistoryTests.swift && git commit -m "Read fish and bash history"`

### Task 3: Shell command lexer

**Files:**
- Create: `Sources/SanketaCore/ShellLex.swift`
- Test: `Tests/SanketaCoreTests/ShellLexTests.swift`

**Interfaces:**
- Consumes: `Shell`
- Produces:
  - `public struct Word: Hashable, Sendable { raw: String; value: String; globbed: Bool; var isRedirect: Bool }`. `raw` is the source text with quotes; `value` has quotes and escapes removed (a substitution part stays raw); `globbed` is true for an unquoted `*`, `?` or `[`; `isRedirect` is true when `raw` matches `^[0-9&]*(<|>|>>|>&\d*|<&\d*)$` or `^[0-9]*>&[0-9]+$`.
  - `public enum Substitution: Hashable, Sendable { case paren, dollar, backtick }` (`paren` is fish `( )`).
  - `public struct ShellCommand: Hashable, Sendable { text: String; stages: [[Word]]; substitution: Substitution?; wrappedText: String? }`. `text` is the trimmed source of one pipeline; `wrappedText` includes the delimiters, e.g. `$(expr $n + 1)`.
  - `ShellLex.commands(_ line: String, shell: Shell) -> [ShellCommand]`

Rules:
- Commands end at `;`, `&&`, `||`, a lone `&` and newlines. Stages split on `|`, `|&` and fish `&|`.
- A `#` at the start of a word starts a comment to the end of the line.
- Single quotes are literal; in fish, `\'` and `\\` are escapes inside them. Inside double quotes, `\"`, `\\` and `\$` are escapes and `$(…)` is still a substitution. An unquoted backslash escapes the next character.
- Substitutions: fish `( … )` unquoted, `$( … )` in both shells, backticks in bash. Parentheses nest. The inner text is lexed recursively; its commands come straight after the command that holds them, with `substitution` and `wrappedText` set.
- Leading keywords are dropped: fish `and or not time command builtin`; bash `time ! do then else elif`.
- An unbalanced quote, parenthesis or backtick anywhere → `[]`.

- [ ] **Step 1: Write failing tests** (assert `stages.map { $0.map(\.value) }` unless noted):
  - `pipelineStages`: `cat a.log | grep 404 | wc -l` (fish) → `[[cat,a.log],[grep,404],[wc,-l]]`
  - `quotedPipeStaysInWord`: `grep 'a|b' f | wc -l` → `[[grep,a|b,f],[wc,-l]]`, `stages[0][1].raw == "'a|b'"`
  - `separators` (bash): `cd /tmp && ls | grep x; echo done` → texts `["cd /tmp","ls | grep x","echo done"]`
  - `fishSubstitution`: `set n (expr $n + 1)` → `[0]` raws `[set,n,(expr $n + 1)]`; `[1]` values `[expr,$n,+,1]`, `.paren`, `wrappedText == "(expr $n + 1)"`
  - `bashDollarSubstitutionInDoubleQuotes`: `echo "count: $(grep -c x f)"` → `[1]` values `[grep,-c,x,f]`, `.dollar`
  - `backtickSubstitution` (bash): ``n=`expr $n + 1` `` → `[1]` values `[expr,$n,+,1]`, `.backtick`
  - `fishKeywordsDropped`: `test -f x; and cat x | grep y` → `[1]` stages `[[cat,x],[grep,y]]`
  - `multilineFishLoop`: `"for f in (ls *.log)\necho $f\nend"` → texts `["for f in (ls *.log)","ls *.log","echo $f","end"]`
  - `unbalancedQuoteGivesNothing`: `echo 'oops | grep x` → `[]`; fish `echo (ls` → `[]`
  - `commentIgnored`: `ls | grep x # find x` → `[[ls],[grep,x]]`
  - `globFlag`: `ls *.log '*.txt'` → `globbed` `[false,true,false]`
  - `redirectWords`: `sort < in.txt > out.txt 2>&1` → `isRedirect` true for `<`, `>`, `2>&1` only
  - `escapedSpace`: `echo a\ b | wc -c` → `[[echo,a b],[wc,-c]]`
- [ ] **Step 2:** `swift test --filter ShellLexTests` → fail.
- [ ] **Step 3:** Implement a single-pass character scanner with a quote state and a paren-depth stack.
- [ ] **Step 4:** `swift test` → pass.
- [ ] **Step 5:** Commit: `git add Sources/SanketaCore/ShellLex.swift Tests/SanketaCoreTests/ShellLexTests.swift && git commit -m "Add shell command lexer"`

### Task 4: Better-ways detectors and coach aggregation

**Files:**
- Create: `Sources/SanketaCore/Detectors.swift`, `Sources/SanketaCore/Coach.swift`
- Test: `Tests/SanketaCoreTests/DetectorExamples.swift`, `DetectorTests.swift`, `CoachTests.swift`

**Interfaces:**
- Consumes: `ShellLex`, `ShellCommand`, `Word`, `Shell`, `HistoryEntry`, `SearchItem(packID:packName:kind:title:detail:explain:tags:)`, `ItemKind.suggestion`
- Produces:
  - `public struct Rewrite: Hashable, Sendable { before: String; after: String; explain: String }`
  - `public struct Detector: Sendable { id: String; title: String; shells: Set<Shell>; rewrite: @Sendable (ShellCommand, Shell) -> Rewrite? }`. Titles are 6 words or fewer (e.g. "Count matches with grep -c").
  - `public enum Detectors { static let all: [Detector] }` in this order: `pgrep, grep-count, grep-awk, sort-unique, find-xargs, find-glob, ls-grep, glob-loop, math, string-split, string-replace, string-case, useless-cat`
  - `Coach.rewrites(_ line: String, shell: Shell) -> [(detectorID: String, title: String, rewrite: Rewrite)]`: lex, then for each command the first detector in order that returns non-nil.
  - `public struct Coaching: Hashable, Sendable { detectorID: String; title: String; shell: Shell; before: String; after: String; explain: String; count: Int; lastSeen: Date?; var item: SearchItem }`. `item`: `packID "coach"`, `packName "Better ways"`, `kind .suggestion`, `title`, `detail = after`, `explain = "Instead of \(before) · \(count)× in your history. \(explain)"`, `tags ["coach", detectorID, shell.rawValue]`.
  - `Coach.analyze(_ entries: [HistoryEntry]) -> [Coaching]`: one result per (detector, shell) that fired; `count` = entries with a hit; the example comes from the latest hit by date (undated entries rank by file order, after dated ones); sorted by `count` desc, then `lastSeen` desc.

Detector rules. `before` is `ShellCommand.text`; for substitutions it is the inner text, except bash `math`, where it is `wrappedText`. Words are re-emitted with `raw`.
- **Cat fold** (shared by `grep-count`, `grep-awk`, `sort-unique`, `useless-cat`): a first stage that is exactly `cat F` (one non-flag, non-glob word) folds `F` into the next stage as its file.
- **pgrep:** stage 0 is `ps` with args in `{aux, -ef, -e, ax}`; the rest is one `grep NAME` (no flags, NAME `^[A-Za-z0-9._-]+$`), optionally with `grep -v grep` before or after → `pgrep -fl NAME`.
- **grep-count:** stage i is `grep` with no `-o -c -l -L --count` and at most one file operand after the pattern; stage i+1 is exactly `wc -l` → `grep -c <grep's args>`, earlier stages kept or the cat fold applied.
- **grep-awk:** adjacent `grep PAT [F]` (no flags, PAT value `^[A-Za-z0-9_ :=-]+$`) and `awk [-F X | -FX] '{…}'` (program value starts with `{`) → `awk [-F…] '/PAT/ PROGRAM' [F]`.
- **sort-unique:** `sort` with no flags or only `-r`, then a bare `uniq` → `sort [-r] -u [F]`, cat fold applied.
- **find-xargs:** `find DIR [-type f] -name PAT | xargs CMD ARGS…` (PAT starts with `*`, no `/`; no other predicates; xargs without flags). fish → `CMD ARGS… <DIR/>**<PAT minus leading *>` (`./` dropped for `.`); bash → `find DIR [-type f] -name PAT -exec CMD ARGS… {} +`.
- **find-glob (fish):** single-stage `find DIR [-type f] -name PAT` (PAT rules as above) → `printf '%s\n' <glob>`.
- **ls-grep:** `ls` or `ls -1` with no other args into `grep P` with no flags. P `^[A-Za-z0-9_-]+$` → `ls -d *P*`; P `\.ext$` or `.ext$` (ext `[A-Za-z0-9]+`) → `ls -d *.ext`.
- **glob-loop:** `for VAR in` with a fish `(ls ARGS)` or `$(ls ARGS)` where every ARG is `globbed` and there are no flags → `for VAR in ARGS` (or `*` with no ARGS).
- **math:** `expr` with all args numbers, `$var` or operators in `+ - \* / %`; or `bc` with no flags fed by `echo E`. fish → `math [-s0] ARGS` (`-s0` when the expression has `/` or `%`; with `*`, a single-quoted expression with `\*` → `*`; bc always single-quoted). bash `expr` → `echo $(( ARGS ))`, or in a substitution `$(( ARGS ))`, with `\*` → `*`.
- **string-split (fish):** `echo $VAR` (one word starting with `$`, optionally double-quoted) into `cut -dD -fN` or `cut -d D -fN` (D one character, N one integer) → `string split -fN D $VAR`.
- **string-replace (fish):** `echo $VAR | sed 's/A/B/[g]'`, A `^[A-Za-z0-9_:@,=+]+$`, B the same class or empty → `string replace [-a] A B $VAR` (empty B as `''`).
- **string-case (fish):** `echo $VAR | tr a-z A-Z` or `tr '[:lower:]' '[:upper:]'` → `string upper $VAR`; the reverse → `string lower $VAR`.
- **useless-cat:** stage 0 `cat F` (one file, no flags) with a next stage; next in `grep awk sed head tail sort cut` → `<next words> F`; next in `wc tr` → `<next words> < F`; else no rewrite.

Explain copy (one line each; keep these facts):
- pgrep: "pgrep -f matches full command lines and never lists itself."
- grep-count: "grep -c counts matching lines itself."
- grep-awk: "awk can match the pattern and print the field in one pass."
- sort-unique: "sort -u drops duplicate lines while sorting."
- find-xargs: fish "** expands to the matching files; names with spaces stay intact." bash "-exec … {} + batches files like xargs and copes with spaces."
- find-glob: "fish's ** walks subdirectories (it skips hidden ones)."
- ls-grep: "A glob picks the names directly."
- glob-loop: "Loop over the glob; parsing ls breaks on spaces."
- math: fish "fish's math builtin; -s0 keeps integer division." bash "Shell arithmetic, no extra process."
- string-split: "fish's string split -fN picks one field."
- string-replace: "fish's string replace works on variables directly."
- string-case: "fish's string upper/lower."
- useless-cat: "Give the file to the command directly."

`DetectorExamples.swift` defines `struct Example: Sendable, CustomTestStringConvertible { shell: Shell; setup: String; input: String; detector: String; before: String; after: String; check: Check }`, `enum Check { case exact, trimmed, sortedLines, sortedNoDotSlash, none }`, and two arrays.

`positive` (setup before ⏐; default empty):

| # | sh | input | detector | before | after | check |
|---|---|---|---|---|---|---|
| 1 | fish | `cat a.log \| grep 404 \| wc -l` | grep-count | (input) | `grep -c 404 a.log` | trimmed |
| 2 | bash | `grep GET a.log \| wc -l` | grep-count | (input) | `grep -c GET a.log` | trimmed |
| 3 | fish | `sort a.log \| grep 404 \| wc -l` | grep-count | (input) | `sort a.log \| grep -c 404` | trimmed |
| 4 | bash | `grep 'GET /gone' a.log \| wc -l` | grep-count | (input) | `grep -c 'GET /gone' a.log` | trimmed |
| 5 | fish | `cat a.log \| grep POST` | useless-cat | (input) | `grep POST a.log` | exact |
| 6 | bash | `cat a.log \| wc -l` | useless-cat | (input) | `wc -l < a.log` | exact |
| 7 | bash | `cat a.log \| tr a-z A-Z` | useless-cat | (input) | `tr a-z A-Z < a.log` | exact |
| 8 | fish | `cat a.log \| head -n 2` | useless-cat | (input) | `head -n 2 a.log` | exact |
| 9 | fish | `sort names.txt \| uniq` | sort-unique | (input) | `sort -u names.txt` | exact |
| 10 | bash | `cat names.txt \| sort \| uniq` | sort-unique | (input) | `sort -u names.txt` | exact |
| 11 | fish | `cut -d, -f1 data.csv \| sort \| uniq` | sort-unique | (input) | `cut -d, -f1 data.csv \| sort -u` | exact |
| 12 | bash | `sort -r names.txt \| uniq` | sort-unique | (input) | `sort -r -u names.txt` | exact |
| 13 | fish | `grep 404 a.log \| awk '{print $5}'` | grep-awk | (input) | `awk '/404/ {print $5}' a.log` | exact |
| 14 | bash | `cat a.log \| grep GET \| awk '{print $1}'` | grep-awk | (input) | `awk '/GET/ {print $1}' a.log` | exact |
| 15 | fish | `grep 404 a.log \| awk -F/ '{print $2}'` | grep-awk | (input) | `awk -F/ '/404/ {print $2}' a.log` | exact |
| 16 | fish | `find . -name '*.py'` | find-glob | (input) | `printf '%s\n' **.py` | sortedNoDotSlash |
| 17 | fish | `find src -type f -name "*.py"` | find-glob | (input) | `printf '%s\n' src/**.py` | sortedLines |
| 18 | fish | `find . -name '*.py' \| xargs wc -l` | find-xargs | (input) | `wc -l **.py` | sortedNoDotSlash |
| 19 | bash | `find . -name '*.py' \| xargs wc -l` | find-xargs | (input) | `find . -name '*.py' -exec wc -l {} +` | sortedLines |
| 20 | fish | `ls \| grep log` | ls-grep | (input) | `ls -d *log*` | sortedLines |
| 21 | bash | `ls \| grep '\.txt$'` | ls-grep | (input) | `ls -d *.txt` | sortedLines |
| 22 | fish | `for f in (ls *.log); echo $f; end` | glob-loop | `for f in (ls *.log)` | `for f in *.log` | sortedLines |
| 23 | bash | `for f in $(ls *.txt); do echo "$f"; done` | glob-loop | `for f in $(ls *.txt)` | `for f in *.txt` | sortedLines |
| 24 | fish | `for f in (ls); echo $f; end` | glob-loop | `for f in (ls)` | `for f in *` | sortedLines |
| 25 | fish | `expr 3 + 4` | math | (input) | `math 3 + 4` | exact |
| 26 | fish | `set n 5⏐set n (expr $n + 1); echo $n` | math | `expr $n + 1` | `math $n + 1` | exact |
| 27 | fish | `expr 7 / 2` | math | (input) | `math -s0 7 / 2` | exact |
| 28 | fish | `expr 3 \* 4` | math | (input) | `math '3 * 4'` | exact |
| 29 | fish | `echo '7 / 2' \| bc` | math | (input) | `math -s0 '7 / 2'` | exact |
| 30 | bash | `expr 3 + 4` | math | (input) | `echo $(( 3 + 4 ))` | exact |
| 31 | bash | `n=5⏐n=$(expr $n + 1); echo $n` | math | `$(expr $n + 1)` | `$(( $n + 1 ))` | exact |
| 32 | fish | `set row a,b,c⏐echo $row \| cut -d, -f2` | string-split | (input) | `string split -f2 , $row` | exact |
| 33 | fish | `set row x:y⏐echo $row \| cut -d ':' -f1` | string-split | (input) | `string split -f1 : $row` | exact |
| 34 | fish | `set name foo-foo⏐echo $name \| sed 's/foo/bar/g'` | string-replace | (input) | `string replace -a foo bar $name` | exact |
| 35 | fish | `set name foo-foo⏐echo $name \| sed 's/foo//'` | string-replace | (input) | `string replace foo '' $name` | exact |
| 36 | fish | `set name Ada⏐echo $name \| tr a-z A-Z` | string-case | (input) | `string upper $name` | exact |
| 37 | fish | `set name Ada⏐echo $name \| tr '[:upper:]' '[:lower:]'` | string-case | (input) | `string lower $name` | exact |
| 38 | fish | `ps aux \| grep sleep` | pgrep | (input) | `pgrep -fl sleep` | none |
| 39 | bash | `ps aux \| grep node \| grep -v grep` | pgrep | (input) | `pgrep -fl node` | none |
| 40 | fish | `ps -ef \| grep -v grep \| grep ssh` | pgrep | (input) | `pgrep -fl ssh` | none |

`negative` (shell, input), each with zero rewrites: fish `grep -o x a.log | wc -l`; bash `grep x a.log names.txt | wc -l`; fish `grep x a.log | wc -w`; bash `cat a.log names.txt | grep x`; fish `cat -n a.log | grep x`; fish `cat a.log | while read l; echo $l; end`; bash `sort -n nums.txt | uniq`; fish `sort names.txt | uniq -c`; fish `find . -iname '*.py'`; fish `find . -name '*.py' -mtime -1`; bash `find . -name '*.py'`; fish `find . -name '*.py' | xargs -n1 wc -l`; fish `ls -la | grep x`; bash `ls | grep -v x`; fish `ls | grep 'a.*b'`; fish `for f in (ls -t); echo $f; end`; fish `for f in (ls src); echo $f; end`; fish `echo $name | sed 's/a.b/c/g'`; fish `echo $row | cut -d, -f1,3`; fish `printf 'a,b\n' | cut -d, -f2`; fish `ps aux | grep -i node`; fish `echo 'oops | grep x`; bash `expr length "$s"`; bash `echo '1/3' | bc -l`.

`makeFixtureDir() throws -> URL` (built on `tempDir()`) creates `a.log` with exactly these four lines:
```
10.0.0.1 - - GET /index 200 512
10.0.0.2 - - GET /missing 404 0
10.0.0.3 - - POST /form 404 0
10.0.0.1 - - GET /gone 404 0
```
plus `names.txt` (`bob\nada\nbob\ncy\nada\n`), `data.csv` (`a,1\nb,2\na,3\n`), `top.py`, `src/x.py`, `src/sub/y.py` (one line each), `old.log`, `app.log`, `readme.txt`, `report.txt`, `catalog.md`. No hidden files. `ProcessRunner` returns nil on a non-zero exit, so every positive example must exit 0 on this fixture.

- [ ] **Step 1: Write failing tests:**
  - `@Test(arguments: positive) rewritesExample`: `Coach.rewrites(input, shell:)` has exactly one element with `detectorID == detector`, `rewrite.before == before`, `rewrite.after == after`. Setup is never analysed.
  - `@Test(arguments: negative) noRewriteForUnsafeInput`: `Coach.rewrites(input, shell:).isEmpty`.
  - `@Test(arguments: positive.filter { $0.check != .none }) rewriteIsEquivalentInRealShell`: in a fresh `makeFixtureDir()`, run `setup; input` and `setup; input` with the first `before` replaced by `after`, through `runFish`/`runBash`; both non-nil and equal after normalising per `check` (`trimmed` trims; `sortedLines` sorts trimmed lines; `sortedNoDotSlash` also removes `./` first).
  - `pgrepSuggestionFindsSpawnedProcess`: spawn `/bin/sleep 37` with `Foundation.Process`; `ProcessRunner().run("/usr/bin/pgrep", ["-fl", "sleep 37"])` contains the child's pid; terminate the child in `defer`.
  - `quotedPatternGrepCount`: fish `grep 'a|b' a.log | wc -l` → after `grep -c 'a|b' a.log`.
  - `substitutionAndOuterBothChecked`: fish `cat a.log | grep (expr 400 + 4)` → two rewrites, `useless-cat` and `math`.
  - `analyzeCountsAndOrders` (CoachTests): three dated grep-count fish lines (t=1, 3, 2), one sort-unique (t=5), one line with no hit → ids `["grep-count","sort-unique"]`; grep-count `count == 3`, `lastSeen` = t3, `before` is the t3 line; `item.kind == .suggestion`, `item.detail == after`, `item.packID == "coach"`, `item.tags.contains("fish")`.
  - `analyzeSplitsByShell`: the same grep-count line once as fish and once as bash → two results with the same `item.id` and different `shell`.
  - `analyzeRealFishHistoryFile`: `writeFishHistory` with lines 1, 9, 25 and `echo hi` → `HistoryCache` → ids exactly `{grep-count, sort-unique, math}`.
  - `analyzeIsFastOnFiveThousandEntries`: 5000 entries cycling all positive inputs → < 2 s (debug build).
- [ ] **Step 2:** `swift test --filter "DetectorTests|CoachTests"` → fail.
- [ ] **Step 3:** Implement `Detectors.swift` (one small function per detector plus shared helpers: cat fold, flag/operand split, word re-emit) and `Coach.swift`.
- [ ] **Step 4:** `swift test` → pass. If an equivalence case fails, the rule is wrong, not the test: narrow the rule, move the example to `negative`, and say why in the task report.
- [ ] **Step 5:** Commit: `git add Sources/SanketaCore/Detectors.swift Sources/SanketaCore/Coach.swift Tests/SanketaCoreTests/DetectorExamples.swift Tests/SanketaCoreTests/DetectorTests.swift Tests/SanketaCoreTests/CoachTests.swift && git commit -m "Add better-ways detectors and coach"`

### Task 5: Coach monitor, coaching card in the tip slot, `--dump-coach`

**Files:**
- Create: `Sources/SanketaSystem/CoachMonitor.swift`
- Modify: `Sources/SanketaUI/PanelModel.swift`, `Sources/SanketaUI/SearchModel.swift`, `Sources/SanketaUI/Views/TipCard.swift`, `Sources/Sanketa/AppDelegate.swift`, `Sources/Sanketa/main.swift`
- Test: `Tests/SanketaSystemTests/CoachMonitorTests.swift`, `Tests/SanketaUITests/CoachCardTests.swift`

**Interfaces:**
- Consumes: `CoachConfig`, `HistoryCache`, `Coach.analyze`, `TipStore.pick(from:count:seed:)`, `PanelModel.pickTips()`/`seed`/`tipCards`, `Context.layers`, `LayerKind.shell`, `Layer.host`, `Layer.name` (`"fish"`/`"bash"` for shell layers), `SearchModel.items`
- Produces:
  - `@MainActor public final class CoachMonitor: ObservableObject`
    - `@Published public private(set) var items: [SearchItem]` and `public private(set) var generation: Int`
    - `public init(config: CoachConfig, cache: HistoryCache = HistoryCache(), interval: TimeInterval = 60)`
    - `public func start()`; `public func reload(config: CoachConfig)`; `public func refreshNow() async`
    - `public func recent(shell: Shell, limit: Int) -> [HistoryEntry]` (newest last, from the last read)
    - Reads and analysis run on a serial utility queue. A repeating `Timer` with tolerance 10 s drives refreshes. `items` is assigned only when `cache.generation` changed. With `enabled == false` it never touches the files and `items == []`.
  - `PanelModel.coachItems: [SearchItem]` (public, set by the app; a change re-picks the card only when the current card is a coaching item that is gone).
  - `pickTips()` rule: when `context.layers.first` is `.shell` with `host == nil` and `seed % 2 == 0`, the first card is `store.pick(from: coachItems.filter { $0.tags.contains(<layer name>) }, count: 1, seed: seed)` if that is non-empty; otherwise the current rule.
  - `TipCard` header: `"better way"` when `item.packID == "coach"`, else `"tip · \(packName)"` as now. "I know this" / "Show less" work unchanged through `PanelModel.mark`.
  - `SearchModel.setSource(library:context:extra:)` gains `extra: [SearchItem]? = nil`; `items` appends `extra` (coaching items are searchable).
  - `--dump-coach [--out FILE]` prints `<shell>\t<detectorID>\t<count>` per line and no command text. `--dump-coach --full` also prints before/after, for the user only. Uses the real `[coach]` paths.

- [ ] **Step 1: Write failing tests:**
  - `monitorPublishesFromRealFiles`: `writeFishHistory(["cat a.log | grep 404 | wc -l"])`, `CoachConfig.fishHistory` = that path, `bashHistory` = a missing temp path; `await refreshNow()` → an item with id `coach|suggestion|<grep-count title>` and explain containing `1×`; real fish appends the same line; `refreshNow()` → `2×`.
  - `monitorUnchangedFileKeepsGeneration`: two `refreshNow()` calls, no change → same `generation`.
  - `monitorDisabledPublishesNothing`: `enabled = false`, valid file → `items == []`.
  - `recentReturnsShellSpecific`: fish file with 3 commands, bash file with 2 → `recent(shell: .bash, limit: 5).count == 2`; fish newest last.
  - `coachCardShowsAtLocalShellPrompt` (CoachCardTests, `PanelModel(tips: TipStore(url: temp), seed: 0)`): context layers `[shell fish (packID "fish"), terminal]` with a fish pack, `coachItems` = one fish coaching item → after `update`, `tipCards == [that item]`.
  - `noCoachCardInsideProgramOrRemote`: innermost layer `htop` program, or a shell with `host: "box"` → no coaching item in `tipCards`.
  - `coachCardMatchesShell`: a bash-only coaching item with a fish layer → not shown.
  - `knownCoachingStaysHidden`: `mark(item, .known)`, rotate twice to even seeds → never shown; a new `PanelModel` over the same `TipStore` file → still hidden.
  - `coachItemsAreSearchable`: `SearchModel` with `extra: [coaching item]`, query `"grep -c"` → results contain it.
- [ ] **Step 2:** `swift test --filter "CoachMonitorTests|CoachCardTests"` → fail.
- [ ] **Step 3:** Implement the monitor, the `PanelModel`/`TipCard`/`SearchModel` changes, `--dump-coach` in `main.swift` (add `--dump-coach` to the usage text), and wiring in `AppDelegate`: build `CoachMonitor(config: config.coach)`, sink `items` into `model.coachItems` and `search.setSource(extra:)`, call `coach.reload` from `reloadConfig()`.
- [ ] **Step 4:** `swift test` → pass. Then `make app && make relaunch` and check by hand, recording results in the task report: (a) at a fish prompt the tip slot shows a "better way" card on even seeds (use the menu or wait for rotation); (b) "I know this" hides it and it stays hidden after relaunch; (c) searching "grep -c" finds it; (d) `build/Sanketa.app/Contents/MacOS/Sanketa --dump-coach --out /tmp/coach.txt` writes only shell/id/count lines; (e) Activity Monitor shows idle CPU under 1%.
- [ ] **Step 5:** Commit: `git add Sources/SanketaSystem/CoachMonitor.swift Sources/SanketaUI/PanelModel.swift Sources/SanketaUI/SearchModel.swift Sources/SanketaUI/Views/TipCard.swift Sources/Sanketa/AppDelegate.swift Sources/Sanketa/main.swift Tests/SanketaSystemTests/CoachMonitorTests.swift Tests/SanketaUITests/CoachCardTests.swift && git commit -m "Show coaching from shell history in the tip slot"`

### Task 6: Retrieval, prompt, grounding and routing (no model)

**Files:**
- Create: `Sources/SanketaCore/Retrieval.swift`, `Sources/SanketaCore/SmartSearch.swift`, `Tests/SanketaCoreTests/Support/Choosers.swift`
- Test: `Tests/SanketaCoreTests/RetrievalTests.swift`, `SmartSearchTests.swift`

**Interfaces:**
- Consumes: `SearchItem` (incl. `active`), `Search.rank(_:_:context:limit:)`, `PackLibrary.pack(process:argv:)`, `HistoryEntry`, `ShellLex`, `LLMConfig`
- Produces:
  - `Retrieval.terms(_ query: String) -> [String]`: lowercase, split on non-alphanumerics, drop stopwords `a an the how do does i to in of for with my me what is are can you show find get make on it this that and or way want`, stem by stripping one of `ing ed es s` (keep ≥ 3 characters), then collapse a doubled final consonant.
  - `Retrieval.candidates(_ query: String, _ items: [SearchItem], context: [String], limit: Int = 40) -> [SearchItem]`: per term, stemmed title-word prefix 3, title substring 2, substring of detail/explain/tags/packName 1; +1 if `packID` is in `context`; +1 if `active`; keep score > 0; sort by score desc, then context index.
  - `public struct ChoicePrompt: Equatable, Sendable { enum Task: Equatable, Sendable { case search(String), suggest([String]) }; task; refs: [String]; lines: [String]; maxPicks: Int; var instructions: String; var userText: String; func halved() -> ChoicePrompt }` (`halved` keeps the first `max(1, n/2)` refs and lines).
  - `ChoicePrompt.build(task:candidates:maxPicks:charBudget: Int = 6000) -> (prompt: ChoicePrompt, refs: [String: SearchItem])`: refs `e1…eN`; line `"\(ref) | \(packName) | \(title) | \(detail)"` cut to 160; stop adding once the running total would pass `charBudget`; `suggest` keeps the last 10 commands, each cut to 120.
  - Exact copy (the bench prompt, which every backend was measured with):
    - `instructions`: `"You match a request to entries from a list of keyboard shortcuts and command tips. Answer only with refs from the list, best first, at most \(maxPicks). Return an empty list if nothing fits."`
    - `userText` for search: `"Request: \(q)\nEntries:\n" + lines.joined(separator: "\n") + "\nAnswer with JSON only: {\"picks\": [...]}, where picks is a list of ref strings from the Entries list."`
    - `userText` for suggest: `"Recent commands:\n" + cmds.joined("\n") + "\nPick entries that would help with what these commands do.\nEntries:\n" + lines… + <same JSON line>`
  - `Grounding.resolve(_ picks: [String], _ refs: [String: SearchItem], order: [String], max: Int) -> [SearchItem]`: drops unknown refs, dedupes, keeps order, caps at `max`; returns `[]` when `picks.count >= 2` and `picks == Array(order.prefix(picks.count))` (positional collapse).
  - `public enum ModelStatus: Equatable, Sendable { case available, unavailable(String), off }`
  - `public enum ChoiceError: Error, Equatable { case contextExceeded, notAllowed, http(Int), badResponse, noKey }`
  - `public protocol Choosing: Sendable { var name: String { get }; var isRemote: Bool { get }; func status() -> ModelStatus; func choose(_ prompt: ChoicePrompt) async throws -> [String]; func prewarm() }` with a default empty `prewarm()`.
  - `public protocol OnDeviceChooser: Choosing {}` with `isRemote` defaulting to `false`. This is the slot for the downloaded-model primary (`MLXChooser`, Task 12).
  - `public struct ModelRouter: Sendable`
    - `init(config: LLMConfig, onDevice: (any OnDeviceChooser)?, appleFM: (any Choosing)?, remote: (any Choosing)?)`
    - `func searchChooser() -> (any Choosing)?`: the first that is enabled in config and `.available`, in order `onDevice` (`config.onDevice`), `appleFM` (`config.appleFM`), `remote` (`config.openai`); else nil.
    - `func suggestChooser() -> (any Choosing)?`: same order without `remote`, and only when `config.suggest`.
    - `func searchNote() -> String?`: nil when `searchChooser()` is non-nil; else `"Plain search: " + reasons.joined("; ")`, one reason per enabled tier that is unavailable, in order (e.g. `"Plain search: on-device model not downloaded; Apple Intelligence is off"`). With every tier off: `"Plain search: no model turned on"`.
    - `func prewarm()`: calls `prewarm()` on `searchChooser()` only.
  - `public struct SmartResult: Equatable, Sendable { items: [SearchItem]; picked: Set<String>; note: String? }`
  - `public struct SmartSearch: Sendable { init(router: ModelRouter, timeout: TimeInterval); func results(_ query: String, _ items: [SearchItem], context: [String]) async -> SmartResult }`
    - `local` = `Search.rank` if non-empty, else `Retrieval.candidates`.
    - Fewer than 3 whitespace words → `local`, no note, no model call. No chooser → `local` and `router.searchNote()`.
    - Else: candidates from `Retrieval.candidates` (for a remote chooser, first drop items whose `packID` has the prefix `app:`); `choose`, racing the timeout; on `.contextExceeded` retry once with `halved()`; picks first, then `local` minus picks; `note` nil. On error or timeout → `local` and `"Plain search: \(chooser.name) \(reason)"` with reason `"timed out"`, `"refused the request"` (`.notAllowed`), `"no key"`, `"HTTP \(n)"` or `"failed"`.
  - `public enum SmartSuggest`
    - `static func candidates(recent: [HistoryEntry], library: PackLibrary, items: [SearchItem], excluding: Set<String>, limit: Int = 30) -> [SearchItem]`: first word of each stage of the last 10 commands (skip `sudo env command`), mapped with `library.pack(process:argv:)`; `.tip`/`.key` items of those packs, most recent pack first, minus `excluding`.
    - `static func pick(recent:library:items:excluding:router:timeout:) async -> [SearchItem]`: up to 2 picks via `router.suggestChooser()`; `[]` on any failure. A remote chooser is never reachable here.
  - Test fakes in `Support/Choosers.swift`: `FixedChooser(picks:status:isRemote:)`, `ThrowingChooser(error:)`, `SlowChooser(seconds:)`, `RecordingChooser` (records prompts; actor-backed), `FakeOnDevice` (an `OnDeviceChooser` wrapping a `FixedChooser`).

- [ ] **Step 1: Write failing tests.** Bundled packs come from `repoRoot/Resources/Packs` through `PackLibrary.load(bundled:user: nil)`.
  - `termsDropStopwordsAndStem`: `"how do I count matching lines"` → `["count","match","line"]`
  - `retrievalFindsSplitForNaturalQuery`: bundled packs, `"how do I split the window side by side"`, context `["tmux"]` → the top 10 hold a tmux item whose title contains "split" (case-insensitive)
  - `promptRespectsBudget`: 500 synthetic candidates → `lines.joined().count <= 6000`, `refs.count == lines.count`, map keys == `Set(refs)`, each line ≤ 160
  - `promptCopyIsExact`: one item (`tmux`, "Split pane left/right", `prefix %`), `.search("split pane")` → `userText == "Request: split pane\nEntries:\ne1 | tmux | Split pane left/right | prefix %\nAnswer with JSON only: {\"picks\": [...]}, where picks is a list of ref strings from the Entries list."`
  - `groundingDropsInventedRefs`: picks `["e3","e99","bogus","e3","e1"]` → `[item3, item1]`
  - `groundingRejectsPositionalCollapse`: order `e1…e10`, picks `["e1","e2","e3"]` → `[]`; picks `["e1"]` → `[item1]`; picks `["e1","e3"]` → two items
  - `smartSearchPutsPicksFirst`: `FixedChooser(["e2"])` → `items[0]` is candidate e2, `picked == [its id]`, no duplicates
  - `shortQueryDoesNotCallModel`: `RecordingChooser`, `"split"` → zero prompts
  - `smartSearchFallsBackOnError`: `ThrowingChooser` → items == local, `note?.hasPrefix("Plain search:") == true`
  - `smartSearchTimesOut`: `SlowChooser(5)`, timeout 0.3 → returns in < 1.5 s with local items and a note containing `"timed out"`
  - `contextExceededRetriesHalved`: throws `.contextExceeded` first, then `["e1"]` → second prompt `refs.count == first/2`; pick applied
  - `remoteChooserNeverSeesMenuItems`: remote `RecordingChooser`, items include `packID "app:com.apple.Terminal"` → no recorded line contains that pack's name; a local `RecordingChooser` does see it
  - `routerOrder`, one case each: on-device available → on-device; on-device unavailable, FM available → FM; both unavailable, openai on and available → remote; openai off → nil and note lists both reasons in order; `onDevice = false` in config skips an available on-device chooser; `suggestChooser()` is nil when only remote is available
  - `suggestCandidatesFromRecentCommands`: bundled library, bash recent `["git status","git log --oneline | head -n 5"]` → non-empty, `[0].packID == "git"`, every `packID` is one `library.pack(process:argv:)` gives for `git` or `head`, ids in `excluding` absent
- [ ] **Step 2:** `swift test --filter "RetrievalTests|SmartSearchTests"` → fail.
- [ ] **Step 3:** Implement. Race the timeout with `withThrowingTaskGroup` over `choose` and `Task.sleep`, cancelling the loser.
- [ ] **Step 4:** `swift test` → pass.
- [ ] **Step 5:** Commit: `git add Sources/SanketaCore/Retrieval.swift Sources/SanketaCore/SmartSearch.swift Tests/SanketaCoreTests/Support/Choosers.swift Tests/SanketaCoreTests/RetrievalTests.swift Tests/SanketaCoreTests/SmartSearchTests.swift && git commit -m "Add grounded retrieval and model routing"`

### Task 7: Apple Foundation Models chooser

**Files:**
- Modify: `Package.swift`: `.target(name: "SanketaAI", dependencies: ["SanketaCore"], swiftSettings: v5)`, `.testTarget(name: "SanketaAITests", dependencies: ["SanketaAI", "SanketaCore"], swiftSettings: v5)`, and `"SanketaAI"` in the `Sanketa` executable's dependencies
- Create: `Sources/SanketaAI/AppleFMChooser.swift`
- Test: `Tests/SanketaAITests/AppleFMChooserTests.swift`

**Interfaces:**
- Consumes: `Choosing`, `ChoicePrompt`, `ChoiceError`, `ModelStatus`, `ModelRouter`, `SmartSearch`
- Produces: `public struct AppleFMChooser: Choosing { public init(model: SystemLanguageModel = .default) }`
  - `name "Apple Intelligence"`, `isRemote false`. Never `SystemLanguageModel(useCase: .contentTagging)`.
  - `status()`: `.available` → `.available`; `.deviceNotEligible` → `"this Mac can't run Apple Intelligence"`; `.appleIntelligenceNotEnabled` → `"Apple Intelligence is off"`; `.modelNotReady` → `"Apple Intelligence model not ready"`; `@unknown default` → `"Apple Intelligence unavailable"`.
  - `static func schema(refs: [String], maxPicks: Int) throws -> GenerationSchema`: root `DynamicGenerationSchema(name: "Choice", properties: [.init(name: "picks", schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(name: "Ref", anyOf: refs), minimumElements: 0, maximumElements: maxPicks))])`.
  - `choose`: empty `refs` → `[]` without a call. Else a fresh `LanguageModelSession(model:, instructions: prompt.instructions)`, `respond(to: prompt.userText, schema:, includeSchemaInPrompt: false, options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 64))`, read `[String]` from property `picks`. `GenerationError.exceededContextWindowSize` → `ChoiceError.contextExceeded`; other errors rethrown.
  - `prewarm()`: `LanguageModelSession(model:, instructions: <the fixed instructions with maxPicks 5>).prewarm(promptPrefix: Prompt("Request: "))`, only when available.

- [ ] **Step 1: Write failing tests:**
  - `schemaAcceptsRefs`: `schema(refs: ["e1","e2","e3"], maxPicks: 3)` doesn't throw; its `JSONEncoder` output contains `maxItems` with 3 and each ref.
  - `@Test(.disabled(if: SystemLanguageModel.default.isAvailable)) unavailableFMDegrades`: real chooser, `ModelRouter(config: LLMConfig(), onDevice: nil, appleFM: it, remote: nil)`, `SmartSearch.results("how do I split the window side by side", bundled items, context: ["tmux"])` → non-empty items, `picked.isEmpty`, note has prefix `"Plain search:"`.
  - `@Test(.enabled(if: SystemLanguageModel.default.isAvailable), .timeLimit(.minutes(1))) liveSearchPicksSplit`: same query → `!picked.isEmpty` (catches the empty-list failure of `includeSchemaInPrompt: true`); every pick is in `Retrieval.candidates` for the query; one of the first 3 items is a tmux item whose title contains "split".
  - `@Test(.enabled(if: …)) liveNoMatchStaysGrounded`: `"bake sourdough bread at home tonight"` → every pick is a candidate, ≤ 5.
  - `@Test(.enabled(if: …)) liveSuggestPicksFromRecentPacks`: recent `["git log --oneline | head -n 20","git status"]` → `SmartSuggest.pick` gives ≤ 2 items, all from candidate packs.
- [ ] **Step 2:** `swift test --filter AppleFMChooserTests` → fail (no target).
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `swift test` → pass. Record which gated tests ran. Apple Intelligence was on during the bench, so the live tests are expected to run here.
- [ ] **Step 5:** Commit: `git add Package.swift Sources/SanketaAI/AppleFMChooser.swift Tests/SanketaAITests/AppleFMChooserTests.swift && git commit -m "Add Apple Foundation Models chooser"`

### Task 8: OpenAI-compatible chooser and the model list

**Files:**
- Create: `Sources/SanketaCore/OpenAIModels.swift`, `Sources/SanketaAI/OpenAIChooser.swift`, `Tests/SanketaAITests/Support/StubProtocol.swift`
- Test: `Tests/SanketaCoreTests/OpenAIModelsTests.swift`, `Tests/SanketaAITests/OpenAIChooserTests.swift`

**Interfaces:**
- Consumes: `Choosing`, `ChoicePrompt`, `ChoiceError`, `LLMConfig`
- Produces:
  - `OpenAIModels.isOpenAI(_ baseURL: URL) -> Bool` (host `api.openai.com`), `OpenAIModels.isLocal(_ baseURL: URL) -> Bool` (host `localhost`, `127.0.0.1` or `::1`).
  - `OpenAIModels.chatCapable(_ ids: [String], openAI: Bool) -> [String]`, sorted. When `openAI` is false, all ids are kept (another server's ids can't be classified). When true, keep ids that match `^(gpt-|chatgpt-|o[0-9])` and contain none of `audio realtime transcribe tts image search embedding moderation instruct codex deep-research computer-use dall-e whisper`, and drop dated snapshots (`-\d{4}-\d{2}-\d{2}$`).
  - `OpenAIModels.preference = ["gpt-5-nano", "gpt-4.1-nano", "gpt-4o-mini", "gpt-5-mini", "gpt-4.1-mini"]` (cheapest first, by input price on 2026-10-24).
  - `OpenAIModels.cheapest(_ chatCapable: [String]) -> String?`: the first `preference` id that is present; else the lexically smallest id that contains `nano`; else the lexically smallest that contains `mini`; else the lexically smallest id; nil when empty.
  - `OpenAIModels.isReasoning(_ id: String) -> Bool`: matches `^(o[0-9]|gpt-5)`.
  - `OpenAIRequest.body(model: String, prompt: ChoicePrompt, openAI: Bool, schema: Bool = true) -> Data`, JSON keys exactly:
    - always `model`, `messages` (`[{role:"system",content:instructions},{role:"user",content:userText}]`)
    - with `schema`: `response_format` = `{type:"json_schema",json_schema:{name:"choice",strict:true,schema:{type:"object",properties:{picks:{type:"array",items:{type:"string",enum:refs},maxItems:maxPicks}},required:["picks"],additionalProperties:false}}}`
    - `openAI`: `store: false`; `max_completion_tokens: 100`, or `1000` plus `reasoning_effort: "low"` when `isReasoning(model)`
    - not `openAI`: `max_tokens: 100`
  - `OpenAIRequest.parse(_ data: Data) throws -> [String]`: `choices[0].message.content` parsed as `{"picks":[…]}`; otherwise `ChoiceError.badResponse`.
  - `public struct OpenAIChooser: Choosing`
    - `init(baseURL: URL, model: @escaping @Sendable () async -> String?, key: @escaping @Sendable () async -> String?, session: URLSession = .shared, timeout: TimeInterval)`. `model` and `key` are resolved lazily on the first call (Task 9 and Task 13 supply them).
    - `name "OpenAI"` when `isOpenAI(baseURL)`, else the host; `isRemote true`.
    - `status()`: `.available` (key and model problems show as errors from `choose`, so `status()` never blocks).
    - `choose`: `.suggest` → throws `.notAllowed` before any request. No key and not `isLocal` → `.noKey`. No model → `.badResponse`. POST `<baseURL>/chat/completions` with `Authorization: Bearer <key>` (left out when there is no key), `Content-Type: application/json`, `timeoutInterval = timeout`. Non-2xx → `.http(status)`, except a `400` from a non-OpenAI server, which is retried once with `schema: false` (Grounding still checks the picks).
  - `public enum ModelList { static func fetch(baseURL: URL, key: String?, session: URLSession = .shared, timeout: TimeInterval = 8) async throws -> [String] }`: `GET <baseURL>/models`, parse `data[].id`, then `OpenAIModels.chatCapable(_, openAI: isOpenAI(baseURL))`.
  - `StubProtocol: URLProtocol` test helper: captures each request (body read from `httpBodyStream`), answers with a canned status and body per path; installed on an ephemeral `URLSessionConfiguration`.

- [ ] **Step 1: Write failing tests:**
  - `chatCapableFiltersOpenAIList` (OpenAIModelsTests): input `["gpt-5-nano","gpt-5-nano-2025-08-07","gpt-4o-mini-tts","gpt-4o-audio-preview","text-embedding-3-small","o4-mini","dall-e-3","gpt-4.1-mini","whisper-1","omni-moderation-latest"]`, `openAI: true` → `["gpt-4.1-mini","gpt-5-nano","o4-mini"]`; `openAI: false` → all ten, sorted
  - `cheapestFollowsPreference`: `["gpt-4.1-mini","gpt-5-mini","gpt-4o-mini"]` → `"gpt-4o-mini"`; `["gpt-9-nano","gpt-8-nano","gpt-9-mini"]` → `"gpt-8-nano"`; `["zeta-mini","alpha-mini"]` → `"alpha-mini"`; `["llama3.2","qwen3:4b"]` → `"llama3.2"`; `[]` → nil
  - `bodyIsExactlyWhatLeaves`: a search prompt from 3 items → for `openAI: true` and model `gpt-4o-mini` the top-level keys are exactly `{model, messages, response_format, store, max_completion_tokens}`, `store == false`, `messages[1].content == prompt.userText`, the enum equals the refs; for `gpt-5-nano` the keys add `reasoning_effort == "low"` and `max_completion_tokens == 1000`; for `openAI: false` the keys are exactly `{model, messages, response_format, max_tokens}`. A `SmartSearch` run with a remote `RecordingChooser` over items plus history entries passed to the same test: no prompt line contains any history command.
  - `parseReadsPicks`: `{"choices":[{"message":{"role":"assistant","content":"{\"picks\":[\"e2\",\"e5\"]}"}}]}` → `["e2","e5"]`
  - `parseRejectsGarbage`: `{"choices":[]}` and `oops` → `.badResponse`
  - `chooserSendsRequestAndParses`: stub 200 → URL `https://api.openai.com/v1/chat/completions`, method `POST`, `Authorization == "Bearer sk-test"`, picks parsed
  - `localServerNeedsNoKey`: base `http://localhost:11434/v1`, key nil → request sent with no `Authorization` header
  - `noKeyThrowsForOpenAI`: key nil, OpenAI base → `.noKey`, stub saw no request
  - `http401FallsBackWithNote`: stub 401 → `choose` throws `.http(401)`; through `SmartSearch` with no on-device tier and openai on → local items, note contains `"OpenAI"` and `"401"`
  - `custom400RetriesWithoutSchema`: base `http://localhost:1234/v1`, stub answers 400 then 200 → two requests, the second body has no `response_format`, picks parsed
  - `suggestIsRefused`: `.suggest` prompt → `.notAllowed`, stub saw no request
  - `modelListFetchesAndFilters`: stub `GET /v1/models` → `{"data":[{"id":"gpt-5-nano"},{"id":"whisper-1"}]}` → `["gpt-5-nano"]`, request carried the bearer key
  - `@Test(.enabled(if: ProcessInfo.processInfo.environment["SANKETA_LIVE_OPENAI"] == "1")) liveOpenAIPicksOnlyCandidates`: real `ModelList.fetch`, `cheapest`, then the Task 7 query → picks ⊆ refs. Never run unless the user sets the flag.
- [ ] **Step 2:** `swift test --filter "OpenAIModelsTests|OpenAIChooserTests"` → fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `swift test` → pass. Do not run the live test.
- [ ] **Step 5:** Commit: `git add Sources/SanketaCore/OpenAIModels.swift Sources/SanketaAI/OpenAIChooser.swift Tests/SanketaAITests/Support/StubProtocol.swift Tests/SanketaCoreTests/OpenAIModelsTests.swift Tests/SanketaAITests/OpenAIChooserTests.swift && git commit -m "Add OpenAI-compatible chooser and model list"`

### Task 9: API key lookup, Keychain store and key box

**Files:**
- Create: `Sources/SanketaAI/KeyStore.swift`, `Sources/SanketaAI/APIKey.swift`, `Sources/SanketaUI/KeyBox.swift`
- Test: `Tests/SanketaAITests/APIKeyTests.swift`

**Interfaces:**
- Consumes: `CommandRunning`, `ProcessRunner`, `LLMConfig.apiKeyEnv`, `LLMConfig.baseURL`
- Produces:
  - `public protocol KeyStore: Sendable { func read(account: String) -> String?; func write(_ key: String, account: String) throws; func delete(account: String) throws }`
  - `public struct KeychainStore: KeyStore { public init(service: String = "dev.sanketa.Sanketa") }`: `kSecClassGenericPassword` with `kSecAttrService`/`kSecAttrAccount`, through `SecItemCopyMatching`, `SecItemAdd`, `SecItemUpdate` (on `errSecDuplicateItem`) and `SecItemDelete`. File-based login keychain (no `kSecUseDataProtectionKeychain`, which needs an entitlement). Errors carry the `OSStatus` only, never the key.
  - `public final class MemoryKeyStore: KeyStore, @unchecked Sendable` (lock-guarded dictionary; for tests).
  - `public enum APIKey`
    - `static func account(for baseURL: URL) -> String` (the host, e.g. `api.openai.com`)
    - `static func loginShell(env: [String: String], passwdShell: String?) -> String?`: `env["SHELL"]`, else `passwdShell`; only an absolute path to an existing executable file.
    - `static func resolve(varName: String, env: [String: String], shell: String?, runner: CommandRunning, store: KeyStore, account: String) -> String?`: a trimmed non-empty `env[varName]`; else, when `shell` is set, `runner.run(shell, ["-l", "-c", "printf %s \"$\(varName)\""], timeout: 3)` trimmed and non-empty; else `store.read(account:)`; else nil. `varName` must match `^[A-Z_][A-Z0-9_]*$`, otherwise nil without running anything.
    - `static func clean(_ typed: String) -> String?`: trimmed; nil when empty or when it has whitespace or control characters inside.
  - `@MainActor public enum KeyBox { static func ask(host: String) -> String? }` in `SanketaUI`: an `NSAlert` with an `NSSecureTextField` accessory ("Paste your API key for <host>. Sanketa keeps it in your Keychain."), Save / Cancel. Opened only from the status-menu item "OpenAI Key…" (Task 13). It activates the app for the box and hands focus back to the previous app afterwards.

- [ ] **Step 1: Write failing tests** (all with `MemoryKeyStore` and temp scripts; none read the real environment or Keychain):
  - `keyFromEnvWins`: env `["OPENAI_API_KEY": " sk-env \n"]`, shell = a nonexistent path, store holding `sk-store` → `"sk-env"`
  - `keyFromLoginShell`: a temp executable `#!/bin/sh\nprintf 'sk-from-shell'\n` (mode 755) as shell, empty env → `"sk-from-shell"`
  - `loginShellGetsTheVariableName`: a temp script that prints its last argument; `varName "OPENROUTER_API_KEY"` → result equals `printf %s "$OPENROUTER_API_KEY"`
  - `keyFromStoreWhenShellHasNone`: a script printing nothing, store holding `sk-store` for `api.openai.com` → `"sk-store"`
  - `keyMissingIsNil`: empty script, empty store → nil
  - `badVarNameRunsNothing`: `varName "X; rm -rf /"` with a script that writes a marker file → nil and no marker file
  - `slowShellTimesOut`: a script that runs `/bin/sleep 10` → nil within 4.5 s
  - `loginShellNeedsExecutable`: `SHELL=/nope` and passwd nil → nil; `SHELL` relative → nil
  - `cleanRejectsBadInput`: `"  sk-1  "` → `"sk-1"`; `""`, `"sk 1"`, `"sk\n1"` → nil
  - `memoryStoreRoundTrip`: write, read, overwrite, delete → expected values
  - `@Test(.enabled(if: ProcessInfo.processInfo.environment["SANKETA_LIVE_KEYCHAIN"] == "1")) keychainRoundTrip`: `KeychainStore(service: "dev.sanketa.test.<uuid>")` write/read/overwrite/delete; delete in `defer`. Only the user runs it.
- [ ] **Step 2:** `swift test --filter APIKeyTests` → fail.
- [ ] **Step 3:** Implement. `KeyBox` has no unit test; it is checked by hand in Task 13.
- [ ] **Step 4:** `swift test` → pass.
- [ ] **Step 5:** Commit: `git add Sources/SanketaAI/KeyStore.swift Sources/SanketaAI/APIKey.swift Sources/SanketaUI/KeyBox.swift Tests/SanketaAITests/APIKeyTests.swift && git commit -m "Add API key lookup and Keychain store"`

### Task 10: MLX build plumbing

Prerequisite: the Metal toolchain (addendum open question 1). Ask the user before running `xcodebuild -downloadComponent MetalToolchain`. **Stop rule:** if the xcodebuild product has no `.metallib` after Step 3, stop and report what was tried; do not try other build systems in this task.

**Files:**
- Modify: `Package.swift`, `Makefile`, `.github/workflows/build.yml`
- Create: `Sources/SanketaMLX/MLXRuntime.swift`
- Test: `Tests/SanketaMLXTests/MLXRuntimeTests.swift`

**Interfaces:**
- Produces:
  - `Package.swift` dependencies add `.package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3")` and `.package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.5")`. New `.target(name: "SanketaMLX", dependencies: ["SanketaCore", .product(name: "MLXLLM", package: "mlx-swift-lm"), .product(name: "MLXLMCommon", package: "mlx-swift-lm"), .product(name: "MLXGuidedGeneration", package: "mlx-swift-lm"), .product(name: "Tokenizers", package: "swift-transformers")], swiftSettings: v5)`, `"SanketaMLX"` in the `Sanketa` executable, `.testTarget(name: "SanketaMLXTests", dependencies: ["SanketaMLX", "SanketaCore"], swiftSettings: v5)`. Do not depend on `MLXFoundationModels` or `MLXHuggingFace`.
  - `public enum MLXRuntime { static func metallibURL(bundle: Bundle = .main, executable: URL? = Bundle.main.executableURL) -> URL?; static var isReady: Bool }`: finds a `.metallib` next to the executable, in `Contents/Resources`, or inside a `*Cmlx*.bundle` there. `isReady` is true when one is found on Apple Silicon. Code paths that touch the GPU check `isReady` first, so `swift run` builds degrade to "on-device model needs the app build" instead of crashing.
  - `Makefile`:
    - `bundle` builds the release binary with `xcodebuild -scheme Sanketa -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath build/xcode -skipPackagePluginValidation build`, copies `build/xcode/Build/Products/Release/Sanketa` and every `*.bundle` from that folder (the MLX resource bundle with the metallib) into the app, and keeps the existing Packs/Brand/Info.plist steps and the move-aside rule.
    - `test` stays `swift test`. New `test-mlx`: `xcodebuild test -scheme Sanketa-Package -destination 'platform=macOS,arch=arm64' -derivedDataPath build/xcode -only-testing:SanketaMLXTests`.
    - `verify` also checks that the bundle holds a `.metallib`.
  - CI `build.yml`: after `brew install`, a step `xcodebuild -downloadComponent MetalToolchain`. `swift build` and `swift test` stay. `make app SIGN_ID=-` now goes through xcodebuild.

- [ ] **Step 1: Write the failing test** `metallibFoundInBundleLayout`: in `tempDir`, make `Fake.app/Contents/MacOS/Sanketa` and `Fake.app/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib` (empty files) → `metallibURL(bundle: Bundle(url: Fake.app)!, executable: …/Sanketa)` is that file; with the metallib moved away → nil.
- [ ] **Step 2:** `swift test --filter MLXRuntimeTests` → fail. Then `swift build` with the new dependencies → it compiles (MLX C++ builds under SwiftPM; only the shaders are missing).
- [ ] **Step 3:** Implement the `Makefile` and CI changes. Run `make bundle` → `find build/Sanketa.app -name '*.metallib'` lists one file. If it lists none, apply the stop rule.
- [ ] **Step 4:** `swift test` → pass; `make app && make verify` → `bundle ok` and the metallib check passes.
- [ ] **Step 5:** Commit: `git add Package.swift Package.resolved Makefile .github/workflows/build.yml Sources/SanketaMLX/MLXRuntime.swift Tests/SanketaMLXTests/MLXRuntimeTests.swift && git commit -m "Build with xcodebuild for MLX Metal shaders"`

### Task 11: Model catalog and installer

**Files:**
- Create: `Sources/SanketaCore/ModelCatalog.swift`, `Sources/SanketaAI/ModelInstaller.swift`
- Test: `Tests/SanketaAITests/ModelInstallerTests.swift`

**Interfaces:**
- Consumes: `MLXModelChoice`, `StubProtocol`
- Produces:
  - `public struct ModelFile: Sendable, Equatable { name: String; size: Int64; sha256: String }`
  - `public struct ModelSpec: Sendable, Equatable { choice: MLXModelChoice; repo: String; revision: String; folder: String; files: [ModelFile]; var downloadSize: Int64; func url(_ f: ModelFile) -> URL }` (`https://huggingface.co/<repo>/resolve/<revision>/<name>`)
  - `ModelCatalog.spec(_ c: MLXModelChoice) -> ModelSpec` with these pinned values (checked on 2026-10-24 with the HF API and `shasum -a 256`):

    `qwen3.5-4b`: repo `mlx-community/Qwen3.5-4B-MLX-4bit`, revision `32f3e8ecf65426fc3306969496342d504bfa13f3`, folder `Qwen3.5-4B-MLX-4bit`

    | file | size | sha256 |
    |---|---|---|
    | config.json | 3366 | f3efc81b2ea8d96a45301037d3ccccbcccdef44a961845c87f286aaddbc6eaaa |
    | model.safetensors | 3034300695 | 5fb9acd0246866381cf8c5c354c6db1019f6498eec4ccb4f5edcc71ffeacb2db |
    | model.safetensors.index.json | 101944 | 52e534c41f7b97708329c85f762e5882bf48bd5955a422c6ae74eba321e6048a |
    | tokenizer.json | 19989343 | 87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4 |
    | tokenizer_config.json | 1139 | e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182 |
    | chat_template.jinja | 7756 | a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715 |

    `qwen3.5-2b`: repo `mlx-community/Qwen3.5-2B-MLX-4bit`, revision `93760be4f1f69842a46bc13dbdc0f19e291392a3`, folder `Qwen3.5-2B-MLX-4bit`

    | file | size | sha256 |
    |---|---|---|
    | config.json | 3113 | beb7fc5a6e0405fe332821cf1a8ef7b69bb390a8c8933171647de5579debf949 |
    | model.safetensors | 1722271785 | 713fe7e5d3c3965f7106b0d0ee17615f7869c23c8d327996df8c1196fbcf07d5 |
    | model.safetensors.index.json | 81722 | 8294c05cca7d53a6c33e3db2b379539bd296d054e0b689711b16b6ac93c7e49d |
    | tokenizer.json | 19989343 | 87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4 |
    | tokenizer_config.json | 1139 | e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182 |
    | chat_template.jinja | 7755 | 273d8e0e683b885071fb17e08d71e5f2a5ddfb5309756181681de4f5a1822d80 |
  - `ModelCatalog.defaultRoot: URL` = `~/Library/Application Support/Sanketa/Models`, or `SANKETA_MODEL_DIR` when set.
  - `public final class ModelInstaller: @unchecked Sendable`
    - `init(root: URL, session: URLSession = .shared)`
    - `func directory(_ spec: ModelSpec) -> URL` (`root/folder`)
    - `func isInstalled(_ spec: ModelSpec) -> Bool`: every file exists with the right size and `root/folder/.verified` holds `spec.revision`. It never hashes 3 GB at launch; hashes are checked once, at install.
    - `func install(_ spec: ModelSpec, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws`: downloads each file into `root/<folder>.partial/` with `URLSession.download`, checks size and SHA-256 (CryptoKit `SHA256`, streamed in 4 MB chunks), writes `.verified`, then renames `.partial` to the final folder (moving an old final folder aside first). A failure removes `.partial` and throws `InstallError.badSize(name)`, `.badHash(name)` or `.http(name, status)`. Only one install runs at a time (`InstallError.busy`).
    - `func remove(_ spec: ModelSpec) throws`.
  - These are the only requests to `huggingface.co`. They carry no key and no user data.

- [ ] **Step 1: Write failing tests** (a test `ModelSpec` with two small files whose real sizes and hashes the test computes, served by `StubProtocol`; root in `tempDir`):
  - `installVerifiesAndMarks`: install → `isInstalled == true`, files equal the served bytes, `.verified` holds the revision, no `.partial` folder left, progress reached the total
  - `badHashLeavesNothingInstalled`: serve different bytes for one file → throws `.badHash`, `isInstalled == false`, no final or `.partial` folder
  - `interruptedDownloadIsNotInstalled`: second file answers 500 → throws `.http`, `isInstalled == false`; a later install with good answers succeeds
  - `wrongSizeIsNotInstalled`: after install, truncate one file → `isInstalled == false`
  - `catalogPinsMatchHFLayout`: for both real specs, every URL is `https://huggingface.co/<repo>/resolve/<40-hex revision>/<name>`, every sha256 is 64 hex characters, the file names are exactly the six above, and `downloadSize` is about 3.06 GB / 1.75 GB (± 1%)
  - `removeDeletesFolder`: install then `remove` → `isInstalled == false`
- [ ] **Step 2:** `swift test --filter ModelInstallerTests` → fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `swift test` → pass.
- [ ] **Step 5:** Commit: `git add Sources/SanketaCore/ModelCatalog.swift Sources/SanketaAI/ModelInstaller.swift Tests/SanketaAITests/ModelInstallerTests.swift && git commit -m "Add pinned model catalog and installer"`

### Task 12: MLX chooser with idle unload

**Files:**
- Create: `Sources/SanketaMLX/IdleHolder.swift`, `Sources/SanketaMLX/MLXChooser.swift`
- Test: `Tests/SanketaMLXTests/IdleHolderTests.swift`, `Tests/SanketaMLXTests/MLXChooserTests.swift`

**Interfaces:**
- Consumes: `OnDeviceChooser`, `ChoicePrompt`, `ChoiceError`, `ModelStatus`, `ModelSpec`, `ModelInstaller.isInstalled/directory`, `MLXRuntime.isReady`, `Grounding` (through `SmartSearch`)
- Produces:
  - `public actor IdleHolder<Value: Sendable> { init(idle: TimeInterval, load: @escaping @Sendable () async throws -> Value, unload: @escaping @Sendable (Value) -> Void = { _ in }); func use<R: Sendable>(_ body: @Sendable (Value) async throws -> R) async throws -> R; var isLoaded: Bool { get } }`: loads on first use; each use restarts a timer; after `idle` seconds without use the value is dropped and `unload` runs; concurrent first uses share one load.
  - `public struct MLXChooser: OnDeviceChooser { public init(spec: ModelSpec, installer: ModelInstaller, idle: TimeInterval = 60) }`
    - `name "on-device (Qwen3.5-4B)"` or `"(Qwen3.5-2B)"` from the spec.
    - `status()`: not installed → `.unavailable("on-device model not downloaded")`; `!MLXRuntime.isReady` → `.unavailable("on-device model needs the app build")`; else `.available`.
    - Load: `loadModelContainer(from: installer.directory(spec), using: LocalTokenizerLoader())`, where `LocalTokenizerLoader: TokenizerLoader` wraps `Tokenizers.AutoTokenizer.from(modelFolder:)`.
    - `choose`: empty refs → `[]`. Chat `[.system(instructions), .user(userText)]` with `additionalContext: ["enable_thinking": false]`; JSON schema `{"type":"object","properties":{"picks":{"type":"array","items":{"enum":refs},"maxItems":maxPicks}},"required":["picks"],"additionalProperties":false}`; `GrammarConstraint(tokenizer: GrammarTokenizer(vocab:vocabType:eosTokenId:) from TokenizerVocabExtractor.extractForGrammar, jsonSchema:)`; `GuidedGenerationLoop.run(…, maxTokens: 64, whitespaceBias/whitespaceTokenIDs from WhitespaceTokenBias.compute, …)` on a detached task, never on the main actor; decode `{"picks": […]}`. Guided-generation errors → `ChoiceError.badResponse`; a prompt longer than the model's limit → `.contextExceeded`.
    - Unload: drop the container and call `MLX.GPU.clearCache()`.
    - `prewarm()`: starts the load in the background when available.

- [ ] **Step 1: Write failing tests:**
  - `holderLoadsOnceAndUnloadsWhenIdle` (IdleHolderTests, fake `load` counting calls, `idle: 0.3`): two concurrent `use` calls → one load; `isLoaded`; after 0.6 s `!isLoaded` and `unload` ran once; next `use` loads again
  - `holderUseKeepsItLoaded`: uses every 0.2 s for 1 s with `idle: 0.3` → one load
  - `notInstalledIsUnavailable` (MLXChooserTests): installer on an empty temp root → `status() == .unavailable("on-device model not downloaded")`, and `ModelRouter` with it plus an available `FixedChooser` as `appleFM` picks the FM chooser
  - `missingMetallibIsUnavailable`: a temp root where `isInstalled` is true (small fake files plus `.verified`), run under `swift test` (no metallib) → `.unavailable("on-device model needs the app build")`
  - `@Test(.enabled(if: MLXGate.ready), .timeLimit(.minutes(2))) liveSearchPicksSplit`: `MLXGate.ready` = the real 4B spec installed under `ModelCatalog.defaultRoot` and `MLXRuntime.isReady` → the Task 7 split query gives non-empty picks, all candidates, a tmux "split" item in the first 3
  - `@Test(.enabled(if: MLXGate.ready)) liveNoMatchIsEmpty`: the sourdough query → zero picks
  - `@Test(.enabled(if: MLXGate.ready)) liveUnloadsAfterIdle`: `idle: 1`, one query, wait 2 s → the holder reports not loaded
- [ ] **Step 2:** `swift test --filter "IdleHolderTests|MLXChooserTests"` → fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `swift test` → pass (live tests skipped). If the model is installed (Task 13's `--install-model` or by the user), run `make test-mlx` and record the live results and the median latency.
- [ ] **Step 5:** Commit: `git add Sources/SanketaMLX/IdleHolder.swift Sources/SanketaMLX/MLXChooser.swift Tests/SanketaMLXTests/IdleHolderTests.swift Tests/SanketaMLXTests/MLXChooserTests.swift && git commit -m "Add MLX on-device chooser"`

### Task 13: Panel wiring, status menu, CLI, debug info, README

**Files:**
- Modify: `Sources/SanketaUI/SearchModel.swift`, `Sources/SanketaUI/PanelController.swift`, `Sources/SanketaUI/Views/PanelView.swift`, `Sources/SanketaSystem/DebugInfo.swift`, `Sources/Sanketa/AppDelegate.swift`, `Sources/Sanketa/main.swift`, `README.md`, `Makefile` (`publish` notes)
- Test: `Tests/SanketaUITests/SmartSearchModelTests.swift`, `Tests/SanketaSystemTests/DebugInfoTests.swift`, `Tests/SanketaSystemTests/AskCLITests.swift`

**Interfaces:**
- Consumes: everything above; `PanelController.beginSearch`, `Config.save(_:_:to:table:)`, `KeyBox.ask`, `APIKey.resolve`, `KeychainStore`, `ModelList.fetch`, `OpenAIModels.cheapest`, `ModelInstaller`, `ModelCatalog`, `CoachMonitor.recent`/`generation`
- Produces:
  - `SearchModel`: `init(provider:pasteboard:smart: SmartSearch? = nil, debounce: TimeInterval = 0.6)`; `@Published public private(set) var picked: Set<String>`, `@Published public private(set) var note: String?`; `public func setSmart(_ s: SmartSearch?)`. Every query change shows `provider.results` at once (current behaviour) and cancels the pending smart task. With 3+ words, a task starts after `debounce`; its result replaces `results` (picks first, then `byPack` of the rest) only if `query` is unchanged.
  - `ResultsList`: picked rows show a small saffron dot; one muted line under the results shows `note`. `PanelView` passes `search.picked`/`search.note`.
  - `PanelController.beginSearch` calls a new `public var prewarm: () -> Void = {}`; the app sets it to `router.prewarm()`.
  - App wiring (`AppDelegate`):
    - Builds one `ModelRouter` from `config.llm`: `MLXChooser(spec: ModelCatalog.spec(config.llm.mlxModel), installer:)`, `AppleFMChooser()`, and `OpenAIChooser` only when `llm.openai`. Its `key` closure runs `APIKey.resolve(varName: llm.apiKeyEnv, env: ProcessInfo.processInfo.environment, shell: APIKey.loginShell(env:passwdShell: getpwuid(getuid()).pw_shell), runner: ProcessRunner(), store: KeychainStore(), account:)` once per launch and caches the result. Its `model` closure returns `llm.openaiModel`, or when empty `OpenAIModels.cheapest(try await ModelList.fetch(…))`, cached. `reloadConfig()` rebuilds the router.
    - Model suggestions: when `coach.generation` changes, the innermost layer is a local shell, `router.suggestChooser() != nil` and 600 s have passed since the last run → `SmartSuggest.pick(recent: coach.recent(shell:limit: 10), …, excluding: ids marked .known)`; results get explain `"Related to what you just ran"` and join `model.coachItems`.
    - Status menu, after Translucency:
      - **"OpenAI Model"** submenu with an `NSMenuDelegate`. With `llm.openai == false` it holds one disabled line, "Turn on with [llm] openai = true in config.toml", and makes no request. Otherwise `menuWillOpen` shows the cached list plus a disabled "Loading models…" line and starts `ModelList.fetch` (8 s timeout); the result replaces the items on the main run loop in `.common` modes. First item "Cheapest (now <id>)" saves `openai_model = ""`; then one item per id, checked when it equals `llm.openaiModel`. A pick saves with `Config.save("openai_model", "\"<id>\"", to: configURL, table: "llm")`. A failure shows "Could not load the model list".
      - **"OpenAI Key…"**: `KeyBox.ask(host:)`, then `APIKey.clean`, then `KeychainStore().write(_, account: APIKey.account(for:))`, and clears the cached key.
      - **"On-Device Model"** submenu: a status line ("Qwen3.5-4B: downloaded" / "not downloaded"), "Download Qwen3.5-4B (3.1 GB)", "Download Qwen3.5-2B (1.8 GB)", "Remove Downloaded Model". During a download the status line shows `Downloading… NN %`. A finished download saves `mlx_model` in `[llm]` and rebuilds the router.
    - Copy Debug Info and `--dump-context` are unchanged except for the `llm` lines below.
  - `DebugInfo.report(… llm: [String] = [])` appends the given lines. The app passes `DebugInfo.llmLines(config: LLMConfig, statuses: [(String, ModelStatus)])`: `on-device: <status>`, `Apple Intelligence: <status>`, `openai: off` or `openai: on provider=openai|custom model=<id or auto>`. It never takes a key and never prints `base_url` for a custom host.
  - CLI in `main.swift` (add each to the usage text and to the value-check list where they take a value):
    - `--ask "<query>" [--out FILE]`: builds the same router (no key box; the key comes from env, login shell or Keychain), runs `SmartSearch.results` over the library items, prints `backend: <chooser name or the Plain search note>` and then the top 5 as `<* if picked><packID>: <title> — <detail>`.
    - `--install-model [4b|2b]`: runs `ModelInstaller.install` with one progress line per 5%, prints `installed <folder>` and exits 0, or the error and exits 1.
  - README (grade 9 or below; `ProseTests` checks it): the intro line changes from "it does not use the network" to "it uses the network only if you turn on OpenAI search or download the on-device model"; new sections "Better ways" (what is detected, local only), "Natural-language search" (the router order, the download size and RAM, Apple Intelligence optional, the 3-word and 600 ms rule), "Privacy" (the addendum's "Exactly what leaves the machine" list, in grade-9 words), and `[coach]`/`[llm]` blocks with defaults in the Settings TOML example; the status-menu list gains the three new items; Development lists `make test-mlx` and the Metal toolchain step.
  - `Makefile` `publish` notes: replace "It does not monitor input, and it does not use the network." with "It does not monitor input. It uses the network only if you turn on OpenAI search or download the on-device model."

- [ ] **Step 1: Write failing tests:**
  - `smartResultReplacesListWhenQueryUnchanged` (SmartSearchModelTests, `debounce: 0.1`, `SmartSearch` over `FixedChooser(["e2"])` with an FM-tier router): set a 4-word query → at once `results` = local; after 0.4 s `results[0]` is the pick, `picked` holds its id, `note == nil`
  - `staleSmartResultDropped`: `SlowChooser(0.3)`; set query A, then query B after 0.15 s → `results` never shows A's pick
  - `typingQuicklyCallsModelOnce`: `RecordingChooser`; set 6 growing queries 30 ms apart, wait 0.5 s → exactly one prompt
  - `plainNoteShowsWithoutChooser`: router with nothing available → after the debounce, `note` has prefix `"Plain search:"`, `results` = local
  - `keyNeverInDebugInfo` (DebugInfoTests): `DebugInfo.report` with `llmLines` from a config with `openai = true`, `base_url = "http://10.0.0.5:1234/v1"` → contains `openai: on provider=custom`, does not contain `10.0.0.5`; the test also runs `APIKey.resolve` with env `["OPENAI_API_KEY": "sk-secret-123"]` before building the report and asserts the report has no `sk-secret-123`
  - `askPrintsBackendAndResults` (AskCLITests): run the built `Sanketa` binary (`swift build --show-bin-path`) through `ProcessRunner` with `--ask "how do I split the window side by side" --out <temp>` and env `HOME=<temp> SANKETA_MODEL_DIR=<temp>/models` through `/usr/bin/env`, so it reads no real config, model folder or Keychain item (`[llm] openai` stays off) → first line starts with `backend: `, at least one later line starts with `tmux:` or `*tmux:`
- [ ] **Step 2:** `swift test --filter "SmartSearchModelTests|DebugInfoTests|AskCLITests"` → fail.
- [ ] **Step 3:** Implement the wiring, the menus, the CLI modes, the debug lines, README and the publish notes.
- [ ] **Step 4:** `swift test` → pass (incl. `ProseTests`). Then `make app && make relaunch` and check by hand, recording results in the task report:
  - (a) `build/Sanketa.app/Contents/MacOS/Sanketa --ask "how do I split the window side by side" --out /tmp/ask.txt` → `backend:` names the best available tier; tmux split entries follow.
  - (b) In the panel the same query shows results at once, then picked rows with dots, or one muted note. No popup, no sound.
  - (c) Typing a 6-word query fast and pausing → one model call (debug counter or timing); CPU back to idle within 2 s.
  - (d) With `[llm] openai = true`, no env key and no Keychain item: the note ends with `OpenAI no key`. "OpenAI Model" opens and shows "Loading models…", then the list or the error line, without blocking the menu. Do not use a real key unless the user asks.
  - (e) "On-Device Model" → "Download Qwen3.5-2B" only if the user agrees to the 1.75 GB download; then `--ask` reports `backend: on-device (Qwen3.5-2B)`, and after 60 s idle Activity Monitor shows the memory released.
  - (f) Idle CPU stays under 1% with the panel open for 5 minutes. Copy Debug Info shows the `llm` lines and no key.
- [ ] **Step 5:** Commit: `git add Sources/SanketaUI/SearchModel.swift Sources/SanketaUI/PanelController.swift Sources/SanketaUI/Views/PanelView.swift Sources/SanketaSystem/DebugInfo.swift Sources/Sanketa/AppDelegate.swift Sources/Sanketa/main.swift README.md Makefile Tests/SanketaUITests/SmartSearchModelTests.swift Tests/SanketaSystemTests/DebugInfoTests.swift Tests/SanketaSystemTests/AskCLITests.swift && git commit -m "Wire natural-language search, model menus and ask mode"`

---

## Self-review notes

- **Spec coverage.**
  - Goal 8: history reading (T2), lexer and detectors (T3, T4), card in the tip slot with no notifications and searchability (T5).
  - Goal 9: grounded NL search (T6, T13); on-device primary MLX (T10–T12) behind `OnDeviceChooser`; Apple FM with the bench fixes `includeSchemaInPrompt: false`, `prewarm`, positional guard, `.default` only (T6, T7, T13); OpenAI-compatible fallback off by default with the cheapest-model rule, model menu, `base_url` and key flow (T1, T8, T9, T13); suggestions on device only (T6, T13).
  - Anti-goals: focus (key box only from a menu item; T9, T13), CPU (Global Constraints, T2 cache, T5 timer, T12 idle unload, T13 checks), chatty UI (one muted note; T6, T13), data off the machine (T6 `remoteChooserNeverSeesMenuItems`, T8 `bodyIsExactlyWhatLeaves`, `suggestIsRefused`, T13 `keyNeverInDebugInfo`; the opt-in download sends no user data, T11).
  - User decisions 1–4: router order (T6 `routerOrder`), OpenAI details (T8, T9, T13), rules-only coaching (T4), executable scope (all tasks; the coordinator's later message made MLX executable, T10–T12).
- **Type consistency against v0.1.1.** `SearchItem(packID:packName:kind:title:detail:explain:tags:)` and `active`; `Search.rank(_:_:context:limit:)`; `SearchProviding`/`LocalSearch` unchanged; `SearchModel.setSource(library:context:)` extended with `extra:`; `PanelModel(tips:seed:)`, `tipCards`, `pickTips()`, `seed`, `mark(_:_:)`; `TipStore.pick(from:count:seed:)`; `Context.layers` with `Layer.kind/.host/.name`; `PackLibrary.pack(process:argv:)`; `ProcessRunner().run(_:_:timeout:)` returns nil on non-zero exit; `Config.save(_:_:to:)` extended with `table:`; `DebugInfo.report(version:context:library:configPath:configError:home:)` extended with `llm:`; `PanelController.beginSearch(previousApp:)`; `FileWatcher` is not used for history (fish renames the file; `stat` polling is cheaper and simpler). Names introduced here (`Choosing`, `OnDeviceChooser`, `ModelRouter(config:onDevice:appleFM:remote:)`, `ChoiceError`, `SmartResult`, `Coaching.item`, `CoachMonitor.generation`, `ModelSpec`, `ModelInstaller`, `IdleHolder`, `MLXRuntime.isReady`, `APIKey.resolve`, `KeyStore`) are used with the same signatures in every later task.
- **Fixed from the old plan.** Wrong addendum path; views live in `SanketaUI`, not `Sanketa`; `tempDir()` already exists; config keys are snake_case; `--dump-coach` writes with the existing `emit(_:to:)`; commits are one STE line with no `feat:` prefix; FM gets `includeSchemaInPrompt: false` and the prompt gets the bench's JSON line; the old hard-coded `gpt-4.1-mini` is replaced by the runtime rule; the coaching card shares the tip slot instead of adding a second card; README and release notes no longer say "no network" without the opt-in exception.
- **Review Focus:** each of the five lines names its test in the owning task.
- **Proportion:** the detector table and pinned hashes are data the implementer can't derive; the rest is signatures and test assertions.
