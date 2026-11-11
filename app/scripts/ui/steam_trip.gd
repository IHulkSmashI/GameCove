extends Control
## What the person sees and feels of the trip to Steam's controller settings
## (steam/steam_handoff.gd does the windows): a calm cover on the way out, no
## input reaching GameCove while Steam's screen is up, and on the way back the
## very place they left: the same page, the same focused control, the quick menu
## on the same tab when the trip started there over a running game.
##
##   out    the cover fades in over everything (no flash of what's behind while
##          Steam's window comes up) and says "Opening Steam's controller settings…";
##          the pad is dead for GameCove from this moment (blocks()).
##   away   Steam's window is in front. The controller goes to Steam: our window
##          lost focus, and SessionWiring is told as well (set_away), so
##          InputPlumber's intercept is on Pass whatever order the events came in.
##   back   focus goes back where it was, the cover fades away like a return from
##          a game, and for GUARD_MS more (and until every button is up) nothing
##          is taken from the pad: the B that closed Steam's screen is still down
##          or just released, and must not also mean Back here.
## A slow or missing Steam ends in a toast, never a hang (the service's timeout).

const Kit := preload("res://scripts/ui/ui_kit.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Motion := preload("res://scripts/ui/motion.gd")
const TC := preload("res://scripts/ui/texts_controls.gd")
const SteamInput := preload("res://scripts/ui/controls/steam_input.gd")
const Handoff := preload("res://scripts/steam/steam_handoff.gd")

## After the return: how long the pad is ignored (and longer while a button is still held).
const GUARD_MS := 350
const OUT_S := 0.14
const BACK_S := 0.3

var service: Node
## main.gd (quick_menu, wiring, toast(), _open_menu(), _screen_default_focus()).
var main: Control
var label: Label
var _dim: ColorRect
var _guard_until := 0
var _held := {}
## Where the trip started: {"focus": WeakRef, "menu": bool, "game": Dictionary, "section": int, "name": String}.
var _from := {}


func _init() -> void:
	name = "SteamTrip"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	modulate.a = 0.0
	_dim = ColorRect.new()
	Kit.fill(_dim)
	_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_dim)
	var center := CenterContainer.new()
	Kit.fill(center)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	label = Kit.label(TC.GYRO_STEAM_OPENING, "LeadLabel")
	label.name = "Line"
	center.add_child(label)
	_restyle()
	service = Handoff.new()
	service.name = "SteamHandoff"
	add_child(service)
	service.left.connect(_on_left)
	service.finished.connect(_on_finished)


func _restyle() -> void:
	_dim.color = Color(ThemeLib.color("scrim"), 0.92)
	label.add_theme_color_override("font_color", ThemeLib.color("text"))


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and _dim != null:
		_restyle()


func setup(main_node: Control, gamescope: Object) -> void:
	main = main_node
	service.gamescope = gamescope
	SteamInput.handoff = open


func _exit_tree() -> void:
	if SteamInput.handoff.is_valid() and SteamInput.handoff.get_object() == self:
		SteamInput.handoff = Callable()


## Nothing of GameCove's may take the pad or the keys: a trip is under way, or it
## just ended and a button may still be down.
func blocks() -> bool:
	return service.active() or Time.get_ticks_msec() < _guard_until or not _held.is_empty()


## main._input hands every pad and key event here while blocks(): true = swallow it.
## B (while Steam's screen hasn't shown yet) and Guide end the trip; the guard
## after the return is held until every button that was down is up again.
func take(event: InputEvent) -> bool:
	if event is InputEventJoypadButton or event is InputEventKey:
		var id := "k%d" % event.keycode if event is InputEventKey else "j%d" % event.button_index
		if event.is_pressed():
			_held[id] = true
		else:
			_held.erase(id)
	if not service.active():
		return true
	if event.is_pressed() and not event.is_echo():
		var guide: bool = (event is InputEventJoypadButton and event.button_index == JOY_BUTTON_GUIDE) \
			or (event is InputEventKey and event.keycode == KEY_F1)
		if guide:
			service.back("guide")
		elif event.is_action("ui_cancel") and service.state == "opening":
			service.back("cancelled")
	return true


## The button: every "Steam controller settings" goes through here. True when
## it's on its way (or was simply handed to Steam outside gamescope).
func open(game: Dictionary) -> bool:
	var vp := get_viewport() if is_inside_tree() else null
	var f: Control = vp.gui_get_focus_owner() if vp != null else null
	var qm: Control = main.quick_menu if main != null else null
	var from := {"focus": weakref(f) if f != null else null, "menu": qm != null and qm.visible,
		"game": qm.game if qm != null and qm.visible and "game" in qm else {},
		"section": int(qm.section) if qm != null and qm.visible else 0, "name": str(f.name) if f != null else ""}
	match service.start(game):
		"":
			_from = from
			_held.clear()
			label.text = TC.GYRO_STEAM_OPENING
			# over a running game the quick menu is all of ours that shows, and it says
			# "Opening…" itself: no cover over the game
			if not (bool(from["menu"]) and main != null and main.session != null and main.session.is_active()):
				visible = true
				Motion.to(self, "modulate:a", 1.0, OUT_S)
			return true
		"direct", "busy":
			return true
		"no_steam":
			if main != null:
				main.toast(TC.GYRO_STEAM_NOT_RUNNING, "gamepad", "warn", TC.GYRO_STEAM_NOT_RUNNING_LINE)
			return true   # said so already: the button needn't say it again
	return false


func _on_left() -> void:
	# Steam's screen is up: the quick menu (our overlay) steps aside for it
	if bool(_from.get("menu", false)) and main != null and main.quick_menu != null and main.quick_menu.visible:
		main.quick_menu.close()
	if main != null and main.wiring != null and main.wiring.has_method("set_away"):
		main.wiring.set_away(true)


func _on_finished(why: String) -> void:
	_guard_until = Time.get_ticks_msec() + GUARD_MS
	if main != null and main.wiring != null and main.wiring.has_method("set_away"):
		main.wiring.set_away(false)
	_restore()
	var t := Motion.to(self, "modulate:a", 0.0, BACK_S)
	if t == null:
		visible = false
	else:
		t.finished.connect(_hide_if_done)
	if main == null:
		return
	match why:
		"timeout":
			main.toast(TC.GYRO_STEAM_SLOW, "gamepad", "warn", TC.GYRO_STEAM_SLOW_LINE)
		"failed":
			main.toast(TC.GYRO_STEAM_FAILED, "gamepad", "warn", "")


func _hide_if_done() -> void:
	if not service.active() and modulate.a < 0.01:
		visible = false


## Back to exactly where the trip started.
func _restore() -> void:
	var from := _from
	_from = {}
	if main == null or from.is_empty():
		return
	var qm: Control = main.quick_menu
	if bool(from.get("menu", false)) and qm != null:
		# it started in the quick menu (which closed itself to let Steam's screen show): the same tab, the same button
		if not qm.visible:
			main._open_menu()
		if qm.section != int(from["section"]):
			qm.show_section(int(from["section"]))
		var again: Node = qm.body.find_child(str(from["name"]), true, false) if str(from["name"]) != "" else null
		if again is Control and (again as Control).is_visible_in_tree():
			(again as Control).grab_focus.call_deferred()
		return
	var ref: Variant = from.get("focus")
	var f: Variant = ref.get_ref() if ref is WeakRef else null
	if f is Control and is_instance_valid(f) and (f as Control).is_visible_in_tree():
		(f as Control).grab_focus()
	else:
		var d: Control = main._screen_default_focus()
		if d != null:
			d.grab_focus()
