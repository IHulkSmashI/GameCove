extends "res://tests/e2e/e2e_case.gd"
## Base for the user journeys (suite_journeys.gd, suite_monkey.gd): a player's
## hands only. Everything a journey does to the app goes in as an input event:
## D-pad, A/B/X/Y, bumpers, triggers, Start / View, the handheld's Guide and
## Quick Access buttons (through InputPlumber's intercept, e2e_case.special),
## holds, touch (screen taps) and a physical keyboard. What a journey checks is
## what is on screen (the focused control, visible text, the screen shown) and
## what reached the system (state files, commands the fake system or the fake
## store tools received).
##
## Finding things is allowed (a node by its name or text, to know where to
## steer); moving to them is done with the D-pad, one press at a time, the way
## a player would get there (nav_to).

const StoresWorld := preload("res://tests/e2e/stores_world.gd")
const Checks := preload("res://tests/e2e/checks.gd")
const View := preload("res://scripts/ui/library_view.gd")

var stores: StoresWorld


# ---- more buttons -------------------------------------------------------------------

func x() -> void:
	await press(JOY_BUTTON_X)


func y() -> void:
	await press(JOY_BUTTON_Y)


## Start (the Menu button: a game's options on a tile).
func start_btn() -> void:
	await press(JOY_BUTTON_START)


## View / Back / Select (the Library's Filter sheet).
func view_btn() -> void:
	await press(JOY_BUTTON_BACK)


## The pad's own Guide button (Godot sees it when InputPlumber passes it through).
func guide_pad() -> void:
	await press(JOY_BUTTON_GUIDE)


## A button held down for `ms` milliseconds.
func hold(button: JoyButton, ms: int) -> void:
	var e := InputEventJoypadButton.new()
	e.device = 0
	e.button_index = button
	e.pressed = true
	e.pressure = 1.0
	_send(e)
	await w.wait_s(ms / 1000.0)
	var u := InputEventJoypadButton.new()
	u.device = 0
	u.button_index = button
	u.pressed = false
	_send(u)
	await w.frames(1)


## A trigger pulled all the way and let go (LT = JOY_AXIS_TRIGGER_LEFT).
func trigger(axis: JoyAxis) -> void:
	await stick(axis, 1.0)


func lt() -> void:
	await trigger(JOY_AXIS_TRIGGER_LEFT)


func rt() -> void:
	await trigger(JOY_AXIS_TRIGGER_RIGHT)


## One key on a physical keyboard (with its character, if it types one).
func key(code: Key, unicode := 0, shift := false) -> void:
	var e := InputEventKey.new()
	e.keycode = code
	e.physical_keycode = code
	e.unicode = unicode
	e.shift_pressed = shift
	e.pressed = true
	_send(e)
	await w.frames(1)
	var u := InputEventKey.new()
	u.keycode = code
	u.physical_keycode = code
	u.pressed = false
	_send(u)
	await w.frames(1)


## Text typed on a physical keyboard.
func type_keys(text: String) -> void:
	for ch in text:
		var c := ch.unicode_at(0)
		var code: Key = (ch.to_upper().unicode_at(0) as Key) if (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9") else (KEY_SPACE if ch == " " else KEY_UNKNOWN)
		await key(code, c, ch >= "A" and ch <= "Z")


## A finger on the touch screen at `pos` (viewport pixels): down, then up.
func tap(pos: Vector2) -> void:
	var d := InputEventScreenTouch.new()
	d.index = 0
	d.position = pos
	d.pressed = true
	_send(d)
	await w.frames(1)
	var u := InputEventScreenTouch.new()
	u.index = 0
	u.position = pos
	u.pressed = false
	_send(u)
	await w.frames(2)


## Taps the middle of `c` on screen.
func tap_on(c: Control) -> void:
	await tap(c.get_global_rect().get_center())


# ---- getting somewhere with the D-pad ----------------------------------------------------

## True when focus is `target` or inside it.
func focused_in(target: Variant) -> bool:
	var f := focus()
	if f == null or target == null or not is_instance_valid(target) or not target is Node:
		return false
	return f == target or (target as Node).is_ancestor_of(f)


## Steers focus to `target` (or anything inside it) with D-pad presses, at most
## `limit` of them: toward where the target is on screen, trying the other
## direction when a press doesn't get closer. `target` may be a Callable that
## finds it again (screens rebuild their rows; a held node can be freed).
## `axes`: "vh" (both), "v" (up / down only: lists whose rows react to left /
## right), "h". True when there.
func nav_to(target: Variant, limit := 60, axes := "vh") -> bool:
	var tried := {}
	for i in limit:
		var t := _resolve(target)
		if t == null:
			return false
		if focused_in(t):
			return true
		var f := focus()
		if f == null:
			await down()
			continue
		var from := f.get_global_rect().get_center()
		var to := t.get_global_rect().get_center()
		var d := to - from
		var order: Array = []
		var vert := "down" if d.y > 0 else "up"
		var horz := "right" if d.x > 0 else "left"
		if absf(d.y) >= 8.0 and "v" in axes:
			order.append(vert)
		if absf(d.x) >= 8.0 and "h" in axes:
			order.append(horz)
		if absf(d.y) < 8.0 and "v" in axes:
			order.append(vert)
		for dir in ["down", "up", "right", "left"]:
			if not dir in order and ((dir in ["down", "up"] and "v" in axes) or (dir in ["right", "left"] and "h" in axes)):
				order.append(dir)
		var moved := false
		for dir in order:
			var mark := "%d:%s" % [f.get_instance_id(), dir]
			if tried.has(mark):
				continue
			tried[mark] = true
			await call(dir)
			await w.frames(1)
			if focus() != f:
				moved = true
				break
		if not moved:
			break
	if focused_in(_resolve(target)):
		return true
	# a page whose focus is one chain (down / up through every card): walk it
	for dir in (["down", "up"] if "v" in axes else ["right", "left"]):
		for i in limit:
			if focused_in(_resolve(target)):
				return true
			var f0 := focus()
			await call(dir)
			await w.frames(1)
			if focus() == f0:
				break
	return focused_in(_resolve(target))


func _resolve(target: Variant) -> Control:
	var t: Variant = target.call() if target is Callable else target
	if t == null or not is_instance_valid(t) or not t is Control:
		return null
	return t


## Steers to `target` and presses A on it.
func press_on(target: Variant, limit := 60, axes := "vh") -> bool:
	if not await nav_to(target, limit, axes):
		return false
	await a()
	await w.frames(2)
	return true


## Moves down (or up) until focus is inside `target`: lists of rows.
func down_to(target: Variant, limit := 60) -> bool:
	return await nav_to(target, limit, "v")


# ---- sheets, menus, keyboards --------------------------------------------------------------

func sheet() -> Control:
	return main().game_actions.sheet


func sheet_open() -> bool:
	return sheet() != null and sheet().is_open()


## The row button for `id` in the open sheet, or null.
func sheet_row(id: String) -> Button:
	var s := sheet()
	for i in s.items.size():
		if str(s.items[i].get("id", "")) == id and i < s.rows.size():
			return s.rows[i]
	return null


## The ids of the open sheet's rows, in order.
func sheet_ids() -> Array:
	return sheet().items.map(func(it): return str(it.get("id", "")))


## Picks row `id` in the open sheet: D-pad to it, A.
func choose(id: String) -> bool:
	await w.frames(2)
	var r := sheet_row(id)
	if r == null:
		return false
	if not await nav_to(r, 30, "v"):
		return false
	await a()
	await w.frames(3)
	return true


## Types `text` on an on-screen keyboard (osk.gd / text_keyboard.gd) by walking
## to each key with the D-pad and pressing A; Y types a space.
func osk_type(osk: Control, text: String) -> bool:
	for ch in text:
		if ch == " ":
			await y()
			continue
		var target := _osk_key(osk, ch)
		if target == null:
			return false
		if not await nav_to(target, 40):
			return false
		await a()
	return true


func _osk_key(osk: Node, ch: String) -> Button:
	var want := ch.to_upper() if ch >= "a" and ch <= "z" else ch
	for b in osk.find_children("*", "Button", true, false):
		if b.is_visible_in_tree() and (b.text == want or b.text == ch):
			return b
	return null


# ---- what's on screen ----------------------------------------------------------------------

## Every visible Label / Button text under `n` (main by default), joined by " | ".
func screen_text(n: Node = null) -> String:
	var root: Node = n if n != null else main()
	var out := PackedStringArray()
	for c in root.find_children("*", "", true, false):
		if c is Label and c.is_visible_in_tree() and c.text != "":
			out.append(c.text)
		elif c is Button and c.is_visible_in_tree() and c.text != "":
			out.append(c.text)
		elif c is RichTextLabel and c.is_visible_in_tree():
			out.append(c.get_parsed_text())
	return " | ".join(out)


func shows(text: String, n: Node = null) -> bool:
	return text.to_lower() in screen_text(n).to_lower()


## Toast texts on screen now.
func toasts() -> String:
	return screen_text(main().toasts)


## The focused control is visible and inside the window.
func focus_on_screen() -> String:
	var f := focus()
	if f == null:
		return "nothing has focus"
	if not f.is_visible_in_tree():
		return "%s has focus but is hidden" % f.get_path()
	var vp := Rect2(Vector2.ZERO, w.tree.root.get_visible_rect().size)
	var r := f.get_global_rect()
	if not vp.grow(2.0).encloses(r) and not vp.intersects(r):
		return "%s has focus but is off screen (%s)" % [f.get_path(), r]
	return ""


## The Library tile of game `key`, or null.
func lib_tile(key: String) -> Control:
	for t in main().library_screen.tiles():
		if str(t.game.get("key", "")) == key:
			return t
	return null


## The screen the player sees: "page", "downloads", "apps", or the tab's id.
func where() -> String:
	if main().page != null:
		return "page:" + str(main().page.name)
	if main()._downloads_open():
		return "downloads"
	if main()._apps_open():
		return "apps"
	return main().current


## RB / LB until the top bar shows `screen`.
func go_tab(screen: String) -> bool:
	for i in 6:
		if main().current == screen and main().page == null and not main()._downloads_open():
			return true
		var from: int = main().SCREENS.find(main().current)
		var to: int = main().SCREENS.find(screen)
		if posmod(to - from, 5) <= 2:
			await rb()
		else:
			await lb()
		await w.frames(3)
	return main().current == screen


func game(key: String) -> Dictionary:
	return w.autoload("Library").game_by_key(key)


# ---- stores ------------------------------------------------------------------------------------

## The player's games on the handheld (stores_world.gd), read by the app as at start.
func with_stores() -> void:
	stores = StoresWorld.new(w)
	stores.attach()
	# favourites, hidden games and collections in the fake home (reset with it)
	var lib: Node = w.autoload("Library")
	DirAccess.make_dir_recursive_absolute(w.home.path_join(".local/share/gamecove-e2e"))
	lib.collections.path = w.home.path_join(".local/share/gamecove-e2e/collections.json")
	lib.collections.reload()
	await stores.rescan()
	await w.idle()


func without_stores() -> void:
	if main().quick_menu.visible:
		await b()
	if stores != null:
		stores.detach()
		stores = null
	await w.idle()


## Every invariant that must hold after any step of a journey ("" when fine).
func invariants(step: String) -> Array[String]:
	var out: Array[String] = []
	for p in Checks.now(w):
		out.append("%s: %s" % [step, p])
	var f := focus_on_screen()
	if f != "" and not main().launch_overlay.is_open() and main()._window_focused:
		out.append("%s: %s" % [step, f])
	return out


func check(step: String) -> void:
	for p in invariants(step):
		ok(false, p)
