extends RefCounted
## Device matrix harness: loads Controls providers against the fake handhelds
## tools/devicematrix/gen.py builds (every devices.json row + an unlisted AMD
## and Intel handheld) and checks the safety rules every control must keep.
## Used by tests/test_device_matrix.gd; docs in docs/CONTROLS.md "Device matrix".
##
## Scenarios, in this order, each with fresh provider instances:
##   battery  services up, charger unplugged; every available control is
##            written (past both ends, the middle, every choice, invalid values)
##            and put back
##   ac       the same with the charger plugged in
##   failing  services answer reads but refuse every write (and sysfs files are
##            read-only when not running as root): a failed write must leave the
##            control's value and the hardware as they were
##   bare     nothing answers (runner exits 127, no hhd): detection must say why
##
## Checks: detect never crashes or hangs; available <-> reason == ""; reasons
## short, one line; ids "group.name", no two providers share an id; ranges and
## written values inside the device limits (expectations.json "invariants");
## the fake sysfs stays sane (backlight never 0, PPT/RAPL limits inside the
## row's range, cpu0 online, governors/EPP from the offered lists, Intel media
## GT untouched...); D-Bus TDP/charge values and root-helper arguments inside
## limits; no command argument names a real /sys, /proc, /dev... path; provider
## sources don't run programs or touch real paths themselves (lint).

const ControlsScript := preload("res://scripts/controls/controls.gd")
const DeviceScript := preload("res://scripts/device/device.gd")

const PROVIDERS_DIR := "res://scripts/controls/providers"
const SCENARIOS: Array[String] = ["battery", "ac", "failing", "bare"]
const REAL_PREFIXES: Array[String] = ["/sys/", "/proc/", "/dev/", "/etc/", "/var/", "/run/", "/tmp/", "/home/", "/root/"]
## Real paths that are fine to name ("tail -f /dev/null" keeps a process alive).
const HARMLESS_PATHS: Array[String] = ["/dev/null", "/dev/zero"]
const SLOW_HOOK_MS := 1500
const REASON_MAX := 100
const INVALID := "__devicematrix_invalid__"
const EXPECT_KEYS: Array[String] = ["available", "reason_contains", "kind", "unit", "min", "max", "min_ge", "max_le",
	"step", "options_include", "options_exclude", "value", "ac", "note"]

static var _manifest_cache: Dictionary = {}


# ---- fakes --------------------------------------------------------------------

## command_runner.gd stand-in driven by backends.json. Stateful D-Bus props.
class FakeRunner extends RefCounted:
	var props: Dictionary = {}
	var methods: Dictionary = {}
	var commands: Array = []
	var mode := "ok"            # ok | failing | bare
	var calls: Array = []       # [program, PackedStringArray]
	var unmatched: Array[String] = []
	var _mutex := Mutex.new()

	var xroot: Dictionary = {}     # gamescope root atoms: name -> "v1, v2"

	func _init(backends: Dictionary, run_mode: String) -> void:
		xroot = backends.get("xprop_root", {}).duplicate()
		props = backends.get("dbus", {}).get("props", {}).duplicate(true)
		methods = backends.get("dbus", {}).get("methods", {}).duplicate(true)
		commands = backends.get("commands", [])
		mode = run_mode

	func run(program: String, args: PackedStringArray) -> Dictionary:
		_mutex.lock()
		calls.append([program, args])
		_mutex.unlock()
		if mode == "bare":
			return {"code": 127, "out": ""}
		if program == "busctl":
			return _busctl(args)
		if program == "xprop" and args.size() > 0 and args[0] == "-root":
			return _xprop(args)
		var argv: Array = [program] + Array(args)
		for rule in commands:
			if _match(rule.get("argv", []), argv):
				if mode == "failing" and bool(rule.get("write", false)):
					return {"code": 1, "out": ""}
				return {"code": int(rule.get("code", 0)), "out": str(rule.get("out", ""))}
		_mutex.lock()
		unmatched.append(" ".join(PackedStringArray(argv)))
		_mutex.unlock()
		return {"code": 127, "out": ""}

	## xprop -root -notype [ATOM] / xprop -root -f ATOM 32c -set ATOM v,v
	func _xprop(args: PackedStringArray) -> Dictionary:
		var a := Array(args)
		if a.has("-set"):
			if mode == "failing":
				return {"code": 1, "out": ""}
			var i := a.find("-set")
			if i + 2 >= a.size():
				return {"code": 1, "out": ""}
			_mutex.lock()
			xroot[str(a[i + 1])] = ", ".join(str(a[i + 2]).split(","))
			_mutex.unlock()
			return {"code": 0, "out": ""}
		if a.has("-remove"):
			if mode == "failing":
				return {"code": 1, "out": ""}
			xroot.erase(str(a[a.find("-remove") + 1]))
			return {"code": 0, "out": ""}
		var atoms := a.filter(func(x): return not str(x).begins_with("-"))
		var lines := PackedStringArray()
		for k in (atoms if not atoms.is_empty() else xroot.keys()):
			lines.append("%s = %s" % [k, xroot[k]] if xroot.has(k) else "%s:  not found." % k)
		return {"code": 0, "out": "\n".join(lines)}

	## Background processes (systemd-inhibit...): recorded, never started.
	var spawned: Dictionary = {}   # pid -> argv

	func spawn(program: String, args: PackedStringArray) -> int:
		_mutex.lock()
		calls.append([program, args])
		var pid := 0
		if mode != "bare":
			pid = 90000 + spawned.size()
			spawned[pid] = [program] + Array(args)
		_mutex.unlock()
		return pid

	func kill(pid: int) -> int:
		spawned.erase(pid)
		return OK

	func is_running(pid: int) -> bool:
		return spawned.has(pid)

	func _busctl(args: PackedStringArray) -> Dictionary:
		var a := Array(args).filter(func(x): return not str(x).begins_with("--timeout") and not str(x).begins_with("--json"))
		if a.size() < 2:
			return {"code": 1, "out": ""}
		var bus: String = a[0]
		match a[1]:
			"get-property":
				var key := " ".join(PackedStringArray([bus] + a.slice(2, 6)))
				if props.has(key):
					return {"code": 0, "out": JSON.stringify(props[key])}
			"set-property":
				var key := " ".join(PackedStringArray([bus] + a.slice(2, 6)))
				if props.has(key) and a.size() >= 8:
					if mode == "failing":
						return {"code": 1, "out": ""}
					var sig: String = a[6]
					var raw: String = a[7]
					props[key]["data"] = float(raw) if sig == "d" else (int(raw) if sig in ["u", "i", "y", "q", "n", "t", "x"] \
						else (raw == "true" if sig == "b" else raw))
					return {"code": 0, "out": ""}
			"call":
				var key := " ".join(PackedStringArray([bus] + a.slice(2, 6)))
				if methods.has(key):
					return {"code": 0, "out": JSON.stringify(methods[key])}
				if mode == "failing":
					return {"code": 1, "out": ""}
		return {"code": 1, "out": ""}

	static func _match(pattern: Array, argv: Array) -> bool:
		for i in pattern.size():
			var p := str(pattern[i])
			if p == "**":
				return true
			if i >= argv.size() or not str(argv[i]).match(p):
				return false
		return pattern.size() == argv.size()

	func prop_value(name: String) -> Array:
		var out := []
		for k in props:
			if str(k).ends_with(" " + name):
				out.append(props[k]["data"])
		return out


## hhd_http.gd stand-in: GET version/state, POST merges into the state.
class FakeHhd extends RefCounted:
	var state: Dictionary = {}
	var up := true
	var posts: Array = []
	var _mutex := Mutex.new()

	func _init(s: Variant, is_up: bool) -> void:
		state = s.duplicate(true) if s is Dictionary else {}
		up = is_up and s is Dictionary

	func request(method: String, path: String, headers: PackedStringArray, body := "") -> Dictionary:
		if not up:
			return {"code": 0, "body": ""}
		if not "Authorization: Bearer devicematrix-token" in headers:
			return {"code": 401, "body": ""}
		if method == "GET" and path == "/api/v1/version":
			return {"code": 200, "body": JSON.stringify({"version": int(state.get("version", 5))})}
		if path == "/api/v1/state":
			if method == "POST":
				var patch: Variant = JSON.parse_string(body)
				if not patch is Dictionary:
					return {"code": 400, "body": ""}
				_mutex.lock()
				posts.append(patch)
				_merge(state, patch)
				_mutex.unlock()
			return {"code": 200, "body": JSON.stringify(state)}
		return {"code": 404, "body": ""}

	static func _merge(into: Dictionary, patch: Dictionary) -> void:
		for k in patch:
			if patch[k] is Dictionary and into.get(k) is Dictionary:
				_merge(into[k], patch[k])
			else:
				into[k] = patch[k]


# ---- fixtures -----------------------------------------------------------------

## The generated matrix: DEVICEMATRIX_DIR when it holds one, else generated
## now into user://devicematrix (once per run). {} + error on failure.
static func manifest() -> Dictionary:
	if not _manifest_cache.is_empty():
		return _manifest_cache
	var dir := OS.get_environment("DEVICEMATRIX_DIR")
	if dir == "" or not FileAccess.file_exists(dir.path_join("manifest.json")):
		if dir == "":
			dir = OS.get_user_data_dir().path_join("devicematrix")
		var gen := ProjectSettings.globalize_path("res://").path_join("../tools/devicematrix/gen.py").simplify_path()
		var out := []
		var code := OS.execute("python3", PackedStringArray(["-I", gen, dir]), out, true)
		if code != 0:
			return {"error": "gen.py failed (%d): %s" % [code, "".join(PackedStringArray(out.map(func(x): return str(x))))]}
	var m: Variant = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("manifest.json")))
	if not m is Dictionary:
		return {"error": "no manifest in " + dir}
	_manifest_cache = m
	return m


static func expectations() -> Dictionary:
	var p := ProjectSettings.globalize_path("res://").path_join("../tools/devicematrix/expectations.json").simplify_path()
	var e: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	return e if e is Dictionary else {}


static func provider_scripts(dir := PROVIDERS_DIR) -> Array[String]:
	var names: Array[String] = []
	for f in DirAccess.get_files_at(dir):
		var n := f.trim_suffix(".remap")
		if n.ends_with(".gd") and not names.has(n):
			names.append(n)
	names.sort()
	var out: Array[String] = []
	for n in names:
		out.append(dir.path_join(n))
	return out


# ---- running ------------------------------------------------------------------

## Runs every provider script against one fixture in every scenario.
## Returns {"problems": [String], "report": {scenario: {id: description}},
##          "unmatched": [command lines no canned answer covered]}.
static func run_device(info: Dictionary, scripts: Array, expect: Dictionary) -> Dictionary:
	var problems: Array[String] = []
	var report := {}
	var unmatched := {}
	var backends: Variant = JSON.parse_string(FileAccess.get_file_as_string(str(info["backends"])))
	if not backends is Dictionary:
		return {"problems": ["%s: backends.json unreadable" % info["id"]], "report": {}, "unmatched": []}
	var root := str(info["root"])
	var original := _snapshot_files(root)
	for scenario in SCENARIOS:
		_set_ac(info, scenario == "ac")
		var ro := scenario == "failing"
		if ro:
			_set_read_only(root, original.keys(), true)
		var r := _run_scenario(info, scripts, backends, scenario, original, expect)
		if ro:
			_set_read_only(root, original.keys(), false)
		for p in r["problems"]:
			problems.append("%s [%s] %s" % [info["id"], scenario, p])
		report[scenario] = r["report"]
		for u in r["unmatched"]:
			unmatched[u] = true
	_set_ac(info, false)
	return {"problems": problems, "report": report, "unmatched": unmatched.keys()}


static func _run_scenario(info: Dictionary, scripts: Array, backends: Dictionary, scenario: String,
		original: Dictionary, expect: Dictionary) -> Dictionary:
	var problems: Array[String] = []
	var root := str(info["root"])
	var runner := FakeRunner.new(backends, {"failing": "failing", "bare": "bare"}.get(scenario, "ok"))
	var hhd := FakeHhd.new(backends.get("hhd"), scenario != "bare")
	var dev: Node = DeviceScript.new()
	dev.root = root
	dev.home = str(info["home"])
	dev.detect()
	var row: Dictionary = dev.profile
	if dev.id() != str(info["expect_row"]):
		problems.append("DMI resolved to %s, expected %s" % [dev.id(), info["expect_row"]])
	var ctx := {"sys_root": root, "runner": runner, "home": str(info["home"]), "device": dev,
		"hhd_transport": hhd, "devicematrix": scenario, "env": session_env(info, scenario),
		"config_path": str(info["home"]).path_join(".config/gamecove/devicematrix-%s.cfg" % scenario)}
	var reg: Node = ControlsScript.new()
	reg.sync_mode = true
	reg.setup(ctx)
	var owner := {}
	for path in scripts:
		var script: Variant = load(path)
		if script == null or not script.can_instantiate():
			problems.append("%s does not load" % path)
			continue
		var p: Object = script.new()
		if p.has_method("setup"):
			p.setup(ctx)
		if not p.has_method("controls"):
			problems.append("%s has no controls()" % path)
			continue
		var list: Variant = p.controls()
		if not list is Array:
			problems.append("%s controls() is not an Array" % path)
			continue
		for c in list:
			if not c is RefCounted or not "id" in c:
				problems.append("%s returned something that isn't a Control" % path)
				continue
			if owner.has(c.id):
				problems.append("%s and %s both register %s" % [owner[c.id], path.get_file(), c.id])
			owner[c.id] = path.get_file()
			if not (c.id is String and "." in c.id and c.id.begins_with(str(c.group) + ".")):
				problems.append("%s: id must be \"<group>.<name>\" (group %s)" % [c.id, c.group])
			if not str(c.group) in ControlsScript.GROUPS:
				problems.append("%s: unknown group %s" % [c.id, c.group])
				continue
			reg.register(c)
	var desc := {}
	for c in reg.list():
		var t0 := Time.get_ticks_msec()
		c.detect()
		c.read()
		var ms := Time.get_ticks_msec() - t0
		if ms > SLOW_HOOK_MS:
			problems.append("%s: detect+read took %d ms" % [c.id, ms])
		problems.append_array(_check_shape(c, row))
		desc[c.id] = _describe(c)
	if scenario in ["battery", "ac"]:
		var seen := {}
		var hot := func() -> void:
			for p in critical_problems(root, row):
				if not seen.has(p):
					seen[p] = true
					problems.append(p)
		for c in reg.list():
			problems.append_array(_exercise(c, hot))
		problems.append_array(hardware_problems(root, row, info, original).filter(func(p): return not seen.has(p)))
		problems.append_array(backend_problems(runner, hhd, row, expect.get("invariants", {})))
		problems.append_array(check_expectations(str(info["id"]), info, row, reg, expect, scenario))
	elif scenario == "failing":
		for c in reg.list():
			problems.append_array(_exercise_failing(c))
		problems.append_array(hardware_problems(root, row, info, original))
	problems.append_array(real_path_args(runner, root))
	for id in desc:
		desc[id]["after"] = reg.control(id).value
	var unmatched := runner.unmatched.duplicate()
	reg.free()
	dev.free()
	return {"problems": problems, "report": desc, "unmatched": unmatched}


## The session environment providers see (ctx.env), so the machine running the
## test never leaks in: a gamescope session, or nothing in "bare".
static func session_env(info: Dictionary, scenario: String) -> Dictionary:
	var on := scenario != "bare"
	var root := str(info["root"])
	return {"GAMESCOPE_WAYLAND_DISPLAY": "gamescope-0" if on else "", "DISPLAY": ":0" if on else "",
		"XDG_RUNTIME_DIR": root + "/run/user/1000", "HOME": str(info["home"]), "XDG_SESSION_TYPE": "x11" if on else "",
		"STEAM_DISPLAY_REFRESH_LIMITS": "", "CUSTOM_REFRESH_RATES": "", "WAYLAND_DISPLAY": "",
		"DBUS_SESSION_BUS_ADDRESS": "unix:path=" + root + "/run/user/1000/bus"}


static func _describe(c: Object) -> Dictionary:
	var d := {"available": c.available, "reason": c.reason, "kind": c.kind, "value": c.value}
	if c.kind == "slider":
		d.merge({"min": c.min_value, "max": c.max_value, "step": c.step, "unit": c.unit})
	elif c.kind == "choice":
		d["options"] = c.options.map(func(o): return o.get("value") if o is Dictionary else o)
	return d


static func _check_shape(c: Object, row: Dictionary) -> Array[String]:
	var out: Array[String] = []
	if not c.reason is String:
		out.append("%s: reason is not text" % c.id)
		return out
	if c.available != (c.reason == ""):
		out.append("%s: available=%s but reason=%s" % [c.id, c.available, c.reason])
	if not c.available:
		if c.reason == "" or c.reason == "Not checked yet":
			out.append("%s: unavailable without a reason" % c.id)
		if c.reason.length() > REASON_MAX or "\n" in c.reason:
			out.append("%s: reason should be one short line: %s" % [c.id, c.reason])
	if not c.kind in ["slider", "choice", "toggle", "color", "action"]:
		out.append("%s: unknown kind %s" % [c.id, c.kind])
	if c.available and c.kind == "slider":
		if not (c.max_value > c.min_value) or c.step < 0.0:
			out.append("%s: bad range %s..%s step %s" % [c.id, c.min_value, c.max_value, c.step])
	if c.available and c.kind == "choice":
		if c.options.is_empty():
			out.append("%s: choice without options" % c.id)
		for o in c.options:
			if not (o is Dictionary and o.has("value") and o.has("label")):
				out.append("%s: option needs value and label: %s" % [c.id, o])
	if c.available and c.default_value != null and c.kind != "action" and c.coerce(c.default_value) == null:
		out.append("%s: default %s is not a valid value" % [c.id, c.default_value])
	return out


## Writes past both ends, the middle, choices and invalid values; puts the
## original back.
static func _exercise(c: Object, hot: Callable) -> Array[String]:
	var out: Array[String] = []
	if not c.available or c.kind == "action":
		return out   # actions (sleep, screenshot) are never fired by the matrix
	var before: Variant = c.value
	var tries: Array = []
	match c.kind:
		"slider":
			tries = [c.max_value + 1000.0, c.min_value - 1000.0, (c.min_value + c.max_value) / 2.0]
		"choice":
			tries = c.options.slice(0, 8).map(func(o): return o.get("value"))
		"toggle":
			tries = [not bool(before) if before != null else true, bool(before) if before != null else false]
		"color":
			tries = ["#ff0000", "#00ff80"]
	for v in tries:
		if c.write(v):
			if c.kind == "slider" and (c.value < c.min_value or c.value > c.max_value):
				out.append("%s: value %s outside %s..%s after writing %s" % [c.id, c.value, c.min_value, c.max_value, v])
			if c.kind == "slider":
				hot.call()   # the hardware right after an extreme value, before it's put back
	hot.call()
	var bads: Array = [null, INVALID, [1, 2]]
	if c.kind in ["choice", "color"]:
		bads.append(-987654321)
	for bad in bads:
		if c.kind != "action" and c.write(bad):
			out.append("%s: accepted invalid value %s" % [c.id, bad])
	if before != null and c.coerce(before) != null:
		c.write(before)
	return out


## Every write is refused below: value and hardware must stay as they were.
static func _exercise_failing(c: Object) -> Array[String]:
	var out: Array[String] = []
	if not c.available or c.kind == "action":
		return out
	var before: Variant = c.value
	var v: Variant = null
	match c.kind:
		"slider":
			v = c.max_value if before != c.max_value else c.min_value
		"choice":
			for o in c.options:
				if str(o.get("value")) != str(before):
					v = o.get("value")
					break
		"toggle":
			v = not bool(before) if before != null else true
		"color":
			v = "#123456"
	if v == null:
		return out
	var wrote: bool = c.write(v)
	if not wrote and str(c.value) != str(before):
		out.append("%s: value changed to %s although the write failed" % [c.id, c.value])
	if not wrote:
		var now: Variant = c.read()
		if before != null and now != null and str(now) != str(before):
			out.append("%s: hardware now reads %s after a failed write (was %s): not restored" % [c.id, now, before])
	return out


# ---- checks -------------------------------------------------------------------

## The fake sysfs after the writes. Structural rules that hold on every handheld.
static func hardware_problems(root: String, row: Dictionary, info: Dictionary, original: Dictionary) -> Array[String]:
	var out: Array[String] = []
	for f in original:
		var now := _read(root + f)
		if now == "" and original[f] != "":
			out.append("%s emptied" % f)
	out.append_array(critical_problems(root, row))
	out.append_array(_cpu_gpu_problems(root, info, original))
	return out


## The checks cheap enough to run after every extreme write: backlight, LEDs,
## power limits, fans, charge limit.
static func critical_problems(root: String, row: Dictionary) -> Array[String]:
	var out: Array[String] = []
	var t: Dictionary = row.get("tdp", {}) if row.get("tdp") is Dictionary else {}
	var w_min := float(t.get("min", 0))
	var w_max := maxf(float(t.get("boost_max", 0)), float(t.get("plugged_max", t.get("battery_max", 0))))
	# backlight never off
	for bl in _dirs(root + "/sys/class/backlight"):
		var b := _num(root + "/sys/class/backlight/%s/brightness" % bl)
		var m := _num(root + "/sys/class/backlight/%s/max_brightness" % bl)
		if b < 1 or b > m:
			out.append("backlight %s brightness %s (allowed 1..%s)" % [bl, b, m])
	for led in _dirs(root + "/sys/class/leds"):
		var lp := root + "/sys/class/leds/" + led
		var m := _num(lp + "/max_brightness")
		if _num(lp + "/brightness") < 0 or _num(lp + "/brightness") > m:
			out.append("led %s brightness out of 0..%s" % [led, m])
		for part in _read(lp + "/multi_intensity").split(" ", false):
			if not part.is_valid_int() or part.to_int() < 0 or part.to_int() > 255:
				out.append("led %s multi_intensity %s" % [led, _read(lp + "/multi_intensity")])
				break
	# PPT firmware attributes
	for fw in _dirs(root + "/sys/class/firmware-attributes"):
		var base := root + "/sys/class/firmware-attributes/%s/attributes" % fw
		for a in _dirs(base):
			var cur := _num(base + "/%s/current_value" % a)
			var lo := _num(base + "/%s/min_value" % a)
			var hi := _num(base + "/%s/max_value" % a)
			if cur < lo or cur > hi:
				out.append("%s/%s = %s outside %s..%s" % [fw, a, cur, lo, hi])
			if a.begins_with("ppt_") and w_max > 0 and (cur > w_max or cur < w_min):
				out.append("%s/%s = %s W outside the device's %s..%s W" % [fw, a, cur, w_min, w_max])
	# RAPL
	for dom in _dirs(root + "/sys/class/powercap"):
		for i in 4:
			var f := root + "/sys/class/powercap/%s/constraint_%d_power_limit_uw" % [dom, i]
			if FileAccess.file_exists(f) and w_max > 0:
				var w := _num(f) / 1000000.0
				if w > w_max + 2.0 or w < w_min:
					out.append("%s constraint_%d = %s W outside the device's %s..%s W (+2 W PL2 headroom)" % [dom, i, w, w_min, w_max])
	# fans
	for hw in _dirs(root + "/sys/class/hwmon"):
		var h := root + "/sys/class/hwmon/" + hw + "/"
		for f in DirAccess.get_files_at(h):
			if f.begins_with("pwm") and (f.ends_with("_pwm") or f.trim_prefix("pwm").is_valid_int()):
				var v := _num(h + f)
				if v < 0 or v > 255:
					out.append("%s/%s = %s outside 0..255" % [_read(h + "name"), f, v])
			elif f.begins_with("pwm") and f.ends_with("_enable"):
				var v := _num(h + f)
				if v < 0 or v > 5:
					out.append("%s/%s = %s" % [_read(h + "name"), f, v])
	# battery
	for ps in _dirs(root + "/sys/class/power_supply"):
		var p := root + "/sys/class/power_supply/" + ps
		if FileAccess.file_exists(p + "/charge_control_end_threshold"):
			var v := _num(p + "/charge_control_end_threshold")
			if v < 50 or v > 100:
				out.append("%s charge_control_end_threshold = %s (allowed 50..100)" % [ps, v])
		if FileAccess.file_exists(p + "/charge_behaviour"):
			var v := _read(p + "/charge_behaviour").replace("[", "").replace("]", "")
			for word in v.split(" ", false):
				if not word in ["auto", "inhibit-charge", "force-discharge"]:
					out.append("%s charge_behaviour = %s" % [ps, v])
	return out


static func _cpu_gpu_problems(root: String, info: Dictionary, original: Dictionary) -> Array[String]:
	var out: Array[String] = []
	# CPU
	var cpu := root + "/sys/devices/system/cpu"
	if FileAccess.file_exists(cpu + "/cpu0/online"):
		out.append("cpu0/online exists: cpu0 can't be taken offline")
	var online := 1
	for d in _dirs(cpu):
		if not (d.begins_with("cpu") and d.substr(3).is_valid_int()):
			continue
		var c := cpu + "/" + d
		if FileAccess.file_exists(c + "/online"):
			var o := _read(c + "/online")
			if not o in ["0", "1"]:
				out.append("%s/online = %s" % [d, o])
			online += 1 if o == "1" else 0
		var f := c + "/cpufreq/"
		if FileAccess.file_exists(f + "scaling_governor") and not _read(f + "scaling_governor") in _read(f + "scaling_available_governors").split(" ", false):
			out.append("%s governor %s not offered" % [d, _read(f + "scaling_governor")])
		if FileAccess.file_exists(f + "energy_performance_preference") and \
				not _read(f + "energy_performance_preference") in _read(f + "energy_performance_available_preferences").split(" ", false):
			out.append("%s EPP %s not offered" % [d, _read(f + "energy_performance_preference")])
		if FileAccess.file_exists(f + "scaling_max_freq"):
			var lo := _num(f + "cpuinfo_min_freq")
			var hi := _num(f + "cpuinfo_max_freq")
			var smin := _num(f + "scaling_min_freq")
			var smax := _num(f + "scaling_max_freq")
			if smin < lo or smax > hi or smin > smax:
				out.append("%s scaling %s..%s outside %s..%s" % [d, smin, smax, lo, hi])
	if online < 1:
		out.append("no CPU online")
	var smt := _read(cpu + "/smt/control")
	if smt != "" and not smt in ["on", "off", "forceoff", "notsupported", "notimplemented"]:
		out.append("smt/control = %s" % smt)
	var ip := cpu + "/intel_pstate/"
	if FileAccess.file_exists(ip + "max_perf_pct"):
		var mx := _num(ip + "max_perf_pct")
		var mn := _num(ip + "min_perf_pct")
		if mx < 1 or mx > 100 or mn > mx:
			out.append("intel_pstate perf pct %s..%s" % [mn, mx])
		if not _read(ip + "no_turbo") in ["0", "1"]:
			out.append("intel_pstate/no_turbo = %s" % _read(ip + "no_turbo"))
	# GPU
	var dev := root + "/sys/class/drm/%s/device/" % info.get("gpu_card", "card1")
	var lvl := _read(dev + "power_dpm_force_performance_level")
	if lvl != "" and not lvl in ["auto", "low", "high", "manual", "profile_standard", "profile_min_sclk", "profile_min_mclk", "profile_peak"]:
		out.append("power_dpm_force_performance_level = %s" % lvl)
	var fq := dev + "tile0/gt0/freq0/"
	if FileAccess.file_exists(fq + "min_freq"):
		var mn := _num(fq + "min_freq")
		var mx := _num(fq + "max_freq")
		if mn > mx or mn < _num(fq + "rpn_freq") or mx > _num(fq + "rp0_freq"):
			out.append("xe gt0 clocks %s..%s outside %s..%s" % [mn, mx, _num(fq + "rpn_freq"), _num(fq + "rp0_freq")])
	for f in ["/tile0/gt1/freq0/min_freq", "/tile0/gt1/freq0/max_freq"]:
		var p := "/sys/class/drm/%s/device%s" % [info.get("gpu_card", "card0"), f]
		if original.has(p) and _read(root + p) != original[p]:
			out.append("Intel media GT (gt1) touched: %s" % p)
	var card := root + "/sys/class/drm/%s/" % info.get("gpu_card", "card0")
	if FileAccess.file_exists(card + "gt_min_freq_mhz"):
		var mn := _num(card + "gt_min_freq_mhz")
		var mx := _num(card + "gt_max_freq_mhz")
		if mn > mx or mn < _num(card + "gt_RPn_freq_mhz") or mx > _num(card + "gt_RP0_freq_mhz"):
			out.append("i915 clocks %s..%s outside RPn..RP0" % [mn, mx])
	return out


## D-Bus values, hhd's TDP and root-helper arguments after the writes.
static func backend_problems(runner: FakeRunner, hhd: FakeHhd, row: Dictionary, inv: Dictionary) -> Array[String]:
	var out: Array[String] = []
	for rule in inv.get("dbus", []):
		for v in runner.prop_value(str(rule.get("prop", ""))):
			var msg := _limit_problem(float(v), rule, row)
			if msg != "":
				out.append("D-Bus %s = %s: %s" % [rule["prop"], v, msg])
	var hrule: Variant = inv.get("hhd_tdp")
	if hrule is Dictionary and not hhd.state.is_empty():
		var info: Dictionary = load("res://scripts/input/hhd.gd").tdp_info(hhd.state)
		if not info.is_empty() and float(info["value"]) >= 0.0:
			var msg := _limit_problem(float(info["value"]), hrule, row)
			if msg != "":
				out.append("hhd TDP = %s: %s" % [info["value"], msg])
	var roots: Dictionary = inv.get("root_set", {})
	for call in runner.calls:
		var argv: Array = [call[0]] + Array(call[1])
		var i := argv.find("set")
		if i < 2 or i + 1 >= argv.size() or not str(argv[i - 2]).ends_with("gamecove-fix-set"):
			continue
		var verb := str(argv[i - 1])
		var value := str(argv[i + 1])
		if roots.has(verb) and value.is_valid_float():
			var msg := _limit_problem(value.to_float(), roots[verb], row)
			if msg != "":
				out.append("gamecove-fix-set %s set %s: %s" % [verb, value, msg])
	return out


## Command arguments that name real system paths (they must carry sys_root).
static func real_path_args(runner: FakeRunner, root: String) -> Array[String]:
	var out: Array[String] = []
	var seen := {}
	for call in runner.calls:
		for a in call[1]:
			var s := str(a)
			for p in REAL_PREFIXES:
				if s.begins_with(p) and not s.begins_with(root) and not seen.has(s) and not s in HARMLESS_PATHS:
					seen[s] = true
					out.append("command %s got a real path %s (prefix it with ctx.sys_root)" % [call[0], s])
	return out


## {"<rule>"}: limits from numbers or row paths ("tdp.boost_max"); a list
## means the largest value present. "allow": values always fine (-1 = unknown).
static func _limit_problem(v: float, rule: Dictionary, row: Dictionary) -> String:
	if rule.get("allow", []).has(v) or rule.get("allow", []).has(int(v)):
		return ""
	var hi: Variant = resolve_limit(rule.get("max_le"), row)
	var lo: Variant = resolve_limit(rule.get("min_ge"), row)
	if hi != null and v > float(hi) + 0.001:
		return "above %s" % hi
	if lo != null and v < float(lo) - 0.001:
		return "below %s" % lo
	if rule.has("min_gt") and v <= float(rule["min_gt"]):
		return "must be above %s" % rule["min_gt"]
	return ""


static func resolve_limit(spec: Variant, row: Dictionary) -> Variant:
	if spec == null:
		return null
	if spec is int or spec is float:
		return float(spec)
	var best: Variant = null
	for s in (spec if spec is Array else [spec]):
		var v: Variant = s if (s is int or s is float) else _dig(row, str(s).split("."))
		if v is int or v is float:
			best = float(v) if best == null else maxf(best, float(v))
	return best


static func _dig(d: Variant, path: Array) -> Variant:
	var cur: Variant = d
	for k in path:
		if not cur is Dictionary or not cur.has(k):
			return null
		cur = cur[k]
	return cur


## Per-device expectations and the slider-limit invariants.
static func check_expectations(dev_id: String, info: Dictionary, row: Dictionary, reg: Node, expect: Dictionary,
		scenario: String) -> Array[String]:
	var out: Array[String] = []
	for rule in expect.get("invariants", {}).get("limits", []):
		for c in reg.list():
			if not c.available or c.kind != "slider" or not _id_matches(c.id, rule.get("ids", [])):
				continue
			for edge in [c.min_value, c.max_value]:
				var msg := _limit_problem(float(edge), rule, row)
				if msg != "":
					out.append("%s range %s..%s: %s %s" % [c.id, c.min_value, c.max_value, edge, msg])
	out.append_array(check_facts(expect.get("facts", {}).get(dev_id, {}), reg))
	for sel in expect.get("devices", {}):
		if not selector_matches(str(sel), dev_id, info):
			continue
		var per: Dictionary = expect["devices"][sel]
		for id in per:
			if str(id).begins_with("_"):
				continue
			var e: Dictionary = per[id].duplicate()
			if scenario == "ac" and e.get("ac") is Dictionary:
				e.merge(e["ac"], true)
			e.erase("ac")
			var c = reg.control(str(id))
			if c == null:
				out.append("expectations.json %s: %s expected but no provider registers it" % [sel, id])
				continue
			out.append_array(_expect_one(c, e, "%s (%s)" % [id, sel]))
	return out


## Community-tested facts (expectations.json "facts", cited to hhd, HueSync,
## SimpleDeckyTDP): checked against whatever matching controls exist.
static func check_facts(f: Dictionary, reg: Node) -> Array[String]:
	var out: Array[String] = []
	var t: Variant = f.get("tdp")
	if t is Dictionary:
		var src := str(t.get("source", ""))
		for c in reg.list():
			if not c.available or c.kind != "slider" or not (c.id.begins_with("power.tdp") or c.id.match("power.*ppt*")):
				continue
			var limit: Variant = t.get("max")
			if c.id.match("*fppt*"):
				limit = t.get("fppt_max", t.get("sppt_max", t.get("max")))
			elif c.id.match("*sppt*") or c.id.match("*boost*"):
				limit = t.get("sppt_max", t.get("max"))
			elif t.has("min") and c.min_value < float(t["min"]) - 0.001:
				out.append("%s min %s W is below the %s W that's known to work here (%s)" % [c.id, _n(c.min_value), _n(t["min"]), src])
			if limit != null and c.max_value > float(limit) + 0.001:
				out.append("%s max %s W is above the %s W known safe here (%s)" % [c.id, _n(c.max_value), _n(limit), src])
	var r: Variant = f.get("rgb")
	if r is Dictionary and r.get("present") == false:
		for c in reg.list():
			if c.available and (c.id.begins_with("controller.rgb") or c.id.begins_with("controller.led")):
				out.append("%s is offered but this handheld has no RGB (%s)" % [c.id, r.get("source", "")])
	return out


static func _expect_one(c: Object, e: Dictionary, label: String) -> Array[String]:
	var out: Array[String] = []
	if e.has("available") and c.available != bool(e["available"]):
		out.append("%s: available %s, expected %s (reason: %s)" % [label, c.available, e["available"], c.reason])
		return out
	if e.has("reason_contains") and not str(e["reason_contains"]).to_lower() in str(c.reason).to_lower():
		out.append("%s: reason \"%s\" lacks \"%s\"" % [label, c.reason, e["reason_contains"]])
	for k in ["kind", "unit"]:
		if e.has(k) and str(c.get(k)) != str(e[k]):
			out.append("%s: %s %s, expected %s" % [label, k, c.get(k), e[k]])
	var nums := {"min": c.min_value, "max": c.max_value, "step": c.step}
	for k in nums:
		if e.has(k) and absf(float(nums[k]) - float(e[k])) > 0.001:
			out.append("%s: %s %s, expected %s" % [label, k, nums[k], e[k]])
	if e.has("min_ge") and c.min_value < float(e["min_ge"]):
		out.append("%s: min %s below %s" % [label, c.min_value, e["min_ge"]])
	if e.has("max_le") and c.max_value > float(e["max_le"]):
		out.append("%s: max %s above %s" % [label, c.max_value, e["max_le"]])
	var vals: Array = c.options.map(func(o): return o.get("value") if o is Dictionary else o)
	for v in e.get("options_include", []):
		if not vals.has(v):
			out.append("%s: option %s missing (has %s)" % [label, v, vals])
	for v in e.get("options_exclude", []):
		if vals.has(v):
			out.append("%s: option %s must not be offered" % [label, v])
	if e.has("value") and str(c.value) != str(e["value"]) and not (c.value is float and absf(c.value - float(e["value"])) < 0.001):
		out.append("%s: value %s, expected %s" % [label, c.value, e["value"]])
	return out


## "*", a device id, "vendor:amd|intel", "driver:amdgpu|xe|i915", "stack:hhd", "generic".
static func selector_matches(sel: String, dev_id: String, info: Dictionary) -> bool:
	if sel == "*" or sel == dev_id:
		return true
	if sel == "generic":
		return bool(info.get("generic", false))
	var k := sel.get_slice(":", 0)
	var v := sel.get_slice(":", 1)
	match k:
		"vendor": return str(info.get("vendor", "")) == v
		"driver": return str(info.get("gpu_driver", "")) == v
		"stack": return v in info.get("stack", [])
	return false


static func _id_matches(id: String, patterns: Array) -> bool:
	for p in patterns:
		if id.match(str(p)):
			return true
	return false


## Problems in expectations.json itself (unknown device ids, typos in keys).
static func expectation_file_problems(expect: Dictionary, ids: Array) -> Array[String]:
	var out: Array[String] = []
	for dev in expect.get("facts", {}):
		if not str(dev) in ids:
			out.append("expectations.json facts: unknown device %s" % dev)
			continue
		for kind in expect["facts"][dev]:
			var fact: Variant = expect["facts"][dev][kind]
			if not kind in ["tdp", "rgb"] or not fact is Dictionary:
				out.append("expectations.json facts.%s: unknown fact %s" % [dev, kind])
			elif str(fact.get("source", "")) == "":
				out.append("expectations.json facts.%s.%s: needs a source" % [dev, kind])
			elif kind == "tdp":
				for key in fact:
					if not key in ["min", "max", "max_dc", "sppt_max", "fppt_max", "source"]:
						out.append("expectations.json facts.%s.tdp: unknown key %s" % [dev, key])
	for k in ["invariants", "devices"]:
		if not expect.get(k) is Dictionary:
			out.append("expectations.json needs an object \"%s\"" % k)
	for sel in expect.get("devices", {}):
		var s := str(sel)
		var known := s == "*" or s == "generic" or s in ids or (s.get_slice(":", 0) in ["vendor", "driver", "stack"] and ":" in s)
		if not known:
			out.append("expectations.json: unknown device or selector %s" % s)
			continue
		for id in expect["devices"][sel]:
			if str(id).begins_with("_"):
				continue
			var e: Variant = expect["devices"][sel][id]
			if not e is Dictionary:
				out.append("expectations.json %s.%s: needs an object" % [s, id])
				continue
			for key in e:
				if not str(key) in EXPECT_KEYS:
					out.append("expectations.json %s.%s: unknown key %s" % [s, id, key])
	return out


# ---- lint ---------------------------------------------------------------------

## Provider sources (providers/ and the area folders next to it) must reach the
## system only through ctx: no OS.execute, no scene tree from hooks, no timers,
## no absolute system path that isn't prefixed with sys_root/home.
static func lint(dir := "res://scripts/controls") -> Array[String]:
	var out: Array[String] = []
	for f in _gd_files(dir):
		if f.get_file() in ["control.gd", "controls.gd", "profiles.gd"]:
			continue
		var lines := FileAccess.get_file_as_string(f).split("\n")
		for n in lines.size():
			var line := lines[n].strip_edges()
			if line.begins_with("#") or "devicematrix: allow" in line:
				continue
			# a fallback right after `if runner.has_method(...)` (runners may lack spawn/kill)
			var guarded := false
			for k in range(maxi(0, n - 3), n):
				if "has_method(" in lines[k]:
					guarded = true
			for bad in ["OS.execute", "OS.create_process", "OS.execute_with_pipe", "OS.shell_open", "get_tree()", "Timer.new()"]:
				if bad in line and not (guarded and bad.begins_with("OS.")):
					out.append("%s:%d uses %s (go through ctx.runner / signals)" % [f, n + 1, bad])
			if line.begins_with("const ") or line.begins_with("static var ") or line.begins_with("var "):
				continue
			for p in REAL_PREFIXES:
				var at := line.find("\"" + p)
				var harmless := false
				for h in HARMLESS_PATHS:
					harmless = harmless or line.find("\"" + h + "\"") == at
				if at < 0 or harmless or ("root" in line or "ctx" in line or "home" in line or "prefix" in line):
					continue
				var before := line.substr(0, at).strip_edges()
				if before.ends_with("+"):
					continue   # <prefix expression> + "/sys/..."
				out.append("%s:%d absolute path without sys_root: %s" % [f, n + 1, line])
				break
	return out


static func _gd_files(dir: String) -> Array[String]:
	var out: Array[String] = []
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd"):
			out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		out.append_array(_gd_files(dir.path_join(d)))
	return out


# ---- files --------------------------------------------------------------------

static func _snapshot_files(root: String) -> Dictionary:
	var out := {}
	_walk(root, "", out)
	return out


static func _walk(root: String, rel: String, out: Dictionary) -> void:
	var here := root + rel
	for f in DirAccess.get_files_at(here):
		if rel.begins_with("/usr") or rel.begins_with("/home"):
			continue
		out[rel + "/" + f] = _read(here + "/" + f)
	for d in DirAccess.get_directories_at(here):
		_walk(root, rel + "/" + d, out)


static func _set_ac(info: Dictionary, on: bool) -> void:
	var root := str(info["root"])
	var f := FileAccess.open(root + str(info["ac_online_file"]), FileAccess.WRITE)
	if f != null:
		f.store_string("1\n" if on else "0\n")
		f.close()
	var st := FileAccess.open(root + str(info["battery"]) + "/status", FileAccess.WRITE)
	if st != null:
		st.store_string("Charging\n" if on else "Discharging\n")
		st.close()


static func _set_read_only(root: String, files: Array, ro: bool) -> void:
	var r := FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_READ_GROUP | FileAccess.UNIX_READ_OTHER
	for f in files:
		FileAccess.set_unix_permissions(root + str(f), r if ro else (r | FileAccess.UNIX_WRITE_OWNER))


## 30.0 -> "30", 7.5 -> "7.5"
static func _n(v: Variant) -> String:
	var f := float(v)
	return str(int(f)) if f == floorf(f) else str(f)


static func _read(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_file_as_string(path).strip_edges()


static func _num(path: String) -> float:
	var s := _read(path)
	return s.to_float() if s.is_valid_float() else -1.0


static func _dirs(path: String) -> PackedStringArray:
	if not DirAccess.dir_exists_absolute(path):
		return PackedStringArray()
	var out := DirAccess.get_directories_at(path)
	out.sort()
	return out
