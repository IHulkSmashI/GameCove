extends "res://scripts/ui/osk.gd"
## The on-screen keyboard for longer text with capitals and symbols (launch
## options like "PROTON_LOG=1 %command%", a collection's name). The same
## keyboard as everywhere (osk.gd: Shift, Caps, the symbols page, the caret);
## it keeps the case a physical keyboard types and takes longer text.

const GameIcons := preload("res://scripts/ui/games/game_icons.gd")

const LONG_MAX := 240


func _init() -> void:
	if get_child_count() == 0:
		super._init()
	name = "TextKeyboard"
	placeholder = "Type here"
	max_len = LONG_MAX
	keep_case = true
	_head_icon.texture = GameIcons.tex("terminal", 22, ThemeLib.color("text_2"))
	_refresh_field()
