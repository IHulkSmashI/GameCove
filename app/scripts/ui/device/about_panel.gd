extends "res://scripts/ui/device/device_panel.gd"
## About this device: the handheld's picture large on the left, everything
## Device.info() knows in tinted cards on the right (device, chip and drivers,
## memory, storage, screen, battery, software, what works, recommended fixes),
## packed into two columns (shortest column takes the next card, so there are
## no gaps) when there's room, one column on narrow screens.
## Asks for the slow details (Steam build, Proton, free space, Vulkan) once and
## refreshes on Device.info_updated.

const BrandMark := preload("res://scripts/ui/brand_mark.gd")
const QuickMenu := preload("res://scripts/ui/quick_menu.gd")
const Picture := preload("res://scripts/ui/device/device_picture.gd")
const FixTexts := preload("res://scripts/ui/texts.gd")
const Icons := preload("res://scripts/ui/icons.gd")
const PhotoView := preload("res://scripts/ui/device/device_photo_view.gd")

var info: Dictionary = {}
var picture: TextureRect
var _side: VBoxContainer
var _cards: VBoxContainer
var _loading: Label
var _focused_card := ""
## The card grid inside the scrolling column: one or two stacks.
var _grid: HBoxContainer
var _stacks: Array = []
var _card_list: Array = []
## Below this width (the scrolling column's) the cards stack in one column.
const TWO_COLUMNS_W := 760.0
## Rough height of each card in rows, to deal them into balanced columns.
const CARD_WEIGHT := {"device": 7.0, "chip": 7.5, "memory": 4.5, "storage": 4.0, "screen": 6.0,
	"battery": 8.5, "software": 4.5, "support": 9.0, "fixes": 3.0}


static func build(services_: Dictionary) -> Control:
	var p = load("res://scripts/ui/device/about_panel.gd").new()
	p.name = "AboutDevicePanel"
	p.services = services_
	p._build()
	return p


func _build() -> void:
	var dev := svc("device")
	info = dev.info() if dev != null and dev.has_method("info") else _basic_info(dev)
	_side = side_column(0.72)
	_cards = main_column(1.28)
	_grid = Kit.hbox(16)
	_grid.name = "Grid"
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cards.add_child(_grid)
	_grid.resized.connect(_deal)
	_fill_side()
	_fill_cards()
	if dev != null:
		if dev.has_signal("info_updated"):
			listen(dev.info_updated, _on_info)
		if dev.has_method("request_slow_info"):
			dev.request_slow_info()


func _on_info(new_info: Dictionary) -> void:
	info = new_info
	var f := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	_focused_card = String(f.name) if f != null and f in _card_list else ""
	clear_box(_side)
	for c in _card_list:
		if is_instance_valid(c):
			if c.get_parent() != null:
				c.get_parent().remove_child(c)
			c.queue_free()
	_card_list.clear()
	if _loading != null and is_instance_valid(_loading):
		Kit.drop(_cards, _loading)
		_loading = null
	_fill_side()
	_fill_cards()
	if _focused_card != "":
		for c in _card_list:
			if String(c.name) == _focused_card:
				(c as Control).grab_focus()


func _g(section: String) -> Dictionary:
	var d: Variant = info.get(section, {})
	return d if d is Dictionary else {}


# ---- left: picture and the essentials ---------------------------------------------

func _fill_side() -> void:
	var d := _g("device")
	var sup := _g("support")
	var hero := DKit.card("", "handheld", "accent", false)
	var hero_card: PanelContainer = hero[0]
	hero_card.name = "Hero"
	var col: VBoxContainer = hero[1]
	Kit.drop(col, col.get_node("Head"))
	col.add_theme_constant_override("separation", 12)
	picture = Picture.new()
	var pic_path := str(d.get("picture", ""))
	if pic_path == "":
		var dev := svc("device")
		pic_path = dev.picture_for(str(d.get("id", "unknown"))) if dev != null and dev.has_method("picture_for") else ""
	picture.setup(pic_path)
	picture.custom_minimum_size = Vector2(0, 230)
	col.add_child(picture)
	# No drawing for this device: no empty box where it would go.
	picture.visible = picture.texture != null
	_device_photo_hook(col, str(d.get("id", "")))
	# The maker's logo over the name (text only when there's no logo).
	var maker_logo := BrandMark.rect(QuickMenu.maker_name(d, str(d.get("name", ""))), 26)
	if maker_logo != null:
		maker_logo.name = "MakerLogo"
		col.add_child(maker_logo)
	var title := Kit.label(str(d.get("name", Texts.UNKNOWN)), "HeaderLabel", true)
	title.name = "DeviceName"
	title.add_theme_font_override("font", ThemeLib.font("display"))
	col.add_child(title)
	var maker_line := " · ".join(PackedStringArray([str(d.get("maker", "")), str(d.get("model", ""))].filter(func(x): return x != "" and x != str(d.get("name", "")))))
	if maker_line != "":
		col.add_child(Kit.label(maker_line, "QuietLabel", true))
	var level := str(sup.get("level", "generic"))
	var chips := Kit.hbox(8)
	chips.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chips.add_child(DKit.chip(Texts.SUPPORT_LABELS.get(level, level.capitalize()), Texts.SUPPORT_TONES.get(level, ""), "shield"))
	if bool(sup.get("verified", false)):
		chips.add_child(DKit.chip("Verified", "good", "check"))
	col.add_child(chips)
	col.add_child(DKit.quiet(Texts.SUPPORT_LINES.get(level, "")))
	_side.add_child(hero_card)

	# three quick facts
	var facts := Kit.hbox(12)
	facts.name = "Facts"
	facts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bat := _g("battery")
	var st := _g("storage")
	var scr := _g("screen")
	var internal: Dictionary = st.get("internal", {}) if st.get("internal") is Dictionary else {}
	if bool(bat.get("present", false)) and int(bat.get("health_pct", -1)) > 0:
		facts.add_child(_fact("power", "%d%%" % int(bat["health_pct"]), "Battery health"))
	if internal.has("free_gb"):
		facts.add_child(_fact("download", Texts.gb(float(internal["free_gb"])), "Free space"))
	elif internal.has("size_gb"):
		facts.add_child(_fact("download", Texts.gb(float(internal["size_gb"])), "Storage"))
	var hz: Array = scr.get("refresh_hz", []) if scr.get("refresh_hz") is Array else []
	if not hz.is_empty():
		facts.add_child(_fact("screen", "%d Hz" % int(hz[hz.size() - 1]), "Screen"))
	if facts.get_child_count() > 0:
		_side.add_child(facts)


# ---- real device photo (DevicePhoto service) ---------------------------------------
# Kept apart so the panel restyle merges cleanly: with a freely licensed photo
# cached for this device, it stands in for the drawing (which stays in the tree,
# hidden, for the controller highlights) with its credit under it. No photo,
# offline or the setting off: nothing changes. A photo that arrives later
# (photo_ready) rebuilds the side column once.

var photo_view: Control


func _device_photo_hook(col: VBoxContainer, device_id: String) -> void:
	photo_view = null
	var ph := svc("photo")
	if ph == null or not ph.has_method("photo_for") or device_id == "":
		return
	if ph.has_signal("photo_ready"):
		listen(ph.photo_ready, _on_photo_ready)
	var got: Dictionary = ph.photo_for(device_id)
	if got.is_empty():
		return
	photo_view = PhotoView.make(got, 230, _open_photo_link)
	if photo_view == null:
		return
	col.add_child(photo_view)
	col.move_child(photo_view, picture.get_index())
	picture.visible = false


func _on_photo_ready(device_id: String, _path: String) -> void:
	if photo_view != null or device_id != str(_g("device").get("id", "")):
		return
	_on_info(info)


func _photo_focus() -> Array:
	return [photo_view.credit] if photo_view != null and not photo_view.credit.disabled else []


func hints_for(c: Control) -> Array:
	if photo_view != null and c == photo_view.credit:
		return [["A", PhotoView.TPhoto.PHOTO_SOURCE], ["B", "Back"]]
	return super(c)


func _open_photo_link(url: String) -> void:
	var d := svc("discover")
	if d != null and d.has_method("open_link") and d.open_link({"kind": "url", "uri": url}):
		return
	OS.shell_open(url)


func _fact(icon: String, value: String, what: String) -> PanelContainer:
	var p := PanelContainer.new()
	p.theme_type_variation = "RaisedPanel"
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var col := Kit.vbox(4)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(Icons.rect(icon, 20, ThemeLib.color("accent")))
	var v := Kit.label(value, "LeadLabel")
	v.add_theme_font_override("font", ThemeLib.font("semibold", true))
	col.add_child(v)
	col.add_child(Kit.label(what, "CaptionLabel"))
	p.add_child(col)
	return p


# ---- right: every detail ---------------------------------------------------------

func _fill_cards() -> void:
	var cards: Array = []
	cards.append(_device_card())
	cards.append(_chip_card())
	cards.append(_memory_card())
	cards.append(_storage_card())
	cards.append(_screen_card())
	cards.append(_battery_card())
	cards.append(_software_card())
	cards.append(_support_card())
	cards.append(_fixes_card())
	_card_list = cards.filter(func(c): return c != null)
	_grid.set_meta("dealt", -1)
	_deal()
	if not info.has("software") or not (_g("software").has("steam_version")):
		_loading = DKit.quiet(Texts.LOADING)
		_loading.name = "Loading"
		_cards.add_child(_loading)


## Deals the cards into one or two stacks for the current width. Each card
## goes to the shorter stack (by CARD_WEIGHT), in order, so the columns end
## close together. Focus runs down the left stack, then the right one; left /
## right jump across to the card beside.
func _deal() -> void:
	if _grid == null:
		return
	var w := _grid.size.x
	if w <= 0.0:
		w = size.x * 0.62   # not laid out yet (tests, first build)
	var n := 2 if w >= TWO_COLUMNS_W else 1
	if _grid.get_meta("dealt", -1) == n * 1000 + _card_list.size():
		return
	_grid.set_meta("dealt", n * 1000 + _card_list.size())
	for c in _card_list:
		if c.get_parent() != null:
			c.get_parent().remove_child(c)
	for st in _stacks:
		_grid.remove_child(st)
		st.queue_free()
	_stacks.clear()
	var heights: Array = []
	for i in n:
		var st := Kit.vbox(16)
		st.name = "Stack%d" % i
		st.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		st.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_grid.add_child(st)
		_stacks.append(st)
		heights.append(0.0)
	for c in _card_list:
		var k := 0
		for i in n:
			if heights[i] < heights[k] - 0.01:
				k = i
		_stacks[k].add_child(c)
		heights[k] += float(CARD_WEIGHT.get(String(c.name).trim_prefix("Card_"), 5.0)) + 1.0
	var order: Array = []
	for st in _stacks:
		order.append_array(st.get_children())
	chain(order + _photo_focus())


func _link() -> void:
	super()
	if _stacks.size() < 2:
		return
	var a: Array = _stacks[0].get_children()
	var b: Array = _stacks[1].get_children()
	if a.is_empty() or b.is_empty():
		return
	for i in a.size():
		a[i].focus_neighbor_right = a[i].get_path_to(b[mini(i, b.size() - 1)])
	for i in b.size():
		b[i].focus_neighbor_left = b[i].get_path_to(a[mini(i, a.size() - 1)])
	# The right stack's top goes up to the tabs too, not to the left stack's end.
	b[0].focus_neighbor_top = b[0].get_path_to(top_target if top_target != null else b[0])
	a[-1].focus_neighbor_bottom = a[-1].get_path_to(b[0])


func _section(key: String, tint := "accent") -> Array:
	var c := DKit.card(Texts.SECTIONS[key], Texts.SECTION_ICONS[key], tint)
	c[0].name = "Card_" + key
	return c


func _device_card() -> Control:
	var d := _g("device")
	var c := _section("device")
	var bios := " ".join(PackedStringArray([str(d.get("bios_version", "")), "(%s)" % d["bios_date"] if str(d.get("bios_date", "")) != "" else ""])).strip_edges()
	c[1].add_child(_kv([
		["Name", d.get("name", "")], ["Maker", d.get("maker", d.get("vendor", ""))], ["Model", d.get("model", "")],
		["Board", d.get("board", "")], ["Family", d.get("family", "")], ["BIOS", bios],
		["Serial number", Texts.SERIAL_HIDDEN],
	]))
	return c[0]


func _chip_card() -> Control:
	var ch := _g("chip")
	var c := _section("chip", "info")
	var cores := ""
	if int(ch.get("cores", -1)) > 0:
		cores = "%d cores, %d threads" % [int(ch["cores"]), int(ch.get("threads", ch["cores"]))]
	var gpu := str(ch.get("gpu", ""))
	if str(ch.get("gpu_arch", "")) not in ["", "unknown"]:
		gpu += " (%s)" % ch["gpu_arch"]
	var driver := str(ch.get("gpu_driver", ""))
	if str(ch.get("vulkan_driver", "")) != "":
		driver += ", Vulkan: %s" % ch["vulkan_driver"]
	if cores == "" and gpu.strip_edges() == "" and driver == "" and str(ch.get("cpu", "")) == "" and str(ch.get("kernel", "")) == "":
		c[0].free()
		return null   # nothing known yet: no empty card
	c[1].add_child(_kv([
		["Processor", ch.get("cpu", "")], ["Cores", cores], ["Graphics", gpu], ["Graphics driver", driver],
		["PCI id", ch.get("gpu_pci_id", "")], ["Mesa", ch.get("mesa", "")], ["Kernel", ch.get("kernel", "")],
	]))
	return c[0]


func _memory_card() -> Control:
	var m := _g("memory")
	if m.is_empty():
		return null
	var c := _section("memory", "info")
	c[1].add_child(_kv([
		["Memory", Texts.mb(int(m.get("total_mb", -1)))],
		["Graphics memory", Texts.mb(int(m.get("vram_mb", -1))), Texts.VRAM_NOTE],
		["Shared (GTT)", Texts.mb(int(m.get("gtt_mb", -1))), Texts.GTT_NOTE],
	]))
	return c[0]


func _storage_card() -> Control:
	var st := _g("storage")
	var c := _section("storage", "info")
	var any := false
	for k in ["internal", "sd_card"]:
		var s: Variant = st.get(k, {})
		if not s is Dictionary or s.is_empty():
			continue
		any = true
		var size := float(s.get("size_gb", -1))
		var title := "Internal" if k == "internal" else "SD card"
		var row := Kit.vbox(6)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var top := Kit.hbox(8)
		top.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var name_l := Kit.label("%s  ·  %s" % [title, str(s.get("model", s.get("name", "")))], "", true)
		name_l.add_theme_font_override("font", ThemeLib.font("medium"))
		top.add_child(name_l)
		var right := Kit.label(Texts.gb(size), "ValueLabel")
		right.add_theme_font_override("font", ThemeLib.font("semibold", true))
		top.add_child(right)
		row.add_child(top)
		if s.has("free_gb") and size > 0.0:
			var free := float(s["free_gb"])
			row.add_child(DKit.UsageBar.new(1.0 - free / size))
			row.add_child(Kit.label(Texts.FREE_OF % [Texts.gb(free), Texts.gb(size)], "CaptionLabel"))
		c[1].add_child(row)
	if not any:
		c[1].add_child(DKit.quiet(Texts.UNKNOWN))
	return c[0]


func _screen_card() -> Control:
	var s := _g("screen")
	if s.is_empty() or (float(s.get("size_in", -1)) <= 0.0 and (s.get("resolution", []) as Array).is_empty()):
		return null
	var c := _section("screen", "accent")
	var res: Array = s.get("resolution", []) if s.get("resolution") is Array else []
	var hz: Array = s.get("refresh_hz", []) if s.get("refresh_hz") is Array else []
	var vrr: Array = s.get("vrr_range", []) if s.get("vrr_range") is Array else []
	var hz_text := ""
	if hz.size() == 2:
		hz_text = "%d Hz" % int(hz[1]) if int(hz[0]) == int(hz[1]) else "%d–%d Hz" % [int(hz[0]), int(hz[1])]
	c[1].add_child(_kv([
		["Size", "%.1f inch" % float(s["size_in"]) if float(s.get("size_in", -1)) > 0 else ""],
		["Resolution", "%d × %d" % [int(res[0]), int(res[1])] if res.size() == 2 else ""],
		["Panel", s.get("type", "")], ["Refresh rate", hz_text],
		["VRR", ("%d–%d Hz" % [int(vrr[0]), int(vrr[1])]) if vrr.size() == 2 else ("Yes" if bool(s.get("vrr", false)) else "No"), Texts.VRR_NOTE],
	]))
	return c[0]


func _battery_card() -> Control:
	var b := _g("battery")
	if not bool(b.get("present", false)):
		return null
	var c := _section("battery", "good")
	var health := int(b.get("health_pct", -1))
	if health > 0:
		var tone := "good" if health >= 80 else ("warn" if health >= 60 else "bad")
		DKit.head_chip(c[1], DKit.chip("%d%% health" % health, tone))
		c[1].add_child(DKit.UsageBar.new(health / 100.0, tone, 8))
	var wh := ""
	if float(b.get("full_wh", -1)) > 0 and float(b.get("design_wh", -1)) > 0:
		wh = "%.1f of %.1f Wh" % [float(b["full_wh"]), float(b["design_wh"])]
	var made := " ".join(PackedStringArray([str(b.get("manufacturer", "")), str(b.get("model", ""))])).strip_edges()
	c[1].add_child(_kv([
		["Holds", wh, Texts.HEALTH_NOTE if wh != "" else ""],
		["Charge cycles", str(int(b.get("cycles", -1))) if int(b.get("cycles", -1)) >= 0 else "", Texts.CYCLES_NOTE],
		["Now", "%d%%%s" % [int(b.get("percent", -1)), ", charging" if bool(b.get("charging", false)) else ""] if int(b.get("percent", -1)) >= 0 else ""],
		["Charge limit", "Supported" if bool(b.get("charge_limit_supported", false)) else "Not on this battery"],
		["Battery", made], ["Type", b.get("technology", "")],
	]))
	return c[0]


func _software_card() -> Control:
	var s := _g("software")
	if [s.get("os", ""), s.get("gamecove_version", ""), s.get("steam_version", ""), s.get("proton", [])].all(func(v): return str(v) in ["", "[]"]):
		return null   # nothing known yet: no empty card
	var c := _section("software", "accent")
	var proton: Array = s.get("proton", []) if s.get("proton") is Array else []
	var proton_text := ""
	if not proton.is_empty():
		proton_text = ", ".join(PackedStringArray(proton.slice(0, 3)))
		if proton.size() > 3:
			proton_text += " and %d more" % (proton.size() - 3)
	c[1].add_child(_kv([
		["System", " ".join(PackedStringArray([str(s.get("os", "")), str(s.get("os_version", ""))])).strip_edges()],
		["GameCove", s.get("gamecove_version", "")], ["Steam", s.get("steam_version", "")], ["Proton", proton_text],
	]))
	return c[0]


func _support_card() -> Control:
	var sup := _g("support")
	var level := str(sup.get("level", "generic"))
	var c := _section("support", Texts.SUPPORT_TONES.get(level, "accent"))
	DKit.head_chip(c[1], DKit.chip(Texts.SUPPORT_LABELS.get(level, level), Texts.SUPPORT_TONES.get(level, "")))
	var f: Dictionary = sup.get("features", {}) if sup.get("features") is Dictionary else {}
	var lines := Kit.vbox(8)
	lines.name = "Features"
	lines.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var feats := [
		["tdp", bool(f.get("tdp", false))],
		["fan_control", bool(f.get("fan_control", false))],
		["charge_limit", bool(f.get("charge_limit", false))],
		["vrr", bool(f.get("vrr", false))],
		["paddles", int(f.get("paddles", 0)) > 0],
		["trackpads", int(f.get("trackpads", 0)) > 0],
	]
	for item in feats:
		lines.add_child(DKit.check_line("yes" if item[1] else "no", Texts.FEATURES[item[0]]))
	var gyro := str(f.get("gyro", "unknown"))
	lines.add_child(DKit.check_line({"yes": "yes", "fix": "maybe", "unknown": "maybe"}.get(gyro, "no"),
		"%s: %s" % [Texts.FEATURES["gyro"], Texts.GYRO_STATES.get(gyro, gyro)]))
	if bool(f.get("rgb", false)):
		lines.add_child(DKit.check_line("maybe", "%s: %s" % [Texts.FEATURES["rgb"], Texts.LED_LINE]))
	c[1].add_child(lines)
	var unv: Array = sup.get("unverified", []) if sup.get("unverified") is Array else []
	if not unv.is_empty():
		var names := PackedStringArray(unv.map(func(u): return str(Texts.UNVERIFIED_NAMES.get(u, u))))
		c[1].add_child(DKit.quiet("%s %s." % [Texts.UNVERIFIED_INTRO, ", ".join(names)]))
	var quirks: Array = sup.get("quirks", []) if sup.get("quirks") is Array else []
	if not quirks.is_empty():
		var qh := Kit.label(Texts.QUIRKS_TITLE, "")
		qh.add_theme_font_override("font", ThemeLib.font("semibold"))
		c[1].add_child(qh)
		for q in quirks:
			c[1].add_child(DKit.check_line("dot", str(q)))
	return c[0]


func _fixes_card() -> Control:
	var sup := _g("support")
	var fixes: Array = (sup.get("fixes", []) as Array).filter(func(x): return not str(x) in FixTexts.HIDDEN_FIXES) if sup.get("fixes") is Array else []
	var c := _section("fixes", "warn" if not fixes.is_empty() else "good")
	if fixes.is_empty():
		c[1].add_child(DKit.check_line("yes", Texts.NO_FIXES))
		return c[0]
	for fx in fixes:
		var row := Kit.vbox(2)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var t := Kit.label(FixTexts.fix_title(str(fx)))
		t.add_theme_font_override("font", ThemeLib.font("semibold"))
		row.add_child(t)
		row.add_child(DKit.quiet(FixTexts.fix_explain(str(fx))))
		c[1].add_child(row)
	c[1].add_child(DKit.quiet(Texts.FIXES_WHERE))
	return c[0]


func _kv(pairs: Array) -> GridContainer:
	return DKit.kv(pairs, 120, true)


## Services without info() (older fakes, partial backends): name and support only.
static func _basic_info(dev: Object) -> Dictionary:
	if dev == null:
		return {}
	var row: Dictionary = dev.get("profile") if dev.get("profile") is Dictionary else {}
	return {"device": {"name": str(row.get("name", "This handheld")), "maker": str(row.get("maker", ""))},
		"support": {"level": str(row.get("support", "generic"))}}
