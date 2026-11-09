# Testing on real handhelds with one SSD

One external SSD with Bazzite boots on every handheld. We test one device at a time.

**Once per SSD** (Desktop Mode, Konsole):

```
curl -fsSL https://raw.githubusercontent.com/IHulkSmashI/GameCove/main/tools/testbed/gamecove-testbed.sh -o ~/gamecove-testbed.sh
sh ~/gamecove-testbed.sh prepare
```

`prepare` installs ttyd (a small browser terminal, checked against its sha256) into `~/.local/bin`, clones this repo to `~/src/GameCove`, and tells you if Chrome is missing.

**On each handheld:**

1. `sh ~/gamecove-testbed.sh console` and leave the window open. It prints the link (`http://127.0.0.1:7681/<random>/`, also in `~/gamecove-tests/console-url`); give it to Claude. The terminal is reachable only from this handheld, only under that random path, and only from its own page (other sites open in Chrome are refused). It stops when you close the window, at `reset` or `console-stop`, and at reboot; it is never a service.
2. Open Chrome on the handheld (with the Claude extension) so Claude can work in that terminal: install, run `gamecove-selftest`, read logs, fix things.
3. Do the hands-on parts Claude asks for (buttons, gyro, Game Mode checks).

**Before moving the SSD to the next handheld:**

```
sh ~/gamecove-testbed.sh reset          # save a report, remove this device's fixes, check it's clean
sh ~/gamecove-testbed.sh reset --full   # same, and uninstall GameCove for a from-scratch install test
```

Reports go to `~/gamecove-tests/<date>-<device>/` (status, GameCove logs, self-test output, relevant journal lines). Fan and charge-limit settings are kept: GameCove stores them per device. If any device-specific fix or kernel argument is left, `reset` says so and exits with code 2; fix that before moving the SSD.
