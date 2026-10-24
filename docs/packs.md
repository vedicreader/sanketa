# Writing a Sanketa pack

A pack is one TOML file. It tells Sanketa which keys and tips to show for one program or app. The bundled packs are in `Sanketa.app/Contents/Resources/Packs/`. Put your packs in `~/.config/sanketa/packs/`, one pack in each `.toml` file.

- To open that folder, use Open Packs Folder in the menu-bar menu.
- After you change a file, use Reload Packs.
- The file name has no effect. Give the file the same name as the `id`, so that you can find it easily.

If a file has an error, Sanketa does not load that file. It writes the cause to stderr (`pack error <file>: <message>`) and loads the other files.

You can use this page to write a valid pack. You can also give it to a language model. The test suite loads the example at the end of this page, so the example is correct.

## Schema

Top-level fields:

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `id` | string | yes | A unique name. A user pack with the same `id` as a bundled pack changes it (see "Extend or replace"). |
| `name` | string | yes | The title of the layer. |
| `processes` | array of strings | no, default `[]` | Exact process names that activate the pack, such as `"htop"` or `"nvim"`. |
| `match` | array of strings | no, default `[]` | Text to find in the full command line of the process. Sanketa checks it before `processes`. |
| `apps` | array of strings | no, default `[]` | macOS bundle ids of GUI apps, such as `"com.apple.Safari"`. |
| `prefix` | string | no | A prefix key in tmux notation, such as `"C-b"`. In keys such as `prefix x`, the panel shows this key in place of the word. |
| `mode` | `"extend"` or `"replace"` | no, default `"extend"` | Has an effect only when a user pack has the same `id` as a bundled pack. |
| `keys` | array of tables `[[keys]]` | no | Shortcuts. |
| `tips` | array of tables `[[tips]]` | no | Snippets with a short explanation. |

A pack without `processes`, `match` and `apps` never shows next to a program. But search can still find its entries.

Each `[[keys]]` table:

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `keys` | string | yes | The key or key sequence, written as described under "Key style". |
| `action` | string | yes | What the key does, in six words or fewer. The panel is narrow. |
| `group` | string | no | The heading of the key, such as `"Panes"`. Keys without a group show together. |
| `command` | string | no | tmux: the command that the key runs, to match your live keys. Leela: the action id, to read your keymap. Other packs do not use it. |

Each `[[tips]]` table:

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `title` | string | yes | A short heading. It must be unique in the pack. |
| `snippet` | string | yes | The command or text to type. It must run as written. |
| `explain` | string | no, default `""` | One or two short sentences: what the snippet does, or when to use it. |
| `tags` | array of strings | no, default `[]` | More words for search. |

Sanketa ignores other fields. A file does not load if it has no `id` or `name`. It also does not load if a key has no `keys` or `action`, or a tip has no `title` or `snippet`.

## How Sanketa picks a pack

Sanketa looks at the program in front in your terminal. It also looks at each program between that program and the terminal: the shell, tmux, ssh and the programs in them. Each program is a layer, and each layer gets one pack or none. For the process of a layer, Sanketa tries these steps in this order:

1. `match`: Sanketa looks for the `match` strings of each pack in the command line (argv with spaces between). The first match wins.
2. `processes`: Sanketa compares the process name exactly. This is the name of the program file, such as `nvim` or `python3.12`.
3. `processes` again: Sanketa compares the last part of argv[0], which is the name that you typed. Sanketa removes a `-` at the start, which a login shell adds.

An example for step 3: the Claude Code program file has its version as its name (`~/.local/share/claude/versions/2.1.304`). But argv[0] is `claude`, so `processes = ["claude"]` works.

If two packs match, the pack whose `id` comes first in alphabetical order wins. Thus keep match strings narrow. Use `match` for programs that run in an interpreter. A Python tool shows as `python3.12`, with a command line such as `python3 /Users/you/.local/bin/ramabana --resume`. The match string `"ramabana"` also finds `nvim ~/code/ramabana/cli.py`. The match string `"bin/ramabana"` finds only the installed script.

Use `apps` for GUI apps. When an app other than a terminal is in front, Sanketa reads its menu keys. Then it adds the pack whose `apps` has the bundle id of the app. With `mode = "extend"`, your keys show with the menu keys. A key that you write in the same way as the menu (such as `⇧⌘N`) replaces the menu label. To find the bundle id of an app, use `mdls -name kMDItemCFBundleIdentifier /Applications/Safari.app`.

## Key style

Write keys in Mac symbols. Put the modifiers in the order of the macOS menus: ⌃ (control), ⌥ (option), ⇧ (shift), ⌘ (command). Thus write `⇧⌘P`, not `⌘⇧P`.

| Key | Write |
| --- | --- |
| Return, Delete | `↩` `⌫` |
| Escape, Tab, forward delete | `esc` `tab` `del` |
| Arrows | `↑` `↓` `←` `→` |
| Function keys, paging | `F5` `pgup` `pgdn` `home` `end` |
| Space bar | `space` |
| A letter | as you type it: `a` is a, `A` is shift-a |

The panel shows Escape, Tab and the paging keys as short words, because many people do not know their symbols. It also changes `⎋`, `Esc`, `⇥` and `PgUp` in a pack to these words.

Put a space between the steps of a sequence: `⌃X ⌃E` means control-x, then control-e. Put ` / ` between alternatives: `⌃P / ⌃N`. Write slash commands and typed text as you type them: `/model NAME`, `:wq`.

tmux is different. Write tmux keys in the tmux notation (`prefix %`, `prefix M-Up`, `prefix C-o`). Give each key a `command`, which is the text that `tmux list-keys` shows for it. Sanketa reads your live tmux keys. It puts your label on the key that runs that command now, so a changed key keeps its label. If no key runs the command, Sanketa hides the entry. Sanketa does not read copy-mode keys from tmux, so put those in tips.

Leela is also different. The bundled Leela pack writes keys in the Leela notation (`mod+shift+p`, `hyper+left`) and puts the action id in `command`. Sanketa reads your Leela keymap and shows your keys.

Sanketa also reads `C-x`, `M-x`, `S-x`, `ctrl+x`, `opt+x`, `cmd+x` and `shift+x`, and shows them as symbols. But the bundled packs use the Mac symbols.

## Extend or replace

A user pack with the same `id` as a bundled pack changes the bundled pack.

With `mode = "extend"`, the default:

- Your `name` replaces the bundled name. Your `prefix`, if you set one, replaces the bundled prefix.
- Sanketa adds your `processes`, `match` and `apps` to the bundled lists.
- A key with the same `keys` text as a bundled key replaces it. Sanketa adds other keys at the end.
- A tip with the same `title` as a bundled tip replaces it. Sanketa adds other tips.

With `mode = "replace"`, Sanketa uses only your pack and ignores the bundled pack.

This complete file gives one tmux key a new label and adds one key of your own:

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

The second key shows only if your tmux config binds `|` to that exact command.

## TOML reminders

In a string in double quotes, a backslash starts an escape. Thus write the regex `\d` as `"\\d"`, and a double quote in the string as `\"`. A string in single quotes is literal: `'grep -E "a|b"'` needs no escapes. But it cannot contain a single quote. Use `"""` for a snippet with more than one line. Each `[[keys]]` or `[[tips]]` header starts a new entry. Put the top-level fields before the first entry.

## Worked example: ramabana

ramabana is a coding agent for the terminal. It is a Python script in `~/.local/bin/ramabana`. Its process is the Python interpreter (such as `python3.13`), so the pack uses `match`. The bundled pack has the full list. This example is shorter.

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
explain = "Without a name, --resume lists the sessions of this folder."
tags = ["sessions"]

[[tips]]
title = "One-shot run"
snippet = "ramabana --approve auto 'fix the failing test'"
explain = "Runs one turn and stops. In ask mode, it refuses each write."
tags = ["headless"]

[[tips]]
title = "Pipe a prompt"
snippet = "cat task.md | ramabana - --json"
explain = "Reads the prompt from stdin. --json prints the full result."
tags = ["headless"]
```

To use the example, do these steps:

1. Save it as `~/.config/sanketa/packs/ramabana.toml`.
2. Use Reload Packs.
3. Start ramabana in a terminal.

The bundled pack has the same `id`, and this file does not set `mode = "replace"`. Thus Sanketa adds these entries to the bundled entries. To see only your entries, add `mode = "replace"`.
