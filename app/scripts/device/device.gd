extends Node
## Knows which handheld we're on and reads live battery and power numbers.
## Read-only: nothing here writes to the system.

const DEVICE_TABLE := "res://data/devices.json"
const DMI := "/sys/class/dmi/id/"
const POWER_SUPPLY := "/sys/class/power_supply/"

var board_name := ""
var product_name := ""
var sys_vendor := ""
## The matched row from devices.json, or an empty Dictionary on unknown hardware.
var profile: Dictionary = {}


func _ready() -> void:
	board_name = read_text(DMI + "board_name")
	product_name = read_text(DMI + "product_name")
	sys_vendor = read_text(DMI + "sys_vendor")
	profile = match_device(load_table(), board_name, product_name)


func display_name() -> String:
	if profile.has("name"):
		return profile["name"]
	if product_name != "":
		return product_name
	return "Unknown device"


func support_level() -> String:
	return profile.get("support", "generic")


static func read_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text().strip_edges()


static func load_table() -> Array:
	var raw := read_text(DEVICE_TABLE)
	if raw == "":
		return []
	var parsed: Variant = JSON.parse_string(raw)
	if typeof(parsed) != TYPE_DICTIONARY:
		return []
	return parsed.get("devices", [])


## Board name is checked first: some vendors put marketing text in product_name.
static func match_device(devices: Array, board: String, product: String) -> Dictionary:
	for key in ["board_name", "product_name"]:
		var value := board if key == "board_name" else product
		if value == "":
			continue
		for d in devices:
			var m: Dictionary = d.get("match", {})
			if value in m.get(key, []):
				return d
	return {}


## First battery found, e.g. BAT0 or BAT1. Empty string when there's none.
func battery_path() -> String:
	var dir := DirAccess.open(POWER_SUPPLY)
	if dir == null:
		return ""
	for name in dir.get_directories():
		if name.begins_with("BAT"):
			return POWER_SUPPLY + name + "/"
	return ""


## {"percent": int, "status": String, "watts": float}; missing values are -1 / "".
func battery() -> Dictionary:
	var out := {"percent": -1, "status": "", "watts": -1.0}
	var bat := battery_path()
	if bat == "":
		return out
	var cap := read_text(bat + "capacity")
	if cap.is_valid_int():
		out["percent"] = cap.to_int()
	out["status"] = read_text(bat + "status")
	var power_uw := read_text(bat + "power_now")
	if power_uw.is_valid_int():
		out["watts"] = power_uw.to_int() / 1_000_000.0
	else:
		var cur := read_text(bat + "current_now")
		var volt := read_text(bat + "voltage_now")
		if cur.is_valid_int() and volt.is_valid_int():
			out["watts"] = cur.to_int() * volt.to_int() / 1e12
	return out


## Read helpers for the power layer. `root` is a filesystem prefix ("" on the
## real system, a fixture folder in tests).

## The hwmon folder whose "name" file is `hwmon_name` (e.g. "msi_wmi_platform"), or "".
static func find_hwmon(hwmon_name: String, root := "") -> String:
	var base := root + "/sys/class/hwmon/"
	var dir := DirAccess.open(base)
	if dir == null:
		return ""
	var names := Array(dir.get_directories()) + Array(dir.get_files())
	names.sort()
	for n in names:
		if read_text(base + n + "/name") == hwmon_name:
			return base + n + "/"
	return ""


## True when a charger is connected (a Mains or USB supply reports online=1).
static func ac_online(root := "") -> bool:
	var base := root + POWER_SUPPLY
	var dir := DirAccess.open(base)
	if dir == null:
		return false
	for n in Array(dir.get_directories()) + Array(dir.get_files()):
		var kind := read_text(base + n + "/type")
		if (kind == "Mains" or kind == "USB") and read_text(base + n + "/online") == "1":
			return true
	return false


## The battery's charge_control_end_threshold file, or "" when the kernel has none.
static func charge_threshold_path(root := "") -> String:
	var base := root + POWER_SUPPLY
	var dir := DirAccess.open(base)
	if dir == null:
		return ""
	var names := Array(dir.get_directories()) + Array(dir.get_files())
	names.sort()
	for n in names:
		var p: String = base + n + "/charge_control_end_threshold"
		if read_text(base + n + "/type") == "Battery" and FileAccess.file_exists(p):
			return p
	return ""
