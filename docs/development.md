# Develop Sanketa

This page tells you how to build, test and release Sanketa. To send a change, also read [CONTRIBUTING.md](../CONTRIBUTING.md).

## Build from source

```sh
make app install
```

- `make app` builds the app in `build/Sanketa.app`. It signs only that bundle with your Apple Development identity.
- `make install` moves an old copy in `~/Applications` to `/tmp/sanketa-trash`. Then it copies the new bundle to `~/Applications`.
- To use a different identity, add `SIGN_ID="Apple Development: Your Name (TEAMID)"`.
- To start the app, open it from `~/Applications`, or use `make run`.

Do not use a build from source and the Homebrew copy as your daily app at the same time. Each has its own Accessibility permission. See "Accessibility" in [guide.md](guide.md).

## Commands

```sh
make test        # swift test; FILTER=<name> runs the tests with that name
make lint        # check the bundled packs; PACKS=<file or folder> checks yours
make shots       # draw the panel to PNG files; SHOTS=<folder> keeps them
make app         # build and sign build/Sanketa.app
make verify      # check the bundle and its signature
make release     # sign with Developer ID and make dist/Sanketa-<version>.zip
make gatekeeper  # ask Gatekeeper if it accepts the bundle
make ship V=<version>  # test, set the version, publish the release and update the cask
```

The app also has command-line modes:

```sh
Sanketa --ask "how do I split the window side by side"   # natural-language search
Sanketa --install-model e4b                              # download Gemma 4 E4B (4b and 2b give Qwen)
```

`--install-model` needs the MLX build. Without it, the command stops and makes no request. It also stops for Gemma 4 E4B on a Mac with less than 16 GB of memory. Add `--force` to download the model anyway. On a Mac with less than 8 GB, it stops for each model, also with `--force`. When the model is installed, Sanketa uses it: the command sets `on_device = true` and `mlx_model` in config.toml. If the download stops, Sanketa tries the file again up to 4 times and goes on from the last byte. The bytes stay on disk, so the next download goes on from there too.

## Releases

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

`make ship V=<version>` does all of a release in one step. It runs on main only. Both this repo and the tap must have no uncommitted changes. First it runs `make test`. Then it sets `CFBundleShortVersionString` in `Resources/Info.plist` to V and adds 1 to `CFBundleVersion`. It commits this as `Version <version>` and pushes main. Then it runs `make publish` and `make cask`. Last, it commits the cask as `Sanketa <version>` in the tap and pushes the tap. The script is `scripts/ship.sh`. When a step fails before the commit, the script puts `Info.plist` back as it was. A second run skips each step that is done already. It does not publish again when `v<version>` is on GitHub already. So you can always run `make ship V=<version>` again. `make -n` and `make -i` do not run `ship`.

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
