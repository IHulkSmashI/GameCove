#!/usr/bin/env python3
"""Builds the showcase profile's data from real, public sources.

    python3 -I tools/showcase/fetch.py            # data (library.json, pinned/) + art cache
    python3 -I tools/showcase/fetch.py --art-only # only (re)download missing art from library.json
    python3 -I tools/showcase/fetch.py --pinned-only  # only the Discover feeds

Writes, next to this file:
  library.json      the showcase library: real games, their real Steam data
                    (name, summary, release year), GameCove's own gamedb record
                    (time to beat, anti-cheat, ProtonDB-derived tier; ProtonDB's
                    public summary when gamedb has none), each game's real
                    achievement list (names, descriptions, icons, global unlock
                    percentages from the Steam Community page) and the art file
                    names. Playtime, last played and which achievements are
                    unlocked are this profile's own (the "user"), picked so the
                    unlocks follow the global percentages (common ones first).
  pinned/           the Discover feeds GameCove reads, as fetched now, cut to
                    well-known games (prices untouched): CheapShark's top deals,
                    its free-to-keep giveaways and GameCove's upcoming.json.gz
                    release calendar.
  cache/            (git-ignored) art from Steam's CDN, achievement icons, the
                    emulated games' box art (libretro-thumbnails), each
                    game's Steam store details (appdetails, the answer GameCove's
                    own game-details lookup reads: genres, developers, release
                    date, Metacritic score, screenshots) and its screenshot
                    thumbnails.

Nothing here invents a price, a name or a number a store published: values come
from the sources above as fetched; the profile's own play history is the only
made-up part, as on any real user's handheld.
"""

import concurrent.futures as cf
import gzip
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, "cache")
PINNED = os.path.join(HERE, "pinned")
UA = "GameCove/showcase (+https://github.com/IHulkSmashI/GameCove)"
GAMEDB = "https://github.com/IHulkSmashI/GameCove-data/releases/download/gamedb/gamedb.json.gz"
UPCOMING = "https://github.com/IHulkSmashI/GameCove-data/releases/download/gamedb/upcoming.json.gz"
CS = "https://www.cheapshark.com/api/1.0/"
ASSETS = "https://shared.akamai.steamstatic.com/store_item_assets/"
CDN = "https://cdn.cloudflare.steamstatic.com/steam/apps/%s/"
ACH_ICONS = "https://cdn.fastly.steamstatic.com/steamcommunity/public/images/apps/%s/%s"

# The profile. store, store id, Steam app id (art, achievements, gamedb), title
# as the store shows it, installed, hours played, days since last played,
# share of achievements unlocked, extras.
LIBRARY = [
    ("steam", "1245620", "1245620", "ELDEN RING", True, 86.4, 0.08, 0.52, {}),
    ("steam", "1086940", "1086940", "Baldur's Gate 3", True, 142.0, 1.2, 0.46, {}),
    ("steam", "1145350", "1145350", "Hades II", True, 38.5, 2.3, 0.41, {}),
    ("steam", "1903340", "1903340", "Clair Obscur: Expedition 33", True, 29.1, 3.4, 0.33, {}),
    ("steam", "2379780", "2379780", "Balatro", True, 61.2, 4.1, 0.55, {}),
    ("gog", "1423049311", "1091500", "Cyberpunk 2077", True, 74.6, 6.2, 0.48, {}),
    ("steam", "1030300", "1030300", "Hollow Knight: Silksong", True, 0.0, -1, 0.0, {"added_days": 1}),
    ("steam", "553850", "553850", "HELLDIVERS 2", True, 15.3, 8.0, 0.30, {}),
    ("steam", "413150", "413150", "Stardew Valley", True, 120.4, 9.5, 0.62, {}),
    ("steam", "2358720", "2358720", "Black Myth: Wukong", True, 18.2, 12.0, 0.21, {"update": True}),
    ("steam", "367520", "367520", "Hollow Knight", True, 44.0, 15.0, 0.57, {}),
    ("steam", "1593500", "1593500", "God of War", True, 25.7, 20.0, 0.43, {}),
    ("steam", "1551360", "1551360", "Forza Horizon 5", True, 22.3, 25.0, 0.18, {}),
    ("steam", "2050650", "2050650", "Resident Evil 4", True, 19.4, 30.0, 0.39, {}),
    ("steam", "2246340", "2246340", "Monster Hunter Wilds", False, 52.8, 40.0, 0.44, {}),
    ("steam", "588650", "588650", "Dead Cells", True, 33.1, 45.0, 0.35, {}),
    ("epic", "celeste", "504230", "Celeste", True, 12.6, 60.0, 0.0, {}),
    ("steam", "1687950", "1687950", "Persona 5 Royal", True, 64.0, 70.0, 0.40, {}),
    ("steam", "1174180", "1174180", "Red Dead Redemption 2", False, 67.2, 90.0, 0.37, {}),
    ("steam", "1817070", "1817070", "Marvel's Spider-Man Remastered", False, 31.5, 120.0, 0.51, {}),
    ("epic", "hogwarts-legacy", "990080", "Hogwarts Legacy", False, 35.9, 150.0, 0.0, {}),
    ("steam", "2344520", "2344520", "Diablo IV", False, 27.4, 180.0, 0.22, {}),
    ("steam", "814380", "814380", "Sekiro: Shadows Die Twice", False, 48.3, 200.0, 0.47, {}),
    ("epic", "death-stranding-directors-cut", "1850570", "DEATH STRANDING DIRECTOR'S CUT", False, 41.0, 300.0, 0.0, {}),
    ("gog", "1495134320", "292030", "The Witcher 3: Wild Hunt", False, 110.2, 400.0, 0.0, {}),
]

# Well-known games kept from the real feeds (everything else is cut for the
# showcase; prices and dates stay as fetched).
DEAL_MIN_METACRITIC = 80
DEAL_MIN_STEAM_REVIEWS = 8000
CALENDAR_KEEP = [
    "Phantom Blade Zero", "Football Manager 27", "DreamWorks Shrek 2 Remastered", "Warhammer Survivors",
    "Warhammer 40,000: Dawn of War IV", "Rayman Legends Retold", "Thief: The Dark Project Remastered",
    "DRAGON QUEST MONSTERS: The Withered World", "Attack on Titan 3 / A.O.T. 3", "Path of Exile 2",
    "STRANGER THAN HEAVEN", "Tropico 7", "Witchbrook", "METRO 2039", "Tomb Raider: Legacy of Atlantis",
    "Persona 4 Revival", "Fable", "FINAL FANTASY VII REVELATION", "Lords of the Fallen II", "Kingdom Hearts IV",
    "Clockwork Revolution", "The Witcher IV", "Sonic Pico Park", "Crimson Desert: Charting the Unknown",
]


def get(url, binary=False, tries=3):
    for i in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "*/*"})
            with urllib.request.urlopen(req, timeout=40) as r:
                data = r.read()
                return data if binary else data.decode("utf-8")
        except urllib.error.HTTPError as e:
            if e.code in (403, 404):
                return None
            time.sleep(1.5 * (i + 1))
        except Exception:
            time.sleep(1.5 * (i + 1))
    return None


def get_json(url):
    t = get(url)
    return json.loads(t) if t else None


def store_items(appids, country="CA"):
    out = {}
    for i in range(0, len(appids), 40):
        body = {"ids": [{"appid": int(a)} for a in appids[i:i + 40]],
                "context": {"language": "english", "country_code": country},
                "data_request": {"include_assets": True, "include_release": True, "include_basic_info": True}}
        d = get_json("https://api.steampowered.com/IStoreBrowseService/GetItems/v1/?input_json="
                     + urllib.parse.quote(json.dumps(body, separators=(",", ":"))))
        for it in (d or {}).get("response", {}).get("store_items", []):
            out[str(it.get("appid", it.get("id")))] = it
    return out


def appdetails(appid):
    d = get_json("https://store.steampowered.com/api/appdetails?appids=%s&cc=ca&l=english&filters=basic,release_date" % appid)
    v = (d or {}).get(str(appid), {})
    return v.get("data", {}) if v.get("success") else {}


def community_achievements(appid):
    """Real schema (names, descriptions, icons, hidden) and global percentages
    from the public Steam Community achievements page."""
    html = get("https://steamcommunity.com/stats/%s/achievements/" % appid)
    if not html:
        return []
    m = re.search(r'"queryData":"((?:[^"\\]|\\.)*)"', html)
    if not m:
        return []
    q = json.loads(json.loads('"' + m.group(1) + '"'))
    schema, pct = None, {}
    for x in q.get("queries", []):
        key = x.get("queryKey", [])
        data = x.get("state", {}).get("data")
        if len(key) >= 3 and key[0] == "achievements" and key[2] == "schema_v2":
            schema = data
        if len(key) >= 3 and key[0] == "achievements" and key[2] == "globalpercentages":
            pct = (data or {}).get("percentages", {})
    out = []
    for g in (schema or {}).get("groups", []):
        if g.get("dlcappid") or not g.get("ispublic", True):
            continue
        for a in g.get("achievements", []):
            if a.get("archived"):
                continue
            out.append({"id": a["api_name"], "name": a.get("name", ""), "description": a.get("description", ""),
                        "hidden": bool(a.get("hidden")), "icon": a.get("icon_achieved", ""),
                        "icon_gray": a.get("icon_unachieved", ""),
                        "rarity": round(float(pct.get(str(a.get("internal_key")), 0.0)), 1)})
    return out


def protondb_summary(appid):
    d = get_json("https://www.protondb.com/api/v1/reports/summaries/%s.json" % appid)
    return (d or {}).get("tier")


def art_urls(appid, item):
    a = (item or {}).get("assets", {})
    base = ASSETS + a.get("asset_url_format", "steam/apps/%s/${FILENAME}" % appid)
    def asset(*names):
        for n in names:
            if a.get(n):
                return base.replace("${FILENAME}", a[n])
        return ""
    cdn = CDN % appid
    return {
        "cover": [asset("library_capsule_2x", "library_capsule"), cdn + "library_600x900_2x.jpg", cdn + "library_600x900.jpg"],
        "hero": [asset("library_hero_2x", "library_hero"), cdn + "library_hero.jpg"],
        "logo": [cdn + "logo_2x.png", cdn + "logo.png"],
        "header": [asset("header_2x", "header"), cdn + "header.jpg"],
    }


def download(path, urls):
    if os.path.exists(path) and os.path.getsize(path) > 0:
        return True
    for u in urls:
        if not u:
            continue
        b = get(u, binary=True)
        if b and len(b) > 200:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path + ".part", "wb") as f:
                f.write(b)
            os.replace(path + ".part", path)
            return True
    return False


def gamedb_index():
    d = json.loads(gzip.decompress(get(GAMEDB, binary=True)))
    idx = {}
    for g in d["games"]:
        s = g.get("ids", {}).get("steam")
        if s:
            idx[s] = g
    return d, idx


def unlocks(items, frac, hours, last_days, now):
    """Unlocks the most common achievements first, dated across the play
    history so the newest unlock lines up with the last session."""
    n = int(round(len(items) * frac))
    order = sorted(range(len(items)), key=lambda i: -items[i]["rarity"])
    chosen = set(order[:n])
    span = max(3.0, hours * 1.6) * 86400
    end = now - max(0.0, last_days) * 86400
    k = 0
    for i in order:
        it = items[i]
        it["unlocked"] = i in chosen
        it["unlock_time"] = 0
        if it["unlocked"]:
            k += 1
            it["unlock_time"] = int(end - span * (1.0 - k / max(1, n)) - 600)
    return sum(1 for it in items if it["unlocked"])


def fetch_library(now):
    print("gamedb ...", flush=True)
    db, idx = gamedb_index()
    appids = [e[2] for e in LIBRARY]
    print("store items ...", flush=True)
    items = store_items(appids)
    games = []

    def one(e):
        store, sid, appid, title, installed, hours, last_days, frac, extra = e
        det = appdetails(appid)
        rec = idx.get(appid, {})
        info = {"released": rec.get("released"), "time_to_beat": rec.get("time_to_beat"),
                "anticheat": rec.get("anticheat"), "protondb": rec.get("protondb"),
                "summary": det.get("short_description", "")}
        src = {"gamedb": bool(rec)}
        t = info["time_to_beat"] or {}
        if t.get("main_h") is not None and t["main_h"] < 2 and (t.get("complete_h") or 0) > 40:
            info["time_to_beat"] = None   # an IGDB entry error (Forza Horizon 5: "1 h"), not shown
            src["ttb_dropped"] = t
        if info["released"] is None:
            m = re.search(r"(\d{4})", det.get("release_date", {}).get("date", ""))
            info["released"] = int(m.group(1)) if m else None
        if not info["protondb"]:
            info["protondb"] = protondb_summary(appid)
            src["protondb"] = "protondb.com summary" if info["protondb"] else None
        ach = community_achievements(appid) if store == "steam" else []
        g = {"store": store, "id": sid, "steam_appid": appid, "title": title, "installed": installed,
             "playtime_min": int(round(hours * 60)), "last_played_days": last_days, "info": info,
             "art_urls": art_urls(appid, items.get(appid)), "achievements": ach, "ach_frac": frac,
             "sources": src, "steam_name": det.get("name", "")}
        g.update(extra)
        return g

    with cf.ThreadPoolExecutor(6) as ex:
        games = list(ex.map(one, LIBRARY))
    for g in games:
        g["ach_unlocked"] = unlocks(g["achievements"], g["ach_frac"], g["playtime_min"] / 60.0, g["last_played_days"], now) if g["achievements"] else 0
        print("  %-34s ttb=%-5s pdb=%-8s ach=%d/%d" % (g["title"][:34], (g["info"]["time_to_beat"] or {}).get("main_h"),
              g["info"]["protondb"], g["ach_unlocked"], len(g["achievements"])), flush=True)
    return {"fetched": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)), "now": now,
            "gamedb_built": db.get("built"), "credits": db.get("credits", ""), "games": games}


def fetch_pinned():
    os.makedirs(PINNED, exist_ok=True)
    # CheapShark: the same query GameCove makes, then a second page of top-rated
    # games so the cut keeps enough well-known titles.
    cands = {}
    for q in ["deals?onSale=1&sortBy=Deal%20Rating&pageSize=60",
              "deals?onSale=1&sortBy=Deal%20Rating&pageSize=60&AAA=1",
              "deals?onSale=1&sortBy=Deal%20Rating&pageSize=60&metacritic=85",
              "deals?storeID=1&onSale=1&sortBy=Deal%20Rating&pageSize=60&metacritic=75",
              "deals?storeID=1&onSale=1&sortBy=Reviews&pageSize=60"]:
        for x in get_json(CS + q) or []:
            mc = int(x.get("metacriticScore") or 0)
            rc = int(x.get("steamRatingCount") or 0)
            t = x.get("title", "").strip().lower()
            if mc < DEAL_MIN_METACRITIC or rc < DEAL_MIN_STEAM_REVIEWS or not x.get("steamAppID"):
                continue
            # one row per game, Steam's own when there is one (priced for Canada by Steam)
            if t not in cands or (x.get("storeID") == "1" and cands[t].get("storeID") != "1"):
                cands[t] = x
    rate = lambda x: -float(x.get("dealRating") or 0)
    steam = sorted([x for x in cands.values() if x.get("storeID") == "1"], key=rate)[:16]
    other = sorted([x for x in cands.values() if x.get("storeID") != "1"], key=rate)[:8]
    keep = sorted(steam + other, key=rate)
    with open(os.path.join(PINNED, "cs_deals.json"), "w") as f:
        json.dump(keep, f, indent=0)
    print("deals kept: %d (%d Steam)" % (len(keep), len(steam)))
    # Free to keep: CheapShark's giveaways right now, as GameCove asks for them.
    free = get_json(CS + "deals?onSale=1&upperPrice=0&sortBy=Recent&pageSize=30") or []
    with open(os.path.join(PINNED, "cs_free.json"), "w") as f:
        json.dump(free, f, indent=0)
    print("free to keep: %d" % len(free))
    up = json.loads(gzip.decompress(get(UPCOMING, binary=True)))
    names = {n.lower() for n in CALENDAR_KEEP}
    up["releases"] = [r for r in up["releases"] if r["title"].lower() in names]
    up["count"] = len(up["releases"])
    with gzip.open(os.path.join(PINNED, "upcoming.json.gz"), "wt") as f:
        json.dump(up, f, separators=(",", ":"))
    print("calendar kept: %d" % len(up["releases"]))


def art_jobs(lib):
    jobs = []
    for g in lib["games"]:
        a = g["steam_appid"]
        for kind, urls in g["art_urls"].items():
            jobs.append((os.path.join(CACHE, a, kind + (".png" if kind == "logo" else ".jpg")), urls))
        for it in g["achievements"]:
            for k in ("icon", "icon_gray"):
                if it[k]:
                    jobs.append((os.path.join(CACHE, "ach", a, it[k]), [ACH_ICONS % (a, it[k])]))
    return jobs


def maker_photo_job():
    """The Claw 8 EX's maker image, from the link in app/data/device_photos.json
    (the app downloads the same picture on the device; never committed)."""
    with open(os.path.join(HERE, "..", "..", "app", "data", "device_photos.json")) as f:
        m = json.load(f)["msi-claw-8-ex"]["maker_image"]
    return (os.path.join(CACHE, "device", "msi-claw-8-ex.png"), [m["url"]])


def details_jobs(lib):
    """Each game's Steam store details, unfiltered and as Steam sends them (the
    showcase reads them with GameCove's own Metadata.steam_layer), and the
    screenshot thumbnails the game page shows."""
    jobs = []
    for g in lib["games"]:
        a = g["steam_appid"]
        path = os.path.join(CACHE, "appdetails", a + ".json")
        if not os.path.exists(path):
            b = get("https://store.steampowered.com/api/appdetails?appids=%s&cc=ca&l=english" % a, binary=True)
            if b:
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "wb") as f:
                    f.write(b)
        try:
            with open(path) as f:
                d = json.load(f).get(a, {}).get("data", {})
        except (OSError, ValueError):
            print("  no details: " + a)
            continue
        for s in (d.get("screenshots") or [])[:8]:
            u = s.get("path_thumbnail", "")
            if u:
                name = re.sub(r"[^A-Za-z0-9_.-]", "_", u.split("/")[-1].split("?")[0])
                jobs.append((os.path.join(CACHE, "shots", a, name), [u]))
    return jobs


# The showcase's EmuDeck games: box art and an in-game picture from
# libretro-thumbnails (the set RetroArch and ES-DE scrapers use), standing in
# for the SteamGridDB art Steam ROM Manager saves on a real device.
LIBRETRO = "https://thumbnails.libretro.com/"
EMU_ART = [
    ("super-metroid", "Nintendo - Super Nintendo Entertainment System", "Super Metroid (Japan, USA) (En,Ja)"),
    ("pokemon-emerald", "Nintendo - Game Boy Advance", "Pokemon - Emerald Version (USA, Europe)"),
    ("castlevania-sotn", "Sony - PlayStation", "Castlevania - Symphony of the Night (USA)"),
    ("sonic-2", "Sega - Mega Drive - Genesis", "Sonic The Hedgehog 2 (World)"),
]


def emu_art_jobs():
    jobs = []
    for name, system, rom in EMU_ART:
        for kind, folder in (("cover", "Named_Boxarts"), ("snap", "Named_Snaps")):
            url = LIBRETRO + urllib.parse.quote("%s/%s/%s.png" % (system, folder, rom))
            jobs.append((os.path.join(CACHE, "emu", "%s-%s.png" % (name, kind)), [url]))
    return jobs


def fetch_art(lib):
    jobs = art_jobs(lib) + [maker_photo_job()] + details_jobs(lib) + emu_art_jobs()
    # One job per file: two threads writing the same .part (an icon two
    # achievements share) raced on the rename.
    seen = set()
    missing = []
    for j in jobs:
        if not os.path.exists(j[0]) and j[0] not in seen:
            seen.add(j[0])
            missing.append(j)
    print("art: %d files, %d to download" % (len(jobs), len(missing)), flush=True)
    with cf.ThreadPoolExecutor(12) as ex:
        res = list(ex.map(lambda j: (j[0], download(*j)), missing))
    bad = [p for p, ok in res if not ok]
    for p in bad:
        print("  no art: " + os.path.relpath(p, HERE))
    return not [p for p in bad if "/ach/" not in p and not p.endswith("logo.png")]


def main():
    path = os.path.join(HERE, "library.json")
    if "--pinned-only" in sys.argv:
        fetch_pinned()
        return
    if "--art-only" in sys.argv:
        with open(path) as f:
            lib = json.load(f)
    else:
        now = int(time.time())
        lib = fetch_library(now)
        with open(path, "w") as f:
            json.dump(lib, f, indent=1, ensure_ascii=False)
        fetch_pinned()
    ok = fetch_art(lib)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
