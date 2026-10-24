# Sanketa phase 2: design addendum

Covers spec goals 8 ("better ways" coaching from shell history) and 9 (natural-language search and suggestions). It adds to `docs/superpowers/specs/2026-10-24-sanketa-design.md` and builds on the phase 1 plan's interfaces. Plan: `2026-10-24-sanketa-phase2.md` (same folder).

## Decisions

**Coaching is rules only, no model.** It uses a small shell lexer (quotes, escapes, `;`/`&&`/`||`, pipes, fish `(…)`, `$(…)`, backticks, comments) and 13 detectors run in a fixed precedence order. Each command gets at most one rewrite. A detector fires only when its rewrite is safe: multi-file grep, `sort -n`/`-k`, `ls DIR`, `cut` on multi-line input and similar cases are rejected. Every positive example is also run in real fish or bash over a fixture directory, and its output must match the original's output.

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

I checked these against fish 4.8.1 in /tmp:
- `**.py` skips hidden directories, and the explain text says so.
- `math -s0` truncates like `expr` does.
- `string split -f2` stops at the first line that lacks the delimiter, so `string-split` only rewrites `echo $VAR | cut`.
- macOS `pgrep -fl` prints the pid and the full argv.

**Cards, not notifications.** Coaching results become `SearchItem`s with `kind: .suggestion` and `packID "coach"`. One "Better way" card shows when the context has a shell layer, and coaching items are also searchable. "I know this" silences a detector, because the item id is per detector.

**History is read locally and cheaply.**
- fish: `~/.local/share/fish/fish_history`. The format is `- cmd: …` and `  when: <epoch>`, plus optional `  paths:` / `    - …` and `  added_when: …` lines. In `cmd`, `\\` stands for a backslash and `\n` for a newline. I confirmed this by having real fish write a temporary history with `history append`/`history save`.
- bash: `~/.bash_history`. Plain lines, with optional `#<epoch>` lines when HISTTIMEFORMAT is set.
- Only the last 4 MB of each file is read, capped at 5000 entries.
- Each file is checked with `stat` every 60 s. It is re-analysed only when the mtime or size changes. fish rewrites the file by rename, so `stat` is more reliable than an fd watcher.

**NL search is retrieval first, then the model chooses.**
1. Local loose retrieval: stopwords removed, light stemming, any-term scoring, context packs boosted. It returns up to 40 candidates.
2. The candidates go into a numbered list (`e1 | pack | title | detail`).
3. The model returns up to 5 refs. Guided generation (`DynamicGenerationSchema(anyOf: refs)`) means it cannot emit anything else.
4. `Grounding.resolve` checks the refs again and maps them back to the loaded items. The model never writes text that the user sees.

No tool calling: retrieval is done before the call, which keeps the token count down and makes the grounding easy to verify.

Other rules for model calls:
- The model is only called when the query has at least 3 words, 600 ms after typing stops. Results from plain search show instantly while the model works.
- Each call uses a fresh `LanguageModelSession` with greedy sampling and `maximumResponseTokens: 64`, and has a 5 s timeout.
- If the context window is exceeded, the call is retried once with half the candidates.

**Model suggestions are on-device only.** The model looks at the last 10 commands for the current shell and picks up to 2 existing tips or keys from the packs those commands map to. They show in the Better-way card pool. This runs at most once every 600 s, only after history changes. It never goes to OpenAI.

**Degrading.** With no usable chooser, search is plain local search. One muted footer line appears only in search mode, for example "Plain search: Apple Intelligence is off". There are no popups and no retries.

**OpenAI fallback.** Settings:
- `[llm] openai = false` by default.
- It is used only for NL search, only when on-device is off or unavailable.
- The key comes from `OPENAI_API_KEY` in the process environment. If it is missing there, Sanketa runs the user's login shell once (`$SHELL -l -c 'printf %s "$OPENAI_API_KEY"'`, 3 s timeout). A Finder-launched app does not inherit fish's environment.

**Exactly what leaves the machine when `openai = true`.** One HTTPS POST to `https://api.openai.com/v1/chat/completions` per NL query, carrying:
- the model name
- the fixed instruction text
- `Request: <query text>`
- up to 40 candidate lines, each `ref | pack name | entry title | keys or snippet`, from TOML packs and live tmux keys only
- `"store": false`
- the bearer key

Never sent:
- shell history
- coaching results
- window titles
- layer or process names
- menu-derived entries (`app:` packs), because menus can contain window and document names

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

## Open questions (user only)

1. **Apple Intelligence is off on this Mac.** Until it is turned on in System Settings, the on-device path and its live tests are skipped, and NL search falls back to plain search (or OpenAI if enabled). Will you turn it on?
2. **OpenAI model and key lookup.** The default model is `gpt-4.1-mini`; is that right, or should it be another one? Is it OK to run your login shell once to read `OPENAI_API_KEY` when the app was launched from Finder? The alternative is to require `launchctl setenv OPENAI_API_KEY …`.
