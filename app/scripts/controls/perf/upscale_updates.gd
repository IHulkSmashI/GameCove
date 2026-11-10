extends RefCounted
## Upscaler updates (the gamecove-upscale helper's check / update / game-update,
## packaging/helpers/gamecove_upscale/upkeep.py): what the Upscaling card says
## about the downloaded OptiScaler, OptiPatcher, fakenvapi, XeSS XMX driver and
## FSR 4 files, and when the background check may run. Pure functions: the perf
## provider calls them on Controls' worker, tests feed them fixtures.
##
## The helper fetches GameCove's signed upscalers index (nightly, from
## .github/workflows/upscalers.yml) and checks its signature itself; the app only
## shows what the helper answers. The background check runs at most once a day
## and only while Settings > About > "Background lookups" is on; pressing the row
## checks right away whatever that switch says (the user asked for it).

const INTERVAL_S := 24 * 3600
## After start-up, so the first frame and the library come first.
const FIRST_DELAY_S := 90.0
const STAMP_SECTION := "upscalers"


## True when the background check should run now.
static func due(last_unix: int, now_unix: int, background_allowed: bool) -> bool:
	return background_allowed and (last_unix <= 0 or now_unix - last_unix >= INTERVAL_S or now_unix < last_unix)


static func last_check(path: String) -> int:
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		return 0
	return int(cfg.get_value(STAMP_SECTION, "checked", 0))


static func save_check(path: String, now_unix: int) -> void:
	var cfg := ConfigFile.new()
	cfg.load(path)
	cfg.set_value(STAMP_SECTION, "checked", now_unix)
	cfg.save(path)


## The rows of a check answer with a downloaded version (the helper lists only those).
static func rows(check: Dictionary) -> Array:
	var out: Array = []
	var comps: Array = check.get("components", []) if check.get("components") is Array else []
	for r in comps:
		if r is Dictionary and str(r.get("installed", "")) not in ["", "<null>"]:
			out.append(r)
	return out


## "OptiScaler 0.9.4 → 0.9.5, OptiPatcher rolling-20261020 → rolling-20261108"
static func updates_line(check: Dictionary) -> String:
	var parts: Array[String] = []
	for r in rows(check):
		if bool(r.get("update", false)):
			parts.append("%s %s → %s" % [str(r.get("name", r.get("id", ""))), str(r.get("installed", "")), str(r.get("latest", ""))])
	return ", ".join(parts)


## "OptiScaler 0.9.4 · XeSS XMX driver 20261104"
static func installed_line(check: Dictionary) -> String:
	var parts: Array[String] = []
	for r in rows(check):
		parts.append("%s %s" % [str(r.get("name", r.get("id", ""))), str(r.get("installed", ""))])
	return " · ".join(parts)


## What the "Upscaler downloads" row shows for a check answer:
## {"reason": "" or why it can't be used, "help": the line under it, "update": bool}
static func summary(check: Dictionary) -> Dictionary:
	if check.is_empty() or not bool(check.get("ok", false)):
		var err := str(check.get("error", ""))
		return {"reason": "Couldn't read what's downloaded" + (": " + err if err != "" else ""), "help": "", "update": false}
	if rows(check).is_empty():
		return {"reason": "Nothing downloaded yet: the newest is fetched the first time a game uses it", "help": "", "update": false}
	var idx: Dictionary = check.get("index", {}) if check.get("index") is Dictionary else {}
	var source := "" if bool(idx.get("verified", false)) else " (GameCove's tested versions: the list of the newest isn't checked yet)"
	var ups := updates_line(check)
	if ups != "":
		return {"reason": "", "help": "Update available: %s. Games keep their copy until you update them on their page." % ups, "update": true}
	return {"reason": "", "help": "Up to date%s: %s. Press to check now." % [source, installed_line(check)], "update": false}


## The per-game row: {"reason", "help"} from the helper's status for the game.
static func game_summary(status: Dictionary) -> Dictionary:
	if not bool(status.get("ok", false)) or str(status.get("owner", "")) != "gamecove":
		return {"reason": "GameCove's OptiScaler isn't in this game", "help": ""}
	var have := str(status.get("opti_version", ""))
	var latest := str(status.get("opti_latest", ""))
	if not bool(status.get("game_update", false)):
		return {"reason": "This game's OptiScaler is up to date (%s)" % have, "help": ""}
	var what := ("OptiScaler %s → %s" % [have, latest]) if have != latest else ("OptiScaler %s with newer add-ons (OptiPatcher, fakenvapi)" % have)
	return {"reason": "", "help": "Update available: %s. Keeps this game's settings; Remove still puts the game back as it was." % what}
