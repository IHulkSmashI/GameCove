extends RefCounted
## Logos for handheld makers, chip makers, stores and launchers.
##
## Shown only to identify the device, chip, store or launcher (the way Heroic,
## Lutris and Playnite show store logos). Removed for any company that asks:
## app/data/brand_logos.json has one "enabled" flag per brand (the kill switch;
## see docs/BRANDS.md "Logo removal requests").
##
## Order, per brand:
## 1. A logo bundled in res://assets/brand/ (Simple Icons single-colour SVG,
##    unmodified, or the project's own GPL icon for Bottles).
## 2. For stores and launchers, the icon the user's own system already has
##    installed (freedesktop hicolor theme in user, Flatpak and system icon
##    dirs, then /usr/share/pixmaps).
## 3. "" -> the UI shows the name as text.
## A disabled brand ("enabled": false) returns "" from every lookup.
##
##   logo_for(name) -> bundled res:// path, else system icon path, else ""
##   bundled_logo_for(name) -> res:// path or ""
##   system_icon_for(name) -> absolute path or ""
##   is_mono(name) -> true when the bundled logo is one flat colour (tint it)
##   brand_color(name) -> the brand's own colour (Simple Icons hex) or Color(0,0,0,0)
##   logo_texture(name, px, tint) -> Texture2D or null (mono logos filled with tint)
##   notice_for(name) -> the notice a shown logo needs, or ""
##   is_enabled(name) / general_notice() / key_for(name)
##
## All static, no I/O beyond small stats of icon dirs (first hit is cached per
## session). Show the result unmodified apart from a flat tint of mono logos.

const DATA_PATH := "res://data/brand_logos.json"
const BRAND_DIR := "res://assets/brand/"
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
	if _data.is_empty():
		_parse(DATA_PATH)


static func _parse(path: String) -> void:
	_alias = {}
	var text := FileAccess.get_file_as_string(path)
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


## Tests: read another table ("" = the real one again). Clears the icon cache.
static func use_data(path: String) -> void:
	_icon_cache.clear()
	_parse(path if path != "" else DATA_PATH)


## Lower case, "_" and "-" runs as spaces, (R)/(TM) and trailing dots dropped,
## so "Micro-Star International Co., Ltd." and "ONE-NETBOOK" both match.
static func _norm(s: String) -> String:
	var t := s.strip_edges().to_lower().replace("_", " ")
	t = t.replace("(r)", "").replace("(tm)", "").replace("®", "").replace("™", "")
	while t.contains("  "):
		t = t.replace("  ", " ")
	return t.strip_edges()


## Looser form for DMI vendors: only letters and digits.
static func _squash(s: String) -> String:
	var out := ""
	for c in s.to_lower():
		if (c >= "a" and c <= "z") or (c >= "0" and c <= "9"):
			out += c
	return out


static func _entry(name: String) -> Dictionary:
	var k := key_for(name)
	return _data["brands"][k] if k != "" else {}


## Words DMI vendor strings add that never identify the maker.
const _VENDOR_NOISE := ["shenzhen", "co", "co.", "co.,", "ltd", "ltd.", "inc", "inc.",
	"corp", "corp.", "corporation", "technology", "technologies", "computer", "international",
	"limited", "gmbh", "llc", "the"]


## "MSI", "Micro-Star International Co., Ltd.", "LENOVO", "AYA NEO", "ONE-NETBOOK",
## "Shenzhen GPD Technology", "steam", "Heroic" -> table key or "".
static func key_for(name: String) -> String:
	_load()
	var n := _norm(name)
	if n == "":
		return ""
	if _alias.has(n):
		return _alias[n]
	var sq := _squash(n)
	if sq == "":
		return ""
	for a in _alias:
		if _squash(str(a)) == sq:
			return _alias[a]
	# Drop company-form words, then try the remaining words, longest prefix first.
	var words: Array = []
	for w in n.replace(",", " ").split(" ", false):
		if not str(w) in _VENDOR_NOISE:
			words.append(str(w))
	for cut in range(words.size(), 0, -1):
		var head := " ".join(PackedStringArray(words.slice(0, cut)))
		if _alias.has(head):
			return _alias[head]
		var hsq := _squash(head)
		for a in _alias:
			if hsq != "" and _squash(str(a)) == hsq:
				return _alias[a]
	return ""


static func general_notice() -> String:
	_load()
	return str(_data.get("general_notice",
		"Product and company names are trademarks of their respective owners; GameCove is not affiliated with or endorsed by them."))


# ---- lookups --------------------------------------------------------------------

## False for unknown brands and for brands switched off on request.
static func is_enabled(name: String) -> bool:
	var e := _entry(name)
	return not e.is_empty() and e.get("enabled", false) == true


## Bundled logo first, then the icon installed on this system, then "".
static func logo_for(maker_or_store: String) -> String:
	var b := bundled_logo_for(maker_or_store)
	return b if b != "" else system_icon_for(maker_or_store)


## The bundled SVG of an enabled brand, if it ships, else "".
static func bundled_logo_for(maker_or_store: String) -> String:
	if not is_enabled(maker_or_store):
		return ""
	var p := str(_entry(maker_or_store).get("file", ""))
	if not p.begins_with(BRAND_DIR) or p.contains("..") or not p.ends_with(".svg"):
		return ""
	if not (FileAccess.file_exists(p) or ResourceLoader.exists(p)):
		return ""
	return p


## True when the bundled logo is a single flat path meant to be tinted.
static func is_mono(maker_or_store: String) -> bool:
	return bundled_logo_for(maker_or_store) != "" and _entry(maker_or_store).get("mono", false) == true


## The brand's own colour from Simple Icons, or transparent when unknown.
static func brand_color(maker_or_store: String) -> Color:
	var h := str(_entry(maker_or_store).get("hex", ""))
	return Color.from_string("#" + h, Color(0, 0, 0, 0)) if h.length() == 6 else Color(0, 0, 0, 0)


## The bundled logo as a texture px tall. Mono logos are filled with tint (pass
## brand_color() or a theme colour); multi-colour ones ignore it. Falls back to
## the imported texture when the raw SVG isn't readable. null when no logo.
static func logo_texture(maker_or_store: String, px := 64, tint := Color.WHITE) -> Texture2D:
	var p := bundled_logo_for(maker_or_store)
	if p == "":
		return null
	var svg := FileAccess.get_file_as_string(p)
	if svg != "":
		if is_mono(maker_or_store):
			svg = svg.replace("<svg ", "<svg fill=\"#%s\" " % tint.to_html(false))
		var img := Image.new()
		var probe := Image.new()
		if probe.load_svg_from_string(svg, 1.0) == OK and probe.get_height() > 0:
			var scale := clampf(float(px) / probe.get_height(), 0.05, 64.0)
			if img.load_svg_from_string(svg, scale) == OK:
				return ImageTexture.create_from_image(img)
	return load(p) as Texture2D if ResourceLoader.exists(p) else null


## The notice a shown logo must carry (CREDITS.md repeats it), or "".
static func notice_for(maker_or_store: String) -> String:
	if logo_for(maker_or_store) == "":
		return ""
	return str(_entry(maker_or_store).get("notice", ""))


## The store's or launcher's own icon from the user's system, or "".
static func system_icon_for(store: String) -> String:
	var k := key_for(store)
	if k == "" or not is_enabled(k):
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
