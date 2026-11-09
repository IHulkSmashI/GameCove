extends RefCounted
## Fills a settings page (settings/page.gd) with cards generated from
## Controls groups, laid out by catalog.gd: one tinted card per topic with a
## ControlList (main settings, then "More settings" for advanced ones and
## the ones this handheld can't use). Topics where nothing works here are
## gathered into one "Not on this handheld" card at the end, so the page
## leads with what you can change.
##
## The page asks focusables() for its chain; `relinked` fires whenever a
## list's chain changed so the page can tell the settings screen.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const SKit := preload("res://scripts/ui/settings/kit.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const TC := preload("res://scripts/ui/texts_controls.gd")
const Catalog := preload("res://scripts/ui/controls/catalog.gd")
const ControlList := preload("res://scripts/ui/controls/control_list.gd")
const CIcons := preload("res://scripts/ui/controls/cicons.gd")
const SteamInput := preload("res://scripts/ui/controls/steam_input.gd")

signal relinked

var model: Object
var groups: Array = []
var lists: Array = []          # ControlList per card, in order
var parts: Array = []          # ControlLists and extra focusables, in order
var cards: Array = []          # the card panels
var _host: Control


## Adds the cards to `page` (anything with add_card(title, icon, line)).
func build(page: Object, m: Object, group_ids: Array, dialog_host: Control = null) -> void:
	model = m
	groups = group_ids
	_host = dialog_host
	lists.clear()
	parts.clear()
	cards.clear()
	var all := []
	for g in groups:
		all.append_array(model.ids(g))
	if all.is_empty():
		var box: VBoxContainer = page.add_card(TC.UNAVAILABLE_TITLE, "info")
		box.add_child(SKit.note(TC.NOTHING_HERE, "info", "Nothing"))
		cards.append(box.get_parent())
		return
	var dead := []
	for card in Catalog.cards_for(groups, all):
		var ids: Array = card[2] + card[3]
		if ids.filter(func(i): return _usable(i)).is_empty():
			dead.append_array(ids)
			continue
		var box: VBoxContainer = page.add_card(card[0], card[1])
		box.get_parent().name = "Card_" + str(card[0]).validate_node_name()
		cards.append(box.get_parent())
		var l := _list(card[2], card[3])
		box.add_child(l)
		if card[0] == "Gyro":
			_gyro_note(box)
	if not dead.is_empty():
		var box: VBoxContainer = page.add_card(TC.UNAVAILABLE_TITLE, "info", TC.UNAVAILABLE_LINE)
		box.get_parent().name = "Card_unavailable"
		box.get_parent().modulate.a = 0.85
		cards.append(box.get_parent())
		box.add_child(_list([], dead))


func _list(main: Array, more: Array) -> VBoxContainer:
	var l: VBoxContainer = ControlList.new()
	l.setup(model, main, more, {"dialog_host": _host, "name": "List"})
	l.rebuilt.connect(func(): relinked.emit())
	lists.append(l)
	parts.append(l)
	return l


func _usable(id: String) -> bool:
	return bool(model.describe(id).get("available", false))


## Which ids work now: the page rebuilds when this changes (late detection).
func signature() -> String:
	var out := []
	for g in groups:
		for id in model.ids(g):
			if _usable(id):
				out.append(id)
	return ",".join(out)


func focusables() -> Array:
	var out := []
	for p in parts:
		if not is_instance_valid(p):
			continue
		if p.has_method("focusables"):
			out.append_array(p.focusables())
		elif p is Control:
			out.append(p)
	return out


## The controller page's gyro card: aiming itself is Steam Input's.
func _gyro_note(box: VBoxContainer) -> void:
	var n := SKit.note(TC.GYRO_STEAM_TITLE + ". " + TC.GYRO_STEAM_LINE, "info", "GyroSteam")
	box.add_child(n)
	var g: Dictionary = model.game if "game" in model else {}
	if SteamInput.uri_for(g) != "":
		var b := SKit.action(TC.GYRO_STEAM_OPEN, "gamepad", "OpenSteamInput")
		b.pressed.connect(func(): SteamInput.open(g))
		box.add_child(b)
		parts.append(b)
