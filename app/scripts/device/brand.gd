extends RefCounted
## Logos for handheld makers, chip makers, stores and launchers.
##
## Two sources, nothing else:
## 1. A logo bundled in res://assets/brand/, only when the owner's own terms let
##    a free, unaffiliated app show it without asking (app/data/brand_logos.json,
##    verdict "allowed"; today only Heroic, GPL-3.0).
## 2. For stores and launchers, the icon the user's own system already has
##    installed, found the way a Linux desktop finds it: the freedesktop
##    "hicolor" theme in the user, Flatpak and system icon dirs, then
##    /usr/share/pixmaps. Nothing is copied or redistributed.
## Makers and chips (MSI, ASUS, Intel, AMD, ...) have neither, so they show text.
##
##   logo_for(maker_or_store) -> bundled res:// path, else system icon path, else ""
##   bundled_logo_for(maker_or_store) -> res:// path or ""
##   system_icon_for(store) -> absolute path or ""
##   notice_for(maker_or_store) -> the notice a bundled logo needs, or ""
##   general_notice() -> "Product and company names are trademarks ..."
##   key_for(name) -> "steam", "msi", ... or "" (case and alias tolerant)
##
## All static, no I/O beyond small stats of icon dirs (first hit is cached per
## session). Show the result unmodified; see display_rules in the JSON.

const DATA_PATH := "res://data/brand_logos.json"
const MAX_ICON_BYTES := 2 * 1024 * 1024
## Sizes tried in hicolor, best first. scalable SVG wins, then big PNGs.
const PNG_SIZES := ["512x512", "256x256", "192x192", "128x128", "96x96", "64x64", "48x48"]

## Tests replace these through set_search_dirs(); "" entries are skipped.
static var _icon_roots: Array = []
static var _pixmap_dirs: Array = []
static var _dirs_set := false
static var _data: Dictionary = {}
static var _alias: Dictionary = {}     # lowercased alias -> key
static var _icon_cache: Dictionary = {} # key -> path ("" = looked, none)


# ---- data -----------------------------------------------------------------------

static func _load() -> void:
	if not _data.is_empty():
		return
	var text := FileAccess.get_file_as_string(DATA_PATH)
	var j := JSON.new()
	if text == "" or j.parse(text) != OK or not j.data is Dictionary:
		_data = {"brands": {}}
		return
	_data = j.data
	if not _data.get("brands") is Dictionary:
		_data["brands"] = {}
	for key in _data["brands"]:
		var e: Variant = _data["brands"][key]
		if not e is Dictionary:
			continue
		_alias[_norm(str(key))] = str(key)
		_alias[_norm(str(e.get("name", "")))] = str(key)
		for a in e.get("aliases", []):
			_alias[_norm(str(a))] = str(key)


static func _norm(s: String) -> String:
	var t := s.strip_edges().to_lower().replace("_", " ")
	while t.contains("  "):
		t = t.replace("  ", " ")
	return t


static func _entry(name: String) -> Dictionary:
	var k := key_for(name)
	return _data["brands"][k] if k != "" else {}


## "MSI", "Micro-Star International Co., Ltd.", "steam", "Heroic" -> table key or "".
static func key_for(name: String) -> String:
	_load()
	var n := _norm(name)
	if n == "":
		return ""
	if _alias.has(n):
		return _alias[n]
	# DMI vendors often carry a suffix: "ASUSTeK COMPUTER INC." already listed,
	# but "AYANEO Ltd" or "GPD Technology" aren't; match on the first word.
	var first := n.split(" ")[0].trim_suffix(",")
	return _alias.get(first, "")


static func general_notice() -> String:
	_load()
	return str(_data.get("general_notice",
		"Product and company names are trademarks of their respective owners; GameCove is not affiliated with or endorsed by them."))


# ---- lookups --------------------------------------------------------------------

## Bundled logo first, then the icon installed on this system, then "".
static func logo_for(maker_or_store: String) -> String:
	var b := bundled_logo_for(maker_or_store)
	return b if b != "" else system_icon_for(maker_or_store)


## Only logos whose owner allows this use (verdict "allowed") and that exist.
static func bundled_logo_for(maker_or_store: String) -> String:
	var e := _entry(maker_or_store)
	if e.is_empty() or str(e.get("verdict", "")) != "allowed":
		return ""
	var p := str(e.get("logo", ""))
	if not p.begins_with("res://assets/brand/") or not ResourceLoader.exists(p):
		return ""
	return p


## The notice a bundled logo must carry (CREDITS.md repeats it), or "".
static func notice_for(maker_or_store: String) -> String:
	if bundled_logo_for(maker_or_store) == "":
		return ""
	return str(_entry(maker_or_store).get("notice", ""))


## The store's or launcher's own icon from the user's system, or "".
static func system_icon_for(store: String) -> String:
	var k := key_for(store)
	if k == "":
		return ""
	if _icon_cache.has(k):
		return _icon_cache[k]
	var found := ""
	for icon_name in _data["brands"][k].get("system_icons", []):
		found = find_icon(str(icon_name))
		if found != "":
			break
	_icon_cache[k] = found
	return found


## freedesktop lookup of one icon name in the hicolor theme, then pixmaps.
static func find_icon(icon_name: String) -> String:
	if not _safe_name(icon_name):
		return ""
	_ensure_dirs()
	for root in _icon_roots:
		if str(root) == "":
			continue
		var base := str(root).path_join("hicolor")
		var hit := _usable(base.path_join("scalable/apps").path_join(icon_name + ".svg"))
		if hit != "":
			return hit
		for size in PNG_SIZES:
			hit = _usable(base.path_join(size).path_join("apps").path_join(icon_name + ".png"))
			if hit != "":
				return hit
	for dir in _pixmap_dirs:
		if str(dir) == "":
			continue
		for ext in [".svg", ".png"]:
			var hit := _usable(str(dir).path_join(icon_name + ext))
			if hit != "":
				return hit
	return ""


## Reverse-DNS or plain names only: no slashes, no "..".
static func _safe_name(icon_name: String) -> bool:
	var re := RegEx.create_from_string("^[A-Za-z0-9][A-Za-z0-9._-]{0,120}$")
	return re.search(icon_name) != null and not icon_name.contains("..")


static func _usable(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var n := f.get_length()
	f.close()
	return path if n > 0 and n <= MAX_ICON_BYTES else ""


# ---- search dirs ----------------------------------------------------------------

## XDG order: user icons, user Flatpak exports, system Flatpak exports, then
## $XDG_DATA_DIRS/icons (default /usr/local/share, /usr/share); pixmaps last.
static func default_icon_roots() -> Array:
	var out: Array = []
	var home := OS.get_environment("HOME")
	var data_home := OS.get_environment("XDG_DATA_HOME")
	if data_home == "" and home != "":
		data_home = home.path_join(".local/share")
	if data_home != "":
		out.append(data_home.path_join("icons"))
	if home != "":
		out.append(home.path_join(".icons"))
		out.append(home.path_join(".local/share/flatpak/exports/share/icons"))
	out.append("/var/lib/flatpak/exports/share/icons")
	var dirs := OS.get_environment("XDG_DATA_DIRS")
	if dirs == "":
		dirs = "/usr/local/share:/usr/share"
	for d in dirs.split(":", false):
		var p := d.path_join("icons")
		if not p in out:
			out.append(p)
	if not "/usr/share/icons" in out:
		out.append("/usr/share/icons")
	return out


static func _ensure_dirs() -> void:
	if _dirs_set:
		return
	_dirs_set = true
	_icon_roots = default_icon_roots()
	_pixmap_dirs = ["/usr/share/pixmaps"]


## Tests: look only here (icon theme roots, pixmap dirs). Clears the cache.
static func set_search_dirs(icon_roots: Array, pixmap_dirs: Array) -> void:
	_icon_roots = icon_roots.duplicate()
	_pixmap_dirs = pixmap_dirs.duplicate()
	_dirs_set = true
	_icon_cache.clear()


## Back to the real system dirs (next lookup re-reads the environment).
static func reset_search_dirs() -> void:
	_dirs_set = false
	_icon_roots = []
	_pixmap_dirs = []
	_icon_cache.clear()
