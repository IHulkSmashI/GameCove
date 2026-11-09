# Brand logos

GameCove shows the real logos of handheld makers, chip makers, stores and launchers, only to say which device, chip, store or launcher something is. Heroic, Lutris and Playnite do the same for store logos. The logos remain their owners' trademarks. GameCove is not affiliated with or endorsed by any of them.

- Table: [`app/data/brand_logos.json`](../app/data/brand_logos.json). For each brand it lists the name, aliases (including DMI vendor strings), `enabled`, `file`, `mono`, `hex`, `source`, `license` and `notice`.
- Files: `app/assets/brand/*.svg`. These are unmodified copies, mostly single-colour SVGs from [Simple Icons](https://simpleicons.org) (the version is in `simple_icons_version`; `source` records `simple-icons@<version> <slug>`). The UI tints single-colour (`mono`) logos with one flat colour at render time.
- Code: [`app/scripts/device/brand.gd`](../app/scripts/device/brand.gd). `logo_for(name)` returns the bundled logo first, then the icon the user's own system has installed (stores and launchers only), then `""`. When it returns `""`, the UI shows the name as text. `logo_texture(name, px, tint)` returns a ready-made texture.
- Tests: `app/tests/test_device_brand.gd`. They check that every enabled file exists and is valid SVG, that disabled brands return nothing, and that every DMI vendor in `devices.json` maps to a brand.

## Adding a logo

1. Copy the SVG unmodified from the `simple-icons` npm package (`icons/<slug>.svg`) into `app/assets/brand/<key>.svg`. If Simple Icons doesn't have the brand, use an official SVG from the maker's own site or press page.
2. Fill in the brand's entry: `file`, `source` (`simple-icons@<version> <slug>` or the official URL), `license`, `mono`, `hex`, and `notice` if the owner requires one.
3. Add a row to the Trademarks table in [CREDITS.md](../CREDITS.md#trademarks).

There is no logo yet (they show text) for Amazon Games / Prime Gaming, Legion (it uses the Lenovo logo), OneXPlayer, AYANEO, AOKZOE, GPD, ZOTAC and Orange Pi. None of these is in Simple Icons, and none publishes an SVG on its own site that we could find (checked 2026-11-09).

## Logo removal requests

Any company that doesn't want its logo shown in GameCove can ask, and we remove it. No questions asked.

**How to ask:** open a GitHub issue titled "Logo removal: <company>" in the GameCove repository (or contact the maintainer listed there). Please say which logo you mean.

**How to remove (maintainers):** the kill switch is one line. In `app/data/brand_logos.json`, set that brand's `"enabled"` to `false`:

```json
"steam": { ..., "enabled": false, ... }
```

With that flag off, `brand.gd` returns `""` for that brand from every lookup: no bundled logo, no system icon, no notice. The name shows as plain text everywhere. In the same commit, delete the SVG from `app/assets/brand/`, clear `file`, update the CREDITS.md Trademarks table, and link the issue. Ship it in the next release.
