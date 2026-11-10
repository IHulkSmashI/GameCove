extends RefCounted
## Desktop apps (browsers, music, video, Discord, emulator front-ends...) as
## things GameCove can start like a game, the way the Quick Launch plugin
## does: read the installed .desktop files (Flatpak exports and the system's
## own), keep the ones a person would open, find their icons, and start one
## full screen in gamescope with the same app id trick as streams: a systemd
## scope named for the id plus GameCove's reaper wrapper (Flatpaks move
## themselves into their own scope, so gamescope finds them through the
## wrapper; see packaging/libexec/reaper). The quick menu works over it and
## closing it brings GameCove back.
##
## What's left out (freedesktop Desktop Entry spec 1.5): Type other than
## Application, NoDisplay, Hidden, Terminal apps, entries limited to one
## desktop with OnlyShowIn, a TryExec that isn't installed, settings and
## system tools (Categories Settings / System / ConsoleOnly / Screensaver
## without Game), and the launchers GameCove already is or covers (Steam,
## GameCove itself, the session switchers).
##
## Pinned apps (user://apps.json, {"pinned": [app, ...]} with each app's
## title, command and icon kept, so Home shows them without a scan) make the
## Home "Apps" shelf. Scanning reads a few hundred small files: worker thread.

const SettingsFile := preload("res://scripts/system/settings_file.gd")
const Common := preload("res://scripts/library/stores/common.gd")

const STORE := "app"
const PINS_PATH := "user://apps.json"
const ICON_CACHE := "user://apps/icons"
const ICON_PX := 256
const REAPER := "/usr/libexec/gamecove/reaper"
const SKIP_CATEGORIES := ["Settings", "System", "ConsoleOnly", "Screensaver", "Monitor", "PackageManager", "TerminalEmulator"]
## Desktop ids GameCove never lists: itself, Steam (its own mode), session switching.
const SKIP_IDS := ["steam", "com.valvesoftware.Steam", "valve-URI-steamvr", "valve-URI-vrmonitor", "gamecove",
	"io.github.ihulksmashi.gamecove", "gamecove-installer", "steamos-gamemode", "return-to-gamemode", "gamescope-session"]
## The line under an app's name on its tile.
const SUB_FLATPAK := "Flatpak"
const SUB_APP := "App"
const ICON_SIZES := ["512x512", "256x256", "192x192", "128x128", "96x96", "64x64", "48x48", "scalable", "32x32"]


## Where .desktop files live, most important first (a user's own copy hides the
## system one with the same id).
static func desktop_dirs(home: String, xdg_data_dirs: String) -> Array:
	var out: Array = [home.path_join(".local/share/applications"), home.path_join(".local/share/flatpak/exports/share/applications"),
		"/var/lib/flatpak/exports/share/applications"]
	var dirs := xdg_data_dirs if xdg_data_dirs.strip_edges() != "" else "/usr/local/share:/usr/share"
	for d in dirs.split(":", false):
		var a := d.path_join("applications")
		if not a in out:
			out.append(a)
	return out


## Icon theme roots, most important first.
static func icon_dirs(home: String, xdg_data_dirs: String) -> Array:
	var out: Array = [home.path_join(".local/share/icons"), home.path_join(".local/share/flatpak/exports/share/icons"),
		"/var/lib/flatpak/exports/share/icons"]
	var dirs := xdg_data_dirs if xdg_data_dirs.strip_edges() != "" else "/usr/local/share:/usr/share"
	for d in dirs.split(":", false):
		var a := d.path_join("icons")
		if not a in out:
			out.append(a)
	return out


## The [Desktop Entry] group as {key: value} (unlocalised keys, and Name[xx]
## for `locale`'s language). Other groups (actions) are skipped.
static func parse_desktop(text: String, locale := "") -> Dictionary:
	var out := {}
	var in_main := false
	var lang := locale.split("_")[0] if locale != "" else ""
	for raw in text.split("\n"):
		var l := raw.strip_edges()
		if l == "" or l.begins_with("#"):
			continue
		if l.begins_with("["):
			in_main = l == "[Desktop Entry]"
			continue
		if not in_main:
			continue
		var eq := l.find("=")
		if eq <= 0:
			continue
		var k := l.substr(0, eq).strip_edges()
		var v := l.substr(eq + 1).strip_edges()
		if k.contains("["):
			if lang != "" and k == "Name[%s]" % lang:
				out["Name@local"] = v
			continue
		out[k] = v
	return out


static func _true(v: Variant) -> bool:
	return str(v).strip_edges().to_lower() == "true"


static func _list(v: Variant) -> PackedStringArray:
	return str(v).split(";", false)


## True when the entry is something a person would open from here.
static func keep(entry: Dictionary, id: String, path_env: String, sys_root := "") -> bool:
	if str(entry.get("Type", "")) != "Application" or str(entry.get("Exec", "")).strip_edges() == "":
		return false
	if _true(entry.get("NoDisplay", "")) or _true(entry.get("Hidden", "")) or _true(entry.get("Terminal", "")):
		return false
	if str(entry.get("OnlyShowIn", "")).strip_edges() != "":
		return false
	if id in SKIP_IDS or id.to_lower().begins_with("gamecove"):
		return false
	var cats := _list(entry.get("Categories", ""))
	if not "Game" in cats:
		for c in cats:
			if c in SKIP_CATEGORIES:
				return false
	var try_exec := str(entry.get("TryExec", "")).strip_edges()
	if try_exec != "":
		var found := FileAccess.file_exists(sys_root + try_exec) if try_exec.begins_with("/") else Common.which(try_exec, path_env) != ""
		if not found:
			return false
	return true


## The command line from Exec, with the field codes the spec defines handled:
## file and URL codes dropped (we open no file), %c the name, %k the file, %%
## a percent sign, %i dropped. Quoting as the spec says (double quotes,
## backslash escapes inside them). [] when it can't be read.
static func exec_argv(exec: String, name := "", file := "") -> Array:
	var words := _split_exec(exec)
	var out: Array = []
	for w in words:
		match w:
			"%f", "%F", "%u", "%U", "%d", "%D", "%n", "%N", "%v", "%m", "%i":
				continue
			"%c":
				if name != "":
					out.append(name)
				continue
			"%k":
				if file != "":
					out.append(file)
				continue
		var s := str(w)
		for code in ["%f", "%F", "%u", "%U", "%i", "%d", "%D", "%n", "%N", "%v", "%m"]:
			s = s.replace(code, "")
		s = s.replace("%c", name).replace("%k", file).replace("%%", "%")
		if s != "":
			out.append(s)
	return out


static func _split_exec(exec: String) -> Array:
	var out: Array = []
	var cur := ""
	var has := false
	var quoted := false
	var i := 0
	while i < exec.length():
		var ch := exec[i]
		if quoted:
			if ch == "\\" and i + 1 < exec.length() and exec[i + 1] in ["\"", "`", "$", "\\"]:
				cur += exec[i + 1]
				i += 2
				continue
			if ch == "\"":
				quoted = false
			else:
				cur += ch
		elif ch == "\"":
			quoted = true
			has = true
		elif ch == " " or ch == "\t":
			if has or cur != "":
				out.append(cur)
			cur = ""
			has = false
		else:
			cur += ch
		i += 1
	if quoted:
		return []
	if has or cur != "":
		out.append(cur)
	return out


## Finds an icon file for the entry's Icon (an absolute path, or a theme name
## looked up in hicolor, then /usr/share/pixmaps). "" when there's none.
static func find_icon(icon: String, roots: Array, sys_root := "") -> String:
	var n := icon.strip_edges()
	if n == "":
		return ""
	if n.begins_with("/"):
		return n if FileAccess.file_exists(sys_root + n) and n.get_extension().to_lower() in ["png", "svg"] else ""
	for root in roots:
		for size in ICON_SIZES:
			for ext in ["png", "svg"]:
				var p: String = str(root).path_join("hicolor").path_join(size).path_join("apps").path_join(n + "." + ext)
				if FileAccess.file_exists(sys_root + p):
					return p
	for ext in ["png", "svg"]:
		var p := "/usr/share/pixmaps/%s.%s" % [n, ext]
		if FileAccess.file_exists(sys_root + p):
			return p
	return ""


## Every app worth listing: [{"key", "id", "store": "app", "title", "exec": [...],
## "icon": source file, "flatpak": id or "", "installed": true, "art": {}}], A to Z.
## env: {"home", "xdg_data_dirs", "path_env", "locale", "sys_root"}.
static func scan(env: Dictionary) -> Array:
	var home := str(env.get("home", ""))
	var xdg := str(env.get("xdg_data_dirs", ""))
	var root := str(env.get("sys_root", ""))
	var path_env := str(env.get("path_env", ""))
	var roots := icon_dirs(home, xdg)
	var seen := {}
	var out: Array = []
	for dir in desktop_dirs(home, xdg):
		var abs: String = root + str(dir)
		if not DirAccess.dir_exists_absolute(abs):
			continue
		for f in DirAccess.get_files_at(abs):
			if not f.ends_with(".desktop"):
				continue
			var id := f.trim_suffix(".desktop")
			if seen.has(id):
				continue
			seen[id] = true   # the first copy decides, even when it hides the app
			var entry := parse_desktop(FileAccess.get_file_as_string(abs.path_join(f)), str(env.get("locale", "")))
			if not keep(entry, id, path_env, root):
				continue
			var title := str(entry.get("Name@local", entry.get("Name", id))).strip_edges()
			var argv := exec_argv(str(entry["Exec"]), title, str(dir).path_join(f))
			if argv.is_empty():
				continue
			var flatpak := str(entry.get("X-Flatpak", ""))
			out.append({"key": STORE + ":" + id, "id": id, "store": STORE, "title": title if title != "" else id,
				"exec": argv, "icon": find_icon(str(entry.get("Icon", "")), roots, root),
				"flatpak": flatpak, "sub": SUB_FLATPAK if flatpak != "" else SUB_APP, "installed": true, "art": {}})
	out.sort_custom(func(a, b): return str(a["title"]).naturalnocasecmp_to(str(b["title"])) < 0)
	return out


## The icon as a PNG in GameCove's cache (SVGs rasterised at ICON_PX), "" when it
## can't be read. Worker thread.
static func cached_icon(app: Dictionary, sys_root := "") -> String:
	var src := str(app.get("icon", ""))
	if src == "":
		return ""
	var out := ProjectSettings.globalize_path(ICON_CACHE).path_join(str(app.get("id", "")).md5_text() + ".png")
	var src_time := FileAccess.get_modified_time(sys_root + src)
	if FileAccess.file_exists(out) and FileAccess.get_modified_time(out) >= src_time:
		return out
	var img := Image.new()
	var err := ERR_FILE_UNRECOGNIZED
	if src.get_extension().to_lower() == "svg":
		var buf := FileAccess.get_file_as_bytes(sys_root + src)
		if not buf.is_empty():
			# render the SVG at its own size first to learn it, then at ICON_PX
			var probe := Image.new()
			if probe.load_svg_from_buffer(buf, 1.0) == OK and probe.get_width() > 0:
				err = img.load_svg_from_buffer(buf, float(ICON_PX) / maxf(1.0, probe.get_width()))
	else:
		err = img.load(sys_root + src)
	if err != OK or img.is_empty():
		return ""
	if img.get_width() > ICON_PX:
		img.resize(ICON_PX, maxi(1, roundi(img.get_height() * float(ICON_PX) / img.get_width())), Image.INTERPOLATE_LANCZOS)
	DirAccess.make_dir_recursive_absolute(out.get_base_dir())
	return out if img.save_png(out) == OK else ""


## What a tile shows for an app: its cached icon as art.icon.
static func with_art(app: Dictionary, icon_png: String) -> Dictionary:
	var a := app.duplicate(true)
	a["art"] = {"icon": icon_png} if icon_png != "" else {}
	return a


# ---- pins -------------------------------------------------------------------------------

## The pinned apps, in the order they were pinned.
static func pinned(path := PINS_PATH) -> Array:
	var r := SettingsFile.load_json(path)
	var d: Variant = r.get("data")
	if not d is Dictionary or not d.get("pinned") is Array:
		return []
	return (d["pinned"] as Array).filter(func(a): return a is Dictionary and str(a.get("key", "")).begins_with(STORE + ":") and a.get("exec") is Array)


static func is_pinned(key: String, path := PINS_PATH) -> bool:
	return pinned(path).any(func(a): return a["key"] == key)


## Pins (true) or unpins (false) `app`. True when saved.
static func set_pinned(app: Dictionary, on: bool, path := PINS_PATH) -> bool:
	var list := pinned(path).filter(func(a): return a["key"] != app.get("key", ""))
	if on:
		var keep_fields := {}
		for k in ["key", "id", "store", "title", "exec", "icon", "flatpak", "sub", "art"]:
			if app.has(k):
				keep_fields[k] = app[k]
		keep_fields["installed"] = true
		list.append(keep_fields)
	return SettingsFile.save_json(path, {"version": 1, "pinned": list}, "\t") == OK


## Pinned apps brought up to date from a fresh scan (title, command, icon);
## ones no longer installed are dropped. Returns the list it saved.
static func refresh_pins(scanned: Array, path := PINS_PATH) -> Array:
	var by_key := {}
	for a in scanned:
		by_key[a["key"]] = a
	var out: Array = []
	var changed := false
	for p in pinned(path):
		if not by_key.has(p["key"]):
			changed = true
			continue
		var fresh: Dictionary = by_key[p["key"]].duplicate(true)
		fresh["art"] = p.get("art", {}) if (fresh.get("art", {}) as Dictionary).is_empty() else fresh["art"]
		if fresh["title"] != p.get("title") or fresh["exec"] != p.get("exec") or fresh.get("art") != p.get("art"):
			changed = true
		out.append(fresh)
	if changed:
		SettingsFile.save_json(path, {"version": 1, "pinned": out}, "\t")
	return out


# ---- launching -------------------------------------------------------------------------

## Gamescope app id for an app (bit 30 set: never a real Steam id; same rule as Library).
static func app_id_for(key: String) -> int:
	return (key.sha256_text().substr(0, 8).hex_to_int() & 0x3FFFFFFF) | 0x40000000


## The full command: a systemd scope named for the app id when the user's
## systemd runs, around GameCove's reaper when it's installed, around the app.
static func launch_command(app: Dictionary, n: int, systemd_run: String, can_scope: bool, reaper: String) -> Dictionary:
	var argv: Array = app.get("exec", []) if app.get("exec") is Array else []
	if argv.is_empty():
		return {"cmd": [], "app_id": 0}
	var id := app_id_for(str(app.get("key", "")))
	var cmd: Array = argv.duplicate()
	if reaper != "":
		cmd = [reaper, "SteamLaunch", "AppId=%d" % id, "--"] + cmd
	if can_scope:
		cmd = [systemd_run, "--user", "--scope", "--collect", "--quiet", "--unit=app-steam-app%d-%d" % [id, n], "--"] + cmd
	var followed := can_scope or reaper != ""
	return {"cmd": cmd, "app_id": id if followed else 0}
