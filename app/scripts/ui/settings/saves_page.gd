extends "res://scripts/ui/settings/page.gd"
## Saves: Epic and GOG cloud saves. The switch for all of it ([privacy] cloud_saves), every
## installed Epic and GOG game with how its saves stand, then how it works in four lines.
## A on a game: Sync now, choose a side after a conflict, turn its sync off or on, restore a
## local backup (a choice sheet over the screen). Services: "saves" (saves_service.gd) and
## "library" (its games).

const TSaves := preload("res://scripts/ui/texts_saves.gd")
const Sheet := preload("res://scripts/ui/games/sheet.gd")
const SavesCard := preload("res://scripts/ui/games/saves_card.gd")

## Short state for a game's row (the full line is its explanation).
const SHORT := {"synced": "Synced", "uploaded": "Synced", "downloaded": "Synced", "restored": "Restored",
	"no_saves": "No saves yet", "pending_up": "Waiting", "pending_down": "Waiting", "conflict": "Choose",
	"offline": "Offline", "failed": "Didn't sync", "backup_failed": "Didn't sync", "too_big": "Upload only",
	"not_set_up": "After first play", "unsupported": "No cloud saves", "signed_out": "Signed out",
	"no_tool": "Needs Heroic", "linux": "Windows only", "off": "Off", "disabled": "Off", "never": "Not yet"}
const SHORT_TONE := {"Synced": "good", "Restored": "good", "Choose": "warn", "Offline": "warn", "Didn't sync": "bad"}

var sheet: Control
var _return_key := ""
## func() -> unix seconds (tests swap it).
var clock: Callable = func() -> int: return int(Time.get_unix_time_from_system())


func _connect() -> void:
	var s := svc("saves")
	if s != null and s.has_signal("status_changed"):
		s.status_changed.connect(func(_k): _later_rebuild())
	var lib := svc("library")
	if lib != null and lib.has_signal("changed"):
		lib.changed.connect(_later_rebuild)


func _later_rebuild() -> void:
	if sheet != null and sheet.is_open():
		return   # the sheet's rows stay put; it rebuilds when it closes
	rebuild.call_deferred()


func _games() -> Array:
	var lib := svc("library")
	return lib.games if lib != null and "games" in lib else []


func build() -> void:
	var s := svc("saves")
	var box := add_card(TSaves.CARD, "cloud", TSaves.PAGE_LINE)
	if s == null:
		box.add_child(SKit.note(TSaves.NO_GAMES, "info"))
		return
	var on: bool = s.allowed()
	var t := toggle(box, "cloud_saves", TSaves.SWITCH, on, by_value(TSaves.SWITCH_HELP), "cloud")
	t.changed.connect(func(v):
		if not s.set_allowed(bool(v)):
			notify("Couldn't change that setting.", "bad")
		_later_rebuild())
	_build_games(s)
	_build_how()


func _build_how() -> void:
	var how := add_card(TSaves.HOW_TITLE, "info")
	for line in TSaves.HOW_LINES:
		how.add_child(Kit.icon_label("check", line, "QuietLabel", ThemeLib.color("good"), 18))
	how.add_child(SKit.note(TSaves.AMAZON_NOTE, "info", "AmazonNote"))


func _build_games(s: Object) -> void:
	var games := add_card(TSaves.GAMES_TITLE, "library")
	var list: Array = s.overview(_games())
	if list.is_empty():
		games.add_child(SKit.note(TSaves.NO_GAMES, "info", "NoGames"))
		return
	var now: int = clock.call()
	for item in list:
		var g: Dictionary = item["game"]
		var st: Dictionary = item["status"]
		var short := str(SHORT.get(str(st["state"]), ""))
		if str(st.get("busy", "")) != "":
			short = "Syncing"
		var n: int = s.backup_list(str(g["key"])).size()
		var hint := TSaves.status_line(st, now)
		if n > 0:
			hint += "  ·  " + TSaves.backup_count(n)
		var r: VBoxContainer = action_row(games, "game_" + str(g["key"]).validate_node_name(), str(g.get("title", g["key"])), short, hint, "cloud")
		r.set_value(short, str(SHORT_TONE.get(short, "")))
		r.pressed.connect(func(): open_game(g))


## The game's actions in a sheet over the screen.
func open_game(g: Dictionary) -> void:
	var s := svc("saves")
	_return_key = "game_" + str(g["key"]).validate_node_name()
	var st: Dictionary = s.status(g)
	var now: int = clock.call()
	var rows: Array = []
	var allowed: bool = s.allowed()
	if str(st["state"]) == "conflict" and allowed and bool(st["enabled"]):
		rows.append_array(SavesCard.conflict_rows(st, now))
	if allowed and bool(st["enabled"]) and not str(st["state"]) in ["unsupported", "linux"]:
		rows.append({"id": "sync", "text": TSaves.SYNC_NOW, "detail": TSaves.status_line(st, now), "icon": "update",
			"disabled": str(st.get("busy", "")) != ""})
	rows.append({"id": "toggle", "text": TSaves.SYNC_TOGGLE, "value": "On" if bool(st["enabled"]) else "Off", "icon": "cloud",
		"disabled": not allowed, "detail": "" if allowed else TSaves.DISABLED_LINE})
	var n: int = s.backup_list(str(g["key"])).size()
	rows.append({"id": "backups", "text": TSaves.BACKUPS, "detail": TSaves.backup_count(n) if n > 0 else TSaves.NO_BACKUPS,
		"icon": "restart", "disabled": n == 0})
	_sheet().open(str(g.get("title", "")), TSaves.status_line(st, now), rows, func(id: String): _on_game_pick(g, st, id))


func _on_game_pick(g: Dictionary, st: Dictionary, id: String) -> void:
	var s := svc("saves")
	match id:
		"local", "cloud":
			s.resolve(g, id)
		"sync":
			s.sync_now(g)
		"toggle":
			s.set_enabled(str(g["key"]), not bool(st["enabled"]))
		"backups":
			call_deferred("_open_backups", g)


func _open_backups(g: Dictionary) -> void:
	var s := svc("saves")
	var rows := SavesCard.backup_rows(s.backup_list(str(g["key"])), clock.call())
	if rows.is_empty():
		return
	_sheet().open(TSaves.BACKUPS_TITLE, TSaves.BACKUPS_LINE, rows, func(id: String):
		s.restore(g, id, func(r: Dictionary):
			if bool(r.get("ok", false)):
				notify(TSaves.RESTORED, "good")
			elif str(r.get("why", "")) == "running":
				notify(TSaves.RESTORE_RUNNING, "warn")
			else:
				notify(TSaves.RESTORE_FAILED % str(r.get("why", "")), "bad")))


func _sheet() -> Control:
	if sheet == null or not is_instance_valid(sheet):
		sheet = Sheet.new()
		sheet.z_index = 12
		var parent: Node = host if host is Control else self
		parent.add_child(sheet)
		sheet.closed.connect(func(): call_deferred("_after_sheet"))
	return sheet


## The sheet closed: fresh rows, focus back on the game it was for.
func _after_sheet() -> void:
	if not is_inside_tree():
		return
	rebuild()
	if rows.has(_return_key) and (sheet == null or not sheet.is_open()):
		Kit.focus_later(rows[_return_key].button)


## While the sheet is open its own prompts are the hints.
func modal_hints() -> Array:
	return Sheet.hints() if sheet != null and is_instance_valid(sheet) and sheet.is_open() else []


func _exit_tree() -> void:
	if sheet != null and is_instance_valid(sheet) and sheet.get_parent() != self:
		sheet.queue_free()
