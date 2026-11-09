extends VBoxContainer
## The body of the game page's Achievements card: "23 of 48" with a bar, a
## line about the focused achievement, and a grid of icons. Unlocked first
## (newest first), then locked by how many players have them (easiest next),
## hidden ones last with their name kept secret. Locked icons are dimmed; rare
## ones (under 10% of players) get a gold ring. Data from the Achievements
## service (request -> loaded, changed when rarity arrives).

const Kit := preload("res://scripts/ui/ui_kit.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const ArtCache := preload("res://scripts/ui/art_cache.gd")
const TG := preload("res://scripts/ui/texts_games.gd")
const GameIcons := preload("res://scripts/ui/games/game_icons.gd")
const ProgressLine := preload("res://scripts/ui/games/progress_line.gd")

## Focusable cells changed (built or rebuilt): the page relinks focus.
signal cells_changed
## A cell took focus: the page scrolls the whole card into view.
signal cell_focused

const COLS := 12
## Columns in use (set_columns); COLS by default.
var cols := COLS
const CELL := Vector2(74, 74)
const MAX_CELLS := 48
const RARE := 10.0

var appid := ""
var service: Object
var data: Dictionary = {}
var cells: Array = []
var items: Array = []
var summary: Label
var percent_label: Label
var bar: Control
var grid: GridContainer
var more_label: Label
var detail_icon: TextureRect
var detail_name: Label
var detail_line: Label
var _detail: PanelContainer
var _status: Label


func setup(id: String, svc: Object) -> void:
	name = "Achievements"
	appid = id
	service = svc
	add_theme_constant_override("separation", 14)
	var top := Kit.hbox(14)
	summary = Kit.label(TG.ACH_LOADING, "LeadLabel")
	summary.name = "Summary"
	summary.add_theme_font_override("font", ThemeLib.font("semibold", true))
	top.add_child(summary)
	top.add_child(Kit.spacer())
	percent_label = Kit.label("", "ValueLabel")
	percent_label.name = "Percent"
	top.add_child(percent_label)
	add_child(top)
	bar = ProgressLine.new(8.0)
	bar.name = "Bar"
	add_child(bar)
	_status = Kit.label("", "QuietLabel", true)
	_status.name = "Status"
	_status.visible = false
	add_child(_status)
	_detail = PanelContainer.new()
	_detail.name = "Detail"
	_detail.theme_type_variation = "RaisedPanel"
	var drow := Kit.hbox(16)
	_detail.add_child(drow)
	detail_icon = TextureRect.new()
	detail_icon.custom_minimum_size = Vector2(56, 56)
	detail_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	detail_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	detail_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	drow.add_child(detail_icon)
	var dcol := Kit.vbox(2)
	dcol.alignment = BoxContainer.ALIGNMENT_CENTER
	dcol.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_name = Kit.label("", "")
	detail_name.name = "Name"
	detail_name.add_theme_font_override("font", ThemeLib.font("semibold"))
	dcol.add_child(detail_name)
	detail_line = Kit.label("", "QuietLabel", true)
	detail_line.name = "Line"
	dcol.add_child(detail_line)
	drow.add_child(dcol)
	_detail.visible = false
	add_child(_detail)
	grid = GridContainer.new()
	grid.name = "Grid"
	grid.columns = cols
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 12)
	add_child(grid)
	more_label = Kit.label("", "QuietLabel")
	more_label.visible = false
	add_child(more_label)
	if svc != null:
		if svc.has_signal("loaded"):
			svc.loaded.connect(_on_loaded)
		if svc.has_signal("changed"):
			svc.changed.connect(_on_changed)
		svc.request(appid)


func _on_changed(id: Variant) -> void:
	if str(id) == appid and service != null:
		service.request(appid)


func _on_loaded(id: Variant, result: Dictionary) -> void:
	if str(id) == appid:
		show_data(result)


## Sorted for display: unlocked newest first, then locked by rarity (most
## common first), hidden locked last.
static func ordered(list: Array) -> Array:
	var un: Array = list.filter(func(a): return a.get("unlocked", false))
	var locked: Array = list.filter(func(a): return not a.get("unlocked", false) and not a.get("hidden", false))
	var hidden: Array = list.filter(func(a): return not a.get("unlocked", false) and a.get("hidden", false))
	un.sort_custom(func(a, b): return int(a.get("unlock_time", 0)) > int(b.get("unlock_time", 0)))
	locked.sort_custom(func(a, b): return float(a.get("rarity", -1)) > float(b.get("rarity", -1)))
	return un + locked + hidden


func show_data(result: Dictionary) -> void:
	data = result
	for c in cells:
		Kit.drop(grid, c)
	cells.clear()
	var total := int(result.get("total", 0))
	var unlocked := int(result.get("unlocked", 0))
	if total <= 0:
		# The card's heading already says Achievements: no second title.
		summary.text = ""
		summary.get_parent().visible = false
		percent_label.text = ""
		bar.visible = false
		_detail.visible = false
		_status.visible = true
		_status.text = TG.ACH_NONE if str(result.get("source", "")) == "" else TG.ACH_EMPTY_GAME
		more_label.visible = false
		cells_changed.emit()
		return
	_status.visible = false
	bar.visible = true
	summary.get_parent().visible = true
	summary.text = "%d of %d unlocked" % [unlocked, total]
	percent_label.text = "%d%%" % roundi(100.0 * unlocked / total)
	bar.set_value(float(unlocked) / total, false)
	bar.set_color(ThemeLib.tone("gold") if unlocked == total else Color(0, 0, 0, 0))
	items = ordered(result.get("items", []))
	for i in mini(items.size(), MAX_CELLS):
		var b := _cell(items[i], i)
		grid.add_child(b)
		cells.append(b)
	more_label.visible = items.size() > MAX_CELLS
	more_label.text = "+%d more" % (items.size() - MAX_CELLS)
	_detail.visible = not items.is_empty()
	if not items.is_empty():
		show_item(items[0])
	_link()
	cells_changed.emit()


func _cell(a: Dictionary, i: int) -> Button:
	var b := Button.new()
	b.name = "Ach_%d" % i
	b.focus_mode = Control.FOCUS_ALL
	b.custom_minimum_size = CELL
	b.theme_type_variation = "TileButton"
	var got: bool = a.get("unlocked", false)
	var rare: bool = float(a.get("rarity", -1)) >= 0.0 and float(a.get("rarity", -1)) < RARE
	var bg := ThemeLib.box(ThemeLib.color("surface_2"), ThemeLib.radius("m"), 0, 0)
	if got and rare:
		bg.border_color = ThemeLib.tone("gold")
		bg.set_border_width_all(2)
	for st in ["normal", "hover", "pressed", "hover_pressed"]:
		b.add_theme_stylebox_override(st, bg)
	b.add_theme_stylebox_override("focus", ThemeLib.focus_ring(ThemeLib.radius("m")))
	var icon := TextureRect.new()
	icon.name = "Icon"
	Kit.fill(icon)
	icon.offset_left = 6
	icon.offset_top = 6
	icon.offset_right = -6
	icon.offset_bottom = -6
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	b.add_child(icon)
	_set_icon(icon, a, 40)
	if not got:
		icon.modulate = Color(1, 1, 1, 0.38)
	b.focus_entered.connect(func():
		show_item(a)
		cell_focused.emit())
	b.tooltip_text = _name(a)
	return b


## Icon of an achievement into `rect`: local file (threaded), else a glyph.
func _set_icon(rect: TextureRect, a: Dictionary, glyph_px: int) -> void:
	var got: bool = a.get("unlocked", false)
	if not got and a.get("hidden", false):
		rect.texture = GameIcons.tex("lock", glyph_px, ThemeLib.color("text_2"))
		return
	var path := str(a.get("icon" if got else "icon_gray", ""))
	if not ArtCache.usable(path):
		path = str(a.get("icon", ""))
	if ArtCache.usable(path):
		var ref: WeakRef = weakref(rect)
		var tex := ArtCache.request("achievement", path, func(t):
			var r: TextureRect = ref.get_ref()
			if r != null:
				r.texture = t, self)
		if tex != null:
			rect.texture = tex
			return
	rect.texture = GameIcons.tex("trophy" if got else "lock", glyph_px, ThemeLib.color("accent") if got else ThemeLib.color("text_2"))


static func _name(a: Dictionary) -> String:
	if not a.get("unlocked", false) and a.get("hidden", false):
		return TG.ACH_HIDDEN
	return str(a.get("name", a.get("id", "")))


## The line under the name: description, then when / how rare.
static func describe(a: Dictionary) -> String:
	var got: bool = a.get("unlocked", false)
	var parts: Array[String] = []
	if not got and a.get("hidden", false):
		parts.append(TG.ACH_HIDDEN_DETAIL)
	elif str(a.get("description", "")) != "":
		parts.append(str(a["description"]))
	var tail: Array[String] = []
	if got:
		var t := int(a.get("unlock_time", 0))
		tail.append("Unlocked " + date_text(t) if t > 0 else "Unlocked")
	else:
		tail.append(TG.ACH_LOCKED)
	var r := float(a.get("rarity", -1))
	if r >= 0.0:
		tail.append(("%.1f%% of players" % r) + (" · rare" if r < RARE else ""))
	parts.append(" · ".join(tail))
	return "  ".join(parts) if parts.size() == 1 else parts[0] + "\n" + parts[1]


static func date_text(unix: int) -> String:
	var d := Time.get_datetime_dict_from_unix_time(unix)
	var months := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
	return "%s %d, %d" % [months[int(d["month"]) - 1], int(d["day"]), int(d["year"])]


func show_item(a: Dictionary) -> void:
	detail_name.text = _name(a)
	detail_line.text = describe(a)
	_set_icon(detail_icon, a, 36)
	detail_icon.modulate = Color.WHITE if a.get("unlocked", false) else Color(1, 1, 1, 0.5)


## Left / right along a row, up / down by column; the page links the edges.
func _link() -> void:
	for i in cells.size():
		var c: Control = cells[i]
		var col := i % cols
		c.focus_neighbor_left = c.get_path_to(cells[i - 1] if col > 0 else c)
		c.focus_neighbor_right = c.get_path_to(cells[i + 1] if col < cols - 1 and i + 1 < cells.size() else c)
		if i >= cols:
			c.focus_neighbor_top = c.get_path_to(cells[i - cols])
		if i + cols < cells.size():
			c.focus_neighbor_bottom = c.get_path_to(cells[i + cols])


## Edges: the first row's up goes to `above`, the last row's down to `below`.
func link_edges(above: Control, below: Control) -> void:
	_link()
	for i in cells.size():
		var c: Control = cells[i]
		if i < cols and above != null:
			c.focus_neighbor_top = c.get_path_to(above)
		if i + cols >= cells.size():
			# Cells in a short last row's columns fall to the next control too.
			c.focus_neighbor_bottom = c.get_path_to(below if below != null else c)
	# A cell above an empty spot in the short last row drops to the last cell.
	var last_row_start := (cells.size() - 1) / cols * cols
	for i in range(maxi(0, last_row_start - cols), last_row_start):
		if i + cols >= cells.size() and i < cells.size():
			cells[i].focus_neighbor_bottom = cells[i].get_path_to(cells[cells.size() - 1])


## Fits the grid to `width` px (the card's inner width); relinks focus.
func fit_width(width: float) -> void:
	var n := clampi(int((width + 12.0) / (CELL.x + 12.0)), 3, COLS)
	if n == cols:
		return
	cols = n
	grid.columns = n
	if not cells.is_empty():
		cells_changed.emit()
