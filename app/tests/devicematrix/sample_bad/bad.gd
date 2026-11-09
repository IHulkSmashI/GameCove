extends RefCounted
## Harness self-test: breaks every rule the matrix checks.

const Ctl := preload("res://scripts/controls/control.gd")

var ctx: Dictionary = {}


func setup(c: Dictionary) -> void:
	ctx = c


func controls() -> Array:
	var root := str(ctx.get("sys_root", ""))
	var store := {}
	return [
		# backlight allowed (and written) down to 0
		Ctl.make({"id": "display.brightness", "group": "display", "kind": "slider", "min_value": 0.0, "max_value": 100.0},
			func(_c): return "",
			func(_c): return 50.0,
			func(_c, v):
				for n in DirAccess.get_directories_at(root + "/sys/class/backlight"):
					var f := FileAccess.open(root + "/sys/class/backlight/" + n + "/brightness", FileAccess.WRITE)
					f.store_string(str(int(v)))
				return true),
		# 200 W slider straight into the PPT attributes
		Ctl.make({"id": "power.tdp", "group": "power", "kind": "slider", "min_value": 1.0, "max_value": 200.0},
			func(_c): return "",
			func(_c): return 10.0,
			func(_c, v):
				var base := root + "/sys/class/firmware-attributes"
				if DirAccess.dir_exists_absolute(base):
					for fw in DirAccess.get_directories_at(base):
						var f := FileAccess.open(base + "/" + fw + "/attributes/ppt_pl1_spl/current_value", FileAccess.WRITE)
						if f != null:
							f.store_string(str(int(v)))
				return true),
		# unavailable with no reason
		Ctl.make({"id": "audio.volume", "group": "audio", "kind": "slider"},
			func(_c): return "\n",
			func(_c): return null,
			func(_c, _v): return false),
		# RGB on every device; real path passed to a command; value changes on failure
		Ctl.make({"id": "controller.rgb", "group": "controller", "kind": "toggle"},
			func(_c): return "",
			func(_c): return store.get("rgb", false),
			func(_c, v):
				store["rgb"] = v
				return int(ctx["runner"].run("cat", PackedStringArray(["/sys/class/leds/x/brightness"])).get("code", 1)) == 0),
		# wrong group prefix
		Ctl.make({"id": "fps.limit", "group": "perf", "kind": "toggle"},
			func(_c): return "", func(_c): return false, func(_c, _v): return true),
	]
