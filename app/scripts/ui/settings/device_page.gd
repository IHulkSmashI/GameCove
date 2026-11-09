extends "res://scripts/ui/settings/page.gd"
## Device: embeds the device panels (About this device, Controller, Storage,
## Updates) from app/scripts/ui/device/ when they exist. Each panel script is
## expected to have
##
##     static func build(services: Dictionary) -> Control
##
## and may add, on the Control it returns:
##     func focusables() -> Array   # its focus chain, top to bottom
##     func opened() / func closed() # Device page shown / hidden (e.g. Storage.watch)
##
## A panel that isn't there yet shows a placeholder card instead. The page is
## built the first time it's shown, so nothing runs at start-up.

const TPhoto := preload("res://scripts/ui/texts_photo.gd")
const CIcons := preload("res://scripts/ui/controls/cicons.gd")
const Motion := preload("res://scripts/ui/motion.gd")

## Panel -> script names we look for, first found wins.
const PANELS := {
	"about": ["about_device.gd", "about_panel.gd", "about.gd"],
	"fixes": ["fixes_page.gd"],
	"controller": ["controller_page.gd", "controller_panel.gd", "controller.gd"],
	"storage": ["storage_page.gd", "storage_panel.gd", "storage.gd"],
	"updates": ["updates_page.gd", "updates_panel.gd", "updates.gd"],
}
const ORDER := ["about", "fixes", "controller", "storage", "updates"]
## Sections without a tab: Controller is its own Settings category, whose page
## links here (open_category("device", "controller")).
const UNTABBED := ["controller"]
const TAB_TITLES := {"about": "About", "fixes": "Fixes", "controller": "Controller", "storage": "Storage", "updates": "Updates"}
const TAB_ICONS := {"about": "handheld", "fixes": "wrench", "controller": "gamepad", "storage": "download", "updates": "update"}
const Shared := preload("res://scripts/ui/controls/shared.gd")
const DIR := "res://scripts/ui/device/"
## Height a panel gets when the page can't measure its scroll area yet.
const FALLBACK_HEIGHT := 560.0

var panels := {}   # id -> Control (loaded panels only)
## Folder the panel scripts are looked up in (tests point it at fixtures).
var panel_dir := DIR
## The section on show: one panel at a time, picked with the tabs on top
## (each device panel is a full page with its own scrolling column).
var part := "about"
var tabs := {}     # id -> Button
var sections := {} # id -> Control (panel or placeholder card)
var tab_row: HBoxContainer
var _photo_card: Control
var _built := false
var _shown := false
var _scroll: ScrollContainer


## Script path for a panel, or "" when none is installed.
static func panel_script(id: String, dir := DIR) -> String:
	for f in PANELS.get(id, []):
		var p: String = dir + f
		if ResourceLoader.exists(p):
			return p
	return ""


func build() -> void:
	panels.clear()
	tabs.clear()
	sections.clear()
	_photo_card = null
	tab_row = null
	if not _built:
		return
	tab_row = Kit.hbox(6)
	tab_row.name = "DeviceTabs"
	add_child(tab_row)
	# LT / RT switch these tabs (LB / RB stay on the top sections).
	var lt := Kit.glyph("LT", false, true)
	lt.name = "TabsLT"
	tab_row.add_child(lt)
	for id in ORDER:
		var path := panel_script(id, panel_dir)
		if path == "" and id == "fixes":
			continue
		var c: Control = null
		if path != "":
			var s: Script = load(path)
			var svc_for: Dictionary = services
			if id == "fixes" and not services.has("fixes"):
				# the Fixes service isn't an autoload: the shared one (none under tests)
				var fx := Shared.fixes(self)
				if fx != null:
					svc_for = services.duplicate()
					svc_for["fixes"] = fx
			if s != null and s.has_method("build"):
				c = s.build(svc_for)
			elif s != null and s.can_instantiate():
				c = s.new() as Control
		if not id in UNTABBED:
			_tab(id)
		if c == null:
			sections[id] = _placeholder(id)
			continue
		c.name = "Panel_" + id
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if c.has_signal("part_requested"):
			c.part_requested.connect(func(to: String):
				var f := focus_part(to)
				if f != null:
					f.grab_focus())
		if c.has_signal("category_requested"):
			c.category_requested.connect(func(to: String):
				if host != null and host.has_method("open_category"):
					host.open_category(to))
		add_child(c)
		panels[id] = c
		sections[id] = c
	var rt := Kit.glyph("RT", false, true)
	rt.name = "TabsRT"
	tab_row.add_child(rt)
	_photo_setting()
	if not sections.has(part):
		part = "about"
	_show_part(part, false)


func _tab(id: String) -> void:
	var t := Kit.button(TAB_TITLES.get(id, id.capitalize()), "SectionTab")
	t.name = "Tab_" + id
	t.toggle_mode = true
	t.custom_minimum_size = Vector2(0, 40)
	t.icon = CIcons.tex(TAB_ICONS.get(id, "info"), 18, ThemeLib.color("text_2"))
	t.expand_icon = false
	t.pressed.connect(func():
		t.set_pressed_no_signal(part == id)
		var f := _panel_chain(id)
		if not f.is_empty():
			f[0].grab_focus())
	t.gui_input.connect(_tab_input.bind(id))
	tab_row.add_child(t)
	tabs[id] = t


## Left / right on the tabs switch sections (left on the first goes back to
## the category list, as everywhere else in Settings).
func _tab_input(event: InputEvent, id: String) -> void:
	var order: Array = tabs.keys()
	var i := order.find(id)
	var to := -1
	if event.is_action_pressed("ui_right") and i + 1 < order.size():
		to = i + 1
	elif event.is_action_pressed("ui_left") and i > 0:
		to = i - 1
	if to < 0:
		return
	tabs[id].accept_event()
	select_part(order[to])
	tabs[order[to]].grab_focus()


## What A does on `f` when a panel names it (About's "Copy info"), else "".
func a_hint(f: Control) -> String:
	var c: Control = panels.get(part)
	if c == null or not c.has_method("hints_for") or f == null or not c.is_ancestor_of(f):
		return ""
	for h in c.hints_for(f):
		if h[0] == "A":
			return str(h[1])
	return ""


## LT / RT: the previous / next tab (wrapping). Returns the new tab.
func cycle_tabs(d: int) -> Control:
	var order: Array = tabs.keys()
	if order.is_empty():
		return null
	var i := order.find(part)
	var to: String = order[0] if i < 0 else order[posmod(i + signi(d), order.size())]
	select_part(to)
	return tabs.get(to)


## Shows section `id` (its tab lit, its panel filling the page).
func select_part(id: String) -> void:
	if not sections.has(id) or id == part:
		return
	_show_part(id, true)
	rebuilt.emit()


func _show_part(id: String, animate: bool) -> void:
	var old := part
	part = id
	for k in sections:
		var on: bool = k == id
		var sec: Control = sections[k]
		sec.visible = on
		var t: Button = tabs.get(k)
		if t != null:
			t.set_pressed_no_signal(on)
			t.icon = CIcons.tex(TAB_ICONS.get(k, "info"), 18, ThemeLib.color("accent") if on else ThemeLib.color("text_2"))
	if _photo_card != null:
		_photo_card.visible = id == "about"
	_fit()
	if animate and sections.has(id):
		sections[id].modulate.a = 0.0
		Motion.to(sections[id], "modulate:a", 1.0, Motion.FAST)
	if _shown and old != id:
		var a: Control = panels.get(old)
		if a != null and a.has_method("closed"):
			a.closed()
		var b: Control = panels.get(id)
		if b != null and b.has_method("opened"):
			b.opened()


## Device panels lay out a fixed area (summary left, scrolling cards right):
## give the open one the height of the Settings scroll area under the tabs.
func _fit() -> void:
	var h := FALLBACK_HEIGHT
	if _scroll == null and is_inside_tree():
		var n := get_parent()
		while n != null and not n is ScrollContainer:
			n = n.get_parent()
		_scroll = n as ScrollContainer
		if _scroll != null and not _scroll.resized.is_connected(_fit):
			_scroll.resized.connect(_fit)
	if _scroll != null and _scroll.size.y > 200.0:
		h = _scroll.size.y - 40.0 - float(get_theme_constant("separation")) - 14.0
	for k in panels:
		(panels[k] as Control).custom_minimum_size.y = h


# ---- real device photo setting (DevicePhoto service); kept apart for merges ----

func _photo_setting() -> void:
	var ph := svc("photo")
	if ph == null or not ph.has_method("set_enabled"):
		return
	var box := add_card(TPhoto.SETTING_CARD, "handheld")
	box.get_parent().name = "Card_photo"
	_photo_card = box.get_parent()
	var r := toggle(box, "real_photo", TPhoto.SETTING_TITLE, bool(ph.enabled), by_value(TPhoto.SETTING_HELP), "handheld")
	r.changed.connect(func(v):
		ph.set_enabled(bool(v))
		rebuild.call_deferred())
	# Maker's own product picture when there's no free photo (one request).
	if ph.has_method("set_maker_enabled") and "maker_enabled" in ph:
		var m := toggle(box, "maker_photo", TPhoto.MAKER_SETTING_TITLE, bool(ph.maker_enabled), by_value(TPhoto.MAKER_SETTING_HELP), "download")
		m.changed.connect(func(v):
			ph.set_maker_enabled(bool(v))
			rebuild.call_deferred())


## Focusable controls under `n`, in tree order.
static func focusable_children(n: Node, out: Array = []) -> Array:
	for ch in n.get_children():
		if ch is Control and ch.focus_mode != Control.FOCUS_NONE and ch.visible:
			out.append(ch)
		focusable_children(ch, out)
	return out


func _placeholder(id: String) -> Control:
	var box := add_card(TS.DEVICE_PANEL_TITLES.get(id, TAB_TITLES.get(id, id)), TS.DEVICE_PANEL_ICONS.get(id, "info"))
	box.get_parent().name = "Placeholder_" + id
	if id == "about":
		var dev := svc("device")
		if dev != null and dev.has_method("display_name"):
			var p: Dictionary = dev.profile if "profile" in dev else {}
			box.add_child(SKit.fact("Device", dev.display_name()))
			box.add_child(SKit.fact("Chip", str(p.get("chip", "Unknown"))))
			box.add_child(SKit.fact("Support", dev.support_level().capitalize() if dev.has_method("support_level") else "Generic"))
			return box.get_parent()
	box.add_child(Kit.label(TS.DEVICE_PANEL_SOON, "QuietLabel", true))
	return box.get_parent()


## The chain now: the open section's tab, then its panel (panels rebuild
## their own buttons, Fixes after Apply / Undo, so it's read each time), then
## the photo setting under About.
func focusables() -> Array:
	var out: Array = []
	var t: Button = tabs.get(part)
	if t != null:
		out.append(t)
	out.append_array(_panel_chain(part))
	if part == "about":
		for f in _focusables:
			if is_instance_valid(f) and not f in out and not _in_panel(f):
				out.append(f)
	return out.filter(func(f): return is_instance_valid(f))


func _panel_chain(id: String) -> Array:
	var c: Control = panels.get(id)
	if c == null or not is_instance_valid(c):
		return []
	return c.focusables() if c.has_method("focusables") else focusable_children(c)


func _in_panel(f: Node) -> bool:
	for c in panels.values():
		if is_instance_valid(c) and c.is_ancestor_of(f):
			return true
	return false


## Settings asked for a part of this page ("fixes"): its first control.
func focus_part(want: String) -> Control:
	if not _built:
		on_shown()
	if not sections.has(want):
		return null
	select_part(want)
	var chain := _panel_chain(want)
	return chain[0] if not chain.is_empty() else tabs.get(want)


## Called by the settings screen when the Device page shows / hides.
func on_shown() -> void:
	_shown = true
	if not _built:
		_built = true
		rebuild()
	_fit()
	var c: Control = panels.get(part)
	if c != null and c.has_method("opened"):
		c.opened()


func on_hidden() -> void:
	if not _shown:
		return
	_shown = false
	var c: Control = panels.get(part)
	if c != null and c.has_method("closed"):
		c.closed()
