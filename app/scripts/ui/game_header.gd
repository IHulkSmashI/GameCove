extends VBoxContainer
## The block that names a game over its art: a short line above (why it's
## here), the logo (Steam's library_logo) or the title in the display face,
## a meta line with icons, and badge chips. Used by the Home spotlight and
## the page template (game page, and later store/deal pages).

const Kit := preload("res://scripts/ui/ui_kit.gd")
const Texts := preload("res://scripts/ui/texts.gd")
const View := preload("res://scripts/ui/library_view.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const ArtCache := preload("res://scripts/ui/art_cache.gd")
const Badges := preload("res://scripts/ui/badges.gd")
const Badge := preload("res://scripts/ui/badge.gd")
const Icons := preload("res://scripts/ui/icons.gd")
const Motion := preload("res://scripts/ui/motion.gd")
const BrandMark := preload("res://scripts/ui/brand_mark.gd")

var game: Dictionary = {}
## The line above the title ("Jump back in"), drawn as a mono tag chip.
var eyebrow: Label
var tag: PanelContainer
## Store and year in mono micro type, beside the tag.
var source: Label
var logo: TextureRect
var title: Label
var meta: HBoxContainer
var badges: HBoxContainer
var max_logo := Vector2(460, 150)
var max_badges := 4
var badge_skip: Array = ["store"]
## Title size: DISPLAY for short titles, smaller for long ones (two lines max).
var title_size := ThemeLib.SIZE_DISPLAY
var _top: HBoxContainer


func _init() -> void:
	name = "GameHeader"
	add_theme_constant_override("separation", ThemeLib.SPACE_3)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_top = Kit.hbox(ThemeLib.SPACE_3)
	_top.name = "Top"
	_top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_top)
	tag = PanelContainer.new()
	tag.name = "Tag"
	tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tag.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_top.add_child(tag)
	eyebrow = Kit.micro("", "EyebrowLabel")
	eyebrow.name = "Eyebrow"
	tag.add_child(eyebrow)
	source = Kit.micro("")
	source.name = "Source"
	source.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_top.add_child(source)
	logo = TextureRect.new()
	logo.name = "Logo"
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo.stretch_mode = TextureRect.STRETCH_SCALE
	logo.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	logo.visible = false
	add_child(logo)
	title = Kit.label("", "DisplayLabel", true)
	title.name = "HeroTitle"
	title.uppercase = true
	title.max_lines_visible = 2
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title.add_theme_constant_override("line_spacing", -8)
	title.add_theme_constant_override("shadow_offset_y", 2)
	title.add_theme_constant_override("shadow_outline_size", 8)
	add_child(title)
	meta = Kit.hbox(ThemeLib.SPACE_3)
	meta.name = "Meta"
	meta.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(meta)
	# The source (store, year) joins the mono meta line under the title.
	remove_child(meta)
	add_child(meta)
	move_child(meta, title.get_index() + 1)
	badges = Kit.hbox(ThemeLib.SPACE_2)
	badges.name = "Badges"
	badges.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(badges)
	_restyle()


## Light themes' text halo strength (see _halo()).
const HALO_ALPHA := 0.85


func _restyle() -> void:
	# The line above the title is plain mono accent text (no box).
	tag.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.40) if ThemeLib.is_dark() else Color(ThemeLib.color("scrim"), HALO_ALPHA))


## Colour of the tag (the art accent on Home).
func set_tag_color(c: Color) -> void:
	eyebrow.add_theme_color_override("font_color", c if c.a > 0.0 else ThemeLib.color("accent"))
	_restyle()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and title != null:
		_restyle()
		if not game.is_empty():
			show_game(game, eyebrow.text)


## `line`: the short accent line above the title ("" hides it).
func show_game(g: Dictionary, line := "", animate := false) -> void:
	var same: bool = g.get("key", "") == game.get("key", "-")
	game = g
	eyebrow.text = line
	tag.visible = line != ""
	title.text = g.get("title", "")
	var fs := title_size if title.text.length() <= 16 else int(title_size * 0.8)
	title.add_theme_font_size_override("font_size", fs)
	_logo_for(g)
	for c in meta.get_children():
		Kit.drop(meta, c)
	# One mono line: "Steam · Played today · 13 h played · 2017".
	var parts: Array[String] = []
	for seg in meta_segments(g, int(Time.get_unix_time_from_system())):
		parts.append(seg[1])
	# The store's own logo leads the line (the name stays in the text, so a
	# store without a logo, or one switched off, still reads the same).
	var mark := BrandMark.rect(str(g.get("store", "")), 18, _meta_color())
	if mark != null:
		mark.name = "StoreLogo"
		meta.add_child(mark)
	if not parts.is_empty():
		meta.add_child(_segment("", "  ·  ".join(parts)))
	source.text = ""
	source.visible = false
	meta.visible = meta.get_child_count() > 0
	for c in badges.get_children():
		Kit.drop(badges, c)
	var n := 0
	for b in Badges.for_game(g):
		if b["kind"] in badge_skip or n >= max_badges:
			continue
		badges.add_child(Badge.make(b, "chip"))
		n += 1
	badges.visible = n > 0
	if animate and not same:
		modulate.a = 0.0
		position.x = Motion.slide(-12.0)
		Motion.to(self, "modulate:a", 1.0, Motion.BASE)
		if not Motion.reduce:
			Motion.to(self, "position:x", 0.0, Motion.BASE)


## [[icon, text], ...] for the meta line: store, last played, playtime.
static func meta_segments(g: Dictionary, now: int) -> Array:
	var out: Array = [["store", View.store_label(g)]]
	var info: Variant = g.get("info", {})
	if g.has("last_played"):
		out.append(["clock", Texts.last_played_text(int(g.get("last_played", 0)), now)])
	var pt := Texts.playtime_text(int(g.get("playtime_min", 0)))
	if pt != "":
		out.append(["gamepad", pt])
	if info is Dictionary and info.get("released") != null:
		out.append(["calendar", str(info["released"])])
	return out


func meta_text() -> String:
	var parts: Array[String] = []
	if source.visible:
		parts.append(source.text)
	for c in meta.get_children():
		for l in c.get_children():
			if l is Label:
				parts.append(l.text)
	return "   ".join(parts)


func _segment(icon: String, text: String) -> HBoxContainer:
	var row := Kit.hbox(ThemeLib.SPACE_2)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if icon != "":
		row.add_child(Icons.rect(icon, 18, ThemeLib.color("accent")))
	var l := Kit.label(text, "MonoLabel")
	l.add_theme_font_override("font", ThemeLib.mono(false, 2))
	l.add_theme_font_size_override("font_size", ThemeLib.SIZE_CAPTION)
	l.add_theme_color_override("font_color", _meta_color())
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_halo(l)
	row.add_child(l)
	return row


## Light themes: a soft light halo around text that sits on the art past the
## title shade (the art keeps its colour, so dark text needs its own ground).
static func _halo(l: Label) -> void:
	if ThemeLib.is_dark():
		return
	l.add_theme_color_override("font_shadow_color", Color(ThemeLib.color("scrim"), HALO_ALPHA))
	l.add_theme_constant_override("shadow_offset_x", 0)
	l.add_theme_constant_override("shadow_offset_y", 0)
	l.add_theme_constant_override("shadow_outline_size", 10)


static func _meta_color() -> Color:
	return ThemeLib.color("text").lerp(ThemeLib.color("text_2"), 0.35)


func _logo_for(g: Dictionary) -> void:
	var a: Variant = g.get("art", {})
	var p: String = a.get("logo", "") if a is Dictionary else ""
	logo.visible = false
	title.visible = true
	# Store logos are drawn for dark art; on a light theme the title reads better.
	if not ArtCache.usable(p) or not ThemeLib.is_dark():
		return
	var want := p
	var tex := ArtCache.request("logo", p, func(t):
		if is_instance_valid(self) and _logo_path() == want:
			_show_logo(t), self)
	if tex != null:
		_show_logo(tex)


func _logo_path() -> String:
	var a: Variant = game.get("art", {})
	return a.get("logo", "") if a is Dictionary else ""


func _show_logo(tex: Texture2D) -> void:
	var s := minf(max_logo.x / tex.get_width(), max_logo.y / tex.get_height())
	logo.texture = tex
	logo.custom_minimum_size = Vector2(tex.get_width(), tex.get_height()) * s
	logo.visible = true
	title.visible = false
