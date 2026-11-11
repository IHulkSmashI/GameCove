# Contributing

Thanks for helping. A few rules keep GameCove fast, honest and easy to maintain.

1. **Reuse before you build.** If a maintained open-source tool already does it (input, power, store sign-in, Proton), use it or fix it upstream. Our own code is for the front end, the device layer and the game database.
2. **Explain every setting.** Every control gets one short line saying what it does and what it costs. No jargon without a plain-words line under it.
3. **Light on the battery.** Nothing polls while a game has focus unless a feature needs it. The UI stops redrawing when nothing changes.
4. **Every change can be undone.** Anything we write to the system (kernel arguments, firmware, config) is recorded and has a remove path.
5. **Tested means tested on hardware.** A device only gets "Tested on hardware" after someone ran it on that device. Others stay "Supported" or "Basic".
6. **Never bypass anti-cheat, never modify Steam.** We show status and offer honest options (cloud, boot to Windows); we never spoof or patch.
7. **Credit people.** If an idea or fix came from someone, they go in CREDITS.md.

## Contributor License Agreement

Before your first pull request is merged, the CLA bot asks you to read [docs/CLA.md](docs/CLA.md) and sign it by posting one comment. You keep the copyright in your work; the agreement lets the project owner license GameCove under other terms in the future (for example for a handheld maker) without tracking down every contributor. You sign once and it covers all your contributions.

If part of a contribution comes from another project, say so in the pull request with its source and licence.

The GameCove name and logo are covered by [TRADEMARKS.md](TRADEMARKS.md).

## Layout

| Folder | What's in it |
| --- | --- |
| `app/` | The Godot 4 front end (Compatibility renderer) |
| `app/data/devices.json` | One row per handheld: chip, power range, panel, what works |
| `app/tests/` | Unit tests (`test_*.gd`), fixtures and the end-to-end suite (`e2e/`) |
| `session/` | The gamescope session, its client and the session switcher |
| `fixes/` | One folder per root fix, each with its own `test.sh` |
| `packaging/` | The installer script, RPM spec, SteamOS sysext, root helpers and their tests |
| `gamedb/` | Nightly builder for the open game database |
| `tools/` | Screenshots, the hardware testbed, CI helpers |
| `docs/` | Architecture and decisions |

## Running the tests

Every change comes with a test that fails without it, and everything below passes before a pull request is
merged (CI runs the same commands). Nothing here touches the real system: files go to temp folders, commands to
fakes. You need Godot 4.7.2 (the standard Linux editor build), Python 3 with `pytest` and `pyyaml`, and
`shellcheck`. Run them from the repository root, one after the other (they share Godot's import cache):

```sh
G=/path/to/Godot_v4.7.2-stable_linux.x86_64

# 1. Import, then the unit tests (0 failed, no "SCRIPT ERROR")
$G --headless --path app --import
XDG_DATA_HOME=$(mktemp -d) $G --headless --path app -s res://tests/run_tests.gd
#    one file or test only: GAMECOVE_TEST=installer (part of a file or test name)

# 2. The app starts and quits cleanly (exit 0, no "SCRIPT ERROR", no "Unicode parsing error")
XDG_DATA_HOME=$(mktemp -d) HOME=$(mktemp -d) $G --headless --path app --quit-after 120

# 3. Shell helpers, session, installer, release and workflow checks (slow: several minutes)
sh packaging/tests/run.sh

# 4. End to end: the real app driven through its screens with fake services (run it alone)
python3 -I app/tests/e2e/run.py --godot $G

# 5. Each root fix against a fake /sys
for t in fixes/*/test.sh fixes/*/tests/test.sh fixes/lib/test.sh; do sh $t || echo "FAILED $t"; done

# 6. Python: the game database builder and the upscaling helper
(cd gamedb && python3 -m pytest -q)
(cd packaging/helpers && python3 -m pytest -q)

# 7. Shell lint
git ls-files '*.sh' | xargs shellcheck -S warning
```

Changed a screen? Render it and look at it at both handheld sizes:
`tools/screenshots/shoot.sh /tmp/shots 1280x800` and `... 1920x1200` (`SHOOT_SCRIPT=shoot_installer.gd` and
friends for the other screens; needs `xvfb-run`).

## Device reports

Own a handheld we don't list, or one that misbehaves? Run `gamecove-selftest` from a terminal in Desktop Mode
(it is installed with GameCove; `gamecove-selftest --no-network` stays offline) and attach the report it writes to
an issue. It includes DMI ids, power-limit paths, fan and battery nodes, and nothing personal: user and host
names, serial numbers, MAC addresses and account ids are never read or are replaced. [docs/DEVICES.md](docs/DEVICES.md)
("Testing on your handheld") says what it checks.
