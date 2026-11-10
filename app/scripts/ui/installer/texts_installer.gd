extends RefCounted
## Words for the installer (app/scripts/ui/installer/). Plain and short.

const STEP_NAMES := {
	"welcome": "Welcome", "startup": "Startup", "steam": "Steam", "stores": "Stores", "device": "Device",
	"look": "Look", "art": "Art", "extras": "Extras", "summary": "Summary", "progress": "Install", "done": "Done",
	"maintenance": "GameCove", "uninstall": "Remove", "finish": "Finish",
}
const STEP_ICONS := {
	"welcome": "handheld", "startup": "power", "steam": "gamepad", "stores": "store", "device": "sparkle",
	"look": "palette", "art": "library", "extras": "tag", "summary": "check", "progress": "download", "done": "check",
	"maintenance": "settings", "uninstall": "x", "finish": "sparkle",
}

const TITLE := "GameCove Installer"
const NEXT := "Continue"
const BACK := "Back"
const SKIP := "Skip"
const INSTALL := "Install"
const APPLY := "Apply changes"
const REMOVE := "Remove GameCove"
const FINISH_FIXES := "Install fixes"
const CLOSE := "Close"
const RESTART := "Restart now"
const LATER := "Restart later"
const RETRY := "Try again"
const UNDO := "Undo changes"
const SHOW_LOG := "Open the log"
const RECOMMENDED := "Recommended"
const CHOSEN := "Chosen"

# ---- welcome
const WELCOME_TITLE := "Choose how to set up GameCove"
const WELCOME_LINE := "GameCove becomes the home screen of your %s. Works with mouse, touch or your controller."
const SUPPORT := {
	"full": "Fully supported",
	"partial": "Supported",
	"beta": "Beta support",
	"generic": "Not tested on this device",
}
const SUPPORT_LINE := {
	"full": "We test GameCove on this exact device.",
	"partial": "Set up from tested community data. A few things may need a nudge.",
	"beta": "Testers say it works; we haven't tried it ourselves.",
	"generic": "GameCove runs, but device-specific settings stay hidden.",
}
const OS_HOW := {
	"rpm-ostree": "%s. GameCove installs as a system package, next to Steam.",
	"sysext": "%s. GameCove installs as a system extension, next to Steam.",
	"none": "%s. This system can't take GameCove as its home screen, but you can set it up and try it in a window.",
}
const PLAN := [
	["power", "Start your way", "Boot straight into GameCove, or keep Steam and add GameCove as a choice."],
	["store", "Bring your games", "Sign in to Epic, GOG and Amazon here on the desktop. Steam stays as it is."],
	["sparkle", "Set up the device", "Fixes for things that don't work out of the box, and power defaults."],
]
const MODE_EASY := "Easy"
const MODE_EASY_CARD := "Easy"
const MODE_EASY_FOOT := "Recommended defaults"
const SELECTED_DEFAULT := "Selected by default"
const SELECTED := "Selected"
const STEP_BY_STEP := "Step-by-step"
const MODE_CUSTOM_FOOT := "Choose every setting"
const DETECTED := "DETECTED HANDHELD"
const WHAT_WILL_HAPPEN := "WHAT WILL HAPPEN"
const LOCKUP_LINE := "LINUX HANDHELD INSTALLER"
const SWITCH_STEP := "Switch step"
const MODE_EASY_LINE := "Tested defaults for your %s on %s: boots into GameCove with Steam quietly in the background, adds the device fixes, keeps your store sign-ins, and helps you get free game art. You see a summary before anything changes."
const MODE_CUSTOM := "Custom"
const MODE_CUSTOM_LINE := "Go through every option yourself: startup, how Steam runs, each device fix, power defaults, theme, game art and the optional extras."
const NO_PACKAGE := "The download for this system is missing. Run the install command again to fetch it."

# ---- startup
const STARTUP_TITLE := "How should your handheld start?"
const STARTUP_LINE := "Pick what you see when you turn it on. You can change this any time."
const STARTUP := {
	"gamecove": ["Boot into GameCove", "GameCove is your home screen. Steam keeps running quietly in the background for your Steam games."],
	"steam": ["Keep Steam, add GameCove", "Steam Gaming Mode stays the default. Switch to GameCove from the desktop or the login screen."],
	"desktop": ["Desktop only (try it first)", "Nothing changes at startup. Try GameCove in a window on the desktop first."],
}
const STARTUP_BACK := "You can switch back any time. If GameCove keeps crashing, you land in Steam Gaming Mode."
const STARTUP_FOOT := {"gamecove": "Default gaming session", "steam": "Two-session mode", "desktop": "No boot changes"}

# ---- steam
const STEAM_TITLE := "How should GameCove work with Steam?"
const STEAM_CARD := "Steam"
const STEAM_TIP := "You can change this any time in Settings, Stores."
const STEAM_LINE := "Your Steam games launch from GameCove through Steam itself, so Steam needs to run."
const STEAM_MODE := "How Steam runs"
const STEAM_MODES := {"silent": "In the background", "gamepadui": "Steam's own screen", "off": "Off"}
const STEAM_MODE_LINES := {
	"silent": "Recommended. Steam runs hidden: games, cloud saves, Steam Input and the in-game overlay all work.",
	"gamepadui": "Steam's handheld screen runs hidden behind GameCove, with its own keyboard and quick menu. Experimental: it may try to take over the screen.",
	"off": "Steam doesn't start. Lightest, but Steam games won't launch until something starts Steam.",
}
const STEAM_SIGNED_IN := "Signed in as %s"
const STEAM_SIGNED_IN_PLAIN := "Signed in"
const STEAM_NOT_SIGNED := "Steam isn't signed in yet"
const STEAM_NOT_SIGNED_LINE := "Open Steam, sign in, then come back here. Your Steam games show up in GameCove after that."
const STEAM_MISSING := "Steam isn't installed"
const STEAM_MISSING_LINE := "Install Steam from your app store to play Steam games. Everything else works without it."
const STEAM_OPEN := "Open Steam to sign in"
const STEAM_CHECK := "Check again"

# ---- stores
const STORES_TITLE := "Connect your stores"
const STORES_LINE := "Sign in on the store's own page in your browser. GameCove never sees your password; it keeps only the store tool's sign-in token."
const STORES_HEROIC := "Heroic is set up here: GameCove uses its sign-ins, so stores you signed in to there are ready."
const BROWSER_SIGNIN := "Browser sign-in"
const SIGN_IN_BROWSER := "Sign in (opens your browser)"
const STORE_READY := "Ready: games show up in your library"
const STORE_NOT_HERE := "Can't sign in from here"
const STORES_LATER := "You can skip this and connect stores later in Settings."
const STORE_ROW_LINE := {
	"signed": "Signed in%s.",
	"code": "Opens the sign-in page in your browser.",
	"redirect_url": "Opens the sign-in page in your browser.",
	"heroic": "Sign in from Heroic on the desktop; GameCove picks it up.",
	"unavailable": "Its store tool isn't installed. Install Heroic to add this store.",
	"steam": "Set on the Steam page.",
}
const SIGNIN_TITLE := "Sign in to %s"
const SIGNIN_STEPS := {
	"epic": ["Open the sign-in page and sign in to Epic.", "The page then shows a short text with \"authorizationCode\".", "Copy all of it and come back here. We pick it up by ourselves, or press Paste."],
	"gog": ["Open the sign-in page and sign in to GOG.", "You land on a mostly empty page. Copy its whole address from the address bar.", "Come back here. We pick it up by ourselves, or press Paste."],
	"amazon": ["Open the sign-in page and sign in to Amazon.", "You land on an Amazon page. Copy its whole address from the address bar.", "Come back here. We pick it up by ourselves, or press Paste."],
}
const SIGNIN_OPEN := "Open sign-in page"
const SIGNIN_PASTE := "Paste"
const SIGNIN_TYPE := "Type it"
const SIGNIN_BACK := "All stores"
const SIGNIN_WAITING := "Waiting for the code…"
const SIGNIN_PREPARING := "Getting the sign-in page ready…"
const SIGNIN_CHECKING := "Checking…"
const SIGNIN_OK := "Signed in to %s."
const SIGNIN_FAILED := "That didn't work: %s"
const SIGNIN_NO_CODE := "The clipboard has no sign-in code. Copy the whole page text or address, then press Paste."
const SIGNIN_TYPE_HINT := "Code or address"

# ---- device
const DEVICE_TITLE := "Set up your %s"
const DEVICE_LINE := "Fixes for things that don't work out of the box. Installing them asks for your admin password once; each one can be removed later."
const DEVICE_NO_FIXES := "This device needs no fixes."
const DEVICE_GENERIC := "We don't have fixes for this device yet."
const DEVICE_RESTART := "Some fixes only start working after a restart, and the gyro needs a full shutdown and power on. The last page reminds you."
const PROGRESS_NOW := "Status"
const DONE_EYEBROW := "Setup complete"
const POWER_HEADER := "Power defaults"
const FIXES_HEADER := "Recommended fixes"
const FIXES_MATCHED := "Matched for %s"
const DEVICE_REVERSIBLE := "Every fix can be removed later in Settings, Device."
const AUTO_TDP := "Auto TDP"
const AUTO_TDP_LINES := {true: "Games use only the power they need to hold their frame rate. Saves battery.", false: "Games get the full power limit of their profile."}
const PROFILE := "Power profile"
const PROFILES := {"battery": "Battery", "balanced": "Balanced", "performance": "Performance"}
const PROFILE_LINES := {
	"battery": "Lowest power. Longest battery, fine for older and 2D games.",
	"balanced": "A good middle for most games.",
	"performance": "Full power. Fastest, shortest battery.",
}
const CHARGE := "Charge limit"
const CHARGE_LINE := "Stops charging at this level so the battery lasts more years. 100% = no limit."
const NO_POWER := "Power settings aren't available on this device yet."

# ---- look
const LOOK_TITLE := "Pick a look"
const LOOK_LINE := "Changes right away. You can switch any time in Settings."
const THEME := "Theme"
const MATCH_ART := "Match game art colours"
const MATCH_ART_LINES := {true: "Each game tints the screen with its own colours.", false: "The theme's colours everywhere."}
const REDUCE_MOTION := "Reduce motion"
const REDUCE_MOTION_LINES := {false: "Smooth movement when you move around.", true: "Things change at once, with no movement."}

# ---- extras
const EXTRAS_TITLE := "Extras"
const EXTRAS_LINE := "All optional. Each one stays on this device."
const MOONLIGHT := "Moonlight, for streaming from your PC"
const MOONLIGHT_LINES := {true: "Installs the free Moonlight player from Flathub, so the Stream tab can play games from a PC running Vibepollo.", false: "You can install it later from the Stream tab."}
const GGDEALS := "gg.deals key"
const GGDEALS_LINE := "Real prices from every store in your country. Free at gg.deals/api (sign in, then API key)."
const SGDB := "SteamGridDB key"
const SGDB_LINE := "Covers, banners and logos for every game, from your own free SteamGridDB key."
const ART_SET := "Your SteamGridDB key"
const ART_NONE := "Steam art only"
const STEAM_PROFILE := "Steam profile"
const STEAM_PROFILE_LINE := "Your profile link or name, to bring in your Steam wishlist. Your game details must be public."
const REGION := "Store country"
const REGION_AUTO := "Auto"
const REGION_LINE := "Prices show as the stores charge them in this country. Auto works it out from Steam or your time zone."
const KEY_BAD := "That doesn't look like a %s. Check it and try again."
const NOT_SET := "Not set"

# ---- summary
const SUMMARY_TITLE := "Ready to install"
const EYEBROWS := {"welcome": "Welcome to GameCove setup", "startup": "Boot mode", "steam": "Steam integration", "stores": "Game libraries", "device": "Hardware", "look": "Appearance", "art": "Artwork", "extras": "Extras", "summary": "Review", "progress": "Installation", "done": "All done", "maintenance": "Installed", "uninstall": "Remove", "finish": "After restart"}
const SUMMARY_LINE := "This is what happens. Press any row to change it."
const SUMMARY_CHANGE_TITLE := "Ready to apply"
const SUMMARY_STORES := {"none": "None signed in", "skipped": "Skipped"}
const SUMMARY_NO_FIXES := "No fixes"
const SUMMARY_EXTRAS_NONE := "None"
const SUMMARY_PASSWORD := "Your admin password is asked for when GameCove installs, and once more for device fixes."
const SUMMARY_PASSWORD_NONE := "Nothing here needs your admin password."
const SUMMARY_REBOOT := "A restart finishes the install. Your current system stays in the boot menu, just in case."
const SUMMARY_STEAM_CONTROL := "Steam control on"

# ---- XeSS XMX driver (Intel Arc with XMX only)
const XESS_TITLE := "XeSS XMX driver"
const XESS_LINE := "Lets XeSS and XeLL use the Arc chip's XMX cores in games: sharper upscaling and less input lag. Optional; you can remove it later."
const XESS_BADGE := "Intel Arc"
const XESS_TIME := "~1 MIN"
const XESS_FOOT := "PRESS A TO ADD IT"
const XESS_ON := "WILL BE INSTALLED"
const XESS_SUMMARY := "XeSS XMX driver"

# ---- progress
const PROGRESS_TITLE := {
	"install": "Installing GameCove", "change": "Applying your changes", "repair": "Repairing GameCove",
	"update": "Updating GameCove", "uninstall": "Removing GameCove", "finish": "Installing fixes",
}
const PROGRESS_STOPPED := {
	"install": "Install stopped", "change": "Changes stopped", "repair": "Repair stopped",
	"update": "Update stopped", "uninstall": "Removal stopped", "finish": "Fixes stopped",
}
const PROGRESS_LINE := "Keep the handheld plugged in or charged. A password window may pop up; that's your system asking, not us."
const TASKS := {
	"check_game": "Make sure no game is running",
	"package": "Install GameCove",
	"package_update": "Update GameCove",
	"package_remove": "Remove GameCove",
	"fix_install": "Install fix: %s",
	"fix_remove": "Remove fix: %s",
	"user_files": "Save Steam and shortcut settings",
	"pending": "Set what starts at boot",
	"apply_now": "Apply the startup choice",
	"state": "Remember your choices",
	"session_restore": "Make Steam Gaming Mode the default again",
	"steam_unwrap": "Take GameCove out of your Steam games' launch options",
	"fix_remove_all": "Undo every device fix and setting (charge limit, fan, lights, rules)",
	"remove_user_files": "Remove GameCove's shortcuts and startup files",
	"remove_settings": "Remove GameCove's settings",
	"forget": "Forget the install",
	"xess_install": "Install the XeSS XMX driver",
	"xess_remove": "Remove the XeSS XMX driver",
	"moonlight_remote": "Add Flathub for this user",
	"moonlight_install": "Install Moonlight for PC streaming",
}
const TASK_WHY := {
	"xess_install": "Downloads it from GitHub; no password needed.",
	"package": "Asks for your admin password.",
	"package_update": "Asks for your admin password.",
	"package_remove": "Asks for your admin password.",
	"fix_install": "Asks for your admin password.",
	"fix_remove": "Asks for your admin password.",
	"moonlight_install": "No password: it installs for this user only.",
}
const STATE := {"": "", "running": "Working…", "ok": "Done", "failed": "Failed", "skipped": "Skipped",
	"pending": "After restart", "undone": "Undone"}
const STATE_TAGS := {"": "Queued", "running": "Running", "ok": "Done", "failed": "Failed", "skipped": "Skipped", "pending": "After restart", "undone": "Undone"}
const ERR := {
	"game_running": "A game is running. Close it first, then try again: we never change anything during a game.",
	"no_password": "No admin password was given, so nothing changed. Try again and enter your password when asked.",
}
const FAILED := "Something went wrong: %s"
const UNDO_OK := "Everything this run changed is undone."
const UNDO_PARTLY := "Some changes couldn't be undone. The log has the details."
const LOG_AT := "Log: %s"
const WAIT_TO_CLOSE := "Hang on, this is still running. Close the installer once it's done."

# ---- done
const DONE_TITLE := {
	"install": "GameCove is installed", "change": "Changes applied", "repair": "GameCove is repaired",
	"update": "Update ready", "uninstall": "GameCove is removed", "finish": "Fixes installed",
}
const NEXT_BOOT := {
	"gamecove": "After the restart your handheld starts GameCove. Steam runs in the background.",
	"steam": "After the restart Steam Gaming Mode starts as before. Pick GameCove from the desktop or the login screen.",
	"desktop": "After the restart nothing changes at startup. Open \"GameCove (window)\" from the app menu to try it.",
}
const WHATS_NEXT := "What happens next"
const NEXT_BOOT_UNINSTALL := "After the restart your handheld starts Steam Gaming Mode, and GameCove is gone."
const RESTART_NEEDED := "Restart to finish. Until then nothing changes."
const RESTART_OPTIONAL := "GameCove is ready now. A restart starts it the way you picked."
const WAITING_FIXES := "Device fixes wait until after the restart: open the desktop once and the installer finishes them (it asks for your password)."
const COLD_BOOT := "The gyro fix needs a full shutdown: turn the handheld off, wait a few seconds, turn it on."
const RESTART_FIX := "Some fixes start working after a restart."
const NO_GAME_REBOOT := "A game is running. Close it before restarting."

# ---- maintenance
const MAINT_TITLE := "GameCove is installed"
const MAINT_STAGED := "GameCove is installed and starts after the next restart."
const MAINT_INFO := "Version %s, installed as %s."
const METHOD_NAMES := {"rpm-ostree": "a system package", "sysext": "a system extension", "none": "settings only"}
const MAINT_CHANGE := "Change options"
const MAINT_CHANGE_LINE := "Startup, Steam, stores, device fixes, look and extras."
const MAINT_REPAIR := "Repair"
const MAINT_REPAIR_LINE := "Installs GameCove, its fixes and its startup files again, with the same choices."
const MAINT_UPDATE := "Update to %s"
const MAINT_UPDATE_LINE := "Installs the newer version. A restart finishes it."
const MAINT_UP_TO_DATE := "Up to date"
const MAINT_UP_TO_DATE_LINE := "You have the newest version we know of."
const MAINT_REMOVE := "Remove GameCove"
const MAINT_REMOVE_LINE := "Makes Steam Gaming Mode the default again and takes GameCove off the system."

# ---- uninstall
const UNINSTALL_TITLE := "Remove GameCove?"
const UNINSTALL_LINE := "Steam Gaming Mode becomes the default again, GameCove comes off the system, and its shortcuts go. Your games stay where they are."
const REMOVE_FIXES := "Undo device fixes too"
const REMOVE_FIXES_LINES := {true: "Every fix GameCove installed is removed, as if it was never there.", false: "Fixes stay in place; they work without GameCove."}
const KEEP_SETTINGS := "Keep my settings"
const KEEP_SETTINGS_LINES := {true: "Settings and sign-ins stay, so installing again picks up where you left off.", false: "GameCove's settings and downloads are deleted too. Store sign-ins belong to the store tools and stay."}

# ---- finish
const FINISH_TITLE := "Finish setting up"
const FINISH_LINE := "These device fixes waited for the restart. Installing them asks for your admin password."


static func task_title(t: Dictionary) -> String:
	var base: String = TASKS.get(str(t.get("id", "")), str(t.get("id", "")))
	if "%s" in base:
		var Texts = load("res://scripts/ui/texts.gd")
		return base % Texts.fix_title(str(t.get("fix", "")))
	return base


static func error_line(msg: String) -> String:
	if ERR.has(msg):
		return ERR[msg]
	return FAILED % msg
