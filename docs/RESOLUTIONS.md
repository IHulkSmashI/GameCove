# Screen sizes

GameCove lays itself out for the screen it is on. `scripts/ui/ui_scale.gd` turns the window size in pixels, the kind of
screen and its diagonal into a layout size (the size the UI is designed in, at least 1280x800) and a scale factor.
`scripts/system/display_output.gd` reads the connectors in `/sys/class/drm` (status, EDID size bytes) to tell a
handheld's own panel from a monitor or a TV; an external output wins, and a box with no panel counts as a TV.

| Screen | Rule |
| --- | --- |
| Handheld panel | Constant visual angle (the Claw 8 at a 36 cm reading distance) from the panel's diagonal: a 7 inch 1080p panel lays out at 1422x800, a 5.5 inch one the same. |
| TV | 10-foot: layout 800 tall at any resolution (1080p, 1440p and 4K are all 1422x800), so 4K text is as readable from the couch as 1080p. |
| Desk monitor (18.5 to 35 inch) | Read from 1.2 m. |
| Unknown size | The older half-rate rule (layout grows at half the rate of the pixels past 1280x800). |

Bounds: layout is never smaller than 1280x800, an automatic layout is at most 1600 wide, and the shape stays between
5:4 and 2:1. An ultrawide or an unrotated portrait screen gets a centred area with bars at the sides (Window aspect
KEEP). Text never drops below `MIN_TEXT_ARCMIN` (9 arc minutes). Settings > Appearance > **Interface size** (Small,
Default, Large, Largest, stored as `interface_size` in `ui.cfg`) offers only the sizes that differ on this screen.

## The matrix

`app/tests/layout/matrix.gd` lists every distinct panel (resolution and size) in `app/data/devices.json` plus external
screens. Panels come from the maker spec sheets already cited in devices.json; the TV and monitor rows are standard
size classes, not products. Print it with `godot --headless --path app -s ../tools/layout/dump_matrix.gd`.

| Row | Pixels | Diagonal | Layout | Scale | CI | Notes / models |
| --- | --- | --- | --- | --- | --- | --- |
| `panel-1280x800-7in` | 1280x800 | 7" | 1280x800 | 1.00x | yes | steam-deck-lcd |
| `panel-1280x800-7.4in` | 1280x800 | 7.4" | 1280x800 | 1.00x |  | steam-deck-oled |
| `panel-1920x1080-5.5in` | 1920x1080 | 5.5" | 1422x800 | 1.35x |  | ayaneo-air-1s |
| `panel-1920x1080-6in` | 1920x1080 | 6" | 1422x800 | 1.35x |  | ayaneo-air-plus, ayaneo-slide, gpd-win-4 |
| `panel-1920x1080-7in` | 1920x1080 | 7" | 1422x800 | 1.35x | yes | 15 models |
| `panel-1920x1080-7.4in` | 1920x1080 | 7.4" | 1477x831 | 1.30x |  | asus-rog-xbox-ally-x20 |
| `panel-1920x1200-7in` | 1920x1200 | 7" | 1371x857 | 1.40x |  | ayaneo-2s, ayaneo-2, orangepi-neo |
| `panel-1920x1200-8in` | 1920x1200 | 8" | 1536x960 | 1.25x | yes | 10 models |
| `panel-1920x1200-8.8in` | 1920x1200 | 8.8" | 1536x960 | 1.25x |  | lenovo-legion-go-2, lenovo-legion-go-2-z2 |
| `panel-2560x1600-8.4in` | 2560x1600 | 8.4" | 1552x970 | 1.65x |  | onexplayer-2, onexplayer-2-pro, ayaneo-kun |
| `panel-2560x1600-8.8in` | 2560x1600 | 8.8" | 1552x970 | 1.65x |  | 6 models |
| `panel-2560x1600-10.1in` | 2560x1600 | 10.1" | 1552x970 | 1.65x |  | gpd-win-max-2 |
| `panel-2560x1600-10.95in` | 2560x1600 | 10.95" | 1552x970 | 1.65x |  | 4 models |
| `panel-2880x1800-14in` | 2880x1800 | 14" | 1557x973 | 1.85x |  | onexplayer-super-x |
| `tv-720p-32in` | 1280x720 | 32" | 1422x800 | 0.90x |  | HD-ready TV, Deck dock's lowest mode |
| `tv-768p-32in` | 1366x768 | 32" | 1423x800 | 0.96x |  | older 1366x768 TV |
| `tv-1080p-55in` | 1920x1080 | 55" | 1422x800 | 1.35x | yes | 1080p TV; a 4K TV with the session at 1080p |
| `tv-1440p-55in` | 2560x1440 | 55" | 1422x800 | 1.80x |  | 4K TV with the session at 1440p (Steam Machine default for heavy games) |
| `tv-4k-55in` | 3840x2160 | 55" | 1422x800 | 2.70x | yes | 4K TV: Steam Machine, docked handheld |
| `tv-4k-unknown` | 3840x2160 | ? | 1422x800 | 2.70x |  | 4K through an AV receiver or projector (no size in the EDID) |
| `monitor-1080p-24in` | 1920x1080 | 24" | 1422x800 | 1.35x |  | desk monitor |
| `monitor-1200p-24in` | 1920x1200 | 24" | 1371x857 | 1.40x |  | 16:10 desk monitor |
| `monitor-1440p-27in` | 2560x1440 | 27" | 1600x900 | 1.60x | yes | desk monitor |
| `monitor-4k-32in` | 3840x2160 | 32" | 1600x900 | 2.40x |  | 4K desk monitor |
| `monitor-4k-16x10-30in` | 3840x2400 | 30" | 1600x1000 | 2.40x |  | 16:10 4K monitor |
| `ultrawide-1080p-29in` | 2560x1080 | 29" | 1600x800 | 1.35x |  | 21:9 monitor |
| `ultrawide-1440p-34in` | 3440x1440 | 34" | 1600x800 | 1.80x |  | 21:9 monitor |
| `ultrawide-1440p-tv` | 3440x1440 | ? | 1600x800 | 1.80x | yes | 21:9 screen on a box that can't read its size |
| `superwide-1440p-49in` | 5120x1440 | 49" | 1600x800 | 1.80x |  | 32:9 monitor |
| `portable-1080p-15in` | 1920x1080 | 15.6" | 1600x900 | 1.20x |  | USB-C portable monitor, read up close |
| `nested-1200p-on-8.8in` | 1920x1200 | 8.8" | 1536x960 | 1.25x |  | gamescope at 1920x1200 on a 2560x1600 8.8 inch panel |
| `nested-800p-on-8in` | 1280x800 | 8" | 1280x800 | 1.00x |  | gamescope at 1280x800 on a 1920x1200 8 inch panel |
| `window-4x3` | 1024x768 | ? | 1280x960 | 0.80x |  | no supported device has a 4:3 panel; a small window or VM |
| `portrait-unrotated` | 800x1280 | ? | 1280x1024 | 0.62x |  | a portrait-native panel (Deck LCD, many 7 and 8 inch ones) before gamescope rotates it |

34 rows land on 13 distinct layouts. Rows that lay out the same are run once.

## The layout harness

`tools/layout/run.py` puts every screen on every row and runs `app/tests/layout/layout_checks.gd` on it, headless
(geometry only, nothing is drawn): text outside the screen, cut or ellipsised text, overlaps, occlusion by later opaque
panels, focus rings outside their scroll area, too-small text, stretched or blurry pictures, tiles and over-wide lines.
The screens come from the showcase profile and the screenshot tools (every screen, sheet, dialog, quick menu tab,
settings page, setup and installer step).

```
python3 -I tools/layout/run.py --ci                  # the rows marked CI above, sets showcase, installer, shots
python3 -I tools/layout/run.py --full                # every distinct layout, every set (slow: hours on a busy machine)
python3 -I tools/layout/run.py --rows tv-4k-55in --form console   # also check the wording for a box
LAYOUT_RENDER=1 ...                                  # with xvfb: also save PNGs
```

Findings we accept go in `tools/layout/known.json`, each with the reason. Exit 1 on any other finding.
