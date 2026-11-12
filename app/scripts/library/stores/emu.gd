extends RefCounted
## Emulation, the way EmuDeck and RetroDECK already set it up: GameCove reads
## their files and starts their tools; it never scans for ROMs to run itself,
## never writes their files, and never bundles or downloads ROMs or BIOS.
##
## Three kinds of Library entries (store "emu"):
## - id "frontend": ES-DE (EmuDeck or standalone) or RetroDECK, started like
##   any non-Steam game (its own gamescope scope, play time counted by us).
## - id "rom:<system>/<path in the system folder>": every game in the ROM
##   folder (roms.gd reads them, ES-DE's details and art included), started
##   the way the setup starts it (esde_launch.gd: EmuDeck's launcher scripts,
##   RetroDECK's CLI, or ES-DE's own command) in its own scope, play time
##   counted by us. "Show emulated games in the Library" turns them off.
## - id <shortcut app id>: an emulated game Steam ROM Manager (EmuDeck's or
##   RetroDECK's) added to Steam as a non-Steam shortcut. Read from
##   userdata/<user>/config/shortcuts.vdf (binary KeyValues); recognised by a
##   launch line that opens a ROM under .../roms/<system>/ through EmuDeck's
##   launchers (Emulation/tools/launchers/*.sh), RetroDECK, RetroArch or a
##   known emulator. Started through Steam (steam://rungameid/<64-bit id>),
##   exactly as Steam starts it; art from Steam's grid folder, where SRM
##   saves SteamGridDB art.
##
## detect() also gives the Emulation page what it shows: which setup is here,
## the ROM folder's systems with file counts (a read-only count, nothing is
## opened), recently played games from ES-DE's gamelist.xml files, and the
## commands for ES-DE / RetroDECK, EmuDeck's app (or RetroDECK's configurator)
## and Steam ROM Manager.

const Common := preload("res://scripts/library/stores/common.gd")
const SteamStore := preload("res://scripts/library/stores/steam.gd")
const SteamConfig := preload("res://scripts/steam/steam_config.gd")
const BinaryKV := preload("res://scripts/achievements/binary_kv.gd")
const Roms := preload("res://scripts/library/stores/roms.gd")
const EsdeLaunch := preload("res://scripts/library/stores/esde_launch.gd")
const SettingsFile := preload("res://scripts/system/settings_file.gd")

const SYSTEMS_FILE := "res://data/emu_systems.json"
const RETRODECK_ID := "net.retrodeck.retrodeck"
const ESDE_FLATPAK := "org.es_de.frontend"
const SRM_FLATPAK := "com.steamgriddb.steam-rom-manager"
const FLATPAK_DIRS := ["/var/lib/flatpak/app/", "~/.local/share/flatpak/app/"]
## Where EmuDeck puts its AppImages (relative to home, then to the Emulation folder).
const ESDE_APPIMAGES := ["~/Applications/ES-DE*.AppImage", "~/Applications/EmulationStation-DE*.AppImage",
	"%EMU%/tools/ES-DE*.AppImage", "%EMU%/tools/EmulationStation-DE*.AppImage"]
const EMUDECK_APPIMAGES := ["~/Applications/EmuDeck*.AppImage"]
const SRM_APPIMAGES := ["~/Applications/srm/Steam-ROM-Manager*.AppImage", "%EMU%/tools/srm/Steam-ROM-Manager*.AppImage",
	"%EMU%/tools/Steam-ROM-Manager*.AppImage", "~/Applications/Steam-ROM-Manager*.AppImage"]
## ES-DE's configuration folders: 3.x, 2.x, RetroDECK's.
const ESDE_DIRS := ["~/ES-DE", "~/.emulationstation", "~/.var/app/net.retrodeck.retrodeck/config/ES-DE"]
## Files and folders in a ROM folder that are never games (roms.gd has the rules).
const NOT_ROM_EXT := Roms.NOT_ROM_EXT
const NOT_ROM_DIRS := Roms.NOT_ROM_DIRS
const TRACK_EXT := Roms.TRACK_EXT
const COUNT_DEPTH := 3
const COUNT_MAX := 20000
const RECENT_MAX := 8
const GAMELIST_MAX_BYTES := 8 * 1024 * 1024
## Launch-line words → the emulator's name (what the game page says it runs in).
const EMULATORS := [["retroarch", "RetroArch"], ["dolphin", "Dolphin"], ["primehack", "PrimeHack"], ["pcsx2", "PCSX2"],
	["duckstation", "DuckStation"], ["ppsspp", "PPSSPP"], ["rpcs3", "RPCS3"], ["cemu", "Cemu"], ["ryujinx", "Ryujinx"],
	["citron", "Citron"], ["eden", "Eden"], ["yuzu", "yuzu"], ["azahar", "Azahar"], ["lime3ds", "Lime3DS"], ["citra", "Citra"],
	["melonds", "melonDS"], ["xemu", "xemu"], ["xenia", "Xenia"], ["flycast", "Flycast"], ["mame", "MAME"],
	["scummvm", "ScummVM"], ["mgba", "mGBA"], ["vita3k", "Vita3K"], ["shadps4", "shadPS4"], ["ares", "ares"],
	["bigpemu", "BigPEmu"], ["supermodel", "Supermodel"], ["model2", "Model 2"], ["snes9x", "Snes9x"], ["mednafen", "Mednafen"]]
## Steam's 64-bit game id for a shortcut: app id << 32 | 0x02000000.
const SHORTCUT_LOW := 33554432

static var _systems: Dictionary = {}
## Where Library.collect() looks for Flatpak apps and programs; tests point
## them at their own folders so nothing on the test machine leaks in.
static var flatpak_dirs: Array = FLATPAK_DIRS
static var path_env := OS.get_environment("PATH")


# ------------------------------------------------------------ systems

## {id: {"name", "short"}}: ES-DE's names, read from the installed ES-DE's
## custom_systems/es_systems.xml first (the user's own), then RetroDECK's
## bundled copy, then our copy of ES-DE's list.
static func systems(home := "", flatpak_dirs: Array = FLATPAK_DIRS) -> Dictionary:
	if _systems.is_empty():
		var doc: Variant = Common.read_json(ProjectSettings.globalize_path(SYSTEMS_FILE), {})
		_systems = doc.get("systems", {}) if doc is Dictionary else {}
	var out := _systems.duplicate()
	if home == "":
		return out
	var files: Array = []
	for d in ESDE_DIRS:
		files.append(_expand(d, home, "").path_join("custom_systems/es_systems.xml"))
	for f in flatpak_dirs:
		files.append(_expand(str(f), home, "") + RETRODECK_ID + "/current/active/files/share/es-de/resources/systems/linux/es_systems.xml")
	for f in files:
		var found := _names_from_xml(f)
		for id in found:
			out[id] = {"name": found[id], "short": out.get(id, {}).get("short", found[id])}
	return out


## <system><name>…</name><fullname>…</fullname> pairs from an es_systems.xml.
static func _names_from_xml(path: String) -> Dictionary:
	var out := {}
	if not FileAccess.file_exists(path):
		return out
	var x := XMLParser.new()
	if x.open(path) != OK:
		return out
	var cur := ""
	var id := ""
	while x.read() == OK:
		match x.get_node_type():
			XMLParser.NODE_ELEMENT:
				cur = x.get_node_name()
				if cur == "system":
					id = ""
			XMLParser.NODE_TEXT:
				var t := x.get_node_data().strip_edges()
				if t == "":
					continue
				if cur == "name":
					id = t
				elif cur == "fullname" and id != "":
					out[id] = t.xml_unescape()
			XMLParser.NODE_ELEMENT_END:
				cur = ""
	return out


static func system_name(id: String, table: Dictionary = {}) -> String:
	var t := table if not table.is_empty() else systems()
	return str(t.get(id, {}).get("name", id.to_upper()))


static func system_short(id: String, table: Dictionary = {}) -> String:
	var t := table if not table.is_empty() else systems()
	return str(t.get(id, {}).get("short", id.to_upper()))


# ------------------------------------------------------------ paths

static func _expand(p: String, home: String, emu: String) -> String:
	var s := p.replace("%EMU%", emu)
	return home + s.substr(1) if s.begins_with("~") else s


## The first file matching `pattern` (a * in the file name only), newest name last-sorted first.
static func _glob(pattern: String) -> String:
	var dir := pattern.get_base_dir()
	var name := pattern.get_file()
	if not "*" in name:
		return pattern if FileAccess.file_exists(pattern) else ""
	var d := DirAccess.open(dir)
	if d == null:
		return ""
	var hits: Array = []
	for f in d.get_files():
		if f.match(name):
			hits.append(dir.path_join(f))
	hits.sort()
	return hits[hits.size() - 1] if not hits.is_empty() else ""


static func _first(patterns: Array, home: String, emu: String) -> String:
	for p in patterns:
		if emu == "" and "%EMU%" in str(p):
			continue
		var hit := _glob(_expand(str(p), home, emu))
		if hit != "":
			return hit
	return ""


static func _flatpak(app_id: String, home: String, flatpak_dirs: Array) -> bool:
	for d in flatpak_dirs:
		if DirAccess.dir_exists_absolute(_expand(str(d), home, "") + app_id):
			return true
	return false


## `key=value` from a shell settings file (EmuDeck's settings.sh, RetroDECK's
## retrodeck.cfg), quotes dropped; "" when missing.
static func _kv(path: String, key: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	for line in FileAccess.get_file_as_string(path).split("\n"):
		var l := line.strip_edges()
		if l.begins_with(key + "="):
			return l.substr(key.length() + 1).strip_edges().trim_prefix("\"").trim_suffix("\"").trim_prefix("'").trim_suffix("'")
	return ""


## A <string name="key" value="…" /> setting from ES-DE's es_settings.xml.
static func _esde_setting(esde_dir: String, key: String) -> String:
	for f in [esde_dir.path_join("settings/es_settings.xml"), esde_dir.path_join("es_settings.xml")]:
		if not FileAccess.file_exists(f):
			continue
		var x := XMLParser.new()
		if x.open(f) != OK:
			continue
		while x.read() == OK:
			if x.get_node_type() == XMLParser.NODE_ELEMENT and x.has_attribute("name") and x.get_named_attribute_value_safe("name") == key:
				return x.get_named_attribute_value_safe("value")
	return ""


# ------------------------------------------------------------ detection

static func empty_setup() -> Dictionary:
	return {"kind": "", "name": "", "frontend": {}, "app": {}, "srm": {}, "roms_dir": "", "systems": [], "recent": [],
		"esde_dir": "", "rom_total": 0, "emu_path": "", "media_dir": "", "gamelist_dirs": [], "es_path": "", "roms_shown": false, "roots": []}


## What's installed: {"kind": "emudeck" | "retrodeck" | "esde" | "",
##  "name", "frontend": {"name", "command"} or {}, "app": {"name", "command"} or {},
##  "srm": {"command"} or {}, "roms_dir", "systems": [{"id", "name", "short", "count"}]
##  (most ROMs first), "rom_total", "recent": [{"title", "system", "last_played"}], "esde_dir",
##  "emu_path" (EmuDeck's Emulation folder), "media_dir" (ES-DE's downloaded_media),
##  "gamelist_dirs", "es_path" (ES-DE's program folder), "roms_shown" (scan() made
##  ROM games)}. `count`: count each system's files here (off when scan() lists the
##  games anyway and fills "systems" from them).
static func detect(home: String, path_env := "", flatpak_dirs: Array = FLATPAK_DIRS, count := true) -> Dictionary:
	var out := empty_setup()
	var emu_settings := home.path_join(".config/EmuDeck/settings.sh")
	var emu_path := _kv(emu_settings, "emulationPath")
	if emu_path == "" and DirAccess.dir_exists_absolute(home.path_join("Emulation/roms")):
		emu_path = home.path_join("Emulation")
	var emudeck_app := _first(EMUDECK_APPIMAGES, home, emu_path)
	var retrodeck := _flatpak(RETRODECK_ID, home, flatpak_dirs)
	var esde_bin := _first(ESDE_APPIMAGES, home, emu_path)
	var esde_cmd: Array = []
	if esde_bin != "":
		esde_cmd = [esde_bin]
	elif _flatpak(ESDE_FLATPAK, home, flatpak_dirs):
		esde_cmd = ["flatpak", "run", ESDE_FLATPAK]
	elif Common.which("es-de", path_env) != "":
		esde_cmd = [Common.which("es-de", path_env)]
	var esde_dir := ""
	if FileAccess.file_exists(emu_settings) or emudeck_app != "" or (emu_path != "" and not esde_cmd.is_empty()):
		out["kind"] = "emudeck"
		out["name"] = "EmuDeck"
		out["roms_dir"] = emu_path.path_join("roms") if emu_path != "" else ""
		if not esde_cmd.is_empty():
			out["frontend"] = {"name": "ES-DE", "command": esde_cmd}
		if emudeck_app != "":
			out["app"] = {"name": "EmuDeck", "command": [emudeck_app]}
		esde_dir = _first_dir([ESDE_DIRS[0], ESDE_DIRS[1]], home)
	elif retrodeck:
		out["kind"] = "retrodeck"
		out["name"] = "RetroDECK"
		out["frontend"] = {"name": "RetroDECK", "command": ["flatpak", "run", RETRODECK_ID]}
		out["app"] = {"name": "RetroDECK", "command": ["flatpak", "run", RETRODECK_ID, "--configurator"]}
		out["roms_dir"] = _retrodeck_roms(home)
		esde_dir = _first_dir([ESDE_DIRS[2]], home)
	elif not esde_cmd.is_empty():
		out["kind"] = "esde"
		out["name"] = "ES-DE"
		out["frontend"] = {"name": "ES-DE", "command": esde_cmd}
		esde_dir = _first_dir([ESDE_DIRS[0], ESDE_DIRS[1]], home)
		out["roms_dir"] = home.path_join("ROMs")
	else:
		return out
	out["esde_dir"] = esde_dir
	out["emu_path"] = emu_path if out["kind"] == "emudeck" else ""
	var fe_cmd: Array = out["frontend"].get("command", []) if out["frontend"] is Dictionary else []
	out["es_path"] = str(fe_cmd[0]).get_base_dir() if fe_cmd.size() == 1 else ""
	if esde_dir != "":
		var rd := tilde(_esde_setting(esde_dir, "ROMDirectory"), home)
		if rd != "" and DirAccess.dir_exists_absolute(rd):
			out["roms_dir"] = rd
	out["media_dir"] = media_dir(home, esde_dir, str(out["roms_dir"]), out["kind"])
	out["roots"] = rom_roots(home, out)
	if not out["roots"].is_empty() and not DirAccess.dir_exists_absolute(str(out["roms_dir"])):
		for r in out["roots"]:
			if r["online"]:
				out["roms_dir"] = r["path"]
				break
	var srm := _first(SRM_APPIMAGES, home, emu_path)
	if srm != "":
		out["srm"] = {"command": [srm]}
	elif _flatpak(SRM_FLATPAK, home, flatpak_dirs):
		out["srm"] = {"command": ["flatpak", "run", SRM_FLATPAK]}
	var names := systems(home, flatpak_dirs)
	if count:
		out["systems"] = count_systems(str(out["roms_dir"]), names)
		for s in out["systems"]:
			out["rom_total"] += int(s["count"])
	var gl_dirs: Array = []
	if esde_dir != "":
		gl_dirs.append(esde_dir.path_join("gamelists"))
	if out["kind"] == "retrodeck":
		gl_dirs.append(out["roms_dir"].get_base_dir().path_join("ES-DE/gamelists"))
	for d in ESDE_DIRS:
		var g := _expand(d, home, "").path_join("gamelists")
		if not g in gl_dirs:
			gl_dirs.append(g)
	out["gamelist_dirs"] = gl_dirs
	out["recent"] = recent_from_gamelists(gl_dirs, names)
	return out


## ES-DE's downloaded_media folder: its MediaDirectory setting, else
## <ES-DE folder>/downloaded_media; RetroDECK keeps it beside the ROM folder
## (<rdhome>/ES-DE/downloaded_media, older <rdhome>/downloaded_media).
static func media_dir(home: String, esde_dir: String, roms_dir: String, kind: String) -> String:
	var cands: Array = []
	if esde_dir != "":
		var setting := tilde(_esde_setting(esde_dir, "MediaDirectory"), home)
		if setting != "":
			cands.append(setting)
		cands.append(esde_dir.path_join("downloaded_media"))
	if kind == "retrodeck" and roms_dir != "":
		cands.append(roms_dir.get_base_dir().path_join("ES-DE/downloaded_media"))
		cands.append(roms_dir.get_base_dir().path_join("downloaded_media"))
	for c in cands:
		if DirAccess.dir_exists_absolute(str(c)):
			return str(c)
	return ""


static func _first_dir(list: Array, home: String) -> String:
	for d in list:
		var p := _expand(str(d), home, "")
		if DirAccess.dir_exists_absolute(p):
			return p
	return ""


## RetroDECK's ROM folder: retrodeck.cfg (roms_folder=, 0.8/0.9), retrodeck.json
## (paths.roms_path / roms_folder, 0.10), else ~/retrodeck/roms.
static func _retrodeck_roms(home: String) -> String:
	var cfg := home.path_join(".var/app/net.retrodeck.retrodeck/config/retrodeck/")
	var p := _kv(cfg + "retrodeck.cfg", "roms_folder")
	if p == "":
		var j: Variant = Common.read_json(cfg + "retrodeck.json", {})
		var paths: Variant = j.get("paths", {}) if j is Dictionary else {}
		if paths is Dictionary:
			p = str(paths.get("roms_path", paths.get("roms_folder", "")))
	if p == "":
		p = home.path_join("retrodeck/roms")
	return tilde(p, home)


## Each system folder under `roms_dir` that holds games, most first:
## [{"id", "name", "short", "count"}]. Counts files only (nothing is opened).
static func count_systems(roms_dir: String, names: Dictionary) -> Array:
	var out: Array = []
	var d := DirAccess.open(roms_dir) if roms_dir != "" else null
	if d == null:
		return out
	for sub in d.get_directories():
		if sub.begins_with(".") or sub in NOT_ROM_DIRS:
			continue
		var n := count_roms(roms_dir.path_join(sub))
		if n > 0:
			out.append({"id": sub, "name": system_name(sub, names) if names.has(sub) else sub, "short": system_short(sub, names) if names.has(sub) else sub, "count": n})
	out.sort_custom(func(a, b): return a["count"] > b["count"] if a["count"] != b["count"] else a["name"].naturalnocasecmp_to(b["name"]) < 0)
	return out


## Game files in one system folder: not media, notes or saves; a .cue / .gdi
## counts once (its tracks don't), a .m3u counts once (the discs it lists don't);
## a folder named like a game file ("Game.ps3", "Game.wiiu") is one game.
static func count_roms(dir: String, depth := 0) -> int:
	var d := DirAccess.open(dir)
	if d == null or depth > COUNT_DEPTH or FileAccess.file_exists(dir.path_join("noload.txt")):
		return 0
	var files := d.get_files()
	# the same rule as the scan (roms.gd): a .bin is a track only when a sheet names it; one .cue used to hide
	# every .bin in the folder from this count
	var tracks := {}
	var bare_sheets: Array = []
	var listed := {}
	for f in files:
		var ext := f.get_extension().to_lower()
		if ext in ["cue", "gdi"]:
			var named := Roms._sheet_tracks(dir.path_join(f), ext)
			for t in named:
				tracks[t] = true
			if named.is_empty():
				bare_sheets.append(f.get_basename().to_lower())
		elif ext == "m3u":
			for line in FileAccess.get_file_as_string(dir.path_join(f)).split("\n"):
				var l := line.strip_edges()
				if l != "" and not l.begins_with("#"):
					listed[l.get_file()] = true
	var n := 0
	for f in files:
		var ext := f.get_extension().to_lower()
		if f.begins_with(".") or ext in NOT_ROM_EXT or listed.has(f) or (ext in TRACK_EXT and (tracks.has(f.to_lower()) or f.get_basename().to_lower() in bare_sheets)):
			continue
		n += 1
	for sub in d.get_directories():
		if sub.begins_with(".") or sub.to_lower() in NOT_ROM_DIRS:
			continue
		if sub.get_extension() != "" and not sub.get_extension().is_valid_int():
			n += 1   # "Game.ps3": the folder is the game
		else:
			n += count_roms(dir.path_join(sub), depth + 1)
		if n >= COUNT_MAX:
			break
	return mini(n, COUNT_MAX)


## The games ES-DE last started, newest first, from <dir>/<system>/gamelist.xml
## (<game><name>, <lastplayed>20240131T201500</lastplayed>): [{"title", "system", "last_played"}].
static func recent_from_gamelists(dirs: Array, names: Dictionary, limit := RECENT_MAX) -> Array:
	var all: Array = []
	var seen := {}
	for root in dirs:
		var d := DirAccess.open(str(root))
		if d == null:
			continue
		for sys in d.get_directories():
			var f := str(root).path_join(sys).path_join("gamelist.xml")
			if seen.has(f) or not FileAccess.file_exists(f):
				continue
			seen[f] = true
			for g in _gamelist_played(f):
				g["system"] = system_short(sys, names) if names.has(sys) else sys
				all.append(g)
	all.sort_custom(func(a, b): return a["last_played"] > b["last_played"])
	return all.slice(0, limit)


static func _gamelist_played(path: String) -> Array:
	var out: Array = []
	var fa := FileAccess.open(path, FileAccess.READ)
	if fa == null or fa.get_length() > GAMELIST_MAX_BYTES:
		return out
	fa.close()
	var x := XMLParser.new()
	if x.open(path) != OK:
		return out
	var cur := ""
	var g := {}
	while x.read() == OK:
		match x.get_node_type():
			XMLParser.NODE_ELEMENT:
				cur = x.get_node_name()
				if cur == "game":
					g = {"title": "", "last_played": 0, "path": ""}
			XMLParser.NODE_TEXT:
				var t := x.get_node_data().strip_edges()
				if g.is_empty() or t == "":
					continue
				match cur:
					"name": g["title"] = t.xml_unescape()
					"path": g["path"] = t.xml_unescape()
					"lastplayed": g["last_played"] = es_time(t)
			XMLParser.NODE_ELEMENT_END:
				if x.get_node_name() == "game" and not g.is_empty():
					if int(g["last_played"]) > 0:
						if g["title"] == "":
							g["title"] = str(g["path"]).get_file().get_basename()
						out.append({"title": g["title"], "last_played": g["last_played"]})
					g = {}
				cur = ""
	return out


## ES-DE's date-time ("20240131T201500", local time) as unix seconds; 0 if not one.
static func es_time(s: String) -> int:
	if s.length() < 15 or s[8] != "T" or not s.substr(0, 8).is_valid_int() or not s.substr(9, 6).is_valid_int():
		return 0
	var iso := "%s-%s-%sT%s:%s:%s" % [s.substr(0, 4), s.substr(4, 2), s.substr(6, 2), s.substr(9, 2), s.substr(11, 2), s.substr(13, 2)]
	return int(Time.get_unix_time_from_datetime_string(iso))


# ------------------------------------------------------------ Steam ROM Manager shortcuts

## What a shortcut's launch line says about an emulated game, or {} when it
## isn't one: {"system", "emulator", "via": "emudeck" | "retrodeck" | "emulator", "rom"}.
static func recognise(exe: String, options: String, start_dir := "") -> Dictionary:
	var line := ("%s %s %s" % [exe, options, start_dir]).replace("\\", "/")
	var low := line.to_lower()
	var rom_path := shortcut_rom_path(line)
	var m := RegEx.create_from_string("/roms/([A-Za-z0-9_+-]+)/(.+)$").search(rom_path)
	if m == null:
		return {}
	var system := m.get_string(1).to_lower()
	var via := "emudeck" if ("/tools/launchers/" in low or "/emudeck/" in low) else ("retrodeck" if RETRODECK_ID in low else "")
	var emulator := ""
	for e in EMULATORS:
		if e[0] in low.replace(RETRODECK_ID, ""):
			emulator = e[1]
			break
	if via == "" and emulator == "" and not systems().has(system):
		return {}
	if via == "":
		via = "emulator"
	return {"system": system, "emulator": emulator, "via": via, "rom": m.get_string(2).strip_edges(), "rom_path": rom_path.strip_edges()}


## The ROM a launch line opens: the first quoted path with /roms/<system>/ in
## it (double quotes first, so a name with an apostrophe stays whole, then the
## single quotes older parsers used), else the first such unquoted word.
static func shortcut_rom_path(line: String) -> String:
	for re in ["\"([^\"]*/roms/[A-Za-z0-9_+-]+/[^\"]+)\"", "'([^']*/roms/[A-Za-z0-9_+-]+/[^']+)'", "(\\S*/roms/[A-Za-z0-9_+-]+/\\S+)"]:
		var m := RegEx.create_from_string(re).search(line)
		if m != null:
			var r := m.get_string(1)
			# "'path'": older parsers' single quotes inside the double ones (EmuDeck's launchers drop them)
			return r.substr(1, r.length() - 2) if r.length() > 1 and r.begins_with("'") and r.ends_with("'") else r
	return ""


## Steam's 64-bit game id for a shortcut app id, as a decimal string
## (it doesn't fit GDScript's signed int when the app id's top bit is set).
static func shortcut_game_id(appid: int) -> String:
	var u := appid & 0xFFFFFFFF
	# u * 2^32 + 0x02000000, in decimal digits
	var digits := PackedInt32Array([0])
	var mul := func(k: int) -> void:
		var carry := 0
		for i in digits.size():
			var v := digits[i] * k + carry
			digits[i] = v % 10
			carry = v / 10
		while carry > 0:
			digits.append(carry % 10)
			carry /= 10
	var add := func(k: int) -> void:
		var carry := k
		var i := 0
		while carry > 0:
			if i >= digits.size():
				digits.append(0)
			var v := digits[i] + carry
			digits[i] = v % 10
			carry = v / 10
			i += 1
	add.call(u)
	for i in 4:
		mul.call(256)
	add.call(SHORTCUT_LOW)
	var s := ""
	for i in range(digits.size() - 1, -1, -1):
		s += str(digits[i])
	return s.lstrip("0") if s.lstrip("0") != "" else "0"


## The emulated games in one shortcuts.vdf, as store entries.
static func shortcuts(path: String, steam_root: String, users: Array[String], names: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var root := BinaryKV.parse_file(path)
	var list: Variant = BinaryKV.get_ci(root, "shortcuts", {})
	if not list is Dictionary:
		return out
	for k in list:
		var s: Variant = list[k]
		if not s is Dictionary:
			continue
		var exe := str(BinaryKV.get_ci(s, "Exe", ""))
		var opts := str(BinaryKV.get_ci(s, "LaunchOptions", ""))
		var info := recognise(exe, opts, str(BinaryKV.get_ci(s, "StartDir", "")))
		var appid_v: Variant = BinaryKV.get_ci(s, "appid")
		if info.is_empty() or not appid_v is int:
			continue
		var u := int(appid_v) & 0xFFFFFFFF
		var title := str(BinaryKV.get_ci(s, "AppName", "")).strip_edges()
		if title == "":
			title = str(info["rom"]).get_file().get_basename()
		var sys_name := system_name(info["system"], names) if names.has(info["system"]) else str(info["system"]).to_upper()
		var art := SteamStore.art_for(steam_root, str(u), users)
		var icon := str(BinaryKV.get_ci(s, "icon", "")).trim_prefix("\"").trim_suffix("\"")
		if art["icon"] == "" and icon != "" and FileAccess.file_exists(icon):
			art["icon"] = icon
		var summary := "A %s game from your ROM folder, added to Steam by Steam ROM Manager%s." % [sys_name,
			{"emudeck": " through EmuDeck", "retrodeck": " through RetroDECK"}.get(info["via"], "")]
		if info["emulator"] != "":
			summary += " It runs in %s." % info["emulator"]
		out.append({"store": "emu", "id": str(u), "title": title, "installed": true, "art": art, "ids": {},
			"shortcut": true, "game_id": shortcut_game_id(u), "rom_path": info["rom_path"],
			"emulated": {"system": info["system"], "system_name": sys_name, "system_short": system_short(info["system"], names) if names.has(info["system"]) else sys_name,
				"emulator": info["emulator"], "via": info["via"]},
			"hidden_in_steam": int(BinaryKV.get_ci(s, "IsHidden", 0)) == 1,
			"last_played": maxi(0, int(BinaryKV.get_ci(s, "LastPlayTime", 0))), "playtime_min": 0,
			"local_meta": {"source": "emu", "meta": {"summary": summary}}})
	return out


# ------------------------------------------------------------ "Show emulated games in the Library"

## user://emulation.json: {"show_roms": bool}. Missing = on (it only matters
## when a ROM folder was found; with none there's nothing to show).
const PREFS_PATH := "user://emulation.json"
static var prefs_path := PREFS_PATH


static func roms_enabled(path := "") -> bool:
	var d: Variant = SettingsFile.load_json(path if path != "" else prefs_path).get("data")
	return not (d is Dictionary and d.get("show_roms") == false)


static func set_roms_enabled(on: bool, path := "") -> bool:
	var p := path if path != "" else prefs_path
	var d: Variant = SettingsFile.load_json(p).get("data")
	var doc: Dictionary = d if d is Dictionary else {}
	doc["show_roms"] = on
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(p).get_base_dir())
	return SettingsFile.save_json(p, doc, "\t") == OK


# ------------------------------------------------------------ ROM games

## Removable drives: a configured ROM folder under one of these that isn't there
## is an SD card or USB drive that isn't plugged in (listed as offline; its games
## hide until it's back, their play time and collections kept).
const REMOVABLE := ["/run/media/", "/media/", "/mnt/"]
## Tests add their own fake mount folder.
static var removable: Array = REMOVABLE


## real_path() of a file's folder (kept in `dirs`) plus its name.
static func _real_in(path: String, dirs: Dictionary) -> String:
	var p := path.simplify_path()
	var d := p.get_base_dir()
	if not dirs.has(d):
		dirs[d] = real_path(d)
	return str(dirs[d]).path_join(p.get_file())


## A leading ~ or ~/ is the home folder; a ~ anywhere else in a path is just a character in a name.
static func tilde(p: String, home: String) -> String:
	if p == "~":
		return home
	if p.begins_with("~/"):
		return home.path_join(p.substr(2))
	return p


## `p` with every symbolic link followed (at most 32 hops; a loop stops there).
static func real_path(p: String) -> String:
	var parts := Array(p.simplify_path().split("/", false))
	var out := ""
	var hops := 0
	while not parts.is_empty():
		var part: String = parts.pop_front()
		if part == ".":
			continue
		if part == "..":
			out = out.get_base_dir() if out != "" and out != "/" else ""
			if out == "/":
				out = ""
			continue
		var d := DirAccess.open(out if out != "" else "/")
		if d != null and hops < 32 and d.is_link(part):
			hops += 1
			var target := d.read_link(part)
			if target.begins_with("/"):
				out = ""
			parts = Array(target.split("/", false)) + parts
			continue
		out += "/" + part
	return out if out != "" else "/"


## Every ROM folder this machine's setups point at, each once (by its real
## path): ES-DE's ROMDirectory (3.x and the legacy 2.x settings, RetroDECK's),
## EmuDeck's emulationPath/roms and romsPath, RetroDECK's roms folder, and the
## defaults (~/Emulation/roms, ~/ROMs, ~/retrodeck/roms) when they exist.
## [{"path", "real", "online": bool, "from": what named it}]; an offline one is a
## configured folder on a removable drive that isn't mounted.
static func rom_roots(home: String, setup: Dictionary) -> Array:
	var cands: Array = []
	var add := func(p: String, from: String) -> void:
		if p.strip_edges() != "":
			cands.append([tilde(p.strip_edges(), home), from])
	if str(setup.get("roms_dir", "")) != "":
		add.call(str(setup["roms_dir"]), str(setup.get("name", "")))
	for d in ESDE_DIRS:
		var esde := _expand(d, home, "")
		var rd := _esde_setting(esde, "ROMDirectory")
		if rd != "" and not "%ESPATH%" in rd:
			add.call(tilde(rd, home), "ES-DE")
	var emu_settings := home.path_join(".config/EmuDeck/settings.sh")
	var ep := _kv(emu_settings, "emulationPath")
	if ep != "":
		add.call(ep.path_join("roms"), "EmuDeck")
	add.call(_kv(emu_settings, "romsPath"), "EmuDeck")
	if DirAccess.dir_exists_absolute(home.path_join(".var/app/net.retrodeck.retrodeck/config/retrodeck")):
		add.call(_retrodeck_roms(home), "RetroDECK")
	for dflt in [["Emulation/roms", "EmuDeck"], ["ROMs", "ES-DE"], ["retrodeck/roms", "RetroDECK"]]:
		add.call(home.path_join(dflt[0]), dflt[1])
	var out: Array = []
	var seen := {}
	for c in cands:
		var p: String = str(c[0]).simplify_path()
		var online := DirAccess.dir_exists_absolute(p)
		if not online and not removable.any(func(r): return p.begins_with(str(r))):
			continue   # a default or a stale setting with nothing behind it
		var real := real_path(p) if online else p
		if seen.has(real):
			continue
		seen[real] = true
		out.append({"path": p, "real": real, "online": online, "from": c[1]})
	return out


## What scanning needs, for every folder in every online ROM root (each real
## folder once, so a system folder EmuDeck symlinked elsewhere isn't read twice):
## [{"key", "id" (the folder's name), "root" (the system's ROM folder: ES-DE's
## <path> when it says <id>/something, like EmuDeck's Wii U), "base" (the ROM
## root), "exts" ([] for a folder ES-DE doesn't know), "known"}].
## ES-DE's app systems (NOT_GAME_SYSTEMS: desktop shortcuts, other stores'
## launchers, EmuDeck's emulator shortcuts) aren't games of ours.
static func rom_systems(setup: Dictionary, custom: Dictionary) -> Array:
	var out: Array = []
	var seen := {}
	for r in setup.get("roots", []):
		if not r.get("online", false):
			continue
		var roms := str(r["path"])
		var d := DirAccess.open(roms)
		if d == null:
			continue
		var subs := Array(d.get_directories())
		subs.sort()
		for sub in subs:
			if sub.begins_with(".") or sub.to_lower() in NOT_ROM_DIRS or sub in EsdeLaunch.NOT_GAME_SYSTEMS:
				continue
			var def := EsdeLaunch.system_def(sub, custom)
			var root := roms.path_join(sub)
			var p := str(def.get("path", "")).replace("%ROMPATH%", roms).replace("\\", "/")
			if p.begins_with(root + "/") and DirAccess.dir_exists_absolute(p):
				root = p   # EmuDeck's custom Wii U, Xbox 360 and Model 2 systems: <system>/roms
			var real := real_path(root)
			if seen.has(real):
				continue
			seen[real] = true
			var exts: Array = []
			for e in def.get("ext", []):
				if str(e) != ".":
					exts.append(str(e).trim_prefix("."))
			out.append({"id": sub, "root": root, "base": roms, "exts": exts, "known": not def.is_empty()})
	return out


## The gamelist.xml ES-DE keeps for `system` ("" when none): its gamelists
## folder first, then one in the system's ROM folder (ES-DE's legacy place).
static func gamelist_for(system: String, root: String, gamelist_dirs: Array) -> String:
	for d in gamelist_dirs:
		var f := str(d).path_join(system).path_join("gamelist.xml")
		if FileAccess.file_exists(f):
			return f
	var legacy := root.path_join("gamelist.xml")
	return legacy if FileAccess.file_exists(legacy) else ""


## Every ROM as a store entry, and the systems with their game counts (most
## first) for the Emulation page: {"entries": [...], "systems": [{"id", "name",
## "short", "count", "roots": [ROM roots it's in], "known"}]}. A folder ES-DE
## doesn't know keeps its games, named after the folder, marked "unknown": they
## can't start (launch_plan says why).
static func rom_entries(home: String, setup: Dictionary, names: Dictionary, sources := {}) -> Dictionary:
	if sources.is_empty():
		sources = rom_sources(setup)
	var custom: Dictionary = sources["custom"]
	var list: Array = sources["list"]
	var found := Roms.scan_all(list, str(setup.get("media_dir", "")))
	var kind := str(setup.get("kind", ""))
	var entries: Array[Dictionary] = []
	var by_sys := {}
	var ids := {}
	var no_art: Dictionary = Common.freeze(Common.empty_art())
	for sy in list:
		var res: Variant = found.get(sy["key"])
		if not res is Dictionary or (res["games"] as Array).is_empty():
			continue
		var id: String = sy["id"]
		var known: bool = sy["known"]
		var sname := system_name(id, names) if names.has(id) else id
		var sshort := system_short(id, names) if names.has(id) else id
		var def := EsdeLaunch.system_def(id, custom)
		var alt := str(res.get("alt", ""))
		var sys_ctx := {"kind": kind, "home": home, "emu_path": str(setup.get("emu_path", "")), "roms_dir": str(sy["base"]),
			"es_path": str(setup.get("es_path", "")), "esde_dir": str(setup.get("esde_dir", "")), "system_alt": alt}
		var names_by := {}   # (game alt, shell file?) -> [label, emulator name]: worked out once per system
		var emulated_by := {}   # one "emulated" for every ROM of this system that reads the same (never edited in place)
		for g in res["games"]:
			var nk := "%s|%s" % [g["altemulator"], str(g["path"]).get_extension().to_lower() in EsdeLaunch.SHELL_EXT]
			if not names_by.has(nk):
				var chosen := EsdeLaunch.pick(def.get("commands", []), alt, str(g["altemulator"]), str(g["path"]))
				var lb := str(chosen[0]) if not chosen.is_empty() else ""
				names_by[nk] = [lb, EsdeLaunch.emulator_name(id, lb, custom)]
			var label: String = names_by[nk][0]
			var emu_name: String = names_by[nk][1]
			var summary := "A %s game from your ROM folder." % sname
			if not known:
				summary = UNKNOWN_SYSTEM % id
			elif emu_name != "":
				summary += " It runs in %s%s." % [emu_name, {"emudeck": " through EmuDeck", "retrodeck": " through RetroDECK"}.get(kind, "")]
			var meta: Dictionary = (g["meta"] as Dictionary).duplicate()
			if str(meta.get("summary", "")) == "":
				meta["summary"] = summary
			# The same file name in two ROM roots: the second one's key names its root.
			var gid := str(g["id"])
			if ids.has(gid):
				gid += "@" + str(sy["base"]).sha256_text().substr(0, 8)
			ids[gid] = true
			var ek := "%s|%s|%s|%s|%s" % [label, emu_name, g["players"], g["rating"], g["playcount"]]
			if not emulated_by.has(ek):
				emulated_by[ek] = Common.freeze({"system": id, "system_name": sname, "system_short": sshort, "emulator": emu_name, "via": kind,
					"rom": true, "unknown": not known, "label": label, "players": g["players"], "rating": g["rating"], "playcount": g["playcount"],
					"root": str(sy["base"])})
			# A ROM without art shares one empty set (merge_shortcuts and a picked cover
			# replace it, never edit it).
			var art: Dictionary = g["art"]
			art = no_art if art == no_art else art.duplicate()
			# No "ids" (ROMs never match the database) and no "aliases" until a shortcut folds
			# in (merge_shortcuts): two empty containers per ROM add up over thousands.
			entries.append({"store": "emu", "id": gid, "title": g["title"], "installed": true, "art": art,
				"rom": g["path"], "rom_rel": g["rel"], "altemulator": g["altemulator"], "launch_ctx": sys_ctx,
				"emulated": emulated_by[ek],
				"es_favorite": g["favorite"], "es_hidden": g["hidden"],
				"last_played": int(g["last_played"]), "playtime_min": 0,
				"local_meta": {"source": "esde" if not (g["meta"] as Dictionary).is_empty() else "emu", "meta": meta}})
		if not by_sys.has(id):
			by_sys[id] = {"id": id, "name": sname, "short": sshort, "count": 0, "roots": [], "known": known, "capped": false, "gamelist_skipped": false}
		by_sys[id]["count"] += (res["games"] as Array).size()
		by_sys[id]["capped"] = by_sys[id]["capped"] or bool(res.get("capped", false))
		by_sys[id]["gamelist_skipped"] = by_sys[id]["gamelist_skipped"] or bool(res.get("gamelist_skipped", false))
		if not str(sy["base"]) in by_sys[id]["roots"]:
			by_sys[id]["roots"].append(str(sy["base"]))
	var counts: Array = by_sys.values()
	counts.sort_custom(func(a, b): return a["count"] > b["count"] if a["count"] != b["count"] else a["name"].naturalnocasecmp_to(b["name"]) < 0)
	return {"entries": entries, "systems": counts}


## What the ROM games are read from: ES-DE's custom systems and every system
## folder with its gamelist ({"custom", "list"}).
static func rom_sources(setup: Dictionary) -> Dictionary:
	var custom := EsdeLaunch.read_custom(str(setup.get("esde_dir", "")))
	var list := rom_systems(setup, custom)
	for sy in list:
		sy["gamelist"] = gamelist_for(sy["id"], sy["root"], setup.get("gamelist_dirs", []))
	return {"custom": custom, "list": list}


const UNKNOWN_SYSTEM := "ES-DE doesn't know a system called \"%s\", so nothing can start these games. Rename the folder to ES-DE's name for that console (EmuDeck's own folders already are)."


## One entry per game: a Steam ROM Manager shortcut for a ROM we list too goes,
## and our entry keeps its art where ES-DE has none, its last-played time and
## its key (in "aliases", so favourites, collections and play time follow).
static func merge_shortcuts(roms: Array, shortcut_entries: Array) -> Array[Dictionary]:
	var by_path := {}
	var dirs := {}   # folder -> its real path: thousands of ROMs share a few folders
	for r in roms:
		by_path[_real_in(str(r["rom"]), dirs)] = r
		var root_rel := str(r["rom_rel"])
		if str(r["rom"]).ends_with("/" + root_rel.get_file() + "/" + root_rel.get_file()):
			by_path[real_path(str(r["rom"]).get_base_dir())] = r   # a folder game launched by its inner file
	var out: Array[Dictionary] = []
	for e in shortcut_entries:
		var p := _real_in(str(e.get("rom_path", "")), dirs)   # real paths: a link into the ROM folder is the same game
		var hit: Variant = null
		var up := p
		for i in 5:
			if up == "" or up == "/":
				break
			if by_path.has(up):
				hit = by_path[up]
				break
			up = up.get_base_dir()
		if hit == null:
			out.append(e)
			continue
		var art: Dictionary = (hit["art"] as Dictionary).duplicate()   # it may be the shared empty set
		hit["art"] = art
		for k in art:
			if str(art[k]) == "" and str(e.get("art", {}).get(k, "")) != "":
				art[k] = e["art"][k]
		hit["last_played"] = maxi(int(hit["last_played"]), int(e.get("last_played", 0)))
		hit["aliases"] = hit.get("aliases", []) + ["emu:%s" % e["id"]]
		if e.get("hidden_in_steam", false):
			hit["hidden_in_steam"] = true
	return out


# ------------------------------------------------------------ Library scan

## Every "emu" entry under `home`: the frontend (when one is installed), every
## ROM (with `roms` on) and Steam ROM Manager's shortcuts of the Steam account
## that signed in last (those for a ROM we list fold into its entry).
## `setup` is what detect() returned (Library keeps it for the Emulation page);
## with `roms` on, its "systems" and "rom_total" come from the games found.
##
## `reuse` ({"stamp", "salt"}) lets the Library skip making thousands of ROM
## games again when nothing they're made from changed: "stamp" is the stamp of
## the ones it has, "salt" the bytes of anything else they depend on (play time,
## picked art). Every stamp is a hash of the setup, the consoles, ES-DE's custom
## systems, every ROM folder (as the ROM cache saw it, unchanged), the shortcuts
## and the salt. The new one goes in reuse["stamp_now"] ("" when a folder changed
## in the second it was read: read again next time). When it matches,
## reuse["same"] is true and nothing comes back: the Library keeps every "emu"
## game it has.
static func scan(home: String, setup: Dictionary, roms := false, reuse := {}) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var setup_bytes := var_to_bytes(setup)
	var fe: Variant = setup.get("frontend", {})
	if fe is Dictionary and not fe.is_empty():
		out.append({"store": "emu", "id": "frontend", "title": str(fe["name"]), "installed": true, "art": Common.empty_art(),
			"ids": {}, "command": fe["command"], "frontend": true, "last_played": 0, "playtime_min": 0,
			"emulated": {"system": "", "system_name": "", "system_short": "", "emulator": "", "via": str(setup.get("kind", ""))},
			"local_meta": {"source": "emu", "meta": {"summary": "%s, with every system %s set up. Start it here and it runs full screen like a game." % [fe["name"], setup.get("name", fe["name"])]}}})
	var names := systems(home)
	var seen := {}
	var cuts: Array[Dictionary] = []
	for r in SteamStore.STEAM_ROOTS:
		var root := SteamStore.expand(r, home)
		if not DirAccess.dir_exists_absolute(root):
			continue
		var user := SteamConfig.current_user_dir(root)
		if user == "":
			continue
		var users: Array[String] = [user]
		for e in shortcuts(user.path_join("config/shortcuts.vdf"), root, users, names):
			if not seen.has(e["id"]):
				seen[e["id"]] = true
				cuts.append(e)
	if roms and str(setup.get("kind", "")) != "":
		var sources := rom_sources(setup)
		var media := str(setup.get("media_dir", ""))
		var ctx := HashingContext.new()
		ctx.start(HashingContext.HASH_MD5)
		ctx.update(var_to_bytes([setup_bytes, names, sources, cuts, out, reuse.get("salt", PackedByteArray())]))
		var inputs := ctx.finish().hex_encode()
		var stamp_of := func() -> String:
			var folders := Roms.unchanged_stamp(sources["list"], media)
			return "" if folders == "" else (inputs + folders).md5_text()
		if reuse.has("stamp"):
			var now: String = stamp_of.call()
			if now != "" and now == str(reuse["stamp"]):
				reuse["stamp_now"] = now
				reuse["same"] = true
				return []
		var found := rom_entries(home, setup, names, sources)
		reuse["stamp_now"] = stamp_of.call()
		setup["systems"] = found["systems"]
		setup["rom_total"] = 0
		for sy in setup["systems"]:
			setup["rom_total"] += int(sy["count"])
		setup["roms_shown"] = true
		cuts = merge_shortcuts(found["entries"], cuts)
		out.append_array(found["entries"])
	out.append_array(cuts)
	return out


## How a game starts: {"ok", "cmd": [program, args...], "label", "why"}. The
## frontend and the setup's tools: their command. A ROM: its setup's way
## (esde_launch.gd), with `extra_env` (the user's launch settings) and ES-DE's
## working folder applied through `env`. A shortcut starts through Steam
## (Library.launch, `steam://rungameid/<game_id>`), so it has none here.
static func launch_plan(entry: Dictionary, extra_env := {}, home := "", path_env := "") -> Dictionary:
	var out := {"ok": false, "cmd": [] as Array[String], "label": "", "why": ""}
	if entry.get("frontend", false):
		for c in entry.get("command", []):
			out["cmd"].append(str(c))
		out["ok"] = not out["cmd"].is_empty()
		return out
	if str(entry.get("rom", "")) == "":
		return out
	if entry.get("emulated", {}).get("unknown", false):
		out["why"] = UNKNOWN_SYSTEM % str(entry["emulated"].get("system", ""))
		return out
	var ctx: Dictionary = (entry.get("launch_ctx", {}) as Dictionary).duplicate()
	if home != "" or str(ctx.get("home", "")) == "":
		ctx["home"] = home if home != "" else OS.get_environment("HOME")
	ctx["path_env"] = path_env if path_env != "" else _path()
	ctx["custom"] = EsdeLaunch.read_custom(str(ctx.get("esde_dir", "")))
	var plan := EsdeLaunch.build({"system": entry.get("emulated", {}).get("system", ""), "path": entry["rom"],
		"altemulator": entry.get("altemulator", "")}, ctx)
	out["label"] = plan["label"]
	if not plan["ok"]:
		out["why"] = plan["why"]
		return out
	var env: Dictionary = plan["env"].duplicate()
	env.merge(extra_env, true)
	var cwd := str(plan["cwd"])
	if cwd != "" and not DirAccess.dir_exists_absolute(cwd):
		DirAccess.make_dir_recursive_absolute(cwd)   # ES-DE makes a missing start folder too
	if env.is_empty() and cwd == "":
		for c in plan["cmd"]:
			out["cmd"].append(str(c))
	else:
		out["cmd"] = Common.with_env(env, plan["cmd"], cwd)
	out["ok"] = true
	return out


static func _path() -> String:
	return path_env if path_env != "" else OS.get_environment("PATH")


## The command that starts the frontend or a ROM; [] for anything else.
static func launch_command(entry: Dictionary, extra_env := {}) -> Array[String]:
	return launch_plan(entry, extra_env)["cmd"]


## A shortcut's 64-bit game id, checked before it goes into a steam:// URI.
static func valid_game_id(gid: String) -> bool:
	return RegEx.create_from_string("^[0-9]{1,20}$").search(gid) != null and gid.lstrip("0") != ""
