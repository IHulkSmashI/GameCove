extends RefCounted
## Fakes for the controller Controls tests (tests/test_controls_controller.gd):
## a stateful InputPlumber behind busctl, Handheld Daemon behind curl, and the
## no-password LED root action running the real fixes/controller-led/fix.sh
## against a fixture tree. Everything goes through one fake runner.

const Runner := preload("res://tests/fixtures/system/fake_runner.gd")
const FakeHhd := preload("res://tests/fixtures/system/fake_hhd.gd")

const SVC := "org.shadowblip.InputPlumber"
const DEV := "/org/shadowblip/InputPlumber/CompositeDevice0"
const DEV_IFACE := "org.shadowblip.Input.CompositeDevice"
const FF := "org.shadowblip.Output.ForceFeedback"

var runner: RefCounted = Runner.new()
var sys_root := ""

# InputPlumber
var ip_on := false
var ip_name := ""
var ip_caps: Array = []
var ip_outs: Array = []
var ip_ff := false
var rumble := true
var profile: Dictionary = {"version": 1, "kind": "DeviceProfile", "name": "Default", "mapping": []}
var loads: Array = []           # every JSON sent with LoadProfileFromYaml
var refuse_load := false        # LoadProfileFromYaml fails
var ignore_load := false        # it "succeeds" but nothing changes
var buzzes := 0

# hhd
var hhd: RefCounted = null      # FakeHhd
var settings: Dictionary = {}
var refuse_paths: Array = []    # state paths hhd leaves unchanged on POST
var curl_calls: Array = []

# root action
var pkexec_calls: Array = []
var fix_dir := ProjectSettings.globalize_path("res://").path_join("../fixes")


func _init(root: String, with_helper := true) -> void:
	sys_root = root
	runner.handler = _handle
	if with_helper:   # the root helper is installed (its stand-in; _pkexec runs the real fix)
		write(root + "/usr/libexec/gamecove/gamecove-fix-set", "#!/bin/sh")


func ctx(row: Dictionary, home := "") -> Dictionary:
	return {"sys_root": sys_root, "runner": runner, "home": home if home != "" else sys_root + "/home", "device": row}


func with_ip(name: String, caps: Array, ff := true) -> void:
	ip_on = true
	ip_name = name
	ip_caps = caps
	ip_ff = ff
	ip_outs = ["ForceFeedback"] if ff else []


func with_hhd(state: Dictionary, schema: Dictionary) -> void:
	hhd = FakeHhd.new(state)
	settings = schema
	DirAccess.make_dir_recursive_absolute(sys_root + "/run/hhd")


static func _s(v: Variant, sig: String) -> Dictionary:
	return {"code": 0, "out": JSON.stringify({"type": sig, "data": v})}


func _handle(cmd: String) -> Variant:
	if cmd.begins_with("busctl --system "):
		return _busctl(cmd.trim_prefix("busctl --system "))
	if cmd.begins_with("curl "):
		return _curl(cmd)
	if cmd.begins_with("pkexec "):
		return _pkexec(cmd.trim_prefix("pkexec "))
	return null


func _busctl(c: String) -> Dictionary:
	if not ip_on:
		return {"code": 1, "out": ""}
	var mgr := "get-property %s /org/shadowblip/InputPlumber/Manager org.shadowblip.InputManager " % SVC
	if c == mgr + "Version":
		return _s("0.82.0", "s")
	if c == mgr + "GamepadOrder":
		return _s([DEV], "ao")
	if c == "call %s /org/shadowblip/InputPlumber org.freedesktop.DBus.ObjectManager GetManagedObjects" % SVC:
		var ifaces := {DEV_IFACE: {"Name": {"type": "s", "data": ip_name}, "Capabilities": {"type": "as", "data": ip_caps},
			"OutputCapabilities": {"type": "as", "data": ip_outs}}}
		if ip_ff:
			ifaces[FF] = {"Enabled": {"type": "b", "data": rumble}}
		return {"code": 0, "out": JSON.stringify({"type": "a{oa{sa{sv}}}", "data": [{DEV: ifaces}]})}
	var dev := "call %s %s " % [SVC, DEV]
	if c == dev + DEV_IFACE + " GetProfileYaml":
		return _s([JSON.stringify(profile)], "s")
	if c.begins_with(dev + DEV_IFACE + " LoadProfileFromYaml s "):
		var json := c.trim_prefix(dev + DEV_IFACE + " LoadProfileFromYaml s ")
		loads.append(json)
		if refuse_load:
			return {"code": 1, "out": ""}
		var p: Variant = JSON.parse_string(json)
		if not (p is Dictionary):
			return {"code": 1, "out": ""}
		if not ignore_load:
			profile = p
		return {"code": 0, "out": ""}
	if c == "get-property %s %s %s Enabled" % [SVC, DEV, FF] and ip_ff:
		return _s(rumble, "b")
	if c.begins_with("set-property %s %s %s Enabled b " % [SVC, DEV, FF]) and ip_ff:
		rumble = c.ends_with(" true")
		return {"code": 0, "out": ""}
	if c.begins_with(dev + FF + " Rumble d ") and ip_ff:
		buzzes += 1
		return {"code": 0, "out": ""}
	if c == dev + FF + " Stop" and ip_ff:
		return {"code": 0, "out": ""}
	return {"code": 1, "out": ""}


func _curl(cmd: String) -> Dictionary:
	curl_calls.append(cmd)
	if hhd == null or hhd.down:
		return {"code": 7, "out": ""}
	var parts := cmd.split(" ")
	var method := "GET"
	var i := parts.find("-X")
	if i >= 0:
		method = parts[i + 1]
	var url := parts[parts.size() - 1]
	var path := url.substr(url.find("/api/"))
	var body := ""
	var b := cmd.find("--data-binary ")
	if b >= 0:
		body = cmd.substr(b + 14, cmd.rfind(" http") - b - 14)
	if path == "/api/v1/settings":
		return {"code": 0, "out": JSON.stringify(settings, "", false) + "\n200"}
	if method == "POST" and not refuse_paths.is_empty():
		var before: Dictionary = (hhd.state as Dictionary).duplicate(true)
		var r: Dictionary = hhd.request(method, path, PackedStringArray(), body)
		for p in refuse_paths:
			var old: Variant = _dig(before, p)
			_put(hhd.state, p, old)
		r["body"] = JSON.stringify(hhd.state)
		return {"code": 0, "out": str(r["body"]) + "\n" + str(r["code"])}
	var r2: Dictionary = hhd.request(method, path, PackedStringArray(), body)
	return {"code": 0, "out": str(r2["body"]) + "\n" + str(r2["code"])}


static func _dig(d: Variant, path: Array) -> Variant:
	var cur: Variant = d
	for k in path:
		if not (cur is Dictionary) or not cur.has(k):
			return null
		cur = cur[k]
	return cur


static func _put(d: Dictionary, path: Array, v: Variant) -> void:
	var cur: Dictionary = d
	for i in path.size() - 1:
		cur = cur[path[i]]
	cur[path[path.size() - 1]] = v


## pkexec /usr/libexec/gamecove/gamecove-fix-set <fix> set <value>: runs the
## real fix.sh for controller-led on the fixture tree; claw8ex-gyro toggles the
## accelerometer line in the fixture override.
func _pkexec(c: String) -> Dictionary:
	pkexec_calls.append(c)
	var p := c.split(" ")
	if p.size() != 4 or p[0] != "/usr/libexec/gamecove/gamecove-fix-set" or p[2] != "set":
		return {"code": 64, "out": ""}
	if p[1] == "controller-led":
		var out: Array = []
		var code := OS.execute("env", PackedStringArray(["GAMECOVE_ROOT=" + sys_root, "sh",
			fix_dir.path_join("controller-led/fix.sh"), "set", p[3]]), out, true)
		return {"code": code, "out": str(out[0]) if out.size() > 0 else ""}
	if p[1] == "claw8ex-gyro":
		var f := sys_root + "/etc/inputplumber/devices.d/50-msi_claw8_ex_ai_cg3em.yaml"
		var t := FileAccess.get_file_as_string(f).replace("      - name: accel_3d\n", "")
		if p[3] == "accel-on":
			t += "      - name: accel_3d\n"
		var fh := FileAccess.open(f, FileAccess.WRITE)
		fh.store_string(t)
		fh.close()
		return {"code": 0, "out": ""}
	return {"code": 65, "out": ""}


# ---- fixture trees -------------------------------------------------------------

static func write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text + "\n")
	f.close()


## A multicolor LED node; extra = {attr: value} (effect, effect_index, speed...).
func led(name: String, index := "red green blue", intensity := "0 0 0", max_b := 255, bri := 0, extra := {}) -> String:
	var d := sys_root + "/sys/class/leds/" + name
	write(d + "/multi_index", index)
	write(d + "/multi_intensity", intensity)
	write(d + "/max_brightness", str(max_b))
	write(d + "/brightness", str(bri))
	for k in extra:
		write(d + "/" + k, str(extra[k]))
	return d


func read(path: String) -> String:
	return FileAccess.get_file_as_string(sys_root + path).strip_edges()
