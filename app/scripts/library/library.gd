extends Node
## One library across every store. See docs/CONTRACTS.md for the game shape.
## Store files are read on a WorkerThreadPool thread so the UI never waits on
## disk; `changed` fires on the main thread once `games` is replaced.
##
## Store management (install, uninstall, update, verify, move, downloads, launch
## options, compatibility tool) is part of this API; the work is done by a
## StoreManager child (scripts/library/manage/). See docs/STORES.md.

signal changed
## Download or other store job progress. bytes_total 0 = unknown; eta in seconds, -1 unknown.
signal download_progress(key: String, bytes_done: int, bytes_total: int, rate: float, eta: int)
## queued | installing | updating | verifying | moving | uninstalling | downloading | paused |
## installed | not_installed | update_required | failed
signal install_state_changed(key: String, state: String)
## The download list changed (added, reordered, finished): call downloads() again.
signal queue_changed
signal action_failed(key: String, action: String, message: String)
## A store's own window needs the user: app is "steam" (a Steam dialog, which we
## bring forward under gamescope) or "heroic"; reason install | uninstall | page | manage.
signal external_window_needed(key: String, app: String, reason: String)
signal store_settings_changed
## A game's details (info.meta) were filled in or refreshed; `changed` follows, batched.
signal metadata_changed(key: String)

const Steam := preload("res://scripts/library/stores/steam.gd")
const Epic := preload("res://scripts/library/stores/epic.gd")
const Gog := preload("res://scripts/library/stores/gog.gd")
const Amazon := preload("res://scripts/library/stores/amazon.gd")
const Common := preload("res://scripts/library/stores/common.gd")
const GameDB := preload("res://scripts/library/gamedb.gd")
const StoreManager := preload("res://scripts/library/manage/store_manager.gd")
const Metadata := preload("res://scripts/library/meta/metadata.gd")
const MetaResolver := preload("res://scripts/library/meta/resolver.gd")
const ArtService := preload("res://scripts/library/art/art_service.gd")
const ArtOverrides := preload("res://scripts/library/art/art_overrides.gd")
## How long to gather detail / art updates before one `changed`.
const BATCH_S := 2.0

var games: Array[Dictionary] = []
## Home folder the stores are read from.
var home := OS.get_environment("HOME")

var _entries := {}            # key -> full store entry (launch details live here)
var _tools := {}
var _task := -1
var _again := false
var _launch_n := 0
var _db: Node
var _task_store := ""
## Does the store work; null until _ready (and in tests that don't make one).
var store: Node
## Fills in missing game details (scripts/library/meta/resolver.gd); null in tests that don't make one.
var metadata: Node
## Change artwork and the automatic art fill (scripts/library/art/art_service.gd).
var artwork: Node
var _batch: Timer


func _ready() -> void:
	if preload("res://scripts/system/run_mode.gd").helper():
		return   # --restore-baseline: no services (review 2, problem 5)
	# The test runner loads autoloads too; tests must never read the real home.
	var main_script = get_tree().get_script()
	if main_script != null and str(main_script.resource_path).begins_with("res://tests/"):
		return
	attach_store(StoreManager.new())
	store.setup(home)
	_db = GameDB.new()
	_db.name = "GameDB"
	add_child(_db)
	_db.updated.connect(refresh)
	attach_metadata(MetaResolver.new(), ArtService.new())
	refresh()
	if preload("res://scripts/system/privacy.gd").background_allowed():   # "Background lookups" (review M22)
		_db.update_if_stale()


## Uses `manager` (a StoreManager, or a fake with the same methods and signals)
## for store management and forwards its signals. Tests pass their own.
func attach_store(manager: Node) -> void:
	store = manager
	store.name = "Store"
	add_child(store)
	store.entry_lookup = func(key: String) -> Dictionary: return _entries.get(key, {})
	store.launcher = get_node_or_null("/root/Launcher") if is_inside_tree() else null
	store.download_progress.connect(func(k, d, t, r, e): download_progress.emit(k, d, t, r, e))
	store.install_state_changed.connect(func(k, s): install_state_changed.emit(k, s))
	store.queue_changed.connect(func(): queue_changed.emit())
	store.action_failed.connect(func(k, a, m): action_failed.emit(k, a, m))
	store.external_window_needed.connect(func(k, a, r): external_window_needed.emit(k, a, r))
	store.settings_changed.connect(func(): store_settings_changed.emit())
	store.store_changed.connect(refresh_store)


## Uses these detail and art services (tests pass their own) and follows their updates.
func attach_metadata(resolver: Node, art: Node) -> void:
	metadata = resolver
	metadata.name = "Metadata"
	add_child(metadata)
	metadata.resolved.connect(_on_meta_resolved)
	artwork = art
	artwork.name = "Artwork"
	add_child(artwork)
	artwork.art_changed.connect(_on_art_changed)
	_batch = Timer.new()
	_batch.one_shot = true
	_batch.timeout.connect(func(): changed.emit())
	add_child(_batch)


## The game, by key, as Library.games has it ({} if unknown).
func game_by_key(key: String) -> Dictionary:
	for g in games:
		if g["key"] == key:
			return g
	return {}


## Its page opened: fetch what's missing for this game now (it jumps the queue).
func request_metadata(game: Dictionary) -> void:
	if metadata != null:
		var g := game_by_key(str(game.get("key", "")))
		metadata.request(game if g.is_empty() else g)


func _changed_soon() -> void:
	if _batch != null and _batch.is_inside_tree():
		if _batch.is_stopped():
			_batch.start(BATCH_S)
	else:
		changed.emit()


func _on_meta_resolved(key: String) -> void:
	var e: Dictionary = _entries.get(key, {})
	var g := game_by_key(key)
	if e.is_empty() or g.is_empty():
		return
	var meta := MetaResolver.assemble(e.get("meta_layers", {}), str(g["info"]["meta"].get("steam_twin", "")),
		str(e.get("title", "")), ProjectSettings.globalize_path(metadata.cache_dir))
	g["info"]["meta"] = meta
	g["info"]["summary"] = meta["summary"]
	metadata_changed.emit(key)
	_changed_soon()


func _on_art_changed(key: String) -> void:
	var e: Dictionary = _entries.get(key, {})
	var g := game_by_key(key)
	if e.is_empty() or g.is_empty():
		return
	var ov: Dictionary = ArtOverrides.read(ProjectSettings.globalize_path(artwork.picked_dir)).get(key, {})
	g["art"] = ArtOverrides.apply(e.get("store_art", g["art"]), ov)
	e["art"] = g["art"]
	_changed_soon()


## Re-reads every store in the background; emits `changed` when done.
func refresh() -> void:
	if _task != -1:
		_again = true
		return
	var h := home
	var db_path := ProjectSettings.globalize_path(GameDB.CACHE_PATH)
	_task_store = ""
	_task = WorkerThreadPool.add_task(func(): _apply.call_deferred(collect(h, db_path)), false, "Library scan")


## Re-reads one store (steam | epic | gog | amazon) in the background after an
## install, uninstall or move; emits `changed` when done.
func refresh_store(store_name: String) -> void:
	if _task != -1:
		_again = true
		return
	var h := home
	var db_path := ProjectSettings.globalize_path(GameDB.CACHE_PATH)
	_task_store = store_name
	_task = WorkerThreadPool.add_task(func(): _apply.call_deferred(collect(h, db_path, [store_name])), false, "Library scan")


func _apply(result: Dictionary) -> void:
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	if _task_store == "":
		games = result["games"]
		_entries = result["entries"]
	else:
		var merged := merge_store(games, _entries, result, _task_store)
		games = merged["games"]
		_entries = merged["entries"]
	changed.emit()
	if store != null:
		store.on_library_scanned(_entries)
	if metadata != null:
		metadata.queue_games(games)
	if artwork != null:
		artwork.auto_fill(games)
	if _again:
		_again = false
		refresh()


## `games`/`entries` with every game of `store_name` replaced by a one-store
## scan's result, still sorted.
static func merge_store(old_games: Array, old_entries: Dictionary, fresh: Dictionary, store_name: String) -> Dictionary:
	var entries := {}
	for k in old_entries:
		if old_entries[k].get("store", "") != store_name:
			entries[k] = old_entries[k]
	var out: Array[Dictionary] = []
	for g in old_games:
		if g["store"] != store_name:
			out.append(g)
	for k in fresh["entries"]:
		entries[k] = fresh["entries"][k]
	out.append_array(fresh["games"])
	_sort(out)
	return {"games": out, "entries": entries}


static func _sort(list: Array) -> void:
	list.sort_custom(func(a, b):
		var c: int = a["title"].naturalnocasecmp_to(b["title"])
		return c < 0 if c != 0 else a["key"] < b["key"])


func _exit_tree() -> void:
	if _task != -1:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1


## Reads all stores under `home_dir`, fills game info from the database at
## `db_path`, and returns {"games": sorted contract games, "entries": key -> entry}.
## Safe to call off the main thread. The same game in two stores keeps two keys.
static func collect(home_dir: String, db_path: String, only: Array = []) -> Dictionary:
	var all: Array[Dictionary] = []
	if only.is_empty() or "steam" in only:
		all.append_array(Steam.scan(home_dir))
	if only.is_empty() or "epic" in only:
		all.append_array(Epic.scan(home_dir))
	if only.is_empty() or "gog" in only:
		all.append_array(Gog.scan(home_dir))
	if only.is_empty() or "amazon" in only:
		all.append_array(Amazon.scan(home_dir))
	var index := GameDB.build_index(GameDB.load_file(db_path))
	var meta_dir := ProjectSettings.globalize_path(MetaResolver.CACHE_DIR)
	var overrides := ArtOverrides.read(ProjectSettings.globalize_path(ArtOverrides.DIR))
	var entries := {}
	for e in all:
		var key := "%s:%s" % [e["store"], e["id"]]
		if entries.has(key) and (entries[key].get("installed", false) or not e.get("installed", false)):
			continue
		var rec := GameDB.find(index, e.get("ids", {}), e.get("title", ""))
		e["info"] = GameDB.info_for(rec)
		var steam_id = rec.get("ids", {}).get("steam", null) if rec.get("ids") is Dictionary else null
		if steam_id != null and e["store"] != "steam":
			e["umu_id"] = "umu-%s" % steam_id
		# Details: the store's own, then the database's, then cached live fetches (Metadata).
		var twin := str(e["id"]) if e["store"] == "steam" else (str(steam_id) if steam_id != null else "")
		e["meta_layers"] = {"local": e.get("local_meta", {}), "db": Metadata.gamedb_layers(rec)}
		e["info"]["meta"] = MetaResolver.assemble(e["meta_layers"], twin, str(e.get("title", "")), meta_dir)
		e["info"]["summary"] = e["info"]["meta"]["summary"]
		# Art: picked or auto-filled art over (or in place of) the store's.
		e["store_art"] = e.get("art", Common.empty_art())
		e["art"] = ArtOverrides.apply(e["store_art"], overrides.get(key, {}))
		entries[key] = e
	var out: Array[Dictionary] = []
	for key in entries:
		out.append(make_game(entries[key]))
	_sort(out)
	return {"games": out, "entries": entries}


## Fills every field of the contract's game shape so the UI never checks for missing keys.
static func make_game(entry: Dictionary) -> Dictionary:
	return {
		"key": "%s:%s" % [entry["store"], entry["id"]],
		"store": entry["store"],
		"id": entry["id"],
		"title": entry.get("title", ""),
		"installed": entry.get("installed", false),
		"art": entry.get("art", Common.empty_art()),
		"info": entry.get("info", {"released": null, "time_to_beat": null, "anticheat": null, "protondb": null,
			"summary": "", "meta": Metadata.empty()}),
		"last_played": entry.get("last_played", 0),
		"playtime_min": entry.get("playtime_min", 0),
	}


## The command that starts `entry` as [program, args...], or [] if this
## machine has no way to run it. Steam games go through steam:// instead.
static func launch_command(entry: Dictionary, tools: Dictionary, extra_env := {}) -> Array[String]:
	match entry.get("store", ""):
		"epic":
			return Epic.launch_command(entry, tools, extra_env)
		"gog":
			var task := {}
			if entry.get("platform", "") != "linux":
				task = Gog.primary_task(entry.get("install_path", ""), entry["id"])
			return Gog.launch_command(entry, tools, task, extra_env)
		"amazon":
			return Amazon.launch_command(entry, tools, extra_env)
	return [] as Array[String]


## Gamescope app id for a game we start ourselves. Real Steam app ids are far
## below 2^30, so ids with bit 30 set (and bit 31 clear, so it stays a positive
## 31-bit int) can't collide with them, with our home screen (769) or with
## Steam's 413091. Stable across runs: the first 32 bits of sha256(key).
## OpenGamepadUI hashes the game name modulo 800483647 instead
## (library_launch_item.gd get_app_id); that range overlaps real Steam ids.
static func app_id_for(game_key: String) -> int:
	return (game_key.sha256_text().substr(0, 8).hex_to_int() & 0x3FFFFFFF) | 0x40000000


## Wraps `cmd` so it runs in its own systemd user scope named the way gamescope
## reads an app id from a process's cgroup (`app-steam-app<id>-<n>.scope`,
## gamescope src/Utils/Process.cpp GetAppIdFromCgroup). Every child the game
## starts stays in the scope, so gamescope can focus its windows. --collect drops
## the unit when it ends, even if the game crashed.
static func scope_command(cmd: Array, app_id: int, n: int, systemd_run := "systemd-run") -> Array[String]:
	var out: Array[String] = [systemd_run, "--user", "--scope", "--collect", "--quiet",
		"--unit=app-steam-app%d-%d" % [app_id, n], "--"]
	for c in cmd:
		out.append(str(c))
	return out


## True when `systemd-run --user` can work here: the binary is on PATH and the
## user's systemd instance is running (its runtime folder exists). Without it a
## scoped launch would fail outright, so we start the game plainly instead.
static func can_scope(systemd_run: String, runtime_dir: String) -> bool:
	return systemd_run != "" and runtime_dir != "" and DirAccess.dir_exists_absolute(runtime_dir.path_join("systemd"))


## A store entry with the user's compatibility settings applied (Launcher.compat_for):
## their Wine prefix and Proton (as umu's PROTONPATH) win over the store's.
static func apply_compat(entry: Dictionary, compat: Dictionary, proton_path: String) -> Dictionary:
	var e := entry.duplicate()
	if str(compat.get("prefix", "")) != "":
		e["prefix"] = compat["prefix"]
	if proton_path != "":
		e["proton_path"] = proton_path
	return e


## `cmd` plus the user's extra game arguments (shell-split). A Heroic hand-off
## takes none: Heroic keeps its own per-game arguments.
static func append_args(cmd: Array, args: String) -> Array[String]:
	var out: Array[String] = []
	for c in cmd:
		out.append(str(c))
	if args.strip_edges() == "":
		return out
	for c in out:
		if c.begins_with("heroic://"):
			return out
	out.append_array(Common.shell_split(args))
	return out


## Starts the game through its store. Returns {"ok", "app_id", "pid", "scoped"}:
## app_id is what gamescope will know the game by (its Steam app id, or our own
## id for a scoped launch; 0 when gamescope can't tell), pid the process we
## started (0 for Steam, which hands the launch to the running client).
## options: {"args": String} extra arguments for this launch only (Steam: before
## the game's own launch options; others: after the saved extra arguments).
func launch(game: Dictionary, options := {}) -> Dictionary:
	var result := {"ok": false, "app_id": 0, "pid": 0, "scoped": false}
	var entry: Dictionary = _entries.get(game.get("key", ""), game)
	var path_env := OS.get_environment("PATH")
	var once := str(options.get("args", ""))
	if entry.get("store", "") == "steam":
		if once != "" and store != null:
			result["ok"] = store.steam.launch(str(entry["id"]), once)["ok"]
		else:
			result["ok"] = Steam.launch(str(entry["id"]), Common.which("steam", path_env))
		result["app_id"] = str(entry["id"]).to_int()
		return result
	if _tools.is_empty():
		_tools = Common.find_tools(home, path_env)
	var extra := {}
	var args := once
	var launcher := get_node_or_null("/root/Launcher") if is_inside_tree() else null
	if launcher != null and launcher.has_method("launch_env"):
		extra = launcher.launch_env(game)
	if launcher != null and launcher.has_method("compat_for"):
		var compat: Dictionary = launcher.compat_for(str(game.get("key", "%s:%s" % [entry["store"], entry["id"]])))
		entry = apply_compat(entry, compat, launcher.proton_path_for(compat["proton"]))
		args = (str(compat["args"]) + " " + once).strip_edges()
	var cmd: Array = append_args(launch_command(entry, _tools, extra), args)
	if cmd.is_empty():
		push_warning("Can't launch %s: install umu-launcher and the store's tool, or Heroic" % entry.get("title", "?"))
		return result
	var systemd_run := Common.which("systemd-run", path_env)
	if can_scope(systemd_run, OS.get_environment("XDG_RUNTIME_DIR")):
		var id := app_id_for("%s:%s" % [entry["store"], entry["id"]])
		_launch_n += 1
		var n := (int(Time.get_unix_time_from_system()) % 100000000) * 10 + _launch_n % 10
		cmd = scope_command(cmd, id, n, systemd_run)
		result["app_id"] = id
		result["scoped"] = true
	else:
		push_warning("systemd-run --user not available: %s starts without an app id, so gamescope can't focus it" % entry.get("title", "?"))
	var pid := OS.create_process(cmd[0], cmd.slice(1))
	result["ok"] = pid > 0
	result["pid"] = maxi(pid, 0)
	if not result["ok"]:
		result["app_id"] = 0
	return result


# --- Store management (docs/STORES.md). Each returns at once; results arrive as signals. ---

func _no_store() -> Dictionary:
	return {"ok": false, "via": "", "why": "Store management isn't running"}


## What can be done for this game here: {"install", "uninstall", "update", "verify",
## "move", "launch_options", "compat_tool", "progress", "pause", "resume", "cancel": bool,
## "how": {cap: backend}, "why": {cap: reason shown when false}, "needs_window": [caps
## that show a Steam or Heroic window]}. Hide or explain whatever is false.
func capabilities(game: Dictionary) -> Dictionary:
	if store == null:
		return {"install": false, "uninstall": false, "update": false, "verify": false, "move": false,
			"launch_options": false, "compat_tool": false, "progress": false, "pause": false, "resume": false,
			"cancel": false, "how": {}, "why": {}, "needs_window": []}
	return store.capabilities(game)


## options: {"path": folder from install_locations() (default <install_root>/<store>,
## Steam: Steam's default library), "platform": "windows"|"linux" (GOG only)}.
func install(game: Dictionary, options := {}) -> Dictionary:
	return store.install(game, options) if store != null else _no_store()


func uninstall(game: Dictionary) -> Dictionary:
	return store.uninstall(game) if store != null else _no_store()


func update(game: Dictionary) -> Dictionary:
	return store.update(game) if store != null else _no_store()


## Verify and repair the game's files.
func verify(game: Dictionary) -> Dictionary:
	return store.verify(game) if store != null else _no_store()


## Moves the install into folder `path` (the game keeps its folder name).
func move(game: Dictionary, path: String) -> Dictionary:
	return store.move(game, path) if store != null else _no_store()


func pause(game: Dictionary) -> Dictionary:
	return store.pause(game) if store != null else _no_store()


func resume(game: Dictionary) -> Dictionary:
	return store.resume(game) if store != null else _no_store()


func cancel(game: Dictionary) -> Dictionary:
	return store.cancel(game) if store != null else _no_store()


## Moves a waiting download up (delta < 0) or down the queue.
func reorder_download(game: Dictionary, delta: int) -> bool:
	return store.reorder(game, delta) if store != null else false


## Unfinished downloads and store jobs, in queue order:
## [{"key", "action", "title", "state", "progress": {"bytes_done", "bytes_total",
##   "rate", "eta", "percent", "unit": bytes|files, "phase"}, "error", "size"}].
func downloads() -> Array[Dictionary]:
	return store.downloads() if store != null else [] as Array[Dictionary]


func launch_options(game: Dictionary) -> String:
	return store.launch_options(game) if store != null else ""


## Steam: the game's launch options in Steam. Others: extra game arguments.
## {"ok", "via", "why", "pending": true when it waits for a Steam restart}.
func set_launch_options(game: Dictionary, options: String) -> Dictionary:
	return store.set_launch_options(game, options) if store != null else _no_store()


## Off-main-thread versions for the UI: `done` gets the value on the main thread.
func launch_options_async(game: Dictionary, done: Callable) -> void:
	if store != null:
		store.launch_options_async(game, done)
	else:
		done.call("")


func compat_tool_async(game: Dictionary, done: Callable) -> void:
	if store != null:
		store.compat_tool_async(game, done)
	else:
		done.call("")


func compat_tools_async(game: Dictionary, done: Callable) -> void:
	if store != null:
		store.compat_tools_async(game, done)
	else:
		done.call([] as Array[Dictionary])


func compat_tool(game: Dictionary) -> String:
	return store.compat_tool(game) if store != null else ""


## tool_id from compat_tools(game); "" = the default.
func set_compat_tool(game: Dictionary, tool_id: String) -> Dictionary:
	return store.set_compat_tool(game, tool_id) if store != null else _no_store()


## [{"id", "name", "path", ...}], the default ("" id) first. Steam's tools for a
## Steam game, umu's (Proton builds GameCove can start a game with) otherwise.
func compat_tools(game: Dictionary = {}) -> Array[Dictionary]:
	return store.compat_tools(game) if store != null else [] as Array[Dictionary]


## Where games can go: [{"path", "label", "free": bytes, "removable": bool}], internal first.
func install_locations() -> Array[Dictionary]:
	return store.install_locations() if store != null else [] as Array[Dictionary]


## {"install_root", "steam_cef", "auto_resume", "max_parallel", "focus_steam_dialogs",
##  "steam_cef_status": off|flag_missing|connecting|ready|unreachable, "steam_pending_count"}
func store_settings() -> Dictionary:
	return store.get_settings() if store != null else {}


func set_store_setting(name: String, value: Variant) -> bool:
	return store.set_setting(name, value) if store != null else false


## Steam settings waiting for Steam to stop: write them now if it is stopped, or
## (restart = true) restart Steam to write them.
func apply_pending_steam_changes(restart := false) -> Dictionary:
	return store.apply_pending_steam_changes(restart) if store != null else _no_store()


## page: store | properties | details | downloads. Opens it in Steam's window.
func open_steam_page(game: Dictionary, page: String) -> Dictionary:
	if store == null:
		return _no_store()
	return store.steam.open_page(str(game.get("id", "")), page)


## Back to GameCove after a Steam dialog we brought forward.
func return_from_steam() -> void:
	if store != null:
		store.return_from_steam()
