# Store management

How GameCove installs, uninstalls, updates, verifies, moves and configures games
for Steam, Epic, GOG and Amazon. Read with [CONTRACTS.md](CONTRACTS.md) (the
`Library` API the UI calls) and [SESSION.md](SESSION.md) (Steam runs in the
background, silent mode by default).

Status: everything here passes its tests against fixtures and fake runners, and
the process runner was checked for real on Linux (line splitting, stopping a
whole process group). **Nothing has run against a real Steam client, legendary,
gogdl or nile yet.** The checklist at the end lists what to try on a handheld.

## Files

| Path | What it does |
| --- | --- |
| `app/scripts/library/library.gd` | `Library` API: the store-management methods and signals (forwarded from StoreManager) |
| `app/scripts/library/manage/store_manager.gd` | Routes each action to Steam or the queue, capabilities, settings, Steam focus |
| `app/scripts/library/manage/store_commands.gd` | Pure: the legendary / gogdl / nile command plan for an action, or a Heroic hand-off, or why not |
| `app/scripts/library/manage/download_queue.gd` | Queue state machine: one at a time, pause / resume / cancel, space check, saved across restarts |
| `app/scripts/library/manage/job_runner.gd` | Runs processes on reader threads; lines and exit codes come back on the main thread |
| `app/scripts/library/manage/progress.gd` | Pure: progress and size parsers for each tool's output |
| `app/scripts/library/manage/disk.gd` | Install folders, SD card detection, free space |
| `app/scripts/steam/steam_backend.gd` | Layered Steam control (below) |
| `app/scripts/steam/steam_cef.gd` | SteamClient over CEF remote debugging (opt-in) |
| `app/scripts/steam/acf.gd` | appmanifest parsing, `StateFlags`, progress |
| `app/scripts/steam/steam_config.gd` | Launch options (`localconfig.vdf`) and compatibility tool (`config.vdf`), Steam-running check |
| `app/scripts/steam/vdf_writer.gd` | Writes VDF the way Steam does, with backups |
| `app/scripts/steam/steam_focus.gd` | Picks Steam's window under gamescope for its dialogs |
| `app/scripts/launch/launcher.gd` | Per-game compatibility settings for non-Steam games (`compat_for`, `save_compat`, `compat_tools`) |

## Steam

Three layers, best first. Each capability reports which one it will use
(`capabilities(game)["how"]`), so the UI can hide or explain what's missing.

1. **SteamClient over CEF** (only if the user turns on "Steam control"): the
   Steam client's own JS API, the way Decky Loader reaches it. No dialogs.
2. **`steam://` URIs** handed to the running client (`steam <uri>`, as for
   launching). Some open a Steam dialog the user has to answer.
3. **Local files**: `appmanifest_<id>.acf` for state and progress;
   `localconfig.vdf` / `config.vdf` for launch options and compatibility tool,
   written **only while Steam is stopped** (Steam writes both back from memory on
   exit), with backups.

| Capability | With Steam control (CEF) | Without |
| --- | --- | --- |
| Install | `Installs.OpenInstallWizard([id])`, then `SetInstallFolder(i)` + `ContinueInstall()` from the `RegisterForShowInstallWizard` callback; folder by path from `InstallFolder.GetInstallFolders()`, added with `AddInstallFolder(path)` if new. If the wizard doesn't report within 5 s, it's left open in Steam and we bring Steam forward | `steam://install/<id>`: Steam's install dialog; we bring Steam's window forward |
| Uninstall | `Installs.OpenUninstallWizard([id], true)` (no prompt) | `steam://uninstall/<id>`: Steam's confirm dialog; window brought forward |
| Verify | `Apps.VerifyApp(id)` | `steam://validate/<id>` |
| Update now | `Downloads.QueueAppUpdate(id)` | Not offered: Steam updates by itself ("why" says so) |
| Pause / resume / cancel | `Downloads.PauseAppUpdate` / `QueueAppUpdate` + `ResumeAppUpdate` / `RemoveFromDownloadList` | Not offered (Steam's Downloads page via `open_steam_page(game, "downloads")`) |
| Move install | `InstallFolder.MoveInstallFolderForApp(id, folderIndex)` | Not offered |
| Launch options | `Apps.SetAppLaunchOptions(id, s)` | Steam stopped: write `localconfig.vdf`. Running: kept as *pending* (saved in the store settings with the value it replaces, so it survives GameCove exiting; the UI says "will apply after restart"), written at GameCove's next start before Steam starts (the session client waits for `$XDG_RUNTIME_DIR/gamecove-steam-ready`, up to 10 s), or after `apply_pending_steam_changes(true)` restarts Steam. A value changed in Steam meanwhile wins; ours is dropped with `setting_failed` (review S2-4) |
| Compatibility tool | `Apps.SpecifyCompatTool(id, name)` (`""` = default) | Same as launch options, `config.vdf` `CompatToolMapping/<id>` `{name, config "", priority "250"}` |
| Tool list | Local list (CEF `Apps.GetAvailableCompatTools` script exists, not wired to the UI yet) | Valve Proton apps from appmanifests (name → `proton_<major>`, `proton_experimental`, `proton_hotfix`) + `compatibilitytools.d` |
| Launch with options | `Apps.RunGame("<id>", args, -1, 100)` (args go before the game's own launch options) | `steam://run/<id>//<args>/` (Steam may ask to confirm custom arguments) |
| Progress | `RegisterForDownloadOverview` / `RegisterForDownloadItems` pushed through a CDP `Runtime.addBinding` (no polling), plus manifests for completion | `appmanifest_<id>.acf`: `StateFlags`, `BytesDownloaded/BytesToDownload`, then `BytesStaged/BytesToStage`; read every 2 s only while one of our requests (or a download found at scan time) is active |
| Pages | `steam://store/<id>`, `steam://gameproperties/<id>`, `steam://nav/games/details/<id>`, `steam://open/downloads` (always URIs; window brought forward) | same |

Notes:

- Install, uninstall, verify and launch fall back to the URI path when CEF
  doesn't answer; API-only actions report `action_failed` instead.
- A first install already has an appmanifest (`StateFlags` 1026 = update
  required + update started); the library now lists it as `installed: false`
  with `busy: true` instead of a playable game.
- "Is Steam running": `~/.steam/steam.pid` points at a live process whose
  `comm` contains `steam` (Flatpak: `~/.var/app/com.valvesoftware.Steam/.steam/steam.pid`).
- VDF writes keep `<file>.gamecove-orig` (first version ever) and
  `<file>.gamecove.bak` (version before the last write), write a temp file and
  rename it. Account: `config/loginusers.vdf` `MostRecent`, else the only
  `userdata/<id>` folder.
- Steam settings restart: `steam -shutdown`, wait (0.5 s checks, up to 40 s)
  until the pid is gone, write, start Steam again with the session's flags
  (`GAMECOVE_STEAM_MODE`: `-silent`, or the gamepadui set). Only on the user's
  request (`apply_pending_steam_changes(true)`); don't offer it while a Steam
  game runs.

### Steam's dialogs under gamescope

Steam's install/uninstall dialogs and pages are Steam windows, which stay behind
GameCove. When one is expected, StoreManager emits `external_window_needed(key,
"steam", reason)` and (setting `focus_steam_dialogs`, on by default, only under
gamescope) reads `GAMESCOPE_FOCUSABLE_WINDOWS` (`[window, appid, pid]` triples),
picks the newest window owned by a `steam` / `steamwebhelper` process and sets
`GAMESCOPECTRL_BASELAYER_WINDOW` to it (gamescope `steamcompmgr.cpp`,
`focusControlWindow`, commit `89b9e6e`). `return_from_steam()` removes the
property; it also runs by itself once Steam starts the job or finishes it. We
pick by process because Steam's own UI and our home can both be app id 769.
xprop runs on the job runner's threads, not the main thread.

### Steam control (CEF remote debugging): security

Turning it on creates `<steam root>/.cef-enable-remote-debugging`, the file
Decky's installer creates (`decky-installer`, `cli/install_release.sh`); Steam
reads it at start and opens Chrome DevTools on **127.0.0.1:8080**. While it's
open, **any process of any user on this machine that can reach that port can run
JavaScript inside the signed-in Steam client**: read session tokens and account
data, change settings, start installs, and use whatever `SteamClient` exposes.
Malware has abused exactly this (CEF debugging on Steam to steal sessions). On
SteamOS, `steam-web-debug-portforward.service` forwards the port to the network
(Decky uses it for its "CEF forward" option): with that on, anyone on the LAN can
do the same. What we do:

- Off by default; only the user's explicit setting creates the file. The
  setting's text must say what it costs: "Lets GameCove (and any app on this
  device) control Steam. Restart Steam to apply."
- Turning it off removes the file **only if we created it** (Decky users keep
  theirs) and closes our socket. Steam keeps the port until it restarts.
- We connect only to `127.0.0.1:8080` and only to a `ws://127.0.0.1|localhost|[::1]`
  debugger URL from `/json`; a non-loopback URL is refused.
- Every script is built from JSON-encoded values (`SteamCef.lit`), never by
  pasting user text into code.
- The socket is open only while a call is pending or a Steam download we follow
  is active, and closes after 15 s idle.
- If Decky is installed the port is already open; our setting then only decides
  whether GameCove uses it.

## Epic, GOG, Amazon

One queue (`DownloadQueue`), one job at a time by default (`max_parallel` 1–4).
A job is a list of steps from `StoreCommands.plan()`:

| Store | Install | Update | Verify / repair | Uninstall | Move |
| --- | --- | --- | --- | --- | --- |
| Epic (legendary) | `info <app> --json` (size), `install <app> --base-path <dir> --platform Windows -y --skip-sdl` | `update <app> -y --skip-sdl` | `repair <app> -y --skip-sdl` | `uninstall <app> -y --skip-uninstaller` | On one drive `mv -T -- <old> <dir>/<folder>` (a rename); across drives `cp -a -T -- <old> <dir>/<folder>.gamecove-moving`, `mv -T` to `<dir>/<folder>`, then `move <app> <dir> --skip-move` (legendary's own move only renames within a drive) and `rm -rf -- <old>`. Only the copy can be paused or cancelled (it runs again over what is there; a cancelled one is removed); from the rename on the job runs to the end |
| GOG (gogdl) | `--auth-config-path <heroic>/gog_store/auth.json info <id> --platform p` (size), `... download <id> --platform p --path <dir> --skip-dlcs`; then we record it | `... update <id> --platform p --path <install>` | `... repair ...` | `rm -rf -- <install>` (only an absolute path ≥ 3 levels deep, not home, holding `goggame-<id>.info`, `gameinfo` or `start.sh`) | The same steps as Epic's move, then our record is updated |
| Amazon (nile) | `install <id> --info --json` (size), `install <id> --base-path <dir>` | `update <id>` | `verify <id>` | `uninstall <id>` | not supported by nile: "why" says reinstall |

- legendary and nile get their config folder (`LEGENDARY_CONFIG_PATH`,
  `NILE_CONFIG_PATH`) so Heroic users' installs land in Heroic's records, exactly
  as Heroic runs them.
- **Heroic hand-off** (`via: "heroic"`): Epic/Amazon games from a Flatpak Heroic,
  or when legendary/nile aren't on the host; GOG games Heroic installed (their
  record is Heroic's `gog_store/installed.json`, which we never write); GOG
  installs without gogdl or a GOG sign-in. Install opens
  `heroic://launch?appName=<id>&runner=<legendary|gog|nile>`; Heroic's protocol
  only knows `launch` and `ping` (`src/backend/protocol.ts`), and for a game
  that isn't installed it asks the user to install it. Other actions open Heroic.
  `external_window_needed(key, "heroic", reason)` tells the UI.
- **GOG installs of our own** are recorded in
  `~/.local/share/gamecove/gog/installed.json` (Heroic's shape: `appName`,
  `install_path`, `platform`, `title`); `Gog.scan` lists them as `source:
  "gamecove"` and launches them like Heroic's (umu-run or `start.sh`).
- **Progress**: every tool line is parsed (`Progress.parse_line`); see the
  formats in `progress.gd`. legendary's verify line is `\r`-separated, so the
  runner splits on `\r` too. Units are bytes, or files for legendary's verify
  (`progress.unit`).
- **Disk space**: the probe step's size is compared to free space at the install
  folder (nearest existing parent); short → the job fails before downloading
  with "Not enough space in …". A failed probe (offline) doesn't stop the job;
  legendary checks space itself too.
- **Pause** stops the process group (`kill -TERM -- -<pid>`; Godot starts piped
  children in their own session); **resume** runs the same step again, and the
  tools continue (legendary's `.resume` file, gogdl/nile skip finished files).
  **Cancel** leaves partial files, so a later install continues.
- **Restart**: the queue is saved to `user://downloads.json` on every state
  change. On start (after the first library scan) running jobs come back queued
  (`auto_resume`, default on) or paused; jobs the stores made pointless (an
  install of a now-installed game) are dropped.
- **Install location**: `install_root` setting (default `~/Games`), games go to
  `<install_root>/<store>` or `options.path`. `install_locations()` lists
  internal plus removable drives under `/run/media/<user>/*` and SteamOS-style
  `/run/media/<label>`, each `<mount>/Games`, with free space.

## Compatibility for non-Steam games

Stored with the per-game settings in `user://launch_settings.json` under
`"compat"` (the five-key `settings_for` shape is unchanged):
`Launcher.compat_for(key)` → `{"proton", "prefix", "extra_env", "args"}`.

- `proton`: a tool id from `Launcher.compat_tools()`: `""` = umu's default
  (UMU-Proton), `"GE-Proton"` = umu downloads the latest GE-Proton, or an
  installed build (`compatibilitytools.d` in Steam and system folders, Valve's
  `steamapps/common/Proton*`). Launch sets `PROTONPATH` to its folder, and
  `launch_plan()` classifies it so the right FSR 4 / low-latency variables apply.
- `prefix`: absolute Wine prefix; overrides the store's / Heroic's.
- `extra_env`: extra variables (names `[A-Za-z_][A-Za-z0-9_]*`).
- `args`: extra game arguments, shell-split and appended (legendary and nile
  pass unknown arguments to the game); not added to a Heroic hand-off.

## Sources (checked 2026-11-08) and licenses

| Source | Used for | License |
| --- | --- | --- |
| [decky-loader](https://github.com/SteamDeckHomebrew/decky-loader) `backend/decky_loader/injector.py` (`ffd103b`) | How to reach Steam's CEF: `http://localhost:8080/json`, shared-context tab titles, `Runtime.evaluate` | GPL-2.0 (ideas only, no code copied) |
| [decky-installer](https://github.com/SteamDeckHomebrew/decky-installer) `cli/install_release.sh` | `.cef-enable-remote-debugging` file | GPL-2.0 (facts only) |
| [@decky/ui](https://github.com/SteamDeckHomebrew/decky-frontend-lib) `src/globals/steam-client/*.ts` (`52d1173`) | SteamClient method names and shapes (Apps, Installs, Downloads, InstallFolder) | LGPL-2.1 (names only) |
| [Valve Developer Wiki: Steam browser protocol](https://developer.valvesoftware.com/wiki/Steam_browser_protocol) | `steam://install`, `uninstall`, `validate`, `run`, `rungameid`, `store`, `gameproperties`, `nav`, `open/downloads` | — |
| [gamescope](https://github.com/ValveSoftware/gamescope) `src/steamcompmgr.cpp` (`89b9e6e`) | `GAMESCOPE_FOCUSABLE_WINDOWS`, `GAMESCOPECTRL_BASELAYER_WINDOW` | BSD-2-Clause |
| SteamKit2 `EAppState` | appmanifest `StateFlags` bits | LGPL-2.1 (values only) |
| [legendary](https://github.com/legendary-gl/legendary) `cli.py`, `downloader/mp/manager.py` (`170964e`) | Commands, progress and verify lines, `info --json` | GPL-3.0 |
| [heroic-gogdl](https://github.com/Heroic-Games-Launcher/heroic-gogdl) `args.py`, `dl/progressbar.py`, `dl/managers/manager.py` (`6c6ef53`) | Commands, progress lines, `info` size JSON | GPL-3.0 |
| [nile](https://github.com/imLinguin/nile) `arguments.py`, `downloading/progress.py`, `downloading/manager.py` (`5647d15`) | Commands, progress lines, `--info --json` | GPL-3.0 |
| [Heroic Games Launcher](https://github.com/Heroic-Games-Launcher/HeroicGamesLauncher) `src/backend/protocol.ts`, `storeManagers/*/games.ts` (`bf42566`) | `heroic://` (launch/ping only), how Heroic runs and parses the tools, GOG auth path | GPL-3.0 |
| Steam session-hijacking malware report (malwaretips.com) | Real abuse of Steam's CEF debugger, for the security notes | — |

## Verified vs assumed

Verified here: tool command lines and output formats (read from source); the
process runner on Linux (reader thread, `\r` split, exit code, stopping a process
group with nested children); Godot's `execute_with_pipe` puts the child in its
own session; VDF round-trip; gamescope's atoms (source).

Assumed until tried on a device: that the `steam://` URIs above still work in
the current client in silent and gamepadui mode and which ones show a dialog;
that the SharedJSContext tab and these SteamClient methods exist in desktop
(silent) mode as in gamepadui; that the install-wizard callback sequence installs
without a dialog; that Steam updates `BytesDownloaded` in the manifest during a
download often enough for a progress bar; the `proton_<major>` naming; that
`GAMESCOPECTRL_BASELAYER_WINDOW` brings Steam's dialog forward and that removing
it hands focus back.

## Hardware checklist (Bazzite handheld, GameCove session)

1. **Steam, no CEF**: install a small free game → Steam's install dialog appears
   in front (`xprop -root GAMESCOPECTRL_BASELAYER_WINDOW` is set); confirm; GameCove
   comes back; progress moves (`appmanifest_<id>.acf` BytesDownloaded changing);
   the tile becomes installed.
2. Uninstall the same game (confirm dialog), verify another (`steam://validate`):
   does verify show a dialog? Is a dialog missing in silent mode?
3. Set launch options while Steam runs → shows as pending; "Restart Steam to
   apply" → Steam restarts in the same mode, the option is in Steam's properties.
   Check `localconfig.vdf.gamecove.bak` exists.
4. **Steam control on** (restart Steam): `curl -s 127.0.0.1:8080/json` lists
   `SharedJSContext`; `ss -ltnp | grep 8080` shows it bound to 127.0.0.1 only.
   Install without a dialog; pause/resume/cancel; move to the SD card; set the
   compatibility tool and see it in Steam; launch with arguments. Turn it off: the
   flag file is gone (unless Decky made it).
5. **Epic** (legendary, own login and Heroic's): install to SD card, watch
   progress, pause, quit GameCove, start it again → the job resumes; verify;
   move back to internal; uninstall.
6. **GOG** with native Heroic signed in: install through gogdl → appears as
   installed and launches; update; repair; uninstall. With Flatpak Heroic: install
   opens Heroic's prompt.
7. **Amazon** (nile): install, verify, uninstall.
8. Disk full: install something larger than free space → fails before download
   with the "Not enough space" line.
9. Non-Steam compat: pick GE-Proton and a custom prefix for an Epic game; it
   starts with them (`ps` shows `PROTONPATH`, prefix created).
