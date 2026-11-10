extends RefCounted
## Words for the Controls UI: the quick menu, the generated settings pages,
## the Profiles page and the game page's Game settings card. Short, plain,
## casual; every bit of jargon gets one line.

# ---- quick menu ---------------------------------------------------------------

const TABS := ["This game", "Power", "Display", "Audio", "Controller", "Device"]
const TAB_IDS := ["game", "power", "display", "audio", "controller", "device"]
const TAB_ICONS := ["game", "bolt", "screen", "volume", "gamepad", "handheld"]
const QM_TITLE := "Quick menu"
const NO_GAME := "No game picked"
const NO_GAME_LINE := "Pick a game on Home and its own settings show up here."
const LOADING := "Checking what this handheld can do…"
const NO_CONTROLS := "Settings aren't ready yet. Give it a second."
const ALL_SETTINGS := "All settings"
const ALL_IN := "All %s settings"
const NOTHING_HERE := "Nothing to change here on this handheld."

# ---- per-game profile ---------------------------------------------------------

const USE_GAME := "Use settings for this game"
const OWN_SETTINGS := "own settings"
const USE_GAME_ON := "Changes save for %s only."
const USE_GAME_OFF := "Off: this game uses your everyday settings."
const USE_GAME_EDIT := "Saved for next time. Nothing changes until it starts."
const RESET_GAME := "Reset this game"
const RESET_GAME_LINE := "Forget its own settings and go back to your everyday ones."
const RESET_CONFIRM := "Press again to reset"
const RESET_DONE := "%s uses your everyday settings again."
const SAVED_FOR := "Saved for %s"

const AUTO_TDP := "Auto TDP"
const AUTO_TDP_HELP := "Lowers the power limit by itself while the game holds its frame rate. Saves battery."
const AUTO_TDP_RUNNING := "Running now"

## Where a value comes from (Profiles.explain layers).
const LAYERS := {
	"game": "This game", "game+ac": "Game, plugged in", "game+battery": "Game, on battery",
	"ac": "Plugged in", "battery": "On battery", "global": "Everyday",
}
const LAYER_HELP := {
	"game": "Comes from this game's own settings.",
	"game+ac": "Comes from this game's settings for when it's plugged in.",
	"game+battery": "Comes from this game's settings for when it's on battery.",
	"ac": "Comes from your plugged-in settings.",
	"battery": "Comes from your on-battery settings.",
}

# ---- control states -----------------------------------------------------------

const PENDING := "Applying…"
const FAILED := "Couldn't change that. It stays at %s."
const FAILED_PLAIN := "Couldn't change that. Nothing was changed."
const ROOT_BADGE := "System"
const ROOT_HELP := "Changed through GameCove's system helper. No password needed."
const NEEDS_FIRST := "Turn on %s first."
const NEEDS_OTHER := "Needs %s, which isn't available here."
const MORE := "More settings"
const MORE_COUNT := "%d more"
const LESS := "Fewer settings"
const UNAVAILABLE_TITLE := "Not on this handheld"
const UNAVAILABLE_LINE := "These need hardware or software this handheld doesn't have. Each says why."
const RUN := "Run"
const DONE := "Done"

# ---- colour and curve editors -------------------------------------------------

const COLOR_HUE := "Fine-tune"
const COLOR_HELP := "Left and right pick a colour. Fine-tune slides through every hue."
const CURVE_HELP := "Left and right pick a point, up and down change it. A saves."
const CURVE_EDIT := "Edit curve"
const CURVE_SAVE := "Save curve"
const CURVE_COOL := "COOL"
const CURVE_HOT := "HOT"
const CURVE_POINT := "Point %d of %d: %d%%"
const CURVE_RESET := "Back to quiet"

# ---- refresh-rate unlock safety -----------------------------------------------

const KEEP_TITLE := "Keep this?"
const KEEP_LINE := "If the screen looks wrong, don't touch anything. It goes back by itself."
const KEEP_REVERT := "Reverting in %d s"
const KEEP_YES := "Keep"
const KEEP_NO := "Go back"
const KEEP_REVERTED := "Put back the way it was."
const UNLOCK_RESTART := "Takes effect after the session restarts. If the screen stays black then, sign in over SSH or a TTY and delete ~/.config/environment.d/80-gamecove-display.conf."
## Controls that get the "Keep this?" countdown right after a change.
const NEEDS_CONFIRM := ["display.hdr"]
## ...and those that take effect next session: the countdown runs then.
const CONFIRM_NEXT_SESSION := ["display.refresh_unlock", "display.rotation"]
const NEXT_SESSION := "Takes effect after the session restarts. You'll get 15 s to keep it."
const CONFIRM_SECONDS := 15

# ---- gyro and Steam Input -----------------------------------------------------

const GYRO_STEAM_TITLE := "Gyro aiming lives in Steam"
const GYRO_STEAM_LINE := "Steam turns the gyro into mouse or stick aiming, with sensitivity and an activation button. Pick Steam Deck or DualSense as the controller type, then set it in Steam's controller settings for the game."
const GYRO_STEAM_OPEN := "Open Steam controller settings"
const GYRO_STEAM_NO_GAME := "Pick a Steam game to open its controller settings."
const GYRO_STEAM_OPENING := "Opening Steam's controller settings…"
const GYRO_STEAM_FAILED := "Couldn't open Steam. Open the game in Steam, then Controller settings."

# ---- device tab ---------------------------------------------------------------

const DEVICE_FIXES := "Device fixes"
const FIXES_OPEN := "Open device fixes"
const FIXES_NONE := "None needed"
const WORKS_SHORT := {"tdp": "TDP", "fan_control": "Fan", "charge_limit": "Charge limit", "vrr": "VRR", "gyro": "Gyro",
	"paddles": "Back buttons", "trackpads": "Trackpads", "rgb": "Lights"}
const FIXES_SUMMARY := "%d applied, %d more available"
const FIXES_ALL_GOOD := "%d applied, all good"
const FIXES_COUNT_ONLY := "%d fixes for this handheld"
const QUICK_TOGGLES := "Quick toggles"

# ---- settings pages -----------------------------------------------------------

## Settings categories in the order they're listed, in two groups.
const CATEGORY_GROUPS := [
	["HANDHELD", ["power", "display", "audio", "controller", "performance", "system", "profiles"]],
	["GAMECOVE", ["appearance", "stores", "discover", "device", "about"]],
]
const CATEGORY_NAMES := {
	"power": "Power", "display": "Display", "audio": "Sound", "controller": "Controller",
	"performance": "Performance", "system": "System", "profiles": "Profiles",
}
const CATEGORY_LINES := {
	"power": "TDP, fan, battery.", "display": "Brightness, refresh, colour.", "audio": "Volume and outputs.",
	"controller": "Gyro, buttons, lights.", "performance": "Overlay, upscaling, frame gen.",
	"system": "Wi-Fi, Bluetooth, sleep.", "profiles": "Per game and per power source.",
}
const CATEGORY_ICONS := {
	"power": "bolt", "display": "screen", "audio": "volume", "controller": "gamepad",
	"performance": "gauge", "system": "wifi", "profiles": "layers",
}
## Settings category -> Controls groups it shows.
const CATEGORY_GROUPS_OF := {
	"power": ["power"], "display": ["display"], "audio": ["audio"], "controller": ["controller"],
	"performance": ["perf"], "system": ["network", "system"],
}
## Quick menu tab -> settings category for "All settings".
const TAB_CATEGORY := {"game": "performance", "power": "power", "display": "display", "audio": "audio",
	"controller": "controller", "device": "device"}

# ---- profiles page ------------------------------------------------------------

const PROF_TITLE := "Profiles"
const PROF_LINE := "Saved settings that switch by themselves: per game, and for battery or plugged in."
const PROF_ORDER := "A game's own settings win over battery or plugged-in ones, which win over everyday ones."
const PROF_EVERYDAY := "Everyday"
const PROF_EVERYDAY_LINE := "Used whenever nothing more specific is saved."
const PROF_BATTERY := "On battery"
const PROF_BATTERY_LINE := "Used while unplugged."
const PROF_AC := "Plugged in"
const PROF_AC_LINE := "Used while charging."
const PROF_GAMES := "Games"
const PROF_GAMES_NONE := "No game has its own settings yet. Turn on \"Use settings for this game\" in the quick menu while it runs."
const PROF_EMPTY := "Nothing saved"
const PROF_COUNT := "%d saved"
const PROF_SAVE_CURRENT := "Save current settings here"
const PROF_COPY_EVERYDAY := "Copy everyday settings here"
const PROF_COPY_TO_GAME := "Copy to the game in focus"
const PROF_RESET := "Reset"
const PROF_RESET_CONFIRM := "Press again to reset"
const PROF_EXPORT := "Export to a file"
const PROF_IMPORT := "Import from a file"
const PROF_EXPORTED := "Saved to %s"
const PROF_EXPORT_FAILED := "Couldn't write %s."
const PROF_IMPORTED := "Imported %d settings."
const PROF_IMPORT_NONE := "No profile file found at %s."
const PROF_FILE_LINE := "Files go to %s, so you can copy them to another handheld."
const PROF_BACKUP := "Backup"
const PROF_SAVED_NOW := "Saved."
const PROF_RESET_DONE := "Reset."
const PROF_NOW := "Now using"
const PROF_SOURCE_NOW := {"ac": "Plugged in", "battery": "On battery"}
const PROF_GAME_LINE := "%d saved · %s"
const PROF_UPDATED_NEVER := "not changed yet"
const PROF_EXPORT_DIR := "Documents/GameCove"

# ---- game page card -----------------------------------------------------------

const GAME_CARD := "Game settings"
const GAME_CARD_ON := "Uses its own settings"
const GAME_CARD_OFF := "Uses your everyday settings"
const GAME_CARD_OFF_LINE := "Turn on to keep a TDP, frame limit or upscaler just for this game."
const GAME_CARD_ON_LINE := "Changes save for this game only. Turn off to go back to your everyday settings."
const GAME_CARD_OFF_CONFIRM := "Press again to forget this game's own settings."
const GAME_CARD_TOGGLE := "Custom settings for this game"
const GAME_CARD_EVERYDAY := "Everyday profile"
const GAME_CARD_EDIT := "Edit"
const GAME_CARD_ON_BUTTON := "Give it its own settings"
const GAME_CARD_RESET := "Reset"
const GAME_CARD_STEAM_INPUT := "Controller in Steam"
const GAME_CARD_MORE := "+%d more"

# ---- extra one-line explanations for jargon in titles -------------------------

## Shown under a control when its own help doesn't already explain the term.
const JARGON := {
	"TDP": "TDP: how many watts the chip may use.",
	"VRR": "VRR: the screen waits for each frame, so uneven frame rates look smooth.",
	"SPPT": "SPPT: the short boost limit, a few seconds above the TDP.",
	"FPPT": "FPPT: the peak limit for split-second bursts.",
	"SMT": "SMT: two threads per CPU core.",
	"EPP": "EPP: how eagerly the CPU speeds up.",
	"FSR": "FSR and NIS: AMD's and Nvidia's sharpening upscalers; they work in every game.",
	"HDR": "HDR: brighter highlights and deeper colour where games support it.",
	"lsfg": "Lossless Scaling: a frame generator; it needs your own copy from Steam.",
}


## "Applying…" / failure line for a control, `old` is the value label to show.
static func failed_line(old: String) -> String:
	return FAILED % old if old != "" else FAILED_PLAIN


## "3 applied, 1 more available" for the Device tab (Fixes.counts()).
static func fixes_line(counts: Dictionary) -> String:
	var applied := int(counts.get("applied", 0))
	var todo := int(counts.get("available", 0))
	if todo > 0:
		return FIXES_SUMMARY % [applied, todo]
	return FIXES_ALL_GOOD % applied

## Controller category: the link to the device's button map and test.
const BUTTONS_CARD := "Buttons"
const BUTTONS_ROW := "Back buttons and button test"
const BUTTONS_ROW_HINT := "Map the back buttons, see this game's layout and test every button."
