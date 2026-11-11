extends "res://tests/e2e/journey_case.gd"
## Journeys for a TV: a handheld docked to a 4K TV (and the Steam Machine, which
## always is one), with a player's hands only. The screen GameCove runs on is
## the TV (UiScale's screen hooks, as E2E_SCREEN sets them); Settings >
## Appearance offers the interface sizes that look different there, the pad
## steps one and back, the layout follows and is saved, and undocking puts the
## handheld's size back. Runs on every setup (its name has "box": the Steam
## Machine's run includes it too).

const UiScale := preload("res://scripts/ui/ui_scale.gd")
const UiPrefs := preload("res://scripts/ui/ui_prefs.gd")
const Layouts := preload("res://tests/layout/matrix.gd")


func _dock(row_id: String) -> void:
	var row: Dictionary = Layouts.row(row_id)
	UiScale.override_screen = row.get("screen", {})
	UiScale.override_window = row.get("size", Vector2i.ZERO)
	main()._fit_density()
	main()._build_settings()   # what Settings shows for this screen
	await w.frames(4)


func _undock() -> void:
	UiScale.override_screen = {}
	UiScale.override_window = Vector2i.ZERO
	main()._fit_density()
	main()._build_settings()
	await w.frames(4)


func _row(key: String) -> Control:
	for c in main().settings.find_children("*", "", true, false):
		if "key" in c and "values" in c and str(c.key) == key and c.is_visible_in_tree():
			return c
	return null


func test_docked_to_a_tv_interface_size_by_pad_then_undocked() -> void:
	var size0 := str(UiPrefs.values().get("interface_size", "default"))
	var layout0: Vector2i = w.tree.root.content_scale_size
	await _dock("tv-4k-55in")
	var sizes: Array = UiScale.sizes_for(UiScale.window_size(w.tree.root), UiScale.screen_for(w.autoload("Device")))
	ok(sizes.size() > 1, "a 4K TV offers more than one interface size (%s)" % [sizes])
	ok(await open_settings("appearance"), "Settings > Appearance with the pad")
	var row := func(): return _row("interface_size")
	ok(row.call() != null, "an Interface size row")
	if row.call() == null:
		await _undock()
		return
	ok(await down_to(func(): return row.call().button if row.call() else null, 30), "D-pad down to it")
	var before: Variant = row.call().values[row.call().index]
	var layout_docked: Vector2i = w.tree.root.content_scale_size
	await right()
	await w.frames(4)
	var after: Variant = row.call().values[row.call().index] if row.call() else before
	ok(after != before, "right: another size (%s -> %s)" % [before, after])
	eq(str(UiPrefs.values().get("interface_size", "")), str(after), "saved")
	ok(w.tree.root.content_scale_size != layout_docked, "the layout follows (%s -> %s)" % [layout_docked, w.tree.root.content_scale_size])
	ok(focus() != null and focus_on_screen() == "", "focus stays on screen at the new size")
	await left()
	await w.frames(4)
	eq(str(UiPrefs.values().get("interface_size", "")), str(before), "left: back")
	eq(w.tree.root.content_scale_size, layout_docked, "and the layout with it")
	check("docked")
	await b()
	await go_tab("home")
	await _undock()
	eq(w.tree.root.content_scale_size, layout0, "undocked: the handheld's layout again")
	var v: Dictionary = UiPrefs.values()
	v["interface_size"] = size0
	UiPrefs.set_values(v)
	check("undocked")


## Every screen on the TV, by pad: focus visible and on screen after each press.
func test_every_screen_on_a_tv_by_pad() -> void:
	await _dock("tv-4k-55in")
	for screen in ["home", "library", "discover", "stream", "settings"]:
		ok(await go_tab(screen), "RB to %s" % screen)
		for d in ["down", "right", "down", "left"]:
			await call(d)
			await w.frames(2)
			await until(func(): return focus_on_screen() == "", 1000)
			var e := focus_on_screen()
			ok(e == "", "%s on a TV: %s" % [screen, e])
	await go_tab("home")
	await _undock()
	check("tv screens")
