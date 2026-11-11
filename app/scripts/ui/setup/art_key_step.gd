extends HBoxContainer
## The Game art step: getting the user's own free SteamGridDB key onto the
## handheld with a controller. Used by first-run setup (setup_flow.gd), the
## installer (installer_screen.gd) and Settings > Discover > SteamGridDB key
## (which opens setup at this step). GameCove ships no key of its own.
##
## On screen: a QR code and four short steps. Choosing "Send from my phone" turns
## the QR into a one-time page GameCove serves on your own network
## (scripts/system/key_drop.gd): the phone signs in to SteamGridDB with Steam,
## generates a key, pastes it on that page and taps Send; the key arrives here by
## itself. That page only ever opens on that press (final review, low: it used
## to open, and listen on the network, as soon as this step was shown). Until
## then, and after "Phone not on this Wi-Fi?", the QR is SteamGridDB's own API
## page and the key is typed (on-screen or Steam keyboard) or pasted. The installer, on the
## desktop, also opens the page in the browser and picks a copied key up from
## the clipboard when its window gets focus back.
##
## Every key is checked with one SteamGridDB request (sgdb.gd check_url) and
## saved only if it works: Setup.set_steamgriddb_key + Discover.set_settings
## (both 0600 files), or `save_fn` (the installer keeps it in its plan). Then
## the library's automatic art fill runs, so missing covers, heroes and logos
## appear right away.
##
##   var step := ArtKeyStep.new()
##   step.configure({"setup": Setup, "discover": Discover, "library": Library, "ask_text": ask_text})
##   add_child(step); step.start()
##   for b in step.buttons: focusables.append(b)
##   step.saved.connect(func(_k): setup.complete("steamgriddb"))

const Kit := preload("res://scripts/ui/ui_kit.gd")
const SKit := preload("res://scripts/ui/settings/kit.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const QR := preload("res://scripts/ui/settings/qr.gd")
const TS := preload("res://scripts/ui/texts_settings.gd")
const Sgdb := preload("res://scripts/library/art/sgdb.gd")
const Privacy := preload("res://scripts/system/privacy.gd")
const KeyDrop := preload("res://scripts/system/key_drop.gd")

## A key SteamGridDB accepted was saved.
signal saved(key: String)

const TITLE := "Game art"
const LINE := "Covers, banners and logos for every game, Steam or not, from SteamGridDB's community. It's free and takes about a minute: sign in with Steam on your phone and send GameCove your key."
const SKIP_TEXT := "Skip, use Steam art only"
const STEPS_PHONE := [
	"Scan the code with your phone's camera.",
	"Tap Open SteamGridDB and sign in with Steam.",
	"Tap Generate API key and copy the key.",
	"Back on the GameCove page, paste it and tap Send. It lands here by itself.",
]
const STEPS_DIRECT := [
	"Scan the code to open SteamGridDB's API page on your phone.",
	"Sign in with Steam.",
	"Tap Generate API key.",
	"Choose Type the key and enter it here (32 letters and digits).",
]
const STEPS_DESKTOP_LAST := "Copy the key: GameCove picks it up when you come back to this window (or choose Paste)."
const TYPE := "Type the key"
const PASTE := "Paste"
const OPEN_HERE := "Open the page here"
const TO_DIRECT := "Phone not on this Wi-Fi?"
const TO_PHONE := "Send from my phone"
const REMOVE := "Remove key"
const SAY := {
	"start": "Choose Send from my phone and this code becomes a one-time page on your own network: paste the key there and it lands here by itself. Or type or paste it.",
	"phone": "Waiting for your phone. The page works for 10 minutes, on your own network only.",
	"direct": "Type or paste the key when you have it.",
	"no_lan": "This handheld isn't on a network your phone can reach, so type or paste the key instead.",
	"expired": "The phone page closed after 10 minutes. Choose Send from my phone for a new code.",
	"checking": "Checking the key with SteamGridDB…",
	"ok": "That key works. Saved.",
	"wrong": "SteamGridDB doesn't accept that key. Copy it again (Generate API key makes a new one) and send it.",
	"offline": "No internet connection, so the key couldn't be checked. Connect and send it again.",
	"error": "SteamGridDB didn't answer properly (%s). Try again in a minute.",
	"privacy": "Look up game details is off (Settings > About > Network and privacy), so GameCove can't check or use the key. Turn it on and try again.",
	"format": "That doesn't look like a SteamGridDB key: it's 32 letters and digits.",
	"has_key": "You already have a key (%s). Send a new one to replace it, or remove it.",
	"removed": "Key removed. GameCove uses Steam's art only.",
}
const FILL_LINE := " Finding art for %d games now."
const FILL_LATER := " GameCove fills in missing art when it starts."

var setup_svc: Object
var discover: Object
var library: Object
var http: Variant = null
## func(placeholder, start, done: Callable(text)) from the host (its keyboard).
var ask_text: Callable
## func(key: String): where a checked key goes instead of Setup / Discover (installer).
var save_fn: Callable
## func(url): opens SteamGridDB's page on this screen (installer, desktop only).
var open_url: Callable
## func() -> String: the clipboard ("" when there's none, e.g. no clipboard in this session).
var read_clipboard: Callable
var prefs_path := Privacy.PREFS_PATH
## func() -> Array: the network interfaces KeyDrop picks its LAN address from (tests).
var lan_fn: Callable

var drop: Node
## idle | phone | direct | checking | ok | wrong | offline | error | privacy
var state := "idle"
## phone: the QR opens GameCove's page; direct: SteamGridDB's own page.
var mode := "phone"
var current_key := ""
var fill_count := -1
var qr_rect: TextureRect
var steps_box: VBoxContainer
var status: Label
var url_label: Label
var type_button: Button
var paste_button: Button
var open_button: Button
var switch_button: Button
var remove_button: Button
## The step's focusable buttons, left to right in one row that wraps where
## the screen is narrow (hosts link them left / right; up / down leave it).
var buttons: Array = []
var _pending := ""
var _last_clip := ""


## opts: {"setup", "discover", "library", "http", "ask_text", "save_fn", "open_url",
## "read_clipboard", "current", "prefs_path", "lan"}. Builds the controls.
func configure(opts: Dictionary) -> void:
	name = "ArtKeyStep"
	setup_svc = opts.get("setup")
	discover = opts.get("discover")
	library = opts.get("library")
	http = opts.get("http", null)
	ask_text = opts.get("ask_text", Callable())
	save_fn = opts.get("save_fn", Callable())
	open_url = opts.get("open_url", Callable())
	read_clipboard = opts.get("read_clipboard", Callable())
	prefs_path = str(opts.get("prefs_path", Privacy.PREFS_PATH))
	lan_fn = opts.get("lan", Callable())
	current_key = str(opts.get("current", _saved_key()))
	if http == null and discover != null and discover.get("http") != null:
		http = discover.get("http")
	_build()


func _saved_key() -> String:
	var k := ""
	if discover != null and discover.has_method("get_settings"):
		k = str(discover.get_settings().get("steamgriddb_key", ""))
	if k == "" and setup_svc != null and setup_svc.has_method("steamgriddb_key"):
		k = str(setup_svc.steamgriddb_key())
	return k


func _build() -> void:
	add_theme_constant_override("separation", 28)
	var qcol := Kit.vbox(8)
	qcol.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	var frame := PanelContainer.new()
	frame.name = "QRFrame"
	frame.add_theme_stylebox_override("panel", ThemeLib.box(Color.WHITE, ThemeLib.radius("l"), 10, 10))
	frame.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	qr_rect = TextureRect.new()
	qr_rect.name = "QR"
	qr_rect.custom_minimum_size = Vector2(232, 232)
	qr_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	qr_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	qr_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	frame.add_child(qr_rect)
	qcol.add_child(frame)
	# One line under the code: "192.168.1.42:34453 · one-time page" (mono, no wrap).
	url_label = Kit.label("", "MonoLabel", false)
	url_label.name = "Url"
	url_label.add_theme_color_override("font_color", ThemeLib.color("text_2"))
	url_label.add_theme_font_size_override("font_size", ThemeLib.SIZE_CAPTION - 1)
	qcol.add_child(url_label)
	add_child(qcol)

	var col := Kit.vbox(12)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_FILL
	add_child(col)
	steps_box = Kit.vbox(8)
	steps_box.name = "Steps"
	col.add_child(steps_box)
	status = Kit.label("", "AccentLabel", true)
	status.name = "Status"
	col.add_child(status)
	# The fallbacks: secondary pills side by side under the steps (the QR is
	# the main way; none of these is styled as the primary). They wrap onto a
	# second line only where the screen is too narrow for one.
	var bcol := HFlowContainer.new()
	bcol.name = "Actions"
	bcol.add_theme_constant_override("h_separation", 12)
	bcol.add_theme_constant_override("v_separation", 10)
	col.add_child(bcol)
	# first in the row: it is what starts the easy way, and where the focus goes
	switch_button = _action(bcol, TO_PHONE, "wifi", "SwitchMode", toggle_mode)
	type_button = _action(bcol, TYPE, "gamepad", "TypeKey", _on_type)
	if read_clipboard.is_valid() or DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
		paste_button = _action(bcol, PASTE, "check", "PasteKey", paste)
	if open_url.is_valid():
		open_button = _action(bcol, OPEN_HERE, "rocket", "OpenHere", func(): open_url.call(Sgdb.API_KEY_PAGE))
	if current_key != "":
		remove_button = _action(bcol, REMOVE, "x", "RemoveKey", remove_key)


func _action(box: Control, text: String, icon: String, node_name: String, fn: Callable) -> Button:
	var b := SKit.action(text, icon, node_name)
	b.custom_minimum_size = Vector2(0, 48)
	b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	b.pressed.connect(fn)
	box.add_child(b)
	buttons.append(b)
	return b


## Shows the step. Nothing listens yet: the QR is SteamGridDB's own page, and the phone page
## opens when "Send from my phone" is pressed (toggle_mode).
func start() -> void:
	_last_clip = _clip()
	mode = "direct"
	_show_mode()
	_set_state("direct", SAY["has_key"] % TS.masked(current_key) if current_key != "" else SAY["start"])


func _open_phone() -> void:
	_ensure_drop()
	if drop.start():
		mode = "phone"
		_show_mode()
		_set_state("phone", SAY["has_key"] % TS.masked(current_key) if current_key != "" else SAY["phone"])
	else:
		mode = "direct"
		_show_mode()
		_set_state("direct", SAY["no_lan"])


func _ensure_drop() -> void:
	if drop != null:
		return
	drop = KeyDrop.new()
	if lan_fn.is_valid():
		drop.interfaces_fn = lan_fn
	drop.key_received.connect(func(k: String): submit(k))
	drop.expired.connect(_on_expired)
	add_child(drop)


## Closes the phone page (leaving the step).
func stop() -> void:
	if drop != null:
		drop.stop()


func _show_mode() -> void:
	var url: String = drop.url if mode == "phone" and drop != null and drop.is_running() else Sgdb.API_KEY_PAGE
	QR.show_on(qr_rect, url, 6)
	url_label.text = url.replace("https://www.", "").replace("http://", "")
	if mode == "phone" and drop != null and drop.is_running():
		url_label.text = url_label.text.get_slice("/k/", 0) + " · one-time page"
	for c in steps_box.get_children():
		Kit.drop(steps_box, c)
	var lines: Array = (STEPS_PHONE if mode == "phone" else STEPS_DIRECT).duplicate()
	if mode == "direct" and open_url.is_valid():
		lines[0] = "Choose Open the page here, or scan the code to open it on your phone."
		lines[3] = STEPS_DESKTOP_LAST
	for i in lines.size():
		var row := Kit.hbox(12)
		var num := Kit.badge(str(i + 1), "info")
		num.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		row.add_child(num)
		var l := Kit.label(lines[i], "", true)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(l)
		steps_box.add_child(row)
	switch_button.text = TO_DIRECT if mode == "phone" else TO_PHONE


## Phone page <-> SteamGridDB's own page.
func toggle_mode() -> void:
	if mode == "phone":
		stop()
		mode = "direct"
		_show_mode()
		_set_state("direct", SAY["direct"])
	else:
		_open_phone()


func _on_expired(why: String) -> void:
	mode = "direct"
	_show_mode()
	_set_state("direct", SAY["expired"] if why == "timeout" else SAY["direct"])


func _on_type() -> void:
	if ask_text.is_valid() and state != "checking":
		ask_text.call(TYPE, _pending, func(t: String):
			if t.strip_edges() != "":
				submit(t))


func paste() -> void:
	var t := _clip().strip_edges()
	if t == "":
		_set_state(state, "The clipboard is empty. Copy the key first.", "warn")
		return
	submit(t)


## The window got focus back (installer): a freshly copied key is sent by itself.
func check_clipboard() -> bool:
	if state in ["checking", "ok"]:
		return false
	var t := _clip().strip_edges()
	if t == "" or t == _last_clip:
		return false
	_last_clip = t
	var k := KeyDrop.key_from_form("key=" + t.uri_encode())
	if k == "":
		return false
	submit(k)
	return true


func _clip() -> String:
	if read_clipboard.is_valid():
		return str(read_clipboard.call())
	return DisplayServer.clipboard_get() if DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD) else ""


## Checks `text` with SteamGridDB and saves it if it works.
func submit(text: String) -> void:
	if state == "checking":
		return
	var k := KeyDrop.key_from_form("key=" + text.strip_edges().uri_encode())
	if k == "":
		_set_state(state if state != "idle" else "direct", SAY["format"], "bad")
		return
	_pending = k
	if not Privacy.metadata_allowed(prefs_path):
		_fail("privacy", SAY["privacy"])
		return
	if http == null:
		var node: Node = load("res://scripts/discover/http.gd").new()
		node.name = "Http"
		add_child(node)
		http = node
	_set_state("checking", SAY["checking"])
	http.request(Sgdb.check_url(), {"headers": Sgdb.headers(k), "timeout": 15.0, "max_bytes": 256 * 1024}, _answer_to(weakref(self), k))


## The answer's callback holds the step weakly: leaving the step while the check runs is fine.
static func _answer_to(me: WeakRef, k: String) -> Callable:
	return func(res: Dictionary):
		var step: Object = me.get_ref()
		if step != null:
			step._on_checked(k, Sgdb.check_result(res), str(res.get("error", "")))


func _on_checked(k: String, result: String, err: String) -> void:
	match result:
		"ok":
			_save(k)
		"wrong":
			_fail("wrong", SAY["wrong"])
		"offline":
			_fail("offline", SAY["offline"])
		_:
			_fail("error", SAY["error"] % (err if err != "" else "unexpected answer"))


## A failed check: say why; reopen the phone page with a new code so the key can be sent again.
func _fail(s: String, line: String) -> void:
	if mode == "phone" and (drop == null or not drop.is_running()):
		_ensure_drop()
		if not drop.start():
			mode = "direct"
		_show_mode()
	_set_state(s, line, "bad")


func _save(k: String) -> void:
	stop()
	current_key = k
	_pending = ""
	var line: String = SAY["ok"]
	if save_fn.is_valid():
		save_fn.call(k)
		line += FILL_LATER
	else:
		if setup_svc != null and setup_svc.has_method("set_steamgriddb_key"):
			setup_svc.set_steamgriddb_key(k)
		if discover != null and discover.has_method("set_settings"):
			discover.set_settings({"steamgriddb_key": k})
		fill_count = fill_missing_art()
		if fill_count > 0:
			line += FILL_LINE % fill_count
	_set_state("ok", line, "good")
	saved.emit(k)


## The library's automatic art fill, now that there's a key. Returns how many
## missing pictures it queued (-1: no library here).
func fill_missing_art() -> int:
	var art: Variant = library.get("artwork") if library != null else null
	if art == null or not art.has_method("auto_fill"):
		return -1
	var games: Variant = library.get("games")
	return int(art.auto_fill(games if games is Array else []))


func remove_key() -> void:
	if save_fn.is_valid():
		save_fn.call("")
	else:
		if setup_svc != null and setup_svc.has_method("set_steamgriddb_key"):
			setup_svc.set_steamgriddb_key("")
		if discover != null and discover.has_method("set_settings"):
			discover.set_settings({"steamgriddb_key": ""})
	current_key = ""
	if remove_button != null:
		remove_button.disabled = true
	_set_state(state if state != "ok" else "direct", SAY["removed"])


func first_focus() -> Control:
	return switch_button


## True once a key that works is saved (or one was already): the host's Next
## only shows then; Skip moves on without one.
func has_key() -> bool:
	return current_key != "" and state != "checking"


func _set_state(s: String, line: String, tone := "") -> void:
	state = s
	status.text = line
	if tone != "":
		status.add_theme_color_override("font_color", ThemeLib.tone(tone))
	else:
		status.add_theme_color_override("font_color", ThemeLib.color("accent"))
	type_button.disabled = s == "checking"


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		stop()
