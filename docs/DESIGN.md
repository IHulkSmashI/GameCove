# Design

GameCove is a console-style home screen, so the screen is about the games, not about us. The game's art fills the screen, everything else stays quiet, and focus is always obvious from arm's length on a 7 to 8 inch panel. The rules below hold everywhere, and every screen is built from the same few components.

Regenerate screenshots with `tools/screenshots/shoot.sh [OUT] [WxH] [only,these]`. It paints its own placeholder art, so no game art is used.

## Principles

- **Art first.** On Home the focused game's hero art is the stage: crisp and right-weighted across the top two thirds, dissolving (a mask, not a dark overlay) into the same picture blurred behind every screen, so there are no seams. Text sits on the quiet left side; shelves overlap the hero's bottom edge. A gradient scrim keeps text readable over any picture.
- **One shape, one ring.** Rounded corners from the theme's radius tokens (`radius_s` chips, `radius_m` controls and tiles, `radius_l` cards, `radius_xl` glass sheets). Focus is either a solid light fill (plain buttons, keys) or one accent ring (tabs, chips, rows, sliders). Tiles lift instead.
- **Colour means something.** Each game brings its own colour: the vibrant colour of its cover tints the backdrop, the tile's glow and the Play button ("Match game art colours", on by default). Badge colours always mean the same thing.
- **Nothing moves when nothing happens.** Animations answer input and stop. Idle CPU is zero (measured: 0 ticks over 10 s on the home screen under xvfb).
- **One page layout.** Anything with art (game page now, deal and profile pages later) uses the page template: hero, logo or title, action row, cards.
- **The hint bar never lies.** The bottom bar shows button glyphs for the control that has focus.

## Themes and tokens

Themes are data in `app/theme/themes.gd`. `ThemeLib.use(id)` then `ThemeLib.build()` on the root control switches live; nodes re-read tokens on `NOTIFICATION_THEME_CHANGED`. Tests check that every theme has every token and that text tokens reach 4.5:1 on panels.

| Theme | Feel |
| --- | --- |
| Cove (default) | Teal `#4FD1C5` on deep navy `#0A1120` |
| Midnight | True black, ice blue `#8AB0FF`, for OLED panels |
| Sunset | Plum `#170C12` and apricot `#FF9E66` |
| Light | Dark text on light panels, deep teal `#0A776F` |

| Token | Use |
| --- | --- |
| `bg` | Screen behind the backdrop; also the clear colour |
| `surface`, `surface_2`, `surface_3` | Panels, raised controls, hover and tracks |
| `glass` | Frosted sheets (quick menu, keyboard, toasts, status panel), translucent |
| `line` | Hairline borders, translucent |
| `text`, `text_2`, `text_3` | Primary, secondary, faint or disabled text |
| `accent`, `accent_2`, `on_accent` | Brand accent, second accent, text on accent |
| `focus_fill`, `on_focus` | Solid fill of a focused button and its text |
| `good`, `warn`, `bad`, `info` | States |
| `scrim`, `scrim_strength` | Colour and strength the backdrop is darkened by |
| `chip` | Badge background; badges always sit on a dark chip |
| `radius_s/m/l/xl`, `dark` | Corner radii; 1 for dark themes |

A handheld can set its own accent with an optional `"accent": "#RRGGBB"` on its `devices.json` row. It's made readable for the theme before use (`ArtColor.accent_for`).

Art colours: `ArtColor.vibrant()` picks the heaviest saturated hue bucket from the tiny blurred copy, and `accent_for()` pushes it until it reads at 4.5:1 on `surface` and against dark text. `on_color()` picks dark or white text for any accent fill.

## Type

Inter 4.0 (OFL-1.1, `app/fonts/`, Latin subset): Regular, Medium, SemiBold for text, Inter Display Bold for titles, tracked 1 px tighter at title sizes. Numbers that change (clock, battery, slider values, counts) use tabular figures (`ThemeLib.font(weight, true)`).

| Size (px at 1280x800) | Theme variation | Use |
| --- | --- | --- |
| 54 | `DisplayLabel` | Spotlight and page titles |
| 36 | `TitleLabel` | Screen titles, empty states |
| 26 | `HeaderLabel` | Card headings |
| 22 | `LeadLabel` | Shelf titles, emphasised lines |
| 19 | (default) | Body |
| 17 | `QuietLabel`, `AccentLabel`, `ValueLabel` | Explanations, the line above a title, setting values |
| 15 | `CaptionLabel` | Hint bar, counts |
| 13 | badge text | Tile badges |

The viewport stretches (`canvas_items`), so 1920x1200 renders the same layout at 1.5x with sharp text; icons are `DPITexture` SVGs and re-rasterise at the screen's scale.

## Motion

All animation goes through `scripts/ui/motion.gd` (`Motion.to`, `Motion.method`, `Motion.fade`), which skips straight to the end under **Reduce motion** (Settings) or outside the tree.

| Moment | Motion |
| --- | --- |
| Tile focus | Card lifts to 1.06 (back ease, 220 ms) and brightens from 0.86, ring and glow fade in, glow pulses from wide to settled (450 ms), cover pans in from the side focus came from (300 ms), badges and title fade in |
| Shelf and grid | Glide to keep focus one tile in (220 ms) |
| Hero and backdrop | 300 ms / 250 ms crossfades; the crisp hero drifts to 1.05 over 20 s per game, stopped by idle (30 s), a running game or Reduce motion |
| Tabs | Old screen fades (150 ms), new one slides 28 px in from its side (220 ms) |
| Quick menu | Dim fades, sheet slides 40 px in from its edge |
| Back from a game | Screens settle in from 0.97 (300 ms) |

## Components

All in `app/scripts/ui/`. Build new screens from these.

| Component | File | What it is |
| --- | --- | --- |
| Theme | `theme/gamecove_theme.gd`, `theme/themes.gd` | Tokens, type scale, theme variations (`AccentButton`, `TabButton`, `SectionTab`, `ChipButton`, `RowButton`, `KeyButton`, `TileButton`, `GlassPanel`, `CardPanel`, `RaisedPanel`, `BadgePanel`) |
| Kit | `ui_kit.gd` | Builders: labels, boxes, buttons, `glyph()`, `prompts()`, `icon_label()`, `accent_button()`, focus linking, `drop()` |
| Icons | `icons.gd` | Original line icons on a 24 px grid (stores shown by name, no brand logos), battery with level and charge |
| Illustrations | `illustrations.gd` | Empty-state pictures: library, no results, discover |
| Backdrop | `backdrop.gd` | Art-first background, crossfade, scrim, art accent |
| Art cache | `art_cache.gd` | Threaded loading; covers cropped to 2:3 at 360x540, heroes 1920 wide, logos, the 320 px blur; least recently used goes first |
| Fallback art | `fallback_art.gd` | Generated cover for games without art: gradient from the key, a motif, the title |
| Hero stage | `hero_stage.gd`, `shaders/hero_fade.gdshader` | Crisp key art behind the Home spotlight, masked into the backdrop; slow drift; welcome glow on first launch |
| Tile | `game_tile.gd` | Cover, one corner pill, lift, glow in its own colour, title under it while focused; unfocused tiles sit slightly dimmed; loads art only near the screen |
| Glyph | `glyph.gd` | Controller button glyph, re-tinted on theme change |
| Shelf | `shelf.gd` | Titled row of tiles with gliding scroll and row memory |
| Game header | `game_header.gd` | Line above, logo or title, meta line with icons, badge chips |
| Page template | `page_template.gd` | Hero, header, action row, cards, focus wiring |
| Badge | `badges.gd`, `badge.gd` | Badge meanings and the chip that draws them |
| Choice row, slider row | `choice_row.gd`, `slider_row.gd` | Settings rows: value with chevrons and position dots, a switch for on/off, explanation under each |
| Top bar | `top_bar.gd` | Logo, tabs with LB/RB and "new" dots, status pill |
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
- **Settings**: theme with swatches, Match game art colours, Reduce motion, Quick menu side, Interface sounds, About this device.
- **Game page**: page template with Play / Install, Settings, Back; About this game; per-game settings.
- **Quick menu**: floating glass sheet on the right (or left), inset below the top bar so the clock and battery stay visible; slim header with the game's mini cover; section icons with the label under the active one only; rows stay compact and only the focused row shows its explanation; the TDP slider has ticks.
- **Top bar**: underline tabs with small, muted LB / RB glyphs, the status pill (Wi-Fi when known, battery, clock) and the Settings button at the far right.
- **First launch**: welcome glow and illustration, "Look again", three cards saying what happens next.

## Performance

- Idle is free: no `_process` anywhere except the launch spinner while it shows; tweens end; the live timer ticks every 5 s only while our window has focus.
- The blur is a 320 px texture made once per game on a worker thread and drawn stretched. No screen-texture shader.
- Covers load on worker threads only when a tile comes near the screen (`VisibleOnScreenNotifier2D`), and are shrunk to 360x540 with mipmaps. Cache caps: 160 covers, 48 blurs, 24 logos, 4 heroes.
- Rounded cover corners and the parallax pan are one tiny shader (`app/shaders/rounded_art.gdshader`); the hero mask is another (`hero_fade.gdshader`). Neither reads the screen texture.
- Interface sounds need a real audio driver. `project.godot` keeps `audio/driver/driver="Dummy"` for now, so sounds stay silent until someone measures the driver's idle cost on the Claw and switches it.

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
| Downloads | `downloads_view.gd`, `downloads_button.gd` | Full-screen list (Now card, Up next rows, Finished) and the top bar's button with a progress ring and count; also a chip in the Library toolbar while anything downloads |
| Steam needs you | `steam_overlay.gd` | Shown on `external_window_needed`; "Back to GameCove" calls `return_from_steam()` |
| Session wiring | `session_wiring.gd` | Around a running game: PerfMonitor start/stop/focus, Achievements.invalidate, Updates.set_game_running, Controller start/end_game, Discover pause/resume |
| Exit game | `game_closer.gd` | Steam: `pkill -f AppId=<id>` on Steam's launch wrapper (no steam://close exists), our scopes: `systemctl --user stop app-steam-app<id>-*.scope`, pids: TERM then KILL after 5 s. Never blocks |

Game page action row: the one thing to do now (Play, Install, Update, Pause / Resume while downloading, Downloads when it can't be paused here), Manage, Settings, Back; a live progress line under it. Library has Installed / Not installed chips; home's spotlight button follows install state.
