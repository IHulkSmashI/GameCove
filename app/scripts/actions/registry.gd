extends RefCounted
## The one list of one-press actions. The quick menu's Shortcuts strip, the
## back buttons and the hold on a handheld's extra buttons all pick from it, so
## an action has one name, one icon, one availability rule and one way to run
## (scripts/actions/runner.gd) wherever it shows up.
##
## Pure data and lookups: nothing here touches the system.
##
## An action:
##   id      stable name ("keyboard", "key_alt_enter")
##   title   full name for lists ("Mute sound")
##   short   one or two words under the strip's icon ("Mute")
##   icon    cicons.gd / icons.gd name
##   help    one plain line
##   kind    "run" (does it), "toggle" (on / off with a state), "cycle" (next
##           value), "sheet" (opens a short list), "key" (types keys at the game)
##   control the Control id behind it ("" when it isn't a Control)
##   keys    kind "key": InputPlumber keyboard names, held together in order
##   game    "front" when it only makes sense with a game on screen, "running"
##           when one must run, "" otherwise
##   strip   offered on the Shortcuts strip
##   button  offered for a back button's press and an extra button's hold
##   confirm asks before it runs (strip: a sheet; button: hold to confirm)
##
## Availability words (Runner.context()): see why_not().

const ACTIONS := [
	{"id": "keyboard", "title": "Keyboard", "short": "Keyboard", "icon": "keyboard", "kind": "run", "game": "front",
		"help": "Opens Steam's on-screen keyboard over the game, so you can type in it.", "strip": true, "button": true},
	{"id": "steam_menu", "title": "Steam menu", "short": "Steam", "icon": "steam", "kind": "run", "game": "front",
		"help": "Opens Steam's own quick access menu over the game: friends, notifications, Steam's settings.", "strip": true, "button": true},
	{"id": "screenshot", "title": "Screenshot", "short": "Capture", "icon": "camera", "kind": "run", "control": "system.screenshot",
		"help": "Saves a picture of the game to Pictures/Screenshots.", "strip": true, "button": true},
	{"id": "record", "title": "Record", "short": "Record", "icon": "record", "kind": "toggle",
		"help": "Starts recording the screen, or stops and saves the clip.", "strip": true, "button": true},
	{"id": "mouse_mode", "title": "Mouse mode", "short": "Mouse", "icon": "mouse", "kind": "toggle", "control": "controller.desktop_mode",
		"help": "Right stick moves the pointer, right trigger clicks. For launchers and dialogs.", "strip": true, "button": true},
	{"id": "mute", "title": "Mute sound", "short": "Mute", "icon": "volume_off", "kind": "toggle", "control": "audio.mute",
		"help": "Turns the sound off and back on.", "strip": true, "button": true},
	{"id": "send_key", "title": "Send a key", "short": "Send key", "icon": "key", "kind": "sheet", "game": "front",
		"help": "Presses Esc, Enter, Tab, Alt+Enter or Alt+F4 in the game. For stuck launchers and dialogs.", "strip": true, "button": false},
	{"id": "sleep", "title": "Sleep now", "short": "Sleep", "icon": "moon", "kind": "run", "control": "system.sleep",
		"help": "Puts the handheld to sleep. The game waits where you left it.", "strip": true, "button": true},
	{"id": "perf_overlay", "title": "Performance overlay", "short": "Overlay", "icon": "overlay", "kind": "cycle", "control": "perf.overlay",
		"help": "Steps through the overlay: off, frame rate, bar, full.", "strip": true, "button": true},
	{"id": "mic_mute", "title": "Mute microphone", "short": "Mic", "icon": "mic", "kind": "toggle", "control": "audio.mic_mute",
		"help": "Turns the microphone off and back on.", "strip": true, "button": true},
	{"id": "wifi", "title": "Wi-Fi", "short": "Wi-Fi", "icon": "wifi", "kind": "toggle", "control": "network.wifi",
		"help": "Turns Wi-Fi off and back on.", "strip": true, "button": false},
	{"id": "bluetooth", "title": "Bluetooth", "short": "Bluetooth", "icon": "bluetooth", "kind": "toggle", "control": "network.bluetooth",
		"help": "Turns Bluetooth off and back on.", "strip": true, "button": false},
	{"id": "airplane", "title": "Airplane mode", "short": "Airplane", "icon": "airplane", "kind": "toggle", "control": "network.airplane",
		"help": "Turns every radio off, and puts back what was on.", "strip": true, "button": false},
	{"id": "night_light", "title": "Night light", "short": "Night light", "icon": "sun", "kind": "toggle", "control": "display.night_light",
		"help": "Warmer colours for the evening.", "strip": true, "button": true},
	{"id": "force_close", "title": "Force close game", "short": "Force close", "icon": "x", "kind": "run", "game": "running", "confirm": true,
		"help": "Ends a game that hangs, at once. Anything it hasn't saved is lost.", "strip": true, "button": true},
	{"id": "power_menu", "title": "Power", "short": "Power", "icon": "power", "kind": "sheet",
		"help": "Restart, shut down, or switch to Desktop Mode or Steam Gaming Mode.", "strip": true, "button": false},
	# buttons only: the strip lives inside the quick menu, and Exit game has its own row there
	{"id": "quick_menu", "title": "Open the quick menu", "short": "Quick menu", "icon": "sliders", "kind": "run",
		"help": "Opens GameCove's quick menu over the game.", "strip": false, "button": true},
	{"id": "exit_game", "title": "Exit game", "short": "Exit game", "icon": "power", "kind": "run", "game": "running", "confirm": true,
		"help": "Closes the game the polite way. Hold the button to confirm.", "strip": false, "button": true},
	# keys typed at the game: the Send key sheet's rows, and what a button can press
	{"id": "key_esc", "title": "Esc", "short": "Esc", "icon": "key", "kind": "key", "keys": ["KeyEsc"], "game": "front",
		"help": "Backs out of a menu or a launcher's dialog.", "strip": false, "button": true},
	{"id": "key_enter", "title": "Enter", "short": "Enter", "icon": "key", "kind": "key", "keys": ["KeyEnter"], "game": "front",
		"help": "Confirms a dialog.", "strip": false, "button": true},
	{"id": "key_tab", "title": "Tab", "short": "Tab", "icon": "key", "kind": "key", "keys": ["KeyTab"], "game": "front",
		"help": "Moves to the next button or field.", "strip": false, "button": true},
	{"id": "key_alt_enter", "title": "Alt + Enter", "short": "Alt+Enter", "icon": "key", "kind": "key", "keys": ["KeyLeftAlt", "KeyEnter"], "game": "front",
		"help": "Switches most games between a window and full screen.", "strip": false, "button": true},
	{"id": "key_alt_f4", "title": "Alt + F4", "short": "Alt+F4", "icon": "key", "kind": "key", "keys": ["KeyLeftAlt", "KeyF4"], "game": "front",
		"help": "Asks the window in front to close.", "strip": false, "button": true},
	{"id": "key_optiscaler", "title": "OptiScaler's menu", "short": "OptiScaler", "icon": "upscale", "kind": "key", "keys": ["KeyInsert"], "game": "front",
		"help": "Presses Insert, which opens OptiScaler's menu in games that use it.", "strip": false, "button": true, "needs": "optiscaler"},
	{"id": "key_optiscaler_fg", "title": "OptiScaler frame generation", "short": "Frame gen", "icon": "frames", "kind": "key", "keys": ["KeyEnd"], "game": "front",
		"help": "Presses End, which turns OptiScaler's frame generation on and off.", "strip": false, "button": true, "needs": "optiscaler"},
]

## The strip when nobody changed it.
const STRIP_DEFAULT := ["keyboard", "steam_menu", "screenshot", "record", "mouse_mode", "mute", "send_key", "sleep"]
## The Send key sheet, top to bottom.
const SEND_KEYS := ["key_esc", "key_enter", "key_tab", "key_alt_enter", "key_alt_f4"]
## Power sheet rows: id -> [title, detail, icon, tone].
const POWER_ROWS := [
	["restart", "Restart", "Closes everything and starts the handheld again.", "restart", ""],
	["shutdown", "Shut down", "Closes everything and turns the handheld off.", "power", ""],
	["desktop", "Switch to Desktop Mode", "Leaves GameCove for the desktop.", "screen", ""],
	["steam", "Switch to Steam Gaming Mode", "Leaves GameCove for Steam's own Gaming Mode.", "external", ""],
]

## Why an action can't run here, in plain words (why_not()).
const WHY := {
	"no_game_front": "Shows while a game is on screen.",
	"no_game": "Shows while a game runs.",
	"no_steam": "Needs Steam running.",
	"no_keys": "Needs InputPlumber, which presses the keys.",
	"no_steam_menu": "Needs InputPlumber, which hands the button to Steam.",
	"no_recorder": "Recording isn't available here.",
	"no_closer": "Not available here.",
	"no_optiscaler": "Shows for games that use OptiScaler.",
}

## Keys a button may press on its own or in a combination (InputPlumber keyboard
## names, src/dbus/interface/target/keyboard.rs; the profile form is "KeyEsc").
const KEY_NAMES := ["KeyEsc", "KeyEnter", "KeyTab", "KeySpace", "KeyBackspace", "KeyDelete", "KeyInsert", "KeyHome", "KeyEnd",
	"KeyPageUp", "KeyPageDown", "KeyUp", "KeyDown", "KeyLeft", "KeyRight",
	"KeyF1", "KeyF2", "KeyF3", "KeyF4", "KeyF5", "KeyF6", "KeyF7", "KeyF8", "KeyF9", "KeyF10", "KeyF11", "KeyF12",
	"KeyA", "KeyB", "KeyC", "KeyD", "KeyE", "KeyF", "KeyG", "KeyH", "KeyI", "KeyJ", "KeyK", "KeyL", "KeyM", "KeyN", "KeyO", "KeyP",
	"KeyQ", "KeyR", "KeyS", "KeyT", "KeyU", "KeyV", "KeyW", "KeyX", "KeyY", "KeyZ",
	"Key1", "Key2", "Key3", "Key4", "Key5", "Key6", "Key7", "Key8", "Key9", "Key0",
	"KeyGrave", "KeyMinus", "KeyEqual", "KeyComma", "KeyDot", "KeySlash", "KeySemicolon", "KeyApostrophe",
	"KeyLeftBrace", "KeyRightBrace", "KeyBackslash", "KeyCapslock", "KeyPause", "KeySysrq"]
const KEY_MODIFIERS := ["KeyLeftCtrl", "KeyLeftShift", "KeyLeftAlt", "KeyLeftMeta"]
const KEY_LABELS := {"KeyEsc": "Esc", "KeyLeftCtrl": "Ctrl", "KeyLeftShift": "Shift", "KeyLeftAlt": "Alt", "KeyLeftMeta": "Super",
	"KeyPageUp": "Page Up", "KeyPageDown": "Page Down", "KeyGrave": "`", "KeyMinus": "-", "KeyEqual": "=", "KeyComma": ",",
	"KeyDot": ".", "KeySlash": "/", "KeySemicolon": ";", "KeyApostrophe": "'", "KeyLeftBrace": "[", "KeyRightBrace": "]",
	"KeyBackslash": "\\", "KeyCapslock": "Caps Lock", "KeySysrq": "Print Screen", "KeyBackspace": "Backspace"}

static var _by_id := {}


static func _index() -> Dictionary:
	if _by_id.is_empty():
		for a in ACTIONS:
			_by_id[a["id"]] = a
	return _by_id


static func has(id: String) -> bool:
	return _index().has(id)


## The action called `id` ({} when there is none), with every field filled in.
static func action(id: String) -> Dictionary:
	var a: Variant = _index().get(id)
	if a == null:
		return {}
	var out: Dictionary = (a as Dictionary).duplicate(true)
	for k in ["control", "game", "needs"]:
		if not out.has(k):
			out[k] = ""
	for k in ["confirm", "strip", "button"]:
		if not out.has(k):
			out[k] = false
	if not out.has("keys"):
		out["keys"] = []
	return out


static func ids() -> Array:
	var out := []
	for a in ACTIONS:
		out.append(a["id"])
	return out


## Ids offered on the strip, in the registry's order.
static func strip_ids() -> Array:
	return ids().filter(func(i): return bool(action(i)["strip"]))


## Ids a button can run, in the registry's order.
static func button_ids() -> Array:
	return ids().filter(func(i): return bool(action(i)["button"]))


## "" when `id` can run in `ctx`, else a WHY key.
## ctx: {"available": func(control id) -> bool, "game_running": bool, "game_front": bool,
##       "steam": bool, "keys": bool, "recording": bool, "closer": bool, "optiscaler": bool}
static func why_not(id: String, ctx: Dictionary) -> String:
	var a := action(id)
	if a.is_empty():
		return "no_closer"
	if a["game"] == "front" and not bool(ctx.get("game_front", false)):
		return "no_game_front"
	if a["game"] == "running" and not bool(ctx.get("game_running", false)):
		return "no_game"
	if a["control"] != "":
		var fn: Variant = ctx.get("available")
		return "" if fn is Callable and bool((fn as Callable).call(a["control"])) else "no_control"
	match id:
		"keyboard":
			return "" if bool(ctx.get("steam", false)) else "no_steam"
		"record":
			return "" if bool(ctx.get("recording", false)) else "no_recorder"
		"send_key":
			return "" if bool(ctx.get("keys", false)) else "no_keys"
		"steam_menu":
			return "" if bool(ctx.get("keys", false)) else "no_steam_menu"
		"force_close", "exit_game":
			return "" if bool(ctx.get("closer", false)) else "no_closer"
	if a["kind"] == "key":
		if not bool(ctx.get("keys", false)):
			return "no_keys"
		if a["needs"] == "optiscaler" and not bool(ctx.get("optiscaler", false)):
			return "no_optiscaler"
	return ""


static func why_text(key: String) -> String:
	return str(WHY.get(key, "Not on this handheld."))


# ---- keys ------------------------------------------------------------------------

static func key_label(key: String) -> String:
	return str(KEY_LABELS.get(key, key.trim_prefix("Key")))


## "Alt + Enter" for ["KeyLeftAlt", "KeyEnter"].
static func combo_label(keys: Array) -> String:
	return " + ".join(PackedStringArray(keys.map(func(k): return key_label(str(k)))))


## A key or a combination a button may press: one to three modifiers first, then
## exactly one other key, no repeats.
static func valid_combo(keys: Array) -> bool:
	if keys.is_empty() or keys.size() > 4:
		return false
	var seen := {}
	for i in keys.size():
		var k := str(keys[i])
		if seen.has(k):
			return false
		seen[k] = true
		var last := i == keys.size() - 1
		if last:
			if not (k in KEY_NAMES or (keys.size() == 1 and k in KEY_MODIFIERS)):
				return false
		elif not k in KEY_MODIFIERS:
			return false
	return true


## "KeyLeftAlt+KeyEnter" <-> ["KeyLeftAlt", "KeyEnter"] (the form a button's
## setting and an InputPlumber mapping use).
static func combo_text(keys: Array) -> String:
	return "+".join(PackedStringArray(keys))


static func combo_keys(text: String) -> Array:
	return Array(text.split("+", false))


## InputPlumber's D-Bus name for a profile key name: "KeyLeftAlt" -> "KEY_LEFTALT"
## (SendKey takes the kernel names).
static func dbus_key(key: String) -> String:
	return "KEY_" + key.trim_prefix("Key").to_upper()


## The key action that presses exactly `keys`, or "".
static func key_action_for(keys: Array) -> String:
	for a in ACTIONS:
		if a.get("kind", "") == "key" and a.get("keys", []) == keys:
			return a["id"]
	return ""
