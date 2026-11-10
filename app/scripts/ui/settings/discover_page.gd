extends "res://scripts/ui/settings/page.gd"
## Discover: store country, keys (gg.deals, SteamGridDB, Steam profile),
## alerts, key-shop prices and affiliate links. Labels and help come from
## Discover.SETTINGS_INFO so they match the Discover screen and setup.

const KEY_RX := "^[A-Za-z0-9_\\-]{10,128}$"


func _connect() -> void:
	var d := svc("discover")
	if d != null and d.has_signal("settings_changed"):
		d.settings_changed.connect(func():
			if is_inside_tree():
				rebuild.call_deferred())


func info(key: String) -> Dictionary:
	var d := svc("discover")
	var all: Variant = d.get("SETTINGS_INFO") if d != null else null
	if all is Dictionary and all.has(key):
		return all[key]
	return {"label": key.capitalize(), "help": ""}


func build() -> void:
	var d := svc("discover")
	if d == null or not d.has_method("get_settings"):
		add_card("Discover", "discover").add_child(SKit.note("Discover isn't available in this build.", "info"))
		return
	var s: Dictionary = d.get_settings()

	var prices := add_card("Prices", "tag")
	var eff := str(s.get("country_effective", "US"))
	var src := str(s.get("country_source", "default"))
	var vals: Array = [""] + TS.COUNTRIES
	var cur := str(s.get("country", ""))
	if cur != "" and not cur in vals:
		vals.append(cur)
	var labels: Array = vals.map(func(c): return TS.COUNTRY_AUTO % eff if c == "" else c)
	var ci := info("country")
	var cr := choice(prices, "country", ci["label"], vals, labels, cur, func(v):
		var why := "Auto: %s, %s. " % [eff, TS.COUNTRY_SOURCES.get(src, src)] if v == "" else ""
		return why + str(ci["help"]), "discover")
	cr.changed.connect(func(v): d.set_settings({"country": v}))
	var ks := info("ggdeals_keyshops")
	var k := toggle(prices, "ggdeals_keyshops", ks["label"], bool(s.get("ggdeals_keyshops", false)), fixed(ks["help"]), "shield_alert")
	k.changed.connect(func(v): d.set_settings({"ggdeals_keyshops": v}))
	var af := info("affiliate_links")
	var a := toggle(prices, "affiliate_links", af["label"], bool(s.get("affiliate_links", true)),
		func(v): return str(af["help"]) + (" Turn off to use plain links." if v else ""), "star")
	a.changed.connect(func(v): d.set_settings({"affiliate_links": v}))
	prices.add_child(SKit.note("Links marked \"%s\" help pay for GameCove's development. Prices are the same either way." % TS.AFFILIATE_NOTE, "info", "AffiliateNote"))

	var keys := add_card("Keys and accounts", "shield", "Your own free keys. They stay on this device.")
	_key_row(keys, "ggdeals_key", str(s.get("ggdeals_key", "")), "gg.deals key", func(t): return t == "" or RegEx.create_from_string(KEY_RX).search(t) != null)
	var sg := str(s.get("steamgriddb_key", ""))
	var setup := svc("setup")
	if sg == "" and setup != null and setup.has_method("steamgriddb_key"):
		sg = setup.steamgriddb_key()
	_key_row(keys, "steamgriddb_key", sg, "SteamGridDB key", func(t): return t == "" or (t.length() == 32 and t.is_valid_hex_number()))
	if host != null and host.has_method("open_setup"):
		# The guided Game art step (phone page, live check, art fill) instead of the bare keyboard.
		var r: VBoxContainer = rows["steamgriddb_key"]
		for c in r.pressed.get_connections():
			r.pressed.disconnect(c["callable"])
		r.pressed.connect(func(): host.open_setup("art"))
	_key_row(keys, "steam_id", str(s.get("steam_id", "")), "Steam profile", func(_t): return true, false)
	_opencritic_row(keys)

	var alerts := add_card("Alerts", "alert")
	var al := info("alerts")
	var t := toggle(alerts, "alerts", al["label"], bool(s.get("alerts", true)), fixed(al["help"]), "alert")
	t.changed.connect(func(v): d.set_settings({"alerts": v}))


## A row that shows a key masked and opens the keyboard to change it.
func _key_row(box: Control, key: String, value: String, what: String, valid: Callable, mask := true) -> void:
	var i := info(key)
	var shown := TS.masked(value) if mask else (value if value != "" else TS.KEY_NONE)
	var r: VBoxContainer = action_row(box, key, i["label"], shown, str(i["help"]), "")
	r.set_value(shown, "muted" if value == "" else "")
	r.pressed.connect(func():
		host.ask_text(i["label"], value, func(text: String):
			save_key(key, text.strip_edges(), what, valid)))


## OpenCritic: the user's own RapidAPI key (OpenCritic's data may not be republished, so none ships).
func _opencritic_row(box: Control) -> void:
	var Resolver := preload("res://scripts/library/meta/resolver.gd")
	var value := Resolver.opencritic_key()
	var shown := TS.masked(value)
	var label := "OpenCritic key (optional)"
	var r: VBoxContainer = action_row(box, "opencritic_key", label, shown,
		"Critic scores, tier and % recommended on game pages. Free on rapidapi.com (OpenCritic API); stays on this device.", "")
	r.set_value(shown, "muted" if value == "" else "")
	r.pressed.connect(func():
		host.ask_text(label, value, func(text: String):
			if Resolver.set_opencritic_key(text.strip_edges()):
				notify((TS.KEY_REMOVED if text.strip_edges() == "" else TS.KEY_SAVED) % "OpenCritic key", "good")
				rebuild()
			else:
				notify(TS.KEY_BAD % "OpenCritic key", "bad")))


## Saves a key typed on the keyboard ("" removes it). SteamGridDB goes to the
## Setup service too, which checks it and keeps it for first-run setup.
func save_key(key: String, text: String, what: String, valid: Callable) -> bool:
	if not bool(valid.call(text)):
		notify(TS.KEY_BAD % what, "bad")
		return false
	if key == "steamgriddb_key":
		var setup := svc("setup")
		if setup != null and setup.has_method("set_steamgriddb_key") and not setup.set_steamgriddb_key(text):
			notify(TS.KEY_BAD % what, "bad")
			return false
	svc("discover").set_settings({key: text})
	notify((TS.KEY_REMOVED if text == "" else TS.KEY_SAVED) % what, "good")
	if not svc("discover").has_signal("settings_changed"):
		rebuild()
	return true
