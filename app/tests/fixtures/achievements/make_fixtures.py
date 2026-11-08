#!/usr/bin/env python3
"""Writes the crafted Steam stats fixtures for test_achievements_*.gd.

Small hand-made files in Steam's binary KeyValues layout (no real game data):
game 4242 with three achievements in block 1 (bits 0-2) and one in block 2,
one unlocked achievement in each block for account 1001, plus an older file
for another account. Run from this folder: python3 make_fixtures.py
"""
import os
import struct


def kv(d):
    out = b""
    for k, v in d.items():
        key = k.encode() + b"\0"
        if isinstance(v, dict):
            out += b"\x00" + key + kv(v) + b"\x08"
        elif isinstance(v, str):
            out += b"\x01" + key + v.encode() + b"\0"
        elif isinstance(v, float):
            out += b"\x03" + key + struct.pack("<f", v)
        elif isinstance(v, tuple) and v[0] == "u64":
            out += b"\x07" + key + struct.pack("<Q", v[1])
        elif isinstance(v, tuple) and v[0] == "w":
            out += b"\x05" + key + v[1].encode("utf-16-le") + b"\0\0"
        else:
            out += b"\x02" + key + struct.pack("<i", v)
    return out


def ach(name, bit, title, desc, hidden="0", icon=""):
    return {"name": name, "display": {
        "name": {"english": title, "german": title + " (de)", "token": name + "_NAME"},
        "desc": {"english": desc, "token": name + "_DESC"},
        "Hidden": hidden, "icon": icon or ("%040x.jpg" % (bit + 1)), "icon_gray": "%040x.jpg" % (bit + 100)},
        "bit": bit}


schema = {"4242": {"stats": {
    "1": {"bits": {
        "0": ach("ACH_START", 0, "First Steps", "Finish the tutorial"),
        "1": ach("ACH_BOSS", 1, "Boss Down", "Beat the first boss"),
        "2": ach("ACH_SECRET", 2, "Shh", "A hidden one", hidden="1"),
    }, "type": "4", "id": "1", "type_int": 4},
    "2": {"bits": {
        "0": {"name": "ACH_PLAIN", "display": {"name": "Plain Name", "desc": "Plain description",
                                               "hidden": "0", "icon": "", "icon_gray": ""}, "bit": 0},
    }, "type": "4", "id": "2", "type_int": 4},
    "10": {"name": "STAT_KILLS", "type": "1", "id": "10", "type_int": 1},
}, "version": "3", "gamename": "Fixture Game"}}

user = {"cache": {"crc": 12345, "PendingChanges": 0,
    "1": {"data": 0b101, "AchievementTimes": {"0": 1700000000, "2": 1700000500}},
    "2": {"data": 1, "AchievementTimes": {"0": 1700001000}},
    "10": {"data": 77},
}}
other = {"cache": {"crc": 1, "PendingChanges": 0, "1": {"data": 0b111}}}

# every type the parser knows, for the parser test
types = {"root": {"s": "text", "i": -5, "f": 1.5, "u": ("u64", 76561197960266729),
                  "w": ("w", "wide"), "nested": {"deep": {"x": 1}}}}

stats = "steam/appcache/stats"
os.makedirs(stats, exist_ok=True)
open(stats + "/UserGameStatsSchema_4242.bin", "wb").write(kv(schema) + b"\x08")
open(stats + "/UserGameStats_1001_4242.bin", "wb").write(kv(user) + b"\x08")
open(stats + "/UserGameStats_2002_4242.bin", "wb").write(kv(other) + b"\x08")
open("types.bin", "wb").write(kv(types) + b"\x08")
open("truncated.bin", "wb").write((kv(types) + b"\x08")[:20])
os.utime(stats + "/UserGameStats_2002_4242.bin", (1600000000, 1600000000))
os.makedirs("steam/config", exist_ok=True)
# SteamID64 of account 1001 = 76561197960265728 + 1001
open("steam/config/loginusers.vdf", "w").write(
    '"users"\n{\n\t"76561197960266729"\n\t{\n\t\t"AccountName"\t\t"fixture"\n'
    '\t\t"MostRecent"\t\t"1"\n\t\t"Timestamp"\t\t"1700000000"\n\t}\n'
    '\t"76561197960267730"\n\t{\n\t\t"AccountName"\t\t"other"\n'
    '\t\t"MostRecent"\t\t"0"\n\t\t"Timestamp"\t\t"1600000000"\n\t}\n}\n')
os.makedirs("steam/appcache/librarycache/4242/abc", exist_ok=True)
open("steam/appcache/librarycache/4242/%040x.jpg" % 1, "wb").write(b"not really a jpeg")
open("steam/appcache/librarycache/4242/abc/%040x.jpg" % 2, "wb").write(b"not really a jpeg")
open("rarity_4242.json", "w").write(
    '{"achievementpercentages":{"achievements":[{"name":"ACH_START","percent":"91.5"},'
    '{"name":"ACH_BOSS","percent":"40.2"},{"name":"ACH_SECRET","percent":3.25}],"result":1}}')
