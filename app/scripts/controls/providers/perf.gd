extends RefCounted
## Performance controls (group "perf"): the performance overlay (MangoHud
## through the session's mangoapp), MangoHud's in-game frame limiter, lsfg-vk
## frame generation, upscaling per game (OptiScaler / XeSS / FSR through the
## gamecove-upscale helper ported from ClawDeck), low latency, the game's
## Proton, the Steam launch wrapper and Steam's shader pre-caching.
## Details, sources and what each writes: docs/CONTROLS.md "Performance".
##
## Game scope: per-game controls act on the game in ctx["game"] (a Library
## game dictionary) or ctx["game_key"] ("steam:976730"); set it with
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
const MANGOHUD_LAYER_DIRS := ["/usr/share/vulkan/implicit_layer.d", "/etc/vulkan/implicit_layer.d",
	"/usr/local/share/vulkan/implicit_layer.d"]
const STATUS_TTL_MS := 3000
## The helper's check hashes the downloaded files (FSR 4 DLLs are ~100 MB): read again at most this often.
const CHECK_TTL_MS := 600000
const UPSCALE_STAMP := "user://upscalers.cfg"

var ctx: Dictionary = {}
var store: RefCounted
var perf: Object
var launcher: Object
var library: Object
var _status_cache := {}           # game key -> {"t": ms, "r": Dictionary}
var _check := {}                  # the helper's last "check" answer
var _check_t := -1
var _mutex := Mutex.new()


static func set_game(context: Dictionary, game: Dictionary) -> void:
	if game.is_empty():
		context.erase("game")
		context.erase("game_key")
	else:
		context["game"] = game
		context["game_key"] = str(game.get("key", "%s:%s" % [game.get("store", ""), game.get("id", "")]))


func setup(c: Dictionary) -> void:
	ctx = c
	var real := str(c.get("sys_root", "")) == ""
	perf = c.get("perf_monitor", _autoload("PerfMonitor") if real else null)
	launcher = c.get("launcher", _autoload("Launcher") if real else null)
	library = c.get("library", _autoload("Library") if real else null)
	store = Store.new(str(c.get("perf_store_path", "")), str(_profile().get("id", "unknown")))
	if launcher != null and "env_hooks" in launcher:
		launcher.env_hooks.append(launch_env_hook)
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
	return Upscale.gpu(_profile())


# ---- the game ------------------------------------------------------------------

func game() -> Dictionary:
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


func _opts(values: Array, labels: Dictionary = {}) -> Array:
	var out := []
	for v in values:
		out.append({"value": v, "label": str(labels.get(v, str(v).capitalize()))})
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
	return Lsfg.find_dll(Lsfg.steam_libraries(root))


func _lsfg_reason() -> String:
	match Lsfg.layer(_root(), _home()):
		"":
			return "Needs lsfg-vk"
		"v1":
			return "Update lsfg-vk to version 2"
	if _lsfg_dll() == "":
		return "Needs Lossless Scaling from Steam (beta: lsfg-vk)"
	return NO_GAME if game_key() == "" else ""


func _lsfg_controls() -> Array:
	return [
		_mk({"id": "perf.lsfg", "title": "Lossless Scaling frame generation",
			"help": "Adds generated frames with lsfg-vk and your own Lossless Scaling. Best above 40 real fps.",
			"kind": "toggle", "default_value": false},
			_lsfg_reason, func(): return bool(_gv("lsfg", false)), func(v): return _lsfg_set("lsfg", v)),
		_mk({"id": "perf.lsfg_multiplier", "title": "Frame generation multiplier",
			"help": "2x adds one frame per real frame; 3x and 4x add more (more lag, more artefacts).",
			"kind": "choice", "options": _opts(Lsfg.MULTIPLIERS, {2: "2x", 3: "3x", 4: "4x"}), "default_value": 2,
			"requires": ["perf.lsfg"]},
			_lsfg_reason, func(): return int(_gv("lsfg_multiplier", 2)), func(v): return _lsfg_set("lsfg_multiplier", v)),
		_mk({"id": "perf.lsfg_flow_scale", "title": "Flow scale",
			"help": "Lower is faster with a softer result; 80 % suits handheld screens.",
			"kind": "slider", "min_value": 0.25, "max_value": 1.0, "step": 0.05, "default_value": 0.8,
			"requires": ["perf.lsfg"]},
			_lsfg_reason, func(): return float(_gv("lsfg_flow_scale", 0.8)), func(v): return _lsfg_set("lsfg_flow_scale", v)),
		_mk({"id": "perf.lsfg_performance", "title": "Performance mode",
			"help": "A lighter frame generation model: faster, slightly lower quality.",
			"kind": "toggle", "default_value": false, "requires": ["perf.lsfg"]},
			_lsfg_reason, func(): return bool(_gv("lsfg_performance", false)), func(v): return _lsfg_set("lsfg_performance", v)),
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
			profiles[k] = vals
	var path := _home().path_join(Lsfg.CONFIG)
	var existing := FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""
	if existing.strip_edges() != "" and not RegEx.create_from_string("(?m)^\\s*version\\s*=\\s*2\\b").search(existing):
		# a 1.x config: lsfg-vk 2 doesn't read it (decky-lsfg-vk discards it too); kept beside
		DirAccess.rename_absolute(path, path + ".v1.bak")
		existing = ""
	if profiles.is_empty() and existing == "":
		return true
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(Lsfg.merge_config(existing, profiles, _lsfg_dll()))
	f.close()
	return true


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


func _upscale_run(verb: String, extra: Array = []) -> Dictionary:
	return Upscale.run(ctx.get("runner"), upscale_cmd(), verb, _home(), game_key(), _gpu(),
		str(game().get("install_path", "")), extra)


## The helper's status for the game, cached for a few seconds (one detect_all
## reads several controls).
func upscale_status() -> Dictionary:
	var k := game_key()
	_mutex.lock()
	var c: Dictionary = _status_cache.get(k, {})
	_mutex.unlock()
	if not c.is_empty() and Time.get_ticks_msec() - int(c["t"]) < STATUS_TTL_MS:
		return c["r"]
	var r := _upscale_run("status")
	_mutex.lock()
	_status_cache[k] = {"t": Time.get_ticks_msec(), "r": r}
	_mutex.unlock()
	return r


func _forget_status() -> void:
	_mutex.lock()
	_status_cache.erase(game_key())
	_mutex.unlock()


## After the helper changed the game: keep its environment for non-Steam launches
## and make sure a Steam game starts through the wrapper.
func _after_upscale(r: Dictionary) -> bool:
	_forget_status()
	if not bool(r.get("ok", false)):
		push_warning("Upscaling: %s" % str(r.get("error", "failed")))
		return false
	var env: Variant = r.get("env", {})
	_sv("upscale_env", env if env is Dictionary and not env.is_empty() else null)
	return true


func _upscale_controls() -> Array:
	var g := _gpu()
	return [
		_mk({"id": "perf.upscaler", "title": "Upscaler",
			"help": "Puts a better upscaler into the game with OptiScaler (XeSS on Intel Arc, FSR on AMD). Pick the game's DLSS or FSR in its menu.",
			"kind": "choice", "options": _opts(Upscale.upscalers(g), Upscale.LABELS), "default_value": "own",
			"apply_order": 3},
			_upscale_reason,
			func(): return str(upscale_status().get("upscaler", "own")) if upscale_status().get("ok", false) else null,
			func(v): return _after_upscale(_upscale_run("choose", ["--upscaler", v, "--fg", str(int(upscale_status().get("fg", 0)))]))),
		_mk({"id": "perf.frame_gen", "title": "Frame generation",
			"help": "XeSS frame generation on Intel Arc (2x-4x), FSR frame generation on AMD (2x). Needs about 40 real fps.",
			"kind": "choice", "options": _opts(Upscale.frame_gens(g), {0: "Off", 2: "2x", 3: "3x", 4: "4x"}),
			"default_value": 0, "apply_order": 2},
			func(): return _upscale_reason() if Upscale.frame_gens(_gpu()).size() > 1 else "Not on this GPU",
			func(): return int(upscale_status().get("fg", 0)) if upscale_status().get("ok", false) else null,
			func(v): return _after_upscale(_upscale_run("choose", ["--upscaler", str(upscale_status().get("upscaler", "own")), "--fg", str(int(v))]))),
		_mk({"id": "perf.upscale_recommended", "title": "Use the recommended setup",
			"help": "Sets up the best upscaler for this game from what it ships and OptiScaler's game list.",
			"kind": "action", "per_game": false},
			_upscale_reason, func(): return null, func(_v): return _after_upscale(_upscale_run("apply"))),
		_mk({"id": "perf.upscale_undo", "title": "Remove GameCove's upscaler",
			"help": "Takes OptiScaler (and REFramework) out of the game folder, exactly as it was.",
			"kind": "action", "per_game": false},
			_upscale_reason, func(): return null, func(_v): return _after_upscale(_upscale_run("undo"))),
		_updates_control(),
		_game_update_control(),
	]


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

func _launch_controls() -> Array:
	return [
		_mk({"id": "perf.low_latency", "title": "Low latency",
			"help": "Cuts input lag: Anti-Lag through low_latency_layer on AMD, XeLL on Intel Arc. From the next launch.",
			"kind": "toggle", "default_value": true, "apply_order": 1},
			func():
				if launcher == null or not launcher.has_method("settings_for"):
					return "Not available"
				if _gpu()["vendor"] == "other":
					return "Unknown GPU"
				return NO_GAME if game_key() == "" else "",
			func(): return bool(launcher.settings_for(game_key()).get("low_latency", true)),
			func(v):
				var k := game_key()
				var s: Dictionary = launcher.settings_for(k)
				s["low_latency"] = bool(v)
				launcher.save_settings(k, s)     # a small JSON file; Launcher reads it again itself
				game_changed(k, game())
				return true),
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
