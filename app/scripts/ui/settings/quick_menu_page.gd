extends "res://scripts/ui/settings/page.gd"
## Settings > Quick menu: which shortcuts the quick menu's strip shows, and in
## what order. A plain list: left / right turns one on or off, X moves it up, Y
## moves it down. Saved at once (scripts/actions/shortcut_prefs.gd); the strip
## picks it up the next time the menu opens.
##
## services: "actions" (the action runner) says which shortcuts work on this
## handheld; without it every one is listed as usable.

const Registry := preload("res://scripts/actions/registry.gd")
const Prefs := preload("res://scripts/actions/shortcut_prefs.gd")
const CIcons := preload("res://scripts/ui/controls/cicons.gd")
const T := preload("res://scripts/ui/quick/texts_shortcuts.gd")

## Reasons that only mean "not right now" (a game isn't on screen): not worth a line.
const SITUATIONAL := ["no_game_front", "no_game"]


func build() -> void:
	var box := add_card(T.CARD, "sliders", T.CARD_LINE)
	var ids := Prefs.all()
	var actions := svc("actions")
	var ctx: Dictionary = actions.context() if actions != null and actions.has_method("context") else {}
	for i in ids.size():
		var id: String = ids[i]
		var a := Registry.action(id)
		var r: VBoxContainer = ChoiceRow.new()
		r.setup(id, str(a["title"]), [false, true], [T.ROW_OFF, T.ROW_ON], Prefs.is_shown(id), "")
		var icon := CIcons.rect(str(a["icon"]), 22, ThemeLib.color("text_2"))
		icon.name = "Icon"
		r._row.add_child(icon)
		r._row.move_child(icon, 0)
		var why := Registry.why_not(id, ctx) if not ctx.is_empty() else ""
		var line := str(a["help"])
		if why != "" and not why in SITUATIONAL:
			line += " " + T.NOT_HERE % Registry.why_text(why)
		r.set_explainer(fixed(line + " " + T.MOVE_HINT))
		r.changed.connect(func(v): Prefs.set_shown(id, bool(v)))
		add_row(box, r)
	var reset := action_row(box, "reset_shortcuts", T.RESET, "", T.RESET_HINT, "reset")
	# after the press is over: rebuilding frees the row that is emitting it
	reset.pressed.connect(func(): call_deferred("reset_all"))


## The reset row: the usual shortcuts in the usual order.
func reset_all() -> void:
	Prefs.reset()
	notify(T.RESET_DONE, "good")
	rebuild()


## The shortcut whose row has focus, or "".
func focused_id() -> String:
	var f := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	for id in rows:
		if id != "reset_shortcuts" and f != null and rows[id].button == f:
			return id
	return ""


## Moves the focused shortcut up (-1) or down (+1); focus follows it.
func move_focused(d: int) -> bool:
	return move(focused_id(), d)


func move(id: String, d: int) -> bool:
	if id == "" or not Prefs.move(id, d):
		return false
	rebuild()
	if rows.has(id) and is_inside_tree():
		rows[id].button.grab_focus()
	return true


## Hint bar extras while a shortcut's row has focus (settings_screen.hints()).
func extra_hints(_f: Control) -> Array:
	return [["X", T.MOVE_UP], ["Y", T.MOVE_DOWN]] if focused_id() != "" else []


func _unhandled_input(event: InputEvent) -> void:
	if not is_visible_in_tree() or focused_id() == "":
		return
	var d := 0
	if event is InputEventJoypadButton and event.pressed:
		d = -1 if event.button_index == JOY_BUTTON_X else (1 if event.button_index == JOY_BUTTON_Y else 0)
	elif event is InputEventKey and event.pressed and not event.echo:
		d = -1 if event.keycode == KEY_X else (1 if event.keycode == KEY_Y else 0)
	if d == 0:
		return
	move_focused(d)
	get_viewport().set_input_as_handled()
