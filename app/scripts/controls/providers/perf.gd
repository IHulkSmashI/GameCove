extends RefCounted
## Performance controls (group "perf"): the performance overlay (MangoHud
## through the session's mangoapp), MangoHud's in-game frame limiter, lsfg-vk
## frame generation, upscaling per game (OptiScaler / XeSS / FSR through the
## gamecove-upscale helper ported from ClawDeck), low latency, the game's
## Proton, the Steam launch wrapper and Steam's shader pre-caching.
## Details, sources and what each writes: docs/CONTROLS.md "Performance".
##
## Game scope: per-game controls act on one game at a time (a Library
## game dictionary; kept in the context's GameScope, see set_game); set it with
## set_game(ctx, game) and call Controls.detect_all() after, so availability
## and values follow the game. Without a game they say "Open a game first".
##
## Services: ctx may carry "perf_monitor", "launcher", "library" (tests pass
## fakes); on the real system (sys_root "") the autoloads are used. Writes that
## must run on the main thread (Steam's settings through Library, the overlay
## through PerfMonitor) are deferred to it; hooks themselves run on Controls'
## worker.

const Ctl := preload("res://scripts/controls/control.gd")
const Store := preload("res://scripts/controls/perf/store.gd")
const Overlay := preload("res://scripts/controls/perf/overlay.gd")
const Lsfg := preload("res://scripts/controls/perf/lsfg.gd")
const Files := preload("res://scripts/controls/perf/launch_files.gd")
const Upscale := preload("res://scripts/controls/perf/upscale.gd")
const UpscaleUpdates := preload("res://scripts/controls/perf/upscale_updates.gd")
const Privacy := preload("res://scripts/system/privacy.gd")
const Proton := preload("res://scripts/launch/proton.gd")

const NO_GAME := "Open a game first"
## Low latency can't be turned off while frame generation is on: generated
## frames add a frame of lag, which Anti-Lag 2 / XeLL win back.
const LOW_LATENCY_WITH_FG := "On automatically with frame generation"
const LOW_LATENCY_HELP := "Leave on. Turn off only if a game stutters or won't start with it."
const MANGOHUD_LAYER_DIRS := ["/usr/share/vulkan/implicit_layer.d", "/etc/vulkan/implicit_layer.d",
	"/usr/local/share/vulkan/implicit_layer.d"]
const GpuCaps := preload("res://scripts/device/gpu_caps.gd")
const GameScope := preload("res://scripts/controls/game_scope.gd")
const STATUS_TTL_MS := 3000
const PLAN_TTL_MS := 15000
## The helper's check hashes the downloaded files (FSR 4 DLLs are ~100 MB): read again at most this often.
const CHECK_TTL_MS := 600000
const UPSCALE_STAMP := "user://upscalers.cfg"

var ctx: Dictionary = {}
var store: RefCounted
var perf: Object
var launcher: Object
var library: Object
var _status_cache := {}           # game key -> {"t": ms, "r": Dictionary}
var _plan_cache := {}             # game key -> {"t": ms, "r": Dictionary}
var _prepared := {}               # game keys set up ahead of their start this session
var _last_did := {}               # game key -> what prepare changed, for the mode row's help
var _running_key := ""            # the game running now (session_wiring through ctx["upscale_running"])
var _running_since := 0           # Time.get_ticks_msec() when it started
var _pending := {}                # game key -> {"verb", "extra"}: a change asked for while that game ran
## Helper commands that change the game's files: never while that game runs
## (its DLLs are loaded; review M7). They wait and run once it has quit.
const CHANGES_FILES := ["choose", "mode", "opt-in"]
var _check := {}                  # the helper's last "check" answer
var _check_t := -1
var _mutex := Mutex.new()


## Any thread. The game lives in the context's GameScope (game_scope.gd), not
## in keys of the context itself: the main thread changes it while the worker
## reads, and a Dictionary can't take a new key under a reader.
static func set_game(context: Dictionary, game: Dictionary) -> void:
	GameScope.ensure(context).swap(game)


func setup(c: Dictionary) -> void:
	ctx = c
	var real := str(c.get("sys_root", "")) == ""
	perf = c.get("perf_monitor", _autoload("PerfMonitor") if real else null)
	launcher = c.get("launcher", _autoload("Launcher") if real else null)
	library = c.get("library", _autoload("Library") if real else null)
	store = Store.new(str(c.get("perf_store_path", "")), str(_profile().get("id", "unknown")))
	c["prepare_installed"] = prepare_installed
	c["upscale_running"] = set_running_game
	if launcher != null and "env_hooks" in launcher:
		launcher.env_hooks.append(launch_env_hook)
	if launcher != null and "frame_gen_hooks" in launcher:
		launcher.frame_gen_hooks.append(frame_gen_on)
	if launcher != null and "native_hooks" in launcher:
		launcher.native_hooks.append(upscale_native)
	refresh_device_files()
	if real:
		_schedule_background_check(UpscaleUpdates.FIRST_DELAY_S)


func _autoload(name: String) -> Object:
	var tree := Engine.get_main_loop() as SceneTree
	return tree.root.get_node_or_null(name) if tree != null and tree.root != null else null


func _profile() -> Dictionary:
	var d: Variant = ctx.get("device")
	if d is Dictionary:
		return d
	if d is Object and "profile" in d and d.get("profile") is Dictionary:
		return d.get("profile")
	return {}


func _home() -> String:
	return str(ctx.get("home", ""))


func _root() -> String:
	return str(ctx.get("sys_root", ""))


func _gpu() -> Dictionary:
	var d: Variant = ctx.get("device")
	var dev: Variant = d.get("gpu") if d is Object and "gpu" in d else ctx.get("gpu_dev", {})
	return Upscale.gpu(_profile(), dev if dev is Dictionary else {})


## The app's own data says this game has anti-cheat (Are We Anti-Cheat Yet):
## the helper then refuses whatever the game's folder shows.
func _anticheat() -> bool:
	return launcher != null and launcher.has_method("has_anticheat") and bool(launcher.has_anticheat(game()))


func _ac_args() -> Array:
	return ["--anticheat"] if _anticheat() else []


# ---- the game ------------------------------------------------------------------

func game() -> Dictionary:
	var scope := GameScope.of(ctx)
	if scope != null:
		var sg: Dictionary = scope.game()
		if not sg.is_empty():
			return sg
	# a context filled by hand before any worker runs (tests, tools)
	var g: Variant = ctx.get("game")
	if g is Dictionary and not g.is_empty():
		return g
	var k := str(ctx.get("game_key", ""))
	if k == "" or not ":" in k:
		return {}
	return {"key": k, "store": k.get_slice(":", 0), "id": k.substr(k.find(":") + 1)}


func game_key() -> String:
	var g := game()
	if g.is_empty():
		return ""
	return str(g.get("key", "%s:%s" % [g.get("store", ""), g.get("id", "")]))


func _gv(key: String, fallback: Variant) -> Variant:
	var k := game_key()
	return store.get_value(k, key, fallback) if k != "" else fallback


func _sv(key: String, v: Variant) -> bool:
	var k := game_key()
	if k == "":
		return false
	var ok: bool = store.set_value(k, key, v)
	game_changed(k, game())
	return ok


## Runs on the main thread: now when we are on it, else deferred.
func _main(job: Callable) -> void:
	if OS.get_thread_caller_id() == OS.get_main_thread_id():
		job.call()
	else:
		job.call_deferred()


# ---- the controls --------------------------------------------------------------

func controls() -> Array:
	var out: Array = []
	out.append_array(_overlay_controls())
	out.append_array(_lsfg_controls())
	out.append_array(_upscale_controls())
	out.append_array(_launch_controls())
	out.append_array(_shader_controls())
	for c in out:
		_controls_by_id[c.id] = weakref(c)   # weak: the controls hold this provider (their hooks), not the other way
	return out


func _mk(spec: Dictionary, detect: Callable, read: Callable, write: Callable) -> RefCounted:
	var s := {"group": "perf"}
	s.merge(spec, true)
	return Ctl.make(s, func(_c): return detect.call(), func(_c): return read.call(), func(_c, v): return write.call(v))


## As _mk, for a detect that also rewrites the control's help line (it gets the control).
func _mkc(spec: Dictionary, detect: Callable, read: Callable, write: Callable) -> RefCounted:
	var s := {"group": "perf"}
	s.merge(spec, true)
	return Ctl.make(s, detect, func(_c): return read.call(), func(_c, v): return write.call(v))


func _opts(values: Array, labels: Dictionary = {}, helps: Dictionary = {}) -> Array:
	var out := []
	for v in values:
		var o := {"value": v, "label": str(labels.get(v, str(v).capitalize()))}
		if str(helps.get(v, "")) != "":
			o["help"] = str(helps[v])     # one plain line for this option (control_view shows it)
		out.append(o)
	return out


# ---- performance overlay (mangoapp) ---------------------------------------------

func _overlay_reason() -> String:
	if perf == null or not perf.has_method("overlay_supported"):
		return "Performance overlay isn't available"
	return "" if perf.overlay_supported() else "Needs gamescope's performance overlay (mangoapp)"


func _overlay_controls() -> Array:
	var out: Array = []
	out.append(_mk({"id": "perf.overlay", "title": "Performance overlay",
		"help": "What the overlay shows on top of games: frame rate only, a thin bar, the full stats, or your own pick.",
		"kind": "choice", "options": _opts(Overlay.PRESETS, {"fps": "Frame rate", "bar": "Horizontal bar"}),
		"default_value": "off", "per_game": true, "apply_order": 0},
		_overlay_reason,
		func(): return Overlay.preset_for(int(perf.overlay_level()), str(store.get_value(Store.GLOBAL, "overlay_preset", ""))),
		func(v):
			store.set_value(Store.GLOBAL, "overlay_preset", v)
			return _apply_overlay()))
	out.append(_mk({"id": "perf.overlay_position", "title": "Overlay position",
		"help": "Where on the screen the overlay sits.", "kind": "choice",
		"options": _opts(Overlay.POSITIONS), "default_value": "top-left", "per_game": false},
		_overlay_reason,
		func(): return str(store.get_value(Store.GLOBAL, "overlay_position", "top-left")),
		func(v):
			store.set_value(Store.GLOBAL, "overlay_position", v)
			return _apply_overlay()))
	out.append(_mk({"id": "perf.overlay_opacity", "title": "Overlay background",
		"help": "How see-through the overlay's background is (0 % is fully clear).", "kind": "slider",
		"min_value": 0.0, "max_value": 100.0, "step": 5.0, "unit": "%", "default_value": 50.0, "per_game": false},
		_overlay_reason,
		func(): return float(store.get_value(Store.GLOBAL, "overlay_opacity", 50.0)),
		func(v):
			store.set_value(Store.GLOBAL, "overlay_opacity", v)
			return _apply_overlay()))
	out.append(_mk({"id": "perf.overlay_scale", "title": "Overlay text size",
		"help": "Bigger text is easier to read on a small screen.", "kind": "slider",
		"min_value": 50.0, "max_value": 200.0, "step": 10.0, "unit": "%", "default_value": 100.0, "per_game": false},
		_overlay_reason,
		func(): return float(store.get_value(Store.GLOBAL, "overlay_scale", 100.0)),
		func(v):
			store.set_value(Store.GLOBAL, "overlay_scale", v)
			return _apply_overlay()))
	for item in Overlay.ITEMS:
		var id: String = item
		out.append(_mk({"id": "perf.overlay_item." + id, "title": Overlay.ITEM_TITLES[id],
			"help": "Shown when the overlay is set to Custom.", "kind": "toggle",
			"default_value": id in Overlay.DEFAULT_ITEMS, "per_game": false},
			_overlay_reason,
			func(): return id in _items(),
			func(v):
				var items := _items()
				if v and not id in items:
					items.append(id)
				elif not v:
					items.erase(id)
				store.set_value(Store.GLOBAL, "overlay_items", items)
				return _apply_overlay()))
	return out


func _items() -> Array:
	var v: Variant = store.get_value(Store.GLOBAL, "overlay_items", Overlay.DEFAULT_ITEMS.duplicate())
	return (v as Array).duplicate() if v is Array else Overlay.DEFAULT_ITEMS.duplicate()


## Writes the stored preset and look through PerfMonitor (main thread).
func _apply_overlay() -> bool:
	if _overlay_reason() != "":
		return false
	var preset := str(store.get_value(Store.GLOBAL, "overlay_preset", ""))
	if preset == "":
		preset = Overlay.preset_for(int(perf.overlay_level()), "")
	var override := Overlay.override_lines(preset, _items())
	var extra := Overlay.extra_lines(str(store.get_value(Store.GLOBAL, "overlay_position", "top-left")),
		float(store.get_value(Store.GLOBAL, "overlay_opacity", 50.0)), float(store.get_value(Store.GLOBAL, "overlay_scale", 100.0)))
	var level: int = Overlay.LEVEL.get(preset, 0)
	var p := perf
	_main(func():
		if p.has_method("set_overlay_style"):
			p.set_overlay_style(override, extra)
		p.set_overlay_level(level))
	return true


# ---- MangoHud's frame limiter (in the game) ----------------------------------------

## MangoHud's Vulkan layer (enabled per game with MANGOHUD=1).
func mangohud_layer() -> bool:
	var dirs: Array = []
	for d in MANGOHUD_LAYER_DIRS:
		dirs.append(_root() + d)
	if _home() != "":
		dirs.append(_home().path_join(".local/share/vulkan/implicit_layer.d"))
	for d in dirs:
		var dir := DirAccess.open(d)
		if dir == null:
			continue
		for f in dir.get_files():
			if f.to_lower().begins_with("mangohud") and f.ends_with(".json"):
				return true
	return false


## The frame limit has one owner: display.fps_limit (gamescope's limiter, applied
## live and per game through Profiles). MangoHud's in-game limiter stays as an
## internal helper, not a second Frame limit control: code that needs it for a
## game (fps 0 = off; method "late" = lowest latency, "early" = smoothest)
## calls this; env_for() then adds MANGOHUD_CONFIG at the next launch.
func set_mangohud_limit(key: String, fps: int, method := "late") -> bool:
	if key == "" or not mangohud_layer():
		return false
	var ok: bool = store.set_value(key, "fps_limit", fps if fps > 0 else null)
	ok = store.set_value(key, "fps_limit_method", "early" if method == "early" else "late") and ok
	game_changed(key, game() if key == game_key() else {})
	return ok


# ---- lsfg-vk frame generation -------------------------------------------------------

func _lsfg_dll() -> String:
	var root := Proton.steam_root(_home()) if _home() != "" else ""
	var libs := Lsfg.steam_libraries(root)
	return Lsfg.find_dll(libs) if Lsfg.app_state(libs, false) == "ready" else ""


func _lsfg_owned() -> bool:
	if library == null or not library.has_method("game_by_key"):
		return false
	var g: Variant = library.game_by_key("steam:" + Lsfg.APP_ID)
	return g is Dictionary and not g.is_empty()


## {"step", "line"}: what Lossless frame generation still needs here (Lsfg.next_step).
func lsfg_step() -> Dictionary:
	var root := Proton.steam_root(_home()) if _home() != "" else ""
	return Lsfg.next_step(Lsfg.layer(_root(), _home()), Lsfg.app_state(Lsfg.steam_libraries(root), _lsfg_owned()))


func _lsfg_reason() -> String:
	var step := lsfg_step()
	match str(step["step"]):
		"buy":
			return "Needs Lossless Scaling, a paid app on Steam"
		"install_app":
			return "Install Lossless Scaling in Steam first"
		"branch":
			return "Needs Lossless Scaling's lsfg-vk beta in Steam"
		"layer":
			return "Needs lsfg-vk: install it below"
		"layer_update":
			return "Update lsfg-vk to version 2 below"
	if game_key() == "":
		return NO_GAME
	if _anticheat() or _helper_says_anticheat():
		return "Off for this game: it uses anti-cheat"
	return ""


## The upscaling helper's look at the game (its folder's anti-cheat files, the
## lists' notes) says anti-cheat, also when the app's own data has no record
## (review H2: Lossless checked only the app's data). Cached with the plan.
func _helper_says_anticheat() -> bool:
	if _upscale_reason() != "":
		return false
	return str(upscale_plan().get("refused", "")) == "anticheat"


## Lossless on/off: never next to another frame generator. The game's own (or
## OptiScaler's) knows the game's motion and keeps the HUD clean, so it wins:
## Lossless can't be switched on while that one is on.
func _lsfg_toggle_reason() -> String:
	var why := _lsfg_reason()
	if why != "":
		return why
	if int(_gv("frame_gen", 0)) > 0:
		return "Off while this game's own frame generation is on: that one is sharper"
	return ""


func _open_uri(uri: String) -> bool:
	var open: Variant = ctx.get("open_uri")
	if open is Callable and (open as Callable).is_valid():
		return bool((open as Callable).call(uri))
	return false               # no opener given (tests): never the real desktop


## The setup row: one press does the next step (open the store page, start
## the install in Steam, or install lsfg-vk itself).
func _lsfg_setup_write() -> bool:
	match str(lsfg_step()["step"]):
		"buy":
			return _open_uri(Lsfg.STORE_URI)
		"install_app":
			return _open_uri(Lsfg.INSTALL_URI)
		"branch":
			return _open_uri("steam://gameproperties/" + Lsfg.APP_ID)
		"layer", "layer_update":
			var r := Upscale.run(ctx.get("runner"), upscale_cmd(), "lsfg-install", _home(), "", _gpu())
			if not bool(r.get("ok", false)):
				push_warning("lsfg-vk: %s" % str(r.get("error", "failed")))
				return false
			return write_lsfg_config()
	return true


func _lsfg_controls() -> Array:
	var d := Lsfg.defaults_for(GpuCaps.tier(_gpu()))
	return [
		_mk({"id": "perf.lsfg", "title": "Lossless Scaling frame generation",
			"help": "For games the upscaler above can't reach: older games, emulators, anything. Uses your own Lossless Scaling. Best above 40 real fps.",
			"kind": "toggle", "default_value": false, "affects": ["perf.low_latency", "perf.frame_gen"]},
			_lsfg_toggle_reason, func(): return bool(_gv("lsfg", false)),
			func(v):
				if bool(v) and int(_gv("frame_gen", 0)) > 0:
					return false
				return _lsfg_set("lsfg", v)),
		_mk({"id": "perf.lsfg_multiplier", "title": "Lossless multiplier",
			"help": "2x adds one frame per real frame; 3x and 4x add more (more lag, more artefacts).",
			"kind": "choice", "options": _opts(Lsfg.MULTIPLIERS, {2: "2x", 3: "3x", 4: "4x"}, Upscale.LSFG_HELP), "default_value": 2,
			"requires": ["perf.lsfg"]},
			_lsfg_reason, func(): return int(_gv("lsfg_multiplier", 2)), func(v): return _lsfg_set("lsfg_multiplier", v)),
		_mk({"id": "perf.lsfg_flow_scale", "title": "Flow scale",
			"help": "Lower is faster with a softer result; 80 % suits handheld screens, 60 % the slower chips.",
			"kind": "slider", "min_value": 0.25, "max_value": 1.0, "step": 0.05, "default_value": d["lsfg_flow_scale"],
			"requires": ["perf.lsfg"]},
			_lsfg_reason, func(): return float(_gv("lsfg_flow_scale", d["lsfg_flow_scale"])), func(v): return _lsfg_set("lsfg_flow_scale", v)),
		_mk({"id": "perf.lsfg_performance", "title": "Performance mode",
			"help": "A lighter frame generation model: faster, slightly lower quality.",
			"kind": "toggle", "default_value": d["lsfg_performance"], "requires": ["perf.lsfg"]},
			_lsfg_reason, func(): return bool(_gv("lsfg_performance", d["lsfg_performance"])), func(v): return _lsfg_set("lsfg_performance", v)),
		_mkc({"id": "perf.lsfg_setup", "title": "Set up Lossless frame generation",
			"help": "Does the next step for you.", "kind": "action", "per_game": false,
			"affects": ["perf.lsfg", "perf.lsfg_multiplier"]},
			func(c):
				var step := lsfg_step()
				if str(step["step"]) == "":
					return "Ready: nothing left to set up"
				if str(step["step"]) in ["layer", "layer_update"] and upscale_cmd() == "":
					return "Needs GameCove's upscaling helper"
				c.help = str(step["line"])
				return "",
			func(): return null, func(_v): return _lsfg_setup_write()),
	]


func _lsfg_set(key: String, v: Variant) -> bool:
	if not _sv(key, v):
		return false
	return write_lsfg_config()


## GameCove's profiles in lsfg-vk's config for every game with it on.
func write_lsfg_config() -> bool:
	if _home() == "" or Lsfg.layer(_root(), _home()) != "v2":
		return false
	var profiles := {}
	for k in store.games():
		var vals: Dictionary = store.values(k)
		if bool(vals.get("lsfg", false)):
			var merged := Lsfg.defaults_for(GpuCaps.tier(_gpu()))
			merged.merge(vals, true)
			profiles[k] = merged
	var path := _home().path_join(Lsfg.CONFIG)
	var existing := FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""
	if existing.strip_edges() != "" and not RegEx.create_from_string("(?m)^\\s*version\\s*=\\s*2\\b").search(existing):
		# a 1.x config: lsfg-vk 2 doesn't read it (decky-lsfg-vk discards it too); kept beside
		DirAccess.rename_absolute(path, path + ".v1.bak")
		existing = ""
	if profiles.is_empty() and existing == "":
		return true
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	# replaced in one rename, never rewritten in place: lsfg-vk reads it at every game start and
	# it holds the user's own profiles (review 2, low 23)
	return preload("res://scripts/system/settings_file.gd").save_text(path, Lsfg.merge_config(existing, profiles, _lsfg_dll())) == OK


# ---- upscaling per game (gamecove-upscale) -------------------------------------------

func upscale_cmd() -> String:
	return Upscale.command(_root(), ctx.get("upscale_paths", []))


func _upscale_reason() -> String:
	if _gpu()["vendor"] == "other":
		return "Unknown GPU: use the game's own settings"
	if upscale_cmd() == "":
		return "Needs GameCove's upscaling helper"
	var g := game()
	if g.is_empty():
		return NO_GAME
	if Files.steam_appid(game_key()) == "" and str(g.get("install_path", "")) == "":
		return "This game's folder isn't known"
	return ""


## Why the Upscaler and Frame generation rows wait (review H1): the helper's plan says to keep hands off this
## game until the player presses Add (an online game, with the ban warning; a game no list knows), or refuses it
## (anti-cheat, another tool's files). "" when the rows may be used. Picking a row anyway is refused by the helper
## itself (choose answers "optin"), so this is the explanation, not the guard.
func _optin_reason() -> String:
	var p := upscale_plan()
	if not bool(p.get("ok", false)):
		return ""
	var refused: Variant = p.get("refused")
	if refused != null and str(refused) == "anticheat":
		return "Off for this game: it uses anti-cheat"
	if refused != null:
		return ""
	var offer: Variant = p.get("offer")
	if (offer != null and str(offer) != "") or (bool(p.get("hands_off", false)) and str(p.get("need", "")) != ""):
		return "Online game: press Add first (an upscaler can get the account banned)" if str(p.get("need", "")) == "online" \
			else "We don't know this game yet: press Add first"
	return ""


func _upscale_run(verb: String, extra: Array = []) -> Dictionary:
	var k := game_key()
	if verb in CHANGES_FILES and is_running(k):
		# the game has these files loaded: the change waits until it has quit (flush_pending)
		_mutex.lock()
		_pending[k] = {"verb": verb, "extra": extra.duplicate()}
		var c: Dictionary = _status_cache.get(k, {})
		_mutex.unlock()
		var env: Variant = (c.get("r", {}) as Dictionary).get("env", {}) if not c.is_empty() else store.get_value(k, "upscale_env", {})
		return {"ok": true, "queued": true, "env": env if env is Dictionary else {}}
	return Upscale.run(ctx.get("runner"), upscale_cmd(), verb, _home(), k, _gpu(),
		str(game().get("install_path", "")), extra, Upscale.title_of(game()))


## Session wiring: `key` started ("" when the game ended). A change asked for
## while it ran is made at the next look at the game or its next start.
func set_running_game(key: String) -> void:
	_mutex.lock()
	_running_key = key
	_running_since = Time.get_ticks_msec()
	_mutex.unlock()


## While a game's process is only starting (Proton sets up its prefix for several
## seconds before the game loads its DLLs), the game's own settings from its
## profile are still put in as it starts; after that window, changes wait.
const LAUNCH_GRACE_MS := 6000


func is_running(key: String) -> bool:
	var grace := int(ctx.get("upscale_launch_grace_ms", LAUNCH_GRACE_MS))
	_mutex.lock()
	var r := key != "" and _running_key == key and Time.get_ticks_msec() - _running_since >= grace
	_mutex.unlock()
	return r


## The change that waited for the game to quit, made now. True when one ran.
func flush_pending(key: String) -> bool:
	_mutex.lock()
	var p: Dictionary = _pending.get(key, {})
	var waiting := not p.is_empty() and _running_key != key
	if waiting:
		_pending.erase(key)
	_mutex.unlock()
	if not waiting or key != game_key():
		if waiting:
			_mutex.lock()
			_pending[key] = p          # not the open game: kept until it is looked at
			_mutex.unlock()
		return false
	var r := _upscale_run(str(p["verb"]), p["extra"])
	_forget_status()
	if bool(r.get("ok", false)):
		var env: Variant = upscale_status().get("env", {})
		_sv("upscale_env", env if env is Dictionary and not env.is_empty() else null)
	return true


## The helper's status for the game, cached for a few seconds (one detect_all
## reads several controls).
func upscale_status() -> Dictionary:
	var k := game_key()
	flush_pending(k)
	_mutex.lock()
	var c: Dictionary = _status_cache.get(k, {})
	var waiting: Dictionary = _pending.get(k, {})
	_mutex.unlock()
	if not c.is_empty() and Time.get_ticks_msec() - int(c["t"]) < STATUS_TTL_MS:
		return _with_pending(c["r"], waiting)
	var r := _upscale_run("status")
	_mutex.lock()
	_status_cache[k] = {"t": Time.get_ticks_msec(), "r": r}
	var p: Dictionary = _pending.get(k, {})
	_mutex.unlock()
	return _with_pending(r, p)


## The status as it will be once the waiting change is made, so the rows show
## the pick (and say it waits for the game to quit).
static func _with_pending(r: Dictionary, p: Dictionary) -> Dictionary:
	if p.is_empty() or not bool(r.get("ok", false)):
		return r
	var out := r.duplicate()
	var x: Array = p.get("extra", [])
	var arg := func(name: String) -> String:
		var i := x.find(name)
		return str(x[i + 1]) if i >= 0 and i + 1 < x.size() else ""
	match str(p.get("verb", "")):
		"choose":
			out["upscaler"] = arg.call("--upscaler")
			out["fg"] = int(arg.call("--fg"))
			out["mode"] = "custom"
		"mode":
			out["mode"] = arg.call("--mode")
		"opt-in":
			out["mode"] = "best"
	var a: Dictionary = (out.get("active", {}) as Dictionary).duplicate() if out.get("active") is Dictionary else {}
	a["line"] = "Your change is made when you quit the game: its files are in use now."
	out["active"] = a
	out["pending"] = true
	return out


func _forget_status() -> void:
	_mutex.lock()
	_status_cache.erase(game_key())
	_plan_cache.erase(game_key())
	_mutex.unlock()


## After the helper changed the game: keep its environment for non-Steam launches
## and make sure a Steam game starts through the wrapper.
func _after_upscale(r: Dictionary, reread := false) -> bool:
	_forget_status()
	if not bool(r.get("ok", false)):
		push_warning("Upscaling: %s" % str(r.get("error", "failed")))
		return false
	var env: Variant = upscale_status().get("env", {}) if reread else r.get("env", {})
	_sv("upscale_env", env if env is Dictionary and not env.is_empty() else null)
	return true


## One press back to how the game shipped, or to our pick. "custom" is set by
## the helper itself when an upscaler or frame generation is picked by hand.
func _set_mode(mode: String) -> bool:
	if mode == "custom":
		return _after_upscale(_upscale_run("mode", ["--mode", "custom"]))
	var r := _upscale_run("mode", ["--mode", mode] + _ac_args())
	_prepared[game_key()] = true
	if mode == "native":
		_sv("frame_gen", 0)
	if bool(r.get("ok", false)):
		_sv("upscale_native", true if mode == "native" else null)
	return _after_upscale(r, true)


## Launcher.native_hooks: Native was picked for this game, so its launch swaps
## nothing (no Proton FSR 4 upgrade either). Any pick afterwards clears it.
func upscale_native(key: String) -> bool:
	return store != null and bool(store.get_value(key, "upscale_native", false))


## Sets the open game up ahead of its first start ("Best for this handheld"),
## once per game and session: the helper puts the plan in when that is safe,
## repairs what a game update removed and steps down when the last start showed
## the pick didn't come up. Worker thread (detect) or the launch itself.
func prepare_game(key := "") -> Dictionary:
	var k := key if key != "" else game_key()
	flush_pending(k)
	if k == "" or _prepared.has(k) or _upscale_reason() != "" or is_running(k):
		return {}
	_prepared[k] = true
	var r := _upscale_run("prepare", _ac_args() + _auto_net_args())
	if str(r.get("waiting", "")) != "":
		_last_did[k] = str(r["waiting"]).trim_suffix(".")
	if str(r.get("did", "")) != "":
		_forget_status()
		var st := upscale_status()
		var env: Variant = st.get("env", {})
		_sv("upscale_env", env if env is Dictionary and not env.is_empty() else null)
		_last_did[k] = str(r.get("did", ""))
	return r


## What GameCove runs by itself (prepare) may download only with "Background
## lookups" on (Settings > About; privacy.gd). Files that came with the install
## are still used; the player's own picks download as before.
func _auto_net_args() -> Array:
	return [] if Privacy.background_allowed(str(ctx.get("privacy_path", Privacy.PREFS_PATH))) else ["--no-download"]


## A game was just installed, updated or had its files checked (main's
## install_finished, on the Controls worker): set it up now, or put back what
## the update removed, so its first start already runs with the pick. Works for
## any game, not only the open one; `now` false (another game is running) only
## marks it, and the next look or start does the work.
func prepare_installed(g: Dictionary, now := true) -> Dictionary:
	var k := str(g.get("key", "%s:%s" % [g.get("store", ""), g.get("id", "")]))
	if k == "" or k == ":":
		return {}
	_prepared.erase(k)
	_mutex.lock()
	_status_cache.erase(k)
	_plan_cache.erase(k)
	_mutex.unlock()
	var dir := str(g.get("install_path", ""))
	if not now or upscale_cmd() == "" or _gpu()["vendor"] == "other" or (Files.steam_appid(k) == "" and dir == ""):
		return {}
	_prepared[k] = true
	var ac: Array = ["--anticheat"] if launcher != null and launcher.has_method("has_anticheat") and bool(launcher.has_anticheat(g)) else []
	var r := Upscale.run(ctx.get("runner"), upscale_cmd(), "prepare", _home(), k, _gpu(), dir, ac + _auto_net_args(), Upscale.title_of(g))
	if str(r.get("did", "")) != "":
		var st := Upscale.run(ctx.get("runner"), upscale_cmd(), "status", _home(), k, _gpu(), dir, [], Upscale.title_of(g))
		var env: Variant = st.get("env", {})
		store.set_value(k, "upscale_env", env if env is Dictionary and not env.is_empty() else null)
		game_changed(k, g)
		_last_did[k] = str(r.get("did", ""))
	return r


## The helper's plan for the open game (what Best would pick, and why not when
## it won't), cached with the status.
func upscale_plan() -> Dictionary:
	var k := game_key()
	_mutex.lock()
	var c: Dictionary = _plan_cache.get(k, {})
	_mutex.unlock()
	if not c.is_empty() and Time.get_ticks_msec() - int(c["t"]) < PLAN_TTL_MS:
		return c["r"]
	var r := _upscale_run("plan", _ac_args())
	_mutex.lock()
	_plan_cache[k] = {"t": Time.get_ticks_msec(), "r": r}
	_mutex.unlock()
	return r


## "Open the upscaler's menu": the shared action registry presses Insert in the
## game (ctx["run_action"], set by main when the registry is there).
func open_upscaler_menu() -> bool:
	var run: Variant = ctx.get("run_action")
	if run is Callable and (run as Callable).is_valid():
		return bool((run as Callable).call("key_optiscaler"))
	return false


func _fg_help(g: Dictionary) -> String:
	match GpuCaps.tier(g):
		"intel_xmx":
			return "XeSS frame generation on the XMX cores: 2x, 3x or 4x, with XeLL low latency. Needs about 40 real fps."
		"intel":
			return "XeSS frame generation at 2x with XeLL low latency. Needs about 40 real fps."
	return "Makes every second frame from the two around it (2x), with low latency on. Needs about 40 real fps."


func _upscale_controls() -> Array:
	var g := _gpu()
	return [
		_mkc({"id": "perf.upscale_mode", "title": "Upscaling for this game",
			"help": "Best sets up the sharpest upscaler this handheld runs, before you start the game. Native takes everything out again.",
			"kind": "choice", "options": _opts(Upscale.MODES, Upscale.MODE_LABELS, Upscale.MODE_HELP), "default_value": "best",
			"apply_order": 4, "affects": ["perf.upscaler", "perf.frame_gen", "perf.fg_generator", "perf.upscale_active", "perf.low_latency"]},
			_mode_detect,
			func(): return str(upscale_status().get("mode", "best")) if upscale_status().get("ok", false) else null,
			func(v): return _set_mode(str(v))),
		_mkc({"id": "perf.upscale_active", "title": "Running now",
			"help": "What the last start of this game really used. Press to check again.",
			"kind": "action", "per_game": false},
			_active_detect, func(): return null,
			func(_v):
				_forget_status()
				return true),
		_mkc({"id": "perf.upscale_offer", "title": "Add our pick to this game",
			"help": "For games we don't set up by ourselves: online games and games we don't know yet. Nothing goes in until you press this.",
			"kind": "action", "per_game": false, "apply_order": 4,
			"affects": ["perf.upscale_mode", "perf.upscaler", "perf.frame_gen", "perf.upscale_active", "perf.upscale_menu"]},
			_offer_detect, func(): return null,
			func(_v):
				if not _after_upscale(_upscale_run("opt-in", _ac_args()), true):
					return false
				_sv("upscale_native", null)
				return true),
		_mk({"id": "perf.upscaler", "title": "Upscaler",
			"help": "Pick one yourself. The game keeps its own menu: choose DLSS or FSR there and it becomes this.",
			"kind": "choice", "options": _opts(Upscale.upscalers(g), Upscale.LABELS, Upscale.upscaler_help(g)), "default_value": "own",
			"apply_order": 3},
			func(): return _upscale_reason() if _upscale_reason() != "" else _optin_reason(),
			func(): return str(upscale_status().get("upscaler", "own")) if upscale_status().get("ok", false) else null,
			func(v):
				if not _after_upscale(_upscale_run("choose", ["--upscaler", v, "--fg", str(int(upscale_status().get("fg", 0)))] + _gen_args() + _ac_args())):
					return false
				_sv("upscale_native", null)
				return true),
		_mk({"id": "perf.frame_gen", "title": "Frame generation",
			"help": _fg_help(g),
			"kind": "choice", "options": _opts(Upscale.frame_gens(g), Upscale.FG_LABELS, Upscale.FG_HELP),
			"default_value": 0, "apply_order": 2, "affects": ["perf.low_latency", "perf.lsfg"]},
			func():
				if Upscale.frame_gens(_gpu()).size() <= 1:
					return "Not on this graphics chip: games use their own" if _gpu()["vendor"] == "nvidia" else "Not on this graphics chip"
				if _upscale_reason() == "" and bool(_gv("lsfg", false)):
					return "Off while Lossless frame generation is on for this game"
				return _upscale_reason() if _upscale_reason() != "" else _optin_reason(),
			func(): return int(upscale_status().get("fg", 0)) if upscale_status().get("ok", false) else null,
			func(v):
				if int(v) > 0 and bool(_gv("lsfg", false)):
					return false           # never two frame generators at once
				if not _after_upscale(_upscale_run("choose", ["--upscaler", str(upscale_status().get("upscaler", "own")), "--fg", str(int(v))] + _gen_args() + _ac_args())):
					return false
				_sv("frame_gen", int(v))   # remembered, so a launch knows FG is on (low latency follows)
				return true),
		_mk({"id": "perf.fg_generator", "title": "Frame generation by",
			"help": "FSR is lighter and pairs with Anti-Lag 2. XeSS handles menus and HUDs better, costs more, and brings XeLL. Not every game likes XeSS here yet.",
			"kind": "choice", "options": _opts(Upscale.generators(g), Upscale.GENERATOR_LABELS, Upscale.GENERATOR_HELP),
			"default_value": Upscale.generators(g)[0] if not Upscale.generators(g).is_empty() else "", "apply_order": 2},
			func():
				if Upscale.generators(_gpu()).size() <= 1:
					return "One frame generator on this graphics chip"
				return _upscale_reason() if _upscale_reason() != "" else _optin_reason(),
			func():
				var st := upscale_status()
				var gens := Upscale.generators(_gpu())
				var cur := str((st.get("launch", {}) as Dictionary).get("fg_out", "")) if st.get("launch") is Dictionary else ""
				return cur if cur in gens else (gens[0] if not gens.is_empty() else null),
			func(v):
				var st := upscale_status()
				return _after_upscale(_upscale_run("choose", ["--upscaler", str(st.get("upscaler", "own")), "--fg", str(maxi(int(st.get("fg", 0)), 2)),
					"--generator", str(v)] + _ac_args()))),
		_mk({"id": "perf.upscale_menu", "title": "Open the upscaler's menu",
			"help": "Opens the in-game menu with every setting (the Insert key). Works while the game is in front.",
			"kind": "action", "per_game": false},
			func():
				if _upscale_reason() != "":
					return _upscale_reason()
				if str(upscale_status().get("owner", "")) != "gamecove":
					return "Our upscaler isn't in this game"
				var run: Variant = ctx.get("run_action")
				return "" if run is Callable and (run as Callable).is_valid() else "Press Insert on a keyboard, or put it on a back button in Settings",
			func(): return null, func(_v): return open_upscaler_menu()),
		_mk({"id": "perf.upscale_undo", "title": "Remove our upscaler from this game",
			"help": "Takes every file we added out of the game folder, exactly as it was. Same as Native.",
			"kind": "action", "per_game": false},
			_upscale_reason, func(): return null, func(_v): return _set_mode("native")),
		_updates_control(),
		_game_update_control(),
	]


func _gen_args() -> Array:
	var st := upscale_status()
	var cur := str((st.get("launch", {}) as Dictionary).get("fg_out", "")) if st.get("launch") is Dictionary else ""
	return ["--generator", cur] if cur in Upscale.generators(_gpu()) else []


## Mode row: sets the game up (once per session) and says in its help what
## Best picks here, or why nothing is added.
func _mode_detect(c: RefCounted) -> String:
	var why := _upscale_reason()
	if why != "":
		return why
	prepare_game()
	var p := upscale_plan()
	var line := str(p.get("line", ""))
	var did := str(_last_did.get(game_key(), ""))
	if line != "":
		c.help = line + (" (" + did.substr(0, 1).to_upper() + did.substr(1) + ".)" if did != "" and did != "set up" else "")
	if str(p.get("refused", "")) == "anticheat":
		return "Off for this game: it uses anti-cheat"
	return ""


## "Add our pick": only for a game Best offers but won't set up by itself (an
## online game, or one no list knows). Its title names the pick, its help line
## says why it isn't added by itself (for an online game, the ban risk).
func _offer_detect(c: RefCounted) -> String:
	var why := _upscale_reason()
	if why != "":
		return why
	var p := upscale_plan()
	var offer := str(p.get("offer", ""))
	if offer == "" or str(upscale_status().get("mode", "best")) != "best":
		return "Nothing to add here: Best already looks after this game" if str(p.get("refused", "")) == "" else "Off for this game"
	c.title = "Add %s to this game" % str(Upscale.LABELS.get(offer, offer))
	c.help = str(p.get("line", c.help))
	return ""


func _active_detect(c: RefCounted) -> String:
	var why := _upscale_reason()
	if why != "":
		return why
	var st := upscale_status()
	var a: Dictionary = st.get("active", {}) if st.get("active") is Dictionary else {}
	var line := str(a.get("line", ""))
	if bool(_gv("lsfg", false)) and _lsfg_reason() == "":
		# lsfg-vk reports nothing back: this is what is set for the next start
		line = (line + " " if str(a.get("state", "own")) != "own" else "") + "Lossless frame generation %dx is set for this game." % int(_gv("lsfg_multiplier", 2))
	if line != "":
		c.help = line
	return ""


# ---- keeping the upscalers current (helper check / update / game-update) -------------

## The helper's "check" (what's downloaded, the newest, updates), cached for
## CHECK_TTL_MS. online: it fetches GameCove's signed list of the newest first.
func upscale_check(online := false) -> Dictionary:
	_mutex.lock()
	var fresh := not online and _check_t >= 0 and Time.get_ticks_msec() - _check_t < CHECK_TTL_MS
	var c := _check
	_mutex.unlock()
	if fresh:
		return c
	var r := Upscale.run(ctx.get("runner"), upscale_cmd(), "check", _home(), "", _gpu(), "", ["--online"] if online else [])
	_mutex.lock()
	_check = r
	_check_t = Time.get_ticks_msec()
	_mutex.unlock()
	return r


func _forget_check() -> void:
	_mutex.lock()
	_check_t = -1
	_mutex.unlock()


func _updates_reason() -> String:
	if _gpu()["vendor"] == "other":
		return "Unknown GPU: use the game's own settings"
	if upscale_cmd() == "":
		return "Needs GameCove's upscaling helper"
	return ""


## "Upscaler downloads": the versions on this handheld and "Update available"
## when GameCove's signed list has newer ones. Pressing it updates, or checks
## right away when everything is current.
func _updates_control() -> RefCounted:
	return Ctl.make({"id": "perf.upscaler_update", "group": "perf", "title": "Upscaler downloads",
		"help": "OptiScaler, OptiPatcher, the XeSS driver and FSR 4 files GameCove downloaded, kept at the newest.",
		"kind": "action", "per_game": false, "affects": ["perf.upscale_game_update"]},
		_updates_detect, func(_c): return null, _updates_write)


func _updates_detect(c: RefCounted) -> String:
	var why := _updates_reason()
	if why != "":
		return why
	var s := UpscaleUpdates.summary(upscale_check())
	if s["help"] != "":
		c.help = s["help"]
	return s["reason"]


func _updates_write(c: RefCounted, _v: Variant) -> bool:
	var r: Dictionary
	if UpscaleUpdates.summary(upscale_check())["update"]:
		r = Upscale.run(ctx.get("runner"), upscale_cmd(), "update", _home(), "", _gpu())
		_forget_check()
		_forget_status()
		upscale_check()
	else:
		r = upscale_check(true)
	if not bool(r.get("ok", false)):
		push_warning("Upscaler update: %s" % str(r.get("error", "failed")))
	c.detect()
	return bool(r.get("ok", false))


## The open game's own copy: "Update available" when the game runs an older
## OptiScaler (or older add-ons) than GameCove now has.
func _game_update_control() -> RefCounted:
	return Ctl.make({"id": "perf.upscale_game_update", "group": "perf", "title": "Update this game's upscaler",
		"help": "Puts the newest OptiScaler into this game, with its settings kept.",
		"kind": "action", "per_game": false},
		_game_update_detect, func(_c): return null, _game_update_write)


func _game_update_detect(c: RefCounted) -> String:
	var why := _upscale_reason()
	if why != "":
		return why
	var s := UpscaleUpdates.game_summary(upscale_status())
	if s["help"] != "":
		c.help = s["help"]
	return s["reason"]


func _game_update_write(c: RefCounted, _v: Variant) -> bool:
	var done := _after_upscale(_upscale_run("game-update"))
	c.detect()
	return done


## The daily background check (Settings > About > "Background lookups" decides).
## Runs on Controls' worker; true when it asked the helper.
func background_check(now_unix: int) -> bool:
	var stamp := str(ctx.get("upscale_stamp_path", UPSCALE_STAMP))
	var allowed := Privacy.background_allowed(str(ctx.get("privacy_path", Privacy.PREFS_PATH)))
	if not UpscaleUpdates.due(UpscaleUpdates.last_check(stamp), now_unix, allowed) or _updates_reason() != "":
		return false
	UpscaleUpdates.save_check(stamp, now_unix)      # at most daily, also when the network is down
	upscale_check(true)
	# the per-game lists: the signed nightly games.json and OptiScaler's compatibility notes (anti-cheat and
	# online flags, fixes). Nothing else called this, so devices kept the list they were installed with (review low)
	Upscale.run(ctx.get("runner"), upscale_cmd(), "refresh", _home(), "", _gpu())
	return true


func _schedule_background_check(delay_s: float) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	tree.create_timer(delay_s).timeout.connect(_on_background_timer)


func _on_background_timer() -> void:
	var reg: Object = _autoload("Controls")
	if reg != null and reg.has_method("run_on_worker"):
		reg.run_on_worker(func():
			if background_check(int(Time.get_unix_time_from_system())):
				_main(func(): reg.detect_all()))
	_schedule_background_check(float(UpscaleUpdates.INTERVAL_S))


# ---- low latency, Proton, the launch wrapper ------------------------------------

## Is frame generation on for this game (`key`, or the game in ctx)? lsfg-vk,
## the upscaling helper's frame generation (remembered when set here, and the
## helper's live status for the open game) or the launch setting. Low latency
## follows it. Also Launcher.frame_gen_hooks, so a launch forces low latency on.
func frame_gen_on(key := "") -> bool:
	var k := key if key != "" else game_key()
	if k == "" or store == null:
		return false
	if bool(store.get_value(k, "lsfg", false)) or int(store.get_value(k, "frame_gen", 0)) > 0:
		return true
	if launcher != null and launcher.has_method("settings_for") and bool(launcher.settings_for(k).get("frame_gen", false)):
		return true
	if key == "" and _upscale_reason() == "":
		var st := upscale_status()
		if bool(st.get("ok", false)) and int(st.get("fg", 0)) > 0:
			return true
	return false


## Low latency (Anti-Lag 2 through low_latency_layer on AMD, XeLL on Intel):
## on by default for every game and forced on while frame generation is on
## (detect gives the reason, read reports On, a write of Off is refused). Off
## is only an override for a game that stutters or won't start with it.
func _low_latency_control() -> RefCounted:
	return Ctl.make({"id": "perf.low_latency", "group": "perf", "title": "Low latency",
		"help": LOW_LATENCY_HELP, "kind": "toggle", "default_value": true, "apply_order": 1},
		func(c):
			c.forced_value = null
			if launcher == null or not launcher.has_method("settings_for"):
				return "Not available"
			if _gpu()["vendor"] == "other":
				return "Unknown GPU"
			if game_key() == "":
				return NO_GAME
			if frame_gen_on():
				c.forced_value = true
				return LOW_LATENCY_WITH_FG
			return "",
		func(_c): return true if frame_gen_on() else bool(launcher.settings_for(game_key()).get("low_latency", true)),
		func(_c, v):
			if not bool(v) and frame_gen_on():
				return false
			var k := game_key()
			var s: Dictionary = launcher.settings_for(k)
			s["low_latency"] = bool(v)
			launcher.save_settings(k, s)     # a small JSON file; Launcher reads it again itself
			game_changed(k, game())
			return true)


func _launch_controls() -> Array:
	return [
		_low_latency_control(),
		_mk({"id": "perf.proton", "title": "Proton version",
			"help": "Which Proton runs this game.", "kind": "choice", "options": [], "default_value": ""},
			_proton_detect,
			func(): return str(library.compat_tool(game())),
			func(v):
				var lib := library
				var g := game()
				_main(func(): lib.set_compat_tool(g, str(v)))
				return true),
		_mk({"id": "perf.launch_wrapper", "title": "Start through GameCove",
			"help": "Adds GameCove's launcher to the game's Steam launch options so per-game settings reach it. Turned on by itself when needed.",
			"kind": "toggle", "default_value": false},
			_wrapper_reason,
			func(): return Files.has_wrapper(str(library.launch_options(game())), _wrapper()),
			func(v): return set_wrapper(game(), bool(v))),
		# Repair (review S2-1): GameCove's launcher out of every Steam game, every account
		_mk({"id": "perf.wrapper_remove_all", "title": "Remove GameCove from all Steam games",
			"help": "Takes GameCove's launcher out of every Steam game's launch options. Steam closes for a moment and starts again. Per-game upscaling and frame limits stop until you turn them on again.",
			"kind": "action", "per_game": false},
			func(): return "" if _steam_root() != "" else "Needs Steam",
			func(): return null,
			func(_v): return remove_wrapper_everywhere()),
	]


## The Proton choices for this game ("" = the store's default), read when detected.
func _proton_detect() -> String:
	if library == null or not library.has_method("compat_tools"):
		return "Not available"
	var g := game()
	if g.is_empty():
		return NO_GAME
	var tools: Array = library.compat_tools(g)
	var opts := []
	for t in tools:
		opts.append({"value": str(t.get("id", "")), "label": str(t.get("name", t.get("id", "")))})
	if opts.is_empty() or opts[0]["value"] != "":
		opts.push_front({"value": "", "label": "Default"})
	var c: RefCounted = _control("perf.proton")
	if c != null:
		c.options = opts
	return ""


var _controls_by_id := {}


func _control(id: String) -> RefCounted:
	var w: WeakRef = _controls_by_id.get(id)
	return w.get_ref() if w != null else null


func _wrapper() -> String:
	return Files.wrapper_path(_root(), ctx.get("wrapper_paths", []))


func _wrapper_reason() -> String:
	if library == null or not library.has_method("launch_options"):
		return "Not available"
	if _wrapper() == "":
		return "Needs GameCove's launch wrapper (gamecove-run)"
	var k := game_key()
	if k == "":
		return NO_GAME
	return "" if Files.steam_appid(k) != "" else "Only for Steam games (GameCove starts the others itself)"


## Adds or removes the wrapper in the game's Steam launch options (main thread,
## through Library: Steam's own API while it runs, its files otherwise).
func set_wrapper(g: Dictionary, on: bool) -> bool:
	var w := _wrapper()
	if library == null or w == "" or Files.steam_appid(str(g.get("key", ""))) == "":
		return false
	var cur := str(library.launch_options(g))
	var next := Files.with_wrapper(cur, w) if on else Files.without_wrapper(cur, w)
	if next == cur.strip_edges():
		return true
	var lib := library
	_main(func(): lib.set_launch_options(g, next))
	return true


## Closes Steam if it runs (it writes its settings back on exit), strips the wrapper from every
## game of every account, then starts Steam again in the session's mode. Worker thread.
func remove_wrapper_everywhere() -> bool:
	var root := _steam_root()
	if root == "":
		return false
	var proc := str(ctx.get("proc_root", "/proc"))
	var was_running := Files.SteamConfig.is_running(_home(), proc)
	var runner: Object = ctx.get("runner")
	if was_running and runner != null:
		runner.run("steam", PackedStringArray(["-shutdown"]))
		var waited := 0
		while Files.SteamConfig.is_running(_home(), proc) and waited < 60:
			OS.delay_msec(500)
			waited += 1
	var r: Dictionary = Files.unwrap_all(_home(), root, proc)
	if was_running and runner != null and not Files.SteamConfig.is_running(_home(), proc):
		var mode := OS.get_environment("GAMECOVE_STEAM_MODE")
		var args := ["-silent"] if mode in ["", "silent"] else (["-silent", "-gamepadui", "-steamos3", "-steampal", "-steamdeck"] if mode == "gamepadui" else [])
		if mode != "off":
			# in the background: the runner waits only for this little shell
			runner.run("sh", PackedStringArray(["-c", "steam \"$@\" >/dev/null 2>&1 &", "sh"] + args))
	return int(r["error"]) == OK


# ---- Steam's shader pre-caching -------------------------------------------------

func _steam_root() -> String:
	return Proton.steam_root(_home()) if _home() != "" else ""


func _shader_controls() -> Array:
	return [
		_mk({"id": "perf.shader_threads", "title": "Shader pre-caching threads",
			"help": "How many CPU threads Steam uses to prepare shaders in the background. 0 = Steam's default. Applies when Steam restarts.",
			"kind": "slider", "min_value": 0.0, "max_value": 16.0, "step": 1.0, "default_value": 0.0, "per_game": false},
			func(): return "" if _steam_root() != "" else "Needs Steam",
			func(): return float(Files.shader_threads(_steam_root())),
			func(v): return Files.set_shader_threads(_steam_root(), int(v))),
		_mk({"id": "perf.clear_shader_cache", "title": "Clear this game's shader cache",
			"help": "Deletes Steam's compiled shaders for this game; they are rebuilt on the next start (fixes some stutter or crashes after driver updates).",
			"kind": "action", "per_game": false},
			func():
				var id := Files.steam_appid(game_key())
				if game_key() == "":
					return NO_GAME
				if id == "":
					return "Only for Steam games"
				return "" if not Files.shader_cache_dirs(Lsfg.steam_libraries(_steam_root()), id).is_empty() else "No shader cache for this game",
			func(): return null,
			func(_v):
				var ok := true
				for d in Files.shader_cache_dirs(Lsfg.steam_libraries(_steam_root()), Files.steam_appid(game_key())):
					ok = Files.remove_shader_cache(d) and ok
				return ok),
	]


# ---- the game's launch environment ------------------------------------------------

## Everything the perf controls add to a game's environment. include_launcher:
## Launcher's own variables too, for a Steam game's file (they don't reach
## steam:// otherwise).
func env_for(key: String, g: Dictionary, include_launcher := false) -> Dictionary:
	var vals: Dictionary = store.values(key) if key != "" else {}
	var env := {}
	var fps := int(float(vals.get("fps_limit", 0)))
	if fps > 0:
		# MangoHud's layer reads only MANGOHUD_CONFIG when it is set (overlay_params.cpp: config files are read
		# when there is no env config), so the session's mangoapp file isn't shown twice.
		env["MANGOHUD"] = "1"
		env["MANGOHUD_CONFIG"] = "no_display,fps_limit=%d,fps_limit_method=%s" % [fps,
			"early" if str(vals.get("fps_limit_method", "late")) == "early" else "late"]
	if bool(vals.get("lsfg", false)):
		env.merge(Lsfg.game_env(key), true)
	if include_launcher and launcher != null and launcher.has_method("launch_env") and not g.is_empty():
		var le: Variant = launcher.launch_env(g)
		if le is Dictionary:
			for k in le:
				if not env.has(k):
					env[k] = str(le[k])
	return env


## Launcher.env_hooks: a non-Steam game GameCove starts gets our variables and
## the upscaler's (the helper's launch file is only read by gamecove-run).
func launch_env_hook(key: String, _game: Dictionary) -> Dictionary:
	if key == game_key():
		prepare_game(key)     # a start from Home without opening the game's page: set up first (once per session)
	var env := env_for(key, {})
	var up: Variant = store.get_value(key, "upscale_env", {})
	if up is Dictionary:
		for k in up:
			env[k] = str(up[k])
	return env


## A per-game value changed: rewrite the Steam game's file and put the wrapper
## in its launch options when there is something for it to do.
func game_changed(key: String, g: Dictionary) -> void:
	var appid := Files.steam_appid(key)
	if appid == "" or _home() == "":
		return
	var env := env_for(key, g if not g.is_empty() else {"key": key, "store": "steam", "id": appid}, true)
	Files.write_env(_home(), appid, env)
	var vals: Dictionary = store.values(key)
	var wants := vals.has("fps_limit") or bool(vals.get("lsfg", false)) or vals.has("upscale_env")
	if wants and library != null and library.has_method("launch_options") and not g.is_empty():
		set_wrapper(g, true)


## On another handheld (one drive, several devices), the files written for the
## last one are rewritten from this device's values. Cheap: a few small files.
func refresh_device_files() -> void:
	var home := _home()
	if home == "" or store == null:
		return
	var stamp := Files.launch_dir(home).path_join(".device")
	var now: String = store.device_id
	var was := FileAccess.get_file_as_string(stamp).strip_edges() if FileAccess.file_exists(stamp) else ""
	if was == now:
		return
	var dir := DirAccess.open(Files.launch_dir(home))
	if dir != null:
		for f in dir.get_files():
			if f.ends_with(".perf.env"):
				DirAccess.remove_absolute(Files.launch_dir(home).path_join(f))
	for k in store.games():
		var appid := Files.steam_appid(k)
		if appid != "":
			Files.write_env(home, appid, env_for(k, {"key": k, "store": "steam", "id": appid}, true))
	write_lsfg_config()
	if dir != null or not store.games().is_empty():
		DirAccess.make_dir_recursive_absolute(Files.launch_dir(home))
		var f := FileAccess.open(stamp, FileAccess.WRITE)
		if f != null:
			f.store_string(now + "\n")
			f.close()
