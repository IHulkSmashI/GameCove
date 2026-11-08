extends "res://tests/test_case.gd"
## Release calendar: date precision, ordering, days_until, the cached file.

const H := preload("res://tests/fixtures/discover/helpers.gd")
const Cal := preload("res://scripts/discover/calendar.gd")


func _u(s: String) -> int:
	return Time.get_unix_time_from_datetime_string(s)


func test_date_labels_and_periods() -> void:
	var t := _u("2026-12-25T15:00:00")
	eq(Cal.date_label(t, "day"), "2026-12-25", "day")
	eq(Cal.date_label(t, "month"), "2026-12", "month")
	eq(Cal.date_label(t, "quarter"), "2026-Q4", "quarter")
	eq(Cal.date_label(t, "year"), "2026", "year")
	eq(Cal.date_label(t, "tba"), "", "tba")
	eq(Cal.period("2026-02", "month"), [_u("2026-02-01T00:00:00"), _u("2026-02-28T00:00:00")], "February")
	eq(Cal.period("2026-12", "month")[1], _u("2026-12-31T00:00:00"), "December wraps the year")
	eq(Cal.period("2027-Q1", "quarter"), [_u("2027-01-01T00:00:00"), _u("2027-03-31T00:00:00")], "Q1")
	eq(Cal.period("2026-Q4", "quarter")[1], _u("2026-12-31T00:00:00"), "Q4")
	eq(Cal.period("2027", "year")[1], _u("2027-12-31T00:00:00"), "year")
	eq(Cal.period("soon", "day"), [], "bad label")
	eq(Cal.period("2026-11", "day"), [], "label doesn't fit precision")


func test_days_until_and_out() -> void:
	var now := H.now()
	eq(Cal.days_until("2026-11-10", "day", now), 2, "in two days")
	eq(Cal.days_until("2026-11-08", "day", now), 0, "today")
	eq(Cal.days_until("2026-11-01", "day", now), -7, "a week ago")
	eq(Cal.days_until("2026-12", "month", now), null, "unknown day")
	ok(Cal.is_out("2026-11-08", "day", now), "out today")
	ok(not Cal.is_out("2026-11", "month", now), "this month isn't over")
	ok(Cal.is_out("2026-Q3", "quarter", now), "last quarter is over")
	ok(not Cal.is_out("", "tba", now), "tba never out")


func test_releases_from_fixture_sorted_by_precision() -> void:
	var doc := Cal.load_file(H.fx("upcoming.json.gz"))
	eq(int(doc.get("schema", 0)), 1, "fixture read")
	var list := Cal.releases_from(doc, H.now(), {"steam:4530370": true})
	var titles := list.map(func(r): return r["title"])
	eq(titles, ["Out Last Week", "Football Manager 27", "Christmas Day Game", "December Thing",
		"Quarter One", "Next Year", "Broken Date", "Someday"], "calendar order, old entries dropped")
	var fm: Dictionary = list[1]
	eq(fm["key"], "steam:4530370", "key")
	eq(fm["days_until"], 2, "days until")
	eq(fm["released"], false, "not out")
	eq(fm["on_wishlist"], true, "on wishlist")
	eq(fm["link"], {"kind": "steam", "uri": "steam://store/4530370"}, "Steam link")
	ok(fm["art"]["cover"].contains("library_capsule.jpg"), "art passed through")
	eq(fm["date_unix"], _u("2026-11-10T00:00:00"), "date_unix")
	var out_week: Dictionary = list[0]
	eq([out_week["released"], out_week["days_until"]], [true, -7], "out now")
	eq(out_week["link"], {"kind": "url", "uri": "https://www.wikidata.org/wiki/Q1"}, "Wikidata link")
	var dec: Dictionary = list[3]
	eq([dec["precision"], dec["days_until"], dec["link"]], ["month", null, {}], "month entry")
	var broken: Dictionary = list[6]
	eq([broken["precision"], broken["date"], broken["date_unix"]], ["tba", "", null], "bad date becomes TBA")


func test_find_by_id_then_title() -> void:
	var list := Cal.releases_from(Cal.load_file(H.fx("upcoming.json.gz")), H.now())
	eq(Cal.find(list, {"steam": "888"}, "whatever")["title"], "Quarter One", "by Steam id")
	eq(Cal.find(list, {}, "december  THING!")["title"], "December Thing", "by title")
	eq(Cal.find(list, {"steam": "1"}, "nope"), {}, "no match")


func test_bad_files() -> void:
	eq(Cal.parse_gz(PackedByteArray()), {}, "empty")
	eq(Cal.parse_gz("<html>404</html>".to_utf8_buffer()), {}, "html")
	eq(Cal.parse_gz('{"games": []}'.to_utf8_buffer().compress(FileAccess.COMPRESSION_GZIP)), {}, "not an upcoming file")
	eq(Cal.load_file("/nonexistent/upcoming.json.gz"), {}, "missing")
	eq(Cal.releases_from({}, H.now()), [], "nothing")
