extends VBoxContainer
## Settings > Controller > Button shortcuts (the Controller page's first card):
## for every button GameCove can change, what a press does and, on the buttons
## next to the screen, what a hold does; Quick Access's "goes to Steam in
## games" switch, the hold time, Handheld Daemon's own shortcuts under hhd, a
## test area and a reset. Everything is a Control of the controller provider
## (controller.paddle.*, controller.button.*, controller.hold.*,
## controller.to_steam.*, controller.hold_time, controller.hhd_shortcut.*,
## controller.reset_shortcuts), read and written through the Controls model, so
## per-game layouts and the profile lock apply as on every other page.
##
## A press or hold row opens a sheet: first the kind of thing (an action, a
## key, a gamepad button, a mouse click, a key combination of your own), then
## the list. A choice the provider refuses (a fourth GameCove action on the
## back buttons) shows its reason in the sheet and on the row.
##
## Controller-only: rows are buttons in one focus chain, sheets take A / B.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const DKit := preload("res://scripts/ui/device/device_kit.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const ActionRow := preload("res://scripts/ui/settings/action_row.gd")
const ControlView := preload("res://scripts/ui/controls/control_view.gd")
const Sheet := preload("res://scripts/ui/games/sheet.gd")
const Buttons := preload("res://scripts/device/buttons.gd")
const ButtonMap := preload("res://scripts/actions/button_map.gd")
const Registry := preload("res://scripts/actions/registry.gd")
const Profile := preload("res://scripts/input/ip_profile.gd")
const T := preload("res://scripts/ui/quick/texts_shortcuts.gd")

## A row was focused (capability, or "" for none): the panel outlines it on the picture.
signal selected(capability: String)
## Something to tell the user (a refusal, a reset).
signal notice(text: String, tone: String)
## A row was drawn again (its button replaced): the host links the focus chain again.
signal rebuilt

var model: Object
var controls: Object
var controller: Object
var device_id := "generic"
## Where the sheet goes (the panel: it outlives a rebuild of this card).
var sheet_host: Control
var sheet: Control
## Row key ("press:LeftPaddle1", "hold:QuickAccess") -> ActionRow.
var rows := {}
var views: Array = []
var test_label: Label
var reset_row: VBoxContainer
var _focus: Array = []
var _caps := {}          # row key -> capability
var _editing := ""       # row key the open sheet edits


## `m`: the Controls model (ui/controls/model.gd). `services`: "controls",
## "controller". Builds the rows at once.
func setup(m: Object, services: Dictionary, device: String, host: Control) -> void:
	model = m
	controls = services.get("controls")
	controller = services.get("controller")
	device_id = device
	sheet_host = host
	name = "ShortcutsCard"
	add_theme_constant_override("separation", 10)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if model != null:
		model.changed.connect(_on_model_changed)
		model.failed.connect(_on_model_failed)
		model.refreshed.connect(refresh)
	if controller != null and controller.has_signal("shortcut_seen"):
		controller.shortcut_seen.connect(_on_seen)
	_build()


func _exit_tree() -> void:
	if controller != null and controller.has_signal("shortcut_seen") and controller.shortcut_seen.is_connected(_on_seen):
		controller.shortcut_seen.disconnect(_on_seen)


## True when the model has at least one usable shortcut control here.
static func wanted(m: Object) -> bool:
	if m == null:
		return false
	for id in m.ids("controller"):
		var s := str(id)
		if (s.begins_with("controller.paddle.") or s.begins_with("controller.button.") or s.begins_with("controller.hold.")
				or s.begins_with("controller.hhd_shortcut.") or s == "controller.paddles_as") and bool(m.describe(s).get("available", false)):
			return true
	return false


## Top to bottom, read fresh (a Control row may have drawn a new button).
func focusables() -> Array:
	var out: Array = []
	for f in _focus:
		if f is Control and f.has_method("focusables"):
			out.append_array(f.focusables())
		elif f != null and is_instance_valid(f):
			out.append(f)
	return out


# ---- building ---------------------------------------------------------------------------

## Buttons in the order the page lists them: the ones next to the screen (each
## once), the extra buttons GameCove leaves to the game, then the back buttons.
func _buttons() -> Array:
	var out: Array = []
	for cap in ButtonMap.hold_caps(device_id):
		out.append({"cap": cap, "kind": "special"})
	for id in model.ids("controller"):
		var s := str(id)
		if s.begins_with("controller.button."):
			out.append({"cap": s.trim_prefix("controller.button."), "kind": "button"})
	for id in model.ids("controller"):
		var s2 := str(id)
		if s2.begins_with("controller.paddle."):
			out.append({"cap": s2.trim_prefix("controller.paddle."), "kind": "paddle"})
	return out


func _title_for(cap: String, kind: String) -> String:
	var label := Buttons.label_for(device_id, cap)
	if kind == "paddle":
		return T.BS_BACK % label
	return label


func _build() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	rows.clear()
	_caps.clear()
	views.clear()
	_focus.clear()
	add_child(DKit.quiet(T.BS_LINE))
	for b in _buttons():
		var cap: String = b["cap"]
		var kind: String = b["kind"]
		var group := Kit.vbox(4)
		group.name = "Button_" + cap
		var head := Kit.label(_title_for(cap, kind), "EyebrowLabel")
		head.name = "Head"
		group.add_child(head)
		if kind == "special":
			var steam_id := "controller.to_steam." + cap
			if model.has(steam_id):
				_view(group, steam_id, cap)
				group.add_child(_note(T.BS_STEAM_NOTE))
			_row(group, "hold:" + cap, T.BS_HOLD, "controller.hold." + cap, cap,
				T.BS_PRESS_BUILT_IN % str(T.BS_BUILT_IN.get(ButtonMap.built_in(device_id, cap), "")) + " " + T.BS_HOLD_HINT)
		else:
			_row(group, "press:" + cap, T.BS_PRESS, "controller.%s.%s" % [kind, cap], cap, T.BS_PRESS_HINT)
		if group.get_child_count() > 1:
			add_child(group)
		else:
			group.free()
	for id in ["controller.hold_time", "controller.paddles_as"]:
		if model.has(id) and bool(model.describe(id).get("available", false)):
			_view(self, id, "")
	for id in model.ids("controller"):
		if str(id).begins_with("controller.hhd_shortcut.") and bool(model.describe(str(id)).get("available", false)):
			_view(self, str(id), "")
	_test_area()
	if model.has("controller.reset_shortcuts") and bool(model.describe("controller.reset_shortcuts").get("available", false)):
		reset_row = ActionRow.new()
		reset_row.setup("reset_shortcuts", str(model.describe("controller.reset_shortcuts").get("title", "")), "",
			str(model.describe("controller.reset_shortcuts").get("help", "")), "reset", false)
		reset_row.pressed.connect(_reset)
		reset_row.button.focus_entered.connect(func(): selected.emit(""))
		add_child(reset_row)
		_focus.append(reset_row.button)
	refresh()


func _note(text: String) -> Label:
	var l := DKit.quiet(text)
	l.name = "Note"
	return l


func _view(box: Control, id: String, cap: String) -> void:
	var v: Control = ControlView.make(model, id)
	if v == null:
		return
	box.add_child(v)
	views.append(v)
	_focus.append(v)
	v.set_meta("cap", cap)
	v.rebuilt.connect(func(): rebuilt.emit())


func _row(box: Control, key: String, title: String, control_id: String, cap: String, hint: String) -> void:
	if not model.has(control_id):
		return
	var r: VBoxContainer = ActionRow.new()
	r.setup(key, title, "", hint, "", true)
	r.set_meta("control", control_id)
	r.set_meta("hint", hint)
	r.pressed.connect(_open.bind(key))
	r.button.focus_entered.connect(func(): selected.emit(cap))
	box.add_child(r)
	rows[key] = r
	_caps[key] = cap
	_focus.append(r.button)


func _test_area() -> void:
	var box := PanelContainer.new()
	box.name = "TestArea"
	box.theme_type_variation = "RaisedPanel"
	var col := Kit.vbox(4)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(col)
	var head := Kit.label(T.BS_TEST_TITLE, "EyebrowLabel")
	col.add_child(head)
	test_label = Kit.label(T.BS_TEST_IDLE, "", true)
	test_label.name = "Detected"
	col.add_child(test_label)
	col.add_child(_note(T.BS_TEST_NOTE))
	add_child(box)


# ---- showing values ---------------------------------------------------------------------

## Value labels and availability from the model (no rebuild: focus stays put).
func refresh() -> void:
	for key in rows:
		var r: VBoxContainer = rows[key]
		var d: Dictionary = model.describe(str(r.get_meta("control")))
		var avail := bool(d.get("available", false))
		r.set_value(_label_of(d, d.get("value")) if avail else "", "" if avail else "muted")
		var hint := str(r.get_meta("hint"))
		r.set_hint(hint if avail else T.BS_UNAVAILABLE % str(d.get("reason", "")))
		r.modulate.a = 1.0 if avail else 0.6


## The words for `v` among the control's options ("As itself", "Screenshot",
## "Alt + Enter"), the hold's "Nothing".
static func _label_of(d: Dictionary, v: Variant) -> String:
	for o in d.get("options", []):
		if o is Dictionary and o.get("value") == v:
			return str(o.get("label", v))
	return ButtonMap.label(str(v)) if v != null else ""


func _on_model_changed(id: String, _v: Variant) -> void:
	if id.begins_with("controller."):
		refresh()


func _on_model_failed(id: String, _v: Variant) -> void:
	var c: RefCounted = model.control(id) if model.has_method("control") else null
	var why := str(c.get_meta("why", "")) if c != null else ""
	if why != "":
		notice.emit(why, "warn")
	refresh()


# ---- the sheets -------------------------------------------------------------------------

func _sheet() -> Control:
	if sheet == null or not is_instance_valid(sheet):
		sheet = Sheet.new()
		sheet.name = "ShortcutSheet"
		sheet.z_index = 15
		_sheet_parent().add_child(sheet)
	return sheet


## The first ancestor that isn't a container (the settings screen), so the
## sheet covers the screen instead of taking a slot in a column.
func _sheet_parent() -> Node:
	if sheet_host != null and not sheet_host is Container:
		return sheet_host
	var n: Node = self
	while n.get_parent() != null and n.get_parent() is Container:
		n = n.get_parent()
	return n.get_parent() if n.get_parent() != null else (sheet_host if sheet_host != null else self)


func sheet_open() -> bool:
	return sheet != null and is_instance_valid(sheet) and sheet.is_open()


func _open(key: String) -> void:
	var r: VBoxContainer = rows.get(key)
	if r == null:
		return
	var id := str(r.get_meta("control"))
	var d: Dictionary = model.describe(id)
	if not bool(d.get("available", false)):
		notice.emit(str(d.get("reason", "")), "")
		return
	_editing = key
	var label := Buttons.label_for(device_id, str(_caps[key]))
	if key.begins_with("hold:"):
		var list: Array = []
		for o in d.get("options", []):
			if str(o["value"]).begins_with(ButtonMap.ACTION + "key_optiscaler") and not _optiscaler() and o.get("value") != d.get("value"):
				continue
			list.append({"id": "set:" + str(o["value"]), "text": str(o["label"]), "detail": _help_of(str(o["value"])),
				"icon": _icon_of(str(o["value"])), "current": o.get("value") == d.get("value")})
		_sheet().open(T.BS_HOLD_TITLE % label, T.BS_HOLD_LINE, list, _picked)
		return
	var cur := str(d.get("value", ""))
	var groups: Array = []
	for g in ["itself", "off", "action", "keys", "pad", "mouse", "custom"]:
		var mine: bool = _group_of(cur) == g
		var detail: String = _label_of(d, cur) if mine and not g in ["itself", "off"] else str(T.BS_GROUP_DETAIL[g])
		if g != "custom" and g != "itself" and g != "off" and _options_in(d, g).is_empty():
			continue
		groups.append({"id": ("set:" if g in ["itself", "off"] else "group:") + ({"itself": "", "off": "disabled"}.get(g, g) as String),
			"text": T.BS_GROUP[g], "detail": detail, "icon": {"itself": "gamepad", "off": "minus", "action": "sparkle", "keys": "key",
				"pad": "gamepad", "mouse": "mouse", "custom": "keyboard"}[g], "current": mine})
	_sheet().open(T.BS_GROUPS_TITLE % label, T.BS_GROUPS_LINE, groups, _picked)


static func _group_of(v: String) -> String:
	if v == "":
		return "itself"
	if v == "disabled":
		return "off"
	if v.begins_with(ButtonMap.ACTION):
		return "action"
	if v.begins_with("mouse:"):
		return "mouse"
	if v.begins_with("Key"):
		return "keys"
	return "pad"


## The options of `d` in group `g`; OptiScaler's keys only for games that use it
## (or when the button already has one).
func _optiscaler() -> bool:
	var up: Variant = controls.value("perf.upscaler") if controls != null and controls.has_method("value") else null
	return up is String and not up in ["", "own", "off"]


func _options_in(d: Dictionary, g: String) -> Array:
	var optiscaler := _optiscaler()
	var out: Array = []
	for o in d.get("options", []):
		var v := str(o.get("value", ""))
		if _group_of(v) != g:
			continue
		if v in ["KeyInsert", "KeyEnd"] and not optiscaler and v != str(d.get("value", "")):
			continue
		out.append(o)
	return out


func _picked(id: String) -> void:
	if id.begins_with("group:"):
		call_deferred("_open_group", id.trim_prefix("group:"))
	else:
		_apply(id.trim_prefix("set:"))


func _open_group(g: String) -> void:
	var r: VBoxContainer = rows.get(_editing)
	if r == null:
		return
	var label := Buttons.label_for(device_id, str(_caps[_editing]))
	if g == "custom":
		var mods: Array = []
		for m in T.BS_MODS:
			mods.append({"id": "mods:" + str(m[0]), "text": str(m[1]), "icon": "key"})
		_sheet().open(T.BS_MODS_TITLE, T.BS_MODS_LINE, mods, func(pick: String): call_deferred("_open_keys", pick.trim_prefix("mods:")))
		return
	var d: Dictionary = model.describe(str(r.get_meta("control")))
	var cap := str(_caps[_editing])
	var list: Array = []
	for o in _options_in(d, g):
		var v := str(o["value"])
		var why := _slot_problem(cap, v)
		list.append({"id": "set:" + v, "text": str(o["label"]), "detail": ButtonMap.why_text(why) if why != "" else _help_of(v),
			"icon": _icon_of(v), "current": v == str(d.get("value", "")), "disabled": why != ""})
	_sheet().open(T.BS_GROUPS_TITLE % label + " · " + str(T.BS_GROUP[g]).to_lower(), T.BS_GROUPS_LINE, list, _picked)


func _open_keys(mods: String) -> void:
	var list: Array = []
	var held := Registry.combo_keys(mods)
	for k in Registry.KEY_NAMES:
		list.append({"id": k, "text": Registry.key_label(k), "icon": "key"})
	var line := T.BS_KEY_LINE % Registry.combo_label(held) if not held.is_empty() else ""
	_sheet().open(T.BS_KEY_TITLE, line, list, func(k: String): _custom(Registry.combo_text(held + [k])))


## A key combination of the user's own: kept in the device's list (Controls
## worker), then set on the button.
func _custom(combo: String) -> void:
	if not Registry.valid_combo(Registry.combo_keys(combo)):
		return
	var r: VBoxContainer = rows.get(_editing)
	if r == null:
		return
	var c: RefCounted = model.control(str(r.get_meta("control")))
	var prov: Object = c.get_meta("provider") if c != null and c.has_meta("provider") else null
	if prov != null and prov.has_method("add_custom_key") and controls != null and controls.has_method("run_on_worker"):
		# kept, and the row's choices read again, before the value is written (one worker, in order)
		controls.run_on_worker(func():
			prov.add_custom_key(combo)
			c.detect())
	_apply(combo)
	if controls != null and controls.has_method("detect_all"):
		controls.detect_all()


func _apply(v: String) -> void:
	var r: VBoxContainer = rows.get(_editing)
	if r == null:
		return
	model.set_value(str(r.get_meta("control")), v)
	refresh()
	call_deferred("_refocus", _editing)


func _refocus(key: String) -> void:
	if sheet_open():
		return
	var r: VBoxContainer = rows.get(key)
	if r != null and is_instance_valid(r) and r.is_visible_in_tree():
		r.button.grab_focus()


## "no_slot" when `v` is a fourth different GameCove action on the buttons
## (ButtonMap.SLOTS), from the values the page already shows: no profile read
## on the main thread. The provider checks again when it writes.
func _slot_problem(cap: String, v: String) -> String:
	if not v.begins_with(ButtonMap.ACTION):
		return ""
	var used := {}
	for key in rows:
		if str(_caps[key]) == cap or not str(key).begins_with("press:"):
			continue
		var w: Variant = model.value(str(rows[key].get_meta("control")))
		if w is String and (w as String).begins_with(ButtonMap.ACTION):
			used[w] = true
	return "" if used.has(v) or used.size() < ButtonMap.SLOTS.size() else "no_slot"


static func _help_of(v: String) -> String:
	if v.begins_with(ButtonMap.ACTION):
		return str(Registry.action(v.trim_prefix(ButtonMap.ACTION)).get("help", ""))
	if v == "":
		return ""
	var known := Registry.key_action_for(Registry.combo_keys(v)) if v.begins_with("Key") else ""
	return str(Registry.action(known).get("help", "")) if known != "" else ""


static func _icon_of(v: String) -> String:
	if v.begins_with(ButtonMap.ACTION):
		return str(Registry.action(v.trim_prefix(ButtonMap.ACTION)).get("icon", "sparkle"))
	if v.begins_with("Key"):
		return "key"
	if v.begins_with("mouse:"):
		return "mouse"
	return "gamepad" if v != "" else "minus"


# ---- test area and reset ----------------------------------------------------------------

func _on_seen(cap: String, what: String) -> void:
	if test_label == null or not is_instance_valid(test_label):
		return
	var label := Buttons.label_for(device_id, cap)
	match what:
		"down":
			test_label.text = T.BS_TEST_DOWN % label
		"press":
			test_label.text = T.BS_TEST_PRESS % [label, _doing(cap, false)]
		"hold":
			test_label.text = T.BS_TEST_HOLD % [label, _doing(cap, true)]


## What the button did, in words: its hold, its press (an action), or its own job.
func _doing(cap: String, held: bool) -> String:
	var id := ("controller.hold." if held else "controller.paddle.") + cap
	if not held and not model.has(id):
		id = "controller.button." + cap
	if model.has(id):
		var d: Dictionary = model.describe(id)
		var v: Variant = d.get("value")
		if not (held == false and str(v) == "" and ButtonMap.built_in(device_id, cap) != ""):
			return _label_of(d, v)
	return str(T.BS_BUILT_IN.get(ButtonMap.built_in(device_id, cap), ""))


func _reset() -> void:
	if model.set_value("controller.reset_shortcuts", true):
		notice.emit(T.BS_RESET_DONE, "good")


## The button a focused control is about ("" for the hold time, the reset...).
func cap_of(c: Control) -> String:
	for key in rows:
		if rows[key].button == c:
			return str(_caps[key])
	for v in views:
		if is_instance_valid(v) and v.is_ancestor_of(c):
			return str(v.get_meta("cap", ""))
	return ""


func hints_for(c: Control) -> Array:
	for key in rows:
		if rows[key].button == c:
			return [["A", "Change"], ["B", "Back"]]
	if reset_row != null and c == reset_row.button:
		return [["A", "Reset"], ["B", "Back"]]
	for v in views:
		if is_instance_valid(v) and v.is_ancestor_of(c):
			# a switch or segmented row changes on A, a stepper or slider with left / right
			var p: Node = c.get_parent()
			return [Kit.change_hint(c) if c is Slider or (p != null and p.has_method("is_stepper")) else ["LR", "Change"], ["B", "Back"]]
	return []
