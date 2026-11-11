extends "res://tests/e2e/e2e_case.gd"
## FocusScroll with a scroller inside a scroller (About this device: a column of cards that scrolls
## inside the Settings page, which scrolls too). Focus inside the inner one is the inner scroller's
## job; the page only keeps the inner pane in view and must not follow the card (which moves while
## the inner scroller glides), or it ends scrolled past the pane's top and cuts the card off.

const FocusScroll := preload("res://scripts/ui/focus_scroll.gd")


func _nested(host: Control, rows: int) -> Array:
	var outer := ScrollContainer.new()
	outer.name = "Outer"
	outer.custom_minimum_size = Vector2(300, 400)
	outer.size = Vector2(300, 400)
	outer.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	host.add_child(outer)
	var page := VBoxContainer.new()
	page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	outer.add_child(page)
	var inner := ScrollContainer.new()
	inner.name = "Inner"
	inner.custom_minimum_size = Vector2(0, 360)
	inner.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	page.add_child(inner)
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.add_child(col)
	var buttons: Array = []
	for i in rows:
		var b := Button.new()
		b.name = "Row%d" % i
		b.text = "Row %d" % i
		b.custom_minimum_size = Vector2(0, 90)
		col.add_child(b)
		buttons.append(b)
	var tail := Control.new()   # what sits under the inner pane on the page (the photo switches)
	tail.custom_minimum_size = Vector2(0, 260)
	page.add_child(tail)
	FocusScroll.attach(outer)
	FocusScroll.attach(inner)
	return [outer, inner, buttons]


func test_the_page_does_not_follow_a_card_in_a_scroller_inside_it() -> void:
	var host := Control.new()
	host.name = "NestedScrollHost"
	w.tree.root.add_child(host)
	var n := _nested(host, 12)
	var outer: ScrollContainer = n[0]
	var inner: ScrollContainer = n[1]
	var rows: Array = n[2]
	await w.frames(3)
	ok(outer.get_v_scroll_bar().max_value > outer.size.y + 100.0, "the page itself scrolls (content taller than its view)")
	(rows[8] as Button).grab_focus()
	await w.wait_s(0.8)
	ok(inner.scroll_vertical > 300, "the inner scroller brought the row into view (%d)" % inner.scroll_vertical)
	eq(outer.scroll_vertical, 0, "the page stayed at its top: the inner pane is whole in view")
	var pane := inner.get_global_rect()
	var r := (rows[8] as Button).get_global_rect()
	ok(r.position.y >= pane.position.y - 1.0 and r.end.y <= pane.end.y + 1.0, "the row sits inside the inner pane")
	ok(pane.position.y >= outer.get_global_rect().position.y - 1.0, "the pane's top is not scrolled out of the page")
	host.free()


func test_the_page_still_scrolls_to_a_button_that_is_not_in_a_nested_scroller() -> void:
	var host := Control.new()
	host.name = "NestedScrollHost2"
	w.tree.root.add_child(host)
	var n := _nested(host, 3)
	var outer: ScrollContainer = n[0]
	var page: Control = outer.get_child(0)
	var low := Button.new()
	low.name = "Low"
	low.text = "Low"
	low.custom_minimum_size = Vector2(0, 80)
	page.add_child(low)
	await w.frames(3)
	low.grab_focus()
	await w.wait_s(0.8)
	ok(outer.scroll_vertical > 100, "a page-level button below the pane is still scrolled to (%d)" % outer.scroll_vertical)
	host.free()
