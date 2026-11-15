extends RefCounted
## D-pad order for the installer's pages, from where the controls are on screen (pure: rects in, indices
## out, so it is tested with made-up layouts; installer_screen.gd applies it to the real controls).
##
##  - Left / Right move along the row the control is in, in screen order, and nothing else. When the row has
##    nothing further that way, to the next column (the control nearest in height); never wrapping.
##  - Up / Down move to the nearest row above / below, in the same column when there is one there.
##  - The buttons under the page (Back, Skip, Continue; kind NAV) are one row below everything: Down from the
##    last row goes to Continue (the primary one), Up from them to the first control at the top of the page.
##
## A control never moves anything but focus: nothing here changes a choice (that is A's job).

const ITEM := 0
const NAV := 1


## kinds[i]: ITEM | NAV, rects[i]: the control's rect on screen. Returns per control {"left","right","up","down"}
## as indices (-1 = stay where it is).
static func neighbors(kinds: Array, rects: Array) -> Array:
	var n := rects.size()
	var out: Array = []
	var items: Array = []
	var navs: Array = []
	for i in n:
		(navs if kinds[i] == NAV else items).append(i)
	var primary: int = navs[-1] if not navs.is_empty() else -1
	for i in n:
		var d := {"left": -1, "right": -1, "up": -1, "down": -1}
		var pool: Array = navs if kinds[i] == NAV else items
		d["left"] = _sideways(i, pool, rects, -1)
		d["right"] = _sideways(i, pool, rects, 1)
		if kinds[i] == NAV:
			d["up"] = items[0] if not items.is_empty() else -1
		else:
			d["up"] = _vertical(i, items, rects, -1)
			d["down"] = _vertical(i, items, rects, 1)
			if d["down"] == -1:
				d["down"] = primary
		out.append(d)
	return out


static func _cy(r: Rect2) -> float:
	return r.position.y + r.size.y * 0.5


static func _cx(r: Rect2) -> float:
	return r.position.x + r.size.x * 0.5


## Share of the shorter one's height that two rects have in common (0..1).
static func _row_overlap(a: Rect2, b: Rect2) -> float:
	var top := maxf(a.position.y, b.position.y)
	var bottom := minf(a.end.y, b.end.y)
	return maxf(0.0, bottom - top) / maxf(1.0, minf(a.size.y, b.size.y))


static func _col_overlap(a: Rect2, b: Rect2) -> float:
	var left := maxf(a.position.x, b.position.x)
	var right := minf(a.end.x, b.end.x)
	return maxf(0.0, right - left) / maxf(1.0, minf(a.size.x, b.size.x))


static func _sideways(i: int, pool: Array, rects: Array, dir: int) -> int:
	var r: Rect2 = rects[i]
	var best := -1
	var best_d := INF
	# the same row first
	for j in pool:
		if j == i or _row_overlap(r, rects[j]) < 0.5:
			continue
		var dx := (_cx(rects[j]) - _cx(r)) * dir
		if dx > 0.0 and dx < best_d:
			best = j
			best_d = dx
	if best != -1:
		return best
	# nothing further along the row: the next column, the control nearest in height
	var best_dy := INF
	for j in pool:
		if j == i or _col_overlap(r, rects[j]) > 0.0:
			continue
		var beyond: bool = (rects[j].position.x >= r.end.x - 1.0) if dir > 0 else (rects[j].end.x <= r.position.x + 1.0)
		if not beyond:
			continue
		var dy := absf(_cy(rects[j]) - _cy(r))
		var dx2 := absf(_cx(rects[j]) - _cx(r))
		if dy < best_dy - 0.5 or (absf(dy - best_dy) <= 0.5 and dx2 < best_d):
			best = j
			best_dy = dy
			best_d = dx2
	return best


static func _vertical(i: int, pool: Array, rects: Array, dir: int) -> int:
	var r: Rect2 = rects[i]
	var cand: Array = []
	var min_dy := INF
	for j in pool:
		if j == i or _row_overlap(r, rects[j]) >= 0.5:
			continue
		var dy := (_cy(rects[j]) - _cy(r)) * dir
		if dy <= 0.0:
			continue
		cand.append(j)
	if cand.is_empty():
		return -1
	# only in the control's own column: past the end of it the page's buttons are next, not another column
	var from: Array = cand.filter(func(j): return _col_overlap(r, rects[j]) > 0.0)
	if from.is_empty():
		return -1
	for j in from:
		min_dy = minf(min_dy, (_cy(rects[j]) - _cy(r)) * dir)
	var best := -1
	var best_dx := INF
	for j in from:
		var dy := (_cy(rects[j]) - _cy(r)) * dir
		if dy - min_dy > minf(r.size.y, rects[j].size.y) * 0.5:
			continue
		var dx := absf(_cx(rects[j]) - _cx(r))
		if dx < best_dx:
			best = j
			best_dx = dx
	return best
