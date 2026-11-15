# GameCove: state and next milestones

Each session takes the top unchecked milestone, finishes it and ticks it here. Last updated 2026-11-15.

## Where we are
- **v0.1.0** is published as a hidden pre-release (main `5c8fa49` at the time).
- **M1 and M2 are on main** (2026-11-15): the controller rules and the installer's pad fixes, CI green on the four setups and the five layouts (run 165).
- **M3 is answered** (2026-11-15): the owner looked at the sheets and said the pictures are fine but the highlight wasn't the same everywhere (a square frame around the installer's Continue). Fixed: the installer builds the theme when nothing above it has one, choice cards share `ThemeLib.card_focus`, and "selected" is a thin edge and a tick, never a ring. He asked to go straight to M4 so device testing can start.
- **Testing on the real Claw:** the owner will give SSH access to the Claw. A cloud session reaches it only if the host is allowed in the session's network settings; otherwise run `claude remote-control` (or `claude`) in the GameCove clone on the Claw, in desktop mode. Either way `tools/devicetest/devicetest.sh` drives the real system with a virtual pad. The owner answers every password prompt himself; a session never types one.
- **This file is kept current by rule and by a hook:** see the top of `CLAUDE.md`. A session that changes the repo updates it in the same commit.
- **The Claw right now:**
  - GameCove's RPM is layered with rpm-ostree, pending a reboot.
  - The gyro fix is applied. ClawDeck's InputPlumber device file was moved to `/var/lib/clawdeck-backup-<time>/`; to restore it, move it back to `/etc/inputplumber/devices.d/`.
  - No other fix and no boot choice is applied, so it still boots as before.
- **ClawDeck** (`github.com/IHulkSmashI/ClawDeck`, AGPLv3, all the owner's own work, so its code may come into GameCove under GPL-3.0): port from it instead of writing again. All of it applies to the MSI Claw 8 EX; most of it to other Intel handhelds with XMX (not the Claw-only fixes, such as the VRR one). Look first at `docs/HARDWARE-FINDINGS.md`, `py_modules/clawdeck` and `tools/` (gyro, cabinet-lzms, upstream watch).
- **GameCove-data** (`github.com/IHulkSmashI/GameCove-data`) is the second repo: it publishes the signed data the app downloads (upscalers, firmware, fixes, the game database, device photos) from its own workflows. A change to what those releases hold is made there, not here; the app's side is `packaging/helpers/gamecove_upscale/mirror.py` and the `*_index` tests.
- **CI runs once per push:** on pull requests and on pushes to main; a newer push to a pull request cancels the older run. Sessions' commits (authored as `claude`) are on the CLA allowlist.

## Milestones
- [x] **M1 Controller UX** (2026-11-15). `docs/CONTROLLER-UX.md` and the focus walk hold every screen on the five CI layouts; 48 px touch targets everywhere.
  - Fixed: top bar at 1280, Emulation and game page order, Discover (Store over Sort, shelves on wide short screens), quick menu media buttons, read-only device cards (the right stick scrolls pages now, `stick_scroll.gd`), battery card at 800p, share sheet and closing sheets keeping or giving back focus, setup art step, Library's second row at 800p, Settings rows clear of the foot fade, honest hints.
  - New: `tools/ux_walk/sheets.sh` (one picture per press, contact sheets). Found on the way and fixed: a Library lookup race that could abort the app, and quick repeated presses on a setting ending one step short.
  - Left: the walk can't finish its reachability pass on pages that rebuild while it walks (device tabs, Deals' store); a Details block on the Fixes page still takes focus to be read.
- [x] **M2 Installer** (2026-11-15). `fix/installer-pad` merged; no focus-walk finding left on any installer page.
  - Up from Skip / Back / Continue goes to the control right above; the installer has the 48 px targets when it runs on its own; monkey seeds 121003 (a sheet whose tile was rebuilt), 163003 (a cancelled Library search) and 164002 / 128004 (a sheet's pick that rebuilds its page) are fixed and are tests now.
  - The device findings it addresses:
    1. Closing the terminal kills the installer.
    2. Welcome cards: double highlight, and A moves on.
    3. Button rows skip Back.
    4. Dead store rows take focus.
    5. Add an Install Heroic button.
    6. Summary focus order.
    7. Device radios change on the d-pad.
    8. The "Press A" hint is weak.
    9. Hidden extras on "Ready to install".
    10. ClawDeck leftovers stopped the install, and one failed fix stopped everything.
    11. The failure-screen buttons are clipped.
    12. A password per fix, with no keyboard: ask once, with Plasma's keyboard (Steam's on-screen keyboard can't type into KDE's polkit box).
- [x] **M3 Owner review** (2026-11-15). Ten sheets reviewed on his phone; one finding (highlight looks differ between screens), fixed and held by tests (`test_controller_ux.gd`, the installer journey). `GODOT=<editor> tools/ux_walk/sheets.sh OUT` renders fresh sheets (about 20 minutes for both sizes).
- [ ] **M4 Release v0.1.1.**
  1. Short external review of the diff since `5c8fa49`.
  2. The version is bumped and `packaging/release-notes/v0.1.1.md` is on main (from `fix/installer-pad`); this session's fixes are in the notes.
  3. Before tagging, run the monkey locally with the seeds the next two CI runs will use (`--suites monkey --seed <run number>`): the seed is the run number, and a new one has found a real focus bug three times.
  4. Run release.yml with publish and prerelease on.
  5. The owner approves the release in a browser.
- [ ] **M4b UI polish** (asked by the owner on 2026-11-15; its own session, after the v0.1.1 tag so device testing isn't held up).
  1. Nothing focused is ever cut: the focus ring and its glow (28 px on primary pills) must fit inside the screen and inside any scroll area. Teach the focus walk to measure the glow, not only the ring, then fix what it finds.
  2. Scroll areas at 1280x800 slice their last card or row (installer Stores cards, Summary rows, the Manage sheet): make them end on a whole row, or fade the edge and show a scroll hint.
  3. Button sizes and positions: one height and one corner radius per button kind, and action rows lined up the same way on every screen.
  4. Send the owner full-size PNG pictures, not small JPEG sheets (the sheets looked pixelated because they were shrunk; check sharpness on the real 1920x1200 panel in M5).
  5. Smoothness and power on the device: frame times of scrolling and opening the quick menu on the Claw, and whether running GameCove on the efficiency cores behind a game is worth it (`docs/PERFORMANCE.md` has the numbers from CI; nothing pins the app's own cores today).
- [ ] **M5 Device tests.**
  1. Claw: re-run the installer over the half install (one password), boot into GameCove, then `tools/devicetest/devicetest.sh run --allow-install-game`.
  2. ROG Ally (SteamOS).
  3. Legion Go S (it needs the external SSD after the Claw).

## Later (after v0.1.1)
- Upstream: fakenvapi moved to `optiscaler/fakenvapi`; OptiScaler's v10 nightly changed its asset name, and the upscalers watcher can't pick it up.
- The new XMX test builds: an XMX upscaler that can also run DLSS models on XMX, and XMX ray reconstruction. Reuse the game's own NVIDIA DLLs; we never ship them. This is the headline for the next update.
- The owner deletes the 4 old data releases and their tags in this repo (upscalers, firmware, gamedb, device-photos); the data now lives in GameCove-data.
