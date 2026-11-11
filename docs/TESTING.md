# Testing GameCove

Every thing a player can do, and the test that does it. Two layers:

- **Headless journeys** (`app/tests/e2e/`): the real app on three fake handhelds (MSI Claw 8 EX on
  Bazzite, ROG Ally on SteamOS, Legion Go S on Bazzite) and a Steam Machine on SteamOS (the suites that fit
  a box, `run.py` BOX_SUITES), driven only through controller input events
  (plus touch and a physical keyboard where the app takes them), checked on what's on screen, the state
  files, and the commands the fake system and the fake store tools received. Runs anywhere, in CI.
- **Device journeys** (`tools/devicetest/`): the same journeys on the real handhelds, with a virtual
  gamepad, against the real system. Run from the browser terminal the testbed opens
  ([TESTING-HARDWARE.md](TESTING-HARDWARE.md)).

Unit tests (`app/tests/test_*.gd`, 1,400+) sit under both; the matrix names them where they are the
main cover.

## Running the headless tests

```
G=/path/to/Godot_v4.7.2-stable_linux.x86_64
python3 -I app/tests/e2e/run.py --godot $G                         # every suite, all three handhelds
python3 -I app/tests/e2e/run.py --godot $G --suites journeys       # the user journeys
python3 -I app/tests/e2e/run.py --godot $G --suites monkey --iters 20 --seed 7   # random journeys
E2E_SOAK=1 python3 -I app/tests/e2e/run.py --godot $G --suites monkey            # soak: 200 runs
python3 -I app/tests/e2e/run.py --godot $G --setups ally-steamos --test own_settings  # one journey
```

Each handheld runs in its own processes with a private HOME and XDG folders; the journeys and the
monkey get a process of their own (they bring the player's stores along). The seed is printed; a
failing random run is replayed with `--seed <seed> --iters 1`. No process may be left behind (the
driver checks), and every test ends with the safety invariants of `checks.gd`.

How long (a two-core machine also running other jobs; a quiet one is about half):

| Run | Claw 8 EX | ROG Ally | Legion Go S |
| --- | --- | --- | --- |
| `--suites journeys` (24 journeys) | 2 min | 3 min | 3 min |
| `--suites monkey` (CI, 5 runs of 70 steps) | 2 min | 2 min | 3.5 min |

### How a journey works

`suite_journeys.gd` extends `journey_case.gd`: a player's hands only. Buttons (`a()`, `b()`, `x()`,
`y()`, `lb()`, `rb()`, `lt()`, `rt()`, `start_btn()`, `view_btn()`, `hold()`), the handheld's Guide and
Quick Access buttons the way InputPlumber's intercept delivers them (`guide()`, `qam()`), touch
(`tap()`), and a keyboard (`key()`, `type_keys()`). Finding a node is allowed, to know where to steer;
getting there is `nav_to()`: D-pad presses toward it, one at a time, walking the page's focus chain when
steering doesn't get closer.

`stores_world.gd` puts the player's games on the fake handheld: Steam (two library folders, the SD
card, a fake Steam client that acts on `steam://` URIs and writes play time), Epic through legendary,
GOG through gogdl, Amazon through nile. The tools are `fakebin/fakestore.py` under each name, first on
PATH: the real StoreManager starts them and parses their real progress lines. The fake system also
answers GameCove's upscaling helper and has lsfg-vk and Lossless Scaling.

`suite_monkey.gd` mashes everything (D-pad, face buttons, bumpers, triggers, Start, View, Guide,
Quick Access, holds, keys, taps, a game quitting by itself) with the stores attached. After every step:
the safety checks (power limits inside the handheld's range, no real system path, every service on the
fixture, no command on the main thread) and focus visible and on screen. Every ten steps: no script
error, every settings file still parses, B and Guide always get back to Home (or the game), the quick
menu opens within its budget. Behind-a-game budgets are `suite_perf.gd`'s (tight, measured), and every
timer behind a game is in `test_timer_lint.gd`.

## Running on the handhelds

On each handheld (the testbed's `prepare` put the repo in `~/src/GameCove`; `console --keep` opened the
browser terminal):

```
sh ~/src/GameCove/tools/devicetest/devicetest.sh update            # the ref under test
sh ~/src/GameCove/tools/devicetest/devicetest.sh plan --allow-install-game --allow-sleep --rtc
sh ~/src/GameCove/tools/devicetest/devicetest.sh run  --allow-install-game --allow-sleep --rtc
sh ~/src/GameCove/tools/devicetest/devicetest.sh report            # the last report again
```

`plan` lists the suites, their minutes and what needs the owner, and announces every password
prompt first (only the installer with `--allow-install-build` and the timed wake with `--rtc`;
nothing types a password). Results: `~/gamecove-devicetest/<date>-<device>/report.txt` (PASS / FAIL /
WARN / SKIP / MANUAL lines and a summary), `results.tsv`, `evidence/<suite>/` (screenshots taken through
gamescope, logs, read-backs, CPU and memory samples). Every suite restores what it changed; the virtual
pad is removed when it ends.

| Suite | Min | What it does | Needs |
| --- | --- | --- | --- |
| build | 1 | the installed build (and `--allow-install-build`: the real installer for `$GAMECOVE_EXPECT_TAG`) | password with the flag |
| controls | 3 | TDP, fan mode, charge limit, brightness, volume set through the real Controls, read back from sysfs / D-Bus, put back; before/after snapshots | — |
| steam-game | 10 | a free Steam game (`DT_APPID`, default 480 Spacewar) installed (Steam's dialog answered with A), launched, Guide for the quick menu over it, B back, GameCove's CPU and memory behind it, quit, uninstalled | `--allow-install-game` |
| optiscaler | 4 | OptiScaler into a free DX12 game (`DT_DX12_APPID`) and out through GameCove's upscaling helper; the folder as it was | an installed free DX12 game |
| sleep | 2 | the testbed's suspend check: values, InputPlumber, network before vs after | `--allow-sleep`; `--rtc` (password once) or the power button |
| session | 1 | session state; with `--allow-session-switch` the steps to Steam and back, then the way back checked | hands with the flag |
| recording | 1 | GPU Screen Recorder records 5 s like the quick menu's Record; the clip is there | — |
| emudeck | 2 | EmuDeck's ROM folders, up to three ROMs started with EmuDeck's launchers, screenshot, closed (the Claw has three homebrew ROMs) | — |
| perf | 1 | GameCove at Home over 30 s: under 2 % CPU (the steam-game suite checks it behind a game: under 3 %) | GameCove's session |
| input | 1 | the virtual pad appears, focus moves, Guide opens the quick menu, RB walks tabs, B closes, the pad is gone after | GameCove's session; eyes on the screenshots |

The virtual pad (`tools/devicetest/vpad.py`): a uinput gamepad through python-evdev (Bazzite ships it)
or the kernel's ioctls with the standard library, or InputPlumber's composite device over D-Bus for the
handheld's own Guide and Quick Access buttons. `python3 vpad.py check` says which works. Tests:
`sh tools/devicetest/test.sh` (a full dry run against a temp home with stand-ins; shellcheck in CI).

## Coverage matrix

`J:` a journey in `suite_journeys.gd`, `M:` the monkey, `E:` another e2e suite (`suite_<name>.gd`),
`U:` unit tests, `D:` a device suite. **Pending merge**: the feature is on its own branch; the
journey is a skipped stub (`test_pending_*`, listed as `E2E SKIP ... (pending merge)`).

### First boot, setup, installer

| Action | Headless | Device |
| --- | --- | --- |
| First boot opens setup by itself | J: first_boot_setup_by_pad_with_a_store_sign_in | — |
| Setup: Welcome, Look (theme by D-pad), Stores, Game art, Keys, Device fixes, Done | J: first_boot_setup…; U: test_installer_ui, test_system_setup | — |
| Store sign-in with a typed code (legendary auth) | J: first_boot_setup… | — |
| Store sign-in from Settings > Stores (Epic, GOG, Amazon, Steam) | U: test_system_setup, test_ui_settings | — |
| Run setup again (Settings) | U: test_installer_ui (first-run flow skips) | — |
| Installer Easy to Done | J: installer_easy_and_custom_by_pad | D: build (`--allow-install-build`) |
| Installer Custom, every step | J: installer_easy_and_custom_by_pad; U: test_installer_ui, test_installer_plan | — |
| Installer: maintenance, update, repair, change | U: test_installer_ui, test_installer_service | — |
| Remove GameCove keeping the settings | J: installer_remove_keeping_or_not_the_settings | — (testbed `uninstall`) |
| Remove GameCove and its settings | J: installer_remove_keeping_or_not_the_settings; U: test_installer_commands | — |

### Library

| Action | Headless | Device |
| --- | --- | --- |
| Every store's games in the Library | J: library_shows_every_store; U: test_library_stores | — |
| Order (X, Filter > Order) | J: library_order_search_favourite_collection_hide | — |
| Search (Y): physical keyboard, on-screen keys, delete, Done | J: library_order… | — |
| Store chips, Installed filter, genre, critic filter | U: test_ui_screens, test_ui_logic; M | — |
| Favourite / unfavourite (Start on a tile, the page's star) | J: library_order…; E: library | — |
| New collection, add, view, rename, delete | J: library_order…; U: test_collections | — |
| Hide, Hidden view, show again | J: library_order…; E: library | — |
| Letter jumps (LT / RT) | J: library_order… | — |
| Steam collections (read-only) | U: test_collections | — |
| Touch a tile / anywhere | M (taps) | — |

### Installing and managing games

| Action | Headless | Device |
| --- | --- | --- |
| Install Epic with drive pick, progress, pause, resume | J: install_epic_pause_resume_finish | — |
| Cancel from Downloads (X pause, Resume, Cancel asks) | J: install_cancel_from_downloads | — |
| Install GOG (gogdl), Amazon (nile) | J: install_gog_and_amazon | — |
| A failed install says why | J: install_failure_says_why | — |
| Install a Steam game (Steam's dialog, its progress) | J: steam_install_finishes_an_interrupted_download | D: steam-game |
| Verify, Steam store page, Steam properties | J: steam_manage_verify_update_move_uninstall | — |
| Update needing Steam control says why | J: steam_update_without_steam_control_says_why | — |
| Move to the SD card | J: epic_move_to_sd_card_then_uninstall_keeps_saves; U: test_store_manager, test_store_commands | — |
| Uninstall (No first; saves kept) | J: epic_move…, steam_manage…; U: test_saves_safety | D: steam-game |
| Launch options, compatibility tool, GE-Proton | U: test_ui_games, test_extras_proton, test_launch_proton | — |
| Queue order, downloads list | U: test_store_queue, test_card_jobs | — |

### A game: its page, its settings, playing it

| Action | Headless | Device |
| --- | --- | --- |
| Game page from the Library / Home; B back to the tile | J: install_epic…, library_order…; E: game, animations | — |
| Use settings for this game; Edit into the quick menu | J: game_page_own_settings_then_play_with_them; E: profiles | — |
| Per-game TDP, frame limit | J: game_page_own_settings… | D: controls |
| Upscaler, frame generation, Native (back to the game's own) | J: game_page_own_settings… (the helper puts it in and takes it out) | D: optiscaler |
| Lossless Scaling frame generation | J: game_page_own_settings…; U: test_perf_controls | — |
| Launch settings (goal), the goal keeps the card's frame limit | J: game_page_own_settings…; U: test_ui_screens | — |
| Game settings off (asks first) | J: game_page_own_settings… | — |
| Play; the game's settings on the system; everyday after | J: game_page_own_settings…, play_quick_menu_every_tab_exit_and_play_time; E: profiles | D: steam-game |
| Quick menu over the game, every tab (RB / LB) | J: play_quick_menu…; E: quick_menu | D: steam-game, input |
| Guide: Home over the game and back | J: play_quick_menu…, presses_for_the_game…; E: game | D: input |
| Presses meant for the game never reach our screens | J: presses_for_the_game_never_reach_our_screens | — |
| Exit game (asks first) | J: play_quick_menu…; E: game | D: steam-game |
| Play time and Jump back in after a game (every store) | J: play_quick_menu…; U: test_playtime_stores | — |
| Cloud save conflict, upload at the end, Epic waits for its save | E: saves; U: test_cloud_saves, test_saves_service | — |
| Achievements, Steam insights, metadata | U: test_achievements_steam, test_steam_insights, test_metadata, test_ui_metadata | — |
| Art picker | J: every_screen_by_pad…; U: test_artwork | — |
| Steam's controller settings and back | E: steam_trip | — |

### Quick menu, settings, the handheld

| Action | Headless | Device |
| --- | --- | --- |
| Every quick-menu control this handheld has, changed on the system | E: quick_menu (test_quick_controls_change_the_system) | D: controls |
| Y: the tab's Settings page | E: quick_menu | — |
| Every Settings page walked by pad, focus on screen | J: settings_every_page_walked_changed_and_put_back | — |
| Every control on the control pages, read back | E: settings | D: controls |
| Theme, match art, reduce motion, menu side, sounds | J: settings_every_page… | — |
| Power: TDP, boost, profile, Auto TDP, fan, charge limit, battery saver | E: settings, profiles, robustness; U: test_power_* | D: controls |
| Temperature limit | J: settings_thermal_limit_reaches_the_system; U: test_power_controls | D: controls |
| Display: brightness, refresh, VRR, colour, scaling, HDR | E: settings; U: test_ctl_display | D: controls (brightness) |
| Audio: volume, mute, outputs, microphone | E: settings; U: test_ctl_audio_system | D: controls (volume) |
| Controller: emulation, gyro, back buttons, sticks, lights, mouse mode | E: settings; U: test_controls_controller, test_input_* | D: input |
| Profiles (per game, battery / plugged in) | E: profiles; U: test_controls_profiles | — |
| Battery and charger changes | E: profiles, robustness | — (testbed `power-source`) |
| Sleep and wake, mid-game | J: over_a_game_record_a_clip_sleep_wake_and_switch_sessions; E: robustness | D: sleep |
| Switch to Desktop / Steam and back | J: over_a_game…; E: quick_menu | D: session |
| Recording a clip, Clips in Settings > Media | J: over_a_game…; U: test_extras_recording, test_extras_clips | D: recording |
| Fixes page: apply, undo, needs the password | J: fixes_page_apply_then_undo; U: test_fixes, test_ui_device_fixes | — (testbed `device`) |
| Device: about, storage, updates | U: test_ui_device_pages, test_system_storage, test_system_updates | — |
| Low battery warning | E: game | — |

### Other screens

| Action | Headless | Device |
| --- | --- | --- |
| Home: hero, shelves | J: every_screen_by_pad_discover_stream_apps_emulation_art; E: animations | D: input |
| Discover: For you, deals, coming soon, offline / loading | J: every_screen_by_pad…; U: test_discover_* | — |
| Wishlist: import, remove | U: test_discover_ui | — |
| Stream: hosts, pair, settings | J: every_screen_by_pad…; U: test_streaming_* | — |
| Apps: the list, pin to Home | J: every_screen_by_pad…; U: test_extras_apps | — |
| Emulation page (EmuDeck / RetroDECK) | J: every_screen_by_pad…; E: library; U: test_emulation | D: emudeck |
| Every screen with RB and back | E: screens, animations | — |

### Shortcuts, button shortcuts, the keyboard, emulated games

| Action | Headless | Device |
| --- | --- | --- |
| The quick menu's Shortcuts strip over a store game (one Up, Screenshot, Keyboard) | J: shortcuts_strip_over_a_store_game; E: shortcuts | D: input |
| Every shortcut on the system (key to the game, mute, sleep, force close, power); Settings > Quick menu | E: shortcuts | — |
| Quick Access in a game: short press our menu, hold Steam's keyboard; Button shortcuts page | E: buttons | D: input |
| The on-screen keyboard: a game's launch options typed on a keyboard and on its keys | J: keyboard_launch_options_typed_two_ways; E: keyboard; U: test_osk | — |
| The keyboard everywhere it opens (search, a key, wishlist name, a streaming host) | E: keyboard | — |
| Every ROM as a game: Filter > Emulation > a console, its page, Play through EmuDeck's launcher, favourite | J: rom_library_by_pad_filter_a_console_open_and_play; E: emulation | D: emudeck |
| Thousands of ROMs: scan and Library budgets | E: emulation (test_five_thousand_roms) | — |
| Fixes lifecycle: updates with rollback, withdrawn and obsolete fixes | E: fixes; U: test_fixes | — (testbed `device`) |
| Upscaling selection (Best / My choice / Native) | J: game_page_own_settings…; U: test_perf_controls | D: optiscaler |
| The launch splash: cancel, a late game closed again, Home after Guide | E: game, animations | D: steam-game |

### Docked to a TV, the Steam Machine

| Action | Headless | Device |
| --- | --- | --- |
| Docked to a 4K TV: Interface size by pad, saved, the layout follows, undocked back | box_tv: test_docked_to_a_tv_interface_size_by_pad_then_undocked (every setup, the Steam Machine too) | — |
| Every screen on a TV by pad, focus on screen | box_tv: test_every_screen_on_a_tv_by_pad | — |
| A box: no battery or handheld power controls, device wording, HDMI-CEC | E: box | — |
| Screens at every resolution and screen size | U: tests/layout (layout matrix); `E2E_SCREEN=<row>` runs any suite as on that screen | — |

No feature is pending merge now: the runner still skips any `test_pending_*` journey written ahead of a
branch and lists it as `E2E SKIP ... (pending merge)`.

## Bugs the journeys found

Each has its own commit and a regression test (named in the commit):

- Play time: Epic, GOG and Amazon games GameCove starts had no play time; a Steam game's new play time
  showed only after a full rescan (Jump back in kept the old game).
- The on-screen keyboard took keys while fading out (X right after Done deleted a letter of the search).
- Hiding the focused game left nothing focused in the Library.
- Game page: the D-pad couldn't reach Game settings once the cards were dealt into three columns (stale
  focus links, an engine error on every press).
- Sheets: what a pick opened (Steam's card, the keyboard) gave focus back to a row of a closed sheet.
- Steam's card: B left nothing focused when the page rebuilt its buttons meanwhile.
- Moving a game to a fresh SD card failed (its Games folder didn't exist yet).
- A Controls detection stopped half way when the registry was replaced under it
  (`Invalid access to key 'power.thermal_limit'`), leaving controls undetected.
- Settings pages never scrolled to the focused row (the focus follower disconnected when the scroll
  was wrapped in its fade mask).
- Discover left nothing focused while deals loaded or offline.
- Setup ending left nothing focused.
- Behind a game, the player's presses moved focus and pressed buttons on GameCove's hidden screens.
- Apps: opening the list left focus on the hidden Apps button.
- Stream: switching to the tab could leave nothing focused (discovery rebuilt it first).
- A new launch goal replaced the game's own frame limit at the next launch (Legion Go S: 15 fps became 60).
- X (a new order) or a Filter pick with a tile focused left nothing focused.
- Stream: the tab could still miss focus while the screen before it slid out.
- The rewritten keyboard (merged later) took keys while fading out again.
