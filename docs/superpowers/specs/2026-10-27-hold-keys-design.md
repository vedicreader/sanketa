# Hold a combo to see its keys, and change keys from Sanketa

Date: 27 October 2026. Status: design, approved by the user in conversation. The mockup of the chosen panel is in
`.superpowers/brainstorm/80466-1793072259/content/hold-combined.html` (design E).

## Why

The user moves tiles and sends them between workspaces with AeroSpace many times a day. AeroSpace has about 74 bindings in four
modes, and three different ways to send a tile to a workspace. The user forgets which is which. The user also uses apps with their own
Hyper (Caps) keys, such as leela. Today nothing shows the AeroSpace keys. Nothing shows when an app key clashes with AeroSpace, which
takes its keys before any app sees them. Leela's default keymap has ten Caps keys that AeroSpace takes. The user found and moved each of
them by hand, to ⌥ keys in `keys.json`. The live keymap has no clash today; this feature makes the next clash visible at once.

The user wants three things:

1. See the keys of a modifier combo at the moment of need: hold Caps, see what Caps does here.
2. See clashes, and fix them.
3. Change a key of the app in front from Sanketa, with suggestions of free keys that sit near the keys the user already uses, so the
   hand moves little.

## Goals

- Hold a modifier combo (Caps/Hyper, or any other combo such as ⌥⌃) for about 0.4 s: Sanketa's panel shows the keys that start with
  that combo. It hides when the user lets go.
- Two columns in the one Sanketa panel (design E): AeroSpace at the left, the app in front at the right.
- Mark each key of the app that AeroSpace (a global binding) takes: struck through, with "· AeroSpace".
- A line with the free keys of the combo.
- Change a key: pick a suggestion or press a new chord. Sanketa writes the change, keeps a backup, offers Undo, and makes the app reload.
- Suggest free keys by rules (below). No model is needed for this.

## Non-goals

- Resize keys get no special care. The user rarely resizes. They show last and muted.
- No model in the first stages. A model may later group actions that a pack does not group; that is out of scope here.
- No change of keys for apps that keep keys only inside themselves (many web and Electron apps). Those keys show read-only.
- No Windows or Linux.

## Anti-goals (a failure even if it works)

- Sanketa sees what the user types. It must see modifier state only, never letters. The README promise "It does not monitor input,
  and it does not record keystrokes" changes only to say that Sanketa sees which modifier keys are held.
- The panel flashes during fast normal use. A quick Caps+arrow must never show it.
- The panel takes keyboard focus from the app, so the held combo goes to Sanketa or the app loses its state.
- A key change that breaks a config file, or that cannot be undone.
- Two floating windows that fight over which is on top. The user chose one panel for this reason.

## Constraints

- macOS 26, Apple Silicon. Sanketa has the Accessibility permission and no other permission; this feature adds none.
- Modifier state comes from the "flags changed" event (`NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)`), or from
  `CGEventSource.flagsState`. Both give modifier flags only. Caps sends Hyper (⌃⌥⇧⌘) on the user's Mac; AeroSpace owns Hyper.
- Look: Sanketa's style. Muted, no boxes, pills or cards, large plain keys (about 15 pt semibold mono) in Mac symbols, contrast of
  4.5:1 or more, no accent-colored text.
- All text in ASD-STE100 Simplified Technical English, US grade 9.
- The user prefers two-key chords on left-hand keys.
- Tests never take window focus and never launch the app.

## Sources of keys

- AeroSpace: `~/.aerospace.toml`, or `$XDG_CONFIG_HOME/aerospace/aerospace.toml` (AeroSpace's own order). Read `[mode.<name>.binding]`
  tables. A binding is `<chord> = '<command>'` or a list of commands. AeroSpace chord names (`cmd-alt-ctrl-shift-h`, `leftSquareBracket`,
  `backtick`, `minus`) map to Sanketa's key style. Name each command in plain words (`move left` -> "Move the tile left",
  `move-node-to-workspace --focus-follows-window 3` -> "Send the tile to 3 and follow"). A long `exec-and-forget` command shows as
  "Run a script". Watch the file and read it again on save, as Sanketa does for packs. Without the file, there is no AeroSpace column.
- The current AeroSpace mode: `main` by default. Builder's choice how to learn the mode (for example `aerospace list-modes --current`
  when the combo is held, cached for a short time). In a mode other than `main`, the left column shows that mode's keys.
- The app in front: its pack keys (bundled and user packs), Leela's keymap overlay (`~/.config/leela/keys.json`, which Sanketa reads
  already), and the menu keys that Sanketa reads through Accessibility.

## The panel (design E)

- One Sanketa panel at its usual place. Left column: "AeroSpace · <combo>". Right column: "<app> · <combo>".
- Left column order: move the tile, focus, workspaces, send to a workspace, layout, then resize muted and last.
- Right column: the app's keys for the combo. Clashing keys at the end of the column, struck through, with "· AeroSpace".
- Last line: "Free <combo> keys: …", over the keys that no source uses for this combo.
- Show after the combo is held for about 0.4 s with no other key. Hide when the combo is let go, unless the panel is pinned (below).
- "No other key" without seeing letters: at the end of the delay, read `CGEventSource.secondsSinceLastEventType(.combinedSessionState,
  eventType: .keyDown)`. It gives only the time since the last key press, never the key. If a key went down after the combo started,
  the user is working (for example, moving tiles with Caps+arrows), so the panel does not show until the combo is let go and held again.
- The panel never takes keyboard focus while it shows.
- If the app has no keys for the combo, the right column says so in one muted line. If there is no AeroSpace, there is one column.

## Decisions from the design review (main session's calls; the user can change them)

1. The hold swaps the content of Sanketa's panel for the combo view, and the layer view comes back when the combo is let go. If the
   panel was hidden, the hold shows it and hides it again. No hold starts while a search runs or the panel has keyboard focus.
2. Only combos of two or more modifiers start a hold (Caps/Hyper counts). One modifier alone (⌘, ⇧, ⌥ or ⌃) never does. A mouse
   click or scroll during the delay cancels the hold (`secondsSinceLastEventType` for mouse-down and scroll-wheel events, as for keys).
   A setting turns the hold off, or limits it to Caps: Off, Caps only, All combos. The default is All combos.
3. The panel lists the chords of the exact combo that is held. Below the AeroSpace column, an "Also" line lists other combos that run
   the same kind of AeroSpace command, for example under Caps: "Send to a workspace also: ⌥⌃⇧ 1–9 (stay), ⌥⌃ 1–9 (follow)". This shows
   the user's three ways to send a tile from any one of them.
4. AeroSpace modes other than `main` have keys with no modifier. When AeroSpace enters such a mode, the panel shows that mode's keys by
   itself, until the mode ends. The builder chooses the trigger (an AeroSpace callback if there is one; else a cheap check), and must not
   start a process for each modifier change.
5. In a terminal, the right column is Sanketa's stack of layers (the program in front, tmux, the shell, the terminal's menu keys). Each
   key shows its layer when more than one layer has keys for the combo. Clashes and free keys use all of these layers.
6. Leela: the panel uses the live keymap only. A default chord that the user moved away is not shown.
7. The user can change AeroSpace keys too. A row that groups bindings ("1 – 9 Workspace") opens its bindings, and the user picks one.
   For a struck-through app key, Sanketa changes the app's key by default, with a second choice to change AeroSpace's key instead.
8. A suggested free chord for an AeroSpace key is checked against AeroSpace and every pack, keymap and menu that Sanketa knows. The
   panel says that apps with no pack are not checked.
9. The first plan covers stages 1 and 2. Stage 3 gets its own design, with the writers, backups and reloads for each format.

## Clash rules

- A global binding (AeroSpace in its current mode) wins over an app binding with the same chord. The app binding is struck through.
- Two keys in the same app with the same chord: both show, marked as a clash in the app.
- A chord that a macOS system shortcut uses is a clash only if Sanketa can read it; else it is ignored. Builder's choice.

## Changing a key

To change keys, the panel must stay open after the user lets go. Main session's call: while the panel shows, a click on it pins it.
A pinned panel takes clicks, stays until Esc or a click outside, and still does not take focus from the app until the user starts to
edit a key. The menu-bar menu also gets "Your Keys…", which opens the same view pinned, for the app that was in front.

Steps:

1. The user clicks a key (struck through or not).
2. Sanketa shows up to three suggested free chords, each with its reason, and "Press a new chord". Recording a chord here is the one
   time Sanketa reads a key press, and only inside its own focused field.
3. Sanketa shows the change (old chord, new chord, file) and asks before it writes.
4. It writes the change, keeps a backup next to the file (`<file>.sanketa-bak`), and shows Undo in a toast.
5. It makes the app reload: Leela reads `keys.json` again by itself; for AeroSpace, run `aerospace reload-config`.

Writers must keep the rest of the file as it is: comments, order and formatting.

- Leela `keys.json` has three top-level parts: `_help`, `_defaults` (Leela writes it and never reads it) and `keys` (the user's
  overrides, which Leela reads). The live keymap is `_defaults` with `keys` over it. Always write into `keys`, never `_defaults`. If the
  action is not in `keys`, add it there with the full value from the live keymap, and change only the chord that the user picked. A value
  can hold alternatives separated by spaces ("hyper+z alt+shift+b").
- `~/.aerospace.toml`: change the chord on the left side of the one binding line, in the table of its mode. Keep the command text as it
  is, including multi-line strings.

## Suggesting free keys

Score each free chord and offer the best three. A chord is free when it is not used by AeroSpace (current mode and main), not by the
app's other keys, and not by a menu item of the app.

Rules, in order of weight:

1. Same family: the same modifiers as the action's current chord, or as its group's other keys.
2. Near its partners: small distance on the keyboard to the keys of the other actions in the same group (pack group, or AeroSpace's
   kind of command). Use a simple key-position map of the ANSI layout; distance is between key centers.
3. Left hand first: keys on the left half score higher.
4. Easy to remember: a bonus when the key is the first letter of a word of the action.

Each suggestion shows its reason in words, for example "Caps Y: free, next to your Caps T and Caps U".

## Stages

1. Hold to show: the flags monitor, the AeroSpace reader and its plain names, design E, clash marks, the free-keys line.
2. Change a key: the pinned panel, "Your Keys…", suggestions, chord recording, the Leela and AeroSpace writers, backup, Undo, reload.
3. More apps: menu shortcuts of any Mac app through macOS App Shortcuts (`defaults write <bundle id> NSUserKeyEquivalents`; the app
   must restart, and Sanketa says so), then tmux, VS Code and Zed key files.

## Left to the builder

- How to learn the current AeroSpace mode.
- The exact delay (about 0.4 s).
- The plain names for AeroSpace commands beyond the common ones listed.
- Whether system shortcuts count as clashes (stage 1 may skip them).
- Test design, within the repo's rules (no focus, no launch, fakes over real files).
