extends RefCounted
## The release calendar: reads upcoming.json.gz (built nightly by
## gamedb/gamedb/upcoming.py, published on the rolling "gamedb" release) and
## turns its records into the contract's Release dicts. Static and thread-safe:
## parse_gz runs on a WorkerThreadPool thread.

const Wish := preload("res://scripts/discover/wishlist.gd")

const URL := "https://github.com/IHulkSmashI/GameCove/releases/download/gamedb/upcoming.json.gz"
const MAX_UNPACKED := 16 * 1024 * 1024
const PRECISIONS := ["day", "month", "quarter", "year", "tba"]
const DAY := 86400


## "2026-12-04" / "2026-12" / "2026-Q4" / "2026" / "" for a unix time (UTC).
static func date_label(unix: int, precision: String) -> String:
	if unix <= 0 or precision == "tba":
		return ""
	var d := Time.get_date_dict_from_unix_time(unix)
	match precision:
		"day":
			return "%04d-%02d-%02d" % [d.year, d.month, d.day]
		"month":
			return "%04d-%02d" % [d.year, d.month]
		"quarter":
			return "%04d-Q%d" % [d.year, (d.month - 1) / 3 + 1]
	return "%04d" % d.year


static func _unix(y: int, m: int, d: int) -> int:
	return Time.get_unix_time_from_datetime_dict({"year": y, "month": m, "day": d, "hour": 0, "minute": 0, "second": 0})


## [first_unix, last_unix] (UTC midnights) a date label can mean, or [] for TBA
## or a label that doesn't match its precision.
static func period(label: String, precision: String) -> Array:
	if precision == "tba" or label.length() < 4 or not label.substr(0, 4).is_valid_int():
		return []
	var y := label.substr(0, 4).to_int()
	match precision:
		"day":
			if label.length() != 10:
				return []
			var t := _unix(y, label.substr(5, 2).to_int(), label.substr(8, 2).to_int())
			return [t, t]
		"month":
			if label.length() != 7:
				return []
			var m := label.substr(5, 2).to_int()
			return [_unix(y, m, 1), _unix(y + int(m == 12), m % 12 + 1, 1) - DAY]
		"quarter":
			if label.length() != 7 or label[5] != "Q":
				return []
			var q := label.substr(6, 1).to_int()
			var m0 := (q - 1) * 3 + 1
			var m1 := q * 3
			return [_unix(y, m0, 1), _unix(y + int(m1 == 12), m1 % 12 + 1, 1) - DAY]
		"year":
			return [_unix(y, 1, 1), _unix(y + 1, 1, 1) - DAY]
	return []


static func _today(now: int) -> int:
	return now - now % DAY


## Days from today (UTC) to a day-precision date: 0 today, negative once out.
## null for coarser precision or TBA (we don't know the day).
static func days_until(label: String, precision: String, now: int) -> Variant:
	if precision != "day":
		return null
	var p := period(label, precision)
	return null if p.is_empty() else int((p[0] - _today(now)) / DAY)


## True once the whole period is in the past (a day date: from that day on).
static func is_out(label: String, precision: String, now: int) -> bool:
	var p := period(label, precision)
	if p.is_empty():
		return false
	return p[0] <= now if precision == "day" else p[1] + DAY <= now


## A Release dict (see CONTRACTS.md) from an upcoming.json.gz record.
## `wishlist_keys` holds wishlist keys so on_wishlist is filled in.
static func make_release(rec: Dictionary, now: int, wishlist_keys := {}) -> Dictionary:
	var ids := {}
	if rec.get("ids") is Dictionary:
		for k in rec["ids"]:
			ids[str(k)] = str(rec["ids"][k])
	var precision: String = rec.get("precision", "tba")
	if not precision in PRECISIONS:
		precision = "tba"
	var label: String = str(rec.get("date", ""))
	var p := period(label, precision)
	if p.is_empty():
		precision = "tba"
		label = ""
	var art := {"cover": "", "hero": "", "header": ""}
	if rec.get("art") is Dictionary:
		for k in rec["art"]:
			art[str(k)] = str(rec["art"][k])
	var title: String = str(rec.get("title", ""))
	var key := Wish.key_for(ids, title)
	var link := {}
	if ids.has("steam") and preload("res://scripts/steam/app_id.gd").valid(ids["steam"]):
		link = {"kind": "steam", "uri": "steam://store/" + ids["steam"]}
	elif ids.has("epic") and RegEx.create_from_string("^[a-z0-9-]+$").search(ids["epic"]):
		# A store page we build ourselves: the only kind of link affiliates.gd may touch.
		link = {"kind": "url", "uri": "https://store.epicgames.com/p/" + ids["epic"], "store": "epic"}
	elif ids.has("wikidata"):
		link = {"kind": "url", "uri": "https://www.wikidata.org/wiki/" + ids["wikidata"]}
	var out := {
		"key": key, "title": title, "date": label, "precision": precision,
		"date_unix": p[0] if not p.is_empty() else null,
		"days_until": days_until(label, precision, now),
		"released": is_out(label, precision, now),
		"ids": ids, "art": art, "link": link,
		"sources": rec.get("sources", []) if rec.get("sources") is Array else [],
		"on_wishlist": wishlist_keys.has(key),
	}
	return out


## Calendar order: by the last day a release can fall on, so "December 2026"
## comes after every known December day; within that, finer precision first;
## TBA last; then title.
static func sort_releases(list: Array) -> void:
	list.sort_custom(func(a, b):
		var pa := period(a["date"], a["precision"])
		var pb := period(b["date"], b["precision"])
		if pa.is_empty() != pb.is_empty():
			return not pa.is_empty()
		if not pa.is_empty() and pa[1] != pb[1]:
			return pa[1] < pb[1]
		var ia := PRECISIONS.find(a["precision"])
		var ib := PRECISIONS.find(b["precision"])
		if ia != ib:
			return ia < ib
		return a["title"].naturalnocasecmp_to(b["title"]) < 0)


## The upcoming document from gzip bytes, or {} if they aren't a valid one.
static func parse_gz(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < 18 or bytes[0] != 0x1f or bytes[1] != 0x8b:
		return {}
	var raw := bytes.decompress_dynamic(MAX_UNPACKED, FileAccess.COMPRESSION_GZIP)
	if raw.is_empty():
		return {}
	var j := JSON.new()
	if j.parse(raw.get_string_from_utf8()) != OK or not j.data is Dictionary:
		return {}
	return j.data if j.data.get("releases") is Array else {}


static func load_file(path: String) -> Dictionary:
	return parse_gz(FileAccess.get_file_as_bytes(path)) if FileAccess.file_exists(path) else {}


## Sorted Release dicts from a document, dropping entries out for more than
## `keep_days` (the nightly already does; this covers an old cached file).
static func releases_from(doc: Dictionary, now: int, wishlist_keys := {}, keep_days := 14) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for rec in doc.get("releases", []):
		if not rec is Dictionary or str(rec.get("title", "")) == "":
			continue
		var r := make_release(rec, now, wishlist_keys)
		var p := period(r["date"], r["precision"])
		if not p.is_empty() and p[1] < _today(now) - keep_days * DAY:
			continue
		out.append(r)
	sort_releases(out)
	return out


## Calendar entry for a game, matched by Steam id first, then normalised title.
static func find(list: Array, ids: Dictionary, title: String) -> Dictionary:
	var steam := str(ids.get("steam", ""))
	var t := Wish.normalise(title)
	var by_title := {}
	for r in list:
		if steam != "" and str(r["ids"].get("steam", "")) == steam:
			return r
		if t != "" and by_title.is_empty() and Wish.normalise(r["title"]) == t:
			by_title = r
	return by_title
