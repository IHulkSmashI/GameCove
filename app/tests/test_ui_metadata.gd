extends "res://tests/test_case.gd"
## Game details UI: critic badges (Metacritic's colours, OpenCritic's tier and
## % recommend, IGDB as a fallback), the facts row, credits, the phone
## hand-off, the artwork picker with a fake service, the game page hook and the
## Library's critic sort and genre / 75+ filters. Synchronous, no network.

const Metadata := preload("res://scripts/library/meta/metadata.gd")
const MetadataCard := preload("res://scripts/ui/games/metadata_card.gd")
const LinkHandoff := preload("res://scripts/ui/games/link_handoff.gd")
const ArtPicker := preload("res://scripts/ui/games/art_picker.gd")
const View := preload("res://scripts/ui/library_view.gd")
const LibraryScreen := preload("res://scripts/ui/library_screen.gd")
const GamePage := preload("res://scripts/ui/game_page.gd")
const Screens := preload("res://tests/test_ui_screens.gd")


static func meta_with(critics: Dictionary, extra := {}) -> Dictionary:
	var m := Metadata.empty()
	for k in critics:
		m["critics"][k] = critics[k]
	m.merge(extra, true)
	return m


static func game(m: Dictionary, store := "steam", title := "Hades") -> Dictionary:
	return {"key": store + ":1", "store": store, "id": "1", "title": title, "installed": true,
		"art": {"cover": "", "hero": "", "logo": "", "icon": ""}, "info": {"meta": m, "summary": ""}, "last_played": 0, "playtime_min": 0}


func test_metacritic_colours_and_badge_text() -> void:
	for spec in [[93, "good", "#66cc33"], [75, "good", "#66cc33"], [74, "mixed", "#ffcc33"], [50, "mixed", "#ffcc33"], [49, "bad", "#ff0000"]]:
		var b: Array = MetadataCard.badges(meta_with({"metacritic": {"score": spec[0], "url": "https://www.metacritic.com/game/x"}}))
		eq(b[0]["color"], Color(spec[2]), "%d is %s" % [spec[0], spec[1]])
		eq(b[0]["source"], "Metacritic", "source label")
	var both: Array = MetadataCard.badges(meta_with({
		"metacritic": {"score": 93, "url": "https://www.metacritic.com/game/hades"},
		"opencritic": {"score": 93, "percent_recommended": 98, "tier": "Mighty", "url": "https://opencritic.com/game/9136/hades", "count": 120},
		"igdb_critic": {"score": 90, "count": 30}}))
	eq(both.map(func(x): return x["id"]), ["metacritic", "opencritic"], "IGDB only when neither has a score")
	eq(both[1]["line"], "Mighty · 98% recommend", "OpenCritic tier and % recommend")
	var igdb: Array = MetadataCard.badges(meta_with({"igdb_critic": {"score": 85, "count": 12}}))
	eq([igdb[0]["source"], igdb[0]["line"]], ["IGDB", "Critic average of 12 reviews"], "IGDB fallback")
	eq(MetadataCard.badges(Metadata.empty()), [], "no scores, no badges")


func test_card_states_and_handoff() -> void:
	var card: VBoxContainer = MetadataCard.new()
	card.setup(game(Metadata.empty()))
	ok(not card.get_node("Critics").visible and not card.get_node("Facts").visible, "empty: nothing but Change artwork")
	eq(card.focusables(), [card.artwork_button], "one stop")
	var links := []
	card.link_requested.connect(func(t, l, u): links.append([t, l, u]))
	card.show_meta(meta_with({"metacritic": {"score": 93, "url": "https://www.metacritic.com/game/hades"}},
		{"genres": ["Action", "Indie", "RPG"], "developers": ["Supergiant Games"], "publishers": ["Supergiant Games"],
			"release_date": "2020-09-17", "controller": "full", "sources": {"genres": "steam", "metacritic": "steam"}}))
	eq(card.critic_buttons.size(), 1, "a Metacritic badge")
	eq(_score_text(card.critic_buttons[0]), "93", "score")
	var facts: Array = MetadataCard.fact_rows(card.meta)
	eq(facts, [["Genres", "Action, Indie, RPG"], ["Developer", "Supergiant Games"], ["Released", "17 Sep 2020"], ["Controller", "Full support"]],
		"publisher hidden when it's the developer")
	ok(card.credit_label.text.contains("Metacritic") and card.credit_label.text.contains("Steam"), "credits: " + card.credit_label.text)
	card.critic_buttons[0].pressed.emit()
	eq(links, [["Metacritic", "Hades on Metacritic", "https://www.metacritic.com/game/hades"]], "A hands the page to the phone")
	var h: Control = LinkHandoff.new()
	h.open(links[0][0], links[0][1], links[0][2])
	ok(h.is_open() and h.visible, "open")
	ok(h.qr_rect.texture != null, "QR code")
	eq(h.url_label.text, "https://www.metacritic.com/game/hades", "address shown")
	h.close()
	ok(not h.is_open(), "closed")
	h.free()
	card.free()


func _score_text(b: Control) -> String:
	for n in b.find_children("*", "Label", true, false):
		if n.get_parent().name == "Score":
			return n.text
	return ""


## Stands in for Library.artwork.
class FakeArt extends RefCounted:
	var reason := ""
	var applied: Array = []
	var resets: Array = []
	var searches: Array = []
	var pos := {}
	func unavailable_reason() -> String:
		return reason
	func search(_g: Dictionary, kind: String, filters: Dictionary, page: int, done: Callable) -> void:
		searches.append([kind, filters.duplicate(true), page])
		var list := []
		for i in 3:
			list.append({"id": i + 1, "url": "https://cdn2.steamgriddb.com/x%d.png" % i, "thumb": "https://cdn2.steamgriddb.com/t%d.png" % i,
				"author": "Artist%d" % i, "author_url": "", "style": "alternate", "width": 600, "height": 900, "mime": "image/png",
				"animated": false, "score": i, "nsfw": false, "humor": false})
		done.call(list, "")
	func thumb(_a: Dictionary, done: Callable) -> void:
		done.call("")
	func apply(g: Dictionary, kind: String, a: Dictionary, to_steam: bool, done: Callable, _source := "user") -> void:
		applied.append([g["key"], kind, a["id"], to_steam])
		done.call(true, "Artwork changed.")
	func reset(g: Dictionary, kind: String) -> bool:
		resets.append([g["key"], kind])
		return true
	func override_for(_g: Dictionary, _k: String) -> Dictionary:
		return {}
	func logo_position(_appid: String) -> Dictionary:
		return pos
	func set_logo_position(_appid: String, pin: String, _w := 50.0, _h := 50.0) -> bool:
		pos = {"pin": pin, "width": 50.0, "height": 50.0}
		return true


func test_art_picker() -> void:
	var p: Control = ArtPicker.new()
	p.prefs_path = ProjectSettings.globalize_path("user://tests/picker_%d.cfg" % randi())
	var svc := FakeArt.new()
	p.open(game(Metadata.empty()), svc)
	ok(p.is_open(), "open")
	eq(svc.searches[0][0], "cover", "starts on Cover")
	eq(svc.searches[0][1]["nsfw"], false, "mature off by default")
	eq(svc.searches[0][1]["animated"], false, "static by default")
	eq(p.asset_buttons.size(), 3, "thumbnails")
	ok(p.asset_buttons[0].find_children("Author", "Label", true, false)[0].text == "by Artist0", "artist under each image")
	ok(p.credit_label.text.contains("SteamGridDB"), "SteamGridDB credited")
	ok(p.steam_button.visible and p.steam_button.text.ends_with("On"), "Steam game: also change in Steam, on by default")
	p.asset_buttons[1].pressed.emit()
	eq(svc.applied, [["steam:1", "cover", 2, true]], "A uses it, in Steam too")
	eq(p.status_label.text, "Artwork changed.", "says so")
	p.steam_button.pressed.emit()
	ok(p.steam_button.text.ends_with("Off"), "Steam option off")
	p.asset_buttons[0].pressed.emit()
	eq(svc.applied[-1][3], false, "then GameCove only")
	p.cycle_kind(1)
	eq(svc.searches[-1][0], "hero", "RB: Hero")
	p.set_kind("logo")
	ok(p.logo_pos_button.visible, "logo position for Steam games")
	p.logo_pos_button.pressed.emit()
	eq(svc.pos["pin"], "UpperLeft", "cycles Steam's logo position")
	p.style_button.pressed.emit()
	eq(svc.searches[-1][1]["styles"], ["official"], "style filter")
	p.animated_button.pressed.emit()
	eq(svc.searches[-1][1]["animated"], true, "animated filter")
	p.mature_button.pressed.emit()
	ok(svc.searches[-1][1]["nsfw"] and svc.searches[-1][1]["humor"], "mature and humour together")
	p.reset_button.pressed.emit()
	eq(svc.resets, [["steam:1", "logo"]], "reset to default")
	var bottom_left: Button = p.asset_buttons[0]
	eq(bottom_left.focus_neighbor_top, bottom_left.get_path_to(p.option_buttons.filter(func(b): return b.visible)[0]), "grid up goes to the options")
	p.close()
	# a GOG game: no Steam option; no key: the reason shows
	svc.reason = "Add your free SteamGridDB key in Settings > Discover > Keys to browse artwork."
	p.open(game(Metadata.empty(), "gog"), svc)
	ok(not p.steam_button.visible, "no Steam option for other stores")
	eq(p.status_label.text, svc.reason, "why it can't browse")
	eq(p.asset_buttons.size(), 0, "nothing listed")
	p.close()
	p.free()


func test_library_critic_sort_and_filters() -> void:
	var a := game(meta_with({"metacritic": {"score": 70, "url": ""}}, {"genres": ["Action"]}), "steam", "Alpha")
	a["key"] = "steam:a"
	var b := game(meta_with({"opencritic": {"score": 90, "percent_recommended": 90, "tier": "Mighty", "url": "", "count": 9}}, {"genres": ["RPG", "Action"]}), "gog", "Bravo")
	b["key"] = "gog:b"
	var c := game(Metadata.empty(), "epic", "Charlie")
	c["key"] = "epic:c"
	var list := [a, b, c]
	eq(View.sort_games(list, "critic").map(func(g): return g["title"]), ["Bravo", "Alpha", "Charlie"], "top rated first, unscored last")
	eq(View.top_genres(list), ["Action", "RPG"], "genres by count")
	eq(View.filter_meta(list, "RPG").map(func(g): return g["title"]), ["Bravo"], "genre filter")
	eq(View.filter_meta(list, "", View.CRITIC_MIN).map(func(g): return g["title"]), ["Bravo"], "75+ filter")
	ok("critic" in View.SORTS and View.SORT_NAMES["critic"] == "Top rated", "X cycles to Top rated")
	var s: Control = LibraryScreen.new()
	s.set_games(list)
	ok(s.genre_button.visible and s.genre_button.text == "All genres", "genre chip")
	s.genre_button.pressed.emit()
	eq(s.genre, "Action", "A cycles genres")
	eq(s.shown.size(), 2, "filtered")
	eq(s.critic_button.text, "Critics 75+", "the chip says what 75+ is")
	ok(s.critic_button.icon != null, "with a star")
	s.critic_button.pressed.emit()
	eq(s.shown.map(func(g): return g["title"]), ["Bravo"], "and 75+")
	ok(s.genre_button in s._toolbar() and s.critic_button in s._toolbar(), "both reachable with the d-pad")
	s.free()


func test_game_page_shows_details_and_opens_overlays() -> void:
	var p: Control = GamePage.new()
	var g := game(meta_with({"metacritic": {"score": 88, "url": "https://www.metacritic.com/game/x"}}, {"genres": ["RPG"]}))
	p.setup(g, Screens.FakeLauncher.new(), {})
	ok(p.meta_card != null and p.meta_card.critic_buttons.size() == 1, "details card on the page")
	ok(p.meta_card.critic_buttons[0] in p.focusables and p.meta_card.artwork_button in p.focusables, "reachable")
	eq(p.hints_for_focus(p.meta_card.critic_buttons[0])[0], ["A", "Open on phone"], "hint")
	p.meta_card.critic_buttons[0].pressed.emit()
	ok(p.handoff.is_open(), "hand-off opens")
	eq(p.hints_for_focus(null), LinkHandoff.hints(), "its hints")
	p.handoff.close()
	p.meta_card.artwork_button.pressed.emit()
	ok(p.art_picker.is_open(), "picker opens (no service: says so)")
	ok(p.art_picker.status_label.text != "", "explains")
	p.art_picker.close()
	p.free()
