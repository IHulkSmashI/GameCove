extends Node
## Discover: deals, prices across stores, wishlist with price and release
## alerts, and the release calendar. See docs/CONTRACTS.md ("Discover") for
## the exact API and the Deal / Release / wishlist item shapes.
##
## Sources (terms in CREDITS.md): CheapShark (which stores have a game on sale,
## links, US prices and lows), Steam's keyless store and wishlist endpoints
## (prices for the user's country, sale end, art, release state) and the
## nightly upcoming.json.gz (calendar). No API keys ship with GameCove.
## Every price shown is a store's own price for the user's country; rows
## without one say "See price" (prices.gd). The country comes from settings,
## else region.gd's detection (Steam files, time zone, locale).
##
## Network: every request goes through `http` (http.gd: threaded HTTPRequest,
## timeouts, per-host backoff; fake_http.gd in tests). A refresh makes a
## handful of requests at most and runs no more than every 6 h, never while a
## game is running (pause()/resume() or game_running), and the calendar file is
## fetched at most daily. Nothing personal is sent: the only user data that
## leaves the device is the Steam profile id/name sent to Steam on import.
## Everything is cached under user://discover/ and works offline.
## Signals are always emitted on the main thread.

signal deals_changed
signal calendar_changed
signal wishlist_changed
signal settings_changed
signal prices_ready(game_key: String, deals: Array)
signal search_done(query: String, results: Array)
signal import_done(ok: bool, added: int, error: String)
signal price_alert(item: Dictionary, deal: Dictionary)
signal release_alert(item: Dictionary)
signal status_changed(source: String, status: String)

const Http := preload("res://scripts/discover/http.gd")
const CheapShark := preload("res://scripts/discover/cheapshark.gd")
const SteamApi := preload("res://scripts/discover/steam_api.gd")
const Prices := preload("res://scripts/discover/prices.gd")
const Money := preload("res://scripts/discover/money.gd")
const Cal := preload("res://scripts/discover/calendar.gd")
const Wish := preload("res://scripts/discover/wishlist.gd")
const Alerts := preload("res://scripts/discover/alerts.gd")
const Region := preload("res://scripts/discover/region.gd")
const GG := preload("res://scripts/discover/ggdeals.gd")
const Affiliates := preload("res://scripts/discover/affiliates.gd")
const Privacy := preload("res://scripts/system/privacy.gd")

const REFRESH_EVERY := 6 * 3600
const CALENDAR_EVERY := 24 * 3600
const STORES_EVERY := 7 * 86400
const FIRST_CHECK_S := 45.0
const CHECK_EVERY_S := 900.0
const TOP_DEALS := 30
const MAX_RESOLVE := 5          # CheapShark id lookups per refresh
const MAX_LOOKUP_BATCHES := 2   # x25 games
const MAX_STEAM_BATCHES := 3    # x50 apps
const MAX_IMPORT_BATCHES := 10  # x50 titles on import
const GG_EVERY := 6 * 3600      # GG.deals prices are cached this long
const INBOX_MAX := 50

const DEFAULT_SETTINGS := {
	"country": "",            # ISO code; "" = detected (region.gd); the currency follows it
	"steam_id": "",           # 64-bit id or custom URL name, for wishlist import
	"steamgriddb_key": "",    # the user's own SteamGridDB API key (optional)
	"ggdeals_key": "",        # the user's own GG.deals API key (optional)
	"ggdeals_keyshops": false, # also show GG.deals key-shop prices
	"price_lookups": true,    # "Look up deals and prices": CheapShark, Steam store and GG.deals calls (review M22)
	"alerts": true,           # master switch for price and release alerts
	"affiliate_links": true,  # allow affiliate ids on links we build (none configured yet)
}
## Label and one-line help for each setting, for the Settings screen and the
## setup steps ("setup": true = offered during first-run setup).
const SETTINGS_INFO := {
	"country": {"label": "Store country", "help": "Prices are shown as the stores charge them in this country. Leave empty to detect it.", "setup": true},
	"steam_id": {"label": "Steam profile", "help": "Your profile link or name, to import your Steam wishlist (needs public game details).", "setup": true},
	"ggdeals_key": {"label": "gg.deals key (optional)", "help": "For real local prices from every store. Free at gg.deals/api; stays on this device.", "setup": true},
	"ggdeals_keyshops": {"label": "Show key-shop prices", "help": GG.KEYSHOP_NOTE, "setup": false},
	"steamgriddb_key": {"label": "SteamGridDB key (optional)", "help": "Artwork for games Steam has none for. Free at steamgriddb.com; stays on this device.", "setup": false},
	"price_lookups": {"label": "Look up deals and prices", "help": "Sends the Steam app ids and titles on your wishlist and on game pages you open (and what you search for) to CheapShark and the Steam store, with your store country, to show deals and prices. Off: Discover shows no prices and nothing is sent.", "setup": false},
	"alerts": {"label": "Price and release alerts", "help": "Tell me when a wishlisted game drops in price or comes out. Checks every 6 hours, never while you play.", "setup": false},
	"affiliate_links": {"label": "Affiliate links", "help": "On by default. Some store links we build can carry a GameCove affiliate id, marked \"Supports GameCove\" (none are set up yet). Prices don't change, and nothing about you is sent.", "setup": false},
}

## http.gd node (made in start()) or a fake_http.gd object in tests.
var http: Variant = null
var data_dir := "user://discover"
## Home folder Steam's files are read from for region detection.
var home := OS.get_environment("HOME")
## Region detection result {"country", "source"}; filled on first use, tests may set it.
var detected_region := {}
## The "Background lookups" switch (Privacy, user://settings.cfg); tests point it at their own file.
var privacy_path := Privacy.PREFS_PATH
## Unix time source; tests replace it.
var clock: Callable = func() -> int: return int(Time.get_unix_time_from_system())
## Parse the calendar file on a worker thread (false in tests: synchronous).
var threaded := false

## Current top deals (Deal dicts), best first.
var deals: Array[Dictionary] = []
## source -> "ok" | "offline" | "rate_limited" | "missing" | "error: <why>"
var status := {}
## Alerts not yet marked seen, newest first: {"id", "kind", "key", "title", "at", ...}.
var alerts_inbox: Array[Dictionary] = []
## Wishlist items with live fields, newest first (see CONTRACTS.md).
var wishlist: Array[Dictionary]:
	get: return _wishlist_view()
## Upcoming releases, calendar order; days_until is computed for today.
var calendar: Array[Dictionary]:
	get: return _calendar_view()
## True while a game has focus: no background refresh. Same as pause()/resume().
var game_running := false:
	set(v):
		game_running = v
		if not v and _pending:
			_pending = false
			refresh()

var _settings := DEFAULT_SETTINGS.duplicate()
var _items := {}            # key -> stored wishlist item
var _state := {"seen": {}, "last_refresh": 0, "last_calendar": 0, "last_stores": 0, "cs_ids": {}, "last_prices": {}}
var _cache := {"stores": {}, "steam": {}, "lookup": {}, "top": [], "gg": {}}
## Store -> affiliate config (res://data/affiliates.json); tests replace it.
var affiliates := Affiliates.load_file()
var _upcoming := {}         # parsed upcoming.json.gz
var _cal_list: Array[Dictionary] = []
var _cal_day := -1
var _busy := false
var _again := false
var _pending := false
var _paused := false
var _task := -1
var _timer: Timer


func _ready() -> void:
	var main_script = get_tree().get_script()
	if main_script != null and str(main_script.resource_path).begins_with("res://tests/"):
		return
	start()


## Real start-up: loads the caches (calendar parsed on a worker thread), makes
## the http node and a timer whose first check is FIRST_CHECK_S after start-up.
func start() -> void:
	var node := Http.new()
	node.name = "Http"
	add_child(node)
	http = node
	threaded = true
	load_all()
	_timer = Timer.new()
	_timer.one_shot = false
	_timer.wait_time = FIRST_CHECK_S
	_timer.timeout.connect(_tick)
	add_child(_timer)
	_timer.start()


func _tick() -> void:
	_timer.wait_time = CHECK_EVERY_S
	refresh()


## Deals and prices may be looked up (the "Look up deals and prices" switch).
func prices_allowed() -> bool:
	return bool(_settings.get("price_lookups", true))


func _exit_tree() -> void:
	if _task != -1:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1


func _now() -> int:
	return int(clock.call())


# ---- settings ---------------------------------------------------------------

## A copy of the settings plus the resolved "country_effective",
## "country_source" ("settings" | "steam" | "timezone" | "locale" | "default")
## and "currency_effective".
func get_settings() -> Dictionary:
	var s := _settings.duplicate()
	s["country_effective"] = country()
	s["country_source"] = country_source()
	s["currency_effective"] = user_currency()
	return s


## Merges `patch` into the settings (unknown keys ignored), saves, emits
## settings_changed. Changing country or currency rebuilds prices from cache.
func set_settings(patch: Dictionary) -> void:
	var money_changed := false
	for k in patch:
		if DEFAULT_SETTINGS.has(k):
			var v = patch[k]
			v = bool(v) if DEFAULT_SETTINGS[k] is bool else str(v).strip_edges()
			if k in ["country", "ggdeals_key", "ggdeals_keyshops", "price_lookups"] and v != _settings[k]:
				money_changed = true
			_settings[k] = v
	if money_changed:
		_cache["steam"] = {}   # Steam prices are per country
		_cache["gg"] = {}      # so are GG.deals'
		_cal_day = -1
		_state["last_refresh"] = 0
	_save("settings.json", _settings)
	settings_changed.emit()
	if money_changed:
		_rebuild_deals()
		deals_changed.emit()
		wishlist_changed.emit()


func _region() -> Dictionary:
	if detected_region.is_empty():
		detected_region = Region.detect(home)
	return detected_region


## The store country prices are for: settings, else detected.
func country() -> String:
	var c: String = _settings.get("country", "")
	return c.to_upper() if c.length() == 2 else str(_region().get("country", "US"))


func country_source() -> String:
	return "settings" if str(_settings.get("country", "")).length() == 2 else str(_region().get("source", "default"))


## The country's Steam currency (prices are never converted).
func user_currency() -> String:
	return Money.currency_for_country(country())


func _ctx() -> Dictionary:
	return {"country": country(), "currency": user_currency(), "wishlist": _items,
		"keyshops": bool(_settings.get("ggdeals_keyshops", false))}


func _gg_key() -> String:
	return str(_settings.get("ggdeals_key", ""))


func _gg_region() -> String:
	return GG.region_for(country())


## GG.deals entry for an app if it's for the current region, else null.
func _gg(appid: String) -> Variant:
	var g = _cache["gg"].get(appid, null)
	return g if g is Dictionary and g.get("region", "") == _gg_region() and _gg_key() != "" else null


## Credits the UI must show (with an active link) wherever Discover prices
## appear: [{"text", "url"}]. GG.deals is listed whenever its data is in use.
func attributions() -> Array:
	var out := [{"text": "Price data by CheapShark", "url": "https://www.cheapshark.com/"}]
	if _gg_key() != "" and not _cache["gg"].is_empty():
		out.append(GG.ATTRIBUTION)
	return out


# ---- pause / resume ---------------------------------------------------------

## No background refresh until resume(); a refresh that came due meanwhile runs then.
func pause() -> void:
	_paused = true


func resume() -> void:
	_paused = false
	if _pending and not game_running:
		_pending = false
		refresh()


func is_paused() -> bool:
	return _paused or game_running


# ---- persistence ------------------------------------------------------------

func _path(name: String) -> String:
	return data_dir.path_join(name)


func _save(name: String, data: Variant) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(data_dir))
	var tmp := _path(name + ".tmp")
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return
	f.close()
	# only this user can read Discover's files: settings.json holds the user's API keys (review L32)
	FileAccess.set_unix_permissions(ProjectSettings.globalize_path(tmp), FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER)
	f = FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(data))
	f.close()
	FileAccess.set_unix_permissions(ProjectSettings.globalize_path(tmp), FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER)
	DirAccess.rename_absolute(ProjectSettings.globalize_path(tmp), ProjectSettings.globalize_path(_path(name)))


func _load(name: String) -> Variant:
	var p := _path(name)
	if not FileAccess.file_exists(p):
		return null
	var j := JSON.new()
	return j.data if j.parse(FileAccess.get_file_as_string(p)) == OK else null


## Reads settings, wishlist, alert state, caches and the cached calendar.
func load_all() -> void:
	var s = _load("settings.json")
	if s is Dictionary:
		for k in DEFAULT_SETTINGS:
			if s.has(k):
				_settings[k] = s[k]
	var w = _load("wishlist.json")
	_items = {}
	if w is Dictionary and w.get("items") is Array:
		for it in w["items"]:
			if it is Dictionary:
				var item := Wish.make_item(it, _now())
				_items[item["key"]] = item
	var st = _load("state.json")
	if st is Dictionary:
		for k in _state:
			if not st.has(k):
				continue
			if _state[k] is int and (st[k] is float or st[k] is int):
				_state[k] = int(st[k])
			elif typeof(st[k]) == typeof(_state[k]):
				_state[k] = st[k]
		if st.get("inbox") is Array:
			alerts_inbox.assign(st["inbox"].filter(func(a): return a is Dictionary))
	var c = _load("cache.json")
	if c is Dictionary:
		for k in _cache:
			if c.has(k) and typeof(c[k]) == typeof(_cache[k]):
				_cache[k] = c[k]
	var cal_path := ProjectSettings.globalize_path(_path("upcoming.json.gz"))
	if threaded and FileAccess.file_exists(cal_path):
		_task = WorkerThreadPool.add_task(func(): _calendar_loaded.call_deferred(Cal.load_file(cal_path), false),
			false, "Discover calendar")
	else:
		_upcoming = Cal.load_file(cal_path)
		_cal_day = -1
	_rebuild_deals()


func _calendar_loaded(doc: Dictionary, _fresh: bool) -> void:
	if _task != -1:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	if not doc.is_empty():
		_upcoming = doc
		_cal_day = -1
		calendar_changed.emit()


func _save_state() -> void:
	var st := _state.duplicate()
	st["inbox"] = alerts_inbox
	_save("state.json", st)


func _save_wishlist() -> void:
	var list := []
	for k in _items:
		list.append(_items[k])
	_save("wishlist.json", {"items": list})


func _set_status(source: String, value: String) -> void:
	if status.get(source, "") != value:
		status[source] = value
		status_changed.emit(source, value)


static func _status_from(res: Dictionary) -> String:
	if res.get("ok", false):
		return "ok"
	var e: String = res.get("error", "")
	if e in ["offline", "backoff", "timeout"]:
		return "offline"
	if int(res.get("code", 0)) == 429:
		return "rate_limited"
	if int(res.get("code", 0)) == 404:
		return "missing"
	return "error: " + e


# ---- refresh pipeline -------------------------------------------------------

## Refreshes what's due: deals and wishlist prices every 6 h, the calendar
## file daily. force := true ignores those ages (and a pause). Returns false
## when nothing started (busy, paused, or nothing due). Results arrive through
## deals_changed / wishlist_changed / calendar_changed and the alert signals.
func refresh(force := false) -> bool:
	if http == null:
		return false
	if _busy:
		_again = _again or force
		return false
	if is_paused() and not force:
		_pending = true
		return false
	if not force and not Privacy.background_allowed(privacy_path):
		return false   # "Background lookups" off: only what the user asks for
	var now := _now()
	var due := prices_allowed() and (force or now - int(_state["last_refresh"]) >= REFRESH_EVERY)
	var cal_due := force or now - int(_state["last_calendar"]) >= CALENDAR_EVERY
	if not due and not cal_due:
		return false
	_busy = true
	var steps: Array[Callable] = []
	if cal_due:
		steps.append(_step_calendar)
	if due:
		steps.append_array([_step_stores, _step_deals, _step_resolve, _step_lookup, _step_steam, _step_ggdeals])
	steps.append(_step_finish.bind(due))
	_run(steps)
	return true


func _run(steps: Array[Callable]) -> void:
	if steps.is_empty():
		return
	var s: Callable = steps.pop_front()
	s.call(func(): _run(steps))


func _step_calendar(next: Callable) -> void:
	var path := ProjectSettings.globalize_path(_path("upcoming.json.gz"))
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var part := path + ".part"
	http.request(Cal.URL, {"download_file": part, "timeout": 60.0}, func(res: Dictionary):
		var st := _status_from(res)
		if st != "offline":
			_state["last_calendar"] = _now()   # 404 too: the file doesn't exist yet, ask tomorrow
		if not res["ok"]:
			if FileAccess.file_exists(part):
				DirAccess.remove_absolute(part)
			_set_status("calendar", st)
			next.call()
			return
		var finish := func(doc: Dictionary):
			if doc.is_empty():
				DirAccess.remove_absolute(part)
				_set_status("calendar", "error: unreadable file")
			else:
				DirAccess.rename_absolute(part, path)
				_set_status("calendar", "ok")
				_calendar_loaded(doc, false)
			next.call()
		if threaded:
			if _task != -1:   # the start-up parse of the old copy; it's quick
				WorkerThreadPool.wait_for_task_completion(_task)
			_task = WorkerThreadPool.add_task(func(): finish.call_deferred(Cal.load_file(part)), false, "Discover calendar")
		else:
			finish.call(Cal.load_file(part)))


func _step_stores(next: Callable) -> void:
	if not _cache["stores"].is_empty() and _now() - int(_state["last_stores"]) < STORES_EVERY:
		next.call()
		return
	http.request(CheapShark.stores_url(), {}, func(res: Dictionary):
		if res["ok"]:
			var s := CheapShark.parse_stores(res["body"])
			if not s.is_empty():
				_cache["stores"] = s
				_state["last_stores"] = _now()
		next.call())


func _step_deals(next: Callable) -> void:
	http.request(CheapShark.deals_url(TOP_DEALS), {}, func(res: Dictionary):
		var parsed = CheapShark.parse_deals(res["body"]) if res["ok"] else null
		if parsed != null:
			_cache["top"] = parsed
			_cache["top_at"] = _now()
			_set_status("cheapshark", "ok")
		else:
			_set_status("cheapshark", _status_from(res) if not res["ok"] else "error: unreadable answer")
		next.call())


## Finds CheapShark game ids for wishlist items that don't have one yet, a few
## per refresh; "" is remembered for games CheapShark doesn't list.
func _step_resolve(next: Callable) -> void:
	var todo: Array = []
	for key in _items:
		var it: Dictionary = _items[key]
		if it["ids"].has("cheapshark"):
			continue
		var memo: String = "steam:" + it["ids"]["steam"] if it["ids"].has("steam") else "title:" + Wish.normalise(it["title"])
		if not _state["cs_ids"].has(memo) and (it["ids"].has("steam") or it["title"] != ""):
			todo.append(key)
	_resolve_some(todo.slice(0, MAX_RESOLVE), next)


func _resolve_some(keys: Array, next: Callable) -> void:
	if keys.is_empty():
		next.call()
		return
	var key: String = keys.pop_front()
	if not _items.has(key):
		_resolve_some(keys, next)
		return
	var it: Dictionary = _items[key]
	var steam: String = it["ids"].get("steam", "")
	var url := CheapShark.by_steam_url(steam) if steam != "" else CheapShark.search_url(it["title"], 5)
	var memo := "steam:" + steam if steam != "" else "title:" + Wish.normalise(it["title"])
	http.request(url, {}, func(res: Dictionary):
		var found = CheapShark.parse_search(res["body"]) if res["ok"] else null
		if found == null:
			next.call()   # offline or failing: stop resolving for this refresh
			return
		var gid := ""
		for g in found:
			if (steam != "" and g["appid"] == steam) or (steam == "" and Wish.normalise(g["title"]) == Wish.normalise(it["title"])):
				gid = g["game_id"]
				break
		if gid == "" and steam != "" and found.size() == 1:
			gid = found[0]["game_id"]
		_state["cs_ids"][memo] = gid
		if gid != "" and _items.has(key):
			_items[key]["ids"]["cheapshark"] = gid
		_resolve_some(keys, next))


func _cs_id_for(ids: Dictionary, title: String) -> String:
	if str(ids.get("cheapshark", "")) != "":
		return str(ids["cheapshark"])
	var memo: String = "steam:" + str(ids["steam"]) if str(ids.get("steam", "")) != "" else "title:" + Wish.normalise(title)
	return str(_state["cs_ids"].get(memo, ""))


func _step_lookup(next: Callable) -> void:
	var gids: Array = []
	for key in _items:
		var gid := _cs_id_for(_items[key]["ids"], _items[key]["title"])
		if gid != "" and not gid in gids:
			gids.append(gid)
	var batches: Array = []
	var i := 0
	while i < gids.size() and batches.size() < MAX_LOOKUP_BATCHES:
		batches.append(gids.slice(i, i + CheapShark.LOOKUP_BATCH))
		i += CheapShark.LOOKUP_BATCH
	_lookup_batches(batches, next)


func _lookup_batches(batches: Array, next: Callable) -> void:
	if batches.is_empty():
		next.call()
		return
	var b: Array = batches.pop_front()
	http.request(CheapShark.lookup_url(b), {}, func(res: Dictionary):
		if not res["ok"]:
			next.call()
			return
		var single: String = b[0] if b.size() == 1 else ""
		var parsed := CheapShark.parse_lookup(res["body"], single)
		for gid in parsed:
			_cache["lookup"][gid] = parsed[gid]
		_lookup_batches(batches, next))


func _step_steam(next: Callable) -> void:
	var appids: Array = []
	for key in _items:
		var s := str(_items[key]["ids"].get("steam", ""))
		if s != "" and not s in appids:
			appids.append(s)
	# Big wishlists: refresh the apps we know least recently first.
	appids.sort_custom(func(a, b): return int(_cache["steam"].get(a, {}).get("at", 0)) < int(_cache["steam"].get(b, {}).get("at", 0)))
	for o in _cache["top"]:
		if o.get("appid", "") != "" and not o["appid"] in appids:
			appids.append(o["appid"])
	_steam_batches(appids, MAX_STEAM_BATCHES, func(_ok): next.call())


## Asks Steam for up to `max_batches` x 50 apps; done.call(ok).
func _steam_batches(appids: Array, max_batches: int, done: Callable) -> void:
	if appids.is_empty() or max_batches <= 0:
		done.call(true)
		return
	var batch := appids.slice(0, SteamApi.BATCH)
	var rest := appids.slice(SteamApi.BATCH)
	http.request(SteamApi.items_url(batch, country()), {}, func(res: Dictionary):
		_set_status("steam", _status_from(res))
		if not res["ok"]:
			done.call(false)
			return
		var info := SteamApi.parse_items(res["body"])
		var art_node := get_node_or_null("/root/Art") if is_inside_tree() else null
		for appid in info:
			info[appid]["at"] = _now()
			_cache["steam"][appid] = info[appid]
			if art_node != null and art_node.has_method("remember"):
				art_node.remember("steam:" + appid, info[appid]["art"])
		_steam_batches(rest, max_batches - 1, done))


## GG.deals prices (only with the user's key and a supported region): wishlist
## apps first, then top deals, those not fetched in the last 6 h, one request
## of at most 100 ids (GG.deals allows 100 a minute, 1,000 an hour).
func _step_ggdeals(next: Callable) -> void:
	var appids: Array = []
	for key in _items:
		var a := str(_items[key]["ids"].get("steam", ""))
		if a != "" and not a in appids:
			appids.append(a)
	for o in _cache["top"]:
		if o.get("appid", "") != "" and not o["appid"] in appids:
			appids.append(o["appid"])
	_gg_fetch(appids, func(): next.call())


func _gg_fetch(appids: Array, done: Callable) -> void:
	var region := _gg_region()
	if _gg_key() == "" or region == "":
		done.call()
		return
	var now := _now()
	var todo := appids.filter(func(a):
		var g = _cache["gg"].get(a, null)
		return not (g is Dictionary and g.get("region", "") == region and now - int(g.get("at", 0)) < GG_EVERY))
	if todo.is_empty():
		done.call()
		return
	todo = todo.slice(0, GG.MAX_IDS)
	http.request(GG.prices_url(todo, region, _gg_key()), {}, func(res: Dictionary):
		var parsed = GG.parse(res["body"]) if res["ok"] else null
		if parsed == null:
			var st := _status_from(res)
			if int(res.get("code", 0)) in [401, 403]:
				st = "error: key not accepted"
			_set_status("ggdeals", st if not res["ok"] else "error: unreadable answer")
			done.call()
			return
		_set_status("ggdeals", "ok")
		for a in todo:
			# unknown ids are remembered too, so they aren't asked again for 6 h
			var g: Dictionary = parsed.get(a, {"title": "", "url": "", "currency": "", "retail": null,
				"retail_low": null, "keyshop": null, "keyshop_low": null})
			g["at"] = now
			g["region"] = region
			_cache["gg"][a] = g
		done.call())


func _step_finish(next: Callable, due: bool) -> void:
	if due:
		_state["last_refresh"] = _now()
	_rebuild_deals()
	check_alerts()
	_save_wishlist()
	_save_state()
	_save("cache.json", _cache)
	_busy = false
	deals_changed.emit()
	wishlist_changed.emit()
	next.call()
	if _again:
		_again = false
		refresh(true)


# ---- deals and prices -------------------------------------------------------

func _rebuild_deals() -> void:
	var ctx := _ctx()
	var out: Array[Dictionary] = []
	for o in _cache["top"]:
		if not o is Dictionary:
			continue
		var low = null
		if _cache["lookup"].has(o.get("game_id", "")):
			low = _cache["lookup"][o["game_id"]].get("historical_low")
		var d := Prices.from_cheapshark(o, _cache["stores"], ctx, low, _cache["steam"].get(o.get("appid", ""), null))
		if d["appid"] != "":
			d["ggdeals"] = Prices.gg_extra(d["appid"], _gg(d["appid"]), ctx)
			if d["ggdeals"] != null and d["ggdeals"]["historical_low"] != null:
				d["historical_low"] = d["ggdeals"]["historical_low"]
				d["is_historical_low"] = d["price"] != null and d["price"]["currency"] == d["historical_low"]["currency"] \
					and d["price"]["amount"] <= d["historical_low"]["amount"] + 0.005
		out.append(d)
	deals = out


func _ids_of(game: Variant) -> Dictionary:
	var ids := {}
	var title := ""
	if game is Dictionary:
		title = str(game.get("title", ""))
		if game.get("ids") is Dictionary:
			for k in game["ids"]:
				ids[str(k)] = str(game["ids"][k])
		if str(game.get("appid", "")) != "":
			ids["steam"] = str(game["appid"])
		if game.get("store", "") == "steam" and str(game.get("id", "")) != "":
			ids["steam"] = str(game["id"])   # a Library game
	elif str(game).is_valid_int():
		ids["steam"] = str(game)
	else:
		title = str(game)
	return {"ids": ids, "title": title, "key": Wish.key_for(ids, title)}


## Every store's price for a game from what's cached, cheapest first. `game`
## is a Steam appid, a title, a Library game, a wishlist item, a Release or a
## Deal. Call request_prices() to fetch fresh ones.
func prices_for(game: Variant) -> Array[Dictionary]:
	var g := _ids_of(game)
	var gid := _cs_id_for(g["ids"], g["title"])
	var lookup: Dictionary = _cache["lookup"].get(gid, {}) if gid != "" else {}
	var appid: String = g["ids"].get("steam", "")
	var steam = _cache["steam"].get(appid, null)
	return Prices.prices_for(lookup, steam, _cache["stores"], _ctx(), _gg(appid) if appid != "" else null, appid)


## Fetches a game's prices (at most 3 requests) and emits
## prices_ready(game_key, deals). Works while paused: the user asked.
func request_prices(game: Variant) -> void:
	var g := _ids_of(game)
	if http == null or not prices_allowed():
		prices_ready.emit(g["key"], prices_for(game))
		return
	var steam: String = g["ids"].get("steam", "")
	var after_steam := func(_ok: bool):
		var gid := _cs_id_for(g["ids"], g["title"])
		if gid == "":
			prices_ready.emit(g["key"], prices_for(game))
			return
		http.request(CheapShark.lookup_url([gid]), {}, func(res: Dictionary):
			if res["ok"]:
				var parsed := CheapShark.parse_lookup(res["body"], gid)
				for k in parsed:
					_cache["lookup"][k] = parsed[k]
			prices_ready.emit(g["key"], prices_for(game)))
	var after_resolve := func():
		if steam != "":
			_steam_batches([steam], 1, func(ok: bool): _gg_fetch([steam], func(): after_steam.call(ok)))
		else:
			after_steam.call(true)
	if _cs_id_for(g["ids"], g["title"]) == "" and (steam != "" or g["title"] != ""):
		var url := CheapShark.by_steam_url(steam) if steam != "" else CheapShark.search_url(g["title"], 5)
		http.request(url, {}, func(res: Dictionary):
			var found = CheapShark.parse_search(res["body"]) if res["ok"] else null
			if found != null:
				for f in found:
					if (steam != "" and f["appid"] == steam) or (steam == "" and Wish.normalise(f["title"]) == Wish.normalise(g["title"])):
						_state["cs_ids"]["steam:" + steam if steam != "" else "title:" + Wish.normalise(g["title"])] = f["game_id"]
						break
			after_resolve.call())
	else:
		after_resolve.call()


## Steam's own store info cached for an app (SteamApi.parse_items shape:
## local price, "free", review summary, ...), or {}.
func steam_info(appid: Variant) -> Dictionary:
	var info = _cache["steam"].get(str(appid), null)
	return info if info is Dictionary else {}


## CheapShark's lowest price ever for a game as CheapShark gives it: US
## stores, in USD ({"price", "currency": "USD", "date"}), or null. Callers
## show it labelled as a US price or not at all; it's never converted.
func cheapest_ever(game: Variant) -> Variant:
	var g := _ids_of(game)
	var gid := _cs_id_for(g["ids"], g["title"])
	var lookup: Dictionary = _cache["lookup"].get(gid, {}) if gid != "" else {}
	var low = lookup.get("historical_low", null)
	return low if low is Dictionary and float(low.get("price", 0.0)) > 0.0 else null


## Best known deal for a Steam app (wishlist prices, then top deals), or {}.
func deal_for_appid(appid: Variant) -> Dictionary:
	var a := str(appid)
	if a == "" or a == "0":
		return {}
	var list := prices_for(a)
	var best := Prices.best(list)
	for d in deals:
		if d["appid"] == a and d["price"] != null and (best.is_empty() or d["price"]["amount"] < best["price"]["amount"]):
			best = d
	return best


## Best known deal by title (normalised match), or {}.
func deal_for_title(title: String) -> Dictionary:
	var t := Wish.normalise(title)
	if t == "":
		return {}
	var best := Prices.best(prices_for(title))
	for d in deals:
		if Wish.normalise(d["title"]) == t and d["price"] != null and best.is_empty():
			best = d
	return best


# ---- search -----------------------------------------------------------------

## Searches CheapShark by title (plus Steam for regional prices); emits
## search_done(query, results). Each result: {"key", "title", "ids", "art",
## "best_deal": Deal or {}, "on_wishlist", "release": Release or {}}.
func search(query: String) -> void:
	var q := query.strip_edges()
	if q == "" or http == null or not prices_allowed():
		search_done.emit(query, [])
		return
	http.request(CheapShark.search_url(q, 20), {}, func(res: Dictionary):
		var found = CheapShark.parse_search(res["body"]) if res["ok"] else null
		if found == null:
			_set_status("cheapshark", _status_from(res) if not res["ok"] else "error: unreadable answer")
			search_done.emit(query, [])
			return
		var appids: Array = []
		for f in found:
			if f["appid"] != "":
				appids.append(f["appid"])
				_state["cs_ids"]["steam:" + f["appid"]] = f["game_id"]
		_steam_batches(appids, 1, func(_ok):
			search_done.emit(query, _search_results(found))))


func _search_results(found: Array) -> Array:
	var ctx := _ctx()
	var cal := calendar
	var out := []
	for f in found:
		var ids := {"cheapshark": f["game_id"]}
		if f["appid"] != "":
			ids["steam"] = f["appid"]
		var best := {}
		var steam = _cache["steam"].get(f["appid"], null)
		if steam is Dictionary and steam.get("price") != null:
			best = Prices.from_steam(steam, ctx)
		var cheapest := Prices.from_cheapshark({"deal_id": f["cheapest_deal_id"], "store_id": "", "game_id": f["game_id"],
			"appid": f["appid"], "title": f["title"], "price": f["cheapest"], "regular_price": f["cheapest"],
			"savings_pct": 0, "thumb": f["thumb"]}, _cache["stores"], ctx)
		cheapest["store_name"] = "Cheapest store"
		if best.is_empty() and cheapest["price"] != null:
			best = cheapest
		var key := Wish.key_for(ids, f["title"])
		out.append({"key": key, "title": f["title"], "ids": ids, "art": best.get("art", {}),
			"best_deal": best, "on_wishlist": _items.has(key), "release": Cal.find(cal, ids, f["title"])})
	return out


# ---- wishlist ---------------------------------------------------------------

func _release_for(item: Dictionary, cal: Array) -> Dictionary:
	var steam: String = item["ids"].get("steam", "")
	var info = _cache["steam"].get(steam, null) if steam != "" else null
	var now := _now()
	if info is Dictionary and info.get("release") is Dictionary:
		var r: Dictionary = info["release"].duplicate()
		r["days_until"] = Cal.days_until(r.get("date", ""), r.get("precision", "tba"), now)
		r["date_unix"] = null if Cal.period(r.get("date", ""), r.get("precision", "tba")).is_empty() else Cal.period(r["date"], r["precision"])[0]
		return r
	var c := Cal.find(cal, item["ids"], item["title"])
	if c.is_empty():
		return {}
	return {"released": c["released"], "date": c["date"], "precision": c["precision"],
		"days_until": c["days_until"], "date_unix": c["date_unix"]}


## A stored item plus its live fields.
func _view(item: Dictionary, cal: Array) -> Dictionary:
	var v := item.duplicate(true)
	var list := prices_for(item)
	var best := Prices.best(list)
	var gid := _cs_id_for(item["ids"], item["title"])
	var low = _cache["lookup"].get(gid, {}).get("historical_low", null) if gid != "" else null
	var steam = _cache["steam"].get(item["ids"].get("steam", ""), null)
	if v["title"] == "" and steam is Dictionary:
		v["title"] = steam.get("title", "")
	if steam is Dictionary and steam.get("art") is Dictionary:
		for k in steam["art"]:
			if v["art"].get(k, "") == "":
				v["art"][k] = steam["art"][k]
	v["best_deal"] = best
	v["historical_low"] = Prices.best_low(low, _gg(str(item["ids"].get("steam", ""))), _ctx())   # only in the user's currency
	v["savings_pct"] = int(best.get("savings_pct", 0))
	v["on_sale"] = v["savings_pct"] > 0
	v["is_historical_low"] = bool(best.get("is_historical_low", false))
	v["sale_ends_at"] = best.get("sale_ends_at", null)
	v["release"] = _release_for(item, cal)
	v["on_wishlist"] = true
	return v


func _wishlist_view() -> Array[Dictionary]:
	var cal := calendar
	var out: Array[Dictionary] = []
	for it in Wish.sorted(_items):
		out.append(_view(it, cal))
	return out


func get_item(key: String) -> Dictionary:
	return _view(_items[key], calendar) if _items.has(key) else {}


func is_wishlisted(game: Variant) -> bool:
	return _items.has(_ids_of(game)["key"])


## Adds a game (partial item, Release, Deal, search result or Library game) and
## returns its key; an existing item keeps its settings. Emits wishlist_changed.
func add_to_wishlist(game: Dictionary) -> String:
	var src := game.duplicate(true)
	if src.get("store", "") == "steam" and str(src.get("id", "")) != "" and not src.has("appid"):
		src["appid"] = str(src["id"])
	var item := Wish.make_item(src, _now())
	if item["title"] == "" and item["ids"].is_empty():
		return ""
	if _items.has(item["key"]):
		return item["key"]
	_items[item["key"]] = item
	_save_wishlist()
	_rebuild_deals()
	wishlist_changed.emit()
	deals_changed.emit()
	return item["key"]


func remove_from_wishlist(key: String) -> void:
	if not _items.erase(key):
		return
	_state["seen"].erase("price:" + key)
	_state["seen"].erase("release:" + key)
	_save_wishlist()
	_save_state()
	_rebuild_deals()
	wishlist_changed.emit()
	deals_changed.emit()


## Target price in the user's currency, or null for "any drop".
func set_target_price(key: String, price: Variant) -> void:
	if not _items.has(key):
		return
	_items[key]["target_price"] = float(price) if price is float or price is int else null
	_state["seen"].erase("price:" + key)
	_save_wishlist()
	_save_state()
	wishlist_changed.emit()


## Turns an item's price and/or release alerts on or off (null = unchanged).
func set_notify(key: String, price: Variant = null, release: Variant = null) -> void:
	if not _items.has(key):
		return
	if price != null:
		_items[key]["notify_price"] = bool(price)
	if release != null:
		_items[key]["notify_release"] = bool(release)
	_save_wishlist()
	wishlist_changed.emit()


## "Notify me" on a calendar entry: adds it to the wishlist with a release
## alert. A game that's already out doesn't alert. Returns the key.
func notify_me(release: Dictionary) -> String:
	var key := add_to_wishlist(release)
	if key == "":
		return ""
	_items[key]["notify_release"] = true
	if release.get("released", false):
		_state["seen"]["release:" + key] = _now()
	if _items[key]["source"] == "manual":
		_items[key]["source"] = "calendar"
	_save_wishlist()
	_save_state()
	wishlist_changed.emit()
	return key


## Imports the public wishlist of a Steam profile (64-bit id, profile URL or
## custom URL name). Emits import_done(ok, added, error) and wishlist_changed.
## The id is remembered in settings.steam_id.
func import_steam_wishlist(profile: String = "") -> void:
	var who := profile if profile.strip_edges() != "" else str(_settings.get("steam_id", ""))
	var parsed := SteamApi.parse_profile_input(who)
	if parsed.is_empty() or http == null:
		import_done.emit(false, 0, "Enter a Steam profile link, custom URL name or 64-bit Steam ID")
		return
	if parsed.has("steam_id"):
		_import_for(parsed["steam_id"], who)
		return
	http.request(SteamApi.profile_xml_url(parsed["vanity"]), {}, func(res: Dictionary):
		var id := SteamApi.parse_profile_xml(res["body"].get_string_from_utf8()) if res["ok"] else ""
		if id == "":
			_set_status("wishlist_import", _status_from(res) if not res["ok"] else "error: profile not found")
			import_done.emit(false, 0, "Steam is unreachable" if _status_from(res) == "offline" else "No Steam profile with that name")
			return
		_import_for(id, who))


func _import_for(steam_id: String, typed: String) -> void:
	http.request(SteamApi.wishlist_url(steam_id), {}, func(res: Dictionary):
		var rows = SteamApi.parse_wishlist(res["body"]) if res["ok"] else null
		if rows == null:
			_set_status("wishlist_import", _status_from(res) if not res["ok"] else "error: unreadable answer")
			import_done.emit(false, 0, "Steam is unreachable" if _status_from(res) == "offline" else "Steam didn't return a wishlist")
			return
		_set_status("wishlist_import", "ok")
		_settings["steam_id"] = typed.strip_edges()
		_save("settings.json", _settings)
		if rows.is_empty():
			import_done.emit(true, 0, "The wishlist is empty or private (Steam profile > Privacy: Game details public)")
			return
		var appids: Array = []
		for r in rows:
			appids.append(r["appid"])
		_steam_batches(appids, MAX_IMPORT_BATCHES, func(_ok):
			var titles := {}
			for a in appids:
				if _cache["steam"].has(a):
					titles[a] = _cache["steam"][a].get("title", "")
			var added := Wish.merge_steam(_items, rows, titles, _now())
			_save_wishlist()
			_save("cache.json", _cache)
			_rebuild_deals()
			wishlist_changed.emit()
			deals_changed.emit()
			import_done.emit(true, added, "")))


# ---- alerts -----------------------------------------------------------------

## Compares every wishlist item with its best price and release state and emits
## price_alert / release_alert once per event (see alerts.gd). Runs at the end
## of each refresh; public so tests and the UI can run it on cached data.
func check_alerts() -> void:
	if not _settings.get("alerts", true):
		return
	var cal := calendar
	var now := _now()
	for key in _items:
		var v := _view(_items[key], cal)
		var best: Dictionary = v["best_deal"]
		var pa := Alerts.check_price(_items[key], best, _state["seen"])
		if not pa.is_empty():
			_push_inbox(pa, now)
			price_alert.emit(v, best)
		var ra := Alerts.check_release(_items[key], v["release"], _state["seen"], now)
		if not ra.is_empty():
			_push_inbox(ra, now)
			release_alert.emit(v)
		if best.get("price") != null:
			_items[key]["last_price"] = best["price"]["amount"]


func _push_inbox(alert: Dictionary, now: int) -> void:
	alert["at"] = now
	alerts_inbox.push_front(alert)
	if alerts_inbox.size() > INBOX_MAX:
		alerts_inbox.resize(INBOX_MAX)


## Removes an alert from alerts_inbox (by its "id"), or all when id is "".
func mark_seen(id: String = "") -> void:
	if id == "":
		alerts_inbox.clear()
	else:
		alerts_inbox.assign(alerts_inbox.filter(func(a): return a.get("id", "") != id))
	_save_state()


# ---- calendar ---------------------------------------------------------------

func _calendar_view() -> Array[Dictionary]:
	var now := _now()
	var day := now / Cal.DAY
	if day != _cal_day:
		_cal_list = Cal.releases_from(_upcoming, now, {})
		_cal_day = day
	var out: Array[Dictionary] = []
	var aff_on := bool(_settings.get("affiliate_links", true))
	for r in _cal_list:
		var c: Dictionary = r.duplicate()
		c["on_wishlist"] = _items.has(c["key"])
		var l: Dictionary = c["link"]
		if l.has("store"):   # a store page we built ourselves (not Steam)
			var al := Affiliates.link(l["store"], l["uri"], affiliates, aff_on)
			al["store"] = l["store"]
			c["link"] = al
		else:
			c["link"] = l.merged({"affiliate": false, "note": ""}) if not l.is_empty() else l
		out.append(c)
	return out


## When the calendar file was built (ISO string) and its source statuses, for
## an "updated ..." line; {} before the first download.
func calendar_info() -> Dictionary:
	if _upcoming.is_empty():
		return {}
	return {"built": _upcoming.get("built", ""), "sources": _upcoming.get("sources", {}),
		"credits": _upcoming.get("credits", "")}


# ---- opening links ----------------------------------------------------------

## The command that opens a Deal's or Release's "link" inside the gamescope
## session: Steam links (steam://store/<appid>) go to the running Steam client;
## web links open in Steam's built-in browser via steam://openurl/ (there's no
## desktop browser in the session). [] when there's nothing to open.
## Falls back to xdg-open when `steam` isn't installed.
static func link_command(link: Dictionary, steam_bin: String) -> Array[String]:
	if not link_allowed(link):
		return [] as Array[String]
	var uri := str(link.get("uri", ""))
	var target := uri if link.get("kind", "") == "steam" else "steam://openurl/" + uri
	if steam_bin != "":
		return [steam_bin, target] as Array[String]
	return ["xdg-open", uri] as Array[String]


## Hosts a web link may open in Steam's browser: the price sites whose data we
## show (their own redirect / referral pages) and the store pages we build.
## Add an affiliate program's host here when one is filled in.
const LINK_HOSTS := ["www.cheapshark.com", "cheapshark.com", "gg.deals", "store.epicgames.com", "www.wikidata.org",
	"www.gog.com", "www.greenmangaming.com", "www.fanatical.com"]


## True for a Steam store link with a valid app id (steam://store/<digits>)
## or an https:// link to one of LINK_HOSTS (or a subdomain of gg.deals).
static func link_allowed(link: Dictionary) -> bool:
	var uri := str(link.get("uri", ""))
	if link.get("kind", "") == "steam":
		var m := RegEx.create_from_string("^steam://store/([0-9]+)/?$").search(uri)
		return m != null and preload("res://scripts/steam/app_id.gd").valid(m.get_string(1))
	return url_host_allowed(uri)


static func url_host_allowed(uri: String) -> bool:
	if not uri.begins_with("https://"):
		return false
	var rest := uri.substr(8)
	var end := rest.length()
	for c in ["/", "?", "#"]:
		var i := rest.find(c)
		if i >= 0:
			end = mini(end, i)
	var host := rest.substr(0, end).to_lower()
	if host == "" or "@" in host or ":" in host or "\\" in host:
		return false
	return host in LINK_HOSTS or host.ends_with(".gg.deals")


func open_link(link: Dictionary) -> bool:
	var Common := preload("res://scripts/library/stores/common.gd")
	var cmd := link_command(link, Common.which("steam", OS.get_environment("PATH")))
	if cmd.is_empty():
		return false
	return OS.create_process(cmd[0], cmd.slice(1)) > 0
