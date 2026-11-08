<p align="center"><img src="assets/banner.png" alt="GameCove" width="100%"></p>

# GameCove

**The all-in-one companion for Linux handhelds.**

GameCove is a free, open-source, controller-first home screen for gaming handhelds. You boot into it, every store's games sit in one library, and your device's power, fan, screen and controller settings are built in. No plugins, no extra apps.

> Early development. Nothing to install yet.

## What it does

- **One library:** Steam, Epic, GOG and Amazon first. EA, Ubisoft, Battle.net, emulators and cloud come later.
- **Game info on every tile:** cover art, time to beat, compatibility and anti-cheat status before you hit play.
- **A quick menu that makes sense:** one button, five sections (This game, Power, Screen, Controller, Device), and a short line under every setting saying what it does.
- **Your handheld, set up properly:** power profiles, auto TDP, fan, charge limit, VRR, and the right upscaling and frame generation for your chip, picked per game.
- **Steam stays a store:** Steam games launch through Steam, so your Steam library keeps working. "Switch to Steam Gaming Mode" is always one press away.

## Devices

Full support only where we have the hardware or documentation. Everything else gets the generic path, with device-specific settings hidden.

| Device | Status |
| --- | --- |
| MSI Claw 8 EX | Full (our test device) |
| Steam Deck, ROG Ally / Xbox Ally, Legion Go, Claw 7/8 AI+, OneXPlayer, GPD, Ayaneo, Zotac Zone | Generic for now, beta once testers confirm |

The device table lives in [`app/data/devices.json`](app/data/devices.json). Own a handheld that isn't listed? Open an issue with your device report.

## Built on

GameCove writes its own front end and device layer and reuses proven open-source parts underneath: gamescope, Proton through umu-launcher, InputPlumber, PowerStation and steamos-manager, and legendary, gogdl and nile for the stores. See [CREDITS.md](CREDITS.md).

## Game data

Our game database is rebuilt nightly from free, open sources (Wikidata, AreWeAntiCheatYet, ProtonDB, IGDB) and published as a download. See [`gamedb/`](gamedb/).

## What we'll never do

- Paywall a device fix, battery feature or safety setting.
- Bypass, spoof or tamper with anti-cheat.
- Modify Steam or take over its interface.

## Thanks

Gyro on the MSI Claw 8 EX was figured out by **Kisenir** (r/MSIClaw). Full list in [CREDITS.md](CREDITS.md).

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).

A few parts carry their own licenses: the gyro fix's HID-BPF program is GPL-2.0-only and its helper scripts GPL-2.0-or-later ([LICENSES/GPL-2.0-only.txt](LICENSES/GPL-2.0-only.txt)); the VRR fix's panel list and EDID logic derive from MIT-licensed code ([fixes/claw8ex-vrr/LICENSE.ClawLab-MIT](fixes/claw8ex-vrr/LICENSE.ClawLab-MIT)). Details in [CREDITS.md](CREDITS.md).
