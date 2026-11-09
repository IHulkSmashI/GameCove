extends SceneTree
## Regenerates the Controls snapshots the controls screenshots use
## (app/tests/fixtures/ui_controls/<device>.json): every provider loaded
## against the device matrix fixture for that handheld, battery scenario.
##   python3 -I tools/devicematrix/gen.py /tmp/dm
##   DEVICEMATRIX_DIR=/tmp/dm godot --headless --path app -s res://../tools/screenshots/dump_controls.gd
## (or copy it under app/ first; it only reads fixtures and writes the JSON).

const Matrix := preload("res://tests/devicematrix/matrix.gd")
const ControlsScript := preload("res://scripts/controls/controls.gd")
const DeviceScript := preload("res://scripts/device/device.gd")
const DEVICES := ["msi-claw-8-ex", "lenovo-legion-go-s-z2go"]


func _initialize() -> void:
	var m := Matrix.manifest()
	var out_dir := ProjectSettings.globalize_path("res://").path_join("tests/fixtures/ui_controls").simplify_path()
	for info in m.get("devices", []):
		if not str(info["id"]) in DEVICES:
			continue
		var backends: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(str(info["backends"])))
		var runner = Matrix.FakeRunner.new(backends, "ok")
		var dev: Node = DeviceScript.new()
		dev.root = str(info["root"])
		dev.home = str(info["home"])
		dev.detect()
		var ctx := {"sys_root": str(info["root"]), "runner": runner, "home": str(info["home"]), "device": dev,
			"hhd_transport": Matrix.FakeHhd.new(backends.get("hhd"), true), "devicematrix": "battery",
			"env": Matrix.session_env(info, "battery"),
			"config_path": str(info["home"]).path_join(".config/gamecove/dump.cfg")}
		var reg: Node = ControlsScript.new()
		reg.sync_mode = true
		reg.setup(ctx)
		for path in Matrix.provider_scripts():
			var p: Object = load(path).new()
			if p.has_method("setup"):
				p.setup(ctx)
			reg.register_provider(p)
		var list := []
		for c in reg.list():
			c.detect()
			c.read()
			var d: Dictionary = c.describe()
			d["apply_order"] = c.apply_order
			list.append(d)
		var f := FileAccess.open(out_dir.path_join(str(info["id"]) + ".json"), FileAccess.WRITE)
		f.store_string(JSON.stringify({"device": info["id"], "controls": list}, " ", true))
		f.close()
		print("%s: %d controls" % [info["id"], list.size()])
		reg.free()
		dev.free()
	quit()
