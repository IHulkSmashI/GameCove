extends "res://scripts/ui/osk.gd"
## The on-screen keyboard for longer text with capitals and symbols (launch
## options like "PROTON_LOG=1 %command%"). Same look and keys as the search
## keyboard, plus a symbol row with Shift; keeps case; longer limit.

const GameIcons := preload("res://scripts/ui/games/game_icons.gd")

const SYMBOLS := ["⇧", "_", "=", "%", "/", "\"", "+", ",", ";", "!"]
const LONG_MAX := 240

# shift, placeholder and shift_button come from osk.gd.
var _letters: Array = []   # [Button, lowercase char]


func _init() -> void:
	if get_child_count() == 0:
		super._init()
	name = "TextKeyboard"
	placeholder = "Type here"
	max_len = LONG_MAX
	keep_case = true
	var col: VBoxContainer = get_child(0)
	var head_icon: Variant = col.get_child(0).get_child(0)
	if head_icon is TextureRect:
		head_icon.texture = GameIcons.tex("terminal", 22, ThemeLib.color("text_2"))
	var row := Kit.hbox(8)
	row.name = "Symbols"
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	var list: Array = []
	for ch in SYMBOLS:
		var b := Kit.button(ch, "KeyButton")
		b.custom_minimum_size = Vector2(56, 50)
		if ch == "⇧":
			b.name = "Shift"
			b.text = ""
			b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
			b.pressed.connect(toggle_shift)
			shift_button = b
		else:
			b.pressed.connect(type.bind(ch))
		row.add_child(b)
		list.append(b)
	col.add_child(row)
	col.move_child(row, col.get_child_count() - 2)
	keys.insert(keys.size() - 1, list)
	for r in keys:
		for b in r:
			if b.text.length() == 1 and b.text >= "A" and b.text <= "Z":
				_letters.append([b, b.text.to_lower()])
	_link()
	_refresh_shift()


func toggle_shift() -> void:
	shift = not shift
	_refresh_shift()


func _refresh_shift() -> void:
	for pair in _letters:
		pair[0].text = pair[1].to_upper() if shift else pair[1]
	if shift_button != null:
		shift_button.icon = GameIcons.tex("arrow_up", 22, ThemeLib.color("accent") if shift else Color.WHITE)


## Letters follow Shift (on-screen); physical keys type exactly what they say.
func type(ch: String) -> void:
	if text.length() >= LONG_MAX:
		return
	if shift and ch.length() == 1 and ch >= "a" and ch <= "z":
		ch = ch.to_upper()
	set_text(text + ch)


func set_text(t: String, emit := true) -> void:
	text = t
	field.text = t if t != "" else placeholder
	field.add_theme_color_override("font_color", ThemeLib.color("text") if t != "" else ThemeLib.color("text_3"))
	field.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	if emit:
		text_changed.emit(text)


func _input(event: InputEvent) -> void:
	if not showing:
		return
	if event is InputEventKey and event.pressed and event.unicode >= 32 and event.unicode < 0x10000 \
			and not event.ctrl_pressed and event.keycode != KEY_BACKSPACE:
		if text.length() < LONG_MAX:
			set_text(text + String.chr(event.unicode))
		get_viewport().set_input_as_handled()
		return
	super._input(event)
