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
const CARD_LINE := "The row of buttons at the top of the quick menu. Pick which show and in what order. A shortcut only shows where it works: Keyboard and Send a key need a game on screen."
const ROW_ON := "Shown"
const ROW_OFF := "Hidden"
const MOVE_HINT := "X moves it up, Y moves it down."
const MOVE_UP := "Move up"
const MOVE_DOWN := "Move down"
const RESET := "Back to the usual shortcuts"
const RESET_HINT := "Keyboard, Screenshot, Record, Mouse mode, Mute, Send a key and Sleep, in that order."
const RESET_DONE := "Shortcuts are back to the usual ones."
const NOT_HERE := "Not on this handheld right now: %s"
const POSITION := "%d of %d"
