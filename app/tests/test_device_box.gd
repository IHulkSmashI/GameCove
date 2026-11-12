extends "res://tests/test_case.gd"
## Devices that aren't handhelds: the Steam Machine and any PC with no battery
## (mini PC, HTPC). Detection, no battery / TDP assumptions, wording.

const DeviceScript := preload("res://scripts/device/device.gd")
const Words := preload("res://scripts/ui/words.gd")
const UiScale := preload("res://scripts/ui/ui_scale.gd")

const FREMONT := {"sys_vendor": "Valve", "product_name": "Fremont", "board_name": "Fremont", "board_vendor": "Valve", "product_family": ""}
const MINI_PC := {"sys_vendor": "AZW", "product_name": "SER8", "board_name": "SER8", "board_vendor": "AZW", "product_family": "SER"}


func _tmp() -> String:
	var d := OS.get_cache_dir().path_join("gamecove-test-box-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(d)
	return d


func _w(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text + "\n")
	f.close()


func _rm(dir: String) -> void:
	for d in DirAccess.get_directories_at(dir):
		_rm(dir.path_join(d))
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)


func _device(root: String) -> Node:
	var was: Variant = DeviceScript.assume_battery
	DeviceScript.assume_battery = null   # this test is about looking
	var dev: Node = DeviceScript.new()
	dev.root = root
	dev.detect()
	DeviceScript.assume_battery = was
	return dev


func test_steam_machine_row() -> void:
	var row := DeviceScript.resolve(DeviceScript.load_doc(), FREMONT, "AMD Custom CPU 1772", {}, false)
	eq(row.get("id"), "valve-steam-machine", "Valve / Fremont")
	eq(DeviceScript.form_of(row), "console", "a console")
	eq(row.get("panel"), null, "no panel")
	eq(row.get("tdp_backends"), [], "no TDP backend")
	eq(row.get("charge_limit"), false, "no charge limit")
	eq(row.get("verified"), false, "not verified: nobody has run it on the hardware")
	eq(row.get("match"), {"sys_vendor": ["Valve"], "board_name": ["Fremont"]}, "matches on sys_vendor + board_name, as steamos-manager does")
	ok(not ("dmi" in row.get("unverified", [])), "the DMI ids come from Valve's steamos-manager config")
	var renamed := FREMONT.duplicate()
	renamed["product_name"] = "Steam Machine"
	eq(DeviceScript.resolve(DeviceScript.load_doc(), renamed, "", {}, false).get("id"), "valve-steam-machine", "product_name does not matter")
	var other := FREMONT.duplicate()
	other["sys_vendor"] = "Beelink"
	ok(DeviceScript.resolve(DeviceScript.load_doc(), other, "", {}, false).get("id") != "valve-steam-machine", "another vendor's Fremont board is not a Steam Machine")
	eq(DeviceScript.row_problems(row), [], "passes the schema")
	var f := DeviceScript.features_of(row)
	eq(f["charge_limit"], false, "feature: charge limit")
	eq(f["gyro"], "none", "feature: gyro")
	# the Decks keep their rows
	eq(DeviceScript.resolve(DeviceScript.load_doc(), {"sys_vendor": "Valve", "product_name": "Galileo"}, "", {}).get("id"), "steam-deck-oled", "Deck OLED")


func test_schema_refuses_a_console_with_handheld_parts() -> void:
	var row: Dictionary = DeviceScript.resolve(DeviceScript.load_doc(), FREMONT, "", {}, false).duplicate(true)
	row["charge_limit"] = true
	ok(not DeviceScript.row_problems(row).is_empty(), "charge limit on a console")
	row["charge_limit"] = false
	row["tdp_backends"] = ["steamos-manager"]
	ok(not DeviceScript.row_problems(row).is_empty(), "TDP backend on a console")
	row["tdp_backends"] = []
	row["form"] = "toaster"
	ok(not DeviceScript.row_problems(row).is_empty(), "unknown form")


func test_unknown_pc_without_battery_is_a_desktop() -> void:
	var cpus: Array = DeviceScript.load_doc().get("cpus", [])
	var box := DeviceScript.fallback_row(MINI_PC, "AMD Ryzen 7 8845HS w/ Radeon 780M Graphics", {}, cpus, false)
	eq(DeviceScript.form_of(box), "desktop", "form")
	eq(box["name"], "SER8", "named by its product name")
	eq(box["tdp_backends"], [], "no power service may set a handheld TDP on it")
	eq(box["art"], "generic-box", "its drawing")
	eq(box["gpu_family"], "amd-rdna3", "the chip is still known (upscaler choice)")
	eq(DeviceScript.fallback_row({}, "", {}, cpus, false)["name"], "Unknown PC", "no DMI name")
	# with a battery nothing changes
	var hh := DeviceScript.fallback_row(MINI_PC, "AMD Ryzen 7 8845HS w/ Radeon 780M Graphics", {}, cpus, true)
	eq(DeviceScript.form_of(hh), "handheld", "an unknown device with a battery stays a handheld")
	ok(not hh.has("tdp_backends"), "and keeps the default power services")
	eq(DeviceScript.fallback_row({}, "", {}, cpus)["name"], "Unknown handheld", "old name")


func test_detection_from_sysfs_ignores_controller_batteries() -> void:
	var root := _tmp()
	for k in MINI_PC:
		_w(root + "/sys/class/dmi/id/" + k, MINI_PC[k])
	_w(root + "/proc/cpuinfo", "model name\t: AMD Ryzen 7 8845HS w/ Radeon 780M Graphics")
	# a DualSense on a cable shows up as a power supply of type Battery
	_w(root + "/sys/class/power_supply/ps-controller-battery-a0:fa:9c:11:22:33/type", "Battery")
	_w(root + "/sys/class/power_supply/ps-controller-battery-a0:fa:9c:11:22:33/scope", "Device")
	_w(root + "/sys/class/power_supply/ps-controller-battery-a0:fa:9c:11:22:33/capacity", "15")
	var dev := _device(root)
	eq(dev.has_battery(), false, "a controller's battery is not the system's")
	eq(dev.form(), "desktop", "so this is a desktop")
	eq(dev.is_handheld(), false, "not a handheld")
	eq(dev.noun(), "device", "noun")
	eq(dev.battery()["percent"], -1, "no battery reading")
	eq(dev.display_name(), "SER8", "name")
	# the same box with a real battery (a laptop-like unknown): a handheld again
	_w(root + "/sys/class/power_supply/BAT0/type", "Battery")
	_w(root + "/sys/class/power_supply/BAT0/capacity", "80")
	dev.free()
	dev = _device(root)
	eq(dev.has_battery(), true, "BAT0")
	eq(dev.form(), "handheld", "handheld")
	dev.free()
	_rm(root)
	# a battery that isn't called BAT*
	root = _tmp()
	_w(root + "/sys/class/power_supply/CMB0/type", "Battery")
	_w(root + "/sys/class/power_supply/CMB0/scope", "System")
	ok(DeviceScript.battery_path_at(root).ends_with("CMB0/"), "found by type")
	_rm(root)


## Review: an unlisted handheld whose battery the kernel doesn't list was treated as a box (no battery, no power
## settings, a firmware update allowed on battery). A built-in screen makes it a handheld; a box has none.
func test_an_unknown_device_with_a_built_in_screen_and_no_battery_is_a_handheld() -> void:
	var cpus: Array = DeviceScript.load_doc().get("cpus", [])
	var cpu := "AMD Ryzen 7 8845HS w/ Radeon 780M Graphics"
	eq(DeviceScript.form_of(DeviceScript.fallback_row(MINI_PC, cpu, {}, cpus, false, true)), "handheld", "a screen of its own: handheld")
	eq(DeviceScript.form_of(DeviceScript.fallback_row(MINI_PC, cpu, {}, cpus, false, false)), "desktop", "no screen: still a box")
	var root := _tmp()
	for k in MINI_PC:
		_w(root + "/sys/class/dmi/id/" + k, MINI_PC[k])
	_w(root + "/proc/cpuinfo", "model name\t: " + cpu)
	_w(root + "/sys/class/drm/card1-DP-1/status", "connected")        # a TV on a cable is not a screen of its own
	ok(not DeviceScript.builtin_display(root), "an external connector is not a built-in screen")
	var dev := _device(root)
	eq(dev.form(), "desktop", "a box with only an external screen")
	dev.free()
	_w(root + "/sys/class/drm/card1-eDP-1/status", "connected")
	ok(DeviceScript.builtin_display(root), "an eDP connector is")
	dev = _device(root)
	eq([dev.has_battery(), dev.form(), dev.is_handheld()], [false, "handheld", true], "no battery found, but a screen of its own: handheld")
	dev.free()
	_rm(root)


func test_steam_machine_from_sysfs_lays_out_for_the_tv() -> void:
	var root := _tmp()
	for k in FREMONT:
		_w(root + "/sys/class/dmi/id/" + k, FREMONT[k])
	_w(root + "/sys/class/drm/card1-HDMI-A-1/status", "connected")
	_w(root + "/sys/class/drm/card1-HDMI-A-1/enabled", "enabled")
	var dev := _device(root)
	eq(dev.id(), "valve-steam-machine", "detected")
	eq(dev.is_handheld(), false, "not a handheld")
	eq(dev.display_name(), "Steam Machine", "name")
	eq(dev.picture(), "res://assets/devices/art/steam-machine.svg", "drawing")
	var scr := UiScale.screen_for(dev)
	eq(scr["kind"], "tv", "its screen is a TV")
	eq(UiScale.layout_for(Vector2i(3840, 2160), scr), Vector2i(1422, 800), "4K: the 10-foot layout")
	dev.free()
	_rm(root)


# ---- wording ---------------------------------------------------------------------

func test_words_stay_as_written_on_a_handheld() -> void:
	Words.use(true, true)
	Words.install()
	ok(not Words.installed(), "nothing installed on a handheld")
	eq(Words.fit("Not on this handheld. Lower saves battery."), "Not on this handheld. Lower saves battery.", "unchanged")


func test_words_on_a_steam_machine() -> void:
	Words.use(false, false, "Steam Machine")
	eq(Words.fit("Not on this handheld"), "Not on this Steam Machine", "this handheld")
	eq(Words.fit("How should your handheld start?"), "How should your Steam Machine start?", "your handheld")
	eq(Words.fit("This handheld has no gyro"), "This Steam Machine has no gyro", "sentence start")
	eq(Words.fit("Detected handheld"), "Detected device", "bare word")
	eq(Words.fit("The all-in-one companion for Linux handhelds."), "The all-in-one companion for Linux devices.", "plural")
	eq(Words.fit("Needs InputPlumber or Handheld Daemon running"), "Needs InputPlumber or Handheld Daemon running", "a product's name stays")
	eq(Words.fit("Handheld Daemon has no gyro switch for this handheld"), "Handheld Daemon has no gyro switch for this Steam Machine", "both in one line")
	eq(Words.fit("Lower saves battery; higher feels smoother."), "Lower saves power; higher feels smoother.", "battery wording")
	eq(Words.fit("Longest battery"), "Cool and quiet", "the quick goal")
	eq(Words.fit("Keep the handheld plugged in or charged. A password window may pop up."), "Keep the power on. A password window may pop up.", "installer")
	Words.use(true, true)


func test_words_on_an_unknown_box() -> void:
	Words.use(false, false, "")
	eq(Words.fit("Not on this handheld"), "Not on this device", "device")
	eq(Words.fit("your handheld's picture"), "your device's picture", "possessive")
	eq(Words.fit("HANDHELD"), "DEVICE", "capitals")
	Words.use(true, true)


func test_labels_show_the_fitted_text() -> void:
	Words.use(false, false, "Steam Machine")
	Words.install()
	ok(Words.installed(), "installed")
	var l := Label.new()
	l.text = "Puts the handheld to sleep."
	eq(l.atr(l.text), "Puts the Steam Machine to sleep.", "a Label's shown text")
	var b := Button.new()
	b.text = "Every app on this handheld"
	eq(b.atr(b.text), "Every app on this Steam Machine", "a Button's")
	l.free()
	b.free()
	Words.use(true, true)
	Words.install()
	ok(not Words.installed(), "removed again")
	Words.use(false, false)
	Words.install()
	Words.uninstall()
	ok(not Words.installed(), "uninstall() on the way out leaves no Translation for the exit to trip over")
	Words.use(true, true)


## Every string in the texts files, as a device with no battery and no screen
## of its own would read it: no "handheld" left, and "battery" only in the
## lines about batteries themselves (hidden there) or about controllers.
const BATTERY_OK := ["Controller battery", "% battery", "Battery saver", "Battery care", "Battery health", "Battery history",
	"Battery time left", "Battery low", "Battery at", "Sleep at low battery", "on battery", "On battery", "on-battery", "No battery",
	"charge", "Charge", "battery level", "Battery readings", "this battery", "This battery", "the battery", "Battery,",
	"battery drain", "battery power limit", "Battery\n", "enough battery"]


func _strings(v: Variant, out: Array) -> void:
	if v is String:
		out.append(v)
	elif v is Dictionary:
		for k in v:
			_strings(k, out)
			_strings(v[k], out)
	elif v is Array:
		for x in v:
			_strings(x, out)


func _text_scripts(dir: String, out: Array) -> void:
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd") and f.begins_with("texts"):
			out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		_text_scripts(dir.path_join(d), out)


func test_every_text_reads_right_without_a_battery_or_a_screen() -> void:
	Words.use(false, false, "")
	var files := []
	_text_scripts("res://scripts", files)
	ok(files.size() >= 12, "found the texts files (%d)" % files.size())
	var seen := 0
	for path in files:
		var all := []
		_strings((load(path) as GDScript).get_script_constant_map(), all)
		for t in all:
			seen += 1
			var fitted := Words.fit(t)
			ok(fitted.findn("handheld") < 0 or fitted.find("Handheld Daemon") >= 0, "%s: still says handheld: %s" % [path.get_file(), fitted])
			if fitted.findn("battery") >= 0 and " " in t:
				var fine := false
				for part in BATTERY_OK:
					if part in fitted:
						fine = true
				ok(fine, "%s: battery wording with no battery: %s" % [path.get_file(), fitted])
	ok(seen > 800, "walked the texts (%d strings)" % seen)
	Words.use(true, true)


# ---- controllers and the screen games run on ---------------------------------------

func test_glyph_set_follows_the_pad() -> void:
	var Glyph := load("res://scripts/ui/glyph.gd")
	var Buttons := load("res://scripts/device/buttons.gd")
	eq(Glyph.set_for_pad("Sony Interactive Entertainment DualSense Wireless Controller", 0x054c), "ps", "DualSense")
	eq(Glyph.set_for_pad("PS4 Controller"), "ps", "DualShock 4 by name")
	eq(Glyph.set_for_pad("Steam Controller", 0x28de), "deck", "Steam Controller (2026)")
	eq(Glyph.set_for_pad("Xbox Series X Controller", 0x045e), "xbox", "Xbox")
	eq(Glyph.set_for_pad("Microsoft X-Box 360 pad"), "xbox", "what Steam Input and InputPlumber present")
	eq(Glyph.set_for_pad(""), "xbox", "unknown")
	var was: String = Glyph.glyph_set
	Glyph.use_set("ps")
	eq(Glyph.label_for("A"), "✕", "cross where A sits")
	eq(Glyph.label_for("Y"), "△", "triangle")
	eq(Glyph.label_for("LB"), "L1", "L1")
	eq(Glyph.label_for("MENU"), "Options", "Options")
	eq(Glyph.face_color("A").a, 0.0, "shapes aren't Xbox-coloured")
	var f: Font = load("res://theme/gamecove_theme.gd").font("mono_bold")
	for ch in "✕◯□△":
		ok(f.has_char(ch.unicode_at(0)), "the glyph font has " + ch)
	Glyph.use_set(was)
	for cap in Buttons.SET_FILES["ps"]:
		ok(FileAccess.file_exists("res://assets/devices/glyphs/ps/%s.svg" % Buttons.SET_FILES["ps"][cap]), "ps glyph for " + cap)


func test_games_follow_the_real_output() -> void:
	var Main := load("res://scripts/main.gd")
	var claw := {"panel": {"size_in": 8.0, "resolution": [1920, 1200]}, "panel_hz": [48, 120]}
	eq(Main.display_for(claw, {"kind": "handheld", "external": false}, Vector2i(1280, 800), 60.0), {"width": 1920, "height": 1200, "hz": 120},
		"on its own panel: the panel, whatever gamescope's nested size is")
	eq(Main.display_for(claw, {"kind": "tv", "external": true}, Vector2i(3840, 2160), 119.88), {"width": 3840, "height": 2160, "hz": 120},
		"docked to a TV: the TV")
	eq(Main.display_for({"panel": null, "panel_hz": []}, {"kind": "tv", "external": true}, Vector2i(2560, 1440), 60.0), {"width": 2560, "height": 1440, "hz": 60},
		"Steam Machine: what the output is")
	eq(Main.display_for({}, {}, Vector2i(1920, 1080), 0.0)["hz"], 60, "an output that doesn't say its rate")
