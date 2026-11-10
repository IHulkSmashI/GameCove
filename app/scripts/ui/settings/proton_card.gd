extends VBoxContainer
## Settings > Performance > GE-Proton: the installed GE-Proton builds (press
## one to remove it), and a row that checks for the newest release and then
## installs it (scripts/launch/proton_ge.gd). Network only when the user
## presses; the work runs on a WorkerThreadPool task, never the main thread.
## The job belongs to scripts/system/card_jobs.gd, not to the card: the page can
## be rebuilt (theme change) or left mid-install and nothing waits; the card that
## is there when it's done gets the result.

signal rebuilt
signal notice(text: String, tone: String)

const ProtonGE := preload("res://scripts/launch/proton_ge.gd")
const Proton := preload("res://scripts/launch/proton.gd")
const ActionRow := preload("res://scripts/ui/settings/action_row.gd")
const Sheet := preload("res://scripts/ui/games/sheet.gd")
const Kit := preload("res://scripts/ui/ui_kit.gd")
const Motion := preload("res://scripts/ui/motion.gd")
const SKit := preload("res://scripts/ui/settings/kit.gd")
const Proc := preload("res://scripts/system/proc.gd")
const Texts := preload("res://scripts/ui/texts_device.gd")
const TX := preload("res://scripts/ui/texts_extras.gd")
const CardJobs := preload("res://scripts/system/card_jobs.gd")
## card_jobs.gd channel.
const CH := "ge_proton"

var runner: RefCounted
## The owner of the jobs (CardJobs.shared(); tests pass their own).
var jobs: RefCounted
var home := OS.get_environment("HOME")
var sheet_host: Node
## [{"name", "internal", "dir", "major", "minor", "games"}], newest first.
var builds: Array = []
## The last check: ProtonGE.latest() ({} = not checked yet). Kept by `jobs`, so
## a rebuilt card still knows what it found.
var release: Dictionary:
	get: return jobs.memo(CH).get("release", {}) if jobs != null else {}
	set(v): jobs.memo(CH)["release"] = v
## "check" / "install" / "remove" / "" (the job running in `jobs`).
var busy: String:
	get: return jobs.busy(CH) if jobs != null else ""
var rows := {}        # build name -> ActionRow
## Builds listed at the last build (a new one pops).
var _listed := {}
var _listed_once := false
var main_row: VBoxContainer
var sheet: Control
## Called after an install or removal (Controls.detect_all, so the per-game
## Proton list picks it up).
var on_changed: Callable


## command_runner: a fake in tests (then the jobs get an owner of their own unless
## job_host is given); null = the real programs, owned by CardJobs.shared().
func setup(command_runner: RefCounted = null, home_dir := "", host: Node = null, job_host: RefCounted = null) -> void:
	name = "GeProton"
	if job_host != null:
		jobs = job_host
	else:
		jobs = CardJobs.shared() if command_runner == null else CardJobs.new()
	runner = command_runner if command_runner != null else jobs.runner()
	jobs.subscribe(CH, self)
	if home_dir != "":
		home = home_dir
	sheet_host = host
	add_theme_constant_override("separation", 8)
	read_installed()


func compat_dir() -> String:
	return ProtonGE.compat_dir(home)


## Lists the installed builds (file reads only, cheap) and redraws.
func read_installed() -> void:
	var dir := compat_dir()
	var root := Proton.steam_root(home)
	builds = ProtonGE.installed(dir)
	for b in builds:
		b["games"] = ProtonGE.games_using(root, str(b["internal"])).size()
	_build()


## Hands `fn` to the job owner; `done` gets its result on whichever card is
## there then. Outside the tree (tests) it runs at once.
func _job(job_name: String, fn: Callable, done: String) -> bool:
	return jobs.start(CH, job_name, fn, done, [], is_inside_tree() or jobs.force_threads)


func _enter_tree() -> void:
	if jobs != null:
		jobs.subscribe(CH, self)


## Leaving never waits for a job (it isn't ours): we just stop listening.
func _exit_tree() -> void:
	if jobs != null:
		jobs.unsubscribe(CH, self)


func _newest_installed() -> String:
	return str(builds[0]["name"]) if not builds.is_empty() else ""


## The main row's title, value and hint for where things stand.
func main_row_text() -> Array:
	if busy == "check":
		return [TX.GE_CHECK, TX.GE_CHECKING, TX.GE_CHECK_HINT]
	if busy == "install":
		return [TX.GE_INSTALL % str(release.get("tag", "")), TX.GE_INSTALLING, ""]
	if release.has("tag"):
		var tag := str(release["tag"])
		if builds.any(func(b): return b["name"] == tag):
			return [TX.GE_CHECK, TX.GE_HAVE_LATEST % tag, TX.GE_CHECK_HINT]
		var size := Texts.bytes(float(release.get("bytes", 0))) if int(release.get("bytes", -1)) > 0 else "500 MB"
		return [TX.GE_INSTALL % tag, TX.GE_LATEST % tag, TX.GE_INSTALL_HINT % size]
	return [TX.GE_CHECK, "", TX.GE_CHECK_HINT]


func _build() -> void:
	var f := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	var keep := ""
	if main_row != null and main_row.button == f:
		keep = "main"
	for c in get_children():
		remove_child(c)
		c.queue_free()
	rows.clear()
	main_row = null
	if compat_dir() == "":
		add_child(SKit.note(TX.GE_NO_STEAM, "info", "GeNoSteam"))
		rebuilt.emit()
		return
	var t := main_row_text()
	main_row = ActionRow.new()
	main_row.setup("ge_main", t[0], t[1], t[2], "download" if t[0] != TX.GE_CHECK else "update")
	if busy != "":
		main_row.set_value(t[1], "muted")
	elif release.has("tag") and t[0] != TX.GE_CHECK:
		main_row.set_value(t[1], "good")
	main_row.pressed.connect(press_main)
	add_child(main_row)
	if builds.is_empty():
		var n := Kit.label(TX.GE_NONE, "QuietLabel", true)
		n.name = "GeNone"
		add_child(n)
	for b in builds:
		var games := int(b.get("games", 0))
		var r: VBoxContainer = ActionRow.new()
		r.setup("ge_" + str(b["name"]), str(b["name"]), TX.GE_ROW_IN_USE % [games, "game" if games == 1 else "games"] if games > 0 else "",
			TX.GE_ROW_HINT, "layers")
		var build: Dictionary = b
		r.pressed.connect(func(): open_build(build))
		add_child(r)
		rows[b["name"]] = r
		# A build that wasn't there at the last read (just installed) pops.
		if _listed_once and not _listed.has(b["name"]):
			Motion.pop(r, 0.9, 0.36, 0.05)
	_listed = {}
	for b in builds:
		_listed[b["name"]] = true
	_listed_once = true
	rebuilt.emit()
	if keep == "main" and is_inside_tree():
		Kit.focus_later(main_row.button)


## The main row: check, or install what the check found.
func press_main() -> void:
	if busy != "":
		return
	if release.has("tag") and not builds.any(func(b): return b["name"] == release["tag"]):
		install()
	else:
		check()


func check() -> void:
	var r := runner
	if _job("check", func(): return ProtonGE.latest(r), "_on_checked"):
		_build()


func _on_checked(res: Dictionary) -> void:
	if res.has("error"):
		notice.emit(TX.GE_ERRORS.get(res["error"], TX.GE_ERRORS["offline"]), "bad")
	else:
		release = res
	_build()


func install() -> void:
	var r := runner
	var rel := release.duplicate()
	var dir := compat_dir()
	if _job("install", func(): return ProtonGE.install(r, rel, dir), "_on_installed"):
		_build()


func _on_installed(res: Dictionary) -> void:
	if bool(res.get("ok", false)):
		notice.emit(TX.GE_INSTALLED % str(release.get("tag", "")), "good")
		if on_changed.is_valid():
			on_changed.call()
	else:
		notice.emit(TX.GE_ERRORS.get(res.get("error", ""), TX.GE_ERRORS["download"]), "bad")
	read_installed()


func _sheet() -> Control:
	if sheet == null or not is_instance_valid(sheet):
		sheet = Sheet.new()
		sheet.z_index = 15
		(sheet_host if sheet_host != null else self).add_child(sheet)
	return sheet


func open_build(b: Dictionary) -> void:
	var games := int(b.get("games", 0))
	var item := {"id": "remove", "text": TX.GE_REMOVE % str(b["name"]), "icon": "x", "tone": "bad",
		"detail": TX.GE_ERRORS["in_use"] if games > 0 else TX.GE_REMOVE_DETAIL, "disabled": games > 0}
	_sheet().open(str(b["name"]), TX.GE_ROW_IN_USE % [games, "game" if games == 1 else "games"] if games > 0 else "", [item],
		func(choice: String): if choice == "remove": remove(str(b["name"])))


## Removes one build on the worker (about 1.5 GB of files).
func remove(build_name: String) -> void:
	if busy != "":
		return
	var dir := compat_dir()
	var root := Proton.steam_root(home)
	_job("remove", func(): return {"name": build_name, "error": ProtonGE.remove(dir, build_name, root)}, "_on_removed")


func _on_removed(res: Dictionary) -> void:
	if str(res.get("error", "")) == "":
		notice.emit(TX.GE_REMOVED % str(res["name"]), "good")
		if on_changed.is_valid():
			on_changed.call()
	else:
		notice.emit(TX.GE_ERRORS.get(res["error"], TX.GE_ERRORS["failed"]), "bad")
	read_installed()


func focusables() -> Array:
	var out: Array = []
	if main_row != null:
		out.append(main_row.button)
	for k in rows:
		out.append(rows[k].button)
	return out
