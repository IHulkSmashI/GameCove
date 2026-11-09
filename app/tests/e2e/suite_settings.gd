extends "res://tests/e2e/e2e_case.gd"
## Settings, page by page, with the pad only: RB to the Settings tab, down the
## category list, right into the page, down through every row (A opens each
## "More settings"). Every control of the page's groups must be there; an
## available one must be reachable and change the system when moved with
## left / right (or A on curves), read back the same from a fresh look at the
## system, and leave every safety invariant intact; an unavailable one shows
## its reason and does nothing when pushed.

const Effects := preload("res://tests/e2e/effects.gd")
const Checks := preload("res://tests/e2e/checks.gd")
const ControlsScript := preload("res://scripts/controls/controls.gd")
const CATEGORIES := ["power", "display", "audio", "controller", "performance", "system"]
## Moved by their own tests (they leave the session, need a game, or go to Steam).
const NOT_HERE := ["system.sleep", "system.screenshot", "perf.wrapper_remove_all", "perf.clear_shader_cache",
	"controller.reset_layout", "controller.rumble_test", "perf.upscale_recommended", "perf.upscale_undo"]


func settings() -> Control:
	return main().settings


## Settings open on `cat`, focus on its first row, reached with the pad.
func open_settings(cat: String) -> bool:
	var guard := 0
	while main().current != "settings" and guard < 8:
		await rb()
		guard += 1
	await w.frames(3)
	if main().current != "settings":
		return false
	var cats: Array = settings().categories()
	var btns: Dictionary = settings().cat_buttons
	# onto the list first (the screen opens on its last category)
	if focus() == null or not focus() in btns.values():
		btns[settings().category].grab_focus()
		await w.frames(1)
	var want: Button = btns[cat]
	guard = 0
	while focus() != want and guard < 20:
		var here := cats.find(_cat_of(focus()))
		if here < cats.find(cat):
			await down()
		else:
			await up()
		guard += 1
	if focus() != want:
		return false
	await right()
	await w.frames(2)
	return settings().in_page()


func _cat_of(f: Control) -> String:
	for k in settings().cat_buttons:
		if settings().cat_buttons[k] == f:
			return k
	return ""


## Walks the open page top to bottom with the pad, opening every "More
## settings". Returns {id: view} for every control row met.
func walk_page(on_row := Callable()) -> Dictionary:
	var met := {}
	var seen := {}
	var opened := {}
	for i in 400:
		var f := focus()
		if OS.get_environment("E2E_DEBUG_WALK") != "":
			print("walk ", i, " ", str(f.get_path()).get_slice("Content/", 1) if f else "null")
		if f == null or not settings().in_page():
			break
		var v := _view_of(f)
		if v != null:
			var id := str(v.get("key"))
			if not met.has(id):
				met[id] = v
				if on_row.is_valid():
					await on_row.call(id, v)
					f = focus()   # a change may rebuild the row
		elif f.get_parent() != null and String(f.get_parent().name) == "More" and "expanded" in f.get_parent().get_parent() \
				and not f.get_parent().get_parent().expanded and not opened.has(f.get_parent().get_parent().get_instance_id()):
			opened[f.get_parent().get_parent().get_instance_id()] = true
			await a()
			await w.frames(2)
			continue
		if seen.has(f) and seen[f] > 2:
			break
		seen[f] = seen.get(f, 0) + 1
		await down()
	return met


func _view_of(f: Node) -> Node:
	var n := f
	while n != null and n != main():
		if n.get_script() == ControlView:
			return n
		n = n.get_parent()
	return null


func _ids_of(cat: String) -> Array:
	var out := []
	for g in TC.CATEGORY_GROUPS_OF[cat]:
		for c in controls().list(g):
			out.append(str(c.id))
	return out


# ---- every row is there ------------------------------------------------------------

func test_every_page_shows_every_control_with_reasons() -> void:
	for cat in CATEGORIES:
		ok(await open_settings(cat), "%s: reached with the pad" % cat)
		var met := await walk_page()
		for id in _ids_of(cat):
			var c := ctl(id)
			if c.available:
				ok(met.has(id), "%s: %s reachable with the pad" % [cat, id])
			else:
				if met.has(id):
					var line: String = met[id].explanation()
					ok(c.reason != "" and line == c.reason, "%s: %s shows its reason (%s), got %s" % [cat, id, c.reason, line])
				else:
					ok(false, "%s: %s (unavailable: %s) isn't shown anywhere" % [cat, id, c.reason])
		await b()   # back to the list
		await w.frames(1)


# ---- every available control changes the system -------------------------------------

func test_every_available_control_applies_and_reads_back() -> void:
	var report := []
	for cat in CATEGORIES:
		if not await open_settings(cat):
			ok(false, "%s: not reached" % cat)
			continue
		await walk_page(func(id: String, v: Node):
			var c := ctl(id)
			if c == null or id in NOT_HERE:
				return
			if not c.available:
				await _push_unavailable(id, v)
				return
			var line: String = await _change(id, v)
			if line != "":
				report.append(line))
		await b()
		await w.frames(1)
	for line in report:
		print("  APPLY " + line)


## A pushed unavailable row: nothing runs, nothing changes.
func _push_unavailable(id: String, v: Node) -> void:
	var n: int = w.fake.log_copy().size()
	# right and A on the row (left would leave the page for the category list)
	await right()
	if focus() != null and v.is_ancestor_of(focus()):
		await a()
	await w.idle()
	var after: Array = w.fake.log_copy().slice(n)
	var writes := after.filter(func(e): return _is_write(e["argv"]))
	eq(writes.size(), 0, "%s (unavailable) wrote nothing when pushed: %s" % [id, writes.map(func(e): return e["argv"])])
	if focus() == null or not settings().in_page():
		var cat: String = settings().category
		await open_settings(cat)


static func _is_write(argv: Array) -> bool:
	var s := " ".join(PackedStringArray(argv.map(func(x): return str(x))))
	return "set-property" in s or s.begins_with("pkexec") or " -set " in s or "set-volume" in s or "set-mute" in s \
		or "set-default" in s or s.begins_with("nmcli radio") or s.begins_with("rfkill block") or s.begins_with("rfkill unblock")


## Moves one control by the pad and checks what reached the system. Returns a
## report line, or "" when the control didn't need checking.
func _change(id: String, v: Node) -> String:
	var c := ctl(id)
	var before: Variant = c.value
	var n: int = w.fake.log_copy().size()
	var model: Object = v.model   # the row may be rebuilt (and freed) by the change
	if c.kind == "choice" and c.options.size() < 2:
		return ""   # one choice: nothing to move to
	var blocked: String = model.blocked_reason(c)
	if blocked != "":
		# "Turn on X first": the row is locked and pushing it changes nothing
		await right()
		await w.idle()
		ok(c.value == before, "%s: %s is locked (%s) and stayed %s" % [setup_name(), id, blocked, before])
		return ""
	match c.kind:
		"slider":
			var at_top: bool = before != null and float(before) >= c.max_value - 0.0001
			if at_top:
				await left()
			else:
				await right()
			await w.frames(1)
			await w.wait_s(0.35)   # SliderRow settles before it sends
		"choice", "toggle", "color":
			await right()
		"curve":
			await a()
			# the first point up, or down when it's already at the top
			if before is Array and not before.is_empty() and float(before[0]) >= c.max_value - 0.001:
				await down()
			else:
				await up()
			await a()
		"action":
			return ""
	await w.idle()
	var after: Variant = c.value
	var why := ""
	if model.is_failed(id):
		why = "the change failed"
	elif model.is_pending(id):
		why = "still applying"
	elif after == before and not _expect_unchanged(id, before):
		why = "value didn't change (%s)" % [before]
	var fresh: Variant = fresh_read(id) if not id in Effects.NO_FRESH_READ else after
	if why == "" and not Effects.same(c, fresh, after):
		why = "a fresh look at the system says %s, the control says %s" % [fresh, after]
	var eff: String = Effects.check(self, id, after)
	if why == "" and eff != "":
		why = eff
	for p in Checks.now(w):
		ok(false, "%s: after changing %s: %s" % [setup_name(), id, p])
	var cmds: Array = w.fake.log_copy().slice(n).filter(func(e): return _is_write(e["argv"])).map(func(e): return " ".join(PackedStringArray(e["argv"].map(func(x): return str(x)))))
	ok(why == "", "%s: %s %s -> %s: %s" % [setup_name(), id, before, after, why])
	if focus() == null or not settings().in_page():
		await open_settings(settings().category)
	return "%s: %s -> %s via %s" % [id, before, after, cmds.slice(0, 3)]


func _expect_unchanged(_id: String, _before: Variant) -> bool:
	return false


## The control's value as a fresh provider reads it from the system now
## (its own registry: no state from the app's instance).
func fresh_read(id: String) -> Variant:
	var c := ctl(id)
	var file: String = {"power": "power.gd", "display": "display.gd", "audio": "audio.gd", "controller": "controller.gd",
		"perf": "perf.gd", "system": "system.gd", "network": "system.gd"}.get(c.group, "")
	if file == "":
		return null
	w.fake.hold()
	var reg: Node = ControlsScript.new()
	reg.sync_mode = true
	var cx: Dictionary = w.ctx.duplicate()
	cx["registry"] = reg
	cx["launcher"] = null
	reg.setup(cx)
	var p: Object = load("res://scripts/controls/providers/" + file).new()
	if p.has_method("setup"):
		p.setup(cx)
	var out: Variant = null
	for x in p.controls():
		if x.id == id:
			x.ctx = cx
			x.detect()
			out = x.read() if x.available else "unavailable: " + x.reason
	reg.free()
	w.fake.release()
	return out
