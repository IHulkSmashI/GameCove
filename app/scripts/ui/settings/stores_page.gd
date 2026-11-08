extends "res://scripts/ui/settings/page.gd"
## Stores: who's signed in (and QR sign-in), downloads, and Steam control.
## Services: "setup" (store_status, start_login…) and "library"
## (store_settings, set_store_setting, install_locations,
## apply_pending_steam_changes, signal store_settings_changed).


func _connect() -> void:
	var lib := svc("library")
	if lib != null and lib.has_signal("store_settings_changed"):
		lib.store_settings_changed.connect(_later_rebuild)
	var st := svc("setup")
	if st != null and st.has_signal("login_finished"):
		st.login_finished.connect(func(_s, ok, _m):
			if ok:
				_later_rebuild())


func _later_rebuild() -> void:
	if is_inside_tree():
		rebuild.call_deferred()
	else:
		rebuild()


func build() -> void:
	_build_sign_in()
	var lib := svc("library")
	if not SvcLib.has_all(lib, ["store_settings", "set_store_setting"]):
		return
	var s: Dictionary = lib.store_settings()
	if s.is_empty():
		return
	_build_downloads(lib, s)
	_build_steam(lib, s)


const SvcLib := preload("res://scripts/ui/settings/services.gd")


func _build_sign_in() -> void:
	var st := svc("setup")
	var box := add_card("Accounts", "store", "Each store's games show up in your library once you're signed in.")
	if st == null or not st.has_method("store_status"):
		box.add_child(SKit.note("Store sign-in isn't available in this build.", "info"))
		return
	var status: Dictionary = st.store_status()
	for store in TS.STORE_ORDER:
		var info: Dictionary = status.get(store, {})
		var signed: bool = info.get("signed_in", false)
		var can: bool = TS.can_sign_in(info)
		var value: String = TS.SIGNED_IN if signed else (TS.SIGN_IN if can else TS.NOT_SIGNED_IN)
		var r: VBoxContainer = action_row(box, "store_" + store, TS.STORE_NAMES[store], value, TS.store_line(info), "")
		r.collapse_hint = false
		r.set_hint(TS.store_line(info))
		r.set_value(value, "good" if signed else ("" if can else "muted"))
		if can:
			r.pressed.connect(func(): host.open_sign_in(store))


func _build_downloads(lib: Object, s: Dictionary) -> void:
	var box := add_card("Downloads", "download")
	var locs: Array = lib.install_locations() if lib.has_method("install_locations") else []
	var root := str(s.get("install_root", ""))
	var paths: Array = []
	var labels: Array = []
	for l in locs:
		paths.append(str(l["path"]))
		labels.append(_loc_label(l))
	if root != "" and not root in paths:
		paths.insert(0, root)
		labels.insert(0, root.get_file() if root.get_file() != "" else root)
	if not paths.is_empty():
		var r := choice(box, "install_root", TS.INSTALL_FOLDER, paths, labels, root,
			func(v): return "%s  %s" % [str(v), TS.INSTALL_FOLDER_HELP], "download")
		r.changed.connect(func(v): _store_set(lib, "install_root", v))
	var a := toggle(box, "auto_resume", TS.AUTO_RESUME, bool(s.get("auto_resume", true)), by_value(TS.AUTO_RESUME_HELP), "update")
	a.changed.connect(func(v): _store_set(lib, "auto_resume", v))
	var p := choice(box, "max_parallel", TS.PARALLEL, [1, 2, 3, 4], ["1", "2", "3", "4"], int(s.get("max_parallel", 1)), fixed(TS.PARALLEL_HELP), "sort")
	p.changed.connect(func(v): _store_set(lib, "max_parallel", v))


static func _loc_label(l: Dictionary) -> String:
	var free := int(l.get("free", -1))
	var name_: String = str(l.get("label", "Folder"))
	if free > 0:
		return "%s, %s free" % [name_, String.humanize_size(free).replace("i", "")]
	return name_


func _build_steam(lib: Object, s: Dictionary) -> void:
	var box := add_card("Steam", "game")
	var on := bool(s.get("steam_cef", false))
	var c := toggle(box, "steam_cef", TS.STEAM_CONTROL, on, by_value(TS.STEAM_CONTROL_HELP), "shield_alert")
	c.changed.connect(func(v): _store_set(lib, "steam_cef", v))
	box.add_child(SKit.note(TS.STEAM_CONTROL_WARNING, "warn", "SteamWarning"))
	if on:
		var st := str(s.get("steam_cef_status", "off"))
		var line := Kit.label(TS.STEAM_CEF_STATUS.get(st, st), "AccentLabel", true)
		line.name = "SteamStatus"
		line.add_theme_color_override("font_color", ThemeLib.tone({"ready": "good", "unreachable": "bad", "flag_missing": "warn"}.get(st, "info")))
		box.add_child(line)
	var f := toggle(box, "focus_steam_dialogs", TS.FOCUS_DIALOGS, bool(s.get("focus_steam_dialogs", true)), by_value(TS.FOCUS_DIALOGS_HELP), "screen")
	f.changed.connect(func(v): _store_set(lib, "focus_steam_dialogs", v))
	var pending := int(s.get("steam_pending_count", 0))
	if pending > 0 or str(s.get("steam_cef_status", "")) == "flag_missing":
		if pending > 0:
			box.add_child(SKit.note(TS.pending_line(pending), "info", "SteamPending"))
		var b := SKit.action(TS.STEAM_RESTART, "update", "RestartSteam")
		b.pressed.connect(func():
			var r: Dictionary = lib.apply_pending_steam_changes(true)
			notify(TS.STEAM_RESTARTING if r.get("ok", false) else str(r.get("why", "")), "" if r.get("ok", false) else "bad"))
		add_focusable(box, b)


func _store_set(lib: Object, key: String, value: Variant) -> void:
	if not lib.set_store_setting(key, value):
		notify("Couldn't change that setting.", "bad")
		_later_rebuild()
