extends PanelContainer
## The "progression" glass card on the Home hero: achievement count and bar,
## the rarest achievement you've unlocked, and battery time left. Every line
## comes from real data (the Achievements service, main's battery estimate);
## the card hides when there's nothing to show. Reads achievements on the
## service's thread pool (request / loaded), never on the main thread.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const Icons := preload("res://scripts/ui/icons.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Motion := preload("res://scripts/ui/motion.gd")

const WIDTH := 300

var service: Object = null
var game: Dictionary = {}
var data: Dictionary = {}
var battery_left := ""
var count_label: Label
var bar: Control
var rare_box: PanelContainer
var rare_name: Label
var rare_line: Label
var battery_row: HBoxContainer
var battery_label: Label
var _head: HBoxContainer
var _fill: Panel
var _track: Panel
var _rare_icon: PanelContainer


func _init() -> void:
	name = "ProgressCard"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(WIDTH, 0)
	var col := Kit.vbox(ThemeLib.SPACE_3)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(col)
	_head = Kit.hbox(ThemeLib.SPACE_2)
	_head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_head.add_child(Kit.micro("Achievements"))
	_head.add_child(Kit.spacer())
	count_label = Kit.label("", "MonoLabel")
	count_label.name = "Count"
	count_label.add_theme_font_override("font", ThemeLib.font("mono_bold"))
	_head.add_child(count_label)
	col.add_child(_head)
	bar = Control.new()
	bar.name = "Bar"
	bar.custom_minimum_size = Vector2(0, 6)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_track = Panel.new()
	Kit.fill(_track)
	bar.add_child(_track)
	_fill = Panel.new()
	_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fill.anchor_bottom = 1.0
	bar.add_child(_fill)
	col.add_child(bar)
	rare_box = PanelContainer.new()
	rare_box.name = "Rarest"
	rare_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var rr := Kit.hbox(ThemeLib.SPACE_3)
	rr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rare_icon = PanelContainer.new()
	_rare_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rare_icon.custom_minimum_size = Vector2(34, 34)
	_rare_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	rr.add_child(_rare_icon)
	var rt := Kit.vbox(2)
	rt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rare_name = Kit.label("", "")
	rare_name.add_theme_font_override("font", ThemeLib.font("bold"))
	rare_name.add_theme_font_size_override("font_size", ThemeLib.SIZE_CAPTION)
	rare_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	rare_name.clip_text = true
	rt.add_child(rare_name)
	rare_line = Kit.label("", "MonoLabel")
	rare_line.add_theme_font_size_override("font_size", 11)
	rt.add_child(rare_line)
	rr.add_child(rt)
	rare_box.add_child(rr)
	col.add_child(rare_box)
	battery_row = Kit.hbox(ThemeLib.SPACE_2)
	battery_row.name = "BatteryLeft"
	battery_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bl := Kit.label("Battery time left", "CaptionLabel")
	battery_row.add_child(bl)
	battery_row.add_child(Kit.spacer())
	battery_label = Kit.label("", "MonoLabel")
	battery_row.add_child(battery_label)
	col.add_child(battery_row)
	visible = false
	_restyle()


func set_service(svc: Object) -> void:
	if service != null and service.has_signal("loaded") and service.loaded.is_connected(_on_loaded):
		service.loaded.disconnect(_on_loaded)
	service = svc
	if service != null and service.has_signal("loaded"):
		service.loaded.connect(_on_loaded)
	if service != null and service.has_signal("changed"):
		service.changed.connect(func(id): if id == _appid(): _ask())
	_ask()


func set_battery_left(text: String) -> void:
	battery_left = text
	_render()


## Steam games only (the service reads Steam's own achievement cache).
func show_game(g: Dictionary) -> void:
	if g.get("key", "") == game.get("key", "-"):
		return
	game = g
	data = {}
	_render()
	_ask()


func _appid() -> String:
	return str(game.get("id", "")) if game.get("store", "") == "steam" else ""


func _ask() -> void:
	var id := _appid()
	if id == "" or service == null:
		return
	if service.has_method("request") and is_inside_tree():
		service.request(id)
	elif service.has_method("achievements_for"):
		_on_loaded(id, service.achievements_for(id))


func _on_loaded(id: String, result: Dictionary) -> void:
	if id != _appid():
		return
	data = result
	_render()


## The rarest unlocked achievement ({} if none has a known rarity).
static func rarest(result: Dictionary) -> Dictionary:
	var best: Dictionary = {}
	for it in result.get("items", []):
		if not it.get("unlocked", false) or float(it.get("rarity", -1)) < 0.0:
			continue
		if best.is_empty() or float(it["rarity"]) < float(best["rarity"]):
			best = it
	return best


func _render() -> void:
	var total := int(data.get("total", 0))
	var has_ach := total > 0
	_head.visible = has_ach
	bar.visible = has_ach
	var r := rarest(data)
	rare_box.visible = has_ach and not r.is_empty()
	battery_row.visible = battery_left != ""
	battery_label.text = battery_left
	# No game (the empty home's welcome picture sits here): no card.
	visible = (has_ach or battery_left != "") and not game.is_empty()
	if has_ach:
		var got := int(data.get("unlocked", 0))
		var pct := roundi(100.0 * got / total)
		count_label.text = "%d / %d (%d%%)" % [got, total, pct]
		_fill.anchor_right = clampf(float(got) / total, 0.0, 1.0)
		_fill.offset_right = 0
	if not r.is_empty():
		rare_name.text = "Rarest: " + str(r.get("name", ""))
		rare_line.text = "Unlocked by %s%% of players" % _pct(float(r["rarity"]))


static func _pct(v: float) -> String:
	return ("%.1f" % v) if v < 10.0 else str(roundi(v))


var _styling := false


func _restyle() -> void:
	if _styling:
		return
	_styling = true
	add_theme_stylebox_override("panel", ThemeLib.card(20, 16))
	_track.add_theme_stylebox_override("panel", ThemeLib.box(ThemeLib.soft(0.12), 999, 0, 0))
	_fill.add_theme_stylebox_override("panel", ThemeLib.gradient_pill(ThemeLib.color("accent"), ThemeLib.color("accent_2").lightened(0.15), 6, 0, 0, false))
	count_label.add_theme_color_override("font_color", ThemeLib.color("accent") if ThemeLib.is_dark() else ThemeLib.color("text"))
	var warn := ThemeLib.color("warn")
	var rb := ThemeLib.box(ThemeLib.soft(0.04), ThemeLib.radius("m"), 12, 10)
	rb.border_color = ThemeLib.color("line_2")
	rb.set_border_width_all(1)
	rare_box.add_theme_stylebox_override("panel", rb)
	var ib := ThemeLib.box(Color(warn, 0.14), 8, 0, 0)
	ib.border_color = Color(warn, 0.5)
	ib.set_border_width_all(1)
	_rare_icon.add_theme_stylebox_override("panel", ib)
	for c in _rare_icon.get_children():
		c.free()
	var ic := Icons.rect("trophy" if Icons.PATHS.has("trophy") else "star", 18, warn)
	ic.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_rare_icon.add_child(ic)
	rare_line.add_theme_color_override("font_color", warn)
	battery_label.add_theme_color_override("font_color", ThemeLib.color("good"))
	_styling = false


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and count_label != null:
		_restyle()
