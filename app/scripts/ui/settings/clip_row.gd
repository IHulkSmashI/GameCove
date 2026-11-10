extends VBoxContainer
## One clip in Settings > Media > Clips: its picture, the game, when, how long
## and how big; A opens its sheet. Same RowButton look and `key` / `button`
## contract as action_row.gd, so pages keep focus on it across rebuilds.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const Icons := preload("res://scripts/ui/icons.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Clips := preload("res://scripts/system/clips.gd")
const Recording := preload("res://scripts/system/recording.gd")
const TX := preload("res://scripts/ui/texts_extras.gd")
const THUMB := Vector2(128, 72)

signal pressed

var key := ""
var clip: Dictionary = {}
var button: Button
var thumb: TextureRect
var title_label: Label
var meta_label: Label
var _hint: Label
var _chevron: TextureRect


## "Nov 10, 3:30 PM · 0:42 · 48 MB" (the length only when the file says it).
static func meta_text(c: Dictionary) -> String:
	var parts := PackedStringArray()
	var when := Clips.when_text(int(c.get("mtime", 0)))
	if when != "":
		parts.append(when)
	var secs := float(c.get("seconds", -1.0))
	if secs >= 0.0:
		parts.append(Recording.clock(roundi(secs)))
	parts.append(Clips.size_text(int(c.get("size", 0))))
	return " · ".join(parts)


func setup(c: Dictionary, picture: Texture2D = null) -> void:
	clip = c
	key = "clip_" + str(c.get("path", "")).md5_text().substr(0, 12)
	name = key
	add_theme_constant_override("separation", 6)
	button = Kit.button("", "RowButton")
	button.name = "Button"
	button.custom_minimum_size = Vector2(0, THUMB.y + 20)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.pressed.connect(func(): pressed.emit())
	button.focus_entered.connect(_refresh_focus)
	button.focus_exited.connect(_refresh_focus)
	add_child(button)
	var row := Kit.hbox(16)
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 10
	row.offset_right = -14
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(row)
	var frame := PanelContainer.new()
	frame.name = "Picture"
	frame.custom_minimum_size = THUMB
	frame.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
	var fsb := ThemeLib.box(ThemeLib.soft(0.08), ThemeLib.radius("s"), 0, 0)
	frame.add_theme_stylebox_override("panel", fsb)
	thumb = TextureRect.new()
	thumb.name = "Thumb"
	thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	thumb.texture = picture
	frame.add_child(thumb)
	if picture == null:
		var ph := Icons.rect("film", 28, ThemeLib.color("text_3"))
		ph.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		frame.add_child(ph)
	row.add_child(frame)
	var texts := Kit.vbox(2)
	texts.alignment = BoxContainer.ALIGNMENT_CENTER
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	texts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_label = Kit.label(Clips.title_of(c))
	title_label.name = "Title"
	title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title_label.add_theme_font_override("font", ThemeLib.font("medium"))
	texts.add_child(title_label)
	meta_label = Kit.label(meta_text(c), "QuietLabel")
	meta_label.name = "Meta"
	meta_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	meta_label.add_theme_font_override("font", ThemeLib.mono(false, 0))
	meta_label.add_theme_font_size_override("font_size", ThemeLib.SIZE_CAPTION)
	texts.add_child(meta_label)
	row.add_child(texts)
	_chevron = Icons.rect("chevron_right", 18, ThemeLib.color("text_3"))
	row.add_child(_chevron)
	_hint = Kit.label(TX.CLIPS_ROW_HINT, "QuietLabel", true)
	_hint.name = "Hint"
	add_child(_hint)
	_refresh_focus()


func has_picture() -> bool:
	return thumb.texture != null


func _refresh_focus() -> void:
	_hint.visible = button.has_focus()
	_chevron.texture = Icons.tex("chevron_right", 18, ThemeLib.color("text") if button.has_focus() else ThemeLib.color("text_3"))
