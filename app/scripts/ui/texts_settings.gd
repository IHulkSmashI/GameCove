extends RefCounted
## Words for Settings, the quick menu additions and first-run setup. Plain,
## short, casual; jargon gets one line of explanation.

const CATEGORIES := ["appearance", "stores", "discover", "performance", "device", "about"]
const CATEGORY_NAMES := {
	"appearance": "Appearance", "stores": "Stores", "discover": "Discover",
	"performance": "Performance", "device": "Device", "about": "About GameCove",
}
const CATEGORY_ICONS := {
	"appearance": "palette", "stores": "store", "discover": "discover",
	"performance": "gauge", "device": "handheld", "about": "info",
}
const CATEGORY_LINES := {
	"appearance": "Colours, motion and sounds.",
	"stores": "Sign-ins, downloads, Steam.",
	"discover": "Prices, keys and alerts.",
	"performance": "Overlay and achievements.",
	"device": "Controller, storage, updates.",
	"about": "Version, setup and credits.",
}

# ---- Appearance

const SOUNDS_NOTE := "You won't hear these yet: GameCove ships with its audio driver off until we've measured what it costs in battery."

# ---- Stores

const STORE_NAMES := {"steam": "Steam", "epic": "Epic Games", "gog": "GOG", "amazon": "Amazon Games"}
const STORE_ORDER := ["steam", "epic", "gog", "amazon"]
const SIGN_IN := "Sign in"
const SIGNED_IN := "Signed in"
const SIGNED_IN_AS := "Signed in as %s"
const NOT_SIGNED_IN := "Not signed in"
const SIGN_IN_STEAM := "Steam signs in by itself. Open Steam once and sign in there."
const SIGN_IN_HEROIC := "Sign in from Heroic in Desktop Mode; GameCove picks it up."
const SIGN_IN_MISSING := "Its store tool isn't installed, so this store can't sign in yet."

const SIGN_IN_TITLE := "Sign in to %s"
const SIGN_IN_STEPS := {
	"code": ["Scan the code with your phone and sign in.", "The page then shows a code. Pick Type code and enter it here.", "That's it: your games show up in the library."],
	"redirect_url": ["Scan the code with your phone and sign in.", "You'll land on a page that may look broken. Copy its whole address.", "Pick Type code and paste or type that address here."],
}
const SIGN_IN_TYPE := "Type code"
const SIGN_IN_WAITING := "Getting the sign-in page ready…"
const SIGN_IN_CHECKING := "Checking the code…"
const SIGN_IN_DONE := "Signed in to %s."
const SIGN_IN_FAILED := "That didn't work: %s. Try again with a fresh code."
const SIGN_IN_NO_CODE := "There's no code in that. Type the code, or the whole address you landed on."
const SIGN_IN_KEYBOARD_TIP := "A USB or Bluetooth keyboard works too."

const INSTALL_FOLDER := "Install folder"
const INSTALL_FOLDER_HELP := "Where new Epic, GOG and Amazon games go. Steam keeps its own library folders."
const AUTO_RESUME := "Resume downloads"
const AUTO_RESUME_HELP := {false: "Paused or cut-off downloads wait for you to resume them.", true: "Downloads pick up where they stopped when GameCove starts."}
const PARALLEL := "Downloads at once"
const PARALLEL_HELP := "How many games download at the same time. One is fastest for each game."
const FOCUS_DIALOGS := "Bring Steam windows forward"
const FOCUS_DIALOGS_HELP := {false: "Steam's install and uninstall windows stay behind GameCove until you switch.", true: "When Steam needs you to confirm something, its window comes to the front."}

const STEAM_CONTROL := "Steam control"
const STEAM_CONTROL_HELP := {false: "Off: installs and settings for Steam games go through Steam's own windows.", true: "On: GameCove installs Steam games and changes their settings without opening Steam's windows."}
const STEAM_CONTROL_WARNING := "While on, any program on this device could control your signed-in Steam. Games running through Proton can also reach it. Turn on only if you trust what's installed. Turning it off takes effect after Steam restarts."
const STEAM_CEF_STATUS := {
	"off": "Off.",
	"flag_missing": "Steam needs a restart with remote control allowed. Restart Steam below.",
	"connecting": "Connecting to Steam…",
	"ready": "Connected to Steam.",
	"unreachable": "Can't reach Steam. Is it running?",
}
const STEAM_PENDING := "%d Steam change waiting. Steam has to restart to apply it."
const STEAM_PENDING_MANY := "%d Steam changes waiting. Steam has to restart to apply them."
const STEAM_RESTART := "Restart Steam to apply"
const STEAM_RESTARTING := "Restarting Steam…"

# ---- Discover

const COUNTRY_AUTO := "Auto (%s)"
const COUNTRY_SOURCES := {"settings": "you picked it", "steam": "from Steam", "timezone": "from your time zone", "locale": "from your language", "default": "default"}
## Countries Steam has its own prices for, most common first.
const COUNTRIES := ["US", "CA", "GB", "DE", "FR", "ES", "IT", "NL", "PL", "SE", "NO", "DK", "FI", "CH", "IE", "BE", "AU", "NZ", "BR", "MX", "JP", "KR", "IN", "TR", "ZA"]
const KEY_NONE := "Not set"
const KEY_SET := "Set"
const KEY_ENTER := "A to type it"
const KEY_BAD := "That doesn't look like a %s. Check it and try again."
const KEY_SAVED := "%s saved."
const KEY_REMOVED := "%s removed."
const AFFILIATE_NOTE := "Supports GameCove"

# ---- Performance

const OVERLAY := "Performance overlay"
const OVERLAY_HELP := {
	0: "Off. Nothing on screen while you play.",
	1: "Just the frame rate, in a corner.",
	2: "One slim row: frame rate, power, temperatures.",
	3: "Everything: frame time graph, CPU, GPU, battery.",
}
const OVERLAY_LABELS := ["Off", "Frame rate", "Compact", "Full"]
const OVERLAY_MISSING := "The overlay comes from MangoHud, which this session doesn't run. It works in the GameCove session on Bazzite and SteamOS."
const FPS_NEEDS_OVERLAY := "On this system the frame rate only comes in while the overlay shows (mangohudctl is missing). Keep it at Frame rate or above if you use Auto TDP."
const RARITY := "Achievement rarity"
const RARITY_HELP := {true: "Shows how many players unlocked each one. Asks Steam once a day per game.", false: "No rarity. GameCove never asks Steam for it."}

# ---- Device

const DEVICE_PANEL_TITLES := {"about": "About this device", "controller": "Controller", "storage": "Storage", "updates": "Updates"}
const DEVICE_PANEL_ICONS := {"about": "handheld", "controller": "gamepad", "storage": "download", "updates": "update"}
const DEVICE_PANEL_SOON := "Coming in the next build."

# ---- About

const ABOUT_TAGLINE := "The all-in-one companion for Linux handhelds."
const ABOUT_LICENSE := "Free and open source under GPL-3.0-or-later. Some parts carry their own licenses; see Credits."
const ABOUT_DATA := "Compatibility tiers: our summary of ProtonDB community reports (protondb.com), ODbL 1.0. Game data from IGDB (igdb.com): time to beat and release dates."
const ABOUT_CREDITS := "Credits and licenses"

# ---- Network and privacy (About; review M22)
const PRIVACY_CARD := "Network and privacy"
const PRIVACY_LINE := "What GameCove asks the internet for, and the switches for it."
const PRIVACY_BACKGROUND := "Background lookups"
const PRIVACY_BACKGROUND_HELP := {
	true: "GameCove refreshes deals, the game database and your device's photo by itself, never while you play.",
	false: "Nothing is requested unless you ask for it right then: opening a store page, searching, pressing Check.",
}
const PRIVACY_PRICES := "Look up deals and prices"
const PRIVACY_PRICES_HELP := "Sends your wishlist's Steam app ids and titles to CheapShark and the Steam store for prices."
const PRIVACY_CALLS := "What GameCove connects to"
const PRIVACY_NEVER := "Never sent: analytics, crash reports, serial numbers or account details. Affiliate links (Discover settings, on by default, none set up yet) only change a link's address, never what you pay."
const ABOUT_CREDITS_HELP := "Everyone whose work GameCove builds on."
const ABOUT_SOURCE := "Source code"
const ABOUT_ISSUE := "Report a problem"
const REPO_URL := "https://github.com/IHulkSmashI/gamecove"
const ISSUES_URL := "https://github.com/IHulkSmashI/gamecove/issues"
const LINK_OPENS := "Opens in Steam's browser."
const CREDITS_MISSING := "The credits file isn't on this device. Read it at github.com/IHulkSmashI/gamecove/blob/main/CREDITS.md."
const SETUP_CARD := "Setup checklist"
const SETUP_CARD_LINE := "Everything first-run setup covers. Open any step again."
const SETUP_OPEN := "Open setup"

# ---- Setup flow

const SETUP_STEPS := ["welcome", "theme", "stores", "art", "keys", "fixes", "done"]
## Our step -> the Setup service's step id.
const SETUP_SERVICE_IDS := {"welcome": "welcome", "theme": "theme", "stores": "stores", "art": "steamgriddb", "keys": "keys", "fixes": "device_fixes", "done": "done"}
const SETUP_STEP_NAMES := {"welcome": "Welcome", "theme": "Look", "stores": "Stores", "art": "Game art", "keys": "Keys", "fixes": "Device fixes", "done": "Done"}
const SETUP_STATE := {"done": "Done", "skipped": "Skipped", "todo": "To do"}

const WELCOME_TITLE := "Welcome to GameCove"
const WELCOME_LINE := "Let's set up your %s. It takes about two minutes, and you can skip anything."
const WELCOME_SUPPORT := {
	"full": "Tested on hardware: we run GameCove on this exact device.",
	"partial": "Supported from tested community data. A few things may need a nudge.",
	"beta": "Beta: testers say it works; we haven't tried it ourselves.",
	"generic": "We don't know this device well yet, so device-specific settings stay hidden.",
}
const THEME_TITLE := "Pick a look"
const THEME_LINE := "Changes right away. You can switch any time in Settings."
const STORES_TITLE := "Connect your stores"
const STORES_LINE := "Every store's games land in one library. Sign in with your phone: no typing passwords on the handheld."
const KEYS_TITLE := "Optional key"
const KEYS_LINE := "A free gg.deals key makes prices better. It stays on this device. Skip this if you like."
const KEY_GGDEALS_WHY := "Real prices from every store in your country, not just Steam's. Get a free key at gg.deals/api."
const KEY_SGDB_WHY := "Covers, banners and logos for every game. Choose to sign in to SteamGridDB with your phone: free, about a minute."
const FIXES_TITLE := "Fixes for your %s"
const FIXES_LINE := "Things that don't work out of the box on this device, and what we can do about them."
const FIXES_DESKTOP := "Installing a fix needs your admin password, and Gaming Mode can't ask for it. Switch to Desktop Mode, open GameCove there and install them from Quick menu, Device."
const FIXES_NONE := "Nothing to fix on this device. Nice."
const FIXES_CHECKING := "Checking what's already set up…"
const FIXES_GENERIC := "We don't have device fixes for this handheld yet."
const WELCOME_PLAN := {
	"theme": "Pick colours you like.",
	"stores": "Sign in with your phone.",
	"art": "Free covers for every game.",
	"keys": "A free extra, optional.",
	"fixes": "What this device needs.",
}
const WELCOME_PLAN_ICONS := {"theme": "palette", "stores": "store", "art": "library", "keys": "shield", "fixes": "sparkle"}
const DONE_TITLE := "You're all set"
const DONE_LINE := "Your games are on the home screen. Press %s any time for power, screen and game settings."
const DONE_TIPS := [
	["Home", "home", "What you played last comes first."],
	["Quick menu", "dots", "Power, screen and game settings."],
	["Settings", "settings", "Everything from setup, any time."],
]
const DONE_LATER := "Skipped steps wait for you in Settings, About GameCove."

const NEXT := "Next"
const BACK := "Back"
const SKIP := "Skip"
const SKIP_SETUP := "Skip setup"
const START := "Let's go"
const FINISH := "Start playing"
const CLOSE := "Close"

## Explanation for a store's sign-in state.
static func store_line(st: Dictionary) -> String:
	if bool(st.get("signed_in", false)):
		var acct := str(st.get("account", ""))
		return SIGNED_IN_AS % acct if acct != "" else SIGNED_IN
	match str(st.get("how", "")):
		"steam": return SIGN_IN_STEAM
		"heroic": return SIGN_IN_HEROIC
		"unavailable": return SIGN_IN_MISSING
	return "Not signed in. Sign in with your phone; no password typing here."


## True when GameCove can run the sign-in itself (QR + code).
static func can_sign_in(st: Dictionary) -> bool:
	return not bool(st.get("signed_in", false)) and str(st.get("how", "")) in ["code", "redirect_url"]


static func pending_line(n: int) -> String:
	return (STEAM_PENDING if n == 1 else STEAM_PENDING_MANY) % n


## "1 h 12 min", "8 min", "Just started".
static func session_time(seconds: int) -> String:
	var m := seconds / 60
	if m < 1:
		return "Just started"
	if m < 60:
		return "%d min" % m
	return "%d h %d min" % [m / 60, m % 60] if m % 60 != 0 else "%d h" % (m / 60)


## Key shown masked: "••••3f2a" or "Not set".
static func masked(key: String) -> String:
	var k := key.strip_edges()
	if k == "":
		return KEY_NONE
	return "••••" + k.right(4) if k.length() > 4 else KEY_SET


# ---- Quick menu additions

const QM_SUPPORT_PARTIAL := "Supported: built from community data tested on this device. We haven't run GameCove on it ourselves yet."
const QM_UNVERIFIED := "Not confirmed yet: %s."
const UNVERIFIED_NAMES := {"tdp": "power limits", "panel": "screen details", "panel.vrr": "VRR range", "panel.resolution": "screen resolution",
	"charge_limit": "charge limit", "chip": "chip name", "buttons": "button layout", "dmi": "device detection", "tdp.battery_max": "battery power limit", "all": "everything"}
const QM_SESSION := "Playing for %s"
const QM_EXIT := "Exit game"
const QM_EXIT_CONFIRM := "Press again to exit"
const QM_EXIT_LINE := "Sure? Unsaved progress is lost. Press A again, or move away to cancel."
const QM_EXITING := "Closing the game…"
const QM_PERF_HEADER := "Performance"
const QM_AUTOTDP := "Auto TDP"
const QM_AUTOTDP_ON := "On: power follows the game, under your TDP limit."
const QM_AUTOTDP_OFF := "Off for this game. Pick Longest battery or Balanced in This game to turn it on."
const QM_RAISE_TDP := "Can't hold %d fps at %d W. Raise the TDP (this device goes up to %d W) or lower the frame limit."
const QM_CANT_HOLD := "This game can't hold %d fps on this device. Lower its graphics settings or its frame limit."


static func unverified_line(fields: Array) -> String:
	if fields.is_empty():
		return ""
	var names: Array = []
	for f in fields:
		var n: String = UNVERIFIED_NAMES.get(str(f), str(f).replace("_", " "))
		if not n in names:
			names.append(n)
	return QM_UNVERIFIED % ", ".join(names)


## The Auto TDP "can't reach" line from Power.autotune_limit's info, or "".
static func autotune_line(cant_reach: bool, info: Dictionary) -> String:
	if not cant_reach:
		return ""
	var target := int(info.get("target_fps", 0))
	var ceiling := float(info.get("ceiling_w", -1.0))
	var tdp_max := float(info.get("tdp_max", -1.0))
	if ceiling > 0.0 and tdp_max > 0.0 and ceiling < tdp_max:
		return QM_RAISE_TDP % [target, int(round(ceiling)), int(round(tdp_max))]
	return QM_CANT_HOLD % target
