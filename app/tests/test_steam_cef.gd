extends "res://tests/test_case.gd"
## SteamClient over CEF: tab choice (loopback only), DevTools answers, scripts
## built from JSON-encoded values, opt-in flag file. No socket is ever opened.

const SteamCef := preload("res://scripts/steam/steam_cef.gd")
const SteamFocus := preload("res://scripts/steam/steam_focus.gd")
const TempTree := preload("res://tests/fixtures/stores/temp_tree.gd")


func test_pick_shared_context_tab_on_loopback_only() -> void:
	var tabs := [
		{"title": "Steam Big Picture Mode", "webSocketDebuggerUrl": "ws://127.0.0.1:8080/devtools/page/A"},
		{"title": "SharedJSContext", "webSocketDebuggerUrl": "ws://127.0.0.1:8080/devtools/page/B"},
	]
	eq(SteamCef.pick_tab(tabs), "ws://127.0.0.1:8080/devtools/page/B", "shared context")
	eq(SteamCef.pick_tab([{"title": "SharedJSContext", "webSocketDebuggerUrl": "ws://192.168.1.5:8080/devtools/page/B"}]), "", "never a LAN address")
	eq(SteamCef.pick_tab([{"title": "Steam", "webSocketDebuggerUrl": "ws://localhost:8080/x"}]), "ws://localhost:8080/x", "older title")
	eq(SteamCef.pick_tab("nope"), "", "bad answer")
	ok(not SteamCef.is_loopback_ws("ws://127.0.0.1.evil.com:8080/"), "lookalike host rejected")


func test_eval_results() -> void:
	eq(SteamCef.parse_eval_result({"id": 1, "result": {"result": {"type": "boolean", "value": true}}}), {"ok": true, "value": true, "error": ""}, "value")
	var ex := SteamCef.parse_eval_result({"id": 2, "result": {"result": {}, "exceptionDetails": {"text": "Uncaught", "exception": {"description": "TypeError: x"}}}})
	eq(ex["ok"], false, "exception fails")
	eq(ex["error"], "TypeError: x", "exception text")
	eq(SteamCef.parse_eval_result({"id": 3, "error": {"message": "nope"}})["error"], "nope", "protocol error")


func test_handle_message_answers_and_bindings() -> void:
	var cef: Node = SteamCef.new()
	var got := []
	cef._pending[7] = {"cb": func(r): got.append(r), "t": 0.0}
	cef.handle_message(JSON.stringify({"id": 7, "result": {"result": {"value": "started"}}}))
	eq(got, [{"ok": true, "value": "started", "error": ""}], "callback answered")
	eq(cef.status, "ready", "a reply means ready")
	var seen := []
	cef.binding_called.connect(func(n, p): seen.append([n, p]))
	cef.handle_message(JSON.stringify({"method": "Runtime.bindingCalled", "params": {"name": "gamecoveDownloads", "payload": "{}"}}))
	eq(seen, [["gamecoveDownloads", "{}"]], "binding event")
	cef.handle_message("not json")
	cef.free()


func test_scripts_escape_values() -> void:
	var js := SteamCef.js_set_launch_options(620, "PROTON_LOG=1 %command% \"-x\" '); alert(1); //")
	ok(js.contains("SetAppLaunchOptions(620, \"PROTON_LOG=1 %command% \\\"-x\\\" '); alert(1); //\")"), "string is one JSON literal: " + js)
	ok(SteamCef.lit("a b").contains("\\u2028"), "line separator escaped")
	eq(SteamCef.js_set_compat_tool(440, ""), "(async () => { SteamClient.Apps.SpecifyCompatTool(440, \"\"); return true; })()", "compat tool")
	ok(SteamCef.js_run(620, "-novid").contains("RunGame(\"620\", \"-novid\", -1, 100)"), "RunGame takes the id as a string")
	ok(SteamCef.js_install(620, "/run/media/deck/SD").contains("OpenInstallWizard([620])"), "install wizard")
	ok(SteamCef.js_install(620, "/run/media/deck/SD").contains("\"/run/media/deck/SD\""), "folder as literal")
	ok(SteamCef.js_install(620, "").contains("ContinueInstall()"), "confirms the wizard")
	ok(SteamCef.js_uninstall(620).contains("OpenUninstallWizard([620], true)"), "no prompt")
	ok(SteamCef.js_move(620, "/mnt").contains("MoveInstallFolderForApp(620, idx)"), "move")
	ok(SteamCef.js_watch_downloads().contains("RegisterForDownloadOverview"), "overview")
	ok(SteamCef.js_watch_downloads().contains(SteamCef.DOWNLOADS_BINDING), "binding name")


func test_opt_in_creates_and_removes_flag() -> void:
	var root := TempTree.temp_dir("cef_root")
	var cef: Node = SteamCef.new()
	cef.steam_root = root
	eq(cef.status, "off", "off by default")
	ok(not cef.is_usable(), "not usable when off")
	ok(not cef.evaluate("1"), "evaluate refused when off")
	var created: bool = cef.set_enabled(true)
	ok(created, "flag created")
	ok(FileAccess.file_exists(root.path_join(SteamCef.FLAG_FILE)), "flag on disk")
	ok(cef.is_usable(), "usable with the flag")
	cef.set_enabled(false, created)
	ok(not FileAccess.file_exists(root.path_join(SteamCef.FLAG_FILE)), "our flag removed")
	# A flag someone else made (Decky) stays.
	FileAccess.open(root.path_join(SteamCef.FLAG_FILE), FileAccess.WRITE).close()
	ok(not cef.set_enabled(true), "not ours")
	cef.set_enabled(false, false)
	ok(FileAccess.file_exists(root.path_join(SteamCef.FLAG_FILE)), "Decky's flag kept")
	cef.free()
	TempTree.remove_tree(root)


func test_steam_window_pick() -> void:
	var triples := [0x400001, 769, 100, 0x600002, 769, 4242, 0x600003, 0, 5000, 0x700004, 620, 7000]
	var comms := {100: "gamecove", 4242: "steam", 5000: "steamwebhelper", 7000: "hl2_linux"}
	eq(SteamFocus.pick_window(triples, 100, comms), 0x600003, "newest Steam window, not ours, not the game")
	eq(SteamFocus.pick_window([0x400001, 769, 100], 100, comms), 0, "none")
	eq(SteamFocus.comms([1, 0, 4242, 2, 0, 5000], fixture("stores/data/proc")), {4242: "steam", 5000: "steamwebhelper"}, "comm from /proc")
	eq(SteamFocus.focus_args(0x600003), PackedStringArray(["-root", "-f", "GAMESCOPECTRL_BASELAYER_WINDOW", "32c", "-set", "GAMESCOPECTRL_BASELAYER_WINDOW", str(0x600003)]), "focus")
	eq(SteamFocus.release_args(), PackedStringArray(["-root", "-remove", "GAMESCOPECTRL_BASELAYER_WINDOW"]), "release")
