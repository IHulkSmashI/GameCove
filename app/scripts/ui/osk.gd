extends PanelContainer
## On-screen keyboard for controller typing (search). A glass sheet with a
## letter grid, space, backspace and Done. A physical keyboard types too.
## Emits text_changed on every key and closed when Done / B is pressed.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const Icons := preload("res://scripts/ui/icons.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Motion := preload("res://scripts/ui/motion.gd")

signal text_changed(text: String)
signal closed(text: String)

const ROWS := ["1234567890", "qwertyuiop", "asdfghjkl'", "zxcvbnm-:."]
const MAX_LEN := 40

var text := ""
## Longest text accepted (search keeps MAX_LEN). Sign-in codes need more.
var max_len := MAX_LEN
## Grey line shown while empty.
var placeholder := "Type to search"
## Keep upper case from a physical keyboard and allow Shift (codes, keys).
var keep_case := false
var shift := false
var shift_button: Button
var keys: Array = []          # rows of Buttons
var field: Label
var done_button: Button


func _init() -> void:
	name = "Keyboard"
	theme_type_variation = "GlassPanel"
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	var col := Kit.vbox(10)
	add_child(col)
	var head := Kit.hbox(12)
	head.add_child(Icons.rect("search", 22, ThemeLib.color("text_2")))
	field = Kit.label("", "LeadLabel")
	field.name = "Field"
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(field)
	head.add_child(Kit.prompts([["Y", "Space"], ["X", "Delete"], ["B", "Done"]]))
	col.add_child(head)
	for r in ROWS:
		var row := Kit.hbox(8)
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		var list: Array = []
		for ch in r:
			var b := Kit.button(ch.to_upper() if ch >= "a" and ch <= "z" else ch, "KeyButton")
			b.custom_minimum_size = Vector2(56, 50)
			b.pressed.connect(type.bind(ch))
			row.add_child(b)
			list.append(b)
		col.add_child(row)
		keys.append(list)
	var last := Kit.hbox(8)
	last.alignment = BoxContainer.ALIGNMENT_CENTER
	var space := Kit.button("Space", "KeyButton")
	space.custom_minimum_size = Vector2(304, 50)
	space.pressed.connect(type.bind(" "))
	var back := Kit.button("", "KeyButton")
	back.name = "Backspace"
	back.icon = Icons.tex("backspace", 22)
	back.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	back.custom_minimum_size = Vector2(120, 50)
	back.pressed.connect(backspace)
	var clear := Kit.button("Clear", "KeyButton")
	clear.custom_minimum_size = Vector2(120, 50)
	clear.pressed.connect(func(): set_text(""))
	done_button = Kit.button("Done", "AccentButton")
	done_button.custom_minimum_size = Vector2(120, 50)
	done_button.add_theme_font_size_override("font_size", ThemeLib.SIZE_BODY)
	done_button.pressed.connect(close)
	for b in [space, back, clear, done_button]:
		last.add_child(b)
	col.add_child(last)
	keys.append([space, back, clear, done_button])
	_link()


## Wire the grid so left/right wrap within a row and up/down keep the column.
func _link() -> void:
	for r in keys.size():
		var row: Array = keys[r]
		for i in row.size():
			var b: Button = row[i]
			b.focus_neighbor_left = b.get_path_to(row[posmod(i - 1, row.size())])
			b.focus_neighbor_right = b.get_path_to(row[posmod(i + 1, row.size())])
			var up: Array = keys[posmod(r - 1, keys.size())]
			var down: Array = keys[posmod(r + 1, keys.size())]
			b.focus_neighbor_top = b.get_path_to(up[mini(_col(i, row.size(), up.size()), up.size() - 1)])
			b.focus_neighbor_bottom = b.get_path_to(down[mini(_col(i, row.size(), down.size()), down.size() - 1)])


static func _col(i: int, from_n: int, to_n: int) -> int:
	return int(round(float(i) / maxf(1.0, from_n - 1) * (to_n - 1)))


func open(start := "") -> void:
	set_text(start, false)
	Motion.fade(self, true)
	if is_inside_tree():
		keys[1][0].grab_focus()


func close() -> void:
	if not visible:
		return
	Motion.fade(self, false)
	closed.emit(text)


func type(ch: String) -> void:
	if text.length() >= max_len:
		return
	set_text(text + (ch.to_upper() if shift and keep_case else ch))


## For codes and keys: longer text, a placeholder, case kept, and a Shift key
## on the bottom row. Search keeps the plain keyboard.
func use_for_codes(hint: String, longest := 600) -> void:
	placeholder = hint
	max_len = longest
	keep_case = true
	if shift_button == null:
		shift_button = Kit.button("Shift", "KeyButton")
		shift_button.name = "Shift"
		shift_button.toggle_mode = true
		shift_button.custom_minimum_size = Vector2(120, 50)
		shift_button.toggled.connect(func(on): _set_shift(on))
		var last: Array = keys[-1]
		last[0].get_parent().add_child(shift_button)
		last[0].get_parent().move_child(shift_button, 0)
		last.insert(0, shift_button)
		_link()
	_set_shift(false)
	set_text(text, false)


func _set_shift(on: bool) -> void:
	shift = on
	for row in keys.slice(0, keys.size() - 1):
		for b in row:
			if b.text.length() == 1 and b.text.to_lower() != b.text.to_upper():
				b.text = b.text.to_upper() if on else b.text.to_lower()


func backspace() -> void:
	if text != "":
		set_text(text.substr(0, text.length() - 1))


func set_text(t: String, emit := true) -> void:
	text = t
	var shown := t if t.length() <= 48 else "…" + t.right(47)
	field.text = shown if t != "" else placeholder
	field.add_theme_color_override("font_color", ThemeLib.color("text") if t != "" else ThemeLib.color("text_3"))
	if emit:
		text_changed.emit(text)


func _input(event: InputEvent) -> void:
	if not visible:
		return
	var handled := true
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_BACKSPACE:
			backspace()
		elif event.keycode == KEY_ESCAPE or event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER:
			close()
		elif event.unicode >= 32 and event.unicode < 0x10000 and not event.ctrl_pressed:
			var ch := String.chr(event.unicode)
			if text.length() < max_len:
				set_text(text + (ch if keep_case else ch.to_lower()))
		else:
			handled = false
	elif event is InputEventJoypadButton and event.pressed:
		match event.button_index:
			JOY_BUTTON_Y: type(" ")
			JOY_BUTTON_X: backspace()
			JOY_BUTTON_B: close()
			_: handled = false
	else:
		handled = false
	if handled and get_viewport() != null:
		get_viewport().set_input_as_handled()
