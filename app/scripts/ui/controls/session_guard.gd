extends RefCounted
## "Keep this?" for settings that only take effect in the next session
## (Unlock refresh rates, Screen rotation). They can leave a panel black, and
## the countdown has to run in the session that shows the problem, so the
## change is remembered here and checked once at the next start: nobody
## pressing Keep within 15 s puts the old value back (and the session after
## that is normal again). Docs: SSH / TTY recovery in docs/CONTROLS.md.

const KeepDialog := preload("res://scripts/ui/controls/keep_dialog.gd")
const TC := preload("res://scripts/ui/texts_controls.gd")

static var path := "user://controls_confirm.json"
## Older than this and nobody restarted: forget it.
const MAX_AGE_S := 7 * 24 * 3600


## A next-session setting changed from `old` to `now` (labels for the dialog).
static func remember(id: String, title: String, old: Variant, now: Variant, now_label: String) -> void:
	# atomic (review H9): a half-written file would lose the "keep or undo" question after a crash
	preload("res://scripts/system/settings_file.gd").save_text(path, JSON.stringify({"id": id, "title": title,
		"old": old, "new": now, "label": now_label, "pid": OS.get_process_id(), "time": int(Time.get_unix_time_from_system())}))


static func pending() -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return d if d is Dictionary else {}


static func clear() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


## At start: if the last session changed such a setting, ask now. `host` is
## any Control in the tree; the dialog goes on the topmost one.
static func check(host: Control, controls: Object, _profiles: Object = null, pid := -1) -> Control:
	var p := pending()
	if p.is_empty() or controls == null:
		return null
	if int(p.get("pid", -1)) == (pid if pid >= 0 else OS.get_process_id()):
		return null   # still the session that made the change
	if int(Time.get_unix_time_from_system()) - int(p.get("time", 0)) > MAX_AGE_S:
		clear()
		return null
	var id := str(p.get("id", ""))
	var c: Object = controls.control(id) if controls.has_method("has") and controls.has(id) else null
	if c == null:
		return null
	if not c.available and controls.has_signal("detected"):
		# detection still running: ask once it's done
		controls.detected.connect(func(): check(host, controls, _profiles, pid), CONNECT_ONE_SHOT)
		return null
	clear()
	var top: Control = host
	while top.get_parent() is Control:
		top = top.get_parent()
	var dlg: Control = KeepDialog.open(top, str(p.get("title", id)), str(p.get("label", "")), TC.CONFIRM_SECONDS)
	dlg.decided.connect(func(keep: bool):
		if not keep:
			controls.set_value(id, p.get("old")))
	return dlg
