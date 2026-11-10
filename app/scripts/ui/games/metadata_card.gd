extends VBoxContainer
## Game details on the game page: critic scores, the facts row (genres,
## developer, publisher, release date, controller support), a small strip of
## screenshots, "Change artwork", and the sources' credits. Fills in as the
## Library's detail lookups arrive (Library.metadata_changed).
##
##   var card := MetadataCard.new()
##   card.setup(game, Library)          # library may be null (previews, tests)
##   card.link_requested.connect(func(title, line, url): handoff.open(title, line, url))
##   card.artwork_requested.connect(...)
##   card.relink.connect(...)           # its focusable controls changed
##
## Each score is a button with its source's name on it; A hands the source's
## page to the phone (link_requested). Metacritic's score is coloured the way
## Metacritic colours it: green 75 and up, yellow 50 to 74, red under 50.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Metadata := preload("res://scripts/library/meta/metadata.gd")
const Icons := preload("res://scripts/ui/icons.gd")

signal link_requested(title: String, line: String, url: String)
signal artwork_requested
signal relink

## Metacritic's own score colours.
const MC_COLORS := {"good": Color("#66cc33"), "mixed": Color("#ffcc33"), "bad": Color("#ff0000")}
const SHOT := Vector2(224, 126)
const MONTH_NAMES := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

var game: Dictionary = {}
var library: Object
var meta: Dictionary = Metadata.empty()
var critic_buttons: Array = []
var shot_buttons: Array = []
var artwork_button: Button
var credit_label: Label
var _critics: HBoxContainer
var _facts: GridContainer
var _shots_scroll: ScrollContainer
var _shots: HBoxContainer


func _init() -> void:
	name = "GameDetails"
	add_theme_constant_override("separation", 14)
	_critics = Kit.hbox(10)
	_critics.name = "Critics"
	add_child(_critics)
	_facts = GridContainer.new()
	_facts.name = "Facts"
	_facts.columns = 2
	_facts.add_theme_constant_override("h_separation", 16)
	_facts.add_theme_constant_override("v_separation", 6)
	add_child(_facts)
	_shots_scroll = ScrollContainer.new()
	_shots_scroll.name = "Screenshots"
	_shots_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_shots_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_shots_scroll.custom_minimum_size = Vector2(0, SHOT.y + 8)
	_shots = Kit.hbox(10)
	_shots_scroll.add_child(_shots)
	add_child(_shots_scroll)
	artwork_button = Kit.button("Change artwork", "")
	artwork_button.name = "ChangeArtwork"
	artwork_button.icon = Icons.tex("palette", 20)
	artwork_button.custom_minimum_size = Vector2(0, 48)
	artwork_button.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	artwork_button.add_theme_constant_override("h_separation", 10)
	artwork_button.pressed.connect(func(): artwork_requested.emit())
	add_child(artwork_button)
	credit_label = Kit.label("", "CaptionLabel", true)
	credit_label.name = "DetailsCredit"
	credit_label.add_theme_font_size_override("font_size", 12)
	credit_label.add_theme_color_override("font_color", ThemeLib.color("text_3"))
	add_child(credit_label)


func setup(g: Dictionary, lib: Object = null) -> void:
	game = g
	library = lib
	if library != null and library.has_signal("metadata_changed"):
		library.metadata_changed.connect(_on_metadata_changed)
	show_meta(_meta_of(g))
	if library != null and library.has_method("request_metadata"):
		library.request_metadata(g)


static func _meta_of(g: Dictionary) -> Dictionary:
	var info = g.get("info", {})
	var m = info.get("meta") if info is Dictionary else null
	return m if m is Dictionary else Metadata.empty()


func _on_metadata_changed(key: String) -> void:
	if not is_instance_valid(self) or key != str(game.get("key", "")) or library == null:
		return
	var fresh: Dictionary = library.game_by_key(key) if library.has_method("game_by_key") else {}
	if not fresh.is_empty():
		game = fresh
		show_meta(_meta_of(fresh))


func focusables() -> Array:
	var out: Array = critic_buttons.duplicate()
	out.append_array(shot_buttons)
	if artwork_button.visible:
		out.append(artwork_button)
	return out


## Builds everything from a merged details block (Metadata's shape).
func show_meta(m: Dictionary) -> void:
	var had := focusables().size()
	meta = m
	_build_critics()
	_build_facts()
	_build_shots()
	var names: Array = Metadata.credits(m).map(func(c): return c["text"])
	credit_label.text = ("Details: " + ", ".join(names)) if not names.is_empty() else ""
	credit_label.visible = not names.is_empty()
	if focusables().size() != had or had == 0:
		relink.emit()


# ------------------------------------------------------------ critics

static func date_text(iso: String) -> String:
	if iso.length() < 10:
		return iso
	var mo := iso.substr(5, 2).to_int()
	return "%d %s %s" % [iso.substr(8, 2).to_int(), MONTH_NAMES[clampi(mo - 1, 0, 11)], iso.substr(0, 4)]


## What each critic badge shows: [{"id", "score", "source", "line", "url", "color"}].
static func badges(m: Dictionary) -> Array:
	var c: Dictionary = m.get("critics", {})
	var out := []
	if c.get("metacritic") is Dictionary:
		var s := int(c["metacritic"]["score"])
		out.append({"id": "metacritic", "score": s, "source": "Metacritic", "line": "Metascore",
			"url": str(c["metacritic"].get("url", "")), "color": MC_COLORS[Metadata.metacritic_band(s)], "dark_text": true})
	if c.get("opencritic") is Dictionary:
		var o: Dictionary = c["opencritic"]
		var parts := []
		if str(o.get("tier", "")) != "":
			parts.append(str(o["tier"]))
		if int(o.get("percent_recommended", -1)) >= 0:
			parts.append("%d%% recommend" % int(o["percent_recommended"]))
		out.append({"id": "opencritic", "score": int(o["score"]), "source": "OpenCritic",
			"line": " · ".join(parts) if not parts.is_empty() else "Top critic average", "url": str(o.get("url", "")),
			"color": ThemeLib.color("accent"), "dark_text": false})
	if out.is_empty() and c.get("igdb_critic") is Dictionary:
		var i: Dictionary = c["igdb_critic"]
		var n := int(i.get("count", 0))
		out.append({"id": "igdb", "score": int(i["score"]), "source": "IGDB",
			"line": ("Critic average of %d reviews" % n) if n > 1 else "Critic average", "url": "https://www.igdb.com",
			"color": ThemeLib.color("text_2"), "dark_text": false})
	return out


func _build_critics() -> void:
	for b in critic_buttons:
		Kit.drop(_critics, b)
	critic_buttons.clear()
	for spec in badges(meta):
		var b := Button.new()
		b.name = "Critic_" + spec["id"]
		b.theme_type_variation = "ChipButton"
		b.custom_minimum_size = Vector2(0, 64)
		b.focus_mode = Control.FOCUS_ALL
		var row := Kit.hbox(12)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.set_anchors_preset(Control.PRESET_FULL_RECT)
		row.offset_left = 8
		row.offset_right = -14
		var tile := PanelContainer.new()
		tile.name = "Score"
		tile.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tile.custom_minimum_size = Vector2(48, 48)
		tile.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var col: Color = spec["color"]
		var sb := ThemeLib.box(col if spec["dark_text"] else Color(col, 0.16), ThemeLib.radius("s"), 6, 4)
		if not spec["dark_text"]:
			sb.border_color = Color(col, 0.7)
			sb.set_border_width_all(2)
		tile.add_theme_stylebox_override("panel", sb)
		var num := Kit.label(str(spec["score"]))
		num.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		num.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		num.add_theme_font_override("font", ThemeLib.font("display", true))
		num.add_theme_font_size_override("font_size", 24)
		num.add_theme_color_override("font_color", Color("#111111") if spec["dark_text"] else ThemeLib.color("text"))
		tile.add_child(num)
		row.add_child(tile)
		var txt := Kit.vbox(0)
		txt.mouse_filter = Control.MOUSE_FILTER_IGNORE
		txt.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var src := Kit.micro(str(spec["source"]).to_upper())
		src.name = "Source"
		txt.add_child(src)
		var line := Kit.label(spec["line"], "CaptionLabel")
		line.name = "Line"
		txt.add_child(line)
		row.add_child(txt)
		b.add_child(row)
		b.custom_minimum_size.x = 92 + maxf(ThemeLib.font("medium").get_string_size(spec["line"], HORIZONTAL_ALIGNMENT_LEFT, -1, ThemeLib.SIZE_CAPTION).x, 90.0)
		var url: String = spec["url"]
		b.disabled = url == ""
		var source: String = spec["source"]
		var what: String = "%s on %s" % [str(game.get("title", "This game")), source]
		b.pressed.connect(func(): link_requested.emit(source, what, url))
		_critics.add_child(b)
		critic_buttons.append(b)
	_critics.visible = not critic_buttons.is_empty()


# ------------------------------------------------------------ facts

static func fact_rows(m: Dictionary) -> Array:
	var rows := []
	var g: Array = m.get("genres", [])
	if not g.is_empty():
		rows.append(["Genres", ", ".join(g.slice(0, 4))])
	var d: Array = m.get("developers", [])
	if not d.is_empty():
		rows.append(["Developer" if d.size() == 1 else "Developers", ", ".join(d.slice(0, 3))])
	var p: Array = m.get("publishers", [])
	if not p.is_empty() and p != d:
		rows.append(["Publisher" if p.size() == 1 else "Publishers", ", ".join(p.slice(0, 3))])
	if str(m.get("release_date", "")) != "":
		rows.append(["Released", date_text(m["release_date"])])
	if str(m.get("controller", "")) != "":
		rows.append(["Controller", "Full support" if m["controller"] == "full" else "Partial support"])
	return rows


func _build_facts() -> void:
	for c in _facts.get_children():
		Kit.drop(_facts, c)
	for r in fact_rows(meta):
		var k := Kit.micro(str(r[0]).to_upper())
		k.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_facts.add_child(k)
		var v := Kit.label(r[1], "", true)
		v.name = "Fact_" + str(r[0]).validate_node_name()
		v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_facts.add_child(v)
	_facts.visible = _facts.get_child_count() > 0


# ------------------------------------------------------------ screenshots

func _build_shots() -> void:
	var want: Array = meta.get("screenshots", [])
	if shot_buttons.size() == mini(want.size(), Metadata.SCREENS_MAX) and not shot_buttons.is_empty():
		return
	for b in shot_buttons:
		Kit.drop(_shots, b)
	shot_buttons.clear()
	var resolver: Object = library.get("metadata") if library != null else null
	for i in mini(want.size(), Metadata.SCREENS_MAX):
		var b := Button.new()
		b.name = "Shot%d" % i
		b.theme_type_variation = "ChipButton"
		b.custom_minimum_size = SHOT
		b.focus_mode = Control.FOCUS_ALL
		var tr := TextureRect.new()
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tr.set_anchors_preset(Control.PRESET_FULL_RECT)
		tr.offset_left = 4
		tr.offset_top = 4
		tr.offset_right = -4
		tr.offset_bottom = -4
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		b.add_child(tr)
		b.focus_entered.connect(func(): _shots_scroll.ensure_control_visible(b))
		_shots.add_child(b)
		shot_buttons.append(b)
		if resolver != null and resolver.has_method("image"):
			var url := str(want[i].get("thumb", ""))
			resolver.image(url, func(path: String):
				if path != "" and is_instance_valid(tr):
					tr.texture = Kit.load_art(path, Vector2i(int(SHOT.x) * 2, int(SHOT.y) * 2)))
	Kit.link_horizontal(shot_buttons)
	_shots_scroll.visible = not shot_buttons.is_empty()
