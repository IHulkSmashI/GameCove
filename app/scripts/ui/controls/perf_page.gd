extends "res://scripts/ui/settings/performance_page.gd"
## Settings > Performance. With Controls: every perf.* setting (overlay and
## its items, upscaling, frame generation, frame limit and latency, Proton,
## shaders) in generated cards, the measuring notes from PerfMonitor, then
## Achievements. Without Controls (older builds, tests) it's the plain
## overlay page it extends. Built the first time it's shown.

const TC := preload("res://scripts/ui/texts_controls.gd")
const Model := preload("res://scripts/ui/controls/model.gd")
const GroupCards := preload("res://scripts/ui/controls/group_cards.gd")
const ProtonCard := preload("res://scripts/ui/settings/proton_card.gd")
const Services := preload("res://scripts/ui/settings/services.gd")
const TX := preload("res://scripts/ui/texts_extras.gd")

var model: Object
var cards: Object
var _built := false
var _sig := ""
var proton_card: VBoxContainer


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
	proton_card = null
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
	_proton_card()
	var a := svc("achievements")
	if a != null and "fetch_rarity" in a:
		var ach := add_card("Achievements", "star")
		var t := toggle(ach, "fetch_rarity", TS.RARITY, bool(a.fetch_rarity), by_value(TS.RARITY_HELP), "star")
		t.changed.connect(func(v): set_rarity(a, bool(v)))


## GE-Proton: install the newest, remove old ones. Tests pass "proton_runner"
## and "proton_home"; without them nothing real is read or run under tests.
func _proton_card() -> void:
	var runner: RefCounted = svc("proton_runner") as RefCounted
	if runner == null and Services.under_tests(self):
		return
	var box := add_card(TX.GE_TITLE, "layers", TX.GE_LINE)
	proton_card = ProtonCard.new()
	proton_card.setup(runner, str(services.get("proton_home", "")), host if host is Node else null)
	proton_card.rebuilt.connect(func(): rebuilt.emit())
	proton_card.notice.connect(func(t: String, tone: String): notify(t, tone))
	var c := svc("controls")
	if c != null and c.has_method("detect_all"):
		proton_card.on_changed = c.detect_all
	box.add_child(proton_card)


func focusables() -> Array:
	var out: Array = cards.focusables() if cards != null else []
	if proton_card != null and is_instance_valid(proton_card):
		out.append_array(proton_card.focusables())   # drawn before Achievements
	out.append_array(_focusables)
	return out


func on_shown() -> void:
	if model != null and not _built:
		_built = true
		rebuild()


func focus_part(_part: String) -> Control:
	var f := focusables()
	return f[0] if not f.is_empty() else null
