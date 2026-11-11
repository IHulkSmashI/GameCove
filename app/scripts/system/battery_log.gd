extends Node
## Battery history and how much each game drains, from events that happen anyway: a game
## starts or ends, the handheld sleeps or wakes, the charger goes in or out. Nothing polls
## and no timer runs; each event costs a few sysfs reads and one small file write.
##
## user://battery_history.json:
##   {"v": 1, "samples": [[unix, percent, wh, event, game key], ...],   newest last, 30 days
##    "games": {key: {"title", "wh", "s", "n"}},                          battery used while playing
##    "open": {"key", "t", "pct", "wh"} | {}}                             a stretch on battery now
##                                                                        (never kept across a start: load_data)
## A stretch is time in a game on battery, awake: it opens at a game start (on battery), an
## unplug or a wake during a game, and closes at the game's end, a plug-in or a sleep; then
## its watt-hours and seconds add to the game. A sleep GameCove didn't start (power button)
## is only noticed at the wake: the stretch then closes at the last battery level Power
## reported before it (Power's battery_level, an event too).
##
## Energy: energy_now (µWh) or charge_now x voltage_min_design; when a battery reports
## neither, the percent of energy_full. Tests pass a fixture `sys_root` and a `clock`.

const DeviceScript := preload("res://scripts/device/device.gd")
const SettingsFile := preload("res://scripts/system/settings_file.gd")

const PATH := "user://battery_history.json"
const KEEP_S := 30 * 86400
const MAX_SAMPLES := 3000
## A game needs this much time on battery before its drain is shown (and a stretch this long to count).
const ENOUGH_S := 20 * 60
const MIN_STRETCH_S := 120
const EVENTS := ["start", "end", "suspend", "resume", "plug", "unplug"]

var path := PATH
var sys_root := ""
var clock: Callable = func() -> int: return int(Time.get_unix_time_from_system())
## Key of the game running now ("" when none): stretches open only during a game.
var game_key := ""
var game_title := ""
var data: Dictionary = {}
## The last levels Power reported, [[unix, percent], ...] newest last (for a sleep we only
## see at the wake: Power reports the level after the wake before it says it woke).
var _levels: Array = []
## func() -> unix time the device fell asleep (Power.slept_at), 0 when unknown.
var slept_at: Callable = func() -> int: return 0


func _init() -> void:
	load_data()


func load_data() -> void:
	var j: Variant = SettingsFile.load_json(path).get("data")
	data = j if j is Dictionary and int(j.get("v", 0)) == 1 else {}
	if not data.get("samples") is Array:
		data["samples"] = []
	if not data.get("games") is Dictionary:
		data["games"] = {}
	# A stretch only lives while this run follows a game. One still open in the
	# file was left by a crash or a power loss (no "end" was ever written): the
	# next plug-in or game end would add everything since, hours or days of
	# standby, to that game. It's dropped here; what it had used is unknown.
	data["open"] = {}
	data["v"] = 1


## Follows Power's events (charger, wake, level) when it has them.
func attach_power(power: Object) -> void:
	if power == null:
		return
	if power.has_signal("source_changed"):
		power.source_changed.connect(func(plugged: bool): record("plug" if plugged else "unplug"))
	if power.has_signal("resumed"):
		power.resumed.connect(func(): record("resume"))
	if power.has_signal("battery_level"):
		power.battery_level.connect(func(pct: int, _p: bool): note_level(pct))
	if "slept_at" in power:
		slept_at = func() -> int: return int(power.slept_at)


## Follows a GameSession's start and end.
func attach_session(session: Object) -> void:
	if session == null:
		return
	session.started.connect(func(g: Dictionary): game_started(g))
	session.ended.connect(func(g: Dictionary): game_ended(g))


func game_started(g: Dictionary) -> void:
	game_key = str(g.get("key", ""))
	game_title = str(g.get("title", ""))
	if str(g.get("store", "")) == "stream":
		game_key = ""   # a stream's drain is the decoder's, not the game's
	record("start")


func game_ended(_g: Dictionary) -> void:
	record("end")
	game_key = ""
	game_title = ""


func note_level(pct: int) -> void:
	_levels.append([int(clock.call()), pct])
	if _levels.size() > 6:
		_levels.pop_front()


## The newest level reported at or before `t` and after `after`: [unix, percent], or [].
func _level_before(t: int, after: int) -> Array:
	for i in range(_levels.size() - 1, -1, -1):
		var l: Array = _levels[i]
		if int(l[0]) <= t and int(l[0]) > after:
			return l
	return []


## {"pct", "wh", "full_wh", "plugged"} now: -1 where the battery doesn't say.
func read() -> Dictionary:
	var out := {"pct": -1, "wh": -1.0, "full_wh": -1.0, "plugged": DeviceScript.ac_online(sys_root)}
	var bat := battery_dir(sys_root)
	if bat == "":
		return out
	var cap := DeviceScript.read_text(bat + "capacity")
	if cap.is_valid_int():
		out["pct"] = cap.to_int()
	out["wh"] = _energy(bat, "now")
	out["full_wh"] = _energy(bat, "full")
	if float(out["wh"]) < 0.0 and float(out["full_wh"]) > 0.0 and int(out["pct"]) >= 0:
		out["wh"] = float(out["full_wh"]) * int(out["pct"]) / 100.0
	return out


static func battery_dir(root: String) -> String:
	var base := root + "/sys/class/power_supply/"
	var dir := DirAccess.open(base)
	if dir == null:
		return ""
	var names := Array(dir.get_directories()) + Array(dir.get_files())
	names.sort()
	for n in names:
		if DeviceScript.read_text(base + n + "/type") == "Battery":
			return base + n + "/"
	return ""


static func _energy(bat: String, which: String) -> float:
	var e := DeviceScript.read_text(bat + "energy_" + which)
	if e.is_valid_int():
		return e.to_int() / 1e6
	var c := DeviceScript.read_text(bat + "charge_" + which)
	var v := DeviceScript.read_text(bat + "voltage_min_design")
	if c.is_valid_int() and v.is_valid_int():
		return c.to_int() * v.to_int() / 1e12
	return -1.0


## One event: a sample, and the stretch on battery opens or closes.
func record(event: String, now_read: Dictionary = {}) -> void:
	var b := now_read if not now_read.is_empty() else read()
	if int(b["pct"]) < 0:
		return   # no battery (a desktop): nothing to keep
	var now: int = clock.call()
	data["samples"].append([now, int(b["pct"]), snappedf(float(b["wh"]), 0.01), event, game_key])
	var open: Dictionary = data["open"]
	match event:
		"start", "unplug":
			if game_key != "" and not bool(b["plugged"]):
				_open(now, b)
		"resume":
			# a sleep we didn't see begin: close the stretch where the battery last reported
			if not open.is_empty():
				var asleep: int = slept_at.call()
				var lvl := _level_before(asleep if asleep > 0 else now, int(open["t"]))
				if not lvl.is_empty() and asleep > 0:
					var full := float(b["full_wh"])
					var wh := float(open["wh"]) - (int(open["pct"]) - int(lvl[1])) * full / 100.0 if full > 0.0 else -1.0
					_close({"pct": lvl[1], "wh": wh}, int(lvl[0]))
				data["open"] = {}
			if game_key != "" and not bool(b["plugged"]):
				_open(now, b)
		"end", "plug", "suspend":
			if not open.is_empty():
				_close(b, now)
	_prune(now)
	SettingsFile.save_json(path, data)


func _open(now: int, b: Dictionary) -> void:
	data["open"] = {"key": game_key, "title": game_title, "t": now, "pct": int(b["pct"]), "wh": float(b["wh"])}


## Adds the open stretch to its game when it's long enough and the battery went down.
func _close(b: Dictionary, now: int) -> void:
	var o: Dictionary = data["open"]
	data["open"] = {}
	var secs := now - int(o["t"])
	var used := float(o["wh"]) - float(b["wh"])
	if secs < MIN_STRETCH_S or float(o["wh"]) < 0.0 or float(b["wh"]) < 0.0 or used < 0.0:
		return
	var g: Dictionary = data["games"].get(str(o["key"]), {"title": str(o.get("title", "")), "wh": 0.0, "s": 0, "n": 0})
	g["wh"] = snappedf(float(g["wh"]) + used, 0.01)
	g["s"] = int(g["s"]) + secs
	g["n"] = int(g["n"]) + 1
	if str(o.get("title", "")) != "":
		g["title"] = str(o["title"])
	data["games"][str(o["key"])] = g


func _prune(now: int) -> void:
	var s: Array = data["samples"]
	var cut := 0
	while cut < s.size() and (int(s[cut][0]) < now - KEEP_S or s.size() - cut > MAX_SAMPLES):
		cut += 1
	if cut > 0:
		data["samples"] = s.slice(cut)


# ---- what the UI shows -------------------------------------------------------------------------

## {"watts", "hours", "seconds"} for a game, or {} until it has ENOUGH_S on battery.
## hours: a full charge at that drain (energy_full / watts), -1 when unknown.
func drain_for(key: String, full_wh := -2.0) -> Dictionary:
	var g: Variant = data["games"].get(key)
	if not g is Dictionary or int(g["s"]) < ENOUGH_S or float(g["wh"]) <= 0.0:
		return {}
	var watts := float(g["wh"]) / (int(g["s"]) / 3600.0)
	var full := full_wh if full_wh > -2.0 else float(read()["full_wh"])
	return {"watts": watts, "hours": full / watts if full > 0.0 and watts > 0.0 else -1.0, "seconds": int(g["s"])}


## Games with enough data, most drain first: [{"key", "title", "watts", "hours", "seconds"}].
func drain_table(full_wh := -2.0) -> Array:
	var full := full_wh if full_wh > -2.0 else float(read()["full_wh"])
	var out: Array = []
	for k in data["games"]:
		var d := drain_for(str(k), full)
		if not d.is_empty():
			d["key"] = str(k)
			d["title"] = str(data["games"][k].get("title", k))
			out.append(d)
	out.sort_custom(func(a, b): return float(a["watts"]) > float(b["watts"]))
	return out


## The last `days` days of samples: [[unix, percent, event], ...] oldest first.
func series(days := 7) -> Array:
	var since: int = int(clock.call()) - days * 86400
	var out: Array = []
	for s in data["samples"]:
		if int(s[0]) >= since:
			out.append([int(s[0]), int(s[1]), str(s[3])])
	return out
