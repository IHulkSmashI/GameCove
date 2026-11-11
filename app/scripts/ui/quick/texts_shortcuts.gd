extends RefCounted
## Words for the quick menu's Shortcuts strip, its sheets, Settings > Quick menu
## and the button shortcuts. Plain and short; the actions' own names and help
## lines live in scripts/actions/registry.gd.

# ---- strip ----------------------------------------------------------------------------
const STRIP_NAME := "Shortcuts"
const REC_LABELS := {"record": "", "busy": "Wait…", "set_up": "Set up"}
const REC_STOP := "Stop"
const OVERLAY_LABELS := {"off": "Off", "fps": "Frame rate", "compact": "Compact", "bar": "Bar", "full": "Full", "custom": "Custom"}

# ---- results (toasts) -----------------------------------------------------------------
const CANT := "%s: %s"
const TURNED_ON := "%s on"
const TURNED_OFF := "%s off"
const OVERLAY_NOW := "Performance overlay: %s"
const FAILED := "%s didn't change."
const SHOT_SAVED := "Screenshot saved"
const SHOT_SAVED_DETAIL := "Pictures/Screenshots · Settings > Media"
const SHOT_FAILED := "The screenshot didn't save."
const KEYBOARD_FAILED := "Steam didn't open its keyboard. Is Steam running?"
const KEY_FAILED := "%s didn't reach the game."
const KEY_SENT := "%s sent"
const FORCE_CLOSED := "Closed %s"
const THE_GAME := "the game"
const THE_GAME_CAP := "The game"
const HOLD_TO := "Hold the button for a second to %s."
const POWER_FAILED := "That didn't work. Try the power button."

# ---- sheets ---------------------------------------------------------------------------
const KEYS_TITLE := "Send a key"
const KEYS_LINE := "Pressed in the game, for launchers and dialogs that want a keyboard."
const FORCE_TITLE := "Force close %s?"
const FORCE_LINE := "For a game that hangs. Anything it hasn't saved is lost."
const FORCE_YES := "Force close"
const FORCE_NO := "Keep playing"
const POWER_TITLE := "Power"
const POWER_LINE := "Pick one, then confirm."
const POWER_GAME_LINE := "%s closes without saving."
const POWER_CONFIRM := {"restart": "Restart now?", "shutdown": "Shut down now?", "desktop": "Switch to Desktop Mode?", "steam": "Switch to Steam Gaming Mode?"}
const POWER_YES := {"restart": "Restart", "shutdown": "Shut down", "desktop": "Switch", "steam": "Switch"}
const POWER_NO := "Stay here"

# ---- Settings > Quick menu ------------------------------------------------------------
const PAGE_NAME := "Quick menu"
const PAGE_LINE := "Shortcuts and their order."
const CARD := "Shortcuts"
const CARD_LINE := "The row of buttons at the top of the quick menu. Pick which show and in what order. A shortcut only shows where it works: Keyboard, Steam menu and Send a key need a game on screen."
const ROW_ON := "Shown"
const ROW_OFF := "Hidden"
const MOVE_HINT := "X moves it up, Y moves it down."
const MOVE_UP := "Move up"
const MOVE_DOWN := "Move down"
const RESET := "Back to the usual shortcuts"
const RESET_HINT := "Keyboard, Steam menu, Screenshot, Record, Mouse mode, Mute, Send a key and Sleep, in that order."
const RESET_DONE := "Shortcuts are back to the usual ones."
const NOT_HERE := "Not on this handheld right now: %s"
const POSITION := "%d of %d"

# ---- Settings > Controller > Button shortcuts -----------------------------------------
const BS_TITLE := "Button shortcuts"
const BS_LINE := "What each button does when you press it, and when you hold it. They work in games too, before Steam Input's own layout."
const BS_PRESS := "Press"
const BS_HOLD := "Hold"
const BS_PRESS_BUILT_IN := "A press: %s."
const BS_PRESS_HINT := "Pick a GameCove action, a key, a gamepad button or a mouse click."
const BS_HOLD_HINT := "Held for the hold time: runs this. A short press stays the same."
const BS_BACK := "%s · back"
const BS_SIDE := {"left": "left", "right": "right"}
const BS_BUILT_IN := {"home": "Home", "quick_menu": "Quick menu", "osk": "Keyboard", "screenshot": "Screenshot"}
const BS_STEAM_NOTE := "In a game, Quick Access opens GameCove's quick menu. Steam's own menu is the Steam menu shortcut in the quick menu, or switch this on to give the button back to Steam."
const BS_GROUPS_TITLE := "%s: press"
const BS_GROUPS_LINE := "What a press of this button does."
const BS_HOLD_TITLE := "%s: hold"
const BS_HOLD_LINE := "What holding this button does."
const BS_GROUP := {"itself": "As itself", "off": "Off", "action": "A GameCove action", "keys": "A key", "pad": "A gamepad button",
	"mouse": "A mouse click", "custom": "Make a key combination"}
const BS_GROUP_DETAIL := {"itself": "What the handheld sends.", "off": "Does nothing.",
	"action": "Screenshot, Keyboard, Steam menu, Record…", "keys": "Esc, Alt + Enter, Insert for OptiScaler…",
	"pad": "A, B, the bumpers, the sticks…", "mouse": "Left or right click.", "custom": "Up to three of Ctrl, Shift, Alt, Super, then one key."}
const BS_MODS_TITLE := "Hold which keys with it?"
const BS_MODS_LINE := "Then pick the key itself."
const BS_MODS := [["", "Nothing"], ["KeyLeftCtrl", "Ctrl"], ["KeyLeftShift", "Shift"], ["KeyLeftAlt", "Alt"], ["KeyLeftMeta", "Super"],
	["KeyLeftCtrl+KeyLeftShift", "Ctrl + Shift"], ["KeyLeftCtrl+KeyLeftAlt", "Ctrl + Alt"], ["KeyLeftShift+KeyLeftAlt", "Shift + Alt"]]
const BS_KEY_TITLE := "Which key?"
const BS_KEY_LINE := "%s + this key"
const BS_TEST_TITLE := "Try them"
const BS_TEST_IDLE := "Press or hold a button with a shortcut: it shows here, and the button lights up on the picture."
const BS_TEST_NOTE := "Keys and gamepad buttons go straight to the game, so try those in a game."
const BS_TEST_DOWN := "%s is down…"
const BS_TEST_PRESS := "%s: pressed · %s"
const BS_TEST_HOLD := "%s: held · %s"
const BS_RESET_DONE := "Button shortcuts are back to the usual ones."
const BS_UNAVAILABLE := "Not here: %s"
