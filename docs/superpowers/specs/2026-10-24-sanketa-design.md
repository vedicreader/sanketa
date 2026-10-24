# Sanketa — design

A macOS glass side panel that knows what you're working in, layer by layer, and shows the shortcuts, snippets and better ways for it.

## Intent

The user lives in the terminal (Conterm today, maybe Ghostty or Terminal.app later) running fish, tmux, htop, bash, and their own tools ramabana and leela, plus Word/PowerPoint/Excel. They use a fraction of what these tools can do and want to get genuinely better at them: tmux bindings, htop features, fish/bash scripting (for loops, string handling, data manipulation), grep/awk/find and pipes. Some tools (ramabana, htop) have no good in-app way to discover shortcuts.

Sanketa is a learning companion that sits beside the work. It starts with shortcuts and grows into suggestions.

## Goals

**Phase 1**
1. **Floating glass panel.** Small, translucent (macOS 26 glass material), draggable, stays above other windows, never steals focus. Remembers position and size. Left open while working.
2. **Layered context detection.** Knows the frontmost app, and if that's a terminal, what runs inside it: terminal → shell → tmux → the foreground program in the active tmux pane. Shows the innermost layer first, outer layers below (e.g. htop, then tmux, then fish, then Conterm). Updates as the user switches apps, panes or programs.
3. **Automatic shortcuts for any Mac app.** Read the frontmost app's menu bar via the Accessibility API, including each item's key equivalent. This covers Word, PowerPoint, Excel, Finder, Safari and Conterm/Ghostty/Terminal with no hand-written content.
4. **TOML packs for terminal tools.** One file per tool, with `keys` (bindings) and `tips` (short snippet plus one-line explanation). Bundled packs: tmux, fish, bash, htop, vim, git, grep, awk, find, sed, and common pipe idioms. User packs in `~/.config/sanketa/packs/*.toml` override or extend bundled ones by tool id. The user will have an LLM author packs for ramabana, leela and others, so the format must be simple and documented with an example.
5. **Live tmux bindings.** Read `tmux list-keys` (and the prefix option) so the user's actual config shows, merged over the bundled tmux pack.
6. **Search hotkey.** A global hotkey brings the panel forward with a search box focused. Instant fuzzy search across all entries (current context ranked first). Esc returns focus to the previous app.
7. **Tip cards ("never used").** For the current context, rotate tips and shortcuts the user hasn't marked. Each card has "I know this" (never show again) and "show less". State persists locally.

**Phase 2**
8. **"Better ways" coaching from shell history.** Read fish history (`~/.local/share/fish/fish_history`) and bash history. Rule-based detectors suggest improvements (e.g. `cat f | grep x | wc -l` → `grep -c x f`; `find . -name` → fish globbing `**`; manual loops → `string`/`math` builtins). Shown as cards in the panel, never as notifications.
9. **Natural-language search and suggestions** via Apple's on-device Foundation Models framework, grounded only in loaded entries and recent history. Optional OpenAI fallback using `OPENAI_API_KEY` from the environment, off by default.

## Non-goals

- App Store distribution, sandboxing, notarization for others. It is a personal tool built and run locally.
- Editing shortcuts or remapping keys.
- Syncing across machines.
- Windows/Linux.

## Anti-goals (failure even if it works)

- Stealing focus from the terminal or interrupting typing.
- Noticeable CPU/battery cost. Polling must be cheap (target well under 1% CPU idle).
- Being chatty: no popups, notifications, sounds. Everything lives in the panel.
- Keylogging or input monitoring. The app never observes keystrokes.
- Sending anything off the machine unless the user explicitly enabled the OpenAI fallback.
- Requiring a Python runtime or an LLM for core function.

## Constraints

- macOS 26 (Darwin 25), Apple Silicon.
- Permissions: Accessibility only (menu reading). Nothing else in phase 1.
- Must work regardless of which terminal emulator is used (Conterm, Ghostty, Terminal.app, iTerm2). Terminal detection by a configurable list of bundle ids.
- Shell history reading is approved by the user (phase 2), local only.

## Decided

- **Swift, native macOS app (SwiftUI + AppKit).** Builder's/assistant's call, accepted by the user. Chosen for the native glass material, cheap process inspection and direct access to Foundation Models.
- **TOML** for packs (user was fine with JSON or TOML).
- **Apple Foundation Models** as the LLM, only where needed (phase 2). OpenAI via env var as optional fallback. No ramabana/rishi dependency.
- **Repo:** `~/code/personal/orgs/sanketa`, name is the assistant's call and can be renamed.

## How detection works (assistant's call, builder may refine)

1. `NSWorkspace` frontmost-app notifications give the app and its pid.
2. If the bundle id is in the terminal list, walk the process tree (libproc / `sysctl KERN_PROC`) from the terminal's pid. Find the tty of the focused session. When there are multiple tabs/panes it is ambiguous: prefer the tty whose foreground process group most recently changed, or use the terminal's Accessibility focused element if it exposes a tty/pid. Builder decides the heuristic and documents its limits.
3. Take the foreground process group's program on that tty (`tpgid`). If it is a tmux client, ask the tmux server for the active pane: `tmux display -p '#{pane_current_command} #{pane_pid}'`, then repeat for that pane's process.
4. Map process names to pack ids (`fish`, `bash`, `tmux`, `htop`, `nvim`→`vim`, `python`/`ramabana` etc.). Packs can declare extra process-name aliases.
5. Poll at ~1 s only while a terminal is frontmost, and push changes to the UI only when the layer stack changes.

## Pack format (sketch; builder finalizes and ships a documented example)

```toml
id = "tmux"
name = "tmux"
processes = ["tmux"]          # process names that activate this pack
prefix = "C-b"                # optional, shown as a chip

[[keys]]
keys = "prefix %"
action = "Split pane left/right"
group = "Panes"

[[tips]]
title = "Loop over files"
snippet = "for f in *.log; echo $f; end"
explain = "fish for-loop; no do/done needed"
tags = ["loops", "files"]
```

## Calls settled after review (assistant's calls, user may override)

- **Plan scope: phase 1 only.** Phase 2 gets its own plan later. Phase 1 keeps seams for it: a `Suggestion` card type, a pluggable search backend, and a settings screen with room for an OpenAI toggle.
- **Conterm** is third party (`app.conterm.Conterm`), so it can't be hooked. Investigate what its Accessibility tree exposes for the focused pane.
- **Pack matching uses argv as well as the process name.** ramabana runs as `python3` through a uv shim. `processes` entries can match the executable name or an argv substring, e.g. `match = ["ramabana"]` checked against the full command line.
- **tmux targeting.** Map the focused tty to its tmux client with `tmux list-clients -F '#{client_tty} #{socket_path} #{pane_current_command} #{pane_pid}'` on the default socket, and use `-c <tty>`. Non-default sockets (`-L`/`-S`) and nested tmux are a documented limit for v1. Fall back to "tmux" without the inner layer.
- **Signing.** The user has an Apple developer licence. Sign with their Apple Development identity (Developer ID for release builds) so the Accessibility grant survives rebuilds.

## Remote machines (user wants this)

The user will do GPU work on a local Linux laptop (RTX 3070) over SSH, running tmux, htop (likely nvtop/nvidia-smi too) and their tools there. The panel must show the remote layers, not just `ssh → host`.

Approach (assistant's call, builder may refine):
- **Primary: terminal title signalling.** A small fish/bash snippet installed on the remote host (the `sanketa remote-setup` command prints it or installs it over ssh) sets the terminal title to a tagged form, e.g. `⟦sanketa host=gpubox layers=fish,tmux,htop⟧`. tmux is configured with `set-titles on` so the title passes through tmux. The Mac reads the focused terminal window's title via Accessibility (AXTitle). No daemon, no open ports, nothing extra to keep running. The tag is stripped from what's shown.
- **Fallback: ssh query.** If the title isn't usable in a given terminal, run `ssh -o ControlPath=… host tmux list-clients …` over an existing ControlMaster connection. It only runs when a ControlMaster socket exists, so it never prompts for a password.
- Remote layers are shown with a host chip (e.g. `gpubox`). Packs are the same as local ones. Add bundled packs for `nvtop` and `nvidia-smi` basics.
- This is part of phase 1, as the last milestone after local detection works.

## Look and identity (user's direction)

- **Neat and minimal, with its own style.** It shouldn't be a generic SwiftUI list. The builder proposes a distinct but quiet visual language: typography, key-chip style, one accent colour, and spacing. The glass must stay readable over any background.
- **Logo.** Design a good app icon and logo. Generate candidates with ramabana using the `gpt6-astra` model, show them to the user, and use the chosen one for the app icon (all macOS icon sizes) and the README.

## Left to the builder

- Exact UI layout of the panel (sections per layer, collapsible groups, chips for key combos), within: glass, compact, readable at a glance.
- Fuzzy-search algorithm and ranking details.
- Hotkey default (must not clash with Conterm's ⌘K/⌘⇧A/⌘⇧M or common tmux/fish keys), and making it configurable.
- Where state lives (`~/Library/Application Support/Sanketa`).
- Build tooling (Xcode project vs Swift Package + app bundle script), test approach for detection logic (unit-test the process-tree and pack-merge logic with fixtures).
- Bundled pack content. Must be accurate. Prefer fewer correct entries over many dubious ones.
- Menu-reading cache and refresh policy.
