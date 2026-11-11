extends "res://scripts/ui/device/device_panel.gd"
## Fixes page: the fixes for this exact handheld in four groups: Applied, Recommended for your
## <device>, Optional, Not needed any more. One card each: plain title, a Recommended / Optional
## badge (and Tested on hardware when we ran it on this model), a status chip, a one-line "what it
## fixes", and Undo or Apply. Details opens what it changes, how it's undone, why it applies here,
## its risk, when it was last checked against its sources and a QR code to the source. History
## lists what GameCove changed by itself (a fix the system now does itself was removed, one was
## updated) with "Keep it anyway". The side column sums it up and shows what changed since the
## last start (a system update re-checks every fix). docs/FIXES.md.
##
## services: "fixes" (scripts/device/fixes.gd or a fake with the same API:
## rows(), counts(), act(fix, verb), refresh(), last_changes, now_os_fixed(), and optionally
## history(), keep(fix), run_pending(fix), data_result; signals changed(rows),
## action_finished(fix, verb, ok, message)) and "device" (display_name(), support_level()).
## Nothing polls.

## Emitted after the cards were rebuilt (Apply / Undo / a refresh): the host relinks focus.
signal rebuilt

const Icons := preload("res://scripts/ui/icons.gd")
const TF := preload("res://scripts/ui/texts_fixes.gd")
const QR := preload("res://scripts/ui/settings/qr.gd")
const GROUPS := ["applied", "recommended", "optional", "retired"]

## "apply:<fix>" / "undo:<fix>" / "check:<fix>" / "details:<fix>" / "pending:<fix>" / "keep:<fix>" -> Button
var buttons := {}
## Fixes whose Details are open.
var expanded := {}
var _rows: Array = []
var _side: VBoxContainer
var _cards: VBoxContainer
## The fix whose Details just opened: its panel takes focus once the cards are rebuilt.
var _focus_details := ""


## An open Details block: one stop in the focus chain (D-pad down from the buttons brings it
## into view, however tall), drawn as a soft inset with the focus ring while it holds focus.
class DetailsPanel extends PanelContainer:
	const TL := preload("res://theme/gamecove_theme.gd")

	func _init() -> void:
		focus_mode = Control.FOCUS_ALL
		mouse_filter = Control.MOUSE_FILTER_STOP
		focus_entered.connect(queue_redraw)
		focus_exited.connect(queue_redraw)
		_restyle()

	var _styling := false

	func _restyle() -> void:
		if _styling:
			return   # the override itself sends THEME_CHANGED
		_styling = true
		add_theme_stylebox_override("panel", TL.box(TL.soft(0.05), TL.radius("m"), 18, 14))
		_styling = false

	func _draw() -> void:
		if has_focus():
			draw_style_box(TL.row_focus(TL.radius("m")), Rect2(Vector2.ZERO, size))

	func _notification(what: int) -> void:
		if what == NOTIFICATION_THEME_CHANGED:
			_restyle()
			queue_redraw()


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
	for k in [keep.substr(0, keep.find(":") + 1), "undo:", "apply:", "check:", "pending:", "details:", "keep:"]:
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
	for g in GROUPS:
		var members := _rows.filter(func(r): return str(r.get("group", _group_fallback(r))) == g)
		# what is in the system's way comes first (a stable sort keeps the service's order otherwise)
		var first := members.filter(func(r): return r.get("harmful", false))
		members = first + members.filter(func(r): return not r.get("harmful", false))
		if members.is_empty():
			continue
		_group_head(g)
		for r in members:
			focus.append_array(_fix_card(r))
	focus.append_array(_history_card())
	chain(focus)


## A fake service without groups (older tests): by status.
static func _group_fallback(r: Dictionary) -> String:
	var st := str(r.get("status", ""))
	if st in ["applied", "restart", "partial"]:
		return "applied"
	if st in ["os-fixed", "retired", "not-needed"]:
		return "retired"
	return "recommended" if r.get("auto", false) else "optional"


func _group_head(g: String) -> void:
	var box := Kit.vbox(2)
	box.name = "Group_" + g
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var title: String = TF.GROUP_TITLES[g]
	var t := Kit.label(title % _device_name() if title.contains("%s") else title, "HeaderLabel", true)
	t.name = "Title"
	box.add_child(t)
	var l := DKit.quiet(TF.GROUP_LINES[g])
	l.name = "Line"
	box.add_child(l)
	_cards.add_child(box)


## What GameCove changed by itself, newest first: [focusables].
func _history_card() -> Array:
	var fx := svc("fixes")
	if fx == null or not fx.has_method("history"):
		return []
	var list: Array = fx.history()
	if list.is_empty():
		return []
	var c := DKit.card(TF.HISTORY_TITLE, "update", "info", true)
	var card: PanelContainer = c[0]
	card.name = "History"
	var focus: Array = []
	var shown := 0
	var offered := {}
	for e in list:
		if shown >= 8:
			break
		shown += 1
		var row := Kit.vbox(4)
		row.name = "Entry%d" % shown
		var when := Time.get_date_string_from_unix_time(int(e.get("time", 0)))
		var line := Kit.label("%s  %s" % [when, TF.history_line(e)], "", true)
		line.name = "Line"
		row.add_child(line)
		if str(e.get("detail", "")) != "" and str(e.get("action", "")) in ["update-failed", "update-removed", "remove-failed"]:
			row.add_child(DKit.quiet(str(e["detail"])))
		var fix := str(e.get("fix", ""))
		if str(e.get("action", "")) == "removed" and not bool(e.get("undone", false)) and not offered.has(fix) and fx.has_method("keep"):
			offered[fix] = true
			var b := _btn("keep:" + fix, TF.KEEP, false, fix, "keep")
			row.add_child(b)
			focus.append(b)
		c[1].add_child(row)
	if not focus.is_empty():
		card.focus_mode = Control.FOCUS_NONE
	else:
		focus.append(card)
	_cards.add_child(card)
	return focus


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
	var lines := [["maybe", TF.SUMMARY_HARMFUL, "harmful"], ["yes", TF.SUMMARY_APPLIED, "applied"], ["maybe", TF.SUMMARY_RECOMMENDED, "recommended"],
		["maybe", TF.SUMMARY_OPTIONAL, "optional"], ["yes", TF.SUMMARY_RETIRED, "retired"], ["none", TF.SUMMARY_HIDDEN, "not-needed"]]
	if not n.has("recommended"):
		lines = [["yes", TF.SUMMARY_APPLIED, "applied"], ["maybe", TF.SUMMARY_AVAILABLE, "available"],
			["yes", TF.SUMMARY_OS, "os-fixed"], ["none", TF.SUMMARY_NOT_NEEDED, "not-needed"]]
	for l in lines:
		var k: int = int(n.get(l[2], 0))
		if k > 0:
			var row := DKit.check_line(l[0], l[1] % k)
			row.name = "Count_" + str(l[2]).replace("-", "_")
			c[1].add_child(row)
	if n.has("recommended") and int(n.get("recommended", 0)) == 0 and int(n.get("harmful", 0)) == 0:
		var done := DKit.check_line("yes", TF.SUMMARY_NOTHING_LEFT % _device_name())
		done.name = "NothingLeft"
		c[1].add_child(done)
	var data := str(fx.get("data_result")) if fx != null and fx.get("data_result") is String else ""
	if TF.DATA_LINES.has(data):
		var dl := DKit.quiet(TF.DATA_LINES[data])
		dl.name = "DataLine"
		c[1].add_child(dl)
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
	var harmful: bool = r.get("harmful", false)
	# one that clashes with the system's own fix while it waits for the password: said loudly
	var tone := "bad" if harmful else TF.status_tone(status)
	var c := DKit.card(r["title"], _icon_for(r), tone if tone != "" else "accent", true)
	var card: PanelContainer = c[0]
	card.name = "Fix_" + id.validate_node_name()
	var col: VBoxContainer = c[1]
	var chip := DKit.chip(TF.HARMFUL_CHIP if harmful else TF.status_text(status), tone,
		"alert" if harmful else {"good": "check", "warn": "alert", "bad": "x"}.get(tone, ""))
	chip.name = "Status"
	DKit.head_chip(col, chip)
	# Recommended / Optional (the owner's two words), and Tested on hardware when it was, here
	var level := str(r.get("level", "recommended" if r.get("auto", false) else "optional"))
	var badges := Kit.hbox(8)
	badges.name = "Badges"
	badges.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if level != "advice":
		var lv := DKit.chip(TF.LEVEL[level], "info" if level == "recommended" else "")
		lv.name = "Level"
		badges.add_child(lv)
	if r.get("tested", false):
		var tb := DKit.chip(TF.TESTED_BADGE, "good", "check")
		tb.name = "Tested"
		badges.add_child(tb)
	if badges.get_child_count() > 0:
		col.add_child(badges)
	else:
		badges.free()
	var line := Kit.label(r["line"], "", true)
	line.name = "Line"
	col.add_child(line)
	# who applied it
	var who := ""
	if r.get("auto_applied", false):
		who = TF.AUTO_APPLIED
	elif r.get("auto", false) and status in ["needed"]:
		who = TF.AUTO_NOT_YET
	if who != "":
		var w := Kit.label(who, "CaptionLabel")
		w.name = "Who"
		w.add_theme_color_override("font_color", ThemeLib.color("good" if r.get("auto_applied", false) else "text_3"))
		col.add_child(w)
	if str(r.get("reason", "")) != "":
		var why := DKit.quiet(str(r["reason"]))
		why.name = "Reason"
		col.add_child(why)
	var pending := str(r.get("pending", ""))
	var note := ""
	if pending == "update":
		note = TF.PENDING_UPDATE
	elif pending == "retire":
		if str(r.get("pending_reason", "")) == "withdrawn":
			note = TF.PENDING_WITHDRAWN % str(r.get("withdrawn", ""))
		else:
			note = TF.HARMFUL_NOTE if harmful else TF.PENDING_RETIRE
	elif status == "retired":
		note = TF.RETIRED_WITHDRAWN % str(r["withdrawn"]) if str(r.get("withdrawn", "")) != "" else TF.RETIRED_NATIVE
	elif r.get("kept", false) and status in ["applied", "restart"]:
		note = TF.KEPT_NOTE
	elif TF.STATUS_NOTES.has(status):
		note = TF.STATUS_NOTES[status]
	if note != "":
		var nl := DKit.quiet(note)
		nl.name = "Note"
		col.add_child(nl)
	elif status == "restart" or (status in ["needed", "available"] and TF.RESTART.has(str(r.get("restart", "")))):
		var rn := DKit.quiet(TF.RESTART.get(str(r.get("restart", "")), TF.RESTART["restart"]))
		rn.name = "Restart"
		col.add_child(rn)
	if r.get("newer_revision", false) and status in ["applied", "restart"]:
		var nr := DKit.quiet(TF.NEWER_NOTE)
		nr.name = "Newer"
		col.add_child(nr)
	var focus: Array = []
	var row := Kit.hbox(10)
	row.name = "Actions"
	var acts := false
	if pending != "":
		row.add_child(_btn("pending:" + id, TF.UPDATE_NOW if pending == "update" else TF.REMOVE_NOW, true, id, "pending"))
		acts = true
	elif r.get("can_undo", false):
		row.add_child(_btn("undo:" + id, TF.UNDO, false, id, "undo"))
		acts = true
	if r.get("can_apply", false):
		row.add_child(_btn("apply:" + id, TF.APPLY, true, id, "apply"))
		acts = true
	if r.get("can_check", false):
		row.add_child(_btn("check:" + id, TF.CHECK, false, id, "check"))
	if _has_details(r):
		row.add_child(_btn("details:" + id, TF.HIDE_DETAILS if expanded.has(id) else TF.DETAILS, false, id, "details"))
	if row.get_child_count() > 0:
		col.add_child(row)
		if r.get("admin", false) and acts:
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
	if expanded.has(id):
		var d := _details(r)
		col.add_child(d)
		focus.append(d)
		buttons["panel:" + id] = d
	_cards.add_child(card)
	return focus


static func _has_details(r: Dictionary) -> bool:
	return not (r.get("changes", []) as Array).is_empty() or str(r.get("undo_text", "")) != "" \
		or str(r.get("link", "")) != "" or str(r.get("why", "")) != ""


func _detail_block(box: VBoxContainer, head: String, lines: Array) -> void:
	if lines.is_empty():
		return
	var h := Kit.micro(head, "EyebrowLabel")
	h.add_theme_color_override("font_color", ThemeLib.color("text_3"))
	box.add_child(h)
	for l in lines:
		box.add_child(Kit.label(str(l), "CaptionLabel", true))


## What it changes, how it's undone, why here, risk, tested on, last audited, and the source as a QR code.
func _details(r: Dictionary) -> Control:
	var panel := DetailsPanel.new()
	panel.name = "Details"
	var wrap := Kit.hbox(18)
	wrap.name = "Body"
	wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(wrap)
	var box := Kit.vbox(6)
	box.name = "Text"
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_detail_block(box, TF.CHANGES_HEAD, r.get("changes", []))
	if str(r.get("undo_text", "")) != "":
		_detail_block(box, TF.UNDO_HEAD, [r["undo_text"]])
	if str(r.get("why", "")) != "":
		_detail_block(box, TF.WHY_HEAD % _device_name(), [r["why"]])
	if str(r.get("risk", "")) != "" and r.get("kind", "") != "advice":
		_detail_block(box, TF.RISK_HEAD, ["%s. %s" % [TF.RISK.get(str(r["risk"]), str(r["risk"])), str(r.get("risk_note", ""))]])
	if r.get("kind", "") != "advice":
		var tested: Array = []
		for t in r.get("tested_on", []):
			tested.append("%s, %s (%s)" % [str(t.get("name", t.get("device", ""))), str(t.get("os", "")), str(t.get("date", ""))])
		_detail_block(box, TF.TESTED_HEAD, tested if not tested.is_empty() else [TF.TESTED_NONE])
	if str(r.get("audited", "")) != "":
		var au := DKit.quiet(TF.AUDITED % str(r["audited"]))
		au.name = "Audited"
		box.add_child(au)
	wrap.add_child(box)
	var link := str(r.get("link", ""))
	if link != "":
		var side := Kit.vbox(4)
		side.name = "Source"
		side.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var qr := TextureRect.new()
		qr.name = "Qr"
		qr.texture = QR.texture(link, 4)
		qr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		qr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		qr.custom_minimum_size = Vector2(132, 132)
		side.add_child(qr)
		var cap := Kit.label(TF.SOURCES_QR, "CaptionLabel")
		cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cap.add_theme_color_override("font_color", ThemeLib.color("text_3"))
		side.add_child(cap)
		wrap.add_child(side)
	return panel


func _btn(key: String, text: String, primary: bool, fix: String, verb: String) -> Button:
	var b := Kit.button(text, "AccentButton" if primary else "")
	b.name = key.replace(":", "_").validate_node_name()
	b.custom_minimum_size = Vector2(150, 48)
	# Deferred: the action rebuilds the page, which must not free the button
	# while it is still emitting `pressed`.
	b.pressed.connect(func(): press.call_deferred(fix, verb))
	buttons[key] = b
	return b


## Apply / Undo / Check again on one fix; Details opens and closes; "pending" runs what waits
## for the admin password; "keep" is History's "Keep it anyway".
func press(fix: String, verb: String) -> void:
	if verb == "details":
		if expanded.has(fix):
			expanded.erase(fix)
		else:
			expanded[fix] = true
			_focus_details = fix
		_rebuild()
		# opened: the panel takes focus, so the column scrolls to what was asked for
		if _focus_details != "" and buttons.has("panel:" + _focus_details) and is_inside_tree():
			(buttons["panel:" + _focus_details] as Control).grab_focus()
		_focus_details = ""
		return
	var fx := svc("fixes")
	if fx == null:
		return
	if verb == "pending":
		if fx.has_method("run_pending"):
			fx.run_pending(fix)
	elif verb == "keep":
		if fx.has_method("keep"):
			fx.keep(fix)
	else:
		fx.act(fix, verb)


static func _icon_for(r: Dictionary) -> String:
	match str(r.get("kind", "")):
		"app":
			return "gauge"
	var id: String = r["id"]
	if "wifi" in id or "d3cold" in id:
		return "wifi"
	if "wakeup" in id or "fingerprint" in id or "powersave" in id or "sleep" in id or "power-button" in id:
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
		if buttons[k] == c and k.begins_with("panel:"):
			return [["DPAD", "Scroll"], ["B", "Back"]]
		if buttons[k] == c:
			var verb: String = k.substr(0, k.find(":"))
			var label: String = (buttons[k] as Button).text
			return [["A", {"apply": TF.APPLY, "undo": TF.UNDO, "check": TF.CHECK}.get(verb, label)], ["B", "Back"]]
	return [["DPAD", "Scroll"], ["B", "Back"]]
