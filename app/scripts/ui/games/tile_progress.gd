extends RefCounted
## Puts install state on a game tile from outside (game_tile.gd stays as is):
## the corner pill says "45%", "Queued", "Paused", "Update"..., and a slim
## progress bar sits along the bottom of the cover while bytes move.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const TG := preload("res://scripts/ui/texts_games.gd")
const Badge := preload("res://scripts/ui/badge.gd")
const ProgressLine := preload("res://scripts/ui/games/progress_line.gd")

const BAR := "InstallBar"


## `state`: an InstallState (or anything with state_of / fraction).
static func apply(tile: Control, state: Object) -> void:
	if tile == null or state == null or not "game" in tile:
		return
	var key := str(tile.game.get("key", ""))
	var st: String = state.state_of(key)
	var f: float = state.fraction(key)
	var spec := corner_for(st, f)
	if not spec.is_empty():
		_set_corner(tile, spec)
	var card: Control = tile.get("card")
	if card == null:
		return
	var bar: Control = card.get_node_or_null(BAR)
	var want := st in TG.BUSY and f >= 0.0
	_lift_badges(tile, want)
	if not want:
		if bar != null:
			Kit.drop(card, bar)
		return
	if bar == null:
		bar = ProgressLine.new(5.0)
		bar.name = BAR
		bar.anchor_top = 1.0
		bar.anchor_right = 1.0
		bar.anchor_bottom = 1.0
		bar.offset_left = 10
		bar.offset_right = -10
		bar.offset_top = -13
		bar.offset_bottom = -8
		bar.track_alpha = 0.85
		card.add_child(bar)
	bar.set_value(f if st in TG.RUNNING else (f if st == "paused" else -1.0))
	bar.set_color(Color(0.62, 0.7, 0.78) if st == "paused" else Color(0, 0, 0, 0))


## The focus strip sits under the SELECTED pill at the top of the card and the
## bar along its bottom edge, so they never meet; kept for callers.
static func _lift_badges(tile: Control, _lifted: bool) -> void:
	var box: Control = tile.get("badges_box")
	if box == null:
		return
	box.offset_top = 32
	box.offset_bottom = 32
	# The title block moves up while the bar shows.
	var info: Control = tile.get("info_box")
	if info != null:
		info.offset_top = -20 if _lifted else -10
		info.offset_bottom = -20 if _lifted else -10


## The corner pill for a state, {} to leave the tile's own pill.
static func corner_for(st: String, f: float) -> Dictionary:
	if st == "":
		return {}
	if st in TG.RUNNING and f >= 0.0 and st != "uninstalling":
		var p := "%d%%" % roundi(f * 100.0)
		return {"kind": "download", "text": p, "short": p, "tone": "info", "icon": "download"}
	if st in TG.BUSY:
		var t: String = TG.STATE_SHORT.get(st, "Busy")
		return {"kind": "download", "text": t, "short": t, "tone": "info" if st != "paused" else "", "icon": "download"}
	if st == "update_required":
		return {"kind": "update", "text": "Update", "short": "Update", "tone": "info", "icon": "update"}
	if st == "failed":
		return {"kind": "failed", "text": "Failed", "short": "Failed", "tone": "bad", "icon": "alert"}
	return {}


static func _set_corner(tile: Control, spec: Dictionary) -> void:
	var card: Control = tile.get("card")
	if card == null:
		return
	var old: Control = tile.get("corner_badge")
	if old != null and is_instance_valid(old):
		if old.get("spec") is Dictionary and old.spec.get("short", "") == spec["short"] and old.spec.get("tone", "") == spec["tone"]:
			return
		Kit.drop(card, old)
	var solid: bool = spec["tone"] in ["info", "bad"]
	var b := Badge.make(spec, "solid" if solid else "tile")
	b.position = Vector2(8, 8)
	card.add_child(b)
	tile.set("corner_badge", b)
