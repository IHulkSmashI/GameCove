extends Node
## Fixes service: which device fixes apply to this exact handheld, their state,
## Apply / Undo, the installer's record of what it applied, GameCove's own
## "quiet" fix (keep GameCove off the game's cores) and the "what changed"
## check after a system update (ported from ClawDeck changes.py / quiet.py).
##
## Data: res://data/fixes.json (the catalogue; docs/DEVICE-FIXES.md is the
## research behind it). Root and file fixes are folders in fixes/ run through
## the root helpers: `gamecove-fix <name> status` (no pkexec, read-only),
## Apply / Undo through `pkexec gamecove-fix-set <name> set on|off` (file fixes:
## no password, works in Gaming Mode) or `pkexec gamecove-fix <name>
## install|remove` (root fixes: admin password, Desktop Mode).
##
## Lifecycle (docs/FIXES.md): every fix carries rules for when it is needed and when the system
## has caught up (fix_conditions.gd), and the definitions can be updated or withdrawn by the signed
## nightly "fixes" release (fix_data.gd). At session start and after a system update (never on a
## timer, never while a game runs) start_lifecycle() looks at the fixes GameCove installed here:
## one the system now does itself, or a withdrawn one, is taken out with the fix's own undo; one
## whose script has a newer revision is brought up to date (the helper puts the old version back
## when that fails). Every such change is in history() with "keep the workaround anyway", is said
## once (lifecycle_notice) and only ever goes through the existing helper: pkexec gamecove-fix
## <name> remove|update (admin password; in Gaming Mode, where nothing can ask for it, the change
## waits and the page says so).
##
## Not an autoload: the page (or whoever owns it) makes one, calls setup(ctx)
## and refresh(). Everything runs through ctx.runner (BgCommand off the main
## thread when in the tree; synchronously in tests), all paths under
## ctx.sys_root / ctx.home. Nothing polls: status is read on refresh(), after
## an action, and after a system update.

signal changed(rows: Array)
## verb: "apply" | "undo" | "check". message: one plain line for a toast.
signal action_finished(fix: String, verb: String, ok: bool, message: String)
## GameCove changed (or couldn't change) a fix by itself: one plain line, said once.
signal lifecycle_notice(message: String, tone: String)
## Fixes still in place that must come out but wait for the admin password, where leaving them
## does harm: withdrawn ones, and ones the system now does itself that clash with the system's own
## fix (lifecycle.both_active "conflict"). [{id, title, reason, withdrawn}], once per GameCove run,
## at the end of the start pass; main.gd shows it over the home screen (attention()).
signal attention_needed(items: Array)

const SettingsFile := preload("res://scripts/system/settings_file.gd")
const BgCommand := preload("res://scripts/ui/bg_command.gd")
const Texts := preload("res://scripts/ui/texts_fixes.gd")
const PerDevice := preload("res://scripts/device/per_device.gd")
const Traits := preload("res://scripts/device/traits.gd")
const DeviceScript := preload("res://scripts/device/device.gd")
const Cond := preload("res://scripts/device/fix_conditions.gd")
const FixData := preload("res://scripts/device/fix_data.gd")
const Life := preload("res://scripts/device/fix_lifecycle.gd")
const Privacy := preload("res://scripts/system/privacy.gd")
const UpdatesScript := preload("res://scripts/system/updates.gd")
const DEVICE_TABLE := "res://data/devices.json"

const CATALOGUE := "res://data/fixes.json"
const FIX_HELPER := "/usr/libexec/gamecove/gamecove-fix"
const FIX_SET_HELPER := "/usr/libexec/gamecove/gamecove-fix-set"
## GameCove's InputPlumber override for the Claw 8 EX shadows this stock file (fixes/lib/claw8ex-common.sh).
const IP_STOCK := "/usr/share/inputplumber/devices/50-msi_claw8_ex_ai_cg3em.yaml"
const IP_OVERRIDE := "/etc/inputplumber/devices.d/50-msi_claw8_ex_ai_cg3em.yaml"
## The VRR fix on SteamOS: its record and the marked line in Valve's grub file (fixes/claw8ex-vrr/fix.sh).
## SteamOS gives every OS slot its own /var and keeps only the keep-listed /etc files across an update,
## so the record lives in /etc there (an older install's is still in /var).
const VRR_MANIFEST := "/etc/gamecove/claw8ex-vrr/record/manifest"
const VRR_MANIFEST_OLD := "/var/lib/gamecove/fixes/claw8ex-vrr/manifest"
const GRUB_DEFAULT := "/etc/default/grub"
const VRR_GRUB_MARK := "# GameCove claw8ex-vrr"
## Helper state= -> page status (see status_of for the rest).
const STATE_STATUS := {"on": "applied", "restart": "restart", "partial": "partial", "os-fixed": "os-fixed",
	"not-needed": "not-needed", "n/a": "not-needed", "unsupported": "blocked", "other-override": "blocked", "clawdeck": "not-needed"}

var catalogue: Array = []
var device_id := "unknown"
## This handheld's devices.json row (its traits pick the fixes: app/data/fixes.json selectors).
var device_row: Dictionary = {}
var sys_root := ""
var home := OS.get_environment("HOME")
## Where the user's choices and the system snapshot live (tests: a temp folder).
var data_dir := ""
var commands: Node
var _status := {}      # fix -> parsed status {key: value}; missing = not checked yet
var _working := {}     # fix -> "apply" | "undo"
var _game_running := false
var _quiet_on := false   # the quiet fix is moving GameCove right now
var last_changes: Dictionary = {}
## Tests: whether a password prompt can show (null = ask the session), Background lookups
## (null = ask privacy.gd), a fixed clock (0 = the real one) and the PATH cosign is looked up in.
var can_prompt_override: Variant = null
var background_override: Variant = null
var now_unix := 0
var path_env := OS.get_environment("PATH")
## "verified" | "bad" | "schema" | "older" | "no-cosign" | "offline" | "" (not tried this run)
var data_result := ""
var _life: Dictionary = {}
var _facts: Dictionary = {}
var _judged := {}          # fix -> Life.judge() result, cleared when its status or the facts change
var _eval_wait := {}       # command ids the running evaluation still waits for
var _eval_queue: Array = []   # [{fix, action, reason}] still to run
var _eval_active := ""     # the fix an automatic change is running on
var _eval_wanted := ""     # "" | "start" | "full": asked for while a game ran
var _data_step := -1
var _refreshing := false    # the no-password InputPlumber override rebuild is running
var _attention_said := false
var _names := {}            # devices.json id -> name (tested-on lines)


func _init() -> void:
	commands = BgCommand.new()
	commands.name = "Commands"
	add_child(commands)
	commands.finished.connect(_on_finished)
	catalogue = load_catalogue(CATALOGUE)
	_life = Life.load_state("")


## ctx: {sys_root, runner, home, device} as Controls providers get it; device
## may be the Device autoload, a devices.json row id, or a row dictionary.
func setup(ctx: Dictionary) -> void:
	sys_root = str(ctx.get("sys_root", sys_root))
	home = str(ctx.get("home", home))
	if ctx.get("runner") != null:
		commands.runner = ctx["runner"]
	var dev: Variant = ctx.get("device")
	device_row = {}
	if dev is String:
		device_id = dev
	elif dev is Dictionary:
		device_id = str(dev.get("id", "unknown"))
		device_row = dev
	elif dev is Object and dev.has_method("id"):
		device_id = str(dev.id())
		if dev.get("profile") is Dictionary:
			device_row = dev.profile
	if device_id == "":
		device_id = "unknown"
	if not device_row.has("traits"):
		device_row = row_for(device_id, device_row)
	data_dir = str(ctx.get("data_dir", home.path_join(".local/share/gamecove")))
	PerDevice.adopt_file(_choices_path(), device_id)
	_status.clear()
	if ctx.has("can_prompt"):
		can_prompt_override = ctx["can_prompt"]
	if ctx.has("background"):
		background_override = ctx["background"]
	_life = Life.load_state(_life_path())
	_facts = Cond.gather(sys_root)
	reload_definitions()


## The built-in definitions with the verified nightly release (if one is held) laid over them.
func reload_definitions() -> void:
	catalogue = FixData.merge(load_catalogue(CATALOGUE), FixData.cached(_data_dir()))
	_judged.clear()


static func load_catalogue(path: String) -> Array:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var d: Variant = JSON.parse_string(f.get_as_text())
	if not d is Dictionary or not d.get("fixes") is Array:
		return []
	return (d["fixes"] as Array).filter(func(e): return e is Dictionary and str(e.get("id", "")) != "")


func entry(fix: String) -> Dictionary:
	for e in catalogue:
		if e["id"] == fix:
			return e
	return {}


## A model's name for people, from devices.json (read once per id).
func _model_name(id: String) -> String:
	if not _names.has(id):
		_names[id] = str(row_for(id, {}).get("name", id))
	return _names[id]


## The devices.json row for an id (with its traits), else `fallback` / {"id": id}.
static func row_for(id: String, fallback: Dictionary = {}) -> Dictionary:
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(DEVICE_TABLE))
	if d is Dictionary and d.get("devices") is Array:
		for r in d["devices"]:
			if r is Dictionary and str(r.get("id", "")) == id:
				return r
	return fallback if not fallback.is_empty() else {"id": id}


## Auto-applied by the installer on this device: the entry's "auto" selector
## holds on this row's traits (devices.json "fixes" is generated from it).
func is_auto(fix: String) -> bool:
	return Traits.fix_auto(entry(fix), device_row)


## Offered with Apply here (the "optional" selector), and why it applies.
func is_optional(fix: String) -> bool:
	return Traits.fix_optional(entry(fix), device_row)


func why(fix: String) -> String:
	var e := entry(fix)
	if Traits.fix_auto(e, device_row):
		return Traits.why(e["auto"], device_row)
	if Traits.fix_optional(e, device_row):
		return Traits.why(e["optional"], device_row)
	return ""


## Catalogue entries for this exact model, Fixes page ones only, auto first.
func entries() -> Array:
	var out: Array = []
	for e in catalogue:
		if str(e.get("page", "fixes")) != "fixes":
			continue
		if Traits.fix_auto(e, device_row) or Traits.fix_optional(e, device_row):
			out.append(e)
	out.sort_custom(func(a, b): return int(is_auto(a["id"])) > int(is_auto(b["id"])))
	return out


## Fixes the installer recorded as installed (install-state.json "fixes").
func installer_applied() -> Array:
	var f := FileAccess.open(home.path_join(".local/share/gamecove/install-state.json"), FileAccess.READ)
	if f == null:
		return []
	var d: Variant = JSON.parse_string(f.get_as_text())
	if d is Dictionary and d.get("fixes") is Array:
		return d["fixes"]
	return []


# ------------------------------------------------------------------ status

## Asks every root / file fix for its state (in the background).
func refresh() -> void:
	_facts = Cond.gather(sys_root).merged({"tools": _facts.get("tools", {})}, true)
	_judged.clear()
	for e in entries():
		if str(e.get("kind", "")) in ["app", "advice"]:
			continue
		_status.erase(e["id"])
		commands.run("status:" + e["id"], FIX_HELPER, PackedStringArray([e["id"], "status"]))
	changed.emit(rows())


static func parse_status(text: String) -> Dictionary:
	var out := {}
	for line in text.split("\n", false):
		var i := line.find("=")
		if i > 0:
			out[line.substr(0, i).strip_edges()] = line.substr(i + 1).strip_edges()
	return out


## The page's status word for one fix: applied, restart, partial, needed,
## available, not-needed, os-fixed, blocked, checking, working, unknown.
func status_of(fix: String) -> String:
	var e := entry(fix)
	if e.is_empty():
		return "unknown"
	if _working.has(fix):
		return "working"
	if str(e.get("kind", "")) == "app":
		return "applied" if quiet_enabled() else "available"
	if str(e.get("kind", "")) == "advice":
		return "advice"
	if not _status.has(fix):
		return "checking"
	var st: String = str(_status[fix].get("state", ""))
	if st == "":
		return "unknown"
	if st == "off":
		var j := judgement(fix)
		if j["withdrawn"] or j["obsolete"] == Cond.YES:
			return "retired"   # the system does it itself now, or the fix was withdrawn: never offered
		return "needed" if is_auto(fix) else "available"
	return STATE_STATUS.get(st, "unknown")


## What the lifecycle rules say about one fix right now (Life.judge, remembered until its status
## or the system facts change).
func judgement(fix: String) -> Dictionary:
	if not _judged.has(fix):
		_judged[fix] = Life.judge(entry(fix), _status.get(fix, {}), _facts, Life.kept(_life, device_id, fix))
	return _judged[fix]


func kept(fix: String) -> bool:
	return Life.kept(_life, device_id, fix)


## Where a row goes on the page: applied | recommended | optional | retired ("Not needed any
## more") | "" (not shown: the part isn't in this handheld, or its advice no longer applies).
func group_of(fix: String, status: String) -> String:
	var e := entry(fix)
	var j := judgement(fix)
	var kind := str(e.get("kind", ""))
	if kind == "advice":
		return "" if j["withdrawn"] or j["obsolete"] == Cond.YES or j["needed"] == Cond.NO else "recommended"
	if status in ["applied", "restart", "partial"]:
		return "applied"
	if status == "working" and (j["installed"] or _working.get(fix, "") == "undo"):
		return "applied"
	if status in ["retired", "os-fixed"]:
		return "retired"
	# the part isn't in this unit, or what the fix builds on isn't on this system: nothing to offer
	if status == "not-needed" or (j["needed"] == Cond.NO and status in ["needed", "available"]):
		return ""
	return "recommended" if is_auto(fix) else "optional"


static func _first_link(sources: Variant) -> String:
	for src in sources if sources is Array else []:
		if str(src).begins_with("https://") and not str(src).contains(" "):
			return str(src)
	return ""


func _row(e: Dictionary, applied: Array) -> Dictionary:
	var id: String = e["id"]
	var s := status_of(id)
	var j := judgement(id)
	var kind := str(e.get("kind", ""))
	var admin := str(e.get("password", "admin")) == "admin"
	var auto := is_auto(id)
	var tested_here := false
	var tested: Array = []
	for t in e.get("tested", []) if e.get("tested") is Array else []:
		if t is Dictionary:
			# the model's name for people (devices.json), not its id
			var name_: String = _model_name(str(t.get("device", "")))
			tested.append(t.merged({"name": name_}))
			tested_here = tested_here or str(t.get("device", "")) == device_id
	var changes: Array = []
	for c in e.get("changes", []) if e.get("changes") is Array else []:
		if c is Dictionary:
			changes.append("%s: %s" % [str(c.get("target", "")), str(c.get("detail", ""))])
	var pend: Dictionary = Life.pending(_life, device_id).get(id, {}) if Life.pending(_life, device_id).get(id) is Dictionary else {}
	var withdrawn: Dictionary = e["withdrawn"] if e.get("withdrawn") is Dictionary else {}
	var offered: bool = s in ["needed", "available"] and not j["withdrawn"]
	return {
		"id": id, "title": str(e.get("title", id)), "line": str(e.get("line", "")),
		"symptom": str(e.get("symptom", "")), "kind": kind,
		"auto": auto, "auto_applied": auto and (id in applied or kind == "app") and s in ["applied", "restart"],
		"status": s, "restart": str(e.get("restart", "")), "admin": admin,
		"can_apply": offered,
		"can_undo": s in ["applied", "restart", "partial"],
		"can_check": s == "unknown",
		"sources": e.get("sources", []), "bazzite": str(e.get("bazzite", "")), "steamos": str(e.get("steamos", "")),
		# the fix's own plain words first; the matching traits only when it has none
		"why": str(e.get("why", "")) if str(e.get("why", "")) != "" else why(id),
		"reason": str(_status.get(id, {}).get("reason", "")),
		"group": group_of(id, s),
		"level": "advice" if kind == "advice" else ("recommended" if auto else "optional"),
		"must_fix": bool(e.get("must_fix", false)), "breaks": str(e.get("breaks", "")),
		"tested": tested_here, "tested_on": tested,
		"changes": changes, "undo_text": str(e.get("undo", "")),
		"risk": str(e.get("risk", "")), "risk_note": str(e.get("risk_note", "")),
		# the nightly audit's date when the signed release carries one, else the maintainer's
		"audited": str((e["audit"] as Dictionary).get("date", e.get("audited", ""))) if e.get("audit") is Dictionary else str(e.get("audited", "")), "link": _first_link(e.get("sources", [])),
		"withdrawn": str(withdrawn.get("reason", "")),
		"pending": str(pend.get("action", "")), "pending_reason": str(pend.get("reason", "")),
		"kept": kept(id), "native": j["obsolete"] == Cond.YES,
		"harmful": str(pend.get("action", "")) == "retire" and harmful(id),
		"newer_revision": bool(e.get("newer_revision", false)),
	}


## One row per fix the page shows (rows the handheld has no use for are left out: hidden()).
func rows() -> Array:
	var applied := installer_applied()
	var out: Array = []
	for e in entries():
		var r := _row(e, applied)
		if r["group"] != "":
			out.append(r)
	return out


## How many fixes for this model aren't shown because this unit doesn't need them.
func hidden() -> int:
	var n := 0
	for e in entries():
		if str(e.get("kind", "")) != "advice" and group_of(e["id"], status_of(e["id"])) == "":
			n += 1
	return n


func counts() -> Dictionary:
	var c := {"applied": 0, "available": 0, "os-fixed": 0, "not-needed": hidden(), "recommended": 0, "optional": 0, "retired": 0,
		"harmful": 0}
	for r in rows():
		if r["kind"] == "advice":
			continue
		if r["harmful"]:
			c["harmful"] += 1
		match r["group"]:
			"applied":
				c["applied"] += 1
			"recommended", "optional":
				c[r["group"]] += 1
				if r["can_apply"]:
					c["available"] += 1
			"retired":
				c["retired"] += 1
				c["os-fixed"] += 1
	return c


# ------------------------------------------------------------------ actions

## Apply (verb "apply") or Undo ("undo") one fix. False when it can't start.
func act(fix: String, verb: String) -> bool:
	var e := entry(fix)
	if e.is_empty() or _working.has(fix) or not verb in ["apply", "undo", "check"]:
		return false
	# Only Fixes-page entries have Apply / Undo / Check here. The Power-page ones (fan, charge-limit)
	# are changed through their Power controls with real values: their no-password helper takes no
	# on / off and refused it with exit 66 (review L8).
	if str(e.get("page", "fixes")) != "fixes" or str(e.get("kind", "")) == "advice":
		return false
	# a withdrawn fix is never applied from here (an automatic change in flight has the fix)
	if _eval_active == fix or (verb == "apply" and e.get("withdrawn") is Dictionary):
		return false
	if verb == "check":
		_status.erase(fix)
		changed.emit(rows())
		return commands.run("status:" + fix, FIX_HELPER, PackedStringArray([fix, "status"]))
	if str(e.get("kind", "")) == "app":
		set_quiet_enabled(verb == "apply")
		action_finished.emit(fix, verb, true, Texts.result(str(e.get("title", fix)), verb, true, 0))
		changed.emit(rows())
		return true
	# A no-password fix has no generic apply / undo verb in gamecove-fix-set (only validated values),
	# so only admin fixes (install / remove through gamecove-fix) are acted on here.
	if str(e.get("password", "admin")) != "admin":
		return false
	var args := PackedStringArray([FIX_HELPER, fix, "install" if verb == "apply" else "remove"])
	_working[fix] = verb
	changed.emit(rows())
	if not commands.run(verb + ":" + fix, "pkexec", args):
		_working.erase(fix)
		changed.emit(rows())
		return false
	return true


func apply(fix: String) -> bool:
	return act(fix, "apply")


func undo(fix: String) -> bool:
	return act(fix, "undo")


func _on_finished(id: String, code: int, output: String) -> void:
	var i := id.find(":")
	if i < 0:
		return
	var kind := id.substr(0, i)
	var fix := id.substr(i + 1)
	match kind:
		"status", "life":
			_status[fix] = parse_status(output) if code == 0 else {}
			_judged.erase(fix)
			if kind == "life":
				_eval_done(id)
		"tool":
			_tool_answer(fix, code, output)
			_eval_done(id)
		"data":
			_data_finished(code)
		"auto-retire", "auto-update":
			_auto_finished(kind.trim_prefix("auto-"), fix, code, output)
			return
		"verify":
			_status[fix] = parse_status(output) if code == 0 else {}
			_judged.erase(fix)
			_auto_verified(fix)
			return
		"refresh":
			if code != 0:
				push_warning("Fixes: couldn't rebuild the InputPlumber override (%d): %s" % [code, output.strip_edges()])
			_refreshing = false
			if _eval_wanted != "" and not _game_running and _data_step < 0 and _eval_wait.is_empty() and _eval_active == "":
				_evaluate()
			else:
				refresh()
		"apply", "undo":
			_working.erase(fix)
			var e := entry(fix)
			var ok := code == 0
			if ok:
				_remember_choice(fix, kind)
				# the user's own Apply / Undo settles anything GameCove was waiting to do
				Life.pending(_life, device_id).erase(fix)
				if kind == "undo":
					Life.set_kept(_life, device_id, fix, false)
				_save_life()
			var detail := ""
			for line in output.split("\n", false):
				if line.strip_edges() != "":
					detail = line.strip_edges()
			action_finished.emit(fix, kind, ok, Texts.result(str(e.get("title", fix)), kind, ok, code, detail.trim_prefix(fix + ": "), str(e.get("restart", ""))))
			_status.erase(fix)
			commands.run("status:" + fix, FIX_HELPER, PackedStringArray([fix, "status"]))
	changed.emit(rows())


# ------------------------------------------------- the user's own choices

func _choices_path() -> String:
	return data_dir.path_join("fixes.cfg")


func _cfg() -> ConfigFile:
	return SettingsFile.load_cfg(_choices_path())


## What the user did on the page, per device: "on" | "off" (installer repairs
## and updates read it so an Undo sticks: see docs/CONTROLS.md, Fixes).
func choice(fix: String) -> String:
	return str(_cfg().get_value(PerDevice.section("fixes", device_id), fix, ""))


func _remember_choice(fix: String, verb: String) -> void:
	DirAccess.make_dir_recursive_absolute(data_dir)
	SettingsFile.update_cfg(_choices_path(), func(c: ConfigFile):
		c.set_value(PerDevice.section("fixes", device_id), fix, "on" if verb == "apply" else "off"))


# ------------------------------------------------------------- quiet fix

func quiet_enabled() -> bool:
	return choice("quiet") != "off"


func set_quiet_enabled(on: bool) -> void:
	_remember_choice("quiet", "apply" if on else "undo")
	if not on and _quiet_on:
		_quiet(false)
	elif on and _game_running:
		_quiet(true)


## The game session owner calls this when a game starts / ends.
func set_game_running(on: bool) -> void:
	_game_running = on
	if not on and _eval_wanted != "":
		# a lifecycle pass was asked for while the game ran: now is the time
		start_lifecycle(_eval_wanted == "full")
	if on and quiet_enabled():
		_quiet(true)
	elif not on and _quiet_on:
		_quiet(false)


static func parse_cpus(text: String) -> Array:
	var out: Array = []
	for part in text.strip_edges().split(",", false):
		var ab := part.split("-")
		if ab.size() == 0 or not ab[0].is_valid_int():
			continue
		var a := int(ab[0])
		var b := int(ab[1]) if ab.size() > 1 and ab[1].is_valid_int() else a
		for c in range(a, b + 1):
			if not c in out:
				out.append(c)
	return out


## The LP-E cores (Atom cores without an L3 cache), else every Atom core, else
## none (AMD, older Intel): then only the priority changes.
func efficiency_cores() -> Array:
	var f := FileAccess.open(sys_root + "/sys/devices/cpu_atom/cpus", FileAccess.READ)
	if f == null:
		return []
	var atom := parse_cpus(DeviceScript.read_all(f))
	var lpe := atom.filter(func(c): return not DirAccess.dir_exists_absolute(sys_root + "/sys/devices/system/cpu/cpu%d/cache/index3" % c))
	return lpe if not lpe.is_empty() else atom


static func cpu_list(cores: Array) -> String:
	return ",".join(PackedStringArray(cores.map(func(c): return str(c))))


## The commands that move GameCove (this process, every thread) and back.
func quiet_commands(on: bool, pid: int, threads: Array) -> Array:
	var out: Array = []
	var cores := efficiency_cores()
	if on and not cores.is_empty():
		out.append(["taskset", ["-a", "-p", "-c", cpu_list(cores), str(pid)]])
	elif not on:
		out.append(["taskset", ["-a", "-p", "-c", "0-%d" % maxi(OS.get_processor_count() - 1, 0), str(pid)]])
	var tids: Array = threads if not threads.is_empty() else [pid]
	var args := ["-n", "10" if on else "0", "-p"]
	for t in tids:
		args.append(str(t))
	out.append(["renice", args])
	return out


func _threads(pid: int) -> Array:
	var out: Array = []
	var d := DirAccess.open("/proc/%d/task" % pid)
	if d != null:
		for t in d.get_directories():
			if t.is_valid_int():
				out.append(int(t))
	return out


func _quiet(on: bool) -> void:
	_quiet_on = on
	var pid := OS.get_process_id()
	var i := 0
	for c in quiet_commands(on, pid, _threads(pid)):
		commands.run("quiet%d:%s" % [i, "on" if on else "off"], c[0], PackedStringArray(c[1]))
		i += 1


# ------------------------------------------------------- what changed

## The parts of the system a fix depends on (read from files only).
func system_snapshot() -> Dictionary:
	var snap := {"kernel": _read(sys_root + "/proc/sys/kernel/osrelease"), "os": _os_version()}
	var q := sys_root + "/usr/share/gamescope-session-plus/device-quirks"
	snap["quirks"] = FileAccess.get_md5(q) if FileAccess.file_exists(q) else ""
	var ip := sys_root + IP_STOCK
	snap["inputplumber"] = FileAccess.get_md5(ip) if FileAccess.file_exists(ip) else ""
	# a BIOS / EC update can fix what a workaround was for (docs/FIXES.md)
	var f := Cond.gather(sys_root)
	snap["bios"] = str(f.get("bios", ""))
	snap["ec"] = str(f.get("ec", ""))
	return snap


## Our InputPlumber override was built from a stock file that has changed since (an OS update):
## a frozen copy of the old file could stop the controller from matching (review S1-4).
static func ip_override_stale(root: String) -> bool:
	var o := root + IP_OVERRIDE
	if not FileAccess.file_exists(o):
		return false
	var text := FileAccess.get_file_as_string(o)
	if not text.begins_with("# GameCove override of"):
		return false  # someone else's: never touched
	var recorded := ""
	for line in text.split("\n", false).slice(0, 5):
		if line.begins_with("# stock-sha256: "):
			recorded = line.trim_prefix("# stock-sha256: ").strip_edges()
	var stock := root + IP_STOCK
	var now := FileAccess.get_sha256(stock) if FileAccess.file_exists(stock) else ""
	return recorded != now


## Rebuilds a stale override at once, without a password (the controller may not work until then).
func refresh_stale_override() -> bool:
	if not ip_override_stale(sys_root):
		return false
	# the lifecycle pass waits for it: the rebuild is what lets our override stand aside for a map
	# InputPlumber now ships itself (fixes/lib/claw8ex-common.sh, ip_render)
	_refreshing = true
	var started: bool = commands.run("refresh:inputplumber", "pkexec",
		PackedStringArray([FIX_SET_HELPER, "claw8ex-buttons", "set", "refresh"]))
	_refreshing = started and _refreshing   # a synchronous runner (tests) has already finished it
	return started


## A SteamOS update brought back Valve's /etc/default/grub without the VRR fix's line (the fix is installed on
## SteamOS: its record has the grub line). The range is gone from the next restart until the line is back.
static func vrr_line_lost(root: String) -> bool:
	var mf := FileAccess.open(root + VRR_MANIFEST, FileAccess.READ)
	if mf == null:
		mf = FileAccess.open(root + VRR_MANIFEST_OLD, FileAccess.READ)
	if mf == null or not ("grubline " + GRUB_DEFAULT) in DeviceScript.read_all(mf).split("\n", false):
		return false
	var gf := FileAccess.open(root + GRUB_DEFAULT, FileAccess.READ)
	return gf != null and not DeviceScript.read_all(gf).contains(VRR_GRUB_MARK)


## Puts the line back at once, without a password (the fix was installed with it); the fix takes itself out
## where the update made it impossible.
func refresh_vrr_after_update() -> bool:
	if not vrr_line_lost(sys_root):
		return false
	return commands.run("refresh:vrr", "pkexec", PackedStringArray([FIX_SET_HELPER, "claw8ex-vrr", "set", "refresh"]))


func _read(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	return DeviceScript.read_all(f).strip_edges() if f != null else ""


func _os_version() -> String:
	var vals := {}
	for line in _read(sys_root + "/etc/os-release").split("\n", false):
		var i := line.find("=")
		if i > 0:
			vals[line.substr(0, i)] = line.substr(i + 1).strip_edges().trim_prefix("\"").trim_suffix("\"").trim_prefix("'").trim_suffix("'")
	var v: String = str(vals.get("OSTREE_VERSION", vals.get("VERSION_ID", vals.get("VERSION", ""))))
	return ("%s %s" % [vals.get("NAME", ""), v]).strip_edges()


static func diff(old: Dictionary, now: Dictionary) -> Array:
	var out: Array = []
	for k in now:
		if old.has(k) and str(old[k]) != str(now[k]):
			out.append({"key": k, "what": Texts.CHANGE_LABELS.get(k, k), "from": str(old[k]), "to": str(now[k])})
	return out


## Compares the system with the last start, saves the new snapshot and, when
## something changed, checks every fix again. {first_run, changed: [...]}.
func check_changes() -> Dictionary:
	var path := data_dir.path_join("system-snapshot.json")
	var old: Variant = null
	if FileAccess.file_exists(path):
		old = SettingsFile.load_json(path)["data"]
	var now := system_snapshot()
	var changes: Array = diff(old, now) if old is Dictionary else []
	DirAccess.make_dir_recursive_absolute(data_dir)
	SettingsFile.save_json(path, now, "  ")
	last_changes = {"first_run": not old is Dictionary, "changed": changes}
	# every start, not only after a change: cheap, and the update may have come before this check existed
	refresh_stale_override()
	refresh_vrr_after_update()
	if not changes.is_empty():
		refresh()
	# the lifecycle pass: every start looks at the fixes GameCove installed; after a system update
	# (or on the first run) at every fix for this model
	start_lifecycle(not changes.is_empty() or not old is Dictionary)
	return last_changes


## After an update: GameCove fixes that the system now does itself.
func now_os_fixed() -> Array:
	var out: Array = []
	for e in entries():
		var st: Dictionary = _status.get(e["id"], {})
		if str(st.get("os_fixed", "")) == "yes" and str(st.get("installed", "")) == "yes":
			out.append(e["id"])
	return out


# ------------------------------------------------------------------ lifecycle

func _life_path() -> String:
	return data_dir.path_join("fixes-lifecycle.json")


func _data_dir() -> String:
	return data_dir.path_join("fixes-data")


func _save_life() -> void:
	if data_dir != "":
		Life.save_state(_life_path(), _life)


func _now() -> int:
	return now_unix if now_unix > 0 else int(Time.get_unix_time_from_system())


## A password prompt can show: not in GameCove's gamescope session (no polkit agent there).
func can_prompt() -> bool:
	if can_prompt_override != null:
		return bool(can_prompt_override)
	return not (OS.get_environment("GAMESCOPE_WAYLAND_DISPLAY") != "" or OS.get_environment("XDG_CURRENT_DESKTOP").to_lower() == "gamescope")


func _background_allowed() -> bool:
	return bool(background_override) if background_override != null else Privacy.background_allowed()


## cosign on this device: the system's, else the copy the installer downloaded; "" when there is none.
func _cosign() -> String:
	for dir in path_env.split(":", false):
		if FileAccess.file_exists(dir.path_join("cosign")):
			return dir.path_join("cosign")
	var mine := home.path_join(".local/share/gamecove/tools/cosign-" + UpdatesScript.COSIGN_VERSION)
	return mine if home != "" and FileAccess.file_exists(mine) else ""


## This device's automatic changes, newest first (the page's History).
func history() -> Array:
	return Life.history(_life, device_id)


## Session start (and again after a game, when one was running): fetch the nightly definitions
## when they are due, then look at the fixes GameCove installed here. full = the system changed
## (or this is the first run): every fix for this model is looked at, not only installed ones.
## "" when it started, else why not: "game_running" (it runs when the game ends) | "busy".
func start_lifecycle(full := false) -> String:
	if _game_running:
		_eval_wanted = "full" if full or _eval_wanted == "full" else "start"
		return "game_running"
	if _data_step >= 0 or not _eval_wait.is_empty() or _eval_active != "":
		return "busy"
	_eval_wanted = "full" if full else "start"
	if maybe_fetch_data() != "":
		_evaluate()
	return ""


## Downloads the signed "fixes" release when Background lookups allow it, at most once a day.
## "" when it started, else why not: "game_running" | "privacy" | "not_due" | "no-cosign" | "busy".
func maybe_fetch_data(force := false) -> String:
	if _game_running:
		return "game_running"
	if _data_step >= 0:
		return "busy"
	if not force:
		if not _background_allowed():
			return "privacy"
		var last := int(_life.get("data_checked", 0))
		if last > 0 and _now() >= last and _now() - last < FixData.CHECK_EVERY_S:
			return "not_due"
	var cos := _cosign()
	if cos == "":
		data_result = "no-cosign"   # no way to check the signature here: the built-in definitions stay
		return "no-cosign"
	_life["data_checked"] = _now()
	_save_life()
	DirAccess.make_dir_recursive_absolute(_data_dir())
	FixData.discard(_data_dir())
	_data_step = 0
	_run_data_step(cos)
	return ""


func _run_data_step(cos := "") -> void:
	var steps := FixData.fetch_steps(_data_dir(), cos if cos != "" else _cosign())
	var step: Array = steps[_data_step]
	commands.run("data:step", step[0], step[1])


func _data_finished(code: int) -> void:
	if _data_step < 0:
		return
	if code != 0:
		# step 0 / 1: no network or no file; step 2: cosign refused the signature
		data_result = "bad" if _data_step == 2 else "offline"
		FixData.discard(_data_dir())
		_data_step = -1
	elif _data_step < 2:
		_data_step += 1
		_run_data_step()
		return
	else:
		data_result = FixData.accept(_data_dir())
		_data_step = -1
		if data_result == "verified":
			reload_definitions()
	if data_result in ["bad", "schema", "older"]:
		push_warning("Fixes: the downloaded fix definitions weren't used (%s); the built-in ones stay." % data_result)
	if _eval_wanted != "" and not _game_running:
		_evaluate()
	else:
		changed.emit(rows())


func _managed(e: Dictionary) -> bool:
	return str(e.get("kind", "")) in Life.MANAGED_KINDS and str(e.get("page", "fixes")) == "fixes"


## Asks the installed fixes (all of them on a full pass) for their status and the tools the
## rules name for their versions; _plan() runs when every answer is in.
func _evaluate() -> void:
	if _refreshing:
		return   # runs when the override rebuild is done ("refresh" in _on_finished)
	var full := _eval_wanted == "full"
	_eval_wanted = ""
	_facts = Cond.gather(sys_root).merged({"tools": _facts.get("tools", {})}, true)
	_judged.clear()
	var applied := installer_applied()
	var pend := Life.pending(_life, device_id)
	var tools: Array = []
	var ask: Array = []
	for e in entries():
		var life: Dictionary = e.get("lifecycle", {}) if e.get("lifecycle") is Dictionary else {}
		Cond.tools_in(life.get("obsolete_when"), tools)
		Cond.tools_in(life.get("needed_when"), tools)
		if not _managed(e):
			continue
		var id: String = e["id"]
		if full or id in applied or choice(id) == "on" or pend.has(id) or str(_status.get(id, {}).get("installed", "")) == "yes":
			ask.append(id)
	var pm := _package_query()
	for t in tools if not pm.is_empty() else []:
		_eval_wait["tool:" + t] = true
	for id in ask:
		_eval_wait["life:" + id] = true
	if _eval_wait.is_empty():
		_plan()
		return
	for t in tools if not pm.is_empty() else []:
		commands.run("tool:" + t, pm[0], PackedStringArray((pm[1] as Array) + [Cond.TOOL_PACKAGES[t][0]]))
	for id in ask:
		_status.erase(id)
		commands.run("life:" + id, FIX_HELPER, PackedStringArray([id, "status"]))


## How this system answers "which version of a package is installed": [program, args...] or [].
func _package_query() -> Array:
	if FileAccess.file_exists(sys_root + "/usr/bin/rpm"):
		return ["rpm", ["-q", "--qf", "%{VERSION}"]]
	if FileAccess.file_exists(sys_root + "/usr/bin/pacman"):
		return ["pacman", ["-Q"]]
	return []


func _tool_answer(tool: String, code: int, output: String) -> void:
	var tools: Dictionary = (_facts.get("tools", {}) as Dictionary).duplicate()
	tools[tool] = Cond.parse_package_version(output) if code == 0 else ""
	_facts["tools"] = tools
	_judged.clear()


func _eval_done(id: String) -> void:
	if not _eval_wait.has(id):
		return
	_eval_wait.erase(id)
	if _eval_wait.is_empty():
		_plan()


## Every answer is in: queue what the rules ask for, then run it one fix at a time.
func _plan() -> void:
	_eval_queue.clear()
	var pend := Life.pending(_life, device_id)
	for e in entries():
		if not _managed(e):
			continue
		var id: String = e["id"]
		var j := judgement(id)
		if j["action"] == "":
			if pend.has(id):
				pend.erase(id)   # nothing to do any more (the user did it, or the rule no longer holds)
			continue
		# one that failed isn't tried again by itself until something changed (a new revision, a
		# system update); the page keeps its button
		var had: Dictionary = pend.get(id, {}) if pend.get(id) is Dictionary else {}
		if str(had.get("failed", "")) == _attempt_key(id) and str(had.get("action", "")) == j["action"]:
			continue
		_eval_queue.append({"fix": id, "action": j["action"], "reason": j["reason"]})
	_save_life()
	_next_action()


func _attempt_key(fix: String) -> String:
	return "%s|%s" % [Cond.system_key(_facts), str(_status.get(fix, {}).get("revision", ""))]


func _next_action() -> void:
	if _eval_queue.is_empty() or _game_running:
		# a game started meanwhile: what is left waits for start_lifecycle() after it
		if _game_running and not _eval_queue.is_empty():
			_eval_wanted = "start"
			_eval_queue.clear()
		changed.emit(rows())
		if not _game_running and not _attention_said:
			var items := attention()
			if not items.is_empty():
				_attention_said = true
				attention_needed.emit(items)
		return
	var a: Dictionary = _eval_queue.pop_front()
	var fix: String = a["fix"]
	if _working.has(fix):
		_next_action()
		return
	if not can_prompt():
		_wait_for_desktop(fix, a["action"], a["reason"])
		_next_action()
		return
	_eval_active = fix
	_working[fix] = "undo" if a["action"] == "retire" else "apply"
	Life.pending(_life, device_id)[fix] = {"action": a["action"], "reason": a["reason"],
		"since": int(Life.pending(_life, device_id).get(fix, {}).get("since", _now())), "told": true, "running": true}
	changed.emit(rows())
	commands.run("auto-%s:%s" % [a["action"], fix], "pkexec",
		PackedStringArray([FIX_HELPER, fix, "remove" if a["action"] == "retire" else "update"]))


## Gaming Mode can't ask for the admin password: the change waits, and is said once.
func _wait_for_desktop(fix: String, action: String, reason: String) -> void:
	var pend := Life.pending(_life, device_id)
	var had: Dictionary = pend.get(fix, {}) if pend.get(fix) is Dictionary else {}
	var told := bool(had.get("told", false)) and str(had.get("action", "")) == action
	pend[fix] = {"action": action, "reason": reason, "since": int(had.get("since", _now())), "told": true}
	_save_life()
	# one that does harm meanwhile is shown at every start instead (attention_needed)
	if not told and not harmful(fix):
		lifecycle_notice.emit(Texts.waiting(_title(fix), action, reason, _withdrawn_reason(fix)), "warn")


func _title(fix: String) -> String:
	return str(entry(fix).get("title", fix))


func _withdrawn_reason(fix: String) -> String:
	var w: Variant = entry(fix).get("withdrawn")
	return str(w.get("reason", "")) if w is Dictionary else ""


func _auto_finished(action: String, fix: String, code: int, output: String) -> void:
	var pend := Life.pending(_life, device_id)
	var p: Dictionary = pend.get(fix, {}) if pend.get(fix) is Dictionary else {}
	p.erase("running")
	p["code"] = code
	var detail := ""
	for line in output.split("\n", false):
		if line.strip_edges() != "":
			detail = line.strip_edges().trim_prefix(fix + ": ").trim_prefix("error: ")
	p["detail"] = detail
	p["action"] = action
	pend[fix] = p
	# whatever the exit code says, the fix's own status is what counts
	commands.run("verify:" + fix, FIX_HELPER, PackedStringArray([fix, "status"]))


func _auto_verified(fix: String) -> void:
	var pend := Life.pending(_life, device_id)
	var p: Dictionary = pend.get(fix, {}) if pend.get(fix) is Dictionary else {}
	var action := str(p.get("action", ""))
	var reason := str(p.get("reason", ""))
	var code := int(p.get("code", 1))
	var st: Dictionary = _status.get(fix, {})
	var installed := str(st.get("installed", "")) == "yes"
	_working.erase(fix)
	_eval_active = ""
	var title := _title(fix)
	var entry_ := {"time": _now(), "device": device_id, "fix": fix, "title": title, "reason": reason,
		"detail": str(p.get("detail", "")), "undone": false}
	if code in [126, 127]:
		# nobody could say yes (dismissed, or no agent after all): it waits, nothing changed
		pend[fix] = {"action": action, "reason": reason, "since": int(p.get("since", _now())), "told": true}
		_save_life()
		lifecycle_notice.emit(Texts.waiting(title, action, reason, _withdrawn_reason(fix)), "warn")
		_next_action()
		return
	pend.erase(fix)
	if action == "retire":
		if code == 0 and not installed and not st.is_empty():
			entry_["action"] = "removed"
			_remember_choice(fix, "undo")   # installer repairs and updates must not put it back
			lifecycle_notice.emit(Texts.removed(title, reason, _withdrawn_reason(fix)), "good")
		else:
			entry_["action"] = "remove-failed"
			pend[fix] = {"action": "retire", "reason": reason, "since": int(p.get("since", _now())), "told": true, "failed": _attempt_key(fix)}
			lifecycle_notice.emit(Texts.REMOVE_FAILED % [title, ": " + entry_["detail"] if entry_["detail"] != "" else ""], "warn")
	else:
		var current := str(st.get("installed_revision", "")) == str(st.get("revision", "x"))
		if code == 0 and installed and current:
			entry_["action"] = "updated"
			entry_["detail"] = "revision %s" % str(st.get("revision", ""))
			lifecycle_notice.emit(Texts.UPDATED % title, "good")
		elif installed:
			entry_["action"] = "update-failed"   # the helper put the old version back
			pend[fix] = {"action": "update", "reason": reason, "since": int(p.get("since", _now())), "told": true, "failed": _attempt_key(fix)}
			lifecycle_notice.emit(Texts.UPDATE_FAILED % title, "warn")
		else:
			entry_["action"] = "update-removed"  # boot-level fixes: taken out cleanly instead
			lifecycle_notice.emit(Texts.UPDATE_REMOVED % title, "warn")
	Life.add_history(_life, entry_)
	_save_life()
	_next_action()


## A fix waiting to come out does harm while it stays: it was withdrawn, or the system now does
## the same thing and the two clash (lifecycle.both_active "conflict"), unless the fix's own status
## says it already stands aside (conflict=no: claw8ex-buttons after the no-password rebuild).
func harmful(fix: String) -> bool:
	var e := entry(fix)
	if e.get("withdrawn") is Dictionary:
		return true
	var life: Dictionary = e.get("lifecycle", {}) if e.get("lifecycle") is Dictionary else {}
	if str(life.get("both_active", "harmless")) != "conflict" or judgement(fix)["obsolete"] != Cond.YES:
		return false
	return str(_status.get(fix, {}).get("conflict", "")) != "no"


## What attention_needed carries: every retirement waiting for the admin password that does harm
## meanwhile (harmful()). Asked again at every start; empty once they are out or kept.
func attention() -> Array:
	var out: Array = []
	var pend := Life.pending(_life, device_id)
	for fix in pend:
		var p: Variant = pend[fix]
		if not p is Dictionary or str(p.get("action", "")) != "retire" or bool(p.get("running", false)):
			continue
		if kept(fix) or not harmful(fix):
			continue
		out.append({"id": fix, "title": _title(fix), "reason": str(p.get("reason", "")), "withdrawn": _withdrawn_reason(fix)})
	return out


## "Keep the workaround anyway": GameCove stops removing this fix by itself and, when it already
## did, applies it again (admin password, like any Apply). False when it couldn't start.
func keep(fix: String) -> bool:
	var e := entry(fix)
	if e.is_empty() or not _managed(e) or _working.has(fix):
		return false
	Life.set_kept(_life, device_id, fix, true)
	Life.pending(_life, device_id).erase(fix)
	for h in _life["history"]:
		if h is Dictionary and str(h.get("device", "")) == device_id and str(h.get("fix", "")) == fix and str(h.get("action", "")) == "removed":
			h["undone"] = true
	Life.add_history(_life, {"time": _now(), "device": device_id, "fix": fix, "title": _title(fix), "action": "kept",
		"reason": "user", "detail": "", "undone": false})
	_save_life()
	_judged.erase(fix)
	changed.emit(rows())
	if str(_status.get(fix, {}).get("installed", "")) == "yes":
		return true
	# a withdrawn fix stays out: keeping only stops GameCove removing one that is still there
	if e.get("withdrawn") is Dictionary:
		return true
	return act(fix, "apply")


## Run what waits for the admin password now (the page's "Remove now" / "Update now").
func run_pending(fix: String) -> bool:
	var p: Variant = Life.pending(_life, device_id).get(fix)
	if not p is Dictionary or _working.has(fix) or _game_running:
		return false
	for q in _eval_queue:
		if q["fix"] == fix:
			return true
	_eval_queue.append({"fix": fix, "action": str(p.get("action", "retire")), "reason": str(p.get("reason", "native"))})
	if _eval_active != "":
		return true   # one is running: this one follows it (_auto_verified runs the queue on)
	var was: Variant = can_prompt_override
	if not can_prompt():
		# asked for by hand: try anyway, the helper's exit code says when nobody could answer
		can_prompt_override = true
	_next_action()
	can_prompt_override = was
	return true
