extends RefCounted
## Words for the device pages (About this device, Controller, Storage, Updates).
## Plain and short; jargon gets one line of explanation.

# ---- About this device ----------------------------------------------------------

const ABOUT_TITLE := "About this device"
const SUPPORT_LABELS := {"full": "Full support", "partial": "Partial support", "beta": "Beta support", "generic": "Basic support"}
const SUPPORT_TONES := {"full": "good", "partial": "info", "beta": "info", "generic": "warn"}
const SUPPORT_LINES := {
	"full": "Tested on this handheld by the GameCove team. Everything below should just work.",
	"partial": "Set up from tested data by InputPlumber, steamos-manager and friends, but we haven't run GameCove on one yet.",
	"beta": "People with this handheld have tried GameCove and told us it works.",
	"generic": "We know the maker or the chip, not the exact model. Power limits are safe guesses.",
}
const SECTIONS := {
	"device": "Device", "chip": "Chip and drivers", "memory": "Memory", "storage": "Storage",
	"screen": "Screen", "battery": "Battery", "software": "Software", "support": "What works here",
	"fixes": "Recommended fixes",
}
const SECTION_ICONS := {
	"device": "handheld", "chip": "bolt", "memory": "gauge", "storage": "download", "screen": "screen",
	"battery": "power", "software": "info", "support": "shield", "fixes": "sparkle",
}
const UNKNOWN := "Unknown"
const SERIAL_HIDDEN := "Hidden"
## What A does on About this device's cards (read-only cards don't take focus).
const ACT_COPY := "Copy info"
const ACT_COPIED := "Device info copied, ready to paste into a bug report"
const ACT_STORAGE := "Manage"
const ACT_UPDATES := "Updates"
const ACT_FIXES := "Open Fixes"
const ACT_POWER := "Power settings"
const ACT_DISPLAY := "Display settings"
const GTT_NOTE := "Shared graphics memory: system RAM the GPU can borrow."
const VRAM_NOTE := "Set aside for graphics at boot (change it in the BIOS on some handhelds)."
const HEALTH_NOTE := "How much the battery holds now, compared with new."
const CYCLES_NOTE := "One cycle = 100 % used, in one go or spread out."
const VRR_NOTE := "Variable refresh: the screen waits for each frame, so no tearing or stutter."
const UNVERIFIED_INTRO := "Best guesses so far (tell us if they're wrong):"
const QUIRKS_TITLE := "Good to know"
const NO_FIXES := "Nothing to fix here. This handheld works out of the box."
const FIXES_WHERE := "Install them from the quick menu: Device. They ask for your admin password, and every one can be undone."
const LOADING := "Looking up a few more details…"
const HERO_EYEBROW := "Hardware profile"
const DRAWING_CREDIT := "Drawn to scale · %d × %d mm"
const FEATURES := {
	"tdp": "Power limit (TDP)", "fan_control": "Fan presets", "charge_limit": "Charge limit",
	"gyro": "Gyro", "vrr": "Variable refresh (VRR)", "paddles": "Back buttons", "rgb": "Lights",
	"trackpads": "Trackpads",
}
const UNVERIFIED_NAMES := {
	"tdp": "power limits", "tdp.battery_max": "battery power limit", "panel": "screen", "panel.vrr": "variable refresh",
	"panel.resolution": "screen resolution", "chip": "chip", "buttons": "button layout", "dmi": "how we recognise it",
	"charge_limit": "charge limit", "gyro": "gyro", "fan": "fan control", "all": "everything",
}
const GYRO_STATES := {
	"yes": "Works", "fix": "Needs a fix", "no": "Not on Linux yet", "none": "No gyro", "unknown": "Not sure yet",
}


# ---- Controller -----------------------------------------------------------------

const CONTROLLER_TITLE := "Controller"
const NO_INPUTPLUMBER := "InputPlumber isn't running"
const NO_INPUTPLUMBER_LINE := "It's the service that handles handheld buttons on Bazzite and SteamOS. Without it, back buttons, gyro and rumble settings aren't available. Buttons still work."
const CHECKING := "Checking your controller…"
const PADDLES_TITLE := "Back buttons"
const PADDLES_LINE := "Pick what each back button presses. Changes save right away."
const PADDLE_NOTHING := "Nothing (default)"
const PADDLE_TARGETS := ["", "South", "East", "West", "North", "LeftBumper", "RightBumper", "LeftTrigger", "RightTrigger",
	"LeftStick", "RightStick", "Select", "Start", "DPadUp", "DPadDown", "DPadLeft", "DPadRight"]
const PADDLE_TARGET_LABELS := {
	"South": "A", "East": "B", "West": "X", "North": "Y", "LeftBumper": "LB", "RightBumper": "RB",
	"LeftTrigger": "LT", "RightTrigger": "RT", "LeftStick": "Left stick click", "RightStick": "Right stick click",
	"Select": "View", "Start": "Menu", "DPadUp": "D-pad up", "DPadDown": "D-pad down", "DPadLeft": "D-pad left", "DPadRight": "D-pad right",
}
const PADDLE_EXPLAIN := "What this back button presses. Nothing = the game or Steam decides."
const GYRO_TITLE := "Gyro"
const GYRO_MODES := ["off", "mouse", "stick"]
const GYRO_LABELS := {"off": "Off", "mouse": "Mouse", "stick": "Right stick", "custom": "Custom"}
const GYRO_EXPLAIN := {
	"off": "Tilting does nothing.",
	"mouse": "Tilt to move the mouse. Great for aiming in shooters.",
	"stick": "Tilt to move the right stick. Works in games without mouse support.",
	"custom": "Set by another profile. Pick one to replace it.",
}
const GYRO_MISSING := {
	"fix": "This handheld's gyro needs a fix first: quick menu, Device.",
	"no": "There's a gyro inside, but Linux can't read it yet.",
	"none": "This handheld has no gyro.",
	"unknown": "We're not sure this handheld has a gyro.",
}
const RUMBLE_TITLE := "Rumble"
const RUMBLE_EXPLAIN := {true: "The controller buzzes when games ask it to.", false: "No buzzing, ever. Saves a little battery."}
const RUMBLE_TEST := "Test rumble"
const RUMBLE_MISSING := "This controller can't rumble, or InputPlumber can't reach its motors."
const LED_TITLE := "Lights"
const LED_LINE := "Shown here so you know they're there. GameCove can't change them yet: InputPlumber has no setting for lights."
const LED_BY := {"inputplumber": "InputPlumber", "hhd": "Handheld Daemon", "ayaneo-ec": "the AYANEO driver", "oxp-ec": "the OneXPlayer driver"}
const GAME_PROFILE_TITLE := "Own layout for this game"
const GAME_PROFILE_EXPLAIN := {true: "Back buttons and gyro here only apply to %s.", false: "This game uses your everyday layout."}
const GAME_PROFILE_IDLE := "Start a game to give it its own back buttons and gyro."
const TEST_TITLE := "Button test"
const TEST_LINE := "Press any button to see it light up. Handy for finding the back buttons."
const TEST_START := "Start button test"
const TEST_RUNNING := "Press any button"
const TEST_HOLD := "Hold B to stop"
const TEST_GAME_NOTE := "Back buttons only show up here with no game running."
const PICTURE_CAPTION := "Buttons light up as you press them"


# ---- Storage --------------------------------------------------------------------

const STORAGE_TITLE := "Storage"
const DRIVES_TITLE := "Drives"
const LIBRARIES_TITLE := "Game folders"
const STORAGE_LOADING := "Looking at your drives…"
const STORAGE_EMPTY := "No drives found"
const STORAGE_EMPTY_LINE := "That's odd. Try again in a moment, or check Desktop Mode."
const STORAGE_ERROR := "Couldn't read your drives"
const LIBRARIES_EMPTY := "No game folders yet. They show up after you install something."
const DRIVE_KINDS := {"internal": "Internal", "sd": "SD card", "external": "USB drive"}
const DRIVE_ICONS := {"internal": "handheld", "sd": "store", "external": "download"}
const STORE_NAMES := {"steam": "Steam", "heroic": "Heroic", "games": "GameCove"}
const FREE_OF := "%s free of %s"
const GAMES_COUNT := {1: "1 game"}
const MEASURE := "Measure size"
const MEASURING := "Measuring…"
const COMPRESSION_NOTE := "Compressed (%s): games take less space than they say."
const HOTPLUG_NOTE := "Plug in an SD card or USB drive and it shows up here."
const REMOVABLE := "Removable"


# ---- Updates --------------------------------------------------------------------

const UPDATES_TITLE := "Updates"
const KINDS := ["os", "firmware", "flatpak"]
const KIND_TITLES := {"os": "System", "firmware": "Firmware", "flatpak": "Apps"}
const KIND_ICONS := {"os": "update", "firmware": "bolt", "flatpak": "store"}
const KIND_LINES := {
	"os": "The whole system image. Installs in the background and takes over after a restart.",
	"firmware": "Small programs inside the hardware (controller, battery, drives) via fwupd.",
	"flatpak": "Apps from Flathub and your other app stores.",
}
const PHASES := {
	"unsupported": "Not available here", "idle": "Not checked yet", "checking": "Checking…",
	"up_to_date": "Up to date", "available": "Update ready", "applying": "Installing…",
	"staged": "Restart to finish", "error": "Something went wrong",
}
const PHASE_TONES := {"up_to_date": "good", "available": "info", "staged": "warn", "error": "bad", "applying": "info", "checking": ""}
const UNSUPPORTED_WHY := {
	"os": "We couldn't find this system's updater (steamos-update or rpm-ostree). Update from Desktop Mode instead.",
	"firmware": "fwupd isn't installed, so firmware can't be checked here.",
	"flatpak": "Flatpak isn't installed on this system.",
}
const CHECK := "Check now"
const CHECK_ALL := "Check for updates"
const APPLY := "Update"
const APPLY_ALL_FW := "Update firmware"
const REBOOT := "Restart now"
const REBOOT_LINE := "An update is ready. It takes over the next time the device starts."
const GAME_RUNNING := "Not while a game runs. Close it first, so nothing slows down or gets cut off."
const FIRMWARE_UNTRUSTED := "Not signed by LVFS, so it needs your admin password. Gaming Mode can't ask for one: update from Desktop Mode."
const FIRMWARE_REBOOT := "Needs a restart"
const NEEDS_PASSWORD := "This needs your admin password, and Gaming Mode can't ask for it. Try again from Desktop Mode."
const FINISHED_REASONS := {
	"game_running": GAME_RUNNING,
	"busy": "Already working on it.",
	"not_available": "Nothing to install. Check again first.",
	"unsupported": "Not available on this system.",
}
const PENDING_APPS := {1: "1 app to update"}
const VERSION_NOW := "Now: %s"
const VERSION_NEW := "New: %s"
const RELEASE_NOTES := "What's new"


static func gb(v: float) -> String:
	if v < 0.0:
		return UNKNOWN
	if v >= 1000.0:
		return "%.1f TB" % (v / 1000.0)
	return ("%d GB" % roundi(v)) if v >= 10.0 else ("%.1f GB" % v)


## Bytes for people: 1.2 TB, 512 GB, 3.4 GB, 120 MB. -1 = unknown.
static func bytes(n: float) -> String:
	if n < 0.0:
		return UNKNOWN
	if n >= 1e12:
		return "%.1f TB" % (n / 1e12)
	if n >= 1e10:
		return "%d GB" % roundi(n / 1e9)
	if n >= 1e9:
		return "%.1f GB" % (n / 1e9)
	if n >= 1e6:
		return "%d MB" % roundi(n / 1e6)
	return "%d KB" % roundi(n / 1e3)


static func games(n: int) -> String:
	return "1 game" if n == 1 else "%d games" % n


static func apps(n: int) -> String:
	return "1 app to update" if n == 1 else "%d apps to update" % n


static func mb(v: int) -> String:
	if v <= 0:
		return UNKNOWN
	return ("%d GB" % roundi(v / 1024.0)) if v >= 1024 else "%d MB" % v


static func paddle_target(t: String) -> String:
	return PADDLE_NOTHING if t == "" else str(PADDLE_TARGET_LABELS.get(t, t))


static func finished_text(kind: String, message: String) -> String:
	if FINISHED_REASONS.has(message):
		return FINISHED_REASONS[message]
	if message.contains("Not authorized") or message.contains("authentication") or message.contains("126"):
		return NEEDS_PASSWORD
	return "%s: %s" % [KIND_TITLES.get(kind, kind), message] if message != "" else ""
