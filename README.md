# Sanketa

<img src="design/logo/sanketa-icon.png" width="96" alt="Sanketa icon">

Sanketa (Sanskrit for hint, or signal) is a small macOS menu-bar app that keeps a floating glass panel of keyboard shortcuts and tips for whatever you are working in right now. It reads the stack of programs in your terminal, from the terminal app through the shell and tmux down to the program in front, and shows one section per layer. Run htop inside tmux inside fish and you get htop's keys, your live tmux bindings and fish's tips, innermost first. It follows you over ssh too, if the remote host is set up for it. Outside a terminal it shows the front app's menu shortcuts. The panel never takes focus from your terminal unless you ask it to search.

![Sanketa panel](design/screenshot.png)

It needs macOS 26 on Apple Silicon and the Accessibility permission. Nothing else: no input monitoring, no network, no keystroke logging.

## Install

```sh
make app install
```

`make app` builds a release binary, assembles `build/Sanketa.app` and signs that bundle with your Apple Development identity. `make install` copies it to `~/Applications`. To sign with a different identity, pass `SIGN_ID="Apple Development: Your Name (TEAMID)"`. Open it from `~/Applications` or with `make run`.

## First run

Sanketa asks for Accessibility at launch. Grant it in System Settings > Privacy & Security > Accessibility. Without it the panel still works in terminals, but it can't read window titles or other apps' menus, and the footer shows "Grant Accessibility..." until you do. The same item is in the menu-bar menu.

Because the bundle is signed with a stable Apple Development identity, macOS keeps the grant when you rebuild. An ad-hoc signed build would lose it every time.

## Using it

The panel floats above other windows. Drag it where you like; it remembers its position and size. The menu-bar icon (a command-key symbol) shows or hides it, and also has Reload Packs, Open Packs Folder, Open Config and Quit.

The hotkey is Control-Option-K (⌃⌥K). It brings the panel forward in search mode, so you can type to find any key or tip across all packs, with the current layers ranked first. Arrows move the selection, Return copies the selected entry to the clipboard, and Escape hands focus back to your terminal. Tab in the search field moves to the layer list and keeps your query; Tab and Shift-Tab cycle through the sections.

The breadcrumb at the top lists the layers, such as `htop > tmux > fish > Kaku`. Click one to jump to its section. A click on the panel outside search gives focus straight back to the app you were in.

A tip card at the bottom shows one key or snippet from the current packs and changes every two minutes. "I know this" retires it, and "Show less" makes it come up less often.

Settings live in `~/.config/sanketa/config.toml`. Open Config creates the file with commented defaults. The keys are:

```toml
hotkey = "ctrl+opt+k"        # modifiers: ctrl, opt (or alt), shift, cmd; then one key
terminals = ["app.conterm.Conterm", "com.mitchellh.ghostty", "com.apple.Terminal",
             "com.googlecode.iterm2", "fun.tw93.kaku"]   # bundle ids treated as terminals
pollInterval = 1.0           # seconds between checks while a terminal is in front
tipRotateSeconds = 120       # how often the tip card changes
translucency = "medium"      # low, medium or high
```

The hotkey can be any letter, digit, F1 to F12, `space`, `/`, `.` or `,` with modifiers, for example `hotkey = "cmd+shift+space"`. Restart Sanketa after changing it. If another app already owns the combination, the footer says so. Translucency is also in the menu-bar menu, where it switches live and writes only that one line back to the file. A file that doesn't parse falls back to defaults.

## Terminals

Kaku and Ghostty are the ones to use. A terminal window can hold many tabs, each with its own shell, and Sanketa has to work out which tab is in front. Kaku and Ghostty put the focused tab's program in the window title (Kaku also adds a `[2/3]` tab index), so Sanketa can pick the right tab and show the full stack.

Terminal.app and iTerm2 work too, with one tab per window or when the title names the running program. Conterm and other multi-tab terminals that give no focused-tab signal show only the shell and the terminal, because Sanketa won't guess which tab you're looking at. A wrong guess would show keys for a program you aren't running.

To add another terminal, put its bundle id in `terminals`. Find it with `mdls -name kMDItemCFBundleIdentifier /Applications/Foo.app`.

## Packs

A pack is a TOML file with the keys and tips for one program or app. These ship with the app: awk, bash, Claude Code, Conterm, find, fish, git, grep, htop, leela, nvidia-smi, nvtop, shell pipes, ramabana, sed, tmux and vim.

Your own packs go in `~/.config/sanketa/packs/`, one per file. A pack with the same `id` as a bundled one extends it, or replaces it with `mode = "replace"`. Use Reload Packs after editing. A file that fails to parse is skipped and counted in the footer; hover the count to see which file.

[docs/packs.md](docs/packs.md) has the full format, the key notation and a worked example. It is written so you can hand it to a language model and get a valid pack back.

## Remote hosts

When you ssh somewhere, Sanketa sees `ssh` locally and nothing beyond it. To see the remote layers, run once per host:

```sh
make remote-setup HOST=me@gpubox
```

This copies three small scripts to `~/.config/sanketa/remote/` on the host and hooks them up:

- fish: `~/.config/fish/conf.d/sanketa.fish`
- bash: a line in `~/.bashrc` that sources `sanketa.bash`
- tmux: a line in `~/.tmux.conf` that sources `tmux.conf`

Each one puts a short tag in the terminal title, naming the host and the programs running there. The tmux part passes that title through to your terminal. Sanketa reads the tag and shows something like `htop@gpubox > tmux@gpubox > fish@gpubox > gpubox > fish > Kaku`. Running the setup again changes nothing that's already in place. Afterwards open a new shell, and in a tmux that's already running, run `tmux source-file ~/.tmux.conf`.

The fish snippet wraps whatever `fish_title` exists when it loads. fish reads `conf.d` before `config.fish`, so a `fish_title` defined in `config.fish` replaces the snippet's and the tag disappears. Move your `fish_title` into `~/.config/fish/functions/fish_title.fish` and the snippet will wrap it.

The bash snippet keeps an existing DEBUG trap and runs it first, and it joins bash-preexec if you use that.

If a host has no snippet but you connect through an ssh ControlMaster, Sanketa falls back to asking that host's tmux for the current program over the existing connection, in batch mode, so it never prompts for a password. It does nothing if no master connection is open. This needs `ControlMaster` and `ControlPath` set for the host in `~/.ssh/config`.

## Limits

- Only the default tmux server is read. Sessions on a socket chosen with `-L` or `-S`, and tmux running inside tmux, show as a plain tmux layer with nothing inside it.
- In multi-tab terminals with no focused-tab signal in the title, only the shell and terminal layers are shown (see Terminals).
- iTerm2 sessions that live under a re-parented `iTermServer` process may not resolve beyond the app layer.
- Remote layers need the title snippet on the host, or a ControlMaster connection.
- Idle CPU is low but not yet zero while a terminal is in front, since the process table is read once per poll.

## Development

```sh
make test     # swift test
make app      # build and sign build/Sanketa.app
make verify   # check the bundle and its signature
```

The code is split into `SanketaCore` (pure logic: packs, config, layer resolution), `SanketaSystem` (processes, tmux, Accessibility, ssh) and `SanketaUI` (the panel), with the app in `Sources/Sanketa`.

Tests run real things: real files, real child processes, real fish and bash, real tmux. A few rules keep that safe:

- Every tmux test uses its own server on a private socket, `tmux -L sanketa-test-<pid>-<n>`, and kills that server when it finishes. Tests never touch your default tmux server or any session they didn't create.
- Tests only spawn real, unmodified programs. Never copy or rename a binary so it looks like another program, never fake argv[0], and never re-sign a binary. When a test needs a process tree that can't be made honestly, such as ssh to a host that doesn't exist, build it as synthetic `ProcInfo` data.
- Every external command goes through `CommandRunning` with a timeout.
- No tests that only check the shape of the code. If a test passes when the feature is broken, it isn't a test.
