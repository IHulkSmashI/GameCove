# Performance

GameCove keeps running behind your games so the quick menu, power and TDP, the session
heartbeat and game tracking work. Behind a game it should cost next to nothing; in front it
should only work when something on screen changes.

## Measured

`tools/perf/measure.py` runs the real app on a fake handheld (the e2e fixture) in private
folders, holds it in each state and reads `/proc/self`. Numbers below: a 2-core CI box,
MSI Claw 8 EX fixture, 60 s per state headless, 20-30 s per state on Xvfb (software GL).
Other jobs shared the box, so take small differences as noise.

Headless (the app's own work, no display):

| | home | quick menu over home | game in front, before | game in front, now | quick menu over game |
| --- | --- | --- | --- | --- | --- |
| main-loop iterations/s | 145 | 145 | 145 | **31** | 145 |
| wake-ups/s, all threads | 156 | 157 | 158 | **44** | 157 |
| CPU, ms per second | 7-9 | 7-8 | 7.6 | **7.4** | 8-10 |
| RSS | 219 MB | 220 MB | 220 MB | 221 MB | 223 MB |
| write syscalls/min (heartbeat) | 12 | 12 | 12 | **0** | 0 |
| child processes | none | none | none | none | none |

On a display (Xvfb, X11 like Xwayland under gamescope), where each main-loop iteration
costs far more:

| | home | game in front, before | game in front, now |
| --- | --- | --- | --- |
| CPU, ms per second | 98-100 | 98 | **47** |
| wake-ups/s, all threads | 2276 | 2240 | **1186** |
| wake-ups/s, main thread | 920 | 889 | **202** |
| write syscalls/min | 34 000 | 34 000 | **7 500** |

- Quick menu over a game (the handheld's button arriving the way InputPlumber's intercept
  delivers it, at a random moment of the main loop's sleep): median 57 ms, worst 99 ms over
  15 presses (before: median 65 ms, worst 116 ms). Most of it is building the menu; the
  sleep adds at most 33 ms.
- Sleep and wake: from Power's resume check being due to `resumed` (TDP, charge limit put
  back) 7 ms, and to the controls' replay done 8 ms, worst of 5, the same as before (7 ms).
- Home sitting idle draws nothing (0.2 frames/s: the clock and battery labels); the slow
  backdrop and hero drift stop after 30 s without input, in a game and under Reduce motion.

## What runs behind a game, and why

- **The main loop, slowed down.** `scripts/system/background_mode.gd` makes the main loop
  sleep up to 33 ms between iterations whenever nothing of ours is visible (a game, Steam or
  any other window in front), instead of 6.9 ms. It never sleeps past the next running
  Timer, wakes to full speed the moment the quick menu opens or our window comes back, and
  for 30 s after a resume from sleep.
- **Power's 15 s check** (charger plugged or not, and noticing a sleep while a game is in
  front so a firmware-reset TDP, fan table or charge limit is put back) and the **thermal
  guard** (10 s, only while GameCove holds thermald). Safety; they stay.
- **InputPlumber's intercept** (`gdbus monitor`, a child process blocked on D-Bus) so the
  quick-menu button works over the game. Event-driven, no polling.
- **Game tracking**: `xprop -spy` (one idle child process blocked on the X socket) reports
  when the game's window goes. Before, `sh` + `xprop` ran every 3 s for the whole game
  (about 6 ms of CPU per run here). The 3 s check only runs to confirm an end, or when the
  watch can't run.
- **The heartbeat Timer** ticks every 5 s but writes nothing while the file says "game"
  (the session client never treats a "game" heartbeat as stale).
- **Performance sampling** (1 s) only while Auto TDP runs; it is what Auto TDP steers by.
- Paused while a game runs: Discover refreshes, the metadata and art fill, update checks,
  Streaming's PC checks. The live top-bar refresh stops whenever our window is hidden.
- **Automatic app updates** (opt-in, off by default) start only with no game running: 3 min
  after start (one one-shot timer) or when a game ends, at most daily. If you start a game
  while one runs, Flatpak carries on at nice 19 and idle I/O priority, so it only gets what
  the game leaves over. Per-app volume, Now playing, Bluetooth devices, Clean up and GE-Proton
  read only when their page opens or you press something: no timers.
- **Collections and emulation** add no timer. Steam's collections file, Steam ROM Manager's
  `shortcuts.vdf`, EmuDeck / RetroDECK / ES-DE settings, the ROM folder counts and ES-DE's
  gamelists are read on the Library's scan thread: at start, after a rescan, and once more
  (the emulation entries only) when ES-DE, RetroDECK or an emulated game ends, to add its
  play time. Nothing of it runs while a game is in front.

`tests/e2e/suite_perf.gd` fails if the main loop runs more than 50 iterations or 70
main-thread wake-ups a second behind a game, a Timer outside that list runs there, the
quick menu takes over 250 ms, or a resume while throttled is handled later than 60 ms after
Power's check is due. `tests/test_timer_lint.gd` makes every new Timer say what it does
behind a game.

## Left for later: Godot's X11 event thread

On a display, most of what remains behind a game is Godot itself: in Godot 4.7.2 the X11
display server's event thread waits for X events with a 1 ms timeout
(`platform/linuxbsd/x11/display_server_x11.cpp`, `_poll_events()` calls
`_wait_for_events(0, 1000)`), about 1000 wake-ups a second whether the app is in front or
not (measured with an empty Godot project too). GameCove can't change that from a script;
it needs an engine build with a longer timeout while the window is unfocused.

## Measuring

On a PC (no handheld needed):

```sh
python3 -I tools/perf/measure.py                                  # 60 s per state, headless
python3 -I tools/perf/measure.py --display xvfb --seconds 30      # drawn on Xvfb (needs xvfb)
python3 -I tools/perf/measure.py --json before.json               # keep the numbers
python3 -I tools/perf/measure.py --compare before.json after.json # both in one table
```

On the handheld, with GameCove running in its session (over SSH, or from Desktop Mode's
terminal while GameCove runs in a window):

```sh
sh tools/perf/device-sample.sh 60     # home in front
# start a game, then:
sh tools/perf/device-sample.sh 60     # game in front
# open the quick menu over the game, then:
sh tools/perf/device-sample.sh 30
```

It prints CPU, wake-ups per thread, RSS, threads, writes and child processes. The real GPU
can't be measured on a CI box. On the handheld, compare the same game with GameCove running
and stopped: AMD `cat /sys/class/drm/card*/device/gpu_busy_percent` (or `amdgpu_top`),
Intel `sudo intel_gpu_top -l`, and for package power `sudo perf stat -e power/energy-pkg/
-a sleep 60` (RAPL). Behind a game GameCove draws no frames, so the GPU numbers should match.
