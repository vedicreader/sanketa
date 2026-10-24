# Sanketa phase 2: design addendum

Covers spec goals 8 ("better ways" coaching from shell history) and 9 (natural-language search and suggestions). It adds to `docs/superpowers/specs/2026-10-24-sanketa-design.md` and builds on the code as shipped in v0.1.1 (Leela contexts, the index layout with one tip card, the release pipeline). Plan: `docs/superpowers/plans/2026-10-24-sanketa-phase2.md`. Model research: `.superpowers/phase2/model-bench.md` (not in git).

## Decisions

Decisions marked **(user)** are binding decisions from the user on 2026-10-24.

**Coaching is rules only, no model (user).** Every model in the bench (MLX, LiteRT, Core ML, Apple FM) made 3 to 14 rewrites out of 20 that broke the command or changed what it does. Coaching uses a small shell lexer (quotes, escapes, `;`/`&&`/`||`, pipes, fish `(…)`, `$(…)`, backticks, comments) and 13 detectors run in a fixed precedence order. Each command gets at most one rewrite. A detector fires only when its rewrite is safe: multi-file grep, `sort -n`/`-k`, `ls DIR`, `cut` on multi-line input and similar cases are rejected. Every positive example is also run in real fish or bash over a fixture directory, and its output must match the original's output.

| id | shell | example → suggestion |
|---|---|---|
| `pgrep` | both | `ps aux \| grep node` → `pgrep -fl node` |
| `grep-count` | both | `cat a.log \| grep 404 \| wc -l` → `grep -c 404 a.log` |
| `grep-awk` | both | `grep 404 a.log \| awk '{print $5}'` → `awk '/404/ {print $5}' a.log` |
| `sort-unique` | both | `sort names.txt \| uniq` → `sort -u names.txt` |
| `find-xargs` | fish / bash | `find . -name '*.py' \| xargs wc -l` → `wc -l **.py` / `find . -name '*.py' -exec wc -l {} +` |
| `find-glob` | fish | `find . -name '*.py'` → `printf '%s\n' **.py` |
| `ls-grep` | both | `ls \| grep log` → `ls -d *log*` |
| `glob-loop` | both | `for f in (ls *.log)` → `for f in *.log` |
| `math` | fish / bash | `expr 7 / 2` → `math -s0 7 / 2` / `echo $(( 7 / 2 ))` |
| `string-split` | fish | `echo $row \| cut -d, -f2` → `string split -f2 , $row` |
| `string-replace` | fish | `echo $name \| sed 's/foo/bar/g'` → `string replace -a foo bar $name` |
| `string-case` | fish | `echo $name \| tr a-z A-Z` → `string upper $name` |
| `useless-cat` | both | `cat a.log \| grep POST` → `grep POST a.log` |

Checked against fish 4.8.1 in /tmp: `**.py` skips hidden directories (the explain text says so); `math -s0` truncates like `expr`; `string split -f2` stops at the first line that lacks the delimiter, so `string-split` only rewrites `echo $VAR | cut`; macOS `pgrep -fl` prints the pid and the full argv.

**One card, in the tip slot.** The index layout from the design pass shows one tip card. Coaching does not add a second card. When the innermost layer is a local shell (the user is at a prompt) and the tip seed is even, the tip slot shows a coaching item for that shell; otherwise it shows a pack tip as before. Coaching results are `SearchItem`s with `kind: .suggestion`, `packID "coach"`, `packName "Better ways"` and tags `["coach", <detector id>, <shell>]`. They are also searchable. The item id is per detector, so "I know this" silences a detector in both shells. No notifications.

**History is read locally and cheaply.**
- fish: `~/.local/share/fish/fish_history`. Format: `- cmd: …` and `  when: <epoch>`, plus optional `  paths:` / `    - …` and `  added_when: …` lines. In `cmd`, `\\` stands for a backslash and `\n` for a newline (confirmed with real fish `history append`/`history save`).
- bash: `~/.bash_history`. Plain lines, with optional `#<epoch>` lines when HISTTIMEFORMAT is set.
- Only the last 4 MB of each file is read, capped at 5000 entries per shell.
- Each file is checked with `stat` every 60 s and re-analysed only when its mtime or size changes. fish rewrites the file by rename, so `stat` is more reliable than an fd watcher.

**NL search is retrieval first, then a model chooses refs.**
1. Local loose retrieval: stopwords removed, light stemming, any-term scoring, context packs and `active` items boosted. Up to 40 candidates.
2. The candidates go into a numbered list (`e1 | pack | title | detail`).
3. The model returns up to 5 refs under constrained decoding (an enum of the refs), so it cannot emit anything else.
4. `Grounding.resolve` checks the refs again and maps them back to loaded items. A pick list equal to the first N refs in list order (N ≥ 2) counts as no pick (Apple FM's positional collapse). The model never writes text that the user sees.

No tool calling. The model is called only for queries of 3 or more words, 600 ms after typing stops. Plain results show at once while the model works. 5 s timeout. On a context overflow, one retry with half the candidates.

**Router order for NL search (user).**
1. **On-device primary: MLX Qwen3.5-4B** (`mlx-community/Qwen3.5-4B-MLX-4bit`, 4-bit, Apache-2.0, 3.06 GB) through mlx-swift-lm with XGrammar guided JSON. Small-RAM fallback: Qwen3.5-2B (1.75 GB), picked by `[llm] mlx_model`. Bench: 26/30 top-1, 30/30 top-3, 1.06 s median, 3.7 GB while loaded. It is used only after the user downloads the model. It sits behind the `OnDeviceChooser` protocol.
2. **Apple Foundation Models**, the no-download tier, when Apple Intelligence is on. Bench after fixes: 17/30 top-1. Required fixes: `includeSchemaInPrompt: false` (with the default `true` it returned empty lists 25/30 times); `prewarm()` when search starts (the first call costs about 3 s); the positional-collapse guard above; `SystemLanguageModel.default` only, never `.contentTagging`.
3. **OpenAI-compatible fallback**, off by default.
4. **Plain search.**

Core ML and LiteRT are not used. Core ML has no generic Swift runtime or constrained output, takes 146 s to compile on first load and is 3× slower. LiteRT's constrained decoding is broken for Gemma (upstream #3510).

**Model suggestions are on-device only.** The chooser looks at the last 10 commands for the current shell and picks up to 2 existing tips or keys from the packs those commands map to. They join the coaching pool. At most once every 600 s, only after history changes, never through OpenAI.

**MLX model download is opt-in.** Nothing is bundled in the app. The user starts the download from the status menu (On-Device Model) or with `Sanketa --install-model [4b|2b]`. Files come from `huggingface.co` at a pinned commit, and each file's size and SHA-256 must match values in the source. They go to `~/Library/Application Support/Sanketa/Models/<name>/`, written to a `.partial` folder and renamed only after every check passes. The model loads on first use and unloads after 60 s idle.

**MLX build.** SwiftPM on the command line cannot compile MLX's Metal shaders. `swift build` and `swift test` still compile everything; MLX code that needs the GPU runs only from an `xcodebuild` build, which compiles the metallib. `make bundle` switches to `xcodebuild`, and both this Mac and CI need `xcodebuild -downloadComponent MetalToolchain` (Xcode 26 ships the Metal toolchain as a separate component; it is not installed on this Mac today).

**Degrading.** With no usable chooser, search is plain local search. One muted line under the results says why, in search mode only, for example "Plain search: Apple Intelligence is off". No popups and no retries.

**OpenAI-compatible fallback (user).**
- `[llm] openai = false` by default. Used only for NL search, only when no on-device chooser can answer.
- `[llm] base_url` (default `https://api.openai.com/v1`) points at any OpenAI-compatible server: OpenRouter, Ollama, LM Studio. A native Anthropic client is out of scope; use an OpenAI-compatible proxy such as OpenRouter.
- Model: `[llm] openai_model`. When it is empty, Sanketa fetches `GET <base_url>/models` and picks the cheapest model by a fixed rule (see the plan, Task 8): a short preference list (`gpt-5-nano`, `gpt-4.1-nano`, `gpt-4o-mini`, `gpt-5-mini`, `gpt-4.1-mini`), then the lexically smallest `nano`, then `mini` model among chat-capable ids. Nothing is hard-coded as the only choice.
- Status menu: an "OpenAI Model" submenu loads the current model list each time it opens and saves the pick to `[llm] openai_model`. It lists whatever the `base_url` server returns.
- API key (account = the `base_url` host): `OPENAI_API_KEY` (or the variable named in `[llm] api_key_env`) from the process environment; else one run of the user's login shell (`$SHELL`, else the account's shell) as `<shell> -l -c 'printf %s "$OPENAI_API_KEY"'` through `CommandRunning` with a 3 s timeout, a real unmodified shell; else the Keychain item saved earlier; else the user types it in a small key box opened from the status menu ("OpenAI Key…"). A typed key goes to the macOS Keychain through the Security framework's `SecItem` API inside the app, never the `security` CLI. Local servers (`localhost`, `127.0.0.1`, `::1`) need no key. The key is never logged, printed or put in Copy Debug Info.

**Exactly what leaves the machine.**
- With `[llm] openai = true`, per NL query: one HTTPS POST to `<base_url>/chat/completions` carrying the model id, the fixed instruction text, `Request: <query text>`, up to 40 candidate lines `ref | pack name | entry title | keys or snippet` from TOML packs and live tmux keys only, and the bearer key. To `api.openai.com` it also sends `"store": false`.
- With `[llm] openai = true`, when the OpenAI Model submenu opens or the default model is resolved: one `GET <base_url>/models` with the bearer key.
- When the user starts a model download: plain GETs to `huggingface.co` for the pinned files. No key, no user data.
- Never sent: shell history, coaching results, window or document titles, layer or process names, menu-derived entries (`app:` packs, which can hold window and document names), the model suggestions prompt.

**Config keys.** New keys use snake_case, like `hyper_label` and the user's `openai_model`/`base_url`. Older top-level keys stay camelCase.

## API facts verified

Evidence is from `FoundationModels.framework/Modules/FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface` (SDK macOS 26.5, module 1.5.2), plus a compiled probe.

- `final class SystemLanguageModel: Sendable` (L513):
  - `availability` and `isAvailable` (L514, L517)
  - `static var default` (L575)
  - `init(useCase:guardrails:)` (L581)
- `@frozen enum Availability { case available; case unavailable(UnavailableReason) }` (L554–569). `UnavailableReason` has `deviceNotEligible`, `appleIntelligenceNotEnabled` and `modelNotReady` (L559–561). It is not `@frozen`, so a switch over it needs `@unknown default`.
- `contextSize: Int` (L634) is `@backDeployed(before: macOS 26.4)` and returns 4096 there. `tokenCount(for:)` (L599) is macOS 26.4+ only. The plan uses a fixed character budget so it doesn't need a `#available` branch.
- `LanguageModelSession(model:tools:instructions:)` (L338–341) and `prewarm(promptPrefix:)` (L342).
- `respond(to:schema:includeSchemaInPrompt:options:) async throws -> Response<GeneratedContent>` (L365). String-prompt and `generating: Content.Type` overloads follow it.
- `GenerationError` cases (L424–432): `exceededContextWindowSize`, `assetsUnavailable`, `guardrailViolation`, `unsupportedGuide`, `unsupportedLanguageOrLocale`, `decodingFailure`, `rateLimited`, `concurrentRequests` and `refusal`. A fresh session per call avoids `concurrentRequests`.
- Guided generation:
  - `@Generable` (L15), `@Guide` (L23–31) and `GenerationGuide<String>.anyOf/constant/pattern` (L254–256)
  - `DynamicGenerationSchema(name:anyOf: [String])` (L1284) and `(arrayOf:minimumElements:maximumElements:)` (L1285)
  - `GenerationSchema(root:dependencies:) throws` (L1350)
  - `GeneratedContent.value(_:forProperty:)` (L217); `[String]` is Generable (L163)
- `GenerationOptions(sampling: .greedy, temperature:, maximumResponseTokens:)` (L1309–1324).
- `protocol Tool` (L1184) exists, with `name`, `description`, `parameters` and `call(arguments:)`. It is deliberately unused.
- Compiled probe on this Mac (Darwin 25.5.0):
  - `SystemLanguageModel.default.availability == .unavailable(.appleIntelligenceNotEnabled)`
  - `contextSize == 4096`
  - The dynamic `Choice { picks: [Ref anyOf e1,e2,e3] }` schema builds, and its JSON shows `maxItems` and an enum per ref.

- Apple FM bench (2026-10-24, Apple Intelligence on): `respond(to:schema:includeSchemaInPrompt:options:)` must pass `includeSchemaInPrompt: false`. The schema in the prompt adds 600–800 tokens of enum listing and made `.default` return empty lists. Prompts measured 755 tokens median, 1022 max, well inside 4096.

## API facts verified: MLX

- mlx-swift-lm 3.32.3 (latest tag on 2026-10-24) depends on mlx-swift `upToNextMinor(from: "0.32.3")`. Products used: `MLXLLM`, `MLXLMCommon`, `MLXGuidedGeneration`. Tokenizer: swift-transformers 1.3.5 (`Tokenizers`).
- `loadModelContainer(from directory: URL, using tokenizerLoader: any TokenizerLoader) async throws -> ModelContainer` (ModelFactory.swift).
- `GrammarConstraint(tokenizer: GrammarTokenizer, jsonSchema: String, fastForward:hostTokenizer:)` and `GrammarTokenizer(vocab:vocabType:eosTokenId:)`, with the vocab from `TokenizerVocabExtractor.extractForGrammar(from:)`.
- `GuidedGenerationLoop.run(input:context:constraint:maxTokens:vocabSize:…whitespaceBias:whitespaceTokenIDs:…emit:) throws -> Int`. It throws `GuidedGenerationError.incompleteOutput` or `.prematureEOS`.
- `LLMModelFactory` registers `qwen3_5`, the `model_type` of both pinned Qwen3.5 repos.
- mlx-swift README: "SwiftPM (command line) cannot build the Metal shaders so the ultimate build has to be done via Xcode."
- On this Mac: Xcode 26.5; `xcrun metal` fails with "missing Metal Toolchain; use: xcodebuild -downloadComponent MetalToolchain".

## Open questions (user only)

1. **Metal toolchain.** May an agent run `xcodebuild -downloadComponent MetalToolchain` on this Mac (a large one-time Apple download)? The MLX build task needs it.
2. **Keychain under `swift run`.** A build that is not signed with your Apple Development identity can make macOS ask for Keychain access. The app reads the Keychain only after you turn on OpenAI and run an NL search. Is that acceptable?
3. **Login shell.** The key lookup runs your login shell once per launch (`fish -l`), which runs your fish config. Is that acceptable?
