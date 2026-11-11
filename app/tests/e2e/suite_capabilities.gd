extends "res://tests/e2e/e2e_case.gd"
## What each setup must offer, and the reason it gives where it can't
## (checked against what its stack really has; sources in gen.py SETUPS).
## "range": [min, max] on battery. A string is a part of the reason.

const EXPECT := {
	"claw8ex-bazzite": {
		"power.tdp": [8.0, 35.0], "power.boost": true, "power.cpu_cores": true, "power.power_mode": true,
		"power.charge_limit": true, "power.fan_mode": true, "power.fan_curve": true, "power.gpu_min": true,
		"power.gpu_profile": true, "perf.overlay": true, "controller.gyro": "gyro fix",
		"power.sppt": "firmware ignores", "power.smt": "no SMT", "power.platform_profile": "Set by Power mode",
		"power.gpu_level": "AMD", "power.sleep_mode": "only one sleep mode", "controller.trackpad": "no trackpad",
		"display.hdr": "doesn't support HDR", "controller.led_effect": true,
	},
	"ally-steamos": {
		"power.tdp": [7.0, 25.0], "power.sppt": true, "power.fppt": true, "power.platform_profile": true,
		"power.charge_limit": true, "power.fan_curve": true, "power.gpu_level": true, "power.gpu_min": true,
		"controller.gyro": true, "controller.led_effect": true, "display.refresh_rate": true,
		# SteamOS: no PowerStation or power-profiles-daemon; the helper's admin verbs need Desktop Mode
		"power.boost": "Not available", "power.power_mode": "No power-profiles-daemon",
		"power.smt": "sleep can break", "power.cpu_cores": "Desktop Mode", "power.mcu_powersave": "Desktop Mode",
		"power.sleep_mode": "Desktop Mode", "controller.trackpad": "no trackpad",
	},
	"legion-go-s-bazzite": {
		"power.tdp": [5.0, 30.0], "power.sppt": true, "power.power_mode": true, "power.smt": true,
		"power.cpu_cores": true, "power.battery_long_life": true, "power.gpu_level": true,
		"controller.gyro": true, "controller.trackpad": true, "display.refresh_rate": true,
		"power.charge_limit": "no charge limit", "power.fan_mode": "No fan control", "power.platform_profile": "Set by Power mode",
		"power.sleep_mode": "Desktop Mode", "controller.led_effect": "No RGB driver",
	},
}


## The Steam Machine: nothing a battery or a handheld's power limit needs, and
## each of those says why; HDMI-CEC from steamos-manager.
const EXPECT_BOX := {
	"power.tdp": "runs from the wall", "power.battery_saver": "No battery", "power.low_battery_sleep": "No battery",
	"power.battery_saver_at": "No battery", "display.brightness": "no brightness", "display.hdmi_cec": true, "perf.overlay": true,
}


func test_offers_what_this_setup_has_and_says_why_not() -> void:
	var want: Dictionary = EXPECT.get(setup_name(), EXPECT_BOX if bool(w.info.get("boxed", false)) else {})
	ok(not want.is_empty(), "expectations for %s" % setup_name())
	for id in want:
		var c := ctl(id)
		ok(c != null, "%s registered" % id)
		if c == null:
			continue
		var e: Variant = want[id]
		if e is String:
			ok(not c.available and e in c.reason, "%s: unavailable because \"%s\" (it says: %s)" % [id, e, c.reason if not c.available else "available"])
		else:
			ok(c.available, "%s available (%s)" % [id, c.reason])
			if e is Array:
				eq([c.min_value, c.max_value], e, "%s range on battery" % id)
