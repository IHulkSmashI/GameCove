extends Node
## Per-game settings and the environment a game launches with (upscaler, frame
## generation, low latency) for this device's GPU and the game's Proton.
## Settings live in user:// as JSON. Nothing here writes outside user://.

const LaunchEnv := preload("res://scripts/launch/launch_env.gd")
const Proton := preload("res://scripts/launch/proton.gd")

const SETTINGS_PATH := "user://launch_settings.json"
const GOALS := ["battery", "balanced", "smooth"]
const UPSCALERS := ["auto", "off", "fsr", "xess"]
const MAX_FPS_LIMIT := 240
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

var _games := {}
var _measured := {}
var _loaded := false


func profile() -> Dictionary:
	if not device_profile.is_empty():
		return device_profile
	if is_inside_tree():
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
	var stored: Variant = _games.get(game_key, {})
	return sanitize(stored, base) if stored is Dictionary else base


func save_settings(game_key: String, settings: Dictionary) -> void:
	_load()
	_games[game_key] = sanitize(settings, settings_for(game_key))
	_write()


func reset_settings(game_key: String) -> void:
	_load()
	_games.erase(game_key)
	_write()


## Real frame rate measured last time (before frame generation). Frame generation is
## only offered from about 40 fps.
func record_base_fps(game_key: String, fps: int) -> void:
	_load()
	_measured[game_key] = clampi(fps, 0, 1000)
	_write()


func base_fps(game_key: String) -> int:
	_load()
	return int(_measured.get(game_key, -1))


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
	var p := profile()
	var device := {"gpu_family": str(p.get("gpu_family", "")), "xmx": bool(p.get("xmx", false))}
	var proton := proton_for(game)
	var facts := {
		"anticheat": has_anticheat(game),
		"base_fps": int(game.get("base_fps", base_fps(key))),
		"extra_env": game.get("extra_env", {}),
	}
	var plan := LaunchEnv.compose(settings_for(key), device, proton, host_facts(), facts, {"indicator": show_indicator})
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
		_measured = measured


## Written to a temp file first, then renamed, so a crash never leaves half a file.
func _write() -> bool:
	var data := JSON.stringify({"version": 1, "games": _games, "measured": _measured}, "\t", true)
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
