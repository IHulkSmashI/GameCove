extends "res://scripts/ui/device/device_panel.gd"
## Updates page: the system image, firmware and Flatpak apps, each with its
## state, Check / Update, a progress bar while installing, "Restart to finish"
## once staged, and a Restart button. Nothing installs while a game runs;
## kinds this system can't update say why. Checks only run when asked.
## Below them: the maker's BIOS / EC / controller firmware (from the firmware index, guided steps,
## an ASUS EZ Flash USB drive, a QR of the maker's page) and the driver stack.

const Icons := preload("res://scripts/ui/icons.gd")
const Hub := preload("res://scripts/system/firmware_texts.gd")
const QR := preload("res://scripts/ui/settings/qr.gd")
const ChoiceRow := preload("res://scripts/ui/choice_row.gd")
const TX := preload("res://scripts/ui/texts_extras.gd")

var state: Dictionary = {}
var buttons := {}          # "check:os", "apply:os", "check_all", "reboot", "apply:firmware:<id>" -> Button
var _progress := {}        # kind -> [percent, line]
var _messages := {}        # kind -> last finished message (shown under the card)
var _side: VBoxContainer
var _cards: VBoxContainer
var _qr_for := ""          # hub item id whose maker-page QR is showing


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
	if kind == "usb":
		_messages["maker"] = Hub.USB_DONE % message if ok else str(Hub.REASONS.get(message, message))
		toast_requested.emit(_messages["maker"], "check" if ok else "alert", "good" if ok else "warn")
	elif ok:
		_messages.erase(kind)
	else:
		_messages[kind] = Hub.REASONS[message] if Hub.REASONS.has(message) else Texts.finished_text(kind, message)
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
	focus.append_array(_hub_card("maker"))
	focus.append_array(_hub_card("drivers"))
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
	if kind == "flatpak" and svc("updates") != null and svc("updates").has_method("set_auto_apps"):
		var auto: VBoxContainer = ChoiceRow.bool_row("auto_apps", TX.AUTO_APPS, bool(state.get("auto_apps", false)), "update")
		auto.collapse_hint = false
		auto.set_explainer(func(v): return str(TX.AUTO_APPS_HELP.get(bool(v), "")))
		auto.changed.connect(func(v): svc("updates").set_auto_apps.call_deferred(bool(v)))
		c[1].add_child(auto)
		buttons["auto_apps"] = auto.button
		focus.append(auto.button)
	if _game_running() and ph == "available":
		c[1].add_child(DKit.quiet(Texts.GAME_RUNNING))
	if focus.is_empty():
		focus.append(c[0])
	return focus


func _hub_items(section: String) -> Array:
	var hub: Array = state.get("hub", []) if state.get("hub") is Array else []
	# fwupd devices already sit in the Firmware card above.
	return hub.filter(func(i): return i is Dictionary and i.get("section") == section and i.get("source") != "fwupd")


## Maker firmware ("maker") or driver stack ("drivers"): one row per hub item.
func _hub_card(kind: String) -> Array:
	var ph := _phase(kind)
	var title := Hub.MAKER_TITLE if kind == "maker" else Hub.DRIVERS_TITLE
	var c := DKit.card(title, "bolt" if kind == "maker" else "update", {"error": "bad", "available": "info"}.get(ph, "accent"))
	c[0].name = "Card_" + kind
	DKit.head_chip(c[1], DKit.chip(Texts.PHASES.get(ph, ph), Texts.PHASE_TONES.get(ph, ""),
		{"up_to_date": "check", "error": "alert"}.get(ph, "")))
	_cards.add_child(c[0])
	if ph == "unsupported":
		c[1].add_child(DKit.quiet(Hub.UNSUPPORTED_MAKER))
		return [c[0]]
	c[1].add_child(DKit.quiet(Hub.MAKER_LINE if kind == "maker" else Hub.DRIVERS_LINE))
	var data: Dictionary = state.get(kind, {}) if state.get(kind) is Dictionary else {}
	var focus: Array = []
	var items := _hub_items("firmware" if kind == "maker" else "drivers")
	if str(data.get("error", "")) == "index_unavailable":
		c[1].add_child(DKit.check_line("maybe", Hub.INDEX_UNAVAILABLE))
	elif bool(data.get("stale", false)):
		c[1].add_child(DKit.quiet(Hub.STALE))
	if items.is_empty() and ph in ["idle", "up_to_date"]:
		c[1].add_child(DKit.quiet(Hub.NOTHING))
	for it in items:
		focus.append_array(_hub_row(c[1], it))
	var msg := str(_messages.get(kind, ""))
	if msg != "":
		var m := DKit.check_line("maybe", msg)
		m.name = "Message"
		c[1].add_child(m)
	if not ph in ["checking", "applying"]:
		var ck := _btn("check:" + kind, Hub.CHECK)
		ck.pressed.connect(func(): svc("updates").check(kind))
		c[1].add_child(ck)
		focus.append(ck)
	if focus.is_empty():
		focus.append(c[0])
	return focus


func _hub_row(col: VBoxContainer, it: Dictionary) -> Array:
	var focus: Array = []
	var row := Kit.vbox(4)
	row.name = "Item_" + str(it["id"]).replace(":", "_")
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var head := Kit.hbox(10)
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var status := str(it.get("status", "unknown"))
	var line := ""
	if status == "update":
		line = Hub.NEW_AVAILABLE % [it.get("name", ""), it.get("latest", ""), Hub.YOURS % (it.get("current", "") if str(it.get("current", "")) != "" else "?")]
	else:
		var parts := PackedStringArray([str(it.get("name", ""))])
		if str(it.get("current", "")) != "":
			parts.append(str(it["current"]))
		if status == "upstream" and str(it.get("latest", "")) != "":
			parts.append("upstream " + str(it["latest"]))
		line = "  ·  ".join(parts)
	var t := Kit.label(line, "", true)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	t.add_theme_font_override("font", ThemeLib.font("medium", true))
	head.add_child(t)
	if str(Hub.STATUS.get(status, "")) != "":
		head.add_child(DKit.chip(Hub.STATUS[status], Hub.STATUS_TONES.get(status, "")))
	row.add_child(head)
	var how := str(it.get("how", "link"))
	if it.get("section") == "drivers":
		row.add_child(Kit.label(Hub.DRIVER_HOW.get(how, ""), "CaptionLabel", true))
	else:
		row.add_child(Kit.label(Hub.HOW.get(how, ""), "CaptionLabel", true))
		if str(it.get("upstream_note", "")) != "":
			row.add_child(Kit.label(Hub.UPSTREAM_NOTE % it["upstream_note"], "CaptionLabel", true))
		if str(it.get("service", "")) in ["disabled", "masked"]:
			row.add_child(DKit.check_line("maybe", Hub.SERVICE_OFF))
		var notes := str(it.get("notes", "")).strip_edges()
		if notes != "" and status == "update":
			row.add_child(DKit.quiet(notes.get_slice("\n", 0).left(160)))
		if status == "update" or how == "link":
			var steps: Array = Hub.STEPS.get(str(it.get("flash", "link")), [])
			for i in steps.size():
				row.add_child(Kit.label("%d. %s" % [i + 1, steps[i]], "CaptionLabel", true))
		var btns := Kit.hbox(12)
		btns.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var up := svc("updates")
		if bool(it.get("download_blocked", false)) and status == "update":
			row.add_child(DKit.check_line("maybe", Hub.DOWNLOAD_BLOCKED))
		elif bool(it.get("download_unverified", false)) and status == "update":
			row.add_child(DKit.check_line("maybe", Hub.DOWNLOAD_UNVERIFIED))
		if it.get("flash") == "ez-flash" and status == "update" and up != null and str(it.get("download_host", "")) != "":
			row.add_child(DKit.quiet(Hub.FROM_HOST % str(it["download_host"])))
			var targets: Array = state.get("usb_targets", []) if state.get("usb_targets") is Array else []
			if targets.is_empty():
				row.add_child(DKit.quiet(Hub.NEEDS_USB))
			elif up.has_method("prepare_usb"):
				var pb := _btn("usb:" + str(it["id"]), Hub.PREPARE_USB, true)
				pb.disabled = _game_running() or not bool((state.get("power", {}) as Dictionary).get("ok", true))
				var mount := str(targets[0]["mount"])
				var id := str(it["id"])
				pb.pressed.connect(func(): svc("updates").prepare_usb(id, mount))
				btns.add_child(pb)
				if not pb.disabled:
					focus.append(pb)
				var pw: Dictionary = state.get("power", {}) if state.get("power") is Dictionary else {}
				if not bool(pw.get("ok", true)):
					row.add_child(DKit.check_line("maybe", str(Hub.REASONS.get(str(pw.get("reason", "")), ""))))
		var page := str(it.get("download_page", it.get("notes_url", "")))
		var qr_box: VBoxContainer = null
		if page != "":
			var id2 := str(it["id"])
			qr_box = Kit.vbox(4)
			qr_box.name = "QRBox"
			qr_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
			qr_box.visible = _qr_for == id2
			var lb := _btn("link:" + id2, Hub.HIDE_LINK if _qr_for == id2 else Hub.SHOW_LINK)
			var box := qr_box
			lb.pressed.connect(func():
				_qr_for = "" if _qr_for == id2 else id2
				box.visible = _qr_for == id2
				lb.text = Hub.HIDE_LINK if box.visible else Hub.SHOW_LINK
				if box.visible and box.get_child_count() == 0:
					_fill_qr(box, page))
			btns.add_child(lb)
			focus.append(lb)
			if qr_box.visible:
				_fill_qr(qr_box, page)
		if btns.get_child_count() > 0:
			row.add_child(btns)
		if qr_box != null:
			row.add_child(qr_box)
	col.add_child(row)
	return focus


## A phone-scannable QR of the maker's page, and the address under it.
func _fill_qr(box: VBoxContainer, page: String) -> void:
	if QR.texture(page, 4) != null:
		var qr := TextureRect.new()
		qr.name = "QR"
		QR.show_on(qr, page, 4)
		qr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		qr.custom_minimum_size = Vector2(200, 200)
		box.add_child(qr)
	box.add_child(Kit.label(page, "CaptionLabel", true))


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
