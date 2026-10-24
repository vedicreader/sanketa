# Writing a Sanketa pack

A pack is one TOML file that tells Sanketa which keys and tips to show for one program or app. Sanketa ships packs in `Sanketa.app/Contents/Resources/Packs/`. Yours go in `~/.config/sanketa/packs/`, one pack per `.toml` file. Use "Open Packs Folder" in the menu bar to get there, and "Reload Packs" after you edit a file. The file name doesn't matter, but naming it after the `id` keeps things findable.

If a file doesn't parse, Sanketa skips that one file, logs the reason to stderr (`pack error <file>: <message>`), and loads the rest.

This page is written so that you, or a language model you hand it to, can produce a valid pack in one go. The worked example at the end is decoded by Sanketa's test suite, so it is known to load.

## Schema

Top-level fields:

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `id` | string | yes | Unique name. A user pack with the same `id` as a bundled one modifies it (see "Extend or replace"). |
| `name` | string | yes | Shown as the layer's title. |
| `processes` | array of strings | no, default `[]` | Exact process names that activate the pack, such as `"htop"` or `"nvim"`. |
| `match` | array of strings | no, default `[]` | Substrings searched for in the process's full command line. Checked before `processes`. |
| `apps` | array of strings | no, default `[]` | macOS bundle ids of GUI apps, such as `"com.apple.Safari"`. |
| `prefix` | string | no | A prefix key in tmux notation, such as `"C-b"`. Keys written as `prefix x` show this key in place of the word. |
| `mode` | `"extend"` or `"replace"` | no, default `"extend"` | Only matters when a user pack shares an `id` with a bundled one. |
| `keys` | array of tables `[[keys]]` | no | Shortcuts. |
| `tips` | array of tables `[[tips]]` | no | Snippets with a one-line explanation. |

A pack with none of `processes`, `match` or `apps` never shows up next to a program, though its entries can still be found in search.

Each `[[keys]]` table:

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `keys` | string | yes | The key or key sequence, written as described under "Key style". |
| `action` | string | yes | What it does, in a few words. Aim for six words or fewer; the panel is narrow. |
| `group` | string | no | Heading the key is listed under, such as `"Panes"`. Keys without a group are listed together. |
| `command` | string | no | tmux only: the exact command the key is bound to, used to match your live bindings. |

Each `[[tips]]` table:

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `title` | string | yes | Short heading. Must be unique within the pack. |
| `snippet` | string | yes | The command or text to type. Keep it runnable as written. |
| `explain` | string | no, default `""` | One line on why it works or when to use it. |
| `tags` | array of strings | no, default `[]` | Extra words for search. |

Any other field is ignored. A missing `id`, `name`, `keys`/`action` in a key, or `title`/`snippet` in a tip makes the whole file fail to load.

## How Sanketa picks a pack

Sanketa watches the program in front in your terminal, and every program between it and the terminal: the shell, tmux, ssh, and whatever runs inside them. Each one is a layer, and each layer gets at most one pack. For a layer's process it tries, in this order:

1. `match`: every pack's `match` strings, searched as plain substrings in the command line (argv joined with spaces). The first hit wins.
2. `processes`: the process name, compared exactly. This is the name of the executable file, such as `nvim` or `python3.12`.
3. `processes` again, against the base name of argv[0], which is what you typed. Claude Code's executable is a file named after its version (`~/.local/share/claude/versions/2.1.304`), but argv[0] is `claude`, so `processes = ["claude"]` still works. A leading `-` from a login shell is dropped.

When two packs could match, the one whose `id` sorts first wins, so keep match strings narrow. `match` exists for programs that run under an interpreter: a Python tool shows up as `python3.12` with a command line like `python3 /Users/you/.local/bin/ramabana --resume`. A match string like `"ramabana"` would also catch `nvim ~/code/ramabana/cli.py`, while `"bin/ramabana"` catches only the installed script.

`apps` is for GUI apps. When a non-terminal app is in front, Sanketa reads its menu shortcuts and merges a pack whose `apps` lists the app's bundle id on top of them. With `mode = "extend"` your keys sit alongside the menu's, and a key written exactly as the menu writes it (such as `⇧⌘N`) replaces the menu's label. To find an app's bundle id, run `mdls -name kMDItemCFBundleIdentifier /Applications/Safari.app`.

## Key style

Write keys in Mac symbols, with modifiers in the order macOS menus use: ⌃ (control), ⌥ (option), ⇧ (shift), ⌘ (command). So `⇧⌘P`, not `⌘⇧P`.

| Key | Write |
| --- | --- |
| Return, Escape, Tab, Delete | `↩` `⎋` `⇥` `⌫` |
| Arrows | `↑` `↓` `←` `→` |
| Function keys, paging | `F5` `PgUp` `PgDn` `Home` `End` |
| Space bar | `Space` |
| A letter | as you type it: `a` is a, `A` is shift-a |

Steps of a sequence are separated by a space: `⌃X ⌃E` means control-x, then control-e. For alternatives, put ` / ` between them: `⌃P / ⌃N`. Slash commands and typed text go in as they are typed: `/model NAME`, `:wq`.

tmux is the exception. Write its keys in tmux's own notation (`prefix %`, `prefix M-Up`, `prefix C-o`) and give each one a `command` equal to what `tmux list-keys` prints for it. Sanketa reads your live bindings and attaches your labels to whatever key is bound to that command now, so a rebind keeps its label. A key whose command isn't bound anymore is hidden. Copy-mode keys aren't read from tmux, so put those in tips.

Sanketa also understands `C-x`, `M-x`, `S-x` and `ctrl+x`, `opt+x`, `cmd+x`, `shift+x` and shows them as symbols, but the bundled packs use the forms above.

## Extend or replace

A user pack whose `id` matches a bundled pack modifies it.

With `mode = "extend"`, the default:

- `name` replaces the bundled name, and `prefix` replaces it if you set one.
- `processes`, `match` and `apps` are added to the bundled lists.
- A key with the same `keys` string as a bundled key replaces it; other keys are added at the end.
- A tip with the same `title` as a bundled tip replaces it; others are added.

With `mode = "replace"`, your pack is used as written and the bundled one is ignored.

To relabel one tmux key and add a binding of your own, this is a complete file:

```toml
id = "tmux"
name = "tmux"

[[keys]]
keys = "prefix %"
action = "Side by side"
group = "Panes"
command = "split-window -h"

[[keys]]
keys = "prefix |"
action = "Side by side, same folder"
group = "Panes"
command = "split-window -h -c \"#{pane_current_path}\""
```

The second key only appears if your tmux config binds `|` to that exact command.

## TOML reminders

Strings in double quotes treat backslash as an escape, so a regex `\d` is written `"\\d"`, and a double quote inside is `\"`. Single-quoted strings are literal: `'grep -E "a|b"'` needs no escaping, but can't contain a single quote. Use `"""` for a snippet spanning lines. Every `[[keys]]` or `[[tips]]` header starts a new entry, and top-level fields must come before the first one.

## Worked example: ramabana

ramabana is a terminal coding agent written in Python, installed as a script at `~/.local/bin/ramabana`. Its process is the Python interpreter (`python3.13` or similar), so the pack activates through `match`. The bundled pack has the full list; this one is shorter.

```toml
id = "ramabana"
name = "ramabana"
processes = ["ramabana", "ramabana-pane"]
match = ["bin/ramabana"]

[[keys]]
keys = "↩"
action = "Send, or steer mid-turn"
group = "Composer"

[[keys]]
keys = "⇧↩"
action = "Queue after this turn"
group = "Composer"

[[keys]]
keys = "⌥↑"
action = "Take queued text back"
group = "Composer"

[[keys]]
keys = "⌃C"
action = "Stop turn, keep composer"
group = "Composer"

[[keys]]
keys = "⇧⇥"
action = "Cycle ask, edits, auto, plan"
group = "Approvals"

[[keys]]
keys = "y"
action = "Approve"
group = "Approvals"

[[keys]]
keys = "n: REASON ↩"
action = "Refuse with a reason"
group = "Approvals"

[[keys]]
keys = "⌃O / ⌥O"
action = "Fold the working / all turns"
group = "Timeline"

[[keys]]
keys = "⌃R"
action = "Browse transcript blocks"
group = "Transcript"

[[keys]]
keys = "/model NAME"
action = "Switch model"
group = "Commands"

[[tips]]
title = "Resume the last session"
snippet = "ramabana --resume latest"
explain = "A bare --resume lists this folder's sessions to pick from"
tags = ["sessions"]

[[tips]]
title = "One-shot run"
snippet = "ramabana --approve auto 'fix the failing test'"
explain = "Runs one turn and exits; in ask mode it would refuse every write"
tags = ["headless"]

[[tips]]
title = "Pipe a prompt"
snippet = "cat task.md | ramabana - --json"
explain = "Reads the prompt from stdin; --json prints the full result"
tags = ["headless"]
```

Save it as `~/.config/sanketa/packs/ramabana.toml`, choose "Reload Packs", and start ramabana in a terminal. Because the bundled pack has the same `id` and this file doesn't say `mode = "replace"`, these entries are merged into the bundled ones; add `mode = "replace"` to see only yours.
