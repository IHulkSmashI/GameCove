extends RefCounted
## The focus walk: GameCove's controller rules (docs/CONTROLLER-UX.md) checked
## on one screen as it stands right now. tools/layout/recorder.gd runs it after
## every shot of every screenshot set (every screen, sheet, dialog, quick menu
## tab, settings page, setup and installer step) on the CI layouts, next to the
## geometry checks (layout_checks.gd).
##
## From every control the pad can focus, it presses each of the four D-pad
## directions (real joypad events through the window, so the app's own handlers
## run), notes where focus went and what changed, puts everything back, and
## reports:
##
##   pad-skip         the press jumps over a control that sits between, in the same line (CUX-5)
##   pad-order        the press goes off its line while a control in line is nearer (CUX-5)
##   pad-direction    the press moves focus the other way (CUX-5)
##   pad-stuck        nothing happens, though a control sits right there in that direction (CUX-5, CUX-9)
##   pad-lost         focus is gone after the press (CUX-8)
##   pad-hidden       focus lands on something that isn't on screen: under a sheet, faded out, hidden (CUX-8)
##   pad-value        the press changed a value on a control that isn't a slider or stepper (CUX-3)
##   pad-action       the press changed the screen (opened, closed or switched something) (CUX-3)
##   pad-dead         something that does nothing takes focus: a label, a card, a disabled control (CUX-7)
##   pad-unreachable  a control on screen the D-pad can't get to from where focus is (CUX-9)
##   pad-offscreen    a control the pad reaches that can't be shown whole (no scroller brings it in) (CUX-8)
##   pad-scroll       a scroller with controls in it that doesn't follow focus (CUX-8)
##   pad-double       a control that isn't focused wears the focus look (accent ring) (CUX-1, CUX-2)
##   pad-nofocus      controls on screen but nothing focused (CUX-6)
##   pad-target       a touch target under 48 x 48 layout px (CUX-13)
##
## Opting out is per node and must say why (the walk prints it in its stats):
##   meta "ux_stepper"  left / right change the value (a "‹ value ›" stepper, a curve point picker)
##   meta "ux_tab"      a tab strip: focus moving along it shows that tab (tvOS / Android TV tab bars)
##   meta "ux_action"   true: a custom control that does something on A; false: never actionable
##   meta "ux_wrap"     on a container: its items wrap around (a linear list, XAG 112)
##   meta "ux_small_ok" a touch target under 48 px, with the reason as its value
##   meta "ux_modal"    a panel that owns the pad while open (the on-screen keyboard): the rest isn't walked
##   meta "ux_follows"  on a scroller: it follows focus with its own code (the journeys check it on screen)
##   meta "ux_any_key"  a "press any button" countdown: nothing to walk
##   method ux_looks_focused() -> bool: a control that draws its own focus look
##
## Headless and synchronous (no frames): every press is handled before the next.

const Checks := preload("res://tests/layout/layout_checks.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")

const TOL := 4.0
## Two candidates whose gaps differ by less than this are "equally near".
const NEAR := 14.0
## Smallest touch target, layout px (Android 48 dp, Steam Deck's own UI).
const MIN_TARGET := 48.0
## The most presses one screen may take (a walk of a 4K library grid stays bounded).
const MAX_PRESSES := 2400

const DIRS := [
	{"name": "up", "button": JOY_BUTTON_DPAD_UP, "v": Vector2(0, -1), "back": 1},
	{"name": "down", "button": JOY_BUTTON_DPAD_DOWN, "v": Vector2(0, 1), "back": 0},
	{"name": "left", "button": JOY_BUTTON_DPAD_LEFT, "v": Vector2(-1, 0), "back": 3},
	{"name": "right", "button": JOY_BUTTON_DPAD_RIGHT, "v": Vector2(1, 0), "back": 2},
]


class Cand:
	var node: Control
	var rect: Rect2
	var pad: bool          # the D-pad can focus it (FOCUS_ALL)
	var actionable: bool
	var in_scroll: ScrollContainer
	var group: Node
	var chain: Array = []   # scrollers above it, outermost first


## {problems: [{kind, node, text, detail}], stats: {...}}. ctx: {walk: bool (default true)}
static func scan(root: Window, ctx := {}) -> Dictionary:
	var problems: Array[Dictionary] = []
	var stats := {"focusable": 0, "presses": 0, "edges": 0, "opt_outs": []}
	var view := root.get_visible_rect()
	var start: Control = root.gui_get_focus_owner()
	var any_key := _find_meta(root, "ux_any_key")
	if any_key != null:
		# "press any button" (a countdown dialog): every button is its answer, so there is nothing to walk
		stats["opt_outs"].append("%s: %s" % [_where(any_key), str(any_key.get_meta("ux_any_key"))])
		return {"problems": problems, "stats": stats}
	var cands := candidates(root, _modal_of(start))
	stats["focusable"] = cands.size()
	var by_node := {}
	for c in cands:
		by_node[c.node] = c
	# ---- static checks ----------------------------------------------------------
	var any_action := false
	for c in cands:
		var n := c.node
		if c.actionable:
			any_action = true
		else:
			_add(problems, "pad-dead", n, "takes focus (%s) but does nothing: %s" % ["pad and touch" if c.pad else "touch",
				_why_dead(n)])
		if c.pad and c.actionable and not _can_show(c, view):
			_add(problems, "pad-offscreen", n, "at %s, can't be scrolled fully into %s" % [_r(c.rect), _r(_show_area(c, view))])
		if c.actionable and n.mouse_filter != Control.MOUSE_FILTER_IGNORE:
			var m := minf(c.rect.size.x, c.rect.size.y)
			if m + 0.5 < MIN_TARGET and not n.has_meta("ux_small_ok"):
				_add(problems, "pad-target", n, "%dx%d touch target (needs %d)" % [int(c.rect.size.x), int(c.rect.size.y), int(MIN_TARGET)])
	for sc in _scrollers(root):
		if not sc.follow_focus and sc.get_node_or_null("FocusScroll") == null and not sc.has_meta("ux_follows") \
				and _has_pad_focusable(sc, by_node) \
				and not _content_fits(sc):
			_add(problems, "pad-scroll", sc, "controls inside, more content than shows, and it doesn't follow focus")
	for n in _focus_looks(root, cands, start):
		_add(problems, "pad-double", n, "wears the focus look while %s has focus" % (_where(start) if start != null else "nothing"))
	if start == null or not is_instance_valid(start) or not start.is_visible_in_tree():
		if any_action and cands.any(func(c): return c.pad and c.actionable):
			_add(problems, "pad-nofocus", root, "%d controls on screen, none focused" % cands.size())
		return {"problems": problems, "stats": stats}
	if not by_node.has(start):
		_add(problems, "pad-hidden", start, "has focus but isn't on screen (%s)" % _why_hidden(start, root))
	if not bool(ctx.get("walk", true)):
		return {"problems": problems, "stats": stats}
	# ---- the walk -----------------------------------------------------------------
	var scroll0 := _scroll_state(root)
	var holders := _value_holders(root)
	var edges := {}   # Cand -> [Cand or null per dir]
	var aborted := ""
	for c in cands:
		if aborted != "" or not c.pad:
			continue
		if stats["presses"] >= MAX_PRESSES:
			aborted = "stopped after %d presses" % MAX_PRESSES
			break
		var row: Array = [null, null, null, null]
		for di in 4:
			if not is_instance_valid(c.node) or not c.node.is_visible_in_tree():
				break
			c.node.grab_focus()
			if root.gui_get_focus_owner() != c.node:
				break
			var d: Dictionary = DIRS[di]
			var before := _values(holders)
			var shown := _shown(cands)
			_press(root, d["button"])
			stats["presses"] += 1
			var g: Control = root.gui_get_focus_owner()
			var changed := _diff(holders, before)
			var gone := _gone(cands, shown)
			if not gone.is_empty():
				var tab := _is_tab(c.node)
				if not tab:
					_add(problems, "pad-action", c.node, "%s here changed the screen (%s no longer shows)" % [d["name"], _where(gone[0])])
				# put the screen back: the opposite press (tabs), else stop walking this screen
				if g != null and is_instance_valid(g):
					_press(root, DIRS[d["back"]]["button"])
				_restore(holders, before)
				if not _gone(cands, shown).is_empty():
					aborted = "%s from %s changed the screen and the walk couldn't put it back" % [d["name"], _where(c.node)]
					break
				if tab:
					row[di] = by_node.get(g)
				continue
			if not changed.is_empty():
				var node := c.node
				var own := changed.any(func(x): return x == node or (x as Node).is_ancestor_of(node))
				var allowed := own and ((_is_stepper(node) and di >= 2) or _is_tab(node))
				if not allowed:
					_add(problems, "pad-value", node, "%s changed %s" % [d["name"], ", ".join(changed.map(func(x): return _where(x).right(50)))])
				_restore(holders, before)
				if own and _is_stepper(node) and di >= 2:
					continue   # a stepper's left / right is its value, not a move
			if g == null or not is_instance_valid(g):
				_add(problems, "pad-lost", c.node, "%s leaves nothing focused" % d["name"])
				continue
			if g == c.node:
				var near := _nearest_in_line(c, cands, d["v"])
				if not near.is_empty() and not _is_stepper(c.node):
					_add(problems, "pad-stuck", c.node, "%s goes nowhere though %s is right there" % [d["name"], _where(near[0].node)])
				continue
			var gc: Cand = by_node.get(g)
			if gc == null:
				_add(problems, "pad-hidden", c.node, "%s goes to %s, which isn't on screen (%s)" % [d["name"], _where(g), _why_hidden(g, root)])
				continue
			row[di] = gc
			stats["edges"] += 1
			var why := _order_problem(c, gc, cands, d)
			if why != "":
				_add(problems, why.get_slice("|", 0), c.node, why.get_slice("|", 1))
		edges[c] = row
	# ---- reachability ---------------------------------------------------------------
	if aborted == "" and by_node.has(start):
		var seen := {by_node[start]: true}
		var todo: Array = [by_node[start]]
		while not todo.is_empty():
			var c: Cand = todo.pop_back()
			for nxt in edges.get(c, []):
				if nxt != null and not seen.has(nxt):
					seen[nxt] = true
					todo.append(nxt)
		for c in cands:
			if c.pad and c.actionable and not seen.has(c) and _can_show(c, view):
				_add(problems, "pad-unreachable", c.node, "the D-pad can't get here from %s" % _where(start))
	if aborted != "":
		stats["aborted"] = aborted
	# ---- put it all back --------------------------------------------------------------
	_restore_scroll(scroll0)
	if is_instance_valid(start) and start.is_visible_in_tree():
		start.grab_focus()
	return {"problems": problems, "stats": stats}


# ---- what's on screen -------------------------------------------------------------

## Every control on screen that takes focus (pad or touch), not under a sheet;
## inside `scope` only when focus is in a modal panel (meta "ux_modal": the
## on-screen keyboard, a dialog without a full-screen scrim).
static func candidates(root: Window, scope: Node = null) -> Array[Cand]:
	var view := root.get_visible_rect()
	var counter := [0]
	var typed: Array[Checks.Item] = []
	_collect(root, view, false, 1.0, typed, counter)
	var occ := Checks._occluders(typed)
	var out: Array[Cand] = []
	for it in typed:
		var n := it.node
		if n.get_focus_mode_with_override() == Control.FOCUS_NONE or not n.is_visible_in_tree():
			continue
		if n is ScrollContainer or n is ScrollBar:
			continue   # Godot's own: a scroll container takes no focus in our UI; bars scroll by stick
		if scope != null and not scope.is_ancestor_of(n):
			continue
		var sc := _scroll_of(n)
		var vis := it.rect.intersection(it.clip)
		if vis.size.x <= 0.0 or vis.size.y <= 0.0:
			if sc == null:
				continue   # cut away by a clipping parent that doesn't scroll: not on screen at all
			# scrolled away: where it shows once its scrollers follow focus to it
			vis = _project(it.rect, _chain(n)).intersection(view)
			if vis.size.x <= 0.0 or vis.size.y <= 0.0:
				continue
		if _under(it, vis, occ):
			continue
		var c := Cand.new()
		c.node = n
		c.rect = it.rect
		c.pad = n.get_focus_mode_with_override() == Control.FOCUS_ALL
		c.actionable = actionable(n)
		c.in_scroll = sc
		c.group = _group_of(n)
		c.chain = _chain(n)
		out.append(c)
	return out


## layout_checks.gd's _collect, but it keeps going into scrollers scrolled
## wholly out of view (their rows are a scroll away, not gone).
static func _collect(n: Node, clip: Rect2, clipped: bool, alpha: float, out: Array[Checks.Item], counter: Array, z := 0) -> void:
	var c := n as CanvasItem
	if c != null:
		z = (z if c.z_as_relative else 0) + c.z_index
		if not c.visible:
			return
		alpha *= c.modulate.a * (c.self_modulate.a if c is Control and c.get_child_count() == 0 else 1.0)
		if alpha < 0.08:
			return
	if n is Window and n != (n as Window).get_tree().root:
		return
	var ctl := n as Control
	var child_clip := clip
	var child_clipped := clipped
	if ctl != null:
		var r := ctl.get_global_rect()
		if r.size.x > 0.0 and r.size.y > 0.0:
			var it := Checks.Item.new()
			it.node = ctl
			it.rect = r
			it.clip = clip
			it.order = z * 1000000 + counter[0]
			it.clipped = clipped
			it.alpha = alpha
			out.append(it)
		counter[0] += 1
		if ctl.clip_contents or ctl is ScrollContainer:
			child_clip = clip.intersection(r)
			child_clipped = true
			if (child_clip.size.x <= 0.0 or child_clip.size.y <= 0.0) and not ctl is ScrollContainer and _scroll_of(ctl) == null:
				return
	for ch in n.get_children():
		_collect(ch, child_clip, child_clipped, alpha, out, counter, z)


## The modal panel focus is in (meta "ux_modal" on it or an ancestor), or null.
static func _modal_of(n: Node) -> Node:
	var p := n
	while p != null and not p is Window:
		if p.has_meta("ux_modal") and p is CanvasItem and (p as CanvasItem).is_visible_in_tree():
			return p
		p = p.get_parent()
	return null


static func _find_meta(n: Node, meta: String) -> Node:
	if n is CanvasItem and not (n as CanvasItem).visible:
		return null
	if n.has_meta(meta):
		return n
	for ch in n.get_children():
		var f := _find_meta(ch, meta)
		if f != null:
			return f
	return null


static func _under(it: Checks.Item, vis: Rect2, occ: Array[Checks.Item]) -> bool:
	for o in occ:
		if o.order > it.order and not o.node.is_ancestor_of(it.node) and o.node != it.node \
				and not it.node.is_ancestor_of(o.node) and o.rect.intersection(o.clip).grow(1.0).encloses(vis):
			return true
	return false


## True when pressing A (or tapping) does something.
static func actionable(n: Control) -> bool:
	if n.has_meta("ux_action"):
		return bool(n.get_meta("ux_action"))
	if n is BaseButton:
		return not (n as BaseButton).disabled
	if n is LineEdit:
		return (n as LineEdit).editable
	if n is TextEdit:
		return (n as TextEdit).editable
	if n is Range:
		return (n as Range).editable if n is SpinBox or n is Slider else false
	if n is ItemList or n is Tree or n is TabBar:
		return true
	return false


static func _why_dead(n: Control) -> String:
	if n is BaseButton and (n as BaseButton).disabled:
		return "a disabled button"
	return "a %s that doesn't take A" % n.get_class()


## Scrollers above `n`, outermost first.
static func _chain(n: Node) -> Array:
	var out := []
	var p := n.get_parent()
	while p != null:
		if p is ScrollContainer:
			out.push_front(p)
		p = p.get_parent()
	return out


## Where `r` ends up when the scrollers in `chain` (outermost first) scroll the
## least that shows it, the way focus-follow scrolls.
static func _project(r: Rect2, chain: Array) -> Rect2:
	var off := Vector2.ZERO
	for sc in chain:
		var box: Rect2 = (sc as Control).get_global_rect()
		box.position += off
		var rr := Rect2(r.position + off, r.size)
		var d := Vector2.ZERO
		for ax in 2:
			var mode: int = sc.horizontal_scroll_mode if ax == 0 else sc.vertical_scroll_mode
			if mode == ScrollContainer.SCROLL_MODE_DISABLED:
				continue
			if rr.position[ax] < box.position[ax] or rr.size[ax] > box.size[ax]:
				d[ax] = box.position[ax] - rr.position[ax]
			elif rr.end[ax] > box.end[ax]:
				d[ax] = box.end[ax] - rr.end[ax]
		off += d
	return Rect2(r.position + off, r.size)


## a's and b's rects in one frame: each scrolled (as focus-follow would) only by
## the scrollers the other isn't in, so things in one list keep their spacing.
static func _pair(a: Cand, b: Cand) -> Array:
	var ca := a.chain.filter(func(s): return not s in b.chain)
	var cb := b.chain.filter(func(s): return not s in a.chain)
	return [_project(a.rect, ca) if not ca.is_empty() else a.rect, _project(b.rect, cb) if not cb.is_empty() else b.rect]


static func _scroll_of(n: Node) -> ScrollContainer:
	var p := n.get_parent()
	while p != null:
		if p is ScrollContainer:
			return p
		p = p.get_parent()
	return null


## The list a control belongs to: its nearest box, grid or flow container that
## holds more than one focusable thing (a button row, a shelf, a grid), else
## its scroller.
static func _group_of(n: Node) -> Node:
	var p := n.get_parent()
	var child := n
	while p != null and not p is Window:
		if (p is BoxContainer or p is GridContainer or p is FlowContainer) and p.get_child_count() > 1:
			var count := 0
			for ch in p.get_children():
				if ch is Control and ch != child and _focusable_inside(ch):
					count += 1
			if count >= 1:
				return p
		if p is ScrollContainer:
			return p
		child = p
		p = p.get_parent()
	return null


static func _focusable_inside(n: Node) -> bool:
	if n is Control and not (n as Control).visible:
		return false
	if n is Control and (n as Control).focus_mode == Control.FOCUS_ALL:
		return true
	for ch in n.get_children():
		if _focusable_inside(ch):
			return true
	return false


# ---- the rules -------------------------------------------------------------------

## "kind|detail" when moving c -> g with direction d breaks the order rules, else "".
static func _order_problem(c: Cand, g: Cand, cands: Array[Cand], d: Dictionary) -> String:
	var v: Vector2 = d["v"]
	var pr := _pair(c, g)
	var along := ((pr[1] as Rect2).get_center() - (pr[0] as Rect2).get_center()).dot(v)
	if along <= TOL:
		if _wraps(c, g, v):
			return ""
		return "pad-direction|%s goes %s to %s" % [d["name"], "back" if along < -TOL else "sideways", _where(g.node)]
	var line := _in_line(c, cands, v)
	if line.is_empty():
		return ""   # nothing straight ahead: any control further that way will do
	var best := INF
	for x in line:
		best = minf(best, _gap_to(c, x, v))
	var near: Array = line.filter(func(x): return _gap_to(c, x, v) <= best + NEAR)
	if g in near:
		return ""
	# entering a tab strip lands on the tab that is open (Android TV top and side navigation)
	if _is_tab(g.node) and g.node is BaseButton and (g.node as BaseButton).button_pressed and not _shares_group(c, g):
		return ""
	# entering another list may land on the item that list remembers (shelves, tvOS / Leanback rows)
	if g.group != null and g.group != c.group and not _shares_group(c, g) \
			and near.any(func(x): return x.group == g.group):
		return ""
	if g in line:
		return "pad-skip|%s jumps to %s over %s" % [d["name"], _where(g.node), _where(near[0].node)]
	return "pad-order|%s goes to %s, off its line, though %s is next in line" % [d["name"], _where(g.node), _where(near[0].node)]


static func _shares_group(c: Cand, g: Cand) -> bool:
	return c.group != null and (c.group == g.group or c.group.is_ancestor_of(g.node))


static func _gap_to(c: Cand, x: Cand, v: Vector2) -> float:
	var pr := _pair(c, x)
	return _gap(pr[0], pr[1], v)


## Candidates straight ahead of c in direction v (their span across overlaps c's).
static func _in_line(c: Cand, cands: Array[Cand], v: Vector2) -> Array:
	var out := []
	for x in cands:
		if x == c or not x.pad or not x.actionable:
			continue
		var pr := _pair(c, x)
		var a: Rect2 = pr[0]
		var b: Rect2 = pr[1]
		if (b.get_center() - a.get_center()).dot(v) <= TOL:
			continue
		if _gap(a, b, v) < -minf(_len(a, v), _len(b, v)) * 0.5:
			continue   # mostly overlapping along the axis: not "ahead"
		if _overlap_across(a, b, v) > minf(8.0, minf(_across(a, v), _across(b, v)) * 0.25):
			out.append(x)
	return out


static func _nearest_in_line(c: Cand, cands: Array[Cand], v: Vector2) -> Array:
	var line := _in_line(c, cands, v)
	line.sort_custom(func(a, b): return _gap_to(c, a, v) < _gap_to(c, b, v))
	return line


## Distance from a's far edge to b's near edge along v.
static func _gap(a: Rect2, b: Rect2, v: Vector2) -> float:
	if v.x > 0: return b.position.x - a.end.x
	if v.x < 0: return a.position.x - b.end.x
	if v.y > 0: return b.position.y - a.end.y
	return a.position.y - b.end.y


static func _len(r: Rect2, v: Vector2) -> float:
	return r.size.x if v.x != 0 else r.size.y


static func _across(r: Rect2, v: Vector2) -> float:
	return r.size.y if v.x != 0 else r.size.x


static func _overlap_across(a: Rect2, b: Rect2, v: Vector2) -> float:
	if v.x != 0:
		return minf(a.end.y, b.end.y) - maxf(a.position.y, b.position.y)
	return minf(a.end.x, b.end.x) - maxf(a.position.x, b.position.x)


## A wrap: both in the same list that says it wraps, g at the far end.
static func _wraps(c: Cand, g: Cand, _v: Vector2) -> bool:
	var p := c.node.get_parent()
	while p != null and not p is Window:
		if p.has_meta("ux_wrap") and p.is_ancestor_of(g.node):
			return true
		p = p.get_parent()
	return false


static func _is_stepper(n: Node) -> bool:
	return n is Slider or n is SpinBox or n.has_meta("ux_stepper")


static func _is_tab(n: Node) -> bool:
	if n.has_meta("ux_tab"):
		return true
	return n is Button and String((n as Button).theme_type_variation) in ["SectionTab", "TabButton"]


## Whether a control can be shown whole. Along an axis some scroller above it
## scrolls, it must fit that scroller (the smallest such); along the others it
## must sit inside every clipping parent and the window.
static func _can_show(c: Cand, view: Rect2) -> bool:
	var lo := Vector2(-INF, -INF)
	var hi := Vector2(INF, INF)
	var lim := view.size + Vector2(TOL, TOL) * 2.0
	var scrolled := [false, false]
	var p := c.node.get_parent()
	while p != null and not p is Window:
		var ctl := p as Control
		if ctl != null and (ctl.clip_contents or ctl is ScrollContainer):
			var pr := ctl.get_global_rect().grow(TOL)
			var sc := ctl as ScrollContainer
			for ax in 2:
				var scrolls := sc != null and (sc.horizontal_scroll_mode if ax == 0 else sc.vertical_scroll_mode) != ScrollContainer.SCROLL_MODE_DISABLED
				if scrolls:
					scrolled[ax] = true
					lim[ax] = minf(lim[ax], pr.size[ax])
				elif not scrolled[ax]:
					lo[ax] = maxf(lo[ax], pr.position[ax])
					hi[ax] = minf(hi[ax], pr.end[ax])
		p = p.get_parent()
	for ax in 2:
		if scrolled[ax]:
			if c.rect.size[ax] > lim[ax] + TOL:
				return false
		else:
			lo[ax] = maxf(lo[ax], view.position[ax] - TOL)
			hi[ax] = minf(hi[ax], view.end[ax] + TOL)
			if c.rect.position[ax] < lo[ax] - TOL or c.rect.end[ax] > hi[ax] + TOL:
				return false
	return true


## For messages: the box the control has to fit (its scroller's, or the window).
static func _show_area(c: Cand, view: Rect2) -> Rect2:
	return c.in_scroll.get_global_rect() if c.in_scroll != null else view


static func _scrolled_axes(n: Node) -> Vector2i:
	var out := Vector2i.ZERO
	var p := n.get_parent()
	while p != null and not p is Window:
		if p is ScrollContainer:
			if (p as ScrollContainer).horizontal_scroll_mode != ScrollContainer.SCROLL_MODE_DISABLED:
				out.x = 1
			if (p as ScrollContainer).vertical_scroll_mode != ScrollContainer.SCROLL_MODE_DISABLED:
				out.y = 1
		p = p.get_parent()
	return out


static func _why_hidden(n: Control, root: Window) -> String:
	if not n.is_visible_in_tree():
		return "hidden"
	var p: Node = n
	var a := 1.0
	while p != null and p is CanvasItem:
		a *= (p as CanvasItem).modulate.a
		p = p.get_parent()
	if a < 0.08:
		return "faded out"
	var r := n.get_global_rect()
	if not root.get_visible_rect().intersects(r):
		return "outside the window"
	return "under another panel"


static func _scrollers(n: Node) -> Array:
	var out := []
	if n is CanvasItem and not (n as CanvasItem).visible:
		return out
	if n is ScrollContainer:
		out.append(n)
	for ch in n.get_children():
		out.append_array(_scrollers(ch))
	return out


static func _has_pad_focusable(sc: ScrollContainer, by_node: Dictionary) -> bool:
	for n in by_node:
		var c: Cand = by_node[n]
		if c.pad and c.actionable and c.in_scroll == sc:
			return true
	return false


static func _content_fits(sc: ScrollContainer) -> bool:
	var v := sc.get_v_scroll_bar()
	var h := sc.get_h_scroll_bar()
	return (v == null or v.max_value - v.page <= 1.0) and (h == null or h.max_value - h.page <= 1.0)


# ---- the focus look -------------------------------------------------------------------

## Controls on screen that look focused but aren't: a ring of the focus colour
## (2 px or more), the way the theme draws focus, or their own say-so.
static func _focus_looks(root: Window, cands: Array[Cand], focused: Control) -> Array:
	var out := []
	var ring: Color = ThemeLib.color("ring")
	var acc: Color = ThemeLib.color("accent")
	for c in cands:
		var n := c.node
		if n == focused:
			continue
		if n.has_method("ux_looks_focused"):
			if bool(n.call("ux_looks_focused")):
				out.append(n)
			continue
		var sb := _drawn_box(n)
		if sb is StyleBoxFlat and _ringlike(sb as StyleBoxFlat, ring, acc):
			out.append(n)
	return out


static func _drawn_box(n: Control) -> StyleBox:
	if n is BaseButton:
		var b := n as BaseButton
		var st := "normal"
		if b.disabled:
			st = "disabled"
		elif b.button_pressed and b.toggle_mode:
			st = "hover_pressed" if b.is_hovered() else "pressed"
		elif b.is_hovered():
			st = "hover"
		return n.get_theme_stylebox(st)
	if n is PanelContainer or n is Panel:
		return n.get_theme_stylebox("panel")
	return null


static func _ringlike(sb: StyleBoxFlat, ring: Color, acc: Color) -> bool:
	var w := maxi(maxi(sb.border_width_left, sb.border_width_right), maxi(sb.border_width_top, sb.border_width_bottom))
	var all_sides := mini(mini(sb.border_width_left, sb.border_width_right), mini(sb.border_width_top, sb.border_width_bottom)) >= 2
	if w < 2 or not all_sides or sb.border_color.a < 0.5:
		return false
	return _near(sb.border_color, ring) or _near(sb.border_color, acc)


static func _near(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b) < 0.18


# ---- values and state -------------------------------------------------------------------

## Everything on screen that holds a value a press could change.
static func _value_holders(n: Node, out: Array = []) -> Array:
	if n is CanvasItem and not (n as CanvasItem).is_visible_in_tree():
		return out
	if n is Window and n != (n as Window).get_tree().root:
		return out
	if n is Range and not n is ScrollBar:
		out.append(n)
	elif n is BaseButton and (n as BaseButton).toggle_mode:
		out.append(n)
	elif n is TabBar or n is TabContainer or n is OptionButton or n is LineEdit:
		out.append(n)
	elif n.has_method("ux_value") or _is_choice_row(n):
		out.append(n)
	for ch in n.get_children():
		_value_holders(ch, out)
	return out


static func _is_choice_row(n: Node) -> bool:
	var s: Script = n.get_script()
	return s != null and s.resource_path.ends_with("/ui/choice_row.gd")


static func _value_of(n: Node) -> Variant:
	if not is_instance_valid(n):
		return null
	if n.has_method("ux_value"):
		return n.call("ux_value")
	if _is_choice_row(n):
		return n.get("index")
	if n is Range:
		return (n as Range).value
	if n is OptionButton:
		return (n as OptionButton).selected
	if n is BaseButton:
		return (n as BaseButton).button_pressed
	if n is TabBar:
		return (n as TabBar).current_tab
	if n is TabContainer:
		return (n as TabContainer).current_tab
	if n is LineEdit:
		return (n as LineEdit).text
	return null


static func _values(holders: Array) -> Array:
	return holders.map(func(h): return _value_of(h))


static func _diff(holders: Array, before: Array) -> Array:
	var out := []
	for i in holders.size():
		if is_instance_valid(holders[i]) and _value_of(holders[i]) != before[i]:
			out.append(holders[i])
	return out


static func _restore(holders: Array, before: Array) -> void:
	for i in holders.size():
		var n: Node = holders[i]
		if not is_instance_valid(n) or _value_of(n) == before[i]:
			continue
		var v: Variant = before[i]
		if n.has_method("ux_restore"):
			n.call("ux_restore", v)
		elif _is_choice_row(n):
			n.set("index", int(v))
			n.call("_refresh")
			n.emit_signal("changed", n.call("value"))
		elif n is Range:
			(n as Range).value = float(v)
		elif n is OptionButton:
			(n as OptionButton).select(int(v))
		elif n is BaseButton:
			(n as BaseButton).button_pressed = bool(v)
		elif n is TabBar:
			(n as TabBar).current_tab = int(v)
		elif n is TabContainer:
			(n as TabContainer).current_tab = int(v)
		elif n is LineEdit:
			(n as LineEdit).text = str(v)


## Which candidates outside scrollers show (a scroller recycling its rows isn't a new screen).
static func _shown(cands: Array[Cand]) -> Dictionary:
	var out := {}
	for c in cands:
		if c.in_scroll == null:
			out[c] = is_instance_valid(c.node) and c.node.is_visible_in_tree()
	return out


static func _gone(cands: Array[Cand], shown: Dictionary) -> Array:
	var out := []
	for c in shown:
		if shown[c] and (not is_instance_valid(c.node) or not c.node.is_visible_in_tree()):
			out.append(c.node)
	return out


static func _scroll_state(root: Node) -> Array:
	var out := []
	for sc in _scrollers(root):
		out.append([sc, sc.scroll_horizontal, sc.scroll_vertical])
	return out


static func _restore_scroll(state: Array) -> void:
	for s in state:
		if is_instance_valid(s[0]):
			s[0].scroll_horizontal = s[1]
			s[0].scroll_vertical = s[2]


static func _press(root: Window, button: JoyButton) -> void:
	var e := InputEventJoypadButton.new()
	e.device = 0
	e.button_index = button
	e.pressed = true
	e.pressure = 1.0
	root.push_input(e)
	var u := InputEventJoypadButton.new()
	u.device = 0
	u.button_index = button
	u.pressed = false
	root.push_input(u)
	_finish_tweens(root)


## Runs every running (finite) tween to its end, so a fade or glide a press
## started is over before the next press: the walk sees what a player sees
## once the screen settles.
static func _finish_tweens(root: Window) -> void:
	for t in root.get_tree().get_processed_tweens():
		if t.is_valid() and t.is_running() and t.get_loops_left() != -1:
			t.custom_step(10.0)


# ---- helpers -----------------------------------------------------------------------------

static func _r(r: Rect2) -> String:
	return "%d,%d %dx%d" % [int(r.position.x), int(r.position.y), int(r.size.x), int(r.size.y)]


static func _where(n: Variant) -> String:
	if n == null or not is_instance_valid(n):
		return "(gone)"
	var parts := PackedStringArray()
	var p: Node = n
	while p != null and parts.size() < 5 and not p is Window:
		parts.insert(0, String(p.name))
		p = p.get_parent()
	var t := Checks._txt(n)
	return "/".join(parts) + (" \"%s\"" % t.left(30) if t != "" else "")


static func _add(problems: Array[Dictionary], kind: String, n: Variant, detail: String) -> void:
	problems.append({"kind": kind, "node": Checks._where(n) if is_instance_valid(n) else "", "text": Checks._txt(n).left(60) if is_instance_valid(n) else "", "detail": detail})
