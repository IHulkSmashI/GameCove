extends "res://tests/fixtures/controller/fakes.gd"
## The controller fakes plus the rumble pieces: kernel rumble knobs in the
## fixture's /sys/bus/hid tree and the no-password root action
## (gamecove-fix-set controller-rumble set <v>) running the real
## fixes/controller-rumble/fix.sh against it.

var rumble_sets: Array = []      # every value sent to the root action
var refuse_rumble := false       # the root action fails (helper missing, controller refused)


func _init(root: String) -> void:
	super(root)
	runner.handler = _handle_rumble


func _handle_rumble(cmd: String) -> Variant:
	var pre := "pkexec /usr/libexec/gamecove/gamecove-fix-set controller-rumble set "
	if cmd.begins_with(pre):
		var v := cmd.trim_prefix(pre)
		pkexec_calls.append(cmd.trim_prefix("pkexec "))
		rumble_sets.append(v)
		if refuse_rumble:
			return {"code": 1, "out": ""}
		var out: Array = []
		var code := OS.execute("env", PackedStringArray(["GAMECOVE_ROOT=" + sys_root, "sh",
			fix_dir.path_join("controller-rumble/fix.sh"), "set", v]), out, true)
		return {"code": code, "out": str(out[0]) if out.size() > 0 else ""}
	return _handle(cmd)


## hid-msi's config interface with the rumble attributes (plus the gamepad
## interface, bound to the same driver, without them). Returns its folder.
func msi_knob(left := 100, right := 100) -> String:
	var base := sys_root + "/sys/bus/hid/drivers/hid-msi/"
	DirAccess.make_dir_recursive_absolute(base + "0003:0DB0:1901.0003")
	var d := base + "0003:0DB0:1901.0004"
	write(d + "/rumble_intensity_left", str(left))
	write(d + "/rumble_intensity_right", str(right))
	write(d + "/rumble_intensity_range", "0-100")
	return d


## hid-lenovo-go's rumble_intensity (both Legion Go controllers).
func go_knob(value := "medium") -> String:
	var d := sys_root + "/sys/bus/hid/drivers/hid-lenovo-go/0003:17EF:61EB.0002"
	write(d + "/rumble_intensity", value)
	write(d + "/rumble_intensity_index", "off low medium high ")
	return d


func buzz_values() -> Array:
	return Array(runner.calls).filter(func(c): return " Rumble d " in c).map(
		func(c): return float(c.substr(c.rfind(" ") + 1)))
