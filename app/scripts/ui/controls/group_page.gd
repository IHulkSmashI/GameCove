extends "res://scripts/ui/settings/page.gd"
## A Settings page made from Controls groups (Power, Display, Sound,
## Controller, System): every setting the providers register, in the cards
## catalog.gd lays out, each with its state (see control_view.gd). Built the
## first time it's shown. Rebuilds itself when detection changes what this
## handheld can use. Values set here are the everyday ones (a game with its
## own settings keeps those; the note at the top says how many).
##
## services: "controls" (Controls or a fake), "profiles" (optional).

const TC := preload("res://scripts/ui/texts_controls.gd")
const Model := preload("res://scripts/ui/controls/model.gd")
const GroupCards := preload("res://scripts/ui/controls/group_cards.gd")

var groups: Array = []
var model: Object
var cards: Object
## Build on first show (true in the settings screen).
var lazy := true
var _built := false
var _sig := ""


func setup(page_id: String, svc_: Dictionary, host_obj: Object) -> void:
	groups = TC.CATEGORY_GROUPS_OF.get(page_id, [page_id])
	super.setup(page_id, svc_, host_obj)


func _connect() -> void:
	var c := svc("controls")
	if c != null:
		model = Model.new()
		model.setup(c, svc("profiles"))
		model.refreshed.connect(_on_refreshed)


func build() -> void:
	cards = null
	if lazy and not _built:
		return
	if model == null:
		var box := add_card(TC.CATEGORY_NAMES.get(id, id), TC.CATEGORY_ICONS.get(id, "sliders"))
		box.add_child(SKit.note(TC.NO_CONTROLS, "info", "NoControls"))
		return
	_profiles_note()
	cards = GroupCards.new()
	cards.relinked.connect(func(): rebuilt.emit())
	cards.build(self, model, groups, host as Control if host is Control else null)
	_sig = cards.signature()
	build_extra()


## Subclasses: cards after the generated ones (use add_card / toggle).
## Controller links to the button map and test (the device's controller
## panel), which used to be a second "Controller" tab under Device.
func build_extra() -> void:
	if id != "controller" or host == null or not host.has_method("open_category"):
		return
	var box := add_card(TC.BUTTONS_CARD, "gamepad")
	var r := action_row(box, "button_map", TC.BUTTONS_ROW, "", TC.BUTTONS_ROW_HINT, "gamepad")
	r.pressed.connect(func(): host.open_category("device", "controller"))


## "2 games have their own settings": these are the everyday values.
func _profiles_note() -> void:
	var p := svc("profiles")
	if p == null or not p.has_method("games"):
		return
	var n: int = p.games().size()
	if n == 0:
		return
	var text := ("%d games have their own settings. " % n if n > 1 else "One game has its own settings. ") + "These are your everyday ones."
	add_child(SKit.note(text, "info", "ProfilesNote"))


func focusables() -> Array:
	var out: Array = cards.focusables() if cards != null else []
	out.append_array(_focusables)
	return out


func on_shown() -> void:
	if not _built:
		_built = true
		rebuild()


func on_hidden() -> void:
	pass


## Detection finished or a profile changed: rebuild only when what's usable changed.
func _on_refreshed() -> void:
	if cards == null:
		return
	var sig: String = cards.signature()
	if sig != _sig:
		rebuild()


## Rebuilds and keeps focus on the same setting.
func rebuild() -> void:
	var keep := _focused_key()
	for c in get_children():
		Kit.drop(self, c)
	_focusables.clear()
	rows.clear()
	build()
	rebuilt.emit()
	if keep != "" and is_inside_tree():
		for f in focusables():
			var n: Node = f
			while n != null and n != self:
				if "key" in n and str(n.get("key")) == keep:
					f.grab_focus.call_deferred()
					return
				n = n.get_parent()


func _focused_key() -> String:
	if not is_inside_tree():
		return ""
	var f := get_viewport().gui_get_focus_owner()
	if f == null or not is_ancestor_of(f):
		return ""
	var n: Node = f
	while n != null and n != self:
		if n.has_method("explanation") and "key" in n:
			return str(n.get("key"))
		n = n.get_parent()
	return ""


## Settings asked to open this page at `part` (unused here).
func focus_part(_part: String) -> Control:
	var f := focusables()
	return f[0] if not f.is_empty() else null
