# Sanketa Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sanketa coaches better shell idioms from the user's local fish and bash history, shown as panel cards. It also adds natural-language search and suggestions, using Apple's on-device model to choose among loaded entries only, with an opt-in OpenAI fallback.

**Architecture:**
- `SanketaCore` gains:
  - pure history parsing
  - a shell lexer
  - 13 rule detectors and the coach aggregation
  - loose retrieval, prompt building, grounding and routing (no model imports)
- A new `SanketaAI` target holds the two `Choosing` backends: Foundation Models, and OpenAI over `URLSession`.
- `SanketaSystem` gets a `CoachMonitor`.
- The app wires a Better-way card, debounced NL search and `--dump-coach` / `--ask` CLI modes.

**Tech Stack:** Swift 6.2 / Xcode 26 (SDK macOS 26.5), language mode v5, Swift Testing, FoundationModels (`SystemLanguageModel`, `LanguageModelSession`, `DynamicGenerationSchema`), `URLSession`. No new package dependencies.

**Spec:** `docs/superpowers/specs/2026-10-24-sanketa-design.md` (goals 8, 9, anti-goals). Addendum: `.superpowers/phase2/2026-10-24-sanketa-phase2-design.md`, which holds the decisions, the verified API facts and exactly what leaves the machine. Builds on: `docs/superpowers/plans/2026-10-24-sanketa-phase1.md`. Phase 1 must be complete; run phase 2 on branch `phase2`.

## Global Constraints

- Every phase 1 Global Constraint still applies, with one exception: the only network call is the opt-in OpenAI request (Task 8). It is made only when `[llm] openai = true`, only for NL search, and only when on-device is off or unavailable.
- "Sending anything off the machine unless the user explicitly enabled the OpenAI fallback" is an anti-goal. When OpenAI is enabled, only the payload listed in the addendum leaves the machine. History, coaching results, window titles, layer names and `app:` (menu-derived) items never do.
- Shell history is read locally only. It is never written, copied into the repo, logged, or put in a test fixture.
- **Agents must not read the user's real history contents.** Verify with `--dump-coach` (detector ids and counts only), never `--dump-coach --full`. Tests generate their own history files in temp dirs.
- Coaching and model output appear only in the panel. No notifications, popups or sounds. Model failures produce at most one muted footer line in search mode.
- The model never invents shortcuts:
  - Everything shown is a loaded entry (packs, menus, live tmux keys) or detector output.
  - The model returns only refs, constrained by `DynamicGenerationSchema(anyOf:)`.
  - `Grounding.resolve` re-validates them.
- On-device model: `SystemLanguageModel.default` only. No adapters, no `Tool`s, a fresh `LanguageModelSession` per call, `GenerationOptions(sampling: .greedy, maximumResponseTokens: 64)`.
- Context window is 4096 tokens. Prompt budget: candidate lines ≤ 6000 characters, each ≤ 160; recent commands ≤ 10, each ≤ 120 characters.
- CPU:
  - no model call while idle
  - history `stat`ed every 60 s and re-analysed only on an mtime/size change
  - model suggestions at most once per 600 s
  - NL search calls the model only for queries of ≥ 3 words, 600 ms after the last keystroke, cancelling any in-flight call
- Config keys are camelCase like phase 1 (`pollInterval`). New tables are `[coach]` and `[llm]`.
- Binaries: fish `/opt/homebrew/bin/fish` (4.8.1), bash `/bin/bash` (3.2). Tests run fish with `--no-config` and bash with `--norc --noprofile`.
- Testing directive (binding): real functional tests.
  - real history files written by real fish/bash in temp dirs
  - real detectors over real command strings, and rewrites executed in real shells
  - the live Foundation Models test, gated on `SystemLanguageModel.default.isAvailable`
  - no code-shape assertions

## Review Focus

1. **A rewrite that changes what the command does.** Examples: multi-file grep, `sort -n`, `cut` on input with lines lacking the delimiter, `ls DIR`, hidden files under `**`. The user expects no suggestion rather than a wrong one. Pinned by the negative table in `noRewriteForUnsafeInput` and by `rewriteIsEquivalentInRealShell` (Task 4).
2. **Quotes, escapes, substitutions and multi-line fish commands in history** (`grep 'a|b' f | wc -l`, `(expr $n + 1)`, unbalanced quotes). They should be lexed correctly or skipped, never mis-split. Pinned by `quotedPipeStaysInWord`, `fishSubstitution`, `unbalancedQuoteGivesNothing` (Task 3) and `quotedPatternGrepCount` (Task 4).
3. **A huge, truncated or non-UTF-8 history file, or a missing bash history.** The expected result is a bounded read (last 4 MB), broken bytes tolerated, no error shown. Pinned by `readsTailOfHugeFile`, `invalidUTF8DoesNotCrash`, `missingFilesGiveEmpty` (Task 2).
4. **Apple Intelligence off or not ready, or the model erroring or hanging mid-search.** Plain results should appear at once, with one muted note and no popup. Pinned by `smartSearchFallsBackOnError`, `smartSearchTimesOut` (Task 6) and `unavailableModelDegradesToLocalSearch` (Task 7; it runs for real on this Mac, where Apple Intelligence is off).
5. **OpenAI enabled with no key, HTTP 401 or offline, and history must never leak.** Plain results plus a note are expected, and the payload never carries history or menu items. Pinned by `remoteChooserNeverSeesMenuItems` (Task 6), `bodyIsExactlyWhatLeaves` and `http401FallsBackWithNote` (Task 8).

---

## File Structure

```
Sources/SanketaCore/
  Config.swift          (modify) + CoachConfig, LLMConfig
  History.swift         Shell, HistoryEntry, FishHistory, BashHistory, HistoryFile, HistoryCache
  ShellLex.swift        Word, ShellCommand, Substitution, ShellLex
  Detectors.swift       Rewrite, Detector, Detectors.all (13, precedence order) + stage helpers
  Coach.swift           Coaching, Coach.rewrites/analyze
  Retrieval.swift       Retrieval, ChoicePrompt, Grounding
  SmartSearch.swift     ModelStatus, Choosing, ModelRouter, SmartSearch, SmartSuggest
Sources/SanketaAI/
  OnDeviceChooser.swift FoundationModels backend
  OpenAIChooser.swift   OpenAIRequest, OpenAIChooser, OpenAIKey
Sources/SanketaSystem/
  CoachMonitor.swift
Sources/Sanketa/
  Views/BetterWayCard.swift, (modify) PanelView.swift, PanelController.swift, AppDelegate.swift, main.swift
Tests/SanketaCoreTests/
  ConfigTests.swift (modify), HistoryTests.swift, ShellLexTests.swift,
  DetectorExamples.swift, DetectorTests.swift, CoachTests.swift, RetrievalTests.swift, SmartSearchTests.swift
  Support/Shells.swift   helpers: tempDir(), runFish(_:in:), runBash(_:in:), writeFishHistory(_:in:), makeFixtureDir()
Tests/SanketaAITests/
  OnDeviceChooserTests.swift, OpenAIChooserTests.swift
Tests/SanketaSystemTests/
  CoachMonitorTests.swift
README.md (modify)
```

---

### Task 1: `[coach]` and `[llm]` config tables

**Files:**
- Modify: `Sources/SanketaCore/Config.swift`
- Test: `Tests/SanketaCoreTests/ConfigTests.swift`

**Interfaces:**
- Consumes: phase 1 `Config`, `Config.load(_:) -> (Config, String?)`
- Produces:
  - `public struct CoachConfig: Codable, Equatable { enabled: Bool; fishHistory: String; bashHistory: String; maxEntries: Int }`
    - defaults: `true`, `"~/.local/share/fish/fish_history"`, `"~/.bash_history"`, `5000`
    - `var fishURL: URL` and `var bashURL: URL`, with the tilde expanded
  - `public struct LLMConfig: Codable, Equatable { onDevice: Bool; suggest: Bool; openai: Bool; openaiModel: String; timeoutSeconds: Double }`
    - defaults: `true`, `true`, `false`, `"gpt-4.1-mini"`, `5`
  - `Config` gains `coach: CoachConfig` and `llm: LLMConfig`, decoded with `decodeIfPresent`. Each nested struct has its own `init(from:)` so a partial table keeps its defaults. Numbers accept a TOML int or float, as in phase 1.

- [ ] **Step 1: Write failing tests:**
  - `llmDefaultsKeepOpenAIOff`: empty file → `llm.openai == false`, `llm.onDevice == true`, `coach.enabled == true`
  - `llmTableParses`: `"[llm]\nopenai = true\nopenaiModel = \"gpt-x\""` → `openai == true`, `openaiModel == "gpt-x"`, `suggest == true`
  - `integerTimeoutAccepted`: `"[llm]\ntimeoutSeconds = 3"` → `3.0`
  - `coachPathsExpandTilde`: default `fishURL.path == NSHomeDirectory() + "/.local/share/fish/fish_history"`
  - `badLLMTypeReturnsError`: `"[llm]\nopenai = \"yes\""` → defaults and a non-nil error
- [ ] **Step 2:** `swift test --filter ConfigTests` → the new tests fail.
- [ ] **Step 3:** Implement in `Config.swift`.
- [ ] **Step 4:** `swift test` → all pass.
- [ ] **Step 5:** Commit `feat: coach and llm config tables`.

### Task 2: Shell history reading

**Files:**
- Create: `Sources/SanketaCore/History.swift`, `Tests/SanketaCoreTests/Support/Shells.swift`
- Test: `Tests/SanketaCoreTests/HistoryTests.swift`

**Interfaces:**
- Produces:
  - `public enum Shell: String, Codable, Hashable, Sendable { case fish, bash }`
  - `public struct HistoryEntry: Hashable, Sendable { command: String; when: Date?; shell: Shell }`
  - `FishHistory.parse(_ text: String) -> [HistoryEntry]`. Line rules:
    - `- cmd: ` starts an entry. Unescape the value in one left-to-right pass: `\\` → `\` and `\n` → newline. Any other `\x` stays as is.
    - `  when: N` sets the date.
    - `  paths:`, `    - …`, `  added_when: …`, unknown keys and any lines before the first `- cmd:` are ignored.
    - An entry with no `when` keeps `when == nil`.
  - `BashHistory.parse(_ text: String) -> [HistoryEntry]`: a line matching `^#\d+$` sets the date for the next command line. Blank lines are skipped. Every other line is one command.
  - `HistoryFile.readTail(_ url: URL, maxBytes: Int = 4_000_000) -> String?`
    - nil when the file is missing or unreadable
    - when the file is larger than `maxBytes`, it seeks to `size - maxBytes` and drops everything up to and including the first `\n`
    - decodes with `String(decoding:as: UTF8.self)`, so invalid bytes become U+FFFD
  - `public final class HistoryCache: @unchecked Sendable { init(); func entries(fish: URL?, bash: URL?, maxEntries: Int) -> [HistoryEntry]; private(set) var generation: Int }`
    - It returns fish entries and then bash entries, each in file order and each capped to its last `maxEntries`.
    - Each file is re-read only when its `(modificationDate, size)` changes.
    - `generation` increments only when the returned content changed. It is guarded by a lock.
  - Test support in `Shells.swift`:
    - `tempDir() -> URL`
    - `runFish(_ script: String, in: URL) -> String?`: `/opt/homebrew/bin/fish --no-config -c "cd '<dir>'; <script>"` via `ProcessRunner`, 5 s timeout
    - `runBash(_:in:) -> String?`: `/bin/bash --norc --noprofile -c …`
    - `writeFishHistory(_ commands: [String], in: URL) -> URL`. It runs real fish with `XDG_DATA_HOME`/`XDG_CONFIG_HOME` pointing into the temp dir, through `/usr/bin/env` so `ProcessRunner` needs no env parameter: `set -g fish_history sktest; history append <each command, fish-single-quoted>; history save`. It returns `<dir>/fish/sktest_history`.

- [ ] **Step 1: Write failing tests:**
  - `fishParsesRealFishOutput`: `writeFishHistory(["cat a.log | grep 404 | wc -l", "for f in (ls *.txt)\necho $f\nend", "echo a\\b"])` → parse gives 3 entries with exactly those commands (the second has two `\n`, the third one backslash), every `when` within 120 s of now, `shell == .fish`
  - `fishIgnoresPathsAndAddedWhen`: the text `"- cmd: ls\n  when: 1792000000\n  paths:\n    - /tmp\n  added_when: 1792000001\n- cmd: pwd\n  when: 1792000002\n"` → commands `["ls","pwd"]`, first `when == Date(timeIntervalSince1970: 1792000000)`
  - `bashParsesRealBashOutput`: `runBash("set -o history; history -s 'sort x | uniq'; history -s 'ps aux | grep node'; history -w h", in: dir)` → parse `dir/h` → commands are exactly those two, `when == nil`
  - `bashTimestampsApply`: `"#1792000000\nls -la\npwd\n"` → `ls -la` dated, `pwd` nil
  - `missingFilesGiveEmpty`: `HistoryCache().entries(fish: dir/"nope", bash: dir/"nope2", maxEntries: 10) == []`
  - `readsTailOfHugeFile`: write 20 MB of synthetic fish entries (`- cmd: echo N\n  when: N\n`) → `readTail` result `utf8.count <= 4_000_000`; parsing it gives a first command matching `^echo \d+$`; read and parse finish in < 1 s
  - `invalidUTF8DoesNotCrash`: bytes for `- cmd: ls \xFF\xFE\n  when: 1\n- cmd: pwd\n  when: 2\n` → 2 entries, the second `pwd`
  - `truncatedLastEntryKept`: `"- cmd: ls\n  when: 1\n- cmd: git st"` → 2 entries, the last `git st` with `when == nil`
  - `cacheReReadsOnlyOnChange`: two calls with no change → same `generation`. Then use real fish to `history append 'git status'` to the same file → `generation` increments and `git status` is last
  - `maxEntriesKeepsNewest`: 10 fish entries, `maxEntries: 3` → the last 3
- [ ] **Step 2:** `swift test --filter HistoryTests` → fail.
- [ ] **Step 3:** Implement `History.swift` and `Shells.swift`.
- [ ] **Step 4:** `swift test` → pass.
- [ ] **Step 5:** Commit `feat: fish and bash history reading`.

### Task 3: Shell command lexer

**Files:**
- Create: `Sources/SanketaCore/ShellLex.swift`
- Test: `Tests/SanketaCoreTests/ShellLexTests.swift`

**Interfaces:**
- Consumes: `Shell`
- Produces:
  - `public struct Word: Hashable, Sendable { raw: String; value: String; globbed: Bool; var isRedirect: Bool }`
    - `raw` is the source text, including quotes. `value` has the quotes and escapes removed; a substitution part stays as its raw text.
    - `globbed` is true when the word has an unquoted `*`, `?` or `[`.
    - `isRedirect` is true when `raw` matches `^[0-9&]*(<|>|>>|>&\d*|<&\d*)$` or `^[0-9]*>&[0-9]+$`.
  - `public enum Substitution: Hashable, Sendable { case paren, dollar, backtick }`. `paren` is fish `( )`.
  - `public struct ShellCommand: Hashable, Sendable { text: String; stages: [[Word]]; substitution: Substitution?; wrappedText: String? }`
    - `text` is the trimmed source of one pipeline.
    - `wrappedText` is set for substitutions and includes the delimiters, e.g. `$(expr $n + 1)`.
  - `ShellLex.commands(_ line: String, shell: Shell) -> [ShellCommand]`

Rules:
- Commands end at `;`, `&&`, `||`, a lone `&`, and newlines.
- Stages split on `|`, `|&` and fish `&|`.
- A `#` at the start of a word starts a comment that runs to the end of the line.
- Single quotes are literal. In fish, `\'` and `\\` are escapes inside them.
- Inside double quotes, `\"`, `\\` and `\$` are escapes, and `$(…)` is still a substitution.
- An unquoted backslash escapes the next character.
- Substitutions: fish `( … )` unquoted, `$( … )` in both shells, and backticks in bash. Parentheses nest. The inner text is lexed recursively; its commands come straight after the command that contains them, with `substitution` and `wrappedText` set.
- Leading keyword words are dropped: fish `and or not time command builtin`; bash `time ! do then else elif`.
- An unbalanced quote, parenthesis or backtick anywhere → `[]`.

- [ ] **Step 1: Write failing tests** (assert `stages.map { $0.map(\.value) }` unless noted):
  - `pipelineStages`: `cat a.log | grep 404 | wc -l` (fish) → `[[cat,a.log],[grep,404],[wc,-l]]`
  - `quotedPipeStaysInWord`: `grep 'a|b' f | wc -l` → `[[grep,a|b,f],[wc,-l]]`, `stages[0][1].raw == "'a|b'"`
  - `separators` (bash): `cd /tmp && ls | grep x; echo done` → texts `["cd /tmp","ls | grep x","echo done"]`
  - `fishSubstitution`: `set n (expr $n + 1)` → 2 commands:
    - `[0]` raws `[set,n,(expr $n + 1)]`
    - `[1]` values `[expr,$n,+,1]`, `substitution == .paren`, `wrappedText == "(expr $n + 1)"`
  - `bashDollarSubstitutionInDoubleQuotes`: `echo "count: $(grep -c x f)"` → `[1]` values `[grep,-c,x,f]`, `.dollar`
  - `backtickSubstitution` (bash): ``n=`expr $n + 1` `` → `[1]` values `[expr,$n,+,1]`, `.backtick`
  - `fishKeywordsDropped`: `test -f x; and cat x | grep y` → `[1]` stages `[[cat,x],[grep,y]]`
  - `multilineFishLoop`: `"for f in (ls *.log)\necho $f\nend"` → texts `["for f in (ls *.log)","ls *.log","echo $f","end"]`
  - `unbalancedQuoteGivesNothing`: `echo 'oops | grep x` → `[]`. Also `echo (ls` in fish → `[]`
  - `commentIgnored`: `ls | grep x # find x` → `[[ls],[grep,x]]`
  - `globFlag`: `ls *.log '*.txt'` → `globbed` `[false,true,false]`
  - `redirectWords`: `sort < in.txt > out.txt 2>&1` → `isRedirect` true for `<`, `>` and `2>&1`, and false otherwise
  - `escapedSpace`: `echo a\ b | wc -c` → `[[echo,a b],[wc,-c]]`
- [ ] **Step 2:** `swift test --filter ShellLexTests` → fail.
- [ ] **Step 3:** Implement as a single-pass character scanner with a quote state and a paren-depth stack.
- [ ] **Step 4:** `swift test` → pass.
- [ ] **Step 5:** Commit `feat: shell command lexer`.

### Task 4: Better-ways detectors and coach aggregation

**Files:**
- Create: `Sources/SanketaCore/Detectors.swift`, `Sources/SanketaCore/Coach.swift`
- Test: `Tests/SanketaCoreTests/DetectorExamples.swift`, `DetectorTests.swift`, `CoachTests.swift`

**Interfaces:**
- Consumes: `ShellLex`, `ShellCommand`, `Word`, `Shell`, `HistoryEntry`, phase 1 `SearchItem`/`ItemKind.suggestion`
- Produces:
  - `public struct Rewrite: Hashable, Sendable { before: String; after: String; explain: String }`
  - `public struct Detector: Sendable { id: String; title: String; shells: Set<Shell>; rewrite: @Sendable (ShellCommand, Shell) -> Rewrite? }`
  - `public enum Detectors { static let all: [Detector] }` in this precedence order: `pgrep, grep-count, grep-awk, sort-unique, find-xargs, find-glob, ls-grep, glob-loop, math, string-split, string-replace, string-case, useless-cat`
  - `Coach.rewrites(_ line: String, shell: Shell) -> [(detectorID: String, title: String, rewrite: Rewrite)]`: lex the line, and for each command apply the first detector in order that returns non-nil
  - `public struct Coaching: Hashable, Sendable { detectorID: String; title: String; before: String; after: String; explain: String; count: Int; lastSeen: Date?; var item: SearchItem }`
    - `item` is `packID "coach"`, `packName "Better ways"`, `kind .suggestion`, `title`, `detail = after`, `explain = "Instead of \(before) · \(count)× in your history. \(explain)"`, `tags ["coach", detectorID]`
  - `Coach.analyze(_ entries: [HistoryEntry]) -> [Coaching]`
    - one result per detector that fired
    - `count` is the number of entries with a hit
    - the example (`before`, `after`, `explain`, `lastSeen`) comes from the latest hit by date; undated entries rank by file order, after dated ones
    - sorted by `count` descending, then `lastSeen` descending

Detector rules. `before` is `ShellCommand.text`. For substitutions it is the inner text, except for bash `math`, where it is `wrappedText`. Words are re-emitted with `raw`.

- **Cat fold** (shared): a first stage that is exactly `cat F` (one non-flag, non-glob word) folds `F` into the next stage as its file. It is used by `grep-count`, `grep-awk`, `sort-unique` and `useless-cat`.
- **pgrep:** stage 0 is `ps` with args in `{aux, -ef, -e, ax}`. The rest is one `grep NAME` (no flags, NAME `^[A-Za-z0-9._-]+$`), plus optionally `grep -v grep` before or after it. The whole command → `pgrep -fl NAME`.
- **grep-count:**
  - Stage i is `grep` and stage i+1 is exactly `wc -l`.
  - grep has no `-o -c -l -L --count` and at most one file operand after the pattern.
  - Result: `grep -c <grep's args>`, with any stages before i kept, or with the cat fold applied.
- **grep-awk:**
  - Adjacent `grep PAT [F]` (no flags, PAT value `^[A-Za-z0-9_ :=-]+$`) and `awk [-F X | -FX] '{…}'`, where the program value starts with `{`.
  - Result: `awk [-F…] '/PAT/ PROGRAM' [F]`.
- **sort-unique:**
  - `sort` with no flags, or only `-r`, followed by a bare `uniq`.
  - Result: `sort [-r] -u [F]`, with the cat fold applied.
- **find-xargs:**
  - `find DIR [-type f] -name PAT | xargs CMD ARGS…`. PAT is a value starting with `*` with no `/`. No other find predicates. xargs has no flags.
  - fish → `CMD ARGS… <DIR/>**<PAT minus leading *>`, with `./` dropped for `.`.
  - bash → `find DIR [-type f] -name PAT -exec CMD ARGS… {} +`.
- **find-glob (fish):** a single-stage `find DIR [-type f] -name PAT` with the PAT rules above → `printf '%s\n' <glob>`.
- **ls-grep:**
  - `ls` or `ls -1` with no other args, piped to `grep P` with no flags.
  - P matching `^[A-Za-z0-9_-]+$` → `ls -d *P*`.
  - P of `\.ext$` or `.ext$`, where ext matches `[A-Za-z0-9]+` → `ls -d *.ext`.
- **glob-loop:**
  - `for VAR in` followed by a fish `(ls ARGS)` or `$(ls ARGS)`, where every ARG is `globbed` and there are no flags.
  - Result: `for VAR in ARGS`, or `*` when there are no ARGS.
- **math:**
  - `expr` whose args are all numbers, `$var` or operators in `+ - \* / %`.
  - `bc` with no flags, fed by `echo E`.
  - fish → `math [-s0] ARGS`. Add `-s0` when the expression contains `/` or `%`. When it contains `*`, emit a single-quoted expression with `\*` turned into `*`. For bc, always emit a single-quoted expression.
  - bash `expr` → `echo $(( ARGS ))`, or inside a substitution `wrappedText` → `$(( ARGS ))`, with `\*` → `*`.
- **string-split (fish):** two stages, `echo $VAR` (one word starting with `$`, optionally double-quoted) and `cut -dD -fN` or `cut -d D -fN` (D a single character, N a single integer) → `string split -fN D $VAR`.
- **string-replace (fish):**
  - `echo $VAR | sed 's/A/B/[g]'`, with A matching `^[A-Za-z0-9_:@,=+]+$` and B matching the same class or empty.
  - Result: `string replace [-a] A B $VAR`, with an empty B written as `''`.
- **string-case (fish):** `echo $VAR | tr a-z A-Z` or `tr '[:lower:]' '[:upper:]'` → `string upper $VAR`, and the reverse → `string lower $VAR`.
- **useless-cat:**
  - stage 0 is `cat F` (single file, no flags) with a next stage
  - next command in `grep awk sed head tail sort cut` → `<next words> F`
  - next command in `wc tr` → `<next words> < F`
  - any other next command → no rewrite

Explain copy (one line each; the builder may tighten the wording but keep these facts):
- pgrep: "pgrep -f matches full command lines and never lists itself."
- grep-count: "grep -c counts matching lines itself."
- grep-awk: "awk can match the pattern and print the field in one pass."
- sort-unique: "sort -u drops duplicate lines while sorting."
- find-xargs: fish: "** expands to the matching files; names with spaces stay intact." bash: "-exec … {} + batches files like xargs and copes with spaces."
- find-glob: "fish's ** walks subdirectories (it skips hidden ones)."
- ls-grep: "A glob picks the names directly."
- glob-loop: "Loop over the glob; parsing ls breaks on spaces."
- math: fish: "fish's math builtin; -s0 keeps integer division." bash: "Shell arithmetic, no extra process."
- string-split: "fish's string split -fN picks one field."
- string-replace: "fish's string replace works on variables directly."
- string-case: "fish's string upper/lower."
- useless-cat: "Give the file to the command directly."

`DetectorExamples.swift` defines `struct Example: Sendable, CustomTestStringConvertible { shell: Shell; setup: String; input: String; detector: String; before: String; after: String; check: Check }` with `enum Check { case exact, trimmed, sortedLines, sortedNoDotSlash, none }`, plus two arrays.

`positive` (setup is shown before ⏐; the default is empty):

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

`negative` (shell, input). Each must give zero rewrites:
- fish `grep -o x a.log | wc -l`
- bash `grep x a.log names.txt | wc -l`
- fish `grep x a.log | wc -w`
- bash `cat a.log names.txt | grep x`
- fish `cat -n a.log | grep x`
- fish `cat a.log | while read l; echo $l; end`
- bash `sort -n nums.txt | uniq`
- fish `sort names.txt | uniq -c`
- fish `find . -iname '*.py'`
- fish `find . -name '*.py' -mtime -1`
- bash `find . -name '*.py'`
- fish `find . -name '*.py' | xargs -n1 wc -l`
- fish `ls -la | grep x`
- bash `ls | grep -v x`
- fish `ls | grep 'a.*b'`
- fish `for f in (ls -t); echo $f; end`
- fish `for f in (ls src); echo $f; end`
- fish `echo $name | sed 's/a.b/c/g'`
- fish `echo $row | cut -d, -f1,3`
- fish `printf 'a,b\n' | cut -d, -f2`
- fish `ps aux | grep -i node`
- fish `echo 'oops | grep x`
- bash `expr length "$s"`
- bash `echo '1/3' | bc -l`

`makeFixtureDir()` creates:
- `a.log`, exactly these four lines:
  ```
  10.0.0.1 - - GET /index 200 512
  10.0.0.2 - - GET /missing 404 0
  10.0.0.3 - - POST /form 404 0
  10.0.0.1 - - GET /gone 404 0
  ```
- `names.txt`: `bob\nada\nbob\ncy\nada\n`
- `data.csv`: `a,1\nb,2\na,3\n`
- `top.py`, `src/x.py`, `src/sub/y.py` (one line each)
- `old.log`, `app.log`, `readme.txt`, `report.txt`, `catalog.md`

There are no hidden files.

- [ ] **Step 1: Write failing tests:**
  - `@Test(arguments: positive) rewritesExample`: `Coach.rewrites(input, shell:)` has exactly one element, with `detectorID == detector`, `rewrite.before == before` and `rewrite.after == after`. Setup is never analysed.
  - `@Test(arguments: negative) noRewriteForUnsafeInput`: `Coach.rewrites(input, shell:).isEmpty`.
  - `@Test(arguments: positive.filter { $0.check != .none }) rewriteIsEquivalentInRealShell`:
    - In a fresh `makeFixtureDir()`, run `setup; input` and `setup; input.replacingFirst(before, with: after)` with `runFish`/`runBash`.
    - Both must be non-nil and equal after normalising per `check`. `trimmed` trims whitespace. `sortedLines` sorts trimmed lines. `sortedNoDotSlash` also removes `./` everywhere first.
  - `pgrepSuggestionFindsSpawnedProcess`: spawn `/bin/sleep 37` with `Foundation.Process`, run `/usr/bin/pgrep -fl 'sleep 37'` via `ProcessRunner` → the output contains the child's pid. Terminate the child in `defer`.
  - `quotedPatternGrepCount`: covered by example 4; additionally `grep 'a|b' a.log | wc -l` (fish) → after `grep -c 'a|b' a.log`.
  - `substitutionAndOuterBothChecked`: `cat a.log | grep (expr 400 + 4)` (fish) → two rewrites, `useless-cat` and `math`.
  - `analyzeCountsAndOrders` (CoachTests):
    - Entries: three dated grep-count lines (t=1, 3, 2), one sort-unique line (t=5), one line with no hit.
    - Result ids `["grep-count","sort-unique"]`.
    - grep-count `count == 3`, `lastSeen` = t3, its `before` is the t3 line.
    - `item.kind == .suggestion`, `item.detail == after`, `item.packID == "coach"`.
  - `analyzeRealFishHistoryFile`: `writeFishHistory` with lines 1, 9, 25 and `echo hi` → read via `HistoryCache` → `analyze` ids are exactly `{grep-count, sort-unique, math}`.
  - `analyzeIsFastOnFiveThousandEntries`: 5000 entries cycling through all positive inputs → finishes in < 2 s (debug build).
- [ ] **Step 2:** `swift test --filter "DetectorTests|CoachTests"` → fail.
- [ ] **Step 3:** Implement `Detectors.swift` (one small function per detector plus the shared stage helpers: cat fold, flag/operand split, word re-emit) and `Coach.swift`.
- [ ] **Step 4:** `swift test` → pass. If an equivalence case fails, the detector rule is wrong, not the test. Narrow the rule, move the example to `negative`, and note why in the task report.
- [ ] **Step 5:** Commit `feat: better-ways detectors and coach`.

### Task 5: Coach monitor, Better-way card, `--dump-coach`

**Files:**
- Create: `Sources/SanketaSystem/CoachMonitor.swift`, `Sources/Sanketa/Views/BetterWayCard.swift`
- Modify: `Sources/Sanketa/Views/PanelView.swift`, `Sources/Sanketa/AppDelegate.swift`, `Sources/Sanketa/main.swift`, and `PanelController`'s search corpus (append `coach.items`)
- Test: `Tests/SanketaSystemTests/CoachMonitorTests.swift`

**Interfaces:**
- Consumes: `CoachConfig`, `HistoryCache`, `Coach.analyze`, `TipStore.pick`, phase 1 `Context.layers`/`LayerKind.shell`
- Produces:
  - `@MainActor public final class CoachMonitor: ObservableObject`
    - `@Published public private(set) var items: [SearchItem]`
    - `public private(set) var generation: Int`
    - `init(config: CoachConfig, cache: HistoryCache = HistoryCache(), interval: TimeInterval = 60)`
    - `func start()`
    - `func refreshNow() async`
    - `func recent(shell: Shell, limit: Int) -> [HistoryEntry]`
    - Work runs on a serial background queue. `items` is assigned only when `cache.generation` changed. When `enabled == false`, it never reads files and `items == []`.
  - `BetterWayCard`: title, `after` in SF Mono with a copy button, the explain line, and "I know this" / "Show less" through `TipStore`.
    - It is shown only when `context.layers` contains a `.shell` layer with `host == nil` and `TipStore.pick(from: coach.items + modelSuggestions, count: 1, seed:)` returns an item.
    - It uses the phase 1 seed rotation (context change and `tipRotateSeconds`).
    - It renders under the tip card, in the same visual language.
  - `--dump-coach` prints `<detectorID>\t<count>` per line and no command text. `--dump-coach --full` also prints before/after; it is for the user only.

- [ ] **Step 1: Write failing tests:**
  - `monitorPublishesFromRealFiles`:
    - Use `writeFishHistory(["cat a.log | grep 404 | wc -l"])` and set `CoachConfig.fishHistory` to that path.
    - `await refreshNow()` → items contain id `coach|suggestion|<grep-count title>` with explain containing `1×`.
    - Append the same line with real fish, `refreshNow()` → explain contains `2×`.
  - `monitorUnchangedFileKeepsGeneration`: two `refreshNow()` calls with no change → same `generation`.
  - `monitorDisabledPublishesNothing`: `enabled = false` and a valid file → `items == []`.
  - `recentReturnsShellSpecific`: a fish file with 3 commands and a bash file with 2 → `recent(shell: .bash, limit: 5).count == 2`, and the fish result is newest-last.
- [ ] **Step 2:** `swift test --filter CoachMonitorTests` → fail.
- [ ] **Step 3:** Implement the monitor, card, panel wiring, `--dump-coach` and searchability (append `coach.items` to the search corpus).
- [ ] **Step 4:** `make test app run`, then check by hand and record in the task report:
  - (a) With a fish window frontmost, the Better-way card shows.
  - (b) "I know this" hides that detector, and it stays hidden after relaunch.
  - (c) Searching "grep -c" finds the coaching item.
  - (d) `open -W build/Sanketa.app --args --dump-coach` (stdout to `--out /tmp/coach.txt` if the phase 1 CLI uses `--out`) prints only id/count lines.
  - (e) Activity Monitor shows idle CPU still under 1%.
- [ ] **Step 5:** Commit `feat: coaching cards from shell history`.

### Task 6: Retrieval, prompt, grounding and routing (no model)

**Files:**
- Create: `Sources/SanketaCore/Retrieval.swift`, `Sources/SanketaCore/SmartSearch.swift`
- Test: `Tests/SanketaCoreTests/RetrievalTests.swift`, `SmartSearchTests.swift`

**Interfaces:**
- Consumes: `SearchItem`, `Search.rank`, `PackLibrary` (incl. `pack(process:argv:)`), `HistoryEntry`, `ShellLex`, `LLMConfig`
- Produces:
  - `Retrieval.terms(_ query: String) -> [String]`:
    - lowercase, split on non-alphanumerics
    - drop stopwords: `a an the how do does i to in of for with my me what is are can you show find get make on it this that and or way want`
    - stem by stripping one of `ing ed es s`, keeping at least 3 characters, then collapsing a doubled final consonant
  - `Retrieval.candidates(_ query: String, _ items: [SearchItem], context: [String], limit: Int = 40) -> [SearchItem]`:
    - per term: stemmed title word prefix 3, title substring 2, a substring of detail, explain, tags or packName 1
    - +1 if `packID` is in `context`
    - keep items scoring > 0, sorted by score descending, then by context index
  - `public struct ChoicePrompt: Equatable, Sendable`
    - `enum Task: Equatable, Sendable { case search(String), suggest([String]) }`
    - fields: `task`, `refs: [String]`, `lines: [String]`, `maxPicks: Int`
    - `var instructions: String`, `var userText: String`, `func halved() -> ChoicePrompt` (keeps the first `max(1, n/2)` refs and lines)
  - `ChoicePrompt.build(task:candidates:maxPicks:charBudget: Int = 6000) -> (prompt: ChoicePrompt, refs: [String: SearchItem])`:
    - refs are `e1…eN`
    - each line is `"\(ref) | \(packName) | \(title) | \(detail)"`, cut to 160 characters
    - lines stop being added once the running total would exceed `charBudget`
    - `suggest` commands are cut to 120 characters, last 10 only
  - Exact copy:
    - `instructions`: `"You match a request to entries from a list of keyboard shortcuts and command tips. Answer only with refs from the list, best first, at most \(maxPicks). Return an empty list if nothing fits."`
    - `userText` for search: `"Request: \(q)\nEntries:\n" + lines.joined("\n")`
    - `userText` for suggest: `"Recent commands:\n" + cmds.joined("\n") + "\nPick entries that would help with what these commands do.\nEntries:\n" + lines…`
  - `Grounding.resolve(_ picks: [String], _ refs: [String: SearchItem], max: Int) -> [SearchItem]`: drops unknown refs, dedupes, keeps order, caps at `max`
  - `public enum ModelStatus: Equatable, Sendable { case available(String), unavailable(String), off }`
  - `public protocol Choosing: Sendable { var name: String { get }; var isRemote: Bool { get }; func status() -> ModelStatus; func choose(_ prompt: ChoicePrompt) async throws -> [String] }`
  - `public struct ModelRouter: Sendable`
    - `init(config: LLMConfig, onDevice: Choosing?, openAI: Choosing?)`
    - `func searchChooser() -> Choosing?`: on-device if `config.onDevice` and it is `.available`; else OpenAI if `config.openai` and it is `.available`; else nil
    - `func suggestChooser() -> Choosing?`: on-device only, and only when `config.suggest`
    - `func searchNote() -> String?`: when `searchChooser()` is nil, `"Plain search: <reason>"`, where reason is the on-device unavailable reason, or `"on-device model off"`. With OpenAI enabled but unusable, append `"; <openAI reason>"`.
  - `public struct SmartSearch: Sendable`
    - `init(router: ModelRouter, timeout: TimeInterval)`
    - `func results(_ query: String, _ items: [SearchItem], context: [String]) async -> SmartResult`, with `public struct SmartResult: Equatable { items: [SearchItem]; picked: Set<String>; note: String? }`
    - `local` = `Search.rank` if that is non-empty, else `Retrieval.candidates`
    - With fewer than 3 whitespace words, or no chooser, return `local` and `router.searchNote()` (only when there are ≥ 3 words).
    - Otherwise:
      - Build the candidates. When `isRemote`, first drop items whose `packID` has the prefix `app:`.
      - `choose`, racing the timeout. On `exceededContextWindowSize`, retry once with `halved()`; detect this by a `ChoiceError.contextExceeded` that backends throw.
      - Picks go first, then `local` minus the picks.
      - On error or timeout, return `local` with the note `"Plain search: \(chooser.name) \(short reason)"`.
  - `public enum ChoiceError: Error, Equatable { case contextExceeded, notAllowed, http(Int), badResponse }`
  - `public enum SmartSuggest`
    - `static func candidates(recent: [HistoryEntry], library: PackLibrary, items: [SearchItem], excluding: Set<String>, limit: Int = 30) -> [SearchItem]`: take the first word of each stage of the last 10 commands (skipping `sudo env command`), map through `library.pack(process:argv:)`, then take `.tip`/`.key` items of those packs, most recent pack first, minus `excluding`
    - `static func pick(recent:library:items:excluding:router:timeout:) async -> [SearchItem]`: max 2 picks, `[]` on any failure, never an OpenAI chooser

- [ ] **Step 1: Write failing tests.** Fakes: `FixedChooser(picks:status:isRemote:)`, `ThrowingChooser`, `SlowChooser(seconds:)`, and `RecordingChooser` (stores the prompts it receives). The real bundled packs are loaded from `Resources/Packs` via `#filePath`.
  - `termsDropStopwordsAndStem`: `"how do I count matching lines"` → `["count","match","line"]`
  - `retrievalFindsSplitForNaturalQuery`: bundled packs, `"how do I split the window side by side"`, context `["tmux"]` → the top 10 contain a tmux item whose title contains "split" (case-insensitive)
  - `promptRespectsBudget`: 500 synthetic candidates → `lines.joined().count <= 6000`, `refs.count == lines.count`, map keys == `Set(refs)`, every line ≤ 160
  - `promptCopyIsExact`: `build(task: .search("split pane"), candidates: [one item], maxPicks: 5)` → `userText == "Request: split pane\nEntries:\ne1 | tmux | Split pane left/right | prefix %"`
  - `groundingDropsInventedRefs`: picks `["e3","e99","bogus","e3","e1"]` → `[item3, item1]`
  - `smartSearchPutsPicksFirst`: `FixedChooser(["e2"])` → `items[0]` is candidate e2, `picked == [its id]`, no duplicates
  - `shortQueryDoesNotCallModel`: `RecordingChooser`, query `"split"` → zero prompts
  - `smartSearchFallsBackOnError`: `ThrowingChooser` → items == local, `note?.hasPrefix("Plain search:") == true`
  - `smartSearchTimesOut`: `SlowChooser(5)`, timeout 0.3 → returns in < 1.5 s with local items and a note
  - `contextExceededRetriesHalved`: a chooser that throws `.contextExceeded` on the first call and then returns `["e1"]` → second prompt `refs.count == first/2`, pick applied
  - `remoteChooserNeverSeesMenuItems`: a remote `RecordingChooser` over items including `packID "app:com.apple.Terminal"` → no recorded line contains that pack's name, and a local chooser does see it
  - `routerPrefersOnDeviceThenOpenAI`, one case per row:
    - on-device available → on-device
    - on-device unavailable, openai on and available → OpenAI
    - openai off → nil, and the note mentions the on-device reason
    - `suggestChooser()` is nil when only OpenAI is available
  - `suggestCandidatesFromRecentCommands`: bundled library, recent `["git status","git log --oneline | head -n 5"]` (bash) → non-empty, `candidates[0].packID == "git"`, every `packID` is one that `library.pack(process:argv:)` returns for `git` or `head`, and ids passed in `excluding` are absent
- [ ] **Step 2:** `swift test --filter "RetrievalTests|SmartSearchTests"` → fail.
- [ ] **Step 3:** Implement. Race the timeout with `withTaskGroup` over `choose` and `Task.sleep`, cancelling the loser.
- [ ] **Step 4:** `swift test` → pass.
- [ ] **Step 5:** Commit `feat: grounded retrieval and model routing`.

### Task 7: On-device chooser (Foundation Models)

**Files:**
- Modify: `Package.swift`:
  - `.target(name: "SanketaAI", dependencies: ["SanketaCore"], swiftSettings: v5)`
  - `.testTarget(name: "SanketaAITests", dependencies: ["SanketaAI","SanketaCore"], swiftSettings: v5)`
  - add `"SanketaAI"` to the `Sanketa` executable's dependencies
- Create: `Sources/SanketaAI/OnDeviceChooser.swift`
- Test: `Tests/SanketaAITests/OnDeviceChooserTests.swift`

**Interfaces:**
- Consumes: `Choosing`, `ChoicePrompt`, `ChoiceError`, `ModelStatus`
- Produces: `public struct OnDeviceChooser: Choosing { init(model: SystemLanguageModel = .default) }`
  - `name "on-device"`, `isRemote false`
  - `status()` maps `availability`:
    - `.available` → `.available("on-device")`
    - `.deviceNotEligible` → `"this Mac can't run Apple Intelligence"`
    - `.appleIntelligenceNotEnabled` → `"Apple Intelligence is off"`
    - `.modelNotReady` → `"Apple Intelligence model not ready"`
    - `@unknown default` → `"Apple Intelligence unavailable"`
  - `static func schema(refs: [String], maxPicks: Int) throws -> GenerationSchema`: `GenerationSchema(root: DynamicGenerationSchema(name: "Choice", properties: [.init(name: "picks", schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(name: "Ref", anyOf: refs), minimumElements: 0, maximumElements: maxPicks))]), dependencies: [])`
  - `choose`:
    - a fresh `LanguageModelSession(model:, instructions: prompt.instructions)`
    - `respond(to: prompt.userText, schema:, options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 64))`
    - `response.content.value([String].self, forProperty: "picks")`
    - error mapping: `GenerationError.exceededContextWindowSize` → `ChoiceError.contextExceeded`; other errors are rethrown
    - an empty `refs` list returns `[]` without calling the model

- [ ] **Step 1: Write failing tests:**
  - `schemaAcceptsRefs`: `schema(refs: ["e1","e2","e3"], maxPicks: 3)` doesn't throw, and its encoded JSON (`JSONEncoder` on the `Codable` `GenerationSchema`) contains `"maxItems" : 3` or `"maxItems":3` and each ref. This proves the real FM schema API accepts our shape.
  - `@Test(.disabled(if: SystemLanguageModel.default.isAvailable)) unavailableModelDegradesToLocalSearch`:
    - Real `OnDeviceChooser` and `ModelRouter(config: .init(), onDevice: it, openAI: nil)`.
    - `SmartSearch.results("how do I split the window side by side", bundled items, context: ["tmux"])` → non-empty items, `picked.isEmpty`, `note?.hasPrefix("Plain search:") == true`.
    - `OnDeviceChooser().status()` is `.unavailable`.
  - `@Test(.enabled(if: SystemLanguageModel.default.isAvailable), .timeLimit(.minutes(1))) liveSearchPicksOnlyCandidates`: same query → `!picked.isEmpty`. Every picked id is among `Retrieval.candidates` for the query, and one of the first 3 items is a tmux item whose title contains "split".
  - `@Test(.enabled(if: …)) liveSuggestPicksFromRecentPacks`: recent `["git log --oneline | head -n 20","git status"]` → `SmartSuggest.pick` returns ≤ 2 items, all from candidate packs.
  - `@Test(.enabled(if: …)) liveNoMatchStaysGrounded`: `"bake sourdough bread at home tonight"` → every pick (possibly none) is a candidate, and there are ≤ 5.
- [ ] **Step 2:** `swift test --filter OnDeviceChooserTests` → fail (no target).
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `swift test` → pass. Record in the report which gated tests ran and which were skipped. On this Mac Apple Intelligence is currently off, so expect the live tests to be skipped and `unavailableModelDegradesToLocalSearch` to run. If the user has enabled it, the live tests must run and pass.
- [ ] **Step 5:** Commit `feat: on-device Foundation Models chooser`.

### Task 8: OpenAI fallback chooser

**Files:**
- Create: `Sources/SanketaAI/OpenAIChooser.swift`
- Test: `Tests/SanketaAITests/OpenAIChooserTests.swift`

**Interfaces:**
- Consumes: `Choosing`, `ChoicePrompt`, `ChoiceError`, `CommandRunning`/`ProcessRunner`
- Produces:
  - `OpenAIRequest.body(model: String, prompt: ChoicePrompt) -> Data`. The JSON object has exactly these keys:
    - `model`
    - `messages`: `[{role:"system",content:instructions},{role:"user",content:userText}]`
    - `response_format`: `{type:"json_schema",json_schema:{name:"choice",strict:true,schema:{type:"object",properties:{picks:{type:"array",items:{type:"string",enum:refs}}},required:["picks"],additionalProperties:false}}}`
    - `store: false`
    - `max_completion_tokens: 100`
  - `OpenAIRequest.parse(_ data: Data) throws -> [String]`: reads `choices[0].message.content` as JSON `{"picks":[…]}`, otherwise throws `ChoiceError.badResponse`
  - `public struct OpenAIChooser: Choosing`
    - `init(model: String, key: String?, session: URLSession = .shared, timeout: TimeInterval)`
    - `name "OpenAI"`, `isRemote true`
    - `status()`: no key → `.unavailable("OPENAI_API_KEY not found")`, else `.available("OpenAI")`
    - `choose`:
      - `.suggest` → throws `.notAllowed`
      - otherwise POST `https://api.openai.com/v1/chat/completions` with `Authorization: Bearer <key>`, `Content-Type: application/json` and `timeoutInterval = timeout`
      - a non-2xx response → `.http(status)`
  - `OpenAIKey.resolve(env: [String: String], loginShell: String?, runner: CommandRunning) -> String?`
    - a trimmed non-empty `env["OPENAI_API_KEY"]` wins
    - otherwise run `[loginShell, "-l", "-c", "printf %s \"$OPENAI_API_KEY\""]` once with a 3 s timeout and use the trimmed non-empty result
    - otherwise nil
    - the key is never logged or written

- [ ] **Step 1: Write failing tests.** `StubProtocol: URLProtocol` captures the request (including `httpBodyStream`) and returns a canned status and body. It is installed on an ephemeral `URLSessionConfiguration`.
  - `bodyIsExactlyWhatLeaves`:
    - Build a search prompt from 3 items and decode the body.
    - The top-level keys are exactly the five listed. `store == false`. `messages[1].content == prompt.userText`. The enum equals the refs.
    - Building from a `SmartSearch` call with a recording remote chooser and history entries passed alongside: no body string contains any history command.
  - `parseReadsPicks`: `{"choices":[{"message":{"role":"assistant","content":"{\"picks\":[\"e2\",\"e5\"]}"}}]}` → `["e2","e5"]`
  - `parseRejectsGarbage`: `{"choices":[]}` and plain text `"oops"` → throw `.badResponse`
  - `chooserSendsRequestAndParses`: stub 200 → the captured URL is `https://api.openai.com/v1/chat/completions`, method `POST`, header `Authorization == "Bearer sk-test"`, picks parsed
  - `http401FallsBackWithNote`: stub 401 → `choose` throws `.http(401)`. Through `SmartSearch` with on-device unavailable and openai on, the result is local items with a note containing `"OpenAI"`.
  - `suggestIsRefused`: `.suggest` prompt → throws `.notAllowed`, and the stub saw no request
  - `keyFromEnvWins`: env `["OPENAI_API_KEY":" sk-env \n"]` → `"sk-env"`, and the login shell is never run (pass a nonexistent shell path)
  - `keyFromLoginShell`: a temp executable script `#!/bin/sh\nprintf 'sk-from-shell'\n` (chmod 755) as `loginShell` with empty env → `"sk-from-shell"`
  - `keyMissingIsNil`: a script printing nothing → nil
  - `@Test(.enabled(if: env["SANKETA_LIVE_OPENAI"] == "1" && env["OPENAI_API_KEY"] != nil)) liveOpenAIPicksOnlyCandidates`: the bundled-packs query from Task 7 → picks ⊆ refs. It never runs unless the user sets the flag.
- [ ] **Step 2:** `swift test --filter OpenAIChooserTests` → fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `swift test` → pass. Do not run the live test; that is the user's call.
- [ ] **Step 5:** Commit `feat: opt-in OpenAI fallback chooser`.

### Task 9: NL search and model suggestions in the panel, `--ask`, README

**Files:**
- Modify: `Sources/Sanketa/PanelController.swift`, `Views/PanelView.swift`, `Views/SearchField.swift`, `Views/BetterWayCard.swift`, `AppDelegate.swift`, `main.swift`, `README.md`

**Interfaces:**
- Consumes: `ModelRouter`, `SmartSearch`, `SmartSuggest`, `OnDeviceChooser`, `OpenAIChooser`, `OpenAIKey`, `CoachMonitor`, `LLMConfig`
- Produces:
  - `AppDelegate` builds one `ModelRouter`. OpenAI is constructed only when `llm.openai`; its key comes from `OpenAIKey.resolve(env: ProcessInfo.processInfo.environment, loginShell: <getpwuid(getuid()).pw_shell>, runner: ProcessRunner())`, resolved lazily on the first NL query.
  - Search mode:
    1. Every keystroke shows `Search.rank` results immediately (phase 1 behaviour).
    2. With ≥ 3 words, a `Task` starts after 600 ms idle. Every keystroke cancels the previous one.
    3. Its `SmartSearch.results` replaces the list only if the query is unchanged.
    4. Picked rows show a small saffron dot. A muted footer line shows `note`, or `"Ranked on-device"` / `"Ranked by OpenAI"`.
  - Model suggestions:
    - Run when `coach.generation` changes, a local `.shell` layer is present, `router.suggestChooser() != nil`, and at least 600 s have passed since the last run.
    - `SmartSuggest.pick` over the current shell's `recent(limit: 10)` and the library items, excluding `.known`.
    - The results join the Better-way pool with explain `"Related to what you just ran"`.
  - `--ask "<query>" [--out FILE]`: prints `backend: <name or Plain search: …>`, then one line per result for the top 5: `<* if picked><packID>: <title> — <detail>`.
  - README sections:
    - "Better ways": what is detected, and that it is local only
    - "Natural-language search": Apple Intelligence requirement and fallback
    - "Privacy": the addendum's exact "what leaves the machine" list, verbatim
    - "Config": a full `config.toml` example with `[coach]` and `[llm]` and their defaults

- [ ] **Step 1:** Implement the wiring, the CLI mode and the README.
- [ ] **Step 2:** `make test app` → all pass. Then check by hand and record in the task report:
  - (a) With Apple Intelligence off, run `open -W build/Sanketa.app --args --ask "how do I split the window side by side" --out /tmp/ask.txt` → the first line is `backend: Plain search: Apple Intelligence is off`, followed by tmux split entries.
  - (b) In the panel, the same query shows results instantly and a single muted note, with no popup and no sound.
  - (c) Typing a 6-word query quickly, then pausing → at most one model call. Check with `--ask` timing or a debug counter. CPU returns to idle within 2 s.
  - (d) With `[llm] openai = true` and no key → the note reads `…; OPENAI_API_KEY not found`. Don't test with a real key unless the user asks.
  - (e) If Apple Intelligence is on: the panel query marks picked tmux rows, and a fish session with recent `git` commands eventually shows a "Related to what you just ran" card.
  - (f) Idle CPU stays under 1% with the panel open for 5 minutes.
- [ ] **Step 3:** Commit `feat: natural-language search and model suggestions`.

---

## Self-review notes

- **Spec coverage:**
  - Goal 8: history reading (T2), detectors (T3–T4), cards with no notifications (T5).
  - Goal 9: grounded NL search (T6–T7, T9), suggestions (T6, T7, T9), OpenAI fallback off by default (T1, T8).
  - Anti-goals: chatty UI (T5/T9 manual checks), CPU (Global Constraints, T2 cache, T5/T9 checks), off-machine data (T6 `remoteChooserNeverSeesMenuItems`, T8 `bodyIsExactlyWhatLeaves`, `suggestIsRefused`).
  - Testing directive: real fish/bash writers (T2), real-shell equivalence (T4), live gated FM tests (T7).
- **Types:** `Choosing`, `ChoicePrompt`, `ChoiceError`, `ModelRouter`, `SmartResult`, `Coaching.item` and `CoachMonitor.generation` are used consistently in T6–T9.
- **Dependency on phase 1 names:** `SearchItem` fields, `Search.rank`, `TipStore.pick`, `PackLibrary.pack(process:argv:)`, `ProcessRunner`, `Context.layers` and `LayerKind.shell` are as defined in the phase 1 plan. If phase 1 shipped different names, adapt them, and say so in the task report.
