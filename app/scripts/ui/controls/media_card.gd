extends PanelContainer
## "Now playing" in the quick menu's Audio tab: the music or video app running
## behind the game (Spotify, a browser, VLC...) with Previous, Play/Pause and
## Next, over MPRIS (scripts/system/media.gd) on the Controls worker.
##
## Reads once when built and again after each press: no polling, nothing
## behind a game. Hidden when no media app is running.

signal rebuilt
signal failed(text: String)

const Kit := preload("res://scripts/ui/ui_kit.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Media := preload("res://scripts/system/media.gd")
const TX := preload("res://scripts/ui/texts_extras.gd")
const KeepFocus := preload("res://scripts/ui/keep_focus.gd")
const CardJobs := preload("res://scripts/system/card_jobs.gd")

var registry: Object
## Media.now_playing() from the last read ({} = nothing playing).
var state: Dictionary = {}
var buttons := {}   # "Previous" / "PlayPause" / "Next" -> Button
var _col: VBoxContainer
var _gen := 0


func setup(reg: Object) -> void:
	name = "MediaCard"
	registry = reg
	var c: Color = ThemeLib.tone("info")
	var sb := ThemeLib.box(Color(c, 0.10), ThemeLib.radius("m"), 16, 12)
	sb.border_color = Color(c, 0.32)
	sb.set_border_width_all(1)
	add_theme_stylebox_override("panel", sb)
	_col = Kit.vbox(6)
	add_child(_col)
	visible = false
	refresh()


func supported() -> bool:
	return registry != null and registry.has_method("run_on_worker") and "ctx" in registry \
		and registry.ctx is Dictionary and registry.ctx.get("runner") != null


## Reads what's playing on the worker; the card follows.
func refresh() -> void:
	if not supported():
		_show({})
		return
	_gen += 1
	var gen := _gen
	var runner: RefCounted = registry.ctx["runner"]
	var me := get_instance_id()
	var courier: RefCounted = CardJobs.shared()
	registry.run_on_worker(func():
		var st: Dictionary = Media.now_playing(runner)
		# the worker never touches the card: it's looked up on the main thread
		courier.hand_back(me, "_on_state", [gen, st]))


func _on_state(gen: int, st: Dictionary) -> void:
	if gen == _gen:
		_show(st)


func _show(st: Dictionary) -> void:
	state = st
	var mark := KeepFocus.mark(self, _buttons_in_order())
	for c in _col.get_children():
		_col.remove_child(c)
		c.queue_free()
	buttons.clear()
	visible = not st.is_empty()
	if st.is_empty():
		rebuilt.emit()
		# the player went away under a focused button: what came before the card takes it
		KeepFocus.restore(self, mark, [])
		return
	var head := Kit.micro("%s · %s" % [TX.MEDIA_TITLE.to_upper(), str(st.get("app", "")).to_upper()])
	head.name = "MediaHead"
	head.add_theme_color_override("font_color", ThemeLib.color("text_3"))
	_col.add_child(head)
	var title := Kit.label(str(st.get("title", "")) if str(st.get("title", "")) != "" else TX.MEDIA_UNKNOWN)
	title.name = "MediaTitle"
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title.add_theme_font_override("font", ThemeLib.font("semibold"))
	_col.add_child(title)
	if str(st.get("artist", "")) != "":
		var a := Kit.label(str(st["artist"]), "QuietLabel")
		a.name = "MediaArtist"
		a.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		_col.add_child(a)
	var row := Kit.hbox(10)
	row.name = "MediaButtons"
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	var playing := str(st.get("status", "")) == "Playing"
	for spec in [["Previous", "skip_back", TX.MEDIA_PREV, bool(st.get("can_prev", true))],
			["PlayPause", "pause" if playing else "play", TX.MEDIA_PAUSE if playing else TX.MEDIA_PLAY, true],
			["Next", "skip_next", TX.MEDIA_NEXT, bool(st.get("can_next", true))]]:
		var b := Kit.icon_button(spec[1], spec[2], 52)
		b.name = spec[0]
		b.disabled = not spec[3]
		var action: String = spec[0]
		b.pressed.connect(func(): press(action))
		row.add_child(b)
		buttons[action] = b
	Kit.link_horizontal([buttons["Previous"], buttons["PlayPause"], buttons["Next"]])
	# the side buttons leave up / down the way the middle one does (siblings: same paths)
	var mid: Button = buttons["PlayPause"]
	for side in [buttons["Previous"], buttons["Next"]]:
		var sb: Button = side
		sb.focus_entered.connect(func():
			sb.focus_neighbor_top = mid.focus_neighbor_top
			sb.focus_neighbor_bottom = mid.focus_neighbor_bottom)
	_col.add_child(row)
	var help := Kit.label(TX.MEDIA_HELP, "QuietLabel", true)
	help.name = "MediaHelp"
	help.add_theme_color_override("font_color", ThemeLib.color("text_3"))
	_col.add_child(help)
	rebuilt.emit()
	KeepFocus.restore(self, mark, _buttons_in_order(), buttons["PlayPause"])


func _buttons_in_order() -> Array:
	return ["Previous", "PlayPause", "Next"].filter(func(k): return buttons.has(k)).map(func(k): return buttons[k])


## Sends one action to the player on show, then reads its state again.
func press(action: String) -> void:
	if state.is_empty() or not supported():
		return
	var runner: RefCounted = registry.ctx["runner"]
	var player := str(state.get("player", ""))
	var app := str(state.get("app", ""))
	var me := get_instance_id()
	var courier: RefCounted = CardJobs.shared()
	_gen += 1
	var gen := _gen
	registry.run_on_worker(func():
		var ok := Media.send(runner, player, action)
		var st: Dictionary = Media.now_playing(runner)
		courier.hand_back(me, "_after_press", [gen, ok, app, st]))


func _after_press(gen: int, ok: bool, app: String, st: Dictionary) -> void:
	if not ok:
		failed.emit(TX.MEDIA_FAILED % (app if app != "" else "The player"))
	if gen == _gen:
		_show(st)


## The buttons, left to right: only the middle one joins the menu's up/down
## chain, so up/down moves past the card in one step and left/right picks.
func focusables() -> Array:
	if buttons.is_empty() or not visible:
		return []
	return [buttons["PlayPause"]]
