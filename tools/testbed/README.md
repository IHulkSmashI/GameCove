# Testing on real handhelds

One external SSD with Bazzite boots on every handheld; a handheld with its own SteamOS works the same way. We test one device at a time. The full plan, device by device, is [docs/TESTING-HARDWARE.md](../../docs/TESTING-HARDWARE.md).

**Once per drive** (Desktop Mode, Konsole):

```
curl -fsSL https://raw.githubusercontent.com/IHulkSmashI/GameCove/main/tools/testbed/gamecove-testbed.sh -o ~/gamecove-testbed.sh
GAMECOVE_TESTBED_REF=main sh ~/gamecove-testbed.sh prepare
```

`prepare` installs ttyd (a small browser terminal, checked against its sha256) into `~/.local/bin`, puts this repo in `~/src/GameCove` (git, or a tarball where git is missing, e.g. SteamOS; `GAMECOVE_TESTBED_REF` picks the branch or tag), and tells you if Chrome is missing (a Flatpak from Discover on Bazzite and SteamOS). After that, run the copy in the repo so the checks match: `sh ~/src/GameCove/tools/testbed/gamecove-testbed.sh ...`.

**On each handheld:**

1. `sh ~/src/GameCove/tools/testbed/gamecove-testbed.sh console --keep`. It prints the link (`http://127.0.0.1:7681/<random>/`, also in `~/gamecove-tests/console-url`); open it in Chrome on the handheld (with the Claude extension) and tell Claude. The terminal is reachable only from this handheld, only under that random path, and only from its own page (other sites open in Chrome are refused). `--keep` runs it as a temporary user unit so it stays up while you switch between Desktop Mode, GameCove and Steam Gaming Mode; it is never installed or enabled and is gone at reboot, `console-stop` or `reset`. Without `--keep` it lives as long as the Konsole window.
2. `install [tag]` runs the real installer for a release and logs everything to `~/gamecove-tests/install-<date>-<device>.log`. Pre-releases aren't "latest" on GitHub, so give the tag (`install v0.1.0`) or set `GAMECOVE_TAG`; with neither, it takes the newest release including pre-releases. You click through the installer and approve password prompts; Claude can't.
3. `check` runs the machine checks (`checks/*.sh`), Claude reads the results; do the hands-on parts Claude asks for (buttons, rumble, LEDs, unplugging the charger).
4. `report` makes one bundle for the device (logs, self-test, check results, versions; no secrets) and prints its path.

**Before moving the SSD to the next handheld:**

```
sh ~/src/GameCove/tools/testbed/gamecove-testbed.sh reset          # report, remove this device's fixes, check it's clean
sh ~/src/GameCove/tools/testbed/gamecove-testbed.sh reset --full   # same, and uninstall GameCove (the installer opens: pick Uninstall)
```

Reports go to `~/gamecove-tests/report-<date>-<device>/` (and a `.tar.gz` beside it). Fan and charge-limit settings are kept: GameCove stores them per device. If any device-specific fix or kernel argument is left, `reset` says so and exits with code 2; fix that before moving the SSD.
