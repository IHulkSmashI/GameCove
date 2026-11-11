extends "res://tests/e2e/e2e_case.gd"
## The quick menu's Shortcuts strip with the pad, on the real app over a fake
## handheld: one Up from the rows reaches it, each shortcut does its job on the
## system (Steam's keyboard, a key in the game, a screenshot file, mute, sleep,
## force close, power), only what works here shows, opening the menu runs
## nothing, and Settings > Quick menu changes what it shows.

const Registry := preload("res://scripts/actions/registry.gd")
const Prefs := preload("res://scripts/actions/shortcut_prefs.gd")
const Screenshots := preload("res://scripts/system/screenshots.gd")
const T := preload("res://scripts/ui/quick/texts_shortcuts.gd")


func strip() -> Control:
	return qm().strip


func _events() -> Array:
	w.fake._log_mutex.lock()
	var e: Array = w.fake.events.duplicate()
	w.fake._log_mutex.unlock()
	return e


func _keys() -> Array:
	w.fake._log_mutex.lock()
	var k: Array = w.fake.keys_sent.duplicate()
	w.fake._log_mutex.unlock()
	return k


func _toasts() -> Array:
	var out := []
	for l in w.main.toasts.find_children("*", "Label", true, false):
		out.append((l as Label).text)
	return out


## A game on screen and the menu open over it, focus on the strip's `id`.
func _over_game(id := "") -> bool:
	Prefs.reset()
	await start_game(GAME_A)
	await until(func(): return not w.main._window_focused, 4000)
	await qam()
	if not qm().visible or strip() == null:
		return false
	await up()
	await w.frames(1)
	if id == "":
		return true
	return await _to(id)


## Moves along the strip to `id` with left / right.
func _to(id: String) -> bool:
	var ids: Array = strip().visible_ids()
	if not id in ids:
		return false
	for i in ids.size() * 2:
		var f := focus()
		if f == strip().buttons[id]:
			return true
		var here: int = ids.find(str(f.get_meta("action", ""))) if f != null and f.has_meta("action") else -1
		if here < 0:
			return false
		if here < ids.find(id):
			await right()
		else:
			await left()
	return focus() == strip().buttons[id]


## Settings open on `cat`, focus on its first row, reached with the pad.
func _open_settings(cat: String) -> bool:
	var s: Control = main().settings
	var guard := 0
	while main().current != "settings" and guard < 8:
		await rb()
		guard += 1
	await w.frames(3)
	if main().current != "settings":
		return false
	var cats: Array = s.categories()
	var btns: Dictionary = s.cat_buttons
	if focus() == null or not focus() in btns.values():
		btns[s.category].grab_focus()
		await w.frames(1)
	guard = 0
	while focus() != btns[cat] and guard < 24:
		var here := cats.find(btns.find_key(focus()))
		if here < cats.find(cat):
			await down()
		else:
			await up()
		guard += 1
	if focus() != btns[cat]:
		return false
	await right()
	await w.frames(2)
	return s.in_page()


func test_one_up_from_the_rows_reaches_the_strip() -> void:
	Prefs.reset()
	await start_game(GAME_A)
	ok(await until(func(): return not w.main._window_focused, 4000), "the game is on screen")
	await qam()
	ok(qm().visible and strip() != null and strip().is_visible_in_tree(), "the strip shows when the menu opens")
	var rows_top: Control = focus()
	ok(rows_top != null and qm().body.is_ancestor_of(rows_top), "the menu still opens on This game's first row")
	# without scrolling: inside the panel, above the rows' scroll area
	var panel_rect: Rect2 = qm().panel.get_global_rect()
	var strip_rect: Rect2 = strip().get_global_rect()
	ok(panel_rect.encloses(strip_rect), "the strip is inside the menu's panel")
	ok(strip_rect.end.y <= qm()._scroll.get_global_rect().position.y + 1.0, "above the rows, so it never scrolls away")
	# the shortcut used last this session, else the first
	var ids: Array = strip().visible_ids()
	var at: int = ids.find(strip()._last) if strip()._last in ids else 0
	await up()
	ok(focus() == strip().buttons[ids[at]], "one D-pad Up from the rows: the shortcut used last, else the first (%s)" % ids[at])
	var nxt: int = at + 1 if at + 1 < ids.size() else at - 1
	if nxt > at:
		await right()
	else:
		await left()
	ok(focus() == strip().buttons[ids[nxt]], "Left / Right move along the strip")
	if nxt > at:
		await left()
	else:
		await right()
	await down()
	ok(focus() == rows_top, "Down goes back to the rows")
	await up()
	await up()
	ok(focus() == qm().tabs[0], "Up from the strip reaches the tabs")
	await down()
	ok(focus() != null and focus().has_meta("action"), "and Down from the tabs comes back to it")
	await rb()
	await up()
	ok(focus() != null and focus().has_meta("action"), "the same on the next tab")
	for b in strip().focusables():
		var r: Rect2 = b.get_global_rect()
		ok(r.size.x >= 56.0 and r.size.y >= 56.0, "%s is a large target (%s)" % [b.name, r.size])
		ok(panel_rect.grow(1.0).encloses(r), "%s is fully inside the panel (button %s, panel %s, strip scrolled %s)" % [b.name, r, panel_rect, strip()._scroll.scroll_horizontal])
	await b()
	await end_game()


func test_only_what_works_here_shows() -> void:
	Prefs.reset()
	for id in Registry.strip_ids():
		Prefs.set_shown(id, true)
	await qam()
	var ids: Array = strip().visible_ids() if strip() != null else []
	ok(not "keyboard" in ids and not "send_key" in ids and not "force_close" in ids, "no game: no Keyboard, Send key or Force close (%s)" % [ids])
	for id in ids:
		var c: String = Registry.action(id)["control"]
		ok(c == "" or available(c), "%s shows, so its Control %s is available" % [id, c])
	for id in Registry.strip_ids():
		var c: String = Registry.action(id)["control"]
		if c != "" and not available(c):
			ok(not id in ids, "%s hidden: %s isn't available on %s" % [id, c, setup_name()])
	await b()
	await start_game(GAME_A)
	await until(func(): return not w.main._window_focused, 4000)
	await qam()
	ids = strip().visible_ids()
	ok("keyboard" in ids and "force_close" in ids, "over a game: Keyboard and Force close")
	var ip: bool = str(w.autoload("Controller").state().get("backend", "")) == "inputplumber"
	eq("send_key" in ids, ip, "Send key only where InputPlumber presses the keys (backend: %s)" % w.autoload("Controller").state().get("backend", ""))
	await b()
	await end_game()
	Prefs.reset()


func test_opening_the_menu_runs_nothing_for_the_strip() -> void:
	Prefs.reset()
	for id in Registry.strip_ids():
		Prefs.set_shown(id, true)
	await start_game(GAME_A)
	await until(func(): return not w.main._window_focused, 4000)
	await qam()
	await w.idle()
	w.fake.reset_log()
	for i in 5:
		strip().refresh()
	eq(w.fake.log_copy().size(), 0, "refreshing the strip runs no program and makes no D-Bus call")
	var built: Dictionary = strip().buttons.duplicate()
	await b()
	await qam()
	for id in built:
		ok(strip().buttons.get(id) == built[id], "%s: the same button as last time (built once, kept)" % id)
	eq(w.fake.main_thread_calls().size(), 0, "nothing ran on the main thread")
	await b()
	await end_game()
	Prefs.reset()


func test_keyboard_opens_steams_keyboard_for_the_game() -> void:
	ok(await _over_game("keyboard"), "Keyboard is on the strip over a game")
	w.fake.reset_log()
	await a()
	ok(not qm().visible, "the menu closes: the game has the keyboard")
	ok(await until(func(): return "steam steam://open/keyboard" in _events(), 3000), "Steam is asked for its own keyboard (steam -ifrunning steam://open/keyboard)")
	eq(calls_with(["/usr/bin/steam"]), [["/usr/bin/steam", "-ifrunning", "steam://open/keyboard"]], "exactly that, once")
	eq(w.fake.main_thread_calls().size(), 0, "off the main thread")
	ok(await until(func(): return w.autoload("Controller").intercept_state()["game_focused"], 3000), "the controller is the game's again")
	eq(_keys().size(), 0, "GameCove types nothing itself")
	await end_game()


func test_send_key_reaches_the_game_and_never_gamecove() -> void:
	if str(w.autoload("Controller").state().get("backend", "")) != "inputplumber":
		Prefs.reset()
		await start_game(GAME_A)
		await qam()
		ok(not "send_key" in strip().visible_ids(), "no InputPlumber here: no Send key")
		await b()
		await end_game()
		return
	ok(await _over_game("send_key"), "Send key is on the strip over a game")
	await a()
	ok(strip().sheet_open(), "A opens the Send key sheet")
	eq(strip().sheet.items.size(), 5, "Esc, Enter, Tab, Alt+Enter, Alt+F4")
	for i in 3:
		await down()
	w.fake.reset_log()
	await a()
	ok(not qm().visible and not strip().sheet_open(), "picked: sheet and menu are gone")
	ok(await until(func(): return _keys().size() == 4, 4000), "four key events went out")
	eq(_keys(), ["KEY_LEFTALT true", "KEY_ENTER true", "KEY_ENTER false", "KEY_LEFTALT false"], "Alt+Enter: down in order, up in reverse")
	eq(w.fake.main_thread_calls().size(), 0, "off the main thread")
	eq(w.fake.keyboards_made, w.fake.keyboards_stopped, "a keyboard made for the press is stopped again")
	# LB / RB don't switch tabs behind the sheet
	await qam()
	await up()
	ok(await _to("send_key"), "back on Send key")
	await a()
	var tab: int = qm().section
	await rb()
	eq(qm().section, tab, "RB behind the sheet does nothing")
	await b()
	ok(not strip().sheet_open() and qm().visible, "B closes the sheet, the menu stays")
	ok(focus() == strip().buttons["send_key"], "focus is back on Send key")
	await b()
	# GameCove in front (the game still runs behind it): keys are refused
	await guide()
	await w.idle()   # the fake gamescope's focus change reaches the window on idle()
	ok(await until(func(): return w.main._window_focused, 4000), "Guide brings GameCove to the front")
	w.fake.reset_log()
	ok(not w.main.actions.run("key_alt_f4", "button"), "GameCove in front: Alt+F4 is refused")
	await w.idle()
	eq(_keys().size(), 0, "no key was pressed at GameCove")
	await qam()
	ok(not "send_key" in strip().visible_ids() and not "keyboard" in strip().visible_ids(), "and the shortcuts aren't offered there")
	await b()
	await end_game()


func test_screenshot_saves_a_file_and_says_so() -> void:
	if not available("system.screenshot"):
		return
	ok(await _over_game("screenshot"), "Screenshot is on the strip")
	var dir := Screenshots.root(w.home)
	var before := Screenshots.list(dir).size()
	await a()
	ok(await until(func(): return Screenshots.list(dir).size() == before + 1, 6000), "a GameCove_*.png lands in Pictures/Screenshots")
	ok("screenshot" in _events(), "taken by gamescope (its request atom)")
	ok(await until(func(): return T.SHOT_SAVED in _toasts(), 3000), "a toast says it saved")
	ok(qm().visible, "the menu stays open (gamescope shoots the game's own plane)")
	var shots := Screenshots.list(dir)
	ok(str(shots[0]["name"]).begins_with("GameCove_") and int(shots[0]["size"]) > 0, "the file is a picture")
	# Settings > Media reads the same folder
	var MediaPage = load("res://scripts/ui/settings/media_page.gd")
	var st: Dictionary = MediaPage.read_state(w.fake, {"home": w.home, "path_env": "", "sys_root": w.root})
	eq(st["shots"].size(), before + 1, "Settings > Media lists it")
	ok(st["pictures"].has(shots[0]["path"]), "with its picture")
	ok(Screenshots.delete(dir, shots[0]["path"]), "and can delete it")
	await b()
	await end_game()


func test_toggles_change_the_system_and_show_it() -> void:
	ok(await _over_game(), "the strip over a game")
	for pair in [["mute", "audio.mute"], ["mouse_mode", "controller.desktop_mode"]]:
		var id: String = pair[0]
		if not id in strip().visible_ids():
			ok(not available(pair[1]), "%s is missing only because %s isn't available here" % pair)
			continue
		ok(await _to(id), "%s reached with the pad" % id)
		var was: bool = ctl(pair[1]).value == true
		await a()
		ok(await until(func(): return (ctl(pair[1]).value == true) != was, 6000), "%s changed %s on the system" % pair)
		await w.idle()
		eq(strip().buttons[id].has_theme_stylebox_override("normal"), not was, "%s shows its new state" % id)
		ok(qm().visible and focus() == strip().buttons[id], "the menu and the focus stay")
		await a()
		ok(await until(func(): return (ctl(pair[1]).value == true) == was, 6000), "%s again: back as it was" % id)
		await w.idle()
	await b()
	await end_game()


func test_sleep_force_close_and_power() -> void:
	Prefs.reset()
	Prefs.set_shown("force_close", true)
	Prefs.set_shown("power_menu", true)
	await start_game(GAME_A)
	await until(func(): return not w.main._window_focused, 4000)
	await qam()
	await up()
	if "sleep" in strip().visible_ids():
		ok(await _to("sleep"), "Sleep reached")
		w.fake.reset_log()
		await a()
		ok(not qm().visible, "Sleep closes the menu first")
		ok(await until(func(): return "suspend" in _events(), 4000), "systemctl suspend")
		await w.idle()
		await qam()
		await up()
	# Force close: asks, No keeps the game, Yes kills it at once
	ok(await _to("force_close"), "Force close reached")
	await a()
	ok(strip().sheet_open(), "it asks first")
	ok(focus() == strip().sheet.rows[0] and strip().sheet.items[0]["id"] == "no", "focus starts on Keep playing")
	await a()
	ok(w.main.session.is_active() and qm().visible, "Keep playing: nothing happened")
	w.fake.reset_log()
	await a()
	await down()
	await a()
	ok(not qm().visible, "Force close: the menu is gone")
	var kills := calls_with(["sh", "-c", "*", "gamecove-close", "KILL", "steam", GAME_A["id"]])
	eq(kills.size(), 1, "one KILL for the game's Steam launch, at once (no TERM, no grace)")
	eq(calls_with(["sh", "-c", "*", "gamecove-close", "TERM"]).size(), 0, "no polite TERM first")
	await end_game()
	# Power: each row asks again
	await qam()
	await up()
	ok(await _to("power_menu"), "Power reached without a game")
	await a()
	eq(strip().sheet.items.map(func(i): return i["id"]), ["restart", "shutdown", "desktop", "steam"], "Restart, Shut down, Desktop Mode, Steam Gaming Mode")
	await a()
	await w.frames(2)
	ok(strip().sheet_open() and strip().sheet.title_label.text == T.POWER_CONFIRM["restart"], "Restart asks again")
	await a()
	ok(not "reboot" in _events(), "Stay here: nothing")
	await a()
	await a()
	await w.frames(2)
	await down()
	w.fake.reset_log()
	await a()
	ok(await until(func(): return "reboot" in _events(), 4000), "Restart: systemctl reboot")
	await w.idle()
	Prefs.reset()


func test_settings_page_picks_and_orders_the_strip() -> void:
	Prefs.reset()
	var s: Control = main().settings
	ok(await _open_settings("quick_menu"), "Settings > Quick menu is reached with the pad")
	var page: Control = s.pages["quick_menu"]
	ok(page.is_visible_in_tree(), "Settings > Quick menu opens")
	eq(page.focusables().size(), Registry.strip_ids().size() + 1, "one row per shortcut and the reset row")
	page.rows["keyboard"].button.grab_focus()
	await w.frames(1)
	ok(page.rows["keyboard"].value() == true, "Keyboard starts shown")
	await left()
	ok(not Prefs.is_shown("keyboard"), "Left turns it off")
	await right()
	ok(Prefs.is_shown("keyboard"), "Right turns it on")
	eq(s.hints(focus()).filter(func(h): return h[0] in ["X", "Y"]).size(), 2, "the hint bar offers X / Y to move it")
	await press(JOY_BUTTON_Y)
	eq(Prefs.all().slice(0, 2), ["steam_menu", "keyboard"], "Y moves it down")
	ok(focus() == page.rows["keyboard"].button, "focus follows the row")
	await press(JOY_BUTTON_X)
	eq(Prefs.all()[0], "keyboard", "X moves it up")
	await press(JOY_BUTTON_X)
	eq(Prefs.all()[0], "keyboard", "the first can't go higher")
	page.rows["wifi"].button.grab_focus()
	await w.frames(1)
	await right()
	ok(Prefs.is_shown("wifi"), "Wi-Fi turned on")
	page.rows["sleep"].button.grab_focus()
	await w.frames(1)
	await left()
	await qam()
	ok(not "sleep" in strip().visible_ids(), "the strip dropped Sleep")
	eq("wifi" in strip().visible_ids(), available("network.wifi"), "and shows Wi-Fi where there is Wi-Fi")
	await b()
	await w.frames(2)
	s.pages["quick_menu"].rows["reset_shortcuts"].button.grab_focus()
	await w.frames(1)
	await a()
	await w.frames(2)
	eq(Prefs.shown(), Registry.STRIP_DEFAULT, "the reset row puts the usual strip back")
	main().show_screen("home")
	await w.idle()


## Eight buttons share the panel's width: a word like "Screenshot" or "Keyboard" used to touch
## both edges of its button (the Shortcuts pictures showed it). Every label keeps air each side.
func test_labels_sit_inside_their_buttons_with_air() -> void:
	Prefs.reset()
	await start_game(GAME_A)
	await until(func(): return not w.main._window_focused, 4000)
	await qam()
	await w.frames(3)
	ok(strip() != null and strip().focusables().size() >= 6, "the strip is there with its default shortcuts")
	for btn in strip().focusables():
		var l := btn.get_node("Col/Name") as Label
		var font := l.get_theme_font("font")
		var px := l.get_theme_font_size("font_size")
		var width := font.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x
		ok(width <= btn.size.x - 8.0, "%s: \"%s\" is %d px wide in a %d px button, with air each side" % [btn.name, l.text, int(width), int(btn.size.x)])
		ok(px >= 9, "%s: the label is still readable (%d px)" % [btn.name, px])
	await b()
	await end_game()
	Prefs.reset()
