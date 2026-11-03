# Shot list for the hero video

The README shows `docs/media/hero.gif` at the top. Now this file shows panels that a test drew, not a real screen. Use this list to record a real screen and replace the file.

## Before you record

1. Close mail, chat and other private windows.
2. Turn on Do Not Disturb, so that no notification shows.
3. Use a test folder with no private file names, such as `~/demo`.
4. Set the panel to the right side of the screen. Use Translucency: Medium.
5. In the shell, clear the screen.

## Shots (25 s in total)

| Time | What to show | Keys |
|---|---|---|
| 0 to 4 s | Kaku with fish. The panel shows the fish tips. | none |
| 4 to 9 s | Type `htop` and press Return. The panel changes to the htop keys. The breadcrumb shows `htop › fish › Kaku`. | none |
| 9 to 13 s | Press q to quit htop. Type `tmux` and press Return. The panel adds the tmux section. | none |
| 13 to 20 s | Press ⌃⌥K. Type `split pane`. Press ↓ two times. Press Return to copy the result. Press Esc. | ⌃⌥K, ↓, Return, Esc |
| 20 to 25 s | Click Finder. The panel shows the Finder menu keys. Then hold Caps for one second. The AeroSpace bar shows at the top. | hold Caps |

## Record and make the file

1. Press ⇧⌘5. Select the part of the screen with the terminal and the panel.
2. Record the shots. Stop the recording.
3. Make the file small. Use 1280 pixels wide and no sound:

```sh
ffmpeg -i in.mov -vf "scale=1280:-2,fps=24" -an -c:v libx264 -crf 28 -movflags +faststart docs/media/hero.mp4
```

4. Make sure that the file is less than 4 MB.
5. Look at each frame. Make sure that it shows no names, paths, mail or tabs that are private.

GitHub does not play an MP4 file from the repo in a README. Thus make a GIF from the MP4, and keep it less than 4 MB:

```sh
ffmpeg -i docs/media/hero.mp4 -vf "fps=12,scale=800:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse" docs/media/hero.gif
```
