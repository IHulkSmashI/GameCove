# Upscaling and frame generation

GameCove looks at the chip in your handheld and at what each game ships, and sets up the sharpest upscaler that
chip really runs, before you start the game. You don't download anything, copy any file or type a launch option.

This page says what you get on each chip, what the choices mean, how to check that it is really running, and how
it all stays up to date. The helper behind it is `packaging/helpers/gamecove_upscale` (ported from ClawDeck, same
author); the technical notes are in [CONTROLS.md](CONTROLS.md).

## The short version

1. Open a game's page (or the quick menu's **This game** tab while playing). The **Upscaling and frame generation**
   card is there.
2. It is already on **Best for this handheld**. The line under it says what we picked and why.
3. Start the game and pick **DLSS** (or FSR, when the line says so) in the game's own graphics menu. The game still
   thinks it runs that; we turn it into the upscaler we picked.
4. Back in GameCove, **Running now** says what the last start really used, read from the logs, for example
   `Active: FSR 4.1.2 on XMX, XeSS frame generation 2x, XeLL low latency`, or the reason it isn't active.

## The choices

Every choice shows one line under it saying what it is. These are all of them.

| Row | Choice | What it does |
| --- | --- | --- |
| Upscaling for this game | **Best for this handheld** (default) | We pick from the table below and keep it set up: after an install, after a game update, and before each start. |
| | **My choice** | You picked the upscaler or frame generation yourself. We keep it exactly as you set it, and put it back after a game update. |
| | **Native (nothing added)** | The game as it shipped. Every file we added is taken out, byte for byte, and nothing comes back by itself. |
| Upscaler | Game's own | The game's own upscaler, untouched. |
| | FSR 4.1.2 on XMX | AMD's newest FSR on Intel Arc's XMX cores. DirectX 12 games. Intel Arc with XMX only. |
| | FSR 4.1.2 Lite on XMX | The lighter model: a few more frames, slightly softer. Intel Arc with XMX only. |
| | XeSS 2 | Intel's XeSS. On Arc with the XMX driver it runs on the XMX cores. Intel only. |
| | FSR 4.1.2 | AMD's newest FSR, from AMD's own file. AMD only. |
| | FSR 3.1 | Runs on every AMD chip and costs the fewest frames. AMD only. |
| Frame generation | Off, 2x, 3x, 4x | Only the multipliers your chip really does are listed. 3x and 4x exist on Intel Arc with XMX only. |
| Frame generation by | FSR or XeSS frame generation | AMD chips that run both get the choice. FSR is lighter; XeSS handles HUDs better and brings XeLL. |
| Lossless Scaling frame generation | Off / On, 2x to 4x | For what the upscaler can't reach: older games, emulators, anything. Needs your own Lossless Scaling. |
| Running now | Check again | The read-out of the last start. |
| Open the upscaler's menu | | The in-game menu with every setting (the Insert key). |

Rules that always hold:

- **Never two frame generators.** A game's own (or ours) knows the game's motion and keeps the HUD clean, so it wins.
  Lossless frame generation can't be switched on while that one is on, and the other way round.
- **Low latency always rides along with frame generation:** XeLL with XeSS frame generation, Anti-Lag 2 with FSR
  frame generation on AMD, the game's own Reflex on NVIDIA.
- **Frame generation is never switched on by itself**, except in the Capcom setup below, which was tested that way.

## What each chip gets

"Takes over" means: the game offers DLSS or FSR in its menu, and what you pick there becomes the upscaler in the
table. Every cell falls back to the next cheaper upscaler, then to the game's own.

### Intel Arc with XMX (MSI Claw 8 EX, Claw 8 AI+, OneXPlayer 3, Lunar Lake, Arrow Lake-H, Arc cards)

Needs the XeSS XMX driver, which the installer offers on these handhelds.

| The game has | Best picks | Frame generation, when you turn it on | Low latency |
| --- | --- | --- | --- |
| XeSS of its own | the game's own XeSS, on the XMX cores | the game's own XeSS frame generation, raised to 3x or 4x if you pick it | XeLL |
| DLSS or FSR, DirectX 12 | **FSR 4.1.2 on XMX**, then Lite, then XeSS 2 | XeSS frame generation 2x, 3x or 4x on XMX | XeLL, always on |
| DLSS or FSR, DirectX 11 or Vulkan | XeSS 2 | none | - |
| A Capcom RE Engine game | the Capcom setup: our upscaler in its newer layout plus the modified REFramework build, exactly as tested on the Claw | the game's DLSS frame generation becomes XeSS frame generation (on by default here) | XeLL |

FSR 4.1.2 on XMX needs the XMX cores in every start. If a start ran without them, we hold FSR 4.1.2 back and say
so; after two starts where it didn't come up, Best steps down to XeSS 2 by itself and tells you.

### Intel without XMX (Claw A1M / Meteor Lake), or the XMX driver isn't installed

| The game has | Best picks | Frame generation |
| --- | --- | --- |
| XeSS of its own | the game's own | the game's own, 2x |
| DLSS or FSR, DirectX 12 | XeSS 2 | XeSS frame generation 2x, when you turn it on |

### AMD: Ryzen Z1 Extreme, Z1, Z2, 7840U, 8840U (780M class), Z2 Extreme, Ryzen AI 9 (880M / 890M), Ryzen AI Max, RX 7000 and RX 9000

| The game has | Best picks | Frame generation, when you turn it on | Low latency |
| --- | --- | --- | --- |
| FSR 3.1 of its own, DirectX 12 | the game's own FSR, upgraded to **FSR 4** by Proton (GE-Proton and Proton-CachyOS do this). Nothing is added to the game's files. | the game's own FSR frame generation | Anti-Lag 2 |
| DLSS, XeSS or older FSR, DirectX 12 | **FSR 4.1.2** with AMD's own file. After two starts where it didn't come up, FSR 3.1 by itself. | FSR frame generation 2x (default) or XeSS frame generation 2x | Anti-Lag 2 with FSR, XeLL with XeSS |
| DLSS or FSR, DirectX 11 or Vulkan | FSR 3.1 | none | - |
| A Capcom RE Engine game | the Capcom setup with FSR (not tested on AMD hardware yet; the card says so) | the game's DLSS frame generation becomes FSR frame generation | the game's Reflex calls, mapped for AMD |

FSR 4.1.2 is the default on all of these, including the Z1 Extreme, which AMD doesn't list: it runs the same file's
INT8 model there. It costs a few frames against FSR 3.1 and looks clearly better; FSR 3.1 is one tap away under
**Upscaler**.

### AMD: Steam Deck, Ryzen Z2 Go, Z2 A, 6800U (RDNA 2)

| The game has | Best picks | Frame generation |
| --- | --- | --- |
| FSR of its own | the game's own | the game's own |
| DLSS, XeSS or older FSR | **FSR 3.1** | FSR frame generation 2x, when you turn it on |

FSR 4.1.2 is offered here under **Upscaler** and never picked by itself. The honest line: it runs and looks clearly
better, but it is heavy on these chips. Community tests on the Steam Deck (steamdeckhq.com and club386.com,
September 2025) lost about 10 fps, a fifth to a quarter of the frame rate, and drew more battery. At 800p and
15 W that isn't a clear win, so FSR 3.1 stays the default and the FSR 4.1.2 choice says "about a quarter fewer
frames" on its own line. XeSS frame generation isn't offered on these chips.

### NVIDIA

Nothing is added. The game's own DLSS, frame generation and Reflex already are the best there.

### Older or unknown graphics chips

The game's own settings. Lossless Scaling frame generation still works.

## Lossless Scaling frame generation

This is for the games nothing else can touch: DirectX 9 and 11, OpenGL and Vulkan games without a modern upscaler,
native Linux games, emulators.

- It is strictly for people who own **Lossless Scaling** on Steam and have it installed. We read `Lossless.dll` from
  your own Steam library. We never ship it and never download it.
- If you don't own it, the card says so in one line and one press opens its Steam store page. Nothing else happens.
- If you own it but haven't installed it, one press starts the install in Steam.
- The frame generation layer itself (lsfg-vk) is installed on one press, unmodified, from its author's own release,
  into your home folder. It isn't part of GameCove's package. A copy your system already has is used as it is.
- Defaults per chip: 2x, flow scale 80 % (60 % on the slower chips), performance mode on where it helps.
- There is no low-latency pairing for it, so it is best above 40 real fps. It is off for games with anti-cheat.

## What we never do

- **No games with anti-cheat.** If our data or the game's folder shows an anti-cheat system, nothing is added, and
  there is no switch to override it. If a game gains anti-cheat in an update, everything of ours is taken out.
- **No stacking.** If another tool's upscaler, ReShade or Special K is in the game, we leave it alone and say which
  one we found.
- **Nothing permanent.** Every file we add is listed in a manifest with its hash; files we replace are kept and put
  back. Native and uninstalling GameCove both restore the game exactly. A file that changed since is never deleted.
- **Nothing from NVIDIA** is shipped or fetched. Only a game's own copy is ever used.

## One install: where the files come from

Everything comes with GameCove. There is no import button and no folder to fill.

| File | From | How it reaches you |
| --- | --- | --- |
| Our upscaler (OptiScaler 0.9.4, and the newer build the Capcom setup uses), OptiPatcher, fakenvapi | their authors' releases | inside the GameCove package |
| REFramework, the build the Capcom setup uses | its author's release | inside the package |
| AMD's FSR 4.1.2 upscaler | AMD's FidelityFX SDK 2.4.0, the signed file, with AMD's notice | inside the package |
| FSR 4.1.2 for the XMX cores | nitec and the OptiScaler community | inside the package, byte for byte |
| The small `cabinet.dll` that build needs under Proton | built from source in this repository | inside the package |
| The XeSS XMX driver's release | its author's release | inside the package; what its own installer needs from Intel and AMD (compiler, libraries, about 260 MB) is fetched from those vendors on Intel XMX handhelds only, with pinned hashes |
| lsfg-vk | its author's site | fetched on one press, only for Lossless Scaling owners (its licence asks that it come from its author) |
| `Lossless.dll` | your own Steam library | never shipped, never fetched |
| AMD's driver FSR 4 file | - | never ours: Proton fetches its own when it upgrades a game's FSR 3.1 |

Every file is pinned by sha256 and checked again when it is used. Where each FSR 4 file came from, its author, its
terms and its date are in `packaging/helpers/gamecove_upscale/data/fsr4_files.json`; credits are in
[CREDITS.md](../CREDITS.md).

All of it lives in one folder, `~/.local/share/gamecove`. **Settings > Device > Storage** shows its size and how many
games have our files in them. Uninstalling GameCove puts every game back as it shipped and removes the folder.

## Staying up to date

A nightly job watches every upstream this depends on. New builds of the files above are adopted only after they
have been out, unchanged, for 72 hours and pass a smoke check; then they go into a signed list your handheld
verifies before it uses anything from it. The version before is kept, a package that fails its check after an
update is rolled back by itself, and a file can be withdrawn from every handheld through the same signed list.
Things that need a person's eyes first (a new Proton, a new Intel or AMD library, a new lsfg-vk) open an issue
instead of changing anything.

## Checking it on a handheld

These are the lines that prove each mode. `<appid>` is the game's Steam app id.

```sh
# what Best would do for a game, and what the last start really used
/usr/libexec/gamecove/gamecove-upscale plan   --home "$HOME" --key <appid> --gpu '<gpu json>'
/usr/libexec/gamecove/gamecove-upscale status --home "$HOME" --key <appid> --gpu '<gpu json>'
# the launch log GameCove's wrapper writes at every start
cat ~/.local/share/gamecove/launch/<appid>.log
# our upscaler's own log, next to the game's exe
grep -iE "upscaler|xefg|fsr|xess" "<game folder>/OptiScaler.log" | tail -40
```

`<gpu json>` is `{"vendor":"intel","arch":"Xe3","xmx":true}` on a Claw 8 EX and
`{"vendor":"amd","arch":"RDNA3","chip":"AMD Ryzen Z1 Extreme"}` on an Ally Z1 Extreme.

| Mode | What proves it |
| --- | --- |
| FSR 4.1.2 on XMX | `status`: `"active": {"state": "active", "line": "Active: FSR 4.1.2 on XMX…"}`. Launch log: `XeSS XMX driver for this game (set before the container)` and an `XMX shim` line. Game folder: `amd_fidelityfx_upscaler_dx12.dll`, `fsr-original.dll`, `cabinet.dll`, `cabinet_wine.dll`. |
| XeSS frame generation 2x / 3x / 4x | Read-out: `XeSS frame generation 3x`. Launch log `settings` line: `XESS_FG=3` and `DXVK_CONFIG=dxgi.customVendorId = 8086`. `OptiScaler.log` has a line with `XeFG` being created. The overlay's frame rate is about the multiplier times the rendered rate. |
| XeLL low latency | `gamecove-upscale latency --home "$HOME" --key <appid> --gpu '<gpu json>'` answers `"mode": "pacing"` with a latency in ms, read from `drive_c/igdext_xell.log` in the game's prefix. |
| FSR 4.1.2 on a Z1 Extreme | Read-out: `Active: FSR 4.1.2`. `OptiScaler.ini` next to the exe has `Fsr4Update=true` and `Fsr4ForceEnableInt8=true`; the launch settings have `PROTON_FSR4_UPGRADE=1`. With `PROTON_FSR4_INDICATOR=1` in the game's launch options the FSR 4 mark shows in a corner. |
| Proton's FSR 4 upgrade (FSR 3.1 games on AMD) | Read-out: `Set for the last start: FSR 4 (Proton's upgrade). Nothing was added to the game's files.` |
| Native | The game's folder has none of our files; `status` says `Using the game's own upscaler.` |

The first start after any change compiles kernels on Intel. Always start twice and judge the second start.
