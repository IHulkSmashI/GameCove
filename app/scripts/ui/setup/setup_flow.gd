extends Control
## First-run setup: Welcome, Look (theme), Stores (QR sign-in), Game art
## (the user's own SteamGridDB key, art_key_step.gd), Keys (gg.deals), Device
## fixes, Done. Shows on the first launch
## (Setup.is_first_run()), every step but Welcome and Done can be skipped, and
## Settings > About GameCove reopens any step from its checklist.
##
## Host entry point (main.gd, after the screens exist):
##
##     const SetupFlow := preload("res://scripts/ui/setup/setup_flow.gd")
##     var flow := SetupFlow.open_if_first_run(self, {"setup": Setup, "device": Device, "discover": Discover})
##     if flow: flow.setting_changed.connect(_on_setting_changed)
##
## `open()` adds the flow as the host's last child (above everything), takes
## focus and swallows LB / RB / B so nothing behind it moves. Theme picks go
## out as `setting_changed("theme", id)`, the same as Settings' `changed`.
## Without that hook the Settings screen opens it on a first run itself.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const SKit := preload("res://scripts/ui/settings/kit.gd")
const TS := preload("res://scripts/ui/texts_settings.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Themes := preload("res://theme/themes.gd")
const Icons := preload("res://scripts/ui/icons.gd")
const Motion := preload("res://scripts/ui/motion.gd")
const Osk := preload("res://scripts/ui/osk.gd")
const ActionRow := preload("res://scripts/ui/settings/action_row.gd")
const SignIn := preload("res://scripts/ui/settings/sign_in.gd")
const Appearance := preload("res://scripts/ui/settings/appearance_page.gd")
const Texts := preload("res://scripts/ui/texts.gd")
const PhotoView := preload("res://scripts/ui/device/device_photo_view.gd")
const ArtKeyStep := preload("res://scripts/ui/setup/art_key_step.gd")

signal setting_changed(key: String, value: Variant)
signal closed

## The open flow, if any (only one at a time).
static var instance: Control = null

var services := {}
var step := "welcome"
var steps_box: VBoxContainer
var body: VBoxContainer
var nav: HBoxContainer
var next_button: Button
var back_button: Button
var skip_button: Button
var keyboard: PanelContainer
var sign_in: HBoxContainer
var art_step: HBoxContainer
var _focusables: Array = []
var _ask_done: Callable
var _ask_return: Control
var _fixes: Array = []
var _fixes_checked := false
var _rebuild_queued := false
var _theme := ""
## First run: Next skips steps already done elsewhere (the installer marks
## the steps it covered in the Setup service). Reopened from Settings: every step.
var skip_finished := false


## True when setup should show now (first launch, setup not finished).
static func should_show(setup_svc: Object) -> bool:
	return setup_svc != null and setup_svc.has_method("is_first_run") and bool(setup_svc.is_first_run())


## Opens setup over `host` at `at` (a TS.SETUP_STEPS id; "" = first unfinished).
## Returns the flow (the open one if it's already showing).
static func open(host: Control, svc: Dictionary, at := "") -> Control:
	if instance != null and is_instance_valid(instance):
		if at != "":
			instance.go(at)
		return instance
	var f: Control = load("res://scripts/ui/setup/setup_flow.gd").new()
	f.setup(svc, at)
	host.add_child(f)
	instance = f
	f.focus_first()
	return f


## The 3-line hook's helper: opens setup only on a first run.
static func open_if_first_run(host: Control, svc: Dictionary) -> Control:
	if not should_show(svc.get("setup")):
		return null
	var f: Control = open(host, svc, "")
	f.set("skip_finished", true)
	return f


func setup(svc: Dictionary, at := "") -> void:
	name = "SetupFlow"
	services = svc
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var st: Object = svc.get("setup")
	if st != null and st.has_signal("fixes_checked"):
		st.fixes_checked.connect(_on_fixes_checked)
	step = at if at in TS.SETUP_STEPS else first_step()
	_theme = ThemeLib.theme_id
	_build()


## First step neither done nor skipped (Welcome on a fresh start).
func first_step() -> String:
	var st: Object = services.get("setup")
	if st == null or not st.has_method("next_step"):
		return "welcome"
	var sid: String = st.next_step()
	for k in TS.SETUP_SERVICE_IDS:
		if TS.SETUP_SERVICE_IDS[k] == sid:
			return k
	return "welcome"


func _build() -> void:
	for c in get_children():
		Kit.drop(self, c)
	var shade := ColorRect.new()
	shade.name = "Shade"
	# Opaque: the shell's top and bottom bars don't show behind setup (their
	# prompts and status would only compete with the setup's own).
	shade.color = ThemeLib.color("bg")
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(shade)

	var panel := PanelContainer.new()
	panel.name = "Panel"
	var psb := ThemeLib.box(Color(ThemeLib.color("surface"), 0.97), ThemeLib.radius("xl"), 32, 28)
	psb.border_color = ThemeLib.color("line")
	psb.set_border_width_all(1)
	psb.shadow_color = Color(0, 0, 0, 0.35 if ThemeLib.is_dark() else 0.10)
	psb.shadow_size = 24
	panel.add_theme_stylebox_override("panel", psb)
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.offset_left = 64
	panel.offset_right = -64
	panel.offset_top = 48
	panel.offset_bottom = -48
	add_child(panel)
	var cols := Kit.hbox(36)
	panel.add_child(cols)

	var rail := Kit.vbox(10)
	rail.name = "Rail"
	rail.custom_minimum_size = Vector2(230, 0)
	var logo := TextureRect.new()
	logo.texture = load("res://assets/logo-mark.svg") if ResourceLoader.exists("res://assets/logo-mark.svg") else null
	logo.custom_minimum_size = Vector2(44, 44)
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	logo.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	rail.add_child(logo)
	var setup_label := Kit.label("Setup", "HeaderLabel")
	setup_label.name = "SetupLabel"
	rail.add_child(setup_label)
	var step_label := Kit.micro("", "EyebrowLabel")
	step_label.name = "StepOf"
	rail.add_child(step_label)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 8)
	rail.add_child(gap)
	steps_box = Kit.vbox(4)
	steps_box.name = "Steps"
	rail.add_child(steps_box)
	cols.add_child(rail)
	var line := ColorRect.new()
	line.custom_minimum_size = Vector2(1, 0)
	line.color = ThemeLib.color("line")
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cols.add_child(line)

	var right := Kit.vbox(16)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(right)
	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.follow_focus = true
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(scroll)
	var pad := Kit.margin(6, 6, 6)
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(pad)
	body = Kit.vbox(16)
	body.name = "Body"
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pad.add_child(body)

	nav = Kit.hbox(12)
	nav.name = "Nav"
	skip_button = Kit.button(TS.SKIP)
	skip_button.name = "Skip"
	skip_button.custom_minimum_size = Vector2(130, 52)
	skip_button.pressed.connect(skip_step)
	nav.add_child(skip_button)
	nav.add_child(Kit.spacer())
	var prompts := Kit.prompts([["A", "Select"]])
	prompts.name = "Prompts"
	nav.add_child(prompts)
	# Back is the B prompt itself: one control (B on the controller, tap or
	# focus + A), not a pill and a prompt saying the same thing.
	back_button = prompt_button("B", TS.BACK)
	back_button.name = "Back"
	back_button.pressed.connect(go_back)
	nav.add_child(back_button)
	next_button = Kit.button(TS.NEXT, "AccentButton")
	next_button.name = "Next"
	next_button.custom_minimum_size = Vector2(190, 52)
	next_button.add_theme_font_size_override("font_size", ThemeLib.SIZE_BODY)
	next_button.pressed.connect(next_step)
	nav.add_child(next_button)
	right.add_child(nav)

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
	_show_step()


## A flat button drawn like a prompt ("(B) Back"): no pill until it's focused.
static func prompt_button(glyph: String, text: String) -> Button:
	var b := Button.new()
	b.theme_type_variation = "TabButton"
	b.focus_mode = Control.FOCUS_ALL
	b.custom_minimum_size = Vector2(0, 52)
	var row := Kit.hbox(7)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_child(Kit.glyph(glyph))
	var l := Kit.label(text, "CaptionLabel")
	l.add_theme_font_override("font", ThemeLib.font("semibold"))
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(l)
	b.add_child(row)
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	b.custom_minimum_size.x = row.get_combined_minimum_size().x + 28
	b.tooltip_text = text
	return b


func go(to: String) -> void:
	if not to in TS.SETUP_STEPS:
		return
	if sign_in != null and is_instance_valid(sign_in):
		sign_in.stop()
	_stop_art()
	step = to
	_show_step()
	focus_first()


func _show_step() -> void:
	sign_in = null
	_stop_art()
	for c in body.get_children():
		Kit.drop(body, c)
	_focusables.clear()
	match step:
		"welcome": _build_welcome()
		"theme": _build_theme()
		"stores": _build_stores()
		"art": _build_art()
		"keys": _build_keys()
		"fixes": _build_fixes()
		"done": _build_done()
	_build_rail()
	var optional: bool = step in ["theme", "stores", "art", "keys", "fixes"]
	back_button.visible = step != "welcome"
	skip_button.visible = optional or step == "welcome"
	skip_button.text = TS.SKIP_SETUP if step == "welcome" else (ArtKeyStep.SKIP_TEXT if step == "art" else TS.SKIP)
	skip_button.custom_minimum_size = Vector2(260 if step == "art" else 130, 52)
	next_button.text = {"welcome": TS.START, "done": TS.FINISH}.get(step, TS.NEXT)
	# Game art: Next only once a key is in (Skip moves on without one), so
	# one primary button shows at a time.
	next_button.visible = step != "art" or (art_step != null and art_step.has_key())
	_link()
	body.modulate.a = 0.0
	Motion.to(body, "modulate:a", 1.0, Motion.BASE)


func _build_rail() -> void:
	for c in steps_box.get_children():
		Kit.drop(steps_box, c)
	var st: Object = services.get("setup")
	var states := {}
	if st != null and st.has_method("steps"):
		for s in st.steps():
			states[s["id"]] = "done" if s.get("done", false) else ("skipped" if s.get("skipped", false) else "todo")
	var n := 0
	for k in TS.SETUP_STEPS:
		n += 1
		var on: bool = k == step
		var state: String = states.get(TS.SETUP_SERVICE_IDS[k], "todo")
		if on:
			var so := find_child("StepOf", true, false) as Label
			if so != null:
				so.text = "Step %d of %d" % [n, TS.SETUP_STEPS.size()]
		# Mono step pills: done in green, the current one in the accent.
		var tone_col: Color = ThemeLib.color("accent") if on else (ThemeLib.tone("good") if state == "done" else ThemeLib.color("text_3"))
		var row := PanelContainer.new()
		row.name = "Step_" + k
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var sb := ThemeLib.box(Color(tone_col, 0.10) if on or state == "done" else ThemeLib.soft(0.03), ThemeLib.radius("m"), 14, 9)
		sb.border_color = Color(tone_col, 0.55) if on or state == "done" else ThemeLib.color("line")
		sb.set_border_width_all(1)
		row.add_theme_stylebox_override("panel", sb)
		var h := Kit.hbox(10)
		h.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var l := Kit.label("%d. %s" % [n, TS.SETUP_STEP_NAMES[k]])
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.add_theme_font_override("font", ThemeLib.mono(on, 1))
		l.add_theme_font_size_override("font_size", ThemeLib.SIZE_CAPTION)
		l.add_theme_color_override("font_color", ThemeLib.color("text") if on else (tone_col if state == "done" else ThemeLib.color("text_2")))
		h.add_child(l)
		if state == "done" or (state == "skipped" and not on):
			h.add_child(Icons.rect("check" if state == "done" else "x", 16, tone_col))
		row.add_child(h)
		steps_box.add_child(row)


func _heading(title: String, line: String) -> void:
	var t := Kit.label(title, "TitleLabel", true)
	t.name = "Heading"
	body.add_child(t)
	if line != "":
		var l := Kit.label(line, "QuietLabel", true)
		l.name = "Lead"
		body.add_child(l)


func _device() -> Object:
	return services.get("device")


func _device_name() -> String:
	var d := _device()
	return d.display_name() if d != null and d.has_method("display_name") else "handheld"


func _build_welcome() -> void:
	var d := _device()
	var pic := _device_photo_hook(d)
	if pic == null:
		pic = _device_picture(d)
	if pic != null:
		body.add_child(pic)
	_heading(TS.WELCOME_TITLE, TS.WELCOME_LINE % _device_name())
	var level := str(d.support_level()) if d != null and d.has_method("support_level") else "generic"
	body.add_child(SKit.note(TS.WELCOME_SUPPORT.get(level, TS.WELCOME_SUPPORT["generic"]), "good" if level in ["full", "partial"] else "info", "Support"))
	var plan := GridContainer.new()
	plan.name = "Plan"
	plan.columns = 2
	plan.add_theme_constant_override("h_separation", 28)
	plan.add_theme_constant_override("v_separation", 14)
	for k in ["theme", "stores", "art", "keys", "fixes"]:
		var row := Kit.hbox(12)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var ic := Icons.rect(TS.WELCOME_PLAN_ICONS[k], 22, ThemeLib.color("accent"))
		ic.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		row.add_child(ic)
		var col := Kit.vbox(2)
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var t := Kit.label(TS.SETUP_STEP_NAMES[k])
		t.add_theme_font_override("font", ThemeLib.font("semibold"))
		col.add_child(t)
		col.add_child(Kit.label(TS.WELCOME_PLAN[k], "QuietLabel", true))
		row.add_child(col)
		plan.add_child(row)
	body.add_child(plan)


# ---- real device photo (DevicePhoto service) ---------------------------------------
# Kept apart so the restyle merges cleanly. With a freely licensed photo cached
# for this device it replaces the drawing, with its credit under it (focusable,
# opens the Commons page). No photo, offline or the setting off: null, and the
# drawing shows as before. A photo that lands while Welcome is up rebuilds it.

func _device_photo_hook(d: Object) -> Control:
	var ph: Object = services.get("photo")
	if ph == null or d == null or not ph.has_method("photo_for"):
		return null
	var device_id := ""
	if d.has_method("id"):
		device_id = str(d.id())
	elif "profile" in d and d.profile is Dictionary:
		device_id = str(d.profile.get("id", ""))
	if device_id == "" or device_id == "unknown":
		return null
	if ph.has_signal("photo_ready") and not ph.photo_ready.is_connected(_on_photo_ready):
		ph.photo_ready.connect(_on_photo_ready)
	var view: Control = PhotoView.make(ph.photo_for(device_id), 190, _open_photo_link)
	if view != null and not view.credit.disabled:
		_focusables.append(view.credit)
	return view


func _on_photo_ready(_device_id: String, _path: String) -> void:
	if step == "welcome" and is_inside_tree() and body != null and not body.has_node("DevicePhoto"):
		_build()


func _open_photo_link(url: String) -> void:
	var d: Object = services.get("discover")
	if d != null and d.has_method("open_link") and d.open_link({"kind": "url", "uri": url}):
		return
	OS.shell_open(url)


## The device's front picture (Device.picture_for), if there is one.
static func _device_picture(d: Object) -> Control:
	if d == null:
		return null
	var path := ""
	if d.has_method("picture"):
		path = str(d.picture())
	elif d.has_method("picture_for") and "profile" in d:
		path = str(d.picture_for(str(d.profile.get("id", ""))))
	if path == "":
		return null
	var tex: Texture2D = null
	if FileAccess.file_exists(path):
		tex = Icons.from_svg(FileAccess.get_file_as_string(path))
	elif ResourceLoader.exists(path):
		tex = load(path)
	if tex == null:
		return null
	var r := TextureRect.new()
	r.name = "DevicePicture"
	r.texture = tex
	r.custom_minimum_size = Vector2(0, 190)
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


func _build_theme() -> void:
	_heading(TS.THEME_TITLE, TS.THEME_LINE)
	var grid := GridContainer.new()
	grid.name = "Themes"
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 16)
	grid.add_theme_constant_override("v_separation", 16)
	body.add_child(grid)
	var current := ThemeLib.theme_id
	for id in Themes.ORDER:
		var b := Button.new()
		b.name = "Theme_" + id
		b.focus_mode = Control.FOCUS_ALL
		b.custom_minimum_size = Vector2(0, 132)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		for st in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
			b.add_theme_stylebox_override(st, StyleBoxEmpty.new())
		b.add_theme_stylebox_override("focus", ThemeLib.focus_ring(ThemeLib.radius("m") + 4, ThemeLib.color("text"), 3))
		var only: Control = Appearance.preview(id)
		Kit.fill(only)
		b.add_child(only)
		Appearance.mark_one(only, id == current)
		b.pressed.connect(func(): pick_theme(id))
		grid.add_child(b)
		_focusables.append(b)
	body.add_child(Kit.label(Texts.THEME_LINES.get(current, ""), "QuietLabel", true))


func pick_theme(id: String) -> void:
	setting_changed.emit("theme", id)
	_theme = id
	# The host rebuilds its theme; we rebuild on NOTIFICATION_THEME_CHANGED.
	# A host that doesn't (tests) still sees the new step state.
	var st: Object = services.get("setup")
	if st != null:
		st.complete("theme")
	if not is_inside_tree():
		_show_step()


func _build_stores() -> void:
	_heading(TS.STORES_TITLE, TS.STORES_LINE)
	var st: Object = services.get("setup")
	if st == null or not st.has_method("store_status"):
		body.add_child(SKit.note("Store sign-in isn't available in this build.", "info"))
		return
	var status: Dictionary = st.store_status()
	for store in TS.STORE_ORDER:
		var info: Dictionary = status.get(store, {})
		var signed: bool = info.get("signed_in", false)
		var can := TS.can_sign_in(info)
		var r: VBoxContainer = ActionRow.new()
		r.setup("store_" + store, TS.STORE_NAMES[store], TS.SIGNED_IN if signed else (TS.SIGN_IN if can else TS.NOT_SIGNED_IN), TS.store_line(info), "", can)
		r.collapse_hint = false
		r.set_hint(TS.store_line(info))
		r.set_value(r.value_label.text, "good" if signed else ("" if can else "muted"))
		if can:
			r.pressed.connect(func(): open_sign_in(store))
		body.add_child(r)
		_focusables.append(r.button)


func open_sign_in(store: String) -> void:
	for c in body.get_children():
		Kit.drop(body, c)
	_focusables.clear()
	sign_in = SignIn.new()
	sign_in.finished.connect(func(_s, ok, _m):
		if ok:
			var st: Object = services.get("setup")
			if st != null:
				st.complete("stores"))
	body.add_child(sign_in)
	var back := Kit.button("All stores")
	back.name = "AllStores"
	back.custom_minimum_size = Vector2(200, 52)
	back.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	back.pressed.connect(func(): go("stores"))
	body.add_child(back)
	sign_in.start(services.get("setup"), store, ask_text)
	_focusables.append(sign_in.type_button)
	_focusables.append(back)
	_link()
	if is_inside_tree():
		sign_in.type_button.grab_focus()


func _build_keys() -> void:
	_heading(TS.KEYS_TITLE, TS.KEYS_LINE)
	var d: Object = services.get("discover")
	var st: Object = services.get("setup")
	var s: Dictionary = d.get_settings() if d != null and d.has_method("get_settings") else {}
	var gg := str(s.get("ggdeals_key", ""))
	var sg := str(s.get("steamgriddb_key", ""))
	if sg == "" and st != null and st.has_method("steamgriddb_key"):
		sg = st.steamgriddb_key()
	if d != null and d.has_method("set_settings"):
		_key_row("ggdeals_key", "gg.deals key", gg, TS.KEY_GGDEALS_WHY)
	# SteamGridDB has its own guided step now: a row that opens it.
	var r: VBoxContainer = ActionRow.new()
	r.setup("steamgriddb_key", "SteamGridDB key", TS.masked(sg), TS.KEY_SGDB_WHY, "shield")
	r.collapse_hint = false
	r.set_hint(TS.KEY_SGDB_WHY)
	r.set_value(TS.masked(sg), "muted" if sg == "" else "good")
	r.pressed.connect(func(): go("art"))
	body.add_child(r)
	_focusables.append(r.button)


# ---- Game art: the user's own SteamGridDB key (art_key_step.gd) ----------------

func _build_art() -> void:
	_heading(ArtKeyStep.TITLE, ArtKeyStep.LINE)
	art_step = ArtKeyStep.new()
	art_step.configure({"setup": services.get("setup"), "discover": services.get("discover"), "library": services.get("library"),
		"http": services.get("http"), "ask_text": ask_text, "lan": services.get("lan", Callable()),
		"prefs_path": services.get("prefs_path", "user://settings.cfg")})
	art_step.saved.connect(_on_art_saved)
	body.add_child(art_step)
	art_step.start()
	for b in art_step.buttons:
		_focusables.append(b)


func _on_art_saved(_key: String) -> void:
	var st: Object = services.get("setup")
	if st != null:
		st.complete("steamgriddb")
	_build_rail()
	next_button.visible = true
	_link()
	if is_inside_tree():
		next_button.grab_focus()


func _stop_art() -> void:
	if art_step != null and is_instance_valid(art_step):
		art_step.stop()
	art_step = null


func _key_row(key: String, title: String, value: String, why: String) -> void:
	var r: VBoxContainer = ActionRow.new()
	r.setup(key, title, TS.masked(value), why, "shield")
	r.collapse_hint = false
	r.set_hint(why)
	r.set_value(TS.masked(value), "muted" if value == "" else "good")
	r.pressed.connect(func(): ask_text(title, value, func(t: String): save_key(key, t.strip_edges())))
	body.add_child(r)
	_focusables.append(r.button)


## Saves a typed key; returns false (and says why) when it doesn't look right.
func save_key(key: String, text: String) -> bool:
	var d: Object = services.get("discover")
	var st: Object = services.get("setup")
	var ok := true
	if key == "steamgriddb_key":
		ok = st == null or st.set_steamgriddb_key(text)
	elif text != "":
		ok = RegEx.create_from_string("^[A-Za-z0-9_\\-]{10,128}$").search(text) != null
	if not ok:
		_say(TS.KEY_BAD % ("SteamGridDB key" if key == "steamgriddb_key" else "gg.deals key"), "bad")
		return false
	if d != null and d.has_method("set_settings"):
		d.set_settings({key: text})
	_show_step()
	focus_first()
	return true


func _say(text: String, tone := "") -> void:
	var l := body.get_node_or_null("Say") as Label
	if l == null:
		l = Kit.label("", "AccentLabel", true)
		l.name = "Say"
		body.add_child(l)
	l.text = text
	l.add_theme_color_override("font_color", ThemeLib.tone(tone) if tone != "" else ThemeLib.color("accent"))


func _build_fixes() -> void:
	_heading(TS.FIXES_TITLE % _device_name(), TS.FIXES_LINE)
	var st: Object = services.get("setup")
	var wanted: Array = st.suggested_fixes() if st != null and st.has_method("suggested_fixes") else []
	if wanted.is_empty():
		var d := _device()
		var generic: bool = d == null or not d.has_method("support_level") or d.support_level() == "generic"
		body.add_child(SKit.note(TS.FIXES_GENERIC if generic else TS.FIXES_NONE, "info" if generic else "good", "NoFixes"))
		return
	if not _fixes_checked:
		body.add_child(Kit.label(TS.FIXES_CHECKING, "QuietLabel", true))
		if st.has_method("check_fixes"):
			st.check_fixes()
		if not _fixes_checked:
			return
		Kit.drop(body, body.get_child(body.get_child_count() - 1))
	var shown := 0
	for f in _fixes:
		if not bool(f.get("applies", false)) or str(f.get("name", "")) in Texts.HIDDEN_FIXES:
			continue
		shown += 1
		body.add_child(_fix_card(f))
	if shown == 0:
		body.add_child(SKit.note(TS.FIXES_NONE, "good", "NoFixes"))
		return
	body.add_child(SKit.note(TS.FIXES_DESKTOP, "warn", "Desktop"))


static func _fix_card(f: Dictionary) -> PanelContainer:
	var name_: String = f.get("name", "")
	var state: String = f.get("state", "unknown")
	var c := SKit.card(Texts.fix_title(name_), "sparkle")
	c[0].name = "Fix_" + name_
	var head: HBoxContainer = c[1].get_node("Heading")
	var tone: String = {"on": "good", "restart": "warn", "partial": "warn", "off": "info"}.get(state, "")
	var ch := SKit.chip(Texts.fix_state(state, name_), tone, {"good": "check", "warn": "alert"}.get(tone, ""))
	head.add_child(Kit.spacer())
	head.add_child(ch)
	c[1].add_child(Kit.label(Texts.fix_explain(name_), "QuietLabel", true))
	return c[0]


func _on_fixes_checked(list: Array) -> void:
	_fixes = list
	_fixes_checked = true
	if step == "fixes" and is_inside_tree():
		_show_step.call_deferred()


func _build_done() -> void:
	var art := Icons.rect("check", 64, ThemeLib.tone("good"))
	art.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	body.add_child(art)
	_heading(TS.DONE_TITLE, TS.DONE_LINE % "the quick menu button")
	var tips := GridContainer.new()
	tips.name = "Tips"
	tips.columns = 3
	tips.add_theme_constant_override("h_separation", 16)
	for t in TS.DONE_TIPS:
		var c := SKit.card(t[0], t[1], t[2])
		c[0].size_flags_vertical = Control.SIZE_FILL
		tips.add_child(c[0])
	body.add_child(tips)
	var st: Object = services.get("setup")
	if st != null and st.has_method("steps"):
		var skipped := false
		for s in st.steps():
			if s.get("skipped", false):
				skipped = true
		if skipped:
			body.add_child(SKit.note(TS.DONE_LATER, "info", "Later"))


# ------------------------------------------------------------ navigation

func next_step() -> void:
	var st: Object = services.get("setup")
	if st != null:
		st.complete(TS.SETUP_SERVICE_IDS[step])
	if step == "done":
		finish()
		return
	go(following(step))


## The step after `from`; on a first run, past steps already done or skipped.
func following(from: String) -> String:
	var i := TS.SETUP_STEPS.find(from) + 1
	var st: Object = services.get("setup")
	while skip_finished and st != null and st.has_method("is_done") and i < TS.SETUP_STEPS.size() - 1:
		var sid: String = TS.SETUP_SERVICE_IDS[TS.SETUP_STEPS[i]]
		if not st.is_done(sid) and not (st.has_method("is_skipped") and st.is_skipped(sid)):
			break
		i += 1
	return TS.SETUP_STEPS[mini(i, TS.SETUP_STEPS.size() - 1)]


func skip_step() -> void:
	var st: Object = services.get("setup")
	if step == "welcome":
		skip_all()
		return
	if st != null:
		st.skip(TS.SETUP_SERVICE_IDS[step])
	go(following(step))


## "Skip setup": unfinished optional steps marked skipped, setup over.
func skip_all() -> void:
	var st: Object = services.get("setup")
	if st != null:
		for s in st.steps():
			if s.get("optional", false) and not s.get("done", false):
				st.skip(s["id"])
		st.complete("welcome")
		st.complete("done")
	finish()


func go_back() -> void:
	var i := TS.SETUP_STEPS.find(step)
	if i > 0:
		go(TS.SETUP_STEPS[i - 1])


func finish() -> void:
	if sign_in != null and is_instance_valid(sign_in):
		sign_in.stop()
	_stop_art()
	if instance == self:
		instance = null
	closed.emit()
	if get_parent() != null:
		get_parent().remove_child(self)
	queue_free()


func focus_first() -> void:
	if not is_inside_tree():
		return
	var f: Control = _focusables[0] if not _focusables.is_empty() and step != "welcome" else next_button
	f.grab_focus()


func focusables() -> Array:
	return _focusables


func _link() -> void:
	var navs: Array = [skip_button, back_button, next_button].filter(func(b): return b.visible)
	Kit.link_horizontal(navs)
	var chain := _focusables.duplicate()
	if step == "theme":
		_link_grid(chain)
	elif step == "art":
		Kit.link_horizontal(chain)  # the fallbacks sit in one row
		for c in chain:
			c.focus_neighbor_top = c.get_path_to(c)
	else:
		Kit.link_vertical(chain)
	var last: Control = chain[-1] if not chain.is_empty() else null
	var up: Control = chain[0] if step == "art" and not chain.is_empty() else last
	for b in navs:
		b.focus_neighbor_top = b.get_path_to(up if up != null else b)
		b.focus_neighbor_bottom = b.get_path_to(b)
	if last != null:
		var down: Control = next_button if next_button.visible else skip_button
		if step == "theme":
			for i in range(maxi(0, chain.size() - 2), chain.size()):
				chain[i].focus_neighbor_bottom = chain[i].get_path_to(down)
		elif step == "art":
			for c in chain:
				c.focus_neighbor_bottom = c.get_path_to(down)
		else:
			last.focus_neighbor_bottom = last.get_path_to(down)


## Theme buttons sit in a 2-column grid.
static func _link_grid(chain: Array) -> void:
	for i in chain.size():
		var c: Control = chain[i]
		var col := i % 2
		c.focus_neighbor_left = c.get_path_to(chain[i - 1] if col == 1 else c)
		c.focus_neighbor_right = c.get_path_to(chain[i + 1] if col == 0 and i + 1 < chain.size() else c)
		c.focus_neighbor_top = c.get_path_to(chain[i - 2] if i >= 2 else c)
		c.focus_neighbor_bottom = c.get_path_to(chain[i + 2] if i + 2 < chain.size() else c)


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
	var guide: bool = event is InputEventJoypadButton and event.button_index == JOY_BUTTON_GUIDE
	if guide or (event is InputEventKey and event.keycode == KEY_F1):
		return
	if event.is_action_pressed("ui_cancel"):
		if step == "stores" and sign_in != null:
			go("stores")
		else:
			go_back()
	elif event.is_action_pressed("ui_accept") or event.is_action_pressed("ui_up") or event.is_action_pressed("ui_down") \
			or event.is_action_pressed("ui_left") or event.is_action_pressed("ui_right"):
		# Focus fell off somehow: put it back on something here.
		if get_viewport().gui_get_focus_owner() == null:
			focus_first()
		else:
			return
	elif not (event is InputEventJoypadButton or event is InputEventKey or event is InputEventJoypadMotion):
		return
	get_viewport().set_input_as_handled()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and body != null and not _rebuild_queued and is_inside_tree():
		_rebuild_queued = true
		_rebuild_for_theme.call_deferred()
	elif what == NOTIFICATION_PREDELETE and instance == self:
		instance = null


func _rebuild_for_theme() -> void:
	_rebuild_queued = false
	if not is_inside_tree():
		return
	var f := get_viewport().gui_get_focus_owner()
	var keep := String(f.name) if f != null and is_ancestor_of(f) else ""
	_build()
	var again := find_child(keep, true, false) as Control if keep != "" else null
	if again != null and again.focus_mode != Control.FOCUS_NONE:
		again.grab_focus()
	else:
		focus_first()
