extends Button
## A library tile: cover art when the game has a local cover, otherwise a clean
## title card. Badges for anti-cheat and time to beat sit along the bottom.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const Texts := preload("res://scripts/ui/texts.gd")
const View := preload("res://scripts/ui/library_view.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")

const SIZE := Vector2(176, 264)

var game: Dictionary = {}


func setup(g: Dictionary, with_badges := true) -> void:
	game = g
	name = "Tile_" + String(g.get("key", "")).validate_node_name()
	theme_type_variation = "TileButton"
	focus_mode = Control.FOCUS_ALL
	custom_minimum_size = SIZE
	tooltip_text = g.get("title", "")
	clip_contents = true

	var tex := Kit.load_art(g.get("art", {}).get("cover", ""), Vector2i(SIZE) * 2)
	if tex != null:
		var art := TextureRect.new()
		art.name = "Cover"
		art.texture = tex
		art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		art.set_anchors_preset(Control.PRESET_FULL_RECT)
		art.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(art)
	else:
		add_child(title_card(g, 22))

	var badges := Kit.vbox(4)
	badges.name = "Badges"
	badges.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badges.anchor_top = 1.0
	badges.anchor_bottom = 1.0
	badges.offset_left = 8
	badges.offset_top = -8
	badges.offset_bottom = -8
	badges.grow_vertical = Control.GROW_DIRECTION_BEGIN
	add_child(badges)
	for b in (badge_specs(g) if with_badges else []):
		badges.add_child(Kit.badge(b["text"], b["tone"]))
	if not g.get("installed", false):
		modulate = Color(1, 1, 1, 0.7)


## [{"text", "tone"}] for this game, in display order.
static func badge_specs(g: Dictionary) -> Array:
	var out: Array = []
	var info: Dictionary = g.get("info", {})
	var ac := Texts.anticheat_badge(info)
	if not ac.is_empty():
		out.append(ac)
	var ttb := Texts.ttb_badge(info)
	if ttb != "":
		out.append({"text": ttb + " to beat", "tone": ""})
	if not g.get("installed", false):
		out.append({"text": "Not installed", "tone": ""})
	return out


## Art-less card: a quiet colour picked from the title so tiles differ, with
## the title and store written on it.
static func title_card(g: Dictionary, font_size: int) -> Control:
	var card := Panel.new()
	card.name = "TitleCard"
	card.set_anchors_preset(Control.PRESET_FULL_RECT)
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var title: String = g.get("title", "")
	var hue := float(absi(hash(title)) % 360) / 360.0
	var sb := ThemeLib.box(Color.from_hsv(hue, 0.3, 0.24), 12)
	sb.border_width_top = 4
	sb.border_color = Color.from_hsv(hue, 0.45, 0.55)
	card.add_theme_stylebox_override("panel", sb)

	var col := Kit.vbox(6)
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	col.offset_left = 14
	col.offset_right = -14
	col.offset_top = 18
	col.offset_bottom = -14
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(col)
	var t := Kit.label(title if title != "" else "Untitled", "", true)
	t.name = "Title"
	t.add_theme_font_size_override("font_size", font_size)
	t.max_lines_visible = 4
	t.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	col.add_child(t)
	col.add_child(Kit.label(View.store_name(g.get("store", "")), "QuietLabel"))
	return card
