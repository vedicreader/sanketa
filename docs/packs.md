# Writing a Sanketa pack

A pack is one TOML file. It tells Sanketa which keys and tips to show for one program or app. The bundled packs are in `Sanketa.app/Contents/Resources/Packs/`. Put your packs in `~/.config/sanketa/packs/`, one pack in each `.toml` file.

- To open that folder, use Open Packs Folder in the menu-bar menu.
- Sanketa loads a pack again when you save it. Reload Packs in the menu does the same.
- The file name has no effect. Give the file the same name as the `id`, so that you can find it easily.

If a file has an error, Sanketa does not load that file. It loads the other files. The footer of the panel shows one line for each bad file, such as "duckdb.toml: key 2 has no action." Click the line to open the file.

## Your first pack

Do these steps to make a pack for a program, for example `duckdb`:

1. Make the file. Start the program in a terminal. The panel says "Sanketa has no keys for duckdb." Click "Make a pack for duckdb". Sanketa writes `~/.config/sanketa/packs/duckdb.toml` and opens it.
2. Add keys. Remove the `#` signs from the example key. Then add one `[[keys]]` table for each key.
3. Save the file. Sanketa loads it at once.
4. Look at the panel. Your keys show when the program is in front.
5. Check the file. Run `Sanketa --lint-pack ~/.config/sanketa/packs/duckdb.toml`. It shows one line for each problem. If it finds an error, it exits with code 1.

If the pack does not show, run `Sanketa --dump-context` with the program in front. It shows each layer and the rule that gave it a pack, such as `via process duckdb`. To try a pack before you put it in the folder, add `--pack FILE`. To see the layers change as you work, add `--watch`.

The `Sanketa` command is in `Sanketa.app/Contents/MacOS/`.

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
| `title_scope` | string | no | A regex on the title of the window in front. Its first group is the scope token that picks a context. See "Contexts". |
| `contexts` | array of tables `[[contexts]]` | no | Views of the app, such as a terminal pane, with their own key groups. |
| `titles` | array of strings | no, default `[]` | Regexes on the window title of a browser. A match shows this pack for the browser. |
| `title_apps` | array of strings | no, default Chrome, Safari and Arc | The bundle ids of the browsers that `titles` applies to. |

A pack without `processes`, `match` and `apps` never shows next to a program. But search can still find its entries.

Each `[[keys]]` table:

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `keys` | string | yes | The key or key sequence, written as described under "Key style". |
| `action` | string | yes | What the key does, in six words or fewer. The panel is narrow. |
| `group` | string | no | The heading of the key, such as `"Panes"`. Keys without a group show together. |
| `command` | string | no | tmux: the command that the key runs, to match your live keys. Leela: the action id, to read your keymap. Other packs do not use it. |
| `context` | string | no | The name of a context. It puts the key in that context, and the `groups` of the contexts have no effect on it. |

Each `[[tips]]` table:

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `title` | string | yes | A short heading. It must be unique in the pack. |
| `snippet` | string | yes | The command or text to type. It must run as written. |
| `explain` | string | no, default `""` | One or two short sentences: what the snippet does, or when to use it. |
| `tags` | array of strings | no, default `[]` | More words for search. |
| `context` | string | no | The name of a context. Without it, a tip is in each context whose name or scope is one of its tags. |

Each `[[contexts]]` table:

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `name` | string | yes | The name. The panel shows it after the layer name, such as `Leela · notebook`. |
| `scopes` | array of strings | no, default `[]` | The scope tokens that select this context. |
| `groups` | array of strings | no, default `[]` | The key groups in this context. A group can be in more than one context. |

Sanketa ignores other fields when it loads a pack, but the lint does not. For a field that it does not know, such as `proccesses`, the lint gives an error and the name that you possibly meant. A file does not load if it has no `id` or `name`. It also does not load if a key has no `keys` or `action`, or a tip has no `title` or `snippet`.

## What the lint checks

`Sanketa --lint-pack` gives an error for:

- A missing field, such as "key 2 has no action".
- A field that it does not know, or a field with the wrong type.
- A key that is not in the key style, such as `Enter` or `C-d`. It tells you what to write: `↩` or `⌃D`. tmux packs (with a `prefix`) and keys with a `command` can use their own notation.
- Two keys with the same `keys` text in one group.
- A `title_scope` or `titles` regex that is not valid. A `title_scope` also needs a group.

It gives a warning for an action of more than six words, two tips with the same title, a short `match` string, and a pack with no way to show. A warning does not change the exit code.

## How Sanketa picks a pack

Sanketa looks at the program in front in your terminal. It also looks at each program between that program and the terminal: the shell, tmux, ssh and the programs in them. Each program is a layer, and each layer gets one pack or none. For the process of a layer, Sanketa tries these steps in this order:

1. `match`: Sanketa looks for the `match` strings of each pack in the command line (argv with spaces between). The first match wins.
2. `processes`: Sanketa compares the process name exactly. This is the name of the program file, such as `nvim` or `python3.12`.
3. `processes` again: Sanketa compares the last part of argv[0], which is the name that you typed. Sanketa removes a `-` at the start, which a login shell adds.

An example for step 3: the Claude Code program file has its version as its name (`~/.local/share/claude/versions/2.1.304`). But argv[0] is `claude`, so `processes = ["claude"]` works.

If two packs match, the pack whose `id` comes first in alphabetical order wins. Thus keep match strings narrow. Use `match` for programs that run in an interpreter. A Python tool shows as `python3.12`, with a command line such as `python3 /Users/you/.local/bin/ramabana --resume`. The match string `"ramabana"` also finds `nvim ~/code/ramabana/cli.py`. The match string `"bin/ramabana"` finds only the installed script.

Use `apps` for GUI apps. When an app other than a terminal is in front, Sanketa reads its menu keys. Then it adds the pack whose `apps` has the bundle id of the app. With `mode = "extend"`, your keys show with the menu keys. A key that you write in the same way as the menu (such as `⇧⌘N`) replaces the menu label. To find the bundle id of an app, use `mdls -name kMDItemCFBundleIdentifier /Applications/Safari.app`.

## Contexts

Some apps have panes or modes, and each one has its own keys. A context tells Sanketa which keys go with which pane. This works only for an app or a terminal, and only when its window title names the pane.

Sanketa reads the title of the window in front. It applies the `title_scope` regex to the title and takes the text of the first group. This text is the scope token. Then Sanketa looks for the first context whose `scopes` has the token. A token with a colon, such as `editor:md`, also matches the scope `editor` when no context has the full token.

When a context is active:

- The breadcrumb and the header of the layer show its name, such as `Leela · notebook`.
- The groups of the context come first and are open. The other groups come after them and are closed. Click a group heading to open or close it.
- Search puts the keys and tips of the context higher.
- The tips of the context come first.

If the title has no token, or no context has the token, the panel shows the pack as it does without contexts.

Leela puts the focused pane at the end of its title, as in `2⚙ (!) · leela — sanketa · notebook`. The bundled Leela pack has this regex, and contexts such as this one:

```toml
id = "leela"
name = "Leela"
title_scope = ' · ([a-z]+(?::[a-z0-9]+)?)(?: [-–] [^·]*)?$'

[[contexts]]
name = "notebook"
scopes = ["notebook"]
groups = ["Notebook: run", "Notebook: cells", "Editing"]
```

The last part of the regex lets a browser add its name after the title, as Chrome does.

### An app in a browser

An app can also run in a browser tab. Use `titles` to find it there. If the browser in front is in `title_apps`, and its window title matches one of the `titles` regexes, Sanketa shows the pack above the menu keys of the browser. The contexts of the pack also work there. A pack whose `apps` has the browser bundle id has priority. Make the `titles` regex match the full title of the app, from `^` to `$`. A short regex such as `leela` also matches a web page about Leela. The bundled Leela pack accepts only the shape of a Leela title, with or without the ` - Google Chrome – <profile>` part that Chrome adds.

In a normal Chrome tab, Chrome keeps some keys for itself, such as ⌘T, ⌘W and ⌘1 to ⌘9. Leela also uses some of these keys, but in a tab they go to Chrome. The panel shows the Leela key all the same. Use Leela.app or `leela --app` to get all the Leela keys.

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

The panel shows Escape, Tab and the paging keys as short words, because many people do not know their symbols. It also changes `⎋`, `Esc`, `⇥` and `PgUp` in a pack to these words. But the lint asks for the words.

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
keys = "⇧tab"
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

1. Save it as `~/.config/sanketa/packs/ramabana.toml`. Sanketa loads it at once.
2. Start ramabana in a terminal.

The bundled pack has the same `id`, and this file does not set `mode = "replace"`. Thus Sanketa adds these entries to the bundled entries. To see only your entries, add `mode = "replace"`.
