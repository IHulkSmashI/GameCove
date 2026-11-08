extends Node
## One library across every store. See docs/CONTRACTS.md for the game shape.
## Store files are read on a WorkerThreadPool thread so the UI never waits on
## disk; `changed` fires on the main thread once `games` is replaced.

signal changed

const Steam := preload("res://scripts/library/stores/steam.gd")
const Epic := preload("res://scripts/library/stores/epic.gd")
const Gog := preload("res://scripts/library/stores/gog.gd")
const Amazon := preload("res://scripts/library/stores/amazon.gd")
const Common := preload("res://scripts/library/stores/common.gd")
const GameDB := preload("res://scripts/library/gamedb.gd")

var games: Array[Dictionary] = []
## Home folder the stores are read from.
var home := OS.get_environment("HOME")

var _entries := {}            # key -> full store entry (launch details live here)
var _tools := {}
var _task := -1
var _again := false
var _db: Node


func _ready() -> void:
	# The test runner loads autoloads too; tests must never read the real home.
	var main_script = get_tree().get_script()
	if main_script != null and str(main_script.resource_path).begins_with("res://tests/"):
		return
	_db = GameDB.new()
	_db.name = "GameDB"
	add_child(_db)
	_db.updated.connect(refresh)
	refresh()
	_db.update_if_stale()


## Re-reads every store in the background; emits `changed` when done.
func refresh() -> void:
	if _task != -1:
		_again = true
		return
	var h := home
	var db_path := ProjectSettings.globalize_path(GameDB.CACHE_PATH)
	_task = WorkerThreadPool.add_task(func(): _apply.call_deferred(collect(h, db_path)), false, "Library scan")


func _apply(result: Dictionary) -> void:
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	games = result["games"]
	_entries = result["entries"]
	changed.emit()
	if _again:
		_again = false
		refresh()


func _exit_tree() -> void:
	if _task != -1:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1


## Reads all stores under `home_dir`, fills game info from the database at
## `db_path`, and returns {"games": sorted contract games, "entries": key -> entry}.
## Safe to call off the main thread. The same game in two stores keeps two keys.
static func collect(home_dir: String, db_path: String) -> Dictionary:
	var all: Array[Dictionary] = []
	all.append_array(Steam.scan(home_dir))
	all.append_array(Epic.scan(home_dir))
	all.append_array(Gog.scan(home_dir))
	all.append_array(Amazon.scan(home_dir))
	var index := GameDB.build_index(GameDB.load_file(db_path))
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
		entries[key] = e
	var out: Array[Dictionary] = []
	for key in entries:
		out.append(make_game(entries[key]))
	out.sort_custom(func(a, b):
		var c: int = a["title"].naturalnocasecmp_to(b["title"])
		return c < 0 if c != 0 else a["key"] < b["key"])
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
		"info": entry.get("info", {"released": null, "time_to_beat": null, "anticheat": null, "protondb": null}),
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


## Starts the game through its store. Returns false if it couldn't be started.
func launch(game: Dictionary) -> bool:
	var entry: Dictionary = _entries.get(game.get("key", ""), game)
	if entry.get("store", "") == "steam":
		Steam.launch(entry["id"])
		return true
	if _tools.is_empty():
		_tools = Common.find_tools(home, OS.get_environment("PATH"))
	var extra := {}
	var launcher := get_node_or_null("/root/Launcher")
	if launcher != null and launcher.has_method("launch_env"):
		extra = launcher.launch_env(game)
	var cmd := launch_command(entry, _tools, extra)
	if cmd.is_empty():
		push_warning("Can't launch %s: install umu-launcher and the store's tool, or Heroic" % entry.get("title", "?"))
		return false
	return OS.create_process(cmd[0], cmd.slice(1)) > 0
