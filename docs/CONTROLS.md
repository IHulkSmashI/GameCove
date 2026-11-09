# Controls

Each area appends its own section.

## Fixes (device fixes)

- **Catalogue** `app/data/fixes.json`: per fix `id`, `title`, `line` (one plain sentence for the
  page), `symptom`, `kind` (`root` admin-password fixes, `file` udev / session-file fixes on
  `fixes/lib/gcfix.sh`, `power` shown on the Power page, `app` GameCove-side), `password`
  (`none` / `admin`), `restart` (`""`, `restart`, `cold-boot`, `session`), `auto` and `optional`
  device ids (`"*"` = any known handheld; the fix itself checks the hardware), `bazzite` /
  `steamos` (already fixed there?), `sources`. Research: `docs/DEVICE-FIXES.md`.
- **Auto-apply**: a device's `devices.json` `"fixes"` equals the catalogue's `auto` list for it
  (`test_fixes.gd` checks), so the installer installs exactly those. Root helper states gained
  `os-fixed`; the installer records what it installed in `install-state.json` `"fixes"`.
- **Service** `app/scripts/device/fixes.gd` (not an autoload; the page owner makes one):
  `setup({sys_root, runner, home, device, data_dir?})`, `entries()`, `refresh()` (status of every
  fix in the background), `rows()` (`id, title, line, status, auto, auto_applied, can_apply,
  can_undo, can_check, admin, restart, sources`), `counts()`, `act(fix, "apply"|"undo"|"check")`,
  signals `changed(rows)` and `action_finished(fix, verb, ok, message)`. Status words: `applied`,
  `restart`, `partial`, `needed` (auto fix that is off), `available` (optional, off),
  `not-needed`, `os-fixed`, `blocked`, `checking`, `working`, `unknown`. Apply / Undo:
  `pkexec gamecove-fix-set <fix> set on|off` for file fixes (no password, works in Gaming Mode),
  `pkexec gamecove-fix <fix> install|remove` for root fixes (Desktop Mode). The user's Apply /
  Undo is remembered per device in `~/.local/share/gamecove/fixes.cfg`
  (`[fixes@<device>] <fix>="on"|"off"`): **the installer should skip re-installing a fix the
  user undid there** (not wired yet; installer owner).
- **quiet** (from ClawDeck `quiet.py`): `set_game_running(bool)` moves GameCove's threads to the
  LP-E cores at nice 10 while a game runs and back after (`taskset -a -p`, `renice`); on by
  default, off with Undo on the page. The game-session owner must call `set_game_running`.
- **What changed** (from ClawDeck `changes.py`): `check_changes()` compares kernel, OS version and
  gamescope-session device-quirks with the last start (`system-snapshot.json`), re-checks every
  fix when something changed; `last_changes`, `now_os_fixed()` (GameCove fixes the system now
  does itself, so they can be undone). Call it once at start.
- **Page** `app/scripts/ui/device/fixes_page.gd`: `build({"fixes": svc, "device": Device})`, a
  device page (`device_panel.gd`): summary and "what changed" on the left, one card per fix with
  status chip, one line, "Applied by GameCove" / "Optional", Undo / Apply / Check again.
  Wiring into Settings and the quick menu is the ui wave's.
- **Selftest**: `gamecove-selftest` gives each fix a verdict (applied, already fixed by the
  system, not needed, needed but not applied, partial) and fails when a fix meant for this
  handheld isn't installed with GameCove.
