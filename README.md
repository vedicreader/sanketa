<img src="design/logo/sanketa-icon.png" width="128" alt="Sanketa kolam logo">

# Sanketa

[![Download for macOS](https://img.shields.io/badge/Download_for_macOS-Sanketa.zip-0A84FF?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/vedicreader/sanketa/releases/latest/download/Sanketa.zip) [All releases](https://github.com/vedicreader/sanketa/releases)

[![build](https://github.com/vedicreader/sanketa/actions/workflows/build.yml/badge.svg)](https://github.com/vedicreader/sanketa/actions/workflows/build.yml)

Sanketa is a small macOS menu-bar app. The name is Sanskrit for "hint" or "signal". It shows a floating glass panel with the keys and tips for the program that you use now.

In a terminal, Sanketa finds each program in the stack. The stack starts at the terminal app and goes through the shell and tmux to the program in front. Each program is a layer, and each layer gets its own section in the panel. For example, if you run htop in tmux in fish, the panel shows the htop keys first. Then it shows your live tmux keys and the fish tips. Sanketa also follows you over ssh when you set up the remote host. Outside a terminal, the panel shows the menu keys of the app in front.

The panel does not take the keyboard focus from your terminal. It takes the focus only when you start a search.

Sanketa needs macOS 26 on Apple Silicon. It needs the Accessibility permission and no other permission. It does not monitor input, and it does not record keystrokes. It uses the network only if you turn on OpenAI search or download the on-device model.

## Download

Click the Download for macOS button at the top, or get [the latest zip](https://github.com/vedicreader/sanketa/releases/latest/download/Sanketa.zip). Then do these steps:

1. Unzip `Sanketa.zip`.
2. Move `Sanketa.app` to Applications.
3. Open Sanketa.
4. If macOS blocks it, right-click `Sanketa.app` and select Open. If macOS still blocks it, go to System Settings, then Privacy & Security, and click Open Anyway.
5. Allow Accessibility. The next section gives the steps.

Each release has a Developer ID signature, and Apple notarized it.

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
- OpenAI Model: the model for OpenAI search
- OpenAI Key…: save an API key for the server in your Keychain
- On-Device Model: download or remove the on-device model
- Reload Packs
- Open Packs Folder
- Open Config
- Allow Accessibility…
- Copy Debug Info
- Quit Sanketa

Copy Debug Info copies a short report for a bug report. It has the version, the app in front, the layers, the packs and the Accessibility state. It also tells which models are on, and if Sanketa found an API key. It has no file contents, and it never has the key.

### Search

The hotkey is Control-Option-K (⌃⌥K). It shows the panel and starts a search. Type a word to find a key or tip in all packs. Results from the current layers come first.

- Press ↑ or ↓ to move the selection.
- Press Return to copy the selected key or snippet.
- Press Esc to give the focus back to your terminal.
- Press Tab to go to the layer list. The search text stays.
- In the layer list, press Tab, Shift-Tab, ↑ or ↓ to go to the next or previous section.

### Layers and sections

The breadcrumb at the top lists the layers, the innermost first, for example `htop › tmux › fish › Kaku`. Click a layer to go to its section. When you click the panel outside a search, the focus goes back to the app that you used.

The panel is an index of the layers. When the innermost layer has keys, its section comes first and is open. It shows the keys of its first two groups. Each other section shows the keys of its first group. The other groups show as one line with a count, such as `› View 10`. Click the line to open the group. A group with two keys or fewer is always open.

When you go to a different program, the panel goes back to the top. If you go back to a stack of layers that you used a short time ago, the panel shows it as you left it. It keeps the groups that you opened and the scroll position. It remembers the last eight stacks.

If a program has no pack, its section says "Sanketa has no keys for yazi." Click "Make a pack for yazi" to make a first pack. Sanketa writes `~/.config/sanketa/packs/yazi.toml` and opens it.

### Tip cards

The panel shows one tip card. It shows one key or one snippet from the current packs. The card comes from the innermost layer that has keys or tips. It comes after the innermost section when that layer has keys. Otherwise it is at the top. The card changes every two minutes. It stays when you change panes, while its pack is in the stack.

- "I know this" removes a card for good.
- "Show less" makes a card come back less often.

### Better ways

Sanketa reads your fish and bash history on this Mac. It looks for commands that have a shorter or safer form. An example is `grep x f | wc -l`, which can be `grep -c x f`. At a local shell prompt, the tip card can then show the better way, such as "Instead of grep x f | wc -l · seen in 3 commands in your history". fish keeps each command only one time, so the number counts different commands, not runs.

Sanketa looks at the history file one time each minute. It reads the end of the file only. It never writes to it, and it never sends it to a server. The cards are also in search. To turn this off, set `enabled = false` in `[coach]`.

### Natural-language search

You can type a question, such as "how do I split the window side by side". When the search has three words or more, Sanketa waits until you stop typing for 0.6 seconds. Then it asks a language model to choose the best entries from your packs. The plain results show at once. When the model answers, its picks move to the top, each with a small orange dot. The model can only choose entries that Sanketa loaded. It cannot make up a key.

Sanketa tries these models in this order, and it uses the first one that works:

1. The on-device model. It is off until you choose a model in the On-Device Model menu or with `--install-model`. Sanketa does not download a model by itself. When it is off, Sanketa does not start MLX and does not use the GPU for it. Each model needs a minimum of memory: its peak memory in our tests plus 3 GB for macOS and your apps, rounded up to a multiple of 8 GB. Gemma 4 E4B needs 16 GB. Each Qwen model needs 8 GB. The menu shows only the models that fit. On a Mac with less than 8 GB, the menu shows one line: "This Mac does not have enough memory for an on-device model. Search uses plain search." The menu item "No On-Device Model" turns the model off. Gemma 4 E4B is the best choice. It is a 5.4 GB download and uses about 5.2 GB of memory while it runs, so Sanketa shows it only on a Mac with 16 GB of memory or more. Qwen3.5-4B is a 3.1 GB download and uses about 3.7 GB. Use it on a Mac with 8 GB. Qwen3.5-2B is a 1.7 GB download and uses about 2.3 GB. If Gemma 4 E4B does not load on your Mac, the menu then offers Qwen3.5-4B 6-bit. It is a 4.1 GB download. Sanketa loads the model when you start a search. While the model loads, the search is plain, and the next search uses the model. Sanketa frees the memory after one minute with no search. The download needs the app build of Sanketa, which has MLX. A build from `swift build` has no MLX, so its download items are off.
2. Apple Intelligence. Sanketa uses it if you turned it on in System Settings. You do not have to.
3. An OpenAI server. This is off until you set `openai = true` in `[llm]`.
4. Plain search, when no model works. One gray line under the results then tells why, such as "Plain search: Apple Intelligence is off". Sanketa shows no popup and makes no sound.

With OpenAI on, the OpenAI Model menu lists the models of the server. "Cheapest" is the default. It uses the model with the lowest price, such as gpt-5-nano. Sanketa keeps the list for 10 minutes. To use a different server that works like OpenAI, set `base_url`. The menu then shows the host of that server.

Sanketa finds the API key in this order: the variable in its environment, then the same variable in your login shell, then the Keychain. To save a key in the Keychain, use OpenAI Key… in the menu. Sanketa keeps one key for each server host and sends it only to that host.

Sanketa sends `OPENAI_API_KEY` only to `api.openai.com`. For a different server, set `api_key_env` to the name of the variable that holds the key for that server. Or save a key for it with OpenAI Key…. A server on this Mac, such as `http://localhost:1234/v1`, needs no key. If it has no key, Sanketa sends no key to it. Sanketa refuses a plain `http` address to a different computer.

On device, a model can also add up to two tips to the tip card, for the commands that you ran last. Their text is "Related to what you just ran". This happens at most one time in 10 minutes. Sanketa never sends your history to OpenAI for this.

### Privacy

Your shell history, the "better ways" results, window and document titles, and the names of layers and programs never leave this Mac. The menu keys of other apps never leave it either, because they can hold window and document names.

This is all that Sanketa sends, and only in these cases:

- With OpenAI on, for each search of three words or more: one HTTPS request to the server. It holds the model name, the fixed instructions, your search text and up to 40 entries from the packs and your live tmux keys. Each entry has a short ref, the pack name, the title and the keys or snippet. A live tmux key that no pack describes has its raw tmux command as its title, so it stays on this Mac. The API key goes in the request header. To OpenAI, Sanketa also asks the server not to store the request.
- With OpenAI on, when the OpenAI Model menu opens or Sanketa needs the cheapest model: one request for the model list, with the API key. Sanketa keeps the list for 10 minutes, so it does not ask for each search.
- When you start a model download: plain requests to `huggingface.co` and its download servers, over HTTPS. They have no key and no data about you. Sanketa checks the size and the SHA-256 hash of each file.

The API key stays in your Keychain or your shell. Sanketa never writes it to a log, and Copy Debug Info never shows it.

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

[coach]                      # better ways from your shell history, on this Mac only
enabled = true
fish_history = "~/.local/share/fish/fish_history"
bash_history = "~/.bash_history"
max_entries = 5000           # read at most this many of the last commands

[llm]                        # natural-language search
on_device = false            # true when you choose a model; off by default
mlx_model = "gemma-4-e4b"    # or "qwen3.5-4b", "qwen3.5-2b" or "qwen3.5-4b-6bit"; the default is Qwen3.5-4B below 16 GB
apple_fm = true              # Apple Intelligence, when it is on
suggest = true               # on-device tips for the commands that you ran last
openai = false               # turn on to use an OpenAI server
openai_model = ""            # empty: the cheapest model
base_url = "https://api.openai.com/v1"
# api_key_env = "OPENROUTER_API_KEY"   # the variable with the key for base_url
timeout_seconds = 5          # Sanketa stops waiting for the model after this
```

The hotkey can be a letter, a digit, F1 to F12, `space`, `/`, `.` or `,` with modifiers. An example is `hotkey = "cmd+shift+space"`. If another app uses the same keys, the footer tells you.

Sanketa applies the file when you save it. You do not have to restart Sanketa. Open Config opens the file in the app that you set for `.toml` files. If you set no app, it opens in your default text editor.

You can also set the translucency and the OpenAI model in the menu-bar menu. The change shows at once, and Sanketa writes only that line to the file. If the file has an error, Sanketa uses the default values.

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

Put your own packs in `~/.config/sanketa/packs/`, one pack in each file. A pack with the same `id` as a bundled pack adds to it. To replace the bundled pack, set `mode = "replace"`. Sanketa loads a pack again when you save it. If a file has an error, Sanketa does not load it. The footer then shows one line for each bad file, such as "duckdb.toml: key 2 has no action." Click the line to open the file. To check a pack before you save it, run `Sanketa --lint-pack FILE`.

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

To help, read [CONTRIBUTING.md](CONTRIBUTING.md).

```sh
make test        # swift test; FILTER=<name> runs the tests with that name
make lint        # check the bundled packs; PACKS=<file or folder> checks yours
make shots       # draw the panel to PNG files; SHOTS=<folder> keeps them
make app         # build and sign build/Sanketa.app
make verify      # check the bundle and its signature
make release     # sign with Developer ID and make dist/Sanketa-<version>.zip
make gatekeeper  # ask Gatekeeper if it accepts the bundle
```

The app also has command-line modes:

```sh
Sanketa --ask "how do I split the window side by side"   # natural-language search
Sanketa --install-model e4b                              # download Gemma 4 E4B (4b and 2b give Qwen)
```

`--install-model` needs the MLX build. Without it, the command stops and makes no request. It also stops for Gemma 4 E4B on a Mac with less than 16 GB of memory. Add `--force` to download the model anyway. On a Mac with less than 8 GB, it stops for each model, also with `--force`. When the model is installed, Sanketa uses it: the command sets `on_device = true` and `mlx_model` in config.toml. If the download stops, Sanketa tries the file again up to 4 times and goes on from the last byte. The bytes stay on disk, so the next download goes on from there too.

### Releases

`make release` signs the bundle with your Developer ID Application identity and a secure timestamp. Then it makes a zip in `dist/`, sends the zip to Apple and waits. When Apple accepts the zip, it staples the ticket to the bundle. Then it checks the bundle with `xcrun stapler validate` and `spctl`, and makes the zip again. If Apple rejects the zip, it shows the issues from the notary log and stops. The version comes from `Resources/Info.plist` only. `make release` and `make publish` stop if you set `VERSION`.

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

Without credentials, `make release` stops, because Gatekeeper rejects a zip that Apple did not notarize. For a local build, use `make app` or `make zip`. These builds are not notarized. After notarization, `make gatekeeper` shows "accepted, source=Notarized Developer ID".

Releases are signed and notarized only on the maintainer's Mac. GitHub has no signing keys or notary keys. To publish a release, push main first, then run `make publish`. It runs `make release`, and then it checks the ticket again. If the check fails, it stops before it uploads. Then it uses `gh release create --target main` to make the release `v<version>`. This also pushes the tag. The release has two zips with the same contents: `Sanketa-<version>.zip` and `Sanketa.zip`. The name `Sanketa.zip` does not change, so the download button always gets the latest release.

The GitHub Actions job builds and tests each push to main and each pull request. It uploads a bundle with an ad-hoc signature as `Sanketa-<sha>.zip`. The job does not make or change a release.

The code has five libraries and the app:

- `SanketaCore` has the logic: packs, settings, layers, the better-ways rules and the model choice rules.
- `SanketaSystem` reads processes, tmux, Accessibility, ssh and shell history.
- `SanketaAI` talks to Apple Intelligence and OpenAI servers, finds the API key and downloads the on-device model.
- `SanketaMLX` loads the on-device model with MLX and runs it.
- `SanketaUI` draws the panel.
- `Sources/Sanketa` is the app.

The tests use real files, real child processes, real fish and bash, and real tmux. These rules keep the tests safe:

- Each tmux test starts its own server on a private socket, `tmux -L sanketa-test-<pid>-<n>`. The test stops that server at the end. Tests never use your default tmux server or a session that they did not make.
- Tests start only real programs that nobody changed. Do not copy or rename a program so that it looks like a different program. Do not change argv[0]. Do not sign a program again. If a test needs a process tree that it cannot make honestly, describe the tree as `ProcInfo` data.
- Each external command goes through `CommandRunning` with a timeout.
- Do not write tests that only check the shape of the code. A test that passes when the feature is broken is not a test.
