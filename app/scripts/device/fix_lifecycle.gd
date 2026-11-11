extends RefCounted
## What should happen to one fix on this system, and the record of what GameCove did by itself.
## Pure: fixes.gd asks judge() and runs the answer through the root helper (docs/FIXES.md,
## "On the handheld").
##
## The rules, in order:
##   - GameCove only ever acts on a fix its own helper says GameCove installed (status
##     installed=yes: the fix's own record and marker). A rule or file someone else set up is
##     never touched, whatever the definitions say.
##   - Withdrawn (the release's kill switch) and installed: take it out ("retire").
##   - The system now does it natively (obsolete_when is YES) and installed: take it out.
##   - Installed at an older revision than this GameCove's script: bring it up to date ("update").
##   - UNKNOWN never acts. "Keep the workaround anyway" (the user's choice) stops retiring.
##
## State file (fixes-lifecycle.json in GameCove's data folder, written through settings_file.gd):
##   {"schema": 1, "keep": {"<device>": ["<fix>", ...]}, "data_checked": unix,
##    "pending": {"<device>": {"<fix>": {"action", "reason", "since", "told"}}},
##    "history": [{"time", "device", "fix", "title", "action", "reason", "detail", "undone"}]}
## history actions: removed | updated | update-failed | remove-failed | kept

const Cond := preload("res://scripts/device/fix_conditions.gd")
const SettingsFile := preload("res://scripts/system/settings_file.gd")

const SCHEMA := 1
const HISTORY_MAX := 60
const MANAGED_KINDS := ["root", "file"]


static func _yn(v: String) -> int:
	return Cond.YES if v == "yes" else (Cond.NO if v == "no" else Cond.UNKNOWN)


## Probe answers out of a fix's `status` output.
static func probe_facts(status: Dictionary) -> Dictionary:
	var hw := _yn(str(status.get("hw", "")))
	return {"os_fixed": _yn(str(status.get("os_fixed", ""))),
		"hw_absent": Cond.UNKNOWN if hw == Cond.UNKNOWN else (Cond.YES if hw == Cond.NO else Cond.NO)}


static func _int(v: Variant, fallback: int) -> int:
	return int(str(v)) if str(v).is_valid_int() else fallback


## {"installed", "withdrawn", "obsolete", "needed", "stale", "action", "reason"} for one fix.
## def: its definition; status: parsed `status` output ({} = not asked or no answer);
## facts: Cond.gather() (+ tools); keep: the user said "keep the workaround anyway".
static func judge(def: Dictionary, status: Dictionary, facts: Dictionary, keep := false) -> Dictionary:
	var f := facts.duplicate()
	f["probe"] = probe_facts(status)
	var life: Dictionary = def.get("lifecycle", {}) if def.get("lifecycle") is Dictionary else {}
	var withdrawn := def.get("withdrawn") is Dictionary
	var obsolete := Cond.NO if life.get("obsolete_when") == null else Cond.evaluate(life.get("obsolete_when"), f)
	var needed := Cond.YES if life.get("needed_when") == null else Cond.evaluate(life.get("needed_when"), f)
	var installed := str(status.get("installed", "")) == "yes"
	var stale := installed and status.has("revision") and _int(status.get("installed_revision", "1"), 1) < _int(status.get("revision", "1"), 1)
	var out := {"installed": installed, "withdrawn": withdrawn, "obsolete": obsolete, "needed": needed, "stale": stale,
		"action": "", "reason": ""}
	if not installed or not str(def.get("kind", "")) in MANAGED_KINDS:
		return out
	if withdrawn and not keep:
		out["action"] = "retire"
		out["reason"] = "withdrawn"
	elif obsolete == Cond.YES and not keep:
		out["action"] = "retire"
		out["reason"] = "native"
	elif stale:
		out["action"] = "update"
		out["reason"] = "revision"
	return out


# ------------------------------------------------------------------ the state file

static func load_state(path: String) -> Dictionary:
	var d: Variant = SettingsFile.load_json(path)["data"] if FileAccess.file_exists(path) else null
	var s: Dictionary = d if d is Dictionary and int(d.get("schema", 0)) == SCHEMA else {}
	for k in ["keep", "pending"]:
		if not s.get(k) is Dictionary:
			s[k] = {}
	if not s.get("history") is Array:
		s["history"] = []
	s["schema"] = SCHEMA
	return s


static func save_state(path: String, state: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	SettingsFile.save_json(path, state, "  ")


static func kept(state: Dictionary, device: String, fix: String) -> bool:
	var l: Variant = state["keep"].get(device, [])
	return l is Array and fix in l


static func set_kept(state: Dictionary, device: String, fix: String, on: bool) -> void:
	var l: Array = (state["keep"].get(device, []) as Array).duplicate() if state["keep"].get(device) is Array else []
	if on and not fix in l:
		l.append(fix)
	elif not on:
		l.erase(fix)
	state["keep"][device] = l


static func pending(state: Dictionary, device: String) -> Dictionary:
	if not state["pending"].get(device) is Dictionary:
		state["pending"][device] = {}
	return state["pending"][device]


static func add_history(state: Dictionary, entry: Dictionary) -> void:
	var h: Array = state["history"]
	h.append(entry)
	while h.size() > HISTORY_MAX:
		h.pop_front()


## This device's history, newest first.
static func history(state: Dictionary, device: String) -> Array:
	var out: Array = []
	for e in state["history"]:
		if e is Dictionary and str(e.get("device", "")) == device:
			out.push_front(e)
	return out
