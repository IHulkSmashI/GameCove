extends HBoxContainer
## Store sign-in without typing a password on the handheld: a QR code of the
## store's sign-in page for your phone, short steps, and "Type code" for the
## code (or address) the page gives back. Talks to the Setup service:
## start_login -> login_started (url) -> finish_login -> login_finished.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const SKit := preload("res://scripts/ui/settings/kit.gd")
const TS := preload("res://scripts/ui/texts_settings.gd")
const QR := preload("res://scripts/ui/settings/qr.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")

## ok: signed in. Emitted once per sign-in attempt that ends.
signal finished(store: String, ok: bool, message: String)

var store := ""
var setup_svc: Object
## func(placeholder: String, start: String, done: Callable(text)) from the host.
var ask_text: Callable
var url := ""
var needs := ""
var state := "idle"   # idle | waiting | ready | checking | done | failed
var qr_rect: TextureRect
var title: Label
var steps_box: VBoxContainer
var url_label: Label
var status: Label
var type_button: Button
var _connected := false


func _init() -> void:
	name = "SignIn"
	add_theme_constant_override("separation", 28)
	var frame := PanelContainer.new()
	frame.name = "QRFrame"
	frame.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	var sb := ThemeLib.box(Color.WHITE, ThemeLib.radius("l"), 10, 10)
	frame.add_theme_stylebox_override("panel", sb)
	qr_rect = TextureRect.new()
	qr_rect.name = "QR"
	qr_rect.custom_minimum_size = Vector2(240, 240)
	qr_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	qr_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	qr_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	frame.add_child(qr_rect)
	add_child(frame)
	var col := Kit.vbox(12)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(col)
	title = Kit.label("", "HeaderLabel", true)
	title.name = "Title"
	col.add_child(title)
	steps_box = Kit.vbox(8)
	steps_box.name = "Steps"
	col.add_child(steps_box)
	url_label = Kit.label("", "CaptionLabel", true)
	url_label.name = "Url"
	url_label.add_theme_color_override("font_color", ThemeLib.color("text_3"))
	col.add_child(url_label)
	status = Kit.label("", "AccentLabel", true)
	status.name = "Status"
	col.add_child(status)
	type_button = Kit.button(TS.SIGN_IN_TYPE, "AccentButton")
	type_button.name = "TypeCode"
	type_button.custom_minimum_size = Vector2(220, 52)
	type_button.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	type_button.add_theme_font_size_override("font_size", ThemeLib.SIZE_BODY)
	type_button.pressed.connect(_on_type)
	col.add_child(type_button)
	col.add_child(Kit.label(TS.SIGN_IN_KEYBOARD_TIP, "QuietLabel", true))


## Starts signing in to `which` (epic | gog | amazon).
func start(svc: Object, which: String, ask: Callable) -> void:
	stop()
	setup_svc = svc
	store = which
	ask_text = ask
	url = ""
	needs = ""
	title.text = TS.SIGN_IN_TITLE % TS.STORE_NAMES.get(store, store.capitalize())
	_set_state("waiting", TS.SIGN_IN_WAITING)
	if setup_svc == null:
		return
	setup_svc.login_started.connect(_on_started)
	setup_svc.login_finished.connect(_on_finished)
	_connected = true
	if not setup_svc.start_login(store) and state == "waiting":
		_set_state("failed", TS.SIGN_IN_MISSING)


## Drops a sign-in that's still open (the person backed out).
func stop() -> void:
	if _connected and setup_svc != null:
		if setup_svc.login_started.is_connected(_on_started):
			setup_svc.login_started.disconnect(_on_started)
		if setup_svc.login_finished.is_connected(_on_finished):
			setup_svc.login_finished.disconnect(_on_finished)
		if state in ["waiting", "ready", "checking", "failed"]:
			setup_svc.cancel_login(store)
	_connected = false


## What the person typed: the code or the whole address.
func submit(text: String) -> void:
	if text.strip_edges() == "":
		return
	_set_state("checking", TS.SIGN_IN_CHECKING)
	if not setup_svc.finish_login(store, text.strip_edges()) and state == "checking":
		_set_state("ready", TS.SIGN_IN_NO_CODE)


func first_focus() -> Control:
	return type_button


func _on_started(which: String, info: Dictionary) -> void:
	if which != store:
		return
	needs = str(info.get("needs", ""))
	url = str(info.get("url", ""))
	if url == "" or not needs in ["code", "redirect_url"]:
		_set_state("failed", TS.store_line({"how": needs}))
		return
	QR.show_on(qr_rect, url, 6)
	url_label.text = url if url.length() <= 90 else url.left(87) + "…"
	for c in steps_box.get_children():
		Kit.drop(steps_box, c)
	var steps: Array = TS.SIGN_IN_STEPS.get(needs, TS.SIGN_IN_STEPS["code"])
	for i in steps.size():
		var row := Kit.hbox(12)
		var n := Kit.label(str(i + 1), "AccentLabel")
		n.custom_minimum_size = Vector2(18, 0)
		row.add_child(n)
		row.add_child(Kit.label(steps[i], "", true))
		steps_box.add_child(row)
	_set_state("ready", "")


func _on_finished(which: String, ok: bool, message: String) -> void:
	if which != store:
		return
	if ok:
		_set_state("done", TS.SIGN_IN_DONE % TS.STORE_NAMES.get(store, store))
	else:
		_set_state("ready" if url != "" else "failed", TS.SIGN_IN_NO_CODE if message == "no code" else TS.SIGN_IN_FAILED % message)
	finished.emit(store, ok, message)


func _on_type() -> void:
	if state in ["ready", "failed"] and url != "" and ask_text.is_valid():
		ask_text.call(TS.SIGN_IN_TYPE, "", submit)


func _set_state(s: String, line: String) -> void:
	state = s
	status.text = line
	status.add_theme_color_override("font_color", ThemeLib.tone("bad") if s == "failed" or line.begins_with("That") else ThemeLib.color("accent"))
	qr_rect.get_parent().modulate.a = 1.0 if url != "" else 0.25
	type_button.disabled = not (s in ["ready", "failed"] and url != "")


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		stop()
