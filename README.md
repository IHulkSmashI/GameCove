<p align="center">
  <img src="assets/logo.svg" alt="GameCove logo" width="180">
</p>

<h1 align="center">GameCove</h1>

<p align="center"><b>The all-in-one companion for Linux handhelds.<br>Every store's games in one library, a quick menu with every setting your handheld has,<br>and the fixes your exact model needs. Free, open source and controller-first.</b></p>

<p align="center">
  <a href="https://github.com/IHulkSmashI/GameCove/releases"><img src="https://img.shields.io/github/v/release/IHulkSmashI/GameCove?include_prereleases&filter=v*&label=Latest%20Release&logo=github&color=7c3aed" alt="Latest release"></a>
  <!-- Downloads badge goes back once v0.1.0 is out: https://img.shields.io/github/downloads/IHulkSmashI/GameCove/total (only app releases are here; the data GameCove downloads lives in IHulkSmashI/GameCove-data) -->
  <a href="https://github.com/IHulkSmashI/GameCove/commits/main"><img src="https://img.shields.io/github/last-commit/IHulkSmashI/GameCove?label=Last%20update" alt="Last update"></a>
  <br>
  <a href="#contents"><img src="https://img.shields.io/badge/Guide%20%26%20FAQ-Read%20the%20docs-2563eb?logo=readthedocs&logoColor=white" alt="Guide and FAQ"></a>
  <a href="https://discord.gg/tuUsn6sSZH"><img src="https://img.shields.io/badge/Discord-Join%20the%20server-5865F2?logo=discord&logoColor=white" alt="Join the Discord"></a>
  <a href="https://www.reddit.com/r/GameCoveLinux/"><img src="https://img.shields.io/badge/Reddit-r%2FGameCoveLinux-FF4500?logo=reddit&logoColor=white" alt="Reddit: r/GameCoveLinux"></a>
  <a href="https://github.com/IHulkSmashI/GameCove/discussions"><img src="https://img.shields.io/badge/Community-Discussions-5865F2?logo=github&logoColor=white" alt="Community: GitHub Discussions"></a>
  <a href="https://github.com/IHulkSmashI/GameCove/issues/new?template=tester_signup.yml"><img src="https://img.shields.io/badge/Test%20it-on%20your%20handheld-0ea5e9" alt="Sign up to test on your handheld"></a>
  <br>
  <a href="#install"><img src="https://img.shields.io/badge/Runs%20on-Bazzite%20%7C%20SteamOS-1f9e8f?logo=linux&logoColor=white" alt="Runs on Bazzite and SteamOS"></a>
  <a href="https://godotengine.org"><img src="https://img.shields.io/badge/Made%20with-Godot%204.7-478cbf?logo=godotengine&logoColor=white" alt="Made with Godot 4.7"></a>
  <a href="https://ko-fi.com/gamervault"><img src="https://img.shields.io/badge/Support-Ko--fi-FF5E5B?logo=kofi&logoColor=white" alt="Support on Ko-fi"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/IHulkSmashI/GameCove?label=License&color=f0b429" alt="License"></a>
</p>

<p align="center">
  <img src="docs/images/home.webp" alt="Home: what you're playing, your achievements, what's installed" width="32%">
  <img src="docs/images/quick-menu.webp" alt="Quick menu in a game: frame limit, TDP, upscaling, Record" width="32%">
  <img src="docs/images/library.webp" alt="One library for Steam, Epic, GOG and Amazon" width="32%">
</p>

## One app, the whole handheld

GameCove is the screen your handheld boots into. Your games sit up front, and everything you'd normally need a plugin,
a script or a Windows app for is built in.

- 🔥 **The best upscaler your chip runs, set up for you.** FSR 4.1.2 on Intel's XMX cores with XeSS frame generation
  up to 4x, FSR 4.1.2 on AMD (the Z1 Extreme too), Lossless Scaling frame generation for everything else, and low
  latency with every frame generator that has one. The upscaler files come with GameCove, so there is nothing to
  copy: it's ready before a game's first start, and one tap takes it out again. (Two optional pieces download when
  you ask: lsfg-vk for Lossless frame generation, and the XeSS driver's vendor files.)
- 🎮 **Every store, one library.** Steam, Epic, GOG and Amazon side by side, with art, critic scores, time to beat,
  achievements and ProtonDB ratings. Install, update, repair and move games right from the handheld.
- ⚡ **A quick menu with every setting your handheld has**, one button away in any game: TDP, fan, frame limit,
  refresh rate, VRR, gyro, stick lights, charge limit and more. It only shows what your model can actually do.
- 🔋 **Auto TDP** finds the lowest power that holds your frame rate, learns each game on battery and plugged in, and
  gives power back within seconds when a scene gets heavy.
- 🛠️ **[Fixes for your exact model](#fixes-for-your-handheld),** applied at install, checked every night, and removed
  again when your system catches up. Each says what it changes and has an **Undo**.
- 🕹️ **Emulation with EmuDeck:** every ROM in your ROM folders is a real game in the Library, like your Steam games:
  ES-DE's art and details, its own page, Play, play time, filters by console. ES-DE, EmuDeck and Steam ROM Manager
  open from one Emulation page. Favourites, hidden games and collections work for every store.
- 🎯 **Profiles per game and per power source.** Change it in a game and it's saved for that game, with different
  values on battery and plugged in.
- 🏷️ **Discover:** deals in your real local prices, wishlist price alerts and a release calendar.
- 📺 **Stream from your PC** through Moonlight: GameCove finds your PC, pairs with a PIN and wakes it.
- 🔄 **One Updates page** for the OS, BIOS and firmware, drivers, upscalers and apps.
- 🛡️ **Safe by design:** everything can be undone, repeated crashes drop you back in Steam Gaming Mode, and there's no
  telemetry and no account.

**Tested on** the MSI Claw 8 EX AI+ (Bazzite) and the ASUS ROG Ally (SteamOS), and 48 more models set up from
tested data. GameCove recognises your exact model and only shows what it can do:

| Support | Handhelds |
| --- | --- |
| **Tested on hardware** | MSI Claw 8 EX AI+ (Bazzite), ASUS ROG Ally (SteamOS) |
| **Supported** | Steam Deck LCD and OLED, the other MSI Claws, ROG Ally X and Xbox Allys, Legion Go, Go 2 and Go S, most OneXPlayers, AOKZOE, AYANEO, GPD, ZOTAC, Acer Predator Atlas 8, Orange Pi Neo, and the Valve Steam Machine for the TV ([every model](#supported-handhelds)) |
| **Basic** | Any other handheld: safe settings for the chip, and model settings once someone helps us test it |

| System | How GameCove installs |
| --- | --- |
| **Bazzite** and Fedora Atomic | A system package; your previous system stays in the boot menu |
| **SteamOS** | A system extension that survives SteamOS updates; read-only mode stays on |

> **Install in one line.** In Desktop Mode, open a terminal (Konsole) and run:
>
> ```sh
> curl -fsSL https://raw.githubusercontent.com/IHulkSmashI/GameCove/main/packaging/get-gamecove.sh | bash
> ```
>
> The installer takes it from there. Full steps: [Install](#install).

## Fixes for your handheld

Some handhelds need a nudge before the basics work on Linux: sleep that stays asleep, the built-in buttons, gyro,
Wi-Fi after waking, touch that lines up with the picture. GameCove knows which of these your exact model needs,
applies them when you install it, and takes them out again the day your system doesn't need them any more.

<table>
<tr>
<td width="33%"><img src="docs/images/fixes.webp" alt="Fixes page on an MSI Claw 8 EX"><br><sub>Fixes for your exact model: Recommended or Optional, each with Undo</sub></td>
<td width="33%"><img src="docs/images/fixes-details.webp" alt="A fix's details"><br><sub>Details: what it changes, how it's undone, the risk, where it was tested</sub></td>
<td width="33%"><img src="docs/images/fixes-retired.webp" alt="A fix the system now does itself, in History"><br><sub>Your system caught up: removed, in History, Keep it anyway</sub></td>
</tr>
<tr>
<td width="33%"><img src="docs/images/fixes-attention.webp" alt="Start dialog for a fix in the system's way"><br><sub>A fix in your system's way is shown at start until it's out</sub></td>
<td width="33%"><img src="docs/images/device.webp" alt="About this device"><br><sub>About this device: your model, chip, drivers, memory</sub></td>
<td width="33%"><img src="docs/images/battery-history.webp" alt="Battery history in About this device"><br><sub>Battery history: 7 days and each game's drain</sub></td>
</tr>
</table>

Every fix in Settings > Device > **Fixes** says what it changes, how it's undone and where it comes from, and carries
one of two badges:

| Badge | What it means |
| --- | --- |
| **Recommended** | It fixes something that breaks everyday use on your model, the workaround is proven and safe, and one press undoes it. Preselected when you install. |
| **Optional** | Everything else we offer: it helps only some units, or isn't proven widely enough to switch on for you. Yours to turn on. |
| *Tested on hardware* | A second, smaller badge: we ran that fix on that exact model ourselves. Without it, the fix comes from projects that tested it (Bazzite, InputPlumber and others), linked as its sources. |

| Fix | Restores | For | Tested on hardware | Your system today |
| --- | --- | --- | --- | --- |
| **MSI buttons**<br>Makes the two MSI buttons next to the screen work: left opens the menu, right opens Quick Access. | Controls and built-in buttons | **Recommended**: MSI Claw 8 EX AI+ | MSI Claw 8 EX AI+ (Bazzite, 2026-11-09) | Bazzite: Not fixed (InputPlumber still maps the board to claw2). SteamOS: Not supported on SteamOS. |
| **Smooth screen down to 30 fps**<br>Lets VRR keep games smooth down to 30 fps instead of 48. | Screen | **Recommended**: MSI Claw 8 EX AI+, MSI Claw 8 AI+<br>**Optional**: MSI Claw 7 AI+, MSI Claw A1M | MSI Claw 8 EX AI+ (Bazzite, 2026-11-09) | Bazzite: Not fixed. SteamOS: Not fixed. GameCove's fix works on SteamOS too (a grub switch kept across SteamOS updates, as ClawDeck does it); untested on a SteamOS Claw (fake-root tests only). |
| **Gyro aiming**<br>Turns on the motion sensor so you can aim by tilting the Claw. | Controls and built-in buttons | **Recommended**: MSI Claw 8 EX AI+ | MSI Claw 8 EX AI+ (Bazzite, 2026-11-09) | Bazzite: Not fixed. SteamOS: Not supported on SteamOS. |
| **Volume buttons don't wake it**<br>Stops a bump of the volume buttons from waking the Claw in your bag. | Sleep and battery while asleep | **Recommended**: MSI Claw 8 EX AI+, MSI Claw 8 AI+, MSI Claw 7 AI+, MSI Claw A1M, MSI Claw A8 | Not yet | Bazzite: Not fixed: Handheld Daemon switched it off at start, InputPlumber (Bazzite 44+) doesn't. SteamOS: Not fixed (no Claw support in SteamOS). |
| **Wi-Fi back after sleep**<br>Keeps the Wi-Fi card awake enough to come back after sleep. Uses a little more battery asleep. | Wi-Fi and Bluetooth | **Optional**: MSI Claw 8 EX AI+, MSI Claw 8 AI+, MSI Claw 7 AI+, MSI Claw A1M | Not yet | Bazzite: Not fixed (reported 2024-12, no answer). SteamOS: Not fixed (SteamOS issues 2742, 2703; user-verified workaround). |
| **Intel AX210 Wi-Fi after sleep**<br>Stops the Intel AX210 Wi-Fi card from crashing after sleep. | Wi-Fi and Bluetooth | **Recommended**: AYANEO 2S, AYANEO 2, GPD WIN 5<br>**Optional**: Any handheld with the part | Not yet | Bazzite: Fixed up to stable 45.20261105 (50-intel-ax200-ax210-disable-d3cold-state.rules, after issue 5867). Bazzite reverted that rule on 2026-11-08 (in testing and unstable 45.20261110), so later builds need ours again; the fix checks the system's own rules. SteamOS: Not shipped as far as we can tell; the fix checks the system's own rules. |
| **Sleep that works**<br>Switches off the fingerprint reader, which has no Linux driver and breaks sleep. | Sleep and battery while asleep | **Recommended**: GPD WIN 4, GPD WIN Max 2 | Not yet | Bazzite: Fixed (50-gpd-win-4-fingerprint.rules, 50-gpd-wm2-fingerprint.rules). SteamOS: Not shipped (GPD isn't a SteamOS device). |
| **Stays asleep**<br>Stops the touch panel from waking the Win Max 2 right after it goes to sleep. | Sleep and battery while asleep | **Optional**: GPD WIN Max 2 | Not yet | Bazzite: Not fixed. SteamOS: Not shipped. |
| **Sticks don't wake it**<br>Stops a nudge of the sticks from waking the handheld while it goes to sleep. | Sleep and battery while asleep | **Recommended**: ASUS ROG Ally X, ASUS ROG Xbox Ally, ASUS ROG Xbox Ally X, ASUS ROG Xbox Ally X20 | Not yet | Bazzite: Fixed (50-ally-x-controller.rules). SteamOS: Unknown; the fix checks the system's own rules. |
| **No drain while off**<br>Lets the fingerprint reader power down, so the battery doesn't drain while the Ally is off. | Sleep and battery while asleep | **Recommended**: ASUS ROG Ally, ASUS ROG Ally X<br>**Optional**: ASUS ROG Xbox Ally, ASUS ROG Xbox Ally X, ASUS ROG Xbox Ally X20 | Not yet | Bazzite: Fixed (50-ally-fingerprint.rules). SteamOS: Reported fixed in SteamOS 3.8 and later (second-hand, from a write-up of the 3.8.0 notes; not yet confirmed on our Ally). The fix checks the system's own rules. |
| **Less drain while asleep**<br>Lets the controller chip power down in sleep. Needs controller firmware 319+ (Ally X 313+); checked first. | Sleep and battery while asleep | **Optional**: ASUS ROG Ally, ASUS ROG Ally X, ASUS ROG Xbox Ally, ASUS ROG Xbox Ally X, ASUS ROG Xbox Ally X20 | Not yet | Bazzite: Handled by Bazzite's own MCU workaround (shows as fixed by the system when on). SteamOS: Not on by default. |
| **Touch in the right place**<br>Makes touch line up with the picture in Gaming Mode (it's turned 90 degrees). | Touch | **Recommended**: OneXFly F1<br>**Optional**: OneXPlayer X1 (AMD), OneXPlayer X1 Mini, OneXPlayer 2, OneXPlayer 2 Pro, AOKZOE A1, AOKZOE A1 Pro | Not yet | Bazzite: Not fixed (issue 5581; waits for ChimeraOS/gamescope-session PR 128). SteamOS: Not affected the same way (SteamOS uses its own session). |

Steam Deck and Legion Go need nothing extra today: the system already covers them. Where a problem has no software
fix (say, it needs a BIOS update), the Fixes page says so in one line instead of pretending.

**Kept current every night.** A workaround should disappear when the real fix lands, so GameCove checks:

- **On your handheld**, at start and after every system update (never while you play): each fix looks whether the
  problem is still there. If your system now handles it, GameCove removes its own workaround with that fix's own
  undo, tells you once, and lists it under History, with **Keep it anyway** if you disagree. It never touches
  anything it didn't install. In Gaming Mode nothing can ask for your admin password, so the removal waits for
  Desktop Mode: said once when both copies are harmless together, shown over Home at every start when ours would get
  in the way of the system's own fix (or was withdrawn), until it's out or you keep it.
- **Every night, for everyone:** a job follows the kernel, Bazzite, SteamOS, InputPlumber, Handheld Daemon,
  linux-firmware, maker BIOS listings and each fix's own sources. When something changes, it opens an issue for a
  maintainer; rules it can check by machine are recorded by themselves. The result is a signed list your handheld
  picks up within a day, so a fix can be retired, or withdrawn, without waiting for a GameCove update.

How it all works, every fix in full and how to propose one: [docs/FIXES.md](docs/FIXES.md). The research per model:
[docs/DEVICE-FIXES.md](docs/DEVICE-FIXES.md).

---

## Contents

1. [Fixes for your handheld](#fixes-for-your-handheld)
2. [Home and library](#home-and-library)
3. [Emulation](#emulation)
4. [Quick menu and settings](#quick-menu-and-settings)
5. [Upscaling, frame generation and Auto TDP](#upscaling-frame-generation-and-auto-tdp)
6. [Profiles](#profiles)
7. [Updates](#updates)
8. [Streaming from your PC](#streaming-from-your-pc)
9. [Discover](#discover)
10. [Safety and reliability](#safety-and-reliability)
11. [Performance](#performance)
12. [Network and privacy](#network-and-privacy)
13. [Supported handhelds](#supported-handhelds)
14. [Install](#install)
15. [FAQ](#faq)
16. [Community](#community)
17. [Credits](#credits)
18. [Licence](#licence)

---

## Home and library

- **Every store in one library.** Steam, Epic, GOG and Amazon side by side. Filter by store, genre, critic score (75+)
  or what's installed, sort by Top rated, and search with the on-screen keyboard.
- **A keyboard made for a controller.** Wherever GameCove asks for text (search, a collection's name, a sign-in code
  or key, a streaming PC's address, launch options) its own on-screen keyboard slides up: letters with a number row,
  a symbols page with everything a code or a URL needs, Shift (press twice for Caps), a caret you can move, and Paste
  where a code is asked for. X deletes, Y is space, LT shifts, RT shows the symbols, LB and RB move the caret, Menu is
  Done; hold the D-pad or X and it repeats. Touch, a mouse and a real keyboard work too. In a game, typing stays
  Steam's keyboard.
- **Home stays quick with a big library.** Each Home shelf shows its first 24 games and ends with **See all**, which
  opens the Library on the same list. Thousands of ROMs don't slow Home down.
- **Favourites, hidden games and collections.** Press Menu on any game (or the star on its page) to make it a
  favourite, put it in a collection or hide it. Favourites get their own shelf on Home; the Library's Filter button (or View) opens its Filter
  sheet for favourites, a collection, emulated games or hidden games. Your Steam collections, favourites and hidden
  games show up too (read-only: GameCove never changes them).
- **Install, update and manage from the handheld.** A download queue with pause and resume, check and repair files,
  move games to an SD card or USB drive, uninstall, launch options and the Proton version per game. Steam games launch
  through Steam, so cloud saves and Steam Input keep working. Already use Heroic? GameCove reuses its sign-ins and games.
- **Game pages that tell you what you need.** Cover art and backgrounds, the Metacritic score (and OpenCritic's with
  your own key), genres, developer, publisher, release date, screenshots, how long it takes to beat (main story,
  extras, 100%), Steam achievements with your progress, ProtonDB compatibility, and anti-cheat status before you hit
  play.
- **Complete details for every store.** Missing descriptions, genres, release dates, screenshots and art get filled in
  for Epic, GOG and Amazon games too, from the game's Steam edition and GameCove's nightly game database.
- **Steam insights.** On a Steam game's page: players right now, review score, the Steam Deck rating, the last update
  with its patch notes, DLC with prices, and a SteamDB link you open on your phone.
- **Change artwork.** Pick any cover, banner, logo or icon from SteamGridDB's community for any game, Steam or not (it
  can update Steam's own library art too). Free with your own SteamGridDB key, which setup gets you in about a minute.
- **Cloud saves for Epic and GOG.** Just before an Epic or GOG game starts, GameCove gets your newest save from the
  store's own cloud (through legendary and Heroic's gogdl, with your sign-in); just after it ends, yours goes up. The
  game page says how it stands ("Saves synced 2 min ago"), with a switch per game, Sync now, and a local backup before
  anything replaces a save on the handheld. Changed on both sides? You pick, with the newer one highlighted. No
  connection? The game starts anyway. Steam games keep Steam Cloud; Amazon games aren't covered (nile has no save sync).
- **Battery drain per game.** "Drains about 9 W, ~5 h on a full charge" on a game's page once you've played it on
  battery for a while, and a 7-day battery chart with every game's drain in About this device. Recorded only when a
  game starts or ends, the handheld sleeps or wakes, or the charger goes in or out.
- **Store sign-in with your phone.** Scan a QR code and sign in there. No typing passwords on the handheld. A code
  or key you'd rather enter here goes in with the on-screen keyboard, or its Paste key.
- **Your desktop apps too.** Browsers, Discord, Spotify, a video player, emulator front-ends: every Flatpak and desktop
  app on the handheld (minus settings tools and terminal programs) in an **Apps** view, reached from the Library's
  header or Home. Pin your favourites to Home's Apps shelf with X; they open full screen like a game, with the quick
  menu over them, and closing one brings you back.
- **Controller battery in the top bar** for wired, 2.4 GHz and Bluetooth pads that report one (from UPower, read when
  something changes, never on a timer).
- **Four themes:** Cove, Midnight, Sunset and Light.

<table>
<tr>
<td width="33%"><img src="docs/images/game.webp" alt="Game page"><br><sub>Game page: Metacritic, game facts, time to beat</sub></td>
<td width="33%"><img src="docs/images/achievements.webp" alt="Achievements on the game page"><br><sub>Achievements with global unlock rates</sub></td>
<td width="33%"><img src="docs/images/game-saves.webp" alt="Cloud saves and battery drain on a GOG game's page"><br><sub>Cloud saves for a GOG game, and what it drains on battery</sub></td>
</tr>
<tr>
<td><img src="docs/images/library-filter.webp" alt="The Library's Filter sheet"><br><sub>Filter: favourites, your collections, emulation, hidden games</sub></td>
<td><img src="docs/images/apps.webp" alt="The Apps view"><br><sub>Your desktop apps, full screen, pinned to Home with X</sub></td>
<td><img src="docs/images/home-light.webp" alt="Home in the Light theme"><br><sub>The Light theme</sub></td>
</tr>
<tr>
<td><img src="docs/images/keyboard.webp" alt="Searching the Library with the on-screen keyboard"><br><sub>Search: the on-screen keyboard, with the controller's buttons on its keys</sub></td>
<td><img src="docs/images/keyboard-code.webp" alt="Typing a key with the symbols page, Caps on, Paste beside the field"><br><sub>A sign-in code or key: symbols, Caps, Paste</sub></td>
<td><img src="docs/images/keyboard-light.webp" alt="The on-screen keyboard in the Light theme"><br><sub>The same keyboard in Light</sub></td>
</tr>
</table>

## Emulation

GameCove works with what EmuDeck (or RetroDECK, or ES-DE on its own) already set up, so your console games live in the
same interface as everything else.

- **Every ROM is a game.** We read every ROM folder your setup points at (EmuDeck's, also on an SD card, ES-DE's own,
  RetroDECK's) and list each game the way ES-DE does: one entry per game (a `.m3u` for its discs, a `.cue` for its
  tracks, a `Game.ps3` folder as one game), a clean title ("Super Game (USA) [!]" reads "Super Game"), ES-DE's
  description, developer, genres, players and rating from its `gamelist.xml`, and the box art, fan art and marquee
  ES-DE downloaded. No art yet? A card in the console's colours with its name on it.
- **Plays the way your setup plays it.** Play starts the emulator ES-DE would pick (your alternative emulator for the
  system or the game included) through EmuDeck's own launcher scripts, RetroDECK's command line, or ES-DE's command,
  in its own scope like any game: the quick menu, sleep, recording and play time all work.
- **Like your Steam games.** Filter > Emulation, then any console; search finds ROM titles; favourites, hidden games
  and collections work (ES-DE's favourites and hidden games are where we start; your changes stay ours); what you
  played last is on Home. A game Steam ROM Manager also added to Steam shows once.
- **One Emulation page** (Library > Filter > Emulation page, or ES-DE's tile): every console with its game count
  (pick one and the Library opens on it), what you played last, each ROM folder, open ES-DE or RetroDECK full screen
  like a game, open EmuDeck for emulator updates and settings, and add ROMs to Steam too with Steam ROM Manager.
  Settings > Stores > **Show emulated games in the Library** turns the ROM games off.
- **Nothing installed yet?** The page shows a QR code to emudeck.com and three short steps.
- GameCove never downloads or ships games or BIOS files. Play backups of games you own.

<table>
<tr>
<td width="50%"><img src="docs/images/emulation.webp" alt="The Emulation page"><br><sub>The Emulation page: ES-DE, EmuDeck, Steam ROM Manager, your systems</sub></td>
<td width="50%"><img src="docs/images/home-emulation.webp" alt="Home's Emulation and Apps shelves"><br><sub>Your ROMs on Home with their box art, and the Apps shelf</sub></td>
</tr>
</table>

## Quick menu and settings

Press the Quick Access button (or Guide) and the quick menu slides in, in a game or on the home screen. It only shows
what your handheld can actually do, and anything it can't gets a plain reason instead of a broken switch. Exit game and
Switch to Desktop Mode live here too.

**Quick Access is GameCove's in a game too.** A short press opens our quick menu over the game, and holding it opens
Steam's keyboard. Steam's own quick access menu (friends, notifications) is one press away on the Shortcuts strip, and
if you'd rather Quick Access went to Steam in games, one switch in Settings > Controller > Button shortcuts gives it
back. Guide works just like before. Leave for Steam Gaming Mode or the desktop and every button is Steam's again.

**Shortcuts strip.** A row of big buttons along the top of the quick menu for the things you want in one press. Pick
which ones show and in what order in Settings > Quick menu.

| Shortcut | What it does |
| --- | --- |
| **Keyboard** | Steam's on-screen keyboard over the game |
| **Steam menu** | Steam's own quick access menu over the game |
| **Screenshot** | Saves a picture of the game (without our menu) to Pictures/Screenshots |
| **Record** | Starts and stops recording; the button shows the time |
| **Mouse mode** | Right stick moves the pointer, right trigger clicks |
| **Mute** | Sound off and back on |
| **Send key** | Esc, Enter, Tab, Alt+Enter or Alt+F4, typed into the game (for stuck launchers and dialogs) |
| **Sleep** | Puts the handheld to sleep |
| Also there to add | Performance overlay, microphone, Wi-Fi, Bluetooth, airplane mode, night light, **Force close** (ends a hung game at once) and **Power** (restart, shut down, Desktop Mode, Steam Gaming Mode) |

**Button shortcuts.** Settings > Controller > Button shortcuts shows your handheld with each button it has: set what
a back button presses (a gamepad button, a mouse click, a key or a key combination like Alt+Enter, or a GameCove
action like Screenshot or Keyboard) and what a hold on the buttons next to the screen does. Holds are only for those
buttons, never for A, B, X, Y or the back buttons that games hold themselves, and Guide stays free for Steam's chords.
A test area shows each press and hold as it happens, and one press puts everything back.

<table>
<tr>
<td width="50%"><img src="docs/images/quick-shortcuts.webp" alt="Quick menu with the Shortcuts strip"><br><sub>The Shortcuts strip over a game</sub></td>
<td width="50%"><img src="docs/images/settings-buttons.webp" alt="Settings, Controller, Button shortcuts"><br><sub>Button shortcuts: press and hold for each button</sub></td>
</tr>
<tr>
<td><img src="docs/images/quick-shortcuts-light.webp" alt="Shortcuts strip in the Light theme"><br><sub>The strip in the Light theme</sub></td>
<td><img src="docs/images/settings-buttons-light.webp" alt="Button shortcuts in the Light theme"><br><sub>Button shortcuts in the Light theme</sub></td>
</tr>
</table>

| Tab | What you control |
| --- | --- |
| **This game** | Performance overlay, frame limit, TDP, Auto TDP and its target, upscaling, frame generation, Lossless frame gen, the scaling filter, and **Record** (screen and sound, until you stop it) |
| **Power** | Power profile, TDP, boost, fan mode, battery saver, charge limit, CPU boost, energy preference (Settings > Power also has **Sleep at low battery**: at 3 to 10 % on battery, a 30 s warning any button cancels, then sleep; off by default) |
| **Display** | Brightness, refresh rate, frame limit, VRR, night light, colour vibrance, scaling filter and sharpness, screen effects |
| **Audio** | Volume, mute, output device, microphone mute and input, each app's own volume, and play/pause and skip for the music playing behind your game |
| **Controller** | Controller type, gyro, Nintendo button layout, rumble, stick lights (effect, colour, brightness), mouse mode |
| **Device** | Wi-Fi, Bluetooth and your Bluetooth devices, airplane mode, keep awake, screenshot, plus your device's fixes |

<table>
<tr>
<td width="50%"><img src="docs/images/quick-power.webp" alt="Quick menu, Power tab"><br><sub>Power: TDP, fan, battery saver, charge limit</sub></td>
<td width="50%"><img src="docs/images/quick-display.webp" alt="Quick menu, Display tab"><br><sub>Display: brightness, refresh rate, VRR, vibrance</sub></td>
</tr>
<tr>
<td><img src="docs/images/quick-audio.webp" alt="Quick menu, Audio tab"><br><sub>Audio: the music playing, each app's own volume</sub></td>
<td><img src="docs/images/quick-controller.webp" alt="Quick menu, Controller tab"><br><sub>Controller: type, gyro, rumble</sub></td>
</tr>
<tr>
<td><img src="docs/images/quick-leds.webp" alt="Quick menu, stick lights"><br><sub>Stick lights: effect, colour, brightness</sub></td>
<td><img src="docs/images/quick-device.webp" alt="Quick menu, Device tab"><br><sub>Device: your model, its fixes, Wi-Fi and Bluetooth</sub></td>
</tr>
</table>

Everything else is one press away in **Settings**, grouped the same way, and every setting has a short line saying what
it does.

<details>
<summary><b>Everything in Settings</b></summary>

- **Power:** TDP and boost limits, power and platform modes, a thermal limit, **Auto TDP**, fan presets and **custom
  fan curves**, **charge limit** and battery care, battery saver that turns on by itself at a level you pick, sleep
  mode, plus CPU (boost, SMT, active cores, energy preference, governor, CPU ceiling) and graphics (GPU performance
  level, clocks, power profile). Every TDP and boost value stays inside your handheld maker's own limits for that
  model (and the firmware's, when it's stricter), whatever sets it: the slider, a preset, Auto TDP or a game's profile.
- **Display:** refresh rate (and extra refresh rates where the panel allows), VRR, allow tearing, colour temperature,
  night light with a schedule, vibrance, **HDR** with inverse tone mapping and SDR brightness, screen effects, rotation,
  dim and screen-off timers.
- **Sound:** volume, output device, microphone and input, plus a volume for each app playing sound (turn the game
  down under your music or a voice chat).
- **Controller:** controller type (Xbox, DualSense, Steam Deck and more), **Button shortcuts** (back buttons set to any
  button, a key or key combination, a mouse click or a GameCove action; holds on the buttons next to the screen; Quick
  Access in games), gyro on/off and which sensor, stick and trigger deadzones, trackpad mode, **rumble on/off and
  strength**, a rumble test, **lights** (effect, colours, brightness, speed), mouse mode with pointer speed, a button
  tester, and one press to start over. **Steam's controller settings** (gyro aiming, layouts) open straight from the
  game for every game Steam starts, emulated games Steam ROM Manager added included, and closing them lands you back
  where you were.
- **Performance:** the overlay (FPS only, compact, a bar, full, or pick your own items, with position, size and
  opacity), upscaling and frame generation with installed versions and updates, Lossless Scaling frame generation,
  Proton version, low latency, shader threads and clearing a game's shader cache, plus **GE-Proton**: install the
  newest release in one press (checked against its checksum) and remove old ones.
- **System:** Wi-Fi, Bluetooth, airplane mode, Wi-Fi power saving, keep awake, sleep, screenshots, and **Bluetooth
  devices**: connect your controller or headphones, see their battery, pair new ones and forget old ones.
- **Media:** recording with GPU Screen Recorder (install it from here, the one-time screen-capture OK, sound on or
  off, 30 or 60 fps) and **Clips**: everything you recorded, with a picture, its length and size. Watch one full
  screen (in mpv, VLC or Celluloid; no player yet? one press installs mpv), **send it to your phone** with a QR code
  (a one-time page on your own Wi-Fi to watch and download it), or delete it.
- **Quick menu:** which shortcuts the strip shows, and their order.
- **Profiles, Appearance, Stores, Discover, Device and About GameCove:** your saved profiles, themes, store sign-ins and
  downloads, Discover's region and keys (SteamGridDB, gg.deals, OpenCritic), fixes, storage (with one-press
  **clean-up** of the shader caches uninstalled games leave behind), updates, and the network and privacy switches.

<table>
<tr>
<td width="50%"><img src="docs/images/settings-power.webp" alt="Settings, Power"><br><sub>Power: battery saver, Sleep at low battery, charge limit</sub></td>
<td width="50%"><img src="docs/images/settings-performance.webp" alt="Settings, Performance, GE-Proton"><br><sub>Performance: GE-Proton in one press</sub></td>
</tr>
<tr>
<td><img src="docs/images/settings-system.webp" alt="Settings, System, Bluetooth devices"><br><sub>System: Bluetooth devices with their battery</sub></td>
<td><img src="docs/images/settings-media.webp" alt="Settings, Media, Clips"><br><sub>Media: recording and your clips</sub></td>
</tr>
<tr>
<td><img src="docs/images/settings-saves.webp" alt="Settings, Saves"><br><sub>Saves: cloud saves for Epic and GOG games</sub></td>
<td><img src="docs/images/settings-storage.webp" alt="Settings, Device, Storage"><br><sub>Storage: drives, game folders and Clean up</sub></td>
</tr>
</table>

</details>

## Upscaling, frame generation and Auto TDP

**GameCove sets up the best upscaler your handheld runs, per game, before you press Play.** It reads your chip and
what the game ships, puts the right files in, and shows afterwards what really ran. No folders, no launch options,
and the upscaler files come with GameCove (lsfg-vk and the XeSS driver's vendor files download only when you ask). The full guide and the table for every chip are in [docs/UPSCALING.md](docs/UPSCALING.md).

| Your chip | What "Best for this handheld" picks | Frame generation |
| --- | --- | --- |
| **Intel Arc with XMX** (Claw 8 EX, Claw 8 AI+, OneXPlayer 3) | **FSR 4.1.2 on the XMX cores**, then its Lite model, then XeSS 2 | XeSS frame generation **2x, 3x or 4x** with XeLL low latency |
| **AMD Z1 Extreme, Z2 Extreme, 780M / 890M, Ryzen AI** | **FSR 4.1.2** from AMD's own file; FSR 3.1 by itself if it doesn't come up | FSR or XeSS frame generation 2x with low latency |
| **Steam Deck, Z2 Go and other RDNA 2** | FSR 3.1; FSR 4.1.2 is one tap away, with its cost said plainly | FSR frame generation 2x |
| **NVIDIA** | Nothing: the game's own DLSS is already the best | The game's own |
| **Anything** | | Lossless Scaling frame generation, if you own Lossless Scaling on Steam |

- **Three plain choices per game:** Best for this handheld, My choice, and Native (nothing added, everything undone).
  Every option has one line saying what it is.
- **You see what's really running.** After a start the card reads the logs and says, for example,
  "Active: FSR 4.1.2 on XMX, XeSS frame generation 2x, XeLL low latency", or why it isn't active.
- **One install.** The upscaler files come with GameCove, each pinned and checked (the optional lsfg-vk and the XeSS
  driver's vendor files, about 260 MB, download only when you ask). The size of it all is in
  Settings > Device > Storage, and uninstalling puts every game back exactly as it shipped.
- **Safe.** Never on games with anti-cheat. Never on top of another tool's upscaler or ReShade. Never two frame
  generators at once. Nothing in a game folder is changed for good.
- **Always the newest tested files.** A nightly job watches every project this builds on and adopts a new build only
  after 72 hours and a smoke check, through a signed list your handheld verifies. The version before is kept.
- **Lossless Scaling frame generation** is for owners of Lossless Scaling only: GameCove uses the copy in your own
  Steam library and never ships or downloads it.

**Auto TDP** watches your frame rate and finds the lowest power that keeps it, so the battery lasts longer without you
noticing a drop. Give it a target FPS or let it pick one. It learns each game on battery and plugged in, gives power
back within seconds in heavy scenes, skips loading screens, and puts everything back when you quit. It's ported from
ClawDeck, which was built and tuned on real hardware, and works on every handheld with a TDP control.

## Profiles

Change something in the quick menu while a game runs and it's saved for that game. Set different values for battery
and plugged in, and GameCove switches when you plug in or unplug. When you quit, everything goes back to your everyday
settings.

Order of priority: this game on this power source, then this game, then battery or plugged in, then everyday. Profiles
stay with the handheld they were made on, and you can copy, reset, export and import them.

<p align="center"><img src="docs/images/profiles.webp" alt="Settings, Profiles" width="70%"></p>

## Updates

One page for everything that can be updated:

- **System:** SteamOS, Bazzite and Fedora Atomic updates, with progress, then a restart to finish.
- **BIOS and firmware:** checks your maker's latest BIOS for ASUS, Lenovo, MSI and Steam Deck, with step-by-step
  instructions (for the Ally, GameCove can download the BIOS, check it and put it on a USB drive for EZ Flash). Other
  makers get a link and your current version to compare. Controllers, docks and other parts update through fwupd.
- **Drivers:** kernel, Mesa, firmware, InputPlumber and friends, the XeSS XMX driver and OptiScaler, compared with the
  latest versions.
- **Apps:** Flatpak updates, by hand or **by themselves** once a day when no game is running (turn it on in
  Updates; it runs at the lowest priority, so a game you start meanwhile doesn't feel it).

GameCove never flashes a BIOS by itself, and firmware installs wait until you're on the charger with at least 50%
battery and no game running.

<p align="center"><img src="docs/images/updates.webp" alt="Settings, Device, Updates" width="70%"></p>

## Streaming from your PC

The **Stream** tab plays games running on your PC. Install [Vibepollo](https://github.com/Nonary/Vibepollo) on the PC
(Sunshine and Apollo work too) and GameCove finds it on your network, pairs with a PIN, shows your PC's games with box
art, wakes the PC, and streams at your handheld's exact resolution and refresh rate through Moonlight (installed for
you). Resolution, frame rate, quality, video format and HDR can be set per PC or per game, and it works away from home
over Tailscale. More in [docs/STREAMING.md](docs/STREAMING.md).

<p align="center"><img src="docs/images/stream.webp" alt="Stream tab: your PCs and their games" width="70%"></p>

## Discover

- **Deals** from the big stores, sorted and filtered by store, with the Steam review score and the lowest price ever
  next to today's.
- **Real local prices** for your Steam region, never converted guesses. Other stores show "See price" and their own page
  has it in your currency.
- **Your wishlist**, imported from Steam, with price alerts.
- **Free to keep:** games a store is giving away right now (Epic, GOG, Steam and the others CheapShark follows), with
  the store's own page one press away.
- **Release calendar** by month or as a list, with a reminder on release day.

<table>
<tr>
<td width="33%"><img src="docs/images/discover.webp" alt="Discover"><br><sub>Discover: top deals and what's coming</sub></td>
<td width="33%"><img src="docs/images/discover-free.webp" alt="Discover, Free to keep"><br><sub>Free to keep: what a store gives away now</sub></td>
<td width="33%"><img src="docs/images/deals.webp" alt="Discover, Deals"><br><sub>Deals with the lowest price ever</sub></td>
</tr>
<tr>
<td><img src="docs/images/calendar.webp" alt="Discover, Coming soon"><br><sub>Release calendar</sub></td>
<td><img src="docs/images/calendar-month.webp" alt="Discover, Coming soon by month"><br><sub>The same calendar by month</sub></td>
<td><img src="docs/images/wishlist.webp" alt="Discover, Wishlist"><br><sub>Wishlist and price alerts</sub></td>
</tr>
</table>

## Safety and reliability

- **Desktop Mode is always one press away**, from the quick menu, and Steam Gaming Mode too.
- **Crash fallback:** if GameCove crashes, hangs or fails to start three times in a row, your handheld goes back to
  Steam Gaming Mode for the rest of that boot, and GameCove tells you why the next time it opens.
- **Nothing above your device's limits.** Power, boost, clocks, fan curves and charge limits are clamped to what your
  model is rated for, and checked again by the system helper.
- **Risky screen changes revert by themselves.** After HDR or a new refresh rate you get "Keep this?" with a 15-second
  countdown.
- **Saves are never overwritten without a copy.** Before a cloud save replaces one on the handheld (or a backup is
  restored), the current one is backed up locally; a download that fails half way puts it straight back. The last 10
  backups per game are kept, plus the last 10 made by a choice between two saves or by a restore, and the game page
  restores any of them.
- **Undo everything:** fixes, upscaling files, launch options, profiles. Uninstalling puts Steam Gaming Mode back as the
  default.
- **Signed releases.** The installer checks every download against a signed checksum list before anything runs.
- **Day-to-day settings never ask for a password.** Only the install and system fixes do, in Desktop Mode.

## Performance

GameCove stays running behind your games (for the quick menu, power and TDP, and game tracking) and is built to cost
next to nothing there. With a game in front its main loop wakes about 31 times a second instead of 145, nothing polls
for the game's window (one idle `xprop -spy` watches it), the session heartbeat writes nothing, and Discover, the
metadata and art fill and update checks wait until you stop playing. Only safety work keeps running: the 15 s charger
and sleep check that puts your TDP and charge limit back after a resume, the thermal guard, and Auto TDP's once-a-second
sample while it's on. The quick menu still opens over a game in under 100 ms. On our test box that cut GameCove's
wake-ups behind a game from about 2240 to 1190 a second and its CPU time in half; most of what's left is Godot's own X11
event thread. Numbers, what runs and why, and how to measure it on your handheld:
[docs/PERFORMANCE.md](docs/PERFORMANCE.md).

## Network and privacy

No analytics, no crash reports, no telemetry, no GameCove account. GameCove never sends serial numbers, store account
IDs or anything you type into its settings to us. It only talks to the services it needs to do its job.

**Settings > About > Network and privacy** has the switches: **Background lookups** (off: nothing is requested unless
you ask for it right then), **Look up deals and prices**, **Look up game details** and **Show maker photos**, all on by
default; **Sync cloud saves** is in Settings > Saves (and per game). Some store links can carry a GameCove affiliate id (Settings > Discover > **Affiliate links**; none are set up
yet). It only changes the link, never the price, and sends nothing about you. Every call is listed in
[docs/PRIVACY.md](docs/PRIVACY.md).

<details>
<summary><b>Every service GameCove talks to, what it sends and when</b></summary>

| What | Who | What is sent | When | Switch |
| --- | --- | --- | --- | --- |
| Game database and release calendar | GitHub (the `gamedb` release of GameCove's data repo, [GameCove-data](https://github.com/IHulkSmashI/GameCove-data)) | Nothing about you | At start, at most daily | Background lookups |
| Deals, prices and free-to-keep games (Discover, wishlist) | [CheapShark](https://www.cheapshark.com) (cheapshark.com) and the Steam store API | Steam app ids and titles from your wishlist and Discover, what you search for, your store country | 45 s after start, then every 6 hours (top deals and the free-to-keep list: two requests); when you search or open a game | Look up deals and prices |
| Local prices (optional) | [GG.deals](https://gg.deals) (gg.deals) | Steam app ids, your region, your own API key | With the deals refresh, only if you added a key | Look up deals and prices, or remove the key |
| Your device's photo | GitHub (free photos on GameCove-data's `device-photos` release) or your handheld's maker (ASUS, MSI, Lenovo, ...) | One request; the address tells the site your model | At start until it's saved, then weekly | Show maker photos, Background lookups |
| Upscaler list and newer upscaler files (OptiScaler, XeSS driver, FSR 4) | GitHub (GameCove-data's `upscalers` release, signed list and mirrored files), then the project's own release | Nothing about you | The list at most daily (90 s after start) and when you change an upscaler; files only when the list has a newer tested version than the one that came with GameCove | Background lookups (daily check). With it off, the files that came with GameCove are used |
| Steam wishlist import (Discover) | steamcommunity.com (`IWishlistService`) | Your Steam profile name or SteamID64 | When you import your wishlist | You start it |
| XeSS driver installer, and the gyro firmware on the MSI Claw | Intel's and AMD's download sites (compiler, libraries, FidelityFX files); download.msi.com (sensor firmware, pinned by size and sha256) | Nothing about you | When you install the XeSS driver, or the Claw gyro fix | You start it |
| lsfg-vk for Lossless Scaling frame generation | Its author's site (builds.lsfg-vk.dev) | Nothing about you | When you press Set up Lossless frame generation, and only if you have Lossless Scaling installed | You start it |
| The list of device fixes | GitHub (the `fixes` release of GameCove's data repo, [GameCove-data](https://github.com/IHulkSmashI/GameCove-data), signed) | Nothing about you: the same file for every handheld | At most once a day, at start, never while you play | Background lookups |
| GE-Proton (Settings > Performance) | GitHub (GloriousEggroll's `proton-ge-custom` releases) | Nothing about you | When you press Check or Install | You start it |
| BIOS and firmware list and downloads | GitHub (GameCove-data's `firmware` release, signed), then only the maker's own site | Nothing about you | When you check for updates or prepare a USB drive | You start it |
| Steam insights on a game's page (players now, reviews, Steam Deck rating, last update, DLC) | Steam's public API and store | The game's app id (DLC prices: also your store country) | When you open a Steam game's page; players at most every 10 min, the rest every 12 h | Background lookups (prices: Look up deals and prices) |
| Achievements | Steam's API and CDN | The game's app id | When you open a game page | Settings > Performance |
| Game pictures in Discover and the calendar | Steam's CDN, IGDB's image server (`images.igdb.com`) and SteamGridDB's CDN (a download only starts on one of these, and every redirect hop is checked against the same list) | The picture's address (it names the game) | When a tile shows a picture that isn't saved yet | None (SteamGridDB lookups: Look up game details) |
| Game details | The Steam store (`appdetails`) | The Steam app id of a game (or of a GOG / Epic / Amazon game's Steam edition) whose details or Metacritic score are missing | In the background after start, one request every 1.6 s, cached a week; at once for the page you open | Look up game details (+ Background lookups for the background fill) |
| Critic scores (optional) | [OpenCritic](https://opencritic.com) through RapidAPI | A game's title, then its OpenCritic id, with your own key | Same as game details, only if you added a key; at most 20 searches and 180 requests a day | Look up game details, or remove the key |
| Artwork | [SteamGridDB](https://www.steamgriddb.com) | A game's Steam app id or title, with your own key | When you open Change artwork; in the background for games with no cover, hero or logo (never a ROM game) | Look up game details (+ Background lookups for the automatic fill) |
| Game art setup | Your phone, on your own network, then SteamGridDB | Your SteamGridDB key: pasted on a one-time page GameCove serves on your LAN, then checked once with SteamGridDB | Only after you choose Send from my phone in the Game art step, 10 minutes at most | You start it |
| Emulation tools | Whatever EmuDeck, RetroDECK, ES-DE and Steam ROM Manager contact themselves | Those tools' own requests (GameCove only reads their files, on the device) | Only while you have them open from the Emulation page | You start it |
| Sending a clip to your phone | Your phone, on your own network | The clip itself, from a one-time page GameCove serves on your LAN; nothing leaves your network | Only while the Send to phone code shows, until it's downloaded or 10 minutes pass | You start it |
| GPU Screen Recorder and a video player (Settings > Media) | Flathub, through Flatpak | Flatpak's own requests | When you press Install (the recorder, or mpv to watch clips) | You start it |
| Game streaming | PCs on your own network (GameStream: Vibepollo, Sunshine, Apollo) | A fixed client id and Moonlight's certificate; Wake-on-LAN packets (your PC's MAC address, to your network's broadcast addresses and to every address saved for that PC, a remote one you added included). With no PC saved and none found by mDNS, a connection attempt to port 47989 on every address of your local network | When you open the Stream tab or wake a PC | You start it |
| Cloud saves (Epic, GOG) | Epic and GOG, through legendary and heroic-gogdl (GOG's remote config once for a game Heroic doesn't know) | Your save files for the game you start or just closed, with your store sign-in; for GOG's remote config only the game's client id | Just before an Epic or GOG game starts and just after it ends; when you press Sync now | Sync cloud saves (Settings > Saves; also per game) |
| Updates, store sign-ins | Your OS, Flatpak, fwupd/LVFS, legendary / gogdl / nile | Those tools' own requests | When you update or sign in; Flatpak apps also once a day if you turned on "Update apps by themselves" | You start it (automatic app updates: off by default, and Background lookups) |

</details>

<p align="center"><img src="docs/images/privacy.webp" alt="Settings, Network and privacy" width="70%"></p>

## Supported handhelds

GameCove recognises your exact model and sets itself up for it. About this device in the app shows a photo of yours.

| Maker | Tested on hardware | Supported | Basic |
| --- | --- | --- | --- |
| **MSI** | Claw 8 EX AI+ (Bazzite) | Claw 8 AI+, Claw 7 AI+, Claw A1M, Claw A8 | |
| **ASUS** | ROG Ally (SteamOS) | ROG Ally X, ROG Xbox Ally, ROG Xbox Ally X, ROG Xbox Ally X20 | |
| **Valve** | | Steam Deck LCD, Steam Deck OLED, Steam Machine (a box for the TV: not yet tested on hardware) | |
| **Lenovo** | | Legion Go, Legion Go 2 (and Z2), Legion Go S (Z2 Go and Z1 Extreme) | |
| **OneXPlayer** | | OneXFly F1, F1 Pro and Apex; X1 (AMD, Intel, Mini, Pro); 2 and 2 Pro; G1 (AMD, Intel); 3 | X2 Mini, X2 Mini Pro, Super X |
| **AOKZOE** | | A1, A1 Pro, A1X | |
| **AYANEO** | | 2, 2S, 3, KUN, AIR 1S, AIR Plus, Flip, Flip 1S DS, Slide | |
| **GPD** | | WIN 4, WIN Mini, WIN Max 2, WIN 5 | |
| **ZOTAC** | | Gaming Zone | |
| **Acer** | | Predator Atlas 8 | Nitro Blaze 7, 8 and 11 |
| **Orange Pi** | | Neo | |

- **Tested on hardware:** we've run GameCove on it. Every setting was changed, read back from the hardware and put back.
- **Supported:** set up from data that InputPlumber, steamos-manager, PowerStation and Handheld Daemon tested on that
  device. Power limits, fans, lights, buttons and fixes are all there.
- **Basic:** GameCove runs with safe settings for the chip, and model-specific settings stay hidden until someone with
  the device helps us test it. Any other handheld gets this too.

### Screens and the Steam Machine

GameCove lays itself out for the screen it is on, from the handheld's panel size to a TV across the room: the size of
the text follows how big and how far away the screen is, not just its pixel count, so a 4K TV reads like a 1080p one.
Settings > Appearance has an **Interface size** (Small, Default, Large, Largest) for the sizes that make sense on your
screen. Ultrawide and portrait screens get a centred 16:10 area with bars at the sides. We check every screen of the
app on 34 resolutions and sizes with a layout harness (`tools/layout/run.py`, see [docs/RESOLUTIONS.md](docs/RESOLUTIONS.md)).

The **Steam Machine** and other living-room boxes (no screen or battery of their own) are supported but **not yet
tested on hardware**: we match Valve's own DMI ids (Valve / Fremont, the same pair steamos-manager uses), and everything
else is checked only against fake devices. A box gets the TV layout, no battery or handheld power settings, "device"
wording, button pictures from the controller you actually hold, and HDMI-CEC control through steamos-manager. Any other
PC with no battery gets the same generic box setup. If you have a Steam Machine, [tell us how it went](https://github.com/IHulkSmashI/GameCove/issues/new?template=tester_signup.yml).

Got one of the Supported or Basic models? Run it and [tell us how it went](https://github.com/IHulkSmashI/GameCove/issues/new?template=tester_signup.yml);
that's how a model moves up. Details per device: [docs/DEVICES.md](docs/DEVICES.md).

<details>
<summary><b>See every model</b></summary>
<br>

<p align="center"><img src="docs/images/devices.png" alt="Every device GameCove supports" width="100%"></p>

<sub>Photos: the makers' official product images (their property, removed on request), except Steam Deck (LCD) by Liam Dawe/GamingOnLinux, <a href="https://commons.wikimedia.org/wiki/File:Steam_Deck_(front).png">CC BY-SA 4.0</a>.</sub>

</details>

## Install

1. Switch to Desktop Mode and open a terminal (Konsole).
2. Run:
   ```sh
   curl -fsSL https://raw.githubusercontent.com/IHulkSmashI/GameCove/main/packaging/get-gamecove.sh | bash
   ```
   It downloads the latest release, checks its signature, adds **GameCove Installer** to your app menu and opens it.
3. The installer walks you through it: **Easy** (recommended settings: sign in to your stores or skip that, get free game art, one summary page) or **Custom** (every option).
   Choose whether your handheld boots into GameCove or keeps Steam Gaming Mode as the default with GameCove one tap
   away, sign in to your stores, get free game art, pick your fixes and extras (like Moonlight for streaming), and
   you're done.

It asks for your admin password once, for the system package and device fixes.

- **Bazzite and Fedora Atomic:** installs as a system package. Your previous system stays in the boot menu.
- **SteamOS:** installs as a system extension that survives SteamOS updates. Read-only mode stays on. After a SteamOS
  update, restart once so GameCove comes back. Our hardware testing so far was on Bazzite; the SteamOS install is
  checked by our automated tests and hasn't been run on a handheld yet, so tell us how it goes.
- **Anything else:** you can try GameCove in a window.

### Game art

The installer's Game art step (or GameCove's own first-run setup) gets you a free
[SteamGridDB](https://www.steamgriddb.com) key in about a minute. Choose Send from my phone, scan the QR code, sign in with Steam,
tap Generate API key, then paste the key on the page your phone opened and it lands on the handheld by itself (no
typing with a controller; typing or pasting it works too). GameCove checks the key, then fills in covers, banners and
logos for every game, Steam or not. GameCove ships no key of its own, so this step is what turns on the art picker and
art for non-Steam games. Skip it and you get Steam's art; add a key later in Settings > Discover > SteamGridDB key.

<table>
<tr>
<td width="50%"><img src="docs/images/installer.webp" alt="GameCove Installer, welcome"><br><sub>The installer: Easy or Custom</sub></td>
<td width="50%"><img src="docs/images/game-art-setup.webp" alt="Game art setup"><br><sub>Game art: scan, sign in with Steam on your phone, done</sub></td>
</tr>
<tr>
<td><img src="docs/images/quick-power-light.webp" alt="Quick menu in the Light theme"><br><sub>Pick your look during setup: here, Light</sub></td>
<td><img src="docs/images/game-light.webp" alt="A game page in the Light theme"><br><sub>A game page in Light, art at full colour</sub></td>
</tr>
</table>

### Update, change or remove

Open **GameCove Installer** from the app menu any time to **update**, **change options**, **repair** or **remove**
GameCove. Removing it makes Steam Gaming Mode the default again, can undo every fix, and can keep or delete your
settings. Store sign-ins stay with the store tools. Everything the installer does is logged to
`~/.local/share/gamecove/installer.log`. Manual install: [docs/SESSION.md](docs/SESSION.md).

## FAQ

<details>
<summary><b>Does it replace Steam?</b></summary>

No. Steam keeps running in the background, Steam games launch through Steam, and Steam Gaming Mode is always one press
away.
</details>

<details>
<summary><b>Do you need Decky Loader or any plugins?</b></summary>

No. Power, Auto TDP, fans, lights, the overlay, upscaling and frame generation are all built in. If you already use
Decky plugins, GameCove leaves their files alone.
</details>

<details>
<summary><b>Can it break your system?</b></summary>

Everything GameCove changes can be undone, on Bazzite your previous system stays in the boot menu, and if GameCove
keeps crashing or won't start you land in Steam Gaming Mode.
</details>

<details>
<summary><b>Does anti-cheat work?</b></summary>

Games run on the same Proton as they do in Steam. GameCove shows each game's anti-cheat status, and it never bypasses
or tampers with anti-cheat.
</details>

<details>
<summary><b>Does it cost anything?</b></summary>

No. GameCove is free and open source, and device fixes, battery features and safety settings will never sit behind a
paywall. Game art and critic scores use free keys that are yours, not ours.
</details>

<details>
<summary><b>What about CachyOS or other distros?</b></summary>

Bazzite and SteamOS come first. On other systems GameCove runs in a window, and a CachyOS package is planned.
</details>

<details>
<summary><b>How does recording work, and does it slow games down?</b></summary>

Press **Record** in the quick menu (This game) and GameCove starts [GPU Screen Recorder](https://git.dec05eba.com/gpu-screen-recorder/about/),
which captures the screen and encodes H.264 on your handheld's video engine (VA-API on AMD and Intel), so a game loses
a frame here and there at most. It only runs while you record; there's no always-on replay buffer. Clips go to
**Videos/GameCove/&lt;game&gt;**. The first time, Settings > Media installs it from Flathub, and screen capture needs a
one-time OK with your admin password, which only Desktop Mode can ask for: switch there once, open GameCove and press
**Allow screen capture**.
</details>

<details>
<summary><b>Your handheld isn't listed?</b></summary>

It still runs with Basic support. [Sign up to test](https://github.com/IHulkSmashI/GameCove/issues/new?template=tester_signup.yml)
with your device report and we'll add it.
</details>

## Community

- **Discord:** chat, testing and help, [discord.gg/tuUsn6sSZH](https://discord.gg/tuUsn6sSZH)
- **Reddit:** news and tips, [r/GameCoveLinux](https://www.reddit.com/r/GameCoveLinux/)
- **GitHub:** [bugs and ideas](https://github.com/IHulkSmashI/GameCove/issues/new/choose),
  [discussions](https://github.com/IHulkSmashI/GameCove/discussions), and
  [sign up to test on your handheld](https://github.com/IHulkSmashI/GameCove/issues/new?template=tester_signup.yml)

More in [docs/COMMUNITY.md](docs/COMMUNITY.md). GameCove is free; if you'd like to chip in:
[ko-fi.com/gamervault](https://ko-fi.com/gamervault).

## Credits

GameCove has its own front end and device layer, built on proven open-source work: gamescope, Proton and umu-launcher,
InputPlumber, PowerStation, steamos-manager and Handheld Daemon, legendary, gogdl and nile for the stores, MangoHud,
OptiScaler, lsfg-vk and Moonlight. Auto TDP, the upscaling setup and the MSI Claw findings are ported from
**ClawDeck** (same author). Gyro on the MSI Claw 8 EX was figured out by **Kisenir** (r/MSIClaw).

Our game database is rebuilt nightly from free, open sources (Wikidata, AreWeAntiCheatYet, ProtonDB, IGDB, the Steam
store) and published as a download on [GameCove-data](https://github.com/IHulkSmashI/GameCove-data); see [`gamedb/`](gamedb/). Game data from [IGDB](https://www.igdb.com): time to beat, game details, critic averages and upcoming release dates. [Metacritic](https://www.metacritic.com) scores as Valve publishes them on the Steam store, each linked to its Metacritic page. Critic scores from [OpenCritic](https://opencritic.com), fetched by the app only with your own key. Artwork from [SteamGridDB](https://www.steamgriddb.com) and its artists, fetched with your own free key. Compatibility tiers are our own summary of [ProtonDB](https://www.protondb.com) community reports, shared under the ODbL 1.0. The full list is in [CREDITS.md](CREDITS.md).

Contributing: [CONTRIBUTING.md](CONTRIBUTING.md).

## Licence

GPL-3.0-or-later. See [LICENSE](LICENSE). Copyright © 2026 Mena Hanna.

"GameCove" and the GameCove logo are trademarks of Mena Hanna. Forks are welcome under the GPL but need their own name
and logo; see [TRADEMARKS.md](TRADEMARKS.md). Contributors sign a short [CLA](docs/CLA.md) once (you keep your
copyright); details in [CONTRIBUTING.md](CONTRIBUTING.md).

A few parts carry their own licences: the Claw 8 EX gyro fix's HID-BPF program is GPL-2.0-only and its helper scripts
GPL-2.0-or-later; the VRR fix's panel list derives from MIT-licensed code; the app is built on Godot Engine (MIT); the
fonts are OFL-1.1. Every release carries these texts, and the app shows them under Settings > About > Credits and
licenses. Details in [CREDITS.md](CREDITS.md) and [LICENSES/](LICENSES/).

**The brand logos in `app/assets/brand/` are not GPL-licensed.** They're the makers' and stores' trademarks, shown only
to identify a device, chip, store or launcher, and removed on request ([docs/BRANDS.md](docs/BRANDS.md),
[app/assets/brand/LICENSE.md](app/assets/brand/LICENSE.md)). Device photos are the makers' property: most are fetched
from the maker's own site when the app needs them, one (the Acer Nitro Blaze 8) is bundled, and the README's device
grid shows them all. Any of them is removed on request. GameCove isn't affiliated with or endorsed by any of these
companies.
