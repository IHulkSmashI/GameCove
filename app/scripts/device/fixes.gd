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
## Not an autoload: the page (or whoever owns it) makes one, calls setup(ctx)
## and refresh(). Everything runs through ctx.runner (BgCommand off the main
## thread when in the tree; synchronously in tests), all paths under
## ctx.sys_root / ctx.home. Nothing polls: status is read on refresh(), after
## an action, and after a system update.

signal changed(rows: Array)
## verb: "apply" | "undo" | "check". message: one plain line for a toast.
signal action_finished(fix: String, verb: String, ok: bool, message: String)

const SettingsFile := preload("res://scripts/system/settings_file.gd")
const BgCommand := preload("res://scripts/ui/bg_command.gd")
const Texts := preload("res://scripts/ui/texts_fixes.gd")
const PerDevice := preload("res://scripts/device/per_device.gd")
const Traits := preload("res://scripts/device/traits.gd")
const DeviceScript := preload("res://scripts/device/device.gd")
const DEVICE_TABLE := "res://data/devices.json"

const CATALOGUE := "res://data/fixes.json"
const FIX_HELPER := "/usr/libexec/gamecove/gamecove-fix"
const FIX_SET_HELPER := "/usr/libexec/gamecove/gamecove-fix-set"
## GameCove's InputPlumber override for the Claw 8 EX shadows this stock file (fixes/lib/claw8ex-common.sh).
const IP_STOCK := "/usr/share/inputplumber/devices/50-msi_claw8_ex_ai_cg3em.yaml"
const IP_OVERRIDE := "/etc/inputplumber/devices.d/50-msi_claw8_ex_ai_cg3em.yaml"
## Helper state= -> page status (see status_of for the rest).
const STATE_STATUS := {"on": "applied", "restart": "restart", "partial": "partial", "os-fixed": "os-fixed",
	"not-needed": "not-needed", "n/a": "not-needed", "unsupported": "blocked", "other-override": "blocked"}

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


func _init() -> void:
	commands = BgCommand.new()
	commands.name = "Commands"
	add_child(commands)
	commands.finished.connect(_on_finished)
	catalogue = load_catalogue(CATALOGUE)


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
	_status.clear()


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
	for e in entries():
		if str(e.get("kind", "")) == "app":
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
	if not _status.has(fix):
		return "checking"
	var st: String = str(_status[fix].get("state", ""))
	if st == "":
		return "unknown"
	if st == "off":
		return "needed" if is_auto(fix) else "available"
	return STATE_STATUS.get(st, "unknown")


## One row per fix for the page.
func rows() -> Array:
	var applied := installer_applied()
	var out: Array = []
	for e in entries():
		var id: String = e["id"]
		var s := status_of(id)
		var admin := str(e.get("password", "admin")) == "admin"
		out.append({
			"id": id, "title": str(e.get("title", id)), "line": str(e.get("line", "")),
			"symptom": str(e.get("symptom", "")), "kind": str(e.get("kind", "")),
			"auto": is_auto(id), "auto_applied": is_auto(id) and (id in applied or str(e.get("kind", "")) == "app") and s in ["applied", "restart"],
			"status": s, "restart": str(e.get("restart", "")), "admin": admin,
			"can_apply": s in ["needed", "available"],
			"can_undo": s in ["applied", "restart", "partial"],
			"can_check": s == "unknown",
			"sources": e.get("sources", []), "bazzite": str(e.get("bazzite", "")), "steamos": str(e.get("steamos", "")),
			"why": why(id),
			"reason": str(_status.get(id, {}).get("reason", "")),
		})
	return out


func counts() -> Dictionary:
	var c := {"applied": 0, "available": 0, "os-fixed": 0, "not-needed": 0}
	for r in rows():
		match r["status"]:
			"applied", "restart":
				c["applied"] += 1
			"needed", "available":
				c["available"] += 1
			"os-fixed":
				c["os-fixed"] += 1
			"not-needed":
				c["not-needed"] += 1
	return c


# ------------------------------------------------------------------ actions

## Apply (verb "apply") or Undo ("undo") one fix. False when it can't start.
func act(fix: String, verb: String) -> bool:
	var e := entry(fix)
	if e.is_empty() or _working.has(fix) or not verb in ["apply", "undo", "check"]:
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
	var args: PackedStringArray
	if str(e.get("password", "admin")) == "none":
		args = PackedStringArray([FIX_SET_HELPER, fix, "set", "on" if verb == "apply" else "off"])
	else:
		args = PackedStringArray([FIX_HELPER, fix, "install" if verb == "apply" else "remove"])
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
		"status":
			_status[fix] = parse_status(output) if code == 0 else {}
		"refresh":
			if code != 0:
				push_warning("Fixes: couldn't rebuild the InputPlumber override (%d): %s" % [code, output.strip_edges()])
			refresh()
		"apply", "undo":
			_working.erase(fix)
			var e := entry(fix)
			var ok := code == 0
			if ok:
				_remember_choice(fix, kind)
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
	return commands.run("refresh:inputplumber", "pkexec",
		PackedStringArray([FIX_SET_HELPER, "claw8ex-buttons", "set", "refresh"]))


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
	SettingsFile.save_json(path, now, "  ")
	last_changes = {"first_run": not old is Dictionary, "changed": changes}
	# every start, not only after a change: cheap, and the update may have come before this check existed
	refresh_stale_override()
	if not changes.is_empty():
		refresh()
	return last_changes


## After an update: GameCove fixes that the system now does itself.
func now_os_fixed() -> Array:
	var out: Array = []
	for e in entries():
		var st: Dictionary = _status.get(e["id"], {})
		if str(st.get("os_fixed", "")) == "yes" and str(st.get("installed", "")) == "yes":
			out.append(e["id"])
	return out
