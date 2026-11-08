extends VBoxContainer
## One device fix in the quick menu's Device section: name and state on top,
## a plain explanation, and one button (Install, Remove or Check again).
## States where nothing can be done (not needed, doesn't apply, ...) get a note
## instead of a button, so `button` is null there.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const Texts := preload("res://scripts/ui/texts.gd")

## verb: "install", "remove" or "status" (check again).
signal action(fix: String, verb: String)

const INSTALL_STATES := ["off"]
const REMOVE_STATES := ["on", "partial", "restart"]
const BUSY_STATES := ["checking", "working"]

var fix := ""
var state := ""
var button: Button
var state_label: Label


## `fix_state`: the helper's state= value, or "checking" / "working" / "unknown".
func setup(fix_name: String, fix_state: String) -> void:
	fix = fix_name
	state = fix_state
	name = fix_name
	add_theme_constant_override("separation", 4)

	var head := Kit.hbox()
	var title := Kit.label(Texts.fix_title(fix))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	state_label = Kit.label(Texts.fix_state(state, fix), "AccentLabel" if state == "on" else "QuietLabel")
	state_label.name = "State"
	head.add_child(state_label)
	add_child(head)

	var explain := Kit.label(Texts.fix_explain(fix), "QuietLabel", true)
	explain.name = "Explain"
	add_child(explain)
	if Texts.FIX_STATE_NOTES.has(state):
		var note := Kit.label(Texts.FIX_STATE_NOTES[state], "QuietLabel", true)
		note.name = "Note"
		add_child(note)

	var verb := verb_for(state)
	if verb == "" and state not in BUSY_STATES:
		return
	button = Kit.button(button_text(state))
	button.name = "Button"
	button.custom_minimum_size = Vector2(0, 54)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.pressed.connect(func():
		if verb != "":
			action.emit(fix, verb))
	add_child(button)


## What the button does in `fix_state`: "install", "remove", "status" or "" (nothing).
static func verb_for(fix_state: String) -> String:
	if fix_state in INSTALL_STATES:
		return "install"
	if fix_state in REMOVE_STATES:
		return "remove"
	if fix_state == "unknown":
		return "status"
	return ""


static func button_text(fix_state: String) -> String:
	match verb_for(fix_state):
		"install": return "Install"
		"remove": return "Remove"
		"status": return "Check again"
	return Texts.fix_state(fix_state)
