extends "res://tests/test_case.gd"
## StoreManager and the Library API on top of it, with a fake runner, a temp home
## and fake entries: capabilities, queue jobs, Heroic hand-off, Steam routing,
## GOG record after install, settings, per-game compat, signal forwarding.

const StoreManager := preload("res://scripts/library/manage/store_manager.gd")
const FakeRunner := preload("res://tests/fixtures/stores/fake_job_runner.gd")
const LibraryScript := preload("res://scripts/library/library.gd")
const LauncherScript := preload("res://scripts/launch/launcher.gd")
const TempTree := preload("res://tests/fixtures/stores/temp_tree.gd")
const DownloadQueue := preload("res://scripts/library/manage/download_queue.gd")
const StoreCommands := preload("res://scripts/library/manage/store_commands.gd")

const TOOLS := {"legendary": "/usr/bin/legendary", "nile": "", "gogdl": "/opt/gogdl", "umu": "/usr/bin/umu-run",
	"heroic": ["/usr/bin/heroic"], "heroic_flatpak": []}

var events: Array = []
var external: Array = []
var entries := {}


func _manager(name: String) -> StoreManager:
	var home := TempTree.temp_dir(name)
	var m := StoreManager.new(FakeRunner.new())
	m.settings_path = home.path_join("store_settings.json")
	m.queue_path = home.path_join("downloads.json")
	m.setup(home)
	m.tools = TOOLS.duplicate()
	m.under_gamescope = false
	m.queue.free_space = func(_p: String) -> int: return -1
	entries = {}
	m.entry_lookup = func(k: String) -> Dictionary: return entries.get(k, {})
	events = []
	external = []
	m.open_external = func(cmd: Array) -> bool:
		external.append(cmd)
		return true
	m.install_state_changed.connect(func(k, s): events.append(["state", k, s]))
	m.store_changed.connect(func(s): events.append(["store", s]))
	m.action_failed.connect(func(k, a, msg): events.append(["failed", k, a, msg]))
	m.external_window_needed.connect(func(k, a, r): events.append(["window", k, a, r]))
	m.download_progress.connect(func(k, d, t, _r, _e): events.append(["progress", k, d, t]))
	return m


func _done(m: StoreManager) -> void:
	var home := m.home
	m.free()
	TempTree.remove_tree(home)


func _epic(installed: bool) -> Dictionary:
	var e := {"key": "epic:Quail", "store": "epic", "id": "Quail", "title": "Hades", "installed": installed,
		"source": "legendary", "heroic_flatpak": false, "config_dir": "/c/legendary", "install_path": "/g/Hades"}
	entries[e["key"]] = e
	return e


func test_epic_install_through_queue() -> void:
	var m := _manager("sm_epic")
	var r: Object = m.runner
	var g := _epic(false)
	var res := m.install({"key": g["key"]})
	eq(res, {"ok": true, "via": "legendary", "why": ""}, "accepted")
	eq(r.last_cmd(), "/usr/bin/legendary info --json -- Quail", "probe runs")
	ok(DirAccess.dir_exists_absolute(m.home.path_join("Games/epic")), "install folder made")
	ok(events.has(["state", "epic:Quail", "installing"]), "installing")
	r.finish(1, 0)
	eq(r.last_cmd(), "/usr/bin/legendary install --base-path %s --platform Windows -y --skip-sdl -- Quail" % m.home.path_join("Games/epic"), "install runs")
	r.feed(2, "[DLManager] INFO: = Progress: 50.00% (5/10), Running for 00:00:01, ETA: 00:00:01")
	eq(m.downloads()[0]["progress"]["percent"], 50.0, "downloads() shows progress")
	r.finish(2, 0)
	ok(events.has(["state", "epic:Quail", "installed"]), "installed")
	ok(events.has(["store", "epic"]), "Epic rescanned")
	eq(m.downloads(), [], "queue empty")
	_done(m)


func test_capabilities_for_epic() -> void:
	var m := _manager("sm_caps")
	_epic(true)
	var c := m.capabilities({"key": "epic:Quail"})
	ok(c["update"] and c["verify"] and c["uninstall"] and c["move"], "legendary can do it all")
	ok(not c["install"], "installed")
	eq(c["how"]["update"], "legendary", "how")
	ok(c["compat_tool"] and c["launch_options"], "umu present: compat tool")
	ok(not c["pause"], "nothing running")
	m.tools["umu"] = ""
	ok(not m.capabilities({"key": "epic:Quail"})["compat_tool"], "no umu: no Proton choice")
	m.tools["legendary"] = ""
	var none := m.capabilities({"key": "epic:Quail"})
	ok(not none["update"], "no legendary")
	ok(str(none["why"]["update"]).contains("legendary"), "explains")
	_done(m)


func test_pause_resume_cancel_through_manager() -> void:
	var m := _manager("sm_ctl")
	var r: Object = m.runner
	_epic(true)
	m.update({"key": "epic:Quail"})
	ok(m.capabilities({"key": "epic:Quail"})["pause"], "pause offered while running")
	ok(m.pause({"key": "epic:Quail"})["ok"], "pause")
	r.finish(1, -15)
	ok(events.has(["state", "epic:Quail", "paused"]), "paused")
	ok(m.resume({"key": "epic:Quail"})["ok"], "resume")
	ok(m.cancel({"key": "epic:Quail"})["ok"], "cancel")
	r.finish(2, -15)
	ok(events.has(["state", "epic:Quail", "installed"]), "cancelled update: still installed")
	ok(not m.cancel({"key": "epic:Quail"})["ok"], "nothing to cancel")
	ok(events.filter(func(e): return e[0] == "failed").size() == 1, "that refusal is reported")
	_done(m)


func test_heroic_hand_off() -> void:
	var m := _manager("sm_heroic")
	entries["gog:1"] = {"key": "gog:1", "store": "gog", "id": "1", "installed": true, "source": "heroic",
		"heroic_flatpak": false, "heroic_root": "/h", "install_path": "/g/x"}
	var r := m.update({"key": "gog:1"})
	eq(r["via"], "heroic", "Heroic's GOG game")
	eq(external, [["/usr/bin/heroic"]], "Heroic opened")
	ok(events.has(["window", "gog:1", "heroic", "manage"]), "UI told a window needs the user")
	eq(m.runner.started, [], "nothing queued")
	_done(m)


func test_gog_install_records_the_folder() -> void:
	var m := _manager("sm_gog")
	var r: Object = m.runner
	var heroic := m.home.path_join("heroic")
	DirAccess.make_dir_recursive_absolute(heroic.path_join("gog_store"))
	FileAccess.open(heroic.path_join("gog_store/auth.json"), FileAccess.WRITE).close()
	entries["gog:42"] = {"key": "gog:42", "store": "gog", "id": "42", "title": "Game", "installed": false,
		"source": "heroic", "heroic_flatpak": false, "heroic_root": heroic}
	var res := m.install({"key": "gog:42"})
	eq(res["via"], "gogdl", "gogdl")
	r.finish(1, 0)
	var base := m.home.path_join("Games/gog")
	ok(r.last_cmd().contains("download --platform windows --path " + base) and r.last_cmd().ends_with(" -- 42"), "download: " + r.last_cmd())
	DirAccess.make_dir_recursive_absolute(base.path_join("Game"))
	FileAccess.open(base.path_join("Game/goggame-42.info"), FileAccess.WRITE).close()
	r.finish(2, 0)
	var rec: Variant = JSON.parse_string(FileAccess.get_file_as_string(m.home + "/.local/share/gamecove/gog/installed.json"))
	eq(rec["installed"][0]["install_path"], base.path_join("Game"), "folder recorded")
	eq(rec["installed"][0]["appName"], "42", "id recorded")
	_done(m)


func test_steam_goes_to_steam_backend() -> void:
	var m := _manager("sm_steam")
	var uris := []
	m.steam.steam_root = m.home   # pretend Steam is installed here
	m.steam.open_uri = func(u):
		uris.append(u)
		return true
	entries["steam:620"] = {"key": "steam:620", "store": "steam", "id": "620", "title": "Portal 2", "installed": false}
	var r := m.install({"key": "steam:620"})
	ok(r["ok"], "accepted")
	eq(uris, ["steam://install/620"], "steam://")
	ok(events.has(["state", "steam:620", "installing"]), "installing")
	ok(events.has(["window", "steam:620", "steam", "install"]), "Steam dialog needs the user")
	eq(m.downloads()[0]["key"], "steam:620", "listed in downloads")
	ok(not m.update({"key": "steam:620"})["ok"], "update needs Steam control")
	_done(m)


func test_settings() -> void:
	var m := _manager("sm_settings")
	eq(m.get_settings()["install_root"], m.home.path_join("Games"), "default ~/Games")
	ok(not m.get_settings().has("cef_flag_created"), "internal keys hidden")
	ok(not m.set_setting("install_root", "relative/path"), "absolute only")
	ok(m.set_setting("install_root", "/run/media/deck/SD/Games"), "SD card")
	ok(not m.set_setting("max_parallel", 9), "bounded")
	ok(m.set_setting("max_parallel", 2), "two at once")
	eq(m.queue.max_parallel, 2, "applied to the queue")
	ok(not m.set_setting("nonsense", true), "unknown")
	var m2 := StoreManager.new(FakeRunner.new())
	m2.settings_path = m.settings_path
	m2.setup(m.home)
	eq(m2.settings["install_root"], "/run/media/deck/SD/Games", "saved")
	m2.free()
	eq(StoreManager.steam_start_args("gamepadui"), ["-silent", "-gamepadui", "-steamos3", "-steampal", "-steamdeck"] as Array[String], "session's gamepadui flags")
	eq(StoreManager.steam_start_args(""), ["-silent"] as Array[String], "silent by default")
	_done(m)


func test_non_steam_compat_through_launcher() -> void:
	var m := _manager("sm_compat")
	var l: Node = LauncherScript.new()
	l.settings_path = m.home.path_join("launch.json")
	l.home = fixture("launch/home")
	l.root_prefix = fixture("launch/root")
	l.device_profile = {"gpu_family": "amd-rdna3"}
	m.launcher = l
	_epic(true)
	ok(m.set_compat_tool({"key": "epic:Quail"}, "GE-Proton10-25")["ok"], "set tool")
	ok(m.set_launch_options({"key": "epic:Quail"}, "-dx11 -skipintro")["ok"], "set args")
	eq(m.compat_tool({"key": "epic:Quail"}), "GE-Proton10-25", "tool back")
	eq(m.launch_options({"key": "epic:Quail"}), "-dx11 -skipintro", "args back")
	var ids: Array = m.compat_tools({"key": "epic:Quail"}).map(func(t): return t["id"])
	ok(ids.slice(0, 2) == ["", "GE-Proton"] and "GE-Proton10-25" in ids, "umu tools: " + str(ids))
	eq(l.proton_path_for("GE-Proton10-25"), fixture("launch/home/.local/share/Steam/compatibilitytools.d/GE-Proton10-25"), "PROTONPATH")
	var plan: Dictionary = l.launch_plan({"key": "epic:Quail", "store": "epic", "id": "Quail"})
	eq(plan["proton"]["flavour"], "ge", "launch plan uses the chosen Proton")
	eq(plan["env"].get("PROTON_FSR4_UPGRADE", ""), "1", "so GE's FSR 4 variable applies")
	var l2: Node = LauncherScript.new()
	l2.settings_path = l.settings_path
	eq(l2.compat_for("epic:Quail")["args"], "-dx11 -skipintro", "saved in the settings file")
	eq(l2.settings_for("epic:Quail").keys().size(), 5, "per-game settings shape unchanged")
	eq(LauncherScript.sanitize_compat({"extra_env": {"OK_1": "x", "bad-name": "y", "N": "a\nb"}, "prefix": "rel"}),
		{"proton": "", "prefix": "", "extra_env": {"OK_1": "x"}, "args": ""}, "bad values dropped")
	l.free()
	l2.free()
	_done(m)


func test_library_forwards_and_merges() -> void:
	var lib: Node = LibraryScript.new()
	var m := StoreManager.new(FakeRunner.new())
	lib.attach_store(m)
	var got := []
	lib.install_state_changed.connect(func(k, s): got.append([k, s]))
	lib.download_progress.connect(func(k, d, t, _r, _e): got.append([k, d, t]))
	m.install_state_changed.emit("epic:A", "installing")
	m.download_progress.emit("epic:A", 1, 2, 0.0, -1)
	eq(got, [["epic:A", "installing"], ["epic:A", 1, 2]], "signals forwarded")
	lib._entries = {"epic:A": {"store": "epic", "id": "A", "title": "A"}}
	eq(m.entry_lookup.call("epic:A")["title"], "A", "manager sees Library's entries")
	var merged := LibraryScript.merge_store(
		[{"key": "epic:A", "store": "epic", "title": "Alpha"}, {"key": "steam:1", "store": "steam", "title": "Zeta"}],
		{"epic:A": {"store": "epic"}, "steam:1": {"store": "steam"}},
		{"games": [{"key": "epic:B", "store": "epic", "title": "Beta"}], "entries": {"epic:B": {"store": "epic"}}}, "epic")
	eq(merged["games"].map(func(g): return g["key"]), ["epic:B", "steam:1"], "store replaced, sorted")
	eq(merged["entries"].keys().size(), 2, "entries replaced")
	lib.free()


func test_launch_helpers() -> void:
	var e := LibraryScript.apply_compat({"prefix": "/old", "proton_path": ""}, {"prefix": "/new", "proton": "x"}, "/tools/GE")
	eq([e["prefix"], e["proton_path"]], ["/new", "/tools/GE"], "user's prefix and Proton win")
	eq(LibraryScript.apply_compat({"prefix": "/old"}, {"prefix": ""}, "")["prefix"], "/old", "empty keeps the store's")
	eq(LibraryScript.append_args(["env", "legendary", "launch", "Q"], "-dx11 \"-name x\""), ["env", "legendary", "launch", "Q", "-dx11", "-name x"] as Array[String], "args shell-split")
	eq(LibraryScript.append_args(["heroic", "heroic://launch?appName=Q"], "-dx11"), ["heroic", "heroic://launch?appName=Q"] as Array[String], "not into a Heroic hand-off")
	var lib: Node = LibraryScript.new()
	eq(lib.capabilities({"key": "epic:A"})["install"], false, "no manager: everything off")
	eq(lib.install({"key": "epic:A"})["ok"], false, "no manager: refused")
	lib.free()


func _gog_manager(name: String) -> StoreManager:
	var m := _manager(name)
	var heroic := m.home.path_join("heroic")
	DirAccess.make_dir_recursive_absolute(heroic.path_join("gog_store"))
	FileAccess.open(heroic.path_join("gog_store/auth.json"), FileAccess.WRITE).close()
	return m


func _linux_game(dir: String, info := "Some Game\n1.0\n") -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(dir.path_join("gameinfo"), FileAccess.WRITE)
	f.store_string(info)
	f.close()
	FileAccess.open(dir.path_join("start.sh"), FileAccess.WRITE).close()


## Two Linux games in one base folder: the second install must be recorded
## against its own new folder, and uninstall must never rm -rf the other one.
func test_gog_two_linux_games_in_one_folder() -> void:
	var m := _gog_manager("sm_gog_two")
	var r: Object = m.runner
	var heroic := m.home.path_join("heroic")
	var base := m.home.path_join("Games/gog")
	# game 42 is already there (installed earlier; its gameinfo has no id line)
	_linux_game(base.path_join("Alpha"))
	StoreCommands.write_gog_record(m.home, [{"appName": "42", "install_path": base.path_join("Alpha"), "platform": "linux", "title": "Alpha"}])
	entries["gog:77"] = {"key": "gog:77", "store": "gog", "id": "77", "title": "Beta", "installed": false,
		"source": "heroic", "heroic_flatpak": false, "heroic_root": heroic}
	m.install({"key": "gog:77"}, {"platform": "linux"})
	r.finish(1, 0)
	_linux_game(base.path_join("Beta"))
	r.finish(2, 0)
	var rec := StoreCommands.read_gog_record(m.home)
	var beta: Array = rec.filter(func(i): return i["appName"] == "77")
	eq(beta.size(), 1, "second game recorded")
	eq(beta[0]["install_path"], base.path_join("Beta"), "against its own new folder, not Alpha")
	ok(FileAccess.file_exists(base.path_join("Beta/.gamecove-gog-77")), "ownership marker left in Beta")
	ok(not FileAccess.file_exists(base.path_join("Alpha/.gamecove-gog-77")), "nothing written into Alpha")
	# uninstall: only a proven folder is deleted
	entries["gog:77"] = {"key": "gog:77", "store": "gog", "id": "77", "title": "Beta", "installed": true,
		"source": "gamecove", "heroic_flatpak": false, "heroic_root": heroic, "install_path": base.path_join("Beta"), "platform": "linux"}
	var res := m.uninstall({"key": "gog:77"})
	ok(res["ok"], "Beta can be uninstalled")
	eq(r.last_cmd(), "rm -rf -- " + base.path_join("Beta"), "deletes Beta only")
	r.finish(3, 0)
	# a record pointing game 77 at Alpha's folder (the old bug) is refused
	entries["gog:77"]["install_path"] = base.path_join("Alpha")
	var started: int = r.started.size()
	res = m.uninstall({"key": "gog:77"})
	ok(not res["ok"], "won't delete a folder not proven to be game 77's")
	ok(str(res["why"]).begins_with("Won't delete"), "refused for the right reason: " + str(res["why"]))
	eq(r.started.size(), started, "nothing ran")
	# Alpha's start.sh and bare gameinfo prove nothing either
	entries["gog:42"] = {"key": "gog:42", "store": "gog", "id": "42", "title": "Alpha", "installed": true,
		"source": "gamecove", "heroic_flatpak": false, "heroic_root": heroic, "install_path": base.path_join("Alpha"), "platform": "linux"}
	res = m.uninstall({"key": "gog:42"})
	ok(not res["ok"] and str(res["why"]).begins_with("Won't delete"), "start.sh is no uninstall marker")
	_done(m)


func test_gog_install_never_guesses() -> void:
	var m := _gog_manager("sm_gog_guess")
	var r: Object = m.runner
	var heroic := m.home.path_join("heroic")
	var base := m.home.path_join("Games/gog")
	entries["gog:77"] = {"key": "gog:77", "store": "gog", "id": "77", "title": "Beta", "installed": false,
		"source": "heroic", "heroic_flatpak": false, "heroic_root": heroic}
	m.install({"key": "gog:77"}, {"platform": "linux"})
	r.finish(1, 0)
	# two unproven new folders appeared (another install ran at the same time)
	_linux_game(base.path_join("Beta"))
	_linux_game(base.path_join("Gamma"))
	r.finish(2, 0)
	eq(StoreCommands.read_gog_record(m.home), [], "nothing recorded")
	ok(events.any(func(e): return e[0] == "failed" and e[1] == "gog:77"), "the person is told")
	ok(not FileAccess.file_exists(base.path_join("Beta/.gamecove-gog-77")) and not FileAccess.file_exists(base.path_join("Gamma/.gamecove-gog-77")), "no marker written")
	_done(m)


func test_gog_folder_proof() -> void:
	var dir := TempTree.temp_dir("gog_proof")
	_linux_game(dir.path_join("A"), "Alpha\n1.0\n42\n")
	ok(StoreCommands.gog_folder_is(dir.path_join("A"), "42"), "gameinfo with the id line")
	ok(not StoreCommands.gog_folder_is(dir.path_join("A"), "4"), "a prefix of the id doesn't count")
	ok(not StoreCommands.gog_folder_is(dir.path_join("A"), "../A"), "ids must be numbers")
	eq(StoreCommands.find_gog_install(dir, "42"), dir.path_join("A"), "found by its gameinfo without a snapshot")
	eq(StoreCommands.find_gog_install(dir, "77"), "", "no snapshot, no proof: nothing")
	DirAccess.make_dir_recursive_absolute(dir.path_join("W"))
	FileAccess.open(dir.path_join("W/goggame-99.info"), FileAccess.WRITE).close()
	eq(StoreCommands.find_gog_install(dir, "77", ["A"]), "", "another game's info file is never taken")
	TempTree.remove_tree(dir)


## Final review, low: nothing stopped uninstalling or moving an Epic, GOG or Amazon game
## while it runs (rm -rf or mv under the live game, its saves inside for some).
func test_no_uninstall_move_update_or_verify_under_the_running_game() -> void:
	var m := _manager("sm_running")
	var e := _epic(true)
	var running := ["epic:Quail"]
	m.game_running = func(key: String) -> bool: return key in running
	for action in ["uninstall", "move", "update", "verify"]:
		events.clear()
		var r: Dictionary = m.move(e, "/sd/Games") if action == "move" else m.call(action, e)
		ok(not r["ok"], action + ": refused while the game runs")
		eq(r["why"], StoreManager.RUNNING_WHY, action + ": and says why")
		eq(events, [["failed", "epic:Quail", action, StoreManager.RUNNING_WHY]], action + ": the UI hears it")
	eq(m.runner.started.size(), 0, "no command was started")
	ok(m.queue.job_for("epic:Quail").is_empty(), "nothing queued")
	var caps: Dictionary = m.capabilities(e)
	ok(not caps["uninstall"] and not caps["move"], "the game page doesn't offer them meanwhile")
	eq(caps["why"]["uninstall"], StoreManager.RUNNING_WHY, "with the reason")
	# another game runs: this one can go
	running[0] = "gog:1"
	ok(m.uninstall(e)["ok"], "a different game running doesn't block this one")
	_done(m)


## main.gd tells the store manager which game runs.
func test_main_wires_the_running_game_to_the_store_manager() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/main.gd")
	ok(src.contains("lib_store.game_running = func(key: String) -> bool: return session != null and session.runs(key)"), "main.gd wires store.game_running")


## Moving to a fresh SD card: its Games folder doesn't exist yet, and cp / mv
## into a missing folder fail. The folder is made before the move starts.
func test_move_makes_the_destination_folder() -> void:
	var m := _manager("sm_move_dest")
	var e := _epic(true)
	var src := m.home.path_join("Games/epic/Hades")
	DirAccess.make_dir_recursive_absolute(src)
	e["install_path"] = src
	var dest := m.home.path_join("media/SD/Games")
	ok(not DirAccess.dir_exists_absolute(dest), "no Games folder on the card yet")
	var res := m.move({"key": e["key"]}, dest)
	ok(res.get("ok", false), "move accepted (%s)" % res)
	ok(DirAccess.dir_exists_absolute(dest), "the folder it goes into is made first")
	_done(m)


## Residual B: the rename went through and only the removal of the old folder failed: the record follows the game.
func test_a_gog_move_that_fails_after_the_rename_still_updates_the_record() -> void:
	var m := _manager("sm_gog_move_rm")
	var old := m.home.path_join("Games/gog/Game")
	var new_path := m.home.path_join("SD/Games/Game")
	DirAccess.make_dir_recursive_absolute(new_path)
	StoreCommands.write_gog_record(m.home, [{"appName": "1", "install_path": old, "platform": "windows", "title": "G"}])
	var job := {"key": "gog:1", "action": "move", "state": DownloadQueue.FAILED, "error": "rm failed", "title": "G",
		"finalize": {"gog_record": "move", "new_path": new_path}}
	m._on_job_finished(job)
	eq(StoreCommands.read_gog_record(m.home)[0]["install_path"], new_path, "the record names the new folder")
	DirAccess.make_dir_recursive_absolute(new_path + StoreCommands.MOVING_SUFFIX)
	StoreCommands.write_gog_record(m.home, [{"appName": "1", "install_path": old, "platform": "windows", "title": "G"}])
	m._on_job_finished(job)
	eq(StoreCommands.read_gog_record(m.home)[0]["install_path"], old, "a copy that never finished leaves it alone")
