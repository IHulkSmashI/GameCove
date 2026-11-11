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
  delivers it, at a random moment of the main loop's sleep, to the menu's first frame):
  see "The quick menu over a game" below. Now a median of ~20-30 ms headless, worst ~45 ms,
  and still under 50 ms with a CPU hog on both cores; most of what's left is the main loop's
  sleep behind the game (at most 33 ms).
- Sleep and wake: from Power's resume check being due to `resumed` (TDP, charge limit put
  back) 7 ms, and to the controls' replay done 8 ms, worst of 5, the same as before (7 ms).
- Home sitting idle draws nothing (0.2 frames/s: the clock and battery labels); the slow
  backdrop and hero drift stop after 30 s without input, in a game and under Reduce motion.

### Home with a big library

Home is rebuilt on every library change (a rescan, an install starting or finishing), and
every tile is a small node tree built on the main thread. Its shelves had no cap, so each
ROM that Steam ROM Manager added sat in three of them (Installed, Emulation, All games).
`Home.set_games()` on a desktop CPU, headless, best of 5, 120 Steam games plus the ROMs:

| ROMs | tiles before | rebuild before | tiles now | rebuild now |
| --- | --- | --- | --- | --- |
| 0 | 159 | 47 ms | 50 | 38 ms |
| 500 | 1,659 | 517 ms | 75 | 37 ms |
| 1,500 | 4,659 | 2,355 ms | 75 | 111 ms |

A Home shelf now shows at most 24 games (`Home.SHELF_MAX`) and ends with a "See all" tile
that opens the Library on the same list; its count still says how many it holds. What's
left at 1,500 ROMs is mostly sorting the lists (`View.shelves`, about 55 ms). A handheld's
CPU is slower than the one measured, so read the table as a ratio. The Library grid itself
still builds one tile per game shown: that's the list you asked for, and it's built when
the library changes, not while a game runs.

## On a 4K screen

The layout does not grow with the pixel count: a TV is laid out 800 tall at any resolution (docs/RESOLUTIONS.md), so a 4K TV runs the same
1422x800 UI, with the same nodes and timers, as a 1080p one; only the renderer fills more pixels (the GPU's job, not measured headless).
`E2E_SCREEN=<matrix row>` runs the e2e suites as on that screen, and `suite_perf` prints its numbers (`-v`). Claw 8 EX fixture, headless,
2-core box shared with other jobs, 2026-11-11:

| Screen | Behind a game: loops/s | main wake-ups/s | CPU ms/s | Quick menu over a game (median / worst) |
| --- | --- | --- | --- | --- |
| default (1280x800 handheld) | 31.2 | 31.5 | 4.1 | 18 ms / 34 ms |
| `tv-4k-55in` (3840x2160) | 31.3 | 31.3 | 4.6 | 30 ms / 39 ms |

Budgets are 50 loops/s, 70 wake-ups/s, 30 ms CPU/s and 100 ms median / 250 ms worst; both rows pass. Display detection (`DisplayOutput`, about ten
tiny sysfs reads) runs on start, on window resize and on focus-in only: no Timer, no polling.

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
  (the session client never treats a "game" heartbeat as stale). It writes again only
  while the quick menu or Home is in front of the game ("front": one small tmpfs write
  every 5 s, so a UI that hangs there is caught), and stops when the game is back in front.
- **Performance sampling** (1 s) only while Auto TDP runs; it is what Auto TDP steers by.
- Paused while a game runs: Discover refreshes, the metadata and art fill, update checks,
  Streaming's PC checks. The live top-bar refresh stops whenever our window is hidden.
- **Automatic app updates** (opt-in, off by default) start only with no game running: 3 min
  after start (one one-shot timer) or when a game ends, at most daily. If you start a game
  while one runs, Flatpak carries on at nice 19 and idle I/O priority, so it only gets what
  the game leaves over. Per-app volume, Now playing, Bluetooth devices, Clean up and GE-Proton
  read only when their page opens or you press something: no timers. GE-Proton won't start an
  install while a game runs, and one already running carries on at nice 19 and idle I/O.
- **Collections and emulation** add no timer. Steam's collections file, Steam ROM Manager's
  `shortcuts.vdf`, EmuDeck / RetroDECK / ES-DE settings, the ROM folders and ES-DE's
  gamelists and downloaded art are read on the Library's scan thread: at start, after a rescan,
  when the Library or the Emulation page opens (at most every 20 s, never while a game runs),
  and once more (the emulation entries only) when ES-DE, RetroDECK or an emulated game ends, to
  add its play time. Nothing of it runs while a game is in front.
- **Thousands of ROMs.** The ROM list is cached per system folder with every folder's
  modification time (`user://emu/roms.cache`, each system's games kept packed): a later scan
  only compares those times. When nothing a ROM game is made from changed (the folders, the
  setup, ES-DE's custom systems, Steam ROM Manager's shortcuts, play time, picked art), the
  scan makes no game at all and the Library keeps the ones it has; a scan that finds exactly
  what's shown redraws nothing and keeps nothing new. ROMs with the same details share one
  read-only copy of them. The game database is read only when a scanned game can match it
  (never for the emulation rescan). Home's shelves show 24 games at most, then See all, and the Library grid
  makes its tiles 56 at a time as you scroll. Measured with a 160-system, 5,440-ROM folder
  (e2e `suite_emulation`, headless, 2-core box): see "ROM folders" below.
- **Cloud saves** run before a launch and after a game ends, never during one. **Battery
  history** writes one small file at game start and end, sleep, wake and the charger (a few
  sysfs reads each); **Sleep at low battery** reacts to Power's 15 s check. None adds a timer that
  keeps running; the warning's 30 s countdown runs only while it shows, and a low reading that
  comes out of nowhere gets one 5 s one-shot to be read again.
- **Recording**, only while you record (you start it; there is no always-on replay buffer):
  GPU Screen Recorder captures through KMS and encodes H.264 on the GPU's video engine, so
  the game's own frame time barely moves; GameCove's part is one thread blocked on the
  recorder's output pipe (no timer, no polling). The Clips list, the Apps scan and the
  controller batteries (UPower) are read on events while GameCove is in front, never behind
  a game. The Send to phone page runs per frame only while its code shows on screen.

- **The quick menu's This game** is built once when a game starts and brought up to date
  once when the game's window takes the screen, then waits hidden. Hidden, its rows do no
  work: a change behind the game (Auto TDP moving the TDP, say) only marks the row out of
  date, and it reads the value when the menu shows it.

- **The quick menu's Shortcuts strip** is built once (and again only when its list or the
  theme changes) and kept while the menu is closed. Opening the menu only reads memory to
  show, hide and tint its buttons (the Controls cache, Recording's state): no program and no
  D-Bus call (`suite_shortcuts.gd` checks the fake system saw nothing). The sheets (Send a
  key, Power, Force close) are made the first time one is needed.
- **Button shortcuts** cost nothing while no button is held: their presses arrive on the
  InputPlumber monitor GameCove already runs, and a hold is one one-shot Timer started on
  the press and dropped on the release. The usual shortcuts go into a profile on the same
  load as the layout, so a wake or a new pad costs no extra D-Bus call.

`tests/e2e/suite_perf.gd` fails if the main loop runs more than 50 iterations or 70
main-thread wake-ups a second behind a game, a Timer outside that list runs there, the
quick menu takes over 250 ms at worst or over 100 ms for the median of 10 presses, the
closed menu's rows do work on a change behind the game, or a resume while throttled is handled later than 60 ms after
Power's check is due. `tests/test_timer_lint.gd` makes every new Timer say what it does
behind a game.

## The quick menu over a game

It has to feel instant. Measured headless on a 2-core box (`suite_perf.gd`, 10 presses,
button event to the menu's first frame), with `open()` instrumented step by step:

| | before | now |
| --- | --- | --- |
| press to first frame, median / worst | 54 / 83 ms | 21 / 40 ms |
| the same, with a CPU hog on both cores | 136 / 184 ms | 30 / 49 ms |
| `open()` in all, median | 28 ms (91 loaded) | 3.4 ms (2.9 loaded) |
| Model.set_game (every row re-read) | 10 ms | 0.3 ms |
| building This game | 12 ms | 0.4 ms (shown as kept) |
| first focus (rebuilt the hint bar under the scrim) | 4 ms | 0.5 ms |
| waiting out the main loop's sleep behind the game | 0-33 ms | 0-33 ms |

With the Shortcuts strip in the menu (2026-11-11, on a 2-core box shared with other jobs):
press to first frame median 34 / 30 / 40 ms, worst 93 / 61 / 100 ms (Claw / Ally / Legion Go S
setups; budgets 100 and 250); behind a game 29-30 main-loop iterations, 30-31 wake-ups and
4-5 ms of CPU a second (budgets 50, 70 and 30).

No process or D-Bus call runs when it opens: the controller batteries (UPower) are read on
a worker after it shows, Now playing and per-app volume are on the Audio tab and read on
the Controls worker when that tab opens, the Record row's state is the Recording service's
own state plus a file check, and the battery pill reads two sysfs files (all of `refresh_live`
is 0.5 ms).

What changed: This game (the tab the menu always opens on) lives in its own box and is kept,
hidden, between opens and while another tab shows; it is built again only when something it
is built from changes (the game, its own settings switch, Favourite, the game starting, the
theme). `main.gd` builds it when a game starts and lets its rows catch up once when the
game takes the screen. Hidden control rows only mark themselves out of date
(`control_view.gd`, `control_list.gd`), so nothing runs for them behind the game, and the
same game again no longer makes every row read itself. Focus moving inside the menu leaves
the hint bar (under the scrim) alone. Opening still waits for the main loop's sleep to end
(BackgroundMode, at most 33 ms): Godot's sleep can't be cut short from another thread, and
the menu's first frame runs at full speed (`set_menu`).

To be measured again on real hardware.

## ROM folders

A 160-system, 5,440-ROM EmuDeck folder (e2e `suite_emulation`, headless, 2-core box; "busy" is
with a dozen other jobs on the same cores):

| | before | now (quiet / busy) |
| --- | --- | --- |
| First scan, every store, on the Library's thread | 2.5 s | 2.5 s / 5.8-6.6 s |
| Whole-Library rescan, nothing changed | 1.5 s | 0.2 s / 0.2-0.5 s (the ROM games aren't made again) |
| Emulation rescan (Library or Emulation page opening), nothing changed | 0.8 s, plus the game database when there is one | 0.15 s / 0.2-0.3 s |
| Library opened on Filter > Emulation | 330 ms (140 tiles) | 0.6 s busy (56 tiles) |
| Godot's own memory over the start, everything open | +142 MB | +54 MB |
| Process memory (RSS) peak over the start | +313 MB (555 MB in all) | +127 MB (383 MB in all) |
| An Emulation rescan with GameCove's game database present (bare process) | 1.6 GB peak | 157 MB |

What held it: every rescan read and indexed the whole game database (73 MB of JSON, well over
a gigabyte of dictionaries for a moment) though ROMs never match it; every ROM carried its own
copy of details, console line and empty art (65 MB of dictionaries, now 22 MB shared read-only);
and an identical rescan built every game again and swapped it in, so two copies lived for a
while and the worker thread's memory stayed with the process. Still true for every store: a
whole-Library rescan with Steam, Epic, GOG or Amazon games reads the game database (about
1.3 GB for a moment) when the app starts and after the database updates.

The first numbers had every tile made at once (Home's All games shelf and the Library grid):
the app ran out of memory. Now Home's shelves show 24 games and See all, and the Library grid makes 56 at a
time as focus nears the end (LT / RT letter jumps make what they land on). None of this runs
behind a game: the rescan waits until the game ends.

## Nothing waits on a slow job

The main thread never joins a worker that may still be busy: leaving a page, a theme
change (which rebuilds every Settings page) or a quick-menu tab switch never waits for a
download, an unpack, a Bluetooth scan or pairing, a recorder or player install (Settings >
Media) or the Apps scan. Those jobs belong to
`scripts/system/card_jobs.gd`, not to the card that started them; the card that is there
when one ends gets the result (looked up by instance id), and a result nobody was there for
waits for the next card. Workers hand results back with `call_deferred` and never touch a
Node themselves.

Only real app exit joins, and only after the programs are stopped: long runs (GE-Proton's
`curl`/`tar`, `bluetoothctl`, `legendary`/`gogdl`, OS and app updates, `du`) run in a stop
group (`exec_safe.gd`), and `ExecSafe.stop_group()` sends them SIGTERM, then SIGKILL after
1.5 s, so the threads waiting on them return at once. A recording still running at exit
gets SIGINT to finish its file, SIGTERM after 3 s and SIGKILL a second later before its
thread is joined. Firmware flashes (`fwupdmgr`), `pkexec`,
`systemctl` and `busctl` are never signalled and still run once the group is stopped (the
exit-time hand-back of the buttons and a key let go mid-press are `busctl` calls). Cache pruning at exit stops at the next file.
`tests/test_card_jobs.gd` fails if an `_exit_tree` outside the app-lifetime owners, or a page
rebuild path, joins a worker.

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
