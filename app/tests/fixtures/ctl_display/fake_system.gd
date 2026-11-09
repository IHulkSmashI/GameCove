extends RefCounted
## A pretend handheld for the display / audio / system controls: an in-memory
## gamescope root window (xprop), PipeWire (wpctl), NetworkManager (nmcli),
## BlueZ / logind / steamos-manager (busctl), rfkill and systemctl. Writes that
## real tools make to sysfs land in the fixture tree under `root`. Every command
## is recorded in `calls`.

var root := ""                       # fixture tree (sys_root)
var props: Dictionary = {}           # root atoms: name -> raw xprop text
var frozen: Array = []               # atoms gamescope ignores (set "works", nothing changes)
var xprop_ok := true
var gamescope_strings: Array = ["sgsr)", "GAMESCOPE_RESHADE_EFFECT"]
var calls: Array[String] = []

# PipeWire
var wpctl_ok := true
var sinks: Array = []                # [{"id", "name", "volume", "muted"}]
var sources: Array = []
var streams: Array = []              # [{"id", "name", "volume"}]
var default_sink := 0
var default_source := 0

# NetworkManager / BlueZ / steamos-manager
var nmcli_ok := true
var wifi_enabled := true
var bluez_ok := true
var bt_powered := true
var steamos_manager := true
var wifi_pm := 1
var logind_ok := true

var _next_pid := 4000
var _alive: Dictionary = {}


func run(program: String, args: PackedStringArray) -> Dictionary:
	var a := Array(args).filter(func(x): return not str(x).begins_with("--timeout=") and x != "--json=short")
	calls.append(program + " " + " ".join(PackedStringArray(a)))
	match program:
		"xprop": return _xprop(a)
		"wpctl": return _wpctl(a)
		"nmcli": return _nmcli(a)
		"busctl": return _busctl(a)
		"rfkill": return _rfkill(a)
		"systemctl": return {"code": 0, "out": ""}
		"grep":
			var needle: String = a[a.size() - 2]
			return {"code": 0 if needle in gamescope_strings else 1, "out": ""}
	return {"code": -1, "out": ""}


func spawn(_program: String, _args: PackedStringArray) -> int:
	_next_pid += 1
	_alive[_next_pid] = true
	return _next_pid


func kill(pid: int) -> void:
	_alive.erase(pid)


func is_running(pid: int) -> bool:
	return _alive.has(pid)


# --- xprop -----------------------------------------------------------------

func _xprop(a: Array) -> Dictionary:
	if not xprop_ok:
		return {"code": 1, "out": "xprop: unable to open display"}
	if a.size() >= 2 and a[0] == "-root" and a[1] == "-notype":
		var out := ""
		if a.size() == 2:
			for k in props:
				out += "%s = %s\n" % [k, props[k]]
			return {"code": 0, "out": out}
		var atom: String = a[2]
		if props.has(atom):
			return {"code": 0, "out": "%s = %s\n" % [atom, props[atom]]}
		return {"code": 0, "out": "%s:  not found.\n" % atom}
	if a.size() == 3 and a[1] == "-remove":
		props.erase(a[2])
		return {"code": 0, "out": ""}
	if a.size() == 7 and a[1] == "-f" and a[4] == "-set":
		var atom: String = a[2]
		if atom in frozen:
			return {"code": 0, "out": ""}
		if a[3] == "32c":
			props[atom] = ", ".join(PackedStringArray(str(a[6]).split(",")))
		else:
			props[atom] = "\"%s\"" % a[6]
		if atom == "GAMESCOPECTRL_REQUEST_SCREENSHOT":
			_take_screenshot()
		return {"code": 0, "out": ""}
	return {"code": 1, "out": ""}


func _take_screenshot() -> void:
	props.erase("GAMESCOPECTRL_REQUEST_SCREENSHOT")
	DirAccess.make_dir_recursive_absolute(root + "/tmp")
	var f := FileAccess.open(root + "/tmp/gamescope.png", FileAccess.WRITE)
	f.store_string("PNG-%d" % Time.get_ticks_usec())
	f.close()


## Sets a float atom the way gamescope would read it.
func set_float_prop(atom: String, values: Array) -> void:
	var parts := PackedStringArray()
	for v in values:
		var b := PackedByteArray()
		b.resize(4)
		b.encode_float(0, float(v))
		parts.append(str(b.decode_u32(0)))
	props[atom] = ", ".join(parts)


func float_prop(atom: String) -> Array:
	var out := []
	if not props.has(atom):
		return out
	for p in str(props[atom]).split(","):
		var b := PackedByteArray()
		b.resize(4)
		b.encode_u32(0, p.strip_edges().to_int())
		out.append(b.decode_float(0))
	return out


# --- wpctl -------------------------------------------------------------------

func _node(target: String) -> Dictionary:
	var id := default_sink if target == "@DEFAULT_AUDIO_SINK@" else (default_source if target == "@DEFAULT_AUDIO_SOURCE@" else target.to_int())
	for n in sinks + sources + streams:
		if int(n["id"]) == id:
			return n
	return {}


func _wpctl(a: Array) -> Dictionary:
	if not wpctl_ok:
		return {"code": -1, "out": ""}
	match a[0]:
		"status":
			return {"code": 0, "out": status_text()}
		"get-volume":
			var n := _node(a[1])
			if n.is_empty():
				return {"code": 1, "out": ""}
			return {"code": 0, "out": "Volume: %.2f%s\n" % [n["volume"], " [MUTED]" if n.get("muted", false) else ""]}
		"set-volume":
			var i := 1
			var limit := 1.5
			if a[1] == "-l":
				limit = float(a[2])
				i = 3
			var n := _node(a[i])
			if n.is_empty():
				return {"code": 1, "out": ""}
			n["volume"] = minf(float(a[i + 1]), limit)
			return {"code": 0, "out": ""}
		"set-mute":
			var n := _node(a[1])
			if n.is_empty():
				return {"code": 1, "out": ""}
			n["muted"] = a[2] == "1"
			return {"code": 0, "out": ""}
		"set-default":
			var id := int(a[1])
			for n in sinks:
				if int(n["id"]) == id:
					default_sink = id
					return {"code": 0, "out": ""}
			for n in sources:
				if int(n["id"]) == id:
					default_source = id
					return {"code": 0, "out": ""}
			return {"code": 1, "out": ""}
	return {"code": 1, "out": ""}


## Same layout as wireplumber 0.5's `wpctl status`.
func status_text() -> String:
	var t := "PipeWire 'pipewire-0' [1.2.7, deck@steamdeck, cookie:1234]\n └─ Clients:\n        33. WirePlumber  [1.2.7, deck@steamdeck, pid:1200]\n\nAudio\n ├─ Devices:\n │      45. Family 17h/19h HD Audio Controller [alsa]\n │  \n ├─ Sinks:\n"
	for n in sinks:
		t += " │  %s %3d. %-40s [vol: %.2f%s]\n" % ["*" if int(n["id"]) == default_sink else " ", n["id"], n["name"], n["volume"], " MUTED" if n.get("muted", false) else ""]
	t += " │  \n ├─ Sources:\n"
	for n in sources:
		t += " │  %s %3d. %-40s [vol: %.2f%s]\n" % ["*" if int(n["id"]) == default_source else " ", n["id"], n["name"], n["volume"], " MUTED" if n.get("muted", false) else ""]
	t += " │  \n ├─ Filters:\n │  \n └─ Streams:\n"
	for s in streams:
		t += "        %d. %s\n             %d. output_FL       > %s:playback_FL\t[active]\n" % [s["id"], s["name"], int(s["id"]) + 1000, "Speaker"]
	t += "\nVideo\n ├─ Devices:\n │  \n └─ Streams:\n\nSettings\n └─ Default Configured Devices:\n         0. Audio/Sink    alsa_output.pci-0000_04_00.5-platform-acp5x_mach.0.HiFi__hw_acp5x_1__sink\n"
	return t


# --- nmcli / busctl / rfkill ------------------------------------------------------

func _nmcli(a: Array) -> Dictionary:
	if not nmcli_ok:
		return {"code": -1, "out": ""}
	if a.size() == 2 and a[0] == "radio" and a[1] == "wifi":
		return {"code": 0, "out": "enabled\n" if wifi_enabled else "disabled\n"}
	if a.size() == 3 and a[0] == "radio" and a[1] == "wifi":
		wifi_enabled = a[2] == "on"
		return {"code": 0, "out": ""}
	return {"code": 1, "out": ""}


func _busctl(a: Array) -> Dictionary:
	var bus: String = a[0]
	var verb: String = a[1]
	if bus == "--system" and verb == "call" and a[5] == "SetBrightness":
		if not logind_ok:
			return {"code": 1, "out": ""}
		var f := FileAccess.open(root + "/sys/class/backlight/%s/brightness" % a[8], FileAccess.WRITE)
		f.store_string(str(a[9]))
		f.close()
		return {"code": 0, "out": ""}
	if bus == "--system" and a[2] == "org.bluez":
		if not bluez_ok or not FileAccess.file_exists(root + "/sys/class/bluetooth/" + str(a[3]).get_file() + "/name"):
			return {"code": 1, "out": ""}
		if verb == "get-property":
			return {"code": 0, "out": JSON.stringify({"type": "b", "data": bt_powered})}
		if verb == "set-property":
			if a[7] == "true" and _soft("bluetooth"):
				return {"code": 1, "out": "Failed to set property Powered: org.bluez.Error.Blocked"}
			bt_powered = a[7] == "true"
			return {"code": 0, "out": ""}
	if bus == "--user" and a[2] == "com.steampowered.SteamOSManager1" and steamos_manager:
		if verb == "get-property":
			return {"code": 0, "out": JSON.stringify({"type": "u", "data": wifi_pm})}
		if verb == "set-property":
			wifi_pm = int(a[7])
			return {"code": 0, "out": ""}
	return {"code": 1, "out": ""}


func _rfkill_dirs() -> Array:
	var base := root + "/sys/class/rfkill"
	return Array(DirAccess.get_directories_at(base)).map(func(n): return base.path_join(n)) if DirAccess.dir_exists_absolute(base) else []


func _soft(type: String) -> bool:
	for d in _rfkill_dirs():
		if FileAccess.get_file_as_string(d.path_join("type")).strip_edges() == type:
			return FileAccess.get_file_as_string(d.path_join("soft")).strip_edges() == "1"
	return false


func _rfkill(a: Array) -> Dictionary:
	if a.size() != 2 or not a[0] in ["block", "unblock"]:
		return {"code": 1, "out": ""}
	var v := "1" if a[0] == "block" else "0"
	var want: String = {"wlan": "wlan", "wifi": "wlan", "bluetooth": "bluetooth", "all": "all"}.get(a[1], a[1])
	for d in _rfkill_dirs():
		var t := FileAccess.get_file_as_string(d.path_join("type")).strip_edges()
		if want == "all" or t == want:
			var f := FileAccess.open(d.path_join("soft"), FileAccess.WRITE)
			f.store_string(v + "\n")
			f.close()
	if want in ["all", "wlan"] and v == "1":
		pass   # NetworkManager keeps its own switch; the rfkill block is what shows
	return {"code": 0, "out": ""}
