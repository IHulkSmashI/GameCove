# Credits

GameCove stands on a lot of other people's work. Thank you.

## People

- **Kisenir** (r/MSIClaw): found and tested how to bring up the MSI Claw 8 EX gyro on Linux (sensor-hub firmware, HID-BPF descriptor fix, keepalive and bias calibration). He gave us permission to use his work (2026-11-08). His HID-BPF program is GPL-2.0-only; his helper scripts are GPL-2.0-or-later, as he confirmed (2026-11-09). GPL-2.0 text: [LICENSES/GPL-2.0-only.txt](LICENSES/GPL-2.0-only.txt).
- **HHHHanasak1**: xess-xmx-linux, XeSS on the XMX cores under Proton.

## Projects we use or build on

| Project | What for | License |
| --- | --- | --- |
| gamescope | Display, frame limit, scaling, overlay layering | BSD-2-Clause |
| Proton / umu-launcher | Running Windows games | Various / GPL-3.0 |
| InputPlumber | Controller input, button and gyro routing; device profiles and D-Bus API for paddles, gyro, rumble | GPL-3.0 |
| PowerStation | TDP, GPU clocks over D-Bus | GPL-3.0 |
| steamos-manager | TDP, GPU, charge limit over D-Bus | MIT |
| legendary, heroic-gogdl, nile | Epic, GOG, Amazon libraries, launch, install / update / repair / uninstall, progress output; Epic and GOG cloud saves (`sync-saves`, `save-sync`) | GPL-3.0 |
| Heroic Games Launcher | Library, playtime, prefixes and art for games installed through Heroic | GPL-3.0 |
| gamescope-session-plus | The session GameCove runs in | see project |
| xprop (X.Org) | Setting gamescope atoms | MIT |
| MangoHud / mangoapp (flightlessmango) | Performance overlay and the game's frame timings (its log) | MIT |
| rpm-ostree | Checking and staging OS updates on Bazzite / Fedora Atomic | LGPL-2.0-or-later (parts GPL-2.0-or-later, Apache-2.0 OR MIT) |
| steamos-update helpers (Valve; OpenGamingCollective gamescope-session-steam) | OS updates the way Steam's Gaming Mode does them | MIT (OGC) |
| uupd (Universal Blue) | Runs Bazzite's updates behind steamos-update | Apache-2.0 |
| fwupd / LVFS | Firmware updates | LGPL-2.1-or-later |
| Flatpak | App updates | LGPL-2.1-or-later |
| util-linux (findmnt, lsblk) | Drives and free space | GPL-2.0-or-later |
| udev-hid-bpf | Loading HID-BPF fixes | GPL-2.0 |
| Godot Engine 4.7.2 | The engine and the export template the GameCove binary is built from | MIT; its licence, third-party notices and authors are in [LICENSES/](LICENSES/) (Godot-LICENSE.txt, Godot-COPYRIGHT.txt, Godot-AUTHORS.md) and in the app (Settings > About > Credits and licenses) |
| Moonlight (moonlight-qt, moonlight-stream) | The Stream tab's player: GameCove runs its CLI (list, pair --pin, stream, quit); its settings-file layout, Wake-on-LAN ports and default-bitrate formula are followed in `scripts/streaming/` (no code copied) | GPL-3.0 |
| moonlight-common-c (moonlight-stream) | GameStream codec bits (`ServerCodecModeSupport`) | GPL-3.0 |
| Vibepollo (Nonary) | The PC-side stream host GameCove is built for: serverinfo extensions (sleep, metrics), permission placeholder, power-actions sleep endpoint; its release page is linked from the Stream tab | GPL-3.0 |
| Apollo (ClassicOldSong) and Sunshine (LizardByte) | GameStream host behaviour read from source: serverinfo / applist / appasset fields, client permission bits, pairing | GPL-3.0 |
| Avahi (avahi-browse) | Finding PCs on the network (`_nvstream._tcp`) | LGPL-2.1-or-later |
| curl | The Stream tab's HTTP(S) calls with Moonlight's client certificate | curl (MIT-style) |
| Flathub | Moonlight's Flatpak, installed for the user from the Stream tab or the installer; GPU Screen Recorder and mpv, installed from Settings > Media when you ask | — |
| GPU Screen Recorder (dec05eba) | Record in the quick menu: screen capture under gamescope (KMS) and GPU video encoding. GameCove runs its CLI and, for the one-time screen-capture OK, its kms-server-proxy (`setup-gsr-ui`, `is-setup`), the way its own UI does | GPL-3.0 |
| mpv | Playing clips full screen with the controller (`--input-gamepad`), when installed; VLC or Celluloid otherwise | GPL-2.0-or-later / LGPL-2.1-or-later |
| UPower (freedesktop.org) | Controller batteries in the top bar | GPL-2.0-or-later |
| freedesktop.org Desktop Entry and Icon Theme specs | Reading installed apps (.desktop files, Exec field codes, hicolor icons) for the Apps view | — |
| InputPlumber device configs and capability maps (ShadowBlip) | DMI matches, special-button and paddle capabilities, IMU and LED presence for every handheld in `devices.json` / `buttons.gd`; D-Bus intercept mode documented in DEVICES.md | GPL-3.0 |
| PowerStation APU and DMI-override databases (ShadowBlip) | TDP ranges and boost in `devices.json` and its `cpus` fallback table | GPL-3.0 |
| steamos-manager device files (Valve, Collabora, Igalia) | DMI ids, TDP / fan / charge-limit methods per handheld | MIT |
| Handheld Daemon adjustor (hhd-dev) | Per-device TDP tables and profile watts (ROG Ally family, Claw, Legion Go S cap, GPD); the ROG Ally fan curve points and minimum/default curves behind the ASUS "quiet" fan preset | GPL-3.0 (adjustor); hhd itself LGPL-2.1-or-later |
| HueSync (honjow) | Which handhelds have RGB and their kernel LED names (`go:rgb:joystick_rings`, `ally`, `ayaneo:rgb:joystick_rings`, `oxp:rgb:*`), cited per device in `tools/devicematrix/expectations.json` | BSD-3-Clause (facts only, no code copied) |
| SimpleDeckyTDP (aarron-lee) | Steam Deck TDP range, Intel TDP cap, Lenovo `lenovo-wmi-other-0` firmware-attribute name, cited in `tools/devicematrix/expectations.json` | BSD-3-Clause (facts only, no code copied) |
| Bazzite (Universal Blue) | Acer Predator Atlas 8 InputPlumber config (DMI board `F900_PTG`, QAM / M1 / M2 buttons) | Apache-2.0 |
| OpenGamepadUI (ShadowBlip) | How a gamescope main app takes Guide / QAM from InputPlumber (intercept mode) | GPL-3.0 |
| Outfit (Outfit Project Authors, github.com/Outfitio/Outfit-Fonts) | Display and heading type (SemiBold, Bold, ExtraBold; Latin subset in `app/fonts/`, licence `app/fonts/OFL-Outfit.txt`) | OFL-1.1 |
| Plus Jakarta Sans (Plus Jakarta Sans Project Authors, github.com/tokotype/PlusJakartaSans) | Interface text (Regular to Bold; Latin subset, `app/fonts/OFL-PlusJakartaSans.txt`) | OFL-1.1 |
| JetBrains Mono (JetBrains Mono Project Authors, github.com/JetBrains/JetBrainsMono) | Telemetry, counts and micro labels (Medium, Bold; Latin subset, `app/fonts/OFL-JetBrainsMono.txt`) | OFL-1.1 |
| Inter typeface | Banner lettering (`assets/banner.png` only; not bundled) | OFL-1.1 |
| CRT-Lottes ReShade effect (Timothy Lottes; ReShade port in Matsilagi/RSRetroArch `Shaders/CRTLottes.fx`) | Bundled CRT screen effect (`app/scripts/controls/display/reshade_shaders.gd`, unchanged) | Public domain |
| ReShade.fxh (crosire/reshade-shaders, slim branch) | Header the bundled ReShade effects include | CC0-1.0 |
| EmuDeck (dragoonDorise), RetroDECK, ES-DE, Steam ROM Manager (SteamGridDB) | The Emulation page starts them (ES-DE / RetroDECK full screen, EmuDeck's app or RetroDECK's configurator, Steam ROM Manager); we read EmuDeck's `settings.sh`, RetroDECK's `retrodeck.cfg`, ES-DE's `es_settings.xml` and `gamelist.xml`, and the Steam shortcuts Steam ROM Manager makes. None of them ships with GameCove, and GameCove never ships or downloads ROMs or BIOS files | GPL-3.0 (EmuDeck, RetroDECK, Steam ROM Manager), MIT (ES-DE) |
| QR Code encoder, kenyoni-software godot-addons (Iceflower S) | QR codes for store sign-in, vendored in `app/addons/kenyoni/qr_code/` (Kanji mode removed; see its README.GameCove.md) | MIT |

## Ideas and findings we borrowed

- **vibrantDeck** (libvibrant, Sefa Eyeoglu, GPL-3.0): colour vibrance through gamescope's SDR gamut atom. No code copied.
- **LeGo2BrightnessFix** (Rayekkk): Legion Go 2 OLED ignores its backlight in PQ; brightness via gamescope's SDR-on-HDR level, re-applied after suspend.
- **Bluetooth** Decky plugin (Outpox): BlueZ adapter power over D-Bus, and why hci0 isn't always the right adapter.
- **ClawDeck** (same author, who permits relicensing its code under GPL-3.0 for GameCove). Parts ported from ClawDeck (same author): the Claw 8 EX power backend findings, launch environment, face-button and EDID findings; the "quiet" fix (`quiet.py`) and the "what changed" check (`changes.py`) in `app/scripts/device/fixes.gd`; per-game / per-power-source profile layering (`app/scripts/controls/profiles.gd`) and the Intel RAPL / xe GPU-clock / msi-wmi-platform sysfs layout the device matrix fakes; Auto TDP (`app/scripts/device/autotune.gd` from `autotune.py`, with its tests), the temperature guard (`thermal.py`), thermald and RAPL PL1-window handling, fan presets and power levers (`power.py`, `fan.py`); its per-game upscaling modules (OptiScaler, XeSS XMX driver and scope, launch environment, game list, REFramework, Decky Framegen detection, downloads) and their tests in `packaging/helpers/gamecove_upscale/`, its launch wrapper as `packaging/libexec/gamecove-run`, and `data/games.json` (ClawDeck's list, derived from OptiScaler's GameConfigs, GPL-3.0); its MSI BIOS check (`msibios.py`) as the MSI source of the firmware index (`gamedb/gamedb/firmware/sources/msi.py`).
- **Device fixes** (each fix names its source in `app/data/fixes.json` and `docs/DEVICE-FIXES.md`): Bazzite's udev rules (Apache-2.0) for the AX210 D3cold, GPD fingerprint, ROG Ally X controller wakeup and Ally fingerprint drain fixes; aarron-lee's gpd-win-tricks (the Win Max 2 touch wakeup rule) and SimpleDeckyTDP (Ally MCU powersave, BSD-3-Clause); Matthew Schwartz's i8042 patch and Dmitry Torokhov's review (Claw keyboard wakeup as a udev rule); Handheld Daemon's Claw wakeup handling; alexl83's OneXFly F1 panel-type fix (Bazzite issue 5581, ChimeraOS/gamescope-session PR 128); the SteamOS issue reporters behind the Claw Wi-Fi D3cold workaround. Rules rewritten for GameCove, DMI-gated.
- **decky-lsfg-vk** (xXJSONDeruloXx, GPL-3.0): lsfg-vk 2 config keys, the Lossless Scaling DLL location and its gamescope workarounds. **Decky-Framegen** (xXJSONDeruloXx): its per-game markers, so GameCove never overwrites its OptiScaler. **MangoPeel** (Gawah): which overlay knobs work on mangoapp's file. **decky-storage-cleaner** (mcarlucci): the per-game shader cache folder. Our code is our own.
- **lsfg-vk** (PancakeTAS, lsfg-vk.dev): its configuration and environment-variable docs. GameCove ships none of it; the user's own Lossless Scaling is used.
- **OptiScaler** (GPL-3.0), **OptiPatcher**, **fakenvapi** (FakeMichau), **REFramework** (onehoon's fork, MIT) and **AMD FSR SDK** (GPUOpen FidelityFX-SDK, AMD binary licence: redistribution allowed with its notice): not in GameCove's app or packages. Downloaded when the user installs or updates them, the newest from GameCove's signed upscalers list or else the tested pins (`packaging/helpers/gamecove_upscale/data/versions.json`), every file sha256 checked. Unmodified copies are kept on GameCove's `upscalers` GitHub release (`.github/workflows/upscalers.yml`, nightly), under their own licences, so a file moved upstream never breaks an install; the helper tries that copy first, then upstream. every mirrored OptiScaler build has GitHub's source archive at the exact commit it was built from next to it (`source` in `upscalers.json`; a build whose commit can't be determined isn't mirrored), and AMD's licence notice next to each AMD DLL (no notice, no copy). `upscalers.json` names each file's upstream URL and release.
- **FSR 4 on Intel XMX** (`fsr4_xmx` in versions.json): nitec's FSR 4.1.2 build for the XMX cores (OptiScaler community), made from AMD's FidelityFX SDK upscaler DLL; shared with nitec's OK and hosted on ClawDeck's `fsr4-xmx-files` branch, pinned by commit and sha256, and copied unmodified to the same `upscalers` release; downloaded only when the user asks. AMD's own DLL (`fsr4_amd`) comes from GPUOpen's FidelityFX-SDK repository under AMD's binary licence, mirrored with its notice.
- **xess-xmx-linux** (HHHHanasak1): its GitHub release, mirrored unmodified on GameCove's `upscalers` release; installed when the user installs XeSS on XMX, sha256 checked.
- **DeckyTDPTuner** (GPL-3.0): the target-fps governor rules Auto TDP's target mode follows (through ClawDeck).
- **SimpleDeckyTDP** (aarron-lee, BSD-3-Clause): device handling for the power controls, no code copied: amd-pstate per-policy CPU boost, Lenovo `lenovo-wmi-other-0` firmware attributes and its custom mode, older asus-armoury `ppt_fppt`, ROG Ally MCU power saving, writing EPP/governor only where offered, re-applying the TDP after resume.
- **PowerTools** (NGnius, GPL-3.0): re-applying every setting after resume; SMT and per-CPU online handling. No code copied.
- **Decky Battery Tracker** (safijari): battery readings (GameCove uses capacity only). **Handheld Daemon** power plugin (hhd-dev): wake and hibernate handling reviewed; not used.
- **Zendo-GIT Intel-Handheld-and-ARC-GPU-laboratory** (MIT, © 2026 ClawLab contributors): the VRR range fix and the checked panel list. Notice reproduced in [fixes/claw8ex-vrr/LICENSE.ClawLab-MIT](fixes/claw8ex-vrr/LICENSE.ClawLab-MIT).
- **OpenGamepadUI** and **gamescope-x11-client**: how a gamescope main app sets its atoms and base layers.
- **Decky Loader** (GPL-2.0) and **@decky/ui / decky-frontend-lib** (LGPL-2.1): how to reach the Steam client's `SteamClient` API over CEF remote debugging (port, tab, `.cef-enable-remote-debugging`) and the API's method names, for the opt-in Steam control. No code copied.
- **Heroic Games Launcher**: how it runs legendary, gogdl and nile for installs and parses their progress; its `heroic://` protocol for hand-offs.
- **SteamKit2** (LGPL-2.1): the `EAppState` bit values behind appmanifest `StateFlags`.
- **OpenGamepadUI** (`core/systems/mangoapp/mangoapp.gd`, GPL-3.0) and **gamescope-session-plus** (MIT): driving mangoapp's overlay level through `MANGOHUD_CONFIGFILE`.
- **node-vdf** (Anthony Beaumont, MIT): the binary KeyValues type table our parser follows. **Achievement Watcher** / **celes** (GPL) and **Steam Achievement Manager** (gibbed, zlib): where Steam keeps achievement stats and how the schema is laid out. Our code is our own.
- **Bazzite** (Apache-2.0): its Gaming Mode update path (`os-update`, polkit rules) shows which update commands work without a password.
- **Heroic Games Launcher**: the GOG sign-in URL and where gogdl keeps its login.
- **Heroic Games Launcher**: how it syncs cloud saves (`save_sync.ts`, GOG `syncSaves` and `getSaveSyncLocation`): legendary's save path from `--skip-upload --skip-download --accept-path`, GOG's save-folder variables and default Galaxy folder, its saved gogdl timestamps.
- **HueSync** (honjow, BSD-3-Clause): tested RGB handling for handheld LED nodes (Legion Go ring profile/mode/enabled order and 0-100 channels, the Ally's 12-channel layout, kernel effect names, re-applying lights after resume), followed in `fixes/controller-led` and `app/scripts/controls/input/leds.gd`. **hhd-decky** (hhd-dev): where Handheld Daemon's HTTP port and token live. Our code is our own.
- **proton-cachyos** (CachyOS), **GE-Proton** (GloriousEggroll) and **low_latency_layer** (Korthos-Software): their docs for the launch variables we set.

## Data

| Source | Use | License |
| --- | --- | --- |
| Wikidata | Titles, dates, cross-store IDs (queried through QLever, University of Freiburg, with the Wikidata Query Service as fallback) | CC0 |
| AreWeAntiCheatYet | Anti-cheat status | MIT |
| Steam Web API (`GetGlobalAchievementPercentagesForApp`) | Global achievement rarity, at most once per game per day | Steam Web API Terms of Use |
| ProtonDB data dumps ([bdefore/protondb-data](https://github.com/bdefore/protondb-data)) | Compatibility tiers: GameCove's own summary of ProtonDB community reports, not ProtonDB's official tier | [ODbL 1.0](https://opendatacommons.org/licenses/odbl/1-0/) (contents DbCL 1.0): credit ProtonDB; the derived tiers in `gamedb.json.gz` are shared under the ODbL 1.0 too |
| [IGDB](https://www.igdb.com) | Game data from IGDB: time to beat (in `gamedb.json.gz`) and upcoming release dates (in `upcoming.json.gz`), built nightly when the job has Twitch credentials | Used under the [Twitch Developer Service Agreement](https://www.twitch.tv/p/legal/developer-agreement/) with credit to IGDB, as IGDB asked: "Game data from IGDB" with a link to igdb.com wherever it shows (game page, Discover calendar, credits) and in the published files' notes |
| [IGDB](https://www.igdb.com) (game details) | Game data from IGDB: summaries, genres, themes, game modes, developers, publishers, release dates, screenshot links and critic averages (`aggregated_rating` and its count) in `gamedb.json.gz` | Same agreement and credit as above; the game page's details credit names IGDB whenever it shows IGDB's data |
| Steam store (`appdetails`, Valve) | Game details for library games (short description, genres, developers, publishers, release date, controller support, screenshots) and Steam's own `metacritic` field: nightly for a slice of the popular games, in the app on demand (cached a week) | [Steam Web API Terms of Use](https://steamcommunity.com/dev/apiterms); keyless store endpoint, about 200 requests per 5 minutes, which we stay under (one request per 1.6–2 s) |
| [Metacritic](https://www.metacritic.com) | Metascores, only as Valve publishes them in the Steam store's `metacritic` field (score and link to the game's Metacritic page). A GOG / Epic / Amazon game shows its Steam edition's score. | Never fetched from Metacritic or scraped. Shown with the label "Metacritic" and a link (QR hand-off) to the game's Metacritic page; the details credit says "Metacritic". Metacritic is a registered trademark of Fandom, Inc.; not affiliated |
| [OpenCritic](https://opencritic.com) | Top-critic average, tier and % recommended on the game page, only with the user's own free key for the OpenCritic API on RapidAPI | OpenCritic's API is licensed per key through RapidAPI, whose terms bind consumers to the provider's terms and forbid sublicensing; nothing in them allows republishing OpenCritic's scores, so **they are never put in `gamedb.json.gz` and no key ships with GameCove**. Each user's app fetches them with their own key (free plan: about 25 searches and 200 requests a day; we stop at 20 and 180). Credit: "Critic scores from OpenCritic" with a link to the game's OpenCritic page wherever a score shows |
| [SteamGridDB](https://www.steamgriddb.com) | Artwork: Change artwork on the game page (covers, heroes, logos, icons, with the artist's name under each) and the automatic fill for games with no cover, hero or logo; Discover art for games Steam has none for | [API](https://www.steamgriddb.com/api/v2) with the user's own free key, made during setup by signing in to SteamGridDB with Steam (no key ships with GameCove; the key the Decky plugin ships is reserved for that plugin and never used). Every image is credited to SteamGridDB and its artist. Images belong to their artists; game art © its publishers. Same endpoints and filters as SteamGridDB's own Decky plugin ([decky-steamgriddb](https://github.com/SteamGridDB/decky-steamgriddb), GPL-3.0), whose approach (Steam's `userdata/<id>/config/grid` names `<appid>p`, `_hero`, `_logo`, `_icon` and the logo position file) we follow; our code is our own |
| [CheapShark](https://www.cheapshark.com) | Which stores have a game on sale and by how much, links, and (US only, where they're the local price) prices and historical lows | [API terms](https://apidocs.cheapshark.com/): free, no key; deals must be opened through CheapShark's redirect links (we never use affiliate or direct links for CheapShark deals); descriptive User-Agent; no catalogue crawling. Price data by CheapShark. |
| Steam (Valve) | Prices for the user's country, sale end dates, release state and art by app id (`IStoreBrowseService/GetItems`); public wishlist import (`IWishlistService/GetWishlist`); coming-soon list for the nightly calendar (`IStoreQueryService/Query`); custom-URL lookup through the public profile XML | [Steam Web API Terms of Use](https://steamcommunity.com/dev/apiterms); called without a key; not affiliated with or endorsed by Valve. Game art © its publishers, shown to identify the game. |
| Steam (Valve), Steam insights card | Players in game now (`ISteamUserStats/GetNumberOfCurrentPlayers`), review summary and Steam Deck rating (`IStoreBrowseService/GetItems` with reviews and platforms), the latest patch notes (`ISteamNews/GetNewsForApp`, `tags=patchnotes`) and DLC ids (store `api/appdetails`) | [Steam Web API Terms of Use](https://steamcommunity.com/dev/apiterms); called without a key; not affiliated with or endorsed by Valve. |
| [SteamDB](https://steamdb.info) | Linked only: the game page shows a QR code for the game's SteamDB page | SteamDB has no API and [forbids scraping](https://steamdb.info/faq/) ("please get the information from Steam itself"); GameCove never requests anything from steamdb.info. |
| [GG.deals](https://gg.deals/) | Optional: best official-store price and historical low in your region's currency for Steam games, with your own free API key | [API terms](https://gg.deals/api/): free plan for personal, hobby and open-source use; credit GG.deals with an active link wherever its data is shown; its referral links are never altered or removed (rows open its URLs unchanged); 100 ids/min, 1,000/hour per key. No key ships with GameCove. |
| European Central Bank | Euro reference exchange rates, published in the nightly upcoming.json.gz; not used for any price the app shows | [ECB reuse policy](https://www.ecb.europa.eu/stats/ecb_statistics/governance_and_quality_framework/html/usage_policy.en.html): free for any use, unmodified, with credit. Source: ECB statistics. |
| Wikidata | Upcoming release dates for the calendar; genres, developers and publishers as the last fallback for game details | CC0 |
| ES-DE's system list (`resources/systems/linux/es_systems.xml`, Leon Styhre and contributors) | System ids and full names in `app/data/emu_systems.json` (short names are ours), used when the installed ES-DE's own file can't be read | MIT |
| ES-DE's systems and find rules (`resources/systems/linux/es_systems.xml`, `es_find_rules.xml`, Leon Styhre and contributors) | Each system's ROM path, extensions and launch commands and where each emulator and RetroArch core is looked for, in `app/data/esde_commands.json` (built by `tools/emu/esde_data.py`), so a ROM starts the way ES-DE starts it | MIT |
| EmuDeck's launcher scripts and Steam ROM Manager parsers (dragoonDorise and contributors) | Which EmuDeck launcher script runs each emulator, and the two scripts that take their arguments their own way, in `app/data/emu_launchers.json` (a table we wrote from them; no EmuDeck code ships) | GPL-3.0 |
| Maker spec pages and launch coverage (ASUS, Lenovo, MSI, OneXPlayer, AYANEO, GPD, Acer, ZOTAC) | Panel size, resolution and refresh in `devices.json` | facts, cited per row in `sources` |

We looked at PCGamingWiki (Cargo API) for controller support and engine facts and don't use it: its content is CC BY-NC-SA 3.0, and its non-commercial and share-alike terms would attach to the nightly `gamedb.json.gz`, which is shared under CC0-compatible terms and the ODbL and may be redistributed commercially by anyone (GameCove is GPL-3.0). Controller support comes from the Steam store instead. We also don't scrape Metacritic, OpenCritic or SteamDB (SteamDB forbids it).

We looked at IsThereAnyDeal for regional deal prices and don't use it: its [API terms](https://docs.isthereanydeal.com/) forbid apps "that could be considered a competition to IsThereAnyDeal" and using the API to help its competition, which a deals and price-alert feature next to CheapShark could be read as.

GOG and Epic prices for your country aren't shown (their rows say "See price"):
- GOG: the catalog API does return local prices, but the [GOG User Agreement](https://support.gog.com/hc/articles/212632089) (effective 9 March 2026, clause 11.1(e)) forbids software that "interact[s] with or affect[s] GOG services or GOG content in any way", so we don't call it.
- Epic: store search (store.epicgames.com/graphql) sits behind a Cloudflare challenge, which we won't get around, and the open free-games promotions feed only covers the week's free and featured games. Epic's [Terms of Service](https://legal.epicgames.com/epicgames/tos) (10 Sept 2026) don't address reading its store data, and our rule is to leave out unclear sources.

Device data was taken as facts (DMI strings, wattages, capability names, which buttons exist), rewritten into GameCove's own format; no code was copied from these projects. The button glyphs and device pictures in `app/assets/devices/` are original drawings made for GameCove (generated by `app/assets/devices/_tools/gen_svgs.py`, GPL-3.0-or-later) and contain no maker logos.

## GameCove's own artwork

The GameCove mark (`assets/logo.svg`, `app/assets/logo-mark.svg`, `assets/app-icon.svg`, `app/icon.svg`) and the boot intro clip (`app/assets/boot/intro.ogv`: the mark scaling in with a cyan glow sweep, 3 s, no audio) are our own, made for GameCove with Google Gemini from our own artwork and edited by us; they're part of GameCove and ship under its licence. How the clip is made and swapped: [docs/BOOT_INTRO.md](docs/BOOT_INTRO.md).

## README screenshots

The screenshots in `docs/images/` are the real app (`tools/showcase/`) with a made-up player's library of real games. The game art in them comes from each game's Steam store page (Valve's CDN), the emulated games' box art and in-game pictures from [libretro-thumbnails](https://github.com/libretro-thumbnails/libretro-thumbnails) (the set RetroArch and ES-DE scrapers use), and Discover's deals and giveaways from CheapShark as fetched on the day. That art belongs to the games' publishers and isn't covered by GameCove's GPL; none of it is in the app package.

## Device photos

"About this device" and the first-run welcome show a real photo of your handheld when a freely licensed one exists on [Wikimedia Commons](https://commons.wikimedia.org/) (or on Flickr, found through [Openverse](https://openverse.org/)). The photos aren't in the app: the weekly `device-photos` workflow re-checks each license at its source, scales the photo to 1200 px wide, converts it to WebP and publishes it to the `device-photos` release; the app downloads only your device's photo, once. Converting and resizing is the only change made. Each photo stays under its own license (below), not GameCove's GPL; the credit line under the photo in the app links to its source page. Where a row lists more than one device, the models look the same from the front and share the photo.

| Device | Commons file | Author | License |
| --- | --- | --- | --- |
| Steam Deck (LCD) | [Steam Deck (front).png](https://commons.wikimedia.org/wiki/File:Steam_Deck_(front).png) | Liam Dawe/GamingOnLinux (PNG version by VulcanSphere) | [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) |

### Maker images

For handhelds with no free photo, or none that shows the device cleanly from the front, the device panel shows the maker's own official product image, credited "Image: <Maker>" (ASUS, Valve, Lenovo, MSI, ONEXPLAYER, AOKZOE, AYANEO, GPD, Acer, ZOTAC, Orange Pi). These images are the makers' property, and GPL-3.0 doesn't apply to them. The app only stores a link (`maker_image` in [`app/data/device_photos.json`](app/data/device_photos.json), with the maker's product page it came from) and downloads that one image from the maker's own site on the user's device, unchanged except for scaling on screen; they aren't in the app package or the `device-photos` release. Two exceptions: the Acer Nitro Blaze 8's picture is bundled in the app (`app/assets/device_photos/acer-nitro-blaze-8.webp`, a flat front view made from Acer's official render, because no linkable head-on image of that model exists; like the linked images, it isn't covered by GameCove's GPL), and the README's device grid (`docs/images/devices.png`, made by `tools/device_photos/readme_grid.py`) is one committed composite that shows every model's photo, maker images included. It can be switched off ("Show maker photos", Settings > Device). A maker that wants its image removed can open an issue and we'll drop it everywhere: the link, the bundled picture and its tile in the README grid. Details: [docs/DEVICES.md](docs/DEVICES.md#maker-images-by-link-only).

## Trademarks

Product and company names are trademarks of their respective owners; GameCove is not affiliated with or endorsed by them.

GameCove shows these logos only to identify a device, chip, store or launcher. Single-colour logos are tinted one flat colour to match the theme. Where a maker publishes no vector logo, its official PNG/JPG logo was traced into a single-colour SVG and checked pixel by pixel against the original (shapes and proportions kept; nothing redrawn). Most come from [Simple Icons](https://simpleicons.org) (simple-icons 16.37.0). Simple Icons releases its icon data under [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/), but the marks themselves still belong to their owners. Any company can ask for its logo to be removed: see [docs/BRANDS.md](docs/BRANDS.md#logo-removal-requests). The full table is [`app/data/brand_logos.json`](app/data/brand_logos.json).

| Logo | Source | Licence of the file | Notice |
| --- | --- | --- | --- |
| Steam (`app/assets/brand/steam.svg`) | [Simple Icons](https://simpleicons.org) 16.37.0, slug `steam` | CC0-1.0 (Simple Icons) | Steam and the Steam logo are trademarks and/or registered trademarks of Valve Corporation in the U.S. and/or other countries. |
| Epic Games Store (`app/assets/brand/epic.svg`) | [Simple Icons](https://simpleicons.org) 16.37.0, slug `epicgames` | CC0-1.0 (Simple Icons) | — |
| GOG (`app/assets/brand/gog.svg`) | [Simple Icons](https://simpleicons.org) 16.37.0, slug `gogdotcom` | CC0-1.0 (Simple Icons) | — |
| Heroic Games Launcher (`app/assets/brand/heroic.svg`) | [Simple Icons](https://simpleicons.org) 16.37.0, slug `heroicgameslauncher` | GPL-3.0-only (Heroic icon, via Simple Icons) | Heroic Games Launcher icon © Heroic Games Launcher contributors, GPL-3.0-only (github.com/Heroic-Games-Launcher/HeroicGamesLauncher). Unmodified Simple Icons rendering. |
| Lutris (`app/assets/brand/lutris.svg`) | [Simple Icons](https://simpleicons.org) 16.37.0, slug `lutris` | GPL-3.0 (Lutris icon, via Simple Icons) | Lutris icon © Lutris contributors, GPL-3.0 (github.com/lutris/lutris). Unmodified Simple Icons rendering. |
| Bottles (`app/assets/brand/bottles.svg`) | [official](https://github.com/bottlesdevs/Bottles/blob/main/data/icons/hicolor/scalable/apps/com.usebottles.bottles.svg) | GPL-3.0-only | Bottles icon © Bottles contributors, GPL-3.0-only (github.com/bottlesdevs/Bottles). Unmodified. |
| Valve (`app/assets/brand/valve.svg`) | [Simple Icons](https://simpleicons.org) 16.37.0, slug `valve` | CC0-1.0 (Simple Icons) | — |
| MSI (`app/assets/brand/msi.svg`) | [Simple Icons](https://simpleicons.org) 16.37.0, slug `msi` | CC0-1.0 (Simple Icons) | — |
| ASUS (`app/assets/brand/asus.svg`) | [Simple Icons](https://simpleicons.org) 16.37.0, slug `asus` | CC0-1.0 (Simple Icons) | — |
| ROG (`app/assets/brand/rog.svg`) | [Simple Icons](https://simpleicons.org) 16.37.0, slug `republicofgamers` | CC0-1.0 (Simple Icons) | — |
| Lenovo (`app/assets/brand/lenovo.svg`) | [Simple Icons](https://simpleicons.org) 16.37.0, slug `lenovo` | CC0-1.0 (Simple Icons) | — |
| Acer (`app/assets/brand/acer.svg`) | [Simple Icons](https://simpleicons.org) 16.37.0, slug `acer` | CC0-1.0 (Simple Icons) | — |
| Intel (`app/assets/brand/intel.svg`) | [Simple Icons](https://simpleicons.org) 16.37.0, slug `intel` | CC0-1.0 (Simple Icons) | — |
| AMD (`app/assets/brand/amd.svg`) | [Simple Icons](https://simpleicons.org) 16.37.0, slug `amd` | CC0-1.0 (Simple Icons) | — |
| Amazon Games (`app/assets/brand/amazon.svg`) | Traced from the 256 px icon in Amazon's official [Amazon Games app installer](https://gaming.amazon.com/aga/AmazonGamesSetup.exe) | Trademark; trace of the official icon | Amazon, Amazon Games and the smile logo are trademarks of Amazon.com, Inc. or its affiliates. |
| OneXPlayer (`app/assets/brand/onexplayer.svg`) | [Official SVG](https://www.onexplayer.com/assets/Logo-03078c08.svg) from onexplayer.com, fills removed for tinting | Trademark of One-Netbook Technology | — |
| AYANEO (`app/assets/brand/ayaneo.svg`) | Traced from the [official emblem PNG](https://shop.ayaneo.com/cdn/shop/files/AYA_logo__20210601_-02.png?v=1663762027) (matches the ayaneo.com header) | Trademark of AYANEO; trace of the official logo | — |
| AOKZOE (`app/assets/brand/aokzoe.svg`) | Traced from the [official store logo PNG](https://aokzoestore.com/cdn/shop/files/aokzoe_logo115.png?v=1679997801) | Trademark of AOKZOE; trace of the official logo | — |
| GPD (`app/assets/brand/gpd.svg`) | Traced from the [official gpd.hk logo PNG](https://img.website.xin/contents/sitefiles3601/18006016/images/176080729.png) | Trademark of Shenzhen GPD Technology Co., Ltd.; trace of the official logo | — |
| ZOTAC GAMING (`app/assets/brand/zotac.svg`) | Traced from the [official ZOTAC GAMING logo](https://www.zotacstore.com/media/wysiwyg/zotac_gaming_logo_1.jpg) on ZOTAC's store | Trademark of ZOTAC International (MCO) Ltd.; trace of the official logo | — |
| Orange Pi (`app/assets/brand/orangepi.svg`) | Traced from the emblem in Orange Pi's own boot theme ([orangepi-build](https://github.com/orangepi-xunlong/orangepi-build/blob/next/external/packages/plymouth-theme-orangepi/orangepi-logo.png)) | Trademark of Shenzhen Xunlong Software Co., Ltd.; trace of the official logo | — |

**These logos are not GPL-licensed.** The files in `app/assets/brand/` are their owners' trademarks (or, for Heroic, Lutris and Bottles, those projects' GPL icons), shipped only to identify a device, chip, store or launcher: nominative use, never as GameCove's branding or to suggest endorsement. GameCove's GPL-3.0-or-later licence doesn't cover them, and Simple Icons' CC0 dedication covers the path data, not the marks. A maker that wants its logo removed only has to ask: it's switched off in `app/data/brand_logos.json` and the file deleted in the next release ([docs/BRANDS.md](docs/BRANDS.md#logo-removal-requests)). Licence note: [app/assets/brand/LICENSE.md](app/assets/brand/LICENSE.md).

Every brand ships a logo. For stores and launchers, GameCove can also show the icon the user's own system already has installed; nothing of that is copied or redistributed.
