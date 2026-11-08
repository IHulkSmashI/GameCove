extends RefCounted
## Which store country to price for, detected in this order:
##   1. Steam's own local files: config/config.vdf, registry.vdf (next to the
##      Steam root and in ~/.steam), config/loginusers.vdf and
##      userdata/<id>/config/localconfig.vdf are searched for a store-country
##      key (STEAM_KEYS) holding a two-letter code. Valve doesn't document such
##      a key, so this is best effort and checked on a real install.
##   2. The system time zone (/etc/localtime -> America/Toronto -> CA) through
##      tzdata's zone.tab / zone1970.tab, with a small built-in table when
##      those files are missing.
##   3. The locale's country (LANG=en_CA.UTF-8 -> CA).
##   4. "US".
## The user's choice in settings always wins (Discover handles that).
## Static, reads local files only, never the network.

const Steam := preload("res://scripts/library/stores/steam.gd")

## Keys (lowercased, as Steam.parse_vdf gives them) that may hold the
## account's store country.
const STEAM_KEYS := ["storecountry", "ipcountry", "walletcountry", "countrycode", "country", "steamcountry"]
const ZONE_FILES := ["/usr/share/zoneinfo/zone.tab", "/usr/share/zoneinfo/zone1970.tab"]
const FALLBACK_ZONES := {
	"America/Toronto": "CA", "America/Vancouver": "CA", "America/Edmonton": "CA", "America/Winnipeg": "CA",
	"America/Halifax": "CA", "America/St_Johns": "CA", "America/Regina": "CA",
	"America/New_York": "US", "America/Chicago": "US", "America/Denver": "US", "America/Los_Angeles": "US",
	"America/Phoenix": "US", "America/Anchorage": "US", "Pacific/Honolulu": "US",
	"Europe/London": "GB", "Europe/Berlin": "DE", "Europe/Paris": "FR", "Europe/Madrid": "ES",
	"Europe/Rome": "IT", "Europe/Amsterdam": "NL", "Europe/Warsaw": "PL", "Australia/Sydney": "AU",
	"Australia/Melbourne": "AU", "Pacific/Auckland": "NZ", "Asia/Tokyo": "JP", "America/Sao_Paulo": "BR",
	"America/Mexico_City": "MX",
}


## {"country": "CA", "source": "steam" | "timezone" | "locale" | "default"}.
## `tz` and `locale` default to the system's; tests pass them.
static func detect(home: String, tz := "", locale := "", zone_files: Array = ZONE_FILES) -> Dictionary:
	var c := steam_country(home)
	if c != "":
		return {"country": c, "source": "steam"}
	var zone := tz if tz != "" else system_time_zone()
	c = country_for_zone(zone, zone_files)
	if c != "":
		return {"country": c, "source": "timezone"}
	c = country_from_locale(locale if locale != "" else _system_locale())
	if c != "":
		return {"country": c, "source": "locale"}
	return {"country": "US", "source": "default"}


static func _valid(code: String) -> bool:
	return code.length() == 2 and code.to_upper() == code and RegEx.create_from_string("^[A-Z]{2}$").search(code) != null


## A store-country value found in a parsed VDF tree, or "".
static func find_country(tree: Variant) -> String:
	if not tree is Dictionary:
		return ""
	for k in tree:
		var v = tree[k]
		if v is String and str(k) in STEAM_KEYS and _valid(v.strip_edges().to_upper()) and v.strip_edges().length() == 2:
			return v.strip_edges().to_upper()
	for k in tree:
		if tree[k] is Dictionary:
			var found := find_country(tree[k])
			if found != "":
				return found
	return ""


## The files we look in under one Steam root (plus ~/.steam/registry.vdf).
static func steam_files(home: String) -> Array[String]:
	var out: Array[String] = []
	for root in Steam.STEAM_ROOTS:
		var r := Steam.expand(root, home)
		if not DirAccess.dir_exists_absolute(r):
			continue
		for rel in ["config/config.vdf", "registry.vdf", "config/loginusers.vdf"]:
			out.append(r.path_join(rel))
		var ud := DirAccess.open(r.path_join("userdata"))
		if ud != null:
			for u in ud.get_directories():
				out.append(r.path_join("userdata").path_join(u).path_join("config/localconfig.vdf"))
	out.append(home.path_join(".steam/registry.vdf"))
	return out


static func steam_country(home: String) -> String:
	if home == "":
		return ""
	for f in steam_files(home):
		if not FileAccess.file_exists(f):
			continue
		var c := find_country(Steam.parse_vdf(FileAccess.get_file_as_string(f)))
		if c != "":
			return c
	return ""


## "America/Toronto" from $TZ or the /etc/localtime link, or "".
static func system_time_zone() -> String:
	var tz := OS.get_environment("TZ").trim_prefix(":")
	if tz.contains("/"):
		return tz
	var d := DirAccess.open("/etc")
	if d != null and d.is_link("/etc/localtime"):
		return zone_from_path(d.read_link("/etc/localtime"))
	if FileAccess.file_exists("/etc/timezone"):
		return FileAccess.get_file_as_string("/etc/timezone").strip_edges()
	return ""


## "../usr/share/zoneinfo/America/Toronto" -> "America/Toronto".
static func zone_from_path(path: String) -> String:
	var i := path.find("zoneinfo/")
	return path.substr(i + 9) if i != -1 else ""


## Country of a time zone from tzdata tables (first code in zone1970.tab rows
## that list several), then the built-in table; "" when unknown.
static func country_for_zone(zone: String, zone_files: Array = ZONE_FILES) -> String:
	if zone == "":
		return ""
	for f in zone_files:
		if not FileAccess.file_exists(f):
			continue
		for line in FileAccess.get_file_as_string(f).split("\n"):
			if line.begins_with("#"):
				continue
			var cols := line.split("\t")
			if cols.size() >= 3 and cols[2] == zone:
				var code := cols[0].split(",")[0]
				if _valid(code):
					return code
	return FALLBACK_ZONES.get(zone, "")


static func _system_locale() -> String:
	for v in ["LC_ALL", "LC_MONETARY", "LANG"]:
		var s := OS.get_environment(v)
		if s != "" and s != "C" and s != "POSIX":
			return s
	return OS.get_locale()


## "en_CA.UTF-8" -> "CA"; "" without a country part.
static func country_from_locale(locale: String) -> String:
	var parts := locale.split(".")[0].split("@")[0].split("_")
	if parts.size() >= 2 and _valid(parts[1].to_upper()) and parts[1].length() == 2:
		return parts[1].to_upper()
	return ""
