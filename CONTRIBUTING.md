# Contributing to Sanketa

Thank you for your help. This page tells you how to test a change before you send it.

## Before you send a change

Do these three steps:

1. Run `make test`. All tests must pass.
2. Run `make lint`. It checks each bundled pack. It must show no errors and no warnings. To check a pack of your own, run `make lint PACKS=path/to/pack.toml`.
3. If you change the panel, run `make shots SHOTS=/tmp/sanketa-shots`. This draws the panel for some typical stacks of layers to PNG files. Run it on main and on your branch. Then attach the two sets of files to the pull request.

`make test` does not move the focus. It does not show the panel, make a window active or start an app. The tests that do these things are off in `make test`. To run them, use `make test-focus`. Run `make test-focus` only when you do not use the Mac, because these tests take the focus from the app that you use.

`make test` does not draw the shots. They are off by default, because they take time and they write files. The `RenderTests` suite draws them only when `SANKETA_RENDER=1` is set. Without `SHOTS`, the files go to a temporary folder. The test prints the folder.

To check that Sanketa reads the menu keys of the common apps that run now, run `SANKETA_LIVE_APPS=1 make test FILTER=CommonAppsLiveTests`. This test only reads the menus. It does not move the focus.

## Rules for tests

- Write tests that check real behaviour: real files, real processes and real tmux. A test that passes when the feature is broken is not a test.
- Tests must not read or write the files in your `~/.config` folder. Use a temporary folder.
- Each tmux test starts its own server on a private socket and stops it at the end.
- A test that shows a window, makes a window active or starts an app must have the `.focusTest` trait. Then it runs only in `make test-focus`.
- Do not copy, rename or sign a program again so that it looks like a different program.

## Rules for the panel

- The panel must not take the focus from your terminal, except in search.
- When the panel is idle, it must use less than 1 % of the CPU.
- Text must have a contrast of 4.5:1 or more over the glass. The `ContrastTests` suite measures it.
- Saffron shows only as thin bars and ticks. It is never the colour of text.

## Rules for text

Write the text of the panel and the docs in simple English (ASD-STE100). Use short sentences, the active voice and one instruction in each sentence. The `ProseTests` suite checks that the docs are at grade 9 or below.

Write each commit message as one short line, such as `Add yazi pack`.
