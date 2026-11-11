extends Node
## Everything you can do to a game besides playing it, as controller-friendly
## flows: install (with a drive picker), update, uninstall (confirmed), check
## files, move, launch options (on-screen keyboard), compatibility tool, Steam
## pages, and pause / resume / cancel / reorder for downloads. Calls Library's
## store API (or a fake with the same methods) and shows its `why` when an
## action can't run. Sheets and the keyboard go on `layer`.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Motion := preload("res://scripts/ui/motion.gd")
const TG := preload("res://scripts/ui/texts_games.gd")
const Sheet := preload("res://scripts/ui/games/sheet.gd")
const TextKeyboard := preload("res://scripts/ui/games/text_keyboard.gd")

## Steam settings that wait for a restart changed (count may be 0).
signal pending_changed(count: int)
## A sheet or the keyboard opened (true) or closed (false).
signal modal_changed(open: bool)
## The game page should open (from the downloads list).
signal open_game(game: Dictionary)

const LOW_FREE := 10 * 1024 * 1024 * 1024

var library: Object
## CollectionActions: Manage also lists favourite, collections and hide.
var collection_actions: Node
var state: Object
var storage: Object
var toast: Callable = func(_t, _i = "info", _tone = "", _d = ""): pass
var layer: Control
var sheet: Control
var keyboard_modal: Control
var keyboard: PanelContainer
var _kb_title: Label
var _kb_detail: Label
var _kb_done := Callable()
var _last_fail := ["", "", -100000]
var _focus_before: Control
var _kb_open := false


func setup(lib: Object, install_state: Object, toast_fn: Callable, sheet_layer: Control, storage_svc: Object = null) -> void:
	name = "GameActions"
	library = lib
	state = install_state
	toast = toast_fn
	layer = sheet_layer
	storage = storage_svc
	sheet = Sheet.new()
	sheet.closed.connect(func(): modal_changed.emit(false))
	layer.add_child(sheet)
	_build_keyboard()


func is_modal() -> bool:
	return (sheet != null and sheet.is_open()) or _kb_open


## Hints for whatever modal is open, [] when none.
func modal_hints() -> Array:
	if _kb_open:
		return [["A", "Type"], ["Y", "Space"], ["X", "Delete"], ["B", "Cancel"], ["MENU", "Done"]]
	if sheet != null and sheet.is_open():
		return Sheet.hints()
	return []


func caps(game: Dictionary) -> Dictionary:
	return library.capabilities(game) if library != null else {}


func _title(game: Dictionary) -> String:
	return str(game.get("title", ""))


## Shows the result of a store call: a toast when it couldn't run, a short
## "Installing X" when it started. Returns ok.
func report(res: Dictionary, game: Dictionary, action: String, quiet_ok := false) -> bool:
	var ok: bool = res.get("ok", false)
	if not ok:
		_last_fail = [str(game.get("key", "")), action, Time.get_ticks_msec()]
		toast.call(TG.failed(action, _title(game)), "alert", "bad", str(res.get("why", "")))
	elif not quiet_ok and TG.STARTED.has(action):
		toast.call(TG.STARTED[action] % _title(game), "download" if action in ["install", "update"] else "info", "", "")
	return ok


## main.gd asks before toasting Library.action_failed: false when we just
## showed the same failure from the call's own result.
func should_toast_failure(key: String, action: String) -> bool:
	return not (_last_fail[0] == key and _last_fail[1] == action and Time.get_ticks_msec() - int(_last_fail[2]) < 3000)


# ------------------------------------------------------------ install / move

## Where a game can go: [{"path", "label", "free", "removable"}]. Steam games
## use Steam's library folders (Storage); others Library.install_locations().
func locations_for(game: Dictionary) -> Array:
	if str(game.get("store", "")) == "steam":
		var out: Array = []
		if storage != null and storage.has_method("state"):
			var st: Dictionary = storage.state()
			for lib in st.get("libraries", []):
				if str(lib.get("store", "")) == "steam":
					var p := str(lib.get("path", ""))
					out.append({"path": p, "label": TG.INTERNAL if not p.begins_with("/run/media") else p.get_file(),
						"free": int(lib.get("free", -1)), "removable": p.begins_with("/run/media")})
			if not st.get("ready", false) and storage.has_method("refresh"):
				storage.refresh()
		return out
	return library.install_locations() if library != null else []


static func location_rows(locs: Array, current_path := "") -> Array:
	var rows: Array = []
	for l in locs:
		var free := int(l.get("free", -1))
		var removable: bool = l.get("removable", false)
		var label := str(l.get("label", ""))
		if label == "" or label == "Internal":
			label = TG.INTERNAL
		var detail := str(l.get("path", ""))
		var low := free >= 0 and free < LOW_FREE
		if low:
			detail = TG.LOW_SPACE + " · " + detail
		rows.append({"id": str(l.get("path", "")), "text": label, "detail": detail,
			"icon": "sdcard" if removable else "drive", "value": (TG.bytes(free) + " free") if free >= 0 else "",
			"tone": "warn" if low else "", "current": current_path != "" and str(l.get("path", "")) == current_path})
	return rows


func install(game: Dictionary) -> void:
	var c := caps(game)
	if not c.get("install", false):
		toast.call(TG.failed("install", _title(game)), "alert", "warn", TG.why(c, "install"))
		return
	var locs := locations_for(game)
	if locs.size() <= 1:
		var opts := {}
		if locs.size() == 1 and str(game.get("store", "")) != "steam":
			opts["path"] = locs[0]["path"]
		report(library.install(game, opts), game, "install")
		return
	open_menu(TG.WHERE_TITLE, TG.WHERE_SUB, location_rows(locs), func(path: String):
		report(library.install(game, {"path": path}), game, "install"))


func move(game: Dictionary) -> void:
	var c := caps(game)
	if not c.get("move", false):
		toast.call(TG.failed("move", _title(game)), "alert", "warn", TG.why(c, "move"))
		return
	var locs := locations_for(game)
	if locs.is_empty():
		toast.call(TG.failed("move", _title(game)), "alert", "warn", "No other drive found. Put in an SD card or USB drive first.")
		return
	open_menu(TG.MOVE_TITLE, TG.MOVE_SUB, location_rows(locs), func(path: String):
		report(library.move(game, path), game, "move"))


func update(game: Dictionary) -> void:
	report(library.update(game), game, "update")


func verify(game: Dictionary) -> void:
	report(library.verify(game), game, "verify")


func uninstall(game: Dictionary) -> void:
	open_menu(TG.CONFIRM_UNINSTALL % _title(game), TG.CONFIRM_UNINSTALL_SUB, [
		{"id": "no", "text": TG.CONFIRM_NO, "icon": "chevron_left", "current": true},
		{"id": "yes", "text": TG.CONFIRM_YES, "icon": "trash", "tone": "bad"},
	], func(id: String):
		if id == "yes":
			report(library.uninstall(game), game, "uninstall"))


func pause(game: Dictionary) -> void:
	report(library.pause(game), game, "pause", true)


func resume(game: Dictionary) -> void:
	report(library.resume(game), game, "resume", true)


func cancel(game: Dictionary) -> void:
	open_menu(TG.CONFIRM_CANCEL % _title(game), TG.CONFIRM_CANCEL_SUB, [
		{"id": "no", "text": TG.CONFIRM_CANCEL_NO, "icon": "download", "current": true},
		{"id": "yes", "text": TG.CONFIRM_CANCEL_YES, "icon": "x", "tone": "bad"},
	], func(id: String):
		if id == "yes":
			report(library.cancel(game), game, "cancel", true))


func reorder(game: Dictionary, delta: int) -> bool:
	return library.reorder_download(game, delta) if library != null else false


func toggle_pause(game: Dictionary) -> void:
	if state != null and state.state_of(str(game.get("key", ""))) == "paused":
		resume(game)
	else:
		pause(game)


# ------------------------------------------------------------ launch options / compat

func launch_options(game: Dictionary) -> void:
	var c := caps(game)
	if not c.get("launch_options", false):
		toast.call(TG.failed("launch_options", _title(game)), "alert", "warn", TG.why(c, "launch_options"))
		return
	if library.has_method("launch_options_async"):
		library.launch_options_async(game, func(cur: Variant): _launch_options_with(game, str(cur)))
	else:
		_launch_options_with(game, library.launch_options(game))


func _launch_options_with(game: Dictionary, current: String) -> void:
	var steam := str(game.get("store", "")) == "steam"
	open_keyboard(TG.LAUNCH_OPTIONS + " · " + _title(game),
		(TG.LAUNCH_OPTIONS_DETAIL_STEAM + " " + TG.LAUNCH_OPTIONS_HOWTO_STEAM + " " + TG.LAUNCH_OPTIONS_EXAMPLE_STEAM) if steam
			else (TG.LAUNCH_OPTIONS_DETAIL + " " + TG.LAUNCH_OPTIONS_EXAMPLE),
		current, func(text: String):
			if text == current:
				return
			_saved(library.set_launch_options(game, text), game, "launch_options"))


func compat_tool(game: Dictionary) -> void:
	var c := caps(game)
	if not c.get("compat_tool", false):
		toast.call(TG.failed("compat_tool", _title(game)), "alert", "warn", TG.why(c, "compat_tool"))
		return
	if library.has_method("compat_tool_async") and library.has_method("compat_tools_async"):
		library.compat_tool_async(game, func(cur: Variant):
			library.compat_tools_async(game, func(tools: Variant): _compat_tool_with(game, str(cur), tools)))
	else:
		_compat_tool_with(game, library.compat_tool(game), library.compat_tools(game))


func _compat_tool_with(game: Dictionary, current: String, tools: Array) -> void:
	var rows: Array = []
	for t in tools:
		var id := str(t.get("id", ""))
		rows.append({"id": id, "text": str(t.get("name", id)), "detail": "Recommended for most games" if id == "" else "",
			"icon": "layers", "current": id == current})
	open_menu(TG.COMPAT_TITLE, TG.COMPAT_DETAIL, rows, func(id: String):
		if id != current:
			_saved(library.set_compat_tool(game, id), game, "compat_tool"))


func _saved(res: Dictionary, game: Dictionary, action: String) -> void:
	if not res.get("ok", false):
		report(res, game, action)
		return
	var pending: bool = res.get("pending", false) or str(res.get("via", "")) == "steam-files-after-restart"
	toast.call(TG.SAVED_PENDING if pending else TG.SAVED, "check", "good" if not pending else "", "")
	pending_changed.emit(pending_count())


func pending_count() -> int:
	if library == null:
		return 0
	return int(library.store_settings().get("steam_pending_count", 0))


func restart_steam() -> void:
	var res: Dictionary = library.apply_pending_steam_changes(true)
	if res.get("ok", false):
		toast.call(TG.RESTARTING, "restart", "", "")
	else:
		toast.call(TG.RESTART_STEAM, "alert", "bad", str(res.get("why", "")))
	pending_changed.emit(pending_count())


func open_steam(game: Dictionary, page: String) -> void:
	var res: Dictionary = library.open_steam_page(game, page)
	if not res.get("ok", false):
		toast.call("Couldn't open Steam", "alert", "bad", str(res.get("why", "")))


# ------------------------------------------------------------ manage menu

## The Manage menu's rows for a game: [{"id", "text", "detail", "icon", "tone", "disabled"}].
## Rows whose reason only says "it's in the other state" are left out; other
## unavailable rows stay, greyed, with the store's reason as their detail.
static func manage_rows(game: Dictionary, c: Dictionary, st: String) -> Array:
	var rows: Array = []
	if str(game.get("store", "")) == "emu":
		return rows   # EmuDeck / RetroDECK / Steam ROM Manager manage these (the Emulation page)
	var installed: bool = game.get("installed", false)
	var steam := str(game.get("store", "")) == "steam"
	var busy := st in TG.BUSY
	var add := func(id: String, cap: String, text: String, detail: String, icon: String, tone := "") -> void:
		if cap == "" or c.get(cap, false):
			rows.append({"id": id, "text": text, "detail": detail, "icon": icon, "tone": tone, "disabled": false})
			return
		var w := TG.why(c, cap)
		if TG.is_state_reason(w):
			return
		rows.append({"id": id, "text": text, "detail": w, "icon": icon, "tone": "", "disabled": true})
	if busy:
		if st == "paused":
			add.call("resume", "resume", TG.RESUME, "", "play")
		else:
			add.call("pause", "pause", TG.PAUSE, "", "pause")
		add.call("cancel", "cancel", TG.CANCEL_DOWNLOAD, TG.CANCEL_DETAIL, "x")
	if installed:
		if st != "update_required" and not busy:
			add.call("update", "update", TG.UPDATE, TG.UPDATE_DETAIL, "update")
		if not busy:
			add.call("verify", "verify", TG.VERIFY, TG.VERIFY_DETAIL, "wrench")
			add.call("move", "move", TG.MOVE, TG.MOVE_DETAIL, "folder_move")
	add.call("launch_options", "launch_options", TG.LAUNCH_OPTIONS,
		TG.LAUNCH_OPTIONS_DETAIL_STEAM if steam else TG.LAUNCH_OPTIONS_DETAIL, "terminal")
	add.call("compat_tool", "compat_tool", TG.COMPAT, TG.COMPAT_DETAIL, "layers")
	if steam:
		rows.append({"id": "steam_store", "text": TG.STEAM_STORE, "detail": TG.STEAM_STORE_DETAIL, "icon": "external", "tone": "", "disabled": false})
		if installed:
			rows.append({"id": "steam_properties", "text": TG.STEAM_PROPS, "detail": TG.STEAM_PROPS_DETAIL, "icon": "external", "tone": "", "disabled": false})
	if installed and not busy:
		add.call("uninstall", "uninstall", TG.UNINSTALL, TG.UNINSTALL_DETAIL, "trash", "bad")
	return rows


func manage(game: Dictionary) -> void:
	var st: String = state.state_of(str(game.get("key", ""))) if state != null else ""
	var rows := manage_rows(game, caps(game), st)
	if collection_actions != null:
		rows = collection_actions.game_rows(game, false) + rows
	open_menu(TG.MANAGE, _title(game), rows, func(id: String): run(id, game))


## Runs a Manage row (also used by tests and the downloads list).
func run(id: String, game: Dictionary) -> void:
	match id:
		"install": install(game)
		"update": update(game)
		"verify": verify(game)
		"move": move(game)
		"uninstall": uninstall(game)
		"pause": pause(game)
		"resume": resume(game)
		"cancel": cancel(game)
		"launch_options": launch_options(game)
		"compat_tool": compat_tool(game)
		"steam_store": open_steam(game, "store")
		"steam_properties": open_steam(game, "properties")
		"steam_downloads": open_steam(game, "downloads")
		"page": open_game.emit(game)
		"up": reorder(game, -1)
		"down": reorder(game, 1)
		_:
			if collection_actions != null:
				collection_actions.run(id, game)


# ------------------------------------------------------------ modals

func open_menu(title: String, sub: String, rows: Array, cb: Callable) -> void:
	sheet.open(title, sub, rows, cb)
	modal_changed.emit(true)


func _build_keyboard() -> void:
	keyboard_modal = Control.new()
	keyboard_modal.name = "TextEntry"
	keyboard_modal.set_anchors_preset(Control.PRESET_FULL_RECT)
	keyboard_modal.mouse_filter = Control.MOUSE_FILTER_STOP
	keyboard_modal.visible = false
	keyboard_modal.z_index = Sheet.Z + 1    # over a sheet, like it (and the hint bar under both)
	var dim := ColorRect.new()
	dim.name = "Dim"
	Kit.fill(dim)
	dim.color = Color(ThemeLib.color("scrim"), 0.78)
	keyboard_modal.add_child(dim)
	keyboard = TextKeyboard.new()
	# Title and explanation inside the keyboard's own sheet, above the field.
	var head := Kit.vbox(2)
	head.name = "Head"
	_kb_title = Kit.label("", "HeaderLabel")
	head.add_child(_kb_title)
	_kb_detail = Kit.label("", "QuietLabel", true)
	_kb_detail.custom_minimum_size = Vector2(780, 0)
	head.add_child(_kb_detail)
	var kcol: Control = keyboard.get_child(0)
	kcol.add_child(head)
	kcol.move_child(head, 0)
	keyboard.anchor_left = 0.5
	keyboard.anchor_right = 0.5
	keyboard.anchor_top = 1.0
	keyboard.anchor_bottom = 1.0
	keyboard.offset_left = -430
	keyboard.offset_right = 430
	keyboard.offset_top = -560
	keyboard.offset_bottom = -64
	keyboard.closed.connect(_on_keyboard_closed)
	keyboard_modal.add_child(keyboard)
	layer.add_child(keyboard_modal)


func open_keyboard(title: String, detail: String, text: String, done: Callable) -> void:
	_kb_title.text = title
	_kb_detail.text = detail
	_kb_done = done
	keyboard.placeholder = "Empty"
	if keyboard_modal.is_inside_tree():
		_focus_before = keyboard_modal.get_viewport().gui_get_focus_owner()
	_kb_open = true
	Motion.fade(keyboard_modal, true)
	keyboard.open(text)
	modal_changed.emit(true)


func _on_keyboard_closed(text: String) -> void:
	_kb_open = false
	Motion.fade(keyboard_modal, false)
	var cb := _kb_done
	_kb_done = Callable()
	modal_changed.emit(false)
	if _focus_before != null and is_instance_valid(_focus_before) and _focus_before.is_visible_in_tree():
		_focus_before.grab_focus()
	if cb.is_valid():
		cb.call(text)
