extends "res://tests/test_case.gd"
## Installer state machine: Easy defaults, Custom paths, skip, summary edits,
## maintenance, and resuming after a reboot from the pending-choices file.

const Plan := preload("res://scripts/installer/plan.gd")
const F := preload("res://tests/fixtures/installer/fakes.gd")


func _plan(t := {}, row := {}) -> RefCounted:
	var target: Dictionary = F.target("bazzite") if t.is_empty() else t
	var r: Dictionary = F.claw().profile if row.is_empty() else row
	return Plan.start(target, r, {"theme": "cove", "match_art": true, "reduce_motion": false})


func test_easy_defaults_and_path() -> void:
	var p := _plan()
	eq(p.mode, "easy")
	eq(p.step, "welcome")
	eq(p.choices["startup"], "gamecove", "supported system boots into GameCove")
	eq(p.choices["steam_mode"], "silent")
	eq(p.choices["steam_control"], false, "Steam control is opt-in")
	eq(p.choices["fixes"], ["claw8ex-buttons", "claw8ex-vrr", "claw8ex-gyro", "claw-kbd-wakeup"], "all suggested fixes")
	eq(p.choices["auto_tdp"], true)
	eq(p.choices["power_profile"], "balanced")
	eq(p.choices["charge_limit"], 100, "no charge limit by default")
	eq(p.steps(), ["welcome", "stores", "art", "summary", "progress", "done"], "store sign-in and Game art show in Easy mode too")
	eq(p.choices["steamgriddb_key"], "", "no key until the user adds theirs")
	eq(p.next(), "stores", "Easy offers store sign-in right after the welcome page")
	ok(p.can_skip(), "the store step can be skipped")
	ok(p.skip(), "skipped with one press")
	eq(p.step, "art")
	eq(p.summary()[2], {"step": "stores", "key": "stores", "value": "skipped"}, "the summary says stores were skipped")
	ok(p.can_skip(), "Game art can be skipped (Steam art only)")
	ok(p.skip(), "skipped")
	eq(p.step, "summary")
	eq(p.summary()[5], {"step": "art", "key": "steamgriddb_key", "value": "skipped"}, "summary says so")
	eq(p.action(), "install")
	eq(p.next(), "progress")
	p.ran = true
	eq(p.next(), "done")
	eq(p.back(), "done", "no way back after the run")


func test_unsupported_system_defaults_to_desktop() -> void:
	var p := _plan(F.target("other"))
	eq(p.choices["startup"], "desktop")


func test_custom_path_back_and_skip() -> void:
	var p := _plan()
	eq(p.set_mode("custom"), "welcome")
	var seen: Array = []
	while p.step != "summary":
		seen.append(p.next())
	eq(seen, ["startup", "steam", "stores", "device", "look", "art", "extras", "summary"])
	eq(p.back(), "extras")
	eq(p.back(), "art")
	eq(p.back(), "look")
	p.step = "startup"
	ok(not p.can_skip(), "startup can't be skipped")
	ok(not p.skip(), "skip refused")
	p.step = "device"
	ok(p.skip(), "device skippable")
	eq(p.step, "look", "skip moves on")
	eq(p.choices["fixes"], [], "skipped device installs no fixes")
	ok(p.skipped.has("device"))
	p.step = "stores"
	ok(p.skip())
	eq(p.summary()[2]["value"], "skipped")


func test_summary_edit_returns() -> void:
	var p := _plan()
	p.next()
	p.next()
	p.next()
	eq(p.step, "summary")
	ok(p.edit("steam"), "edit a step from the summary")
	eq(p.step, "steam")
	ok(p.set_choice("steam_mode", "off"))
	eq(p.next(), "summary", "Next goes back to the summary")
	ok(p.edit("look"))
	eq(p.back(), "summary", "so does Back")
	ok(not p.edit("progress"), "only option steps")
	eq(p.summary().map(func(x): return x["step"]), ["startup", "steam", "stores", "device", "look", "art", "extras"])
	ok(p.edit("art") and p.set_choice("steamgriddb_key", "0123456789abcdef0123456789abcdef"), "a key from the Game art step")
	eq(p.summary()[5]["value"], "set", "summary shows it")


func test_choice_validation() -> void:
	var p := _plan()
	ok(not p.set_choice("startup", "windows"))
	ok(not p.set_choice("steam_mode", "loud"))
	ok(not p.set_choice("charge_limit", 30))
	ok(not p.set_choice("charge_limit", "80"))
	ok(p.set_choice("charge_limit", 80.0))
	eq(p.choices["charge_limit"], 80)
	ok(not p.set_choice("theme", "neon"))
	ok(p.set_choice("theme", "midnight"))
	ok(not p.set_choice("auto_tdp", "yes"))
	ok(not p.set_choice("nope", 1))
	ok(p.set_choice("fixes", ["claw8ex-vrr", "../../etc", "other-fix"]))
	eq(p.choices["fixes"], ["claw8ex-vrr"], "only this device's fixes")
	p.toggle_fix("claw8ex-gyro", true)
	p.toggle_fix("claw8ex-vrr", false)
	p.toggle_fix("made-up", true)
	eq(p.choices["fixes"], ["claw8ex-gyro"])
	ok(p.set_choice("steam_id", "  kira  "))
	eq(p.choices["steam_id"], "kira")


func test_maintenance_modes() -> void:
	var t := F.target("bazzite", {"installed": true, "maintenance": true,
		"state": {"version": "0.2.0", "choices": {"startup": "steam", "steam_mode": "gamepadui", "fixes": ["claw8ex-vrr"]}}})
	var p := _plan(t)
	eq(p.mode, "maintenance")
	eq(p.step, "maintenance")
	eq(p.choices["startup"], "steam", "saved choices come back")
	eq(p.choices["steam_mode"], "gamepadui")
	eq(p.choices["fixes"], ["claw8ex-vrr"])
	p.set_mode("change")
	eq(p.next(), "startup")
	eq(p.action(), "change")
	p.set_mode("uninstall")
	p.step = "maintenance"
	eq(p.next(), "uninstall")
	eq(p.action(), "uninstall")
	eq(p.choices["keep_settings"], true)
	p.set_mode("repair")
	p.step = "maintenance"
	eq(p.next(), "progress")
	eq(p.action(), "repair")


func test_resume_after_reboot_from_pending_file() -> void:
	# Before the reboot the package was only staged: fixes waited in the pending file.
	var staged := F.target("bazzite", {"staged": true, "maintenance": true, "pending": {"FIXES": "claw8ex-vrr,claw8ex-gyro"},
		"state": {"stage": "staged"}})
	eq(_plan(staged).mode, "maintenance", "not live yet: nothing to finish")
	# After the reboot the package is live: finish the fixes.
	var live := F.target("bazzite", {"installed": true, "maintenance": true, "pending": {"FIXES": "claw8ex-vrr,claw8ex-gyro,evil"},
		"state": {"stage": "staged"}})
	var p := _plan(live)
	eq(p.mode, "finish")
	eq(p.step, "finish")
	eq(p.choices["fixes"], ["claw8ex-vrr", "claw8ex-gyro"], "only known fixes resume")
	eq(p.steps(), ["finish", "progress", "done"])
	eq(p.action(), "finish")
	eq(p.next(), "progress")
