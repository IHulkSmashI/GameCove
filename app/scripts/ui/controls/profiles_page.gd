extends "res://scripts/ui/settings/page.gd"
## Settings > Profiles: what Profiles keeps on this handheld and the tools
## for it. Everyday / On battery / Plugged in, then one row per game with its
## own settings, then Backup (export / import a JSON file). A on a row opens
## a sheet: save current settings there, copy the everyday ones, edit a
## game's in the quick menu, export one game, reset (asks first).
##
## services: "profiles" (Profiles or the real script with a test file),
## "controls" (for titles and value labels), optional "profiles_dir" (where
## export / import look, default ~/Documents/GameCove).

const Words := preload("res://scripts/ui/words.gd")
const TC := preload("res://scripts/ui/texts_controls.gd")
const Model := preload("res://scripts/ui/controls/model.gd")
const Sheet := preload("res://scripts/ui/games/sheet.gd")
const CIcons := preload("res://scripts/ui/controls/cicons.gd")

## A game's own settings should open in the quick menu ({key, title, store, id}).
signal edit_game_requested(game: Dictionary)

var model: Object
var sheet: Control
var export_dir := ""
var _armed := ""


func _connect() -> void:
	var p := svc("profiles")
	if svc("controls") != null:
		model = Model.new()
		model.setup(svc("controls"), p)
	if p != null and p.has_signal("changed"):
		p.changed.connect(func():
			if is_inside_tree() and is_visible_in_tree():
				rebuild.call_deferred())
	export_dir = str(services.get("profiles_dir", OS.get_environment("HOME").path_join(TC.PROF_EXPORT_DIR)))


func profiles() -> Object:
	return svc("profiles")


func build() -> void:
	var p := profiles()
	var head := add_card(TC.PROF_TITLE, "layers", TC.PROF_LINE)
	head.get_parent().name = "Card_how"
	if p == null:
		head.add_child(SKit.note(TC.NO_CONTROLS, "info", "NoProfiles"))
		return
	head.add_child(SKit.note(TC.PROF_ORDER, "info", "Order"))
	var now := Kit.hbox(8)
	now.name = "Now"
	var lbl := Kit.micro(TC.PROF_NOW)
	lbl.add_theme_color_override("font_color", ThemeLib.color("text_3"))
	lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	now.add_child(lbl)
	var src := str(p.current_source()) if p.has_method("current_source") else "battery"
	if Words.battery:
		now.add_child(Kit.chip(TC.PROF_SOURCE_NOW.get(src, src), "plug" if src == "ac" else "bolt", "info", true))
	if "game_key" in p and str(p.game_key) != "":
		now.add_child(Kit.chip(str(p.game_title) if str(p.game_title) != "" else str(p.game_key), "game", "accent", true))
	head.add_child(now)

	var base := add_card(TC.PROF_EVERYDAY + " and power", "bolt")
	base.get_parent().name = "Card_layers"
	for l in [["", TC.PROF_EVERYDAY, TC.PROF_EVERYDAY_LINE, "sliders"], ["battery", TC.PROF_BATTERY, TC.PROF_BATTERY_LINE, "bolt"],
			["ac", TC.PROF_AC, TC.PROF_AC_LINE, "power"]]:
		if str(l[0]) != "" and not Words.battery:
			continue   # no battery (Steam Machine, mini PC): no "on battery" / "plugged in" settings
		var vals: Dictionary = p.layer("", str(l[0]))
		var key: String = "layer_" + (str(l[0]) if str(l[0]) != "" else "global")
		var r := action_row(base, key, l[1], _count(vals), l[2] + " " + _summary(vals), l[3])
		if vals.is_empty():
			r.set_value(_count(vals), "muted")
		var src_id: String = l[0]
		var title: String = l[1]
		r.pressed.connect(func(): open_layer("", src_id, title))
		if l[0] == src:
			r.badge_slot().add_child(Kit.chip(TC.PROF_NOW, "", "info", true))

	var games := add_card(TC.PROF_GAMES, "game")
	games.get_parent().name = "Card_games"
	var list: Array = p.games()
	if list.is_empty():
		games.add_child(SKit.note(TC.PROF_GAMES_NONE, "info", "NoGames"))
	for g in list:
		var gk := str(g["key"])
		var title := str(g["title"]) if str(g["title"]) != "" else gk
		var vals := _game_values(gk)
		var r := action_row(games, "game_" + gk.validate_node_name(), title, _count(vals), _summary(vals), "game")
		r.pressed.connect(func(): open_layer(gk, "*", title))

	var backup := add_card(TC.PROF_BACKUP, "save", TC.PROF_FILE_LINE % _path().get_base_dir().replace(OS.get_environment("HOME"), "~"))
	backup.get_parent().name = "Card_backup"
	var ex := action_row(backup, "export", TC.PROF_EXPORT, "", "", "export")
	ex.pressed.connect(export_all)
	var im := action_row(backup, "import", TC.PROF_IMPORT, "", "", "import")
	im.pressed.connect(import_all)


func _count(vals: Dictionary) -> String:
	return TC.PROF_COUNT % vals.size() if not vals.is_empty() else TC.PROF_EMPTY


## Every value a game's layers hold (any source first, then battery / plugged in).
func _game_values(key: String) -> Dictionary:
	var out := {}
	for s in ["", "battery", "ac"]:
		out.merge(profiles().layer(key, s), false)
	return out


## "TDP 15 W · Frame limit 30 fps · +4 more".
func _summary(vals: Dictionary) -> String:
	if vals.is_empty():
		return ""
	var parts: Array[String] = []
	var ids := vals.keys()
	ids.sort()
	for id in ids:
		if parts.size() >= 3:
			break
		var d: Dictionary = model.describe(id) if model != null else {}
		if d.is_empty():
			continue
		parts.append("%s %s" % [d.get("title", id), Model.value_label(d, vals[id])])
	if parts.is_empty():
		return ""
	var more := vals.size() - parts.size()
	return " · ".join(parts) + (" · +%d more" % more if more > 0 else "")


# ---- sheets -----------------------------------------------------------------------

func _sheet() -> Control:
	if sheet == null or not is_instance_valid(sheet):
		sheet = Sheet.new()
		sheet.z_index = 15
		var parent: Node = host if host is Control else self
		parent.add_child(sheet)
	return sheet


## The actions for one layer (game "" = everyday / battery / plugged in;
## src "*" = all of a game's layers).
func open_layer(game: String, src: String, title: String) -> void:
	_armed = ""
	var vals: Dictionary = _game_values(game) if game != "" else profiles().layer("", src)
	var items := []
	if game == "":
		items.append({"id": "save", "text": TC.PROF_SAVE_CURRENT, "icon": "download"})
		if src != "":
			items.append({"id": "copy", "text": TC.PROF_COPY_EVERYDAY, "icon": "update"})
	else:
		items.append({"id": "edit", "text": TC.GAME_CARD_EDIT, "detail": "Opens the quick menu for it.", "icon": "sliders"})
		items.append({"id": "copy", "text": TC.PROF_COPY_EVERYDAY, "icon": "update"})
		items.append({"id": "export", "text": TC.PROF_EXPORT, "icon": "download"})
	items.append({"id": "reset", "text": TC.PROF_RESET, "detail": _count(vals), "icon": "x", "tone": "bad", "disabled": vals.is_empty()})
	_sheet().open(title, _summary(vals), items, func(choice: String): act(game, src, title, choice))


## One sheet choice (tests call it directly).
func act(game: String, src: String, title: String, choice: String) -> void:
	var p := profiles()
	match choice:
		"save":
			p.save_current(game, src)
			notify(TC.PROF_SAVED_NOW, "good")
		"copy":
			p.copy("", "", game, src if src != "*" else "")
			notify(TC.PROF_SAVED_NOW, "good")
		"edit":
			var g := {"key": game, "title": title, "store": game.get_slice(":", 0), "id": game.get_slice(":", 1) if game.contains(":") else ""}
			edit_game_requested.emit(g)
			_open_quick_menu(g)
		"export":
			_export(game)
		"reset":
			if _armed != "reset:%s:%s" % [game, src]:
				_armed = "reset:%s:%s" % [game, src]
				_sheet().open(title, TC.PROF_RESET_CONFIRM + ".", [
					{"id": "reset", "text": TC.PROF_RESET, "icon": "x", "tone": "bad"},
					{"id": "cancel", "text": "Cancel", "icon": "chevron_left"}], func(c2: String): act(game, src, title, c2))
				return
			_armed = ""
			p.reset(game, "*" if game != "" else src)
			notify(TC.PROF_RESET_DONE, "good")
		_:
			_armed = ""
	rebuild()


## Without a host listening: the quick menu in the scene, if there is one.
func _open_quick_menu(g: Dictionary) -> void:
	if not edit_game_requested.get_connections().is_empty() or not is_inside_tree():
		return
	var qm := get_tree().root.find_child("QuickMenu", true, false)
	if qm != null and qm.has_method("open"):
		qm.open(g)


func _path(game := "") -> String:
	var dev := str(profiles().device_id) if profiles() != null and "device_id" in profiles() else "handheld"
	var name_ := "gamecove-profiles-%s.json" % dev if game == "" else "gamecove-profile-%s.json" % game.replace(":", "-")
	return export_dir.path_join(name_)


func export_all() -> void:
	_export("")


func _export(game: String) -> void:
	var path := _path(game)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		notify(TC.PROF_EXPORT_FAILED % path, "bad")
		return
	f.store_string(profiles().export_json(game))
	f.close()
	notify(TC.PROF_EXPORTED % path.replace(OS.get_environment("HOME"), "~"), "good")


func import_all() -> void:
	var path := _path("")
	if not FileAccess.file_exists(path):
		notify(TC.PROF_IMPORT_NONE % path.replace(OS.get_environment("HOME"), "~"), "warn")
		return
	var res: Dictionary = profiles().import_json(FileAccess.get_file_as_string(path))
	if bool(res.get("ok", false)):
		notify(TC.PROF_IMPORTED % int(res.get("values", 0)), "good")
	else:
		notify(str(res.get("why", "")), "bad")
	rebuild()
