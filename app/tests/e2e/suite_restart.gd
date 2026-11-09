extends "res://tests/e2e/e2e_case.gd"
## GameCove started again with saved state (run.py runs this suite twice on
## the same files: E2E_PHASE=1 changes settings with the pad and quits,
## E2E_PHASE=2 is the app starting again). After the restart the everyday and
## per-game profiles, the device settings (fan curve, battery saver, charge
## limit) and the hardware must be what the player left.

const Effects := preload("res://tests/e2e/effects.gd")
const Checks := preload("res://tests/e2e/checks.gd")
const STATE := "user://e2e_restart_expect.json"


func test_settings_survive_a_restart() -> void:
	if OS.get_environment("E2E_PHASE") == "2":
		await _after_restart()
	else:
		await _before_restart()


func _before_restart() -> void:
	var expect := {}
	ok(await open_menu_tab("power"), "Power tab")
	var v := view("power.tdp")
	ok(v != null and await focus_on(v), "TDP row")
	await left()
	await left()
	await w.wait_s(0.4)
	await w.idle()
	expect["power.tdp"] = ctl("power.tdp").value
	await b()
	for id in ["power.charge_limit", "power.battery_saver", "power.fan_curve", "display.vibrance"]:
		var c := ctl(id)
		if c == null or not c.available:
			continue
		var target: Variant
		match id:
			"power.charge_limit": target = 80.0 if float(c.value) != 80.0 else 85.0
			"power.battery_saver": target = true
			"power.fan_curve": target = (c.value as Array).map(func(x): return minf(float(x) + 10.0, c.max_value))
			"display.vibrance": target = 40.0
		qm().model.set_value(id, target)   # same path the rows take
		await w.idle()
		expect[id] = ctl(id).value
	# what everything is now (the battery saver moves the TDP too)
	for id in expect.keys():
		expect[id] = ctl(id).value
	profiles().set_layer(GAME_A["key"], "", {"display.fps_limit": 30})
	expect["game_fps"] = 30
	await w.idle()
	for id in expect:
		if id.contains("."):
			eq(Effects.check(self, id, expect[id]), "", "before quitting: %s on the system" % id)
	var f := FileAccess.open(STATE, FileAccess.WRITE)
	f.store_string(JSON.stringify(expect))
	f.close()


func _after_restart() -> void:
	var expect: Variant = JSON.parse_string(FileAccess.get_file_as_string(STATE))
	ok(expect is Dictionary and not expect.is_empty(), "phase 1 left what to expect")
	if not expect is Dictionary:
		return
	await w.idle()
	for id in expect:
		if not id.contains("."):
			continue
		var c := ctl(id)
		ok(c != null and c.available, "%s still there" % id)
		if c == null or not c.available:
			continue
		ok(Effects.same(c, c.value, expect[id]), "%s is %s after the restart (was %s)" % [id, c.value, expect[id]])
		eq(Effects.check(self, id, expect[id]), "", "%s on the hardware after the restart" % id)
	eq(int(profiles().layer(GAME_A["key"], "").get("display.fps_limit", -1)), int(expect["game_fps"]), "the game's profile kept")
	await start_game(GAME_A)
	eq(atom("GAMESCOPE_FPS_LIMIT"), str(int(expect["game_fps"])), "and applies at launch")
	await end_game()
	for p in Checks.now(w):
		ok(false, "after restart: " + p)
