extends "res://tests/test_case.gd"
## Steam insights: parsers on recorded Steam answers (tests/fixtures/insights,
## recorded 2026-11-09), the service's caching, switches and offline paths
## with fake_http.gd and a fake Discover, the game page card's states and
## drawers, and the review pill on Discover deals. No network.

const Api := preload("res://scripts/steam/insights_api.gd")
const Insights := preload("res://scripts/steam/steam_insights.gd")
const Card := preload("res://scripts/ui/games/insights_card.gd")
const TI := preload("res://scripts/ui/texts_insights.gd")
const FakeHttp := preload("res://scripts/discover/fake_http.gd")
const SteamApi := preload("res://scripts/discover/steam_api.gd")
const Prices := preload("res://scripts/discover/prices.gd")
const W := preload("res://scripts/ui/discover/widgets.gd")
const Privacy := preload("res://scripts/system/privacy.gd")
const GamePage := preload("res://scripts/ui/game_page.gd")
const Screens := preload("res://tests/test_ui_screens.gd")

const ER := "1245620"
const T0 := 1794225600   # 2026-11-08 12:00 UTC


## Discover's price side, as the service uses it.
class FakeDiscover extends Node:
	signal prices_ready(game_key: String, deals: Array)
	var allowed := true
	var cur := "CAD"
	var cc := "CA"
	var deals: Array = []
	var info := {}
	var cs_low: Variant = null
	var asked: Array = []
	var opened: Array = []
	func prices_allowed() -> bool: return allowed
	func country() -> String: return cc
	func user_currency() -> String: return cur
	func prices_for(_g: Variant) -> Array: return deals
	func steam_info(_a: Variant) -> Dictionary: return info
	func cheapest_ever(_g: Variant) -> Variant: return cs_low
	func attributions() -> Array: return [{"text": "Price data by CheapShark", "url": "https://www.cheapshark.com/"}]
	func open_link(l: Dictionary) -> bool:
		opened.append(l)
		return true
	func request_prices(g: Variant) -> void:
		asked.append(str(g))
		prices_ready.emit("steam:" + str(g), deals)


## An http that never answers (requests stay "loading").
class SilentHttp extends RefCounted:
	var requests: Array[String] = []
	func request(url: String, _o: Dictionary, _done: Callable) -> void:
		requests.append(url)


## fake_http routes by prefix, but GetItems puts the ids last (JSON keys are
## sorted): its answers are picked by app id here.
class RoutingHttp extends FakeHttp:
	func request(url: String, opts: Dictionary, done: Callable) -> void:
		var u := url
		if url.contains("IStoreBrowseService/GetItems"):
			u = ("fake://dlc/" if url.contains("%22appid%22%3A3655690") else "fake://store/") + url
		super.request(u, opts, done)


func _fx(name: String) -> String:
	return fixture("insights/" + name)


func _http() -> FakeHttp:
	var h := RoutingHttp.new()
	h.route(Api.API + "ISteamUserStats/GetNumberOfCurrentPlayers/", {"file": _fx("players_1245620.json")})
	h.route("fake://store/", {"file": _fx("store_items.json")})
	h.route("fake://dlc/", {"file": _fx("dlc_items_ca.json")})
	h.route(Api.API + "ISteamNews/GetNewsForApp/", {"file": _fx("news_1245620.json")})
	h.route(Api.STORE + "api/appdetails", {"file": _fx("appdetails_1245620.json")})
	return h


## A service on a throwaway folder and settings file, fixed clock.
func _svc(h: Variant, disc: Object = null, background := true) -> Dictionary:
	var dir := "user://tests/insights_%d" % randi()
	DirAccess.make_dir_recursive_absolute(dir)
	var prefs := dir + "/settings.cfg"
	Privacy.set_background_allowed(background, prefs)
	var s: Node = Insights.new()
	s.http = h
	s.discover = disc
	s.data_dir = dir
	s.privacy_path = prefs
	var now := [T0]
	s.clock = func() -> int: return now[0]
	return {"svc": s, "now": now, "dir": dir}


func _done(r: Dictionary) -> void:
	r["svc"].free()
	var d := DirAccess.open(r["dir"])
	if d != null:
		for f in d.get_files():
			d.remove(f)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(r["dir"]))


# ---- parsers ---------------------------------------------------------------------

func test_parse_players() -> void:
	eq(Api.parse_players(FileAccess.get_file_as_bytes(_fx("players_1245620.json"))), 16472, "players now")
	eq(Api.parse_players(FileAccess.get_file_as_bytes(_fx("players_unknown.json"))), -1, "result 42: not counted")
	eq(Api.parse_players("<html>"), -1, "junk")
	ok(Api.players_url(ER).begins_with("https://api.steampowered.com/ISteamUserStats/GetNumberOfCurrentPlayers/v1/?appid=1245620"), "url")
	ok(not Api.players_url(ER).contains("key="), "keyless")


func test_parse_store_reviews_and_deck() -> void:
	var s := Api.parse_store(FileAccess.get_file_as_bytes(_fx("store_items.json")))
	eq(s.size(), 3, "three apps")
	eq(s[ER]["reviews"], {"label": "Very Positive", "percent": 93, "count": 835755, "score": 8}, "review summary (all languages)")
	eq(s[ER]["deck"], Api.DECK_VERIFIED, "Deck Verified")
	eq(s["730"]["deck"], Api.DECK_PLAYABLE, "Deck Playable")
	ok(s["730"]["free"], "free game flagged")
	eq(Api.review_line(s[ER]["reviews"]), "Very Positive · 93% of 835,755", "review line")
	eq(Api.review_short(s[ER]["reviews"]), "93% positive", "pill text")
	eq(Api.review_tone(s[ER]["reviews"]), "good", "tone")
	eq(Api.deck_info(1)["text"], "Unsupported", "deck labels")
	eq(Api.deck_info(99)["text"], "Unknown", "unknown category")
	var url := Api.store_url([ER])
	ok(url.contains("%22country_code%22%3A%22US%22"), "neutral country, not the user's")
	ok(url.contains("include_reviews") and url.contains("include_platforms"), "asks for reviews and platforms")
	eq(Api.group(9972361), "9,972,361", "thousands")
	eq(Api.group(12), "12", "small")


func test_parse_news_and_notes() -> void:
	var n: Array = Api.parse_news(FileAccess.get_file_as_bytes(_fx("news_1245620.json")))
	ok(n.size() >= 1, "patch notes")
	eq(n[0]["title"], "Release Note for 2025/12/16", "newest first")
	eq(n[0]["date"], 1765868757, "date")
	ok(n[0]["date"] >= n[-1]["date"], "sorted")
	eq(Api.parse_news("{}"), null, "not a news answer")
	ok(Api.news_url(ER).contains("tags=patchnotes"), "patch notes only")
	var cp: Array = Api.parse_news(FileAccess.get_file_as_bytes(_fx("news_1091500.json")))
	var rich := Api.bbcode_to_rich(cp[1]["body"])
	ok(rich.contains("[b][font_size=23]New features[/font_size][/b]"), "heading kept: " + rich.left(300))
	ok(rich.contains("• V's issue"), "list items become bullets")
	ok(not rich.contains("STEAM_CLAN_IMAGE") and not rich.contains("[img") and not rich.contains(".gif"), "pictures dropped")
	ok(not rich.contains("[list]") and not rich.contains("[*]"), "list tags gone")


func test_bbcode_is_safe() -> void:
	var evil := "Hi [url=steam://run/1]click[/url] [img]x.png[/img] [font=res://x.ttf]big[/font] [b]bold [i]both[/b] a [ b"
	var r := Api.bbcode_to_rich(evil)
	ok(not r.contains("[url"), "no link tags")
	ok(not r.contains("[font="), "no font injection")
	ok(not r.contains("x.png"), "image dropped")
	ok(r.contains("click"), "link text kept")
	ok(r.contains("[lb] b"), "stray bracket escaped: " + r)
	var opens := r.count("[b]") + r.count("[i]")
	var closes := r.count("[/b]") + r.count("[/i]")
	eq(opens, closes, "tags balanced: " + r)
	eq(Api.bbcode_to_rich("<p>One</p><ul><li>Two</li></ul>&amp; more"), "One\n\n• Two\n& more", "html feeds")


func test_parse_dlc_ids() -> void:
	var ids = Api.parse_dlc_ids(FileAccess.get_file_as_bytes(_fx("appdetails_1245620.json")), ER)
	eq(ids, ["3655690", "2778590", "2778580"] as Array[String], "dlc ids")
	eq(Api.parse_dlc_ids("{\"1\":{\"success\":false}}", "1"), null, "unknown app")
	eq(Api.steamdb_url(ER), "https://steamdb.info/app/1245620/", "steamdb link")
	eq(Api.steamdb_url("1/../x"), "", "only real ids")


# ---- service ---------------------------------------------------------------------

func test_service_fetches_and_caches() -> void:
	var h := _http()
	var disc := FakeDiscover.new()
	var r := _svc(h, disc)
	var s: Node = r["svc"]
	var changes := []
	s.changed.connect(func(a): changes.append(a))
	s.request(ER)
	var v: Dictionary = s.view(ER)
	eq(v["summary"], "data", "data")
	eq(v["players"], 16472, "players")
	eq(v["reviews"]["percent"], 93, "reviews")
	eq(v["deck"], Api.DECK_VERIFIED, "deck")
	eq(v["news"][0]["title"], "Release Note for 2025/12/16", "last update")
	eq(v["dlc_count"], 3, "dlc count")
	eq(v["dlc"].size(), 3, "dlc rows")
	ok(v["dlc_priced"], "dlc priced for the store country")
	eq(v["dlc"][0]["price_text"], "C$ 6.99", "dlc local price")
	eq(disc.asked, [ER], "price asked through Discover")
	ok(changes.size() >= 5, "changed per part")
	ok(h.count("fake://dlc/") == 1 and h.requests.any(func(u): return u.contains("%22CA%22")), "dlc priced with the user's country")
	var n := h.requests.size()
	# within the cache periods nothing is asked again
	s.request(ER)
	eq(h.requests.size(), n, "all cached")
	disc.asked.clear()
	# 11 minutes later only players are stale
	r["now"][0] += 660
	s.request(ER)
	eq(h.requests.size(), n + 1, "one more call")
	ok(h.requests[-1].contains("GetNumberOfCurrentPlayers"), "players refreshed")
	eq(disc.asked, [], "prices follow the deals refresh, not players")
	# 13 hours later the rest too; prices again with the deals refresh
	r["now"][0] += 13 * 3600
	s.request(ER)
	ok(h.count(Api.API + "ISteamNews/") == 2 and h.count(Api.STORE + "api/appdetails") == 2, "12 h parts refreshed")
	eq(disc.asked, [ER], "prices refreshed after 6 h")
	# a new service reads the file cache
	var s2: Node = Insights.new()
	s2.data_dir = r["dir"]
	s2.http = SilentHttp.new()
	s2.privacy_path = s.privacy_path
	s2.clock = s.clock
	eq(s2.view(ER)["reviews"]["count"], 835755, "kept on disk")
	s2.free()
	disc.free()
	_done(r)


func test_background_off_sends_nothing() -> void:
	var h := _http()
	var disc := FakeDiscover.new()
	disc.allowed = false
	var r := _svc(h, disc, false)
	var s: Node = r["svc"]
	s.request(ER)
	eq(h.requests.size(), 0, "nothing sent")
	eq(disc.asked, [], "no price lookup either")
	var v: Dictionary = s.view(ER)
	eq(v["summary"], "off", "off")
	eq(v["state"]["price"], "off", "prices off")
	ok(v["price"].is_empty(), "no prices shown")
	disc.free()
	_done(r)


func test_prices_off_keeps_the_rest() -> void:
	var h := _http()
	var disc := FakeDiscover.new()
	disc.allowed = false
	var r := _svc(h, disc)
	var s: Node = r["svc"]
	s.request(ER)
	var v: Dictionary = s.view(ER)
	eq(v["summary"], "data", "insights still there")
	eq(disc.asked, [], "Discover not asked")
	ok(not h.requests.any(func(u): return u.contains("%22CA%22")), "the user's country isn't sent")
	eq(v["dlc"].size(), 3, "dlc names from the neutral call")
	ok(not v["dlc_priced"] and v["dlc"][0]["price_text"] == "", "but no prices")
	disc.free()
	_done(r)


func test_offline_and_retry_pause() -> void:
	var h := FakeHttp.new()
	h.offline = true
	var r := _svc(h, null)
	var s: Node = r["svc"]
	s.request(ER)
	var v: Dictionary = s.view(ER)
	eq(v["summary"], "offline", "offline")
	eq(v["state"]["players"], "offline", "part state")
	var n := h.requests.size()
	eq(n, 4, "players, store, news, dlc tried once")
	s.request(ER)
	eq(h.requests.size(), n, "not retried right away")
	r["now"][0] += Insights.RETRY_S
	s.request(ER)
	eq(h.requests.size(), n * 2, "retried after the pause")
	s.request(ER, true)
	eq(h.requests.size(), n * 3, "Refresh retries at once")
	_done(r)


func test_price_and_lowest_ever_real_sources_only() -> void:
	var disc := FakeDiscover.new()
	disc.deals = [{"source": "steam", "price": {"text": "C$ 47.99", "regular_text": "C$ 79.99", "amount": 47.99, "currency": "CAD"},
		"savings_pct": 40, "historical_low": null}]
	disc.cs_low = {"price": 23.99, "currency": "USD", "date": 1710000000}
	var r := _svc(_http(), disc)
	var s: Node = r["svc"]
	var v: Dictionary = s.view(ER)
	eq(v["price"]["text"], "C$ 47.99", "Steam's own local price")
	eq(TI.price_line(v["price"]), "C$ 47.99  −40%  (was C$ 79.99)", "price line")
	eq(v["low"]["text"], "$23.99 USD", "a US low is labelled USD, never converted")
	eq(v["low"]["note"], "US store", "and where it's from")
	ok(not v["low"]["local"], "not local")
	ok(TI.low_line(v["low"]).begins_with("$23.99 USD · US store · Mar 2024"), TI.low_line(v["low"]))
	# a local low (GG.deals in CAD) wins
	disc.deals[0]["historical_low"] = {"amount": 29.99, "currency": "CAD", "date": 0}
	v = s.view(ER)
	eq(v["low"]["text"], "C$29.99", "local low")
	ok(v["low"]["local"], "local")
	ok(not v["attributions"].is_empty(), "credits travel with prices")
	# no data: nothing made up
	disc.deals = []
	disc.cs_low = null
	v = s.view(ER)
	ok(v["price"].is_empty() and v["low"].is_empty(), "nothing invented")
	disc.info = {"free": true}
	eq(s.view(ER)["price"]["text"], "Free to play", "free games")
	disc.free()
	_done(r)


# ---- card ------------------------------------------------------------------------

func _card(s: Node, game := {"store": "steam", "id": ER, "title": "ELDEN RING", "key": "steam:" + ER}) -> Array:
	var host := Control.new()
	var c: VBoxContainer = Card.new()
	host.add_child(c)
	c.setup(game, s, host)
	return [c, host]


func test_card_states() -> void:
	# loading
	var r := _svc(SilentHttp.new(), null)
	var pair := _card(r["svc"])
	var c: VBoxContainer = pair[0]
	eq(c.state, "loading", "loading")
	eq(c.status_label.text, TI.LOADING, "says so")
	ok(c.stats.visible and c.players_value.text == TI.DASH, "empty tiles")
	ok(not c.update_button.visible and not c.dlc_button.visible, "rows wait for data")
	ok(c.steamdb_button.visible, "SteamDB link always there")
	eq(c.focusables(), [c.steamdb_button], "focus: the link")
	pair[1].free()
	_done(r)
	# data
	var disc := FakeDiscover.new()
	disc.deals = [{"source": "steam", "price": {"text": "C$ 79.99", "regular_text": "C$ 79.99", "amount": 79.99, "currency": "CAD"},
		"savings_pct": 0, "historical_low": {"amount": 39.99, "currency": "CAD", "date": 0}}]
	r = _svc(_http(), disc)
	pair = _card(r["svc"])
	c = pair[0]
	var relinks := [0]
	c.relinked.connect(func(): relinks[0] += 1)
	eq(c.state, "data", "data")
	ok(not c.status_label.visible, "no status line")
	eq(c.players_value.text, "16,472", "players")
	eq(c.reviews_value.text, "Very Positive", "review label")
	eq(c.reviews_sub.text, "93% of 835,755", "share and count")
	eq(c.deck_value.text, "Verified", "deck")
	ok(c.update_button.visible, "last update row")
	ok(c.update_button.get_child(0).get_child(1).get_node("Text").text.ends_with("16 Dec 2025"), "update date")
	eq(c.update_button.get_child(0).get_child(1).get_node("Detail").text, "Release Note for 2025/12/16", "update title")
	eq(c.price_label.text, TI.PRICE + ": C$ 79.99", "price")
	eq(c.low_label.text, TI.LOWEST + ": C$39.99", "lowest ever")
	ok(c.dlc_button.visible, "dlc row")
	eq(c.dlc_button.get_child(0).get_node("Value").text, "from C$ 6.99", "cheapest dlc")
	ok(c.credits_row != null, "price credits")
	eq(c.focusables().slice(0, 3), [c.update_button, c.dlc_button, c.steamdb_button], "focus order")
	# drawers
	c.update_button.pressed.emit()
	ok(c.overlay.is_open() and c.overlay.mode == "text", "notes open")
	ok(c.overlay.body.text.contains("pre-order bonuses"), "notes readable in place")
	eq(c.overlay.sub_label.text, "Release Note for 2025/12/16 · 16 Dec 2025", "notes heading")
	c.overlay.close()
	c.dlc_button.pressed.emit()
	ok(c.overlay.body.text.contains("ELDEN RING Tarnished Pack") and c.overlay.body.text.contains("C$ 6.99"), "dlc list with prices")
	c.overlay.close()
	c.steamdb_button.pressed.emit()
	eq(c.overlay.mode, "qr", "QR drawer")
	ok(c.overlay.qr_rect.texture != null, "QR code drawn")
	eq(c.overlay.url_label.text, "https://steamdb.info/app/1245620/", "address written out")
	c.overlay.close()
	ok(not c.overlay.is_open(), "B closes")
	eq(relinks[0], 0, "no relink when nothing changed")
	c.credits_row.get_meta("buttons")[0].pressed.emit()
	eq(disc.opened[0]["uri"], "https://www.cheapshark.com/", "credit links open through Discover")
	pair[1].free()
	disc.free()
	_done(r)
	# offline
	var off := FakeHttp.new()
	off.offline = true
	r = _svc(off, null)
	pair = _card(r["svc"])
	c = pair[0]
	eq(c.state, "offline", "offline")
	eq(c.status_label.text, TI.OFFLINE_EMPTY, "says so")
	ok(not c.stats.visible, "no empty tiles")
	pair[1].free()
	_done(r)
	# Background lookups off
	r = _svc(_http(), null, false)
	pair = _card(r["svc"])
	c = pair[0]
	eq(c.state, "off", "off")
	eq(c.status_label.text, TI.OFF, "explains where the switch is")
	pair[1].free()
	_done(r)


func test_card_only_for_steam_games() -> void:
	ok(Card.visible_for({"store": "steam", "id": ER}), "Steam game")
	ok(not Card.visible_for({"store": "epic", "id": "abc"}), "not for Epic")
	ok(not Card.visible_for({"store": "steam", "id": "x/../1"}), "not for a bad id")
	var epic := {"key": "epic:fn", "store": "epic", "id": "fn", "title": "Fn", "installed": false,
		"art": {"cover": "", "hero": "", "logo": "", "icon": ""}, "info": {}, "last_played": 0, "playtime_min": 0}
	var p: Control = GamePage.new()
	p.setup(epic, Screens.FakeLauncher.new(), {})
	ok(p.insights_card == null, "non-Steam game: no card")
	p.free()
	var r := _svc(_http(), null)
	var steam := epic.duplicate()
	steam.merge({"key": "steam:" + ER, "store": "steam", "id": ER}, true)
	p = GamePage.new()
	p.setup(steam, Screens.FakeLauncher.new(), {"insights": r["svc"]})
	ok(p.insights_card != null and p.insights_card.state == "data", "Steam game: card with data")
	ok(p.focusables.has(p.insights_card.update_button), "its rows are in the page's focus chain")
	p.free()
	_done(r)


# ---- Discover pill ---------------------------------------------------------------

func test_discover_review_pill() -> void:
	var info := SteamApi.parse_items(FileAccess.get_file_as_bytes(_fx("store_items.json")))
	eq(info[ER]["reviews"]["percent"], 93, "reviews ride along on GetItems")
	ok(SteamApi.items_url([ER], "CA").contains("include_reviews"), "Discover asks for them on the same call")
	var deal := Prices.from_steam(info[ER], {"country": "US", "currency": "USD"})
	eq(deal["reviews"]["percent"], 93, "deal carries them")
	var pills := W.deal_badges(deal, "USD", T0)
	ok(pills.any(func(b): return b["kind"] == "reviews" and b["text"] == "93% positive"), "review pill")
	var bare := Prices.from_steam({"appid": "1", "price": 1.0, "regular_price": 1.0}, {"country": "US", "currency": "USD"})
	eq(bare["reviews"], {}, "none without data")
	ok(not W.deal_badges(bare, "USD", T0).any(func(b): return b["kind"] == "reviews"), "no pill")
