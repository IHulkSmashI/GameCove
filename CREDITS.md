# Credits

GameCove stands on a lot of other people's work. Thank you.

## People

- **Kisenir** (r/MSIClaw): found and tested how to bring up the MSI Claw 8 EX gyro on Linux (sensor-hub firmware, HID-BPF descriptor fix, keepalive and bias calibration). He gave us permission to use his work (2026-11-08). His HID-BPF program is GPL-2.0-only; his helper scripts are GPL-2.0-or-later once he confirms. GPL-2.0 text: [LICENSES/GPL-2.0-only.txt](LICENSES/GPL-2.0-only.txt).
- **HHHHanasak1**: xess-xmx-linux, XeSS on the XMX cores under Proton.

## Projects we use or build on

| Project | What for | License |
| --- | --- | --- |
| gamescope | Display, frame limit, scaling, overlay layering | BSD-2-Clause |
| Proton / umu-launcher | Running Windows games | Various / GPL-3.0 |
| InputPlumber | Controller input, button and gyro routing | GPL-3.0 |
| PowerStation | TDP, GPU clocks over D-Bus | GPL-3.0 |
| steamos-manager | TDP, GPU, charge limit over D-Bus | MIT |
| legendary, heroic-gogdl, nile | Epic, GOG, Amazon libraries and launch | GPL-3.0 |
| Heroic Games Launcher | Library, playtime, prefixes and art for games installed through Heroic | GPL-3.0 |
| gamescope-session-plus | The session GameCove runs in | see project |
| xprop (X.Org) | Setting gamescope atoms | MIT |
| udev-hid-bpf | Loading HID-BPF fixes | GPL-2.0 |
| Godot Engine | UI | MIT |
| Inter typeface | Banner lettering | OFL-1.1 |

## Ideas and findings we borrowed

- **ClawDeck**: the Claw 8 EX power backend findings, launch environment, face-button and EDID findings, ported here.
- **DeckyTDPTuner**: ideas behind Auto TDP.
- **Zendo-GIT Intel-Handheld-and-ARC-GPU-laboratory** (MIT, © 2026 ClawLab contributors): the VRR range fix and the checked panel list. Notice reproduced in [fixes/claw8ex-vrr/LICENSE.ClawLab-MIT](fixes/claw8ex-vrr/LICENSE.ClawLab-MIT).
- **OpenGamepadUI** and **gamescope-x11-client**: how a gamescope main app sets its atoms and base layers.
- **proton-cachyos** (CachyOS), **GE-Proton** (GloriousEggroll) and **low_latency_layer** (Korthos-Software): their docs for the launch variables we set.

## Data

| Source | Use | License |
| --- | --- | --- |
| Wikidata | Titles, dates, cross-store IDs | CC0 |
| AreWeAntiCheatYet | Anti-cheat status | MIT |
| ProtonDB data dumps | Compatibility reports | ODbL (credit and share-alike) |
| IGDB | Time to beat; upcoming release dates (nightly, when the job has Twitch credentials) | Free for non-commercial use under the [Twitch Developer Service Agreement](https://api-docs.igdb.com/#getting-started); commercial use needs an IGDB partnership; credit IGDB.com |
| SteamGridDB | Optional artwork, only with each user's own API key | [Terms](https://www.steamgriddb.com/terms): personal, non-commercial use; no key ships with GameCove |
| [CheapShark](https://www.cheapshark.com) | Deals, other stores' prices (USD), historical lows | [API terms](https://apidocs.cheapshark.com/): free, no key; deals must be opened through CheapShark's redirect links (we never use affiliate or direct links for CheapShark deals); descriptive User-Agent; no catalogue crawling. Price data by CheapShark. |
| Steam (Valve) | Regional prices, sale end dates, release state and art by app id (`IStoreBrowseService/GetItems`); public wishlist import (`IWishlistService/GetWishlist`); coming-soon list for the nightly calendar (`IStoreQueryService/Query`); custom-URL lookup through the public profile XML | [Steam Web API Terms of Use](https://steamcommunity.com/dev/apiterms); called without a key; not affiliated with or endorsed by Valve. Game art © its publishers, shown to identify the game. |
| European Central Bank | Euro reference exchange rates, to compare USD prices with your currency (estimates, marked "~") | [ECB reuse policy](https://www.ecb.europa.eu/stats/ecb_statistics/governance_and_quality_framework/html/usage_policy.en.html): free for any use, unmodified, with credit. Source: ECB statistics. |
| Wikidata | Upcoming release dates for the calendar | CC0 |

We looked at IsThereAnyDeal for regional deal prices and don't use it: its [API terms](https://docs.isthereanydeal.com/) forbid apps "that could be considered a competition to IsThereAnyDeal" and using the API to help its competition, which a deals and price-alert feature next to CheapShark could be read as.
