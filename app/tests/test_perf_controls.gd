extends "res://tests/test_case.gd"
## Perf controls (providers/perf.gd and scripts/controls/perf/*): overlay
## presets, MangoHud limiter, lsfg-vk profiles, the upscaling helper bridge,
## low latency, Proton, the Steam launch wrapper, shader pre-caching, the
## launch environment and per-device files. Everything runs in a fixture tree
## under user:// with fake services; nothing touches the real system.

const ExecSafe := preload("res://scripts/system/exec_safe.gd")
const ControlsScript := preload("res://scripts/controls/controls.gd")
const PerfProvider := preload("res://scripts/controls/providers/perf.gd")
const Fakes := preload("res://tests/fixtures/perf_controls/fakes.gd")
const Overlay := preload("res://scripts/controls/perf/overlay.gd")
const Lsfg := preload("res://scripts/controls/perf/lsfg.gd")
const SC := preload("res://scripts/steam/steam_config.gd")
const VdfW := preload("res://scripts/steam/vdf_writer.gd")
const Files := preload("res://scripts/controls/perf/launch_files.gd")
const Upscale := preload("res://scripts/controls/perf/upscale.gd")
const MangoHud := preload("res://scripts/perf/mangohud.gd")
const LauncherScript := preload("res://scripts/launch/launcher.gd")
const LaunchEnv := preload("res://scripts/launch/launch_env.gd")
const Proton := preload("res://scripts/launch/proton.gd")
const PrivacyScript := preload("res://scripts/system/privacy.gd")
const UpscaleUpdates := preload("res://scripts/controls/perf/upscale_updates.gd")
const Model := preload("res://scripts/ui/controls/model.gd")
const ControlView := preload("res://scripts/ui/controls/control_view.gd")
const Catalog := preload("res://scripts/ui/controls/catalog.gd")

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
	if not "dll" in leave_out and not "manifest" in leave_out:
		_w(home.path_join(".local/share/Steam/steamapps/appmanifest_993090.acf"), "\"AppState\"\n{\n}\n")
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
			"perf.frame_gen", "perf.upscale_mode", "perf.upscale_offer", "perf.upscale_active", "perf.fg_generator", "perf.upscale_menu", "perf.upscale_undo", "perf.upscaler_update",
			"perf.upscale_game_update", "perf.low_latency", "perf.proton",
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
	eq(w["library"].options.get("steam:42"), Files.launch_prefix("/usr/libexec/gamecove/gamecove-run") + " %command%", "wrapper in the launch options")
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
	eq(w["reg"].control("perf.lsfg").reason, "Needs lsfg-vk: install it below", "no layer")
	_w(w["home"].path_join(".local/share/vulkan/implicit_layer.d").path_join(Lsfg.LAYER_V1), "{}")
	w["reg"].detect_all()
	eq(w["reg"].control("perf.lsfg").reason, "Update lsfg-vk to version 2 below", "1.x layer")
	_done(w)
	var w2 := _world("lsfg_nodll", DECK, ["dll"])
	_with_game(w2, GAME)
	eq(w2["reg"].control("perf.lsfg").reason, "Needs Lossless Scaling, a paid app on Steam", "no DLL")
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
	eq(Upscale.upscalers(Upscale.gpu(DECK)), ["own", "fsr31", "fsr4_amd"], "Steam Deck: FSR 4.1.2 offered, never picked by itself")
	eq(Upscale.frame_gens(Upscale.gpu({"gpu_family": "intel-xe-lpg"})), [0, 2], "Meteor Lake: XeSS frame generation 2x")
	eq(Upscale.generators(Upscale.gpu(ALLY_X)), ["fsrfg", "xefg"], "AMD: FSR first, XeSS as a choice")
	eq(Upscale.upscalers(Upscale.gpu({}, {"vendor": "nvidia"})), ["own"], "NVIDIA: the game's own")
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
	ok(last.begins_with("/usr/libexec/gamecove/gamecove-upscale choose --home ") and "--key epic:abc --dir /games/abc --name Epic Game --upscaler fsr31 --fg 0" in last, "choose call: " + last)
	ok("--gpu {\"arch\":\"RDNA3.5\",\"chip\":\"\",\"family\":\"amd-rdna3\",\"gpu\":\"\",\"tier\":\"amd_rdna35\",\"vendor\":\"amd\",\"xmx\":false} " in last, "GPU facts passed as JSON: " + last)
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
	eq(w3["reg"].control("perf.frame_gen").options.map(func(o): return int(o["value"])), [0, 2], "Meteor Lake: 2x only, never 3x or 4x")
	eq(w3["reg"].control("perf.fg_generator").reason, "One frame generator on this graphics chip", "nothing to choose between")
	_done(w3)


func test_python_and_gdscript_choices_agree() -> void:
	if OS.execute("python3", ["-c", "1"]) != 0:
		return
	var helpers := ProjectSettings.globalize_path("res://").path_join("../packaging/helpers").simplify_path()
	for dev in [CLAW, ALLY_X, DECK, {"gpu_family": "intel-xe-lpg"}, {}]:
		var g := Upscale.gpu(dev)
		# the real argv path (exec_safe), so the JSON --gpu reaches Python intact
		var r := ExecSafe.run("python3", PackedStringArray(["-I", "-c",
			"import sys,json; sys.path.insert(0, sys.argv[1]); from gamecove_upscale import cli, games; g=cli.parse_gpu(sys.argv[2]); print(json.dumps([games.upscalers_for(g), games.fg_for(g)]))",
			helpers, Upscale.gpu_arg(g)]), false)
		eq(r["code"], 0, "python ran")
		eq(JSON.parse_string(str(r["out"]).strip_edges()), [Upscale.upscalers(g), Upscale.frame_gens(g)].map(func(a): return a.map(func(x): return float(x) if x is int else x)), "same choices for %s" % str(dev.get("gpu_family", "?")))


func test_python_helper_tests_pass() -> void:
	# the ported ClawDeck tests and GameCove's own (packaging/helpers/tests), when pytest is installed
	if OS.execute("python3", ["-c", "import pytest"]) != 0:
		return
	var helpers := ProjectSettings.globalize_path("res://").path_join("../packaging/helpers").simplify_path()
	var out := []
	var code := OS.execute("python3", ["-m", "pytest", "-q", "-p", "no:cacheprovider", helpers.path_join("tests")], out, true)
	eq(code, 0, "pytest: " + str(out[0]).right(600))


# ---- upscaler updates (helper check / update / game-update) ---------------------------

const CHECK_UPDATE := {"ok": true, "update": true, "index": {"verified": true, "generated": "2026-11-09T04:23:00Z"},
	"components": [
		{"id": "optiscaler", "name": "OptiScaler", "installed": "0.9.4", "latest": "0.9.5", "update": true},
		{"id": "optipatcher", "name": "OptiPatcher", "installed": "rolling-20261020", "latest": "rolling-20261020", "update": false},
		{"id": "fsr4_amd", "name": "FSR 4 (AMD)", "installed": "20261028-7539ae8b", "latest": "20261028-7539ae8b", "update": false}]}
const CHECK_CURRENT := {"ok": true, "update": false, "index": {"verified": true},
	"components": [
		{"id": "optiscaler", "name": "OptiScaler", "installed": "0.9.5", "latest": "0.9.5", "update": false},
		{"id": "optipatcher", "name": "OptiPatcher", "installed": "rolling-20261020", "latest": "rolling-20261020", "update": false}]}


func _calls_with(runner, verb: String) -> Array:
	return runner.calls.filter(func(c): return (" %s --home " % verb) in c)


func test_upscaler_updates_summary() -> void:
	var s := UpscaleUpdates.summary(CHECK_UPDATE)
	ok(s["update"] and s["reason"] == "", "update available")
	ok(s["help"].begins_with("Update available: OptiScaler 0.9.4 → 0.9.5."), s["help"])
	ok(not "OptiPatcher" in s["help"], "only what has an update")
	var u := UpscaleUpdates.summary(CHECK_CURRENT)
	ok(not u["update"] and u["reason"] == "", "up to date stays usable (press: check now)")
	eq(u["help"], "Up to date: OptiScaler 0.9.5 · OptiPatcher rolling-20261020. Press to check now.", "installed versions shown")
	var stale := CHECK_CURRENT.duplicate(true)
	stale["index"] = {"verified": true, "stale": true, "files_from": "2026-10-02", "generated": "2026-10-02T05:00:00Z"}
	ok(UpscaleUpdates.summary(stale)["help"].begins_with("Up to date (offline, files from 2026-10-02):"), "a month without a check says how old the files are: " + UpscaleUpdates.summary(stale)["help"])
	var pins := CHECK_CURRENT.duplicate(true)
	pins["index"]["verified"] = false
	ok("tested versions" in UpscaleUpdates.summary(pins)["help"], "says when the newest list isn't verified")
	ok(UpscaleUpdates.summary({"ok": true, "components": []})["reason"].begins_with("Nothing downloaded yet"), "nothing yet")
	ok(UpscaleUpdates.summary({"ok": false, "error": "boom"})["reason"].ends_with("boom"), "helper error")
	ok(UpscaleUpdates.summary({})["reason"] != "", "no answer")
	var g := UpscaleUpdates.game_summary({"ok": true, "owner": "gamecove", "opti_version": "0.9.4", "opti_latest": "0.9.5", "game_update": true})
	ok(g["reason"] == "" and "OptiScaler 0.9.4 → 0.9.5" in g["help"], "game: " + g["help"])
	ok("add-ons" in UpscaleUpdates.game_summary({"ok": true, "owner": "gamecove", "opti_version": "0.9.5", "opti_latest": "0.9.5", "game_update": true})["help"], "same OptiScaler, newer OptiPatcher")
	ok("up to date" in UpscaleUpdates.game_summary({"ok": true, "owner": "gamecove", "opti_version": "0.9.5", "opti_latest": "0.9.5", "game_update": false})["reason"], "game current")
	eq(UpscaleUpdates.game_summary({"ok": true, "owner": "decky-framegen"})["reason"], "GameCove's OptiScaler isn't in this game", "not ours")


func test_upscaler_update_row_shows_and_runs_the_update() -> void:
	var w := _world("upscale_updates", ALLY_X)
	var runner = w["runner"]
	var reg: Node = w["reg"]
	runner.answers["check"] = CHECK_UPDATE
	w["p"]._forget_check()
	reg.detect_all()
	var c: RefCounted = reg.control("perf.upscaler_update")
	ok(c.available, "available: " + c.reason)
	ok(c.help.begins_with("Update available: OptiScaler 0.9.4 → 0.9.5"), c.help)
	eq(_calls_with(runner, "check").filter(func(x): return "--online" in x), [], "detecting never goes online")
	# the Upscaling card shows it, with its line
	var m = Model.new()
	m.setup(reg, null)
	var v: Control = ControlView.make(m, "perf.upscaler_update")
	eq(str(v.row.get_script().resource_path).get_file(), "action_row.gd", "an action row")
	ok("Update available: OptiScaler 0.9.4 → 0.9.5" in v.explanation(), "the row says so: " + v.explanation())
	var card: Array = Catalog.cards_for(["perf"], reg.list().map(func(x): return x.id)).filter(func(cd): return cd[0] == "Upscaling and frame generation")[0]
	ok("perf.upscaler_update" in card[3] and "perf.upscale_game_update" in card[3], "on the Upscaling card, under More")
	eq(card[2].slice(0, 3), ["perf.upscale_mode", "perf.upscale_offer", "perf.upscale_active"], "the mode, what it offers and what is running come first")
	# pressing it updates, then reads again
	runner.answers["update"] = {"ok": true, "results": {}, "games": ["epic:abc"]}
	var n_check := _calls_with(runner, "check").size()
	runner.answers["check"] = CHECK_CURRENT
	reg.set_value("perf.upscaler_update", true)
	eq(_calls_with(runner, "update").size(), 1, "update ran once")
	ok(_calls_with(runner, "check").size() > n_check, "checked again after")
	ok(c.help.begins_with("Up to date: OptiScaler 0.9.5"), "now: " + c.help)
	v.refresh()
	ok("Up to date: OptiScaler 0.9.5" in v.explanation(), "the row follows: " + v.explanation())
	# up to date, pressing it checks right away (online)
	reg.set_value("perf.upscaler_update", true)
	eq(_calls_with(runner, "update").size(), 1, "nothing to update: no update call")
	ok(_calls_with(runner, "check")[-1].ends_with("--online"), "checks the signed list now: " + str(_calls_with(runner, "check")[-1]))
	v.free()
	m.setup(null, null)
	_done(w)


func test_upscaler_update_reasons() -> void:
	var w := _world("upscale_updates_none", ALLY_X, ["helper"])
	eq(w["reg"].control("perf.upscaler_update").reason, "Needs GameCove's upscaling helper", "no helper")
	_done(w)
	var w2 := _world("upscale_updates_empty", ALLY_X)
	w2["runner"].answers["check"] = {"ok": true, "components": [], "update": false}
	w2["p"]._forget_check()
	w2["reg"].detect_all()
	ok(w2["reg"].control("perf.upscaler_update").reason.begins_with("Nothing downloaded yet"), "nothing downloaded")
	_done(w2)


func test_game_update_row_updates_the_games_copy() -> void:
	var w := _world("upscale_game_update", ALLY_X)
	var runner = w["runner"]
	runner.answers["status"] = {"ok": true, "upscaler": "fsr31", "fg": 0, "owner": "gamecove", "opti_version": "0.9.4",
		"opti_latest": "0.9.5", "game_update": true}
	runner.answers["game-update"] = {"ok": true, "version": "0.9.5", "was": "0.9.4", "env": {"WINEDLLOVERRIDES": "dxgi=n,b;"}}
	eq(w["reg"].control("perf.upscale_game_update").reason, PerfProvider.NO_GAME, "needs a game")
	_with_game(w, EPIC)
	var c: RefCounted = w["reg"].control("perf.upscale_game_update")
	ok(c.available and "OptiScaler 0.9.4 → 0.9.5" in c.help, c.help + " / " + c.reason)
	runner.answers["status"] = {"ok": true, "upscaler": "fsr31", "fg": 0, "owner": "gamecove", "opti_version": "0.9.5",
		"opti_latest": "0.9.5", "game_update": false}
	w["reg"].set_value("perf.upscale_game_update", true)
	var last: Array = _calls_with(runner, "game-update")
	ok(last.size() == 1 and "--key epic:abc --dir /games/abc" in last[0], "game-update call: " + str(last))
	ok(not c.available and "up to date" in c.reason, "current afterwards: " + c.reason)
	eq(w["p"].launch_env_hook("epic:abc", EPIC).get("WINEDLLOVERRIDES"), "dxgi=n,b;", "launch env kept")
	_done(w)


func test_background_check_is_daily_and_follows_the_privacy_switch() -> void:
	var w := _world("upscale_bg", ALLY_X)
	var base := ProjectSettings.globalize_path("user://test_perf_controls/upscale_bg")
	var prefs := base.path_join("settings.cfg")
	var stamp := base.path_join("upscalers.cfg")
	w["ctx"]["privacy_path"] = prefs
	w["ctx"]["upscale_stamp_path"] = stamp
	var runner = w["runner"]
	runner.answers["check"] = CHECK_UPDATE
	var p = w["p"]
	var now := 1_800_000_000
	ok(PrivacyScript.set_background_allowed(false, prefs), "switch off")
	ok(not p.background_check(now), "off: no background check")
	eq(_calls_with(runner, "check").filter(func(x): return "--online" in x), [], "nothing went online")
	eq(_calls_with(runner, "refresh"), [], "and no list refresh")
	eq(UpscaleUpdates.last_check(stamp), 0, "and nothing recorded")
	PrivacyScript.set_background_allowed(true, prefs)
	ok(p.background_check(now), "on: checks")
	eq(_calls_with(runner, "check").filter(func(x): return "--online" in x).size(), 1, "one online check")
	eq(_calls_with(runner, "refresh").size(), 1, "the per-game lists (signed games.json, OptiScaler's notes) refresh with it")
	eq(UpscaleUpdates.last_check(stamp), now, "recorded")
	ok(not p.background_check(now + 3600), "not again within a day")
	ok(p.background_check(now + UpscaleUpdates.INTERVAL_S), "again a day later")
	ok(UpscaleUpdates.due(now, now - 10, true), "a clock set back doesn't block it forever")
	ok(not UpscaleUpdates.due(0, now, false), "never with the switch off")
	_done(w)


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
	eq(w["library"].options["steam:42"], "PROTON_LOG=1 " + Files.launch_prefix("/usr/libexec/gamecove/gamecove-run") + " ~/fgmod/fgmod %command% -dx11", "in front of fgmod, after variables")
	reg.set_value("perf.launch_wrapper", false)
	eq(w["library"].options["steam:42"], "PROTON_LOG=1 ~/fgmod/fgmod %command% -dx11", "taken out again")
	_with_game(w, EPIC)
	eq(reg.control("perf.launch_wrapper").reason, "Only for Steam games (GameCove starts the others itself)", "Steam only")
	_done(w)


func test_low_latency_follows_frame_generation() -> void:
	var w := _world("lowlat_fg", DECK)
	_with_game(w, GAME)
	var reg: Node = w["reg"]
	var ll: RefCounted = reg.control("perf.low_latency")
	ok(ll.available, "frame generation off: the override is free")
	eq(ll.help, PerfProvider.LOW_LATENCY_HELP, "says to leave it on")
	reg.set_value("perf.low_latency", false)
	eq(reg.value("perf.low_latency"), false, "off allowed without frame generation")
	reg.set_value("perf.lsfg", true)
	ok(not ll.available, "frame generation on: can't be changed")
	eq(ll.reason, PerfProvider.LOW_LATENCY_WITH_FG, "and says why")
	eq(ll.value, true, "shows On")
	eq(ll.write(false), false, "a write of Off is refused")
	eq(w["launcher"].frame_gen_hooks.size(), 1, "the launcher asks the provider")
	ok(w["launcher"].frame_gen_hooks[0].call("steam:42"), "frame generation on for the launch")
	var plan := LaunchEnv.compose(w["launcher"].settings_for("steam:42"), {"gpu_family": "amd-rdna3"},
		Proton.classify("proton-cachyos-11.0-20260702-slr"), {}, {"frame_gen_on": w["launcher"].frame_gen_hooks[0].call("steam:42")})
	eq(plan["env"].get("LOW_LATENCY_LAYER"), "1", "launch env has it although the saved setting says off")
	reg.set_value("perf.lsfg", false)
	ok(ll.available, "frame generation off again: the override is back")
	eq(reg.value("perf.low_latency"), false, "with the user's own value")
	ok(not w["launcher"].frame_gen_hooks[0].call("steam:42"), "no longer forced at launch")
	_done(w)


func test_wrapper_text() -> void:
	var wr := "/usr/libexec/gamecove/gamecove-run"
	var sh := Files.launch_prefix(wr)
	eq(sh, "/bin/sh -c '[ -x %s ] && exec %s \"$@\"; exec \"$@\"' gamecove-run" % [wr, wr], "fall-through shim")
	eq(Files.with_wrapper("", wr), sh + " %command%", "empty")
	eq(Files.with_wrapper("-dx11", wr), sh + " %command% -dx11", "arguments only")
	eq(Files.with_wrapper(sh + " %command%", wr), sh + " %command%", "already there")
	eq(Files.without_wrapper(sh + " %command%", wr), "", "back to nothing")
	ok(not Files.has_wrapper("/opt/x/gamecove-run-old %command%", wr), "whole words only")
	# review S2-1: an old bare path (a missing file stops the game) is recognised and replaced
	ok(Files.has_legacy_wrapper(wr + " %command%", wr), "legacy form seen")
	ok(not Files.has_legacy_wrapper(sh + " %command%", wr), "the shim isn't legacy")
	eq(Files.with_wrapper("DXVK_HUD=1 " + wr + " %command% -dx11", wr), "DXVK_HUD=1 " + sh + " %command% -dx11", "legacy upgraded in place")
	eq(Files.without_wrapper("DXVK_HUD=1 " + wr + " %command%", wr), "DXVK_HUD=1 %command%", "legacy taken out")
	eq(Files.strip_all_wrappers(Files.launch_prefix("/opt/old/gamecove-run") + " %command% -dx11"), "%command% -dx11", "any path's shim stripped")
	eq(Files.strip_all_wrappers("/usr/libexec/gamecove/gamecove-run ~/fgmod/fgmod %command%"), "~/fgmod/fgmod %command%", "any bare path stripped")


func test_wrapper_shim_falls_through_when_gamecove_is_gone() -> void:
	# review S2-1: run the exact launch options the way Steam does (through sh) with the wrapper missing.
	# (From a script file: OS.execute with output goes through popen, whose quoting expands "$@".)
	var dir := ProjectSettings.globalize_path("user://test_perf/shim")
	DirAccess.make_dir_recursive_absolute(dir)
	var gone := dir + "/missing/gamecove-run"
	eq(_run_launch(dir, Files.with_wrapper("", gone)), "game-started", "the game still starts without the wrapper")
	var real := dir + "/gamecove-run"
	_w(real, "#!/bin/sh\necho wrapped\nexec \"$@\"\n")
	OS.execute("chmod", PackedStringArray(["+x", real]))
	eq(_run_launch(dir, Files.with_wrapper("", real)), "wrapped game-started", "with the wrapper: through it")


func _run_launch(dir: String, options: String) -> String:
	_w(dir + "/launch.sh", options.replace("%command%", "echo game-started") + "\n")
	var out := []
	OS.execute("/bin/sh", PackedStringArray([dir + "/launch.sh"]), out, true)
	return " ".join(str(out[0]).split("\n", false)) if not out.is_empty() else ""


func test_unwrap_every_steam_game() -> void:
	# review S2-1: uninstall / Repair take the wrapper out of every game of every account
	var home := ProjectSettings.globalize_path("user://test_perf/unwrap")
	var root := home.path_join(".local/share/Steam")
	DirAccess.remove_absolute(home.path_join(".steam/steam.pid"))  # a previous run's
	var wr := "/usr/libexec/gamecove/gamecove-run"
	var vdf := "\"UserLocalConfigStore\"\n{\n\t\"Software\"\n\t{\n\t\t\"Valve\"\n\t\t{\n\t\t\t\"Steam\"\n\t\t\t{\n\t\t\t\t\"apps\"\n\t\t\t\t{\n" \
		+ "\t\t\t\t\t\"10\"\n\t\t\t\t\t{\n\t\t\t\t\t\t\"LaunchOptions\"\t\t\"%s\"\n\t\t\t\t\t}\n" % VdfW.escape(Files.with_wrapper("-dx11", wr)) \
		+ "\t\t\t\t\t\"20\"\n\t\t\t\t\t{\n\t\t\t\t\t\t\"LaunchOptions\"\t\t\"%s\"\n\t\t\t\t\t}\n" % VdfW.escape(wr + " %command%") \
		+ "\t\t\t\t\t\"30\"\n\t\t\t\t\t{\n\t\t\t\t\t\t\"LaunchOptions\"\t\t\"gamemoderun %command%\"\n\t\t\t\t\t}\n" \
		+ "\t\t\t\t}\n\t\t\t}\n\t\t}\n\t}\n}\n"
	for uid in ["111", "222"]:
		_w(root.path_join("userdata/%s/config/localconfig.vdf" % uid), vdf)
	var up: Dictionary = Files.upgrade_legacy_all(home, root, wr, home)
	eq(up["error"], OK)
	eq(up["changed"], ["20", "20"], "only the bare-path entry is upgraded, in both accounts")
	eq(SC.launch_options(root.path_join("userdata/111"), "20"), Files.launch_prefix(wr) + " %command%", "now the fall-through form")
	var r: Dictionary = Files.unwrap_all(home, root, home)
	eq(r["error"], OK)
	eq(r["changed"].size(), 4, "two games x two accounts")
	eq(SC.launch_options(root.path_join("userdata/222"), "10"), "%command% -dx11", "game arguments kept")
	eq(SC.launch_options(root.path_join("userdata/222"), "20"), "", "nothing left")
	eq(SC.launch_options(root.path_join("userdata/111"), "30"), "gamemoderun %command%", "others untouched")
	# Steam running: refused (it would write the file back from memory)
	_w(home.path_join(".steam/steam.pid"), "4242")
	_w(home.path_join("4242/comm"), "steam")
	eq(Files.unwrap_all(home, root, home)["error"], ERR_BUSY, "refused while Steam runs")


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


## Review 2, low 23: lsfg-vk's conf.toml (with the user's own profiles) was rewritten in place.
func test_lsfg_config_is_replaced_atomically() -> void:
	var SettingsFile := preload("res://scripts/system/settings_file.gd")
	var w := _world("lsfg_atomic", DECK)
	var cfg: String = w["home"].path_join(Lsfg.CONFIG)
	var mine := "version = 2\n\n[[profile]]\nname = \"mine\"\nactive_in = [ \"mpv\" ]\n"
	_w(cfg, mine)
	_with_game(w, GAME)
	SettingsFile.test_write_limit = 0
	w["reg"].set_value("perf.lsfg", true)
	SettingsFile.test_write_limit = -1
	eq(_read(cfg), mine, "a failed write keeps the user's file whole")
	ok(not FileAccess.file_exists(cfg + ".tmp"), "no temp file left")
	var src := FileAccess.get_file_as_string("res://scripts/controls/providers/perf.gd")
	var body := src.substr(src.find("func write_lsfg_config"), 1600)
	ok(not "FileAccess.WRITE" in body.substr(0, body.find("\nfunc ", 10)), "written through settings_file.gd, not in place")
	_done(w)


# ---- Best / My choice / Native, what is running, one frame generator ------------------

## The game is changed on the main thread (quick menu, game page) while the
## Controls worker reads it. It used to be two keys added to and erased from
## the shared context, which crashed a reader on the worker (SIGABRT in game()).
func test_the_game_can_change_while_the_worker_reads_it() -> void:
	var w := _world("game_race", ALLY_X)
	var ctx: Dictionary = w["ctx"]
	var p = w["p"]
	var keys_before := ctx.keys()
	keys_before.sort()
	PerfProvider.set_game(ctx, EPIC)
	eq(p.game_key(), "epic:abc", "the provider sees the game")
	var keys_after := ctx.keys()
	keys_after.sort()
	eq(keys_after, keys_before, "changing the game never adds a key to the shared context")
	ok(not ctx.has("game") and not ctx.has("game_key"), "the game isn't kept in the context's own keys")
	# the stored game is a copy: the caller changing its dictionary later doesn't reach a reader
	var mine := {"key": "gog:9", "store": "gog", "id": "9", "title": "Before"}
	PerfProvider.set_game(ctx, mine)
	mine["title"] = "After"
	eq(str(p.game().get("title", "")), "Before", "a reader keeps the game as it was set")
	# stress: the worker reads without pause while the main thread swaps the game and clears it
	var other := {"key": "steam:42", "store": "steam", "id": "42", "title": "Steam Game", "install_path": "/games/42"}
	var stop := [false]
	var seen := {"reads": 0, "bad": []}
	PerfProvider.set_game(ctx, {})   # the reader starts on "none", one of the values it may see
	var reader := Thread.new()
	reader.start(func():
		while not stop[0]:
			var k: String = p.game_key()
			var g: Dictionary = p.game()
			var gk := str(g.get("key", ""))
			if not k in ["", "epic:abc", "steam:42"] or not gk in ["", "epic:abc", "steam:42"]:
				seen["bad"].append([k, gk])
			if gk == "steam:42" and str(g.get("install_path", "")) != "/games/42":
				seen["bad"].append(["torn", g])
			seen["reads"] += 1)
	# a loaded machine may not run the reader at once: wait for it, then swap until it has read
	# a fair number of times while the game changes (not only a fixed count of swaps)
	var t0 := Time.get_ticks_msec()
	while int(seen["reads"]) == 0 and Time.get_ticks_msec() - t0 < 5000:
		OS.delay_usec(500)
	var start_reads := int(seen["reads"])
	var i := 0
	while i < 20000 or (int(seen["reads"]) - start_reads < 200 and Time.get_ticks_msec() - t0 < 10000):
		PerfProvider.set_game(ctx, [EPIC, other, {}][i % 3])
		i += 1
	stop[0] = true
	reader.wait_to_finish()
	ok(int(seen["reads"]) > 0, "the worker read while the game changed (%d reads)" % int(seen["reads"]))
	eq(seen["bad"], [], "every read saw a whole game or none")
	PerfProvider.set_game(ctx, {})
	eq(p.game_key(), "", "cleared")
	eq(ctx.keys().size(), keys_before.size(), "and the context is as it was")
	_done(w)


## Every alternative says in one plain line what it is.
func test_every_choice_has_its_own_plain_line() -> void:
	for chip in [CLAW, ALLY_X]:
		var w := _world("option_lines_" + str(chip.get("id", "x")), chip)
		runner_ok(w)
		_with_game(w, EPIC)
		var reg: Node = w["reg"]
		for id in ["perf.upscaler", "perf.frame_gen", "perf.fg_generator", "perf.lsfg_multiplier"]:
			var c: RefCounted = reg.control(id)
			for o in c.options:
				ok(str(o.get("help", "")).length() > 12 and str(o["help"]).length() < 130, "%s / %s has a short line: %s" % [id, str(o["label"]), str(o.get("help", ""))])
				ok(not "OptiScaler" in str(o.get("help", "")), "in plain words, no tool names")
		var mode: RefCounted = reg.control("perf.upscale_mode")
		var by := {}
		for o in mode.options:
			by[o["value"]] = str(o.get("help", ""))
		ok(by["native"].contains("as it shipped") and by["custom"] != "", "Native and My choice explain themselves")
		eq(by["best"], "", "Best's line is what the plan picked for this game")
		_done(w)
	# the row shows the line of the option in view, and the reason when it can't be used
	var w2 := _world("option_lines_row", CLAW)
	runner_ok(w2)
	_with_game(w2, EPIC)
	var m = Model.new()
	m.setup(w2["reg"], null)
	var v: Control = ControlView.make(m, "perf.frame_gen")
	eq(v._option_line(3, "the control's own line"), Upscale.FG_HELP[3], "3x says what 3x is")
	eq(v._option_line(0, "the control's own line"), Upscale.FG_HELP[0], "Off too")
	eq(v._option_line(8, "the control's own line"), "the control's own line", "an option without a line keeps the control's")
	var mv: Control = ControlView.make(m, "perf.upscale_mode")
	eq(mv._option_line("best", "Best here: FSR 4.1.2 on XMX."), "Best here: FSR 4.1.2 on XMX.", "Best shows what was picked for this game")
	eq(mv._option_line("native", "x"), Upscale.MODE_HELP["native"], "Native says what it does")
	mv.desc["available"] = false
	eq(mv._option_line("native", "Off for this game: it uses anti-cheat"), "Off for this game: it uses anti-cheat", "why not wins over any option line")
	# "Running now" is a read-out: its line shows without focus, and its button says what it does
	var av: Control = ControlView.make(m, "perf.upscale_active")
	ok(not av.row.collapse_hint, "the read-out stays in view")
	eq(av.row.value_label.text, "Check again", "the button says what a press does, not Run")
	var undo: Control = ControlView.make(m, "perf.upscale_undo")
	ok(undo.row.collapse_hint and undo.row.value_label.text == "Remove", "other action rows fold their line away until focused")
	undo.free()
	av.free()
	v.free()
	mv.free()
	_done(w2)
	eq(Upscale.upscaler_help({"vendor": "amd", "arch": "RDNA2", "chip": "AMD Van Gogh"})["fsr4_amd"], Upscale.FSR4_HEAVY_HELP, "FSR 4 is called heavy where it is")
	ok(Upscale.upscaler_help({"vendor": "amd", "arch": "RDNA3", "chip": "AMD Ryzen Z1 Extreme"})["fsr4_amd"].contains("sharpest"), "and the best pick on a Z1 Extreme")


func runner_ok(w: Dictionary) -> void:
	w["runner"].answers["status"] = {"ok": true, "mode": "best", "upscaler": "own", "fg": 0, "owner": "none", "env": {},
		"active": {"state": "own", "line": "Using the game's own upscaler. Nothing of ours is in this game."}}
	w["runner"].answers["prepare"] = {"ok": true, "did": ""}
	w["runner"].answers["plan"] = {"ok": true, "line": "", "auto": false, "refused": null}


## Set up when a game is installed or updated, not at its first start.
func test_a_game_is_set_up_when_it_is_installed_or_updated() -> void:
	var w := _world("prepare_installed", ALLY_X)
	var runner = w["runner"]
	runner.answers["status"] = {"ok": true, "mode": "best", "upscaler": "fsr4_amd", "fg": 0, "owner": "gamecove",
		"env": {"WINEDLLOVERRIDES": "dxgi=n,b;", "PROTON_FSR4_UPGRADE": "1"}, "active": {"state": "waiting", "line": "Ready"}}
	runner.answers["prepare"] = {"ok": true, "did": "set up", "mode": "best"}
	runner.answers["plan"] = {"ok": true, "line": "Best here: FSR 4.1.2.", "auto": true, "refused": null}
	var prepare: Variant = w["ctx"].get("prepare_installed")
	ok(prepare is Callable and (prepare as Callable).is_valid(), "main reaches it through the controls' context")
	# no game page is open: the installed game is set up all the same
	var r: Dictionary = (prepare as Callable).call(EPIC, true)
	eq(str(r.get("did", "")), "set up", "set up right after the install")
	var calls := _calls_with(runner, "prepare")
	eq(calls.size(), 1, "one helper run")
	ok("epic:abc" in calls[0] or "abc" in calls[0], "for that game: " + calls[0])
	eq(w["p"].launch_env_hook("epic:abc", EPIC).get("PROTON_FSR4_UPGRADE"), "1", "its first start already has the upscaler's settings")
	_with_game(w, EPIC)
	eq(_calls_with(runner, "prepare").size(), 1, "opening its page afterwards doesn't do it twice")
	# an update: checked again (the update may have removed our files)
	runner.answers["prepare"] = {"ok": true, "did": "put back after a game update", "mode": "best"}
	(prepare as Callable).call(EPIC, true)
	eq(_calls_with(runner, "prepare").size(), 2, "an update is looked at again")
	# while another game runs nothing is started; the next look does it
	(prepare as Callable).call(EPIC, false)
	eq(_calls_with(runner, "prepare").size(), 2, "nothing runs behind a running game")
	w["reg"].detect_all()
	eq(_calls_with(runner, "prepare").size(), 3, "done at the next look instead")
	eq((prepare as Callable).call({}, true), {}, "no game: nothing")
	_done(w)


func test_mode_row_sets_the_game_up_once_and_says_what_best_picks() -> void:
	var w := _world("mode_best", ALLY_X)
	var runner = w["runner"]
	var reg: Node = w["reg"]
	runner.answers["status"] = {"ok": true, "mode": "best", "upscaler": "fsr4_amd", "fg": 0, "owner": "gamecove",
		"env": {"WINEDLLOVERRIDES": "dxgi=n,b;", "PROTON_FSR4_UPGRADE": "1"},
		"active": {"state": "waiting", "line": "Ready: FSR 4.1.2. Start the game, then pick DLSS or FSR in its graphics menu."}}
	runner.answers["prepare"] = {"ok": true, "did": "set up", "mode": "best"}
	runner.answers["plan"] = {"ok": true, "line": "Best here: FSR 4.1.2. OptiScaler turns the game's DLSS into FSR 4.1.2.", "auto": true, "refused": null}
	_with_game(w, EPIC)
	var c: RefCounted = reg.control("perf.upscale_mode")
	ok(c.available, "available: " + c.reason)
	eq(c.value, "best", "Best is the default")
	eq(c.options.map(func(o): return o["value"]), ["best", "custom", "native"], "three plain choices")
	eq(c.options.map(func(o): return o["label"]), ["Best for this handheld", "My choice", "Native (nothing added)"], "in plain words")
	ok(c.help.begins_with("Best here: FSR 4.1.2."), "says what it picked: " + c.help)
	eq(_calls_with(runner, "prepare").size(), 1, "set up ahead of the first start")
	reg.detect_all()
	reg.detect_all()
	eq(_calls_with(runner, "prepare").size(), 1, "once per game and session, not at every look")
	var env: Dictionary = w["p"].launch_env_hook("epic:abc", EPIC)
	eq(env.get("PROTON_FSR4_UPGRADE"), "1", "a non-Steam start gets what prepare set")
	var a: RefCounted = reg.control("perf.upscale_active")
	ok(a.available and a.help.begins_with("Ready: FSR 4.1.2."), "the read-out: " + a.help)
	_done(w)


func test_native_takes_everything_out_in_one_press() -> void:
	var w := _world("mode_native", ALLY_X)
	var runner = w["runner"]
	var reg: Node = w["reg"]
	runner.answers["status"] = {"ok": true, "mode": "best", "upscaler": "fsr31", "fg": 2, "owner": "gamecove", "env": {"WINEDLLOVERRIDES": "dxgi=n,b;"}}
	runner.answers["prepare"] = {"ok": true, "did": ""}
	runner.answers["plan"] = {"ok": true, "line": "Best here: FSR 3.1."}
	runner.answers["mode"] = {"ok": true, "mode": "native"}
	_with_game(w, EPIC)
	runner.answers["status"] = {"ok": true, "mode": "native", "upscaler": "own", "fg": 0, "owner": "none", "env": {},
		"active": {"state": "own", "line": "Using the game's own upscaler. Nothing of ours is in this game."}}
	reg.set_value("perf.upscale_mode", "native")
	var last: Array = _calls_with(runner, "mode")
	ok(last.size() == 1 and "--mode native" in last[0] and "--key epic:abc" in last[0], "one helper call: " + str(last))
	eq(w["p"].launch_env_hook("epic:abc", EPIC).has("WINEDLLOVERRIDES"), false, "nothing of ours reaches the next start")
	ok(w["p"].upscale_native("epic:abc"), "the launcher is told Native: no Proton FSR 4 upgrade either")
	reg.detect_all()
	eq(reg.control("perf.upscale_mode").value, "native", "stays Native")
	eq(reg.control("perf.upscaler").value, "own", "the game's own")
	ok("Nothing of ours" in reg.control("perf.upscale_active").help, reg.control("perf.upscale_active").help)
	runner.calls.clear()
	reg.set_value("perf.upscale_undo", true)
	ok(_calls_with(runner, "mode").size() == 1 and "--mode native" in _calls_with(runner, "mode")[0], "Remove is the same as Native")
	_done(w)


func test_anticheat_games_get_nothing_and_say_why() -> void:
	var w := _world("mode_anticheat", ALLY_X)
	var runner = w["runner"]
	w["launcher"].anticheat_keys = ["epic:abc"]
	runner.answers["status"] = {"ok": true, "mode": "best", "upscaler": "own", "fg": 0, "owner": "none"}
	runner.answers["prepare"] = {"ok": true, "did": ""}
	runner.answers["plan"] = {"ok": true, "refused": "anticheat", "line": "This game uses Easy Anti-Cheat. We never put an upscaler into a game with anti-cheat: it can get an account banned. The game's own settings still work."}
	_with_game(w, EPIC)
	var c: RefCounted = w["reg"].control("perf.upscale_mode")
	eq(c.available, false, "nothing to choose")
	eq(c.reason, "Off for this game: it uses anti-cheat", "says why")
	ok("--anticheat" in _calls_with(runner, "prepare")[0] and "--anticheat" in _calls_with(runner, "plan")[0], "the app's own anti-cheat data reaches the helper")
	eq(w["reg"].control("perf.lsfg").reason, "Off for this game: it uses anti-cheat", "Lossless too")
	_done(w)


func test_best_downloads_nothing_by_itself_with_background_lookups_off() -> void:
	var w := _world("mode_privacy", ALLY_X)
	var base := ProjectSettings.globalize_path("user://test_perf_controls/mode_privacy")
	var prefs := base.path_join("settings.cfg")
	w["ctx"]["privacy_path"] = prefs
	ok(PrivacyScript.set_background_allowed(false, prefs), "Background lookups off")
	var runner = w["runner"]
	var wait := "Background lookups are off, so we don't download the upscaler by ourselves. Pick it here and it downloads now."
	runner.answers["status"] = {"ok": true, "mode": "best", "upscaler": "own", "fg": 0, "owner": "none", "env": {}}
	runner.answers["prepare"] = {"ok": true, "did": "", "waiting": wait}
	runner.answers["plan"] = {"ok": true, "line": "Best here: FSR 4.1.2.", "auto": true, "refused": null}
	_with_game(w, EPIC)
	var calls := _calls_with(runner, "prepare")
	ok(calls.size() == 1 and "--no-download" in calls[0], "what Best does by itself fetches nothing: " + str(calls))
	ok("Background lookups are off" in w["reg"].control("perf.upscale_mode").help, "and says so: " + w["reg"].control("perf.upscale_mode").help)
	runner.answers["choose"] = {"ok": true, "env": {}}
	w["reg"].set_value("perf.upscaler", "fsr31")
	ok(not "--no-download" in _calls_with(runner, "choose")[0], "the player's own pick still downloads")
	PrivacyScript.set_background_allowed(true, prefs)
	w["p"].prepare_installed(EPIC)
	ok(not "--no-download" in _calls_with(runner, "prepare")[-1], "with the switch on, Best may fetch")
	_done(w)


func test_online_and_unknown_games_are_offered_never_added_by_themselves() -> void:
	var w := _world("mode_offer", ALLY_X)
	var runner = w["runner"]
	var reg: Node = w["reg"]
	var warn := "This is an online game. An upscaler in its files can break its rules and get the account banned, so we don't add one by ourselves. Press Add to put FSR 4.1.2 in if you accept that risk."
	runner.answers["status"] = {"ok": true, "mode": "best", "upscaler": "own", "fg": 0, "owner": "none", "env": {}}
	runner.answers["prepare"] = {"ok": true, "did": ""}
	runner.answers["plan"] = {"ok": true, "line": warn, "auto": false, "refused": null, "online": true, "offer": "fsr4_amd"}
	_with_game(w, EPIC)
	eq(_calls_with(runner, "opt-in").size(), 0, "nothing is put in by itself")
	eq(reg.control("perf.upscale_mode").help, warn, "the mode row says why, in plain words")
	var c: RefCounted = reg.control("perf.upscale_offer")
	ok(c.available, "offered: " + c.reason)
	eq(c.title, "Add FSR 4.1.2 to this game", "our pick is the one offered")
	eq(c.help, warn, "with the plain warning")
	# review H1: the Upscaler and Frame generation rows wait for the same Add step (the helper refuses them as well)
	for id in ["perf.upscaler", "perf.frame_gen"]:
		ok(not reg.control(id).available and "press Add first" in reg.control(id).reason, id + " waits for Add: " + reg.control(id).reason)
	runner.answers["opt-in"] = {"ok": true, "did": "set up", "mode": "best"}
	runner.answers["status"] = {"ok": true, "mode": "best", "upscaler": "fsr4_amd", "fg": 0, "owner": "gamecove", "env": {"WINEDLLOVERRIDES": "dxgi=n,b;"}}
	reg.set_value("perf.upscale_offer", true)
	var calls := _calls_with(runner, "opt-in")
	ok(calls.size() == 1 and "--key epic:abc" in calls[0], "one press, the player's pick: " + str(calls))
	eq(w["p"].launch_env_hook("epic:abc", EPIC).get("WINEDLLOVERRIDES"), "dxgi=n,b;", "and the next start has it")
	runner.answers["plan"] = {"ok": true, "line": "Best here: FSR 4.1.2.", "auto": true, "refused": null, "opted_in": true}
	w["p"]._forget_status()
	reg.detect_all()
	ok(not reg.control("perf.upscale_offer").available, "nothing left to offer once added")
	ok(reg.control("perf.upscaler").available, "and the Upscaler row is open: " + reg.control("perf.upscaler").reason)
	_done(w)


func test_the_launch_asks_the_helpers_plan_whether_to_keep_hands_off() -> void:
	# review H3: one per-game fact (the plan's hands_off) for the launch swap, kept with the game's values
	var w := _world("hands_off_launch", ALLY_X)
	var runner = w["runner"]
	var launcher = w["launcher"]
	ok(launcher.hands_off_hooks.size() == 1, "the provider is on the launcher's list")
	var nikki := {"key": "epic:nikki", "store": "epic", "id": "nikki", "title": "Infinity Nikki", "install_path": "/games/nikki"}
	runner.answers["plan"] = {"ok": true, "hands_off": true, "refused": "anticheat", "line": "x"}
	ok(launcher.hands_off_hooks[0].call("epic:nikki", nikki), "refused: hands off")
	var calls := _calls_with(runner, "plan")
	ok(calls.size() == 1 and "--name Infinity Nikki" in calls[0] and "--dir /games/nikki" in calls[0], "asked for that game: " + str(calls))
	ok(launcher.hands_off_hooks[0].call("epic:nikki", nikki), "answered again within the plan's lifetime")
	eq(_calls_with(runner, "plan").size(), 1, "without another helper run")
	ok(w["p"].store.get_value("epic:nikki", "upscale_hands_off", false), "kept with the game's values")
	runner.answers["plan"] = {"ok": true, "hands_off": false, "refused": null, "line": "x"}
	w["p"]._hands_off_cache.clear()
	ok(not launcher.hands_off_hooks[0].call("epic:nikki", nikki), "added to the game: not held back")
	ok(not w["p"].store.has_value("epic:nikki", "upscale_hands_off"), "and the kept fact is gone")
	runner.answers["plan"] = {"ok": false, "error": "helper failed"}
	w["p"].store.set_value("epic:nikki", "upscale_hands_off", true)
	w["p"]._hands_off_cache.clear()
	ok(launcher.hands_off_hooks[0].call("epic:nikki", nikki), "a helper that fails keeps the last known answer")
	_done(w)


func test_every_helper_call_for_a_game_carries_its_title() -> void:
	# review H2: the lists' notes (anti-cheat named, online game) are found by title; a non-Steam game has no app id,
	# so Infinity Nikki from Epic was planned as "unknown" with no ban line
	var w := _world("helper_title", ALLY_X)
	var runner = w["runner"]
	var reg: Node = w["reg"]
	runner.answers["status"] = {"ok": true, "mode": "best", "upscaler": "own", "fg": 0, "owner": "none", "env": {}}
	runner.answers["prepare"] = {"ok": true, "did": ""}
	runner.answers["plan"] = {"ok": true, "line": "Best here: FSR 3.1.", "auto": true, "refused": null}
	runner.answers["choose"] = {"ok": true, "env": {}}
	var nikki := {"key": "epic:nikki", "store": "epic", "id": "nikki", "title": "Infinity Nikki", "install_path": "/games/nikki"}
	_with_game(w, nikki)
	reg.set_value("perf.upscaler", "fsr31")
	for verb in ["status", "plan", "prepare", "choose"]:
		var calls := _calls_with(runner, verb)
		ok(not calls.is_empty(), verb + " was asked")
		for c in calls:
			ok("--name Infinity Nikki" in c, verb + " names the game: " + c)
	w["p"].prepare_installed(nikki)
	for c in _calls_with(runner, "prepare"):
		ok("--name Infinity Nikki" in c, "an install-time prepare names it too: " + c)
	_done(w)


func test_upscaler_changes_wait_until_the_game_has_quit() -> void:
	# review M7: changing the upscaler while the game ran rewrote DLLs the game had loaded
	var w := _world("upscale_running", ALLY_X)
	var runner = w["runner"]
	var reg: Node = w["reg"]
	runner.answers["status"] = {"ok": true, "mode": "best", "upscaler": "fsr4_amd", "fg": 0, "owner": "gamecove",
		"env": {"WINEDLLOVERRIDES": "dxgi=n,b;"}, "active": {"state": "active", "line": "Active: FSR 4.1.2"}}
	runner.answers["prepare"] = {"ok": true, "did": ""}
	runner.answers["plan"] = {"ok": true, "line": "Best here: FSR 4.1.2.", "auto": true, "refused": null}
	runner.answers["choose"] = {"ok": true, "env": {"WINEDLLOVERRIDES": "dxgi=n,b;"}}
	_with_game(w, EPIC)
	w["ctx"]["upscale_launch_grace_ms"] = 0
	(w["ctx"]["upscale_running"] as Callable).call("epic:abc")
	runner.calls.clear()
	reg.set_value("perf.upscaler", "fsr31")
	eq(_calls_with(runner, "choose").size(), 0, "nothing in the game's folder changes while it runs")
	reg.detect_all()
	eq(reg.control("perf.upscaler").value, "fsr31", "the pick shows")
	ok("when you quit the game" in reg.control("perf.upscale_active").help, reg.control("perf.upscale_active").help)
	eq(w["p"].launch_env_hook("epic:abc", EPIC).get("WINEDLLOVERRIDES"), "dxgi=n,b;", "the running setup keeps its launch settings")
	(w["ctx"]["upscale_running"] as Callable).call("")
	w["p"]._forget_status()
	reg.detect_all()
	var calls := _calls_with(runner, "choose")
	ok(calls.size() == 1 and "--upscaler fsr31" in calls[0], "made once the game has quit: " + str(calls))
	reg.detect_all()
	eq(_calls_with(runner, "choose").size(), 1, "and only once")
	# the game's own profile settings still go in as it starts (Proton hasn't loaded it yet)
	w["ctx"]["upscale_launch_grace_ms"] = 60000
	(w["ctx"]["upscale_running"] as Callable).call("epic:abc")
	reg.set_value("perf.upscaler", "fsr4_amd")
	eq(_calls_with(runner, "choose").size(), 2, "at the start: made at once")
	_done(w)


func test_a_held_change_survives_a_power_off_and_game_update_is_held_too() -> void:
	# review M: "game-update" ran while the game had its files loaded, and a held change lived in memory only, so
	# a handheld switched off during the game lost the pick silently
	var w := _world("held_persist", ALLY_X)
	var runner = w["runner"]
	var reg: Node = w["reg"]
	runner.answers["status"] = {"ok": true, "mode": "best", "upscaler": "fsr4_amd", "fg": 0, "owner": "gamecove",
		"env": {}, "game_update": true, "opti_version": "0.9.4", "opti_latest": "0.9.5"}
	runner.answers["prepare"] = {"ok": true, "did": ""}
	runner.answers["plan"] = {"ok": true, "line": "Best here: FSR 4.1.2.", "auto": true, "refused": null}
	runner.answers["choose"] = {"ok": true, "env": {}}
	runner.answers["game-update"] = {"ok": true, "version": "0.9.5"}
	_with_game(w, EPIC)
	w["ctx"]["upscale_launch_grace_ms"] = 0
	(w["ctx"]["upscale_running"] as Callable).call("epic:abc")
	runner.calls.clear()
	reg.set_value("perf.upscaler", "fsr31")
	reg.set_value("perf.upscale_game_update", true)
	eq(_calls_with(runner, "choose").size() + _calls_with(runner, "game-update").size(), 0, "nothing is written while the game runs")
	ok(w["p"].store.has_value("epic:abc", "upscale_pending"), "the held change is kept with the game's values")
	# the power goes off: a new session, nothing in memory
	var p2 = PerfProvider.new()
	p2.setup(w["ctx"])
	(w["ctx"]["upscale_running"] as Callable).call("")
	ok(p2.flush_pending("epic:abc"), "after the restart it is made once")
	eq([_calls_with(runner, "choose").size(), _calls_with(runner, "game-update").size()], [1, 1], "the pick and the update both ran: " + str(runner.calls))
	ok(not p2.store.has_value("epic:abc", "upscale_pending"), "and is gone from the store")
	ok(not p2.flush_pending("epic:abc"), "not made twice")
	# game-update alone is held as well
	w["p"]._pending.clear()
	(w["ctx"]["upscale_running"] as Callable).call("epic:abc")
	runner.calls.clear()
	w["p"]._upscale_run("game-update")
	eq(_calls_with(runner, "game-update").size(), 0, "game-update waits while the game runs")
	_done(w)


func test_lossless_is_off_when_the_helper_finds_anticheat() -> void:
	# the app's own data has no anti-cheat record; the game's folder (or the list's notes) does
	var w := _world("lsfg_ac_folder", ALLY_X)
	var runner = w["runner"]
	runner.answers["status"] = {"ok": true, "mode": "best", "upscaler": "own", "fg": 0, "owner": "none"}
	runner.answers["prepare"] = {"ok": true, "did": ""}
	runner.answers["plan"] = {"ok": true, "refused": "anticheat", "line": "This game uses NetEase Anti-Cheat."}
	_with_game(w, EPIC)
	eq(w["reg"].control("perf.lsfg").reason, "Off for this game: it uses anti-cheat", "Lossless stays off")
	_done(w)


func test_never_two_frame_generators() -> void:
	var w := _world("fg_exclusive", ALLY_X)
	var runner = w["runner"]
	var reg: Node = w["reg"]
	runner.answers["status"] = {"ok": true, "mode": "custom", "upscaler": "fsr31", "fg": 0, "owner": "gamecove", "launch": {}}
	runner.answers["prepare"] = {"ok": true, "did": ""}
	runner.answers["plan"] = {"ok": true, "line": "Best here: FSR 3.1."}
	runner.answers["choose"] = {"ok": true, "env": {"WINEDLLOVERRIDES": "dxgi=n,b;"}}
	_with_game(w, EPIC)
	reg.set_value("perf.lsfg", true)
	eq(reg.control("perf.lsfg").value, true, "Lossless on")
	reg.detect_all()
	eq(reg.control("perf.frame_gen").reason, "Off while Lossless frame generation is on for this game", "the game's frame generation steps aside, and says so")
	var failed := []
	reg.control_failed.connect(func(id, _v): failed.append(id))
	reg.set_value("perf.frame_gen", 2)
	eq(failed, ["perf.frame_gen"], "and can't be switched on next to it")
	reg.set_value("perf.lsfg", false)
	reg.detect_all()
	reg.set_value("perf.frame_gen", 2)
	eq(int(w["p"].store.get_value("epic:abc", "frame_gen", 0)), 2, "game frame generation on")
	reg.detect_all()
	eq(reg.control("perf.lsfg").reason, "Off while this game's own frame generation is on: that one is sharper", "Lossless steps aside for the sharper one")
	failed.clear()
	reg.set_value("perf.lsfg", true)
	eq(bool(w["p"].store.get_value("epic:abc", "lsfg", false)), false, "Lossless stays off")
	_done(w)


func test_frame_generator_choice_reaches_the_helper() -> void:
	var w := _world("fg_generator", ALLY_X)
	var runner = w["runner"]
	var reg: Node = w["reg"]
	runner.answers["status"] = {"ok": true, "mode": "custom", "upscaler": "fsr31", "fg": 2, "owner": "gamecove", "launch": {"fg_out": "fsrfg"}}
	runner.answers["prepare"] = {"ok": true, "did": ""}
	runner.answers["plan"] = {"ok": true, "line": ""}
	runner.answers["choose"] = {"ok": true, "env": {}}
	_with_game(w, EPIC)
	var c: RefCounted = reg.control("perf.fg_generator")
	ok(c.available, c.reason)
	eq(c.value, "fsrfg", "FSR frame generation is the default on AMD")
	eq(c.options.map(func(o): return o["label"]), ["FSR frame generation", "XeSS frame generation"], "plain names")
	reg.set_value("perf.fg_generator", "xefg")
	var last: String = _calls_with(runner, "choose")[-1]
	ok("--upscaler fsr31 --fg 2 --generator xefg" in last, last)
	eq(reg.control("perf.frame_gen").options.map(func(o): return int(o["value"])), [0, 2], "2x only off Intel: no 3x or 4x shown")
	var claw := _world("fg_claw", CLAW)
	eq(claw["reg"].control("perf.frame_gen").options.map(func(o): return o["label"]), ["Off", "2x", "3x", "4x"], "XMX: 2x 3x 4x")
	eq(claw["reg"].control("perf.fg_generator").reason, "One frame generator on this graphics chip", "XeSS only on Intel")
	_done(claw)
	_done(w)


func test_upscaler_menu_uses_the_shared_action() -> void:
	var w := _world("opti_menu", ALLY_X)
	var runner = w["runner"]
	runner.answers["status"] = {"ok": true, "mode": "best", "upscaler": "fsr31", "fg": 0, "owner": "gamecove"}
	runner.answers["prepare"] = {"ok": true, "did": ""}
	runner.answers["plan"] = {"ok": true, "line": ""}
	_with_game(w, EPIC)
	eq(w["reg"].control("perf.upscale_menu").reason, "Press Insert on a keyboard, or put it on a back button in Settings", "no registry: says how")
	eq(w["p"].open_upscaler_menu(), false, "nothing to press with")
	var pressed := []
	w["ctx"]["run_action"] = func(id): pressed.append(id); return true
	w["reg"].detect_all()
	ok(w["reg"].control("perf.upscale_menu").available, "with the action registry it is one press")
	w["reg"].set_value("perf.upscale_menu", true)
	eq(pressed, ["key_optiscaler"], "presses the registry's OptiScaler key")
	runner.answers["status"] = {"ok": true, "mode": "native", "upscaler": "own", "fg": 0, "owner": "none"}
	w["p"]._forget_status()
	w["reg"].detect_all()
	eq(w["reg"].control("perf.upscale_menu").reason, "Our upscaler isn't in this game", "no menu without our upscaler")
	_done(w)


func test_lossless_only_for_people_who_own_it() -> void:
	# not owned: a plain line and the store page, nothing else
	var w := _world("lsfg_not_owned", ALLY_X, ["dll", "lsfg"])
	var opened := []
	w["ctx"]["open_uri"] = func(u): opened.append(u); return true
	_with_game(w, EPIC)
	eq(w["reg"].control("perf.lsfg").reason, "Needs Lossless Scaling, a paid app on Steam", "plain line")
	var setup: RefCounted = w["reg"].control("perf.lsfg_setup")
	ok(setup.available and setup.help == "Lossless Scaling is a paid app on Steam. This uses your own copy.", setup.help)
	w["reg"].set_value("perf.lsfg_setup", true)
	eq(opened, ["steam://store/993090"], "the store page, nothing else")
	eq(_calls_with(w["runner"], "lsfg-install"), [], "lsfg-vk is never installed for someone without the app")
	_done(w)
	# a DLL without Steam's own install record doesn't count
	var w2 := _world("lsfg_loose_dll", ALLY_X, ["manifest"])
	_with_game(w2, EPIC)
	eq(w2["reg"].control("perf.lsfg").reason, "Needs Lossless Scaling, a paid app on Steam", "a copied DLL is not ownership")
	_done(w2)
	# owned, not installed: one press installs it in Steam
	var w3 := _world("lsfg_owned", ALLY_X, ["dll"])
	w3["library"].games["steam:993090"] = {"key": "steam:993090", "store": "steam", "id": "993090"}
	var opened3 := []
	w3["ctx"]["open_uri"] = func(u): opened3.append(u); return true
	_with_game(w3, EPIC)
	eq(w3["reg"].control("perf.lsfg").reason, "Install Lossless Scaling in Steam first", "owned")
	w3["reg"].set_value("perf.lsfg_setup", true)
	eq(opened3, ["steam://install/993090"], "installs it in Steam")
	_done(w3)
	# owned and installed, lsfg-vk missing: the helper installs lsfg-vk
	var w4 := _world("lsfg_layer", ALLY_X, ["lsfg"])
	w4["runner"].answers["lsfg-install"] = {"ok": true, "how": "installed", "version": "2.0.0"}
	_with_game(w4, EPIC)
	eq(w4["reg"].control("perf.lsfg").reason, "Needs lsfg-vk: install it below", "one piece left")
	w4["reg"].set_value("perf.lsfg_setup", true)
	eq(_calls_with(w4["runner"], "lsfg-install").size(), 1, "one press installs lsfg-vk")
	_done(w4)
	# everything there
	var w5 := _world("lsfg_ready", ALLY_X)
	_with_game(w5, EPIC)
	ok(w5["reg"].control("perf.lsfg").available, "ready: " + w5["reg"].control("perf.lsfg").reason)
	eq(w5["reg"].control("perf.lsfg_setup").reason, "Ready: nothing left to set up", "nothing to do")
	_done(w5)


func test_lossless_defaults_follow_the_chip() -> void:
	eq(Lsfg.defaults_for("amd_rdna2")["lsfg_performance"], true, "Steam Deck: the lighter model")
	eq(Lsfg.defaults_for("amd_rdna2")["lsfg_flow_scale"], 0.6, "and 60 % flow scale")
	eq(Lsfg.defaults_for("amd_rdna35")["lsfg_performance"], false, "890M: the full model")
	eq(Lsfg.defaults_for("intel_xmx")["lsfg_multiplier"], 2, "2x everywhere")
	eq(Lsfg.next_step("v2", "ready")["step"], "", "ready")
	eq(Lsfg.next_step("", "wrong_branch")["step"], "branch", "the Steam beta comes before lsfg-vk")
	var w := _world("lsfg_deck", DECK)
	_with_game(w, EPIC)
	eq(w["reg"].control("perf.lsfg_performance").value, true, "the Deck starts on the lighter model")
	w["reg"].set_value("perf.lsfg", true)
	var conf := FileAccess.get_file_as_string(w["home"].path_join(Lsfg.CONFIG))
	ok("performance_mode = true" in conf and "flow_scale = 0.6" in conf, conf)
	_done(w)
