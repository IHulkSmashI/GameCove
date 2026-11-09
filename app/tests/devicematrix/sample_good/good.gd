extends RefCounted
## Harness self-test: a well-behaved provider (sysfs through ctx.sys_root,
## ranges from the device row, steamos-manager through ctx.runner).

const Ctl := preload("res://scripts/controls/control.gd")

var ctx: Dictionary = {}


func setup(c: Dictionary) -> void:
	ctx = c


func controls() -> Array:
	return [_tdp(), _brightness(), _rgb(), _governor(), _sm_tdp()]


func _root() -> String:
	return str(ctx.get("sys_root", ""))


func _row() -> Dictionary:
	var d: Variant = ctx.get("device")
	return d.profile if d != null and "profile" in d else {}


static func _r(p: String) -> String:
	return FileAccess.get_file_as_string(p).strip_edges() if FileAccess.file_exists(p) else ""


static func _w(p: String, v: String) -> bool:
	var f := FileAccess.open(p, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(v)
	f.close()
	return true


func _ppt_dir() -> String:
	var base := _root() + "/sys/class/firmware-attributes"
	for fw in DirAccess.get_directories_at(base) if DirAccess.dir_exists_absolute(base) else PackedStringArray():
		var a := base + "/" + fw + "/attributes/ppt_pl1_spl"
		if FileAccess.file_exists(a + "/current_value"):
			return a
	return ""


func _tdp() -> RefCounted:
	return Ctl.make({"id": "power.tdp", "title": "TDP", "group": "power", "kind": "slider", "unit": "W", "apply_order": 10},
		func(c):
			var a := _ppt_dir()
			var t: Dictionary = _row().get("tdp", {}) if _row().get("tdp") is Dictionary else {}
			if a == "" or t.is_empty():
				return "Needs the firmware power limits"
			c.min_value = float(t["min"])
			c.max_value = float(t.get("plugged_max", t["battery_max"]))
			c.min_value = maxf(c.min_value, _r(a + "/min_value").to_float())
			c.max_value = minf(c.max_value, _r(a + "/max_value").to_float())
			return "",
		func(_c): return _r(_ppt_dir() + "/current_value").to_float(),
		func(_c, v): return _w(_ppt_dir() + "/current_value", str(int(v))))


func _bl() -> String:
	var base := _root() + "/sys/class/backlight"
	var names := DirAccess.get_directories_at(base) if DirAccess.dir_exists_absolute(base) else PackedStringArray()
	return base + "/" + names[0] if names.size() > 0 else ""


func _brightness() -> RefCounted:
	return Ctl.make({"id": "display.brightness", "title": "Brightness", "group": "display", "kind": "slider",
		"min_value": 5.0, "max_value": 100.0, "step": 1.0, "unit": "%", "per_game": false},
		func(_c): return "" if _bl() != "" else "No backlight",
		func(_c): return roundf(_r(_bl() + "/brightness").to_float() * 100.0 / maxf(1.0, _r(_bl() + "/max_brightness").to_float())),
		func(_c, v): return _w(_bl() + "/brightness", str(maxi(1, roundi(v * _r(_bl() + "/max_brightness").to_float() / 100.0)))))


func _led() -> String:
	var base := _root() + "/sys/class/leds"
	for n in DirAccess.get_directories_at(base) if DirAccess.dir_exists_absolute(base) else PackedStringArray():
		if "rgb" in n:
			return base + "/" + n
	return ""


func _rgb() -> RefCounted:
	return Ctl.make({"id": "controller.rgb", "title": "LED colour", "group": "controller", "kind": "color", "default_value": "#ffffff"},
		func(_c): return "" if _led() != "" else "No RGB lights here",
		func(_c):
			var p := _r(_led() + "/multi_intensity").split(" ")
			return "#%02x%02x%02x" % [p[0].to_int(), p[1].to_int(), p[2].to_int()] if p.size() == 3 else null,
		func(_c, v):
			var col := Color.html(v)
			return _w(_led() + "/multi_intensity", "%d %d %d" % [col.r8, col.g8, col.b8]))


func _cpu0() -> String:
	return _root() + "/sys/devices/system/cpu/cpu0/cpufreq/"


func _governor() -> RefCounted:
	var c := Ctl.make({"id": "power.governor", "title": "CPU governor", "group": "power", "kind": "choice"},
		func(c):
			var avail := _r(_cpu0() + "scaling_available_governors")
			if avail == "":
				return "No CPU frequency control"
			c.options = Array(avail.split(" ", false)).map(func(g): return {"value": g, "label": g.capitalize()})
			return "",
		func(_c): return _r(_cpu0() + "scaling_governor"),
		func(_c, v): return _w(_cpu0() + "scaling_governor", v))
	return c


func _sm_tdp() -> RefCounted:
	var args := ["--user", "get-property", "com.steampowered.SteamOSManager1", "/com/steampowered/SteamOSManager1",
		"com.steampowered.SteamOSManager1.TdpLimit1"]
	return Ctl.make({"id": "power.tdp_steamos", "title": "TDP (steamos-manager)", "group": "power", "kind": "slider", "unit": "W"},
		func(c):
			var r: Dictionary = ctx["runner"].run("busctl", PackedStringArray(args + ["TdpLimit"]))
			var t: Dictionary = _row().get("tdp", {}) if _row().get("tdp") is Dictionary else {}
			if int(r.get("code", 1)) != 0 or t.is_empty():
				return "steamos-manager isn't running"
			c.min_value = float(t["min"])
			c.max_value = float(t.get("plugged_max", t["battery_max"]))
			return "",
		func(_c):
			var r: Dictionary = ctx["runner"].run("busctl", PackedStringArray(args + ["TdpLimit"]))
			var d: Variant = JSON.parse_string(str(r.get("out", "")))
			return float(d["data"]) if d is Dictionary else null,
		func(_c, v):
			var r: Dictionary = ctx["runner"].run("busctl", PackedStringArray(["--user", "set-property", args[2], args[3], args[4], "TdpLimit", "u", str(int(v))]))
			return int(r.get("code", 1)) == 0)
