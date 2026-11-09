extends RefCounted
## Client for Handheld Daemon (hhd, github.com/hhd-dev/hhd, GPL-3.0/LGPL) and
## its TDP plugin (adjustor). Bazzite ships InputPlumber + PowerStation on
## handhelds today (bazzite-hardware-setup, late 2026) and no longer ships hhd,
## but people still install it (it replaces InputPlumber), so Controller and
## Power support both. Names from hhd src/hhd/http/api.py and __main__.py,
## adjustor src/adjustor/drivers/*, docs/http.md:
##
##   GET  /api/v1/version            {"version": 5}
##   GET  /api/v1/state              every setting's current value, nested:
##        {"controllers": {"rog_ally": {"imu": true, "controller_mode": {"mode": "dualsense",
##          "dualsense": {"paddles_as": "steam_input"}}, "limits": {"mode": "default"}}},
##         "rgb": {"handheld": {"mode": {"mode": "solid", "solid": {"hue": 30, ...}}}},
##         "tdp": {"asus": {"tdp_v2": {"mode": "custom", "custom": {"tdp": 15}}}},
##         "hhd": {"settings": {"tdp_enable": true}, "http": {...}}, "info": {...}}
##   POST /api/v1/state              the same shape, only the keys to change; answers
##                                   with the whole state once hhd applied it
##   Auth: "Authorization: Bearer <token>" when hhd.http.token is on. The token is in
##   /tmp/hhd/token (0644, written at start), /etc/hhd/.token (0644) or, on older
##   versions, ~/.config/hhd/token.
##
## Every request runs on the caller's worker thread (transport blocks).

const Http := preload("res://scripts/input/hhd_http.gd")

## Where the TDP lives per adjustor driver. "mode": the mode switch that must say
## "custom" for "value" to be the TDP; none for the SMU driver's QAM slider.
const TDP_PATHS: Array[Dictionary] = [
	{"driver": "asus", "mode": ["tdp", "asus", "tdp_v2", "mode"], "value": ["tdp", "asus", "tdp_v2", "custom", "tdp"]},
	{"driver": "lenovo", "mode": ["tdp", "lenovo", "tdp", "mode"], "value": ["tdp", "lenovo", "tdp", "custom", "tdp"]},
	{"driver": "msi", "mode": ["tdp", "msi", "tdp", "mode"], "value": ["tdp", "msi", "tdp", "custom", "tdp"]},
	{"driver": "smu", "mode": [], "value": ["tdp", "qam", "tdp"]},
]
## hhd's controller output modes that have a paddles_as option, and what each
## paddles_as value means (outputs.yml).
const PADDLE_MODES := ["steam_input", "noob", "touchpad", "both", "disabled"]

var transport: RefCounted = Http.new()
var home := OS.get_environment("HOME")
## Filesystem prefix for the token files (tests).
var root := ""


func token_files() -> Array[String]:
	return [root + "/tmp/hhd/token", root + "/etc/hhd/.token", home.path_join(".config/hhd/token")]


func token() -> String:
	for f in token_files():
		if FileAccess.file_exists(f):
			var t := FileAccess.get_file_as_string(f).strip_edges()
			if t != "":
				return t
	return ""


func _headers() -> PackedStringArray:
	var t := token()
	return PackedStringArray(["Authorization: Bearer " + t]) if t != "" else PackedStringArray()


## API version, 0 when hhd doesn't answer (not installed, stopped, or the API off).
func version() -> int:
	var r: Dictionary = transport.request("GET", "/api/v1/version", _headers())
	if int(r.get("code", 0)) != 200:
		return 0
	var v: Variant = JSON.parse_string(str(r.get("body", "")))
	return int(v.get("version", 0)) if v is Dictionary else 0


## The whole state, or null.
func get_state() -> Variant:
	return _json(transport.request("GET", "/api/v1/state", _headers()))


## Sends the keys to change; returns the state after hhd applied them, or null.
func set_state(partial: Dictionary) -> Variant:
	return _json(transport.request("POST", "/api/v1/state", _headers(), JSON.stringify(partial)))


static func _json(r: Dictionary) -> Variant:
	if int(r.get("code", 0)) != 200:
		return null
	var v: Variant = JSON.parse_string(str(r.get("body", "")))
	return v if v is Dictionary else null


# ---- reading the state ----------------------------------------------------------

static func dig(d: Variant, path: Array) -> Variant:
	var cur: Variant = d
	for k in path:
		if not (cur is Dictionary) or not cur.has(k):
			return null
		cur = cur[k]
	return cur


## {"a": {"b": value}} for path ["a", "b"].
static func nest(path: Array, value: Variant) -> Dictionary:
	var out: Variant = value
	for i in range(path.size() - 1, -1, -1):
		out = {path[i]: out}
	return out


## The device's controller section name ("rog_ally", "legion_gos", "claw"...), "" when none.
static func controller_key(state: Variant) -> String:
	var c: Variant = dig(state, ["controllers"])
	if not (c is Dictionary):
		return ""
	var keys: Array = c.keys()
	keys.sort()
	for k in keys:
		if c[k] is Dictionary:
			return str(k)
	return ""


## Name of the motion on/off switch in the controller section ("imu" on the Ally,
## Legion Go S and Claw, "gyro" on the Legion Go), "" when none.
static func gyro_key(section: Dictionary) -> String:
	for k in ["imu", "gyro"]:
		if section.get(k) is bool:
			return k
	return ""


## Where paddles_as is for the current output mode: {"path": [...], "value": String,
## "modes": [...]}, {} when the current mode has none (Xbox Elite, hidden...).
static func paddle_info(section_key: String, section: Dictionary) -> Dictionary:
	for mk in ["controller_mode", "xinput"]:
		var m: Variant = section.get(mk)
		if not (m is Dictionary) or not (m.get("mode") is String):
			continue
		var cur: String = m["mode"]
		var sub: Variant = m.get(cur)
		if sub is Dictionary and sub.get("paddles_as") is String:
			return {"path": ["controllers", section_key, mk, cur, "paddles_as"], "value": sub["paddles_as"],
				"modes": PADDLE_MODES.duplicate()}
	return {}


## Vibration: hhd's "Deadzones & Vibration" (limits) in manual mode has an intensity.
static func has_rumble(section: Dictionary) -> bool:
	var l: Variant = section.get("limits")
	return l is Dictionary and l.get("mode") is String


## Vibration on (true) / off (false), or null when hhd uses its defaults (on).
static func rumble_on(section: Dictionary) -> Variant:
	var l: Variant = section.get("limits")
	if not (l is Dictionary) or str(l.get("mode", "")) != "manual":
		return null
	var v: Variant = dig(l, ["manual", "vibration"])
	return null if v == null else int(v) > 0


## What a per-game profile keeps of hhd's state: the controller section and the
## LEDs (never TDP, the HTTP settings or hhd's own options).
static func game_slice(state: Variant) -> Dictionary:
	var out := {}
	var key := controller_key(state)
	if key != "":
		out["controllers"] = {key: (dig(state, ["controllers", key]) as Dictionary).duplicate(true)}
	var rgb: Variant = dig(state, ["rgb", "handheld", "mode"])
	if rgb is Dictionary:
		out["rgb"] = {"handheld": {"mode": rgb.duplicate(true)}}
	return out


static func has_rgb(state: Variant) -> bool:
	return dig(state, ["rgb", "handheld", "mode"]) is Dictionary


## hhd's solid color: hue 0-360, saturation and brightness 0-100.
static func solid_rgb(color: Color, brightness: float) -> Dictionary:
	return {"mode": "solid", "solid": {
		"hue": int(roundf(color.h * 360.0)) % 361,
		"saturation": int(roundf(clampf(color.s, 0.0, 1.0) * 100.0)),
		"brightness": int(roundf(clampf(brightness, 0.0, 1.0) * 100.0)),
	}}


## What hhd can do here for the controller page.
static func capabilities(state: Variant) -> Dictionary:
	var key := controller_key(state)
	var section: Dictionary = dig(state, ["controllers", key]) if key != "" else {}
	return {
		# Guide/QAM reach GameCove as the virtual pad's Guide (our UI focused) and
		# as hhd's Steam shortcuts Ctrl+1 / Ctrl+2 (see controller.gd).
		"guide_qam": key != "",
		"intercept": false,
		"paddles": "mode" if not paddle_info(key, section).is_empty() else "",
		"gyro": gyro_key(section) != "",
		"rumble": has_rumble(section),
		"rgb": has_rgb(state),
		"per_game": key != "",
	}


## TDP as adjustor holds it: {"enabled": hhd manages TDP, "driver", "value": watts
## (-1 unknown), "mode": the driver's current mode ("" when it has none),
## "value_path", "mode_path"}; {} when hhd has no TDP section.
static func tdp_info(state: Variant) -> Dictionary:
	var enabled: bool = dig(state, ["hhd", "settings", "tdp_enable"]) == true
	for t in TDP_PATHS:
		var mode_path: Array = t["mode"]
		var value: Variant = dig(state, t["value"])
		var mode: Variant = dig(state, mode_path) if not mode_path.is_empty() else null
		if value == null and mode == null:
			continue
		var w := -1.0
		if value != null and (mode_path.is_empty() or str(mode) == "custom"):
			w = float(value)
		return {"enabled": enabled, "driver": t["driver"], "value": w, "mode": str(mode) if mode != null else "",
			"value_path": t["value"], "mode_path": mode_path}
	return {}


## The POST body that sets the TDP to `watts` (switching the driver to custom).
static func tdp_patch(info: Dictionary, watts: int) -> Dictionary:
	var out := nest(info["value_path"], watts)
	var mp: Array = info.get("mode_path", [])
	if not mp.is_empty():
		var mode_node: Dictionary = dig(out, mp.slice(0, mp.size() - 1))
		mode_node["mode"] = "custom"
	return out
