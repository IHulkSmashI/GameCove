extends "res://scripts/ui/device/device_panel.gd"
## Updates page: the system image, firmware and Flatpak apps, each with its
## state, Check / Update, a progress bar while installing, "Restart to finish"
## once staged, and a Restart button. Nothing installs while a game runs;
## kinds this system can't update say why. Checks only run when asked.

const Icons := preload("res://scripts/ui/icons.gd")

var state: Dictionary = {}
var buttons := {}          # "check:os", "apply:os", "check_all", "reboot", "apply:firmware:<id>" -> Button
var _progress := {}        # kind -> [percent, line]
var _messages := {}        # kind -> last finished message (shown under the card)
var _side: VBoxContainer
var _cards: VBoxContainer


static func build(services_: Dictionary) -> Control:
	var p = load("res://scripts/ui/device/updates_panel.gd").new()
	p.name = "UpdatesPanel"
	p.services = services_
	p._build()
	return p


func _build() -> void:
	_side = side_column(0.7)
	_cards = main_column(1.3)
	var up := svc("updates")
	if up != null:
		listen(up.changed, _on_changed)
		listen(up.progress, _on_progress)
		listen(up.finished, _on_finished)
		state = up.state()
	_fill()


func _on_changed(s: Dictionary) -> void:
	state = s
	_rebuild()


func _on_progress(kind: String, percent: float, line: String) -> void:
	_progress[kind] = [percent, line]
	var bar: Variant = _cards.find_child("Progress_" + kind, true, false)
	if bar != null:
		bar.set_fraction(percent / 100.0 if percent >= 0.0 else 0.0)
		var l: Variant = _cards.find_child("ProgressLine_" + kind, true, false)
		if l != null:
			l.text = _progress_text(kind)
	else:
		_rebuild()


func _on_finished(kind: String, ok: bool, message: String) -> void:
	_progress.erase(kind)
	if ok:
		_messages.erase(kind)
	else:
		_messages[kind] = Texts.finished_text(kind, message)
		toast_requested.emit(_messages[kind], "alert", "warn")
	var up := svc("updates")
	if up != null:
		state = up.state()
	_rebuild()


func _rebuild() -> void:
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
	if keep.begins_with("card:") and _cards.has_node(keep.substr(5)):
		(_cards.get_node(keep.substr(5)) as Control).grab_focus()
	elif buttons.has(keep) and not buttons[keep].disabled:
		buttons[keep].grab_focus()
	elif keep != "" and not _chain.is_empty() and is_inside_tree():
		_chain[0].grab_focus()


func _phase(kind: String) -> String:
	var ph: Dictionary = state.get("phase", {}) if state.get("phase") is Dictionary else {}
	return str(ph.get(kind, "unsupported"))


func _game_running() -> bool:
	return bool(state.get("game_running", false))


func _btn(key: String, text: String, primary := false) -> Button:
	var b := Kit.button(text, "AccentButton" if primary else "")
	b.name = key.replace(":", "_")
	b.custom_minimum_size = Vector2(0, 48)
	buttons[key] = b
	return b


func _fill() -> void:
	buttons.clear()
	_fill_side()
	var focus: Array = []
	for kind in Texts.KINDS:
		focus.append_array(_kind_card(kind))
	chain(focus)


func _fill_side() -> void:
	var info: Dictionary = state.get("os_info", {}) if state.get("os_info") is Dictionary else {}
	var c := DKit.card("This system", "info", "accent", false)
	c[0].name = "Summary"
	var name_l := Kit.label(str(info.get("name", Texts.UNKNOWN)), "HeaderLabel", true)
	name_l.name = "OsName"
	name_l.add_theme_font_override("font", ThemeLib.font("display"))
	c[1].add_child(name_l)
	var ver := " · ".join(PackedStringArray([str(info.get("version", "")), str(info.get("variant", ""))].filter(func(x): return x != "")))
	if ver != "":
		c[1].add_child(Kit.label(ver, "QuietLabel", true))
	var busy := Texts.KINDS.any(func(k): return _phase(k) in ["checking", "applying"])
	var check := _btn("check_all", Texts.CHECK_ALL, true)
	check.disabled = busy or Texts.KINDS.all(func(k): return _phase(k) == "unsupported")
	check.pressed.connect(func(): svc("updates").check_updates())
	c[1].add_child(check)
	if bool(state.get("reboot_needed", false)) or Texts.KINDS.any(func(k): return _phase(k) == "staged"):
		c[1].add_child(DKit.check_line("maybe", Texts.REBOOT_LINE))
		var rb := _btn("reboot", Texts.REBOOT)
		rb.disabled = _game_running()
		rb.pressed.connect(func(): svc("updates").reboot())
		c[1].add_child(rb)
	if _game_running():
		c[1].add_child(DKit.check_line("maybe", Texts.GAME_RUNNING))
	_side.add_child(c[0])


func _progress_text(kind: String) -> String:
	var p: Array = _progress.get(kind, [-1.0, ""])
	var pct := "%d%%" % roundi(float(p[0])) if float(p[0]) >= 0.0 else ""
	return " · ".join(PackedStringArray([pct, str(p[1]).strip_edges().left(80)].filter(func(x): return x != "")))


## Focusables of one kind's card.
func _kind_card(kind: String) -> Array:
	var ph := _phase(kind)
	var c := DKit.card(Texts.KIND_TITLES[kind], Texts.KIND_ICONS[kind], {"error": "bad", "available": "info", "staged": "warn"}.get(ph, "accent"))
	c[0].name = "Card_" + kind
	DKit.head_chip(c[1], DKit.chip(Texts.PHASES.get(ph, ph), Texts.PHASE_TONES.get(ph, ""),
		{"up_to_date": "check", "error": "alert", "staged": "power"}.get(ph, "")))
	_cards.add_child(c[0])
	if ph == "unsupported":
		c[1].add_child(DKit.quiet(Texts.UNSUPPORTED_WHY[kind]))
		return [c[0]]
	c[1].add_child(DKit.quiet(Texts.KIND_LINES[kind]))
	var data: Dictionary = state.get(kind, {}) if state.get(kind) is Dictionary else {}
	match kind:
		"os":
			var lines := []
			if str(data.get("current", "")) != "":
				lines.append(Texts.VERSION_NOW % data["current"])
			if bool(data.get("available", false)) and str(data.get("version", "")) != "":
				lines.append(Texts.VERSION_NEW % data["version"])
			if bool(data.get("staged", false)) and str(data.get("staged_version", "")) != "":
				lines.append("Ready after restart: %s" % data["staged_version"])
			for l in lines:
				var ll := Kit.label(l, "")
				ll.add_theme_font_override("font", ThemeLib.font("medium", true))
				c[1].add_child(ll)
		"firmware":
			for dev in (data.get("devices", []) if data.get("devices") is Array else []):
				var row := Kit.vbox(2)
				row.mouse_filter = Control.MOUSE_FILTER_IGNORE
				var t := Kit.label("%s  ·  %s → %s" % [dev.get("name", ""), dev.get("current", "?"), dev.get("version", "?")], "", true)
				t.add_theme_font_override("font", ThemeLib.font("medium", true))
				row.add_child(t)
				if not bool(dev.get("trusted", true)):
					row.add_child(DKit.check_line("maybe", Texts.FIRMWARE_UNTRUSTED))
				elif bool(dev.get("needs_reboot", false)):
					row.add_child(Kit.label(Texts.FIRMWARE_REBOOT, "CaptionLabel"))
				c[1].add_child(row)
		"flatpak":
			var pending: Array = data.get("pending", []) if data.get("pending") is Array else []
			if not pending.is_empty():
				var names := PackedStringArray(pending.slice(0, 4).map(func(p): return str(p.get("name", p.get("id", "")))))
				var more := " and %d more" % (pending.size() - 4) if pending.size() > 4 else ""
				var pl := Kit.label("%s: %s%s" % [Texts.apps(pending.size()), ", ".join(names), more], "", true)
				pl.add_theme_font_override("font", ThemeLib.font("medium"))
				c[1].add_child(pl)
	if ph == "applying":
		var p: Array = _progress.get(kind, [-1.0, ""])
		var bar := DKit.UsageBar.new(float(p[0]) / 100.0 if float(p[0]) >= 0.0 else 0.0, "info", 10)
		bar.name = "Progress_" + kind
		c[1].add_child(bar)
		var pl2 := Kit.label(_progress_text(kind), "CaptionLabel", true)
		pl2.name = "ProgressLine_" + kind
		c[1].add_child(pl2)
	var err := str(data.get("error", ""))
	var msg := str(_messages.get(kind, ""))
	if msg == "" and ph == "error" and err != "":
		msg = Texts.finished_text(kind, err)
	if msg != "":
		var m := DKit.check_line("maybe", msg)
		m.name = "Message"
		c[1].add_child(m)
	var row_b := Kit.hbox(12)
	row_b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var focus: Array = []
	if ph == "available":
		var ap := _btn("apply:" + kind, Texts.APPLY_ALL_FW if kind == "firmware" else Texts.APPLY, true)
		ap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		ap.disabled = _game_running()
		ap.pressed.connect(func(): svc("updates").apply(kind))
		row_b.add_child(ap)
		if not ap.disabled:
			focus.append(ap)
	if not ph in ["checking", "applying"]:
		var ck := _btn("check:" + kind, Texts.CHECK)
		ck.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		ck.pressed.connect(func(): svc("updates").check(kind))
		row_b.add_child(ck)
		focus.append(ck)
	if row_b.get_child_count() > 0:
		c[1].add_child(row_b)
	if _game_running() and ph == "available":
		c[1].add_child(DKit.quiet(Texts.GAME_RUNNING))
	if focus.is_empty():
		focus.append(c[0])
	return focus


func default_focus() -> Control:
	if buttons.has("check_all") and not buttons["check_all"].disabled:
		return buttons["check_all"]
	return super.default_focus()


func _link() -> void:
	# The side buttons sit above the cards in the chain.
	var side: Array = []
	for k in ["check_all", "reboot"]:
		if buttons.has(k) and not buttons[k].disabled:
			side.append(buttons[k])
	var all := side + _chain.filter(func(c): return not c in side)
	if all.is_empty():
		return
	Kit.link_vertical(all, top_target)
	for s in side:
		if not s.focus_entered.is_connected(_on_focus.bind(s)):
			s.focus_entered.connect(_on_focus.bind(s))


func focus_chain() -> Array:
	var side: Array = []
	for k in ["check_all", "reboot"]:
		if buttons.has(k) and not buttons[k].disabled:
			side.append(buttons[k])
	return side + _chain


func hints_for(c: Control) -> Array:
	if c is Button:
		return [["A", c.text], ["B", "Back"]]
	return [["DPAD", "Scroll"], ["B", "Back"]]
