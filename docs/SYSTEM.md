# System services: updates, storage, controller, setup

How GameCove updates the OS, firmware and Flatpaks, shows storage, changes
controller settings through InputPlumber, and runs the first-run checklist.
Read with [CONTRACTS.md](CONTRACTS.md) (exact APIs) and [SESSION.md](SESSION.md)
(root helper, polkit).

Status: every parser and state machine is tested against fixtures and fake
command runners. **Nothing here has run on a handheld yet.** The checklist at
the end lists what to try on the Claw 8 EX (Bazzite) and a Steam Deck (SteamOS).

## Rules all four follow

- All process work runs on one worker thread per service (`scripts/system/service.gd`);
  results come back on the main thread as signals. The thread starts on the first job.
- Nothing runs at start and nothing polls. Exceptions: `Controller` puts your saved
  layout back on at start when one exists (InputPlumber forgets it at reboot), and
  `Storage.watch(true)` compares `/proc/self/mounts` every 4 s while the Storage page
  is open (a file read, no process).
- No new root action. Everything uses the OS's own polkit rules or runs as the user.
- Tests never run a command: services take a runner (`scripts/system/proc.gd`, or
  `tests/fixtures/system/fake_runner.gd`) and a filesystem root.

## Updates (`Updates`, `scripts/system/updates.gd`)

### OS image

Detected from `/etc/os-release` (then `/usr/lib/os-release`), Universal Blue's
`/usr/share/ublue-os/image-info.json` and `/run/ostree-booted` (`scripts/system/os_info.gd`).

| OS | Check | Apply | Privilege | Verified? |
| --- | --- | --- | --- | --- |
| SteamOS | `/usr/bin/steamos-polkit-helpers/steamos-update check` (exit 0 update, 7 none) | same script, no args; prints `NN%` lines | The script re-runs itself with `pkexec --disable-internal-agent`; polkit allows the active session without a password. This is exactly what Steam's Gaming Mode runs, so it works without a polkit agent. | Exit codes and progress format read from OGC's copy of the script; Valve's copy **assumed** to match (Steam client expects the same contract) |
| Bazzite deck images (Claw, Ally, Deck) | `rpm-ostree upgrade --check` (exit 0 update, 77 none) + `rpm-ostree status --json` | `steamos-polkit-helpers/steamos-update` → `/usr/libexec/ogc/os-update` → `uupd` (system only), `NN%` lines. Afterwards we read `rpm-ostree status --json`: **os-update exits 0 even when uupd failed**, so success = a staged deployment exists. | Helper: polkit action `org.chimeraos.policykit.steamos.pkexec.run-steamos-update`, `allow_active=yes` (gamescope-session-steam). rpm-ostree check: action `upgrade`, see below. | Read from Bazzite and OGC sources; not run |
| Bazzite deck before Steam's Gaming Mode ever ran | as above | `rpm-ostree upgrade` | — | **Danger avoided:** os-update restarts `graphical.target` the first time it runs and only then creates `/etc/bazzite/fixups/first_steam_gamemode_boostrap`. Without that file we never call it. |
| Bazzite desktop images, Fedora Atomic | `rpm-ostree upgrade --check` | `rpm-ostree upgrade` (progress from `[n/m]` and `NN%` in its output) | Fedora Atomic 41+ ships `/etc/polkit-1/rules.d/org.projectatomic.rpmostree1.rules`: actions `repo-refresh` and `upgrade` are allowed to any active local session without a password. rpm-ostreed maps both `Upgrade` and `AutomaticUpdateTrigger` (used by `--check`) to `upgrade` (`rpmostreed-os.cxx`). | Rule verified in Fedora's change page; rpm-ostree's own policy default is `auth_admin_keep`, so on an image **without** the rule the check fails with an auth error (shown as `error`), it does not hang |
| bootc-only images, anything else | — | — | `bootc upgrade --check` and `bootc status` need root | `unsupported` |

Staged state: `rpm-ostree status --json` → a deployment with `staged: true` (or a
newer, non-booted first deployment) means "restart to finish". `Updates.reboot()`
runs `systemctl reboot` (logind allows the active session).

`apply()` refuses while a game runs (`set_game_running(true)`, wired by `main.gd`
from `GameSession.started/ended`). Checks are only ever started by the UI.

Release notes: Bazzite <https://github.com/ublue-os/bazzite/releases>,
SteamOS <https://store.steampowered.com/news/app/1675200>, Fedora Atomic
<https://fedoraproject.org/atomic-desktops/>.

### Firmware (fwupd)

- Check: `fwupdmgr refresh` (action `refresh-remote`, `allow_active=yes`; exit 2 = already
  fresh), then `fwupdmgr get-updates --json --no-unreported-check --no-metadata-check`
  (read-only, exit 2 = nothing to do).
- Apply: `fwupdmgr update <DeviceId> --assume-yes --no-reboot-check`. fwupd's polkit:
  `update-internal-trusted` and `update-hotplug-trusted` are `allow_active=yes`, so
  LVFS-signed updates install without a password; untrusted ones need
  `auth_admin_keep` and will fail in Gaming Mode (no agent). Device flag `needs-reboot`
  (UEFI capsules) → phase `staged`.
- fwupdmgr's progress bar is terminal-only; we pass on whatever `NN%` it prints.
- The UI should ask for the charger before firmware (fwupd refuses `require-ac`
  devices on battery anyway).

### Flatpak

- Check: `flatpak remote-ls --updates --user|--system --columns=application,name,version,branch,origin`
  for each installation that exists (`~/.local/share/flatpak`, `/var/lib/flatpak`).
- Apply: `flatpak update --user|--system --noninteractive -y`. Flatpak's polkit:
  `app-update`, `runtime-update`, `appstream-update` are `allow_active=yes`, so system
  updates need no password in the active session (verified in Flatpak's policy file).
- Automatically (opt-in, "Update apps by themselves" on the Updates page, `[updates] auto_apps` in
  `user://settings.cfg`, off by default): at most once a day (`user://firmware/auto_apps.stamp`), 3 min after start
  (one one-shot timer) or when a game ends; refused while a game runs, with Background lookups off, or on battery on
  a metered network. It runs `nice -n 19 ionice -c 3 flatpak update ...` (ionice only when present), so a game
  started meanwhile keeps the CPU and disk.

## Firmware, BIOS and drivers (Updates hub)

`Updates` (`scripts/system/updates.gd`) gained two check-only kinds, `maker` and `drivers`, and
`hub_items()` (also `state()["hub"]`): one list of `{id, section, kind, name, current, latest,
status, severity, how, flash, notes, notes_url, download_page, download_url, sha256, source}` over
fwupd devices, the maker's firmware and the driver stack (item shape: `firmware_index.gd`).
`how`: `auto` (GameCove installs: fwupd, OS update), `guided` (steps, maybe a prepared USB drive),
`link` (maker's page only). GameCove never flashes maker firmware.

### Coverage

| Maker / devices | Source | Flash route shown |
| --- | --- | --- |
| ASUS ROG Ally, Ally X, Xbox Ally, Xbox Ally X, X20 | index: ASUS support API (`GetPDBIOS`, the JSON ASUS's own page loads): BIOS (+ the maker's sha256), ROG MCU (controller), touch panel | EZ Flash from a FAT32 USB drive; GameCove can download the zip, check ASUS's sha256 and put the `.CAP` on the drive. MCU/touch: Windows tool, or fwupd when it lists the MCU (asus-hid plugin, community support since fwupd 2.0.2) |
| Lenovo Legion Go, Go 2 (both), Go S (both) | index: Lenovo PC Support download list (BIOS/UEFI) | Windows `.exe` (link + steps). Legion Go controllers: fwupd `legion-hid` / `legion-hid2` plugins when the OS's fwupd has them |
| MSI Claw 8 EX, 8 AI+, 7 AI+, A1M, A8 | index: MSI support panel API (ported from ClawDeck `msibios.py`), newest revision per board | MSI's steps (Windows or MSI's USB method) + link. msi.com refuses some cloud networks: the job keeps last night's entry |
| Valve Steam Deck LCD / OLED | local: the OS image's own `/usr/bin/jupiter-biosupdate` map (what this image installs) and `systemctl is-enabled jupiter-biosupdate.service`; index: Valve's newest jupiter-hw-support (what a newer image brings); controller firmware shared by family | SteamOS at boot; Bazzite `ujust enable-deck-bios-firmware-updates`; Desktop Mode `sudo jupiter-biosupdate` |
| OneXPlayer, AOKZOE, AYANEO, GPD (per-model pages), ZOTAC, Acer, Orange Pi | link-only (no readable listing) | maker's page + current BIOS version to compare |
| Docks, SSDs, Wi-Fi, other USB parts | fwupd/LVFS (whatever the LVFS lists for them) | `fwupdmgr update` (LVFS-signed: no password) |

LVFS public metadata (checked 2026-11-09) has no handheld BIOS (no Steam Deck, Ally, Legion Go,
Claw entries), so fwupd covers controllers via plugins and accessories only.

### Rules

- Index: `firmware.json.gz` + `.sha256` + `.sigstore.json` on the rolling `firmware` release of
  IHulkSmashI/GameCove-data, built nightly by `gamedb/gamedb/firmware/` (that repo's `.github/workflows/firmware.yml`;
  URL and signer in `app/scripts/system/data_repo.gd`). The app downloads it with `curl`
  when the copy is over 7 days old (a failed try is retried at most daily), only on AC or an
  unmetered network (NetworkManager `Metered`), and keeps it only when the sha256 matches.
- fwupd metadata refresh: at most daily, same network rule. `fwupdmgr get-devices --json` lists
  every updatable part with its running version.
- Installs (fwupd) and USB preparation are refused while a game runs, without AC
  (`needs_ac`) or under 50% battery (`low_battery`). A box with no battery at all (Steam Machine, desktop) counts as being on the mains: it is never refused for it.
- Shared firmware: index `shared[].traits` matched against the row's `traits` (filled from
  maker/family/cpu_vendor/chip/buttons/gpu_family when a row has none), so siblings get it.
- Drivers: kernel (`/proc/sys/kernel/osrelease`), Mesa, linux-firmware, InputPlumber,
  PowerStation, hhd (`rpm -q` or `pacman -Q`), Decky (`~/homebrew/services/.loader.version`), XeSS
  XMX and OptiScaler (`gamecove-upscale state`), against upstream (index) and, on rpm-ostree with
  an update pending, `rpm-ostree upgrade --preview`'s "Upgraded:" list (**assumed** to list
  packages for container images). OS-level items update through the OS kind.

### Needs a handheld

ASUS EZ Flash steps and that ASUS's `sha256` is the zip's (tests assume so; a mismatch refuses);
DMI `bios_version` formats on Lenovo/ASUS (assumed `N3CN40WW` / `RC71L.343`); fwupd naming of the
Ally MCU and Legion controllers; `jupiter-biosupdate.service` state on Bazzite deck images;
whether msi.com answers GitHub's runners.

## Storage (`Storage`, `scripts/system/storage.gd`)

- `findmnt --json --list -b -o SOURCE,TARGET,FSTYPE,SIZE,USED,AVAIL,OPTIONS` (falls back
  to `df -B1 --output=…` on util-linux without size columns) and
  `lsblk --json -b -o NAME,PATH,PKNAME,TYPE,SIZE,RM,HOTPLUG,TRAN,MODEL,LABEL,FSTYPE`.
  Unprivileged.
- One entry per partition; btrfs subvolume mounts (`/dev/x[/home]`) merge. Best mount
  first: `/var/home`, `/home`, `/run/media/*`, `/media/*`, `/mnt/*`, `/var`, `/`.
  `/boot`, `/efi`, `/sysroot`, swap and squashfs are hidden.
- Kind: `sd` (mmcblk), `external` (USB, hot-plug or removable, or mounted under
  `/run/media`), else `internal`.
- btrfs compression from the mount options (`compress=zstd:1`) — free to read. Per-file
  `chattr +c` flags are not read (would need a walk).
- Libraries: every Steam library in `libraryfolders.vdf` (size = sum of Steam's own per-app
  sizes, no walk), Heroic's `defaultInstallPath`, `~/Games`. `measure(path)` runs `du -sb`
  for the others on request.
- Hot-plug: `watch(true)` while the page is open. udisks2 signals would avoid even that,
  but need a long-running `gdbus monitor`/`busctl monitor` process; not worth it for a
  page that is open for seconds.

### Future work: "Format SD card for games"

Not implemented on purpose (destructive). Plan: SteamOS and Bazzite deck images ship
`/usr/lib/hwsupport/format-device.sh` (jupiter-hw-support; Bazzite patches it in
`spec_files/jupiter-hw-support/fedora.patch`), which Steam runs through a
`steamos-polkit-helpers/` wrapper (exact name and polkit rule to confirm on the device).
It formats with Steam's options and adds the card as a Steam library. We would call
the same helper (no root action of ours), only for an `sd` drive, only after a typed
confirmation, never while a game runs, and show its progress lines.

## Display output (`DisplayOutput`, `scripts/system/display_output.gd`)

Reads `/sys/class/drm/card*-*/{status,enabled,edid}` (through `Device.read_all`) to say what the window is on: the handheld's own panel
(eDP / DSI), an external monitor or a TV. The EDID's physical size bytes (21 and 22) give the diagonal. An external output that is
connected and enabled wins; a machine with no panel at all (a Steam Machine) counts as a TV. `UiScale` (docs/RESOLUTIONS.md) uses it for the
layout, and streaming uses the real output size and refresh when the output is external or there is no panel. It runs on start, on window
resize and on focus-in: about ten tiny sysfs reads, no Timer and no polling.

## Controller (`Controller`, `scripts/input/controller.gd`)

Autoload name `Controller`, not `Input`: an autoload called `Input` would hide Godot's
own `Input` singleton.

InputPlumber D-Bus API (system bus, service `org.shadowblip.InputPlumber`), read from
`ShadowBlip/InputPlumber` commit `6aca920` (2026-11-07), `src/dbus/interface/*.rs`:

| Object | Interface | Members we use |
| --- | --- | --- |
| `/org/shadowblip/InputPlumber` | `org.freedesktop.DBus.ObjectManager` | `GetManagedObjects()` (lists `CompositeDeviceN`) |
| `/org/shadowblip/InputPlumber/Manager` | `org.shadowblip.InputManager` | `Version` s, `GamepadOrder` ao |
| `/org/shadowblip/InputPlumber/CompositeDeviceN` | `org.shadowblip.Input.CompositeDevice` | `Name` s, `ProfileName` s, `ProfilePath` s, `Capabilities` as, `OutputCapabilities` as; `GetProfileYaml() → s`, `LoadProfileFromYaml(s)`, `LoadProfilePath(s)`, `SendButtonChord(as)` (Steam menu shortcut) |
| `/org/shadowblip/InputPlumber/devices/target/keyboardN` | `org.shadowblip.Input.Keyboard` | `SendKey(s key, b pressed)` (Send key: `KEY_ESC`...), made with `InputManager.CreateTargetDevice("keyboard")` and stopped with `StopTargetDevice(path)` when the device config has no keyboard target |
| same | `org.shadowblip.Output.ForceFeedback` (only when the device rumbles) | `Enabled` b (rw), `Rumble(d)`, `Stop()` |

Not used yet: `SetTargetDevices(as)`, `FilteredEvents`, `SetInterceptMode`.

polkit (InputPlumber's policy + `org.shadowblip.InputPlumber.rules`): property reads and
`ForceFeedback.Enable` are `yes` for everyone; `LoadProfileFromYaml`/`LoadProfilePath`,
`SendEvent`, `SetTargetDevices`, `Rumble` are `auth_admin`, but the rule returns YES for
members of `wheel` or `inputplumber`. The default user on Bazzite and SteamOS is in
`wheel` (**assumed**, check `id`).

Profiles: InputPlumber's schema is `rootfs/usr/share/inputplumber/schema/device_profile_v1.json`:
`{version: 1, kind: DeviceProfile, name, description?, target_devices?, mapping: [{name,
source_event, target_events[]}]}`. Events: `{gamepad: {button: South}}`,
`{gamepad: {gyro: {name: Gyro1, axis?, direction?, deadzone?}}}`, `{gamepad: {axis: {name: RightStick}}}`,
`{keyboard: KeyW}`, `{mouse: {motion: {speed_pps?}}}`, …

- Paddles: a mapping whose source is `LeftPaddle1..3` / `RightPaddle1..3` (the device has
  them when `Capabilities` lists `Gamepad:Button:LeftPaddle1`).
- Gyro: `off` = no gyro mapping; `mouse` = `Gyro1 → mouse motion`; `stick` = `Gyro1 →
  RightStick axis` (as in InputPlumber's `profiles/test.yaml`). Present when
  `Capabilities` has `Gyroscope:*`. With a ds5/deck target, raw gyro still reaches games
  that read it even when `off`.
- Rumble: on/off only. InputPlumber has no intensity setting (games and Steam choose
  strength).
- LED/RGB: `OutputCapabilities` shows `LED:*` and we report it, but InputPlumber has no
  D-Bus setter (colours come from root-owned device configs), so `set_led()` returns false.
- Edits: read `GetProfileYaml` (our small reader `yaml_lite.gd` handles serde_yaml
  output), change `mapping`, send JSON (valid YAML) with `LoadProfileFromYaml`, read
  back. InputPlumber itself never reads `~/.config/inputplumber/profiles`; we keep our
  files there (JSON in `.yaml` files, so `LoadProfilePath` or OpenGamepadUI could load them):
  `gamecove/default.yaml` (everyday), `gamecove/<store>_<id>.yaml` (per game).
- Per game: `start_game(key)` loads the game's profile when it has one; `end_game()`
  puts `default.yaml` (or the layout from before) back. Edits during a game go to its
  profile if it has one, else to the everyday one.
- Button shortcuts (docs/CONTROLS.md, "Button shortcuts"): while it intercepts, every
  profile the service loads gets the handheld's usual shortcuts on the same load (Quick
  Access mapped to `dbus: ui_quick`, so it opens our quick menu in a game; held: Steam's
  keyboard). Press against hold is timed from the two D-Bus events (1.0 then 0.0) with one
  one-shot Timer per press (`hold_s`, 0.5 s unless changed). `release_intercept()`,
  `_exit_tree()`, the `--restore-baseline` helper and `gamecove-session-select leave` (the
  session unit's `ExecStopPost`) load the profile without the D-Bus mappings, so another
  session never inherits a button nobody answers.
- Steam menu: `open_steam_menu()` gives the game the pad (Pass) and sends
  `SendButtonChord(["Gamepad:Button:QuickAccess"])`, which InputPlumber writes straight to
  the virtual pad without the profile; the Xbox pad sends it as Guide + A, Steam's quick
  access menu.

## Quick menu shortcuts (`scripts/actions/`)

The Shortcuts strip, the back buttons and the holds share one action list
(`registry.gd`) and one runner (`runner.gd`, a Service: blocking calls on its worker).

| Action | How |
| --- | --- |
| Keyboard | `steam -ifrunning steam://open/keyboard` (never starts a second Steam), after our menu closed, only with a game in front |
| Steam menu | Controller `open_steam_menu()` (above) |
| Send key | InputPlumber's virtual keyboard (`SendKey`, above); refused unless a game is in front, so a key is never typed at GameCove; hidden under Handheld Daemon (no call that presses a key) |
| Screenshot, Sleep, Mute, Mic, Wi-Fi, Bluetooth, Airplane, Night light, Mouse mode, Performance overlay | the existing Controls (`system.screenshot`: gamescope's screenshot of the game plane, saved to `~/Pictures/Screenshots/GameCove_<date>_<time>.png`) |
| Record | the Recording service (GPU Screen Recorder) |
| Force close | `game_closer.gd`'s own targets (Steam's reaper for the app id, our scope, the process tree), KILL at once; confirmed first |
| Power | `systemctl reboot` / `poweroff` (logind allows the active seat's user), or the quick menu's own session switch; each confirmed |

## Setup (`Setup`, `scripts/system/setup.gd`)

Steps `welcome, theme, stores, steamgriddb, keys, device_fixes, done` in `user://setup.cfg` (0600: it holds the
user's SteamGridDB key; `steamgriddb` is the Game art step, `keys` the optional gg.deals key).
Store sign-in, read from each tool's source:

| Store | Signed in when | `start_login` gives | `finish_login(text)` runs |
| --- | --- | --- | --- |
| Steam | `config/loginusers.vdf` has a user | `needs: steam` (sign in through Steam; switch to Steam Gaming Mode) | — |
| Epic | legendary `user.json` has `displayName` (Heroic's `legendaryConfig/legendary` first, then `~/.config/legendary`) | `https://legendary.gl/epiclogin`; type the `authorizationCode` it shows | `[env LEGENDARY_CONFIG_PATH=…] legendary auth --code <code>` |
| GOG | Heroic's `gog_store/auth.json` has client `46899977096215655` | GOG's OAuth URL (Heroic's client id); after sign-in the address ends with `code=…` | `gogdl --auth-config-path <heroic>/gog_store/auth.json auth --code <code>` |
| Amazon | nile `current_user.json` has `user_id` | runs `nile auth --login --non-interactive` → its URL; after sign-in the amazon.com address has `openid.oa2.authorization_code=…` | `nile register --code … --client-id … --code-verifier … --serial …` |

None of these stores has a device-code flow. The person scans a QR of the URL, signs in
on the phone, and types the code (or pastes the address) back. Success is decided by the
saved login file, not the exit code (the tools exit 0 on some failures). Typing GOG's and
Amazon's long codes on a handheld is painful; **future work:** a tiny LAN page served by
GameCove (QR to `http://<handheld>:<port>/`) where the phone pastes the code.

Device fixes: `devices.json` `"fixes"` ∩ `gamecove-fix --list`, each with its `status`
(no root). Installing stays on the Device page (needs the admin password: Desktop Mode).

## Hardware checklist

### MSI Claw 8 EX, Bazzite (deck image)

1. `id` shows `wheel`. `cat /etc/polkit-1/rules.d/org.projectatomic.rpmostree1.rules` exists.
2. In GameCove (Gaming Mode, no polkit agent): Updates → check. `rpm-ostree upgrade --check`
   runs without a prompt; version matches `rpm-ostree upgrade --check` in a terminal.
3. With an update available: apply. Progress moves (os-update's `NN%`), phase ends `staged`,
   `rpm-ostree status` shows the staged deployment, restart boots it. Try once with
   no network: phase `error`, message shown, nothing hangs.
4. Firmware: `fwupdmgr get-updates --json` as the user; does the Claw report anything?
5. Flatpak: check and update the system installation without a password.
6. Storage: SD card and a USB SSD appear with the right kind, free space and
   `zstd:1` on the internal drive; plug/unplug with the page open updates within ~4 s.
7. Controller: `busctl --system call org.shadowblip.InputPlumber /org/shadowblip/InputPlumber org.freedesktop.DBus.ObjectManager GetManagedObjects --json=short`
   lists the Claw; do the M1/M2 back buttons show as `Gamepad:Button:LeftPaddle1/RightPaddle1`?
   Remap one, gyro mouse on/off (with Kisenir's gyro fix installed), rumble off/on and test.
   Reboot: the layout comes back. Per-game profile loads at launch and reverts at exit.
8. Setup: Epic sign-in through the QR + code; GOG via Heroic's gogdl; Amazon via nile.

### Steam Deck, SteamOS

1. Updates → check runs `steamos-polkit-helpers/steamos-update check` without a prompt
   (exit 7 when current). Apply on the beta channel when an update is out; progress;
   phase `staged`; restart.
2. firmware: `unsupported` (SteamOS has no fwupd by default) unless installed.
3. Storage: internal NVMe on `/home`, SD on `/run/media/deck/<label>` as `sd`.
4. Controller: InputPlumber is not on SteamOS by default → `available: false`, all
   controls hidden.

## Everyday extras (what people otherwise add with plugins)

Small helpers that cover what the most-installed Decky Loader plugins do, built on tools every Bazzite and SteamOS
install already has (recording needs GPU Screen Recorder, which Settings > Media installs from Flathub when you ask). None of them runs a timer or polls: each reads when its page or tab opens and after you press
something, so nothing costs anything behind a game. All run as the user; none needs the root helper.

| Extra | Where | How | Code |
| --- | --- | --- | --- |
| Per-app volume | Quick menu > Audio, Settings > Sound | PipeWire: `wpctl status` for the app streams, `wpctl get-volume` / `set-volume -l 1.0 <id>` per app, on the Controls worker | `controls/providers/audio.gd` (`app_mixer`), `ui/controls/app_mixer.gd` |
| Now playing | Quick menu > Audio | MPRIS on the session bus through `busctl --user`: `ListNames` for `org.mpris.MediaPlayer2.*`, `PlaybackStatus` / `Metadata` / `Identity`, then `PlayPause`, `Next`, `Previous` | `system/media.gd`, `ui/controls/media_card.gd` |
| Bluetooth devices | Settings > System (Quick menu > Device links there) | BlueZ on the system bus through `busctl --system`: `GetManagedObjects` (devices, `Battery1.Percentage`), `Device1.Connect` / `Disconnect` / `Pair` (+ `Trusted`), `Adapter1.RemoveDevice`. Finding new devices runs `bluetoothctl --timeout 10 scan on`, because BlueZ ends a scan as soon as the client that started it leaves the bus. Pairing asks for no code (controllers, headphones, speakers); a keyboard that wants one pairs from Desktop Mode | `system/bluetooth.gd`, `ui/settings/bluetooth_card.gd` |
| Clean up | Settings > Device > Storage | Finds `steamapps/shadercache/<appid>` folders in every Steam library whose game has no `appmanifest_<appid>.acf` in any library (non-Steam shortcuts, ids from 2^31, are skipped), sizes them with `du -sbc` and removes them through `launch_files.gd`'s guarded remover (the same one that clears a single game's cache). Measured when the Storage page opens. While any library listed in `libraryfolders.vdf` has no readable `steamapps` (an SD card that isn't in), nothing counts as left over and the card says which drive is missing. Whether Steam keeps listing an ejected card isn't relied on: every library GameCove has seen and the games it held are remembered in `user://steam_libraries.json` (`system/steam_library_memory.gd`, fed by the Library's Steam scan and by Storage); while a remembered library can't be read its games count as installed, and it is let go after 60 days unseen. The card says whose caches it kept; the button's job looks again on the worker and removes only folders that are still left over and were in the list shown. Proton prefixes (`compatdata`) are never touched: they can hold saves that aren't in the cloud | `system/storage.gd` (`leftovers`, `clean_leftovers`), `ui/device/storage_panel.gd` |
| Upscaling files | Settings > Device > Storage | What upscaling keeps on the handheld: one call of `gamecove-upscale storage` on the worker when the Storage page opens (never in the background), which sizes the managed folders under `~/.local/share/gamecove` (OptiScaler packages, downloads and the signed list, FSR 4 files, game lists, launch settings, the XeSS XMX driver) and counts the games that have our files in them. What came inside the package (`/usr/lib/gamecove/bin/upscalers`) is said apart. No card without the helper or when nothing is there. Uninstall (`install.sh --uninstall` and the installer app's `upscale_purge` step) runs `gamecove-upscale purge` as the user before the package goes: every game back to the files it shipped with, the XMX driver and an lsfg-vk we installed out, the folders deleted; saves, lsfg-vk's own config and FSR 4 XMX files the user put there stay | `system/storage.gd` (`upscaling`, `upscaling_report`), `ui/device/storage_panel.gd`, `packaging/helpers/gamecove_upscale/upkeep.py` (`storage`, `purge`) |
| GE-Proton | Settings > Performance | GitHub's latest-release API for `GloriousEggroll/proton-ge-custom` (only when you press Check), then the release's `.tar.gz` and `.sha512sum` with `curl` (only from that release page), `curl` with `--proto =https` and a stall limit (`--speed-limit 1024 --speed-time 30`: under 1 KB/s for 30 s gives up), `sha512sum` compared before anything is unpacked, `tar -xzf` into `compatibilitytools.d/.gamecove-download/`, and only once `compatibilitytool.vdf` is there one rename moves it into Steam's `compatibilitytools.d` (the folder Steam reads custom Protons from; Steam's own files aren't touched). Download, checksum and unpack run at `nice -n 19` and `ionice -c 3` (like the automatic Flatpak update), and Install is refused while a game runs. A removal is renamed out first, then deleted. Whatever an interruption leaves stays in `.gamecove-download/` and goes at the next start; a GE-Proton folder without its `compatibilitytool.vdf` shows as "Didn't finish unpacking" and can be removed. A version a Steam game is set to (`config.vdf` `CompatToolMapping`) can't be removed. Steam lists a new version after it restarts | `launch/proton_ge.gd`, `ui/settings/proton_card.gd` |
| Favourites, hidden games, collections | Menu on any tile, the game page's star and Manage, Library > Filter (View), Home's Favourites shelf, Quick menu > This game, Settings > Stores > Collections | Ours in `user://collections.json` through `settings_file.gd`; Steam's collections, favourites and hidden games read (never written) from `userdata/<account>/config/cloudstorage/cloud-storage-namespace-1.json` of the account that signed in last (static collections; dynamic ones stay in Steam). Turning off a Steam favourite or hidden game records an override in our file | `library/collections.gd`, `ui/games/collection_actions.gd` |
| Emulation | Library > Filter > Emulation page, ES-DE's / RetroDECK's tile | Reads EmuDeck's `settings.sh`, RetroDECK's `retrodeck.cfg` / `.json`, ES-DE's `es_settings.xml`, `es_systems.xml` (names) and `gamelist.xml` (recently played); counts ROM folder files. Starts ES-DE / RetroDECK, EmuDeck's app (or RetroDECK's configurator) and Steam ROM Manager through `Library.launch` like any game (scope, launch overlay, quick menu, play time in `user://playtime.json`). Every ROM in every ROM root (ES-DE's ROMDirectory, EmuDeck's emulationPath/romsPath, RetroDECK's roms folder, the defaults; each real folder once, symlinks followed, an unmounted SD card listed offline) becomes a store `emu` game (`roms.gd`: ES-DE's extensions, `.m3u`/`.cue`/`.gdi` collapse (a sheet hides only the track files it names, read from the sheet; a .bin it doesn't name is a game of its own), folder games, ES-DE's gamelist details and downloaded_media art, cached by folder times in `user://emu/roms.cache`) and starts through `esde_launch.gd`: ES-DE's command (custom_systems first, else `app/data/esde_commands.json`), the system's or game's alternative emulator, through EmuDeck's launcher scripts (`app/data/emu_launchers.json`), RetroDECK's CLI or ES-DE's find rules, in a scope like any game. Steam ROM Manager's shortcuts (`shortcuts.vdf`, launch lines through EmuDeck's launchers, RetroDECK, RetroArch or a known emulator, ROMs under `roms/<system>/`) become store `emu` games with Steam's grid art and start through `steam://rungameid/<64-bit id>`; one for a ROM we list folds into it. Settings > Stores > Show emulated games in the Library. Never writes their files; never bundles or downloads ROMs or BIOS | `library/stores/emu.gd`, `library/stores/roms.gd`, `library/stores/esde_launch.gd`, `library/playtime.gd`, `ui/emulation_page.gd` |
| Recording | Quick menu > This game (Record / Stop recording), Settings > Media | GPU Screen Recorder: the host `gpu-screen-recorder` (its `gsr-kms-server` has `cap_sys_admin` from the package) or the **system-wide** Flatpak `com.dec05eba.gpu_screen_recorder` run as `flatpak run --command=gpu-screen-recorder`. Gamescope has no desktop portal, so capture is KMS: `-w screen -c mp4 -k h264 -f 60\|30 -q very_high -cursor no -v no [-a default_output] -o ~/Videos/GameCove/<game>/<game> <date>.mp4`; H.264 for every phone and browser, the hardware encoder (VA-API on AMD/Intel) picked by the recorder. Stop is SIGINT to the recorder's own process (found under the Flatpak's bwrap through `/proc/<pid>/stat`), which finishes the file; a game ending stops it too. The recorder never outlives GameCove: the `sh` wrapper that starts it leaves a watcher asleep in one `select()` (python3: a pidfd on GameCove, one on the recorder, and the stdin pipe; no polling), and if GameCove goes away for any reason (a crash, `SIGKILL`) the recorder gets the same SIGINT, then SIGTERM if it's still there 10 s later. The Flatpak's KMS helper needs a one-time `pkexec`: `kms-server-proxy setup-gsr-ui ~` (what the official UI runs) from Desktop Mode, checked with `kms-server-proxy is-setup ~`. Install: `flatpak install --system --noninteractive -y flathub com.dec05eba.gpu_screen_recorder` (Flatpak's polkit rule lets a local admin do this without a password; otherwise we say Desktop Mode). The clip's picture is a gamescope screenshot (base plane) taken right after recording starts; clips without one get a frame from `ffmpeg` when it's installed. Nothing records until you press Record; no replay buffer | `system/recorder.gd`, `system/recording.gd`, `system/clips.gd`, `ui/settings/media_page.gd` |
| Clips | Settings > Media | Lists `~/Videos/GameCove/*/` (mp4, mkv, webm, mov), reads the length from the MP4 `mvhd` box, deletes only inside that folder. Watch opens the first installed player (mpv with `--fs --input-gamepad=yes`, then VLC, Celluloid; host or Flatpak) as an app (below); no player: `flatpak install --user flathub io.mpv.Mpv`. Send to phone serves a one-time LAN page (docs/PRIVACY.md, Clips) | `system/clips.gd`, `system/clip_drop.gd`, `ui/settings/share_sheet.gd` |
| Apps | Home > Apps shelf (pinned), Library header > Apps | `.desktop` files from `~/.local/share/applications`, both Flatpak export folders and `$XDG_DATA_DIRS/applications` (a user copy hides the system one). Skipped: not `Type=Application`, `NoDisplay`, `Hidden`, `Terminal`, `OnlyShowIn`, a missing `TryExec`, Settings / System / ConsoleOnly / Screensaver / PackageManager / TerminalEmulator without Game, Steam and GameCove itself. `Exec` field codes per the Desktop Entry spec (file and URL codes dropped). Icons from hicolor (PNG, or SVG rasterised to 256 px) into `user://apps/icons/`. Started like a game: `systemd-run --user --scope --unit=app-steam-app<id>-<n>` around `/usr/libexec/gamecove/reaper SteamLaunch AppId=<id> --` around the app (Flatpaks move into their own scope, so gamescope finds them by the reaper), followed by GameSession without a frame limit or Auto TDP. Pins in `user://apps.json` | `library/apps.gd`, `library/library.gd` (`launch_app`), `ui/apps_view.gd`, `ui/home.gd` |
| Controller battery | Top bar (status pill) | UPower on the system bus through `busctl --system`: `EnumerateDevices`, then `Properties.GetAll` of each; kept: `Type` 12 (gaming input), not `PowerSupply`; `Percentage`, or `BatteryLevel` turned into a rough percentage. Read when GameCove comes to the front, when the quick menu opens, when a controller connects or disconnects, and at most every 2 minutes on the live refresh that only runs while GameCove is in front: never behind a game | `system/upower.gd`, `ui/top_bar.gd` |

## Cloud saves (`scripts/system/saves_service.gd`, `cloud_saves.gd`, `save_backup.gd`)

Epic and GOG games sync with the stores' own clouds, through the tools that already hold the sign-in, the same calls
Heroic makes. Steam games keep Steam Cloud. Amazon games aren't covered: nile has no save sync.

| Store | Tool | Look / before a launch / after a game / a conflict |
| --- | --- | --- |
| Epic | legendary (native, Heroic's bundled one, or `flatpak run --command=legendary com.heroicgameslauncher.hgl`) | `legendary -y sync-saves <app> --accept-path --skip-upload --skip-download` to look; `--skip-upload` downloads, `--skip-download` uploads, `--force-download` / `--force-upload` settle a conflict. `LEGENDARY_CONFIG_PATH` is the game's legendary folder, `WINEPREFIX` its prefix (`<prefix>/pfx` for Proton layouts) so legendary finds the save folder; it keeps it in `installed.json` `save_path` |
| GOG | heroic-gogdl (native or Heroic's Flatpak) | `gogdl --auth-config-path <heroic>/gog_store/auth.json save-sync <folder> <id> --os windows --ts <last> --name <location>` with `--skip-upload` before a launch, `--skip-download` after, `--force-*` for a conflict. Folders from Heroic's `GamesConfig/<id>.json` `gogSaves`, else `store_cache/gog_library.json` `gog_save_location` with GOG's `<?VARIABLES?>` resolved in the prefix, else GOG's remote config for the game's client id; the timestamps start from Heroic's `gog_store/saveTimestamps.json` |

Rules: never while a game runs (one worker thread, before `Library.launch()` and after `GameSession.ended`; Sync now,
a restore and a conflict choice are refused while one runs). Epic: a side counts as changed when its newest save is past our last sync (60 s slack, as
legendary's own same-age check); both changed, or never synced with saves on both sides, is a conflict the user
settles (the launch waits; B starts nothing; "Decide later" plays without syncing). GOG: gogdl's own classification;
the fresh timestamp it prints on a conflict is never kept. Before anything may overwrite saves on the handheld
(legendary's download empties the folder first, gogdl's deletes files the cloud doesn't have) the folders are backed
up with `tar` into `user://saves/backups/<game>/`; a download that fails puts the backup back. Settling a GOG conflict
for this handheld first fetches the cloud's files into a scratch folder and keeps them as a backup too (gogdl's forced
upload deletes cloud files the handheld doesn't have); Epic keeps earlier cloud saves itself. A save folder over 1 GiB
(a game that saves into its install folder) isn't backed up, so nothing is downloaded over it. Offline, signed out or a
failed step: the game starts, nothing is deleted, the status says so and the next launch or exit tries again. Every
step runs under `timeout 90`. Status per game in `user://saves.cfg`; the game page's Cloud saves card and Settings >
Saves show it.

What keeps a save from being lost (final review; each has a test against ports of gogdl's and legendary's own sync in
`app/tests/fixtures/saves/fake_clouds.gd`):

- **A sync time only stands for the folder it was made with.** gogdl's upload deletes every cloud file the folder
  lacks, and picks an upload when only local files are newer than `--ts`; legendary uploads when the local save is
  newer. So a deleted or changed prefix, where the game writes a fresh default save, must not look like "only local
  changed". GOG: a location's time is dropped to `0` when its folder is empty, missing, or not the one the time was kept
  for (`gog_paths`), and the whole game's when there is no folder to sync yet; Heroic's time is only a fallback for a
  folder Heroic itself synced. Epic: `last_sync` is dropped the same way (`epic_path`). Uninstalling forgets both. With
  no sync time both sides count as changed and the user chooses.
- **A copy of the cloud before an upload may delete from it.** Before a run that may upload, gogdl is run once with a
  `--ts` in the far future: nothing counts as changed, so it only lists the cloud (its debug log). If the cloud holds
  files the folder lacks, or the list can't be read, the cloud is fetched and kept as a backup first; without that
  copy nothing is uploaded.
- **A changed prefix (Epic).** legendary keeps the folder it worked out once. When the game's prefix is another one
  now, the same folder inside it is handed over with `--save-path`.
- **A download cut short.** Before a tool may write into the save folders a note goes into `saves.cfg` (`pending`: the
  backup to put back, the folders that were empty). A failed download puts the backup back and empties the folders that
  were empty. A note still there at the next sync (the app or the power went mid-download) is put right first: what is
  found is kept as a backup, the folders go back as they were, the sync times are dropped.
- **Two GOG locations.** When one fails and the backup goes back, a location that had downloaded gets its old sync time
  back with it.
- **A restore holds.** Restoring makes the folder exactly what the backup holds (unpacked next to it and swapped in).
  For Epic the restored files carry old times, so until the next good sync the local side counts as changed
  (`restored_at`): "cloud newer" is a conflict with the restored save offered first.
- **"Keep this handheld's save" (Epic).** legendary names an upload by the newest local file's time and every device
  takes the newest name, so the newest file is stamped now before the forced upload.
- **What the status says.** gogdl's "Refused" (the other side is newer and this run could only go one way) is shown as
  waiting, not as synced. GOG's cloud time is an upload time, so the GOG conflict sheet calls neither side "Newer".
- **Backups.** The newest 10 everyday backups per game, and apart from those the newest 10 made by a conflict choice,
  a cloud copy, a restore or an interrupted download.

## Battery history and Sleep at low battery

`scripts/system/battery_log.gd` records battery percent, energy (`energy_now`, else `charge_now` x
`voltage_min_design`) and the time at game starts and ends, sleep (when GameCove puts it to sleep), wake and charger
plug / unplug, the events GameSession and Power already send; no timer and no polling. Time in a game on battery adds
to that game; a sleep only seen at the wake ends the stretch at the last level Power reported before it (`Power.slept_at`
marks the last 15 s look before the sleep). After 20 minutes on battery a game's page shows "Drains about X W, ~Y h on a
full charge" (energy_full / watts); About this device has a 7-day chart and the drain per game.

`scripts/system/low_battery.gd` acts on Power's existing 15 s check (`battery_level`, `source_changed`): with
**Sleep at low battery** on (Settings > Power > Battery, `power.low_battery_sleep` / `power.low_battery_sleep_at`,
3 to 10 %, off by default, kept per handheld) and on battery at or below the level, a 30 s warning shows over
everything (a running game too, as gamescope's overlay); any button stays awake (until the level drops 2 % more, the
charger goes in or the level climbs back), the charger closes it, otherwise `systemctl suspend`.
Two things never start the countdown: one odd reading (a level that lands at the line from more than 2 % above,
or with no reading before it, is read again from the battery 5 s later and only counts if it's still there),
and a charger the kernel doesn't list as `Mains` or `USB` (the battery's own `status` saying `Charging` or
`Full` is believed, at the warning and again before the sleep).

## Sources

- Bazzite: `system_files/deck/shared/usr/libexec/ogc/os-update`, `usr/share/polkit-1/…gamescope-session.policy`,
  `usr/libexec/uupd-update`, `just/10-update.just` (<https://github.com/ublue-os/bazzite>)
- OGC gamescope-session-steam (MIT): `usr/bin/steamos-update`, `usr/bin/steamos-polkit-helpers/steamos-update`,
  `org.chimeraos.update.policy` (<https://github.com/OpenGamingCollective/gamescope-session-steam>, `82c45fc`)
- rpm-ostree: `src/daemon/rpmostreed-os.cxx`, `org.projectatomic.rpmostree1.policy` (<https://github.com/coreos/rpm-ostree>);
  Fedora change "Unprivileged updates for Fedora Atomic Desktops" (F41)
- fwupd: `policy/org.freedesktop.fwupd.policy.in` (<https://github.com/fwupd/fwupd>)
- Flatpak: `system-helper/org.freedesktop.Flatpak.policy.in`, `.rules.in` (<https://github.com/flatpak/flatpak>)
- SteamOS atomupd D-Bus API (`com.steampowered.Atomupd1`: `CheckForUpdates`, `StartUpdate`,
  `ProgressPercentage`, `UpdateStatus`), from KDE Discover's copy of the XML. Not used: its
  polkit rules and bus are undocumented publicly; the Steam helper is the proven path.
- InputPlumber (GPL-3.0): `src/dbus/interface/{manager,composite_device,force_feedback}.rs`,
  `src/dbus/polkit.rs`, `rootfs/usr/share/polkit-1/`, `rootfs/usr/share/inputplumber/schema/device_profile_v1.json`,
  `profiles/test.yaml`, `src/cli/device.rs` (<https://github.com/ShadowBlip/InputPlumber>, `6aca920`)
- legendary `cli.py` (auth), heroic-gogdl `auth.py`/`args.py`, nile `cli.py`, `api/authorization.py`, `arguments.py`
- Cloud saves: legendary `cli.py` `sync_saves`, `core.py` `get_save_path` / `check_savegame_state` / `download_saves`
  (<https://github.com/legendary-gl/legendary>); heroic-gogdl `saves.py`, `args.py`
  (<https://github.com/Heroic-Games-Launcher/heroic-gogdl>); Heroic `src/backend/save_sync.ts`,
  `storeManagers/gog/games.ts` `syncSaves`, `storeManagers/gog/library.ts` `getSaveSyncLocation`,
  `storeManagers/gog/electronStores.ts` (<https://github.com/Heroic-Games-Launcher/HeroicGamesLauncher>); nile has no
  save command (<https://github.com/imLinguin/nile>)


## GameCove's root actions (polkit)

GameCove's own root helper has two polkit actions (`packaging/polkit/io.github.ihulksmashi.gamecove.policy`),
picked by the program pkexec runs. Gaming Mode has no polkit agent, so anything that needs a password only works
from Desktop Mode (or the installer there). The split follows one rule: **a setting people change while playing
is prompt-free and bounded; anything installed, persistent across boots, or risky without being needed day to
day needs the administrator password.** (Review S3-2; `packaging/tests/run.sh` checks the policy text names
exactly what `gamecove-fix-set` accepts.)

Prompt-free (`gamecove-fix-set`, `allow_active` yes, `allow_inactive` / `allow_any` no, so only the person at the
handheld, never a background or remote session):

| Setting | Why prompt-free | How it's bounded |
| --- | --- | --- |
| charge-limit 50-100, release | changed from the Power page and at session end | 50-100 only; a udev guard never leaves charging blocked |
| fan auto / quiet / max / curve | changed while playing | curves never below Quiet and never falling; a failed set goes back to auto |
| power-tune boost, epp, governor, cpumax, gpulevel, gpumin, gpumax, gpuprofile | Auto TDP and the Power page move them per game | every value checked against what the kernel offers; recorded and restored on exit |
| power-tune sppt, fppt, platform, tau | the TDP slider on firmware-attribute handhelds | inside the firmware's own min/max and devices.json, never under SPL |
| power-tune battery (long life) | a charge setting like the limit | the kernel's own charge_types values |
| power-tune thermald hold / release | on Intel, thermald puts the firmware PL1 back every few seconds, so the TDP only sticks with it held | a watcher started by the hold starts thermald again once no game of that user runs (60 s for a game to start, then two checks 10 s apart), even if GameCove crashed; GameCove asks again on the next TDP write |
| controller-led | the lights, changed often | every field checked strictly; the original colours are restored on removal |
| controller-rumble | rumble strength, per game | 0-100 or off/low/medium/high, checked against what the driver offers; an unchanged value is never rewritten (hid-msi stores it in the controller's flash); the original is restored on removal |
| claw8ex-gyro accel on/off | a gyro tuning switch | only rewrites GameCove's own InputPlumber override |
| claw8ex-gyro / -buttons refresh | after an OS update the controller may otherwise stop matching; must work without a keyboard | only rebuilds GameCove's override from the current stock file, or removes it |
| claw8ex-vrr refresh | a SteamOS update brings back Valve's `/etc/default/grub` without the VRR fix's line; the fix was installed with the password, and Gaming Mode has no keyboard to type it | only puts back GameCove's one marked line (`gamecove.vrr=1`) when the fix is installed and every file the keep list kept is there; where the update made the fix impossible it takes the fix out instead; update-grub runs as its own systemd unit, so the time bound can't cut it halfway |

Administrator password (`gamecove-fix`, `auth_admin_keep`):

| Action | Why it needs the password |
| --- | --- |
| install / remove of every fix, `--remove-all` | writes udev rules, kernel arguments, initramfs, firmware or units that persist across boots |
| the small file fixes (udev rules, session files) | they persist across boots and act on every start; applied once from Desktop Mode, not a day-to-day setting |
| power-tune smt, cores | taking CPUs offline is rarely needed and can make the system crawl if misused |
| power-tune sleep (s2idle / deep) | a wrong mode can stop the handheld waking; set once |
| power-tune mcu (Ally controller power saving) | old MCU firmware leaves the controller dead after sleep; also gated on the firmware version |

These last three are also **kept when GameCove's session ends**: `power-tune set restore`, which the session
runs without a password on the way out, puts back only the day-to-day values above it. A setting made with the
administrator password stays until you change it again or the fix is removed (`gamecove-fix power-tune remove`,
which the uninstaller runs): the session couldn't ask for the password to set it again.

`gamecove-fix <name> update` (same action, same password) brings an installed fix to the revision of the script this
GameCove carries, and puts the old version back when that fails. The fix lifecycle ([FIXES.md](FIXES.md)) uses only
`remove` and `update` through this action when it retires or updates a fix by itself: it adds no prompt-free verb, so
in Gaming Mode such a change waits for Desktop Mode (`packaging/tests/run.sh` checks `gamecove-fix-set` refuses
`update` and `retire`).

In Gaming Mode the Power page shows these as "Needs your admin password: change it in Desktop Mode", and the
Fixes page shows the admin note on the file fixes.
