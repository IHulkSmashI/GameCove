# Network and privacy

GameCove has no analytics, no crash reporting, no telemetry and no GameCove account. It never sends device
serial numbers, Steam or store account ids, API keys to anyone but the service they belong to, or anything else
about you to the GameCove project. The README's "Network and privacy" table is the short version; this is every
call, where it lives in the code and what stops it. `app/scripts/system/privacy.gd` (`NETWORK_CALLS`) is the list
the app itself shows under Settings > About > Network and privacy.

## The switches

| Switch | Where | Default | Off means |
| --- | --- | --- | --- |
| Background lookups | Settings > About > Network and privacy (`user://settings.cfg` `[privacy] background`) | On | Nothing is requested on GameCove's own initiative: no deals refresh, no game-database or calendar download, no device-photo prefetch at start. What you ask for right then (searching, opening a store page, pressing Check) still works. |
| Look up deals and prices | Same card, and Discover's settings (`price_lookups`) | On | No request to CheapShark, the Steam store API or GG.deals at all, background or not. Discover shows no prices. |
| Show maker photos | Same card, and Settings > Device (`[device] maker_photo`) | On | Your handheld's picture is never requested from its maker's site; the free photo or our drawing is used. |
| Affiliate links | Settings > Discover | On | Store links GameCove builds carry no affiliate id. None are configured today. It only changes a link's address; prices are the same and nothing is sent. |

## Every outbound call

| # | Host | What is sent | Trigger | Gated by | Code |
| --- | --- | --- | --- | --- | --- |
| 1 | github.com (`gamedb/gamedb.json.gz`) | Nothing personal | Start, at most daily | Background lookups | `app/scripts/library/gamedb.gd` |
| 2 | github.com (`gamedb/upcoming.json.gz`) | Nothing personal | Deals refresh, at most daily | Background lookups | `app/scripts/discover/discover.gd` |
| 3 | www.cheapshark.com | Wishlist Steam app ids and titles; search text | 45 s after start, every 6 h; search; game page | Look up deals and prices (+ Background lookups for the timer) | `discover.gd`, `cheapshark.gd` |
| 4 | api.steampowered.com `IStoreBrowseService/GetItems` | Wishlist and top-deal app ids, store country | Same | Same | `steam_api.gd` |
| 5 | api.gg.deals | App ids, region, your API key (in the query, as GG.deals requires) | Same, only with a key | Same | `ggdeals.gd` |
| 6 | github.com (`device-photos` release) | The asset name, i.e. your device model | Start until cached, weekly manifest | Background lookups (prefetch) | `app/scripts/device/photo.gd` |
| 7 | Your maker's site (MSI, Lenovo, ASUS, OneXPlayer, AOKZOE, AYANEO, Acer, GPD, ...) | The image URL implies your model; your IP address | Same, when there's no free photo | Show maker photos, Background lookups | `photo.gd` |
| 8 | Steam art CDN | App id | A tile needs art | — | `app/scripts/discover/art.gd` |
| 9 | www.steamgriddb.com | App id or title; your key (bearer header, dropped on cross-host redirects) | Art missing, only with a key | Remove the key | `art.gd` |
| 10 | api.steampowered.com achievements, Steam CDN icons | App id | Opening a game page | Settings > Performance | `app/scripts/achievements/` |
| 11 | steamcommunity.com, `IWishlistService` | Your Steam profile name or SteamID64 | You import your wishlist | You start it | `discover.gd` |
| 12 | github.com (`firmware/firmware.json.gz`, `.sha256`, `.sigstore.json`) | Nothing | Checking for updates | You start it | `app/scripts/system/updates.gd` |
| 13 | The maker's own download site (allow-listed per maker, https only) | Nothing | You prepare a USB drive | You start it | `updates.gd`, `firmware_index.gd` |
| 14 | LVFS, rpm-ostree / steamos-update, Flatpak, Flathub | Those tools' own | You update or install Moonlight | You start it | `updates.gd`, `app/scripts/streaming/` |
| 15 | PCs on your LAN (GameStream 47989 http, 47984 https pinned to the PC's certificate) | Fixed client id, Moonlight's client certificate | Stream tab | You start it | `app/scripts/streaming/host_api.gd` |
| 16 | LAN broadcast (Wake-on-LAN) | Your PC's MAC address | You wake a PC | You start it | `wol.gd` |
| 17 | 127.0.0.1 (Steam's CEF debugger; Handheld Daemon) | Local only | Opt-in Steam control; controller settings | — | `app/scripts/steam/`, `hhd_client.gd` |
| 18 | legendary.gl, auth.gog.com, Amazon | The sign-in code you type back | You sign in to a store | You start it | `app/scripts/library/stores/` |

Helpers and scripts outside the app: the upscaling helper downloads OptiScaler, OptiPatcher, fakenvapi,
REFramework, xess-xmx-linux and the FSR 4 files from their own releases only when you install them, each pinned by
sha256 (`packaging/helpers/gamecove_upscale/data/versions.json`); the gyro fix downloads MSI's sensor firmware
from download.msi.com (size and sha256 pinned); the installer (`get-gamecove.sh`) downloads GameCove's own
release, checks its Sigstore signature and every file's sha256, and fetches a pinned cosign if the system has
none.
