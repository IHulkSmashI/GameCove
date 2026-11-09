extends "res://tests/e2e/e2e_case.gd"
## Profiles end to end: a game's own settings on launch and back on exit,
## battery / plugged-in layers with the TDP clamped to what each source allows,
## game + source precedence, "Use settings for this game", a game without a
## profile, and edits while the game runs. Checked on the system (firmware
## attribute / RAPL TDP, gamescope's frame limit atom), not in Controls.

const Effects := preload("res://tests/e2e/effects.gd")
const Checks := preload("res://tests/e2e/checks.gd")


func tdp_range() -> Dictionary:
	return w.row.get("tdp", {})


func w_(n: float) -> int:
	return int(tdp_range().get("min", 5)) + int(n)


## The TDP the hardware has now (via whichever backend Power uses).
func system_tdp() -> float:
	var power_: Node = power()
	if power_.backend == "powerstation" and FileAccess.file_exists(w.root + "/sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw"):
		return w.read("/sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw").to_float() / 1e6
	if power_.backend == "steamos-manager":
		return Effects._fw_attr(w, "ppt_pl1_spl").to_float()
	var v: Variant = w.fake.prop("org.shadowblip.PowerStation", "/org/shadowblip/Performance/GPU/card1", "org.shadowblip.GPU.Card.TDP", "TDP")
	return float(v) if v != null else -1.0


func fps_atom() -> int:
	return atom("GAMESCOPE_FPS_LIMIT").to_int()


func _layer(game: String, src: String, values: Dictionary) -> void:
	profiles().set_layer(game, src, values)
	await w.idle()


func _no_problems(step: String) -> void:
	for p in Checks.now(w):
		ok(false, "%s: %s" % [step, p])


func test_game_profile_on_launch_and_back_on_exit() -> void:
	await _layer("", "", {"power.tdp": w_(6), "display.fps_limit": 0})
	eq(system_tdp(), float(w_(6)), "everyday TDP on the hardware")
	await _layer(GAME_A["key"], "", {"power.tdp": w_(3), "display.fps_limit": 30})
	await start_game(GAME_A)
	eq(system_tdp(), float(w_(3)), "the game's TDP once it starts")
	eq(fps_atom(), 30, "the game's frame limit in gamescope")
	_no_problems("in game")
	await end_game()
	eq(system_tdp(), float(w_(6)), "everyday TDP back when it quits")
	eq(fps_atom(), 0, "frame limit off again")
	_no_problems("after the game")


func test_battery_and_charger_layers_clamp_to_each_source() -> void:
	var t := tdp_range()
	var bat_max := float(t.get("battery_max", 0))
	var ac_max := float(t.get("plugged_max", bat_max))
	# the everyday value is the plugged-in ceiling: on battery it can only be the battery one
	await _layer("", "", {"power.tdp": ac_max})
	ok(system_tdp() <= bat_max + 0.01, "on battery the TDP stays within %s W (it is %s)" % [bat_max, system_tdp()])
	w.set_ac(true)
	await w.idle()
	await w.idle()
	eq(system_tdp(), ac_max, "plugged in: the saved %s W applies (range grew)" % ac_max)
	w.set_ac(false)
	await w.idle()
	await w.idle()
	ok(system_tdp() <= bat_max + 0.01, "unplugged: back within %s W at once (it is %s)" % [bat_max, system_tdp()])
	_no_problems("after unplugging")


func test_game_and_source_precedence() -> void:
	await _layer("", "", {"power.tdp": w_(1)})
	await _layer("", "ac", {"power.tdp": w_(8)})
	await _layer(GAME_A["key"], "", {"power.tdp": w_(3)})
	await _layer(GAME_A["key"], "ac", {"power.tdp": w_(5)})
	await start_game(GAME_A)
	eq(system_tdp(), float(w_(3)), "battery, in the game: the game's layer")
	w.set_ac(true)
	await w.idle()
	await w.idle()
	eq(system_tdp(), float(w_(5)), "plugged in, in the game: game + plugged in")
	await end_game()
	eq(system_tdp(), float(w_(8)), "plugged in, no game: the plugged-in layer")
	w.set_ac(false)
	await w.idle()
	await w.idle()
	eq(system_tdp(), float(w_(1)), "battery, no game: everyday")


## "Use settings for this game" with the pad saves what runs now; a TDP change
## in the This game tab then goes into the game's profile and comes back next time.
func test_use_settings_for_this_game_and_edit_mid_game() -> void:
	await _layer("", "", {"power.tdp": w_(6), "display.fps_limit": 0})
	await start_game(GAME_A)
	ok(await open_menu_tab("game"), "This game tab")
	eq(qm().head_title.text, GAME_A["title"], "the menu names the game")
	var use: Node = qm().body.get_node("UseGame")
	ok(await focus_on(use), "Use settings for this game reachable")
	await right()
	await w.idle()
	ok(profiles().has_profile(GAME_A["key"]), "the game has its own settings now")
	var v := view("display.fps_limit")
	ok(v != null and await focus_on(v), "frame limit in This game")
	await right()
	await w.idle()
	var fps := int(ctl("display.fps_limit").value)
	ok(fps > 0, "frame limit moved (%s)" % fps)
	eq(fps_atom(), fps, "gamescope has it")
	eq(int(profiles().layer(GAME_A["key"], "").get("display.fps_limit", -1)), fps, "saved in the game's profile")
	eq(int(profiles().layer("", "").get("display.fps_limit", 0)), 0, "everyday untouched")
	await b()
	await end_game()
	eq(fps_atom(), 0, "everyday frame limit back after the game")
	await start_game(GAME_A)
	eq(fps_atom(), fps, "and the game's comes back next launch")
	await end_game()


## A game with no profile: nothing changes at launch; a change made while it
## runs is an everyday change and stays after it.
func test_game_without_a_profile() -> void:
	await _layer("", "", {"power.tdp": w_(6)})
	await start_game(GAME_C)
	eq(system_tdp(), float(w_(6)), "no profile: everyday TDP stays")
	ok(await open_menu_tab("power"), "Power tab")
	var v := view("power.tdp")
	ok(v != null and await focus_on(v), "TDP row")
	await right()
	await w.wait_s(0.4)
	await w.idle()
	var now := float(ctl("power.tdp").value)
	eq(system_tdp(), now, "the hardware follows")
	eq(float(profiles().layer("", "").get("power.tdp", -1)), now, "saved as everyday")
	ok(not profiles().has_profile(GAME_C["key"]), "the game got no profile of its own")
	await b()
	await end_game()
	eq(system_tdp(), now, "stays after the game")
