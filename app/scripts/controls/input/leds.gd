extends RefCounted
## Handheld RGB through the kernel's LED class (/sys/class/leds), for when
## Handheld Daemon isn't the one driving the lights (Bazzite's default stack:
## InputPlumber, which only forwards a game's lightbar colour to these nodes).
##
## Nodes (multicolor LED class: multi_index, multi_intensity, brightness,
## max_brightness), by driver:
##   ally:rgb:joystick_rings          ASUS ROG Ally / Ally X / Xbox Ally (hid-asus)
##   go:rgb:joystick_rings            Lenovo Legion Go / Go 2 (hid-lenovo-go)   + effect, speed, enabled
##   go_s:rgb:joystick_rings          Lenovo Legion Go S (hid-lenovo-go-s)      + effect, speed, enabled
##   msi_claw:rgb:joystick_rings      MSI Claw (hid-msi, patch series 2026)     + effect, speed, enabled
##   ayaneo:rgb:joystick_rings        AYANEO (ayaneo-platform / ayaneo-ec)
##   multicolor:chassis               older AYANEO / AYN naming
##   ayn:rgb:joystick_rings           AYN Loki (ayn-ec)                          + led_mode
##   zotac:rgb:spectra_zone_0 / _1    ZOTAC Zone, two zones (zotac-zone-platform)
## Sources: kernel Documentation/ABI/testing/sysfs-driver-hid-lenovo-go{,-s};
## LKML "HID: hid-msi: Add RGB control interface" (v13, 2026-07); InputPlumber
## rootfs/usr/share/inputplumber/devices/*.yaml (group: led); hhd
## src/hhd/controller/physical/rgb.py.
##
## The nodes are root-only to write, so writes go through the no-password root
## action `gamecove-fix-set controller-led set <spec>` (fixes/controller-led):
##   <zone>,<rrggbb>,<percent>[,<effect>[,<speed percent>]]   zone: all | 0..9
##   off
## Reading needs no rights.
##
## Quirks from HueSync (github.com/honjow/HueSync, tested on these handhelds):
##  * py_modules/devices/legion_go2.py: channel values scale by multi_max_intensity
##    (the go ring is 0-100); the ring needs enabled=true, mode=custom and a valid
##    profile (the root action does that).
##  * py_modules/devices/asus_ally.py: the Ally may list 12 channels in multi_index
##    (4 zones x RGB); every zone takes the colour.
##  * src/index.tsx: lights are applied again 5 s after resume (firmware resets
##    some of them); the provider lists which controls (REAPPLY_AFTER_RESUME).

const PATTERNS: Array[String] = ["*:rgb:joystick_rings", "multicolor:chassis", "*:rgb:spectra_zone_*"]
const FIX_SET_HELPER := "/usr/libexec/gamecove/gamecove-fix-set"
const FIX := "controller-led"
## Kernel effect names -> GameCove effect values (shared with hhd's modes). The
## Lenovo/MSI drivers call the whole-ring colour cycle "chroma" and the spinning one
## "rainbow": HueSync (github.com/honjow/HueSync) py_modules/devices/legion_go2.py,
## GO2_EFFECTS = {Rainbow: "chroma", Spiral: "rainbow"}.
const KERNEL_EFFECTS := {"monocolor": "solid", "breathe": "pulse", "chroma": "rainbow", "rainbow": "spiral", "frostfire": "frostfire"}


## Every RGB node under <sys_root>/sys/class/leds, sorted by name:
## [{"name", "path", "index": ["red", "green", "blue"], "intensity": [ints],
##   "brightness": int, "max": int, "effects": [kernel names], "effect": String,
##   "speed": int, "speed_range": [min, max] or [], "enabled": bool or null}]
static func scan(sys_root: String) -> Array:
	var base := sys_root + "/sys/class/leds"
	var d := DirAccess.open(base)
	if d == null:
		return []
	var names: Array = []
	for n in d.get_directories() + d.get_files():
		if not n in names and PATTERNS.any(func(p): return n.match(p)):
			names.append(n)
	names.sort()
	var out: Array = []
	for n in names:
		var node := read_node(base + "/" + n)
		if not node.is_empty():
			node["name"] = n
			out.append(node)
	return out


static func _read(path: String) -> String:
	return FileAccess.get_file_as_string(path).strip_edges() if FileAccess.file_exists(path) else ""


static func read_node(path: String) -> Dictionary:
	var idx := _read(path + "/multi_index")
	var inten := _read(path + "/multi_intensity")
	var mx := _read(path + "/max_brightness")
	if idx == "" or inten == "" or not mx.is_valid_int() or int(mx) <= 0:
		return {}
	var node := {"path": path, "index": Array(idx.split(" ", false)),
		"intensity": Array(inten.split(" ", false)).map(func(x): return int(x)),
		"chan_max": Array(_read(path + "/multi_max_intensity").split(" ", false)).map(func(x): return int(x)),
		"brightness": int(_read(path + "/brightness")), "max": int(mx),
		"effects": [], "effect": "", "speed": -1, "speed_range": [], "enabled": null}
	var eff_idx := _read(path + "/effect_index")
	if eff_idx != "":
		node["effects"] = Array(eff_idx.split(" ", false))
		node["effect"] = _read(path + "/effect")
	var sr := _read(path + "/speed_range")
	if sr.contains("-") and _read(path + "/speed").is_valid_int():
		var parts := sr.split("-")
		if parts.size() == 2 and parts[0].strip_edges().is_valid_int() and parts[1].strip_edges().is_valid_int():
			node["speed_range"] = [int(parts[0]), int(parts[1])]
			node["speed"] = int(_read(path + "/speed"))
	var en := _read(path + "/enabled")
	if en in ["true", "false"]:
		node["enabled"] = en == "true"
	return node


## The colour a node shows (first red/green/blue triplet).
static func color_of(node: Dictionary) -> Color:
	var rgb := {"red": 0, "green": 0, "blue": 0}
	var idx: Array = node.get("index", [])
	var inten: Array = node.get("intensity", [])
	var mx: Array = node.get("chan_max", [])
	for i in mini(idx.size(), inten.size()):
		if idx[i] in rgb and rgb[idx[i]] == 0:
			var top := int(mx[i]) if i < mx.size() and int(mx[i]) > 0 else 255
			rgb[idx[i]] = clampi(int(roundf(float(inten[i]) * 255.0 / float(top))), 0, 255)
	return Color8(rgb["red"], rgb["green"], rgb["blue"])


static func brightness_pct(node: Dictionary) -> float:
	var on: Variant = node.get("enabled")
	if on == false:
		return 0.0
	return roundf(100.0 * float(node.get("brightness", 0)) / float(maxi(1, int(node.get("max", 1)))))


## GameCove effect value of a node: off, solid or a kernel effect mapped through
## KERNEL_EFFECTS.
static func effect_of(node: Dictionary) -> String:
	if brightness_pct(node) <= 0.0:
		return "off"
	var e := str(node.get("effect", ""))
	return KERNEL_EFFECTS.get(e, e) if e != "" else "solid"


## Effects a node can show, as GameCove values ("off" and "solid" always).
static func effects_of(node: Dictionary) -> Array:
	var out: Array = ["off", "solid"]
	for e in node.get("effects", []):
		var v: String = KERNEL_EFFECTS.get(e, e)
		if not v in out:
			out.append(v)
	return out


## Kernel name for a GameCove effect on this node, "" when it has none.
static func kernel_effect(node: Dictionary, effect: String) -> String:
	for k in node.get("effects", []):
		if KERNEL_EFFECTS.get(k, k) == effect:
			return k
	return ""


static func speed_pct(node: Dictionary) -> float:
	var r: Array = node.get("speed_range", [])
	if r.size() != 2 or int(r[1]) <= int(r[0]):
		return -1.0
	return roundf(100.0 * float(int(node["speed"]) - int(r[0])) / float(int(r[1]) - int(r[0])))


## The fix-set value for one zone ("all" or its index).
static func spec(zone: String, color: Color, percent: float, effect := "", speed := -1.0) -> String:
	var s := "%s,%s,%d" % [zone, color.to_html(false).to_lower(), clampi(int(roundf(percent)), 0, 100)]
	if effect != "":
		s += "," + effect
		if speed >= 0.0:
			s += ",%d" % clampi(int(roundf(speed)), 0, 100)
	return s


static func valid_spec(s: String) -> bool:
	if s == "off":
		return true
	var re := RegEx.new()
	re.compile("^(all|[0-9]),[0-9a-f]{6},([0-9]|[1-9][0-9]|100)(,[a-z]{1,16}(,([0-9]|[1-9][0-9]|100))?)?$")
	return re.search(s) != null


## Runs the root action; true when it exited 0.
static func apply(runner: RefCounted, s: String) -> bool:
	if runner == null or not valid_spec(s):
		return false
	var r: Dictionary = runner.run("pkexec", PackedStringArray([FIX_SET_HELPER, FIX, "set", s]))
	return int(r.get("code", -1)) == 0
