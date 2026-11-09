<p align="center"><img src="assets/banner.png" alt="GameCove" width="100%"></p>

# GameCove

**The all-in-one companion for Linux handhelds.**

GameCove is a free, open-source, controller-first home screen for gaming handhelds. You boot into it, every store's games sit in one library, and your device's power, fan, screen and controller settings are built in. No plugins, no extra apps.

> Early development. Untested on hardware: try it if you're comfortable rolling back.

## Install

In Desktop Mode, open a terminal and run:

```sh
curl -fsSL https://raw.githubusercontent.com/IHulkSmashI/GameCove/main/packaging/get-gamecove.sh | bash
```

It downloads the latest release (checked against its SHA256SUMS), adds **GameCove Installer** to your app menu and opens it. The installer walks you through it, like EmuDeck: Easy (recommended defaults, one summary page) or Custom (every option). It can make GameCove what your handheld boots into, or keep Steam Gaming Mode as the default with GameCove as a choice, signs in your stores in the browser, installs device fixes and sets everything up so the first start needs nothing. It asks for your admin password only for the system package and device fixes.

- **Bazzite / Fedora Atomic:** installs as a layered package (`rpm-ostree`); a restart finishes it, and your previous system stays in the boot menu.
- **SteamOS:** installs as a system extension (sysext) kept on the home partition and linked from `/etc/extensions`, so SteamOS updates keep it; `steamos-readonly` stays on.
- **Anything else:** you can try GameCove in a window.

Run **GameCove Installer** again any time to change options, repair, update or remove GameCove (removing makes Steam Gaming Mode the default again). Everything it does is logged to `~/.local/share/gamecove/installer.log`. If GameCove crashes, hangs or fails to start three times in a row, your handheld goes back to Steam Gaming Mode for the rest of that boot, and GameCove tells you why the next time it opens. Manual install: [docs/SESSION.md](docs/SESSION.md).

## What it does

- **One library:** Steam, Epic, GOG and Amazon in one place, with installs, updates and a download queue. EA, Ubisoft, Battle.net, emulators and cloud come later.
- **Game info on every tile:** cover art, time to beat, compatibility and anti-cheat status before you hit play.
- **A quick menu that makes sense:** one button, five sections (This game, Power, Screen, Controller, Device), and a short line under every setting saying what it does. Performance overlay, Auto TDP status and Exit game are right there.
- **Your handheld, set up properly:** power profiles, auto TDP, fan, charge limit, VRR, device fixes, and the right upscaling and frame generation for your chip, picked per game.
- **Discover:** deals, real local prices, your wishlist with price alerts, and a release calendar.
- **Two-minute setup:** pick a look, sign in to stores with your phone (scan a QR code, no typing passwords on the handheld), add optional free keys, see what your device needs.
- **Settings in one place:** appearance and four themes, stores and downloads, Discover, performance, device and updates.
- **Steam stays a store:** Steam games launch through Steam, so your Steam library keeps working. "Switch to Steam Gaming Mode" is always one press away.

## Devices

**Full** = tested on the device by us. **Partial** = built from upstream data that was tested on the device, but we haven't run GameCove on it yet. Anything else (or an unknown model) gets the generic path, with device-specific settings hidden.

| Maker | Models | Support |
| --- | --- | --- |
| MSI | Claw 8 EX AI+ | Full (our test device) |
| MSI | Claw 8 AI+, Claw 7 AI+, Claw A1M, Claw A8 | Partial |
| Valve | Steam Deck (LCD, OLED) | Partial |
| ASUS | ROG Ally, Ally X, Xbox Ally, Xbox Ally X, Xbox Ally X20 | Partial |
| Lenovo | Legion Go, Legion Go 2 (and Z2), Legion Go S (Z2 Go, Z1 Extreme) | Partial |
| OneXPlayer | OneXFly F1, F1 Pro, Apex; X1 (AMD, Intel, Mini, Pro); 2, 2 Pro; G1 (AMD, Intel); 3 | Partial |
| AYANEO | 2, 2S, 3, KUN, AIR 1S, AIR Plus, Flip, Flip 1S DS, Slide | Partial |
| AOKZOE | A1, A1 Pro, A1X | Partial |
| GPD | WIN 4, WIN Mini, WIN Max 2, WIN 5 | Partial |
| ZOTAC, Acer, Orange Pi | Gaming Zone, Predator Atlas 8, Neo | Partial |
| Others | OneXPlayer X2 Mini and Super X, Acer Nitro Blaze 7 / 8 / 11, unknown models | Generic |

Details per device: [docs/DEVICES.md](docs/DEVICES.md); the data lives in [`app/data/devices.json`](app/data/devices.json). Own a handheld that isn't listed? Open an issue with your device report.

## Built on

GameCove writes its own front end and device layer and reuses proven open-source parts underneath: gamescope, Proton through umu-launcher, InputPlumber, PowerStation and steamos-manager, and legendary, gogdl and nile for the stores. See [CREDITS.md](CREDITS.md).

## Game data

Our game database is rebuilt nightly from free, open sources (Wikidata, AreWeAntiCheatYet, ProtonDB, IGDB) and published as a download. See [`gamedb/`](gamedb/).

## What we'll never do

- Paywall a device fix, battery feature or safety setting.
- Bypass, spoof or tamper with anti-cheat.
- Modify Steam or take over its interface.

## Community

Bugs and ideas: [GitHub issues](https://github.com/IHulkSmashI/GameCove/issues/new/choose) and [Discussions](https://github.com/IHulkSmashI/GameCove/discussions). Chat and testing: [Discord](https://discord.gg/tuUsn6sSZH). News and tips: [r/GameCoveLinux](https://www.reddit.com/r/GameCoveLinux/). Want to test on your handheld? [Sign up here](https://github.com/IHulkSmashI/GameCove/issues/new?template=tester_signup.yml). More in [COMMUNITY.md](docs/COMMUNITY.md).

## Thanks

Gyro on the MSI Claw 8 EX was figured out by **Kisenir** (r/MSIClaw). Full list in [CREDITS.md](CREDITS.md).

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).

A few parts carry their own licenses: the gyro fix's HID-BPF program is GPL-2.0-only and its helper scripts GPL-2.0-or-later ([LICENSES/GPL-2.0-only.txt](LICENSES/GPL-2.0-only.txt)); the VRR fix's panel list and EDID logic derive from MIT-licensed code ([fixes/claw8ex-vrr/LICENSE.ClawLab-MIT](fixes/claw8ex-vrr/LICENSE.ClawLab-MIT)); and the Heroic Games Launcher icon in `app/assets/brand/` is GPL-3.0-only. Details in [CREDITS.md](CREDITS.md).

Product and company names are trademarks of their respective owners; GameCove is not affiliated with or endorsed by them. See [CREDITS.md](CREDITS.md#trademarks).
