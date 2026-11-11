extends "res://scripts/ui/device/device_panel.gd"
## Storage page: every drive that can hold games (internal, SD card, USB) with
## a usage bar, and the game folders on them. Storage.watch(true) while the
## page shows, so a card or drive that comes or goes shows up at once;
## watch(false) when it closes or leaves.

const Icons := preload("res://scripts/ui/icons.gd")
const KeepFocus := preload("res://scripts/ui/keep_focus.gd")
const TX := preload("res://scripts/ui/texts_extras.gd")

var state: Dictionary = {}
var measure_buttons := {}    # library path -> Button
var _measuring := {}
var _side: VBoxContainer
var _cards: VBoxContainer
var _watching := false
var clean_button: Button
var _last_freed := -1


static func build(services_: Dictionary) -> Control:
	var p = load("res://scripts/ui/device/storage_panel.gd").new()
	p.name = "StoragePanel"
	p.services = services_
	p._build()
	return p


func _build() -> void:
	_side = side_column(0.62)
	_cards = main_column(1.38)
	var st := svc("storage")
	if st != null:
		listen(st.changed, _on_changed)
		state = st.state()
		if not bool(state.get("ready", false)):
			st.refresh()
	_fill()


## On its own (a test, a screenshot) the panel watches while it's on screen. In
## the Device page every part is built at once, hidden: there only the part on
## show watches (the page calls opened() / closed()), so a Storage tab nobody
## looked at never polls the mounts behind a game.
func _enter_tree() -> void:
	call_deferred("_open_if_shown")


func _open_if_shown() -> void:
	if is_inside_tree() and is_visible_in_tree():
		opened()


func closed() -> void:
	var st := svc("storage")
	if st != null and _watching:
		st.watch(false)
		_watching = false


func opened() -> void:
	var st := svc("storage")
	if st != null and not _watching:
		st.watch(true)
		_watching = true
		if st.has_method("leftovers"):
			st.leftovers()
		if st.has_method("upscaling"):
			st.upscaling()


func _leave() -> void:
	closed()
	super._leave()


func _on_changed(s: Dictionary) -> void:
	state = s
	var f := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	var keep := String(f.name) if f != null else ""
	for path in measure_buttons:
		if measure_buttons[path] == f:
			keep = "measure:" + str(path)
	if clean_button != null and clean_button == f:
		keep = "CleanButton"
	var mark := KeepFocus.mark(self, focusables())
	var cl: Dictionary = s.get("cleanup", {}) if s.get("cleanup") is Dictionary else {}
	if cl.has("freed") and int(cl["freed"]) != _last_freed:
		_last_freed = int(cl["freed"])
		var bad := int(cl.get("failed", 0)) > 0
		toast_requested.emit(TX.CLEAN_FAILED if bad else TX.CLEAN_DONE % Texts.bytes(float(cl["freed"])), "alert" if bad else "check", "warn" if bad else "good")
	_measuring.clear()
	clear_box(_side)
	clear_box(_cards)
	_fill()
	if keep == "CleanButton" and clean_button != null:
		clean_button.grab_focus()
	elif keep.begins_with("measure:") and measure_buttons.has(keep.substr(8)):
		measure_buttons[keep.substr(8)].grab_focus()
	elif keep != "":
		var n := _cards.find_child(keep, true, false)
		if n is Control and n.focus_mode != Control.FOCUS_NONE:
			n.grab_focus()
	if KeepFocus.focused_in(self) == null or not is_instance_valid(KeepFocus.focused_in(self)):
		# Clean up finished (its button went) or a measure button became a size
		KeepFocus.restore(self, mark, focusables(), default_focus())


func _drives() -> Array:
	return state.get("drives", []) if state.get("drives") is Array else []


func _libraries() -> Array:
	return state.get("libraries", []) if state.get("libraries") is Array else []


func _fill() -> void:
	measure_buttons.clear()
	clean_button = null
	_fill_side()
	var focus: Array = []
	if clean_button != null:
		focus.append(clean_button)
	if not bool(state.get("ready", false)) and str(state.get("error", "")) == "":
		var c := DKit.card(Texts.DRIVES_TITLE, "download", "info")
		c[0].name = "Card_loading"
		c[1].add_child(DKit.quiet(Texts.STORAGE_LOADING))
		_cards.add_child(c[0])
		chain(focus + [c[0]])
		return
	if str(state.get("error", "")) != "" and _drives().is_empty():
		var e := DKit.card(Texts.STORAGE_ERROR, "alert", "bad")
		e[0].name = "Card_error"
		e[1].add_child(DKit.quiet(str(state["error"])))
		_cards.add_child(e[0])
		chain(focus + [e[0]])
		return
	if _drives().is_empty():
		var n := DKit.card(Texts.STORAGE_EMPTY, "download", "warn")
		n[0].name = "Card_empty"
		n[1].add_child(DKit.quiet(Texts.STORAGE_EMPTY_LINE))
		_cards.add_child(n[0])
		focus.append(n[0])
	var head := Kit.label(Texts.DRIVES_TITLE, "LeadLabel")
	head.name = "DrivesTitle"
	if not _drives().is_empty():
		_cards.add_child(head)
	var i := 0
	for d in _drives():
		var card := _drive_card(d, i)
		_cards.add_child(card)
		focus.append(card)
		i += 1
	var lh := Kit.label(Texts.LIBRARIES_TITLE, "LeadLabel")
	lh.name = "LibrariesTitle"
	_cards.add_child(lh)
	if _libraries().is_empty():
		var lc := DKit.card(Texts.LIBRARIES_TITLE, "library", "accent")
		lc[0].name = "Card_nolibs"
		lc[1].add_child(DKit.quiet(Texts.LIBRARIES_EMPTY))
		_cards.add_child(lc[0])
		focus.append(lc[0])
	var j := 0
	for lib in _libraries():
		var r := _library_card(lib, j)
		_cards.add_child(r[0])
		focus.append_array(r[1])
		j += 1
	chain(focus)


## Left: total across drives, one big bar, the hot-plug note.
func _fill_side() -> void:
	var total := 0.0
	var used := 0.0
	for d in _drives():
		if float(d.get("size", -1)) > 0 and float(d.get("used", -1)) >= 0:
			total += float(d["size"])
			used += float(d["used"])
	var c := DKit.card("Free space", "download", "accent", false)
	c[0].name = "Summary"
	if total > 0.0:
		var big := Kit.label(Texts.bytes(total - used), "DisplayLabel")
		big.name = "FreeTotal"
		big.add_theme_font_override("font", ThemeLib.font("display", true))
		c[1].add_child(big)
		c[1].add_child(Kit.label("free of %s on %d %s" % [Texts.bytes(total), _drives().size(), "drive" if _drives().size() == 1 else "drives"], "QuietLabel", true))
		c[1].add_child(DKit.UsageBar.new(used / total, "", 12))
	else:
		c[1].add_child(DKit.quiet(Texts.STORAGE_LOADING if not bool(state.get("ready", false)) else Texts.STORAGE_EMPTY))
	var note := DKit.check_line("dot", Texts.HOTPLUG_NOTE)
	c[1].add_child(note)
	_side.add_child(c[0])
	_clean_card()
	_upscaling_card()


## Upscaling files: one managed folder, its size, and how to get rid of it.
## Only shown once the helper has answered and something is there.
func _upscaling_card() -> void:
	var up: Dictionary = state.get("upscaling", {}) if state.get("upscaling") is Dictionary else {}
	var bytes := float(up.get("bytes", 0))
	var bundle := float(up.get("bundle_bytes", 0))
	if up.is_empty() or (bytes <= 0.0 and bundle <= 0.0):
		return
	var c := DKit.card(TX.UPSCALE_STORE_TITLE, "gauge", "info", false)
	c[0].name = "UpscalingFiles"
	var games := int(up.get("games", 0))
	var size := Kit.label(TX.UPSCALE_STORE_SIZE % Texts.bytes(bytes), "")
	size.name = "UpscalingSize"
	size.add_theme_font_override("font", ThemeLib.font("medium", true))
	c[1].add_child(size)
	var line := TX.UPSCALE_STORE_GAMES % [games, "game" if games == 1 else "games"] if games > 0 else TX.UPSCALE_STORE_NO_GAMES
	var gl := DKit.quiet(line)
	gl.name = "UpscalingGames"
	c[1].add_child(gl)
	if bundle > 0.0:
		var b := DKit.quiet(TX.UPSCALE_STORE_BUNDLE % Texts.bytes(bundle))
		b.name = "UpscalingBundle"
		c[1].add_child(b)
	var how := DKit.quiet(TX.UPSCALE_STORE_LINE)
	how.name = "UpscalingWhy"
	c[1].add_child(how)
	_side.add_child(c[0])


## Clean up: leftover shader caches of uninstalled games, one button.
func _clean_card() -> void:
	var st := svc("storage")
	if st == null or not st.has_method("clean_leftovers"):
		return
	var cl: Dictionary = state.get("cleanup", {}) if state.get("cleanup") is Dictionary else {}
	var c := DKit.card(TX.CLEAN_TITLE, "sparkle", "good", false)
	c[0].name = "CleanUp"
	var dirs: Array = cl.get("dirs", []) if cl.get("dirs") is Array else []
	var bytes := float(cl.get("bytes", 0))
	var missing: Array = cl.get("missing", []) if cl.get("missing") is Array else []
	if not bool(cl.get("ready", false)):
		c[1].add_child(DKit.quiet(TX.CLEAN_MEASURING))
	elif not missing.is_empty():
		var m := DKit.quiet(TX.CLEAN_MISSING % ", ".join(PackedStringArray(missing)))
		m.name = "CleanMissing"
		c[1].add_child(m)
	elif dirs.is_empty():
		c[1].add_child(DKit.quiet(TX.CLEAN_NONE))
	else:
		var found := Kit.label(TX.CLEAN_FOUND % [Texts.bytes(bytes), dirs.size(), "game" if dirs.size() == 1 else "games"], "")
		found.name = "CleanFound"
		found.add_theme_font_override("font", ThemeLib.font("medium", true))
		c[1].add_child(found)
		var b := Kit.button(TX.CLEAN_RUNNING if bool(cl.get("cleaning", false)) else TX.CLEAN_BUTTON % Texts.bytes(bytes))
		b.name = "CleanButton"
		b.custom_minimum_size = Vector2(0, 46)
		b.disabled = bool(cl.get("cleaning", false))
		# deferred: the clean-up rebuilds this card, which frees the button
		b.pressed.connect(start_clean, CONNECT_DEFERRED)
		c[1].add_child(b)
		clean_button = b
	var away: Array = cl.get("away", []) if cl.get("away") is Array else []
	if bool(cl.get("ready", false)) and missing.is_empty() and not away.is_empty():
		var kept := DKit.quiet(TX.CLEAN_AWAY % ", ".join(PackedStringArray(away)))
		kept.name = "CleanAway"
		c[1].add_child(kept)
	var why := DKit.quiet(TX.CLEAN_LINE)
	why.name = "CleanWhy"
	c[1].add_child(why)
	c[1].add_child(DKit.check_line("yes", TX.CLEAN_SAVES))
	_side.add_child(c[0])


func _drive_card(d: Dictionary, i: int) -> Control:
	var kind := str(d.get("kind", "internal"))
	var title := str(d.get("label", ""))
	if title == "":
		title = str(d.get("model", "")) if str(d.get("model", "")) != "" else Texts.DRIVE_KINDS.get(kind, "Drive")
	var c := DKit.card(title, Texts.DRIVE_ICONS.get(kind, "download"), {"internal": "accent", "sd": "info", "external": "good"}.get(kind, "accent"))
	c[0].name = "Drive_%d" % i
	DKit.head_chip(c[1], DKit.chip(Texts.DRIVE_KINDS.get(kind, kind), ""))
	var size := float(d.get("size", -1))
	var used := float(d.get("used", -1))
	var free := float(d.get("free", -1))
	if size > 0.0 and used >= 0.0:
		var bar := DKit.UsageBar.new(used / size, "", 10)
		bar.name = "Usage"
		c[1].add_child(bar)
	var line := Kit.hbox(8)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fl := Kit.label(Texts.FREE_OF % [Texts.bytes(free), Texts.bytes(size)], "")
	fl.name = "FreeLine"
	fl.add_theme_font_override("font", ThemeLib.font("medium", true))
	fl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(fl)
	var meta := PackedStringArray([str(d.get("fstype", ""))])
	if str(d.get("model", "")) != "" and str(d.get("model", "")) != title:
		meta.append(str(d["model"]))
	line.add_child(Kit.label(" · ".join(meta).strip_edges(), "CaptionLabel"))
	c[1].add_child(line)
	if str(d.get("compression", "")) != "":
		c[1].add_child(DKit.quiet(Texts.COMPRESSION_NOTE % d["compression"]))
	if str(d.get("mount", "")) != "":
		var m := Kit.label(str(d["mount"]), "CaptionLabel")
		m.add_theme_color_override("font_color", ThemeLib.color("text_3"))
		c[1].add_child(m)
	return c[0]


## [card, focusables]
func _library_card(lib: Dictionary, i: int) -> Array:
	var store := str(lib.get("store", "games"))
	var c := DKit.card(Texts.STORE_NAMES.get(store, store.capitalize()), "library", "accent")
	c[0].name = "Library_%d" % i
	var n := int(lib.get("games", -1))
	if n >= 0:
		DKit.head_chip(c[1], DKit.chip(Texts.games(n), ""))
	var p := Kit.label(str(lib.get("path", "")), "QuietLabel", true)
	p.name = "Path"
	c[1].add_child(p)
	var b := float(lib.get("bytes", -1))
	var line := Kit.hbox(12)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var used_l := Kit.label("Games use %s" % Texts.bytes(b) if b >= 0 else "Size not measured yet", "")
	used_l.name = "Used"
	used_l.add_theme_font_override("font", ThemeLib.font("medium", true))
	used_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(used_l)
	if float(lib.get("free", -1)) >= 0:
		line.add_child(Kit.label("%s free" % Texts.bytes(float(lib["free"])), "CaptionLabel"))
	c[1].add_child(line)
	var focus: Array = [c[0]]
	if b < 0 and svc("storage") != null and svc("storage").has_method("measure"):
		var mb := Kit.button(Texts.MEASURING if _measuring.has(lib.get("path", "")) else Texts.MEASURE)
		mb.name = "Measure_%d" % i
		mb.custom_minimum_size = Vector2(0, 46)
		var path := str(lib.get("path", ""))
		mb.pressed.connect(func():
			_measuring[path] = true
			mb.text = Texts.MEASURING
			mb.disabled = true
			svc("storage").measure(path))
		c[1].add_child(mb)
		measure_buttons[path] = mb
		focus = [mb]
	return [c[0], focus]


## Clean up pressed: the Storage service removes the leftovers (the card rebuilds).
func start_clean() -> void:
	var st := svc("storage")
	if st != null and st.has_method("clean_leftovers"):
		st.clean_leftovers()


func hints_for(c: Control) -> Array:
	if c is Button:
		return [["A", c.text], ["B", "Back"]]
	return [["DPAD", "Scroll"], ["B", "Back"]]
