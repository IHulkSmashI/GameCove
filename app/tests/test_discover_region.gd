extends "res://tests/test_case.gd"
## Store-country detection order: Steam files, time zone, locale, default.

const H := preload("res://tests/fixtures/discover/helpers.gd")
const Region := preload("res://scripts/discover/region.gd")


func _zone_files() -> Array:
	return [H.fx("region/zone.tab"), H.fx("region/zone1970.tab")]


func test_steam_file_wins() -> void:
	var r := Region.detect(H.fx("region/home_config"), "Europe/Berlin", "de_DE.UTF-8", _zone_files())
	eq(r, {"country": "CA", "source": "steam"}, "config.vdf key beats time zone and locale")
	r = Region.detect(H.fx("region/home_userdata"), "America/Toronto", "en_CA", _zone_files())
	eq(r, {"country": "GB", "source": "steam"}, "localconfig.vdf under ~/.steam/steam/userdata, lowercase value")


func test_non_code_values_are_ignored() -> void:
	eq(Region.steam_country(H.fx("region/home_none")), "", "\"Country\" \"Canada\" isn't a code")
	var r := Region.detect(H.fx("region/home_none"), "America/Toronto", "en_US.UTF-8", _zone_files())
	eq(r, {"country": "CA", "source": "timezone"}, "time zone beats an en_US locale")


func test_time_zone_then_locale_then_default() -> void:
	var none := "/nonexistent"
	eq(Region.detect(none, "America/New_York", "", _zone_files()), {"country": "US", "source": "timezone"}, "zone.tab")
	eq(Region.detect(none, "Europe/Brussels", "", _zone_files()), {"country": "NL", "source": "timezone"}, "zone1970.tab first code")
	eq(Region.detect(none, "America/Vancouver", "", []), {"country": "CA", "source": "timezone"}, "built-in table without tzdata")
	eq(Region.detect(none, "Mars/Olympus", "fr_CA.UTF-8", []), {"country": "CA", "source": "locale"}, "locale")
	eq(Region.country_from_locale("C"), "", "C locale has no country")
	eq(Region.country_from_locale("sr_RS@latin"), "RS", "modifier stripped")
	eq(Region.zone_from_path("../usr/share/zoneinfo/America/Toronto"), "America/Toronto", "localtime link")
	eq(Region.zone_from_path("/etc/foo"), "", "not a zoneinfo path")


func test_find_country_nested() -> void:
	eq(Region.find_country({"a": {"b": {"storecountry": "fr"}}}), "FR", "nested, upper-cased")
	eq(Region.find_country({"country": "USA"}), "", "three letters rejected")
	eq(Region.find_country({"name": "CA"}), "", "only known keys")
