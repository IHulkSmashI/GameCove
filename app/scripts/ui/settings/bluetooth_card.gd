extends VBoxContainer
## Settings > System > Bluetooth devices: paired and connected devices with
## their battery, a row to find new ones, and a sheet per device (Connect /
## Disconnect / Pair / Forget). BlueZ work (scripts/system/bluetooth.gd) runs on
## a WorkerThreadPool task, never the main thread; a 10 s scan doesn't hold up
## the Controls worker either. The jobs belong to scripts/system/card_jobs.gd:
## leaving or rebuilding the page mid-pair never waits, and the card that is
## there when the job ends gets the result.
##
## Reads when built and when the page is shown again (refresh()), and after an
## action. No polling.

signal rebuilt
## A short result for a toast: text, tone ("good" / "bad").
signal notice(text: String, tone: String)

const Bluetooth := preload("res://scripts/system/bluetooth.gd")
const ActionRow := preload("res://scripts/ui/settings/action_row.gd")
const Sheet := preload("res://scripts/ui/games/sheet.gd")
const Kit := preload("res://scripts/ui/ui_kit.gd")
const Motion := preload("res://scripts/ui/motion.gd")
const SKit := preload("res://scripts/ui/settings/kit.gd")
const Proc := preload("res://scripts/system/proc.gd")
const TX := preload("res://scripts/ui/texts_extras.gd")
const CardJobs := preload("res://scripts/system/card_jobs.gd")
const KeepFocus := preload("res://scripts/ui/keep_focus.gd")
## card_jobs.gd channel.
const CH := "bluetooth"

## Runs busctl / bluetoothctl (proc.gd in the jobs' stop group, or a fake in tests).
var runner: RefCounted
## The owner of the jobs (CardJobs.shared(); tests pass their own).
var jobs: RefCounted
## Where the action sheet goes (the settings screen); self when unset.
var sheet_host: Node
## Bluetooth.snapshot() from the last read; {} before the first one. Kept by
## `jobs`, so a rebuilt card shows the devices at once.
var state: Dictionary:
	get: return jobs.memo(CH).get("state", {}) if jobs != null else {}
	set(v): jobs.memo(CH)["state"] = v
var rows := {}           # device path -> ActionRow
## Devices paired or connected at the last build (newly on ones pop).
var _was_on := {}
var _had_state := false
var find_row: VBoxContainer
var sheet: Control
## "read" / "scan" / an action id, "" when idle (the job running in `jobs`).
var busy: String:
	get: return jobs.busy(CH) if jobs != null else ""


## command_runner: a fake in tests (then the jobs get an owner of their own unless
## job_host is given); null = the real programs, owned by CardJobs.shared().
func setup(command_runner: RefCounted = null, host: Node = null, job_host: RefCounted = null) -> void:
	name = "BluetoothDevices"
	if job_host != null:
		jobs = job_host
	else:
		jobs = CardJobs.shared() if command_runner == null else CardJobs.new()
	runner = command_runner if command_runner != null else jobs.runner()
	jobs.subscribe(CH, self)
	sheet_host = host
	add_theme_constant_override("separation", 8)
	refresh()


## Reads the devices again.
func refresh() -> void:
	if busy != "":
		_build()   # a job from before a rebuild: its result comes to us
		return
	var r := runner
	if _job("read", func(): return {"snap": Bluetooth.snapshot(r), "scan": false}, "_on_snapshot", []):
		_build()


## Hands `fn` to the job owner; `done` gets its result (then `extra`) on whichever
## card is there then. Outside the scene tree (tests) it runs at once.
func _job(job_name: String, fn: Callable, done: String, extra: Array) -> bool:
	return jobs.start(CH, job_name, fn, done, extra, is_inside_tree() or jobs.force_threads)


func _enter_tree() -> void:
	if jobs != null:
		jobs.subscribe(CH, self)


## Leaving never waits for a job (it isn't ours): we just stop listening.
func _exit_tree() -> void:
	if jobs != null:
		jobs.unsubscribe(CH, self)


func _on_snapshot(res: Dictionary) -> void:
	var was_scan := bool(res.get("scan", false))
	var st: Dictionary = res.get("snap", {})
	var before: Array = state.get("devices", []).map(func(d): return d["path"]) if state.get("devices") is Array else []
	state = st
	_build()
	if was_scan:
		var fresh: Array = state.get("devices", []).filter(func(d): return not d["paired"] and not d["path"] in before)
		if fresh.is_empty() and not state.get("devices", []).any(func(d): return not d["paired"]):
			notice.emit(TX.BT_FOUND_NONE, "")


## The value shown on a device's row: "Connected · 80% battery", "Paired", "New".
static func status_text(d: Dictionary) -> String:
	var parts := PackedStringArray()
	parts.append(TX.BT_CONNECTED if d.get("connected", false) else (TX.BT_PAIRED if d.get("paired", false) else TX.BT_NEW))
	if int(d.get("battery", -1)) >= 0:
		parts.append(TX.BT_BATTERY % int(d["battery"]))
	return " · ".join(parts)


func _build() -> void:
	var mark := KeepFocus.mark(self, focusables())
	for c in get_children():
		remove_child(c)
		c.queue_free()
	rows.clear()
	find_row = null
	if state.is_empty():
		add_child(SKit.note(TX.BT_LOADING, "info", "BtLoading"))
		_rebuilt(mark)
		return
	if (state.get("adapters", []) as Array).is_empty():
		add_child(SKit.note(TX.BT_NONE, "info", "BtNone"))
		_rebuilt(mark)
		return
	if not state.get("powered", false):
		add_child(SKit.note(TX.BT_OFF, "warn", "BtOff"))
		_rebuilt(mark)
		return
	var devs: Array = state.get("devices", [])
	var now_on := {}
	if not devs.any(func(d): return d["paired"]):
		add_child(SKit.note(TX.BT_EMPTY, "info", "BtEmpty"))
	for d in devs:
		var r: VBoxContainer = ActionRow.new()
		r.setup("bt_" + str(d["address"]).replace(":", ""), str(d["name"]), status_text(d),
			TX.BT_ROW_HINT if d["paired"] else TX.BT_NEW_HINT, str(d["icon"]))
		if d["connected"]:
			r.set_value(status_text(d), "good")
		var dev: Dictionary = d
		r.pressed.connect(func(): open_device(dev))
		add_child(r)
		rows[d["path"]] = r
		# Just paired or connected since the last read: the row pops.
		var on: bool = d["connected"] or d["paired"]
		if on and _had_state and not _was_on.has(d["path"]):
			Motion.pop(r, 0.9, 0.36, 0.05)
		if on:
			now_on[d["path"]] = true
	_was_on = now_on
	_had_state = true
	find_row = ActionRow.new()
	find_row.setup("bt_find", TX.BT_FIND, TX.BT_FINDING if busy == "scan" else "", TX.BT_FIND_HINT, "search")
	find_row.pressed.connect(find_new)
	add_child(find_row)
	_rebuilt(mark)


## After a rebuild: focus stays on the same row, or moves to the nearest one left
## (Forget, a failed Pair whose device BlueZ dropped), or Find new devices.
func _rebuilt(mark: Dictionary) -> void:
	rebuilt.emit()
	KeepFocus.restore(self, mark, focusables(), find_row.button if find_row != null else null)


## Scans for new devices for about 10 s.
func find_new() -> void:
	if busy != "":
		return
	if find_row != null:
		find_row.set_value(TX.BT_FINDING, "muted")
	var r := runner
	_job("scan", func(): return {"snap": Bluetooth.scan(r), "scan": true}, "_on_snapshot", [])


func _sheet() -> Control:
	if sheet == null or not is_instance_valid(sheet):
		sheet = Sheet.new()
		sheet.z_index = 15
		var parent: Node = sheet_host if sheet_host != null else self
		parent.add_child(sheet)
	return sheet


## The sheet for one device.
func open_device(d: Dictionary) -> void:
	var items := []
	if not d["paired"]:
		items.append({"id": "pair", "text": TX.BT_PAIR, "icon": "bluetooth"})
	elif d["connected"]:
		items.append({"id": "disconnect", "text": TX.BT_DISCONNECT, "icon": "x"})
	else:
		items.append({"id": "connect", "text": TX.BT_CONNECT, "icon": "bluetooth"})
	if d["paired"]:
		items.append({"id": "forget", "text": TX.BT_FORGET, "detail": TX.BT_FORGET_DETAIL, "icon": "x", "tone": "bad"})
	_sheet().open(str(d["name"]), status_text(d), items, func(choice: String): act(d, choice))


## Runs one sheet action (tests call it directly), then reads again.
func act(d: Dictionary, action: String) -> void:
	if busy != "" or not action in ["connect", "disconnect", "pair", "forget"]:
		return
	if rows.has(d["path"]):
		rows[d["path"]].set_value(TX.BT_WORKING, "muted")
	var r := runner
	var path := str(d["path"])
	_job(action, func():
		var ok := false
		match action:
			"connect": ok = Bluetooth.connect_device(r, path)
			"disconnect": ok = Bluetooth.disconnect_device(r, path)
			"pair": ok = Bluetooth.pair(r, path)
			"forget": ok = Bluetooth.forget(r, path)
		return {"ok": ok, "snap": Bluetooth.snapshot(r)}, "_on_action", [action, str(d["name"])])


func _on_action(res: Dictionary, action: String, dev_name: String) -> void:
	var ok := bool(res.get("ok", false))
	notice.emit((TX.BT_DONE if ok else TX.BT_FAILED)[action] % dev_name, "good" if ok else "bad")
	state = res.get("snap", state)
	_build()


func focusables() -> Array:
	var out: Array = []
	for p in rows:
		out.append(rows[p].button)
	if find_row != null:
		out.append(find_row.button)
	return out
