extends Node
## Per-game settings and the environment a game launches with (upscaler, frame
## generation, low latency) for this device's GPU and the game's Proton.
## Settings live in user:// as JSON. Nothing here writes outside user://.

const LaunchEnv := preload("res://scripts/launch/launch_env.gd")
const PerDevice := preload("res://scripts/device/per_device.gd")
const Proton := preload("res://scripts/launch/proton.gd")

const SETTINGS_PATH := "user://launch_settings.json"
const GOALS := ["battery", "balanced", "smooth"]
const UPSCALERS := ["auto", "off", "fsr", "xess"]
const MAX_FPS_LIMIT := 240
## Goals that run Auto TDP while the game plays. "smooth" keeps the user's full TDP.
const AUTO_TDP_GOALS := ["battery", "balanced"]
const LAYER_DIRS := ["/usr/share/vulkan/implicit_layer.d", "/etc/vulkan/implicit_layer.d"]
const XESS_ENV_CONF := ".config/environment.d/50-xess-xmx.conf"

## Overridable for tests: settings file, home folder, a fake root for /usr and /etc,
## and a device profile (otherwise the Device autoload's).
var settings_path := SETTINGS_PATH
var home := OS.get_environment("HOME")
var root_prefix := ""
var device_profile: Dictionary = {}
## Show the active upscaler on screen (Proton's FSR 4 watermark). For testing a game.
var show_indicator := false
## More environment for a game at launch, from other areas (perf controls: the
## MangoHud frame limiter, lsfg-vk profile, OptiScaler's DLL override). Each
## callable takes (game_key: String, game: Dictionary) and returns {NAME: value};
## their variables join ours like the user's extra_env (LaunchEnv.merge).
var env_hooks: Array[Callable] = []

var _games := {}
## Frame rates measured per device: {device id: {game key: fps}} (a game runs
## differently on a Claw and an Ally booting the same drive).
var _measured := {}
var _compat := {}
## Goal for games without their own settings ("" = the device default). Set by
## the installer's Auto TDP choice: "smooth" = Auto TDP off.
var _default_goal := ""
var _loaded := false


func _ready() -> void:
	# kept here: the per-game controls read settings_for() on the Controls worker,
	# which may not look up nodes in the tree
	if device_profile.is_empty():
		var d := get_node_or_null("/root/Device")
		if d != null and d.get("profile") is Dictionary:
			device_profile = d.get("profile")


func profile() -> Dictionary:
	if not device_profile.is_empty():
		return device_profile
	if is_inside_tree() and OS.get_thread_caller_id() == OS.get_main_thread_id():
		var d := get_node_or_null("/root/Device")
		if d != null:
			return d.get("profile")
	return {}


## Starting settings for a game on this device. A devices.json row may carry
## "launch_defaults" to override them.
static func defaults_for(device: Dictionary) -> Dictionary:
	var d := {"goal": "balanced", "fps_limit": 0, "upscaler": "auto", "frame_gen": false, "low_latency": true}
	# Older, weaker chips: battery first.
	if device.get("gpu_family", "") in ["amd-rdna2", "intel-xe-lpg"]:
		d["goal"] = "battery"
	var custom: Variant = device.get("launch_defaults", {})
	if custom is Dictionary:
		d = sanitize(custom, d)
	return d


## Only known keys with valid values survive; anything else falls back to `base`.
static func sanitize(raw: Dictionary, base: Dictionary) -> Dictionary:
	var out := base.duplicate()
	var goal: Variant = raw.get("goal")
	if goal is String and goal in GOALS:
		out["goal"] = goal
	var up: Variant = raw.get("upscaler")
	if up is String and up in UPSCALERS:
		out["upscaler"] = up
	var fps: Variant = raw.get("fps_limit")
	if (fps is int or fps is float) and fps >= 0 and fps <= MAX_FPS_LIMIT:
		out["fps_limit"] = int(fps)
	for k in ["frame_gen", "low_latency"]:
		var v: Variant = raw.get(k)
		if v is bool:
			out[k] = v
	return out


## Per-game settings shape fixed by docs/CONTRACTS.md.
func settings_for(game_key: String) -> Dictionary:
	_load()
	var base := defaults_for(profile())
	if _default_goal != "":
		base["goal"] = _default_goal
	var stored: Variant = _games.get(game_key, {})
	return sanitize(stored, base) if stored is Dictionary else base


## Goal for every game without its own settings; "" goes back to the device default.
func set_default_goal(goal: String) -> bool:
	if goal != "" and not goal in GOALS:
		return false
	_load()
	_default_goal = goal
	return _write()


func default_goal() -> String:
	_load()
	return _default_goal


## Whether this game's goal turns Auto TDP on while it runs.
func auto_tdp_for(game_key: String) -> bool:
	return settings_for(game_key)["goal"] in AUTO_TDP_GOALS


func save_settings(game_key: String, settings: Dictionary) -> void:
	_load()
	_games[game_key] = sanitize(settings, settings_for(game_key))
	_write()


func reset_settings(game_key: String) -> void:
	_load()
	_games.erase(game_key)
	_write()


## Compatibility settings for a game GameCove starts itself (Epic, GOG, Amazon):
## {"proton": tool id ("" = umu's default), "prefix": Wine prefix ("" = the
## store's), "extra_env": {NAME: value}, "args": extra game arguments}.
## Steam games keep theirs in Steam (Library.set_compat_tool / set_launch_options).
func compat_for(game_key: String) -> Dictionary:
	_load()
	var stored: Variant = _compat.get(game_key, {})
	return sanitize_compat(stored if stored is Dictionary else {})


func save_compat(game_key: String, compat: Dictionary) -> void:
	_load()
	var c := sanitize_compat(compat)
	if c == sanitize_compat({}):
		_compat.erase(game_key)
	else:
		_compat[game_key] = c
	_write()


static func sanitize_compat(raw: Dictionary) -> Dictionary:
	var out := {"proton": "", "prefix": "", "extra_env": {}, "args": ""}
	var p: Variant = raw.get("proton")
	if p is String and p.length() <= 256 and not "\n" in p:
		out["proton"] = p
	var pre: Variant = raw.get("prefix")
	if pre is String and (pre == "" or pre.is_absolute_path()) and not "\n" in pre:
		out["prefix"] = pre
	var a: Variant = raw.get("args")
	if a is String and a.length() <= 2048 and not "\n" in a:
		out["args"] = a
	var env: Variant = raw.get("extra_env")
	if env is Dictionary:
		var name := RegEx.create_from_string("^[A-Za-z_][A-Za-z0-9_]*$")
		for k in env:
			var v := str(env[k])
			if k is String and name.search(k) != null and not "\n" in v:
				out["extra_env"][k] = v
	return out


## Proton builds a non-Steam game can run with, through umu-run's PROTONPATH:
## [{"id", "name", "path"}]. "" is umu's default (UMU-Proton); "GE-Proton" makes
## umu fetch and use the latest GE-Proton; the rest are installed builds
## (compatibilitytools.d, system folders, and Valve's Proton from Steam).
func compat_tools() -> Array[Dictionary]:
	var out: Array[Dictionary] = [
		{"id": "", "name": "Default (UMU-Proton)", "path": ""},
		{"id": "GE-Proton", "name": "GE-Proton, latest (downloaded by umu)", "path": "GE-Proton"},
	]
	var steam := Proton.steam_root(home) if home != "" else ""
	var tools := Proton.tools(Proton.tool_dirs(steam, root_prefix))
	var ids := tools.keys()
	ids.sort()
	for id in ids:
		out.append({"id": str(id), "name": str(tools[id]["display_name"]), "path": str(tools[id]["dir"])})
	if steam != "":
		var common := DirAccess.open(steam.path_join("steamapps/common"))
		if common != null:
			for d in common.get_directories():
				if d.begins_with("Proton") and FileAccess.file_exists(steam.path_join("steamapps/common").path_join(d).path_join("proton")):
					out.append({"id": d, "name": d, "path": steam.path_join("steamapps/common").path_join(d)})
	return out


## PROTONPATH for a tool id from compat_tools(), or "" for umu's default.
func proton_path_for(tool_id: String) -> String:
	if tool_id == "":
		return ""
	for t in compat_tools():
		if t["id"] == tool_id:
			return t["path"]
	return ""


## Real frame rate measured last time (before frame generation). Frame generation is
## only offered from about 40 fps. No caller yet: nothing in the app reads a game's
## frame rate (mangoapp / MangoHud log or the XeLL shim, see autotune.gd); until
## then base_fps() is -1 and frame generation is always offered.
func record_base_fps(game_key: String, fps: int) -> void:
	_load()
	var mine: Dictionary = _measured.get(device_key(), {})
	mine[game_key] = clampi(fps, 0, 1000)
	_measured[device_key()] = mine
	_write()


func base_fps(game_key: String) -> int:
	_load()
	return int((_measured.get(device_key(), {}) as Dictionary).get(game_key, -1))


func device_key() -> String:
	return PerDevice.key(str(profile().get("id", "unknown")))


func frame_gen_available(game_key: String) -> bool:
	var b := base_fps(game_key)
	return b < 0 or b >= LaunchEnv.FRAME_GEN_MIN_BASE_FPS


## Environment variables to add when launching this game on this device.
func launch_env(game: Dictionary) -> Dictionary:
	return launch_plan(game)["env"]


## Everything behind launch_env: {"env", "upscaler", "frame_gen", "low_latency",
## "conflicts", "notes", "proton"}. The UI shows conflicts and notes.
func launch_plan(game: Dictionary) -> Dictionary:
	var key := str(game.get("key", "%s:%s" % [game.get("store", ""), game.get("id", "")]))
	if str(game.get("store", "")) != "steam":
		var compat := compat_for(key)
		if compat["proton"] != "" or not compat["extra_env"].is_empty():
			game = game.duplicate()
			if compat["proton"] != "":
				game["proton"] = compat["proton"]
			var extra: Dictionary = (game.get("extra_env", {}) as Dictionary).duplicate()
			extra.merge(compat["extra_env"], true)
			game["extra_env"] = extra
	var p := profile()
	var device := {"gpu_family": str(p.get("gpu_family", "")), "xmx": bool(p.get("xmx", false))}
	var proton := proton_for(game)
	var facts := {
		"anticheat": has_anticheat(game),
		"base_fps": int(game.get("base_fps", base_fps(key))),
		"extra_env": game.get("extra_env", {}),
	}
	var plan := LaunchEnv.compose(settings_for(key), device, proton, host_facts(), facts, {"indicator": show_indicator})
	for hook in env_hooks:
		if hook.is_valid():
			var more: Variant = hook.call(key, game)
			if more is Dictionary and not more.is_empty():
				plan["env"] = LaunchEnv.merge(plan["env"], more)
	plan["proton"] = proton
	return plan


func proton_for(game: Dictionary) -> Dictionary:
	var steam := Proton.steam_root(home) if home != "" else ""
	return Proton.for_game(game, steam, Proton.tool_dirs(steam, root_prefix))


static func has_anticheat(game: Dictionary) -> bool:
	var info: Variant = game.get("info", {})
	if not (info is Dictionary):
		return false
	var ac: Variant = info.get("anticheat")
	return ac is Dictionary and not (ac.get("anticheats", []) as Array).is_empty()


## What is installed on this system that the environment depends on.
func host_facts() -> Dictionary:
	return {"xess_xmx": xess_xmx_installed(), "low_latency_layer": low_latency_layer_installed()}


## xess-xmx-linux's install.sh points VK_DRIVER_FILES at its run/intel_icd.json.
func xess_xmx_installed() -> bool:
	if home == "":
		return false
	var path := home.path_join(XESS_ENV_CONF)
	if not FileAccess.file_exists(path):
		return false
	var text := FileAccess.get_file_as_string(path)
	return "VK_DRIVER_FILES" in text and "/run/intel_icd.json" in text


## low_latency_layer installed system-wide or for this user as a Vulkan implicit layer.
func low_latency_layer_installed() -> bool:
	var dirs: Array[String] = []
	for d in LAYER_DIRS:
		dirs.append(root_prefix + d)
	if home != "":
		dirs.append(home.path_join(".local/share/vulkan/implicit_layer.d"))
	for d in dirs:
		var dir := DirAccess.open(d)
		if dir == null:
			continue
		for f in dir.get_files():
			if not f.ends_with(".json"):
				continue
			if "low_latency" in f.to_lower() or "LOW_LATENCY_LAYER" in FileAccess.get_file_as_string(d.path_join(f)):
				return true
	return false


func _load() -> void:
	if _loaded:
		return
	_loaded = true
	_games = {}
	_measured = {}
	_compat = {}
	_default_goal = ""
	if not FileAccess.file_exists(settings_path):
		return
	var json := JSON.new()
	var parsed: Variant = null
	if json.parse(FileAccess.get_file_as_string(settings_path)) == OK:
		parsed = json.data
	if not (parsed is Dictionary):
		push_warning("Launcher: %s is not valid JSON; starting fresh" % settings_path)
		return
	var games: Variant = parsed.get("games", {})
	if games is Dictionary:
		_games = games
	var measured: Variant = parsed.get("measured", {})
	if measured is Dictionary:
		for k in measured:
			if measured[k] is Dictionary:
				_measured[k] = measured[k]
			elif measured[k] is float or measured[k] is int:
				# saved before per-device frame rates: this device's
				var mine: Dictionary = _measured.get(device_key(), {})
				mine[k] = int(measured[k])
				_measured[device_key()] = mine
	var compat: Variant = parsed.get("compat", {})
	if compat is Dictionary:
		_compat = compat
	var dg: Variant = parsed.get("default_goal", "")
	if dg is String and dg in GOALS:
		_default_goal = dg


## Written to a temp file first, then renamed, so a crash never leaves half a file.
func _write() -> bool:
	var all := {"version": 1, "games": _games, "measured": _measured, "compat": _compat}
	if _default_goal != "":
		all["default_goal"] = _default_goal
	var data := JSON.stringify(all, "\t", true)
	var tmp := settings_path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_warning("Launcher: cannot write %s" % tmp)
		return false
	f.store_string(data)
	f.close()
	var err := DirAccess.rename_absolute(ProjectSettings.globalize_path(tmp), ProjectSettings.globalize_path(settings_path))
	return err == OK


## Forget what's in memory; the next call reads the file again.
func reload() -> void:
	_loaded = false
