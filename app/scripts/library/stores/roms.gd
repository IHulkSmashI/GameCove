extends RefCounted
## Every ROM in the ROM folder EmuDeck, RetroDECK or ES-DE set up, as a game:
## its file (or folder), a clean title, ES-DE's details from gamelist.xml and
## ES-DE's downloaded art. Read-only: nothing here writes their files, and
## only the detected ROM folder is read (never the whole disk).
##
## One game per entry ES-DE would list, with these rules on top:
## - a system's files must have one of the extensions ES-DE lists for it
##   (custom_systems/es_systems.xml first); unknown systems: anything that isn't
##   notes, media or saves (NOT_ROM_EXT);
## - a .cue / .gdi stands for its track files; a .m3u stands for every disc it
##   lists (the discs don't show on their own);
## - a folder named like a game file ("Game.ps3", "Game.wua") is one game
##   (ES-DE's "directories interpreted as files"); a Wii U game folder
##   (Game/code/*.rpx) is one game named after its folder;
## - media, saves, updates and DLC folders and folders holding noload.txt are
##   skipped; SCAN_DEPTH levels of sub-folders at most, SYSTEM_MAX games per
##   system and TOTAL_MAX in all.
##
## Results are cached (CACHE_PATH, Godot's binary format) per system with the
## modification time of every folder read, the gamelist and the media folders:
## a later start only looks at those times and reads a system again when one
## changed. Runs on the Library's scan thread.

const SettingsFile := preload("res://scripts/system/settings_file.gd")

## Files in a ROM folder that are never games (EmuDeck puts a systeminfo.txt /
## metadata.txt in each; scrapers leave media).
const NOT_ROM_EXT := ["txt", "xml", "md", "png", "jpg", "jpeg", "webp", "gif", "mp4", "mkv", "pdf", "srm", "sav",
	"state", "cfg", "ini", "json", "log", "nfo", "db", "sh", "bat", "lnk", "url", "html"]
const NOT_ROM_DIRS := ["media", "images", "videos", "manuals", "downloaded_media", "snaps", "saves", "states",
	"screenshots", "covers", "marquees", "titles", "boxart", "wheel", "fanart", "updates", "update", "dlc"]
const NOT_ROM_FILES := ["systeminfo.txt", "metadata.txt", "gamelist.xml", "noload.txt"]
## Track files a .cue / .gdi already stands for.
const TRACK_EXT := ["bin", "img", "raw", "sub", "track", "wav"]
const SCAN_DEPTH := 3
const SYSTEM_MAX := 20000
const TOTAL_MAX := 60000
const GAMELIST_MAX_BYTES := 8 * 1024 * 1024
const CACHE_PATH := "user://emu/roms.cache"
## 2: each system's games are kept packed (var_to_bytes) so checking that nothing
## changed reads only folder times, not thousands of games.
const CACHE_VERSION := 2
## ES-DE's media folders (downloaded_media/<system>/<type>/<rom path without extension>.<ext>)
## for each kind of art, best first.
const ART_FROM := {"cover": ["covers", "3dboxes", "miniatures"], "hero": ["fanart", "screenshots", "titlescreens"],
	"logo": ["marquees"]}
const MEDIA_EXT := ["png", "jpg", "jpeg", "webp"]
const MEDIA_DEPTH := 4
## gamelist.xml art tags (older scrapers such as Skraper write them) for each kind.
const GAMELIST_ART := {"cover": ["image", "thumbnail"], "hero": ["fanart", "screenshot"], "logo": ["marquee"]}

## Tests point this at their own folder.
static var cache_path := CACHE_PATH


# ------------------------------------------------------------ titles

## A clean title from a ROM's file name: region, language, revision, disc and
## dump tags dropped ("(USA)", "[!]", "(Rev 1)", "(Disc 1)"), No-Intro's
## "Name, The" turned round, underscores read as spaces when there are no spaces.
static func clean_title(stem: String) -> String:
	var s := stem
	if not " " in s and "_" in s:
		s = s.replace("_", " ")
	s = RegEx.create_from_string("\\s*(\\([^)]*\\)|\\[[^\\]]*\\])").sub(s, "", true)
	s = RegEx.create_from_string("\\s+").sub(s, " ", true).strip_edges()
	var art := RegEx.create_from_string("^(.+?), (The|A|An)( - .*)?$").search(s)
	if art != null:
		s = "%s %s%s" % [art.get_string(2), art.get_string(1), art.get_string(3)]
	s = s.strip_edges().trim_suffix(" -").strip_edges()
	# No-Intro and Redump write a title's colon as " - ": the first one is the colon back
	# ("Castlevania - Symphony of the Night" -> "Castlevania: Symphony of the Night").
	var dash := s.find(" - ")
	if dash > 0:
		s = s.substr(0, dash) + ": " + s.substr(dash + 3)
	return s if s != "" else stem.strip_edges()


## The disc a file name says it is ("(Disc 2)", "(Disk 2 of 3)", "(CD2)"), 0 if none.
static func disc_number(stem: String) -> int:
	var m := RegEx.create_from_string("(?i)\\((?:disc|disk|cd)\\s*(\\d+)").search(stem)
	return m.get_string(1).to_int() if m != null else 0


## ES-DE's date-time ("19910821T000000") as "1991-08-21"; "" if not one.
static func es_date(s: String) -> String:
	if s.length() < 8 or not s.substr(0, 8).is_valid_int():
		return ""
	var y := s.substr(0, 4).to_int()
	var mo := s.substr(4, 2).to_int()
	var d := s.substr(6, 2).to_int()
	if y < 1950 or mo < 1 or mo > 12 or d < 1 or d > 31:
		return ""
	return "%04d-%02d-%02d" % [y, mo, d]


## ES-DE's date-time ("20240131T201500", local time) as unix seconds; 0 if not one.
static func es_time(s: String) -> int:
	if s.length() < 15 or s[8] != "T" or not s.substr(0, 8).is_valid_int() or not s.substr(9, 6).is_valid_int():
		return 0
	var iso := "%s-%s-%sT%s:%s:%s" % [s.substr(0, 4), s.substr(4, 2), s.substr(6, 2), s.substr(9, 2), s.substr(11, 2), s.substr(13, 2)]
	return int(Time.get_unix_time_from_datetime_string(iso))


# ------------------------------------------------------------ listing

## The games in one system folder: {"games": [{"rel", "path", "dir": bool}], "dirs": {folder: mtime}}.
## `exts`: the extensions ES-DE lists for the system ("sfc", lower case, no
## dot); [] = unknown system (NOT_ROM_EXT rules). `rel` is relative to `root`;
## `path` is what starts the game (a folder game's same-named file inside it
## when there is one, as ES-DE does).
static func list_games(root: String, exts: Array, max_games := SYSTEM_MAX) -> Dictionary:
	var out := {"games": [], "dirs": {}}
	var allowed := {}
	for e in exts:
		allowed[str(e).to_lower().trim_prefix(".")] = true
	var listed := {}
	_list(root, "", 0, allowed, listed, out, max_games)
	return out


static func _list(root: String, rel_dir: String, depth: int, allowed: Dictionary, listed: Dictionary, out: Dictionary, max_games: int) -> void:
	var dir := root.path_join(rel_dir) if rel_dir != "" else root
	var d := DirAccess.open(dir)
	if d == null:
		return
	out["dirs"][dir] = FileAccess.get_modified_time(dir)
	var files := d.get_files()
	if files.has("noload.txt"):
		return
	var has_sheet := false
	var has_rpx := false
	for f in files:
		var ext := f.get_extension().to_lower()
		if ext in ["cue", "gdi"]:
			has_sheet = true
		elif ext == "rpx":
			has_rpx = true
		elif ext == "m3u":
			var fa := FileAccess.open(dir.path_join(f), FileAccess.READ)
			if fa == null or fa.get_length() > 65536:
				continue
			for line in fa.get_as_text().split("\n"):
				var l := line.strip_edges().replace("\\", "/")
				if l != "" and not l.begins_with("#"):
					listed[(l if l.begins_with("/") else dir.path_join(l)).simplify_path()] = true
			fa.close()
	# A Wii U game's code folder: its .rpx is the game (title.tmd beside it isn't another one).
	var wiiu_code := has_rpx and dir.get_file().to_lower() == "code"
	var games: Array = out["games"]
	for f in files:
		if games.size() >= max_games:
			return
		var ext := f.get_extension().to_lower()
		if f.begins_with(".") or f.to_lower() in NOT_ROM_FILES:
			continue
		if allowed.is_empty():
			if ext in NOT_ROM_EXT:
				continue
		elif not allowed.has(ext):
			continue
		if has_sheet and ext in TRACK_EXT:
			continue
		if wiiu_code and ext != "rpx":
			continue
		var abs := dir.path_join(f)
		if listed.has(abs.simplify_path()):
			continue
		games.append({"rel": rel_dir.path_join(f) if rel_dir != "" else f, "path": abs, "dir": false})
	for sub in d.get_directories():
		if games.size() >= max_games:
			return
		if sub.begins_with(".") or sub.to_lower() in NOT_ROM_DIRS:
			continue
		var sext := sub.get_extension().to_lower()
		var rel := rel_dir.path_join(sub) if rel_dir != "" else sub
		var as_file := allowed.has(sext) if not allowed.is_empty() else (sext != "" and not sext.is_valid_int())
		if as_file:
			var p := root.path_join(rel)
			var inner := p.path_join(sub)
			games.append({"rel": rel, "path": inner if FileAccess.file_exists(inner) else p, "dir": true})
		elif depth < SCAN_DEPTH:
			_list(root, rel, depth + 1, allowed, listed, out, max_games)


# ------------------------------------------------------------ gamelist.xml

## What ES-DE's gamelist.xml says: {"alt": the system's alternative emulator
## label ("" = the default), "games": {relative path: {field: text}}}. Paths
## are relative to the system's ROM folder `root` ("./x.sfc" -> "x.sfc").
static func parse_gamelist(path: String, root: String) -> Dictionary:
	var out := {"alt": "", "games": {}}
	var fa := FileAccess.open(path, FileAccess.READ) if path != "" else null
	if fa == null or fa.get_length() > GAMELIST_MAX_BYTES:
		return out
	fa.close()
	var x := XMLParser.new()
	if x.open(path) != OK:
		return out
	var cur := ""
	var g := {}
	var in_alt := false
	while x.read() == OK:
		match x.get_node_type():
			XMLParser.NODE_ELEMENT:
				cur = x.get_node_name()
				if cur == "game":
					g = {}
				elif cur == "alternativeEmulator":
					in_alt = true
			XMLParser.NODE_TEXT:
				var t := x.get_node_data().strip_edges()
				if t == "" or cur == "":
					continue
				if in_alt and cur == "label":
					out["alt"] = t.xml_unescape()
				elif not g.is_empty() or cur == "path":
					g[cur] = t.xml_unescape()
			XMLParser.NODE_ELEMENT_END:
				var n := x.get_node_name()
				if n == "game":
					var rel := rel_path(str(g.get("path", "")), root)
					if rel != "":
						out["games"][rel] = g
					g = {}
				elif n == "alternativeEmulator":
					in_alt = false
				cur = ""
	return out


## A gamelist <path> as a path relative to the system's folder; "" when it isn't in it.
static func rel_path(p: String, root: String) -> String:
	var s := p.strip_edges().replace("\\", "/")
	if s.begins_with("./"):
		return s.substr(2).simplify_path()
	if s.begins_with("/"):
		var r := root.simplify_path() + "/"
		return s.simplify_path().substr(r.length()) if s.simplify_path().begins_with(r) else ""
	return s.simplify_path() if s != "" else ""


static func _truthy(v: Variant) -> bool:
	return str(v).strip_edges().to_lower() in ["true", "1", "yes"]


# ------------------------------------------------------------ media

## ES-DE's downloaded art for one system: {type: {rom path without extension: file}}
## and the folders read, with their modification times.
static func media_index(media_root: String, system: String) -> Dictionary:
	var out := {"types": {}, "dirs": {}}
	if media_root == "":
		return out
	var base := media_root.path_join(system)
	var seen := {}
	for kind in ART_FROM:
		for t in ART_FROM[kind]:
			if seen.has(t):
				continue
			seen[t] = true
			var idx := {}
			_media(base.path_join(t), "", 0, idx, out["dirs"])
			out["types"][t] = idx
	return out


static func _media(dir: String, rel: String, depth: int, idx: Dictionary, dirs: Dictionary) -> void:
	var d := DirAccess.open(dir.path_join(rel) if rel != "" else dir)
	if d == null:
		return
	var here := dir.path_join(rel) if rel != "" else dir
	dirs[here] = FileAccess.get_modified_time(here)
	for f in d.get_files():
		if f.get_extension().to_lower() in MEDIA_EXT:
			var stem := (rel.path_join(f) if rel != "" else f).get_basename()
			if not idx.has(stem):
				idx[stem] = here.path_join(f)
	if depth < MEDIA_DEPTH:
		for sub in d.get_directories():
			if not sub.begins_with("."):
				_media(dir, rel.path_join(sub) if rel != "" else sub, depth + 1, idx, dirs)


## Art for one game: ES-DE's downloaded media first, then the gamelist's own art tags.
static func art_for(rel: String, media: Dictionary, gl: Dictionary, root: String) -> Dictionary:
	var art := {"cover": "", "hero": "", "logo": "", "icon": ""}
	var stem := rel.get_basename()
	for kind in ART_FROM:
		for t in ART_FROM[kind]:
			var p := str(media.get("types", {}).get(t, {}).get(stem, ""))
			if p != "":
				art[kind] = p
				break
		if art[kind] == "":
			for tag in GAMELIST_ART[kind]:
				var v := str(gl.get(tag, ""))
				if v == "":
					continue
				var p := root.path_join(v.substr(2)) if v.begins_with("./") else (v if v.begins_with("/") else "")
				if p != "" and FileAccess.file_exists(p):
					art[kind] = p
					break
	return art


# ------------------------------------------------------------ one system

## Every game of one system as plain data (what the cache keeps):
## [{"id": "rom:<system>/<rel>", "system", "rel", "path", "title", "meta": {...},
##   "players", "rating" (0..1, -1 unknown), "playcount", "last_played",
##   "favorite", "hidden", "altemulator", "art"}], plus "alt" (the system's
## alternative emulator), "dirs" (folders read) and "files" (gamelist).
static func scan_system(system: String, root: String, exts: Array, gamelist: String, media_root: String, max_games := SYSTEM_MAX) -> Dictionary:
	var listing := list_games(root, exts, max_games)
	var gl := parse_gamelist(gamelist, root)
	var media := media_index(media_root, system)
	var games: Array = []
	var titles := {}
	for item in listing["games"]:
		var rel: String = item["rel"]
		var e: Dictionary = gl["games"].get(rel, {})
		var stem := rel.get_file().get_basename()
		if rel.get_base_dir().get_file().to_lower() == "code" and rel.get_extension().to_lower() == "rpx":
			stem = rel.get_base_dir().get_base_dir().get_file()
			if stem == "":
				stem = rel.get_file().get_basename()
		var title := str(e.get("name", "")).strip_edges()
		var from_name := title == ""
		if from_name:
			title = clean_title(stem)
		var meta := {}
		if str(e.get("desc", "")) != "":
			meta["summary"] = str(e["desc"])
		for pair in [["developer", "developers"], ["publisher", "publishers"]]:
			if str(e.get(pair[0], "")).strip_edges() != "":
				meta[pair[1]] = [str(e[pair[0]]).strip_edges()]
		if str(e.get("genre", "")) != "":
			var gs: Array = []
			for part in RegEx.create_from_string("\\s*[/,;]\\s*").sub(str(e["genre"]), "|", true).split("|", false):
				if part.strip_edges() != "" and not part.strip_edges() in gs:
					gs.append(part.strip_edges())
			meta["genres"] = gs
		var rd := es_date(str(e.get("releasedate", "")))
		if rd != "":
			meta["release_date"] = rd
		var rating := -1.0
		if str(e.get("rating", "")).is_valid_float():
			rating = clampf(str(e["rating"]).to_float(), 0.0, 1.0)
		var g := {"id": "rom:%s/%s" % [system, rel], "system": system, "rel": rel, "path": item["path"], "title": title,
			"meta": meta, "players": str(e.get("players", "")).strip_edges(), "rating": rating,
			"playcount": maxi(0, str(e.get("playcount", "0")).to_int()), "last_played": es_time(str(e.get("lastplayed", ""))),
			"favorite": _truthy(e.get("favorite", "")), "hidden": _truthy(e.get("hidden", "")),
			"altemulator": str(e.get("altemulator", "")).strip_edges(), "art": art_for(rel, media, e, root),
			"disc": disc_number(stem) if from_name else 0}
		games.append(g)
		titles[title] = int(titles.get(title, 0)) + 1
	# Discs a .m3u doesn't hold: "Game (Disc 2)" rather than two games both called "Game".
	for g in games:
		if int(titles[g["title"]]) > 1 and int(g["disc"]) > 0:
			g["title"] = "%s (Disc %d)" % [g["title"], int(g["disc"])]
		g.erase("disc")
	var files := {}
	if gamelist != "":
		files[gamelist] = FileAccess.get_modified_time(gamelist)
	var dirs: Dictionary = listing["dirs"]
	dirs.merge(media["dirs"])
	# The media folder itself (a type folder created later shows up as a change).
	if media_root != "":
		var mb := media_root.path_join(system)
		dirs[mb] = FileAccess.get_modified_time(mb)
	return {"games": games, "alt": gl["alt"], "dirs": dirs, "files": files}


# ------------------------------------------------------------ all systems, cached

## Every system folder's games: `systems` is [{"id", "root", "exts", "gamelist"}]
## (rom_systems' list; each gets its cache key in "key"). Returns {key:
## scan_system()'s result}. Uses and refreshes the cache; a cached system whose
## folder is gone (a drive not plugged in) stays in the file, so it's quick when
## the drive is back.
static func scan_all(systems: Array, media_root: String, now := -1) -> Dictionary:
	var t := int(Time.get_unix_time_from_system()) if now < 0 else now
	var cache := load_cache()
	var old: Dictionary = cache.get("systems", {})
	var fresh := {}
	var keep := {}
	var changed := false
	var total := 0
	for s in systems:
		var key := _key(s, media_root)
		s["key"] = key
		var hit: Variant = old.get(key)
		var res: Dictionary
		if hit is Dictionary and still_valid(hit):
			res = hit.duplicate()
			res["games"] = bytes_to_var(hit["games"])
			if not res["games"] is Array:
				res["games"] = []
			keep[key] = hit
		else:
			var gl := str(s.get("gamelist", ""))
			res = scan_system(str(s["id"]), str(s["root"]), s.get("exts", []), gl, media_root, mini(SYSTEM_MAX, TOTAL_MAX - total))
			res["at"] = t
			changed = true
			var packed := res.duplicate()
			packed["games"] = var_to_bytes(res["games"])
			packed["count"] = (res["games"] as Array).size()
			keep[key] = packed
		total += (res["games"] as Array).size()
		fresh[key] = res
		if total >= TOTAL_MAX:
			break
	for key in old:
		if not keep.has(key) and not DirAccess.dir_exists_absolute(str(key).get_slice("|", 1)):
			keep[key] = old[key]
	if changed or keep.size() != old.size():
		save_cache({"version": CACHE_VERSION, "systems": keep})
	return fresh


static func _key(s: Dictionary, media_root: String) -> String:
	return "%s|%s|%s|%s" % [s["id"], s["root"], str(s.get("gamelist", "")), media_root]


## What scan_all would return, as one hash, when every system's folders are as
## the cache has them ("" when something changed or isn't cached yet, so it must
## be read). Reads only the cache's folder times: no game is unpacked.
static func unchanged_stamp(systems: Array, media_root: String) -> String:
	var old: Dictionary = load_cache().get("systems", {})
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	var total := 0
	for s in systems:
		var key := _key(s, media_root)
		var hit: Variant = old.get(key)
		if not (hit is Dictionary and still_valid(hit)):
			return ""
		ctx.update(("%s@%d\n" % [key, int(hit["at"])]).to_utf8_buffer())
		total += int(hit.get("count", 0))
		if total >= TOTAL_MAX:
			break
	return ctx.finish().hex_encode()


## True while every folder and file a cached system was read from still has
## the time it had. One changed in the second the scan ran (or later) never
## counts as unchanged: times are whole seconds, so it may have changed after
## it was read.
static func still_valid(entry: Dictionary) -> bool:
	if not (entry.get("dirs") is Dictionary and entry.get("files") is Dictionary and entry.get("games") is PackedByteArray):
		return false
	var at := int(entry.get("at", 0))
	for group in [entry["dirs"], entry["files"]]:
		for p in group:
			var m := int(group[p])
			if FileAccess.get_modified_time(p) != m or m >= at:
				return false
	return true


## The cache file: CACHE_MAGIC, the payload's MD5 (32 hex characters), then the
## payload (var_to_bytes). A file that doesn't check out is ignored (read again).
const CACHE_MAGIC := "GCROMS1\n"


static func load_cache() -> Dictionary:
	var p := ProjectSettings.globalize_path(cache_path)
	if not FileAccess.file_exists(p):
		return {}
	var b := FileAccess.get_file_as_bytes(p)
	var head := CACHE_MAGIC.length() + 32
	if b.size() <= head or b.slice(0, CACHE_MAGIC.length()).get_string_from_ascii() != CACHE_MAGIC:
		return {}
	var payload := b.slice(head)
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	ctx.update(payload)
	if ctx.finish().hex_encode() != b.slice(CACHE_MAGIC.length(), head).get_string_from_ascii():
		return {}
	var v: Variant = bytes_to_var(payload)
	if not v is Dictionary or int(v.get("version", 0)) != CACHE_VERSION or not v.get("systems") is Dictionary:
		return {}
	return v


static func save_cache(data: Dictionary) -> void:
	var p := ProjectSettings.globalize_path(cache_path)
	DirAccess.make_dir_recursive_absolute(p.get_base_dir())
	var payload := var_to_bytes(data)
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	ctx.update(payload)
	var out := CACHE_MAGIC.to_ascii_buffer()
	out.append_array(ctx.finish().hex_encode().to_ascii_buffer())
	out.append_array(payload)
	SettingsFile.save_bytes(p, out)
