extends PanelContainer
## GameCove's on-screen keyboard, for typing with a controller, a finger or a
## mouse wherever GameCove asks for text: search, sign-in codes and keys,
## collection names, a wishlist's Steam name, a streaming host, launch options.
## (In a game, typing is Steam's keyboard; this one never leaves GameCove.)
##
## A glass sheet with the text field on top (a caret, and text that scrolls
## when it's longer than the field), a letters page with a number row, a
## symbols page with every other printable ASCII character, and an action row:
## Shift (once for one capital, twice for Caps), symbols, space, the caret left
## and right, backspace, clear and Done.
##
## Controller: A types the focused key, X backspace, Y space, LT or L3 shift,
## RT symbols, LB / RB move the caret, Menu is Done, B closes. A held D-pad
## direction keeps moving (rows and columns wrap around), held backspace keeps
## deleting. The keys show those buttons. A physical keyboard types as usual
## (Ctrl+V pastes).
##
## Emits text_changed on every change and closed(text) on Done / B / Enter.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const Icons := preload("res://scripts/ui/icons.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const Motion := preload("res://scripts/ui/motion.gd")
const Drawer := preload("res://scripts/ui/drawer.gd")

signal text_changed(text: String)
signal closed(text: String)

## The letters page: a number row over qwerty, with the four marks typed most.
const ROWS := ["1234567890", "qwertyuiop", "asdfghjkl'", "zxcvbnm-:."]
## The symbols page: with the letters page, every printable ASCII character.
const SYMBOL_ROWS := ["!@#$%^&*", "()[]{}<>", "-_=+/\\|~", ";:'\",.?`"]
## Accented letters (the Accents key): the ones the stores and the ROM sets use, each typed lower case and a capital with Shift.
const ACCENT_ROWS := ["àáâãäåæç", "èéêëìíîïñ", "òóôõöøœš", "ùúûüýÿžð"]
const MAX_LEN := 40
## A letter key, layout px: big enough for a thumb at 1280x800 on a 7" screen.
const KEY := Vector2(66, 52)
const GAP := 8
## Held D-pad / backspace / caret: the wait before it repeats, then the pace.
const REPEAT_DELAY := 0.40
const REPEAT_RATE := 0.075
## How far the sheet slides up as it opens, px (0 under Reduce motion).
const SLIDE := 24.0
## Characters shown when the field's width isn't known yet (outside the tree).
const FIELD_CHARS := 48

var text := ""
## Where the next character goes: 0 .. text.length().
var caret := 0
## Longest text accepted (search keeps MAX_LEN). Sign-in codes need more.
var max_len := MAX_LEN
## Grey line shown while empty.
var placeholder := "Type to search"
## Keep upper case from a physical keyboard (codes, keys, names). Search
## doesn't: it matches either way, and lower case reads calmer.
var keep_case := false
## Capitals are on: for the next letter only, or for all while `caps`.
var shift := false
var caps := false
## The symbols page is showing.
var symbols := false
## The accents page is up (symbols is true then too, so RT goes back to the letters).
var accents := false
## Shown as dots (an API key or a password); Show reveals it.
var masked := false
var revealed := false
var accents_button: Button
var show_button: Button
var _original := ""
## The last close was a Cancel (B, Esc): the text handed back is the old one, and an owner that would save or
## check what it is given (an API key) can skip that.
var cancelled := false
## The rows of keys on screen now (the page showing, then the action row),
## for focus and for callers that look a key up by its text.
var keys: Array = []
var field: Label
var shift_button: Button
var symbols_button: Button
var space_button: Button
var left_button: Button
var right_button: Button
var back_button: Button
var clear_button: Button
var done_button: Button
## Open from open() until close(): it takes keys only then, not while it fades
## out (a press right after Done goes to the screen, not into the text).
var showing := false
## Every keyboard is in this group while it's in the tree (main.gd puts them away when their screen is left).
const GROUP := "osk"
var _was_seen := false
## Paste, beside the field: only where a code or key is asked for (use_for_codes).
var paste_button: Button
## func() -> String: the clipboard; tests return canned text.
var read_clipboard: Callable = func() -> String:
	return DisplayServer.clipboard_get() if DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD) else ""

var _col: VBoxContainer
var _head_icon: TextureRect
var _caret: ColorRect
var _pages: Array = []          # [letters VBox, symbols VBox]
var _page_rows: Array = []      # [letters rows, symbols rows] of Buttons
var _action_row: Array = []
var _letters: Array = []        # [Button, lower-case char]
var _win_start := 0             # first character of `text` the field shows
var _win_end := 0               # one past the last character it shows
var _repeat: Timer
var _repeat_what := ""
var _lt := false
var _rt := false
var _back_held := false
var _base_offsets := Vector2.ZERO
var _have_base := false
var _styling := false


func _init() -> void:
	name = "Keyboard"
	theme_type_variation = "GlassPanel"
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	# Callers pin the sheet's foot; when it needs more height it grows upward.
	grow_vertical = Control.GROW_DIRECTION_BEGIN
	_col = Kit.vbox(10)
	add_child(_col)
	_build_head()
	for rows in [ROWS, SYMBOL_ROWS, ACCENT_ROWS]:
		var page := Kit.vbox(GAP)
		page.name = ["Letters", "Symbols", "Accents"][_pages.size()]
		var list: Array = []
		var total := ROWS[0].length() * KEY.x + (ROWS[0].length() - 1) * GAP
		for r in rows:
			var row := Kit.hbox(GAP)
			row.alignment = BoxContainer.ALIGNMENT_CENTER
			var made: Array = []
			var w := floorf((total - (r.length() - 1) * GAP) / r.length())
			for ch in r:
				var b := _key(ch.to_upper() if _is_letter(ch) else ch, Vector2(w, KEY.y))
				b.pressed.connect(type.bind(ch))
				if _is_letter(ch):
					_letters.append([b, ch])
				row.add_child(b)
				made.append(b)
			page.add_child(row)
			list.append(made)
		_col.add_child(page)
		_pages.append(page)
		_page_rows.append(list)
	_pages[1].visible = false
	_pages[2].visible = false
	_build_actions()
	_repeat = Timer.new()
	_repeat.name = "Repeat"
	_repeat.one_shot = true
	_repeat.timeout.connect(_on_repeat)
	add_child(_repeat)
	_show_page()
	_refresh_case()
	_refresh_field()


static func _is_letter(ch: String) -> bool:
	return ch.length() == 1 and ch.to_lower() != ch.to_upper()


func _build_head() -> void:
	var head := Kit.hbox(12)
	head.name = "FieldRow"
	_head_icon = Icons.rect("search", 22, ThemeLib.color("text_2"))
	head.add_child(_head_icon)
	var well := PanelContainer.new()
	well.name = "FieldWell"
	well.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	well.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(well)
	field = Kit.label("", "LeadLabel")
	field.name = "Field"
	field.clip_text = true
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	field.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	field.resized.connect(_refresh_field)
	# A tap or click in the text puts the caret there.
	field.mouse_filter = Control.MOUSE_FILTER_STOP
	field.gui_input.connect(_field_input)
	well.add_child(field)
	_caret = ColorRect.new()
	_caret.name = "Caret"
	_caret.mouse_filter = Control.MOUSE_FILTER_IGNORE
	field.add_child(_caret)
	paste_button = _key("Paste", Vector2(84, 40))
	paste_button.name = "Paste"
	paste_button.add_theme_font_size_override("font_size", ThemeLib.SIZE_SMALL)
	paste_button.visible = false
	paste_button.pressed.connect(paste)
	head.add_child(paste_button)
	show_button = _key("Show", Vector2(84, 40))
	show_button.name = "Show"
	show_button.add_theme_font_size_override("font_size", ThemeLib.SIZE_SMALL)
	show_button.visible = false
	show_button.pressed.connect(toggle_reveal)
	head.add_child(show_button)
	var tips := Kit.prompts([["B", "Cancel"], ["MENU", "Done"]])
	tips.name = "Tips"
	head.add_child(tips)
	_col.add_child(head)
	_style()


## A key: a glass button that pulses when it's pressed.
func _key(label: String, size: Vector2) -> Button:
	var b := Kit.button(label, "KeyButton")
	b.custom_minimum_size = size
	b.button_down.connect(_pulse.bind(b))
	return b


## An action key: the controller button that does the same, then its icon or
## word, drawn inside the key (the Button itself has no text, its tooltip
## says what it is).
func _action(key_name: String, glyph: String, icon: String, word: String, width: float) -> Button:
	var b := _key("", Vector2(width, KEY.y))
	b.name = key_name
	b.tooltip_text = word if word != "" else key_name
	var row := Kit.hbox(6)
	row.name = "Face"
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if glyph != "":
		row.add_child(Kit.glyph(glyph, false, true))
	if icon != "":
		# white, tinted by its state's ink (_ink_action)
		var ic := Icons.rect(icon, 20, Color.WHITE)
		ic.name = "Icon"
		row.add_child(ic)
	if word != "" and icon == "":
		var l := Kit.label(word)
		l.name = "Word"
		l.add_theme_font_override("font", ThemeLib.font("semibold"))
		l.add_theme_font_size_override("font_size", ThemeLib.SIZE_SMALL)
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(l)
	b.add_child(row)
	b.focus_entered.connect(_ink_action.bind(b))
	b.focus_exited.connect(_ink_action.bind(b))
	return b


func _build_actions() -> void:
	var last := Kit.hbox(GAP)
	last.name = "Actions"
	last.alignment = BoxContainer.ALIGNMENT_CENTER
	shift_button = _action("Shift", "LT", "arrow_up", "Shift", 76)
	shift_button.pressed.connect(press_shift)
	symbols_button = _action("SymbolsKey", "RT", "", "?123", 92)
	symbols_button.pressed.connect(toggle_symbols)
	space_button = _action("Space", "Y", "", "Space", 60)
	space_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	space_button.pressed.connect(type.bind(" "))
	left_button = _action("CaretLeft", "LB", "chevron_left", "Left", 62)
	left_button.pressed.connect(move_caret.bind(-1))
	right_button = _action("CaretRight", "RB", "chevron_right", "Right", 62)
	right_button.pressed.connect(move_caret.bind(1))
	back_button = _action("Backspace", "X", "backspace", "Backspace", 70)
	# Held (a finger, the mouse, A): the first one goes at once, then it repeats.
	back_button.button_down.connect(func():
		_back_held = true
		backspace()
		_start_repeat("back"))
	back_button.button_up.connect(func(): _stop_repeat("back"))
	back_button.pressed.connect(func():
		if not _back_held:
			backspace()
		_back_held = false)
	accents_button = _action("Accents", "", "", "áé", 60)
	accents_button.pressed.connect(toggle_accents)
	clear_button = _action("Clear", "", "", "Clear", 64)
	clear_button.pressed.connect(func(): set_text(""))
	done_button = Kit.button("Done", "AccentButton")
	done_button.name = "Done"
	done_button.custom_minimum_size = Vector2(118, KEY.y)
	done_button.add_theme_font_size_override("font_size", ThemeLib.SIZE_BODY)
	load("res://scripts/ui/button_fx.gd").attach(done_button, {"glyph": "MENU"})
	done_button.pressed.connect(close)
	_action_row = [shift_button, symbols_button, accents_button, space_button, left_button, right_button, back_button, clear_button, done_button]
	for b in _action_row:
		last.add_child(b)
	_col.add_child(last)


## Colours that don't come from a theme variation: the field's well, the
## caret, the modifier keys while they're on. All from the theme's tokens.
func _style() -> void:
	if field == null or _styling:
		return
	_styling = true
	# Near-opaque glass, like the drawers: the page behind mustn't ghost
	# through the keys (it did on the Light theme).
	var glass := Drawer.glass()
	glass.bg_color.a = 1.0
	add_theme_stylebox_override("panel", glass)
	_styling = false
	var well := field.get_parent() as PanelContainer
	var wb := ThemeLib.box(ThemeLib.soft(0.06), ThemeLib.radius("s"), 12, 6)
	wb.border_color = ThemeLib.color("line_2")
	wb.set_border_width_all(1)
	well.add_theme_stylebox_override("panel", wb)
	_caret.color = ThemeLib.color("accent")
	if shift_button != null:
		_mark(shift_button, shift, caps)
		_mark(symbols_button, symbols, false)
		for b in _action_row:
			_ink_action(b)
	_refresh_field()


## A modifier key that's on wears the accent: a tint with the theme's text for
## "on", the solid accent with its own ink for Caps. Off: the plain key.
func _mark(b: Button, on: bool, strong: bool) -> void:
	for st in ["normal", "hover"]:
		if not on:
			b.remove_theme_stylebox_override(st)
			continue
		var acc: Color = ThemeLib.color("accent")
		var base: Color = ThemeLib.color("surface_2")
		var fill := acc if strong else Color(base.r, base.g, base.b, 1.0).lerp(Color(acc.r, acc.g, acc.b, 1.0), 0.24)
		var sb := ThemeLib.box(fill, ThemeLib.radius("s"), 6, 6)
		sb.border_color = acc
		sb.set_border_width_all(1)
		b.add_theme_stylebox_override(st, sb)
	b.set_meta("on", on)
	b.set_meta("strong", on and strong)
	_ink_action(b)


## An action key's icon and word take the colour its state gives text: the
## focus ink on the focused key, the accent's ink on a Caps key, else the text.
func _ink_action(b: Button) -> void:
	var face := b.get_node_or_null("Face")
	if face == null:
		return
	var col: Color = ThemeLib.color("text")
	if b.has_focus():
		col = ThemeLib.color("on_focus")
	elif b.get_meta("strong", false):
		col = ThemeLib.color("on_accent")
	for c in face.get_children():
		if c is Label:
			(c as Label).add_theme_color_override("font_color", col)
		elif c is TextureRect and c.name == "Icon":
			(c as TextureRect).modulate = col
	b.set_meta("ink", col)


func _notification(what: int) -> void:
	if what == NOTIFICATION_ENTER_TREE:
		add_to_group(GROUP)
	elif what == NOTIFICATION_THEME_CHANGED and field != null:
		_style()
	elif what == NOTIFICATION_VISIBILITY_CHANGED:
		_on_seen_changed(is_visible_in_tree())


## It can be seen now (true) or not (false: it, or a screen above it, was hidden).
func _on_seen_changed(seen: bool) -> void:
	if not seen:
		_stop_repeat()
	# Hidden without close() (its screen went away, Guide, the quick menu): it is closed. Left
	# "showing" it kept taking every key and button, unseen (review Medium, input).
	if _was_seen and not seen and showing:
		showing = false
		visible = false
	_was_seen = seen


# ---- pages, focus --------------------------------------------------------------

func _show_page() -> void:
	_pages[0].visible = not symbols
	_pages[1].visible = symbols and not accents
	_pages[2].visible = accents
	keys = []
	var head_keys: Array = [paste_button, show_button].filter(func(b): return b != null and b.visible)
	if not head_keys.is_empty():
		keys.append(head_keys)
	keys.append_array(_page_rows[_page_i()])
	keys.append(_action_row)
	_mark(accents_button, accents, false)
	var word := symbols_button.get_node("Face/Word") as Label
	word.text = "ABC" if symbols else "?123"
	_mark(symbols_button, symbols, false)
	_link()


## Wire the grid so left/right wrap within a row and up/down keep the column
## (and wrap from the last row to the first).
func _link() -> void:
	for r in keys.size():
		var row: Array = keys[r]
		for i in row.size():
			var b: Button = row[i]
			b.focus_neighbor_left = b.get_path_to(row[posmod(i - 1, row.size())])
			b.focus_neighbor_right = b.get_path_to(row[posmod(i + 1, row.size())])
			var up: Array = keys[posmod(r - 1, keys.size())]
			var down: Array = keys[posmod(r + 1, keys.size())]
			b.focus_neighbor_top = b.get_path_to(up[mini(_column(i, row.size(), up.size()), up.size() - 1)])
			b.focus_neighbor_bottom = b.get_path_to(down[mini(_column(i, row.size(), down.size()), down.size() - 1)])


static func _column(i: int, from_n: int, to_n: int) -> int:
	return int(round(float(i) / maxf(1.0, from_n - 1) * (to_n - 1)))


func _page_i() -> int:
	return 2 if accents else (1 if symbols else 0)


## Letters <-> the accents page (the Accents key); RT goes back to the letters from it.
func toggle_accents() -> void:
	accents = not accents
	symbols = accents
	_show_page()
	if is_inside_tree():
		first_key_on_page().grab_focus()


func first_key_on_page() -> Button:
	return _page_rows[_page_i()][0][0]


## Letters <-> symbols (RT). Focus stays in the same place on the grid.
func toggle_symbols() -> void:
	var f: Control = get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	var at := Vector2i(-1, -1)
	var rows: Array = _page_rows[_page_i()]
	for r in rows.size():
		var i: int = rows[r].find(f)
		if i >= 0:
			at = Vector2i(r, i)
	var from_n: int = rows[at.x].size() if at.x >= 0 else 1
	symbols = not symbols
	accents = false
	_show_page()
	if at.x >= 0 and is_inside_tree():
		var row: Array = _page_rows[_page_i()][at.x]
		row[mini(_column(at.y, from_n, row.size()), row.size() - 1)].grab_focus()


## The first letter key (where focus starts).
func first_key() -> Button:
	return _page_rows[0][1][0]


# ---- shift ---------------------------------------------------------------------

## What the Shift key does: off -> the next letter is a capital -> Caps -> off.
func press_shift() -> void:
	if not shift:
		shift = true
		caps = false
	elif not caps:
		caps = true
	else:
		shift = false
		caps = false
	_refresh_case()


## Capitals on or off until changed (what callers and tests ask for outright).
func toggle_shift() -> void:
	shift = not shift
	caps = shift
	_refresh_case()


func _set_shift(on: bool) -> void:
	shift = on
	caps = on
	_refresh_case()


func _refresh_case() -> void:
	for pair in _letters:
		pair[0].text = pair[1].to_upper() if shift else pair[1]
	if shift_button != null:
		_mark(shift_button, shift, caps)
		shift_button.tooltip_text = "Caps" if caps else "Shift"


# ---- text ------------------------------------------------------------------------

func open(start := "") -> void:
	showing = true
	set_text(start, false)
	shift = false
	caps = false
	_original = start
	cancelled = false
	revealed = false
	if symbols or accents:
		symbols = false
		accents = false
		_show_page()
	_refresh_case()
	var was := visible
	Motion.fade(self, true)
	_slide_in(was)
	if is_inside_tree():
		first_key().grab_focus()


## The sheet rises a little as it fades in (not under Reduce motion, and not
## where a container places it).
func _slide_in(was_open: bool) -> void:
	if not _have_base:
		_base_offsets = Vector2(offset_top, offset_bottom)
		_have_base = true
	var dy := Motion.slide(SLIDE)
	if was_open or dy <= 0.0 or not is_inside_tree() or get_parent() is Container:
		return
	offset_top = _base_offsets.x + dy
	offset_bottom = _base_offsets.y + dy
	Motion.to(self, "offset_top", _base_offsets.x, Motion.BASE)
	Motion.to(self, "offset_bottom", _base_offsets.y, Motion.BASE)


func close() -> void:
	if not showing:
		return
	showing = false
	_stop_repeat()
	Motion.fade(self, false)
	closed.emit(text)


## Put away without `closed` (the screen it sits on was left: nothing there wants the focus back,
## and a keyboard still open under a fading screen would take the next B from what's in front).
func dismiss() -> void:
	if not showing:
		return
	showing = false
	_stop_repeat()
	Motion.fade(self, false)
## Closes without keeping what was typed: the text goes back to what it was when the keyboard opened, and the
## owner hears that first (a search shows its old list again), then closed with the old text.
func cancel() -> void:
	if not showing:
		return
	if text != _original:
		set_text(_original)
	cancelled = true
	close()


## Types `ch` at the caret (a letter as a capital while Shift is on).
func type(ch: String) -> void:
	if text.length() + ch.length() > max_len:
		return
	if shift and _is_letter(ch):
		ch = ch.to_upper()
		if not caps:
			shift = false
			_refresh_case()
	_insert(ch)


func _insert(s: String) -> void:
	var at := clampi(caret, 0, text.length())
	text = text.substr(0, at) + s + text.substr(at)
	caret = at + s.length()
	_changed()


## For codes and keys: longer text, a placeholder, case kept from a physical
## keyboard, and Paste beside the field.
func use_for_codes(hint: String, longest := 600, secret := false) -> void:
	placeholder = hint
	max_len = longest
	keep_case = true
	masked = secret
	revealed = false
	show_button.text = "Show"
	show_button.visible = secret
	_show_page()
	if not paste_button.visible:
		paste_button.visible = true
		_show_page()
	_set_shift(false)
	set_text(text, false)


## Show / Hide for a masked field.
func toggle_reveal() -> void:
	revealed = not revealed
	show_button.text = "Hide" if revealed else "Show"
	_refresh_field()


## What the field draws for `t`: the text, or a dot for each character while masked.
func _display(t: String) -> String:
	return "•".repeat(t.length()) if masked and not revealed else t


## Puts the clipboard's text at the caret (one line, as much as fits).
func paste() -> void:
	var s := str(read_clipboard.call()) if read_clipboard.is_valid() else ""
	s = s.replace("\r", "").replace("\n", " ").strip_edges()
	var clean := ""
	for i in s.length():
		if s.unicode_at(i) >= 32:
			clean += s[i]
	clean = clean.left(maxi(0, max_len - text.length()))
	if clean != "":
		_insert(clean if keep_case else clean.to_lower())


func backspace() -> void:
	if caret <= 0 or text == "":
		return
	text = text.substr(0, caret - 1) + text.substr(caret)
	caret -= 1
	_changed()


## Deletes the character after the caret (Delete on a physical keyboard).
func delete_forward() -> void:
	if caret >= text.length():
		return
	text = text.substr(0, caret) + text.substr(caret + 1)
	_changed()


## Moves the caret by `by` characters (LB / RB), within the text.
func move_caret(by: int) -> void:
	var to := clampi(caret + by, 0, text.length())
	if to != caret:
		caret = to
		_refresh_field()


## Replaces the text; the caret goes to its end.
func set_text(t: String, emit := true) -> void:
	text = t
	caret = t.length()
	_win_start = 0
	_refresh_field()
	if emit:
		text_changed.emit(text)


func _changed() -> void:
	_refresh_field()
	text_changed.emit(text)


# ---- the field: a window on the text that keeps the caret in view --------------------

func _field_font() -> Font:
	return field.get_theme_font("font")


func _width(s: String) -> float:
	return _field_font().get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, field.get_theme_font_size("font_size")).x


func _fits(s: String) -> bool:
	if field.size.x < 40.0:
		return s.length() <= FIELD_CHARS
	return _width(s) <= field.size.x - 6.0


func _refresh_field() -> void:
	if field == null or _caret == null:
		return
	var fs := field.get_theme_font_size("font_size")
	_caret.size = Vector2(2, fs + 6)
	var mid := (field.size.y - _caret.size.y) / 2.0 if field.size.y > 0.0 else 0.0
	if text == "":
		field.text = placeholder
		field.add_theme_color_override("font_color", ThemeLib.color("text_3"))
		_caret.position = Vector2(0, mid)
		_win_start = 0
		_win_end = 0
		return
	field.add_theme_color_override("font_color", ThemeLib.color("text"))
	var shown := _display(text)   # dots while masked; the caret and window count the same characters
	caret = clampi(caret, 0, shown.length())
	var a := clampi(_win_start, 0, shown.length())
	if caret < a:
		a = maxi(0, caret - 3)
	# Scroll right until the caret is in view.
	while a < caret and not _fits(("…" if a > 0 else "") + shown.substr(a, caret - a)):
		a += 1
	# Then show as much after the caret as fits.
	var b := caret
	while b < shown.length():
		var more := b + 1 < shown.length()
		if not _fits(("…" if a > 0 else "") + shown.substr(a, b + 1 - a) + ("…" if more else "")):
			break
		b += 1
	# With everything to the right in view, pull the start back as far as it goes.
	while b == shown.length() and a > 0 and _fits(("…" if a - 1 > 0 else "") + shown.substr(a - 1)):
		a -= 1
	_win_start = a
	_win_end = b
	var lead := "…" if a > 0 else ""
	field.text = lead + shown.substr(a, b - a) + ("…" if b < shown.length() else "")
	_caret.position = Vector2(_width(lead + shown.substr(a, caret - a)), mid)


## The caret position (0..text.length()) nearest to `x`, a pixel offset in the field.
func caret_index_at(x: float) -> int:
	var shown := _display(text)
	if text == "":
		return 0
	var lead := "…" if _win_start > 0 else ""
	var best := _win_start
	var best_d := INF
	for i in range(_win_start, _win_end + 1):
		var d := absf(_width(lead + shown.substr(_win_start, i - _win_start)) - x)
		if d < best_d:
			best_d = d
			best = i
	return best


## Puts the caret where the field was tapped or clicked.
func place_caret_at(x: float) -> void:
	var to := caret_index_at(x)
	if to != caret:
		caret = to
		_refresh_field()


func _field_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		place_caret_at(event.position.x)
		field.accept_event()


# ---- feedback, repeat ------------------------------------------------------------

func _pulse(b: Button) -> void:
	if Motion.reduce or not b.is_inside_tree():
		return
	b.pivot_offset = b.size / 2.0
	b.scale = Vector2(0.93, 0.93)
	Motion.to(b, "scale", Vector2.ONE, Motion.FAST)


func _start_repeat(what: String) -> void:
	_repeat_what = what
	if _repeat.is_inside_tree():
		_repeat.start(REPEAT_DELAY)


func _stop_repeat(what := "") -> void:
	if what != "" and what != _repeat_what:
		return
	_repeat_what = ""
	if _repeat != null:
		_repeat.stop()


func _on_repeat() -> void:
	if _repeat_what == "" or not is_visible_in_tree():
		_stop_repeat()
		return
	repeat_step(_repeat_what)
	if _repeat_what != "" and _repeat.is_inside_tree():
		_repeat.start(REPEAT_RATE)


## One repeat of a held button: "back", "caret_left", "caret_right", or a
## D-pad direction ("left", "right", "top", "bottom": focus moves on, wrapping).
func repeat_step(what: String) -> void:
	match what:
		"back": backspace()
		"caret_left": move_caret(-1)
		"caret_right": move_caret(1)
		_: move_focus(what)


## Moves focus one key toward `side` ("left", "right", "top", "bottom").
func move_focus(side: String) -> void:
	if not is_inside_tree():
		return
	var f := get_viewport().gui_get_focus_owner()
	if f == null or not is_ancestor_of(f):
		return
	var path: NodePath = f.get("focus_neighbor_" + side)
	var n := f.get_node_or_null(path) as Control
	if n != null:
		n.grab_focus()


const DPAD := {JOY_BUTTON_DPAD_LEFT: "left", JOY_BUTTON_DPAD_RIGHT: "right", JOY_BUTTON_DPAD_UP: "top", JOY_BUTTON_DPAD_DOWN: "bottom"}


## Open and taking keys (false as soon as Done is pressed, while it fades out).
func is_open() -> bool:
	return showing


## This keyboard or a screen above it is hidden (walks the parents, so it also holds outside a live tree).
func _hidden() -> bool:
	var n: Node = self
	while n != null:
		if n is CanvasItem and not (n as CanvasItem).visible:
			return true
		n = n.get_parent()
	return false


func _input(event: InputEvent) -> void:
	if not showing:
		return
	# Open on a screen that has since been left (Library search, then Guide to Home): hidden, the
	# keyboard must not take B, Start, X, Y or the bumpers from whatever is in front now
	if _hidden():
		return
	var handled := true
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_BACKSPACE:
			backspace()
		elif event.keycode == KEY_DELETE:
			delete_forward()
		elif event.keycode == KEY_HOME:
			move_caret(-text.length())
		elif event.keycode == KEY_END:
			move_caret(text.length())
		elif event.keycode == KEY_ESCAPE:
			cancel()
		elif event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER:
			close()
		elif event.ctrl_pressed and event.keycode == KEY_V:
			paste()
		elif event.unicode >= 32 and event.unicode < 0x10000 and not event.ctrl_pressed:
			var ch := String.chr(event.unicode)
			if text.length() < max_len:
				_insert(ch if keep_case else ch.to_lower())
		else:
			handled = false
	elif event is InputEventJoypadButton:
		handled = _pad_button(event.button_index, event.pressed)
	elif event is InputEventJoypadMotion and (event.axis == JOY_AXIS_TRIGGER_LEFT or event.axis == JOY_AXIS_TRIGGER_RIGHT):
		# Triggers are axes: act once as one is pulled, again only after it's let go.
		var down: bool = event.axis_value > 0.5
		var up: bool = event.axis_value < 0.3
		if event.axis == JOY_AXIS_TRIGGER_LEFT:
			if down and not _lt:
				_lt = true
				press_shift()
			elif up:
				_lt = false
		else:
			if down and not _rt:
				_rt = true
				toggle_symbols()
			elif up:
				_rt = false
	else:
		handled = false
	if handled and get_viewport() != null:
		get_viewport().set_input_as_handled()


## A controller button went down or up; true when the keyboard took it.
func _pad_button(button: int, pressed: bool) -> bool:
	if DPAD.has(button):
		# The first step is the usual focus move; holding repeats it.
		if pressed:
			_start_repeat(DPAD[button])
		else:
			_stop_repeat(DPAD[button])
		return false
	if not pressed:
		match button:
			JOY_BUTTON_X: _stop_repeat("back")
			JOY_BUTTON_LEFT_SHOULDER: _stop_repeat("caret_left")
			JOY_BUTTON_RIGHT_SHOULDER: _stop_repeat("caret_right")
			_: return false
		return true
	match button:
		JOY_BUTTON_Y:
			type(" ")
		JOY_BUTTON_X:
			backspace()
			_start_repeat("back")
		JOY_BUTTON_B:
			cancel()
		JOY_BUTTON_START:
			close()
		JOY_BUTTON_LEFT_STICK:
			press_shift()
		JOY_BUTTON_LEFT_SHOULDER:
			move_caret(-1)
			_start_repeat("caret_left")
		JOY_BUTTON_RIGHT_SHOULDER:
			move_caret(1)
			_start_repeat("caret_right")
		_:
			return false
	return true
