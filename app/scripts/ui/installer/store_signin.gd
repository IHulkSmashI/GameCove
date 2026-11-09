extends VBoxContainer
## Store sign-in on the desktop: open the store's own sign-in page in the
## browser, then hand back what it shows (Epic: a JSON text with
## "authorizationCode"; GOG / Amazon: the address you land on). None of the
## tools (legendary, gogdl, nile) has a local callback, so we do the next best
## thing: when the window gets focus back we look at the clipboard, and a
## copied code or address finishes the sign-in by itself. Paste and Type it
## are there too. The Setup service runs the tool; we never see a password.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const SKit := preload("res://scripts/ui/settings/kit.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Icons := preload("res://scripts/ui/icons.gd")
const TI := preload("res://scripts/ui/installer/texts_installer.gd")
const TS := preload("res://scripts/ui/texts_settings.gd")

signal finished(store: String, ok: bool, message: String)

var store := ""
var setup_svc: Object
var ask_text: Callable
## func(url) — OS.shell_open by default; tests record instead.
var open_url: Callable = func(u: String): OS.shell_open(u)
## func() -> String — the clipboard by default; tests return canned text.
var read_clipboard: Callable = func() -> String: return DisplayServer.clipboard_get() if DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD) else ""
var url := ""
var state := "idle"   # idle | preparing | waiting | checking | done | failed
var status: Label
var open_button: Button
var paste_button: Button
var type_button: Button
var buttons: Array = []
var _last_clip := ""


func setup(svc: Object, which: String, ask: Callable) -> void:
	name = "SignIn"
	setup_svc = svc
	store = which
	ask_text = ask
	add_theme_constant_override("separation", 14)
	var title := Kit.label(TI.SIGNIN_TITLE % TS.STORE_NAMES.get(store, store), "TitleLabel", true)
	title.name = "Heading"
	add_child(title)
	var n := 1
	for line in TI.SIGNIN_STEPS.get(store, []):
		var row := Kit.hbox(12)
		var num := Kit.badge(str(n), "info")
		num.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		row.add_child(num)
		var l := Kit.label(line, "", true)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(l)
		add_child(row)
		n += 1
	var actions := Kit.hbox(12)
	actions.name = "Actions"
	open_button = SKit.action(TI.SIGNIN_OPEN, "rocket", "Open")
	open_button.theme_type_variation = "AccentButton"
	open_button.pressed.connect(open_page)
	paste_button = SKit.action(TI.SIGNIN_PASTE, "check", "Paste")
	paste_button.pressed.connect(paste)
	type_button = SKit.action(TI.SIGNIN_TYPE, "gamepad", "Type")
	type_button.pressed.connect(func():
		if ask_text.is_valid():
			ask_text.call(TI.SIGNIN_TYPE_HINT, "", func(t: String): submit(t)))
	for b in [open_button, paste_button, type_button]:
		b.custom_minimum_size = Vector2(0, 52)
		actions.add_child(b)
		buttons.append(b)
	add_child(actions)
	status = Kit.label("", "QuietLabel", true)
	status.name = "Status"
	add_child(status)
	if setup_svc != null:
		if setup_svc.has_signal("login_started") and not setup_svc.login_started.is_connected(_on_started):
			setup_svc.login_started.connect(_on_started)
		if setup_svc.has_signal("login_finished") and not setup_svc.login_finished.is_connected(_on_finished):
			setup_svc.login_finished.connect(_on_finished)
	_last_clip = _clip()


func start() -> void:
	state = "preparing"
	_say(TI.SIGNIN_PREPARING)
	if setup_svc == null or not setup_svc.has_method("start_login") or not setup_svc.start_login(store):
		if state == "preparing":
			state = "failed"
			_say(TI.SIGNIN_FAILED % "the store tool isn't available", "bad")


func stop() -> void:
	if setup_svc != null:
		if setup_svc.has_signal("login_started") and setup_svc.login_started.is_connected(_on_started):
			setup_svc.login_started.disconnect(_on_started)
		if setup_svc.has_signal("login_finished") and setup_svc.login_finished.is_connected(_on_finished):
			setup_svc.login_finished.disconnect(_on_finished)
		if state in ["waiting", "preparing"] and setup_svc.has_method("cancel_login"):
			setup_svc.cancel_login(store)


func open_page() -> void:
	if url != "":
		open_url.call(url)
		_say(TI.SIGNIN_WAITING)


func paste() -> void:
	var t := _clip().strip_edges()
	if t == "":
		_say(TI.SIGNIN_NO_CODE, "warn")
		return
	submit(t)


## The window got focus back: a freshly copied code finishes the sign-in.
func check_clipboard() -> bool:
	if state != "waiting":
		return false
	var t := _clip().strip_edges()
	if t == "" or t == _last_clip or not looks_like_code(store, t):
		return false
	_last_clip = t
	submit(t)
	return true


## Strict enough that nothing random from the clipboard is sent.
static func looks_like_code(which: String, text: String) -> bool:
	match which:
		"epic":
			return "authorizationCode" in text
		"gog":
			return "on_login_success" in text and "code=" in text
		"amazon":
			return "openid.oa2.authorization_code=" in text
	return false


func submit(text: String) -> void:
	if text.strip_edges() == "" or setup_svc == null:
		return
	state = "checking"
	_say(TI.SIGNIN_CHECKING)
	if not setup_svc.finish_login(store, text) and state == "checking":
		state = "waiting"
		_say(TI.SIGNIN_NO_CODE, "warn")


func first_focus() -> Control:
	return open_button


func _clip() -> String:
	return str(read_clipboard.call()) if read_clipboard.is_valid() else ""


func _on_started(which: String, info: Dictionary) -> void:
	if which != store:
		return
	url = str(info.get("url", ""))
	if url == "":
		state = "failed"
		_say(TS.store_line({"how": info.get("needs", "")}), "warn")
		return
	state = "waiting"
	_say(TI.SIGNIN_WAITING)


func _on_finished(which: String, ok: bool, message: String) -> void:
	if which != store:
		return
	state = "done" if ok else "waiting"
	if ok:
		_say(TI.SIGNIN_OK % TS.STORE_NAMES.get(store, store), "good")
	else:
		_say(TI.SIGNIN_FAILED % message, "bad")
	finished.emit(store, ok, message)


func _say(text: String, tone := "") -> void:
	if status == null:
		return
	status.text = text
	if tone != "":
		status.add_theme_color_override("font_color", ThemeLib.tone(tone))
	else:
		status.remove_theme_color_override("font_color")


func _exit_tree() -> void:
	stop()
