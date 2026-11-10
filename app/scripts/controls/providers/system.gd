extends RefCounted
## Radios and system actions: Wi-Fi, Bluetooth, airplane mode, Wi-Fi power
## saving, sleep now, screenshot, keep awake. Everything here works for the
## user on the active seat without root or a prompt:
##   Wi-Fi        nmcli radio wifi on|off            (NetworkManager)
##   Bluetooth    org.bluez Adapter1.Powered          (BlueZ over D-Bus, busctl)
##   airplane     rfkill block all / unblock by type  (/dev/rfkill has uaccess)
##   power save   steamos-manager WifiPowerManagement1 (user bus)
##   sleep        systemctl suspend                   (logind)
##   screenshot   gamescope GAMESCOPECTRL_REQUEST_SCREENSHOT -> /tmp/gamescope.png
##   keep awake   systemd-inhibit --what=idle:sleep, tied to our process
## Hooks run on the Controls worker.

const Ctl := preload("res://scripts/controls/control.gd")
const XAtoms := preload("res://scripts/controls/display/xatoms.gd")
const Busctl := preload("res://scripts/device/busctl.gd")
const PanelInfo := preload("res://scripts/controls/display/panel.gd")
const Store := preload("res://scripts/controls/display/store.gd")
const T := preload("res://scripts/controls/display/texts_display.gd")
const Sysfs := preload("res://scripts/controls/display/sysfs.gd")

const BLUEZ := "org.bluez"
const BLUEZ_ADAPTER := "org.bluez.Adapter1"
const SM_SERVICE := "com.steampowered.SteamOSManager1"
const SM_PATH := "/com/steampowered/SteamOSManager1"
const SM_WIFI_PM := "com.steampowered.SteamOSManager1.WifiPowerManagement1"   # WifiPowerManagementState u: 0 off, 1 on
const A_SCREENSHOT := "GAMESCOPECTRL_REQUEST_SCREENSHOT"
## gamescope_control screenshot_type: 1 = base plane only (the game, without
## our quick menu on top). gamescope writes it to /tmp/gamescope.png.
const SCREENSHOT_TYPE := 1
const SCREENSHOT_TMP := "/tmp/gamescope.png"
const SCREENSHOT_DIR := "Pictures/Screenshots"
const SCREENSHOT_WAIT_MS := 3000

var _xa: RefCounted
var _store: RefCounted
var _store_ctx: Variant = null
var _inhibit_pid := 0


func setup(_ctx: Dictionary) -> void:
	pass


func controls() -> Array:
	return [
		# airplane mode switches both radios, and a radio coming on ends airplane mode: each
		# write reads the others again, or they keep showing the old state
		_mk("network.wifi", "network", {"kind": "toggle", "default_value": true, "affects": ["network.airplane"]}, _detect_wifi, _read_wifi, _write_wifi),
		_mk("network.bluetooth", "network", {"kind": "toggle", "default_value": true, "affects": ["network.airplane"]}, _detect_bt, _read_bt, _write_bt),
		_mk("network.airplane", "network", {"kind": "toggle", "default_value": false, "affects": ["network.wifi", "network.bluetooth"]}, _detect_airplane,
			_read_airplane, _write_airplane),
		_mk("network.wifi_power_save", "network", {"kind": "toggle", "default_value": true}, _detect_wifi_pm,
			func(c): return _wifi_pm(c) == 1,
			func(c, v): return _user_bus(c).set_prop(SM_SERVICE, SM_PATH, SM_WIFI_PM, "WifiPowerManagementState", "u", "1" if v else "0")),
		_mk("system.sleep", "system", {"kind": "action"}, _detect_sleep, func(_c): return null,
			func(c, _v): return _ok(c.ctx.runner.run("systemctl", PackedStringArray(["suspend"])))),
		_mk("system.screenshot", "system", {"kind": "action"},
			func(c): return "" if _x(c).running() else T.NO_GAMESCOPE, func(_c): return null, _write_screenshot),
		_mk("system.keep_awake", "system", {"kind": "toggle", "default_value": false},
			func(_c): return "", func(c): return _inhibit_alive(c), _write_keep_awake),
	]


func _mk(id: String, group: String, spec: Dictionary, d: Callable, r: Callable, w: Callable) -> RefCounted:
	var s := {"id": id, "title": T.title(id), "help": T.help(id), "group": group, "per_game": false}
	s.merge(spec, true)
	var c = Ctl.make(s, d, r, w)
	c.set_meta("provider", self)
	return c


func _x(c) -> RefCounted:
	if _xa == null or not is_same(_xa.ctx, c.ctx):
		_xa = XAtoms.new(c.ctx)
	return _xa


func _st(c) -> RefCounted:
	if _store == null or not is_same(_store_ctx, c.ctx):
		_store = Store.new(c.ctx, "system", PanelInfo.device_id(c.ctx))
		_store_ctx = c.ctx
	return _store


static func _ok(r: Dictionary) -> bool:
	return int(r.get("code", -1)) == 0


func _run(c, program: String, args: Array) -> Dictionary:
	var runner = c.ctx.get("runner")
	return runner.run(program, PackedStringArray(args)) if runner != null else {"code": -1, "out": ""}


func _sys(c) -> String:
	return str(c.ctx.get("sys_root", ""))


static func _entries(dir: String) -> Array:
	return Sysfs.entries(dir)


static func _read_text(path: String) -> String:
	return Sysfs.read_text(path)


# --- rfkill (sysfs read, rfkill tool write) ----------------------------------

## [{"type": "wlan"|"bluetooth"|..., "soft": bool, "hard": bool}] from /sys/class/rfkill.
func rfkill_state(c) -> Array:
	var base := _sys(c) + "/sys/class/rfkill"
	var out := []
	for n in _entries(base):
		var d := base.path_join(n)
		var t := _read_text(d.path_join("type"))
		if t == "":
			continue
		out.append({"type": t, "soft": _read_text(d.path_join("soft")) == "1", "hard": _read_text(d.path_join("hard")) == "1"})
	return out


func _blocked(c, type: String) -> bool:
	for r in rfkill_state(c):
		if r["type"] == type and (r["soft"] or r["hard"]):
			return true
	return false


func _unblock(c, type: String) -> void:
	if _blocked(c, type):
		_run(c, "rfkill", ["unblock", type])


# --- Wi-Fi -----------------------------------------------------------------------

func _detect_wifi(c) -> String:
	if _entries(_sys(c) + "/sys/class/ieee80211").is_empty():
		return T.NO_WIFI
	return "" if _ok(_run(c, "nmcli", ["radio", "wifi"])) else T.NO_NMCLI


func _read_wifi(c) -> Variant:
	var r := _run(c, "nmcli", ["radio", "wifi"])
	if not _ok(r):
		return null
	return str(r.get("out", "")).strip_edges() == "enabled" and not _blocked(c, "wlan")


func _write_wifi(c, v) -> bool:
	if v:
		_unblock(c, "wlan")
	return _ok(_run(c, "nmcli", ["radio", "wifi", "on" if v else "off"]))


# --- Bluetooth -------------------------------------------------------------------------

## The radio to switch: the adapter that owns a paired device, else the lowest
## hciN. Outpox/Bluetooth (Decky, main.py _adapter_path_of) does the same: a
## dock or USB dongle can take hci0 while the radio holding the user's devices
## is hci1, and powering every adapter would be wrong for the same reason.
## One BlueZ GetManagedObjects per detect pass; read/write reuse the answer.
## Powered goes through BlueZ's Adapter1 like that plugin.
func _adapter(c) -> String:
	if c.has_meta("bt_adapter"):
		return str(c.get_meta("bt_adapter"))
	return _pick_adapter(c)


func _pick_adapter(c) -> String:
	var adapters: Array = []
	for n in _entries(_sys(c) + "/sys/class/bluetooth"):
		if str(n).begins_with("hci") and not ":" in str(n):
			adapters.append("/org/bluez/" + str(n))
	if adapters.is_empty():
		return ""
	adapters.sort()
	var objs: Variant = _sys_bus(c).call_method(BLUEZ, "/", "org.freedesktop.DBus.ObjectManager", "GetManagedObjects")
	var tree: Variant = objs[0] if objs is Array and not objs.is_empty() else null
	if tree is Dictionary:
		var paths: Array = tree.keys()
		paths.sort()
		for path in paths:
			var dev: Variant = tree[path].get("org.bluez.Device1") if tree[path] is Dictionary else null
			if not dev is Dictionary:
				continue
			var paired: Variant = dev.get("Paired")
			if paired is Dictionary:
				paired = paired.get("data")
			var owner := str(path).get_base_dir()
			if paired == true and owner in adapters:
				return owner
	return adapters[0]


func _sys_bus(c) -> RefCounted:
	return Busctl.new(c.ctx.runner, "--system")


func _user_bus(c) -> RefCounted:
	return Busctl.new(c.ctx.runner, "--user")


func _detect_bt(c) -> String:
	var path := _pick_adapter(c)
	c.set_meta("bt_adapter", path)
	if path == "":
		return T.NO_BT
	return "" if _sys_bus(c).get_prop(BLUEZ, path, BLUEZ_ADAPTER, "Powered") != null else T.NO_BLUEZ


func _read_bt(c) -> Variant:
	var v = _sys_bus(c).get_prop(BLUEZ, _adapter(c), BLUEZ_ADAPTER, "Powered")
	return null if v == null else bool(v)


func _write_bt(c, v) -> bool:
	var path := _adapter(c)
	if path == "":
		return false
	if v:
		_unblock(c, "bluetooth")
	return _sys_bus(c).set_prop(BLUEZ, path, BLUEZ_ADAPTER, "Powered", "b", "true" if v else "false")


# --- airplane mode ----------------------------------------------------------------------

func _detect_airplane(c) -> String:
	if rfkill_state(c).is_empty():
		return T.NO_RFKILL
	return ""


func _read_airplane(c) -> Variant:
	var st := rfkill_state(c)
	if st.is_empty():
		return null
	for r in st:
		if not (r["soft"] or r["hard"]):
			return false
	return true


func _write_airplane(c, v) -> bool:
	if v:
		# Remember what was on, so turning airplane mode off brings back just that.
		var wifi = _read_wifi(c) if _detect_wifi(c) == "" else null
		var bt = _read_bt(c) if _adapter(c) != "" else null
		_st(c).set_value("before_airplane", {"wifi": wifi != false, "bluetooth": bt != false})
		return _ok(_run(c, "rfkill", ["block", "all"]))
	var before: Dictionary = _st(c).get_value("before_airplane", {"wifi": true, "bluetooth": true})
	var ok := true
	if before.get("wifi", true):
		ok = _ok(_run(c, "rfkill", ["unblock", "wlan"])) and ok
		if _detect_wifi(c) == "":
			_run(c, "nmcli", ["radio", "wifi", "on"])
	if before.get("bluetooth", true):
		ok = _ok(_run(c, "rfkill", ["unblock", "bluetooth"])) and ok
		if _adapter(c) != "":
			_sys_bus(c).set_prop(BLUEZ, _adapter(c), BLUEZ_ADAPTER, "Powered", "b", "true")
	# Anything else (WWAN, NFC...) comes back too.
	for r in rfkill_state(c):
		if r["soft"] and not r["type"] in ["wlan", "bluetooth"]:
			_run(c, "rfkill", ["unblock", r["type"]])
	return ok


# --- Wi-Fi power saving -------------------------------------------------------------------

func _wifi_pm(c) -> int:
	var v = _user_bus(c).get_prop(SM_SERVICE, SM_PATH, SM_WIFI_PM, "WifiPowerManagementState")
	return -1 if v == null else int(v)


func _detect_wifi_pm(c) -> String:
	if _entries(_sys(c) + "/sys/class/ieee80211").is_empty():
		return T.NO_WIFI
	return "" if _wifi_pm(c) >= 0 else T.NO_STEAMOS_MANAGER


# --- sleep / screenshot / keep awake ----------------------------------------------------------

func _detect_sleep(c) -> String:
	var states := _read_text(_sys(c) + "/sys/power/state").split(" ")
	return "" if ("mem" in states or "freeze" in states) else T.NO_SLEEP


func _write_screenshot(c, _v) -> bool:
	var tmp := _sys(c) + SCREENSHOT_TMP
	# gamescope always writes the same file; clear the last one so a new file
	# (not a same-second mtime) tells us this shot is done.
	if FileAccess.file_exists(tmp):
		DirAccess.remove_absolute(tmp)
	if not _x(c).send_cardinal(A_SCREENSHOT, SCREENSHOT_TYPE):
		return false
	# gamescope writes the file on its next frame; a short bounded wait, once.
	var waited := 0
	while not (FileAccess.file_exists(tmp) and FileAccess.get_size(tmp) > 0) and waited < SCREENSHOT_WAIT_MS:
		OS.delay_msec(100)
		waited += 100
	if not FileAccess.file_exists(tmp):
		return false
	var dir := str(c.ctx.get("home", "")).path_join(SCREENSHOT_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	var stamp := Time.get_datetime_string_from_system().replace(":", "").replace("-", "").replace("T", "_")
	var dest := dir.path_join("GameCove_%s.png" % stamp)
	var n := 1
	while FileAccess.file_exists(dest):
		dest = dir.path_join("GameCove_%s_%d.png" % [stamp, n])
		n += 1
	if DirAccess.copy_absolute(tmp, dest) != OK:
		return false
	c.set_meta("last_path", dest)
	return true


func _inhibit_alive(c) -> bool:
	if _inhibit_pid <= 0:
		return false
	var runner = c.ctx.get("runner")
	if runner != null and runner.has_method("is_running"):
		return runner.is_running(_inhibit_pid)
	return OS.is_process_running(_inhibit_pid)


func _write_keep_awake(c, v) -> bool:
	var runner = c.ctx.get("runner")
	if not v:
		if _inhibit_pid > 0:
			if runner != null and runner.has_method("kill"):
				runner.kill(_inhibit_pid)
			else:
				OS.kill(_inhibit_pid)
		_inhibit_pid = 0
		return true
	if _inhibit_alive(c):
		return true
	# `tail --pid` ends the inhibitor with GameCove, so a crash never leaves the
	# handheld unable to sleep.
	var args := PackedStringArray(["--what=idle:sleep", "--who=GameCove", "--why=Keep awake is on", "--mode=block",
		"tail", "--pid=%d" % OS.get_process_id(), "-f", "/dev/null"])
	var pid := -1
	if runner != null and runner.has_method("spawn"):
		pid = runner.spawn("systemd-inhibit", args)
	else:
		pid = OS.create_process("systemd-inhibit", args)
	_inhibit_pid = maxi(pid, 0)
	return _inhibit_pid > 0
