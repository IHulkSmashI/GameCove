extends "res://tests/test_case.gd"
## Review 3, medium 3: a focused row that disappears in a rebuild (Bluetooth
## Forget or a failed Pair, a GE-Proton build removed, an app that stopped
## playing, a deleted clip) left nothing focused, so a controller had no way
## back. scripts/ui/keep_focus.gd moves focus to the same control, the nearest
## one left, or the card's main button. Outside a live tree the box's
## KeepFocus.TEST_META stands in for the focus owner (and follows the move).

const KeepFocus := preload("res://scripts/ui/keep_focus.gd")
const BtCard := preload("res://scripts/ui/settings/bluetooth_card.gd")
const BtT := preload("res://tests/test_extras_bluetooth.gd")
const ProtonCard := preload("res://scripts/ui/settings/proton_card.gd")
const ProtonT := preload("res://tests/test_extras_proton.gd")
const MixerT := preload("res://tests/test_extras_mixer.gd")
const AppMixer := preload("res://scripts/ui/controls/app_mixer.gd")
const Fake := preload("res://tests/fixtures/system/fake_runner.gd")


func _box(names: Array) -> VBoxContainer:
	var box := VBoxContainer.new()
	for n in names:
		var b := Button.new()
		b.name = n
		box.add_child(b)
	return box


func _rebuild(box: VBoxContainer, names: Array) -> Array:
	for c in box.get_children():
		box.remove_child(c)
		c.free()
	for n in names:
		var b := Button.new()
		b.name = n
		box.add_child(b)
	return box.get_children()


func test_helper_picks_same_then_nearest_then_fallback() -> void:
	var box := _box(["A", "B", "C"])
	var main := Button.new()
	box.set_meta(KeepFocus.TEST_META, box.get_node("B"))
	var m := KeepFocus.mark(box, box.get_children())
	eq(m["index"], 1, "where focus was")
	var after := _rebuild(box, ["A", "B", "C"])
	eq(KeepFocus.restore(box, m, after, main), box.get_node("B"), "still there: the same one")
	box.set_meta(KeepFocus.TEST_META, box.get_node("B"))
	m = KeepFocus.mark(box, box.get_children())
	after = _rebuild(box, ["A", "C"])
	eq(KeepFocus.restore(box, m, after, main), box.get_node("C"), "gone: the one now at its place")
	eq(box.get_meta(KeepFocus.TEST_META), box.get_node("C"), "focus moved there")
	m = KeepFocus.mark(box, box.get_children())
	after = _rebuild(box, ["A"])
	eq(KeepFocus.restore(box, m, after, main), box.get_node("A"), "the last one gone: the one before")
	m = KeepFocus.mark(box, box.get_children())
	after = _rebuild(box, [])
	eq(KeepFocus.restore(box, m, after, main), main, "none left: the main button")
	box.remove_meta(KeepFocus.TEST_META)
	eq(KeepFocus.mark(box, []), {}, "focus elsewhere: nothing to do")
	eq(KeepFocus.restore(box, {}, [], main), null, "and nothing moves")
	main.free()
	box.free()


func test_bluetooth_forget_and_failed_pair_keep_focus() -> void:
	var bz = BtT.Bluez.new()
	var f: RefCounted = Fake.new()
	f.handler = bz.answer
	f.set_meta("bz", bz)
	var c: VBoxContainer = BtCard.new()
	c.setup(f)
	c.set_meta(KeepFocus.TEST_META, c.rows[BtT.BUDS].button)
	c.act(c.state["devices"][1], "forget")
	ok(not c.rows.has(BtT.BUDS), "forgotten: its row went")
	var now: Control = c.get_meta(KeepFocus.TEST_META)
	ok(is_instance_valid(now) and now == c.rows[BtT.NEW].button, "focus on the next device")
	# a pair that fails and BlueZ drops the device: the row it was on goes too
	bz.ok_calls["Pair"] = false
	var orig: Callable = bz.answer
	f.handler = func(cmd: String) -> Variant:
		if " Pair" in cmd:
			bz.tree.erase(BtT.NEW)
		return orig.call(cmd)
	c.act({"path": BtT.NEW, "name": "JBL Flip 6", "paired": false, "connected": false}, "pair")
	ok(not c.rows.has(BtT.NEW), "dropped device: row gone")
	now = c.get_meta(KeepFocus.TEST_META)
	ok(is_instance_valid(now) and now == c.find_row.button, "focus on Find new devices (the nearest left)")
	c.free()


func test_proton_remove_keeps_focus() -> void:
	var t = ProtonT.new()
	var h: Dictionary = t._home("keepfocus")
	var c: VBoxContainer = ProtonCard.new()
	c.setup(t._fake(), h.home)
	c.set_meta(KeepFocus.TEST_META, c.rows["GE-Proton9-20"].button)
	c.remove("GE-Proton9-20")
	ok(not c.rows.has("GE-Proton9-20"), "removed")
	var now: Control = c.get_meta(KeepFocus.TEST_META)
	ok(is_instance_valid(now) and now == c.rows["GE-Proton10-25"].button, "focus on the build before it")
	c.free()
	t._rm(h.root)


func test_mixer_refresh_keeps_focus() -> void:
	var mt = MixerT.new()
	var s: Dictionary = mt._env("keepfocus_mixer")
	var m: VBoxContainer = AppMixer.new()
	m.setup(s.reg)
	eq(m.rows.size(), 3, "three apps")
	m.set_meta(KeepFocus.TEST_META, m.rows[1].slider)
	s.fake.streams.remove_at(1)   # that Spotify stopped playing
	m.refresh()
	eq(m.rows.size(), 2, "two left")
	var now: Control = m.get_meta(KeepFocus.TEST_META)
	ok(is_instance_valid(now) and now == m.rows[1].slider, "focus on the slider now at its place")
	m.free()
	s.reg.free()
