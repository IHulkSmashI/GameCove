extends RefCounted
## Emulation, the way EmuDeck and RetroDECK already set it up: GameCove reads
## their files and starts their tools; it never scans for ROMs to run itself,
## never writes their files, and never bundles or downloads ROMs or BIOS.
##
## Two kinds of Library entries (store "emu"):
## - id "frontend": ES-DE (EmuDeck or standalone) or RetroDECK, started like
##   any non-Steam game (its own gamescope scope, play time counted by us).
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
## Files and folders in a ROM folder that are never games (EmuDeck puts a
## systeminfo.txt / metadata.txt in each; scrapers leave media).
const NOT_ROM_EXT := ["txt", "xml", "md", "png", "jpg", "jpeg", "webp", "gif", "mp4", "mkv", "pdf", "srm", "sav",
	"state", "cfg", "ini", "json", "log", "nfo", "db", "sh", "bat", "lnk", "url", "html"]
const NOT_ROM_DIRS := ["media", "images", "videos", "manuals", "downloaded_media", "snaps", "saves", "states",
	"screenshots", "covers", "marquees", "titles", "boxart", "wheel", "fanart"]
## Track files a .cue / .gdi already counts.
const TRACK_EXT := ["bin", "img", "raw", "sub", "track", "wav"]
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
		"esde_dir": "", "rom_total": 0}


## What's installed: {"kind": "emudeck" | "retrodeck" | "esde" | "",
##  "name", "frontend": {"name", "command"} or {}, "app": {"name", "command"} or {},
##  "srm": {"command"} or {}, "roms_dir", "systems": [{"id", "name", "short", "count"}]
##  (most ROMs first), "rom_total", "recent": [{"title", "system", "last_played"}], "esde_dir"}.
static func detect(home: String, path_env := "", flatpak_dirs: Array = FLATPAK_DIRS) -> Dictionary:
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
	if esde_dir != "":
		var rd := _esde_setting(esde_dir, "ROMDirectory").replace("~", home)
		if rd != "" and DirAccess.dir_exists_absolute(rd):
			out["roms_dir"] = rd
	var srm := _first(SRM_APPIMAGES, home, emu_path)
	if srm != "":
		out["srm"] = {"command": [srm]}
	elif _flatpak(SRM_FLATPAK, home, flatpak_dirs):
		out["srm"] = {"command": ["flatpak", "run", SRM_FLATPAK]}
	var names := systems(home, flatpak_dirs)
	out["systems"] = count_systems(str(out["roms_dir"]), names)
	for s in out["systems"]:
		out["rom_total"] += int(s["count"])
	var gl_dirs: Array = []
	for d in ESDE_DIRS:
		gl_dirs.append(_expand(d, home, "").path_join("gamelists"))
	if out["kind"] == "retrodeck":
		gl_dirs.append(out["roms_dir"].get_base_dir().path_join("ES-DE/gamelists"))
	out["recent"] = recent_from_gamelists(gl_dirs, names)
	return out


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
	return p.replace("~", home)


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
	var has_sheet := false
	var listed := {}
	for f in files:
		var ext := f.get_extension().to_lower()
		if ext in ["cue", "gdi"]:
			has_sheet = true
		elif ext == "m3u":
			for line in FileAccess.get_file_as_string(dir.path_join(f)).split("\n"):
				var l := line.strip_edges()
				if l != "" and not l.begins_with("#"):
					listed[l.get_file()] = true
	var n := 0
	for f in files:
		var ext := f.get_extension().to_lower()
		if f.begins_with(".") or ext in NOT_ROM_EXT or listed.has(f) or (has_sheet and ext in TRACK_EXT):
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
	var re := RegEx.create_from_string("/roms/([A-Za-z0-9_+-]+)/([^\"']+)")
	var m := re.search(line)
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
	return {"system": system, "emulator": emulator, "via": via, "rom": m.get_string(2).strip_edges()}


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
			"shortcut": true, "game_id": shortcut_game_id(u),
			"emulated": {"system": info["system"], "system_name": sys_name, "system_short": system_short(info["system"], names) if names.has(info["system"]) else sys_name,
				"emulator": info["emulator"], "via": info["via"]},
			"hidden_in_steam": int(BinaryKV.get_ci(s, "IsHidden", 0)) == 1,
			"last_played": maxi(0, int(BinaryKV.get_ci(s, "LastPlayTime", 0))), "playtime_min": 0,
			"local_meta": {"source": "emu", "meta": {"summary": summary}}})
	return out


# ------------------------------------------------------------ Library scan

## Every "emu" entry under `home`: the frontend (when one is installed) and
## Steam ROM Manager's shortcuts of the Steam account that signed in last.
## `setup` is what detect() returned (Library keeps it for the Emulation page).
static func scan(home: String, setup: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var fe: Variant = setup.get("frontend", {})
	if fe is Dictionary and not fe.is_empty():
		out.append({"store": "emu", "id": "frontend", "title": str(fe["name"]), "installed": true, "art": Common.empty_art(),
			"ids": {}, "command": fe["command"], "frontend": true, "last_played": 0, "playtime_min": 0,
			"emulated": {"system": "", "system_name": "", "system_short": "", "emulator": "", "via": str(setup.get("kind", ""))},
			"local_meta": {"source": "emu", "meta": {"summary": "%s, with every system %s set up. Start it here and it runs full screen like a game." % [fe["name"], setup.get("name", fe["name"])]}}})
	var names := systems(home)
	var seen := {}
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
				out.append(e)
	return out


## The command that starts the frontend; [] for anything else (a shortcut
## starts through Steam: Library.launch, `steam://rungameid/<game_id>`).
static func launch_command(entry: Dictionary) -> Array[String]:
	var out: Array[String] = []
	if entry.get("frontend", false):
		for c in entry.get("command", []):
			out.append(str(c))
	return out


## A shortcut's 64-bit game id, checked before it goes into a steam:// URI.
static func valid_game_id(gid: String) -> bool:
	return RegEx.create_from_string("^[0-9]{1,20}$").search(gid) != null and gid.lstrip("0") != ""
