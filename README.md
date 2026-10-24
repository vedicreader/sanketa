<img src="design/logo/sanketa-icon.png" width="128" alt="Sanketa kolam logo">

# Sanketa

[![build](https://github.com/vedicreader/sanketa/actions/workflows/build.yml/badge.svg)](https://github.com/vedicreader/sanketa/actions/workflows/build.yml)

Sanketa is a small macOS menu-bar app. The name is Sanskrit for "hint" or "signal". It shows a floating glass panel with the keys and tips for the program that you use now.

In a terminal, Sanketa finds each program in the stack. The stack starts at the terminal app and goes through the shell and tmux to the program in front. Each program is a layer, and each layer gets its own section in the panel. For example, if you run htop in tmux in fish, the panel shows the htop keys first. Then it shows your live tmux keys and the fish tips. Sanketa also follows you over ssh when you set up the remote host. Outside a terminal, the panel shows the menu keys of the app in front.

The panel does not take the keyboard focus from your terminal. It takes the focus only when you start a search.

Sanketa needs macOS 26 on Apple Silicon. It needs the Accessibility permission and no other permission. It does not monitor input, it does not record keystrokes, and it does not use the network.

## Download

Get the latest zip from [the releases page](https://github.com/vedicreader/sanketa/releases/latest). Then do these steps:

1. Unzip `Sanketa-<version>.zip`.
2. Move `Sanketa.app` to Applications.
3. Open Sanketa.
4. If macOS blocks it, right-click `Sanketa.app` and select Open. If macOS still blocks it, go to System Settings, then Privacy & Security, and click Open Anyway.
5. Allow Accessibility. The next section gives the steps.

A release that is not notarized says so in its notes. macOS blocks such a release at the first start.

## Build from source

```sh
make app install
```

- `make app` builds the app in `build/Sanketa.app`. It signs only that bundle with your Apple Development identity.
- `make install` moves an old copy in `~/Applications` to `/tmp/sanketa-trash`. Then it copies the new bundle to `~/Applications`.
- To use a different identity, add `SIGN_ID="Apple Development: Your Name (TEAMID)"`.
- To start the app, open it from `~/Applications`, or use `make run`.

## First start

Sanketa asks for Accessibility when it starts. Follow these steps:

1. Open System Settings.
2. Go to Privacy & Security, then Accessibility.
3. Turn on Sanketa.

Without Accessibility, the panel still works in terminals. But it cannot read window titles or the menus of other apps. Until you allow it, the footer shows "Allow Accessibility to show menu keys". The menu-bar menu has the same item, "Allow Accessibility…".

The bundle has a stable Apple Development signature. Thus macOS keeps the permission when you build the app again.

## Use the panel

The panel floats above other windows. You can move it and change its size. It keeps its position and size.

The menu-bar icon is a command-key symbol. Its menu has these items:

- Show or Hide Panel
- Search (with the hotkey)
- Translucency: Low, Medium or High
- Reload Packs
- Open Packs Folder
- Open Config
- Allow Accessibility…
- Quit Sanketa

### Search

The hotkey is Control-Option-K (⌃⌥K). It shows the panel and starts a search. Type a word to find a key or tip in all packs. Results from the current layers come first.

- Press ↑ or ↓ to move the selection.
- Press Return to copy the selected key or snippet.
- Press Esc to give the focus back to your terminal.
- Press Tab to go to the layer list. The search text stays.
- In the layer list, press Tab, Shift-Tab, ↑ or ↓ to go to the next or previous section.

### Layers and sections

The breadcrumb at the top lists the layers, the innermost first, for example `htop › tmux › fish › Kaku`. Click a layer to go to its section. When you click the panel outside a search, the focus goes back to the app that you used.

When the innermost layer has keys, its section comes first and is open. When you go to a different program, the panel goes back to the top. Thus the keys of the new program are always in view.

If a program has no pack, its section shows one line: "No keys for yazi. Add a pack in ~/.config/sanketa/packs."

### Tip cards

The panel shows three tip cards. Each card shows one key or one snippet from the current packs. The first card comes from the innermost layer that has keys or tips. The cards come after the innermost section when that layer has keys. Otherwise they are at the top. The cards change every two minutes.

- "I know this" removes a card for good.
- "Show less" makes a card come back less often.

## Settings

The settings file is `~/.config/sanketa/config.toml`. Open Config makes the file with the default values in comments. These are the settings:

```toml
hotkey = "ctrl+opt+k"        # modifiers: ctrl, opt (or alt), shift, cmd; then one key
terminals = ["app.conterm.Conterm", "com.mitchellh.ghostty", "com.apple.Terminal",
             "com.googlecode.iterm2", "fun.tw93.kaku"]   # bundle ids that are terminals
pollInterval = 1.0           # seconds between checks while a terminal is in front (0.25 or more)
tipRotateSeconds = 120       # how often the tip cards change
translucency = "medium"      # low, medium or high
hyper_label = "Caps"         # how Leela's Hyper key (⌃⌥⇧⌘) shows
```

The hotkey can be a letter, a digit, F1 to F12, `space`, `/`, `.` or `,` with modifiers. An example is `hotkey = "cmd+shift+space"`. Restart Sanketa after you change the hotkey. If another app uses the same keys, the footer tells you.

You can also set the translucency in the menu-bar menu. The change shows at once, and Sanketa writes only that line to the file. If the file has an error, Sanketa uses the default values.

## Terminals

Use Kaku or Ghostty. A terminal window can have many tabs, and each tab has its own shell. Sanketa must find the tab in front. Kaku and Ghostty put the program of the front tab in the window title. Thus Sanketa can find the correct tab and show the full stack.

Kaku also adds a tab number such as `[2/3]` to the title. Sanketa counts the tabs in the order that you opened them. If you move a tab to a different position, Sanketa can show the wrong tab. This is the one case where Sanketa guesses.

Terminal.app and iTerm2 also work. They work with one tab for each window, or when the title shows the program. Conterm and other terminals with many tabs give no signal for the front tab. For these, Sanketa shows only the shell and the terminal. It does not guess the tab, because a wrong guess shows keys for a program that you do not use.

To add a terminal, put its bundle id in `terminals`. To find the bundle id, use `mdls -name kMDItemCFBundleIdentifier /Applications/Foo.app`.

## Packs

A pack is a TOML file with the keys and tips for one program or app. These packs come with the app:

- Tools: awk, find, git, grep, htop, lazygit, nvidia-smi, nvtop, sed, shell pipes, vim and yazi.
- Shells and tmux: bash, fish and tmux.
- Apps and agents: Claude Code, Conterm, Leela and ramabana.

Put your own packs in `~/.config/sanketa/packs/`, one pack in each file. A pack with the same `id` as a bundled pack adds to it. To replace the bundled pack, set `mode = "replace"`. After you change a pack, use Reload Packs. If a file has an error, Sanketa does not load it. The footer shows the number of these files. Point to the number to see the file names.

[docs/packs.md](docs/packs.md) gives the full format, the key notation and an example. You can give that page to a language model, and it can write a valid pack.

### Leela

The Leela pack holds the default keys of Leela. Sanketa reads your Leela keymap, `~/.config/leela/keys.json`, when it loads the packs. If you set `$LEELA_KEYMAP`, Sanketa reads that file.

- A key in `keys` replaces the default.
- An empty key hides the action.
- Two or more keys with spaces between them show as alternatives.
- Hyper (⌃⌥⇧⌘) shows as "Caps" and the key, for example `Caps E`. Caps Lock sends Hyper on the author's Mac. To change the word, set `hyper_label`.

When Leela changes `keys.json`, the panel reads the file again.

## Remote hosts

When you use ssh, Sanketa sees only the local `ssh` process. To see the layers on the remote host, run this command one time for each host:

```sh
make remote-setup HOST=me@gpubox
```

The command copies three small scripts to `~/.config/sanketa/remote/` on the host. Then it connects them:

- fish: `~/.config/fish/conf.d/sanketa.fish`
- bash: a line in `~/.bashrc` that loads `sanketa.bash`
- tmux: a line in `~/.tmux.conf` that loads `tmux.conf`

Each script puts a short tag in the terminal title. The tag gives the host and the programs that run there. The tmux script sends the title through to your terminal. Sanketa reads the tag and shows the remote layers. The breadcrumb then looks like `htop@gpubox › tmux@gpubox › fish@gpubox › ssh gpubox › fish › Kaku`.

If you run the setup again, it does not change the parts that are already there. After the setup, open a new shell. In a tmux that runs already, run `tmux source-file ~/.tmux.conf`.

The fish script wraps the `fish_title` function that exists when it loads. fish reads `conf.d` before `config.fish`. Thus a `fish_title` in `config.fish` replaces the script's function, and the tag goes away. To prevent this, move your `fish_title` to `~/.config/fish/functions/fish_title.fish`.

The bash script keeps a DEBUG trap that exists and runs it first. If you use bash-preexec, the script uses it too.

Some hosts have no script. If you connect to such a host through an ssh ControlMaster, Sanketa asks the tmux on the host for the current program. It uses the open connection in batch mode, so it never asks for a password. If no master connection is open, it does nothing. For this, set `ControlMaster` and `ControlPath` for the host in `~/.ssh/config`.

## Limits

- Sanketa reads only the default tmux server. A session on a socket from `-L` or `-S` shows as an empty tmux layer. tmux in tmux shows the same way.
- In a terminal with many tabs and no signal for the front tab, Sanketa shows only the shell and the terminal.
- Kaku tab numbers assume that you did not move the tabs.
- Some iTerm2 sessions run under a separate `iTermServer` process. For these, Sanketa can show only the app layer.
- Remote layers need the title script on the host, or a ControlMaster connection.
- Idle CPU is low but not zero while a terminal is in front, because Sanketa reads the process table at each check.

## Development

```sh
make test        # swift test
make app         # build and sign build/Sanketa.app
make verify      # check the bundle and its signature
make release     # sign with Developer ID and make dist/Sanketa-<version>.zip
make gatekeeper  # ask Gatekeeper if it accepts the bundle
```

### Releases

`make release` signs the bundle with your Developer ID Application identity and a secure timestamp. Then it makes a zip in `dist/`. If it finds notary credentials, it sends the zip to Apple and waits. When Apple accepts the zip, it staples the ticket to the bundle and makes the zip again. If Apple rejects the zip, it shows the issues from the notary log.

`scripts/notarize.sh` uses the first credentials that it finds:

1. The file `~/.config/sanketa/notary.json`. To use a different file, set `NOTARY_CONFIG`.
2. The variables `NOTARY_KEY_PATH`, `NOTARY_KEY_ID` and `NOTARY_ISSUER`.
3. The variable `NOTARY_PROFILE`, the name of a notarytool keychain profile.

The file holds an App Store Connect API key:

```json
{"key_id": "ABC123DEFG", "issuer_id": "00000000-0000-0000-0000-000000000000", "key_path": "~/.config/sanketa/AuthKey.p8"}
```

The key must have the Developer role or the Admin role. Keep the .p8 file out of the repo. To use a keychain profile, store it one time:

```sh
xcrun notarytool store-credentials sanketa-notary --apple-id <id> --team-id <team id>
make release NOTARY_PROFILE=sanketa-notary
```

Without credentials, the zip has a signature, but Gatekeeper rejects it. After notarization, `make gatekeeper` shows "accepted, source=Notarized Developer ID".

The GitHub Actions job builds and tests each push to main and each pull request. It uploads an ad-hoc bundle as `Sanketa-<sha>.zip`. When you push a tag such as `v0.1.0`, it attaches a zip to a GitHub release. To sign and notarize that zip, add these repository secrets:

- `MACOS_CERT_P12_BASE64`: your Developer ID Application certificate and its private key, exported as a .p12 file, in base64.
- `MACOS_CERT_PASSWORD`: the password of the .p12 file.
- `NOTARY_KEY_ID`: the key id of an App Store Connect API key.
- `NOTARY_ISSUER_ID`: the issuer id of that key.
- `NOTARY_KEY_P8_BASE64`: the .p8 file of that key, in base64.

To make the base64 text, use `base64 -i file.p12 | pbcopy`. If a secret is missing, the job attaches an ad-hoc zip, and the release notes say "Not notarized".

The code has three libraries and the app:

- `SanketaCore` has the logic: packs, settings and layers.
- `SanketaSystem` reads processes, tmux, Accessibility and ssh.
- `SanketaUI` draws the panel.
- `Sources/Sanketa` is the app.

The tests use real files, real child processes, real fish and bash, and real tmux. These rules keep the tests safe:

- Each tmux test starts its own server on a private socket, `tmux -L sanketa-test-<pid>-<n>`. The test stops that server at the end. Tests never use your default tmux server or a session that they did not make.
- Tests start only real programs that nobody changed. Do not copy or rename a program so that it looks like a different program. Do not change argv[0]. Do not sign a program again. If a test needs a process tree that it cannot make honestly, describe the tree as `ProcInfo` data.
- Each external command goes through `CommandRunning` with a timeout.
- Do not write tests that only check the shape of the code. A test that passes when the feature is broken is not a test.
