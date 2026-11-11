extends VBoxContainer
## The body of the game page's "Cloud saves" card (installed Epic and GOG games): how the
## saves stand ("Saves synced 2 min ago", a conflict, offline...), this game's switch,
## Sync now, the choice when both sides changed, and Restore a backup. The work is
## saves_service.gd's; sheets open on the page's GameActions (open_menu).
##
##   var card := SavesCard.new()
##   card.setup(game, saves_service, game_actions)
##   card.relinked.connect(page._relink)   # rows shown or hidden

const Kit := preload("res://scripts/ui/ui_kit.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Icons := preload("res://scripts/ui/icons.gd")
const GameIcons := preload("res://scripts/ui/games/game_icons.gd")
const TS := preload("res://scripts/ui/texts_saves.gd")
const TG := preload("res://scripts/ui/texts_games.gd")

signal relinked
signal row_focused

var game: Dictionary = {}
var service: Object
var actions: Object
var status_label: Label
var toggle_button: Button
var sync_button: Button
var choose_button: Button
var backups_button: Button
## func() -> unix seconds (tests swap it).
var clock: Callable = func() -> int: return int(Time.get_unix_time_from_system())
var _sig := ""


func setup(g: Dictionary, svc: Object, game_actions: Object) -> void:
	name = "SavesCard"
	game = g
	service = svc
	actions = game_actions
	add_theme_constant_override("separation", 10)
	status_label = Kit.label("", "", true)
	status_label.name = "Status"
	add_child(status_label)
	choose_button = _row("alert", TS.CHOOSE, "Choose")
	choose_button.pressed.connect(open_conflict)
	add_child(choose_button)
	toggle_button = _row("cloud", TS.SYNC_TOGGLE, "Toggle")
	toggle_button.pressed.connect(func(): service.set_enabled(key(), not service.enabled(key())))
	add_child(toggle_button)
	sync_button = _row("update", TS.SYNC_NOW, "SyncNow")
	sync_button.pressed.connect(func(): service.sync_now(game))
	add_child(sync_button)
	backups_button = _row("restart", TS.BACKUPS, "Backups")
	backups_button.pressed.connect(open_backups)
	add_child(backups_button)
	if service.has_signal("status_changed"):
		service.status_changed.connect(_on_status)
	refresh()


func key() -> String:
	return str(game.get("key", ""))


func _on_status(k: String) -> void:
	if k == key() and is_instance_valid(self):
		refresh()


func refresh() -> void:
	var st: Dictionary = service.status(game)
	var now: int = clock.call()
	status_label.text = TS.status_line(st, now)
	var tone := TS.tone(st)
	if tone != "":
		status_label.add_theme_color_override("font_color", ThemeLib.tone(tone))
	else:
		status_label.remove_theme_color_override("font_color")
	var busy := str(st.get("busy", "")) != ""
	var allowed: bool = service.allowed()
	var on := bool(st.get("enabled", true))
	var store := str(TS.STORE_NAMES.get(str(game.get("store", "")), "the store"))
	_set_row(toggle_button, TS.SYNC_TOGGLE, TS.SYNC_TOGGLE_HELP % store if allowed else TS.DISABLED_LINE, "On" if on else "Off")
	toggle_button.disabled = not allowed
	choose_button.visible = str(st.get("state", "")) == "conflict" and on and allowed
	sync_button.visible = on and allowed and not str(st.get("state", "")) in ["unsupported", "linux"]
	sync_button.disabled = busy
	_set_row(sync_button, TS.SYNC_NOW, TS.SYNCING if busy else "", "")
	var n: int = service.backup_list(key()).size()
	_set_row(backups_button, TS.BACKUPS, TS.backup_count(n) if n > 0 else TS.NO_BACKUPS, "")
	backups_button.disabled = n == 0
	_maybe_relink()


## The A hint for one of the card's rows ("" when it isn't one).
func a_hint(f: Control) -> String:
	if f == toggle_button:
		return TS.HINT_OFF if service.enabled(key()) else TS.HINT_ON
	if f == sync_button:
		return TS.SYNC_NOW
	if f == choose_button:
		return TS.HINT_CHOOSE
	if f == backups_button:
		return TS.HINT_RESTORE
	return ""


func focusables() -> Array:
	var out: Array = []
	for b in [choose_button, toggle_button, sync_button, backups_button]:
		if b != null and b.visible:
			out.append(b)
	return out


func _maybe_relink() -> void:
	var sig := ""
	for c in focusables():
		sig += str(c.get_instance_id()) + ","
	if sig != _sig:
		_sig = sig
		relinked.emit()


# ---- sheets ------------------------------------------------------------------------------------

## The two sides of a conflict, newest first and highlighted (Epic; for GOG a fixed order and
## no "Newer", see below), each with what it holds. A picks; both are kept as a backup.
## After a restore (st "prefer": "local") the restored save comes first whatever its age:
## it is the one the user just asked for. A side here that may be a blank save (st "fresh",
## or far smaller than the cloud's) is never "Newer": the cloud's comes first and this one
## says why it's in doubt (review at ff76ca4: the blank save was badged Newer).
static func conflict_rows(st: Dictionary, now: int, with_later := false) -> Array:
	var local := int(st.get("local", 0))
	var remote := int(st.get("remote", 0))
	var rows: Array = [
		{"id": "local", "text": TS.KEEP_LOCAL, "detail": TS.side_detail(TS.saved_at(local, now), int(st.get("local_files", -1)), int(st.get("local_bytes", -1))), "icon": "drive", "t": local},
		{"id": "cloud", "text": TS.KEEP_CLOUD, "detail": TS.side_detail(TS.saved_at(remote, now), int(st.get("cloud_files", -1)), int(st.get("cloud_bytes", -1))), "icon": "download", "t": remote},
	]
	var gog := str(st.get("store", "")) == "gog"
	if gog:
		# GOG's time is the upload's, not the play session's: it says nothing about which save
		# is further on, so it's shown for what it is and neither side is called newer
		rows[1]["detail"] = TS.side_detail(TS.uploaded_at(remote, now), int(st.get("cloud_files", -1)), int(st.get("cloud_bytes", -1)))
	var doubt := local_doubt(st)
	if str(st.get("prefer", "")) == "local":
		rows[0].merge({"tone": "good", "value": TS.RESTORED_BADGE, "detail": TS.RESTORED_DETAIL}, true)
	elif doubt != "":
		rows.reverse()
		rows[1]["tone"] = "warn"
		rows[1]["value"] = TS.SMALL_BADGE if doubt == "small" else TS.FRESH_BADGE
		if doubt == "fresh":
			rows[1]["detail"] = "%s · %s" % [TS.FRESH_DETAIL, str(rows[1]["detail"])]
		if not gog and remote > local:
			rows[0]["tone"] = "good"
			rows[0]["value"] = TS.NEWER
	elif not gog:
		if remote > local:
			rows.reverse()
		if local != remote and maxi(local, remote) > 0:
			rows[0]["tone"] = "good"
			rows[0]["value"] = TS.NEWER
	if with_later:
		rows.append({"id": "later", "text": TS.DECIDE_LATER, "detail": TS.DECIDE_LATER_DETAIL, "icon": "clock"})
	return rows


## Why this handheld's side of a conflict may be a blank save: "small" (no files, or a quarter
## of the cloud's size or less), "fresh" (no sync time for this folder), "" (no doubt).
static func local_doubt(st: Dictionary) -> String:
	var lf := int(st.get("local_files", -1))
	var lb := int(st.get("local_bytes", -1))
	var cb := int(st.get("cloud_bytes", -1))
	if lf == 0 or (lb >= 0 and cb > 0 and lb * 4 <= cb):
		return "small"
	return "fresh" if bool(st.get("fresh", false)) else ""


func open_conflict() -> void:
	if actions == null:
		return
	var st: Dictionary = service.status(game)
	actions.open_menu(TS.CONFLICT_TITLE, TS.CONFLICT_LINE % str(game.get("title", "")), conflict_rows(st, clock.call()),
		func(id: String):
			if id in ["local", "cloud"] and service.resolve(game, id) == false and actions.get("toast") is Callable:
				actions.toast.call(TS.RESOLVE_RUNNING, "info", "warn"))


## Local backups, newest first: date, why it was made, size.
static func backup_rows(list: Array, now: int) -> Array:
	var rows: Array = []
	for b in list:
		rows.append({"id": str(b["id"]), "text": str(TS.REASONS.get(str(b.get("reason", "")), str(b.get("reason", "")))),
			"detail": TG.ago(int(b.get("time", 0)), now), "value": String.humanize_size(int(b.get("bytes", 0))).replace("i", ""),
			"icon": "restart"})
	return rows


func open_backups() -> void:
	if actions == null:
		return
	var rows := backup_rows(service.backup_list(key()), clock.call())
	if rows.is_empty():
		return
	actions.open_menu(TS.BACKUPS_TITLE, TS.BACKUPS_LINE, rows, func(id: String):
		service.restore(game, id, func(r: Dictionary):
			if actions == null or not actions.get("toast") is Callable:
				return
			var t: Callable = actions.toast
			if bool(r.get("ok", false)):
				t.call(TS.RESTORED, "check", "good")
			elif str(r.get("why", "")) == "running":
				t.call(TS.RESTORE_RUNNING, "info", "warn")
			else:
				t.call(TS.RESTORE_FAILED % str(r.get("why", "")), "alert", "bad")))


# ---- rows --------------------------------------------------------------------------------------

func _row(icon: String, title: String, node: String) -> Button:
	var b := Kit.button("", "RowButton")
	b.name = node
	b.custom_minimum_size = Vector2(0, 62)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var row := Kit.hbox(12)
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 14
	row.offset_right = -12
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(row)
	var ic: TextureRect = Icons.rect(icon, 22, ThemeLib.color("text_2")) if Icons.PATHS.has(icon) else GameIcons.rect(icon, 22, ThemeLib.color("text_2"))
	row.add_child(ic)
	var texts := Kit.vbox(0)
	texts.alignment = BoxContainer.ALIGNMENT_CENTER
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	texts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := Kit.label(title)
	l.name = "Text"
	l.add_theme_font_override("font", ThemeLib.font("medium"))
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	texts.add_child(l)
	var dl := Kit.label("", "QuietLabel")
	dl.name = "Detail"
	dl.add_theme_font_size_override("font_size", ThemeLib.SIZE_CAPTION)
	dl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	texts.add_child(dl)
	row.add_child(texts)
	var v := Kit.label("", "CaptionLabel")
	v.name = "Value"
	v.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(v)
	b.focus_entered.connect(func(): row_focused.emit())
	return b


static func _set_row(b: Button, title: String, detail: String, value: String) -> void:
	var texts: Node = b.get_child(0).get_child(1)
	texts.get_node("Text").text = title
	var dl: Label = texts.get_node("Detail")
	dl.text = detail
	dl.visible = detail != ""
	b.get_child(0).get_node("Value").text = value
