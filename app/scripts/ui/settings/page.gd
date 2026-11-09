extends VBoxContainer
## Base for one Settings category: cards of rows. `build()` fills it from the
## services; `focusables()` is its focus chain, top to bottom. Pages rebuild
## themselves when their service says something changed, keeping focus on the
## same row (rows are named after their setting).

const Kit := preload("res://scripts/ui/ui_kit.gd")
const SKit := preload("res://scripts/ui/settings/kit.gd")
const TS := preload("res://scripts/ui/texts_settings.gd")
const ChoiceRow := preload("res://scripts/ui/choice_row.gd")
const ActionRow := preload("res://scripts/ui/settings/action_row.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")

## The focus chain changed (rebuilt); the screen relinks it.
signal rebuilt

var id := ""
var services := {}
## The settings screen: ask_text(), notify(), open_sign_in(), etc.
var host: Object
var _focusables: Array = []
var rows := {}


func setup(page_id: String, svc: Dictionary, host_obj: Object) -> void:
	id = page_id
	name = "Page_" + page_id
	services = svc
	host = host_obj
	add_theme_constant_override("separation", 18)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_connect()
	rebuild()


## Subclasses: connect service signals here (once).
func _connect() -> void:
	pass


## Subclasses: add cards with add_card() and rows with add_row().
func build() -> void:
	pass


func rebuild() -> void:
	var keep := _focused_row()
	for c in get_children():
		Kit.drop(self, c)
	_focusables.clear()
	rows.clear()
	build()
	rebuilt.emit()
	if keep != "" and rows.has(keep) and is_inside_tree():
		Kit.focus_later(rows[keep].button)


func focusables() -> Array:
	return _focusables


func svc(name_: String) -> Object:
	return services.get(name_)


func add_card(title: String, icon: String, line := "") -> VBoxContainer:
	var c := SKit.card(title, icon, line)
	add_child(c[0])
	return c[1]


## Adds a row (choice_row / action_row / anything with `.button`) to `box`.
func add_row(box: Control, r: Control) -> Control:
	box.add_child(r)
	if "key" in r and str(r.key) != "":
		rows[str(r.key)] = r
	_focusables.append(r.button)
	return r


func add_focusable(box: Control, c: Control) -> Control:
	box.add_child(c)
	_focusables.append(c)
	return c


func choice(box: Control, key: String, title: String, vals: Array, lbls: Array, current: Variant, explain: Callable, icon := "") -> VBoxContainer:
	var r: VBoxContainer = ChoiceRow.new()
	r.setup(key, title, vals, lbls, current, icon)
	r.set_explainer(explain)
	add_row(box, r)
	return r


func toggle(box: Control, key: String, title: String, current: bool, explain: Callable, icon := "") -> VBoxContainer:
	return choice(box, key, title, [false, true], ["Off", "On"], current, explain, icon)


func action_row(box: Control, key: String, title: String, value := "", hint := "", icon := "") -> VBoxContainer:
	var r: VBoxContainer = ActionRow.new()
	r.setup(key, title, value, hint, icon)
	add_row(box, r)
	return r


## Explanation that ignores the value.
static func fixed(text: String) -> Callable:
	return func(_v): return text


## Explanation from a {value: text} map.
static func by_value(map: Dictionary) -> Callable:
	return func(v): return str(map.get(v, ""))


func _focused_row() -> String:
	if not is_inside_tree():
		return ""
	var f := get_viewport().gui_get_focus_owner()
	if f == null or not is_ancestor_of(f):
		return ""
	return String(f.get_parent().name)


func notify(text: String, tone := "") -> void:
	if host != null and host.has_method("notify"):
		host.notify(text, tone)
