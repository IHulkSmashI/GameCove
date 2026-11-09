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
## Writes: where every file a change needs is world-writable (the MSI Claw's
## hid-msi node on Bazzite has effect, multi_intensity and brightness at 0666),
## apply_direct() writes them itself and reads them back. Anything else (enabled
## and speed are 0644 root there; the Legion rings need profile/mode first) goes
## through the no-password root action `gamecove-fix-set controller-led set <spec>`
## (fixes/controller-led):
##   <zone>,<rrggbb>,<percent>[,<effect>[,<speed percent>]]   zone: all | 0..9
##   off
## Reading needs no rights. Reads go line by line: real sysfs files report a size
## of 4096, and FileAccess.get_file_as_string() returns "" for them (that hid
## every LED on real hardware while the regular-file fixtures worked).
##
## hid-msi ABI (drivers/hid/hid-msi.c; OGC's 0100 patch names the node
## go:rgb:joystick_rings, the Legion Go name, so Steam lights it): effect one of
## effect_index (monocolor breathe chroma rainbow frostfire), enabled true|false
## (false = dark whatever the rest says), speed 0..speed_range max (20 = fastest),
## multi_intensity per multi_max_intensity (100), brightness 0..max_brightness;
## the driver sends the frame 50 ms after the last write.
##
## Quirks from HueSync (github.com/honjow/HueSync, tested on these handhelds):
##  * py_modules/devices/legion_go2.py: channel values scale by multi_max_intensity
##    (the go ring is 0-100); the ring needs enabled=true, mode=custom and a valid
##    profile (the root action does that).
##  * py_modules/devices/asus_ally.py: the Ally may list 12 channels in multi_index
##    (4 zones x RGB); every zone takes the colour.
##  * src/index.tsx: lights are applied again 5 s after resume (firmware resets
##    some of them); the provider lists which controls (REAPPLY_AFTER_RESUME).

const DeviceScript := preload("res://scripts/device/device.gd")
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


## Line by line, so a sysfs file's fake size (4096) or a /proc file's 0 doesn't blank it.
static func _read(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var lines := PackedStringArray()
	while lines.size() < 64:
		var l := f.get_line()
		if f.eof_reached() and l == "":
			break
		lines.append(l)
		if f.eof_reached():
			break
	return "\n".join(lines).strip_edges()


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


## The colour a node shows (first red/green/blue triplet, or the first packed "rgb"
## channel: hid-asus's Ally rings list multi_index "rgb rgb rgb rgb", one 0xRRGGBB
## intensity per zone; OGC patch 0155 "hid-asus-ally: Add joystick LED ring support").
static func color_of(node: Dictionary) -> Color:
	var rgb := {"red": 0, "green": 0, "blue": 0}
	var idx: Array = node.get("index", [])
	var inten: Array = node.get("intensity", [])
	var mx: Array = node.get("chan_max", [])
	for i in mini(idx.size(), inten.size()):
		if idx[i] == "rgb":
			var v := int(inten[i])
			return Color8((v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff)
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


# ---- direct writes (world-writable nodes) ---------------------------------------------

const DIRECT_OK := 1      # written and read back
const DIRECT_NO := 0      # a needed file isn't writable for us: use the root action
const DIRECT_FAIL := -1   # tried, a value didn't stick; what was there is back


static func writable(path: String) -> bool:
	return FileAccess.file_exists(path) and (int(FileAccess.get_unix_permissions(path)) & 2) != 0   # others may write (o+w)


static func _write(path: String, value: String) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(value + "\n")
	f.close()
	return _read(path) == value


## multi_intensity for a colour, in the node's multi_index order, scaled by
## multi_max_intensity (fixes/controller-led rgb_line does the same).
static func intensity_line(node: Dictionary, color: Color) -> String:
	var rgb := {"red": color.r8, "green": color.g8, "blue": color.b8}
	var mx: Array = node.get("chan_max", [])
	var out := PackedStringArray()
	var idx: Array = node.get("index", [])
	for i in idx.size():
		if idx[i] == "rgb":   # packed 0xRRGGBB (hid-asus Ally zones)
			out.append(str((color.r8 << 16) | (color.g8 << 8) | color.b8))
			continue
		var v: int = rgb.get(idx[i], 0)
		var top := int(mx[i]) if i < mx.size() and int(mx[i]) > 0 else 255
		if top != 255:
			v = int((v * top + 127) / 255)
		out.append(str(v))
	return " ".join(out)


## The attribute writes one node needs for a spec, in the root action's order:
## [[attribute, value], ...]; [] when the spec doesn't fit the node.
static func plan(node: Dictionary, s: String) -> Array:
	var path: String = node["path"]
	var want_on := s != "off"
	var out: Array = []
	if want_on:
		var p := s.split(",")
		var color := Color.html("#" + p[1])
		var pct := int(p[2])
		var eff := p[3] if p.size() > 3 else ""
		if eff != "" and not eff in node.get("effects", []):
			return []
		if eff != "" and p.size() > 4 and (node.get("speed_range", []) as Array).size() == 2:
			var r: Array = node["speed_range"]
			out.append(["speed", str(int(r[0]) + int((int(r[1]) - int(r[0])) * int(p[4]) / 100))])
		out.append(["multi_intensity", intensity_line(node, color)])
		out.append(["brightness", str(int((int(node["max"]) * pct + 50) / 100))])
		if eff != "":
			out.append(["effect", eff])
		want_on = pct > 0
	else:
		out.append(["brightness", "0"])
	if node.get("enabled") != null and bool(node["enabled"]) != want_on:
		# brightness 0 is dark already: off needn't touch a root-only enabled
		if want_on or writable(path + "/enabled"):
			out.append(["enabled", "true" if want_on else "false"])
	# drop writes that change nothing (an unwritable file holding the right value is fine)
	return out.filter(func(w): return _read(path + "/" + w[0]) != w[1])


## Writes a spec straight to world-writable nodes. Nodes that need the root
## action's set-up (Legion profile/mode, AYN led_mode) never go direct.
static func apply_direct(nodes: Array, s: String) -> int:
	if not valid_spec(s) or nodes.is_empty():
		return DIRECT_NO
	var zone := "all" if s == "off" else s.split(",")[0]
	var targets: Array = nodes if zone == "all" else ([nodes[int(zone)]] if int(zone) < nodes.size() else [])
	if targets.is_empty():
		return DIRECT_NO
	var plans: Array = []
	for n in targets:
		for extra in ["profile", "mode", "led_mode"]:
			if FileAccess.file_exists(str(n["path"]) + "/" + extra):
				return DIRECT_NO
		var pl := plan(n, s)
		if s != "off" and pl.is_empty() and not _already(n, s):
			return DIRECT_NO
		for w in pl:
			if not writable(str(n["path"]) + "/" + w[0]):
				return DIRECT_NO
		plans.append(pl)
	for i in targets.size():
		var path: String = targets[i]["path"]
		var before := {}
		for w in plans[i]:
			before[w[0]] = _read(path + "/" + w[0])
		for w in plans[i]:
			if not _write(path + "/" + w[0], w[1]):
				for k in before:
					_write(path + "/" + k, before[k])
				return DIRECT_FAIL
	return DIRECT_OK


## A spec whose plan is empty: the node already shows it (or the effect is unknown).
static func _already(node: Dictionary, s: String) -> bool:
	var p := s.split(",")
	return p.size() <= 3 or p[3] in node.get("effects", [])


## True when GameCove can change the node's colour and brightness without root.
static func direct_capable(node: Dictionary) -> bool:
	return writable(str(node.get("path", "")) + "/multi_intensity") and writable(str(node.get("path", "")) + "/brightness")
