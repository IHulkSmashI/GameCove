extends "res://scripts/ui/settings/performance_page.gd"
## Settings > Performance. With Controls: every perf.* setting (overlay and
## its items, upscaling, frame generation, frame limit and latency, Proton,
## shaders) in generated cards, the measuring notes from PerfMonitor, then
## Achievements. Without Controls (older builds, tests) it's the plain
## overlay page it extends. Built the first time it's shown.

const TC := preload("res://scripts/ui/texts_controls.gd")
const Model := preload("res://scripts/ui/controls/model.gd")
const GroupCards := preload("res://scripts/ui/controls/group_cards.gd")

var model: Object
var cards: Object
var _built := false
var _sig := ""


func _connect() -> void:
	super._connect()
	var c := svc("controls")
	if c != null:
		model = Model.new()
		model.setup(c, svc("profiles"))
		model.refreshed.connect(func():
			if cards != null and cards.signature() != _sig:
				rebuild())


func build() -> void:
	cards = null
	if model == null:
		super.build()
		return
	if not _built:
		return
	var p := svc("perf")
	if p != null and p.has_method("capabilities"):
		var caps: Dictionary = p.capabilities()
		if bool(caps.get("fps_needs_overlay", false)):
			add_child(SKit.note(TS.FPS_NEEDS_OVERLAY, "warn", "FpsNeedsOverlay"))
	cards = GroupCards.new()
	cards.relinked.connect(func(): rebuilt.emit())
	cards.build(self, model, ["perf"], host as Control if host is Control else null)
	_sig = cards.signature()
	if p != null and p.has_method("capabilities"):
		var srcs: Dictionary = p.capabilities().get("sources", {})
		if not srcs.is_empty() and not cards.cards.is_empty():
			(cards.cards[0].get_child(0) as VBoxContainer).add_child(_measures(srcs))
	var a := svc("achievements")
	if a != null and "fetch_rarity" in a:
		var ach := add_card("Achievements", "star")
		var t := toggle(ach, "fetch_rarity", TS.RARITY, bool(a.fetch_rarity), by_value(TS.RARITY_HELP), "star")
		t.changed.connect(func(v): set_rarity(a, bool(v)))


func focusables() -> Array:
	var out: Array = cards.focusables() if cards != null else []
	out.append_array(_focusables)
	return out


func on_shown() -> void:
	if model != null and not _built:
		_built = true
		rebuild()


func focus_part(_part: String) -> Control:
	var f := focusables()
	return f[0] if not f.is_empty() else null
