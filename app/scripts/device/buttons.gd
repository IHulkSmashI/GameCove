extends RefCounted
## Special buttons, back paddles and button glyphs for every handheld in
## data/devices.json. Pure data and lookups: nothing here reads input.
##
## Button names are InputPlumber capability names (Gamepad:Button:<name>):
## South, East, West, North, LeftBumper, RightBumper, LeftTrigger, RightTrigger,
## Select, Start, LeftStick, RightStick, DPadUp/Down/Left/Right, Guide,
## QuickAccess, QuickAccess2, Keyboard, Screenshot, LeftPaddle1..3,
## RightPaddle1..3, LeftTop, RightTop, LeftStickTouch, RightStickTouch.
## Where a physical button lands is taken from InputPlumber's device configs
## and capability maps (rootfs/usr/share/inputplumber, GPL-3.0), plus Bazzite's
## Acer Atlas 8 config (Apache-2.0). docs/DEVICES.md has the full table.
##
## GameCove actions: home, quick_menu, osk, screenshot (from special buttons),
## and accept, back, option, context, menu, view, tab_left, tab_right,
## page_left, page_right (from the standard buttons).

const GLYPH_ROOT := "res://assets/devices/glyphs/"
const DEVICE_TABLE := "res://data/devices.json"

## What a special button does in GameCove unless its profile says otherwise.
## Everything else (paddles, QuickAccess2, LeftTop...) goes to Steam or the game.
const DEFAULT_ACTIONS := {
	"Guide": "home",
	"QuickAccess": "quick_menu",
	"Keyboard": "osk",
	"Screenshot": "screenshot",
}

## Standard buttons behind each navigation action.
const ACTION_BUTTONS := {
	"accept": "South", "back": "East", "option": "West", "context": "North",
	"menu": "Start", "view": "Select",
	"tab_left": "LeftBumper", "tab_right": "RightBumper",
	"page_left": "LeftTrigger", "page_right": "RightTrigger",
}

## InputPlumber's DBusDevice sends these names (InputEvent signal) for the
## capabilities above when a composite device is in intercept mode.
const DBUS_EVENTS := {
	"ui_guide": "Guide", "ui_quick": "QuickAccess", "ui_quick2": "QuickAccess2",
	"ui_osk": "Keyboard", "ui_screenshot": "Screenshot",
	"ui_accept": "South", "ui_back": "East", "ui_action": "West", "ui_context": "North",
	"ui_option": "Start", "ui_select": "Select",
	"ui_l1": "LeftBumper", "ui_r1": "RightBumper", "ui_l2": "LeftTrigger", "ui_r2": "RightTrigger",
	"ui_l3": "LeftStick", "ui_r3": "RightStick",
	"ui_up": "DPadUp", "ui_down": "DPadDown", "ui_left": "DPadLeft", "ui_right": "DPadRight",
}

## Chords the Input service may offer where a device lacks the button (held
## together; first entry is the modifier). Only while GameCove has focus.
const FALLBACK_CHORDS := {
	"home": ["QuickAccess", "South"],
	"osk": ["QuickAccess", "North"],
	"screenshot": ["QuickAccess", "RightBumper"],
}

## Standard button -> glyph file name, per glyph set.
const SET_FILES := {
	"xbox": {
		"South": "a", "East": "b", "West": "x", "North": "y",
		"LeftBumper": "lb", "RightBumper": "rb", "LeftTrigger": "lt", "RightTrigger": "rt",
		"LeftStick": "ls", "RightStick": "rs", "Select": "view", "Start": "menu",
		"DPad": "dpad", "DPadUp": "dpad_up", "DPadDown": "dpad_down", "DPadLeft": "dpad_left", "DPadRight": "dpad_right",
		"Guide": "guide",
	},
	"deck": {
		"South": "a", "East": "b", "West": "x", "North": "y",
		"LeftBumper": "l1", "RightBumper": "r1", "LeftTrigger": "l2", "RightTrigger": "r2",
		"LeftStick": "l3", "RightStick": "r3", "Select": "view", "Start": "menu",
		"DPad": "dpad", "DPadUp": "dpad_up", "DPadDown": "dpad_down", "DPadLeft": "dpad_left", "DPadRight": "dpad_right",
		"Guide": "steam", "QuickAccess": "qam", "LeftPad": "trackpad_l", "RightPad": "trackpad_r",
	},
}

## Glyphs for actions a device has no button for (the UI can still show what
## the action is, next to the fallback chord).
const ACTION_GLYPHS := {
	"home": "special/house", "quick_menu": "special/sliders", "osk": "special/keyboard", "screenshot": "special/camera",
}

## One entry per button profile ("buttons" in devices.json).
##   glyphs:  glyph set for the standard buttons
##   special: [{id, label, capability, press: short|long|combo, glyph}]; one
##            physical button may appear twice (short and long press)
##   paddles: {capability: printed label}
##   actions: capability -> GameCove action, overriding DEFAULT_ACTIONS ("" = pass through)
##   verified: false when the layout is guessed (no upstream config)
const PROFILES := {
	"generic": {
		"glyphs": "xbox",
		"special": [{"id": "guide", "label": "Guide", "capability": "Guide", "press": "short", "glyph": "xbox/guide"}],
		"paddles": {},
		"verified": true,
		"source": "InputPlumber generic gamepad",
	},
	"steam-deck": {
		"glyphs": "deck",
		"special": [
			{"id": "steam", "label": "STEAM", "capability": "Guide", "press": "short", "glyph": "deck/steam"},
			{"id": "qam", "label": "Quick Access (…)", "capability": "QuickAccess", "press": "short", "glyph": "deck/qam"},
		],
		"paddles": {"LeftPaddle1": "L4", "LeftPaddle2": "L5", "RightPaddle1": "R4", "RightPaddle2": "R5"},
		"trackpads": 2,
		"verified": true,
		"source": "InputPlumber steam_deck driver",
	},
	"rog-ally": {
		"glyphs": "xbox",
		"special": [
			{"id": "command_center", "label": "Command Center", "capability": "Guide", "press": "short", "glyph": "special/command_center"},
			{"id": "command_center", "label": "Command Center (hold)", "capability": "Keyboard", "press": "long", "glyph": "special/command_center"},
			{"id": "armoury_crate", "label": "Armoury Crate", "capability": "QuickAccess", "press": "short", "glyph": "special/armoury_crate"},
			{"id": "armoury_crate", "label": "Armoury Crate (hold)", "capability": "QuickAccess2", "press": "long", "glyph": "special/armoury_crate"},
		],
		"paddles": {"LeftPaddle1": "M1", "RightPaddle1": "M2"},
		"verified": true,
		"source": "InputPlumber ally_type1",
	},
	"rog-xbox-ally": {
		"glyphs": "xbox",
		"special": [
			{"id": "xbox", "label": "Xbox button", "capability": "Guide", "press": "short", "glyph": "special/guide_ring"},
			{"id": "armoury_crate", "label": "Armoury Crate", "capability": "Keyboard", "press": "short", "glyph": "special/armoury_crate"},
			{"id": "armoury_crate", "label": "Armoury Crate (hold)", "capability": "LeftPaddle2", "press": "long", "glyph": "special/armoury_crate"},
			{"id": "library", "label": "Library", "capability": "QuickAccess", "press": "short", "glyph": "special/library"},
			{"id": "library", "label": "Library (hold)", "capability": "QuickAccess2", "press": "long", "glyph": "special/library"},
		],
		"paddles": {"LeftPaddle1": "M1", "RightPaddle1": "M2"},
		"verified": true,
		"source": "InputPlumber ally_type2",
	},
	"legion-go": {
		"glyphs": "xbox",
		"special": [
			{"id": "legion_l", "label": "Legion L", "capability": "Guide", "press": "short", "glyph": "special/legion_l"},
			{"id": "legion_r", "label": "Legion R", "capability": "QuickAccess", "press": "short", "glyph": "special/legion_r"},
			{"id": "m1", "label": "M1", "capability": "LeftStickTouch", "press": "short", "glyph": "paddle/m1"},
			{"id": "m2", "label": "M2", "capability": "RightStickTouch", "press": "short", "glyph": "paddle/m2"},
		],
		"paddles": {"LeftPaddle1": "Y1", "LeftPaddle2": "Y2", "RightPaddle1": "Y3", "RightPaddle2": "M3"},
		"trackpads": 1,
		"verified": true,
		"source": "InputPlumber legion_go driver (go1)",
	},
	"legion-go-2": {
		"glyphs": "xbox",
		"special": [
			{"id": "legion_l", "label": "Legion L", "capability": "Guide", "press": "short", "glyph": "special/legion_l"},
			{"id": "legion_r", "label": "Legion R", "capability": "QuickAccess", "press": "short", "glyph": "special/legion_r"},
			{"id": "view_desktop", "label": "Desktop (⧉)", "capability": "Keyboard", "press": "short", "glyph": "special/view_desktop"},
			{"id": "hamburger", "label": "Menu (☰)", "capability": "QuickAccess2", "press": "short", "glyph": "special/hamburger"},
		],
		"paddles": {"LeftPaddle1": "Y1", "LeftPaddle2": "Y2", "RightPaddle1": "Y3", "RightPaddle2": "M3"},
		"trackpads": 1,
		"verified": true,
		"source": "InputPlumber legion_go driver (go2)",
	},
	"legion-go-s": {
		"glyphs": "xbox",
		"special": [
			{"id": "legion_l", "label": "Legion L", "capability": "Guide", "press": "short", "glyph": "special/legion_l"},
			{"id": "legion_r", "label": "Legion R", "capability": "QuickAccess", "press": "short", "glyph": "special/legion_r"},
		],
		"paddles": {"LeftPaddle1": "Y1", "RightPaddle1": "Y2"},
		"trackpads": 1,
		"verified": true,
		"source": "InputPlumber legion_go_s driver",
	},
	"msi-claw": {
		"glyphs": "xbox",
		"special": [
			{"id": "msi_center", "label": "MSI Center M", "capability": "Guide", "press": "short", "glyph": "special/msi_m"},
			{"id": "quick_settings", "label": "Quick Settings", "capability": "QuickAccess", "press": "short", "glyph": "special/quick_settings"},
			{"id": "quick_settings", "label": "Quick Settings (hold)", "capability": "QuickAccess2", "press": "long", "glyph": "special/quick_settings"},
		],
		"paddles": {"LeftPaddle1": "M2", "RightPaddle1": "M1"},
		"verified": true,
		"source": "InputPlumber msiclaw_type1",
	},
	"msi-claw-8-ex": {
		"glyphs": "xbox",
		"special": [
			{"id": "msi_center", "label": "MSI Center M", "capability": "Guide", "press": "short", "glyph": "special/msi_m"},
			{"id": "quick_settings", "label": "Quick Settings", "capability": "QuickAccess", "press": "short", "glyph": "special/quick_settings"},
		],
		"paddles": {"LeftPaddle1": "M2", "RightPaddle1": "M1"},
		"verified": true,
		"source": "InputPlumber msiclaw_type2, tested on the device",
	},
	"oxp-generic": {
		"glyphs": "xbox",
		"special": [
			{"id": "home", "label": "Home (orange)", "capability": "Guide", "press": "short", "glyph": "special/home_dot"},
			{"id": "home", "label": "Home (hold)", "capability": "QuickAccess2", "press": "long", "glyph": "special/home_dot"},
			{"id": "turbo", "label": "Turbo", "capability": "QuickAccess", "press": "short", "glyph": "special/turbo"},
			{"id": "kb", "label": "Keyboard", "capability": "Keyboard", "press": "short", "glyph": "special/keyboard"},
			{"id": "turbo_home", "label": "Turbo + Home", "capability": "Screenshot", "press": "combo", "glyph": "special/camera"},
		],
		"paddles": {},
		"verified": true,
		"source": "InputPlumber onexplayer_type3",
	},
	"oxp-f1": {
		"glyphs": "xbox",
		"special": [
			{"id": "home", "label": "Home (orange)", "capability": "Guide", "press": "short", "glyph": "special/home_dot"},
			{"id": "home", "label": "Home (hold)", "capability": "QuickAccess2", "press": "long", "glyph": "special/home_dot"},
			{"id": "turbo", "label": "Turbo", "capability": "QuickAccess", "press": "short", "glyph": "special/turbo"},
			{"id": "kb", "label": "Keyboard", "capability": "Keyboard", "press": "short", "glyph": "special/keyboard"},
			{"id": "turbo_home", "label": "Turbo + Home", "capability": "Screenshot", "press": "combo", "glyph": "special/camera"},
		],
		"paddles": {"RightPaddle1": "M2"},
		"verified": true,
		"source": "InputPlumber onexplayer_type7",
	},
	"oxp-apex": {
		"glyphs": "xbox",
		"special": [
			{"id": "home", "label": "Home (orange)", "capability": "Guide", "press": "short", "glyph": "special/home_dot"},
			{"id": "home", "label": "Home (hold)", "capability": "QuickAccess2", "press": "long", "glyph": "special/home_dot"},
			{"id": "turbo", "label": "Turbo", "capability": "QuickAccess", "press": "short", "glyph": "special/turbo"},
			{"id": "kb", "label": "Keyboard", "capability": "Keyboard", "press": "short", "glyph": "special/keyboard"},
			{"id": "turbo_home", "label": "Turbo + Home", "capability": "Screenshot", "press": "combo", "glyph": "special/camera"},
		],
		"paddles": {"LeftPaddle1": "M1", "RightPaddle1": "M2"},
		"verified": true,
		"source": "InputPlumber onexplayer_type8",
	},
	"oxp-x1": {
		"glyphs": "xbox",
		"special": [
			{"id": "turbo", "label": "Turbo", "capability": "Keyboard", "press": "short", "glyph": "special/turbo"},
			{"id": "kb", "label": "Keyboard button", "capability": "QuickAccess", "press": "short", "glyph": "special/keyboard"},
			{"id": "kb_hid", "label": "Keyboard button (controller mode)", "capability": "QuickAccess2", "press": "short", "glyph": "special/keyboard"},
		],
		"paddles": {"LeftPaddle1": "M1", "RightPaddle1": "M2"},
		"verified": true,
		"source": "InputPlumber onexplayer_type5",
	},
	"oxp-2": {
		"glyphs": "xbox",
		"special": [
			{"id": "turbo", "label": "Turbo", "capability": "QuickAccess", "press": "short", "glyph": "special/turbo"},
		],
		"paddles": {},
		"verified": true,
		"source": "InputPlumber onexplayer_type4",
	},
	"oxp-g1": {
		"glyphs": "xbox",
		"special": [
			{"id": "home", "label": "Home", "capability": "Guide", "press": "short", "glyph": "special/home_dot"},
			{"id": "home", "label": "Home (hold)", "capability": "QuickAccess2", "press": "long", "glyph": "special/home_dot"},
			{"id": "turbo", "label": "Turbo", "capability": "QuickAccess", "press": "short", "glyph": "special/turbo"},
		],
		"paddles": {},
		"verified": true,
		"source": "InputPlumber onexplayer_type6",
	},
	"oxp-x2": {
		"glyphs": "xbox",
		"special": [
			{"id": "onex", "label": "OneX button", "capability": "QuickAccess", "press": "short", "glyph": "special/home_dot"},
			{"id": "kb", "label": "Keyboard button", "capability": "QuickAccess2", "press": "short", "glyph": "special/keyboard"},
		],
		"actions": {"QuickAccess2": "osk"},
		"paddles": {"LeftPaddle1": "M1", "RightPaddle1": "M2"},
		"verified": true,
		"source": "InputPlumber onexplayer_type9",
	},
	"aokzoe": {
		"glyphs": "xbox",
		"special": [
			{"id": "home", "label": "Home (orange)", "capability": "Guide", "press": "short", "glyph": "special/home_dot"},
			{"id": "home", "label": "Home (hold)", "capability": "QuickAccess2", "press": "long", "glyph": "special/home_dot"},
			{"id": "turbo", "label": "Turbo", "capability": "QuickAccess", "press": "short", "glyph": "special/turbo"},
			{"id": "kb", "label": "Keyboard", "capability": "Keyboard", "press": "short", "glyph": "special/keyboard"},
			{"id": "turbo_home", "label": "Turbo + Home", "capability": "Screenshot", "press": "combo", "glyph": "special/camera"},
		],
		"paddles": {},
		"verified": true,
		"source": "InputPlumber onexplayer_type3",
	},
	"aya-classic": {
		"glyphs": "xbox",
		"special": [
			{"id": "aya", "label": "AYA Space", "capability": "Guide", "press": "short", "glyph": "special/aya"},
			{"id": "custom", "label": "Custom", "capability": "QuickAccess", "press": "short", "glyph": "special/sliders"},
			{"id": "lc", "label": "LC", "capability": "LeftTop", "press": "short", "glyph": "paddle/lc"},
			{"id": "rc", "label": "RC", "capability": "RightTop", "press": "short", "glyph": "paddle/rc"},
			{"id": "second_screen", "label": "Second screen (Flip DS)", "capability": "Keyboard", "press": "short", "glyph": "special/keyboard"},
		],
		"paddles": {},
		"verified": true,
		"source": "InputPlumber ayaneo_type4",
	},
	"aya-kun": {
		"glyphs": "xbox",
		"special": [
			{"id": "aya", "label": "AYA Space", "capability": "QuickAccess2", "press": "short", "glyph": "special/aya"},
			{"id": "custom", "label": "Custom", "capability": "QuickAccess", "press": "short", "glyph": "special/sliders"},
			{"id": "lc", "label": "LC", "capability": "LeftTop", "press": "short", "glyph": "paddle/lc"},
			{"id": "rc", "label": "RC", "capability": "RightTop", "press": "short", "glyph": "paddle/rc"},
			{"id": "t", "label": "T", "capability": "RightTop", "press": "short", "glyph": "paddle/t"},
		],
		"actions": {"QuickAccess2": "home"},
		"paddles": {},
		"verified": true,
		"source": "InputPlumber ayaneo_type6",
	},
	"aya-3": {
		"glyphs": "xbox",
		"special": [
			{"id": "aya", "label": "AYA Space", "capability": "Guide", "press": "short", "glyph": "special/aya"},
			{"id": "quick", "label": "Quick Access", "capability": "QuickAccess", "press": "short", "glyph": "special/sliders"},
			{"id": "lc", "label": "LC", "capability": "LeftTop", "press": "short", "glyph": "paddle/lc"},
			{"id": "rc", "label": "RC", "capability": "RightTop", "press": "short", "glyph": "paddle/rc"},
		],
		"paddles": {},
		"verified": true,
		"source": "InputPlumber ayaneo_type7",
	},
	"aya-flip-1s": {
		"glyphs": "xbox",
		"special": [
			{"id": "aya", "label": "AYA Space", "capability": "QuickAccess", "press": "short", "glyph": "special/aya"},
			{"id": "lc", "label": "LC", "capability": "LeftTop", "press": "short", "glyph": "paddle/lc"},
			{"id": "rc", "label": "RC", "capability": "RightTop", "press": "short", "glyph": "paddle/rc"},
		],
		"paddles": {"LeftPaddle2": "L", "RightPaddle2": "R"},
		"verified": true,
		"source": "InputPlumber ayaneo_type8",
	},
	"gpd-win4": {
		"glyphs": "xbox",
		"special": [
			{"id": "back_right", "label": "R4 (back)", "capability": "QuickAccess", "press": "short", "glyph": "paddle/r4"},
		],
		"paddles": {"LeftPaddle1": "L4"},
		"verified": true,
		"source": "InputPlumber gpd_type3",
	},
	"gpd-winmax2": {
		"glyphs": "xbox",
		"special": [],
		"paddles": {"LeftPaddle1": "L4", "RightPaddle1": "R4"},
		"verified": true,
		"source": "InputPlumber gpd_type2",
	},
	"gpd-win5": {
		"glyphs": "xbox",
		"special": [
			{"id": "home", "label": "Home", "capability": "Guide", "press": "short", "glyph": "special/house"},
			{"id": "mode", "label": "Mode switch", "capability": "QuickAccess", "press": "short", "glyph": "special/swap"},
			{"id": "kb", "label": "Keyboard", "capability": "Keyboard", "press": "short", "glyph": "special/keyboard"},
		],
		"paddles": {"LeftPaddle1": "L4", "RightPaddle1": "R4"},
		"verified": true,
		"source": "InputPlumber gpd_type4",
	},
	"zotac-zone": {
		"glyphs": "xbox",
		"special": [
			{"id": "zotac", "label": "ZOTAC button", "capability": "Guide", "press": "short", "glyph": "special/guide_ring"},
			{"id": "more", "label": "More (…)", "capability": "QuickAccess", "press": "short", "glyph": "special/dots"},
			{"id": "home", "label": "Home", "capability": "QuickAccess2", "press": "short", "glyph": "special/house"},
			{"id": "home", "label": "Home (hold)", "capability": "Keyboard", "press": "long", "glyph": "special/house"},
		],
		"actions": {"QuickAccess2": "home"},
		"paddles": {"LeftPaddle1": "M1", "RightPaddle1": "M2"},
		"trackpads": 2,
		"dials": 2,
		"verified": true,
		"source": "InputPlumber zone_buttons",
	},
	"acer-atlas": {
		"glyphs": "xbox",
		"special": [
			{"id": "guide", "label": "Guide (hold)", "capability": "Guide", "press": "long", "glyph": "special/guide_ring"},
			{"id": "qam", "label": "Quick Access", "capability": "QuickAccess", "press": "short", "glyph": "special/sliders"},
			{"id": "qam", "label": "Quick Access (hold)", "capability": "QuickAccess2", "press": "long", "glyph": "special/sliders"},
		],
		"paddles": {"LeftPaddle1": "M2", "RightPaddle1": "M1"},
		"verified": true,
		"source": "Bazzite acer_atlas8_hid_type1/2",
	},
	"acer-blaze": {
		"glyphs": "xbox",
		"special": [
			{"id": "guide", "label": "Guide", "capability": "Guide", "press": "short", "glyph": "special/guide_ring"},
			{"id": "quick", "label": "Quick Access", "capability": "QuickAccess", "press": "short", "glyph": "special/sliders"},
		],
		"paddles": {},
		"verified": false,
		"source": "guess: no InputPlumber config yet",
	},
	"orangepi-neo": {
		"glyphs": "xbox",
		"special": [
			{"id": "guide", "label": "Guide", "capability": "Guide", "press": "short", "glyph": "special/guide_ring"},
			{"id": "quick", "label": "Quick Access", "capability": "QuickAccess", "press": "short", "glyph": "special/sliders"},
			{"id": "lc", "label": "LC", "capability": "LeftTop", "press": "short", "glyph": "paddle/lc"},
			{"id": "rc", "label": "RC", "capability": "RightTop", "press": "short", "glyph": "paddle/rc"},
		],
		"paddles": {},
		"trackpads": 2,
		"verified": true,
		"source": "InputPlumber orangepi_type1",
	},
}

## device id -> button profile id, read once from devices.json.
static var _profile_by_device: Dictionary = {}


static func _load_index() -> void:
	if not _profile_by_device.is_empty():
		return
	if not FileAccess.file_exists(DEVICE_TABLE):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(DEVICE_TABLE))
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	for d in parsed.get("devices", []):
		if d is Dictionary:
			_profile_by_device[str(d.get("id", ""))] = str(d.get("buttons", "generic"))


## Button profile id for a device id, a devices.json row, or a profile id.
## Unknown devices get "generic".
static func profile_id(device: Variant) -> String:
	if device is Dictionary:
		var p := str(device.get("buttons", "generic"))
		return p if PROFILES.has(p) else "generic"
	var key := str(device)
	if PROFILES.has(key):
		return key
	_load_index()
	var p2: String = _profile_by_device.get(key, "generic")
	return p2 if PROFILES.has(p2) else "generic"


static func profile(device: Variant) -> Dictionary:
	return PROFILES[profile_id(device)]


## "xbox" or "deck".
static func glyph_set(device: Variant) -> String:
	return str(profile(device).get("glyphs", "xbox"))


## The device's special buttons, each {id, label, capability, press, glyph, action}.
static func special_buttons(device: Variant) -> Array:
	var p := profile(device)
	var out := []
	for b in p.get("special", []):
		var e: Dictionary = b.duplicate()
		e["action"] = action_for(device, str(b["capability"]))
		e["glyph"] = GLYPH_ROOT + str(b["glyph"]) + ".svg"
		out.append(e)
	return out


## {capability: label} for the back paddles, e.g. {"LeftPaddle1": "L4"}.
static func paddles(device: Variant) -> Dictionary:
	return profile(device).get("paddles", {})


## Capabilities this device's special buttons and paddles produce.
static func capabilities(device: Variant) -> Array:
	var out := []
	for b in profile(device).get("special", []):
		if not b["capability"] in out:
			out.append(b["capability"])
	for c in paddles(device):
		if not c in out:
			out.append(c)
	return out


## GameCove action for a capability on this device, "" = leave it to Steam / the game.
static func action_for(device: Variant, capability: String) -> String:
	var overrides: Dictionary = profile(device).get("actions", {})
	if overrides.has(capability):
		return str(overrides[capability])
	return str(DEFAULT_ACTIONS.get(capability, ""))


## {capability: action} for every special capability that triggers a GameCove action.
static func action_map(device: Variant) -> Dictionary:
	var out := {}
	for c in capabilities(device):
		var a := action_for(device, c)
		if a != "":
			out[c] = a
	return out


## Capabilities that trigger `action` on this device (special or standard), in
## profile order. Empty when the device has no button for it: then use
## FALLBACK_CHORDS.
static func buttons_for(device: Variant, action: String) -> Array:
	if ACTION_BUTTONS.has(action):
		return [ACTION_BUTTONS[action]]
	var out := []
	for c in capabilities(device):
		if action_for(device, c) == action:
			out.append(c)
	return out


## The action for an InputPlumber DBusDevice InputEvent name ("ui_guide"...).
static func action_for_dbus(device: Variant, event: String) -> String:
	var cap: String = DBUS_EVENTS.get(event, "")
	if cap == "":
		return ""
	if ACTION_BUTTONS.values().has(cap):
		return ACTION_BUTTONS.find_key(cap)
	return action_for(device, cap)


## Printed name of a button on this device, e.g. "Armoury Crate", "L4", "A".
static func label_for(device: Variant, button: String) -> String:
	var pad: Dictionary = paddles(device)
	if pad.has(button):
		return str(pad[button])
	for b in profile(device).get("special", []):
		if b["capability"] == button or b["id"] == button:
			return str(b["label"]).replace(" (hold)", "")
	var deck := glyph_set(device) == "deck"
	var names := {
		"South": "A", "East": "B", "West": "X", "North": "Y",
		"LeftBumper": "L1" if deck else "LB", "RightBumper": "R1" if deck else "RB",
		"LeftTrigger": "L2" if deck else "LT", "RightTrigger": "R2" if deck else "RT",
		"Select": "View", "Start": "Menu", "LeftStick": "L3" if deck else "LS", "RightStick": "R3" if deck else "RS",
	}
	return str(names.get(button, button))


## res:// path of the glyph for an action ("accept", "home", ...), an
## InputPlumber capability ("South", "QuickAccess", "LeftPaddle1"...) or a
## special button id ("armoury_crate") on this device. Never empty: unknown
## names get the generic button glyph.
static func glyph_for(name: String, device: Variant) -> String:
	var set_name := glyph_set(device)
	var button := name
	if ACTION_BUTTONS.has(name):
		button = ACTION_BUTTONS[name]
	elif ACTION_GLYPHS.has(name):
		var caps := buttons_for(device, name)
		if caps.is_empty():
			return GLYPH_ROOT + ACTION_GLYPHS[name] + ".svg"
		button = caps[0]
	# a special button (by capability, short press first, or by id)
	var specials: Array = profile(device).get("special", [])
	for b in specials:
		if b["capability"] == button and b.get("press", "short") != "long":
			return GLYPH_ROOT + str(b["glyph"]) + ".svg"
	for b in specials:
		if b["capability"] == button or b["id"] == button:
			return GLYPH_ROOT + str(b["glyph"]) + ".svg"
	var pad: Dictionary = paddles(device)
	if pad.has(button):
		return GLYPH_ROOT + "paddle/" + str(pad[button]).to_lower() + ".svg"
	var files: Dictionary = SET_FILES.get(set_name, SET_FILES["xbox"])
	if files.has(button):
		return GLYPH_ROOT + set_name + "/" + str(files[button]) + ".svg"
	if button.begins_with("LeftPaddle") or button.begins_with("RightPaddle"):
		return GLYPH_ROOT + "paddle/p" + button.right(1) + ".svg"
	return GLYPH_ROOT + "generic/button.svg"


## Every glyph path any profile can return (for tests and preloading).
static func all_glyphs() -> Array:
	var out := []
	for set_name in SET_FILES:
		for k in SET_FILES[set_name]:
			out.append(GLYPH_ROOT + set_name + "/" + str(SET_FILES[set_name][k]) + ".svg")
	for p in PROFILES.values():
		for b in p.get("special", []):
			out.append(GLYPH_ROOT + str(b["glyph"]) + ".svg")
		for label in p.get("paddles", {}).values():
			out.append(GLYPH_ROOT + "paddle/" + str(label).to_lower() + ".svg")
	for g in ACTION_GLYPHS.values():
		out.append(GLYPH_ROOT + g + ".svg")
	for n in ["1", "2", "3"]:
		out.append(GLYPH_ROOT + "paddle/p" + n + ".svg")
	out.append(GLYPH_ROOT + "generic/button.svg")
	var uniq := []
	for p in out:
		if not p in uniq:
			uniq.append(p)
	return uniq
