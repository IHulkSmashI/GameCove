extends Control
## The Stream tab: play games from a PC running Vibepollo through Moonlight.
##
##   STREAM  Play games from your PC on this screen      [Moonlight ready] (Y) Add PC  Search again
##   [Moonlight is needed ... Install]                    (only while it's missing)
##   YOUR PCS   [GAMING-PC  ● ONLINE · 4 MS · HOME]  [office  ● ASLEEP]
##   (the focused PC)  running-now card · pair / wake card · its apps as a shelf of box art
##   This stream: 1920x1200 · 120 fps · AV1 · 46 Mb/s      (X) Stream settings
##
## With no PC yet: the setup guide (three steps, a QR code to Vibepollo's
## download page), Add PC and Search again.
##
## services (setup): {"streaming": the Streaming service, "toast": func(text, icon, tone, detail),
## "play": func(game: Dictionary, host_id: String, app: Dictionary)}. A finds what to do with the
## focused PC (wake, pair, its apps), X opens stream settings, Y adds a PC by
## address, Menu has the rest (sleep the PC, quit what runs on it, forget it).

const Kit := preload("res://scripts/ui/ui_kit.gd")
const KeepFocus := preload("res://scripts/ui/keep_focus.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Motion := preload("res://scripts/ui/motion.gd")
const Icons := preload("res://scripts/ui/icons.gd")
const Shelf := preload("res://scripts/ui/shelf.gd")
const Tile := preload("res://scripts/ui/game_tile.gd")
const Sheet := preload("res://scripts/ui/games/sheet.gd")
const Osk := preload("res://scripts/ui/osk.gd")
const QR := preload("res://scripts/ui/settings/qr.gd")
const SKit := preload("res://scripts/ui/settings/kit.gd")
const SIcons := preload("res://scripts/ui/streaming/stream_icons.gd")
const HostCard := preload("res://scripts/ui/streaming/host_card.gd")
const PairSheet := preload("res://scripts/ui/streaming/pair_sheet.gd")
const SettingsSheet := preload("res://scripts/ui/streaming/settings_sheet.gd")
const Settings := preload("res://scripts/streaming/stream_settings.gd")
const GameStream := preload("res://scripts/streaming/gamestream.gd")
const T := preload("res://scripts/ui/texts_streaming.gd")

## Box art size: Vector2.ZERO sizes them like every other shelf (seven across).
const TILE := Vector2.ZERO
## Stream's apps are box art on a screen with room below them: seven across
## like every shelf, but at true 2:3 box-art height (taller than library tiles).
const TILE_ASPECT := 1.5

var services := {}
var service: Object
var selected_id := ""
var host_cards: Array = []
var add_button: Button
var refresh_button: Button
var install_button: Button
var moon_chip: PanelContainer
## The focused PC's section: buttons and tiles, top to bottom.
var detail_focus: Array = []
var shelf: Control
var empty: Control
var pair_sheet: Control
var settings_sheet: Control
var more_sheet: Control
var keyboard: Control
var _kb_modal: Control
var _root: VBoxContainer
var _scroll: ScrollContainer
var _head_row: HBoxContainer
var _moon_card: Control
var _hosts_label: Label
var _hosts_row: HBoxContainer
var _detail: VBoxContainer
var _top_target: Control
var _rebuild_queued := false
var _modals_ready := false


func _init() -> void:
	name = "Stream"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var margin := Kit.margin(0)
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	# The scroll clips 24 px from the edge and its content pads another 24, so
	# the app shelf can reach into that room for the focused cover's ring.
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_top", 88)
	margin.add_theme_constant_override("margin_bottom", 58)
	add_child(margin)
	_scroll = ScrollContainer.new()
	_scroll.name = "Scroll"
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_scroll.follow_focus = true
	margin.add_child(_scroll)
	_root = Kit.vbox(ThemeLib.SPACE_5)
	_root.name = "Root"
	_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var inset := Kit.margin(0, 24, 0)
	inset.name = "Inset"
	inset.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inset.add_child(_root)
	_scroll.add_child(inset)
	_build_header()
	_moon_card = Control.new()
	_moon_card.name = "MoonlightSlot"
	_root.add_child(_moon_card)
	var hosts_box := Kit.vbox(ThemeLib.SPACE_3)
	hosts_box.name = "Hosts"
	_hosts_label = Kit.micro("Your PCs")
	_hosts_label.add_theme_font_override("font", ThemeLib.mono(true, 3))
	hosts_box.add_child(_hosts_label)
	var hscroll := ScrollContainer.new()
	hscroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	hscroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	hscroll.follow_focus = true
	hscroll.custom_minimum_size = Vector2(0, HostCard.SIZE.y + 16)
	hosts_box.add_child(hscroll)
	var pad := Kit.margin(0, 6, 6)
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hscroll.add_child(pad)
	_hosts_row = Kit.hbox(ThemeLib.SPACE_4)
	_hosts_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hosts_row.name = "Row"
	pad.add_child(_hosts_row)
	_root.add_child(hosts_box)
	_detail = Kit.vbox(ThemeLib.SPACE_4)
	_detail.name = "Detail"
	_root.add_child(_detail)
	visibility_changed.connect(func():
		if service != null and service.has_method("set_active"):
			service.set_active(is_visible_in_tree()))


func _build_header() -> void:
	_head_row = Kit.hbox(ThemeLib.SPACE_4)
	_head_row.name = "Head"
	var titles := Kit.vbox(2)
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var t := Kit.label(T.TITLE, "TitleLabel")
	t.name = "Title"
	titles.add_child(t)
	var sub := Kit.label(T.SUBTITLE, "QuietLabel")
	titles.add_child(sub)
	_head_row.add_child(titles)
	moon_chip = PanelContainer.new()
	moon_chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_head_row.add_child(moon_chip)
	add_button = Kit.secondary(T.ADD_PC, "", "Y")
	add_button.name = "AddPC"
	add_button.icon = SIcons.tex("plus", 20)
	add_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	add_button.pressed.connect(open_add)
	_head_row.add_child(add_button)
	# Its own button (View), shown right on it like every other shortcut.
	refresh_button = Kit.secondary(T.SEARCH_AGAIN, "update", "VIEW")
	refresh_button.name = "Refresh"
	refresh_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	refresh_button.pressed.connect(func(): service.refresh())
	_head_row.add_child(refresh_button)
	_root.add_child(_head_row)


func setup(svc: Dictionary) -> void:
	services = svc
	service = svc.get("streaming")
	if service == null:
		return
	service.changed.connect(queue_rebuild)
	service.apps_changed.connect(func(_id): queue_rebuild())
	service.pair_changed.connect(_on_pair_changed)
	service.install_changed.connect(_on_install_changed)
	service.notice.connect(func(text, tone): _toast(text, "check" if tone == "good" else "info", tone))
	rebuild()


func _ready() -> void:
	# main.gd makes its modal layer after the screens: wait for it
	_make_modals.call_deferred()


## Sheets and the keyboard live in main's modal layer (over the top bar, under
## the hint bar) when there is one, else here.
func _make_modals() -> void:
	if _modals_ready:
		return
	_modals_ready = true
	var layer: Node = self
	var h := host()
	if h != null and h.get("_modal_layer") is Control:
		layer = h.get("_modal_layer")
	pair_sheet = PairSheet.new()
	pair_sheet.cancel_requested.connect(func():
		service.cancel_pair()
		pair_sheet.close())
	pair_sheet.retry_requested.connect(func():
		var id: String = selected_id
		pair_sheet.close()
		start_pair(id))
	pair_sheet.done.connect(func():
		pair_sheet.close()
		_focus_detail())
	layer.add_child(pair_sheet)
	settings_sheet = SettingsSheet.new()
	settings_sheet.closed.connect(func():
		queue_rebuild()
		_hints_changed())
	layer.add_child(settings_sheet)
	more_sheet = Sheet.new()
	more_sheet.closed.connect(_hints_changed)
	layer.add_child(more_sheet)
	_kb_modal = Control.new()
	_kb_modal.name = "AddPCModal"
	_kb_modal.set_anchors_preset(Control.PRESET_FULL_RECT)
	_kb_modal.visible = false
	_kb_modal.mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	Kit.fill(dim)
	dim.color = Color(ThemeLib.color("scrim"), 0.78)
	_kb_modal.add_child(dim)
	keyboard = Osk.new()
	keyboard.placeholder = T.ADD_HINT
	keyboard.max_len = 120
	var head := Kit.vbox(2)
	head.add_child(Kit.label(T.ADD_TITLE, "HeaderLabel"))
	var hint := Kit.label(T.ADD_HINT, "QuietLabel", true)
	hint.custom_minimum_size = Vector2(780, 0)
	head.add_child(hint)
	keyboard.get_child(0).add_child(head)
	keyboard.get_child(0).move_child(head, 0)
	keyboard.anchor_left = 0.5
	keyboard.anchor_right = 0.5
	keyboard.anchor_top = 1.0
	keyboard.anchor_bottom = 1.0
	keyboard.offset_left = -430
	keyboard.offset_right = 430
	keyboard.offset_top = -560
	keyboard.offset_bottom = -64
	keyboard.closed.connect(_on_add_closed)
	_kb_modal.add_child(keyboard)
	layer.add_child(_kb_modal)


## The screen was left (main.gd _screen_out): its sheets and keyboard sit in main's layer, not under
## it, so they would stay up over the next screen and take its B (focus then went to a hidden
## button: monkey seed 104004). Put away, no focus grabbed back: the next screen takes it.
func dismiss_overlays() -> void:
	if pair_sheet != null and pair_sheet.is_open():
		if pair_sheet.state == "waiting":
			service.cancel_pair()
		pair_sheet.close(false)
	if settings_sheet != null and settings_sheet.is_open():
		settings_sheet.close(false)
	if more_sheet != null and more_sheet.is_open():
		more_sheet.close(false)
	if _kb_modal != null and _kb_modal.visible:
		keyboard.dismiss()
		_kb_modal.visible = false
	_hints_changed()


func _exit_tree() -> void:
	# the modals sit in main's layer: they go with this screen
	for m in [pair_sheet, settings_sheet, more_sheet, _kb_modal]:
		if m != null and is_instance_valid(m) and m.get_parent() != self:
			m.queue_free()


## The node that owns the hint bar (main.gd), found by duck typing.
func host() -> Node:
	var n := get_parent()
	while n != null:
		if n.get("hint_bar") is Control:
			return n
		n = n.get_parent()
	return null


func _toast(text: String, icon := "info", tone := "", detail := "") -> void:
	var t: Variant = services.get("toast")
	if t is Callable and t.is_valid():
		t.call(text, icon, tone, detail)


func _hints_changed() -> void:
	var h := host()
	if h != null and h.has_method("_update_hints"):
		h.call_deferred("_update_hints")


# ---------------------------------------------------------------- building

func queue_rebuild() -> void:
	if _rebuild_queued:
		return
	_rebuild_queued = true
	# A deferred method (not a lambda): if the screen is freed first, Godot
	# drops the call instead of running it on a dead instance.
	call_deferred("_run_queued_rebuild")


func _run_queued_rebuild() -> void:
	_rebuild_queued = false
	rebuild()


## Redraws everything from the service, keeping focus where it was (same PC,
## same app, same button).
func rebuild() -> void:
	if service == null:
		return
	var f := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	var keep := _focus_key(f)
	var mark := KeepFocus.mark(self, _host_focus())
	_style_moon_chip()
	_build_moonlight_card()
	var list: Array = service.host_list()
	if selected_id == "" or not service.hosts.has(selected_id):
		selected_id = _default_host(list)
	_build_hosts(list)
	_build_detail()
	_link()
	if keep != "":
		var target := _find_focus(keep)
		if target != null and target != f:
			target.grab_focus()
		elif target == null:
			# that PC was removed: the next one in the list, or Add PC
			KeepFocus.restore(self, mark, _host_focus(), add_button)
	elif _shown_without_focus(f):
		# the tab was just shown and its focus was on its way to a control this
		# rebuild freed (Install, as discovery starts): the tab's own control
		var d := default_focus()
		if d != null and d.is_visible_in_tree():
			d.grab_focus.call_deferred()
	_hints_changed()
	# the top bar's "down" pointed at a button this rebuild just freed (Install,
	# a host card): the host links it again to the new one
	var h := host()
	if h != null and h.has_method("_link_top"):
		h.call("_link_top")


## This tab is the screen in front (the host says so; the screen before it may
## still be sliding out with focus on it) and nothing of ours, or of a sheet or
## the quick menu over it, has focus.
func _shown_without_focus(f: Control) -> bool:
	if not is_visible_in_tree():
		return false
	var h := host()
	if h != null and h.has_method("_screen") and h.call("_screen") != self:
		return false
	if f != null and is_instance_valid(f) and f.is_visible_in_tree():
		if is_ancestor_of(f):
			return false
		var qm: Variant = h.get("quick_menu") if h != null else null
		if qm is Control and (qm as Control).is_ancestor_of(f):
			return false
		var ga: Variant = h.get("game_actions") if h != null else null
		if ga is Object and ga.has_method("is_modal") and ga.is_modal():
			return false
		if h != null and h.get("top_bar") is Control and (h.get("top_bar") as Control).is_ancestor_of(f):
			return false
	return true


func _default_host(list: Array) -> String:
	for h in list:
		if bool(h["paired"]) and h["status"] in ["online", "busy"]:
			return h["id"]
	return str(list[0]["id"]) if not list.is_empty() else ""


func _focus_key(f: Control) -> String:
	if f == null or not is_ancestor_of(f):
		return ""
	if f is HostCard:
		return "host:" + str(f.host.get("id", ""))
	if f.get("game") is Dictionary and not (f.get("game") as Dictionary).is_empty():
		return "tile:" + str(f.game.get("key", ""))
	return "node:" + str(f.name)


func _host_focus() -> Array:
	return host_cards.filter(func(c): return is_instance_valid(c))


func _find_focus(key: String) -> Control:
	if key.begins_with("host:"):
		for c in host_cards:
			if "host:" + str(c.host.get("id", "")) == key:
				return c
	elif key.begins_with("tile:") and shelf != null:
		for t in shelf.tiles:
			if "tile:" + str(t.game.get("key", "")) == key:
				return t
	elif key.begins_with("node:"):
		var n := key.substr(5)
		for c in [add_button, refresh_button, install_button] + detail_focus:
			if c != null and is_instance_valid(c) and str(c.name) == n:
				return c
	return null


func _style_moon_chip() -> void:
	for c in moon_chip.get_children():
		Kit.drop(moon_chip, c)
	var ok: bool = service.has_moonlight()
	var chip := Kit.chip("Moonlight ready" if ok else "Moonlight needed", "check" if ok else "alert", "good" if ok else "warn")
	moon_chip.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	moon_chip.add_child(chip)


func _build_moonlight_card() -> void:
	for c in _moon_card.get_children():
		Kit.drop(_moon_card, c)
	install_button = null
	_moon_card.visible = not service.has_moonlight()
	if service.has_moonlight():
		_moon_card.custom_minimum_size = Vector2.ZERO
		return
	var card := PanelContainer.new()
	card.name = "MoonlightCard"
	card.theme_type_variation = "CardPanel"
	card.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	var row := Kit.hbox(ThemeLib.SPACE_5)
	card.add_child(row)
	var tile := PanelContainer.new()
	tile.custom_minimum_size = Vector2(56, 56)
	tile.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tile.add_theme_stylebox_override("panel", ThemeLib.box(Color(ThemeLib.tone("warn"), 0.14), ThemeLib.radius("m"), 0, 0))
	var ic := SIcons.rect("stream", 28, ThemeLib.tone("warn"))
	ic.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	tile.add_child(ic)
	row.add_child(tile)
	var col := Kit.vbox(4)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(Kit.label(T.MOONLIGHT_TITLE, "LeadLabel"))
	var line := Kit.label(T.MOONLIGHT_LINE, "QuietLabel", true)
	col.add_child(line)
	row.add_child(col)
	var running: bool = service.install_state == "running"
	install_button = Kit.primary(T.INSTALLING if running else T.INSTALL, "A")
	install_button.name = "Install"
	install_button.disabled = running
	install_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	install_button.pressed.connect(func(): service.install_moonlight())
	row.add_child(install_button)
	_moon_card.add_child(card)
	_moon_card.custom_minimum_size = Vector2(0, 104)


func _build_hosts(list: Array) -> void:
	for c in _hosts_row.get_children():
		Kit.drop(_hosts_row, c)
	host_cards.clear()
	_hosts_label.get_parent().visible = not list.is_empty()
	for h in list:
		var card: Button = HostCard.new()
		card.set_host(h, host_line(h, service.has_moonlight()), h["id"] == selected_id)
		var id: String = h["id"]
		# Three or more PCs share the row's width (no dead space at its end).
		if list.size() >= 3:
			card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.pressed.connect(func(): host_action(id))
		card.focus_entered.connect(func(): _select(id))
		_hosts_row.add_child(card)
		host_cards.append(card)
	Kit.link_horizontal(host_cards)


## What A on a PC card does now, in a few words.
static func host_line(h: Dictionary, moonlight: bool) -> String:
	var st := str(h.get("status", ""))
	if st in ["online", "busy"] and not bool(h.get("paired", false)):
		return T.NOT_PAIRED_LINE
	if st == "busy" and int(h.get("current_app", 0)) > 0:
		for a in h.get("apps", []):
			if int(a["id"]) == int(h["current_app"]):
				return T.PLAYING % str(a["title"])
	if st == "asleep" and not moonlight:
		return T.STATUS_LINE["asleep"]
	return T.STATUS_LINE.get(st, "")


func _select(id: String) -> void:
	if id == selected_id:
		return
	selected_id = id
	for c in host_cards:
		c.set_host(c.host, host_line(c.host, service.has_moonlight()), c.host["id"] == id)
	_build_detail()
	_link()
	_hints_changed()


func _build_detail() -> void:
	for c in _detail.get_children():
		Kit.drop(_detail, c)
	detail_focus.clear()
	shelf = null
	if empty != null and is_instance_valid(empty):
		Kit.drop(_root, empty)
	empty = null
	var h: Dictionary = service.host(selected_id)
	if h.is_empty():
		if service.discovering:
			_detail.add_child(_searching_card())
		else:
			empty = _empty_state()
			_root.add_child(empty)
		return
	var st := str(h["status"])
	var name_text: String = service.display_name(h)
	var paired := bool(h["paired"])
	if st == "busy" and paired:
		var running: Dictionary = service.app_by_id(selected_id, int(h["current_app"]))
		if not running.is_empty():
			_detail.add_child(_running_card(h, running))
	if st in ["online", "busy"] and not paired:
		_detail.add_child(_action_card("link", T.PAIR_TITLE % name_text, T.PAIR_ENTER + ". " + T.PAIR_PERMS,
			T.PAIR, func(): start_pair(selected_id), "PairButton", "accent"))
		_detail.add_child(SKit.note(T.PAIR_ONCE % service.web_ui_url(h), "info", "PairNote"))
	elif st == "asleep" or st == "waking":
		var waking := st == "waking"
		_detail.add_child(_action_card("moon", "%s is asleep" % name_text if not waking else T.STATUS["waking"],
			T.STATUS_LINE["waking"] if waking else "Wake-on-LAN sends it a wake-up signal. It needs Wake-on-LAN on in the PC's BIOS.",
			T.WAKE, func(): service.wake(selected_id), "WakeButton", "warn", waking))
	elif st in ["offline", "unknown", "checking"]:
		_detail.add_child(_action_card("cloud_off", "Can't reach %s" % name_text,
			"Is it on and Vibepollo running? Away from home, connect Tailscale (or your VPN) on both first.",
			"Check again", func(): service.check_host(selected_id), "CheckButton", "", st == "checking"))
	if paired:
		_add_apps(h)
		if int(h.get("permission", -1)) >= 0 and int(h["permission"]) & GameStream.PERM_LAUNCH == 0:
			_detail.add_child(SKit.note(T.NO_LAUNCH_PERMISSION, "warn", "PermissionNote"))


func _searching_card() -> Control:
	var row := Kit.hbox(ThemeLib.SPACE_3)
	row.name = "Searching"
	row.add_child(Icons.rect("search", 22, ThemeLib.color("accent")))
	row.add_child(Kit.label(T.SEARCHING, "QuietLabel"))
	return row


func _action_card(icon: String, title: String, line: String, button: String, cb: Callable, node_name: String, tone := "", disabled := false) -> Control:
	var card := PanelContainer.new()
	card.theme_type_variation = "CardPanel"
	card.name = "Card_" + node_name
	var row := Kit.hbox(ThemeLib.SPACE_5)
	card.add_child(row)
	var col: Color = ThemeLib.tone(tone) if tone in ["warn", "good", "bad", "info"] else ThemeLib.color("accent" if tone == "accent" else "text_2")
	var tile := PanelContainer.new()
	tile.custom_minimum_size = Vector2(56, 56)
	tile.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tile.add_theme_stylebox_override("panel", ThemeLib.box(Color(col, 0.14), ThemeLib.radius("m"), 0, 0))
	var ic := SIcons.rect(icon, 28, col)
	ic.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	tile.add_child(ic)
	row.add_child(tile)
	var texts := Kit.vbox(4)
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var tl := Kit.label(title, "LeadLabel")
	tl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	texts.add_child(tl)
	texts.add_child(Kit.label(line, "QuietLabel", true))
	row.add_child(texts)
	var b := Kit.primary(button, "A")
	b.name = node_name
	b.disabled = disabled
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.pressed.connect(cb)
	row.add_child(b)
	detail_focus.append(b)
	return card


func _running_card(h: Dictionary, app: Dictionary) -> Control:
	var card := PanelContainer.new()
	card.theme_type_variation = "CardPanel"
	card.name = "RunningCard"
	var row := Kit.hbox(ThemeLib.SPACE_5)
	card.add_child(row)
	var art := TextureRect.new()
	art.custom_minimum_size = Vector2(68, 96)
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	var path := str(app.get("art", ""))
	if path != "" and FileAccess.file_exists(path):
		Kit.load_art_async(path, Vector2i(136, 192), art)
	row.add_child(art)
	var texts := Kit.vbox(4)
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	texts.alignment = BoxContainer.ALIGNMENT_CENTER
	texts.add_child(Kit.label(T.RUNNING_ON_PC % service.display_name(h), "EyebrowLabel"))
	var tl := Kit.label(str(app["title"]), "HeaderLabel")
	tl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	texts.add_child(tl)
	texts.add_child(Kit.label(Settings.summary(service.resolved(selected_id, int(app["id"]))), "MonoLabel"))
	row.add_child(texts)
	var resume := Kit.primary(T.RESUME, "A", "play")
	resume.name = "Resume"
	resume.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var id := selected_id
	resume.pressed.connect(func(): play(id, app))
	row.add_child(resume)
	var quit := Kit.secondary(T.QUIT_ON_PC)
	quit.icon = SIcons.tex("stop", 20)
	quit.name = "QuitOnPC"
	quit.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	quit.pressed.connect(func():
		if service.quit_app(id):
			_toast(T.QUIT_SENT % str(app["title"]), "stop", ""))
	row.add_child(quit)
	detail_focus.append(resume)
	detail_focus.append(quit)
	return card


func _add_apps(h: Dictionary) -> void:
	var state := str(h["apps_state"])
	var apps: Array = h["apps"]
	if state == "loading" and apps.is_empty():
		var row := _searching_card()
		(row.get_child(1) as Label).text = T.APPS_LOADING
		_detail.add_child(row)
		return
	if state == "denied":
		_detail.add_child(SKit.note(T.APPS_DENIED, "warn", "DeniedNote"))
		return
	if state == "error" and apps.is_empty():
		_detail.add_child(SKit.note(T.APPS_ERROR, "warn", "ErrorNote"))
		return
	if apps.is_empty():
		if state == "ready":
			_detail.add_child(SKit.note(T.APPS_EMPTY, "info", "EmptyNote"))
		return
	var games: Array = []
	for a in apps:
		games.append(service.game_for(selected_id, a))
	shelf = Shelf.new()
	var ts := TILE if TILE != Vector2.ZERO else Tile.size_for(Tile.row_width(), Shelf.GAP)
	ts.y = roundf(ts.x * TILE_ASPECT)
	shelf.setup("stream_apps", T.APPS_ON % service.display_name(h), games, ts)
	shelf.count_label.text = "%d %s" % [games.size(), "app" if games.size() == 1 else "apps"]
	# What this PC will stream, as a quiet glass pill beside the row's title
	# (it used to float under the row over empty space).
	shelf.get_node("Head").add_child(_spec_pill())
	shelf.get_node("Head").move_child(shelf.get_node("Head/SpecPill"), shelf.get_node("Head/Title").get_index() + 1)
	var asleep := str(h["status"]) in ["asleep", "offline", "waking"]
	for t in shelf.tiles:
		t.sub_label.text = service.display_name(h) + (" · HDR" if bool(t.game["stream"].get("hdr", false)) and service.hdr_available(selected_id) else "")
		if asleep:
			t.set_meta("base_alpha", 0.55)
			t.modulate = Color(1, 1, 1, 0.55)
	shelf.tile_pressed.connect(func(g): play(selected_id, service.app_by_id(selected_id, int(g["stream"]["app_id"]))))
	shelf.tile_focused.connect(func(_g, _i): _hints_changed())
	# The shelf pads its tiles for the focus glow: pull it out by that much so
	# the first cover lines up with the PC cards above.
	var align := Kit.margin(0)
	align.name = "ShelfAlign"
	align.add_theme_constant_override("margin_left", -int(Shelf.PAD.x))
	align.add_theme_constant_override("margin_right", -int(Shelf.PAD.x))
	align.add_child(shelf)
	_detail.add_child(align)
	for t in shelf.tiles:
		detail_focus.append(t)


## "1920x1200 · 120 fps · AV1 · 32 Mb/s" in a glass pill (signal icon, mono):
## the row header's own fact, next to ON GAMING-PC. X opens the settings.
func _spec_pill() -> Control:
	var pill := PanelContainer.new()
	pill.name = "SpecPill"
	pill.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var sb := ThemeLib.box(ThemeLib.soft(0.05), 999, 12, 4)
	sb.border_color = ThemeLib.soft(0.10)
	sb.set_border_width_all(1)
	pill.add_theme_stylebox_override("panel", sb)
	var row := Kit.hbox(ThemeLib.SPACE_2)
	row.name = "Foot"
	row.add_child(SIcons.rect("signal", 14, ThemeLib.color("accent")))
	var sum := Kit.label(Settings.summary(service.resolved(selected_id)), "MonoLabel")
	sum.name = "Summary"
	sum.add_theme_font_size_override("font_size", 13)
	sum.add_theme_color_override("font_color", ThemeLib.color("text_2"))
	sum.tooltip_text = T.WILL_STREAM % sum.text
	row.add_child(sum)
	pill.add_child(row)
	return pill


func _empty_state() -> Control:
	var wrap := Kit.hbox(ThemeLib.SPACE_6)
	wrap.name = "Empty"
	var left := Kit.vbox(ThemeLib.SPACE_3)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var head := Kit.hbox(ThemeLib.SPACE_4)
	var pic := TextureRect.new()
	pic.texture = Icons.from_svg(SIcons.illustration_svg(ThemeLib.color("accent"), ThemeLib.color("accent_2"),
		ThemeLib.color("text"), ThemeLib.color("bg"), 108))
	pic.custom_minimum_size = Vector2(108, 108)
	pic.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	head.add_child(pic)
	var ht := Kit.vbox(6)
	ht.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ht.alignment = BoxContainer.ALIGNMENT_CENTER
	ht.add_child(Kit.label(T.EMPTY_TITLE, "HeaderLabel", true))
	ht.add_child(Kit.label(T.EMPTY_LINE, "QuietLabel", true))
	head.add_child(ht)
	left.add_child(head)
	for i in T.STEPS.size():
		left.add_child(_step(i + 1, T.STEPS[i][0], T.STEPS[i][1]))
	wrap.add_child(left)
	var qr_card := PanelContainer.new()
	qr_card.theme_type_variation = "CardPanel"
	qr_card.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	var qcol := Kit.vbox(ThemeLib.SPACE_3)
	qcol.alignment = BoxContainer.ALIGNMENT_CENTER
	qr_card.add_child(qcol)
	qcol.add_child(Kit.label(T.QR_CAPTION, "EyebrowLabel"))
	var qr := TextureRect.new()
	qr.name = "QR"
	QR.show_on(qr, T.VIBEPOLLO_URL, 5)
	qr.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	qr.custom_minimum_size = Vector2(210, 210)
	qcol.add_child(qr)
	var cap := Kit.label(T.SCAN, "CaptionLabel")
	cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	qcol.add_child(cap)
	var url := Kit.label("github.com/Nonary/Vibepollo", "MonoLabel")
	url.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	qcol.add_child(url)
	wrap.add_child(qr_card)
	return wrap


func _step(n: int, title: String, line: String) -> Control:
	var card := PanelContainer.new()
	card.theme_type_variation = "CardPanel"
	card.add_theme_stylebox_override("panel", ThemeLib.card(20, 12))
	var row := Kit.hbox(ThemeLib.SPACE_4)
	card.add_child(row)
	var num := PanelContainer.new()
	num.custom_minimum_size = Vector2(40, 40)
	num.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	num.add_theme_stylebox_override("panel", ThemeLib.gradient_pill(ThemeLib.color("accent"), ThemeLib.color("accent_end"), 40, 0, 0, false))
	var l := Kit.label(str(n))
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_font_override("font", ThemeLib.font("mono_bold"))
	l.add_theme_color_override("font_color", ThemeLib.color("on_accent"))
	num.add_child(l)
	row.add_child(num)
	var col := Kit.vbox(2)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var tl := Kit.label(title, "")
	tl.add_theme_font_override("font", ThemeLib.font("semibold"))
	col.add_child(tl)
	var ll := Kit.label(line, "QuietLabel", true)
	ll.add_theme_font_size_override("font_size", ThemeLib.SIZE_CAPTION)
	col.add_child(ll)
	row.add_child(col)
	return card


# ---------------------------------------------------------------- focus

func default_focus() -> Control:
	if install_button != null and not service.has_moonlight():
		return install_button
	for c in host_cards:
		if c.host["id"] == selected_id:
			return c
	if not host_cards.is_empty():
		return host_cards[0]
	return add_button


func set_top_target(c: Control) -> void:
	_top_target = c
	_link()


func _link() -> void:
	var head: Array = [add_button, refresh_button]
	Kit.link_horizontal(head)
	var hosts_target: Control = null
	for c in host_cards:
		if c.host["id"] == selected_id:
			hosts_target = c
	if hosts_target == null and not host_cards.is_empty():
		hosts_target = host_cards[0]
	# rows top to bottom: header buttons, install, hosts, detail buttons, tiles
	var tiles: Array = shelf.tiles if shelf != null else []
	var buttons: Array = detail_focus.filter(func(c): return not c in tiles)
	var rows_list: Array = [head]
	if install_button != null:
		rows_list.append([install_button])
	if not host_cards.is_empty():
		rows_list.append(host_cards)
	if not buttons.is_empty():
		rows_list.append(buttons)
	if not tiles.is_empty():
		rows_list.append(tiles)
	for i in rows_list.size():
		var row: Array = rows_list[i]
		var up_row: Array = rows_list[i - 1] if i > 0 else []
		var down_row: Array = rows_list[i + 1] if i + 1 < rows_list.size() else []
		var up_t: Control = _entry(up_row, hosts_target) if not up_row.is_empty() else _top_target
		var down_t: Control = _entry(down_row, hosts_target) if not down_row.is_empty() else null
		for c in row:
			if up_t != null:
				c.focus_neighbor_top = c.get_path_to(up_t)
			c.focus_neighbor_bottom = c.get_path_to(down_t if down_t != null else c)
	Kit.link_horizontal(buttons)


func _entry(row: Array, hosts_target: Control) -> Control:
	if row == host_cards and hosts_target != null:
		return hosts_target
	if shelf != null and row == shelf.tiles:
		return shelf.remembered()
	return row[0]


func _focus_detail() -> void:
	if not is_inside_tree():
		return
	if not detail_focus.is_empty():
		var t: Control = shelf.remembered() if shelf != null else detail_focus[0]
		t.grab_focus()
	else:
		var d := default_focus()
		if d != null:
			d.grab_focus()


# ---------------------------------------------------------------- actions

## A on a PC card.
func host_action(id: String) -> void:
	var h: Dictionary = service.host(id)
	if h.is_empty():
		return
	_select(id)
	if not service.has_moonlight():
		_toast(T.NEED_MOONLIGHT, "alert", "warn")
		if install_button != null and install_button.is_inside_tree():
			install_button.grab_focus()
		return
	match str(h["status"]):
		"asleep":
			service.wake(id)
		"waking":
			pass
		"offline", "unknown":
			service.check_host(id)
		_:
			if not bool(h["paired"]):
				start_pair(id)
			else:
				_focus_detail()


func start_pair(id: String) -> void:
	if not service.pair(id):
		if not service.has_moonlight():
			_toast(T.NEED_MOONLIGHT, "alert", "warn")


func _on_pair_changed(id: String, state: String, info: Dictionary) -> void:
	if pair_sheet == null:
		return
	match state:
		"waiting":
			selected_id = id
			pair_sheet.open_waiting(str(info.get("name", "")), str(info.get("pin", "")), str(info.get("url", "")))
		"paired":
			selected_id = id
			pair_sheet.show_paired()
			queue_rebuild()
		"failed":
			pair_sheet.show_failed(str(info.get("why", "")))
		"cancelled":
			pair_sheet.close()
	_hints_changed()


func _on_install_changed(state: String, line: String) -> void:
	match state:
		"done": _toast(line, "check", "good")
		"failed": _toast(line, "alert", "bad")
	queue_rebuild()


## A on an app: stream it (waking the PC first if it sleeps).
func play(id: String, app: Dictionary) -> void:
	var h: Dictionary = service.host(id)
	if h.is_empty() or app.is_empty():
		return
	if str(h["status"]) in ["asleep", "offline"] and service.can_wake(id):
		service.wake(id)
		_toast("Waking %s first" % service.display_name(h), "info", "")
		return
	var cb: Variant = services.get("play")
	if cb is Callable and cb.is_valid():
		cb.call(service.game_for(id, app), id, app)


func open_add() -> void:
	if _kb_modal == null:
		return
	_kb_modal.visible = true
	keyboard.open("")
	_hints_changed()


func _on_add_closed(text: String) -> void:
	_kb_modal.visible = false
	if text.strip_edges() != "":
		var why: String = service.add_manual(text)
		if why != "":
			_toast(why, "alert", "warn")
	if add_button.is_inside_tree():
		add_button.grab_focus()
	_hints_changed()


func open_settings(f: Control = null) -> void:
	if settings_sheet == null or selected_id == "":
		return
	var app := {}
	if f != null and f.get("game") is Dictionary and (f.get("game") as Dictionary).has("stream"):
		app = service.app_by_id(selected_id, int(f.game["stream"]["app_id"]))
	settings_sheet.open(service, selected_id, app)
	_hints_changed()


func open_more() -> void:
	var h: Dictionary = service.host(selected_id)
	if h.is_empty() or more_sheet == null:
		return
	var items: Array = [{"id": "settings", "text": T.SETTINGS, "icon": "sliders"}]
	if service.can_wake(selected_id) and not h["status"] in ["online", "busy"]:
		items.append({"id": "wake", "text": T.WAKE, "icon": "power"})
	if int(h.get("current_app", 0)) > 0:
		items.append({"id": "quit", "text": T.QUIT_ON_PC, "icon": "stop"})
	if service.can_sleep(selected_id):
		items.append({"id": "sleep", "text": T.SLEEP, "icon": "power", "detail": "Vibepollo lets this handheld put the PC to sleep"})
	items.append({"id": "pair", "text": T.PAIR + (" again" if bool(h["paired"]) else ""), "icon": "lock",
		"disabled": not h["status"] in ["online", "busy"], "detail": "" if h["status"] in ["online", "busy"] else "The PC has to be on"})
	items.append({"id": "refresh", "text": "Check again", "icon": "update"})
	items.append({"id": "forget", "text": T.REMOVE, "icon": "trash", "tone": "bad",
		"detail": "Only here: the PC and Moonlight keep their pairing"})
	var id := selected_id
	more_sheet.open(service.display_name(h), str(h.get("address", "")), items, func(choice: String): _more_choice(id, choice))
	_hints_changed()


func _more_choice(id: String, choice: String) -> void:
	match choice:
		"settings":
			open_settings()
		"wake":
			service.wake(id)
		"quit":
			service.quit_app(id)
		"sleep":
			service.sleep_pc(id)
		"pair":
			start_pair(id)
		"refresh":
			service.check_host(id)
		"forget":
			service.remove_host(id)
			selected_id = ""


func modal_open() -> bool:
	return (pair_sheet != null and pair_sheet.is_open()) or (settings_sheet != null and settings_sheet.is_open()) \
		or (more_sheet != null and more_sheet.is_open()) or (_kb_modal != null and _kb_modal.visible)


# ---------------------------------------------------------------- input and hints

func _unhandled_input(event: InputEvent) -> void:
	if not is_visible_in_tree() or service == null:
		return
	var guide: bool = (event is InputEventJoypadButton and event.button_index == JOY_BUTTON_GUIDE) \
		or (event is InputEventKey and event.keycode == KEY_F1)
	if guide:
		return
	if modal_open():
		# our sheets handle B themselves; nothing else leaks to the screen behind
		if event.is_pressed():
			get_viewport().set_input_as_handled()
		return
	var h := host()
	if h != null and h.get("page") != null:
		return
	if _pressed(event, JOY_BUTTON_X, KEY_S):
		open_settings(get_viewport().gui_get_focus_owner())
		get_viewport().set_input_as_handled()
	elif _pressed(event, JOY_BUTTON_Y, KEY_SLASH):
		open_add()
		get_viewport().set_input_as_handled()
	elif _pressed(event, JOY_BUTTON_START, KEY_M):
		open_more()
		get_viewport().set_input_as_handled()
	elif _pressed(event, JOY_BUTTON_BACK, KEY_R):
		service.refresh()
		_toast(T.SEARCHING, "search")
		get_viewport().set_input_as_handled()


static func _pressed(event: InputEvent, button: JoyButton, key: Key) -> bool:
	if event is InputEventJoypadButton:
		return event.pressed and event.button_index == button
	if event is InputEventKey:
		return event.pressed and not event.echo and event.keycode == key
	return false


## The hint bar for whatever has focus here (main.gd asks).
func hints(f: Control) -> Array:
	if pair_sheet != null and pair_sheet.is_open():
		return pair_sheet.hints()
	if settings_sheet != null and settings_sheet.is_open():
		return settings_sheet.hints()
	if more_sheet != null and more_sheet.is_open():
		return Sheet.hints()
	if _kb_modal != null and _kb_modal.visible:
		return [["A", "Type"], ["B", "Cancel"], ["MENU", "Done"]]
	var out: Array = []
	if f is HostCard:
		var hh: Dictionary = f.host
		match str(hh.get("status", "")):
			"asleep": out.append(["A", T.H_WAKE])
			"offline", "unknown": out.append(["A", T.H_REFRESH])
			"waking", "checking": pass
			_: out.append(["A", T.H_OPEN if bool(hh.get("paired", false)) else T.H_PAIR])
	elif f != null and f.get("game") is Dictionary and (f.get("game") as Dictionary).has("stream"):
		out.append(["A", T.H_STREAM])
	elif f is Button and f.visible:
		out.append(["A", f.text if f.text != "" else "Select"])
	if selected_id != "":
		out.append(["X", T.H_SETTINGS])
	out.append(["Y", T.H_ADD])
	if selected_id != "":
		out.append(["MENU", T.H_MORE])
	out.append(["VIEW", T.SEARCH_AGAIN])
	out.append(["B", T.H_HOME])
	return out
