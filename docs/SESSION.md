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
| `packaging/polkit/io.github.ihulksmashi.gamecove.policy` | `/usr/share/polkit-1/actions/` | Who may run `gamecove-fix` and `gamecove-fix-set` |
| `packaging/rpm/gamecove.spec` | | RPM for Bazzite / Fedora |
| `packaging/install.sh` | | Guided install on Bazzite (`rpm-ostree install`) |
| `packaging/get-gamecove.sh` | `/usr/libexec/gamecove/` | Installer bootstrap (`curl … \| bash`), see "Installer" below |
| `packaging/libexec/gamecove-apply-choices` | `/usr/libexec/gamecove/` | Applies the installer's startup choice once the package is live |
| `packaging/installer/*.desktop` | `/usr/share/applications/` | "GameCove Installer" app entry |
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
   listed (the game has a window), then `focus_app(id)`. After 60 s without a
   window, our own launch keeps following its process; a Steam launch keeps waiting
   while Steam's reaper for it runs (`pgrep -f "SteamLaunch AppId=<id>( |$)"`, every
   3 s): shader pre-caching, an update or a launcher can take minutes. The profile and
   Auto TDP stay on and the window gets focus when it appears. The session ends when
   the reaper is gone twice in a row (Controller.end_game hands input back).
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
GameCove never traps you on a black screen. The session client adds a tighter
guard (3 unclean exits in a row), see "If GameCove won't let you out".

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
- `--default` makes it stick across boots. steamos-manager boots "desktop mode"
  into its *default desktop session*, so GameCove has to be that default, and any
  "switch to desktop" that doesn't name a session would then land in GameCove.
  The rules that keep Desktop Mode reachable:
  - `--default` first saves the default desktop session and boot mode it replaces
    (`~/.local/share/gamecove/prev-desktop-session`, `prev-login-mode`).
  - `gamecove-session-select desktop` (the quick menu's **Switch to Desktop Mode**)
    always names the real desktop: the saved session, else Plasma/GNOME from
    `get-valid-desktop-sessions`.
  - Steam's "Switch to Desktop": on Bazzite it runs `os-session-select plasma`,
    which names `plasma.desktop`/`gnome.desktop` itself. Where Steam asks
    steamos-manager for the *default* desktop instead, the switch lands in our
    session; `gamecove-session-select steam` (or `desktop`) left a marker (with the
    boot id), so the session client sees that nothing asked for GameCove and
    forwards to the real desktop before the app starts (`session-start`, exit 3).
    The marker lasts the whole boot (review L22: Desktop, back to Gaming Mode, then
    "Switch to Desktop" again still reaches the desktop) until `gamecove` is asked for.
    "Asked for" also covers picking GameCove at the login screen: that session's PAM
    service is `sddm` (`loginctl show-session $XDG_SESSION_ID -p Service`), while every
    switch arrives through `sddm-autologin`, so it stays in GameCove and the marker is
    cleared. One case can't be told apart from Steam's switch and still goes to the
    desktop: logging out of the desktop while GameCove is the boot default (both are an
    autologin into the default session). The **GameCove** entry in the app menu and on
    the desktop runs `gamecove-session-select gamecove`, which always works.
  - `steam --default` and `restore` put the saved desktop session and boot mode
    back. The installer's Uninstall runs `restore`.
  - `--default` also keeps a copy of the script in the data folder and enables a
    user unit, `gamecove-session-guard.service`, that runs `guard` at every login:
    if `gamecove.desktop` is gone (package removed, previous deployment booted) it
    puts the previous defaults back but stays, marked `default-suspended`: when
    GameCove's session is back at a later login (it was only missing for a boot, e.g.
    a SteamOS update that didn't merge the sysext) it makes GameCove the default
    again (review L24). `restore` (uninstall) and `steam --default` remove it. Both
    live in the home folder, so they survive the package.

`gamecove-session-select steam|gamecove|desktop [--default] | restore | guard` wraps this.

### The boot default never names a missing session (review H4)

SDDM looks the autologin `Session=` up in its session folders; if the file isn't
there it logs "Unable to find autologin session entry" and shows the login screen
(`src/daemon/Display.cpp`), which on a handheld is a password prompt with no
keyboard. The login guard above can't help, it runs after a login. So:

- **Bazzite:** `rpm-ostree install --apply-live` only overlays the running `/usr`;
  the deployment that boots next is staged. `gamecove-session-select gamecove
  --default` refuses (exit 4) until the booted deployment holds `gamecove.desktop`
  (`ostree admin --print-current-dir`, else `rpm-ostree status --booted --json`),
  so the installer's `STARTUP=gamecove` stays in `pending-choices` and the login
  unit applies it after the reboot. Each ostree deployment has its own `/etc`, so a
  rollback boots the `/etc` from before, which never named GameCove.
- **Uninstall:** the installer's `session_restore` and `fix_remove_all` must succeed
  before the package goes (a failure stops the uninstall); `install.sh --uninstall`
  runs `gamecove-session-select restore` and `gamecove-fix --remove-all` first and
  stops if either fails.
- **SteamOS and Bazzite:** the installer copies `gamecove-autologin-guard` and its unit out of
  GameCove's files into `/etc/gamecove/` and `/etc/systemd/system/` (on SteamOS listed in
  `/etc/atomic-update.conf.d/gamecove.conf`; on Bazzite in the same root command as
  `rpm-ostree install`, from `/usr` when the layer is live, else from the deployment
  rpm-ostree just staged). On Bazzite it covers a layer taken off by hand
  (`rpm-ostree uninstall gamecove`) while GameCove is the boot default: without it the
  login screen stops at a password prompt, because the user-level guard only runs after a
  login. A copy that fails stops the install. It runs as root after
  `systemd-sysext.service` and before the display manager, and if an autologin entry
  names `gamecove.desktop` while no session folder holds it, points it at
  `gamescope-wayland.desktop` (Steam Gaming Mode; on Bazzite
  `gamescope-session-ogui-steam.desktop`, else any other gamescope session), else the
  desktop. Uninstall removes it (a layer removed by hand leaves it in `/etc`, where it
  does nothing once no autologin entry names GameCove).
- **Display settings for the session:** uninstall also takes away
  `~/.config/environment.d/80-gamecove-display.conf` (rotation, the refresh-rate unlock,
  HDR), which every gamescope session reads, Steam Gaming Mode included. With "Keep my
  settings" a copy waits in `~/.local/share/gamecove/display-session.conf` and the next
  install puts it back.

### Leaving GameCove's session (review H2)

A switch logs the session out, which stops gamescope-session-plus with a signal, so
`post_client_shutdown` never runs and Godot gets no `_exit_tree`. So
`gamecove-session-select steam|desktop`, when run from GameCove's session (the session
file exports `GAMECOVE_SESSION=1`), first runs `gamecove.x86_64 --headless --
--restore-baseline` (the everyday values back in place of a running game's, bounded to
35 s), then the charge-limit release and power-tune restore through the no-password
helper, then `steam -shutdown`, then switches. The root restores run in one background
job waited for at most `GAMECOVE_ROOT_WAIT_S` (10 s), here and in
`post_client_shutdown`: `timeout pkexec` only killed pkexec, never its root child.
A restore that fails never holds the next one up: each runs by itself, and a failure ends
the wait at once.

What goes back, in order:

1. In the app, before the switch starts (quick menu): Power stops everything that keeps
   writing (`Power.request_leave`: Auto TDP with its levers put back, the charge hold, the
   thermald hold, the 15 s check, the thermal guard), so nothing of ours lands after the
   restores. If the switch fails or never comes, `request_cancel_leave` turns it back on. The
   quick menu waits up to 75 s for `gamecove-session-select` and 20 s more for the logout.
2. `--restore-baseline`: the everyday values in place of a running game's (Profiles), then
   **the TDP, boost and fan mode the handheld had before GameCove** (`Power.restore_before`).
   Power notes them at every start, before it applies GameCove's own
   (`power_before.json` next to `power.cfg`, once per boot, so a GameCove that restarts
   keeps the first record). The TDP is never put past the current power source's limit, a
   fan curve from another tool ("custom") can't be put back, and nothing is remembered as
   your choice: GameCove's own profile is what it applies the next time it starts.
3. The root helper: the charge limit released, power-tune values restored, thermald started.

### If GameCove won't let you out

- **Crash loop:** the session client counts unclean exits in a row (a non-zero
  exit it didn't cause, a missing binary) in `~/.local/share/gamecove/crash-count`,
  across sessions and however long each run lasted (review M4: a crash a minute
  after every start used to slip through a 2-minute window). Three in a row and it
  switches to Steam Gaming Mode for this boot (the desktop if Steam isn't
  installed). A clean exit, or a run that stays up 10 minutes
  (`GAMECOVE_HEALTHY_S`), starts the count over. If the count can't be saved
  (home full or read-only) it switches away at once. The reason goes to
  `crash-fallback`. gamescope-session-plus's own guard (5 sessions under 60 s,
  in `/tmp`, so it forgets on reboot) also switches to Steam, through
  `gamecove-session-select steam`; it's the backstop for a session that never gets
  as far as our client.
- **Hang** (review H1): the client also stops an app that is alive but stuck. If
  the first heartbeat (`$XDG_RUNTIME_DIR/gamecove-heartbeat`, `GAMECOVE_HEARTBEAT`,
  written at the end of the main scene's start) doesn't appear within 60 s
  (`GAMECOVE_READY_TIMEOUT_S`; the earlier `gamecove-steam-ready` file counts only
  when no heartbeat is expected), or the heartbeat stops changing for 30 s
  (`GAMECOVE_HEARTBEAT_STALE_S`), it kills the app and counts an unclean exit.
  The app (`scripts/system/session_health.gd`) rewrites the heartbeat every 5 s
  from a main-loop Timer as `<sequence> ui|game|front`. While a game runs it says `game`
  and is never killed, so a long load (or gamescope holding back frames from a
  hidden window) can't end the session and the game with it. `front` is a game that
  runs with GameCove's own UI in front of it (the quick menu is open, or Home was
  brought back): there the screen and the controller are GameCove's again, so the
  heartbeat beats every 5 s as in `ui`, and if it stops for 45 s
  (`GAMECOVE_HEARTBEAT_FRONT_STALE_S`) the app is stopped too. A game that is still
  starting stays `game` until its window has had the screen once.
- **Telling you why:** after a fallback, the next GameCove start shows a notice
  ("GameCove closed unexpectedly 3 times in a row, so Steam started instead") from
  `crash-fallback`, then deletes it.
- **From a TTY** (Ctrl+Alt+F3 with a keyboard, or SSH), logged in as yourself, not root:

  ```
  gamecove-session-select restore    # boot and desktop defaults from before GameCove
  gamecove-session-select desktop    # leave GameCove for the desktop now
  ```

  If steamos-manager doesn't answer (it starts it as a user unit when it can),
  the root fallback is the autologin file it writes:
  `printf '[Autologin]\nSession=plasma.desktop\n' | sudo tee /etc/sddm.conf.d/zz-holo-autologin.conf`
  (`zz-steamos-autologin.conf` if that one exists), then `sudo systemctl restart sddm`.
- **At the login screen** pick Plasma or Steam (touch works).

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

polkit has two actions, picked by the program pkexec runs:

| Action | Program | Who | Allows |
| --- | --- | --- | --- |
| `io.github.ihulksmashi.gamecove.fix-set` | `/usr/libexec/gamecove/gamecove-fix-set` | active local session: `yes` (no password); inactive / remote: `no` | `set` and `status` only: `charge-limit` 50-100 / release, `fan` auto / quiet / max / curve, `power-tune` boost, epp, governor, cpumax, gpulevel, gpumin, gpumax, gpuprofile, sppt, fppt, platform, tau, battery, restore and thermald hold / release (a hold ends by itself when no game runs), `controller-led`, `controller-rumble` 0-100 / off / low / medium / high, `claw8ex-gyro` accel-on / accel-off, `claw8ex-gyro` / `claw8ex-buttons` refresh |
| `io.github.ihulksmashi.gamecove.fix` | `/usr/libexec/gamecove/gamecove-fix` | `auth_admin_keep` | everything else: every install and remove (the small udev-rule / session-file fixes too), `power-tune` smt, cores, sleep, mcu, `--remove-all` |

Why each setting is on one side or the other: [SYSTEM.md](SYSTEM.md), "GameCove's root actions".

The gamescope session has no polkit agent, so it can't ask for a password: in
Gaming Mode only the `fix-set` actions work, and pkexec on the full helper fails
(126/127). The Device page says so and points to Desktop Mode, where the desktop's
polkit agent asks. `status` needs no root and runs without pkexec.

## Packaging

**Bazzite / Fedora (RPM).** `packaging/rpm/gamecove.spec` takes the repo tarball and
a CI-exported app tarball (`gamecove.x86_64` + `gamecove.pck`). It depends on files
(`/usr/bin/gamescope-session-plus`, `/usr/bin/xprop`, `/usr/bin/pkexec`), so any
provider works. On Bazzite, `packaging/install.sh` explains and runs
`rpm-ostree install ./gamecove-*.rpm`, then reboot, then
`gamecove-session-select gamecove`. Removal: `install.sh --uninstall`.
The Release workflow builds it with `rpmbuild` in a pinned Fedora container (not in mock). Tested on hardware:
MSI Claw 8 EX AI+ (Bazzite) and ASUS ROG Ally (SteamOS). rpm-ostree may warn about
`/var/lib/gamecove` in the package (the dispatcher creates it anyway).

**SteamOS (systemd-sysext).** `packaging/sysext/build-sysext.sh` makes
`gamecove.raw` (squashfs) holding our files plus gamescope-session-plus pinned at
`08e65a6` (SteamOS doesn't have it), with `extension-release` `ID=_any`,
`ARCHITECTURE=x86-64` so OS updates don't disable it (no SteamOS libraries
inside). Same idea as OpenGamepadUI's `make dist-ext`. Built and checked by the Release workflow; not run on a SteamOS
handheld yet (hardware testing so far was on Bazzite).

Where the image lives on SteamOS, and why (checked against SteamOS 3.8 / steamos-manager v26.4):

- `/var` is a small partition per OS slot, and since SteamOS 3.6 an OS update keeps only the `/etc` changes
  listed in `/etc/atomic-update.conf.d/*.conf` (one path or glob per line; Igalia's "Keeping your system-wide
  configuration files intact after updating SteamOS"; Determinate's Nix installer does the same). So the image
  goes to `/home/.steamos/offload/gamecove/gamecove.raw` (root-owned, on the big home partition, beside
  SteamOS's own offload folders; Nix keeps `/nix` in `/home/.steamos/offload/nix`), is linked from
  `/etc/extensions/gamecove.raw` (a systemd-sysext search path; `systemd-sysext.service` runs after
  `local-fs.target`, so `/home` is mounted), and `/etc/atomic-update.conf.d/gamecove.conf` keeps that link and
  `systemd-sysext.service`'s enable link (`sysinit.target.wants`), which SteamOS doesn't enable by itself.
  An older install's `/var/lib/extensions/gamecove.raw` is removed on reinstall.
- The image is root-owned and never in a user-writable place: it carries the polkit policy and the
  prompt-free `gamecove-fix-set`.
- While SteamOS installs an update, its updater unmerges system extensions until the reboot (steamos-extension
  loader notes): GameCove's files are gone from `/usr` until you restart. The app keeps running, but session
  switching and root actions fail until then, so restart right after a SteamOS update.
- Session switching uses Valve's steamos-manager (`SessionManagement1`, v25.9+): `steamosctl
  switch-to-desktop-mode gamecove.desktop`, `get-valid-desktop-sessions`, game mode is
  `gamescope-wayland.desktop`. Since SteamOS 3.8 Steam's own "Switch to Desktop" goes through steamos-manager
  too (the default desktop session), which `gamecove-session-select`'s marker already handles.
  steamos-manager reports the login mode from `gamescope-session.service`, so while GameCove runs it says
  "desktop"; nothing of ours reads that.
- polkit: `systemctl reload polkit` re-reads our policy on Type=notify-reload polkit; on an older polkit
  without a reload, the prompt-free actions work after the next restart (`pkaction --action-id
  io.github.ihulksmashi.gamecove.fix-set` shows whether it's loaded; the hardware checks test it).
- Chrome is a Flatpak (`com.google.Chrome`); git may be missing (the testbed falls back to a tarball).
- Device support Valve ships (steamos-manager `data/devices/*.toml`): ROG Ally (board RC71L) has TDP through
  `asus-armoury` firmware attributes with platform profile `performance`, `asus-wmi` profiles and
  `charge_control_end_threshold`; no InputPlumber entry (Steam reads the Ally's controller itself).
  Legion Go S (83L3/83N6/83Q2/83Q3) has TDP through `lenovo-wmi-other-0` with profile `custom` and
  InputPlumber in `deck-uhid` mode. The Claw 8 EX has `msi-wmi-platform` TDP and InputPlumber `deck-uhid`.
  GameCove's power controls use steamos-manager's `TdpLimit1` first on SteamOS, so both agree.

**CachyOS.** Later: a PKGBUILD with the same file list.

## Installer

The guided install (README "Install"). Three parts:

1. **`packaging/get-gamecove.sh`** (POSIX sh, no root): detects the OS from `os-release` (+ `/run/ostree-booted`
   for Fedora Atomic), asks the GitHub API for the release list and takes the highest `vX.Y.Z` tag that isn't a draft
   (`--tag` / `GAMECOVE_TAG` for a given one, which is never replaced). `releases/latest` is never asked: it
   answers with whichever release GitHub marks "latest", and that is one of the data releases (`upscalers`,
   `firmware`, `gamedb`, `device-photos`), not the app. A stable release wins over a pre-release; while only
   pre-releases exist (v0.1.0 is one) the highest of those is used. If the lookup fails (offline, a rate limit, no
   app release listed, or the newest listed is older than the installed one) and a copy was downloaded before, that
   copy opens instead, so the "GameCove Installer" entry always works; an error away from a terminal is also shown
   as a desktop notification. Then it downloads the app tarball, the package for this
   system (RPM, or the `.raw` sysext on SteamOS), its own copy and `SHA256SUMS` into
   `~/.local/share/gamecove/installer/`, checks `SHA256SUMS`'s Sigstore signature (`SHA256SUMS.sigstore.json`, made
   by the Release workflow with its GitHub OIDC identity, no key or secret; verified with cosign from the system or a
   pinned, sha256-checked download, and only accepted for `.github/workflows/release.yml` on a `v*` tag of this
   repository; a release without one is refused unless `GAMECOVE_ALLOW_UNSIGNED=1`; review S3-3), refuses anything
   that isn't listed in or doesn't match `SHA256SUMS`,
   unpacks the app, writes `release.env`, adds the "GameCove Installer" app entry and an "Install GameCove" desktop
   shortcut, and starts `gamecove.x86_64 -- --installer`. Offline, it starts the copy it has.
2. **Installer mode in the app.** `scenes/boot.tscn` is the main scene; `scripts/installer/boot.gd` reads
   `OS.get_cmdline_user_args()` (what follows `--`, the same in an exported binary) and loads
   `scenes/installer.tscn` for `--installer`, else `scenes/main.tscn`. Logic in `scripts/installer/`
   (`plan.gd` steps and choices, `target.gd` system and install state, `commands.gd` every command,
   `installer_service.gd` runs them on a worker and logs to `~/.local/share/gamecove/installer.log`,
   `settings_writer.gd` writes the choices into the app's own settings, `user_files.gd`), UI in
   `scripts/ui/installer/`.
3. **`gamecove-apply-choices`**, shipped in the package: sets the default session
   (`gamecove-session-select gamecove|steam --default --no-switch`) and a charge limit (through the no-password
   `gamecove-fix-set`) from `~/.local/share/gamecove/pending-choices` (`KEY=value`, read, never sourced).

How the install runs (every privileged step through `pkexec`, so the desktop's polkit agent asks):

| System | Package | Live now? |
| --- | --- | --- |
| Bazzite / Fedora Atomic | `pkexec rpm-ostree install --idempotent --apply-live <rpm>`; if that fails, the same without `--apply-live` (staged) | with `--apply-live` yes, else after the reboot |
| SteamOS | `pkexec sh -c '<image to /home/.steamos/offload/gamecove/gamecove.raw, link /etc/extensions/gamecove.raw, keep list /etc/atomic-update.conf.d/gamecove.conf; systemctl enable systemd-sysext; systemd-sysext refresh; reload polkit>' sh <raw>` (elsewhere: `/var/lib/extensions/gamecove.raw`). Nothing goes into `/usr`, so `steamos-readonly` stays on | yes |

When the package is live, fixes install right away (`pkexec gamecove-fix <name> install`) and
`gamecove-apply-choices` runs at once. When it's only staged, the default session can't be set yet (the session
file isn't there), so the startup choice waits in `pending-choices`, and a one-shot user unit
(`~/.config/systemd/user/gamecove-apply-choices.service`, `ConditionPathExists` on the helper and the file) applies
it at the first login after the reboot; GameCove applies it too on its first start. With "Boot into GameCove" and
the first login landing in Steam Gaming Mode, the helper also switches to GameCove once. Fixes can't install in
Gaming Mode (no polkit agent), so they wait in `FIXES=` and an autostart entry opens the installer once in Desktop
Mode ("Finish setting up"). If the reboot never happens, nothing changes: the boot stays Steam Gaming Mode.

Startup choices: **Boot into GameCove** (default session), **Keep Steam, add GameCove** (Steam stays the default;
a "GameCove" app entry switches with `gamecove-session-select gamecove`), **Desktop only** (nothing at boot; a
"GameCove (window)" app entry). Steam mode goes to `~/.config/environment.d/gamecove.conf`
(`GAMECOVE_STEAM_MODE`). The first-run setup steps the installer covered are marked in the Setup service, so the
in-app setup shows nothing (it still runs for people who installed another way, and skips steps done elsewhere).

Uninstall: `gamecove-session-select restore` (the copy in the data folder, else the installed one, else
`steamosctl` directly: the default desktop session back from `gamecove.desktop`, boot to Steam Gaming Mode), optionally `gamecove-fix --remove-all` (every fix in use, whoever applied it: charge limit, fan curve, LEDs, power-tune values, udev rules; review S2-5) instead of only the fixes it
installed, `pkexec rpm-ostree uninstall gamecove` (next boot) or removing the sysext (`systemd-sysext refresh`),
then every user file above; "Keep my settings" off also deletes GameCove's `user://` folder and the download.
Store sign-ins belong to legendary / gogdl / nile and stay. Every step can be undone after a failure (Undo).

Store sign-in on the desktop uses the Setup service's flows: the store's own page opens in the browser
(`OS.shell_open`). legendary, gogdl and nile have no local callback (legendary's automatic capture needs
pywebview), so when the window gets focus back the installer reads the clipboard and finishes on its own if it
holds the Epic JSON (`authorizationCode`), GOG's `on_login_success?…code=` address or Amazon's
`openid.oa2.authorization_code=` address; Paste and Type it do the same by hand. Heroic's sign-ins are reused
(its config folders are read first). No password is ever asked for or stored.

## Hardware checklist (MSI Claw 8 EX, Bazzite)

Do these in order; note results in an issue.

0. Installer: run the bootstrap in Desktop Mode, go through Easy. Check the password prompts appear, whether
   `--apply-live` worked (`rpm-ostree status`), `~/.local/share/gamecove/installer.log`, and that after
   "Restart now" the handheld boots into GameCove. Then Uninstall from "GameCove Installer" and check Steam
   Gaming Mode is the default again after the restart.
1. Install via `install.sh`, reboot, `gamecove-session-select gamecove`. GameCove
   appears (not a black screen). `xprop -root GAMESCOPECTRL_BASELAYER_APPID` from a
   terminal in the session (or SSH with `DISPLAY=:0`) shows `413091, 769`.
2. Kill the app (`pkill -SEGV -f gamecove.x86_64`) 3 times: session falls back to Steam Gaming Mode.
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
12. Charge limit and fan from the UI (`pkexec gamecove-fix-set …`): no password
    prompt, entry in `/var/lib/gamecove/changes.log`. Installing a fix from the
    Device page in Gaming Mode fails with the Desktop Mode message; in Desktop Mode
    it asks for the password and works.
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
