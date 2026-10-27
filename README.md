<img src="design/logo/sanketa-icon.png" width="128" alt="Sanketa kolam logo">

# Sanketa

[![Download for macOS](https://img.shields.io/badge/Download_for_macOS-Sanketa.zip-0A84FF?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/vedicreader/sanketa/releases/latest/download/Sanketa.zip) [All releases](https://github.com/vedicreader/sanketa/releases)

[![build](https://github.com/vedicreader/sanketa/actions/workflows/build.yml/badge.svg)](https://github.com/vedicreader/sanketa/actions/workflows/build.yml)

Sanketa is a small macOS menu-bar app. The name is Sanskrit for "hint" or "signal". It shows a floating glass panel with the keys and tips for the program that you use now.

In a terminal, Sanketa finds each program in the stack. The stack starts at the terminal app and goes through the shell and tmux to the program in front. Each program is a layer, and each layer gets its own section in the panel. For example, if you run htop in tmux in fish, the panel shows the htop keys first. Then it shows your live tmux keys and the fish tips. Sanketa also follows you over ssh when you set up the remote host. Outside a terminal, the panel shows the menu keys of the app in front.

The panel does not take the keyboard focus from your terminal. It takes the focus only when you start a search.

Sanketa needs macOS 26 on Apple Silicon. It needs the Accessibility permission and no other permission. It sees which modifier keys you hold, so that it can show their keys. It does not see or record the other keys that you press. It uses the network only if you turn on OpenAI search, download the on-device model or set up the vault.

## Download

Click the Download for macOS button at the top, or get [the latest zip](https://github.com/vedicreader/sanketa/releases/latest/download/Sanketa.zip). Then do these steps:

1. Unzip `Sanketa.zip`.
2. Move `Sanketa.app` to Applications.
3. Open Sanketa.
4. If macOS blocks it, right-click `Sanketa.app` and select Open. If macOS still blocks it, go to System Settings, then Privacy & Security, and click Open Anyway.
5. Allow Accessibility. The next section gives the steps.

Each release has a Developer ID signature, and Apple notarized it.

### Homebrew

```sh
brew install --cask vedicreader/tap/sanketa
```

Then open Sanketa and allow Accessibility. To get a new version, run `brew upgrade --cask sanketa`. To remove the app and its settings, packs, tips and on-device models, run `brew uninstall --zap --cask sanketa`.

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
- Show Keys When Held: All Combos, Caps Only or Off. See "Hold a combo".
- Show AeroSpace Mode Keys…: shows only when Sanketa finds an AeroSpace file. See "AeroSpace modes".
- Your Keys…: shows the Caps keys of the app in front, and keeps them on the panel. See "Change a key".
- Use OpenAI: turns OpenAI search on or off. When you turn it on, Sanketa looks for the key in the environment, in your login shell and in your Keychain. The next line tells where it found the key, for example "Key: environment". If Sanketa finds no key, the key box opens. Click Save to keep the key in your Keychain and turn OpenAI on. Click Cancel to keep it off.
- OpenAI Model: the model for OpenAI search, when Use OpenAI is on. The menu shows each model by its name, such as GPT-5 Nano.
- OpenAI Key…: save an API key for the server in your Keychain
- Use On-Device Model: turns the on-device model on or off. If no model is downloaded, the model choice opens. Sanketa does not download a model until you choose one. On a Mac with less than 8 GB of memory, this item is off.
- On-Device Model: download, use or remove a model, when Use On-Device Model is on
- The three vault items: Search the Vault, "Search by Meaning, Save Notes" and Open in Abhyasa. See "Use Sanketa alone, or with other tools".
- Set Up the Vault…: shows only when the vault server is missing. See "Set up the vault".
- Reload Packs
- Open Packs Folder
- Make a Pack for <app>…: makes a pack for the app in front with a model or a local agent. See "Make a pack with a model" in [docs/packs.md](docs/packs.md). If a terminal is in front, it makes a first pack for the program in front.
- Open Config
- Allow Accessibility…
- Copy Debug Info
- Quit Sanketa

Copy Debug Info copies a short report for a bug report. It has the version, the app in front, the layers, the packs and the Accessibility state. It also tells which models are on, and if Sanketa found an API key. It has no file contents, and it never has the key.

### Search

The hotkey is Control-Option-K (⌃⌥K). It shows the panel and starts a search. Type a word to find a key or tip in all packs. The best matches come first. When two results match equally well, a result from the current layers comes first.

- Press ↑ or ↓ to move the selection.
- Press Return to copy the command or snippet of the selected result. A key that has no command copies nothing. A vault result opens instead. See "Vault search".
- Click a result to see all its text, its command and its explanation. Click it again to make it short. Search stays open.
- Put the pointer on a result to see all its text and a copy button. The copy button copies the command or the snippet.
- Press Esc to give the focus back to your terminal.
- Press Tab to go to the layer list. The search text stays.
- The search field has the usual text keys of macOS. ⌘A selects all. ⌘C, ⌘X and ⌘V copy, cut and paste. ⌘Z undoes and ⇧⌘Z redoes. ⌥← and ⌥→ move one word. ⌘← and ⌘→ go to the start or the end. ⌥⌫ and ⌘⌫ delete a word or the line. Add ⇧ to select the text.
- In the layer list, press Tab, Shift-Tab, ↑ or ↓ to go to the next or previous section.

### Vault search

Search also finds documents in your vault. The vault is one file on this Mac. It keeps your learnings from Abhyasa, your ramabana sessions and your notes. One search box finds them all. Each tool keeps its own functions.

- Type 3 letters or more. Sanketa waits until you stop typing for 0.2 seconds. Then it searches the vault.
- The vault results and the pack results are in one list. The best matches come first. See "How search ranks the results".
- Each vault result shows the title of the document and a short part of its text. The shelf shows at the right of the title, such as "ramabana" or "leela". The main shelf shows as "vault".
- The selected result shows its keys on one line, such as `↩ Open     ⌥↩ Resume session`.

Sanketa finds the vault in this order: `path` in `[vault]`, then the variable `VISHALAKSHI_VAULT`, then `ABHYASA_VAULT`, then `~/.vishalakshi/vault.db`. An app that you start from the Dock does not get the variables of your shell. Set `path` if your vault is in a different place. Sanketa skips the test shelves whose names start with `tmp` or `dialogprobe`.

#### How search ranks the results

Sanketa gives each result a match level. It uses the same rules for keys, tips and vault results. Case and accents do not count, so "cafe" finds "Café". The levels, from best to worst, are:

1. Each word of the search starts a word in the title.
2. The title has the search text as one phrase.
3. Each word of the search is in the title or in the text.
4. Some words of the search are in the title or in the text.

The best result comes first. Each pack and each vault shelf has one heading, and all its results show under it. The packs and shelves come in the order of their best results. Thus a vault document whose title has your search comes before a pack whose best key matches one word. In one level, more matches in the title come first. Vault results with the same match keep the order of the vault search.

The rows do not move while you read them. When you type, the old list stays until the new list is ready. Sanketa waits for the vault for 0.5 seconds at most. Then it shows the new list in the order above. Some results come later, such as the choices of the model. They go below the rows that show and below the selected row. If a result is in the list already, its text changes in its row. The selected row stays selected. Only a new search changes the order.

The model for natural-language search can choose results. Its choices stay at the top only when no other result has a better title match. Else they go into the list with the other results.

#### Scope

Push ⌘E during a search to change the scope. Push ⇧⌘E to go back. A label next to the search field shows the scope:

- All: keys, tips and vault results. This is the scope at the start of each search.
- Shortcuts: keys and tips only. Sanketa does not search the vault.
- Vault: vault results only. Sanketa gets up to 20 results, which is more than in All.

Tab does not change the scope, because Tab goes to the layer list.

#### Search by meaning

Sanketa can search by words and by meaning together. This is hybrid search. For it, Sanketa uses the vault server. Sanketa starts the server when you start a search. The server runs on this Mac, and it reads the same vault file.

- The server needs about 1.5 seconds to start. Until it is ready, Sanketa finds words only.
- A hybrid search takes about 60 milliseconds. Sanketa waits 1 second at most. Then it shows the word results.
- If Sanketa cannot start the server, it finds words only. It shows no error.
- The server stops after 10 minutes with no search. It uses about 270 MB of memory while it runs.
- The server hides personal data in the results, such as email addresses.

#### Set up the vault

The vault server is a separate program (the `vishalakshi` package). If Sanketa does not find it, the menu-bar menu shows "Set Up the Vault…". Sanketa does not install the server until you click that item. Then do these steps:

1. Click Set Up the Vault….
2. Read the message. It tells you the command that Sanketa will run.
3. Click Set Up. Click Cancel to stop.

Sanketa then runs this command in the background:

```sh
uv tool install vishalakshi
```

A message at the bottom of the panel shows "Setting up the vault…". When the command stops, the message tells you the result. Then Sanketa looks for the server again.

Sanketa looks for uv in `/opt/homebrew/bin`, then `~/.local/bin`, then `/usr/local/bin`. If it does not find uv, the message tells you to install uv with `brew install uv`. Use version 0.1.35 of the vault server or later. An old version can start very slowly. To update the server, run the same command with `upgrade` in place of `install`.

#### Save to the vault

You can save text in the vault as a note. Sanketa saves only when you push one of these keys during a search:

- Push ⌘S to save the search text as a note.
- Push ⇧⌘S to save the text on the clipboard as a note. The search text is the title. If you did not type a search, the first line is the title.
- ⌘D also saves the clipboard. But another app can use ⌘D for all apps. Then Sanketa does not get the key. Use ⇧⌘S.

A line under the results shows the keys. After the save, a message at the bottom of the panel tells you the title of the note. If the save fails, the message tells you why. The message stays for 4 seconds. It stays longer while the pointer is on it. A save of a pack in Make a Pack also shows a message with the name of the file.

Each save makes a new note. It never replaces a note that has the same title. Sanketa adds the tag `sanketa` to each note. The vault server writes the note. Sanketa itself never writes to the vault file. If there is no vault file yet, the first note makes it.

#### Open a result

Push Return to open the selected result:

- A web page opens in your browser.
- A file opens in its app, if it is on this Mac.
- If the Abhyasa app is installed, Return opens the result in the app. A concept opens at `abhyasa://concept/<name>`. Other documents open at `abhyasa://vault/<shelf>/<id>`. These links work on each port that the app uses. If the app is closed, macOS starts it.
- If the app is not installed but the Abhyasa server answers, the result opens in your browser. A concept opens at `<url>/c/<name>`, and other documents at `<url>/v/<shelf>/<id>`.
- These links include ramabana sessions, memory entries and notes. A note that you saved with ⌘S or ⇧⌘S is on the main shelf. Thus it opens at `abhyasa://vault/store/<id>` or `<url>/v/store/<id>`.
- In all other cases, Return shows all the text of the result in the panel. Push Return again to make it short.

Push ⌥Return for more actions:

- On a ramabana session, ⌥Return resumes the session with `ramabana --resume <id>`. If you use tmux, the session opens in a new window of your tmux session. If not, it opens in a new window of your terminal app.
- On a ramabana memory entry, ⌥Return opens its file, such as `~/.config/ramabana/memory/<id>/MEMORY.md`.
- On a document that has no file and no web page, ⌥Return opens the text as a Markdown file. An example is a note that you saved with ⌘S. Sanketa writes the file to `~/Library/Caches/Sanketa/Notes`. Only you can read it. The file opens in your default app for Markdown files.

Put the pointer on a result that can open. An open button then shows. Click it to open the result.

#### Use Sanketa alone, or with other tools

Sanketa works alone. Three items in the menu-bar menu connect it to other tools. Each item changes one line in the settings file.

| Item | Setting | Needs | What it does |
|---|---|---|---|
| Search the Vault | `[vault] enabled` | the vault file | Finds documents in the vault. Sanketa only reads the vault file. |
| Search by Meaning, Save Notes | `[vault] mcp` | the vault server | Starts the vault server for hybrid search, ⌘S and ⇧⌘S. |
| Open in Abhyasa | `[abhyasa] enabled` | the Abhyasa app or server | Return opens vault results in Abhyasa. |

Each item is on when Sanketa finds the tool that it needs. Sanketa looks again each time that you open the menu. If you set a value to `false`, the item stays off. If the settings file has no value, the item is on when the tool is there. A click on an item writes `true` or `false`.

If a tool is missing, its item is gray and tells you what it needs:

- "Search the Vault (no vault file)": Sanketa does not find the vault file.
- "Search by Meaning (needs the vault server)": Sanketa does not find the vault server. "Set Up the Vault…" then shows below.
- "Get the Abhyasa App…": the Abhyasa app is not installed, and the Abhyasa server does not answer. Click it to open the download page of Abhyasa.

The two vault options need Search the Vault. Saving needs no vault file: the first note makes the file.

Sanketa finds the Abhyasa app through macOS. This check sends nothing on the network. If the app is not installed, Sanketa asks the Abhyasa server at `url` if it runs. It asks at most one time in 10 seconds. If Abhyasa is off, Sanketa never connects to it.

The vault never leaves this Mac. The model for natural-language search does not get vault results.

### Hold a combo

Hold two or more modifier keys (for example ⌃⌥⇧⌘, which Caps Lock can send) and press nothing else. After a short wait, the panel shows the keys of that combo. If you press a key before the panel shows, the panel does not show. A mouse click or a scroll also stops the wait. This lets you use a combo for fast key presses with no flicker.

The panel has two columns. The left column shows your AeroSpace keys for the combo. Sanketa reads them from `~/.aerospace.toml`, or from `aerospace/aerospace.toml` in your config folder. If it finds no file, the left column does not show. Sanketa reads the file again when you save it. The right column shows the keys of the app in front.

If AeroSpace and the app use the same key, the app row has a line through it. The row ends with "· AeroSpace", because AeroSpace gets the key first. The last line lists the free keys: the keys that no AeroSpace key and no app key uses for this combo. Use them when you pick a new key.

The panel does not take keyboard focus. Only the chord field takes it, when you change a key (see "Change a key"). When you release the keys, the panel goes back to how it was. A panel that was hidden hides again. Sanketa does not show the keys while you search.

To choose which combos show their keys, use Show Keys When Held in the menu, or set `hold` in the config file:

- `all`: any combo of two or more modifier keys (the default)
- `caps`: only the combo of all four modifier keys, which Caps Lock sends in a Hyper setup
- `off`: never

#### AeroSpace modes

The keys of an AeroSpace mode, such as `resize`, have no modifier key. So you cannot hold a combo to see them, and AeroSpace does not tell other apps when its mode changes. To fix this, choose Show AeroSpace Mode Keys… in the menu. The item shows only when Sanketa finds an AeroSpace file. Sanketa tells you what it will change, and you click Change or Cancel. Each binding that starts a mode then also opens a link, `sanketa://aerospace/mode/<name>`. Sanketa keeps a copy of the old file as `<file>.sanketa-bak`, and then runs `aerospace reload-config`.

While a mode is on, the panel shows the keys of that mode. It does not take the focus, and a change of modifier keys does not hide it. The panel hides when the `main` mode comes back.

#### Change a key

You can change an AeroSpace key or a Leela key from the panel:

1. Hold the combo, and click the panel. The panel then stays when you release the keys. To keep the view without a hold, choose Your Keys… in the menu: it shows the Caps keys of the app in front.
2. Click a key row. A row for a group of keys, such as "1 – 9", first lists its keys: click one. A row with a line through it lets you choose "Change Leela's key" (the first choice) or "Change AeroSpace's key".
3. Sanketa shows up to three free chords, each with its reason, for example "free, next to your Caps T and Caps U, left hand". Click one. Or click "Press a new chord" and press the chord. Only then does the panel take keyboard focus, and only to read that one chord. Press Esc to stop.
4. Sanketa shows the change, for example "Change Toggle tools: Caps X → Caps Y in ~/.config/leela/keys.json?". Click Change or Cancel. Then the app in front gets the focus again.
5. Sanketa keeps a copy of the old file as `<file>.sanketa-bak`, for example `keys.json.sanketa-bak`. It writes the new key and changes nothing else in the file. For AeroSpace, it then runs `aerospace reload-config`. Leela reads `keys.json` again by itself.
6. The toast says "Changed." and has an Undo button. Undo puts the old file back. If you changed the file after the change, Undo does not run, so your edit stays.

Which keys you can change:

- AeroSpace keys, when Sanketa finds an AeroSpace file. Sanketa changes only the key on the left side of the binding line.
- Leela keys. Sanketa writes them in the `keys` part of `keys.json`, never in `_defaults`.
- The keys of other apps are only shown. For a row with a line through it, you can change AeroSpace's key.

A suggested chord is free in AeroSpace (the mode now and `main`) and in the app in front. For an AeroSpace key, Sanketa also checks every pack that it has. Sanketa does not check apps that have no pack.

To close the view, click outside the panel, or hide the panel. Sanketa cannot see Esc while the app in front has the focus.

### Layers and sections

The breadcrumb at the top lists the layers, the innermost first, for example `htop › tmux › fish › Kaku`. Click a layer to go to its section and open all its groups. When you click the panel outside a search, the focus goes back to the app that you used. When you click the search field, the search starts and the field keeps the focus.

The panel is an index of the layers. When the innermost layer has keys, its section comes first and is open. It shows the keys of its first two groups. Each other section shows the keys of its first group. The other groups show as one line with a count, such as `› View 10`. Click the line to open the group. A group with two keys or fewer is always open. Click a key to see all its text and its full command. Click it again to make it short. Put the pointer on a key to see all its text. If the key has a command, a copy button shows at the right. The copy button copies the command, or the snippet of a tip. It does not copy the keys. The panel then shows "Copied" for a short time. The focus does not change.

When you go to a different program, the panel goes back to the top. If you go back to a stack of layers that you used a short time ago, the panel shows it as you left it. It keeps the groups that you opened and the scroll position. It remembers the last eight stacks.

If a program has no pack, its section says "Sanketa has no keys for yazi." Click "Make a pack for yazi" to make a first pack. Sanketa writes `~/.config/sanketa/packs/yazi.toml` and opens it. If an app has no pack, the link "Make a pack for <app>" shows under its menu keys. It opens the Make a Pack window.

### Make a pack

The Make a Pack window makes a pack for the app in front. Open it from "Make a Pack for <app>…" in the menu-bar menu, or from the link in the panel.

1. Optional: type the URLs of the shortcut pages of the app.
2. Click one of these buttons:
   - **Copy Prompt**: paste the prompt in a local agent, such as Claude Code. Then paste the result in the window.
   - **Send to OpenAI**: this button shows when Use OpenAI is on. The model reads the docs on the web.
   - **Send to On-Device Model**: this button shows when a model is ready. Paste the text of the shortcut page first. The model cannot read web pages. This can take 2 minutes.
3. Sanketa checks the result and shows a preview.
4. Click Save, or press Return.

The status line at the bottom shows what Sanketa does. While a model works, it shows a timer. Press Esc to stop the request. When no request runs, Esc closes the window.

After a save, the panel shows the new keys and the message "Saved". The window closes, and the app that was in front gets the focus again. If a pack file for the app exists, Sanketa asks before it replaces the file. It keeps the old file as `<id>.toml.bak`.

The prompt does not contain window titles, file names, paths or your history. For all the rules, see "Make a pack with a model" in [docs/packs.md](docs/packs.md). Check each key in the app before you trust it. A model can make a mistake.

### Tip cards

The panel shows one tip card. It shows one key or one snippet from the current packs. The card comes from the innermost layer that has keys or tips. It comes after the innermost section when that layer has keys. Otherwise it is at the top. The card changes every two minutes. It stays when you change panes, while its pack is in the stack.

- "I know this" removes a card for good.
- "Show less" makes a card come back less often.

### Better ways

Sanketa reads your fish and bash history on this Mac. It looks for commands that have a shorter or safer form. An example is `grep x f | wc -l`, which can be `grep -c x f`. At a local shell prompt, the tip card can then show the better way. An example is "Instead of grep x f | wc -l · seen in 3 commands in your history". fish keeps each command only one time, so the number counts different commands, not runs.

Sanketa looks at the history file one time each minute. It reads the end of the file only. It never writes to it, and it never sends it to a server. The cards are also in search. To turn this off, set `enabled = false` in `[coach]`.

### Natural-language search

You can type a question, such as "how do I split the window side by side". When the search has three words or more, Sanketa waits until you stop typing for 0.6 seconds. Then it asks a language model to choose the best entries from your packs. The plain results show at once. When the model answers, its picks move to the top, each with a small orange dot. The model can only choose entries that Sanketa loaded. It cannot make up a key.

Sanketa tries these models in this order, and it uses the first one that works:

1. The on-device model. It is off until you choose a model in the On-Device Model menu or with `--install-model`. Sanketa does not download a model by itself. When it is off, Sanketa does not start MLX and does not use the GPU for it. Each model needs a minimum of memory: its peak memory in our tests plus 3 GB for macOS and your apps, rounded up to a multiple of 8 GB. Gemma 4 E4B needs 16 GB. Each Qwen model needs 8 GB. The menu shows only the models that fit. On a Mac with less than 8 GB, the menu shows one line: "This Mac does not have enough memory for an on-device model. Search uses plain search." The menu item "No On-Device Model" turns the model off. Gemma 4 E4B is the best choice. It is a 5.4 GB download and uses about 5.2 GB of memory while it runs. Thus Sanketa shows it only on a Mac with 16 GB of memory or more. Qwen3.5-4B is a 3.1 GB download and uses about 3.7 GB. Use it on a Mac with 8 GB. Qwen3.5-2B is a 1.7 GB download and uses about 2.3 GB. If Gemma 4 E4B does not load on your Mac, the menu then offers Qwen3.5-4B 6-bit. It is a 4.1 GB download. Sanketa loads the model when you start a search. While the model loads, the search is plain, and the next search uses the model. Sanketa frees the memory after one minute with no search. The download needs the app build of Sanketa, which has MLX. A build from `swift build` has no MLX, so its download items are off.
2. Apple Intelligence. Sanketa uses it if you turned it on in System Settings. You do not have to.
3. An OpenAI server. This is off until you set `openai = true` in `[llm]`.
4. Plain search, when no model works. One gray line under the results then tells why, such as "Plain search: Apple Intelligence is off". Sanketa shows no popup and makes no sound.

With OpenAI on, the OpenAI Model menu lists the models of the server. "Cheapest" is the default. It uses the model with the lowest price, such as GPT-5 Nano. Sanketa keeps the list for 10 minutes. To use a different server that works like OpenAI, set `base_url`. The menu then shows the host of that server.

Sanketa finds the API key in this order: the variable in its environment, then the same variable in your login shell, then the Keychain. To save a key in the Keychain, use OpenAI Key… in the menu. Sanketa keeps one key for each server host and sends it only to that host.

Sanketa sends `OPENAI_API_KEY` only to `api.openai.com`. For a different server, set `api_key_env` to the name of the variable that holds the key for that server. Or save a key for it with OpenAI Key…. A server on this Mac, such as `http://localhost:1234/v1`, needs no key. If it has no key, Sanketa sends no key to it. Sanketa refuses a plain `http` address to a different computer.

On device, a model can also add up to two tips to the tip card, for the commands that you ran last. Their text is "Related to what you just ran". This happens at most one time in 10 minutes. Sanketa never sends your history to OpenAI for this.

### Privacy

Your shell history, the "better ways" results, window and document titles, and the names of layers and programs never leave this Mac. The menu keys of other apps never leave it either, because they can hold window and document names.

This is all that Sanketa sends, and only in these cases:

- With OpenAI on, for each search of three words or more: one HTTPS request to the server. It holds the model name, the fixed instructions, your search text and up to 40 entries from the packs and your live tmux keys. Each entry has a short ref, the pack name, the title and the keys or snippet. A live tmux key that no pack describes has its raw tmux command as its title, so it stays on this Mac. The API key goes in the request header. To OpenAI, Sanketa also asks the server not to store the request.
- With OpenAI on, when the OpenAI Model menu opens or Sanketa needs the cheapest model: one request for the model list, with the API key. Sanketa keeps the list for 10 minutes, so it does not ask for each search.
- When you start a model download: plain requests to `huggingface.co` and its download servers, over HTTPS. They have no key and no data about you. Sanketa checks the size and the SHA-256 hash of each file.
- When you click Set Up the Vault… and then Set Up: uv gets the vault server from the Python package index. Sanketa sends no data about you.

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
hold = "all"                 # show the keys of a combo that you hold: "all", "caps" or "off"

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

[vault]                      # search your vault too
enabled = true               # on when the vault file exists; false: off
path = ""                    # empty: VISHALAKSHI_VAULT, then ABHYASA_VAULT, then ~/.vishalakshi/vault.db
mcp = true                   # search by meaning and save notes, through the vault server; false: off
mcp_command = ""             # the vault server; empty: ~/.local/bin, then /opt/homebrew/bin, then /usr/local/bin
mcp_url = ""                 # a server that runs already on this Mac, such as "http://127.0.0.1:8000/mcp"
mcp_timeout_seconds = 1.0    # then Sanketa shows the word results
mcp_idle_seconds = 600       # the server stops after this time with no search

[abhyasa]                    # the Abhyasa learning app
enabled = true               # on when the app is installed or the server answers; false: Sanketa never connects to it
url = "http://127.0.0.1:5077"   # the server, if the app is not installed; [vault] learning_url, the old name, also works
```

The hotkey can be a letter, a digit, F1 to F12, `space`, `/`, `.` or `,` with modifiers. An example is `hotkey = "cmd+shift+space"`. If another app uses the same keys, the footer tells you.

Sanketa applies the file when you save it. You do not have to restart Sanketa. Open Config opens the file in the app that you set for `.toml` files. If you set no app, it opens in your default text editor.

If you set `mcp_url`, Sanketa uses that vault server and starts no server. Sanketa accepts only an address on this Mac. To start such a server, run the vault server with its `--http` option. It listens on port 8000.

You can also set the translucency, the OpenAI model and the three vault items in the menu-bar menu. The change shows at once, and Sanketa writes only that line to the file. If the file has an error, Sanketa uses the default values.

## Terminals

Use Kaku or Ghostty. A terminal window can have many tabs, and each tab has its own shell. Sanketa must find the tab in front. Kaku and Ghostty put the program of the front tab in the window title. Thus Sanketa can find the correct tab and show the full stack.

Kaku also adds a tab number such as `[2/3]` to the title. Sanketa counts the tabs in the order that you opened them. If you move a tab to a different position, Sanketa can show the wrong tab. This is the one case where Sanketa guesses.

Terminal.app and iTerm2 also work. They work with one tab for each window, or when the title shows the program. Conterm and other terminals with many tabs give no signal for the front tab. For these, Sanketa shows only the shell and the terminal. It does not guess the tab, because a wrong guess shows keys for a program that you do not use.

To add a terminal, put its bundle id in `terminals`. To find the bundle id, use `mdls -name kMDItemCFBundleIdentifier /Applications/Foo.app`.

## Packs

A pack is a TOML file with the keys and tips for one program or app. These packs come with the app:

- Tools: awk, find, git, grep, htop, lazygit, nvidia-smi, nvtop, sed, shell pipes, vim and yazi.
- Shells and tmux: bash, fish and tmux.
- Apps and agents: Claude Code, Conterm, Leela, ramabana and RawTherapee.

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

Releases are signed and notarized only on the maintainer's Mac. GitHub has no signing keys or notary keys. To publish a release, push main first, then run `make publish`. If the release of this version is on GitHub already, it stops before it builds anything. Else it runs `make release`, and then it checks the ticket again. If the check fails, it stops before it uploads. Then it uses `gh release create --target main` to make the release `v<version>`. This also pushes the tag. The release has two zips with the same contents: `Sanketa-<version>.zip` and `Sanketa.zip`. The name `Sanketa.zip` does not change, so the download button always gets the latest release.

After a release, run `make cask`. It gets `Sanketa-<version>.zip` from the GitHub release, and it writes the version and the SHA-256 hash of that zip into the cask in the [tap](https://github.com/vedicreader/homebrew-tap). It does not use the zip in `dist/`, because a second `make release` makes a zip with a different hash. The tap is at `../homebrew-tap` by default; set `TAP=<folder>` for another folder. Then commit and push the tap.

The GitHub Actions job builds and tests each push to main and each pull request. It uploads a bundle with an ad-hoc signature as `Sanketa-<sha>.zip`. The job does not make or change a release.

The code has six libraries and the app:

- `SanketaCore` has the logic: packs, settings, layers, the better-ways rules and the model choice rules.
- `SanketaSystem` reads processes, tmux, Accessibility, ssh and shell history.
- `SanketaAI` talks to Apple Intelligence and OpenAI servers, finds the API key and downloads the on-device model.
- `SanketaMLX` loads the on-device model with MLX and runs it.
- `SanketaVault` reads the vault file and talks to the vault server.
- `SanketaUI` draws the panel.
- `Sources/Sanketa` is the app.

The tests use real files, real child processes, real fish and bash, and real tmux. These rules keep the tests safe:

- Each tmux test starts its own server on a private socket, `tmux -L sanketa-test-<pid>-<n>`. The test stops that server at the end. Tests never use your default tmux server or a session that they did not make.
- Tests start only real programs that nobody changed. Do not copy or rename a program so that it looks like a different program. Do not change argv[0]. Do not sign a program again. If a test needs a process tree that it cannot make honestly, describe the tree as `ProcInfo` data.
- Each external command goes through `CommandRunning` with a timeout.
- Do not write tests that only check the shape of the code. A test that passes when the feature is broken is not a test.
