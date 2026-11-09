extends "res://tests/test_case.gd"
## Perf controls (providers/perf.gd and scripts/controls/perf/*): overlay
## presets, MangoHud limiter, lsfg-vk profiles, the upscaling helper bridge,
## low latency, Proton, the Steam launch wrapper, shader pre-caching, the
## launch environment and per-device files. Everything runs in a fixture tree
## under user:// with fake services; nothing touches the real system.

const ControlsScript := preload("res://scripts/controls/controls.gd")
const PerfProvider := preload("res://scripts/controls/providers/perf.gd")
const Fakes := preload("res://tests/fixtures/perf_controls/fakes.gd")
const Overlay := preload("res://scripts/controls/perf/overlay.gd")
const Lsfg := preload("res://scripts/controls/perf/lsfg.gd")
const Files := preload("res://scripts/controls/perf/launch_files.gd")
const Upscale := preload("res://scripts/controls/perf/upscale.gd")
const MangoHud := preload("res://scripts/perf/mangohud.gd")
const LauncherScript := preload("res://scripts/launch/launcher.gd")

const CLAW := {"id": "msi-claw-8-ex", "gpu_family": "intel-xe3", "gpu_arch": "Xe3", "xmx": true, "panel_hz": [60, 120]}
const ALLY_X := {"id": "asus-rog-xbox-ally-x", "gpu_family": "amd-rdna3", "gpu_arch": "RDNA3.5", "xmx": false, "panel_hz": [48, 120]}
const DECK := {"id": "steam-deck-oled", "gpu_family": "amd-rdna2", "gpu_arch": "RDNA2", "xmx": false, "panel_hz": [45, 90]}
const GAME := {"key": "steam:42", "store": "steam", "id": "42", "title": "Test Game", "install_path": ""}
const EPIC := {"key": "epic:abc", "store": "epic", "id": "abc", "title": "Epic Game", "install_path": "/games/abc"}


func _dir(name: String) -> String:
	var d := ProjectSettings.globalize_path("user://test_perf_controls/" + name)
	_rm(d)
	DirAccess.make_dir_recursive_absolute(d)
	return d


func _rm(dir: String) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	d.include_hidden = true
	for f in d.get_files():
		DirAccess.remove_absolute(dir.path_join(f))
	for s in d.get_directories():
		_rm(dir.path_join(s))
	DirAccess.remove_absolute(dir)


func _w(path: String, text := "x") -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _read(path: String) -> String:
	return FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""


## A fixture system: MangoHud and lsfg-vk layers, the wrapper and the helper,
## Steam with Lossless Scaling's lsfg-vk.dll. parts lists what to leave out.
func _world(name: String, device: Dictionary, leave_out: Array = []) -> Dictionary:
	var base := _dir(name)
	var root := base.path_join("root")
	var home := base.path_join("home")
	var layers := root.path_join("usr/share/vulkan/implicit_layer.d")
	if not "mangohud" in leave_out:
		_w(layers.path_join("MangoHud.x86_64.json"), "{}")
	if not "lsfg" in leave_out:
		_w(layers.path_join(Lsfg.LAYER_V2), "{}")
	if not "wrapper" in leave_out:
		_w(root.path_join("usr/libexec/gamecove/gamecove-run"), "#!/bin/sh\n")
	if not "helper" in leave_out:
		_w(root.path_join("usr/libexec/gamecove/gamecove-upscale"), "#!/bin/sh\n")
	DirAccess.make_dir_recursive_absolute(home.path_join(".local/share/Steam/steamapps"))
	if not "dll" in leave_out:
		_w(home.path_join(".local/share/Steam/steamapps/common/Lossless Scaling/lsfg-vk.dll"), "dll")
	var perf = Fakes.FakePerf.new()
	var launcher = Fakes.FakeLauncher.new()
	var library = Fakes.FakeLibrary.new()
	var runner = Fakes.FakeRunner.new()
	var ctx := {"sys_root": root, "home": home, "device": device, "runner": runner,
		"perf_monitor": perf, "launcher": launcher, "library": library,
		"perf_store_path": base.path_join("perf_controls.cfg")}
	var reg: Node = ControlsScript.new()
	reg.sync_mode = true
	reg.setup(ctx)
	var p = PerfProvider.new()
	p.setup(ctx)
	reg.register_provider(p)
	reg.detect_all()
	return {"reg": reg, "p": p, "ctx": ctx, "root": root, "home": home, "perf": perf, "launcher": launcher,
		"library": library, "runner": runner}


func _with_game(w: Dictionary, g: Dictionary) -> void:
	PerfProvider.set_game(w["ctx"], g)
	w["reg"].detect_all()


func _done(w: Dictionary) -> void:
	w["reg"].free()


# ---- registry -----------------------------------------------------------------

func test_every_control_is_perf_and_explains_itself() -> void:
	var w := _world("all", CLAW)
	var ids := []
	for c in w["reg"].list():
		ids.append(c.id)
		eq(c.group, "perf", c.id + " group")
		ok(c.title != "" and c.help != "", c.id + " has a title and help")
		ok(c.available or c.reason != "", c.id + " says why it is unavailable")
	for want in ["perf.overlay", "perf.overlay_position", "perf.overlay_opacity", "perf.overlay_scale",
			"perf.overlay_item.fps", "perf.lsfg",
			"perf.lsfg_multiplier", "perf.lsfg_flow_scale", "perf.lsfg_performance", "perf.upscaler",
			"perf.frame_gen", "perf.upscale_recommended", "perf.upscale_undo", "perf.low_latency", "perf.proton",
			"perf.launch_wrapper", "perf.shader_threads", "perf.clear_shader_cache"]:
		ok(want in ids, want + " registered")
	# per-game controls wait for a game
	ok(not "perf.mangohud_fps_limit" in ids, "one Frame limit control (display.fps_limit); MangoHud's is a helper")
	for id in ["perf.lsfg", "perf.upscaler", "perf.low_latency", "perf.proton", "perf.launch_wrapper"]:
		eq(w["reg"].control(id).reason, PerfProvider.NO_GAME, id + " without a game")
	_done(w)


func test_the_real_provider_loads_with_the_others() -> void:
	# what Controls does at startup: every provider file, a fixture context
	var reg: Node = ControlsScript.new()
	reg.sync_mode = true
	reg.setup({"sys_root": _dir("load"), "home": "", "runner": null, "device": null})
	reg.load_providers()
	ok(reg.has("perf.overlay") and reg.has("perf.upscaler"), "perf provider loaded")
	reg.detect_all()
	eq(reg.control("perf.overlay").reason, "Performance overlay isn't available", "no PerfMonitor in a fixture")
	eq(reg.control("perf.upscaler").reason, "Unknown GPU: use the game's own settings", "unknown device")
	reg.free()


# ---- overlay ------------------------------------------------------------------

func test_overlay_presets_and_look_go_through_perf_monitor() -> void:
	var w := _world("overlay", CLAW)
	var perf = w["perf"]
	var reg: Node = w["reg"]
	eq(reg.value("perf.overlay"), "off", "starts off")
	reg.set_value("perf.overlay", "bar")
	eq(perf.level, 2, "bar is level 2")
	eq(perf.override, Overlay.BAR, "bar lines")
	reg.set_value("perf.overlay_position", "top-right")
	reg.set_value("perf.overlay_opacity", 20)
	reg.set_value("perf.overlay_scale", 150)
	ok("position=top-right" in perf.extra and "background_alpha=0.20" in perf.extra and "font_scale=1.50" in perf.extra, "look lines")
	reg.set_value("perf.overlay", "custom")
	reg.set_value("perf.overlay_item.temps", true)
	reg.set_value("perf.overlay_item.cpu", false)
	eq(perf.level, 3, "custom is level 3")
	ok("cpu_temp" in perf.override and not "cpu_stats" in perf.override, "custom items")
	reg.detect_all()
	eq(reg.value("perf.overlay"), "custom", "read back")
	# someone used the old 0-3 slider: the preset follows the level
	perf.level = 1
	reg.detect_all()
	eq(reg.value("perf.overlay"), "fps", "level wins over a stale preset")
	perf.supported = false
	reg.detect_all()
	eq(reg.control("perf.overlay").reason, "Needs gamescope's performance overlay (mangoapp)", "no mangoapp")
	_done(w)


func test_overlay_lines() -> void:
	eq(Overlay.override_lines("compact", []), [], "level's own lines")
	eq(Overlay.override_lines("custom", []), ["legacy_layout=0", "cpu_stats=0", "gpu_stats=0", "frametime=0", "fps"], "nothing ticked: fps")
	eq(Overlay.extra_lines("top-left", 50.0, 100.0), [], "defaults add nothing")
	eq(Overlay.extra_lines("nowhere", 150.0, 500.0), ["background_alpha=1.00", "font_scale=2.00"], "clamped, bad position dropped")
	eq(Overlay.preset_for(2, "bar"), "bar", "remembered")
	eq(Overlay.preset_for(3, "bar"), "full", "level changed")


func test_mangohud_config_carries_the_style() -> void:
	var text := MangoHud.config_text(2, false, "", true, ["horizontal", "fps"], ["position=top-right"])
	ok("horizontal\nfps\nposition=top-right" in text and not "table_columns=20" in text, "override and extra")
	var off := MangoHud.config_text(0, false, "", true, ["fps"], ["position=top-right"])
	ok("no_display" in off and not "position" in off, "off ignores the style")
	eq(MangoHud._clean(["fps", "a\nb", "# x", "output_folder=/x", "log_interval=1", " gpu_stats "]), ["fps", "gpu_stats"], "unsafe lines dropped")
	var m = MangoHud.new()
	var d := _dir("mangohud")
	m.config_path = d.path_join("cfg")
	m.level = 1
	ok(m.set_style([], ["position=bottom-left"]), "style written")
	ok("position=bottom-left" in _read(m.config_path), "in the file")


# ---- MangoHud limiter -------------------------------------------------------------

func test_limiter_writes_the_steam_file_and_adds_the_wrapper() -> void:
	var w := _world("limiter", ALLY_X)
	_with_game(w, GAME)
	var reg: Node = w["reg"]
	ok(w["p"].set_mangohud_limit("steam:42", 40, "early"), "internal helper")
	var env := Files.read_env(Files.perf_env_path(w["home"], "42"))
	eq(env.get("MANGOHUD"), "1", "layer on")
	eq(env.get("MANGOHUD_CONFIG"), "no_display,fps_limit=40,fps_limit_method=early", "limit and method")
	eq(env.get("LOW_LATENCY_LAYER"), "1", "Launcher's variables reach the Steam game too")
	eq(w["library"].options.get("steam:42"), "/usr/libexec/gamecove/gamecove-run %command%", "wrapper in the launch options")
	reg.detect_all()
	eq(reg.value("perf.launch_wrapper"), true, "wrapper reads back")
	w["p"].set_mangohud_limit("steam:42", 0)
	ok(not Files.read_env(Files.perf_env_path(w["home"], "42")).has("MANGOHUD"), "0 removes the limiter")
	_done(w)


func test_limiter_needs_mangohud() -> void:
	var w := _world("nomh", ALLY_X, ["mangohud"])
	_with_game(w, GAME)
	ok(not w["p"].set_mangohud_limit("steam:42", 40), "no MangoHud layer: refused")
	_done(w)


# ---- lsfg-vk ----------------------------------------------------------------------

func test_lsfg_profiles_keep_the_users_own() -> void:
	var w := _world("lsfg", DECK)
	var cfg: String = w["home"].path_join(Lsfg.CONFIG)
	_w(cfg, "version = 2\n\n[global]\nallow_fp16 = true\n\n[[profile]]\nname = \"mine\"\nactive_in = [ \"mpv\" ]\nmultiplier = 3\n")
	_with_game(w, GAME)
	var reg: Node = w["reg"]
	ok(reg.control("perf.lsfg").available, "available: v2 layer and the DLL")
	reg.set_value("perf.lsfg", true)
	reg.set_value("perf.lsfg_multiplier", 3)
	reg.set_value("perf.lsfg_flow_scale", 0.5)
	var text := _read(cfg)
	ok("name = \"mine\"" in text and "active_in = [ \"mpv\" ]" in text, "the user's profile kept")
	ok("name = \"GameCove steam:42\"\nactive_in = [ \"42\" ]" in text, "ours by Steam app id")
	ok("multiplier = 3" in text and "flow_scale = 0.5" in text, "our values")
	ok("dll = " in text and "lsfg-vk.dll" in text, "the user's DLL found and set")
	var env := Files.read_env(Files.perf_env_path(w["home"], "42"))
	eq(env.get("ENABLE_GAMESCOPE_WSI"), "0", "decky-lsfg-vk's gamescope WSI workaround")
	reg.set_value("perf.lsfg", false)
	text = _read(cfg)
	ok(not "GameCove steam:42" in text and "name = \"mine\"" in text, "off removes only ours")
	_done(w)


func test_lsfg_reasons_and_old_config() -> void:
	var w := _world("lsfg_reasons", DECK, ["lsfg"])
	_with_game(w, GAME)
	eq(w["reg"].control("perf.lsfg").reason, "Needs lsfg-vk", "no layer")
	_w(w["home"].path_join(".local/share/vulkan/implicit_layer.d").path_join(Lsfg.LAYER_V1), "{}")
	w["reg"].detect_all()
	eq(w["reg"].control("perf.lsfg").reason, "Update lsfg-vk to version 2", "1.x layer")
	_done(w)
	var w2 := _world("lsfg_nodll", DECK, ["dll"])
	_with_game(w2, GAME)
	eq(w2["reg"].control("perf.lsfg").reason, "Needs Lossless Scaling from Steam (beta: lsfg-vk)", "no DLL")
	_done(w2)
	var w3 := _world("lsfg_v1cfg", DECK)
	var cfg: String = w3["home"].path_join(Lsfg.CONFIG)
	_w(cfg, "version = 1\n[[game]]\nexe = \"x\"\n")
	_with_game(w3, GAME)
	w3["reg"].set_value("perf.lsfg", true)
	ok(_read(cfg).begins_with("version = 2"), "fresh v2 config")
	ok(FileAccess.file_exists(cfg + ".v1.bak"), "the 1.x config kept beside")
	_done(w3)


func test_lsfg_config_text() -> void:
	var fresh := Lsfg.merge_config("", {"epic:abc": {"lsfg": true, "lsfg_multiplier": 9, "lsfg_flow_scale": 0.1}}, "/x/lsfg-vk.dll")
	ok(fresh.begins_with("version = 2\n\n[global]\ndll = \"/x/lsfg-vk.dll\"\nallow_fp16 = true\n"), "header")
	ok("name = \"GameCove epic:abc\"\npacing_mode" in fresh, "non-Steam: no active_in")
	ok("multiplier = 2" in fresh and "flow_scale = 0.25" in fresh, "values made valid")
	eq(Lsfg.game_env("epic:abc").get("LSFGVK_PROFILE"), "GameCove epic:abc", "picked by name")
	ok(not Lsfg.game_env("steam:1").has("LSFGVK_PROFILE"), "Steam games by app id")
	var again := Lsfg.merge_config(fresh, {}, "/x/lsfg-vk.dll")
	ok(not "[[profile]]" in again and again.count("dll =") == 1, "ours removed, DLL once")


# ---- upscaling helper ----------------------------------------------------------------

func test_upscaler_choices_follow_the_gpu() -> void:
	eq(Upscale.upscalers(Upscale.gpu(CLAW)), ["own", "xess", "fsr4_xmx", "fsr4_xmx_lite"], "Claw")
	eq(Upscale.frame_gens(Upscale.gpu(CLAW)), [0, 2, 3, 4], "XeSS-FG 2x-4x")
	eq(Upscale.upscalers(Upscale.gpu(ALLY_X)), ["own", "fsr31", "fsr4_amd"], "RDNA3.5")
	eq(Upscale.upscalers(Upscale.gpu(DECK)), ["own", "fsr31"], "Steam Deck: no FSR 4")
	eq(Upscale.frame_gens(Upscale.gpu(DECK)), [0, 2], "FSR-FG 2x")
	eq(Upscale.upscalers(Upscale.gpu({"gpu_family": "intel-xe-lpg"})), ["own", "xess"], "Meteor Lake")
	eq(Upscale.upscalers(Upscale.gpu({})), ["own"], "unknown")
	eq(Upscale.helper_key("steam:42"), "42", "Steam by app id")
	eq(Upscale.helper_key("epic:abc"), "epic:abc", "others by key")


func test_upscaler_runs_the_helper_and_keeps_its_environment() -> void:
	var w := _world("upscale", ALLY_X)
	var runner = w["runner"]
	runner.answers["status"] = {"ok": true, "upscaler": "own", "fg": 0}
	runner.answers["choose"] = {"ok": true, "env": {"Dx12Upscaler": "fsr31", "WINEDLLOVERRIDES": "dxgi=n,b;"}}
	_with_game(w, EPIC)
	var reg: Node = w["reg"]
	var c: RefCounted = reg.control("perf.upscaler")
	ok(c.available, "available for a game with a folder")
	eq(c.value, "own", "read from the helper")
	eq(c.options.map(func(o): return o["value"]), ["own", "fsr31", "fsr4_amd"], "AMD choices")
	reg.set_value("perf.upscaler", "fsr31")
	var last: String = runner.calls[runner.calls.size() - 1]
	ok(last.begins_with("/usr/libexec/gamecove/gamecove-upscale choose --home ") and "--key epic:abc --dir /games/abc --upscaler fsr31 --fg 0" in last, "choose call: " + last)
	ok("--gpu vendor=amd,family=amd-rdna3,arch=RDNA3.5,xmx=0 " in last, "GPU facts passed without quotes")
	var env: Dictionary = w["p"].launch_env_hook("epic:abc", EPIC)
	eq(env.get("WINEDLLOVERRIDES"), "dxgi=n,b;", "non-Steam launch gets OptiScaler's override")
	runner.answers["choose"] = {"ok": false, "error": "Decky Framegen has put OptiScaler in this game"}
	var failed := []
	reg.control_failed.connect(func(id, _v): failed.append(id))
	reg.set_value("perf.frame_gen", 2)
	eq(failed, ["perf.frame_gen"], "a refused choice fails the control")
	_done(w)


func test_upscaler_reasons() -> void:
	var w := _world("upscale_reasons", ALLY_X, ["helper"])
	_with_game(w, GAME)
	eq(w["reg"].control("perf.upscaler").reason, "Needs GameCove's upscaling helper", "no helper")
	_done(w)
	var w2 := _world("upscale_nodir", ALLY_X)
	_with_game(w2, {"key": "gog:1", "store": "gog", "id": "1"})
	eq(w2["reg"].control("perf.upscaler").reason, "This game's folder isn't known", "no folder")
	_done(w2)
	var w3 := _world("upscale_lpg", {"id": "x", "gpu_family": "intel-xe-lpg", "gpu_arch": "Xe-LPG"})
	_with_game(w3, GAME)
	eq(w3["reg"].control("perf.frame_gen").reason, "Not on this GPU", "no XeSS-FG without XMX")
	_done(w3)


func test_python_and_gdscript_choices_agree() -> void:
	if OS.execute("python3", ["-c", "1"]) != 0:
		return
	var helpers := ProjectSettings.globalize_path("res://").path_join("../packaging/helpers").simplify_path()
	for dev in [CLAW, ALLY_X, DECK, {"gpu_family": "intel-xe-lpg"}, {}]:
		var g := Upscale.gpu(dev)
		var out := []
		var code := OS.execute("python3", ["-I", "-c",
			"import sys,json; sys.path.insert(0, sys.argv[1]); from gamecove_upscale import cli, games; g=cli.parse_gpu(sys.argv[2]); print(json.dumps([games.upscalers_for(g), games.fg_for(g)]))",
			helpers, Upscale.gpu_arg(g)], out)
		eq(code, 0, "python ran")
		eq(JSON.parse_string(str(out[0]).strip_edges()), [Upscale.upscalers(g), Upscale.frame_gens(g)].map(func(a): return a.map(func(x): return float(x) if x is int else x)), "same choices for %s" % str(dev.get("gpu_family", "?")))


func test_python_helper_tests_pass() -> void:
	# the ported ClawDeck tests and GameCove's own (packaging/helpers/tests), when pytest is installed
	if OS.execute("python3", ["-c", "import pytest"]) != 0:
		return
	var helpers := ProjectSettings.globalize_path("res://").path_join("../packaging/helpers").simplify_path()
	var out := []
	var code := OS.execute("python3", ["-m", "pytest", "-q", "-p", "no:cacheprovider", helpers.path_join("tests")], out, true)
	eq(code, 0, "pytest: " + str(out[0]).right(600))


# ---- low latency, Proton, wrapper ------------------------------------------------------

func test_low_latency_and_proton_and_wrapper() -> void:
	var w := _world("launch", CLAW)
	_with_game(w, GAME)
	var reg: Node = w["reg"]
	eq(reg.value("perf.low_latency"), true, "Launcher's default")
	reg.set_value("perf.low_latency", false)
	eq(w["launcher"].settings["steam:42"]["low_latency"], false, "saved through Launcher")
	var pc: RefCounted = reg.control("perf.proton")
	eq(pc.options.map(func(o): return o["value"]), ["", "proton_cachyos_11"], "the game's tools")
	reg.set_value("perf.proton", "proton_cachyos_11")
	ok("compat steam:42 proton_cachyos_11" in w["library"].calls, "through Library")
	w["library"].options["steam:42"] = "PROTON_LOG=1 ~/fgmod/fgmod %command% -dx11"
	reg.set_value("perf.launch_wrapper", true)
	eq(w["library"].options["steam:42"], "PROTON_LOG=1 /usr/libexec/gamecove/gamecove-run ~/fgmod/fgmod %command% -dx11", "in front of fgmod, after variables")
	reg.set_value("perf.launch_wrapper", false)
	eq(w["library"].options["steam:42"], "PROTON_LOG=1 ~/fgmod/fgmod %command% -dx11", "taken out again")
	_with_game(w, EPIC)
	eq(reg.control("perf.launch_wrapper").reason, "Only for Steam games (GameCove starts the others itself)", "Steam only")
	_done(w)


func test_wrapper_text() -> void:
	var wr := "/usr/libexec/gamecove/gamecove-run"
	eq(Files.with_wrapper("", wr), wr + " %command%", "empty")
	eq(Files.with_wrapper("-dx11", wr), wr + " %command% -dx11", "arguments only")
	eq(Files.with_wrapper(wr + " %command%", wr), wr + " %command%", "already there")
	eq(Files.without_wrapper(wr + " %command%", wr), "", "back to nothing")
	ok(not Files.has_wrapper("/opt/x/gamecove-run-old %command%", wr), "whole words only")


# ---- shader pre-caching ------------------------------------------------------------------

func test_shader_threads_and_cache() -> void:
	var w := _world("shader", DECK)
	var steam: String = w["home"].path_join(".local/share/Steam")
	_w(steam.path_join("steam_dev.cfg"), "@nClientDownloadEnableHTTP2PlatformLinux 0\n")
	_w(steam.path_join("steamapps/shadercache/42/fozpipelinesv6/steam_pipeline_cache.foz"), "x")
	_with_game(w, GAME)
	var reg: Node = w["reg"]
	eq(reg.value("perf.shader_threads"), 0.0, "Steam's default")
	reg.set_value("perf.shader_threads", 6)
	var cfg := _read(steam.path_join("steam_dev.cfg"))
	ok("@nClientDownloadEnableHTTP2PlatformLinux 0" in cfg and "unShaderBackgroundProcessingThreads 6" in cfg, "line added, others kept")
	reg.set_value("perf.shader_threads", 0)
	ok(not "unShader" in _read(steam.path_join("steam_dev.cfg")), "0 removes it")
	ok(reg.control("perf.clear_shader_cache").available, "cache found")
	reg.set_value("perf.clear_shader_cache", true)
	ok(not DirAccess.dir_exists_absolute(steam.path_join("steamapps/shadercache/42")), "cache removed")
	reg.detect_all()
	eq(reg.control("perf.clear_shader_cache").reason, "No shader cache for this game", "nothing left")
	ok(not Files.remove_shader_cache(steam.path_join("steamapps")), "only shadercache/<appid> folders")
	_done(w)


# ---- launch environment and devices ---------------------------------------------------------

func test_launcher_env_hooks_merge() -> void:
	var l = LauncherScript.new()
	var d := _dir("launcher")
	l.settings_path = d.path_join("launch.json")
	l.home = d
	l.device_profile = ALLY_X
	l.env_hooks.append(func(key, _g): return {"MANGOHUD": "1", "SEEN": key})
	var env: Dictionary = l.launch_env({"key": "epic:abc", "store": "epic", "id": "abc"})
	eq(env.get("MANGOHUD"), "1", "hook's variables")
	eq(env.get("SEEN"), "epic:abc", "hook gets the key")
	l.free()


func test_files_follow_the_device() -> void:
	var w := _world("devices", ALLY_X)
	_with_game(w, GAME)
	w["p"].set_mangohud_limit("steam:42", 45)
	var path := Files.perf_env_path(w["home"], "42")
	ok(Files.read_env(path).has("MANGOHUD"), "written on the Ally")
	# the same drive boots a Claw: its own (empty) values, the Ally's file goes
	var ctx: Dictionary = w["ctx"].duplicate()
	ctx["device"] = CLAW
	var p = PerfProvider.new()
	p.setup(ctx)
	ok(not FileAccess.file_exists(path), "the Ally's file is gone on the Claw")
	eq(_read(Files.launch_dir(w["home"]).path_join(".device")).strip_edges(), "msi-claw-8-ex", "device stamp")
	# and back on the Ally its value comes back
	ctx["device"] = ALLY_X
	var p2 = PerfProvider.new()
	p2.setup(ctx)
	ok(Files.read_env(path).get("MANGOHUD_CONFIG", "").contains("fps_limit=45"), "the Ally's file again")
	_done(w)


func test_env_file_text() -> void:
	eq(Files.render_env({"B": "2", "A": "1", "bad-name": "x", "NL": "a\nb"}),
		"# Written by GameCove (perf controls) for gamecove-run. KEY=VALUE, one per line.\nA=1\nB=2\n", "sorted, unsafe left out")
	eq(Files.steam_appid("steam:976730"), "976730", "app id")
	eq(Files.steam_appid("steam:abc"), "", "not numeric")
	eq(Files.steam_appid("epic:1"), "", "other store")
