extends "res://scripts/ui/device/device_panel.gd"
## Fixes page: every fix for this exact handheld, one card each: plain title,
## a one-line "what it fixes", a status chip (Applied / Needed / Available /
## Not needed / Already fixed by the system ...), whether GameCove applied it
## at install, and Undo or Apply. The side column sums it up and shows what
## changed since the last start (a system update re-checks every fix).
##
## services: "fixes" (scripts/device/fixes.gd or a fake with the same API:
## rows(), counts(), act(fix, verb), refresh(), last_changes, now_os_fixed(),
## signals changed(rows), action_finished(fix, verb, ok, message)) and
## "device" (display_name(), support_level()). Nothing polls.

## Emitted after the cards were rebuilt (Apply / Undo / a refresh): the host relinks focus.
signal rebuilt

const Icons := preload("res://scripts/ui/icons.gd")
const TF := preload("res://scripts/ui/texts_fixes.gd")

var buttons := {}            # "apply:<fix>" / "undo:<fix>" / "check:<fix>" -> Button
var _rows: Array = []
var _side: VBoxContainer
var _cards: VBoxContainer


static func build(services_: Dictionary) -> Control:
	var p = load("res://scripts/ui/device/fixes_page.gd").new()
	p.name = "FixesPage"
	p.services = services_
	p._build()
	return p


func _build() -> void:
	_side = side_column(0.7)
	_cards = main_column(1.3)
	var fx := svc("fixes")
	if fx != null:
		listen(fx.changed, _on_changed)
		listen(fx.action_finished, _on_action_finished)
		_rows = fx.rows()
	_fill()


func _device_name() -> String:
	var d := svc("device")
	return str(d.display_name()) if d != null and d.has_method("display_name") else "handheld"


func _on_changed(rows_: Array) -> void:
	_rows = rows_
	_rebuild()


func _on_action_finished(_fix: String, _verb: String, ok: bool, message: String) -> void:
	toast_requested.emit(message, "check" if ok else "alert", "good" if ok else "warn")


func _rebuild() -> void:
	_rebuild_cards()
	rebuilt.emit()


func _rebuild_cards() -> void:
	var f := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	var keep := ""
	for k in buttons:
		if buttons[k] == f:
			keep = k
	if keep == "" and f != null and f.get_parent() == _cards:
		keep = "card:" + String(f.name)
	clear_box(_side)
	clear_box(_cards)
	_fill()
	if keep == "" or not is_inside_tree():
		return
	if keep.begins_with("card:") and _cards.has_node(keep.substr(5)):
		(_cards.get_node(keep.substr(5)) as Control).grab_focus()
		return
	# the same fix keeps focus even when Apply turned into Undo
	var fix := keep.substr(keep.find(":") + 1)
	for k in ["undo:", "apply:", "check:"]:
		if buttons.has(k + fix):
			buttons[k + fix].grab_focus()
			return
	if _cards.has_node("Fix_" + fix.validate_node_name()):
		(_cards.get_node("Fix_" + fix.validate_node_name()) as Control).grab_focus()
	elif not _chain.is_empty():
		_chain[0].grab_focus()


func _fill() -> void:
	buttons.clear()
	_fill_side()
	var focus: Array = []
	if _rows.is_empty():
		var d := svc("device")
		var generic: bool = d != null and d.has_method("support_level") and str(d.support_level()) == "generic"
		var e := DKit.empty_state("check", TF.NO_FIXES_TITLE, TF.GENERIC_LINE if generic else TF.NO_FIXES_LINE)
		_cards.add_child(e)
		chain([])
		return
	for r in _rows:
		focus.append_array(_fix_card(r))
	chain(focus)


func _fill_side() -> void:
	var c := DKit.card(TF.SUMMARY_TITLE, "handheld", "accent", false)
	c[0].name = "Summary"
	var name_l := Kit.label(_device_name(), "HeaderLabel", true)
	name_l.name = "DeviceName"
	name_l.add_theme_font_override("font", ThemeLib.font("display"))
	c[1].add_child(name_l)
	var intro := DKit.quiet(TF.PAGE_LINE % _device_name())
	intro.name = "Intro"
	c[1].add_child(intro)
	var fx := svc("fixes")
	var n: Dictionary = fx.counts() if fx != null else {}
	var lines := [["yes", TF.SUMMARY_APPLIED, "applied"], ["maybe", TF.SUMMARY_AVAILABLE, "available"],
		["yes", TF.SUMMARY_OS, "os-fixed"], ["none", TF.SUMMARY_NOT_NEEDED, "not-needed"]]
	for l in lines:
		var k: int = int(n.get(l[2], 0))
		if k > 0:
			var row := DKit.check_line(l[0], l[1] % k)
			row.name = "Count_" + str(l[2]).replace("-", "_")
			c[1].add_child(row)
	_side.add_child(c[0])
	if fx != null:
		_changes_card(fx)


func _changes_card(fx: Object) -> void:
	var ch: Dictionary = fx.last_changes if fx.get("last_changes") is Dictionary else {}
	if ch.is_empty():
		return
	var c := DKit.card(TF.CHANGES_TITLE, "update", "info", false)
	c[0].name = "Changes"
	var list: Array = ch.get("changed", [])
	if bool(ch.get("first_run", false)):
		c[1].add_child(DKit.quiet(TF.CHANGES_FIRST))
	elif list.is_empty():
		c[1].add_child(DKit.quiet(TF.CHANGES_NONE))
	else:
		for x in list:
			var to: String = str(x.get("to", ""))
			c[1].add_child(DKit.check_line("maybe", TF.CHANGES_LINE % [x.get("what", ""), str(x.get("from", "")).left(40), to.left(40)]))
		c[1].add_child(DKit.quiet(TF.CHANGES_RECHECKED))
		if fx.has_method("now_os_fixed"):
			for f in fx.now_os_fixed():
				var title := f as String
				for r in _rows:
					if r["id"] == f:
						title = r["title"]
				c[1].add_child(DKit.check_line("yes", TF.CHANGES_NOW_OS % title))
	_side.add_child(c[0])


## One fix: [focusables].
func _fix_card(r: Dictionary) -> Array:
	var id: String = r["id"]
	var status: String = r["status"]
	var tone := TF.status_tone(status)
	var c := DKit.card(r["title"], _icon_for(r), tone if tone != "" else "accent", true)
	var card: PanelContainer = c[0]
	card.name = "Fix_" + id.validate_node_name()
	var col: VBoxContainer = c[1]
	var chip := DKit.chip(TF.status_text(status), tone, {"good": "check", "warn": "alert", "bad": "x"}.get(tone, ""))
	chip.name = "Status"
	DKit.head_chip(col, chip)
	var line := Kit.label(r["line"], "", true)
	line.name = "Line"
	col.add_child(line)
	# who applied it
	var who := ""
	if r.get("auto_applied", false):
		who = TF.AUTO_APPLIED
	elif r.get("auto", false) and status in ["needed"]:
		who = TF.AUTO_NOT_YET
	elif not r.get("auto", false) and status in ["available", "applied", "restart"]:
		who = TF.OPTIONAL
	if who != "":
		var w := Kit.label(who, "CaptionLabel")
		w.name = "Who"
		w.add_theme_color_override("font_color", ThemeLib.color("good" if r.get("auto_applied", false) else "text_3"))
		col.add_child(w)
	if str(r.get("reason", "")) != "":
		var why := DKit.quiet(str(r["reason"]))
		why.name = "Reason"
		col.add_child(why)
	if TF.STATUS_NOTES.has(status):
		var note := DKit.quiet(TF.STATUS_NOTES[status])
		note.name = "Note"
		col.add_child(note)
	elif status == "restart" or (status in ["needed", "available"] and TF.RESTART.has(str(r.get("restart", "")))):
		var rn := DKit.quiet(TF.RESTART.get(str(r.get("restart", "")), TF.RESTART["restart"]))
		rn.name = "Restart"
		col.add_child(rn)
	var focus: Array = []
	var row := Kit.hbox(10)
	row.name = "Actions"
	if r.get("can_undo", false):
		row.add_child(_btn("undo:" + id, TF.UNDO, false, id, "undo"))
	if r.get("can_apply", false):
		row.add_child(_btn("apply:" + id, TF.APPLY, true, id, "apply"))
	if r.get("can_check", false):
		row.add_child(_btn("check:" + id, TF.CHECK, false, id, "check"))
	if row.get_child_count() > 0:
		col.add_child(row)
		if r.get("admin", false) and (r.get("can_undo", false) or r.get("can_apply", false)):
			var a := Kit.label(TF.NEEDS_DESKTOP_NOTE, "CaptionLabel", true)
			a.name = "Admin"
			a.add_theme_color_override("font_color", ThemeLib.color("text_3"))
			col.add_child(a)
		for b in row.get_children():
			focus.append(b)
		card.focus_mode = Control.FOCUS_NONE
	else:
		row.free()
		focus.append(card)
	_cards.add_child(card)
	return focus


func _btn(key: String, text: String, primary: bool, fix: String, verb: String) -> Button:
	var b := Kit.button(text, "AccentButton" if primary else "")
	b.name = key.replace(":", "_").validate_node_name()
	b.custom_minimum_size = Vector2(150, 48)
	# Deferred: the action rebuilds the page, which must not free the button
	# while it is still emitting `pressed`.
	b.pressed.connect(func(): press.call_deferred(fix, verb))
	buttons[key] = b
	return b


## Apply / Undo / Check again on one fix.
func press(fix: String, verb: String) -> void:
	var fx := svc("fixes")
	if fx != null:
		fx.act(fix, verb)


static func _icon_for(r: Dictionary) -> String:
	match str(r.get("kind", "")):
		"app":
			return "gauge"
	var id: String = r["id"]
	if "wifi" in id or "d3cold" in id:
		return "wifi"
	if "wakeup" in id or "fingerprint" in id or "powersave" in id:
		return "power"
	if "touch" in id or "vrr" in id:
		return "screen"
	if "gyro" in id:
		return "motion"
	if "buttons" in id:
		return "gamepad"
	return "sparkle"


func hints_for(c: Control) -> Array:
	for k in buttons:
		if buttons[k] == c:
			var verb: String = k.substr(0, k.find(":"))
			return [["A", {"apply": TF.APPLY, "undo": TF.UNDO, "check": TF.CHECK}[verb]], ["B", "Back"]]
	return [["DPAD", "Scroll"], ["B", "Back"]]
