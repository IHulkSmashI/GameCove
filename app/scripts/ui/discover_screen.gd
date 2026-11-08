extends Control
## Discover: deals, release calendar and wishlist.
##
## HOOK FOR THE DISCOVER SCREENS. Two ways in, pick one:
##   1. Edit build_content() below (this file is yours to take over), or
##   2. From anywhere before the screen is shown, set
##        DiscoverScreen.content_factory = func(services: Dictionary) -> Control: ...
##      and that Control is used as the screen's content instead of the
##      placeholder. `services` is what main.gd passes to setup():
##      {"library": Library, "open_game": Callable(game), "toast": Callable(text, icon, tone)}
## Build with the design system (docs/DESIGN.md): Shelf for rows of tiles,
## Badge/Badges for "On sale -60%" / "Wishlisted", PageTemplate for a deal
## page, GlassPanel/CardPanel for cards, Kit.prompts for the hint bar.
## The content sits inside the same margins as Home; main.gd provides the top
## bar, backdrop and hint bar. Emit `game_focused(game)` to make the backdrop
## follow focus, `open_requested(game)` to open a game page. If the content
## has default_focus() -> Control, main uses it when the tab opens.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const Icons := preload("res://scripts/ui/icons.gd")
const Illustrations := preload("res://scripts/ui/illustrations.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")

signal game_focused(game: Dictionary)
signal open_requested(game: Dictionary)

static var content_factory: Callable = Callable()

var services: Dictionary = {}
var content: Control
var _margin: MarginContainer


func _init() -> void:
	name = "Discover"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_margin = Kit.margin(0)
	_margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	_margin.add_theme_constant_override("margin_left", 48)
	_margin.add_theme_constant_override("margin_right", 48)
	_margin.add_theme_constant_override("margin_top", 92)
	_margin.add_theme_constant_override("margin_bottom", 58)
	add_child(_margin)


func setup(svc: Dictionary) -> void:
	services = svc
	if content != null:
		content.queue_free()
	content = content_factory.call(svc) if content_factory.is_valid() else build_content()
	_margin.add_child(content)


## The placeholder: one card saying what's coming. Replace me.
func build_content() -> Control:
	var center := CenterContainer.new()
	center.name = "Placeholder"
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var card := PanelContainer.new()
	card.theme_type_variation = "GlassPanel"
	card.custom_minimum_size = Vector2(760, 0)
	center.add_child(card)
	var row := Kit.hbox(32)
	card.add_child(row)
	row.add_child(Illustrations.rect("discover", 200))
	var col := Kit.vbox(14)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(Kit.label("Deals, release calendar and wishlist", "TitleLabel", true))
	col.add_child(Kit.label("Price drops on games you want, what comes out this month, and your wishlist from every store in one place. It's being built now.", "QuietLabel", true))
	var chips := Kit.hbox(8)
	for spec in [["tag", "Deals", "sale"], ["calendar", "Release calendar", "info"], ["star", "Wishlist", "wish"]]:
		chips.add_child(load("res://scripts/ui/badge.gd").make({"kind": spec[1], "text": spec[1], "short": spec[1], "tone": spec[2], "icon": spec[0]}, "chip"))
	col.add_child(chips)
	row.add_child(col)
	return center


func default_focus() -> Control:
	if content != null and content.has_method("default_focus"):
		return content.default_focus()
	return null
