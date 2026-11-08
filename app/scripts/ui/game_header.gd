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

var game: Dictionary = {}
var eyebrow: Label
var logo: TextureRect
var title: Label
var meta: HBoxContainer
var badges: HBoxContainer
var max_logo := Vector2(460, 150)
var max_badges := 4
var badge_skip: Array = ["store"]


func _init() -> void:
	name = "GameHeader"
	add_theme_constant_override("separation", 10)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	eyebrow = Kit.label("", "AccentLabel")
	eyebrow.name = "Eyebrow"
	add_child(eyebrow)
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
	title.max_lines_visible = 2
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title.add_theme_constant_override("line_spacing", -6)
	title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.35) if ThemeLib.is_dark() else Color(1, 1, 1, 0.0))
	title.add_theme_constant_override("shadow_offset_y", 2)
	title.add_theme_constant_override("shadow_outline_size", 6)
	add_child(title)
	meta = Kit.hbox(22)
	meta.name = "Meta"
	meta.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(meta)
	badges = Kit.hbox(8)
	badges.name = "Badges"
	badges.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(badges)


## `line`: the short accent line above the title ("" hides it).
func show_game(g: Dictionary, line := "", animate := false) -> void:
	var same: bool = g.get("key", "") == game.get("key", "-")
	game = g
	eyebrow.text = line
	eyebrow.visible = line != ""
	title.text = g.get("title", "")
	_logo_for(g)
	for c in meta.get_children():
		Kit.drop(meta, c)
	for seg in meta_segments(g, int(Time.get_unix_time_from_system())):
		meta.add_child(_segment(seg[0], seg[1]))
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
	var out: Array = [["store", View.store_name(String(g.get("store", "")))]]
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
	for c in meta.get_children():
		for l in c.get_children():
			if l is Label:
				parts.append(l.text)
	return "   ".join(parts)


func _segment(icon: String, text: String) -> HBoxContainer:
	var row := Kit.hbox(7)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(Icons.rect(icon, 18, ThemeLib.color("text_2")))
	var l := Kit.label(text, "QuietLabel")
	l.add_theme_font_override("font", ThemeLib.font("medium"))
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(l)
	return row


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
