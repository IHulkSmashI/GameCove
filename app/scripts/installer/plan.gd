extends RefCounted
## The installer's state machine: which steps show in which mode, where Next,
## Back and Skip go, the choices with their defaults, and the summary. No I/O;
## the screen drives it and the service carries it out.
##
## Modes and their steps:
##   easy       welcome, art, summary, progress, done         (recommended defaults)
##   custom     welcome, startup, steam, stores, device, look, art, extras, summary, progress, done
##   maintenance  maintenance                                 (already installed: pick below)
##   change     maintenance, startup … art, extras, summary, progress, done
## "art" is the Game art step (the user's own SteamGridDB key): shown in Easy
## mode too, since GameCove ships no key; skippable ("Steam art only").
##   repair / update  maintenance, progress, done
##   uninstall  maintenance, uninstall, progress, done
##   finish     finish, progress, done                       (after a reboot: fixes left to install)
## A step opened from the summary (edit) goes back to the summary on Next or Back.

const Themes := preload("res://theme/themes.gd")
const Traits := preload("res://scripts/device/traits.gd")

const OPTION_STEPS: Array[String] = ["startup", "steam", "stores", "device", "look", "art", "extras"]
const STEPS := {
	"easy": ["welcome", "art", "summary", "progress", "done"],
	"custom": ["welcome", "startup", "steam", "stores", "device", "look", "art", "extras", "summary", "progress", "done"],
	"maintenance": ["maintenance"],
	"change": ["maintenance", "startup", "steam", "stores", "device", "look", "art", "extras", "summary", "progress", "done"],
	"repair": ["maintenance", "progress", "done"],
	"update": ["maintenance", "progress", "done"],
	"uninstall": ["maintenance", "uninstall", "progress", "done"],
	"finish": ["finish", "progress", "done"],
}
## mode -> what the progress step runs (InstallerService.start action).
const ACTIONS := {"easy": "install", "custom": "install", "change": "change", "repair": "repair",
	"update": "update", "uninstall": "uninstall", "finish": "finish"}
const SKIPPABLE: Array[String] = ["stores", "device", "look", "art", "extras"]

const STARTUPS := ["gamecove", "steam", "desktop"]
const STEAM_MODES := ["silent", "gamepadui", "off"]
const PROFILES := ["battery", "balanced", "performance"]
const PROFILE_DEFAULT := "balanced"

var mode := "easy"
const PerDevice := preload("res://scripts/device/per_device.gd")

var step := "welcome"
var choices := {}
## Fixes devices.json suggests for this handheld (the only ones `fixes` may hold).
var suggested_fixes: Array = []
## Intel Arc with XMX cores (devices.json xmx): the XeSS XMX driver option is offered.
var xess_offered := false
var skipped := {}
## "summary" while a step was opened from the summary.
var return_to := ""
## Progress finished (ok or not); Back is closed from then on.
var ran := false


## Starts a plan: maintenance when GameCove is installed, finish when a reboot
## left fixes to install, else the welcome page in Easy mode.
static func start(target: Dictionary, device_row: Dictionary, prefs: Dictionary) -> RefCounted:
	var p: RefCounted = load("res://scripts/installer/plan.gd").new()
	p.suggested_fixes = auto_fixes_for(device_row)
	p.xess_offered = xess_capable(device_row)
	p.choices = defaults(target, device_row, prefs)
	var saved: Variant = target.get("state", {}).get("choices", {})
	if saved is Dictionary:
		for k in saved:
			p.set_choice(k, saved[k])
	var pending: Dictionary = target.get("pending", {})
	var left := str(pending.get("FIXES", ""))
	if left != "" and bool(target.get("installed", false)):
		p.mode = "finish"
		p.step = "finish"
		p.choices["fixes"] = Array(left.split(",", false)).filter(func(f): return f in p.suggested_fixes)
	elif bool(target.get("maintenance", false)):
		p.mode = "maintenance"
		p.step = "maintenance"
	var undone := undone_fixes(target, device_row)
	p.choices["fixes"] = (p.choices["fixes"] as Array).filter(func(f): return not f in undone)
	return p


## The fixes the installer applies here: the fix catalogue's "auto" selectors
## resolved on the row's traits (app/data/fixes.json), so every handheld with
## the shared part gets them; rows without traits (tests, old tables) use
## their "fixes" list.
static func auto_fixes_for(device_row: Dictionary) -> Array:
	if device_row.get("traits") is Dictionary:
		return Traits.auto_fixes(device_row)
	return (device_row.get("fixes", []) as Array).duplicate() if device_row.get("fixes", []) is Array else []


## Fixes the user undid on the Fixes page on this handheld (fixes.cfg): repair,
## change and finish leave them off; the Device step can still tick one again.
static func undone_fixes(target: Dictionary, device_row: Dictionary) -> Array:
	var per: Variant = target.get("fix_choices", {}).get(PerDevice.key(str(device_row.get("id", "unknown"))), {})
	var out: Array = []
	if per is Dictionary:
		for f in per:
			if str(per[f]) == "off":
				out.append(f)
	return out


## The XeSS XMX driver only helps Intel GPUs with XMX cores (Arc Xe2 / Xe3, Arrow Lake H).
static func xess_capable(device_row: Dictionary) -> bool:
	return bool(device_row.get("xmx", false)) and str(device_row.get("cpu_vendor", "")) == "intel"


## Recommended choices for this device and system.
static func defaults(target: Dictionary, device_row: Dictionary, prefs: Dictionary) -> Dictionary:
	var fixes: Array = auto_fixes_for(device_row)
	return {
		"startup": "gamecove" if bool(target.get("supported", false)) else "desktop",
		"steam_mode": "silent",
		"steam_control": false,
		"fixes": fixes.duplicate(),
		"auto_tdp": true,
		"power_profile": PROFILE_DEFAULT,
		"charge_limit": 100,
		"theme": str(prefs.get("theme", "cove")),
		"match_art": bool(prefs.get("match_art", true)),
		"reduce_motion": bool(prefs.get("reduce_motion", false)),
		"ggdeals_key": "",
		"steamgriddb_key": "",
		"steam_id": "",
		"country": "",
		"remove_fixes": true,
		"keep_settings": true,
		# only read when keep_settings is off: save backups go only when asked for by name (final review, high 9)
		"remove_save_backups": false,
		"xess_driver": false,
		"moonlight": false,
	}


func steps() -> Array:
	return STEPS.get(mode, STEPS["easy"])


func action() -> String:
	return ACTIONS.get(mode, "install")


## Easy / Custom from the welcome page; change / repair / update / uninstall
## from the maintenance page. Returns the step it lands on.
func set_mode(m: String) -> String:
	if not STEPS.has(m):
		return step
	mode = m
	return_to = ""
	if not step in steps():
		step = steps()[0]
	return step


func index() -> int:
	return steps().find(step)


func next() -> String:
	if return_to != "":
		step = return_to
		return_to = ""
		return step
	var s := steps()
	var i := s.find(step)
	if i >= 0 and i + 1 < s.size():
		step = s[i + 1]
	return step


func back() -> String:
	if ran and step in ["progress", "done"]:
		return step
	if return_to != "":
		step = return_to
		return_to = ""
		return step
	var s := steps()
	var i := s.find(step)
	if i > 0 and s[i - 1] != "progress":
		step = s[i - 1]
	return step


func can_skip() -> bool:
	return step in SKIPPABLE


## Skip this step: keep its defaults, except Device, which then installs no fixes.
func skip() -> bool:
	if not can_skip():
		return false
	skipped[step] = true
	if step == "device":
		choices["fixes"] = []
	next()
	return true


## Opens an option step from the summary; Next / Back come back to it.
func edit(s: String) -> bool:
	if not s in OPTION_STEPS:
		return false
	return_to = "summary"
	step = s
	skipped.erase(s)
	return true


## Sets one choice if the value is valid. Returns false otherwise.
func set_choice(key: String, value: Variant) -> bool:
	match key:
		"startup":
			if not str(value) in STARTUPS:
				return false
		"steam_mode":
			if not str(value) in STEAM_MODES:
				return false
		"power_profile":
			if not str(value) in PROFILES:
				return false
		"charge_limit":
			if not (value is int or value is float) or int(value) < 50 or int(value) > 100:
				return false
			value = int(value)
		"fixes":
			if not value is Array:
				return false
			value = (value as Array).filter(func(f): return f in suggested_fixes)
		"theme":
			if not Themes.has_theme(str(value)):
				return false
		"steam_control", "auto_tdp", "match_art", "reduce_motion", "remove_fixes", "keep_settings", "remove_save_backups", "moonlight":
			if not value is bool:
				return false
		"xess_driver":
			if not value is bool or (value and not xess_offered):
				return false
		"ggdeals_key", "steamgriddb_key", "steam_id", "country":
			value = str(value).strip_edges()
		_:
			return false
	choices[key] = value
	return true


func toggle_fix(fix: String, on: bool) -> void:
	var f: Array = choices.get("fixes", []).duplicate()
	if on and not fix in f and fix in suggested_fixes:
		f.append(fix)
	elif not on:
		f.erase(fix)
	choices["fixes"] = f


## [{"step", "key", "value"}] for the summary page, one per option step.
func summary() -> Array:
	return [
		{"step": "startup", "key": "startup", "value": choices["startup"]},
		{"step": "steam", "key": "steam_mode", "value": choices["steam_mode"]},
		{"step": "stores", "key": "stores", "value": "skipped" if skipped.has("stores") else ""},
		{"step": "device", "key": "fixes", "value": choices["fixes"]},
		{"step": "look", "key": "theme", "value": choices["theme"]},
		{"step": "art", "key": "steamgriddb_key", "value": "skipped" if skipped.has("art") and str(choices["steamgriddb_key"]) == "" else ("set" if str(choices["steamgriddb_key"]) != "" else "")},
		{"step": "extras", "key": "extras", "value": "skipped" if skipped.has("extras") else ""},
	]
