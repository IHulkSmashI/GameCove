# Contributing

Thanks for helping. A few rules keep GameCove fast, honest and easy to maintain.

1. **Reuse before you build.** If a maintained open-source tool already does it (input, power, store sign-in, Proton), use it or fix it upstream. Our own code is for the front end, the device layer and the game database.
2. **Explain every setting.** Every control gets one short line saying what it does and what it costs. No jargon without a plain-words line under it.
3. **Light on the battery.** Nothing polls while a game has focus unless a feature needs it. The UI stops redrawing when nothing changes.
4. **Every change can be undone.** Anything we write to the system (kernel arguments, firmware, config) is recorded and has a remove path.
5. **Tested means tested on hardware.** A device only gets "full" status after someone ran it on that device. Untested devices stay "beta" or "generic".
6. **Never bypass anti-cheat, never modify Steam.** We show status and offer honest options (cloud, boot to Windows); we never spoof or patch.
7. **Credit people.** If an idea or fix came from someone, they go in CREDITS.md.

## Layout

| Folder | What's in it |
| --- | --- |
| `app/` | The Godot 4 front end (Compatibility renderer) |
| `app/data/devices.json` | One row per handheld: chip, power range, panel, what works |
| `gamedb/` | Nightly builder for the open game database |
| `docs/` | Architecture and decisions |

## Device reports

Own a handheld we don't list? Run the device report (coming soon) and attach it to an issue. It includes DMI ids, power-limit paths, fan and battery nodes, and nothing personal.
