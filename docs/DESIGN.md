# Design

GameCove is a console-style home screen, so the screen is about the games, not about us. The game's art fills the screen, everything else stays quiet, and focus is always obvious from arm's length on a 7 to 8 inch panel. The rules below hold everywhere, and every screen is built from the same few components.

Regenerate screenshots with `tools/screenshots/shoot.sh [OUT] [WxH] [only,these]` (see "Screenshots" at the end). It paints its own placeholder art, so no game art is used.

## Principles

- **Art first.** On Home the focused game's hero art is the stage: crisp and right-weighted across the top two thirds, dissolving (a mask, not a dark overlay) into the same picture blurred behind every screen, so there are no seams. Text sits on the quiet left side; shelves overlap the hero's bottom edge. A gradient scrim keeps text readable over any picture.
- **One shape, one ring.** Rounded corners from the theme's radius tokens (`radius_s` chips, `radius_m` controls and tiles, `radius_l` cards, `radius_xl` glass sheets). Focus is always the theme accent ring with its glow (tabs, chips, rows, buttons, cards, tiles); keys on the on-screen keyboard fill instead, tiles also lift.
- **Colour means something.** Each game brings its own colour: the vibrant colour of its cover tints the backdrop, the Play button and the glow under a focused tile ("Match game art colours", on by default); the focus ring itself stays the theme accent. Badge colours always mean the same thing.
- **Nothing moves when nothing happens.** Animations answer input and stop. Idle CPU is zero (measured: 0 ticks over 10 s on the home screen under xvfb).
- **One page layout.** Anything with art (game page now, deal and profile pages later) uses the page template: hero, logo or title, action row, cards.
- **The hint bar never lies.** The bottom bar shows button glyphs for the control that has focus.

## The Neon system

The look is called Neon: near-black glass, one electric accent (cyan `#00F0FF` in Cove) running into a second (violet `#7000FF`) for anything primary, mono micro-labels for facts and numbers, big caps display titles. The references are the owner's prototype renders; every screen, the first-run flow and the desktop installer share it.

### Themes and tokens

Themes are data in `app/theme/themes.gd`. `ThemeLib.use(id)` then `ThemeLib.build()` on the root control switches live; nodes re-read tokens on `NOTIFICATION_THEME_CHANGED`. Tests check that every theme has every token (`Themes.TOKENS`), that each pair in `Themes.TEXT_PAIRS` reaches 4.5:1 (translucent tokens composited over `bg`), and that the focus ring reaches 3:1 on `bg`.

| Theme | Accent → accent_2 | Ground | Feel |
| --- | --- | --- | --- |
| Cove (default) | `#00F0FF` → `#7000FF` | `#040508`, surfaces `#0B0F18` / `#111724` | The GameCove look |
| Midnight | `#4CC9FF` → `#8B5CFF` | pure black `#000000`, surfaces `#060609` / `#0D0E13` | Unlit pixels for OLED panels |
| Sunset | `#FF8A3D` → `#FF2E88` | plum-black `#0C0508`, surfaces `#160A10` / `#211019` | Warm neon |
| Light | `#007A8C` → `#6D28D9` | `#EEF1F6`, white surfaces | Dark ink on light glass for bright rooms |

| Token | Use |
| --- | --- |
| `bg` | Screen behind the backdrop; also the clear colour |
| `surface`, `surface_2`, `surface_3` | Cards, raised controls (rows, buttons), hover and tracks |
| `glass`, `glass_2` | Frosted sheets (quick menu, keyboard, toasts); glass pills (secondary buttons, chips, top-bar pills) |
| `line`, `line_2` | Hairlines; the brighter one for card edges on art and pill borders |
| `text`, `text_2`, `text_3` | Primary, secondary, faint or disabled text |
| `accent`, `accent_2`, `accent_end`, `on_accent` | Brand accent (focus, selected tab, start of the primary gradient), second accent, end of the primary gradient, text on it |
| `ring`, `glow`, `glow_size` | Focus ring, its soft halo and halo size |
| `focus_fill`, `on_focus` | Focused on-screen key and its letter |
| `good`, `warn`, `bad`, `info` | States |
| `face_a/b/x/y`, `on_face` | Controller glyph colours (A green, B red, X blue, Y yellow) |
| `scrim`, `scrim_strength` | Colour and strength the backdrop art is pulled toward |
| `chip` | Badge background; badges always sit on a chip |
| `radius_s/m/l/xl`, `dark` | 8 / 12 / 16 / 24 px corners; 1 for dark themes |

A handheld can set its own accent with `"accent": "#RRGGBB"` on its `devices.json` row; it's made readable for the theme first (`ArtColor.accent_for`). Art colours: `ArtColor.vibrant()` picks the heaviest saturated hue from the tiny blurred copy, `accent_for()` pushes it to 4.5:1 on `surface`. They tint the backdrop, the Play button and a focused tile's glow, never the focus ring.

### Type

Three OFL-1.1 families in `app/fonts/` (Latin subset): **Outfit** (SemiBold, Bold, ExtraBold) for display and headings, **Plus Jakarta Sans** (Regular to Bold) for interface text, **JetBrains Mono** (Medium, Bold) for telemetry, counts and micro-labels. `ThemeLib.font(weight, tabular, tracking)`; `ThemeLib.mono(bold, tracking)` for mono labels. Numbers that change use tabular figures.

| Size (px at 1280x800) | Theme variation | Face | Use |
| --- | --- | --- | --- |
| 52 | `DisplayLabel` | Outfit ExtraBold, -1 tracking | Spotlight and page titles, always caps |
| 36 | `TitleLabel` | Outfit ExtraBold | Screen titles (HOME, DOWNLOADS), empty states |
| 26 | `HeaderLabel` | Outfit Bold | Card and section headings, caps |
| 22 | `LeadLabel` | Outfit SemiBold | Shelf titles, option-card titles |
| 19 | (default) | Plus Jakarta Sans | Body |
| 17 | `QuietLabel`, `AccentLabel`, `ValueLabel` | Plus Jakarta Sans | Explanations, setting values |
| 15 | `CaptionLabel`, `MonoLabel` | Jakarta / JetBrains Mono | Hint bar, mono facts |
| 13 | `EyebrowLabel` | JetBrains Mono Bold, +3 tracking, accent | The line above a title (NOW DOWNLOADING, BOOT MODE) |
| 12 | `MicroLabel` | JetBrains Mono, +2 tracking | Micro-labels, store and playtime lines, counts (use `Kit.micro()`, which uppercases) |

Density: the window keeps `canvas_items` stretch, but past 1280x800 the layout grows at half the rate (`main.gd base_size_for`: 1920x1200 lays out at 1536x960, 1.25x), so big panels get more room rather than just bigger text. The installer uses the same rule. Icons are `DPITexture` SVGs and re-rasterise at the screen's scale.

### Spacing

`SPACE_1..7` = 4, 8, 12, 16, 24, 32, 48 px; screen edge `EDGE` 32, top bar 64, hint bar 52. Cards pad 20 x 18; rows 18 x 10; pills 22 x 11.

### Surfaces

- **Glass card** (`CardPanel`, `ThemeLib.card()`): `glass` at 90 %, `line_2` hairline, `radius_l`. Content cards, side panels, device cards.
- **Glass sheet** (`GlassPanel`, `ThemeLib.glass()`): `glass`, hairline, 28 px shadow, `radius_xl`. Quick menu, keyboard, dialogs.
- **Hero frame**: art in a `radius_xl` frame with a hairline (Home spotlight, game page, Downloads' now card), dissolving left into the backdrop through `hero_fade.gdshader` (its `frame_radius` clips the corners).
- **Pills**: secondary buttons are `glass_2` pills with a `line_2` hairline; chips (`Kit.chip`) are `chip`-filled pills with a toned hairline and icon; telemetry and step pills are mono.

### Focus ring

One language everywhere: a ring a pixel outside the control (`ThemeLib.focus_ring`, never shifts layout) in `ring`, with a `glow` halo of `glow_size`. Rows, list items and device cards use `row_focus()`: a 3 px ring hugging the card, the halo falling below it, the card's own fill kept so text keeps its contrast. Secondary buttons add a faint `ring` tint and scale 1.03 (`button_fx.gd`). Tiles lift to 1.06 with the ring in the theme accent; the art colour only tints the glow (mixed 60 % into the ring colour). A day in the calendar grid that is today carries a permanent 2 px accent outline.

### Buttons

- **Primary** (`Kit.primary(text, "A")`, `AccentButton`): a pill filled with the `accent` → `accent_end` gradient (`ThemeLib.gradient_pill`, or the art colour's pair via `Kit.accent_button`), caps label in `on_accent`, the controller glyph inside on a dark disc, an outer glow. `button_fx.gd` draws the caps label and keeps the button wide enough for it whenever the text changes.
- **Secondary** (`Kit.secondary` / `Kit.button`): glass pill, icon optional, glyph optional.
- **Icon** (`Kit.icon_button`): round glass button (search, settings, more).

### Segmented rows

`ChoiceRow` shows two to four short values (each at most 12 characters, 30 in all; `ChoiceRow.segmented()`) as a segmented control: a dark track with the current value as an accent-filled segment in mono caps. Longer or more values keep the chevrons and position dots; on / off is a switch. Left / right step the value either way; the focused row shows its explanation underneath.

### Badges

See "Badges" below for meanings. Visually: tile pills are small mono caps on a bright fill; chips on the spotlight and pages are `Kit.chip` (tone hairline, icon, Jakarta SemiBold). Tone colours come from `ThemeLib.tone()`: `TONES` on dark chips, `TONES_LIGHT` on light chips.

### Motion

All animation goes through `scripts/ui/motion.gd` (`Motion.to`, `Motion.method`, `Motion.fade`; FAST 150 ms, BASE 220 ms, SLOW 300 ms, cubic ease-out), which jumps to the end under **Reduce motion** or outside the tree. Tweens end; nothing runs per frame when idle.

| Moment | Motion |
| --- | --- |
| Boot splash (`boot_splash.gd`) | Logo mark and wordmark fade and scale in (450 ms), a light sweeps across, hold 450 ms, fade out 350 ms; never takes input, skipped under Reduce motion |
| Tile focus | Lift to 1.06 (back ease, 220 ms), brighten from 0.82, ring and glow fade in, glow pulses wide to settled (450 ms), cover pans in from the side focus came from (300 ms), SELECTED pill fades in |
| Shelf and grid | Glide to keep focus one tile in (220 ms) |
| Hero and backdrop | 300 / 250 ms crossfades; the Home hero drifts to 1.05 over 20 s, stopped by idle (30 s), a running game or Reduce motion |
| Tabs | Old screen fades (150 ms), new one slides 28 px in from its side (220 ms) |
| Pages and Downloads | Fade in over the screen (220 ms), the top bar stays |
| Progress bars | Glide to the new value (220 ms) |
| Quick menu | Dim fades, sheet slides 40 px in from its edge |
| Back from a game | Screens settle in from 0.97 (300 ms) |

## Components

All in `app/scripts/ui/`. Build new screens from these.

| Component | File | What it is |
| --- | --- | --- |
| Theme | `theme/gamecove_theme.gd`, `theme/themes.gd` | Tokens, type and spacing scales, `focus_ring()`, `row_focus()`, `gradient_pill()`, `gradient_box()`, theme variations (`AccentButton`, `IconButton`, `TabButton`, `SectionTab`, `ChipButton`, `RowButton`, `KeyButton`, `TileButton`, `GlassPanel`, `CardPanel`, `RaisedPanel`, `BadgePanel`, `PillPanel`, label variations above) |
| Kit | `ui_kit.gd` | Builders: labels, `micro()`, boxes, `button()`, `primary()`, `secondary()`, `icon_button()`, `chip()`, `glyph()`, `prompts()`, `icon_label()`, `accent_button()`, focus linking, `drop()` |
| Button fx | `button_fx.gd` | Caps label, glyph and glow drawn on primary pills; focus scale on secondary ones |
| Boot splash | `boot_splash.gd` | The logo glow-in at start (see Motion) |
| Icons | `icons.gd` | Original line icons on a 24 px grid, battery with level and charge (brand logos come from `brand_mark.gd`) |
| Illustrations | `illustrations.gd` | Empty-state pictures: library, no results, discover |
| Backdrop | `backdrop.gd` | Art-first background, crossfade, scrim, art accent |
| Art cache | `art_cache.gd` | Threaded loading; covers cropped to 2:3 at 360x540, heroes 1920 wide, logos, the 320 px blur; least recently used goes first |
| Fallback art | `fallback_art.gd` | Generated cover for games without art: gradient from the key, a motif, the title |
| Hero stage | `hero_stage.gd`, `shaders/hero_fade.gdshader` | Crisp key art masked into the backdrop or into a rounded frame (`frame_radius`): the Home spotlight and Downloads' now card; slow drift; welcome glow on first launch |
| Tile | `game_tile.gd` | Cover, one corner pill, lift, accent ring with a glow tinted by the art, SELECTED pill and title while focused; unfocused tiles sit slightly dimmed; loads art only near the screen |
| Glyph | `glyph.gd` | Controller button glyph, re-tinted on theme change |
| Shelf | `shelf.gd` | Titled row of tiles with gliding scroll and row memory |
| Game header | `game_header.gd` | Line above, logo or title, meta line with icons, badge chips |
| Page template | `page_template.gd` | Hero, header, action row, cards, focus wiring; `top_inset` leaves room for the top bar, `set_top_target()` sends d-pad up from the actions to it |
| Badge | `badges.gd`, `badge.gd` | Badge meanings and the chip that draws them |
| Choice row, slider row | `choice_row.gd`, `slider_row.gd` | Settings rows: value with chevrons and position dots, a switch for on/off, explanation under each |
| Top bar | `top_bar.gd` | Logo, segmented tab pill with LB / RB and "new" dots, search, telemetry pill (TDP, profile, temperature), downloads ring, status pill, settings |
| Status panel | `status_panel.gd` | Battery detail, volume and brightness hooks |
| Toasts | `toast.gd` | Top-right notes; never take focus, leave after 4 s, at most three |
| Launch splash | `launch_overlay.gd` | Art, logo, spinner, "Launching…", B to cancel |
| Keyboard | `osk.gd` | On-screen keyboard; physical keys work too |
| Sounds | `sounds.gd` | Synthesised move, select, back and toast sounds; Off, Low (default), Medium, High |

## Badges

One list per game from `Badges.for_game(g)`. An unfocused tile shows at most one corner pill, picked in this order: downloading, on sale, update, not installed, anti-cheat problem, new. The focused tile adds up to two more along its bottom (anti-cheat, time to beat, ProtonDB). The spotlight, the Library details bar and the game page show them as chips. Badge colours come from the theme (`ThemeLib.tone()`): bright tones on dark chips in dark themes, deep tones on light chips in Light; corner flags are always a bright fill with near-black text.

| Kind | Wording | Colour | Data |
| --- | --- | --- | --- |
| `download` | Downloading 45% | info | `g.download.progress` (optional) |
| `sale` | On sale -60% | lime | `g.deal.cut` (Discover) |
| `wish` | Wishlisted | pink | `g.wishlisted` (Discover) |
| `new` | New | sky | `g.added` within 14 days (library) |
| `update` | Update ready | info | `g.update_available` (library) |
| `device` | Runs great here / Playable here | good / warn | `g.info.device_rating` (future) |
| `protondb` | ProtonDB Gold | tier colour | `info.protondb` |
| `anticheat` | Anti-cheat OK / blocked / Linux denied | good / warn / bad | `info.anticheat` |
| `ttb` | 12 h to beat | short good, long info | `info.time_to_beat` |
| `not_installed` | Not installed | neutral | `installed` |

## Screens

- **Home**: spotlight over the art (Play and Game page act on the focused game), then shelves: Recently played, Installed, Short games (under 10 h), Anti-cheat friendly, one per store when there's more than one, All games.
- **Library**: cover grid under a fixed header (search, store chips, sort), a details bar for the focused game above the hint bar, a fade and "More below" cue while there's more, sort (X: Recent, A to Z, Most played, Shortest first), search (Y, on-screen keyboard), LT / RT jump to the previous / next first letter.
- **Discover**: placeholder card. Hook: `discover_screen.gd` (edit `build_content()`, or set `DiscoverScreen.content_factory`). It gets `{"library", "open_game", "toast"}` and emits `game_focused` / `open_requested`.
- **Settings**: a compact category list on the left in two groups, HANDHELD (Power, Display, Sound, Controller, Performance, System, Profiles; generated from the Controls) and GAMECOVE (Appearance, Stores, Discover, Device with Fixes, About GameCove), the category's tinted cards on the right. Moving through the list shows each page; A or right goes in, B comes back to the list. Store sign-in, credits and keys open as a sheet over the screen (it dims the top and hint bars too). Details below.
- **Discover**: four sections under one header (LT / RT switch them): For you, Deals, Coming soon, Wishlist; store pages on the page template. Details in "Discover" below.
- **Settings**: theme with swatches, Match game art colours, Reduce motion, Quick menu side, Interface sounds, About this device.
- **Game page**: page template under the top bar (LB / RB switch tabs and close the page, B goes back, up from the actions reaches the tabs) with Play / Install, Manage, Settings, Back; About this game, achievements and per-game settings in three columns.
- **Downloads**: under the top bar too. A hero card for what's running (the game's art in the frame, NOW DOWNLOADING eyebrow, caps title, mono percent and numbers, a 12 px accent-to-violet bar, Pause / Cancel / Game page on the right), then two columns: UP NEXT (n) and FINISHED (n). Left / right cross the columns, up returns to the hero, then the tabs. The empty state keeps its illustration and "See games to install".
- **Quick menu**: floating glass sheet on the right (or left), inset below the top bar so the clock and battery stay visible; slim header with the game's mini cover (and "own settings" when the game has a profile); six icon tabs (This game, Power, Display, Audio, Controller, Device), the open one filled and named; rows stay compact and only the focused row shows its explanation; Power opens with three mono stat tiles (battery, drawing, TDP); every tab ends with "All … settings" (Y anywhere). Details in docs/CONTROLS.md "UI".
- **Top bar**: underline tabs with small, muted LB / RB glyphs, the status pill (Wi-Fi when known, battery, clock) and the Settings button at the far right.
- **First launch**: welcome glow and illustration, "Look again", three cards saying what happens next.

## Performance

- Idle is free: no `_process` anywhere except the launch spinner while it shows; tweens end; the live timer ticks every 5 s only while our window has focus.
- The blur is a 320 px texture made once per game on a worker thread and drawn stretched. No screen-texture shader.
- Covers load on worker threads only when a tile comes near the screen (`VisibleOnScreenNotifier2D`), and are shrunk to 360x540 with mipmaps. Cache caps: 160 covers, 48 blurs, 24 logos, 4 heroes.
- Rounded cover corners and the parallax pan are one tiny shader (`app/shaders/rounded_art.gdshader`); the hero mask is another (`hero_fade.gdshader`). Neither reads the screen texture.
- Interface sounds need a real audio driver. `project.godot` keeps `audio/driver/driver="Dummy"` for now, so sounds stay silent until someone measures the driver's idle cost on the Claw and switches it.

## Settings and first-run setup

Files: `scripts/ui/settings_screen.gd` (layout, overlays), `scripts/ui/settings/` (one page per category, `action_row.gd`, `kit.gd` cards and notes, `sign_in.gd`, `qr.gd`, `credits.gd`, `services.gd`), `scripts/ui/setup/setup_flow.gd`, words in `scripts/ui/texts_settings.gd`.

- **Rows.** Choice rows and switches (`choice_row.gd`, which now takes `set_explainer(fn)` for words that aren't in texts.gd) and action rows (`settings/action_row.gd`: title, value, chevron; pressing opens something). Every row keeps its one-line explanation under it while focused.
- **Notes** (`SKit.note(text, tone)`): a faint tinted box with an icon. `warn` for risks (the Steam control warning), `info` for facts, `good` for all-clear. Never focusable.
- **Services.** `settings.set_services({...})` with `setup`, `library`, `discover`, `perf`, `achievements`, `device` (and anything the Device panels want). Without it the screen falls back to the autoloads once it's in the tree (never under the test runner).
- **Store sign-in.** A QR code of the store's sign-in page (dark on white, whatever the theme, so phones read it), three short steps, and Type code, which opens the on-screen keyboard in code mode (`osk.use_for_codes()`: longer text, Shift, case kept). The QR encoder is kenyoni-software's MIT one, vendored in `app/addons/kenyoni/qr_code/`.
- **Device panels** come from `scripts/ui/device/` when they exist: each script has `static func build(services: Dictionary) -> Control` and may add `focusables()`, `opened()` and `closed()` on the Control. Missing panels show a placeholder card. The page builds the first time it's shown.
- **Hint bar.** `settings.hints(focus)` returns the prompts for whatever has focus here (B goes back to the list from a page, sheets show A / B); main.gd uses it when a screen has `hints`.
- **First-run setup** (`SetupFlow`): a full-screen sheet with a step rail on the left (Welcome, Look, Stores, Keys, Device fixes, Done; check = done, x = skipped) and Back / Skip / Next. It opens on the first launch, `Skip setup` ends it, and Settings > About GameCove lists every step to open again. Device fixes are only listed there: installing needs an admin password Gaming Mode can't ask for, and the step says so.
- **Quick menu additions.** Power shows Auto TDP's state and, while it can't hold the frame rate, what to do (raise the TDP or lower settings), then a Performance block with the overlay level. This game shows how long you've played this session and Exit game (press twice). Device explains Partial support and names unconfirmed values.
## Games: page actions, downloads, install state

All in `app/scripts/ui/games/` (words in `texts_games.gd`).

| Piece | File | What it is |
| --- | --- | --- |
| Install state | `install_state.gd` | Follows Library's store signals: state per game, live progress (at most 1 update/s per job), queue, "Finished" list; `decorate(games)` adds the fields badges read |
| Tile progress | `tile_progress.gd` | Corner pill ("45%", "Queued", "Paused", "Update") and a slim bar on the cover, applied from outside `game_tile.gd` |
| Game actions | `game_actions.gd` | Install (drive picker with free space), update, uninstall (confirmed), check files, move, launch options (keyboard), compatibility tool, Steam pages, pause / resume / cancel / reorder. Shows the store's `why` when something can't run; Manage rows whose reason is only "it's in the other state" are hidden, others greyed with the reason |
| Sheet | `sheet.gd` | Modal glass list: title, line, rows with icon, detail, value, current check; A picks, B closes |
| Text keyboard | `text_keyboard.gd` | The search keyboard plus a symbol row and Shift, keeps case, 240 characters |
| Achievements | `achievements_card.gd` | Count and bar, focused achievement line, icon grid (unlocked newest first, locked by rarity, hidden last and secret; locked dimmed; under 10% of players gets a gold ring) |
| Downloads | `downloads_view.gd`, `downloads_button.gd` | The Downloads screen (hero now card, Up next and Finished columns) and the top bar's button with a progress ring and count; also a chip in the Library toolbar while anything downloads. `progress_line.gd` has a `gradient` option for the hero bar |
| Steam needs you | `steam_overlay.gd` | Shown on `external_window_needed`; "Back to GameCove" calls `return_from_steam()` |
| Session wiring | `session_wiring.gd` | Around a running game: PerfMonitor start/stop/focus, Achievements.invalidate, Updates.set_game_running, Controller start/end_game, Discover pause/resume |
| Exit game | `game_closer.gd` | Steam: `pkill -f AppId=<id>` on Steam's launch wrapper (no steam://close exists), our scopes: `systemctl --user stop app-steam-app<id>-*.scope`, pids: TERM then KILL after 5 s. Never blocks |

Game page action row: the one thing to do now (Play, Install, Update, Pause / Resume while downloading, Downloads when it can't be paused here), Manage, Settings, Back; a live progress line under it. Library has Installed / Not installed chips; home's spotlight button follows install state.
## Device pages

`app/scripts/ui/device/` holds the pages the Settings screen embeds: `about_panel.gd` (About this device), `controller_panel.gd`, `storage_panel.gd`, `updates_panel.gd`. Each is `static func build(services) -> Control` on `device_panel.gd`, which gives the host `default_focus()`, `focusables()`, `set_top_target(c)`, `hints()` / `hints_changed`, `opened()` / `closed()` and `toast_requested`. Layout: a summary column on the left (the device picture or photo, name, support chips, three quick facts), a scrolling area of tinted cards on the right. About this device packs its cards into two columns where the area is at least 760 px wide (each card goes to the shorter column by an estimated height, so the columns end together and there are no gaps; left / right cross between them) and one column below that; its key / value lines use the compact size (`DKit.kv(pairs, width, true)`). Read-only cards take focus themselves (`device_kit.gd` FocusCard, one accent ring) so the d-pad scrolls through information; settings inside cards are choice rows. `device_picture.gd` recolours the device SVG's `btn-*` parts as text: pressed buttons fill with the accent, the back button being edited is outlined. Strings live in `texts_device.gd`. Screenshots: `SHOOT_SCRIPT=shoot_device.gd tools/screenshots/shoot.sh`.
## Discover

Code: `scripts/ui/discover_screen.gd` (the hook; `DiscoverScreen.content_factory` still replaces everything) and `scripts/ui/discover/` (`root.gd` header, sections, input and hints; one file per section; `store_page.gd`; `model.gd` pure logic; `widgets.gd` shared builders). Strings: `texts_discover.gd`.

- **For you**: a spotlight over the focused game's art, like Home (starts on a wishlisted game on sale, else a game out today, else the biggest real-price deal, else a release in the next two weeks), then shelves: Top deals, From your wishlist on sale, Coming soon, Free right now. Tiles are library tiles with a price plate and at most one extra pill (Lowest ever, Ends in…, Out today) stacked bottom-left, away from the title most covers carry at the top. Under the shelves: the optional gg.deals card (dismissable), the offline / loading card when there's nothing to show, and the credits.
- **Deals**: Store and Sort choice rows, then one row per deal. A price only shows when it's the store's real price in the user's currency; otherwise the discount and "See price" with the store. X cycles the sort, Y wishlists.
- **Coming soon**: List (Out now, This week, This month, Later, Date not announced) or Month (Monday-first grid whose rows share the height; days with releases focus and, where the cell is at least 96 x 92 px, show small covers (one cover beside its title, or as many as fit with "+n"), else their first titles; a dot with the count; today carries a TODAY tag and an accent outline; the focused day's games in a side panel; month-only dates under "Sometime this month"). X switches, the choice is remembered. Each entry has a Notify me toggle (Y anywhere). A game out today is outlined in the accent.
- **Wishlist**: Import from Steam (a sheet with the on-screen keyboard and the public-profile explanation), the alerts inbox with Mark all seen, then the list beside a details card (price alert target as a choice row, alert switches, Game page, Remove with a second press to confirm).
- **Store page**: page template with our own chip row under the title (sale, lowest ever, ends, wishlisted, countdown, in your library). Actions: Open in library (when owned), Buy with the best local price (or See price on the store), Notify me (upcoming), Wishlist, Back. Cards: every store's price (each row opens that store through `Discover.open_link`), the price alert, the release date, credits.
- **Credits**: `Discover.attributions()` plus any row's `attribution` are focusable link chips wherever their prices show (For you, Deals, store pages).
- **Alerts**: `price_alert` / `release_alert` become toasts (they never take focus); waiting alerts put a dot on the Wishlist chip and on the Discover tab.
- **Hints and input**: Discover redraws main's hint bar after main draws its generic one (`DiscoverScreen.request_hints`); X, Y, LT / RT and B (back within Discover first) are handled before main sees them. A store page hides the top bar and swallows LB / RB (the game page and Downloads keep the top bar).
- **Component additions** (backward compatible): `ChoiceRow.explain_fn` (custom line under a row; an empty line takes no space) and `Osk.placeholder`.
## Installer

`scripts/ui/installer/` (words in `texts_installer.gd`), shown for `gamecove.x86_64 -- --installer` on the desktop, laid out like the owner's installer renders in the Neon system and at the app's density. Top bar: the GAMECOVE lockup (icon tile with the gradient edge, "LINUX HANDHELD INSTALLER" in mono micro), one mono step pill per step (done = good dot, current = accent tint and dot) and a mono status pill when there's room. Page: a mono eyebrow over a big caps Outfit title and a lead line; the content; a hairline; a mono note (or a tinted note) on the left and Skip / Back / the gradient Continue pill with its A glyph on the right. Footer: the mono "STEP n / N" pill, "INSTALLER – STEP" and the working buttons.

Big choices are `option_card.gd`: icon tile on the left and badge chip on the right (or badge left and a mono time estimate right), caps title, description, and a mono footer that turns accent with a dot when chosen ("● SELECTED BY DEFAULT"). They're used for Easy / Custom, the three startup modes, the three stores (badge Signed in / Browser sign-in, A opens the sign-in) and the four themes (each with a swatch of its gradient). The device step is two cards side by side: recommended fixes (with a "Matched for <device>" chip) and power defaults (profile, Auto TDP, charge limit). The progress page is a card with a ring (accent into violet, percent inside), STATUS eyebrow and the current task in caps, the gradient bar and a two-column grid of mono task rows (Queued / Running / Done / After restart / Failed). Done is a centred card: check ring, SETUP COMPLETE, the title, what happens next, notes, Restart later. Screenshots: `SHOOT_SCRIPT=shoot_installer.gd tools/screenshots/shoot.sh`.

## Screenshots

`tools/screenshots/shoot.sh [OUT] [WxH] [only,these]` renders inside the real main scene with fake services and painted art; 1280x800 files are `name.png`, other sizes `name_<width>.png`. Three shot lists:

- `shoot.gd` (default): home, home_focus, home_focus2, home_empty, library, library_search, game_page, game_page_settings, game_no_art, launch, status, boot, toast, discover, quick_game, quick_power, quick_perf, quick_screen, quick_device, quick_device_partial, quick_session, settings and its pages (settings_appearance, _stores, _discover, _performance, _device, _about, _credits, _signin, _light), setup_welcome, _theme, _stores, _signin, _keys, _fixes, _done, _light, theme_cove / _midnight / _sunset / _light (plus _page and _quick each), the discover_* set (home, home_focus, deals, deals_store, calendar, calendar_month, calendar_empty, wishlist, wishlist_empty, import, page, page_prices, page_upcoming, offline, toast, light, midnight_page) and the games_* set (library, home, page, page_achievements, page_downloading, page_light, manage, install, launch_options, compat, downloads, downloads_empty, downloads_midnight, steam, toasts).
- `SHOOT_SCRIPT=shoot_device.gd`: device_about, device_about_scrolled, device_about_light, device_about_generic, device_about_photo (needs a cached photo), device_controller, device_controller_test, device_controller_midnight, device_controller_missing, device_storage, device_storage_loading, device_updates.
- `SHOOT_SCRIPT=shoot_installer.gd`: installer_welcome, _welcome_steamos, _welcome_other, _welcome_light, _startup, _steam, _stores, _signin, _device, _look, _extras, _summary, _progress, _failed, _done, _maintenance, _uninstall, _finish.

The release set at both sizes lives in `ui-shots/release/` next to the worktrees (not in the repo).

## Controls UI

Settings rows from the Controls registry (`scripts/ui/controls/`, docs/CONTROLS.md "UI"). Chips inside a 52 px row are small mono pills (11 px, 8 x 2 padding): SYSTEM with a lock (root helper, no password), ON BATTERY / PLUGGED IN (where a value comes from; none for everyday values or when the whole game has its own settings), APPLYING (until the worker answers). A failure is a bad-tone line under the row naming the value it kept. Unavailable rows are dimmed with their reason always showing and sit behind "More settings"; whole topics that can't work here gather in one "Not on this handheld" card at the end. The colour picker is ten swatches plus a rainbow hue track; the fan curve is a line over the dashed quiet floor, COOL to HOT, the selected point lit with its percentage. "Keep this?" is a centred glass sheet with a warn icon, the setting as the eyebrow, a mono countdown and a gradient bar, Go back (B) and Keep (A). Screenshots: `SHOOT_SCRIPT=shoot_controls.gd tools/screenshots/shoot.sh` (controls_* set, fake Controls from real provider snapshots of a Claw 8 EX and a Legion Go S). `SHOOT_THEME=midnight|sunset|light` renders the whole set in one theme. Settings > Device uses section tabs (About, Fixes, Controller, Storage, Updates; the open one accent-filled) so each device panel gets the full height. `ThemeLib.tone("accent")` is the theme's own accent.
