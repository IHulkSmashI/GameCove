# GameCove: state and next milestones

Each session takes the top unchecked milestone, finishes it and ticks it here. Last updated 2026-11-15.

## Where we are
- **v0.1.0** is published as a hidden pre-release (main `5c8fa49` at the time).
- **M1 and M2 are on main** (2026-11-15): the controller rules and the installer's pad fixes, CI green on the four setups and the five layouts.
- **The Claw right now:**
  - GameCove's RPM is layered with rpm-ostree, pending a reboot.
  - The gyro fix is applied. ClawDeck's InputPlumber device file was moved to `/var/lib/clawdeck-backup-<time>/`; to restore it, move it back to `/etc/inputplumber/devices.d/`.
  - No other fix and no boot choice is applied, so it still boots as before.
- **ClawDeck** (`github.com/IHulkSmashI/ClawDeck`, AGPLv3, all the owner's own work, so its code may come into GameCove under GPL-3.0): port from it instead of writing again. All of it applies to the MSI Claw 8 EX; most of it to other Intel handhelds with XMX (not the Claw-only fixes, such as the VRR one). Look first at `docs/HARDWARE-FINDINGS.md`, `py_modules/clawdeck` and `tools/` (gyro, cabinet-lzms, upstream watch).
- **CI runs once per push:** on pull requests and on pushes to main; a newer push to a pull request cancels the older run. Sessions' commits (authored as `claude`) are on the CLA allowlist.

## Milestones
- [x] **M1 Controller UX** (2026-11-15). `docs/CONTROLLER-UX.md` and the focus walk hold every screen on the five CI layouts; 48 px touch targets everywhere.
  - Fixed: top bar at 1280, Emulation and game page order, Discover (Store over Sort, shelves on wide short screens), quick menu media buttons, read-only device cards (the right stick scrolls pages now, `stick_scroll.gd`), battery card at 800p, share sheet and closing sheets keeping or giving back focus, setup art step, Library's second row at 800p, Settings rows clear of the foot fade, honest hints.
  - New: `tools/ux_walk/sheets.sh` (one picture per press, contact sheets). Found on the way and fixed: a Library lookup race that could abort the app, and quick repeated presses on a setting ending one step short.
  - Left: the walk can't finish its reachability pass on pages that rebuild while it walks (device tabs, Deals' store); a Details block on the Fixes page still takes focus to be read.
- [x] **M2 Installer** (2026-11-15). `fix/installer-pad` merged; no focus-walk finding left on any installer page.
  - Up from Skip / Back / Continue goes to the control right above; the installer has the 48 px targets when it runs on its own; monkey seeds 121003 (a sheet whose tile was rebuilt) and 128004 are tests now.
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
- [ ] **M3 Owner review.** `GODOT=<editor> tools/ux_walk/sheets.sh OUT` renders them (about 20 minutes for both sizes; a download journey loses its timing under the slower renderer, its pictures are still right). Render pad-only walkthroughs of first run, Library → game page → play, the quick menu, settings, store sign-in, Emulation, Discover, text entry and the whole installer. The owner approves them on his phone.
- [ ] **M4 Release v0.1.1.**
  1. Short external review of the diff since `5c8fa49`.
  2. The version is bumped and `packaging/release-notes/v0.1.1.md` is on main (from `fix/installer-pad`); add this session's fixes to the notes.
  3. Run release.yml with publish and prerelease on.
  4. The owner approves the release in a browser.
- [ ] **M5 Device tests.**
  1. Claw: re-run the installer over the half install (one password), boot into GameCove, then `tools/devicetest/devicetest.sh run --allow-install-game`.
  2. ROG Ally (SteamOS).
  3. Legion Go S (it needs the external SSD after the Claw).

## Later (after v0.1.1)
- Upstream: fakenvapi moved to `optiscaler/fakenvapi`; OptiScaler's v10 nightly changed its asset name, and the upscalers watcher can't pick it up.
- The new XMX test builds: an XMX upscaler that can also run DLSS models on XMX, and XMX ray reconstruction. Reuse the game's own NVIDIA DLLs; we never ship them. This is the headline for the next update.
- The owner deletes the 4 old data releases and their tags in this repo (upscalers, firmware, gamedb, device-photos); the data now lives in GameCove-data.
