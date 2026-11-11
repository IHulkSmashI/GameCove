extends Control
## The installer (GameCove started with `-- --installer`, see scripts/installer/boot.gd):
## a guided wizard on the desktop, like the first-run setup sheet: a step rail
## on the left, the page on the right, Back / Skip / Next under it. Mouse,
## touch, keyboard and controller all work (plain Buttons and design-system
## rows, linked for focus; B goes back).
##
## Logic lives in scripts/installer/ (plan.gd = steps and choices,
## installer_service.gd = running the tasks, commands.gd = every command).
## Built only from design-system pieces (ui_kit, settings kit cards / notes /
## chips, action_row, choice_row, slider_row, osk, toast, icons, illustrations,
## Device.picture_for), so a restyle carries over.
##
## Tests: InstallerScreen.create(services, target, plan, installer) outside the
## tree; nothing real runs (the installer service gets a fake runner).

const TFix := preload("res://scripts/ui/texts_fixes.gd")
const Kit := preload("res://scripts/ui/ui_kit.gd")
const SKit := preload("res://scripts/ui/settings/kit.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Themes := preload("res://theme/themes.gd")
const Icons := preload("res://scripts/ui/icons.gd")
const Illus := preload("res://scripts/ui/illustrations.gd")
const Motion := preload("res://scripts/ui/motion.gd")
const Osk := preload("res://scripts/ui/osk.gd")
const Toasts := preload("res://scripts/ui/toast.gd")
const ChoiceRow := preload("res://scripts/ui/choice_row.gd")
const SliderRow := preload("res://scripts/ui/slider_row.gd")
const ActionRow := preload("res://scripts/ui/settings/action_row.gd")
const UiPrefs := preload("res://scripts/ui/ui_prefs.gd")
const Texts := preload("res://scripts/ui/texts.gd")
const TS := preload("res://scripts/ui/texts_settings.gd")
const TI := preload("res://scripts/ui/installer/texts_installer.gd")
const SignIn := preload("res://scripts/ui/installer/store_signin.gd")
const ArtKeyStep := preload("res://scripts/ui/setup/art_key_step.gd")
const PhotoView := preload("res://scripts/ui/device/device_photo_view.gd")
const OptionCard := preload("res://scripts/ui/installer/option_card.gd")
const Plan := preload("res://scripts/installer/plan.gd")
const Target := preload("res://scripts/installer/target.gd")
const Paths := preload("res://scripts/installer/paths.gd")
const Service := preload("res://scripts/installer/installer_service.gd")
const UserData := preload("res://scripts/installer/user_data.gd")
const SettingsWriter := preload("res://scripts/installer/settings_writer.gd")
const Login := preload("res://scripts/system/store_login.gd")

signal closed

## {"setup", "library", "discover", "launcher", "device", "power_cfg", "ui_prefs", "photo"}
var services := {}
var target := {}
var plan: RefCounted
var installer: Node
## Quit the app when the installer closes (false in tests and previews).
var quit_on_close := true
## func(cmd: Array) for "Open Steam" (OS.create_process by default; tests record).
var launch: Callable = func(cmd: Array): OS.create_process(cmd[0], PackedStringArray(cmd.slice(1)))
## func(url) for "Open the page here" in the Game art step (the desktop browser; tests record).
var open_page: Callable = func(u: String): OS.shell_open(u)

var rail: HBoxContainer
var status_pill: PanelContainer
var step_chip: PanelContainer
var foot_label: Label
var prompts_box: HBoxContainer
var eyebrow: Label
var page_title: Label
var page_lead: Label
var nav_note: HBoxContainer
var body: VBoxContainer
var scroll: ScrollContainer
var nav: HBoxContainer
var back_button: Button
var skip_button: Button
var next_button: Button
var keyboard: PanelContainer
var toasts: VBoxContainer
var sign_in: Control
var art_step: Control
var task_rows: Array = []
var progress_bar: ProgressBar
var progress_title: Label
var progress_pct: Label
var progress_ring: Control
var _focusables: Array = []
var _ask_done: Callable
var _ask_return: Control
var _run_state := ""   # "" | running | ok | failed | undone
var _run_message := ""
var _started_action := ""
var _rebuild_queued := false
var _configured := false


## The install progress ring: a track and an accent arc, the percent inside.
## Redraws only when the value changes.
class ProgressRing extends Control:
	var value := 0.0
	func _init() -> void:
		custom_minimum_size = Vector2(76, 76)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
	func set_value(v: float) -> void:
		value = clampf(v, 0.0, 1.0)
		queue_redraw()
	func _draw() -> void:
		var Lib = load("res://theme/gamecove_theme.gd")
		var c := size / 2.0
		var r := minf(size.x, size.y) / 2.0 - 5.0
		draw_arc(c, r, 0.0, TAU, 64, Lib.color("surface_3"), 6.0, true)
		if value > 0.0:
			var a0 := -PI / 2.0
			var steps := 48
			# Accent into accent_2 along the arc, like the primary gradient.
			for i in steps:
				var t0 := float(i) / steps
				if t0 >= value:
					break
				var t1 := minf(float(i + 1) / steps, value)
				var col: Color = Lib.color("accent").lerp(Lib.color("accent_2"), t0)
				draw_arc(c, r, a0 + TAU * t0, a0 + TAU * t1, 4, col, 6.0, true)


static func create(svc: Dictionary, t: Dictionary, p: RefCounted, inst: Node) -> Control:
	var s: Control = load("res://scripts/ui/installer/installer_screen.gd").new()
	s.quit_on_close = false
	s.configure(svc, t, p, inst)
	return s


func configure(svc: Dictionary, t: Dictionary, p: RefCounted, inst: Node) -> void:
	_configured = true
	name = "Installer"
	services = svc
	target = t
	plan = p
	installer = inst
	set_anchors_preset(Control.PRESET_FULL_RECT)
	if installer != null:
		if installer.get_parent() == null:
			add_child(installer)
		installer.task_started.connect(_on_task_started)
		installer.task_line.connect(_on_task_line)
		installer.task_finished.connect(_on_task_finished)
		installer.finished.connect(_on_finished)
		installer.undone.connect(_on_undone)
	var st: Object = services.get("setup")
	if st != null and st.has_signal("changed"):
		st.changed.connect(func(_s): _refresh_stores_later())
	_build()
	prefetch_photo()


## The installer is online anyway: fetch this handheld's real photo into the
## cache now (DevicePhoto.prefetch), so it shows the first time Game Mode opens
## GameCove, even offline. Nothing when the photo settings are off.
func prefetch_photo() -> bool:
	var ph: Object = services.get("photo")
	var id := str(_device_row().get("id", ""))
	if ph == null or not ph.has_method("prefetch") or id == "" or id == "unknown":
		return false
	return bool(ph.prefetch(id))


## Big windows get more room, not just bigger pixels: the same density rule
## as the app (1920x1200 lays out at 1536x960), so the installer's type
## matches the main screens.
func _enter_tree() -> void:
	var w := get_window()
	if w == null or not is_instance_valid(w):
		return
	if not w.size_changed.is_connected(_fit_density):
		w.size_changed.connect(_fit_density)
	_fit_density()


func _fit_density() -> void:
	var w := get_window()
	if w == null or w.content_scale_mode == Window.CONTENT_SCALE_MODE_DISABLED:
		return
	w.content_scale_size = load("res://scripts/main.gd").base_size_for(w.size)


## The real thing: autoloads, this system, a real command runner.
func _ready() -> void:
	if _configured:
		return
	UiPrefs.load_prefs()
	ThemeLib.use(UiPrefs.theme)
	theme = ThemeLib.build()
	get_tree().set_auto_accept_quit(false)
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_title(TI.TITLE)
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED)
	var paths := Paths.new()
	var t := Target.detect(paths)
	var dev := get_node_or_null("/root/Device")
	var row: Dictionary = dev.profile if dev != null else {}
	var p := Plan.start(t, row, UiPrefs.values())
	var inst: Node = Service.new()
	inst.name = "InstallerService"
	inst.setup(inst.runner, paths, t)
	configure({"setup": _svc("Setup"), "library": _svc("Library"), "discover": _svc("Discover"),
		"launcher": _svc("Launcher"), "device": dev, "power_cfg": "user://power.cfg", "ui_prefs": true,
		"photo": _svc("DevicePhoto")}, t, p, inst)
	focus_first()


func _svc(n: String) -> Node:
	return get_node_or_null("/root/" + n)


# ------------------------------------------------------------------ layout

func _build() -> void:
	for c in get_children():
		if c != installer:
			Kit.drop(self, c)
	var bg := ColorRect.new()
	bg.name = "Background"
	bg.color = ThemeLib.color("bg")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	var glow := TextureRect.new()
	glow.name = "Glow"
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	glow.set_anchors_preset(Control.PRESET_FULL_RECT)
	glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	var g := GradientTexture2D.new()
	g.fill = GradientTexture2D.FILL_RADIAL
	g.fill_from = Vector2(0.85, 0.15)
	g.fill_to = Vector2(0.2, 1.0)
	var grad := Gradient.new()
	grad.set_color(0, Color(ThemeLib.color("accent"), 0.07))
	grad.set_color(1, Color(ThemeLib.color("accent_2"), 0.0))
	g.gradient = grad
	glow.texture = g
	add_child(glow)

	var frame := Kit.vbox(0)
	frame.name = "Frame"
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(frame)

	# Top bar: lockup, step pills, status pill.
	var top := Kit.margin(0, 28, 14)
	top.name = "TopBar"
	var top_row := Kit.hbox(18)
	top.add_child(top_row)
	var lock := Kit.hbox(12)
	lock.name = "Lockup"
	var mark := PanelContainer.new()
	mark.name = "Mark"
	# The app icon tile: dark glass with the cyan-to-violet gradient edge.
	mark.add_theme_stylebox_override("panel", ThemeLib.gradient_box(ThemeLib.color("accent"), ThemeLib.color("accent_2"), ThemeLib.radius("m"), Color(0, 0, 0, 0), 2, 2))
	var inner := PanelContainer.new()
	inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_theme_stylebox_override("panel", ThemeLib.box(ThemeLib.color("bg"), ThemeLib.radius("m") - 2, 8, 8))
	mark.add_child(inner)
	var logo := TextureRect.new()
	logo.texture = load("res://assets/logo-mark.svg") if ResourceLoader.exists("res://assets/logo-mark.svg") else Icons.tex("handheld", 24, ThemeLib.color("accent"))
	logo.custom_minimum_size = Vector2(24, 24)
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	inner.add_child(logo)
	lock.add_child(mark)
	var words := Kit.vbox(0)
	words.alignment = BoxContainer.ALIGNMENT_CENTER
	var brand := Kit.hbox(0)
	var w1 := Kit.label("GAME", "LeadLabel")
	w1.add_theme_font_override("font", ThemeLib.font("display"))
	var w2 := Kit.label("COVE", "LeadLabel")
	w2.add_theme_font_override("font", ThemeLib.font("display"))
	w2.add_theme_color_override("font_color", ThemeLib.color("accent"))
	brand.add_child(w1)
	brand.add_child(w2)
	words.add_child(brand)
	var sub := Kit.micro(TI.LOCKUP_LINE)
	sub.name = "LockupLine"
	sub.add_theme_font_size_override("font_size", 11)
	words.add_child(sub)
	lock.add_child(words)
	top_row.add_child(lock)
	top_row.add_child(Kit.spacer())
	rail = Kit.hbox(6)
	rail.name = "Steps"
	rail.alignment = BoxContainer.ALIGNMENT_CENTER
	top_row.add_child(rail)
	top_row.add_child(Kit.spacer())
	status_pill = _pill(_status_text(), "", false)
	status_pill.name = "Status"
	top_row.add_child(status_pill)
	frame.add_child(top)
	frame.add_child(_hairline())

	# Page: eyebrow + title + content (scrolls), then a note and Back / Continue.
	var page := Kit.margin(0, 64, 0)
	page.name = "Page"
	page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var page_col := Kit.vbox(14)
	page.add_child(page_col)
	var title_box := Kit.vbox(4)
	title_box.name = "TitleBox"
	var tpad := Control.new()
	tpad.custom_minimum_size = Vector2(0, 22)
	title_box.add_child(tpad)
	# Mono eyebrow in the accent, then the big caps title (the app's page
	# heading style), then a plain lead line.
	eyebrow = Kit.micro("", "EyebrowLabel")
	eyebrow.name = "Eyebrow"
	title_box.add_child(eyebrow)
	page_title = Kit.label("", "DisplayLabel", true)
	page_title.name = "Heading"
	page_title.add_theme_font_override("font", ThemeLib.font("display"))
	page_title.add_theme_font_size_override("font_size", ThemeLib.SIZE_HEADLINE + 8)
	title_box.add_child(page_title)
	page_lead = Kit.label("", "QuietLabel", true)
	page_lead.name = "Lead"
	title_box.add_child(page_lead)
	page_col.add_child(title_box)
	scroll = ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.follow_focus = true
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page_col.add_child(scroll)
	var pad := Kit.margin(6, 6, 10)
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(pad)
	body = Kit.vbox(16)
	body.name = "Body"
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pad.add_child(body)
	page_col.add_child(_hairline())
	nav = Kit.hbox(14)
	nav.name = "Nav"
	nav_note = Kit.hbox(0)
	nav_note.name = "NavNote"
	nav_note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nav.add_child(nav_note)
	skip_button = Kit.button(TI.SKIP)
	skip_button.name = "Skip"
	skip_button.custom_minimum_size = Vector2(112, 50)
	skip_button.pressed.connect(skip_step)
	nav.add_child(skip_button)
	back_button = Kit.button(TI.BACK)
	back_button.name = "Back"
	back_button.custom_minimum_size = Vector2(112, 50)
	back_button.pressed.connect(go_back)
	nav.add_child(back_button)
	# The gradient primary pill with the A glyph, like Play on the game page.
	next_button = Kit.primary(TI.NEXT, "A")
	next_button.name = "Next"
	# Its (A) shows only while it has focus: A presses whatever has focus.
	load("res://scripts/ui/button_fx.gd").attach(next_button, {"glyph_on_focus": true})
	next_button.focus_entered.connect(func(): _update_hints.call_deferred())
	next_button.focus_exited.connect(func(): _update_hints.call_deferred())
	next_button.custom_minimum_size = Vector2(200, 50)
	next_button.pressed.connect(next_step)
	nav.add_child(next_button)
	var nav_pad := Kit.margin(0, 0, 14)
	nav_pad.add_child(nav)
	page_col.add_child(nav_pad)
	frame.add_child(page)

	# Footer: where you are, and the buttons that work.
	frame.add_child(_hairline())
	var foot := Kit.margin(0, 28, 10)
	foot.name = "Footer"
	var foot_row := Kit.hbox(14)
	foot.add_child(foot_row)
	step_chip = _pill("", "", true)
	step_chip.name = "StepChip"
	foot_row.add_child(step_chip)
	foot_label = Kit.micro("")
	foot_label.name = "Where"
	foot_row.add_child(foot_label)
	foot_row.add_child(Kit.spacer())
	prompts_box = Kit.hbox(0)
	prompts_box.name = "PromptsBox"
	foot_row.add_child(prompts_box)
	frame.add_child(foot)

	keyboard = Osk.new()
	keyboard.anchor_left = 0.5
	keyboard.anchor_right = 0.5
	keyboard.anchor_top = 1.0
	keyboard.anchor_bottom = 1.0
	keyboard.offset_left = -400
	keyboard.offset_right = 400
	keyboard.offset_top = -380
	keyboard.offset_bottom = -20
	keyboard.closed.connect(_on_keyboard_closed)
	add_child(keyboard)
	toasts = Toasts.new()
	add_child(toasts)
	show_step()


## Like Kit.drop, but outside the tree (tests) the page's old controls are
## kept until the screen goes: a button may be the one emitting right now.
var _graveyard: Array = []


func _drop(parent: Node, c: Node) -> void:
	if parent.is_inside_tree():
		Kit.drop(parent, c)
		return
	if c.get_parent() == parent:
		parent.remove_child(c)
	_graveyard.append(c)


func _hairline() -> ColorRect:
	var l := ColorRect.new()
	l.custom_minimum_size = Vector2(0, 1)
	l.color = ThemeLib.color("line")
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## Steps shown by name in the top bar; more than this and only the current
## one is named (the rest are dots), so 11 Custom steps fit at 1280 px.
const RAIL_NAMED := 8


## A rounded pill: optional dot, mono caps text. `accent`: tinted with the accent.
func _pill(text: String, dot_tone: String, accent: bool) -> PanelContainer:
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := ThemeLib.box(Color(ThemeLib.color("accent"), 0.10) if accent else Color(ThemeLib.color("surface"), 0.85), 999, 12, 5)
	sb.border_color = Color(ThemeLib.color("accent"), 0.5) if accent else ThemeLib.color("line")
	sb.set_border_width_all(1)
	p.add_theme_stylebox_override("panel", sb)
	var row := Kit.hbox(8)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if dot_tone != "":
		var d := Panel.new()
		d.name = "Dot"
		d.custom_minimum_size = Vector2(7, 7)
		d.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		d.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var col: Color = ThemeLib.color("text_3") if dot_tone == "muted" else (ThemeLib.color("accent") if dot_tone == "accent" else ThemeLib.tone(dot_tone))
		d.add_theme_stylebox_override("panel", ThemeLib.box(col, 4, 0, 0))
		row.add_child(d)
	# Mono, tracked: the step pills, the status pill and STEP n / N.
	var l := Kit.label(text, "CaptionLabel")
	l.name = "Text"
	l.add_theme_font_override("font", ThemeLib.mono(accent, 1))
	l.add_theme_font_size_override("font_size", ThemeLib.SIZE_MICRO)
	l.add_theme_color_override("font_color", ThemeLib.color("accent") if accent else ThemeLib.color("text_2"))
	row.add_child(l)
	p.add_child(row)
	return p


func _status_text() -> String:
	var parts: Array = []
	var d := _device()
	if d != null and d.has_method("battery"):
		var b: Variant = d.battery()
		if b is Dictionary and int(b.get("percent", -1)) >= 0:
			parts.append("%d%%" % int(b["percent"]))
	var t := Time.get_time_dict_from_system()
	parts.append("%02d:%02d" % [t["hour"], t["minute"]])
	return "  ·  ".join(PackedStringArray(parts))


## Builds the page for plan.step.
func show_step() -> void:
	if sign_in != null and is_instance_valid(sign_in):
		sign_in.stop()
	sign_in = null
	if art_step != null and is_instance_valid(art_step):
		art_step.stop()
	art_step = null
	task_rows.clear()
	for c in body.get_children():
		_drop(body, c)
	_focusables.clear()
	_nav_note("")
	page_title.get_parent().visible = true
	match plan.step:
		"welcome": _build_welcome()
		"startup": _build_startup()
		"steam": _build_steam()
		"stores": _build_stores()
		"device": _build_device()
		"look": _build_look()
		"art": _build_art()
		"extras": _build_extras()
		"summary": _build_summary()
		"progress": _build_progress()
		"done": _build_done()
		"maintenance": _build_maintenance()
		"uninstall": _build_uninstall()
		"finish": _build_finish()
	_build_rail()
	_update_nav()
	_link()
	body.modulate.a = 0.0
	Motion.to(body, "modulate:a", 1.0, Motion.BASE)


func _build_rail() -> void:
	for c in rail.get_children():
		Kit.drop(rail, c)
	var steps: Array = plan.steps()
	var at: int = steps.find(plan.step)
	# Past RAIL_NAMED steps (Custom and Change have 11) the names don't fit a
	# 1280 px top bar: only the current step keeps its name, the others are
	# status dots (green done, grey to come); "STEP n / N" is in the footer.
	var compact := steps.size() > RAIL_NAMED
	for i in steps.size():
		var k: String = steps[i]
		var on: bool = k == plan.step
		var passed: bool = i < at or (plan.step == "done" and k == "done")
		var tone := "accent" if on else ("good" if passed and not plan.skipped.has(k) else "muted")
		var p := _pill(TI.STEP_NAMES.get(k, k), tone, on)
		p.name = "Step_" + k
		if compact and not on:
			var dsb: StyleBoxFlat = p.get_theme_stylebox("panel").duplicate()
			dsb.content_margin_left = 8
			dsb.content_margin_right = 8
			p.add_theme_stylebox_override("panel", dsb)
			(p.find_child("Text", true, false) as Label).visible = false
			p.tooltip_text = str(TI.STEP_NAMES.get(k, k))
		if passed and not on:
			var sb: StyleBoxFlat = p.get_theme_stylebox("panel").duplicate()
			sb.border_color = Color(ThemeLib.tone("good"), 0.45)
			p.add_theme_stylebox_override("panel", sb)
			(p.find_child("Text", true, false) as Label).add_theme_color_override("font_color", ThemeLib.tone("good"))
		rail.add_child(p)
	(step_chip.find_child("Text", true, false) as Label).text = "STEP %d / %d" % [at + 1, steps.size()]
	foot_label.text = "INSTALLER  –  " + str(TI.STEP_NAMES.get(plan.step, plan.step)).to_upper()
	(status_pill.find_child("Text", true, false) as Label).text = _status_text()
	# Ten steps fill a 1280 px top bar: the status pill makes room.
	status_pill.visible = steps.size() <= 6


func _update_nav() -> void:
	var s: String = plan.step
	back_button.visible = not s in ["welcome", "maintenance", "finish", "progress", "done"] or plan.return_to != ""
	skip_button.visible = plan.can_skip() and plan.return_to == ""
	skip_button.text = ArtKeyStep.SKIP_TEXT if s == "art" else (TI.SKIP_STORES if s == "stores" else TI.SKIP)
	next_button.visible = not s in ["maintenance", "progress"]
	next_button.disabled = false
	next_button.text = TI.NEXT
	match s:
		"summary":
			next_button.text = TI.APPLY if plan.mode == "change" else TI.INSTALL
			next_button.disabled = _blocked()
		"uninstall": next_button.text = TI.REMOVE
		"finish": next_button.text = TI.FINISH_FIXES
		"done": next_button.text = TI.RESTART if _wants_restart() else TI.CLOSE
	nav.visible = true
	back_button.visible = back_button.visible and not (s == "progress")
	_update_hints()


## The hint bar says what A does now: Continue (or Install...) while that
## has focus, else Select for whatever does.
func _update_hints() -> void:
	if prompts_box == null or not is_instance_valid(next_button):
		return
	var s: String = plan.step
	for c in prompts_box.get_children():
		Kit.drop(prompts_box, c)
	var hints: Array = []
	var f: Control = get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	if next_button.visible and not next_button.disabled and (f == null or f == next_button):
		hints.append(["A", next_button.text])
	elif f != null or s in ["welcome", "maintenance"]:
		hints.append(["A", TI.SELECT])
	if back_button.visible:
		hints.append(["B", TI.BACK])
	if s != "progress" and s != "done":
		hints.append([["LB", "RB"], TI.SWITCH_STEP])
	prompts_box.add_child(Kit.prompts(hints))


## Install can't go ahead: a supported system without its downloaded package.
func _blocked() -> bool:
	return plan.mode in ["easy", "custom"] and bool(target.get("supported", false)) and str(target.get("package", "")) == ""


func _heading(title: String, line: String, kicker := "") -> void:
	eyebrow.text = (kicker if kicker != "" else TI.EYEBROWS.get(plan.step, "")).to_upper()
	page_title.text = title.to_upper()
	page_lead.text = line
	page_lead.visible = line != ""


## A short line next to Back / Continue (the reassurance note, a tip).
func _nav_note(text: String, tone := "") -> void:
	for c in nav_note.get_children():
		Kit.drop(nav_note, c)
	if text == "":
		return
	if tone != "":
		var n := SKit.note(text, tone, "NavNoteText")
		n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		n.custom_minimum_size = Vector2(380, 0)
		nav_note.add_child(n)
	else:
		var l := Kit.label(text, "MonoLabel", true)
		l.name = "NavNoteText"
		l.add_theme_font_override("font", ThemeLib.mono(false, 1))
		l.add_theme_font_size_override("font_size", ThemeLib.SIZE_MICRO + 1)
		l.add_theme_color_override("font_color", ThemeLib.color("text_2"))
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		nav_note.add_child(l)


## The size the page lays out at (the window's content scale size), or the
## base 1280x800 outside the tree.
func _layout_size() -> Vector2:
	return get_viewport_rect().size if is_inside_tree() else Vector2(1280, 800)


func _device() -> Object:
	return services.get("device")


func _device_row() -> Dictionary:
	var d := _device()
	if d != null and "profile" in d and d.profile is Dictionary:
		return d.profile
	return {}


func _device_name() -> String:
	var d := _device()
	return str(d.display_name()) if d != null and d.has_method("display_name") else "handheld"


func _support() -> String:
	var d := _device()
	return str(d.support_level()) if d != null and d.has_method("support_level") else "generic"


## The device's picture: its real photo when the DevicePhoto service has one
## cached (the free photo or the maker's image, with its credit line, as in
## About this device and first-run setup), else Device.picture_for's drawing
## (generic art for unknown ids). A photo prefetch_photo() brings in while the
## page is up rebuilds it once.
func _device_picture(height: float) -> Control:
	var ph: Object = services.get("photo")
	var id0 := str(_device_row().get("id", ""))
	if ph != null and ph.has_method("photo_for") and id0 != "" and id0 != "unknown":
		if ph.has_signal("photo_ready") and not ph.photo_ready.is_connected(_on_photo_ready):
			ph.photo_ready.connect(_on_photo_ready)
		# the credit line goes under the picture: the pair takes the drawing's height
		var view: Control = PhotoView.make(ph.photo_for(id0), maxf(height - PHOTO_CREDIT_H, 60.0), func(_url: String): pass)
		if view != null:
			view.credit.focus_mode = Control.FOCUS_NONE
			view.custom_minimum_size.x = height * 2.0
			return view
	var path := ""
	var d := _device()
	var id := str(_device_row().get("id", ""))
	if d != null and d.has_method("picture_for"):
		path = str(d.picture_for(id))
	elif d != null and d.has_method("picture"):
		path = str(d.picture())
	if path == "":
		path = load("res://scripts/device/device.gd").picture_for(id)
	var tex: Texture2D = null
	if ResourceLoader.exists(path):
		tex = load(path)
	elif FileAccess.file_exists(path):
		tex = Icons.from_svg(FileAccess.get_file_as_string(path))
	if tex == null:
		return Illus.rect("library", int(height))
	var r := TextureRect.new()
	r.name = "DevicePicture"
	r.texture = tex
	r.custom_minimum_size = Vector2(height * 1.1, height)
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


## Room the photo's credit line takes under it (see _device_picture).
const PHOTO_CREDIT_H := 34.0


func _on_photo_ready(_device_id: String, _path: String) -> void:
	if is_inside_tree() and body != null and body.find_child("DevicePhoto", true, false) == null:
		_build.call_deferred()


func _row(key: String, title: String, value: String, hint: String, icon := "", chevron := true) -> VBoxContainer:
	var r: VBoxContainer = ActionRow.new()
	r.setup(key, title, value, hint, icon, chevron)
	body.add_child(r)
	_focusables.append(r.button)
	return r


func _choice(key: String, title: String, vals: Array, labels: Array, current: Variant, explain: Callable, icon := "", parent: Control = null) -> VBoxContainer:
	var r: VBoxContainer = ChoiceRow.new()
	r.setup(key, title, vals, labels, current, icon)
	r.set_explainer(explain)
	(parent if parent != null else body).add_child(r)
	_focusables.append(r.button)
	return r


func _bool(key: String, title: String, current: bool, lines: Dictionary, icon := "", parent: Control = null) -> VBoxContainer:
	return _choice(key, title, [false, true], ["Off", "On"], current, func(v): return lines.get(v, ""), icon, parent)


# ------------------------------------------------------------------ pages

func _build_welcome() -> void:
	_heading(TI.WELCOME_TITLE, TI.WELCOME_LINE % _device_name())
	var cols := Kit.hbox(28)
	cols.name = "Cols"
	# Left: the detected handheld and what will happen.
	var dev := PanelContainer.new()
	dev.name = "DeviceCard"
	dev.theme_type_variation = "CardPanel"
	dev.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dev.size_flags_stretch_ratio = 0.9
	var dcol := Kit.vbox(10)
	dev.add_child(dcol)
	var k := Kit.micro(TI.DETECTED, "EyebrowLabel")
	k.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	dcol.add_child(k)
	# Smaller picture on short screens so the plan and the cards fit unscrolled.
	var pic := _device_picture(170.0 if _layout_size().y >= 900.0 else 96.0)
	pic.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	dcol.add_child(pic)
	var dn := Kit.label(_device_name().to_upper(), "LeadLabel", true)
	dn.name = "DeviceName"
	dn.add_theme_font_override("font", ThemeLib.font("display"))
	dn.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	dcol.add_child(dn)
	var level := _support()
	var os_name := str(target.get("os", {}).get("name", "Linux"))
	var facts := Kit.label("%s  ·  %s" % [TI.SUPPORT.get(level, TI.SUPPORT["generic"]), os_name], "MonoLabel", true)
	facts.name = "Facts"
	facts.add_theme_font_override("font", ThemeLib.mono(false, 1))
	facts.add_theme_font_size_override("font_size", ThemeLib.SIZE_MICRO + 1)
	facts.add_theme_color_override("font_color", ThemeLib.tone("good") if level in ["full", "partial"] else ThemeLib.tone("warn"))
	facts.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	dcol.add_child(facts)
	var plan_box := PanelContainer.new()
	plan_box.name = "Plan"
	var psb := ThemeLib.box(Color(ThemeLib.color("bg"), 0.5), ThemeLib.radius("m"), 18, 14)
	psb.border_color = ThemeLib.color("line")
	psb.set_border_width_all(1)
	plan_box.add_theme_stylebox_override("panel", psb)
	var pcol := Kit.vbox(8)
	var ph := Kit.micro(TI.WHAT_WILL_HAPPEN + ":")
	ph.add_theme_font_override("font", ThemeLib.mono(true, 2))
	pcol.add_child(ph)
	var n := 1
	for p in TI.PLAN:
		var r := Kit.hbox(10)
		var num := Kit.label("%d." % n, "CaptionLabel")
		num.add_theme_color_override("font_color", ThemeLib.color("accent"))
		num.add_theme_font_override("font", ThemeLib.mono(true, 0))
		num.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		r.add_child(num)
		var l := Kit.label(p[2], "CaptionLabel", true)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		r.add_child(l)
		pcol.add_child(r)
		n += 1
	plan_box.add_child(pcol)
	dcol.add_child(plan_box)
	cols.add_child(dev)
	# Right: Easy / Custom.
	var right := Kit.vbox(16)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.alignment = BoxContainer.ALIGNMENT_CENTER
	if not bool(target.get("supported", false)):
		right.add_child(SKit.note(TI.OS_HOW["none"] % os_name, "warn", "System"))
	if _blocked():
		right.add_child(SKit.note(TI.NO_PACKAGE, "bad", "NoPackage"))
	var cards := Kit.hbox(18)
	cards.name = "Modes"
	var easy := _card("mode_easy", TI.MODE_EASY_CARD, TI.MODE_EASY_LINE % [_device_name(), os_name], "", [TI.RECOMMENDED, "good"],
		"~1 MIN", TI.MODE_EASY_FOOT, TI.SELECTED_DEFAULT, cards)
	easy.set_selected(plan.mode != "custom")
	easy.pressed.connect(func(): pick_mode("easy"))
	var custom := _card("mode_custom", TI.MODE_CUSTOM, TI.MODE_CUSTOM_LINE, "", [TI.STEP_BY_STEP, "info"], "~3 MIN",
		TI.MODE_CUSTOM_FOOT, TI.SELECTED, cards)
	custom.set_selected(plan.mode == "custom")
	custom.pressed.connect(func(): pick_mode("custom"))
	right.add_child(cards)
	cols.add_child(right)
	body.add_child(cols)


func _card(key: String, title: String, line: String, icon: String, badge: Array, corner: String, foot: String,
		selected_text: String, parent: Control) -> Button:
	var c: Button = OptionCard.new()
	c.setup(key, title, line, icon, badge, corner, foot, selected_text)
	parent.add_child(c)
	_focusables.append(c)
	return c


## Easy or Custom, then on to the next page.
func pick_mode(m: String) -> void:
	plan.set_mode(m)
	go(plan.next())


func _build_startup() -> void:
	_heading(TI.STARTUP_TITLE, TI.STARTUP_LINE)
	var allowed: Array = ["gamecove", "steam", "desktop"] if bool(target.get("supported", false)) else ["desktop"]
	var cards := Kit.hbox(18)
	cards.name = "Startup"
	for k in ["gamecove", "steam", "desktop"]:
		var c := _card("startup_" + k, TI.STARTUP[k][0], TI.STARTUP[k][1], {"gamecove": "rocket", "steam": "gamepad", "desktop": "screen"}[k],
			[TI.RECOMMENDED, "good"] if k == "gamecove" else [], "", TI.STARTUP_FOOT[k], TI.STARTUP_FOOT[k], cards)
		c.custom_minimum_size = Vector2(0, 290)
		c.set_selected(plan.choices["startup"] == k)
		if k in allowed:
			c.pressed.connect(func(): choose("startup", k))
		else:
			c.disabled = true
	body.add_child(cards)
	_nav_note(TI.STARTUP_BACK, "info")


## Sets a choice and redraws the page, keeping focus on the same control.
func choose(key: String, value: Variant) -> void:
	if not plan.set_choice(key, value):
		return
	_redraw_keep_focus()


func _redraw_keep_focus() -> void:
	var f := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	var keep := (String(f.name) if f is OptionCard else String(f.get_parent().name)) if f != null and is_ancestor_of(f) else ""
	show_step()
	var again := body.find_child(keep, true, false) as Control if keep != "" else null
	if again != null and is_inside_tree():
		var b: Control = again.get("button") if again.get("button") is Control else again
		if b.focus_mode != Control.FOCUS_NONE:
			b.grab_focus()
	else:
		focus_first()


func _build_steam() -> void:
	_heading(TI.STEAM_TITLE, TI.STEAM_LINE)
	var steam: Dictionary = target.get("steam", {})
	_nav_note(TI.STEAM_TIP)
	var c := SKit.card(TI.STEAM_CARD, "gamepad")
	c[0].name = "SteamState"
	var head: HBoxContainer = c[1].get_node("Heading")
	head.add_child(Kit.spacer())
	if bool(steam.get("signed_in", false)):
		var acct := str(steam.get("account", ""))
		head.add_child(SKit.chip(TI.STEAM_SIGNED_IN % acct if acct != "" else TI.STEAM_SIGNED_IN_PLAIN, "good", "check"))
		body.add_child(c[0])
	else:
		var missing := not bool(steam.get("installed", false))
		head.add_child(SKit.chip(TI.STEAM_MISSING if missing else TI.STEAM_NOT_SIGNED, "warn", "alert"))
		c[1].add_child(Kit.label(TI.STEAM_MISSING_LINE if missing else TI.STEAM_NOT_SIGNED_LINE, "QuietLabel", true))
		var acts := Kit.hbox(12)
		if not missing:
			var open := SKit.action(TI.STEAM_OPEN, "rocket", "OpenSteam")
			open.theme_type_variation = "AccentButton"
			open.pressed.connect(open_steam)
			acts.add_child(open)
			_focusables.append(open)
		var again := SKit.action(TI.STEAM_CHECK, "update", "CheckSteam")
		again.pressed.connect(refresh_steam)
		acts.add_child(again)
		_focusables.append(again)
		c[1].add_child(acts)
		body.add_child(c[0])
	var mode := _choice("steam_mode", TI.STEAM_MODE, Plan.STEAM_MODES, Plan.STEAM_MODES.map(func(m): return TI.STEAM_MODES[m]),
		plan.choices["steam_mode"], func(v): return TI.STEAM_MODE_LINES.get(v, ""), "gamepad")
	mode.collapse_hint = false
	mode.set_explainer(func(v): return TI.STEAM_MODE_LINES.get(v, ""))
	mode.changed.connect(func(v): plan.set_choice("steam_mode", v))
	var ctl := _bool("steam_control", TS.STEAM_CONTROL, bool(plan.choices["steam_control"]), TS.STEAM_CONTROL_HELP, "shield_alert")
	ctl.changed.connect(func(v): plan.set_choice("steam_control", v))
	body.add_child(SKit.note(TS.STEAM_CONTROL_WARNING, "warn", "SteamWarning"))


func open_steam() -> void:
	launch.call(["steam", "steam://open/main"])


## Reads loginusers.vdf again (after signing in to Steam).
func refresh_steam() -> void:
	var p: RefCounted = installer.paths if installer != null else Paths.new()
	var st: Dictionary = Login.status(p.home, OS.get_environment("PATH")).get("steam", {})
	target["steam"] = {"installed": str(st.get("tool", "")) != "" or str(st.get("config", "")) != "" or bool(target.get("steam", {}).get("installed", false)),
		"signed_in": bool(st.get("signed_in", false)), "account": str(st.get("account", ""))}
	if plan.step == "steam":
		_redraw_keep_focus()


func _store_status() -> Dictionary:
	var st: Object = services.get("setup")
	return st.store_status() if st != null and st.has_method("store_status") else {}


func _build_stores() -> void:
	_heading(TI.STORES_TITLE, TI.STORES_LINE)
	var status := _store_status()
	var heroic := false
	for store in ["epic", "gog", "amazon"]:
		var info: Dictionary = status.get(store, {})
		if "heroic" in str(info.get("config", "")).to_lower() or str(info.get("how", "")) == "heroic":
			heroic = true
	if heroic:
		body.add_child(SKit.note(TI.STORES_HEROIC, "good", "Heroic"))
	# One card per store: its state as a badge, what A does in the footer.
	var cards := Kit.hbox(18)
	cards.name = "StoreCards"
	for store in ["epic", "gog", "amazon"]:
		var info: Dictionary = status.get(store, {})
		var signed: bool = info.get("signed_in", false)
		var can := TS.can_sign_in(info)
		var acct := str(info.get("account", ""))
		var line: String = TI.STORE_ROW_LINE["signed"] % (" as " + acct if acct != "" else "") if signed \
			else TI.STORE_ROW_LINE.get(str(info.get("how", "")), "")
		var badge: Array = [TS.SIGNED_IN, "good"] if signed else ([TI.BROWSER_SIGNIN, "info"] if can else [TS.NOT_SIGNED_IN, ""])
		var foot: String = TI.STORE_READY if signed else (TI.SIGN_IN_BROWSER if can else TI.STORE_NOT_HERE)
		var c := _card("store_" + store, TS.STORE_NAMES[store], line, "brand:" + store, badge, "", foot, foot, cards)
		c.set_selected(signed)
		if can:
			c.pressed.connect(func(): open_sign_in(store))
		else:
			c.disabled = true
	body.add_child(cards)
	_nav_note(TI.STORES_LATER)


func open_sign_in(store: String) -> void:
	for c in body.get_children():
		_drop(body, c)
	_focusables.clear()
	sign_in = SignIn.new()
	sign_in.setup(services.get("setup"), store, ask_text)
	sign_in.finished.connect(func(s, ok, _m):
		if ok:
			toasts.show_toast(TI.SIGNIN_OK % TS.STORE_NAMES.get(s, s), "check", "good")
			go("stores"))
	body.add_child(sign_in)
	var back := Kit.button(TI.SIGNIN_BACK)
	back.name = "AllStores"
	back.custom_minimum_size = Vector2(200, 52)
	back.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	back.pressed.connect(func(): go("stores"))
	body.add_child(back)
	for b in sign_in.buttons:
		_focusables.append(b)
	_focusables.append(back)
	_link_signin()
	sign_in.start()
	if is_inside_tree():
		sign_in.first_focus().grab_focus()


func _link_signin() -> void:
	var row: Array = sign_in.buttons
	Kit.link_horizontal(row)
	var back: Control = _focusables[-1]
	for b in row:
		b.focus_neighbor_bottom = b.get_path_to(back)
		b.focus_neighbor_top = b.get_path_to(b)
	back.focus_neighbor_top = back.get_path_to(row[0])
	back.focus_neighbor_bottom = back.get_path_to(next_button)
	for b in [back_button, skip_button, next_button]:
		b.focus_neighbor_top = b.get_path_to(back)


func _refresh_stores_later() -> void:
	if plan.step == "stores" and sign_in == null and not _rebuild_queued:
		if is_inside_tree():
			_redraw_keep_focus.call_deferred()
		else:
			show_step()


## The badges every fix carries (docs/FIXES.md): Recommended here (only those are preselected and
## listed in setup; Optional ones are on the Fixes page), and Tested on hardware when we ran it on this model.
func _fix_badges(fix: String) -> HBoxContainer:
	var row := Kit.hbox(8)
	row.name = "Badges_" + fix.validate_node_name()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var lv := Kit.badge(TFix.LEVEL["recommended"], "info")
	lv.name = "Level"
	row.add_child(lv)
	var id := str(_device_row().get("id", ""))
	for t in Texts.fix_tested(fix):
		if str(t.get("device", "")) == id:
			var tb := Kit.badge(TFix.TESTED_BADGE, "good")
			tb.name = "Tested"
			row.add_child(tb)
			break
	return row


func _build_device() -> void:
	_heading(TI.DEVICE_TITLE % _device_name(), TI.DEVICE_LINE)
	var fixes: Array = plan.suggested_fixes.filter(func(f): return not f in Texts.HIDDEN_FIXES)
	var cols := Kit.hbox(18)
	cols.name = "DeviceCols"
	body.add_child(cols)
	# Left: the fixes this handheld needs. Right: power defaults.
	var left := _panel_card(cols, TI.FIXES_HEADER, TI.FIXES_MATCHED % _device_name() if not fixes.is_empty() else "", 1.0)
	if fixes.is_empty():
		left.add_child(SKit.note(TI.DEVICE_GENERIC if _support() == "generic" else TI.DEVICE_NO_FIXES, "info", "NoFixes"))
	for f in fixes:
		var r := _bool("fix_" + f, Texts.fix_title(f), f in plan.choices["fixes"], {}, "sparkle", left)
		r.collapse_hint = false
		r.set_explainer(func(_v): return Texts.fix_explain(f))
		r.changed.connect(func(v): plan.toggle_fix(f, v))
		left.add_child(_fix_badges(f))
	var right := _panel_card(cols, TI.POWER_HEADER, "", 1.0)
	right.get_parent().get_parent().name = "PowerCard"
	var row := _device_row()
	var has_tdp: bool = row.get("tdp", null) is Dictionary or row.is_empty()
	if has_tdp:
		var p := _choice("power_profile", TI.PROFILE, Plan.PROFILES, Plan.PROFILES.map(func(x): return TI.PROFILES[x]),
			plan.choices["power_profile"], func(v): return TI.PROFILE_LINES.get(v, ""), "gauge", right)
		p.changed.connect(func(v): plan.set_choice("power_profile", v))
		var a := _bool("auto_tdp", TI.AUTO_TDP, bool(plan.choices["auto_tdp"]), TI.AUTO_TDP_LINES, "bolt", right)
		a.changed.connect(func(v): plan.set_choice("auto_tdp", v))
	if bool(row.get("charge_limit", false)):
		var s: VBoxContainer = SliderRow.new()
		s.setup("charge_limit", TI.CHARGE, 50, 100, float(plan.choices["charge_limit"]), 5, "%")
		right.add_child(s)
		var hint := Kit.label(TI.CHARGE_LINE, "QuietLabel", true)
		hint.add_theme_font_size_override("font_size", ThemeLib.SIZE_CAPTION)
		right.add_child(hint)
		s.changed.connect(func(v): plan.set_choice("charge_limit", int(v)))
		_focusables.append(s.slider)
	if not has_tdp and not bool(row.get("charge_limit", false)):
		right.add_child(SKit.note(TI.NO_POWER, "info", "NoPower"))
	if plan.xess_offered:
		_xess_card()
	if not fixes.is_empty():
		body.add_child(SKit.note(TI.DEVICE_RESTART, "info", "Restart"))
	_nav_note(TI.DEVICE_REVERSIBLE)


## Intel Arc with XMX only: the XeSS XMX driver (off by default; the upscaler
## and XeLL in the quick menu use it). A toggles it.
func _xess_card() -> void:
	var row := Kit.hbox(18)
	row.name = "XessRow"
	body.add_child(row)
	var on := bool(plan.choices.get("xess_driver", false))
	var c := _card("xess_driver", TI.XESS_TITLE, TI.XESS_LINE, "sparkle", [TI.XESS_BADGE, "info"], TI.XESS_TIME,
		TI.XESS_FOOT, TI.XESS_ON, row)
	c.set_selected(on)
	c.pressed.connect(func():
		var now := not bool(plan.choices.get("xess_driver", false))
		plan.set_choice("xess_driver", now)
		c.set_selected(now))


## A titled card in a row of cards (caps heading, optional chip on the
## right). Returns the box to put rows in.
func _panel_card(parent: Control, title: String, chip: String, ratio: float) -> VBoxContainer:
	var p := PanelContainer.new()
	p.name = "Card_" + title.validate_node_name().replace(" ", "")
	p.theme_type_variation = "CardPanel"
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.size_flags_stretch_ratio = ratio
	parent.add_child(p)
	var col := Kit.vbox(12)
	p.add_child(col)
	var head := Kit.hbox(10)
	var t := Kit.label(title.to_upper(), "HeaderLabel")
	t.add_theme_font_size_override("font_size", ThemeLib.SIZE_LEAD)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(t)
	if chip != "":
		head.add_child(Kit.chip(chip, "check", "accent"))
	col.add_child(head)
	var rows := Kit.vbox(10)
	rows.name = "Rows"
	col.add_child(rows)
	return rows


func _build_look() -> void:
	_heading(TI.LOOK_TITLE, TI.LOOK_LINE)
	# One card per theme with a swatch of its colours; the chosen one is ticked.
	var cards := Kit.hbox(16)
	cards.name = "Themes"
	for id in Themes.ORDER:
		var c := _card("theme_" + id, Themes.NAMES.get(id, id), str(Texts.THEME_LINES.get(id, "")), "", [], "", "", TI.SELECTED, cards)
		c.min_height = 230.0
		var t: Dictionary = Themes.get_theme(id)
		var sw := Panel.new()
		sw.name = "Swatch"
		sw.custom_minimum_size = Vector2(0, 64)
		sw.mouse_filter = Control.MOUSE_FILTER_IGNORE
		sw.add_theme_stylebox_override("panel", _swatch_box(t))
		var content: Control = c.get_node("Content")
		content.add_child(sw)
		content.move_child(sw, 0)
		c.set_selected(plan.choices["theme"] == id)
		c.pressed.connect(func(): pick_theme(id))
	body.add_child(cards)
	var toggles := Kit.hbox(16)
	toggles.name = "LookToggles"
	body.add_child(toggles)
	var m := _bool("match_art", TI.MATCH_ART, bool(plan.choices["match_art"]), TI.MATCH_ART_LINES, "sparkle", toggles)
	m.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	m.changed.connect(func(v): plan.set_choice("match_art", v))
	var r := _bool("reduce_motion", TI.REDUCE_MOTION, bool(plan.choices["reduce_motion"]), TI.REDUCE_MOTION_LINES, "motion", toggles)
	r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.changed.connect(func(v):
		plan.set_choice("reduce_motion", v)
		Motion.reduce = v)


## A theme's swatch: its surface with the accent-to-accent_2 gradient.
func _swatch_box(t: Dictionary) -> StyleBox:
	var a: Color = t["accent"]
	var b: Color = t["accent_2"]
	var sb := ThemeLib.gradient_box(Color(a, 0.85), Color(b, 0.85), ThemeLib.radius("m"), t["line_2"], 0, 0)
	if int(t.get("dark", 1)) == 0:
		sb = ThemeLib.gradient_box(Color(t["surface"]), Color(a, 0.35), ThemeLib.radius("m"), t["line_2"], 0, 0)
	elif str(t.get("bg", "")) == str(Color("#000000")):
		sb = ThemeLib.gradient_box(Color("#000000"), Color(a, 0.30), ThemeLib.radius("m"), t["line_2"], 0, 0)
	return sb


## Theme changes show at once (the choice is saved when the install runs).
func pick_theme(id: String) -> void:
	if not plan.set_choice("theme", id):
		return
	ThemeLib.use(id)
	if is_inside_tree():
		theme = ThemeLib.build()   # NOTIFICATION_THEME_CHANGED rebuilds the page


func _build_extras() -> void:
	_heading(TI.EXTRAS_TITLE, TI.EXTRAS_LINE)
	for k in ["ggdeals_key", "steam_id"]:
		var title: String = {"ggdeals_key": TI.GGDEALS, "steam_id": TI.STEAM_PROFILE}[k]
		var line: String = {"ggdeals_key": TI.GGDEALS_LINE, "steam_id": TI.STEAM_PROFILE_LINE}[k]
		var v := str(plan.choices[k])
		var shown := (TS.masked(v) if k != "steam_id" else v) if v != "" else TI.NOT_SET
		var r := _row(k, title, shown, line, "shield" if k != "steam_id" else "gamepad")
		r.collapse_hint = false
		r.set_hint(line)
		r.set_value(shown, "muted" if v == "" else "good")
		r.pressed.connect(func(): ask_text(title, v, func(t: String): save_extra(k, t)))
	var vals: Array = [""] + TS.COUNTRIES
	var labels: Array = [TI.REGION_AUTO] + TS.COUNTRIES
	var c := _choice("country", TI.REGION, vals, labels, plan.choices["country"], func(_v): return TI.REGION_LINE, "discover")
	c.changed.connect(func(v): plan.set_choice("country", v))
	var ml := _bool("moonlight", TI.MOONLIGHT, bool(plan.choices.get("moonlight", false)), TI.MOONLIGHT_LINES, "screen")
	ml.changed.connect(func(v): plan.set_choice("moonlight", v))


## Game art: the user's own SteamGridDB key, the same guided step as first-run
## setup (art_key_step.gd). Checked live, kept in the plan, written at install
## by settings_writer.gd; the art fill runs when GameCove starts.
func _build_art() -> void:
	_heading(ArtKeyStep.TITLE, ArtKeyStep.LINE)
	art_step = ArtKeyStep.new()
	art_step.configure({"setup": services.get("setup"), "discover": services.get("discover"), "http": services.get("http"),
		"ask_text": ask_text, "open_url": open_page, "read_clipboard": services.get("read_clipboard", Callable()),
		"lan": services.get("lan", Callable()), "prefs_path": services.get("prefs_path", "user://settings.cfg"),
		"current": str(plan.choices.get("steamgriddb_key", "")),
		"save_fn": func(k: String): plan.set_choice("steamgriddb_key", k)})
	art_step.saved.connect(func(_k):
		plan.skipped.erase("art")
		toasts.show_toast(TI.ART_SET, "check", "good")
		if is_inside_tree():
			next_button.grab_focus())
	body.add_child(art_step)
	art_step.start()
	for b in art_step.buttons:
		_focusables.append(b)


## A typed key or profile; false (and a note) when it doesn't look right.
func save_extra(key: String, text: String) -> bool:
	var t := text.strip_edges()
	var ok := true
	if t != "":
		match key:
			"steamgriddb_key": ok = t.length() == 32 and t.is_valid_hex_number()
			"ggdeals_key": ok = RegEx.create_from_string("^[A-Za-z0-9_\\-]{10,128}$").search(t) != null
	if not ok:
		toasts.show_toast(TI.KEY_BAD % (TI.SGDB if key == "steamgriddb_key" else TI.GGDEALS), "alert", "bad")
		return false
	plan.set_choice(key, t)
	_redraw_keep_focus()
	return true


func _build_summary() -> void:
	_heading(TI.SUMMARY_CHANGE_TITLE if plan.mode == "change" else TI.SUMMARY_TITLE, TI.SUMMARY_LINE)
	for item in plan.summary():
		var s: String = item["step"]
		var value := _summary_value(item)
		var r := _row("sum_" + s, TI.STEP_NAMES[s], value[0], value[1], TI.STEP_ICONS.get(s, "dots"))
		r.collapse_hint = false
		r.set_hint(value[1])
		r.pressed.connect(func(): edit(s))
	if _blocked():
		body.add_child(SKit.note(TI.NO_PACKAGE, "bad", "NoPackage"))
		return
	var privileged := false
	for t in load("res://scripts/installer/commands.gd").tasks_for(plan.action(), plan.choices, target, installer.paths if installer else Paths.new()):
		privileged = privileged or bool(t["privileged"])
	body.add_child(SKit.note(TI.SUMMARY_PASSWORD if privileged else TI.SUMMARY_PASSWORD_NONE, "info", "Password"))
	if str(target.get("method", "")) == "rpm-ostree" and not bool(target.get("installed", false)):
		body.add_child(SKit.note(TI.SUMMARY_REBOOT, "info", "Reboot"))


## [value, line] for a summary row.
func _summary_value(item: Dictionary) -> Array:
	var c: Dictionary = plan.choices
	match str(item["step"]):
		"startup":
			return [TI.STARTUP[c["startup"]][0], TI.STARTUP[c["startup"]][1]]
		"steam":
			var line: String = TI.STEAM_MODE_LINES[c["steam_mode"]]
			if c["steam_control"]:
				line += " " + TI.SUMMARY_STEAM_CONTROL + "."
			return [TI.STEAM_MODES[c["steam_mode"]], line]
		"stores":
			var names: Array = []
			var st := _store_status()
			for s in TS.STORE_ORDER:
				if bool(st.get(s, {}).get("signed_in", false)):
					names.append(TS.STORE_NAMES[s])
			if plan.skipped.has("stores") and names.is_empty():
				return [TI.SUMMARY_STORES["skipped"], TI.STORES_LINE]
			return [", ".join(PackedStringArray(names)) if not names.is_empty() else TI.SUMMARY_STORES["none"], TI.STORES_LINE]
		"device":
			var f: Array = c["fixes"]
			var power := "%s, %s" % [TI.PROFILES[c["power_profile"]], TI.AUTO_TDP + (" on" if c["auto_tdp"] else " off")]
			if bool(c.get("xess_driver", false)):
				power += ". " + TI.XESS_SUMMARY
			if f.is_empty():
				return [TI.SUMMARY_NO_FIXES, power]
			return ["%d fix%s" % [f.size(), "" if f.size() == 1 else "es"], ", ".join(PackedStringArray(f.map(func(x): return Texts.fix_title(x)))) + ". " + power]
		"look":
			return [Themes.NAMES.get(c["theme"], c["theme"]), Texts.THEME_LINES.get(c["theme"], "")]
		"art":
			return [TI.ART_SET if str(c["steamgriddb_key"]) != "" else TI.ART_NONE, TI.SGDB_LINE]
		"extras":
			var set_: Array = []
			if c["ggdeals_key"] != "": set_.append(TI.GGDEALS)
			if c["steam_id"] != "": set_.append(TI.STEAM_PROFILE)
			if c["country"] != "": set_.append(c["country"])
			return [", ".join(PackedStringArray(set_)) if not set_.is_empty() else TI.SUMMARY_EXTRAS_NONE, TI.EXTRAS_LINE]
	return ["", ""]


func edit(step_id: String) -> void:
	if plan.edit(step_id):
		show_step()
		focus_first()


func _build_progress() -> void:
	var act: String = plan.action()
	if _run_state == "failed":
		_heading(TI.PROGRESS_STOPPED.get(act, TI.PROGRESS_STOPPED["install"]), "")
	else:
		_heading(TI.PROGRESS_TITLE.get(act, TI.PROGRESS_TITLE["install"]) + "…", "")
	_nav_note(TI.PROGRESS_LINE)
	if installer == null:
		return
	if _started_action != act:
		_started_action = act
		_start_run(act)
	var card := PanelContainer.new()
	card.name = "ProgressCard"
	card.theme_type_variation = "CardPanel"
	var col := Kit.vbox(16)
	card.add_child(col)
	# Ring with the percent, the current task in caps, then the gradient bar.
	var head := Kit.hbox(20)
	progress_ring = ProgressRing.new()
	progress_ring.name = "Ring"
	head.add_child(progress_ring)
	progress_pct = Kit.label("", "NumberLabel")
	progress_pct.name = "Percent"
	progress_pct.add_theme_font_override("font", ThemeLib.mono(true, 0))
	progress_pct.add_theme_font_size_override("font_size", ThemeLib.SIZE_SMALL)
	progress_pct.add_theme_color_override("font_color", ThemeLib.color("accent"))
	progress_pct.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	progress_pct.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	progress_pct.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	progress_ring.add_child(progress_pct)
	var hcol := Kit.vbox(4)
	hcol.alignment = BoxContainer.ALIGNMENT_CENTER
	hcol.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hcol.add_child(Kit.micro(TI.PROGRESS_NOW, "EyebrowLabel"))
	progress_title = Kit.label("", "HeaderLabel", true)
	progress_title.name = "Current"
	progress_title.add_theme_font_override("font", ThemeLib.font("display"))
	progress_title.add_theme_font_size_override("font_size", ThemeLib.SIZE_LEAD)
	hcol.add_child(progress_title)
	head.add_child(hcol)
	col.add_child(head)
	progress_bar = ProgressBar.new()
	progress_bar.name = "Bar"
	progress_bar.show_percentage = false
	progress_bar.custom_minimum_size = Vector2(0, 12)
	progress_bar.add_theme_stylebox_override("background", ThemeLib.box(ThemeLib.color("surface_3"), 999, 0, 0))
	progress_bar.add_theme_stylebox_override("fill", ThemeLib.gradient_box(ThemeLib.color("accent"), ThemeLib.color("accent_2"), 6, Color(0, 0, 0, 0), 0, 0))
	col.add_child(progress_bar)
	var grid := GridContainer.new()
	grid.name = "Tasks"
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 12)
	for i in installer.tasks.size():
		var row := PanelContainer.new()
		row.name = "Task_%d" % i
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var h := Kit.hbox(10)
		h.name = "Row"
		var col2 := Kit.vbox(0)
		col2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var l := Kit.label("", "CaptionLabel", true)
		l.name = "Title"
		l.add_theme_font_override("font", ThemeLib.mono(false, 0))
		l.add_theme_font_size_override("font_size", ThemeLib.SIZE_MICRO + 1)
		col2.add_child(l)
		var sub := Kit.label("", "CaptionLabel", true)
		sub.name = "Line"
		sub.add_theme_font_size_override("font_size", ThemeLib.SIZE_MICRO)
		sub.add_theme_color_override("font_color", ThemeLib.color("text_3"))
		sub.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		col2.add_child(sub)
		h.add_child(col2)
		var st := Kit.label("", "CaptionLabel")
		st.name = "State"
		st.add_theme_font_override("font", ThemeLib.mono(true, 1))
		st.add_theme_font_size_override("font_size", ThemeLib.SIZE_MICRO)
		st.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(st)
		row.add_child(h)
		grid.add_child(row)
		task_rows.append(row)
	col.add_child(grid)
	# Failed: what went wrong and what to do sit above the task list, so
	# they're on screen at 1280x800 without scrolling.
	if _run_state == "failed":
		body.add_child(SKit.note(TI.error_line(_run_message), "bad", "Error"))
		var acts := Kit.hbox(12)
		acts.name = "FailActions"
		var retry := SKit.action(TI.RETRY, "update", "Retry")
		retry.theme_type_variation = "AccentButton"
		retry.pressed.connect(func():
			if installer.retry():
				_run_state = "running"
				show_step())
		var undo := SKit.action(TI.UNDO, "x", "Undo")
		undo.pressed.connect(func():
			if installer.undo():
				_run_state = "running"
				show_step())
		var logb := SKit.action(TI.SHOW_LOG, "info", "Log")
		logb.pressed.connect(func(): OS.shell_open(installer.paths.log_file()))
		for b in [retry, undo, logb]:
			acts.add_child(b)
			_focusables.append(b)
		body.add_child(acts)
		_nav_note(TI.LOG_AT % _short_path(installer.paths.log_file()))
	body.add_child(card)
	for i in task_rows.size():
		_refresh_task(i)
	if _run_state == "undone":
		body.add_child(SKit.note(_run_message, "info", "Undone"))


## A path with the home folder as "~" (shorter, and the same on every handheld).
func _short_path(p: String) -> String:
	var h := str(installer.paths.get("home")) if installer != null and installer.paths != null else ""
	return "~" + p.substr(h.length()) if h != "" and h != "<null>" and p.begins_with(h + "/") else p


func _start_run(act: String) -> void:
	if act in ["install", "change", "repair"]:
		for l in SettingsWriter.apply(plan.choices, services):
			installer.log_line("settings: " + str(l))
	_run_state = "running"
	_run_message = ""
	if not installer.start(act, plan.choices):
		_run_state = "failed"
		_run_message = "busy"


func _on_task_started(i: int, _t: Dictionary) -> void:
	_refresh_task(i)


func _on_task_line(i: int, line: String) -> void:
	if i < task_rows.size() and is_instance_valid(task_rows[i]):
		var l: Label = task_rows[i].find_child("Line", true, false)
		if l != null:
			l.text = line


func _on_task_finished(i: int, _ok: bool, _msg: String) -> void:
	_refresh_task(i)


const TASK_TONES := {"ok": "good", "failed": "bad", "pending": "warn", "running": "accent", "skipped": "warn", "undone": "info"}
const TASK_MARKS := {"ok": "✓", "failed": "✕", "pending": "◷", "running": "›", "skipped": "–", "undone": "↺", "": "…"}


func _refresh_task(i: int) -> void:
	if plan.step != "progress" or i >= task_rows.size() or not is_instance_valid(task_rows[i]):
		return
	var row: PanelContainer = task_rows[i]
	var res: String = installer.results[i] if i < installer.results.size() else ""
	var tone: String = TASK_TONES.get(res, "")
	var col: Color = ThemeLib.color("accent") if tone == "accent" else (ThemeLib.tone(tone) if tone != "" else ThemeLib.color("text_3"))
	var sb := ThemeLib.box(Color(ThemeLib.color("bg"), 0.45), ThemeLib.radius("m"), 16, 12)
	sb.border_color = col if res == "running" else ThemeLib.color("line")
	sb.set_border_width_all(2 if res == "running" else 1)
	row.add_theme_stylebox_override("panel", sb)
	var t: Label = row.find_child("Title", true, false)
	t.text = "%s  %s" % [TASK_MARKS.get(res, "…"), TI.task_title(installer.tasks[i])]
	t.add_theme_color_override("font_color", col if res in ["ok", "running"] else ThemeLib.color("text_2"))
	var st: Label = row.find_child("State", true, false)
	st.text = str(TI.STATE_TAGS.get(res, res)).to_upper()
	st.add_theme_color_override("font_color", col)
	var l: Label = row.find_child("Line", true, false)
	if res == "" or res == "running":
		if l.text == "":
			l.text = TI.TASK_WHY.get(str(installer.tasks[i]["id"]), "")
	elif res != "failed":
		l.text = ""
	if progress_bar != null and is_instance_valid(progress_bar):
		var done := 0
		var current := ""
		for k in installer.results.size():
			if installer.results[k] in ["ok", "pending", "skipped", "undone"]:
				done += 1
			elif installer.results[k] == "running" and current == "":
				current = TI.task_title(installer.tasks[k])
		var total := maxi(1, installer.results.size())
		var pct := int(round(100.0 * done / total))
		progress_bar.value = pct
		progress_pct.text = "%d%%" % pct
		if progress_ring != null and is_instance_valid(progress_ring):
			progress_ring.set_value(pct / 100.0)
		if current == "":
			current = TI.PROGRESS_TITLE.get(plan.action(), "") if _run_state != "failed" else TI.STATE["failed"]
		progress_title.text = current.to_upper()


func _on_finished(act: String, ok: bool, msg: String) -> void:
	if act == "reboot":
		if not ok:
			toasts.show_toast(TI.NO_GAME_REBOOT if msg == "game_running" else TI.error_line(msg), "alert", "bad")
		return
	_run_state = "ok" if ok else "failed"
	_run_message = msg
	if ok:
		if act in ["install", "change", "repair"]:
			SettingsWriter.mark_setup(services.get("setup"), plan.choices, plan.skipped, _any_signed_in())
		plan.ran = true
		go(plan.next())
	elif plan.step == "progress":
		show_step()
		focus_first()


func _on_undone(ok: bool) -> void:
	_run_state = "undone"
	_run_message = TI.UNDO_OK if ok else TI.UNDO_PARTLY
	if plan.step == "progress":
		show_step()
		focus_first()


func _any_signed_in() -> bool:
	var st := _store_status()
	for s in st:
		if bool(st[s].get("signed_in", false)):
			return true
	return false


func _wants_restart() -> bool:
	var act: String = plan.action()
	if act in ["uninstall", "update"]:
		return true
	if installer == null:
		return false
	if act == "finish":
		for f in plan.choices.get("fixes", []):
			if f in ["claw8ex-vrr", "claw8ex-gyro"]:
				return true
		return false
	return str(target.get("method", "none")) != "none" and plan.choices.get("startup", "") != "desktop" or installer.results.has("pending")


func _build_done() -> void:
	var act: String = plan.action()
	_heading(TI.DONE_TITLE.get(act, TI.DONE_TITLE["install"]), "")
	# The title moves into a centred card: check ring, eyebrow, title, what's next.
	page_title.get_parent().visible = false
	var wrap := CenterContainer.new()
	wrap.name = "DoneWrap"
	wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(wrap)
	var card := PanelContainer.new()
	card.name = "DoneCard"
	card.theme_type_variation = "CardPanel"
	card.custom_minimum_size = Vector2(880, 0)
	wrap.add_child(card)
	var col := Kit.vbox(14)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	card.add_child(col)
	var ring := PanelContainer.new()
	ring.name = "Check"
	ring.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var rsb := ThemeLib.box(Color(ThemeLib.tone("good"), 0.12), 999, 12, 12)
	rsb.border_color = ThemeLib.tone("good")
	rsb.set_border_width_all(2)
	ring.add_theme_stylebox_override("panel", rsb)
	ring.add_child(Icons.rect("check", 30, ThemeLib.tone("good")))
	col.add_child(ring)
	var eb := Kit.micro(TI.DONE_EYEBROW, "EyebrowLabel")
	eb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(eb)
	var title := Kit.label(page_title.text, "TitleLabel", true)
	title.name = "DoneTitle"
	title.add_theme_font_override("font", ThemeLib.font("display"))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(title)
	var line: String = TI.NEXT_BOOT_UNINSTALL if act == "uninstall" else TI.NEXT_BOOT.get(str(plan.choices.get("startup", "steam")), "")
	var nb := Kit.label(line, "QuietLabel", true)
	nb.name = "NextBoot"
	nb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(nb)
	var live: bool = installer != null and installer.is_live()
	if act != "uninstall":
		col.add_child(SKit.note(TI.RESTART_NEEDED if not live or act == "update" else TI.RESTART_OPTIONAL, "info", "Restart"))
	if installer != null and not installer.deferred_fixes.is_empty():
		col.add_child(SKit.note(TI.WAITING_FIXES, "warn", "WaitingFixes"))
	var fixes: Array = plan.choices.get("fixes", []) if act in ["install", "change", "repair", "finish"] else []
	if "claw8ex-gyro" in fixes:
		col.add_child(SKit.note(TI.COLD_BOOT, "warn", "ColdBoot"))
	elif "claw8ex-vrr" in fixes:
		col.add_child(SKit.note(TI.RESTART_FIX, "info", "RestartFix"))
	var later := SKit.action(TI.LATER if _wants_restart() else TI.CLOSE, "x", "Later")
	later.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	later.custom_minimum_size = Vector2(220, 52)
	later.pressed.connect(close)
	col.add_child(later)
	_focusables.append(later)


func _build_maintenance() -> void:
	var st: Dictionary = target.get("state", {})
	var ver := str(st.get("version", target.get("release", {}).get("version", "")))
	_heading(TI.MAINT_TITLE, TI.MAINT_INFO % [ver if ver != "" else "?", TI.METHOD_NAMES.get(str(st.get("method", target.get("method", "none"))), "")])
	var top := Kit.hbox(24)
	top.add_child(_device_picture(110))
	var col := Kit.vbox(8)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	var dn := Kit.label(_device_name().to_upper(), "HeaderLabel")
	dn.add_theme_font_override("font", ThemeLib.font("display"))
	col.add_child(dn)
	if bool(target.get("staged", false)):
		col.add_child(SKit.chip(TI.MAINT_STAGED, "warn", "clock"))
	top.add_child(col)
	body.add_child(top)
	var change := _row("maint_change", TI.MAINT_CHANGE, "", TI.MAINT_CHANGE_LINE, "settings")
	change.collapse_hint = false
	change.set_hint(TI.MAINT_CHANGE_LINE)
	change.pressed.connect(func(): maintenance("change"))
	var repair := _row("maint_repair", TI.MAINT_REPAIR, "", TI.MAINT_REPAIR_LINE, "update")
	repair.collapse_hint = false
	repair.set_hint(TI.MAINT_REPAIR_LINE)
	repair.pressed.connect(func(): maintenance("repair"))
	if bool(target.get("update_available", false)):
		var tag := str(target.get("release", {}).get("tag", ""))
		var up := _row("maint_update", TI.MAINT_UPDATE % tag, "", TI.MAINT_UPDATE_LINE, "download")
		up.collapse_hint = false
		up.set_hint(TI.MAINT_UPDATE_LINE)
		up.set_value(tag, "good")
		up.pressed.connect(func(): maintenance("update"))
	else:
		var same := _row("maint_update", TI.MAINT_UP_TO_DATE, "", TI.MAINT_UP_TO_DATE_LINE, "check", false)
		same.collapse_hint = false
		same.set_hint(TI.MAINT_UP_TO_DATE_LINE)
		same.button.disabled = true
		_focusables.erase(same.button)
	var rm := _row("maint_remove", TI.MAINT_REMOVE, "", TI.MAINT_REMOVE_LINE, "x")
	rm.collapse_hint = false
	rm.set_hint(TI.MAINT_REMOVE_LINE)
	rm.pressed.connect(func(): maintenance("uninstall"))


func maintenance(m: String) -> void:
	plan.set_mode(m)
	go(plan.next())


func _build_uninstall() -> void:
	_heading(TI.UNINSTALL_TITLE, TI.UNINSTALL_LINE)
	var had: Array = target.get("state", {}).get("fixes", []) if target.get("state", {}).get("fixes", []) is Array else []
	if not had.is_empty():
		var f := _bool("remove_fixes", TI.REMOVE_FIXES, bool(plan.choices["remove_fixes"]), TI.REMOVE_FIXES_LINES, "sparkle")
		_always_explain(f, TI.REMOVE_FIXES_LINES)
		f.changed.connect(func(v): plan.set_choice("remove_fixes", v))
	# Save backups aren't settings (final review, high 9): they stay unless their own switch, which says how
	# many and how big, is turned on. It only shows with "Keep my settings" off and when there are any.
	var stats: Dictionary = UserData.save_backup_stats(installer.user_dir if installer != null else OS.get_user_data_dir())
	var has_backups := int(stats["backups"]) > 0
	var keep_lines: Dictionary = TI.KEEP_SETTINGS_LINES.duplicate()
	if has_backups:
		keep_lines[false] = str(keep_lines[false]) + TI.KEEP_SETTINGS_SAVES
	var k := _bool("keep_settings", TI.KEEP_SETTINGS, bool(plan.choices["keep_settings"]), keep_lines, "settings")
	_always_explain(k, keep_lines)
	k.changed.connect(_on_keep_settings)
	if has_backups and not bool(plan.choices["keep_settings"]):
		var what: String = TI.backups_text(int(stats["backups"]), int(stats["games"]), UserData.size_text(int(stats["bytes"])))
		var where: String = (installer.user_dir if installer != null else OS.get_user_data_dir()).path_join(UserData.SAVE_BACKUPS)
		var home_dir := OS.get_environment("HOME")
		if home_dir.length() > 1 and where.begins_with(home_dir + "/"):
			where = "~" + where.substr(home_dir.length())
		var lines := {false: TI.REMOVE_SAVE_BACKUPS_LINES[false] % [what, where], true: TI.REMOVE_SAVE_BACKUPS_LINES[true] % what}
		var b := _bool("remove_save_backups", TI.REMOVE_SAVE_BACKUPS, bool(plan.choices["remove_save_backups"]), lines, "x")
		_always_explain(b, lines)
		b.changed.connect(func(v): plan.set_choice("remove_save_backups", v))
	body.add_child(SKit.note(TI.SUMMARY_PASSWORD, "info", "Password"))


## The line under a switch stays visible, focused or not: on this page it says what gets deleted.
## (collapse_hint alone changes nothing until the row redraws, so these lines never showed
## while the Remove button had the focus, which is where this page starts.)
func _always_explain(row: VBoxContainer, lines: Dictionary) -> void:
	row.collapse_hint = false
	row.set_explainer(func(v): return lines.get(v, ""))


## "Keep my settings" changed: the save-backups switch comes and goes with it, and deleting
## them is never left on from an earlier visit.
func _on_keep_settings(v: Variant) -> void:
	plan.set_choice("keep_settings", v)
	plan.set_choice("remove_save_backups", false)
	if plan.step != "uninstall":
		return
	show_step()
	var row := body.find_child("keep_settings", true, false)
	if row != null and row.get("button") is Control and is_inside_tree():
		row.button.grab_focus()
		_update_hints()


func _build_finish() -> void:
	_heading(TI.FINISH_TITLE, TI.FINISH_LINE)
	for f in plan.choices.get("fixes", []):
		var c := SKit.card(Texts.fix_title(f), "sparkle", Texts.fix_explain(f))
		c[0].name = "Fix_" + f
		body.add_child(c[0])


# ------------------------------------------------------------ navigation

func go(to: String) -> void:
	plan.step = to
	show_step()
	focus_first()


func next_step() -> void:
	match plan.step:
		"done":
			if _wants_restart() and installer != null:
				installer.reboot()
			else:
				close()
			return
		"summary":
			if _blocked():
				return
	go(plan.next())


func skip_step() -> void:
	if plan.skip():
		show_step()
		focus_first()


func go_back() -> void:
	var was: String = plan.step
	var to: String = plan.back()
	if to != was:
		show_step()
		focus_first()


func close() -> void:
	if installer != null and installer.running:
		return
	if sign_in != null and is_instance_valid(sign_in):
		sign_in.stop()
	if art_step != null and is_instance_valid(art_step):
		art_step.stop()
	closed.emit()
	if quit_on_close and is_inside_tree():
		get_tree().quit()


func focus_first() -> void:
	if not is_inside_tree():
		return
	var f: Control = null
	for c in _focusables:
		if c is Control and c.is_visible_in_tree() and not (c is BaseButton and c.disabled):
			f = c
			break
	# Easy mode's store step starts on Continue: one press moves on, signing in is a step up
	var on_next: bool = plan.step in ["summary", "uninstall", "finish", "done"] or (plan.step == "stores" and plan.mode == "easy" and sign_in == null)
	if f == null or on_next and next_button.visible:
		f = next_button if next_button.visible else f
	if f != null:
		f.grab_focus()
	_update_hints()


func focusables() -> Array:
	return _focusables


func _link() -> void:
	var navs: Array = [back_button, skip_button, next_button].filter(func(b): return b.visible)
	Kit.link_horizontal(navs)
	var chain: Array = _focusables.filter(func(c): return not (c is BaseButton and c.disabled))
	Kit.link_vertical(chain)
	var last: Control = chain[-1] if not chain.is_empty() else null
	for b in navs:
		b.focus_neighbor_top = b.get_path_to(last if last != null else b)
		b.focus_neighbor_bottom = b.get_path_to(b)
	if last != null and not navs.is_empty():
		last.focus_neighbor_bottom = last.get_path_to(next_button if next_button.visible else navs[-1])
	# Rows that sit side by side (cards, fail actions) move left / right; down
	# goes to whatever follows the row in the chain (else Continue), up to
	# what comes before it.
	for row_name in ["FailActions", "Modes", "Startup", "StoreCards", "Themes", "Actions"]:
		var r := body.find_child(row_name, true, false)
		if r == null:
			continue
		var items: Array = r.get_children().filter(func(c): return c is BaseButton and not c.disabled and c in chain)
		if items.is_empty():
			continue
		Kit.link_horizontal(items)
		var first_i := chain.find(items[0])
		var last_i := chain.find(items[-1])
		var below: Control = chain[last_i + 1] if last_i + 1 < chain.size() else (next_button if next_button.visible else null)
		var above: Control = chain[first_i - 1] if first_i > 0 else null
		for c in items:
			c.focus_neighbor_bottom = c.get_path_to(below if below != null else c)
			c.focus_neighbor_top = c.get_path_to(above if above != null else c)
		if below != null and below in chain:
			below.focus_neighbor_top = below.get_path_to(items[0])
		if last_i == chain.size() - 1:
			for b in navs:
				b.focus_neighbor_top = b.get_path_to(items[0])


func ask_text(placeholder: String, start: String, done: Callable) -> void:
	_ask_done = done
	_ask_return = get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	keyboard.use_for_codes(placeholder)
	keyboard.open(start)


func _on_keyboard_closed(text: String) -> void:
	var cb := _ask_done
	_ask_done = Callable()
	if _ask_return != null and is_instance_valid(_ask_return) and _ask_return.is_visible_in_tree():
		_ask_return.grab_focus()
	if cb.is_valid():
		cb.call(text)


func _unhandled_input(event: InputEvent) -> void:
	if keyboard != null and keyboard.is_open():
		return
	var lb: bool = event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_LEFT_SHOULDER
	var rb: bool = event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_RIGHT_SHOULDER
	if (lb or rb) and plan.step != "progress" and plan.step != "done":
		if lb:
			go_back()
		elif next_button.visible and not next_button.disabled and plan.step != "summary":
			next_step()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("ui_cancel"):
		if sign_in != null and is_instance_valid(sign_in):
			go("stores")
		else:
			go_back()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_accept") or event.is_action_pressed("ui_up") or event.is_action_pressed("ui_down") \
			or event.is_action_pressed("ui_left") or event.is_action_pressed("ui_right"):
		if get_viewport().gui_get_focus_owner() == null:
			focus_first()
			get_viewport().set_input_as_handled()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and body != null and not _rebuild_queued and is_inside_tree():
		_rebuild_queued = true
		_rebuild_for_theme.call_deferred()
	elif what == NOTIFICATION_PREDELETE:
		for c in _graveyard:
			if is_instance_valid(c):
				c.free()
		_graveyard.clear()
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		# Back from the browser or Steam: pick up a copied code, a new Steam sign-in.
		if sign_in != null and is_instance_valid(sign_in):
			sign_in.check_clipboard()
		elif art_step != null and is_instance_valid(art_step):
			art_step.check_clipboard()
		elif plan != null and plan.step == "steam":
			refresh_steam()
		elif plan != null and plan.step == "stores":
			show_step()
	elif what == NOTIFICATION_WM_CLOSE_REQUEST:
		if installer != null and installer.running:
			toasts.show_toast(TI.WAIT_TO_CLOSE, "info")
		elif quit_on_close:
			get_tree().quit()


func _rebuild_for_theme() -> void:
	_rebuild_queued = false
	if not is_inside_tree():
		return
	var f := get_viewport().gui_get_focus_owner()
	var keep := String(f.get_parent().name) if f != null and is_ancestor_of(f) else ""
	_build()
	var again := body.find_child(keep, true, false) as Control if keep != "" else null
	if again != null and again.get("button") is Control:
		again.button.grab_focus()
	else:
		focus_first()
