extends RefCounted
## Layout checks for one screen as it stands right now (tools/layout/run.gd
## calls scan() after every shot, on every layout of tests/layout/matrix.gd).
## Geometry only: it works headless, nothing is rendered.
##
##   outside     a label, button or focusable control reaches past the window
##               (and isn't inside something that scrolls or clips)
##   cut         text that doesn't fit its own box: clipped lines, a button
##               narrower than its text
##   ellipsis    a label cut short with "…" while its row has room to spare
##   overlap     two texts drawn over each other
##   focus       the focused control (and its ring) isn't fully on screen
##   small       text under the smallest readable size for this layout's screens
##   stretched   art drawn at the wrong aspect
##   blurry      a bitmap icon or picture drawn well above its own resolution
##               at this layout's sharpest scale (4K)
##   tile        a game cover bigger than a cover should be (grids add columns)
##   wide        a line of text or a row of settings too wide to read (ultrawide)
##
## Controls under an opaque panel drawn later (a sheet over a screen) aren't on
## screen for these purposes.

const RING := 4.0          # focus ring + a little glow, layout px
const TOL := 1.5
const MAX_TEXT_LINE := 1400.0
const MAX_ROW := 1500.0
const BLUR_RATIO := 0.62   # texture px per screen px below this = visibly soft
## Pictures that are blurred on purpose (the backdrop is a 320 px wash of the art).
const SOFT_BY_DESIGN: Array[String] = ["/Backdrop/", "/LaunchOverlay/Card/From"]
## Controls that paint their own dimming layer over everything behind them.
const SCRIM_SCRIPTS: Array[String] = ["/ui/games/sheet.gd", "/ui/low_battery_dialog.gd"]


class Item:
	var node: Control
	var rect: Rect2          # global, layout px
	var clip: Rect2          # what its clipping ancestors leave of the window
	var order: int
	var clipped: bool        # has a scrolling / clipping ancestor
	var alpha: float


## {problems: [{kind, node, text, detail}], stats: {...}}.
## ctx: {scale: float, min_font_px: float, ignore: [name parts]}
static func scan(root: Window, ctx: Dictionary) -> Dictionary:
	var view := root.get_visible_rect()
	var items: Array[Item] = []
	var counter := [0]
	_collect(root, view, false, 1.0, items, counter)
	var occluders := _occluders(items)
	var problems: Array[Dictionary] = []
	var texts: Array[Item] = []
	var scale := float(ctx.get("scale", 1.0))
	var min_px := float(ctx.get("min_font_px", 0.0))
	var stats := {"controls": items.size(), "texts": 0, "smallest_font": 999.0, "tiles": 0}
	for it in items:
		var n := it.node
		if _covered(it, occluders):
			continue
		var is_text := (n is Label and (n as Label).text.strip_edges() != "") or (n is Button and (n as Button).text.strip_edges() != "") \
			or (n is RichTextLabel and (n as RichTextLabel).get_parsed_text().strip_edges() != "") or n is LineEdit
		var matters := is_text or n.focus_mode != Control.FOCUS_NONE or n is Range
		if matters and not it.clipped and not _inside(view, it.rect):
			_add(problems, "outside", n, "reaches %s, window is %s" % [_r(it.rect), _r(view)])
		if is_text:
			stats["texts"] += 1
			var px := _font_px(n)
			stats["smallest_font"] = minf(stats["smallest_font"], px)
			if min_px > 0.0 and px + 0.01 < min_px:
				_add(problems, "small", n, "%d px text; this screen needs %.1f" % [int(px), min_px])
			_text_fit(it, problems)
			if it.clip.intersects(it.rect):
				texts.append(it)
			if n is Label and (n as Label).autowrap_mode != TextServer.AUTOWRAP_OFF and it.rect.size.x > MAX_TEXT_LINE \
					and _line_px(n as Label) > MAX_TEXT_LINE:
				_add(problems, "wide", n, "a %d px line of text" % int(_line_px(n as Label)))
		if n.focus_mode != Control.FOCUS_NONE and n is Button and it.rect.size.x > MAX_ROW and not n.has_meta("layout_wide_ok"):
			_add(problems, "wide", n, "a %d px wide row" % int(it.rect.size.x))
		if n is TextureRect:
			_texture(it, scale, problems)
		if n is Button and (n as Button).icon != null:
			_icon(it, (n as Button).icon, scale, problems)
		if _is_tile(n):
			stats["tiles"] += 1
			var base: Vector2 = n.get_script().get("SIZE")
			if it.rect.size.x > base.x * 1.45 + 1.0:
				_add(problems, "tile", n, "cover %d px wide (base %d): add a column instead" % [int(it.rect.size.x), int(base.x)])
			if it.rect.size.y > view.size.y * 0.62:
				_add(problems, "tile", n, "cover %d px tall on a %d px screen" % [int(it.rect.size.y), int(view.size.y)])
	_overlaps(texts, occluders, problems)
	var f := root.gui_get_focus_owner()
	if f != null and f.is_visible_in_tree():
		var fr := f.get_global_rect().grow(RING)
		var clip := view
		var p := f.get_parent()
		while p != null:
			# a ring may spill over its own scroller's padding; the window and any clipping parent must hold it
			if p is Control and ((p as Control).clip_contents or p is ScrollContainer):
				clip = clip.intersection((p as Control).get_global_rect().grow(RING + 2.0))
			p = p.get_parent()
		# a card taller than its scroller can't fit; a control scrolled wholly away isn't the
		# state a player sees (FocusScroll follows focus; its own tests cover that)
		var fits := fr.size.x <= clip.size.x + TOL and fr.size.y <= clip.size.y + TOL
		if fits and clip.intersects(fr) and not _inside(clip.grow(TOL), fr):
			_add(problems, "focus", f, "focus ring %s leaves %s" % [_r(fr), _r(clip)])
	else:
		stats["no_focus"] = true
	return {"problems": problems, "stats": stats}


# ---- collecting ---------------------------------------------------------------

static func _collect(n: Node, clip: Rect2, clipped: bool, alpha: float, out: Array[Item], counter: Array, z := 0) -> void:
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
			var it := Item.new()
			it.node = ctl
			it.rect = r
			it.clip = clip
			it.order = z * 1000000 + counter[0]   # what draws later: z first, then tree order
			it.clipped = clipped
			it.alpha = alpha
			out.append(it)
		counter[0] += 1
		if ctl.clip_contents or ctl is ScrollContainer:
			child_clip = clip.intersection(r)
			child_clipped = true
			if child_clip.size.x <= 0.0 or child_clip.size.y <= 0.0:
				return
	for ch in n.get_children():
		_collect(ch, child_clip, child_clipped, alpha, out, counter, z)


## Panels and colour fills solid enough to hide what is under them.
static func _occluders(items: Array[Item]) -> Array[Item]:
	var out: Array[Item] = []
	for it in items:
		var n := it.node
		var a := 0.0
		if n is ColorRect:
			a = (n as ColorRect).color.a
		elif n is PanelContainer or n is Panel:
			var sb := n.get_theme_stylebox("panel")
			if sb is StyleBoxFlat:
				a = (sb as StyleBoxFlat).bg_color.a
			elif sb is StyleBoxTexture:
				a = 1.0
		var sc: Script = n.get_script()
		if sc != null:
			for part in SCRIM_SCRIPTS:
				if sc.resource_path.ends_with(part):
					a = 1.0
		if a * it.alpha >= 0.45 and it.rect.size.x > 60.0 and it.rect.size.y > 24.0:
			out.append(it)
	return out


static func _covered(it: Item, occluders: Array[Item]) -> bool:
	var vis := it.rect.intersection(it.clip)
	for o in occluders:
		if o.order > it.order and not o.node.is_ancestor_of(it.node) and o.node != it.node \
				and o.rect.intersection(o.clip).grow(1.0).encloses(vis):
			return true
	return false


# ---- text ---------------------------------------------------------------------

static func _font_px(n: Control) -> float:
	if n is RichTextLabel:
		return float(n.get_theme_font_size("normal_font_size"))
	return float(n.get_theme_font_size("font_size"))


static func _line_px(l: Label) -> float:
	var f := l.get_theme_font("font")
	var widest := 0.0
	var ps := TextParagraph.new()
	ps.add_string(l.atr(l.text).to_upper() if l.uppercase else l.atr(l.text), f, l.get_theme_font_size("font_size"))
	ps.width = l.size.x
	for i in ps.get_line_count():
		widest = maxf(widest, ps.get_line_width(i))
	return widest


static func _text_fit(it: Item, problems: Array[Dictionary]) -> void:
	var n := it.node
	if n is Label:
		var l := n as Label
		var shown := l.atr(l.text).to_upper() if l.uppercase else l.atr(l.text)
		var f := l.get_theme_font("font")
		var fs := l.get_theme_font_size("font_size")
		var sb := l.get_theme_stylebox("normal")
		var pad := sb.get_minimum_size() if sb != null else Vector2.ZERO
		if l.autowrap_mode == TextServer.AUTOWRAP_OFF:
			var need := 0.0
			for line in shown.split("\n"):
				need = maxf(need, f.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x)
			var room := l.size.x - pad.x
			if need > room + TOL:
				if l.clip_text or l.text_overrun_behavior != TextServer.OVERRUN_NO_TRIMMING:
					# cut short on purpose: only wrong when the row had the room
					var spare := _spare_width(l)
					if spare >= need - room - TOL:
						_add(problems, "ellipsis", n, "cut to %d of %d px with %d px free beside it" % [int(room), int(need), int(spare)])
				else:
					_add(problems, "cut", n, "text needs %d px, the label is %d" % [int(need), int(room)])
		else:
			var lines := l.get_line_count()
			var vis := l.get_visible_line_count()
			var capped := l.max_lines_visible > 0 and lines > l.max_lines_visible
			if vis < lines and not capped:
				_add(problems, "cut", n, "%d of %d lines fit" % [vis, lines])
			elif capped and l.text_overrun_behavior == TextServer.OVERRUN_NO_TRIMMING:
				_add(problems, "cut", n, "%d lines, %d shown, no ellipsis" % [lines, l.max_lines_visible])
		# the label's own box cut by a clipping parent (not a scroller: those scroll)
		if it.clipped and not _in_scroll(l):
			var vr := it.rect.intersection(it.clip)
			if vr.size.x > 0.0 and vr.size.y > 0.0 and (vr.size.x < it.rect.size.x - TOL or vr.size.y < it.rect.size.y - TOL) \
					and not l.has_meta("layout_clip_ok"):
				_add(problems, "cut", n, "label %s clipped to %s by a parent" % [_r(it.rect), _r(vr)])
	elif n is Button:
		var b := n as Button
		var need_b := b.get_minimum_size().x
		if b.size.x + TOL < need_b and not b.clip_text and b.text_overrun_behavior == TextServer.OVERRUN_NO_TRIMMING:
			_add(problems, "cut", n, "button needs %d px, has %d" % [int(need_b), int(b.size.x)])
		elif (b.clip_text or b.text_overrun_behavior != TextServer.OVERRUN_NO_TRIMMING) and b.text != "":
			var f2 := b.get_theme_font("font")
			var w := f2.get_string_size(b.atr(b.text), HORIZONTAL_ALIGNMENT_LEFT, -1, b.get_theme_font_size("font_size")).x
			var sbn := b.get_theme_stylebox("normal")
			var room2 := b.size.x - (sbn.get_minimum_size().x if sbn != null else 0.0) \
				- (float(b.icon.get_width()) + float(b.get_theme_constant("h_separation")) if b.icon != null else 0.0)
			if w > room2 + TOL:
				var spare2 := _spare_width(b)
				if spare2 >= w - room2 - TOL:
					_add(problems, "ellipsis", n, "button text cut to %d of %d px with %d px free beside it" % [int(room2), int(w), int(spare2)])


static func _in_scroll(n: Node) -> bool:
	var p := n.get_parent()
	while p != null:
		if p is ScrollContainer:
			return true
		p = p.get_parent()
	return false


## Free width in the row a control sits in: what its box container hands to
## plain spacers, plus the gap to the container's edge.
static func _spare_width(c: Control) -> float:
	var p := c.get_parent() as Control
	if p == null:
		return 0.0
	var spare := 0.0
	if p is HBoxContainer:
		for s in p.get_children():
			var sc := s as Control
			if sc != null and sc != c and sc.visible and sc.get_child_count() == 0 and sc.get_class() == "Control" \
					and sc.get_script() == null:
				spare += sc.size.x
	return spare


static func _text_rect(it: Item) -> Rect2:
	var n := it.node
	var r := it.rect
	if n is Label:
		var l := n as Label
		if l.autowrap_mode == TextServer.AUTOWRAP_OFF and not l.clip_text:
			var f := l.get_theme_font("font")
			var shown := l.atr(l.text).to_upper() if l.uppercase else l.atr(l.text)
			var w := 0.0
			for line in shown.split("\n"):
				w = maxf(w, f.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, l.get_theme_font_size("font_size")).x)
			w = minf(w, r.size.x) if w > 0.0 else r.size.x
			var sx := l.get_global_transform().get_scale().x
			w *= sx
			match l.horizontal_alignment:
				HORIZONTAL_ALIGNMENT_CENTER: r = Rect2(r.position.x + (r.size.x - w) / 2.0, r.position.y, w, r.size.y)
				HORIZONTAL_ALIGNMENT_RIGHT: r = Rect2(r.end.x - w, r.position.y, w, r.size.y)
				_: r = Rect2(r.position.x, r.position.y, w, r.size.y)
	return r.intersection(it.clip)


static func _overlaps(texts: Array[Item], occluders: Array[Item], problems: Array[Dictionary]) -> void:
	var rects: Array[Rect2] = []
	for t in texts:
		rects.append(_text_rect(t).grow(-2.0))
	var said := {}
	for i in texts.size():
		var a := rects[i]
		if a.size.x <= 0.0 or a.size.y <= 0.0 or not texts[i].node is Label:
			continue
		for j in range(i + 1, texts.size()):
			var b := rects[j]
			if b.size.x <= 0.0 or b.size.y <= 0.0 or not texts[j].node is Label:
				continue
			var x := a.intersection(b)
			if x.size.x < 3.0 or x.size.y < 3.0:
				continue
			var na := texts[i].node
			var nb := texts[j].node
			if na.is_ancestor_of(nb) or nb.is_ancestor_of(na) or na.has_meta("layout_overlap_ok") or nb.has_meta("layout_overlap_ok"):
				continue
			if said.has(na) or said.has(nb):
				continue
			# a panel drawn over the earlier text hides that part of it (a sheet over the top bar)
			var first := texts[i] if texts[i].order < texts[j].order else texts[j]
			var hidden := false
			for o in occluders:
				if o.order > first.order and not o.node.is_ancestor_of(first.node) and o.rect.intersection(o.clip).grow(1.0).encloses(x):
					hidden = true
					break
			if hidden:
				continue
			said[na] = true
			_add(problems, "overlap", na, "over \"%s\" (%s) by %dx%d px" % [_txt(nb).left(40), _where(nb).right(60), int(x.size.x), int(x.size.y)])


# ---- art ------------------------------------------------------------------------

static func _texture(it: Item, scale: float, problems: Array[Dictionary]) -> void:
	var t := it.node as TextureRect
	var tex := t.texture
	if tex == null or tex is GradientTexture1D or tex is GradientTexture2D or tex is NoiseTexture2D or t.has_meta("layout_art_ok"):
		return
	var ts := Vector2(tex.get_size())
	if ts.x < 2.0 or ts.y < 2.0:
		return
	var rs := it.rect.size
	var drawn := rs
	match t.stretch_mode:
		TextureRect.STRETCH_SCALE:
			var ar := (rs.x / rs.y) / (ts.x / ts.y)
			if (ar > 1.04 or ar < 0.96) and t.material == null:
				_add(problems, "stretched", t, "%dx%d picture drawn %dx%d" % [int(ts.x), int(ts.y), int(rs.x), int(rs.y)])
		TextureRect.STRETCH_KEEP, TextureRect.STRETCH_KEEP_CENTERED:
			drawn = ts
		TextureRect.STRETCH_KEEP_ASPECT, TextureRect.STRETCH_KEEP_ASPECT_CENTERED:
			var k := minf(rs.x / ts.x, rs.y / ts.y)
			drawn = ts * k
		TextureRect.STRETCH_KEEP_ASPECT_COVERED:
			var k2 := maxf(rs.x / ts.x, rs.y / ts.y)
			drawn = ts * k2
	_sharp(t, tex, drawn, scale, problems)


static func _icon(it: Item, tex: Texture2D, scale: float, problems: Array[Dictionary]) -> void:
	var drawn := Vector2(tex.get_size())
	var cap := (it.node as Button).get_theme_constant("icon_max_width")   # a button draws its icon no wider than this
	if cap > 0 and drawn.x > cap:
		drawn *= float(cap) / drawn.x
	_sharp(it.node, tex, drawn, scale, problems)


## A bitmap drawn `drawn` layout px big needs drawn * scale real pixels. SVG
## textures (DPITexture) re-rasterise at the window's scale by themselves.
static func _sharp(n: Control, tex: Texture2D, drawn: Vector2, scale: float, problems: Array[Dictionary]) -> void:
	if tex is DPITexture or tex is AtlasTexture or tex is ViewportTexture or n.has_meta("layout_soft_ok"):
		return
	if n.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST or n.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS:
		return   # hard-edged on purpose (QR codes, pixel art): upscaling doesn't blur it
	var path := str(n.get_path())
	for part in SOFT_BY_DESIGN:
		if part in path:
			return
	var have := float(tex.get_width())
	if tex is ImageTexture or tex is CompressedTexture2D or tex is PortableCompressedTexture2D:
		var need := drawn.x * scale
		if need > 24.0 and have / need < BLUR_RATIO:
			_add(problems, "blurry", n, "%d px wide bitmap drawn %d screen px wide (%.0f %%)" % [int(have), int(need), 100.0 * have / need])


static func _is_tile(n: Node) -> bool:
	var s: Script = n.get_script()
	return s != null and s.resource_path.ends_with("/ui/game_tile.gd")


# ---- helpers ----------------------------------------------------------------------

static func _inside(outer: Rect2, r: Rect2) -> bool:
	return r.position.x >= outer.position.x - TOL and r.position.y >= outer.position.y - TOL \
		and r.end.x <= outer.end.x + TOL and r.end.y <= outer.end.y + TOL


static func _r(r: Rect2) -> String:
	return "%d,%d %dx%d" % [int(r.position.x), int(r.position.y), int(r.size.x), int(r.size.y)]


static func _txt(n: Node) -> String:
	if n is Label:
		return (n as Label).text.replace("\n", " ")
	if n is Button:
		return (n as Button).text
	if n is RichTextLabel:
		return (n as RichTextLabel).get_parsed_text().replace("\n", " ")
	return ""


static func _where(n: Node) -> String:
	var parts := PackedStringArray()
	var p := n
	while p != null and parts.size() < 6 and not p is Window:
		parts.insert(0, String(p.name))
		p = p.get_parent()
	return "/".join(parts)


static func _add(problems: Array[Dictionary], kind: String, n: Node, detail: String) -> void:
	problems.append({"kind": kind, "node": _where(n), "text": _txt(n).left(60), "detail": detail})
