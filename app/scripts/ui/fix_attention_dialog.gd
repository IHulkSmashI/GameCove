extends Control
## "Our MSI buttons fix is in your system's way": shown over the home screen at GameCove's start
## when a fix GameCove installed has to come out but waits for the admin password, and leaving it
## in does harm (it was withdrawn, or the system now does the same thing and the two clash:
## scripts/device/fixes.gd attention()). Never over a game: fixes.gd only says it at the end of a
## start pass, which waits for a running game to end. Shown at every start until the fix is out
## or kept (docs/FIXES.md, "When it can't happen now"). No timer: it waits for a button.
##   Remove now  (only where a password prompt can show: Desktop Mode) -> decided("remove")
##   Open Fixes  -> decided("open")      Later / B -> decided("later")

const Kit := preload("res://scripts/ui/ui_kit.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Motion := preload("res://scripts/ui/motion.gd")
const Icons := preload("res://scripts/ui/icons.gd")
const TF := preload("res://scripts/ui/texts_fixes.gd")

signal decided(choice: String)

var items: Array = []
var can_prompt := false
var title_label: Label
## "remove" / "open" / "later" -> Button
var buttons := {}
var _done := false
var _return_focus: Control


## Opens over `host` for `items_` (fixes.gd attention()); can_prompt_: a password prompt can show.
static func open(host: Control, items_: Array, can_prompt_: bool) -> Control:
	var d = load("res://scripts/ui/fix_attention_dialog.gd").new()
	d.build(items_, can_prompt_)
	host.add_child(d)
	d.start()
	return d


func build(items_: Array, can_prompt_: bool) -> void:
	name = "FixAttentionDialog"
	items = items_
	can_prompt = can_prompt_
	set_anchors_preset(Control.PRESET_FULL_RECT)
	z_index = 30
	mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.name = "Dim"
	dim.color = Color(ThemeLib.color("scrim"), 0.86)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var card := PanelContainer.new()
	card.name = "Card"
	card.add_theme_stylebox_override("panel", ThemeLib.glass(ThemeLib.radius("xl"), 32, 28))
	card.set_anchors_preset(Control.PRESET_CENTER)
	card.grow_horizontal = Control.GROW_DIRECTION_BOTH
	card.grow_vertical = Control.GROW_DIRECTION_BOTH
	card.custom_minimum_size = Vector2(640, 0)
	add_child(card)
	var col := Kit.vbox(14)
	card.add_child(col)
	var head := Kit.hbox(14)
	var icon := Icons.rect("alert", 32, ThemeLib.tone("warn"))
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(icon)
	title_label = Kit.label(TF.attention_title(items), "TitleLabel", true)
	title_label.name = "Title"
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title_label)
	col.add_child(head)
	var list := Kit.vbox(8)
	list.name = "Items"
	for it in items:
		var l := Kit.label(TF.attention_line(it), "", true)
		l.name = "Item_" + str(it.get("id", "")).validate_node_name()
		list.add_child(l)
	col.add_child(list)
	var how := Kit.label(TF.ATTN_DESKTOP if can_prompt else TF.ATTN_GAMING, "QuietLabel", true)
	how.name = "How"
	col.add_child(how)
	var again := Kit.label(TF.ATTN_AGAIN, "CaptionLabel", true)
	again.name = "Again"
	again.add_theme_color_override("font_color", ThemeLib.color("text_3"))
	col.add_child(again)
	var row := Kit.hbox(12)
	row.name = "Buttons"
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_child(_button("later", TF.ATTN_LATER, false))
	row.add_child(_button("open", TF.ATTN_OPEN, not can_prompt))
	if can_prompt:
		row.add_child(_button("remove", TF.REMOVE_NOW, true))
	col.add_child(row)
	# focus stays on the card's buttons
	var list_b: Array = row.get_children()
	for i in list_b.size():
		var b: Button = list_b[i]
		b.focus_neighbor_left = b.get_path_to(list_b[maxi(0, i - 1)])
		b.focus_neighbor_right = b.get_path_to(list_b[mini(list_b.size() - 1, i + 1)])
		b.focus_neighbor_top = b.get_path_to(b)
		b.focus_neighbor_bottom = b.get_path_to(b)
		b.focus_previous = b.focus_neighbor_left
		b.focus_next = b.focus_neighbor_right


func _button(key: String, text: String, primary: bool) -> Button:
	var b: Button = Kit.primary(text, "A") if primary else Kit.button(text)
	b.name = key.capitalize()
	b.custom_minimum_size = Vector2(170, 52)
	b.pressed.connect(func(): finish.call_deferred(key))
	buttons[key] = b
	return b


## The button A lands on: Remove now where it can work, else Open Fixes.
func default_button() -> Button:
	return buttons["remove"] if buttons.has("remove") else buttons["open"]


func start() -> void:
	if is_inside_tree():
		_return_focus = get_viewport().gui_get_focus_owner()
		default_button().grab_focus()
	modulate.a = 0.0
	Motion.to(self, "modulate:a", 1.0, Motion.FAST)


func finish(choice: String) -> void:
	if _done:
		return
	_done = true
	decided.emit(choice)
	if choice != "open" and _return_focus != null and is_instance_valid(_return_focus) and _return_focus.is_inside_tree():
		_return_focus.grab_focus()
	queue_free()


func is_open() -> bool:
	return not _done


## B is Later; nothing behind the card reacts while it's up (Guide included).
func _input(event: InputEvent) -> void:
	if _done or not is_inside_tree():
		return
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		finish("later")
		return
	var guide: bool = (event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_GUIDE) \
		or (event is InputEventKey and event.pressed and event.keycode == KEY_F1)
	if guide:
		get_viewport().set_input_as_handled()


func hints() -> Array:
	var f := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	var label := TF.ATTN_OPEN
	for k in buttons:
		if buttons[k] == f:
			label = (buttons[k] as Button).text
	return [["A", label], ["B", TF.ATTN_LATER]]
