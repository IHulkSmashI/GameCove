extends "res://tests/e2e/e2e_case.gd"
## Robustness: random pad bursts (seeded, E2E_ITERS times, seeds printed),
## closing the menu while a slow write is out, the charger flapping, a
## suspend / resume that resets the firmware, writes that fail (polkit says no,
## read-only sysfs, a D-Bus service timing out), the Controls worker racing
## itself, and the main thread never waiting while commands are slow. After
## each: no engine or script errors (the runner), the safety invariants, and
## every control with a known effect matching the system.

const Effects := preload("res://tests/e2e/effects.gd")
const Checks := preload("res://tests/e2e/checks.gd")


func iters() -> int:
	return maxi(1, OS.get_environment("E2E_ITERS").to_int())


func seed0() -> int:
	var s := OS.get_environment("E2E_SEED").to_int()
	return s if s != 0 else 1


## Every available control with a checked effect agrees with the system.
func consistent(step: String) -> void:
	for c in controls().list():
		if not c.available or c.value == null:
			continue
		var e := Effects.check(self, c.id, c.value)
		ok(e == "", "%s: %s is %s in GameCove but %s" % [step, c.id, c.value, e])
		if e != "" and OS.get_environment("E2E_DEBUG") != "":
			for r in helper_runs():
				print("  helper ", r)
			for x in w.fake.log_copy().slice(-40):
				print("  log ", x["argv"])
	for p in Checks.now(w):
		ok(false, "%s: %s" % [step, p])


## The InputPlumber intercept comes back (a Desktop / Steam switch in a burst
## releases it, as it should).
func _rearm() -> void:
	var c: Node = w.autoload("Controller")
	if not c.intercept_state()["active"]:
		c.setup_intercept_for_tests()
		c.monitor_line({"kind": "started"})


func test_random_pad_bursts() -> void:
	var moves := ["qam", "b", "lb", "rb", "up", "down", "left", "right", "a", "up", "down", "left", "right", "guide"]
	for i in iters():
		var seed := seed0() * 1000 + i
		print("E2E SEED suite_robustness::test_random_pad_bursts %d" % seed)
		var rng := RandomNumberGenerator.new()
		rng.seed = seed
		for k in 60:
			match moves[rng.randi() % moves.size()]:
				"qam": await qam()
				"guide": await guide()
				"b": await b()
				"lb": await lb()
				"rb": await rb()
				"up": await up()
				"down": await down()
				"left": await left()
				"right": await right()
				"a": await a()
		await w.wait_s(0.4)   # sliders settle
		await w.idle()
		consistent("burst seed %d" % seed)
		_rearm()
		if qm().visible:
			qm().close()
		main().show_screen("home")
		await w.idle()


func test_closing_the_menu_while_a_write_is_out() -> void:
	w.fake.faults["latency_ms"] = 300
	ok(await open_menu_tab("power"), "Power tab")
	var v := view("power.tdp")
	ok(v != null and await focus_on(v), "TDP row")
	await right()
	await w.wait_s(0.35)
	await b()              # closed while the worker is still writing
	await qam()            # and open again at once
	await rb()
	await w.idle(20000)
	w.fake.faults.erase("latency_ms")
	await w.idle()
	consistent("after closing mid-apply")
	var again := view("power.tdp")
	if again != null and qm().visible:
		eq(qm().model.value("power.tdp"), ctl("power.tdp").value, "the menu shows what the hardware has")
	await b()


func test_charger_flapping() -> void:
	var t: Dictionary = w.row.get("tdp", {})
	var bat_max := float(t.get("battery_max", 0))
	var ac_max := float(t.get("plugged_max", bat_max))
	profiles().set_layer("", "", {"power.tdp": ac_max})
	await w.idle()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed0()
	var on := false
	for k in 12:
		on = not on if rng.randf() < 0.8 else on
		w.set_ac(on)
		await w.frames(rng.randi_range(0, 3))
	await w.idle()
	await w.idle()
	var tdp := float(ctl("power.tdp").value)
	if OS.get_environment("E2E_DEBUG") != "":
		print("  FLAP saver=", ctl("power.battery_saver").value, " profile=", ctl("power.profile").value, " autotune=", power().autotune_active(), " layer=", profiles().layer("", ""), " ac=", profiles().layer("", "ac"))
	ok(tdp <= (ac_max if on else bat_max) + 0.01, "after flapping (plugged %s) the TDP %s is within the source's limit" % [on, tdp])
	eq(tdp, ac_max if on else bat_max, "and it is the saved value clamped to that source")
	if OS.get_environment("E2E_DEBUG") != "" and tdp != (ac_max if on else bat_max):
		for x in w.fake.log_copy():
			var s := " ".join(PackedStringArray(x["argv"].map(func(y): return str(y))))
			if "TdpLimit " in s or "TDP " in s:
				print("  ", x["t_ms"], " ", s.get_slice("SteamOSManager1.", 2).get_slice("PowerStation", 0))
	consistent("after flapping")


func test_suspend_resume_puts_settings_back() -> void:
	profiles().set_layer("", "", {"power.tdp": int(w.row["tdp"]["min"]) + 4})
	await w.idle()
	if available("power.epp"):
		controls().set_value("power.epp", "balance_power")
	await w.idle()
	var tdp: float = ctl("power.tdp").value
	# the firmware resets limits over sleep (ClawDeck, LeGo2BrightnessFix notes)
	for fw in DirAccess.get_directories_at(w.root + "/sys/class/firmware-attributes"):
		var a := "/sys/class/firmware-attributes/%s/attributes/ppt_pl1_spl/" % fw
		if FileAccess.file_exists(w.root + a + "default_value"):
			w.write(a + "current_value", w.read(a + "default_value"))
	if FileAccess.file_exists(w.root + "/sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw"):
		w.write("/sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw", str(int(w.row["tdp"]["battery_max"]) * 1000000))
	for d in DirAccess.get_directories_at(w.root + "/sys/devices/system/cpu"):
		var f := "/sys/devices/system/cpu/%s/cpufreq/energy_performance_preference" % d
		if FileAccess.file_exists(w.root + f):
			w.write(f, "balance_performance")
	# the clocks say we slept: wall time moved 2 minutes, the monotonic one 1 s
	main()._clock_mark = [Time.get_unix_time_from_system() - 120.0, Time.get_ticks_msec() - 1000]
	main()._check_resume()
	await w.wait_s(5.6)    # the controller lights come 5 s later
	await w.idle()
	eq(Effects.check(self, "power.tdp", tdp), "", "TDP put back after resume")
	if available("power.epp"):
		eq(Effects.check(self, "power.epp", "balance_power"), "", "EPP put back after resume")
	consistent("after resume")


func test_failing_writes_keep_the_value_and_say_so() -> void:
	# polkit refuses the root helper
	if available("power.epp"):
		w.fake.faults["helper"] = "deny"
		var before: Variant = ctl("power.epp").value
		var cpu0: String = w.read("/sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference")
		ok(await open_settings_page("power"), "Power page")
		var v := view("power.epp", main().settings)
		ok(v != null and await focus_on(v), "EPP row")
		await change()
		await w.idle()
		ok(v.model.is_failed("power.epp"), "the change is marked failed")
		eq(ctl("power.epp").value, before, "the control keeps the old value")
		eq(w.read("/sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference"), cpu0, "the CPU too")
		ok(v.status_label.visible and v.status_label.text != "", "a line says it didn't work")
		w.fake.faults.erase("helper")
		await b()
	# read-only sysfs: the backlight can't be written either way
	w.set_readonly(true, "/sys/class/backlight")
	var bl_before: Variant = ctl("display.brightness").value
	controls().set_value("display.brightness", 80)
	await w.idle()
	eq(ctl("display.brightness").value, bl_before, "read-only backlight: the value stays")
	w.set_readonly(false)
	consistent("after failing writes")


## A TDP service that answers after its timeout: the UI keeps moving.
func test_dbus_timeout_never_blocks_the_ui() -> void:
	var svc := "com.steampowered.SteamOSManager1" if power().backend == "steamos-manager" else "org.shadowblip.PowerStation"
	w.fake.faults["dbus_timeout"] = [svc]
	w.fake.timeout_ms = 400
	ok(await open_menu_tab("power"), "Power tab")
	var v := view("power.tdp")
	ok(v != null and await focus_on(v), "TDP row")
	var worst := 0
	for k in 6:
		var t0 := Time.get_ticks_usec()
		await right()
		worst = maxi(worst, Time.get_ticks_usec() - t0)
	ok(worst < 150000, "each press answered within 150 ms (worst %d ms) while %s times out" % [worst / 1000, svc])
	await w.wait_s(0.4)
	await w.idle(30000)
	ok(not qm().model.is_pending("power.tdp"), "no write left pending")
	w.fake.faults.erase("dbus_timeout")
	await b()
	await w.idle()
	for p in Checks.now(w):
		ok(false, "after timeouts: " + p)


## Many changes, detections and profile applies queued at once on the real
## worker: the end state is consistent and nothing errors.
func test_worker_races() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed0() + 7
	print("E2E SEED suite_robustness::test_worker_races %d" % (seed0() + 7))
	var ids := []
	for c in controls().list():
		if c.available and c.kind in ["slider", "choice", "toggle"] and Effects.check(self, c.id, c.value) == "" \
				and not c.id in ["network.airplane", "network.wifi", "network.bluetooth", "power.battery_saver", "display.refresh_unlock", "display.rotation"]:
			ids.append(c.id)
	for k in 120:
		var c := ctl(ids[rng.randi() % ids.size()])
		match rng.randi() % 4:
			0:
				controls().detect_all()
			1:
				profiles().apply_now("race")
			_:
				var v: Variant
				match c.kind:
					"slider": v = rng.randf_range(c.min_value - 5.0, c.max_value + 5.0)
					"toggle": v = rng.randf() < 0.5
					"choice": v = c.options[rng.randi() % c.options.size()]["value"]
				controls().set_value(c.id, v)
	await w.idle(60000)
	consistent("after racing the worker")


## Every command 300 ms slow: the frames keep coming (nothing waits on the main thread).
func test_slow_system_main_thread_never_waits() -> void:
	w.fake.faults["latency_ms"] = 300
	var gaps := []
	var last := [Time.get_ticks_usec()]
	var watch := func():
		var now := Time.get_ticks_usec()
		gaps.append(now - last[0])
		last[0] = now
	w.tree.process_frame.connect(watch)
	for tab in ["power", "display", "audio", "controller"]:
		await open_menu_tab(tab)
		await down()
		await right()
		await down()
		await right()
	await b()
	await w.idle(60000)
	w.tree.process_frame.disconnect(watch)
	w.fake.faults.erase("latency_ms")
	var worst: int = gaps.max() if not gaps.is_empty() else 0
	ok(worst < 250000, "longest frame %d ms while every command took 300 ms" % (worst / 1000))
	for p in Checks.now(w):
		ok(false, "slow system: " + p)


func open_settings_page(cat: String) -> bool:
	main()._open_settings_category(cat, "")
	await w.frames(4)
	return main().current == "settings" and main().settings.category == cat
