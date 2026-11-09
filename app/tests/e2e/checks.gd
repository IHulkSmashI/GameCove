extends RefCounted
## Safety invariants the end-to-end suite re-checks after every test (and
## suites call `now()` after every step that writes):
##
##  - the fake hardware stays inside this handheld's limits: power limits
##    (firmware attributes, RAPL), backlight never off, fan duties, charge limit
##    50-100 %, CPU / GPU files from the offered lists (device matrix checks)
##  - D-Bus TDP / charge values and root-helper arguments inside the limits
##  - no command names a real system path (everything carries the fixture root)
##  - every service still points at the fixture (nothing can reach real paths)
##  - the battery charge limit the player set is what the battery has
##  - the Desktop Mode switch is always reachable from the quick menu
##  - no command ran on the main thread (the UI never waits for one)

const Matrix := preload("res://tests/devicematrix/matrix.gd")
const TC := preload("res://scripts/ui/texts_controls.gd")
const Fake := preload("res://tests/e2e/fake_system.gd")

## Orphan nodes a test may leave behind (none expected; see run_e2e.gd).
const ORPHAN_SLACK := 0

## Engine messages the headless renderer prints that aren't the app's doing.
const KNOWN_ENGINE_NOISE: Array[String] = []


static func drop_noise(seen: Array[Dictionary]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e in seen:
		var noise := false
		for n in KNOWN_ENGINE_NOISE:
			if n in str(e["text"]):
				noise = true
		if not noise:
			out.append(e)
	return out


## Cheap checks for after any step.
static func now(w: RefCounted) -> Array[String]:
	var out: Array[String] = []
	out.append_array(Matrix.critical_problems(w.root, w.row))
	var inv: Dictionary = Matrix.expectations().get("invariants", {})
	out.append_array(Matrix.backend_problems(w.fake, w.hhd, w.row, inv))
	out.append_array(Matrix.real_path_args(w.fake, w.root))
	out.append_array(wiring(w))
	for e in w.fake.main_thread_calls():
		# starting a process that carries on by itself (OS.create_process) doesn't wait
		if bool(e.get("spawn", false)):
			continue
		if not _allowed_on_main(e["argv"]):
			out.append("command on the main thread (the UI waited for it): %s" % " ".join(PackedStringArray(e["argv"].map(func(x): return str(x)))))
	return out


## Commands that may run on the main thread: none. (Kept as a hook so a
## deliberate exception has to be named here, with its reason.)
static func _allowed_on_main(_argv: Array) -> bool:
	return false


## Every service and control still on the fixture.
static func wiring(w: RefCounted) -> Array[String]:
	var out: Array[String] = []
	var c: Node = w.autoload("Controls")
	if str(c.ctx.get("sys_root", "")) != w.root or c.ctx.get("runner") != w.fake:
		out.append("Controls context left the fixture")
	for ctl in c.list():
		if str(ctl.ctx.get("sys_root", "")) != w.root:
			out.append("%s has sys_root %s" % [ctl.id, ctl.ctx.get("sys_root", "")])
	var p: Node = w.autoload("Power")
	if p.sys_root != w.root or p.runner != w.fake:
		out.append("Power left the fixture")
	if w.autoload("Device").root != w.root:
		out.append("Device left the fixture")
	var gs: Node = w.autoload("Gamescope")
	if not gs.runner is Fake.GamescopeRunner:
		out.append("Gamescope runner is real")
	if w.autoload("Controller").runner != w.fake:
		out.append("Controller runner is real")
	return out


## After each test: the cheap checks, the battery limit, and Desktop Mode.
static func after_test(w: RefCounted) -> Array[String]:
	var out := now(w)
	out.append_array(battery_limit(w))
	out.append_array(await desktop_reachable(w))
	return out


## The charge limit the player has (power.charge_limit) is what the battery
## shows, on every path (steamos-manager or the root helper).
static func battery_limit(w: RefCounted) -> Array[String]:
	var out: Array[String] = []
	var c: RefCounted = w.autoload("Controls").control("power.charge_limit")
	if c == null or not c.available or c.value == null:
		return out
	var f := ""
	for b in ["BAT0", "BAT1"]:
		if FileAccess.file_exists(w.root + "/sys/class/power_supply/%s/charge_control_end_threshold" % b):
			f = "/sys/class/power_supply/%s/charge_control_end_threshold" % b
	if f == "":
		return out
	var hw = w.read(f).to_int()
	if hw != int(c.value) and not w.readonly_files.size() > 0:
		out.append("charge limit control says %s %% but the battery has %s %%" % [c.value, hw])
	return out


## The quick menu's Device tab always offers Switch to Desktop Mode, focusable
## with the D-pad, whatever state the test left the app in.
static func desktop_reachable(w: RefCounted) -> Array[String]:
	var out: Array[String] = []
	if w.main == null:
		return out
	var qm: Control = w.main.quick_menu
	var was_open := qm.visible
	if not was_open:
		qm.open({})
	qm.show_section(TC.TAB_IDS.find("device"))
	await w.frames(1)
	var desk := qm.body.get_node_or_null("DesktopMode/Button") as Button
	if desk == null:
		out.append("quick menu Device tab has no Switch to Desktop Mode")
	elif desk.disabled or not desk in qm.focusables():
		out.append("Switch to Desktop Mode can't be reached with the D-pad")
	if not was_open:
		qm.close()
	return out


## The app quits: Controller's exit path puts every device back to InterceptMode 0.
static func on_exit(w: RefCounted) -> Array[String]:
	var out: Array[String] = []
	var c: Node = w.autoload("Controller")
	var parent = c.get_parent()
	var idx = c.get_index()
	parent.remove_child(c)    # _exit_tree: the shutdown path
	var modes: Array = w.fake.prop_value("InterceptMode")
	for m in modes:
		if int(m) != 0:
			out.append("InterceptMode %s left on an InputPlumber device at exit" % m)
	parent.add_child(c)
	parent.move_child(c, idx)
	return out
