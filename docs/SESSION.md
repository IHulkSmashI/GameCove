# Session, gamescope and packaging

How GameCove runs as its own gamescope session, talks to gamescope, starts Steam,
switches sessions, gets root for fixes, and is packaged. Read with
[CONTRACTS.md](CONTRACTS.md) and [ARCHITECTURE.md](ARCHITECTURE.md).

Status: everything here passes its tests against fakes and an Xvfb X server.
**Nothing has run on a handheld yet.** The checklist at the end lists what must be
tried on the Claw 8 EX before we call any of it working.

## Files

| Path | Installed to | What it does |
| --- | --- | --- |
| `app/scripts/gamescope/gamescope.gd` | (in the app) | `Gamescope` service: frame limit, refresh rate, overlay, focus |
| `app/scripts/gamescope/command_runner.gd` | (in the app) | Runs `xprop`; tests swap in a fake |
| `session/gamescope-session-plus/sessions.d/gamecove` | `/usr/share/gamescope-session-plus/sessions.d/gamecove` | Session definition (`CLIENTCMD`, fallback, Steam shutdown) |
| `session/wayland-sessions/gamecove.desktop` | `/usr/share/wayland-sessions/gamecove.desktop` | Login-screen entry "GameCove" |
| `session/systemd/gamescope-session-plus@gamecove.service.d/10-gamecove.conf` | `/usr/lib/systemd/user/…` | Pulls in steamos-manager and Bazzite's power-button daemon |
| `session/gamecove-session-client` | `/usr/libexec/gamecove/` | Starts Steam in the background, then runs the app |
| `session/gamecove-session-select` | `/usr/bin/` | Switch to Steam Gaming Mode, GameCove or desktop |
| `packaging/libexec/gamecove-fix` | `/usr/libexec/gamecove/` | Root-fix dispatcher, run with `pkexec` |
| `packaging/polkit/io.github.ihulksmashi.gamecove.policy` | `/usr/share/polkit-1/actions/` | Who may run `gamecove-fix` |
| `packaging/rpm/gamecove.spec` | | RPM for Bazzite / Fedora |
| `packaging/install.sh` | | Guided install on Bazzite (`rpm-ostree install`) |
| `packaging/sysext/build-sysext.sh` | | systemd-sysext image for SteamOS |
| `packaging/tests/run.sh` | | Shell tests + shellcheck + every `fixes/*/test.sh` |

## How gamescope is told things

Gamescope (in "embedded" / `--steam` mode, which gamescope-session-plus uses) takes
orders through **X11 window properties**, all 32-bit `CARDINAL`. This is how Steam
drives it in Game Mode, and OpenGamepadUI copies Steam.

| Atom | On | Value | Used for | Source |
| --- | --- | --- | --- | --- |
| `STEAM_GAME` | our window | `769` | Marks the main launcher window. Without any `STEAM_GAME`, gamescope shows nothing | gamescope `steamcompmgr.cpp` (`GAME_PROP`); gamescope-x11-client `OVERLAY_APP_ID = 769`; gamescope-session README |
| `STEAM_OVERLAY` | our window | `1`/`0` | Composite our window on top of the focused game (quick menu) | `steamcompmgr.cpp` `OVERLAY_PROP`, overlay pick in `determine_and_apply_focus` |
| `STEAM_INPUT_FOCUS` | our window | `1`/`0` | Send keyboard/controller/mouse to our overlay instead of the game | `steamcompmgr.cpp` `steamInputFocusAtom`; OGUI `card_ui.gd` |
| `GAMESCOPE_FPS_LIMIT` | root | fps, `0` = none | Frame limit | `steamcompmgr.cpp` (`g_nSteamCompMgrTargetFPS`); OGUI `set_fps_limit` |
| `GAMESCOPE_DYNAMIC_REFRESH` | root | Hz, `0` = panel max | Panel refresh while a game has focus | `steamcompmgr.cpp` (`g_nDynamicRefreshRate`) |
| `GAMESCOPECTRL_BASELAYER_APPID` | root | list of app ids | Which app is in front. Steam/OGUI write `[413091, <game>, 769]`; `[413091, 769]` shows home | `steamcompmgr.cpp`; OGUI `running_app.gd grab_focus`, `card_ui.gd _setup` |
| `GAMESCOPE_FOCUSED_APP` | root (read) | app id | What's in front now | OGUI `get_focused_app` |
| `GAMESCOPE_FOCUSABLE_APPS` | root (read) | list | Always present under gamescope; our `is_running()` probe | `steamcompmgr.cpp` writes it on every focus change |
| `GAMESCOPE_EXTERNAL_OVERLAY` | window | `1` | Non-interactive overlays (MangoHud's mangoapp sets it itself). **Not used by us** | `steamcompmgr.cpp`; gamescope-session-steam notes |

Notes from gamescope's source (`ValveSoftware/gamescope`, commit `89b9e6e`, 2026-11-07):

- The overlay window chosen is a `STEAM_OVERLAY` window that spans the screen width
  **or** has `STEAM_INPUT_FOCUS` set. A narrower one without input focus is treated
  as a notification.
- `GAMESCOPE_DYNAMIC_REFRESH` only changes the panel when gamescope knows its valid
  rates (a known panel, or `CUSTOM_REFRESH_RATES=…` in the session environment)
  **and VRR is off**, and only while a game (not our home screen) is focused.
  So `set_refresh_rate()` returning `true` means "gamescope accepted it", not "the
  panel switched".
- Games get an app id automatically when gamescope can find one: from the
  Steam reaper (`SteamLaunch AppId=`) or a systemd scope named
  `app-steam-app<id>-<n>.scope` (`Utils/Process.cpp`). **For the Launcher:** a
  non-Steam game started with
  `systemd-run --user --scope --unit=app-steam-app<id>-<n> …` gets a focusable app
  id with no X property work. A game with no app id isn't focusable.

What the service does (`Gamescope` autoload):

| Call | Effect |
| --- | --- |
| start (`_ready`) | If under gamescope: `STEAM_GAME=769` on our window, base layer `[413091, 769]` |
| `set_fps_limit(fps)` | root `GAMESCOPE_FPS_LIMIT`, read back |
| `set_refresh_rate(hz)` | root `GAMESCOPE_DYNAMIC_REFRESH`, read back |
| `set_overlay(open)` | our `STEAM_OVERLAY` and `STEAM_INPUT_FOCUS` = 1/0 |
| `focus_home()` / `focus_app(id)` | root `GAMESCOPECTRL_BASELAYER_APPID` |
| `focused_app()` | reads root `GAMESCOPE_FOCUSED_APP` |
| `focusable_apps()` | reads root `GAMESCOPE_FOCUSABLE_APPS` (apps with a window) |
| `is_running()` | `GAMESCOPE_WAYLAND_DISPLAY` set (gamescope-session-plus exports it), else root has `GAMESCOPE_FOCUSABLE_APPS`. Cached |

## Launching a game and giving it focus

`claim_main_window()` puts our home in front (`[413091, 769]`); nothing else
changes the base layer, so a launched game would stay behind us. The flow
(`Library.launch` + `scripts/launch/game_session.gd`):

1. **Steam:** `steam steam://rungameid/<id>` via `OS.create_process` (the running
   client takes it and the command returns). `OS.shell_open` only if `steam` isn't
   on `PATH` (Flatpak Steam), since it needs `xdg-open` and the session has no
   desktop. Gamescope gets the Steam app id from Steam's reaper.
2. **Epic / GOG / Amazon / Heroic:** the store command runs under
   `systemd-run --user --scope --collect --quiet --unit=app-steam-app<id>-<n> -- <cmd>`.
   `<id>` is `Library.app_id_for("<store>:<id>")`: the first 32 bits of the key's
   sha256 with bit 30 set and bit 31 clear, so it's stable, a positive 31-bit
   int, and can't collide with real Steam app ids, 769 or 413091. (OpenGamepadUI
   uses `hash(name) % 800483647` and a `reaper SteamLaunch AppId=` wrapper from
   its own extension, which we don't ship.) `<n>` changes per launch.
   `systemd-run` is used only when it's on `PATH` and `$XDG_RUNTIME_DIR/systemd`
   exists; otherwise the game starts plainly, with a warning: it runs but gamescope
   can't focus it.
3. **Focus:** a 0.5 s timer reads `GAMESCOPE_FOCUSABLE_APPS` until the app id is
   listed (the game has a window), then `focus_app(id)`. It gives up after 60 s
   (Steam: session over; our own launch: keep following the process).
4. **While it runs:** the game's `fps_limit` is on `GAMESCOPE_FPS_LIMIT`, Auto TDP
   runs for goals battery/balanced. A 3 s timer (only while a game runs) checks
   the focusable list and our process.
5. **End:** app id not listed and our process gone on two checks in a row:
   `focus_home()`, frame limit 0, Auto TDP stopped. The frame limit is also
   cleared when GameSession starts, so a crash never leaves home capped.

Known gaps: a Heroic launch through the **Flatpak** lands in Flatpak's own scope,
and a launch handed to an **already running** Heroic runs under Heroic's process,
so neither carries our app id. Those games run but aren't focused.

The app must run on **X11** (`--display-driver x11`, set by the session client):
our window id comes from `DisplayServer.window_get_native_handle(WINDOW_HANDLE)`.

For the quick menu to show the game *behind* it, the window needs per-pixel
transparency (`display/window/per_pixel_transparency/allowed`,
`display/window/size/transparent`, `rendering/viewport/transparent_background`).
That's a UI decision (`project.godot` isn't owned here); without it the open quick
menu is opaque, which still works.

## Decision: xprop, not a GDExtension (yet)

OpenGamepadUI sets these atoms from Godot through its Rust GDExtension
(`ShadowBlip/OpenGamepadUI`, `extensions/core`, crate `opengamepadui-core`, GPL-3.0),
which wraps `ShadowBlip/gamescope-x11-client` (GPL-3.0-or-later). The license would
let us reuse it, but:

- It's one big library: gamescope plus InputPlumber, PowerStation, NetworkManager,
  BlueZ, UPower, a process reaper, a tokio runtime. We'd ship and load all of it
  for five properties.
- It isn't released on its own. We'd either build Rust in our RPM/sysext or copy a
  binary out of OGUI's tarball and track their godot-rust ABI.
- It registers its own classes and resources (`GamescopeInstance` etc.) designed
  around OGUI's app.

`xprop` is the standard X tool, a few KB, and its commands are easy to test. We only
write atoms when something changes (a menu opens, a setting moves), so the cost of
starting a process is irrelevant and nothing polls. Verified here: real `xprop`
against Xvfb from the Godot app sets every atom above, including the array.

Revisit when we need to **watch** properties (e.g. react to focus changes without
polling): then a small GDExtension of our own on top of `gamescope-x11-client` is
the right step, and `command_runner.gd` is the seam to swap.

Needs: `xprop` (Fedora package `xprop`, required by the RPM; Bazzite installs
`xwininfo`/`xdotool` but `xprop` isn't confirmed, so the RPM pulls it in).

## The session

[gamescope-session-plus](https://github.com/OpenGamingCollective/gamescope-session)
(MIT; ChimeraOS, now OpenGamingCollective) is the shared launcher every
non-Valve gamescope session uses, Bazzite's included. A session is two files:

- `/usr/share/gamescope-session-plus/sessions.d/<name>`: bash, sourced with `set -a`;
  must set `CLIENTCMD`; may define `short_session_recover`, `post_gamescope_start`,
  `post_client_shutdown`.
- `/usr/share/wayland-sessions/<file>.desktop` with `Exec=gamescope-session-plus <name>`
  and `DesktopNames=gamescope`.

It runs as the user unit `gamescope-session-plus@<name>.service`, starts gamescope
with `--xwayland-count 2`, exports `DISPLAY` and `GAMESCOPE_WAYLAND_DISPLAY`, sources
`~/.config/environment.d/*.conf` (so users can tune `CUSTOM_REFRESH_RATES`,
`GAMECOVE_STEAM_MODE`, …), and runs `$CLIENTCMD`. After 5 sessions shorter than 60 s
it calls `short_session_recover`; ours switches to Steam Gaming Mode so a broken
GameCove never traps you on a black screen.

Bazzite today boots `gamescope-session-ogui-steam.desktop` (Steam as main client,
OpenGamepadUI as overlay; Terra packages `gamescope-session`,
`gamescope-session-steam`, `gamescope-session-ogui-steam`, `opengamepadui`,
`steamos-manager-powerstation`). Ours sits beside it.

## Steam inside our session

GameCove launches Steam games with `steam://rungameid/<id>`. That needs a running
Steam, so the session client starts one before the app. Options
(`GAMECOVE_STEAM_MODE`):

| Mode | Command | Good | Risk |
| --- | --- | --- | --- |
| `silent` (default) | `steam -silent` | Normal client, no window. Games, cloud saves, Steam Input, Shift+Tab overlay inside games | Desktop-mode Steam: its on-screen keyboard and quick menu are not the Deck ones |
| `gamepadui` | `steam -silent -gamepadui -steamos3 -steampal -steamdeck` | Steam's handheld keyboard and overlay; the flags OpenGamepadUI's Steam plugin uses (`OpenGamepadUI-steam/core/library_steam.gd`) | Steam may set `STEAM_GAME=769` on its own window and fight us for the main slot; Steam's QAM may grab the guide button |
| `off` | nothing | Lightest | No Steam games until something starts Steam |

`steam -shutdown` runs when GameCove exits (`post_client_shutdown`). Gamescope
gives Steam games their app id from Steam's reaper, so focus works without us
tagging their windows.

## Switching sessions

Bazzite and SteamOS both ship **steamos-manager** (`steamosctl`); Bazzite's
`os-session-select` and `return-to-gamemode` just call it. We reuse it, so no root
helper of our own:

- To Steam: `steamosctl switch-to-game-mode`. On Bazzite (OGC fork, `platform.rs`)
  game mode is `gamescope-session-ogui-steam.desktop`; on SteamOS
  `gamescope-wayland.desktop`. It writes a one-time SDDM autologin entry and stops
  `graphical-session.target`, which ends our session (our unit is bound to it).
- To GameCove: `steamosctl switch-to-desktop-mode gamecove.desktop`.
  steamos-manager accepts any `wayland-sessions/*.desktop` whose **name has no
  "gamescope"** as a desktop session (`is_valid_desktop_session_name`), which is why
  our file is `gamecove.desktop`.
- `--default` makes it stick across boots. Side effect: Steam's own "Switch to
  Desktop" then lands in GameCove. Undo: `steamosctl set-default-login-mode game`.

`gamecove-session-select steam|gamecove|desktop [--default]` wraps this. The UI's
"Switch to Steam Gaming Mode" button should run `gamecove-session-select steam`.

## Root fixes: `gamecove-fix`

```
pkexec /usr/libexec/gamecove/gamecove-fix <name> install|remove|status
pkexec /usr/libexec/gamecove/gamecove-fix <name> set <value>
/usr/libexec/gamecove/gamecove-fix --list
```

- `<name>` must match `[a-z0-9][a-z0-9-]*` (≤ 64) and be a real folder (not a
  symlink) in `/usr/lib/gamecove/fixes/` with a `fix.sh`. Nothing else can be named,
  so `../` and absolute paths can't escape.
- `set` values: ≤ 128 chars of `A-Za-z0-9._:,=+-`, not starting with `-`.
- Runs `sh fix.sh <action> [value]` from `/` with a fixed `PATH`, `GAMECOVE_ROOT`
  and `GAMECOVE_CHANGES_LOG` exported.
- Every `install`/`remove`/`set` is logged to `/var/lib/gamecove/changes.log`:
  `<UTC time> uid=<PKEXEC_UID> fix=<name> action=<a> value=<v|-> result=ok|fail(<code>)`.
  `status` isn't logged and its output passes straight through.
- Exit: 0 ok, 64 usage, 65 unknown fix, 66 bad value, otherwise the fix's code.
- `GAMECOVE_ROOT` / `GAMECOVE_FIXES_DIR` are for tests and are **ignored when
  `PKEXEC_UID` is set** (pkexec also clears the environment).

polkit (`io.github.ihulksmashi.gamecove.fix`): active local session `yes` (the
gamescope session has no polkit agent to ask for a password; Bazzite and OGUI do
the same for their helpers), inactive and remote `auth_admin`.

## Packaging

**Bazzite / Fedora (RPM).** `packaging/rpm/gamecove.spec` takes the repo tarball and
a CI-exported app tarball (`gamecove.x86_64` + `gamecove.pck`). It depends on files
(`/usr/bin/gamescope-session-plus`, `/usr/bin/xprop`, `/usr/bin/pkexec`), so any
provider works. On Bazzite, `packaging/install.sh` explains and runs
`rpm-ostree install ./gamecove-*.rpm`, then reboot, then
`gamecove-session-select gamecove`. Removal: `install.sh --uninstall`.
Untested: never built in mock or installed; `rpmspec -P` parses it and a local
`rpmbuild --nodeps` with fake sources builds it. rpm-ostree may warn about
`/var/lib/gamecove` in the package (the dispatcher creates it anyway).

**SteamOS (systemd-sysext).** `packaging/sysext/build-sysext.sh` makes
`gamecove.raw` (squashfs) holding our files plus gamescope-session-plus pinned at
`08e65a6` (SteamOS doesn't have it), with `extension-release` `ID=_any`,
`ARCHITECTURE=x86-64` so OS updates don't disable it (no SteamOS libraries
inside). Copy to `/var/lib/extensions/`, `systemd-sysext refresh`. Same idea as
OpenGamepadUI's `make dist-ext`. Documented, not run on SteamOS.

**CachyOS.** Later: a PKGBUILD with the same file list.

## Hardware checklist (MSI Claw 8 EX, Bazzite)

Do these in order; note results in an issue.

1. Install via `install.sh`, reboot, `gamecove-session-select gamecove`. GameCove
   appears (not a black screen). `xprop -root GAMESCOPECTRL_BASELAYER_APPID` from a
   terminal in the session (or SSH with `DISPLAY=:0`) shows `413091, 769`.
2. Kill the app 5 times quickly: session falls back to Steam Gaming Mode.
3. "Switch to Steam" lands in Bazzite's Gaming Mode; Steam's "Switch to Desktop"
   still goes to the desktop (without `--default`).
4. **Steam, `silent` mode:** Play on a Steam game runs `steam steam://rungameid/<id>`,
   the game starts and comes to the front within a second of its window
   (`xprop -root GAMESCOPECTRL_BASELAYER_APPID` shows `413091, <appid>, 769`);
   quitting returns to GameCove within ~6 s; a second launch is fast.
5. **Steam overlay:** Shift+Tab / Steam button inside a game. Does anything show?
   Does the guide button reach us or Steam?
6. **Keyboard:** a text field in a game and in Steam's login prompt. Which on-screen
   keyboard (if any) appears? Try `gamepadui` mode for comparison.
7. **Steam Input:** controller works in a Steam game with Steam Input on; per-game
   layouts apply; InputPlumber and Steam don't double inputs. Gyro (Kisenir's fix).
8. `gamepadui` mode: does Steam steal `STEAM_GAME=769` / the screen? Does its QAM
   open over our quick menu?
9. Quick menu over a game: `set_overlay(true)` shows our menu on top and takes the
   controller; `false` gives the game back. With and without transparency.
10. `set_fps_limit(30)` caps a game (MangoHud). `set_refresh_rate` with
    `CUSTOM_REFRESH_RATES` set in `~/.config/environment.d/` and VRR off.
11. Non-Steam game (legendary + umu): `systemctl --user list-units 'app-steam-app*'`
    shows the scope, `GAMESCOPE_FOCUSABLE_APPS` lists its id, the game comes to the
    front, and home comes back when it quits. The per-game frame limit applies at
    launch and is 0 again at home.
12. `pkexec gamecove-fix charge-limit set 80` from the UI: no password prompt,
    entry in `/var/lib/gamecove/changes.log`.
13. Idle power and RAM of the session vs. Bazzite's Gaming Mode.

## Sources

- gamescope: <https://github.com/ValveSoftware/gamescope> (`src/steamcompmgr.cpp`, `src/Utils/Process.cpp`)
- OpenGamepadUI: <https://github.com/ShadowBlip/OpenGamepadUI> (`core/ui/card_ui/card_ui.gd`, `core/ui/card_ui_overlay_mode/card_ui_overlay_mode.gd`, `core/global/launch_manager.gd`, `core/systems/launcher/running_app.gd`, `extensions/core`, `Makefile` `dist-ext`, `package/rpm`)
- gamescope-x11-client: <https://github.com/ShadowBlip/gamescope-x11-client> (`src/atoms.rs`, `src/xwayland.rs`)
- OpenGamepadUI Steam plugin: <https://github.com/ShadowBlip/OpenGamepadUI-steam>
- gamescope-session(-plus): <https://github.com/OpenGamingCollective/gamescope-session> (README, `gamescope-session-plus`)
- gamescope-session-steam / -ogui-steam / -opengamepadui: OpenGamingCollective and ShadowBlip repos
- steamos-manager: Valve <https://gitlab.steamos.cloud/holo/steamos-manager>, OGC fork <https://github.com/OpenGamingCollective/steamos-manager> (`session.rs`, `platform.rs`, `steamosctl.rs`)
- Bazzite: <https://github.com/ublue-os/bazzite> (`build_files/bazzite-deck/`, `system_files/deck/shared/usr/libexec/os-session-select`, `bazzite-autologin`, `holo.conf`)
- Terra packages: <https://github.com/terrapkg/packages> (`anda/games/gamescope-session*`, `steamos-manager-powerstation`)
- systemd-sysext: <https://www.freedesktop.org/software/systemd/man/latest/systemd-sysext.html>
