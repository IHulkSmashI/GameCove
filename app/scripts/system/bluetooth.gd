extends RefCounted
## Bluetooth devices: the ones paired with this handheld and new ones nearby,
## with connect, disconnect, pair and forget. Through BlueZ on the system bus
## (busctl, part of systemd), the way the Bluetooth Decky plugin
## (Outpox/Bluetooth) and providers/system.gd's on/off switch already talk to
## it; finding new devices uses BlueZ's own `bluetoothctl --timeout N scan on`,
## because BlueZ stops a scan the moment the client that asked for it leaves
## the bus (a one-shot busctl call would stop it at once).
##
## Pairing asks for no PIN: controllers, headphones and speakers pair the
## "just works" way. A keyboard that wants a code typed on it pairs from
## Desktop Mode.
##
## Everything blocks (busctl, bluetoothctl): call from a worker thread only.
## Nothing here runs by itself; the Settings card reads when it's shown and
## after an action.

const Busctl := preload("res://scripts/device/busctl.gd")

const BLUEZ := "org.bluez"
const DEVICE := "org.bluez.Device1"
const ADAPTER := "org.bluez.Adapter1"
const BATTERY := "org.bluez.Battery1"
const SCAN_S := 10
## Pairing waits for the device to answer (BlueZ's own default is 25 s).
const PAIR_TIMEOUT_S := 30

## BlueZ's device Icon -> GameCove icon name.
const ICONS := {
	"input-gaming": "gamepad", "audio-headset": "volume", "audio-headphones": "volume", "audio-card": "volume",
	"input-keyboard": "sliders", "input-mouse": "mouse", "input-tablet": "mouse", "phone": "handheld",
	"computer": "screen", "video-display": "screen",
}


static func _v(x: Variant) -> Variant:
	return x.get("data") if x is Dictionary and x.has("type") and x.has("data") else x


static func _bus(runner: RefCounted, timeout_s := 4) -> RefCounted:
	var b: RefCounted = Busctl.new(runner, "--system")
	b.timeout_s = timeout_s
	return b


## BlueZ's object tree (GetManagedObjects) as {path: {iface: {prop: variant}}}, or {}.
static func objects(runner: RefCounted) -> Dictionary:
	if runner == null:
		return {}
	var r: Variant = _bus(runner).call_method(BLUEZ, "/", "org.freedesktop.DBus.ObjectManager", "GetManagedObjects")
	return r[0] if r is Array and not (r as Array).is_empty() and r[0] is Dictionary else {}


## The adapters: [{"path", "powered"}], sorted by path.
static func adapters(tree: Dictionary) -> Array:
	var out := []
	for path in tree:
		var a: Variant = tree[path].get(ADAPTER) if tree[path] is Dictionary else null
		if a is Dictionary:
			out.append({"path": str(path), "powered": _v(a.get("Powered", false)) == true})
	out.sort_custom(func(x, y): return x["path"] < y["path"])
	return out


## Every device worth showing: paired ones, connected ones and named new ones
## (nameless addresses a scan turns up are left out). Connected first, then
## paired, then by name.
## [{"path", "adapter", "address", "name", "icon", "paired", "connected",
##   "trusted", "battery" (-1 = not reported)}]
static func devices(tree: Dictionary) -> Array:
	var out := []
	for path in tree:
		var d: Variant = tree[path].get(DEVICE) if tree[path] is Dictionary else null
		if not d is Dictionary:
			continue
		var paired: bool = _v(d.get("Paired", false)) == true
		var connected: bool = _v(d.get("Connected", false)) == true
		var named := str(_v(d.get("Name", ""))).strip_edges()
		var alias := str(_v(d.get("Alias", ""))).strip_edges()
		var address := str(_v(d.get("Address", ""))).strip_edges()
		if not paired and not connected and named == "":
			continue
		var name := alias if alias != "" and alias.replace("-", ":") != address else (named if named != "" else address)
		var bat := -1
		var b: Variant = tree[path].get(BATTERY)
		if b is Dictionary and b.has("Percentage"):
			bat = int(_v(b["Percentage"]))
		out.append({"path": str(path), "adapter": str(path).get_base_dir(), "address": address, "name": name,
			"icon": ICONS.get(str(_v(d.get("Icon", ""))), "bluetooth"), "paired": paired, "connected": connected,
			"trusted": _v(d.get("Trusted", false)) == true, "battery": bat})
	out.sort_custom(func(x, y):
		if x["connected"] != y["connected"]:
			return x["connected"]
		if x["paired"] != y["paired"]:
			return x["paired"]
		return str(x["name"]).naturalnocasecmp_to(str(y["name"])) < 0)
	return out


## {"adapters": [...], "devices": [...], "powered": bool (any adapter on)} in one bus call.
static func snapshot(runner: RefCounted) -> Dictionary:
	var tree := objects(runner)
	var ads := adapters(tree)
	return {"adapters": ads, "devices": devices(tree), "powered": ads.any(func(a): return a["powered"])}


static func _device_path_ok(path: String) -> bool:
	return RegEx.create_from_string("^/org/bluez/hci[0-9]+/dev(_[0-9A-Fa-f]{2}){6}$").search(path) != null


static func _call(runner: RefCounted, path: String, iface: String, method: String, args: Array = [], timeout_s := 4) -> bool:
	if runner == null:
		return false
	var argv := PackedStringArray(["--system", "--timeout=%d" % timeout_s, "call", BLUEZ, path, iface, method])
	argv.append_array(PackedStringArray(args))
	return int(runner.run("busctl", argv).get("code", -1)) == 0


static func connect_device(runner: RefCounted, path: String) -> bool:
	return _device_path_ok(path) and _call(runner, path, DEVICE, "Connect", [], 15)


static func disconnect_device(runner: RefCounted, path: String) -> bool:
	return _device_path_ok(path) and _call(runner, path, DEVICE, "Disconnect")


## Pairs, trusts (so it reconnects by itself next time) and connects a new device.
static func pair(runner: RefCounted, path: String) -> bool:
	if not _device_path_ok(path):
		return false
	if not _call(runner, path, DEVICE, "Pair", [], PAIR_TIMEOUT_S):
		return false
	_bus(runner).set_prop(BLUEZ, path, DEVICE, "Trusted", "b", "true")
	_call(runner, path, DEVICE, "Connect", [], 15)
	return true


## Removes a paired device (BlueZ forgets its keys; it has to pair again).
static func forget(runner: RefCounted, path: String) -> bool:
	return _device_path_ok(path) and _call(runner, path.get_base_dir(), ADAPTER, "RemoveDevice", ["o", path])


## Looks for new devices for `seconds` (blocks that long), then reads again.
static func scan(runner: RefCounted, seconds := SCAN_S) -> Dictionary:
	if runner != null:
		runner.run("bluetoothctl", PackedStringArray(["--timeout", str(clampi(seconds, 3, 30)), "scan", "on"]))
	return snapshot(runner)
