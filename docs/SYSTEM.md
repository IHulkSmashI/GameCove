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

- Index: `firmware.json.gz` + `.sha256` on the rolling `firmware` release, built nightly by
  `gamedb/gamedb/firmware/` (`.github/workflows/firmware.yml`). The app downloads it with `curl`
  when the copy is over 7 days old (a failed try is retried at most daily), only on AC or an
  unmetered network (NetworkManager `Metered`), and keeps it only when the sha256 matches.
- fwupd metadata refresh: at most daily, same network rule. `fwupdmgr get-devices --json` lists
  every updatable part with its running version.
- Installs (fwupd) and USB preparation are refused while a game runs, without AC
  (`needs_ac`) or under 50% battery (`low_battery`).
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

## Controller (`Controller`, `scripts/input/controller.gd`)

Autoload name `Controller`, not `Input`: an autoload called `Input` would hide Godot's
own `Input` singleton.

InputPlumber D-Bus API (system bus, service `org.shadowblip.InputPlumber`), read from
`ShadowBlip/InputPlumber` commit `6aca920` (2026-11-07), `src/dbus/interface/*.rs`:

| Object | Interface | Members we use |
| --- | --- | --- |
| `/org/shadowblip/InputPlumber` | `org.freedesktop.DBus.ObjectManager` | `GetManagedObjects()` (lists `CompositeDeviceN`) |
| `/org/shadowblip/InputPlumber/Manager` | `org.shadowblip.InputManager` | `Version` s, `GamepadOrder` ao |
| `/org/shadowblip/InputPlumber/CompositeDeviceN` | `org.shadowblip.Input.CompositeDevice` | `Name` s, `ProfileName` s, `ProfilePath` s, `Capabilities` as, `OutputCapabilities` as; `GetProfileYaml() → s`, `LoadProfileFromYaml(s)`, `LoadProfilePath(s)` |
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

## Setup (`Setup`, `scripts/system/setup.gd`)

Steps `welcome, theme, stores, device_fixes, steamgriddb, done` in `user://setup.cfg`.
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
| claw8ex-gyro accel on/off | a gyro tuning switch | only rewrites GameCove's own InputPlumber override |
| claw8ex-gyro / -buttons refresh | after an OS update the controller may otherwise stop matching; must work without a keyboard | only rebuilds GameCove's override from the current stock file, or removes it |

Administrator password (`gamecove-fix`, `auth_admin_keep`):

| Action | Why it needs the password |
| --- | --- |
| install / remove of every fix, `--remove-all` | writes udev rules, kernel arguments, initramfs, firmware or units that persist across boots |
| the small file fixes (udev rules, session files) | they persist across boots and act on every start; applied once from Desktop Mode, not a day-to-day setting |
| power-tune smt, cores | taking CPUs offline is rarely needed and can make the system crawl if misused |
| power-tune sleep (s2idle / deep) | a wrong mode can stop the handheld waking; set once |
| power-tune mcu (Ally controller power saving) | old MCU firmware leaves the controller dead after sleep; also gated on the firmware version |

In Gaming Mode the Power page shows these as "Needs your admin password: change it in Desktop Mode", and the
Fixes page shows the admin note on the file fixes.
