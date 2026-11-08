extends "res://tests/test_case.gd"
## Steam backend: capability detection, steam:// fallbacks, appmanifest progress
## and completion, settings that wait for Steam to stop. Fake URI opener; manifests
## changed in a temp copy of the fixture home.

const SteamBackend := preload("res://scripts/steam/steam_backend.gd")
const SteamCef := preload("res://scripts/steam/steam_cef.gd")
const SteamConfig := preload("res://scripts/steam/steam_config.gd")
const TempTree := preload("res://tests/fixtures/stores/temp_tree.gd")

const STEAM := ".local/share/Steam"

var uris: Array = []
var events: Array = []


func _backend(name: String, running := false) -> Node:
	var home := TempTree.temp_dir(name)
	TempTree.copy_tree(fixture("stores/data/steamhome"), home)
	var b: Node = SteamBackend.new()
	b.proc_root = fixture("stores/data/proc") if running else home.path_join("noproc")
	b.setup(home)
	uris = []
	events = []
	b.open_uri = func(u: String) -> bool:
		uris.append(u)
		return true
	b.progress.connect(func(a, d, t, r, e): events.append(["progress", a, d, t, r, e]))
	b.state_changed.connect(func(a, s): events.append(["state", a, s]))
	b.finished.connect(func(a, act, okk, _m): events.append(["finished", a, act, okk]))
	b.window_needed.connect(func(a, r): events.append(["window", a, r]))
	return b


func _done(b: Node) -> void:
	var home: String = b.home
	b.free()
	TempTree.remove_tree(home)


func _write_manifest(b: Node, appid: String, flags: int, done := 0, total := 0) -> void:
	var p: String = b.steam_root.path_join("steamapps/appmanifest_%s.acf" % appid)
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_string("\"AppState\"\n{\n\t\"appid\"\t\t\"%s\"\n\t\"name\"\t\t\"Game\"\n\t\"StateFlags\"\t\t\"%d\"\n\t\"installdir\"\t\t\"Game\"\n\t\"BytesToDownload\"\t\t\"%d\"\n\t\"BytesDownloaded\"\t\t\"%d\"\n}\n" % [appid, flags, total, done])
	f.close()


func _has(kind: String) -> Array:
	return events.filter(func(e): return e[0] == kind)


func test_capabilities_without_cef() -> void:
	var b := _backend("sb_caps", true)
	var c: Dictionary = b.capabilities(false)
	ok(c["install"], "install via steam://")
	eq(c["how"]["install"], "steam-uri", "how")
	ok(not c["uninstall"], "not installed: no uninstall")
	ok("install" in c["needs_window"], "install shows a Steam dialog")
	var ci: Dictionary = b.capabilities(true)
	ok(ci["verify"] and ci["uninstall"], "verify, uninstall")
	ok(not ci["update"] and not ci["move"] and not ci["pause"], "API-only actions off")
	ok(str(ci["why"]["move"]).contains("Steam control"), "explains how to get move")
	eq(ci["how"]["launch_options"], "steam-files-after-restart", "Steam running: waits for restart")
	ok(ci["progress"], "progress from manifests")
	_done(b)


func test_capabilities_with_cef_opt_in() -> void:
	var b := _backend("sb_caps_cef")
	b.cef.set_enabled(true)
	var c: Dictionary = b.capabilities(true)
	ok(c["update"] and c["move"] and c["pause"] and c["cancel"], "API actions on")
	eq(c["how"]["compat_tool"], "steam-cef", "compat via SteamClient")
	eq(c["needs_window"], [], "no dialogs")
	b.cef.set_enabled(false, true)
	_done(b)


func test_no_steam_means_nothing() -> void:
	var b: Node = SteamBackend.new()
	b.setup("/nonexistent")
	var c: Dictionary = b.capabilities(true)
	ok(not c["install"] and not c["launch_options"] and not c["progress"], "all off")
	eq(c["why"]["install"], "Steam isn't installed", "why")
	b.free()


func test_uri_install_progress_and_completion() -> void:
	var b := _backend("sb_install")
	var r: Dictionary = b.install("777")
	ok(r["ok"], "accepted")
	eq(r["via"], "steam-uri", "via steam://")
	eq(uris, ["steam://install/777"], "uri")
	eq(_has("window"), [["window", "777", "install"]], "asks for Steam's window")
	ok(b.is_watching("777"), "watching")
	b.poll(2.0)
	eq(_has("progress"), [], "no manifest yet: nothing")
	_write_manifest(b, "777", 1026, 2500000, 10000000)
	b.poll(2.0)
	eq(_has("progress").back(), ["progress", "777", 2500000, 10000000, 0.0, -1], "first numbers")
	_write_manifest(b, "777", 1026, 5000000, 10000000)
	b.poll(2.0)
	var p: Array = _has("progress").back()
	eq(p[2], 5000000, "done")
	eq(p[4], 1250000.0, "rate from the change over 2 s")
	eq(p[5], 4, "eta")
	_write_manifest(b, "777", 4, 10000000, 10000000)
	b.poll(2.0)
	eq(_has("finished"), [["finished", "777", "install", true]], "finished")
	ok(not b.is_watching("777"), "stopped watching")
	b.poll(2.0)
	eq(_has("finished").size(), 1, "nothing more")
	_done(b)


func test_uri_uninstall_waits_for_manifest_to_go() -> void:
	var b := _backend("sb_uninstall")
	b.uninstall("440")
	eq(uris, ["steam://uninstall/440"], "uri")
	b.poll(2.0)
	eq(_has("finished"), [], "still there")
	DirAccess.remove_absolute(b.steam_root.path_join("steamapps/appmanifest_440.acf"))
	b.poll(2.0)
	eq(_has("finished"), [["finished", "440", "uninstall", true]], "gone: done")
	_done(b)


func test_verify_done_after_busy_or_grace() -> void:
	var b := _backend("sb_verify")
	b.verify("440")
	eq(uris, ["steam://validate/440"], "uri")
	b.poll(2.0)
	eq(_has("finished"), [], "not started yet")
	_write_manifest(b, "440", 4 | 131072)
	b.poll(2.0)
	eq(_has("state").back(), ["state", "440", "verifying"], "verifying")
	_write_manifest(b, "440", 4)
	b.poll(2.0)
	eq(_has("finished"), [["finished", "440", "verify", true]], "done after busy")
	events.clear()
	b.verify("440")
	b.poll(SteamBackend.START_GRACE_S + 1.0)
	eq(_has("finished"), [["finished", "440", "verify", true]], "never busy: done after the grace time")
	_done(b)


func test_api_only_actions_refused_without_cef() -> void:
	var b := _backend("sb_api")
	for f in ["update", "pause", "resume", "cancel"]:
		var r: Dictionary = b.call(f, "440")
		ok(not r["ok"], f + " refused")
	ok(not b.move("440", "/mnt/x")["ok"], "move refused")
	_done(b)


func test_cef_failure_falls_back_to_uri() -> void:
	var b := _backend("sb_fallback")
	b.cef.set_enabled(true)
	var r: Dictionary = b.install("777")
	eq(r["via"], "steam-cef", "tried the API first")
	eq(uris, ["steam://install/777"], "Steam not answering: steam:// instead")
	b.cef.set_enabled(false, true)
	_done(b)


func test_launch_with_args_without_cef() -> void:
	var b := _backend("sb_launch")
	b.launch("440")
	b.launch("440", "-novid +map x")
	eq(uris, ["steam://rungameid/440", "steam://run/440//-novid%20%2Bmap%20x/"], "rungameid, run with args")
	b.open_page("440", "store")
	b.open_page("440", "downloads")
	eq(uris.slice(2), ["steam://store/440", "steam://open/downloads"], "pages")
	_done(b)


func test_settings_wait_for_steam_to_stop() -> void:
	var b := _backend("sb_pending", true)
	var r: Dictionary = b.set_launch_options("440", "-dx11")
	ok(r["ok"] and r.get("pending", false), "queued until Steam stops")
	eq(b.launch_options("440"), "-dx11", "shows the waiting value")
	b.set_compat_tool("440", "proton_experimental")
	eq(b.compat_tool("440"), "proton_experimental", "waiting compat tool")
	eq(b.apply_pending(), 0, "still running: nothing written")
	b.proc_root = b.home.path_join("noproc")
	eq(b.apply_pending(), 2, "Steam stopped: both written")
	eq(b.pending, {}, "nothing waits")
	eq(SteamConfig.launch_options(b.steam_root.path_join("userdata/12345678"), "440"), "-dx11", "on disk")
	eq(SteamConfig.compat_tool(b.steam_root, "440"), "proton_experimental", "on disk")
	var direct: Dictionary = b.set_launch_options("440", "")
	eq(direct["via"], "steam-files", "Steam stopped: written at once")
	_done(b)


func test_compat_tools_list() -> void:
	var b := _backend("sb_tools")
	var ids: Array = b.compat_tools().map(func(t): return t["id"])
	eq(ids, ["", "proton_experimental", "proton_9", "GE-Proton10-25"], "default, Valve (manifest order), custom")
	_done(b)


func test_observe_and_cef_progress() -> void:
	var b := _backend("sb_observe")
	b.observe(["620"])
	ok(b.is_watching("620"), "following a download Steam already runs")
	b._on_cef_binding(SteamCef.DOWNLOADS_BINDING, JSON.stringify({"kind": "overview", "appid": 620, "bytes_done": 10, "bytes_total": 100, "rate": 5.0, "eta": 18}))
	eq(_has("progress").back(), ["progress", "620", 10, 100, 5.0, 18], "Steam's own numbers")
	_done(b)
