extends Node
## "Sleep at low battery": on battery at or below the level the user picked (Power >
## Battery, power.low_battery_sleep / power.low_battery_sleep_at, off by default), asks for a
## 30 s warning (main.gd shows ui/low_battery_dialog.gd over whatever is in front); when
## nobody presses a button, the handheld sleeps (`systemctl suspend`, logind).
## Driven by Power's existing 15 s check (its battery_level and source_changed signals): no
## timer of its own. Pressing a button (or waking it up again) holds the warning off until the
## level drops REWARN_DROP more, the charger goes in or the level climbs back above the line,
## so it doesn't nag at every percent.
##
## Two things must never start the countdown (final review):
##   - One odd reading. A fuel gauge can say 0 for a moment (after a wake, when the
##     embedded controller is busy). A battery runs down a percent or two between checks,
##     so a reading that lands at the line from further up than STEP_MAX (or with no
##     reading before it) is read again from the battery CONFIRM_S later, and only counts
##     when it's still there. That re-read is the one timer here: one shot, and only then.
##   - A charger the kernel doesn't list as Mains or USB (Power's `plugged` is false for
##     it). The battery itself says "Charging" or "Full" then, and that's believed.

signal warn_requested(percent: int)
## The charger went in while the warning showed: close it.
signal warn_cancelled
## About to sleep (battery history records it first).
signal sleeping

## Percent the battery must drop after a cancel (or a wake) before the warning comes back.
const REWARN_DROP := 2
## The most a battery falls between two of Power's checks; a bigger fall to the line is checked again.
const STEP_MAX := 2
## What the battery says about itself when it's on external power, whatever the charger is listed as.
const POWERED := ["Charging", "Full"]

const DeviceScript := preload("res://scripts/device/device.gd")
const BatteryLog := preload("res://scripts/system/battery_log.gd")

## func() -> {"on": bool, "at": int} (the two controls; tests swap it).
var settings: Callable = func() -> Dictionary: return {"on": false, "at": 5}
## func() -> bool: on the charger now.
var plugged_now: Callable = func() -> bool: return false
## func() -> void: puts the handheld to sleep (tests swap it).
## Started and left (OS.create_process passes argv untouched): no worker task that
## the app's exit would have to wait for.
var suspend: Callable = func() -> void:
	OS.create_process("systemctl", PackedStringArray(["suspend"]))

## func() -> int: the battery's percent read now (-1 unknown). Tests swap it.
var level_now: Callable = Callable()
## func() -> String: the battery's own status ("Charging", "Discharging", "Full", ...; "" unknown).
var battery_status: Callable = func() -> String: return ""
## Seconds before an out-of-nowhere low reading is read again.
var confirm_s := 5.0

var warning := false
var suppressed := false
var _pct := -1
var _held_at := -1   # the level when the warning was held off
## A low reading waits to be read again (confirm_reading()).
var _unconfirmed := false
var _doubt := 0


## Power: its level and charger events; controls: the registry the two settings live in.
func setup(power: Object, controls: Object) -> void:
	if controls != null and controls.has_method("value"):
		settings = func() -> Dictionary:
			var on: Variant = controls.value("power.low_battery_sleep")
			var at: Variant = controls.value("power.low_battery_sleep_at")
			return {"on": on == true, "at": int(at) if at != null else 5}
	if power == null:
		return
	if "plugged" in power:
		plugged_now = func() -> bool: return bool(power.plugged)
	if "sys_root" in power:
		# the root is asked for at each read (tests point Power at another tree later)
		level_now = func() -> int: return read_level(str(power.sys_root))
		battery_status = func() -> String: return read_status(str(power.sys_root))
	if power.has_signal("battery_level"):
		power.battery_level.connect(on_level)
	if power.has_signal("source_changed"):
		power.source_changed.connect(on_source)
	if power.has_method("battery_percent"):
		_pct = int(power.battery_percent())


static func should_warn(pct: int, plugged: bool, on: bool, at: int, held_off: bool, showing: bool) -> bool:
	return on and not plugged and pct >= 0 and pct <= clampi(at, 3, 10) and not held_off and not showing


## The battery's percent, straight from sysfs (one small read; -1 when there's none).
static func read_level(root: String) -> int:
	var bat := BatteryLog.battery_dir(root)
	var c := DeviceScript.read_text(bat + "capacity") if bat != "" else ""
	return c.to_int() if c.is_valid_int() else -1


## The battery's status line ("" when there's none).
static func read_status(root: String) -> String:
	var bat := BatteryLog.battery_dir(root)
	return DeviceScript.read_text(bat + "status").strip_edges() if bat != "" else ""


func on_level(pct: int, plugged: bool) -> void:
	var before := _pct
	_pct = pct
	var s: Dictionary = settings.call()
	if pct > int(s.get("at", 5)) or (suppressed and _held_at >= 0 and pct <= _held_at - REWARN_DROP):
		suppressed = false
	var line := clampi(int(s.get("at", 5)), 3, 10)
	if pct >= 0 and pct <= line and (before < 0 or before - pct > STEP_MAX):
		# at the line out of nowhere: not believed until it's read again
		_unconfirmed = true
		_doubt += 1
		if is_inside_tree():
			get_tree().create_timer(confirm_s).timeout.connect(confirm_reading.bind(_doubt))
		return
	_unconfirmed = false   # a step down from the last reading (or back up): nothing to doubt
	_check(plugged)


## The second look at a low reading that came out of nowhere. Still at the line:
## it counts. Back up: it was a glitch, and nothing happens. `doubt`: which reading
## this look belongs to (a newer one has its own).
func confirm_reading(doubt := -1) -> void:
	if not _unconfirmed or (doubt >= 0 and doubt != _doubt):
		return
	_unconfirmed = false
	var fresh: int = int(level_now.call()) if level_now.is_valid() else -1
	if fresh < 0:
		return   # the battery can't be read now: Power's next report decides
	_pct = fresh
	_check(bool(plugged_now.call()))


func on_source(plugged: bool) -> void:
	if plugged:
		suppressed = false
		if warning:
			warning = false
			warn_cancelled.emit()
		return
	_check(false)


func _check(plugged: bool) -> void:
	if _unconfirmed:
		return
	var s: Dictionary = settings.call()
	if should_warn(_pct, plugged, bool(s.get("on", false)), int(s.get("at", 5)), suppressed, warning):
		if on_external_power():
			return   # a charger the kernel doesn't list as one: the battery says it's charging
		warning = true
		warn_requested.emit(_pct)


## The battery itself says it's on external power (asked only when a warning or the sleep is about to happen).
func on_external_power() -> bool:
	return str(battery_status.call()) in POWERED


## A button was pressed during the warning: stay awake.
func cancel() -> void:
	warning = false
	suppressed = true
	_held_at = _pct


## The warning ran out: sleep, unless the charger came in meanwhile.
func confirm() -> void:
	warning = false
	if plugged_now.call() or on_external_power():
		return
	suppressed = true   # after the wake, the same low level shouldn't put it straight back to sleep
	_held_at = _pct
	sleeping.emit()
	suspend.call()
