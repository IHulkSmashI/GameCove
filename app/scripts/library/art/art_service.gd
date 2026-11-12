extends Node
## Change artwork and the automatic art fill, for every library game. A child
## of Library ("Artwork"). Talks to SteamGridDB (sgdb.gd), keeps what's picked
## in user://art/picked (art_overrides.gd) and, for Steam games, can also put
## it in Steam's own grid folder with a backup (steam_grid.gd), so Steam shows
## the same art. "Reset to default" removes ours and restores Steam's files.
##
##   Library.artwork.search(game, "cover", filters, page, func(assets, error): ...)
##   Library.artwork.apply(game, "cover", asset, true, func(ok, message): ...)
##   Library.artwork.reset(game, "cover")
##   Library.artwork.art_changed.connect(func(key): ...)
##
## Privacy: every request needs "Look up game details"; the automatic fill also
## needs "Background lookups". Nothing happens without the user's own
## SteamGridDB key (the Game art step of setup, see sgdb.gd).

signal art_changed(key: String)

const Sgdb := preload("res://scripts/library/art/sgdb.gd")
const SteamGrid := preload("res://scripts/library/art/steam_grid.gd")
const Overrides := preload("res://scripts/library/art/art_overrides.gd")
const Privacy := preload("res://scripts/system/privacy.gd")
const SettingsFile := preload("res://scripts/system/settings_file.gd")
const ArtScript := preload("res://scripts/discover/art.gd")
const MAX_FILE := 12 * 1024 * 1024
## SteamGridDB's pictures come from its own hosts (cdn2.steamgriddb.com...): the
## address and every redirect hop must be https on one of them (http.gd "hosts").
const IMAGE_HOSTS := ["steamgriddb.com"]
const AUTO_GAP := 1.5
const AUTO_KINDS := ["cover", "hero", "logo"]
const RETRY_AUTO_S := 7 * 86400

var http: Variant = null
var picked_dir := Overrides.DIR
var thumbs_dir := "user://art/thumbs"
var backup_root := "user://art/steam_backup"
var prefs_path := Privacy.PREFS_PATH
## Steam's folders (tests point these at fixtures).
var steam_roots: Array = []
## Returns the user's own SteamGridDB key ("" when none); default reads Discover / Setup.
var user_key_fn: Callable = Callable()
var clock: Callable = func() -> int: return int(Time.get_unix_time_from_system())
var sync_mode := false

var _game_ids := {}     # normalised title -> SteamGridDB game id
var _auto: Array = []   # [game, kind]
var _auto_tried := {}   # "key|kind" -> unix (kept in auto_tried_path between runs)
var _auto_loaded := false
var _tasks: Array[int] = []   # WorkerThreadPool tasks writing picks into Steam
## The automatic fill's "already tried" list, so a restart doesn't ask SteamGridDB again
## for every game that has no art there (review 2, low 23).
var auto_tried_path := "user://art/auto_tried.json"
var _timer: Timer


func _ready() -> void:
	if http == null:
		var d := get_node_or_null("/root/Discover")
		if d != null and d.get("http") != null:
			http = d.http
		else:
			var node: Node = preload("res://scripts/discover/http.gd").new()
			node.name = "Http"
			add_child(node)
			http = node
	if steam_roots.is_empty():
		var Steam := preload("res://scripts/library/stores/steam.gd")
		var home := OS.get_environment("HOME")
		for r in Steam.STEAM_ROOTS:
			steam_roots.append(Steam.expand(r, home))
	_timer = Timer.new()
	_timer.one_shot = true
	_timer.timeout.connect(_auto_next)
	add_child(_timer)
	# picker thumbnails are only for browsing: a month is plenty
	preload("res://scripts/system/cache_prune.gd").prune_later(_abs(thumbs_dir), 30 * 86400)


func _abs(p: String) -> String:
	return ProjectSettings.globalize_path(p)


func user_key() -> String:
	if user_key_fn.is_valid():
		return str(user_key_fn.call())
	var d := get_node_or_null("/root/Discover") if is_inside_tree() else null
	if d != null and d.has_method("get_settings"):
		var k := str(d.get_settings().get("steamgriddb_key", ""))
		if k != "":
			return k
	var s := get_node_or_null("/root/Setup") if is_inside_tree() else null
	if s != null and s.has_method("steamgriddb_key"):
		return str(s.steamgriddb_key())
	return ""


func api_key() -> String:
	return Sgdb.key(user_key())


## Why Change artwork can't browse right now ("" when it can).
func unavailable_reason() -> String:
	if not Privacy.metadata_allowed(prefs_path):
		return "Turn on Look up game details in Settings > About > Network and privacy to browse artwork."
	if api_key() == "":
		return "Add your free SteamGridDB key in Settings > Discover > Keys to browse artwork."
	return ""


static func steam_id_of(game: Dictionary) -> String:
	if str(game.get("store", "")) == "steam":
		return str(game.get("id", ""))
	var info = game.get("info", {})
	var m = info.get("meta", {}) if info is Dictionary else {}
	return str(m.get("steam_twin", "")) if m is Dictionary else ""


func _fail(done: Callable, why: String) -> void:
	done.call([], why)


## SteamGridDB assets for `game` and `kind` (cover | hero | logo | icon):
## done(assets: Array, error: String). By Steam app id (the game's or its
## Steam twin's), else by title through SteamGridDB's search.
func search(game: Dictionary, kind: String, filters := {}, page := 0, done: Callable = Callable()) -> void:
	var why := unavailable_reason()
	if why != "":
		_fail(done, why)
		return
	var hdr := Sgdb.headers(api_key())
	var by_id := func(gid: String, by_steam: bool):
		http.request(Sgdb.assets_url(kind, gid, by_steam, filters, page), {"headers": hdr, "timeout": 20.0, "max_bytes": 2 * 1024 * 1024},
			func(res: Dictionary):
				if res["ok"]:
					done.call(Sgdb.parse_assets(res["body"]), "")
				else:
					done.call([], "SteamGridDB didn't answer (%s)." % res.get("error", "")))
	var sid := steam_id_of(game)
	if sid.is_valid_int():
		by_id.call(sid, true)
		return
	if is_rom(game):
		# A ROM game's title stays on the device (docs/PRIVACY.md row 9), here too.
		_fail(done, "A game from a ROM file keeps its title on this device, so there is no artwork to browse for it.")
		return
	var title := str(game.get("title", ""))
	var norm := title.to_lower()
	if _game_ids.has(norm):
		by_id.call(str(_game_ids[norm]), false)
		return
	http.request(Sgdb.search_url(title), {"headers": hdr, "timeout": 20.0, "max_bytes": 1024 * 1024}, func(res: Dictionary):
		var gid := Sgdb.parse_game_id(res["body"], title) if res["ok"] else 0
		if gid <= 0:
			done.call([], "SteamGridDB has nothing for this game." if res["ok"] else "SteamGridDB didn't answer (%s)." % res.get("error", ""))
			return
		_game_ids[norm] = gid
		by_id.call(str(gid), false))


## A thumbnail on disk: done(path) ("" on failure). Cached by asset id.
func thumb(asset: Dictionary, done: Callable) -> void:
	var dir := _abs(thumbs_dir)
	DirAccess.make_dir_recursive_absolute(dir)
	var base := dir.path_join("t%d" % int(asset.get("id", 0)))
	for e in ["jpg", "png", "webp"]:
		if FileAccess.file_exists(base + "." + e):
			done.call(base + "." + e)
			return
	var part := base + ".part"
	http.request(str(asset.get("thumb", "")), {"download_file": part, "timeout": 20.0, "max_bytes": 4 * 1024 * 1024, "hosts": IMAGE_HOSTS}, func(res: Dictionary):
		done.call(_keep(part, base) if res["ok"] else _drop(part)))


func _drop(part: String) -> String:
	if FileAccess.file_exists(part):
		DirAccess.remove_absolute(part)
	return ""


## Checks a download is an image (by its bytes) and names it by type.
func _keep(part: String, base: String) -> String:
	if not FileAccess.file_exists(part):
		return ""
	var f := FileAccess.open(part, FileAccess.READ)
	var size := f.get_length()
	var ext := ArtScript.sniff(f.get_buffer(12))
	f.close()
	if ext == "" or size <= 0 or size > MAX_FILE:
		return _drop(part)
	var dest := base + "." + ext
	if DirAccess.rename_absolute(part, dest) != OK:
		return _drop(part)
	return dest


## Uses `asset` as the game's `kind`: downloads it into GameCove's art and, for
## a Steam game with `to_steam`, also into Steam's grid folder (backed up
## first). done(ok: bool, message: String). source "user" (Change artwork) or "auto".
func apply(game: Dictionary, kind: String, asset: Dictionary, to_steam: bool, done: Callable = Callable(), source := "user") -> void:
	var key := str(game.get("key", ""))
	if not kind in Overrides.KINDS or key == "" or not str(asset.get("url", "")).begins_with("https://"):
		if done.is_valid():
			done.call(false, "That image can't be used.")
		return
	var dir := _abs(picked_dir)
	DirAccess.make_dir_recursive_absolute(dir)
	var base := dir.path_join(Overrides.file_base(key, kind) + "-%d" % int(asset.get("id", 0)))
	var part := base + ".part"
	http.request(str(asset["url"]), {"download_file": part, "timeout": 60.0, "max_bytes": MAX_FILE, "hosts": IMAGE_HOSTS}, func(res: Dictionary):
		var path := _keep(part, base) if res["ok"] else _drop(part)
		if path == "":
			if done.is_valid():
				done.call(false, "The image didn't download. Try another one.")
			return
		var rec := {"path": path, "source": source, "id": int(asset.get("id", 0)), "author": str(asset.get("author", "")),
			"author_url": str(asset.get("author_url", "")), "steam": []}
		if not (to_steam and str(game.get("store", "")) == "steam"):
			_apply_finish(dir, key, kind, rec, [], done)
		elif sync_mode or not is_inside_tree():
			_apply_finish(dir, key, kind, rec, write_to_steam(str(game.get("id", "")), kind, path), done)
		else:
			# a WebP pick is decoded and saved as PNG for Steam: off the main thread (review 2, low 23)
			var appid := str(game.get("id", ""))
			_tasks.append(WorkerThreadPool.add_task(func():
				call_deferred("_apply_finish", dir, key, kind, rec, write_to_steam(appid, kind, path), done),
				false, "Art to Steam")))


func _apply_finish(dir: String, key: String, kind: String, rec: Dictionary, written: Array, done: Callable) -> void:
	rec["steam"] = written
	var msg := "Artwork changed."
	if not written.is_empty():
		msg = "Artwork changed here and in Steam (Steam shows it after it restarts)."
	if not Overrides.set_override(dir, key, kind, rec):
		# the index could not be written (a full disk, a damaged index it will not overwrite): the pick is not kept
		if done.is_valid():
			done.call(false, "Couldn't save that choice. Try again.")
		return
	art_changed.emit(key)
	if done.is_valid():
		done.call(true, msg)


func _exit_tree() -> void:
	for t in _tasks:
		WorkerThreadPool.wait_for_task_completion(t)
	_tasks.clear()


## Writes an image into every Steam account's grid folder; returns the files written.
func write_to_steam(appid: String, kind: String, path: String) -> Array:
	var out := []
	for root in steam_roots:
		for grid in SteamGrid.grid_dirs(str(root)):
			var w := SteamGrid.apply(grid, SteamGrid.backup_dir_for(_abs(backup_root), grid), appid, kind, path)
			if w != "":
				out.append(w)
	return out


## The logo position Steam uses for this game ({} if it has none set).
func logo_position(appid: String) -> Dictionary:
	for root in steam_roots:
		for grid in SteamGrid.grid_dirs(str(root)):
			var p := SteamGrid.logo_position(grid, appid)
			if not p.is_empty():
				return p
	return {}


func set_logo_position(appid: String, pin: String, width_pct := 50.0, height_pct := 50.0) -> bool:
	var any := false
	for root in steam_roots:
		for grid in SteamGrid.grid_dirs(str(root)):
			any = SteamGrid.set_logo_position(grid, SteamGrid.backup_dir_for(_abs(backup_root), grid), appid, pin, width_pct, height_pct) or any
	return any


## Reset to default: forgets GameCove's pick and restores Steam's own files.
func reset(game: Dictionary, kind: String) -> bool:
	var key := str(game.get("key", ""))
	Overrides.remove(_abs(picked_dir), key, kind)
	var ok := true
	if str(game.get("store", "")) == "steam":
		var appid := str(game.get("id", ""))
		var entries := [SteamGrid.base_name(appid, kind)]
		if kind == "logo":
			entries.append(appid + ".json")
		for root in steam_roots:
			for grid in SteamGrid.grid_dirs(str(root)):
				for e in entries:
					ok = SteamGrid.reset(grid, SteamGrid.backup_dir_for(_abs(backup_root), grid), e) and ok
	art_changed.emit(key)
	return ok


## The pick GameCove has for this game and kind ({} if none): for credits.
func override_for(game: Dictionary, kind: String) -> Dictionary:
	var o = Overrides.read(_abs(picked_dir)).get(str(game.get("key", "")), {}).get(kind, {})
	if not o is Dictionary or o.is_empty():
		return {}
	o["id"] = int(o.get("id", 0))
	return o


# ------------------------------------------------------------ automatic fill

## A game made from a ROM file (the Emulation page's, EmuDeck / RetroDECK / ES-DE folders).
static func is_rom(game: Dictionary) -> bool:
	var e: Variant = game.get("emulated", {})
	# a ROM from the ROM folder ("rom"), or a game Steam ROM Manager made a Steam shortcut of (emu.gd shortcuts():
	# an "emulated" game with no "rom" key): the title of either stays on the device
	return e is Dictionary and (bool(e.get("rom", false)) or bool(game.get("shortcut", false)))


static func missing_kinds(game: Dictionary) -> Array:
	var art = game.get("art", {})
	var out := []
	for k in AUTO_KINDS:
		var p := str(art.get(k, "")) if art is Dictionary else ""
		if p == "" or not FileAccess.file_exists(p):
			out.append(k)
	return out


## Queues the top-rated SteamGridDB image for every game missing a cover, hero
## or logo. Needs both privacy switches and a key; each game and kind is tried
## at most once a week.
func auto_fill(games: Array) -> int:
	if not Privacy.background_allowed(prefs_path) or unavailable_reason() != "":
		return 0
	var now := int(clock.call())
	_load_auto_tried(now)
	var n := 0
	for g in games:
		# a ROM's title never leaves the device (docs/PRIVACY.md, the Emulation page): a search
		# can't tell a console game from a PC one by its title anyway. Every caller goes through
		# here, so the setup step's fill after a key is saved is covered too.
		if is_rom(g):
			continue
		for k in missing_kinds(g):
			var id := "%s|%s" % [g.get("key", ""), k]
			if _auto_tried.has(id) and now - int(_auto_tried[id]) < RETRY_AUTO_S:
				continue
			_auto_tried[id] = now
			_auto.append([g, k])
			n += 1
	if n > 0:
		SettingsFile.save_json(_abs(auto_tried_path), _auto_tried)
	if sync_mode:
		while not _auto.is_empty() and not paused:
			_auto_next()
	elif _timer != null and _timer.is_stopped() and n > 0 and not paused:
		_timer.start(0.5)
	return n


## Reads the tried list once; entries past RETRY_AUTO_S are dropped (pruned).
func _load_auto_tried(now: int) -> void:
	if _auto_loaded:
		return
	_auto_loaded = true
	var d: Variant = SettingsFile.load_json(_abs(auto_tried_path))["data"]
	if d is Dictionary:
		for id in d:
			var t := int(d[id]) if (d[id] is int or d[id] is float) else 0
			if now - t < RETRY_AUTO_S and not _auto_tried.has(id):
				_auto_tried[id] = t


## True while a game runs (Library.set_background_paused): the automatic fill waits;
## searches and picks the user makes still run.
var paused := false


func set_paused(on: bool) -> void:
	paused = on
	if on and _timer != null and _timer.is_inside_tree():
		_timer.stop()
	elif not on and not _auto.is_empty():
		if sync_mode:
			while not _auto.is_empty() and not paused:
				_auto_next()
		elif _timer != null and _timer.is_inside_tree() and _timer.is_stopped():
			_timer.start(0.5)


func _auto_next() -> void:
	if _auto.is_empty() or paused:
		return
	if not Privacy.background_allowed(prefs_path) or unavailable_reason() != "":
		_auto.clear()   # a switch went off (or the key went away) after these were queued (review 2, low 23)
		return
	var job: Array = _auto.pop_front()
	var g: Dictionary = job[0]
	var kind: String = job[1]
	search(g, kind, {}, 0, func(assets: Array, _err: String):
		var best := Sgdb.best(assets)
		if not best.is_empty():
			apply(g, kind, best, false, Callable(), "auto")
		if not sync_mode and _timer != null and is_inside_tree() and not _auto.is_empty():
			_timer.start(AUTO_GAP))
