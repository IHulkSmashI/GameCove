extends VBoxContainer
## The body of the game page's Achievements card, the same data Home's
## progress card shows (one Achievements service and its cache): "6 of 14
## unlocked" with a bar, the rarest one you've unlocked in a gold-edged box
## (the focused one instead while you browse), then a list of rows: unlocked
## first (newest first), then locked by how many players have them (easiest
## next), hidden ones last with their name kept secret. Locked rows are
## dimmed; rare ones (under 10% of players) get a gold edge. The first
## LIST_ROWS rows show, then "Show all n"; A on it lists the rest. Data from
## the Achievements service (request -> loaded, changed when rarity arrives).

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

const ProgressCard := preload("res://scripts/ui/progress_card.gd")

## A list now: one column (kept for callers).
const COLS := 1
var cols := COLS
const CELL := Vector2(0, 46)
const MAX_CELLS := 48
## Rows shown before "Show all" (which makes the fourth): the card fits the
## bento on one screen, no "More below".
const LIST_ROWS := 3
const RARE := 10.0

## The list shows every row (after "Show all").
var expanded := false
## The rarest unlocked achievement ({} when none has a rarity yet).
var rarest: Dictionary = {}
var detail_eyebrow: Label

var appid := ""
var service: Object
var data: Dictionary = {}
var cells: Array = []
var items: Array = []
var summary: Label
var percent_label: Label
var bar: Control
## Gone (the icon grid became `list`); null, kept for callers.
var grid: GridContainer
var list: VBoxContainer
## "Show all n" while the list is cut at LIST_ROWS.
var show_all: Button
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
	detail_icon.custom_minimum_size = Vector2(48, 48)
	detail_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	detail_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	detail_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	drow.add_child(detail_icon)
	var dcol := Kit.vbox(2)
	dcol.alignment = BoxContainer.ALIGNMENT_CENTER
	dcol.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_eyebrow = Kit.micro(TG.ACH_RAREST)
	detail_eyebrow.name = "Eyebrow"
	dcol.add_child(detail_eyebrow)
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
	list = Kit.vbox(6)
	list.name = "List"
	add_child(list)
	grid = null
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
		Kit.drop(list, c)
	cells.clear()
	show_all = null
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
	rarest = ProgressCard.rarest(result)
	var n := mini(items.size(), MAX_CELLS)
	var shown := n if expanded or n <= LIST_ROWS + 1 else LIST_ROWS
	for i in shown:
		var b := _cell(items[i], i)
		list.add_child(b)
		cells.append(b)
	if shown < n:
		show_all = Kit.button(TG.ACH_SHOW_ALL % items.size(), "RowButton")
		show_all.name = "ShowAll"
		show_all.custom_minimum_size = Vector2(0, 44)
		show_all.alignment = HORIZONTAL_ALIGNMENT_LEFT
		show_all.icon = GameIcons.tex("chevron_down", 18, ThemeLib.color("text_2"))
		show_all.pressed.connect(_expand)
		show_all.focus_entered.connect(func(): show_rarest(); cell_focused.emit())
		list.add_child(show_all)
		cells.append(show_all)
	more_label.visible = items.size() > MAX_CELLS and expanded
	more_label.text = "+%d more" % (items.size() - MAX_CELLS)
	_detail.visible = not items.is_empty()
	show_rarest()
	_link()
	cells_changed.emit()


## "Show all": add the rest of the rows in its place (it's pressed right now,
## so it's let go of, not freed in its own signal) and focus the first new one.
func _expand() -> void:
	if expanded or show_all == null:
		return
	expanded = true
	var at := cells.find(show_all)
	cells.erase(show_all)
	list.remove_child(show_all)
	show_all.queue_free()
	show_all = null
	for i in range(at, mini(items.size(), MAX_CELLS)):
		var b := _cell(items[i], i)
		list.add_child(b)
		cells.append(b)
	more_label.visible = items.size() > MAX_CELLS
	_link()
	cells_changed.emit()
	if at < cells.size() and is_inside_tree():
		cells[at].grab_focus()


## The box over the list: the rarest unlocked one, gold-edged, when nothing
## is being browsed (else the first one).
func show_rarest() -> void:
	if not rarest.is_empty():
		show_item(rarest, true)
	elif not items.is_empty():
		show_item(items[0])


## One row: icon, name, "Unlocked Nov 7" or "Locked", rarity on the right.
func _cell(a: Dictionary, i: int) -> Button:
	var b := Button.new()
	b.name = "Ach_%d" % i
	b.focus_mode = Control.FOCUS_ALL
	b.custom_minimum_size = CELL
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.theme_type_variation = "RowButton"
	var got: bool = a.get("unlocked", false)
	var rare: bool = float(a.get("rarity", -1)) >= 0.0 and float(a.get("rarity", -1)) < RARE
	if got and rare:
		# The row's own fill (as the theme's RowButton draws it), with a gold edge.
		var g2: Color = ThemeLib.color("glass_2")
		var sb := ThemeLib.box(Color(g2, g2.a * 0.8) if ThemeLib.is_dark() else ThemeLib.color("surface"), ThemeLib.radius("m"), 18, 10)
		sb.border_color = Color(ThemeLib.tone("gold"), 0.7)
		sb.set_border_width_all(1)
		for st in ["normal", "hover"]:
			b.add_theme_stylebox_override(st, sb)
	var row := Kit.hbox(12)
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 10
	row.offset_right = -14
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(row)
	var icon := TextureRect.new()
	icon.name = "Icon"
	icon.custom_minimum_size = Vector2(34, 34)
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(icon)
	_set_icon(icon, a, 24)
	var col := Kit.vbox(0)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var nm := Kit.label(_name(a), "")
	nm.name = "Name"
	nm.add_theme_font_override("font", ThemeLib.font("semibold"))
	nm.add_theme_font_size_override("font_size", ThemeLib.SIZE_SMALL)
	nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	nm.clip_text = true
	col.add_child(nm)
	var t := int(a.get("unlock_time", 0))
	var st_line := (("Unlocked " + date_text(t)) if t > 0 else "Unlocked") if got else TG.ACH_LOCKED
	var sub := Kit.label(st_line, "CaptionLabel")
	sub.name = "State"
	sub.add_theme_color_override("font_color", ThemeLib.color("good") if got else ThemeLib.color("text_3"))
	col.add_child(sub)
	row.add_child(col)
	var r := float(a.get("rarity", -1))
	if r >= 0.0:
		var pct := Kit.label(ProgressCard._pct(r) + "%", "MonoLabel")
		pct.name = "Rarity"
		pct.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		pct.add_theme_color_override("font_color", ThemeLib.tone("gold") if rare else ThemeLib.color("text_2"))
		row.add_child(pct)
	if not got:
		icon.modulate = Color(1, 1, 1, 0.38)
		nm.add_theme_color_override("font_color", ThemeLib.color("text_2"))
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


## The box over the list for `a`; `as_rarest` gives it the gold edge and the
## RAREST eyebrow (Home's card says the same thing).
func show_item(a: Dictionary, as_rarest := false) -> void:
	detail_name.text = _name(a)
	# The rarest box stays two lines (when, how rare); browsing shows the description too.
	detail_line.text = describe(a).get_slice("\n", 1) if as_rarest and "\n" in describe(a) else describe(a)
	_set_icon(detail_icon, a, 36)
	detail_icon.modulate = Color.WHITE if a.get("unlocked", false) else Color(1, 1, 1, 0.5)
	detail_eyebrow.visible = as_rarest
	var sb := ThemeLib.box(ThemeLib.soft(0.05) if ThemeLib.is_dark() else ThemeLib.color("surface"), ThemeLib.radius("m"), 16, 12)
	sb.border_color = Color(ThemeLib.tone("gold"), 0.85) if as_rarest else ThemeLib.color("line")
	sb.set_border_width_all(2 if as_rarest else 1)
	_detail.add_theme_stylebox_override("panel", sb)
	detail_eyebrow.add_theme_color_override("font_color", ThemeLib.tone("gold"))


## Up / down along the list; left / right stay put. The page links the edges.
func _link() -> void:
	for i in cells.size():
		var c: Control = cells[i]
		c.focus_neighbor_left = c.get_path_to(c)
		c.focus_neighbor_right = c.get_path_to(c)
		if i > 0:
			c.focus_neighbor_top = c.get_path_to(cells[i - 1])
		if i + 1 < cells.size():
			c.focus_neighbor_bottom = c.get_path_to(cells[i + 1])


## Edges: the first row's up goes to `above`, the last row's down to `below`.
func link_edges(above: Control, below: Control) -> void:
	_link()
	if cells.is_empty():
		return
	if above != null:
		cells[0].focus_neighbor_top = cells[0].get_path_to(above)
	cells[-1].focus_neighbor_bottom = cells[-1].get_path_to(below if below != null else cells[-1])


## Kept for callers: a list fits any width.
func fit_width(_width: float) -> void:
	pass
