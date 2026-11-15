# GameCove: state and next milestones

Each session takes the top unchecked milestone, finishes it and ticks it here. Last updated 2026-11-15.

## Where we are
- **v0.1.0** is published as a hidden pre-release (main `5c8fa49` at the time).
- The first real install on the MSI Claw 8 EX (Bazzite) found 12 installer problems; they're listed under M2 below.
- **The Claw right now:**
  - GameCove's RPM is layered with rpm-ostree, pending a reboot.
  - The gyro fix is applied. ClawDeck's InputPlumber device file was moved to `/var/lib/clawdeck-backup-<time>/`; to restore it, move it back to `/etc/inputplumber/devices.d/`.
  - No other fix and no boot choice is applied, so it still boots as before.
- **Branches waiting:**
  - `fix/installer-pad` (`db25101`): every installer finding addressed. CI is green except one monkey seed on Home (121003, "nothing has focus").
  - `feat/controller-ux` (`888b684`): `docs/CONTROLLER-UX.md` (rules CUX-1 to CUX-15) and the focus-walk check in the layout job. Many app-wide fixes are done; the last 4 commits are WIP and untested; the layout job fails until the installer findings land or are listed in `tools/layout/known.json`.

## Milestones
- [ ] **M1 Controller UX on `feat/controller-ux`.**
  1. Test the 4 WIP commits; the 48 px touch-target change may move layouts.
  2. Fix the open list: share sheet focus, quick menu media buttons, read-only device cards taking focus, battery card too tall at 800p, setup art step order, Emulation page order, toasts with nothing focused.
  3. Run the focus walk on every CI layout.
  4. Build `tools/ux_walk/sheets.sh` (pad-only contact sheets).
  5. Get CI green and merge.
- [ ] **M2 Installer on `fix/installer-pad`.** Merge main (with M1) in, then:
  1. Fix monkey seed 121003; check main first.
  2. Clear every focus-walk finding on the installer pages.
  3. Get CI green and merge.

  The device findings it addresses:
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
- [ ] **M3 Owner review.** Render pad-only walkthroughs of first run, Library → game page → play, the quick menu, settings, store sign-in, Emulation, Discover, text entry and the whole installer. The owner approves them on his phone.
- [ ] **M4 Release v0.1.1.**
  1. Short external review of the diff since `5c8fa49`.
  2. Bump the version; `packaging/release-notes/v0.1.1.md` already exists on `fix/installer-pad`.
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
