# Brand logos

GameCove shows the real logos of handheld makers, chip makers, stores and launchers, only to say which device, chip, store or launcher something is. Heroic, Lutris and Playnite do the same for store logos. The logos remain their owners' trademarks. GameCove is not affiliated with or endorsed by any of them.

## Trademark use (the owner's decision)

- **What we use:** the makers' and stores' own logos, unmodified or faithfully traced, as listed below. We don't ask for permission first; we remove any logo whose owner asks (see [Logo removal requests](#logo-removal-requests)).
- **Why it's allowed:** nominative, identification-only use. A logo appears only next to the thing it names (your device's maker, the store a game comes from, the chip inside), smaller than GameCove's own name, never in GameCove's own branding, marketing or icon, and never in a way that suggests the owner endorses GameCove.
- **Not GPL:** `app/assets/brand/*` is excluded from GameCove's GPL-3.0-or-later licence; see [app/assets/brand/LICENSE.md](../app/assets/brand/LICENSE.md). The RPM's `License:` tag and the shipped licence files say the same.
- **Every logo records where it came from:** each entry in `brand_logos.json` has `owner`, `source` (the exact URL, package or Simple Icons slug), `license` (how it was made and under what terms) and `notice`. `packaging/tests/release.sh` fails if any entry lacks them or any file in `app/assets/brand/` has no entry.

- Table: [`app/data/brand_logos.json`](../app/data/brand_logos.json). For each brand it lists the name, aliases (including DMI vendor strings), `enabled`, `file`, `mono`, `hex`, `source`, `license` and `notice`.
- Files: `app/assets/brand/*.svg`, one per brand (every brand has one). Three kinds:
  - Unmodified single-colour SVGs from [Simple Icons](https://simpleicons.org) (the version is in `simple_icons_version`; `source` records `simple-icons@<version> <slug>`), plus the Bottles project's own icon.
  - The maker's own SVG with only presentation removed (fills, ids, `<title>`), geometry untouched: OneXPlayer.
  - Traces of the maker's official raster logo, for makers that publish no vector: AYANEO, AOKZOE, GPD, ZOTAC GAMING, Orange Pi and Amazon Games. `source` is the exact PNG/JPG and `license` gives the method and the overlap score.
  The UI tints single-colour (`mono`) logos with one flat colour at render time, so mono files carry no fill of their own; `hex` is the brand colour.
- Code: [`app/scripts/device/brand.gd`](../app/scripts/device/brand.gd). `logo_for(name)` returns the bundled logo first, then the icon the user's own system has installed (stores and launchers only), then `""`. When it returns `""`, the UI shows the name as text. `logo_texture(name, px, tint)` returns a ready-made texture.
- Tests: `app/tests/test_device_brand.gd`. They check that every enabled file exists and is valid SVG, that disabled brands return nothing, that every DMI vendor in `devices.json` maps to a brand, and that every maker in `devices.json` and every store in the library has an enabled, pure-vector logo with a sensible viewBox that draws at 48 px (mono logos with no hard-coded fill).

## Adding a logo

Never redraw a logo from memory. In order of preference:

1. **Simple Icons**: copy the SVG unmodified from the `simple-icons` npm package (`icons/<slug>.svg`) into `app/assets/brand/<key>.svg`.
2. **The maker's own vector**: their site's header logo (often an inline SVG or an `.svg` asset in the page's JS/CSS), press kit, GitHub, app packages, or Wikimedia Commons. For a mono logo, strip only presentation so tinting works: `python3 tools/brandlogos/normalize.py in.svg app/assets/brand/<key>.svg --title "<Name>"`.
3. **A faithful trace of the maker's official raster logo** (largest copy you can find; check it is the current mark on their site):
   ```sh
   pip install potracer cairosvg            # potrace in pure Python
   python3 tools/brandlogos/trace.py logo.png app/assets/brand/<key>.svg --title "<Name>" \
       --ink alpha|dark|light --scale 4..12 --turdsize 40
   python3 tools/brandlogos/compare.py logo.png app/assets/brand/<key>.svg --width <logo width in px> --diff /tmp/diff.png
   ```
   `compare.py` crops both to their ink, binarises them at the original's resolution and prints the overlap (IoU). Iterate on `--scale`, `--alphamax`, `--opttolerance` and `--level` until it reads **0.97 or more**, then look at the diff: differences should be one-pixel edges only. Record the score and the source URL in `license`.

Then fill in the brand's entry (`file`, `source`, `license`, `mono`, `hex`, `notice` if the owner requires one), add a row to the Trademarks table in [CREDITS.md](../CREDITS.md#trademarks), and check every logo by eye: `python3 tools/brandlogos/contact.py . /tmp/contact.png` renders all of them on dark, light and brand-colour backgrounds.

### Where each non-Simple-Icons logo came from (checked 2026-11-09)

| Brand | Source | Method | Overlap |
| --- | --- | --- | --- |
| Amazon Games | 256x256 icon in Amazon's official `AmazonGamesSetup.exe` (the store is labelled Amazon Games, the launcher's name; the publisher is Amazon Game Studios again since 2025 and Prime Gaming moved into Luna, so neither of their marks fits) | potrace | 0.972 |
| OneXPlayer | onexplayer.com header SVG (`/assets/Logo-03078c08.svg`) | fills removed, viewBox added | 1.000 |
| AYANEO | Emblem PNG on shop.ayaneo.com; the same emblem as the current ayaneo.com header (0.994 against it) | potrace | 0.995 |
| AOKZOE | Header PNG on aokzoestore.com (512x115, the largest published; aokzoe.com serves an expired certificate) | potrace | 0.979 |
| GPD | Header PNG on gpd.hk (1424x525, purple-to-blue gradient) | potrace | 0.997 |
| ZOTAC GAMING | ZOTAC GAMING logo JPG on ZOTAC's own store zotacstore.com (zotac.com refused automated access); the Zone is a ZOTAC GAMING product | potrace | 0.977 |
| Orange Pi | Emblem PNG in Orange Pi's own boot theme (`orangepi-build`, `plymouth-theme-orangepi/orangepi-logo.png`); orangepi.org only has smaller copies | potrace | 0.973 |

Not used: Wikimedia Commons (rate-limited from our build machine during this pass; it has an "Amazon Games" and an older ZOTAC SVG worth comparing next time) and Brandfetch (blocks automated access).

## Logo removal requests

Any company that doesn't want its logo shown in GameCove can ask, and we remove it. No questions asked.

**How to ask:** open a GitHub issue titled "Logo removal: <company>" at https://github.com/IHulkSmashI/GameCove/issues, or, to ask privately, message the maintainer (IHulkSmashI) on GitHub or on the GameCove Discord linked from the README. Please say which logo you mean. We act on the request within a week: the logo is switched off in the next release (or a hotfix release if you ask for one).

**How to remove (maintainers):** the kill switch is one line. In `app/data/brand_logos.json`, set that brand's `"enabled"` to `false`:

```json
"steam": { ..., "enabled": false, ... }
```

With that flag off, `brand.gd` returns `""` for that brand from every lookup: no bundled logo, no system icon, no notice. The name shows as plain text everywhere. In the same commit, delete the SVG from `app/assets/brand/`, clear `file`, update the CREDITS.md Trademarks table, and link the issue. Ship it in the next release.
