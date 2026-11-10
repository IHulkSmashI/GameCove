# Boot intro

GameCove opens with a short intro over the home screen (`app/scripts/ui/boot_splash.gd`):

- If `app/assets/boot/intro.ogv` exists it plays that clip (Godot's `VideoStreamPlayer`, Theora), stretched to the screen, on the clip's own background (`#0F1723`), then fades away. A clip runs at most 6 s.
- Otherwise it plays the code animation: the GameCove mark (`app/assets/logo-mark.svg`, the same file as `assets/logo.svg`) scales in and one soft cyan (`#00F0FF`) glow sweeps across the wordmark on the same slate background, 1.9 s in all.

Either way it never delays anything: it's added last when the app starts, after the session client's heartbeat and ready file are set up, nothing waits for it, and the home screen behind it is live at once. Any button, key or click skips it (that press is used up), it goes at once if a game or anything else takes the screen, and with Settings > Reduce motion there's no intro at all. It isn't shown in headless runs (tests, CI).

## Dropping in a new clip

The clip that ships is our own (made with Google Gemini from the GameCove mark; see CREDITS.md). To replace it, convert the new MP4 to Theora, 16:10, no audio, 30 fps, and keep it short (2-3 s):

```sh
# 1920x1200 (sharp on 1200p handhelds); pad to 16:10 with the background colour
ffmpeg -i gemini_intro.mp4 -t 3 -an -r 30 \
  -vf "scale=1920:1200:force_original_aspect_ratio=decrease,pad=1920:1200:(ow-iw)/2:(oh-ih)/2:color=0x0F1723" \
  -c:v libtheora -q:v 8 app/assets/boot/intro.ogv

# or 1280x800 (smaller file, fine on 800p screens)
ffmpeg -i gemini_intro.mp4 -t 3 -an -r 30 \
  -vf "scale=1280:800:force_original_aspect_ratio=decrease,pad=1280:800:(ow-iw)/2:(oh-ih)/2:color=0x0F1723" \
  -c:v libtheora -q:v 7 app/assets/boot/intro.ogv
```

If the new clip's background isn't `#0F1723`, change `BG` in `boot_splash.gd` to match it, so the hand-off from the splash colour to the first frame is seamless. Then run Godot once with `--import`. The export keeps the file (`assets/boot/*.ogv` is in `app/export_presets.cfg`'s include filter; `packaging/tests/release.sh` checks that). Delete the file to go back to the code animation.

To see it: `tools/screenshots/record_animations.sh /tmp/anim boot` (the clip) or `boot_code` (the code animation) writes an MP4 and a GIF.
