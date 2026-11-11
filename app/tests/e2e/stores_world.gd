extends RefCounted
## The game stores of the end-to-end journeys (suite_journeys.gd, suite_monkey.gd).
##
## World (world.gd) gives the real app a fake handheld. This adds the player's
## games on it, the way they are on a real one: Steam's library folders and
## appmanifests, legendary's (Epic) metadata and installed.json, Heroic's GOG
## library with a gogdl sign-in, nile's (Amazon) library, an SD card. The store
## tools are tests/e2e/fakebin/fakestore.py under each tool's name, first on PATH,
## so the real StoreManager, DownloadQueue and JobRunner start real processes and
## parse real progress lines; nothing reaches a network.
##
## Steam itself is played here (`steam_tick`), like the running client: the fake
## `steam` binary only spools the URI it was handed, and this:
##   steam://install/<id>    downloads into the manifest in steps (BytesDownloaded,
##                           StateFlags downloading), then marks it installed
##   steam://uninstall/<id>  removes the manifest and the game folder
##   steam://validate/<id>   validates for a few steps
##   steam://rungameid/<id>  the game's window shows up in gamescope's list; Steam
##                           writes LastPlayed / Playtime into localconfig.vdf when
##                           the game quits (World.end_app)
##   steam://open/..., store, gameproperties: recorded (Steam's own windows)
##
## attach() before a journey, detach() after: PATH, Library and the services go
## back to what the other suites expect (no games).

const StoreManager := preload("res://scripts/library/manage/store_manager.gd")
const Common := preload("res://scripts/library/stores/common.gd")
const Acf := preload("res://scripts/steam/acf.gd")

## The games, by key.
const STEAM := {
	"1145360": {"name": "Hades", "dir": "Hades", "flags": 4, "playtime": 90, "last": 1700000000},
	"367520": {"name": "Hollow Knight", "dir": "Hollow Knight", "flags": 4, "playtime": 600, "last": 1760000000},
	"1091500": {"name": "Cyberpunk 2077", "dir": "Cyberpunk 2077", "flags": 6, "playtime": 30, "last": 1750000000},
	"413150": {"name": "Stardew Valley", "dir": "Stardew Valley", "flags": 2, "playtime": 0, "last": 0},
}
const EPIC := {
	"Quail": {"title": "Celeste", "installed": true},
	"Salt": {"title": "Rocket League", "installed": false},
	"Fern": {"title": "Alan Wake 2", "installed": false},
}
const GOG := {"1207658924": {"title": "The Witcher 3", "installed": false}}
const AMAZON := {"amzn1.adg.product.e2e1": {"title": "Quake", "installed": false}}

var w: RefCounted
var bin_dir := ""
var state_dir := ""
var sd_card := ""
var steam_root := ""
var _old_path := ""
var _old_home := ""
var _old_storage_home := ""
var _ticker: Callable
var _last_tick := 0
## appid -> {"action", "step"}: what the fake Steam client is doing.
var steam_jobs := {}
## steam:// URIs and flags the client got, in order.
var steam_uris: Array = []
## appid -> unix time the game started (Steam counts play time from it).
var steam_running := {}


func _init(world: RefCounted) -> void:
	w = world


# ---- building the stores -----------------------------------------------------------

func attach() -> void:
	var base: String = w.root.get_base_dir()
	bin_dir = base.path_join("fakebin")
	state_dir = base.path_join("fakestore")
	sd_card = w.root.path_join("run/media/deck/SDCARD")
	steam_root = w.home.path_join(".local/share/Steam")
	_reset_dir(state_dir)
	DirAccess.make_dir_recursive_absolute(bin_dir)
	var src := FileAccess.get_file_as_string(ProjectSettings.globalize_path("res://tests/e2e/fakebin/fakestore.py"))
	for tool in ["steam", "legendary", "gogdl", "nile", "umu-run"]:
		var f := FileAccess.open(bin_dir.path_join(tool), FileAccess.WRITE)
		f.store_string(src)
		f.close()
		FileAccess.set_unix_permissions(bin_dir.path_join(tool), 493)
	_write_home()
	_old_path = OS.get_environment("PATH")
	if not _old_path.begins_with(bin_dir):
		OS.set_environment("PATH", bin_dir + ":" + _old_path)
	OS.set_environment("GAMECOVE_FAKE_STORE", state_dir)
	_wire_library()
	_wire_storage()
	_ticker = steam_tick
	if not w.tree.process_frame.is_connected(_ticker):
		w.tree.process_frame.connect(_ticker)
	w.on_app_end = _steam_ended


func detach() -> void:
	if _ticker.is_valid() and w.tree.process_frame.is_connected(_ticker):
		w.tree.process_frame.disconnect(_ticker)
	w.on_app_end = Callable()
	var lib: Node = w.autoload("Library")
	if lib.store != null:
		for j in lib.store.queue.jobs.duplicate():
			if str(j.get("state", "")) in ["running", "queued", "paused"]:
				lib.store.queue.cancel(str(j["key"]))
		lib.store.queue.jobs.clear()
		lib.store.queue._save()
		lib.store.steam._watch.clear()
		lib.store.steam._timer.stop()
	_kill_fakes()
	OS.set_environment("PATH", _old_path if _old_path != "" else OS.get_environment("PATH").trim_prefix(bin_dir + ":"))
	OS.unset_environment("GAMECOVE_FAKE_STORE")
	lib.home = _old_home if _old_home != "" else lib.home
	lib.games.clear()
	lib._entries.clear()
	lib.changed.emit()
	steam_jobs.clear()
	steam_running.clear()


## Store tools still running (a download a journey left): ended.
func _kill_fakes() -> void:
	OS.execute("pkill", PackedStringArray(["-TERM", "-f", bin_dir]))


static func _reset_dir(d: String) -> void:
	if DirAccess.dir_exists_absolute(d):
		for f in DirAccess.get_files_at(d):
			DirAccess.remove_absolute(d.path_join(f))
	DirAccess.make_dir_recursive_absolute(d)


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _write_home() -> void:
	var h: String = w.home
	# Steam: the home library and an SD card library
	DirAccess.make_dir_recursive_absolute(sd_card.path_join("steamapps"))
	_write(steam_root.path_join("steamapps/libraryfolders.vdf"),
		"\"libraryfolders\"\n{\n\t\"0\"\n\t{\n\t\t\"path\"\t\t\"%s\"\n\t}\n\t\"1\"\n\t{\n\t\t\"path\"\t\t\"%s\"\n\t}\n}\n" % [steam_root, sd_card])
	_write(steam_root.path_join("config/loginusers.vdf"),
		"\"users\"\n{\n\t\"76561190000000001\"\n\t{\n\t\t\"AccountName\"\t\t\"coveplayer\"\n\t\t\"PersonaName\"\t\t\"CovePlayer\"\n\t\t\"MostRecent\"\t\t\"1\"\n\t}\n}\n")
	for appid in STEAM:
		var g: Dictionary = STEAM[appid]
		write_manifest(steam_root, appid, int(g["flags"]), 0 if int(g["flags"]) & Acf.FULLY_INSTALLED else 0)
		if int(g["flags"]) & Acf.FULLY_INSTALLED:
			_write(steam_root.path_join("steamapps/common/%s/game.bin" % g["dir"]), "e2e\n")
	_write_localconfig()
	# Epic (legendary, signed in)
	var leg := h.path_join(".config/legendary")
	_write(leg.path_join("user.json"), JSON.stringify({"displayName": "CovePlayer", "account_id": "e2e"}))
	var inst := {}
	for app in EPIC:
		var e: Dictionary = EPIC[app]
		_write(leg.path_join("metadata/%s.json" % app), JSON.stringify({"app_name": app, "app_title": e["title"],
			"metadata": {"namespace": "e2e", "title": e["title"], "id": "id-" + app}}))
		if e["installed"]:
			var folder := h.path_join("Games/epic/" + str(e["title"]))
			_write(folder.path_join("game.exe"), "e2e\n")
			inst[app] = {"app_name": app, "title": e["title"], "install_path": folder, "executable": "game.exe",
				"is_dlc": false, "platform": "Windows", "version": "1.0", "install_size": 1234, "can_run_offline": true,
				"launch_parameters": "", "save_path": null}
	_write(leg.path_join("installed.json"), JSON.stringify(inst, "  "))
	# GOG through Heroic, signed in for gogdl
	var heroic := h.path_join(".config/heroic")
	var games := []
	for id in GOG:
		games.append({"app_name": id, "title": GOG[id]["title"], "runner": "gog", "is_installed": false})
	_write(heroic.path_join("store_cache/gog_library.json"), JSON.stringify({"games": games}))
	_write(heroic.path_join("gog_store/installed.json"), JSON.stringify({"installed": []}))
	_write(heroic.path_join("gog_store/auth.json"), JSON.stringify({"46899977096215655": {"access_token": "e2e", "user_id": "1"}}))
	# Amazon (nile)
	var lib := []
	for id in AMAZON:
		lib.append({"product": {"id": id, "title": AMAZON[id]["title"]}})
	_write(h.path_join(".config/nile/library.json"), JSON.stringify(lib))
	_write(h.path_join(".config/nile/installed.json"), "[]")
	_write(h.path_join(".config/nile/current_user.json"), JSON.stringify({"user_id": "e2e", "name": "CovePlayer"}))


## An appmanifest as Steam writes it.
static func write_manifest(root: String, appid: String, flags: int, done: int, total := 1048576000, folder := "") -> void:
	var g: Dictionary = STEAM.get(appid, {"name": appid, "dir": appid})
	var lib := folder if folder != "" else root
	var text := "\"AppState\"\n{\n\t\"appid\"\t\t\"%s\"\n\t\"Universe\"\t\t\"1\"\n\t\"name\"\t\t\"%s\"\n\t\"StateFlags\"\t\t\"%d\"\n\t\"installdir\"\t\t\"%s\"\n\t\"SizeOnDisk\"\t\t\"%d\"\n\t\"buildid\"\t\t\"100\"\n\t\"BytesToDownload\"\t\t\"%d\"\n\t\"BytesDownloaded\"\t\t\"%d\"\n\t\"BytesToStage\"\t\t\"%d\"\n\t\"BytesStaged\"\t\t\"%d\"\n}\n" % [
		appid, g["name"], flags, g["dir"], total if flags & Acf.FULLY_INSTALLED else 0, total, done, total, done]
	var p := lib.path_join("steamapps/appmanifest_%s.acf" % appid)
	DirAccess.make_dir_recursive_absolute(p.get_base_dir())
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _write_localconfig() -> void:
	var apps := ""
	for appid in STEAM:
		var g: Dictionary = STEAM[appid]
		var pt: int = int(g["playtime"]) + int(_extra_minutes.get(appid, 0))
		var last: int = int(_last_played.get(appid, g["last"]))
		apps += "\t\t\t\t\t\"%s\"\n\t\t\t\t\t{\n\t\t\t\t\t\t\"LastPlayed\"\t\t\"%d\"\n\t\t\t\t\t\t\"Playtime\"\t\t\"%d\"\n\t\t\t\t\t}\n" % [appid, last, pt]
	_write(steam_root.path_join("userdata/12345678/config/localconfig.vdf"),
		"\"UserLocalConfigStore\"\n{\n\t\"Software\"\n\t{\n\t\t\"Valve\"\n\t\t{\n\t\t\t\"Steam\"\n\t\t\t{\n\t\t\t\t\"apps\"\n\t\t\t\t{\n%s\t\t\t\t}\n\t\t\t}\n\t\t}\n\t}\n}\n" % apps)


var _extra_minutes := {}
var _last_played := {}


# ---- wiring the app's services to the stores --------------------------------------------

func _wire_library() -> void:
	var lib: Node = w.autoload("Library")
	if _old_home == "":
		_old_home = lib.home
	lib.home = w.home
	if lib.store == null:
		# the test runner's Library comes up without a store (library.gd _ready): the app's one
		lib.attach_store(StoreManager.new())
	var st: Node = lib.store
	st.settings_path = "user://e2e_store_settings.json"
	st.queue_path = "user://e2e_downloads.json"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(st.settings_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(st.queue_path))
	st.media_root = w.root.path_join("run/media")
	st.user = "deck"
	st.queue.jobs.clear()
	st.setup(w.home)
	st.steam.proc_root = w.root.path_join("proc")
	st.steam._timer.wait_time = 0.3   # Steam's manifest watch, on the journeys' clock
	st.launcher = w.autoload("Launcher")


func _wire_storage() -> void:
	var s: Node = w.autoload("Storage")
	if s == null:
		return
	var mounts: String = str(w.root).get_base_dir().path_join("mounts")
	var root_dev := "/dev/nvme0n1p2 / btrfs rw 0 0\n/dev/nvme0n1p2 /home btrfs rw 0 0\n/dev/mmcblk0p1 %s ext4 rw 0 0\n" % sd_card
	_write(mounts, root_dev)
	var fm := {"filesystems": [
		{"source": "/dev/nvme0n1p2", "target": "/", "fstype": "btrfs", "size": 512110190592, "used": 200000000000, "avail": 312110190592, "options": "rw"},
		{"source": "/dev/nvme0n1p2", "target": "/home", "fstype": "btrfs", "size": 512110190592, "used": 200000000000, "avail": 312110190592, "options": "rw"},
		{"source": "/dev/mmcblk0p1", "target": sd_card, "fstype": "ext4", "size": 255850000000, "used": 5000000000, "avail": 250850000000, "options": "rw"}]}
	var lb := {"blockdevices": [
		{"name": "nvme0n1", "path": "/dev/nvme0n1", "pkname": null, "type": "disk", "size": 512110190592, "rm": false, "hotplug": false, "tran": "nvme", "model": "E2E SSD", "label": null, "fstype": null},
		{"name": "nvme0n1p2", "path": "/dev/nvme0n1p2", "pkname": "nvme0n1", "type": "part", "size": 512110190592, "rm": false, "hotplug": false, "tran": null, "model": null, "label": null, "fstype": "btrfs"},
		{"name": "mmcblk0", "path": "/dev/mmcblk0", "pkname": null, "type": "disk", "size": 255850000000, "rm": true, "hotplug": true, "tran": null, "model": "SD", "label": null, "fstype": null},
		{"name": "mmcblk0p1", "path": "/dev/mmcblk0p1", "pkname": "mmcblk0", "type": "part", "size": 255850000000, "rm": true, "hotplug": true, "tran": null, "model": null, "label": "SDCARD", "fstype": "ext4"}]}
	var f: RefCounted = w.fake
	f.commands = f.commands.duplicate()
	f.commands.append({"argv": ["findmnt", "*"], "out": JSON.stringify(fm)})
	f.commands.append({"argv": ["lsblk", "*"], "out": JSON.stringify(lb)})
	if _old_storage_home == "":
		_old_storage_home = s.home
	s.setup(f, w.home, mounts)


## The library as the app reads it from the files now (a rescan, as at start).
func rescan() -> void:
	var lib: Node = w.autoload("Library")
	var done := [false]
	var cb := func(): done[0] = true
	lib.changed.connect(cb, CONNECT_ONE_SHOT)
	lib.refresh()
	var deadline := Time.get_ticks_msec() + 10000
	while not done[0] and Time.get_ticks_msec() < deadline:
		await w.tree.process_frame
	await w.frames(3)


# ---- the fake Steam client ------------------------------------------------------------

## One look at what Steam was handed and one step of what it is doing (every 150 ms).
func steam_tick() -> void:
	var now := Time.get_ticks_msec()
	if now - _last_tick < 150:
		return
	_last_tick = now
	_read_spool()
	for appid in steam_jobs.keys():
		_step(appid)


func _read_spool() -> void:
	var p := state_dir.path_join("steam.spool")
	if not FileAccess.file_exists(p):
		return
	var text := FileAccess.get_file_as_string(p)
	DirAccess.remove_absolute(p)
	for line in text.split("\n", false):
		var argv: Variant = JSON.parse_string(line)
		if not argv is Array or argv.is_empty():
			continue
		var uri := str(argv[0])
		steam_uris.append(uri)
		_handle(uri)


func _handle(uri: String) -> void:
	for kind in ["install", "uninstall", "validate", "rungameid"]:
		var prefix := "steam://%s/" % kind
		if uri.begins_with(prefix):
			var appid := uri.trim_prefix(prefix).get_slice("/", 0)
			if kind == "rungameid":
				start_game(appid)
			else:
				steam_jobs[appid] = {"action": kind, "step": 0}


## Where an app's manifest is now (its library folder), "" when it has none.
func library_of(appid: String) -> String:
	for lib in [steam_root, sd_card]:
		if FileAccess.file_exists(lib.path_join("steamapps/appmanifest_%s.acf" % appid)):
			return lib
	return ""


func _step(appid: String) -> void:
	var j: Dictionary = steam_jobs[appid]
	j["step"] = int(j["step"]) + 1
	var lib := library_of(appid)
	var total := 1048576000
	match str(j["action"]):
		"install":
			if lib == "":
				lib = steam_root
			if int(j["step"]) <= 4:
				write_manifest(steam_root, appid, Acf.UPDATE_REQUIRED | Acf.UPDATE_STARTED | Acf.DOWNLOADING,
					total * int(j["step"]) / 5, total, lib)
			else:
				var g: Dictionary = STEAM.get(appid, {"dir": appid})
				_write(lib.path_join("steamapps/common/%s/game.bin" % g["dir"]), "e2e\n")
				write_manifest(steam_root, appid, Acf.FULLY_INSTALLED, total, total, lib)
				steam_jobs.erase(appid)
		"uninstall":
			if lib != "":
				var g: Dictionary = STEAM.get(appid, {"dir": appid})
				DirAccess.remove_absolute(lib.path_join("steamapps/appmanifest_%s.acf" % appid))
				var gd := lib.path_join("steamapps/common/%s" % g["dir"])
				for f in DirAccess.get_files_at(gd):
					DirAccess.remove_absolute(gd.path_join(f))
				DirAccess.remove_absolute(gd)
			steam_jobs.erase(appid)
		"validate":
			if lib == "":
				steam_jobs.erase(appid)
			elif int(j["step"]) <= 2:
				write_manifest(steam_root, appid, Acf.FULLY_INSTALLED | Acf.VALIDATING, total, total, lib)
			else:
				write_manifest(steam_root, appid, Acf.FULLY_INSTALLED, total, total, lib)
				steam_jobs.erase(appid)


## Steam starts a game: its window joins gamescope's list (and Steam's reaper runs).
func start_game(appid: String) -> void:
	var id := appid.to_int()
	steam_running[appid] = int(Time.get_unix_time_from_system())
	w.fake_apps[id] = true
	var f: RefCounted = w.fake
	f._mutex.lock()
	var ids: Array = Array(str(f.xroot.get("GAMESCOPE_FOCUSABLE_APPS", "769")).split(",", false)).map(func(x): return x.strip_edges())
	if not str(id) in ids:
		ids.append(str(id))
	f.xroot["GAMESCOPE_FOCUSABLE_APPS"] = ", ".join(PackedStringArray(ids))
	f._mutex.unlock()


## The game quit (by itself or Exit game): Steam writes its play time.
func game_quit(appid: String, minutes := 0) -> void:
	w.end_app(appid.to_int())   # on_app_end: _steam_ended


func _steam_ended(app: int, minutes := 0) -> void:
	var appid := str(app)
	if steam_running.has(appid):
		steam_running.erase(appid)
		_extra_minutes[appid] = int(_extra_minutes.get(appid, 0)) + maxi(1, minutes)
		_last_played[appid] = int(Time.get_unix_time_from_system())
		_write_localconfig()


# ---- what the store tools were asked ------------------------------------------------------

## Every store tool command line so far: [[tool, args...]].
func tool_calls() -> Array:
	var p := state_dir.path_join("calls.log")
	var out := []
	if not FileAccess.file_exists(p):
		return out
	for line in FileAccess.get_file_as_string(p).split("\n", false):
		var a: Variant = JSON.parse_string(line)
		if a is Array:
			out.append(a)
	return out


func launches() -> Array:
	var p := state_dir.path_join("launches.spool")
	var out := []
	if FileAccess.file_exists(p):
		for line in FileAccess.get_file_as_string(p).split("\n", false):
			var a: Variant = JSON.parse_string(line)
			if a is Array:
				out.append(a)
	return out


## The next `action` of a store tool fails with `why`.
func fail_next(action: String, why: String) -> void:
	_write(state_dir.path_join("fail-" + action), why)


## Seconds per progress step of the fake downloads.
func set_speed(step_s: float) -> void:
	_write(state_dir.path_join("slow"), str(step_s))


func epic_installed() -> Dictionary:
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(w.home.path_join(".config/legendary/installed.json")))
	return d if d is Dictionary else {}
