extends RefCounted
## What a game's badges say. One list per game, each entry:
##   {"kind", "text" (chip wording), "short" (tile wording), "tone", "icon"}
## Tones are keys of Themes.TONES. The Badge component (badge.gd) draws them;
## tiles show a few small ones, the game page shows them all as chips.
##
## Fields read beyond docs/CONTRACTS.md (all optional, for the Discover and
## library work to fill in later):
##   g.deal = {"cut": 60, ...}         -> "On sale -60%"
##   g.wishlisted = true               -> "Wishlisted"
##   g.added = unix seconds            -> "New" for 14 days after install
##   g.update_available = true         -> "Update"
##   g.download = {"progress": 0.45}   -> "Downloading 45%"
##   g.info.device_rating = "great" | "playable" | "unsupported"

const Texts := preload("res://scripts/ui/texts.gd")
const View := preload("res://scripts/ui/library_view.gd")

const NEW_DAYS := 14
const SHORT_H := 10.0
const LONG_H := 30.0

## Display order on the game page.
const ORDER := ["download", "sale", "wish", "new", "update", "device", "protondb", "anticheat", "ttb", "not_installed", "store"]
## Tiles show one corner pill when unfocused (first match; anti-cheat only
## when it's a problem) ...
const TILE_CORNER := ["download", "sale", "update", "not_installed", "anticheat_problem", "new"]
## ... and up to two more along the bottom only while focused.
const TILE_STRIP := ["anticheat", "ttb", "protondb"]

const PROTON_TONE := {"platinum": "platinum", "gold": "gold", "silver": "silver", "bronze": "bronze", "borked": "borked"}
const DEVICE := {
	"great": {"text": "Runs great here", "short": "Great", "tone": "good", "icon": "check"},
	"playable": {"text": "Playable here", "short": "Playable", "tone": "warn", "icon": "handheld"},
	"unsupported": {"text": "Doesn't run here", "short": "No", "tone": "bad", "icon": "x"},
}


static func for_game(g: Dictionary, now := -1) -> Array:
	if now < 0:
		now = int(Time.get_unix_time_from_system())
	var info: Dictionary = g.get("info", {}) if g.get("info") is Dictionary else {}
	var out := {}

	var dl: Variant = g.get("download")
	if dl is Dictionary and dl.has("progress"):
		var p := roundi(clampf(float(dl["progress"]), 0.0, 1.0) * 100.0)
		out["download"] = _b("download", "Downloading %d%%" % p, "%d%%" % p, "info", "download")
	var deal: Variant = g.get("deal")
	if deal is Dictionary and int(deal.get("cut", 0)) > 0:
		var cut := int(deal["cut"])
		out["sale"] = _b("sale", "On sale -%d%%" % cut, "-%d%%" % cut, "sale", "tag")
	if g.get("wishlisted", false):
		out["wish"] = _b("wish", "Wishlisted", "Wishlist", "wish", "star")
	var added := int(g.get("added", 0))
	if added > 0 and g.get("installed", false) and now - added < NEW_DAYS * 86400:
		out["new"] = _b("new", "New", "New", "new", "sparkle")
	if g.get("update_available", false):
		out["update"] = _b("update", "Update ready", "Update", "info", "update")
	var dr: Variant = info.get("device_rating")
	if dr is String and DEVICE.has(dr):
		var d: Dictionary = DEVICE[dr]
		out["device"] = _b("device", d["text"], d["short"], d["tone"], d["icon"])
	var tier: Variant = info.get("protondb")
	if tier is String and PROTON_TONE.has(tier):
		out["protondb"] = _b("protondb", "Community reports: " + tier.capitalize(), tier.capitalize(), PROTON_TONE[tier], "gauge")
	var ac := Texts.anticheat_badge(info)
	if not ac.is_empty():
		var icon: String = {"good": "shield", "warn": "shield_alert", "bad": "shield_x"}.get(ac["tone"], "shield")
		out["anticheat"] = _b("anticheat", ac["text"], ac["text"], ac["tone"], icon)
	var ttb := Texts.ttb_badge(info)
	if ttb != "":
		out["ttb"] = _b("ttb", ttb + " to beat", ttb + " to beat", ttb_tone(main_hours(info)), "clock")
	if not g.get("installed", false):
		out["not_installed"] = _b("not_installed", "Not installed", "Not installed", "", "download")
	if g.has("store"):
		out["store"] = _b("store", View.store_name(String(g["store"])), View.store_name(String(g["store"])), "", "store")

	var list: Array = []
	for k in ORDER:
		if out.has(k):
			list.append(out[k])
	return list


## {"corner": badge or {}, "strip": [<= 2 badges, shown on focus]} for a tile.
static func for_tile(g: Dictionary, now := -1) -> Dictionary:
	var all := for_game(g, now)
	var by := {}
	for b in all:
		by[b["kind"]] = b
	var corner := {}
	for k in TILE_CORNER:
		if k == "anticheat_problem":
			if by.has("anticheat") and by["anticheat"]["tone"] in ["warn", "bad"]:
				corner = by["anticheat"]
				break
		elif by.has(k):
			corner = by[k]
			break
	var strip: Array = []
	for k in TILE_STRIP:
		if by.has(k) and by[k] != corner and strip.size() < 2:
			strip.append(by[k])
	return {"corner": corner, "strip": strip}


## Hours for the main story, else extras, else completionist; -1 if unknown.
static func main_hours(info: Dictionary) -> float:
	var t: Variant = info.get("time_to_beat")
	if not t is Dictionary:
		return -1.0
	for k in ["main_h", "extra_h", "complete_h"]:
		if t.get(k) != null and float(t[k]) > 0.0:
			return float(t[k])
	return -1.0


## short (<= 10 h) good, long (> 30 h) info, else neutral.
static func ttb_tone(hours: float) -> String:
	if hours < 0.0:
		return ""
	if hours <= SHORT_H:
		return "good"
	if hours > LONG_H:
		return "info"
	return ""


static func ttb_length(hours: float) -> String:
	if hours < 0.0:
		return ""
	if hours <= SHORT_H:
		return "short"
	if hours > LONG_H:
		return "long"
	return "medium"


static func _b(kind: String, text: String, short: String, tone: String, icon: String) -> Dictionary:
	return {"kind": kind, "text": text, "short": short, "tone": tone, "icon": icon}
