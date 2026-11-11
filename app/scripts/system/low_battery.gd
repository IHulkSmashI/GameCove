extends Node
## "Sleep at low battery": on battery at or below the level the user picked (Power >
## Battery, power.low_battery_sleep / power.low_battery_sleep_at, off by default), asks for a
## 30 s warning (main.gd shows ui/low_battery_dialog.gd over whatever is in front); when
## nobody presses a button, the handheld sleeps (`systemctl suspend`, logind).
## Driven by Power's existing 15 s check (its battery_level and source_changed signals): no
## timer that keeps running (the one exception is the one-shot re-read below). Pressing a button (or waking it up again) holds the warning off until the
## level drops REWARN_DROP more, the charger goes in or the level climbs back above the line,
## so it doesn't nag at every percent.
##
## Two things it doesn't take at face value (final review, low):
##  - one odd reading. A fuel gauge can say 0 for a moment (after a wake, when the embedded
##    controller is busy), and a countdown to sleep in the middle of a game for that is wrong.
##    A battery runs down a percent or two between checks, so a reading that lands at the line
##    from more than STEP_MAX above it (or with no reading before it) is read again from the
##    battery CONFIRM_S later and only counts when it's still there. That re-read is the one
##    timer here: one shot, and only then. A second low report in a row counts at once.
##  - "not plugged in" from the charger list alone. Some chargers aren't exposed as Mains or
##    USB; if the battery itself says it is charging, the handheld is on the charger (believed
##    at the warning and again before the sleep).

signal warn_requested(percent: int)
## The charger went in while the warning showed: close it.
signal warn_cancelled
## About to sleep (battery history records it first).
signal sleeping

## Percent the battery must drop after a cancel (or a wake) before the warning comes back.
const REWARN_DROP := 2
## The most a battery falls between two of Power's checks; a bigger fall to the line is looked at again.
const STEP_MAX := 2

const DeviceScript := preload("res://scripts/device/device.gd")
const BatteryLog := preload("res://scripts/system/battery_log.gd")

## func() -> {"on": bool, "at": int} (the two controls; tests swap it).
var settings: Callable = func() -> Dictionary: return {"on": false, "at": 5}
## func() -> bool: on the charger now.
var plugged_now: Callable = func() -> bool: return false
## func() -> bool: the battery says it is charging (whatever the charger list says).
var charging_now: Callable = func() -> bool: return false
## func() -> int: the battery's percent read now (-1 unknown). Tests swap it.
var level_now: Callable = func() -> int: return -1
## Seconds before an out-of-nowhere low reading is read again.
var confirm_s := 5.0
## func() -> void: puts the handheld to sleep (tests swap it).
## Started and left (OS.create_process passes argv untouched): no worker task that
## the app's exit would have to wait for.
var suspend: Callable = func() -> void:
	OS.create_process("systemctl", PackedStringArray(["suspend"]))

var warning := false
var suppressed := false
var _pct := -1
var _held_at := -1   # the level when the warning was held off
var _unconfirmed := false   # a low reading that came out of nowhere waits to be read again
var _doubt := 0   # which such reading the re-read belongs to


## Power: its level and charger events; controls: the registry the two settings live in.
func setup(power: Object, controls: Object) -> void:
	if controls != null and controls.has_method("value"):
		settings = func() -> Dictionary:
			var on: Variant = controls.value("power.low_battery_sleep")
			var at: Variant = controls.value("power.low_battery_sleep_at")
			return {"on": on == true, "at": int(at) if at != null else 5}
	if power == null:
		return
	if power.has_method("battery_charging"):
		charging_now = func() -> bool: return bool(power.battery_charging())
	if "sys_root" in power:
		# the root is asked for at each read (tests point Power at another tree later)
		level_now = func() -> int: return read_level(str(power.sys_root))
	if "plugged" in power:
		plugged_now = func() -> bool: return bool(power.plugged) or bool(charging_now.call())
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


## A low reading that needs a second look before it counts (see the top of the file).
static func sudden(prev: int, pct: int, at: int) -> bool:
	return pct >= 0 and pct <= clampi(at, 3, 10) and (prev < 0 or prev - pct > STEP_MAX)


func on_level(pct: int, plugged: bool) -> void:
	var prev := _pct
	_pct = pct
	var s: Dictionary = settings.call()
	if pct > int(s.get("at", 5)) or (suppressed and _held_at >= 0 and pct <= _held_at - REWARN_DROP):
		suppressed = false
	if sudden(prev, pct, int(s.get("at", 5))):
		# at the line out of nowhere: not believed until it's read again
		_unconfirmed = true
		_doubt += 1
		if is_inside_tree():
			get_tree().create_timer(confirm_s).timeout.connect(confirm_reading.bind(_doubt))
		return
	_unconfirmed = false   # a step down from the last reading (or back up): nothing to doubt
	_check(plugged or bool(charging_now.call()))


## The second look at a low reading that came out of nowhere. Still at the line: it counts.
## Back up: it was a glitch and nothing happens. `doubt`: which reading this look belongs to
## (a newer one has its own).
func confirm_reading(doubt := -1) -> void:
	if not _unconfirmed or (doubt >= 0 and doubt != _doubt):
		return
	_unconfirmed = false
	var fresh: int = int(level_now.call())
	if fresh < 0:
		return   # the battery can't be read now: Power's next report decides
	_pct = fresh
	_check(bool(plugged_now.call()))


func on_source(plugged: bool) -> void:
	if plugged:
		suppressed = false
		_unconfirmed = false
		if warning:
			warning = false
			warn_cancelled.emit()
		return
	_check(bool(charging_now.call()))


func _check(plugged: bool) -> void:
	if _unconfirmed:
		return
	var s: Dictionary = settings.call()
	if should_warn(_pct, plugged, bool(s.get("on", false)), int(s.get("at", 5)), suppressed, warning):
		warning = true
		warn_requested.emit(_pct)


## A button was pressed during the warning: stay awake.
func cancel() -> void:
	warning = false
	suppressed = true
	_held_at = _pct


## The warning ran out: sleep, unless the charger came in meanwhile.
func confirm() -> void:
	warning = false
	if plugged_now.call():
		return
	suppressed = true   # after the wake, the same low level shouldn't put it straight back to sleep
	_held_at = _pct
	sleeping.emit()
	suspend.call()
