extends RefCounted
## Words for the game page, downloads and game actions. Plain and short; any
## jargon gets one line of explanation. Kept apart from texts.gd so screens
## owned by other people don't collide with these.

## States that mean "something is happening to this game right now".
const BUSY := ["queued", "installing", "updating", "verifying", "moving", "uninstalling", "downloading", "paused"]
## Busy states where bytes move (progress bar makes sense).
const RUNNING := ["installing", "updating", "verifying", "moving", "uninstalling", "downloading"]

## What a job is doing, as a short verb phrase (downloads list, progress line).
const ACTION_ING := {
	"install": "Installing", "update": "Updating", "verify": "Checking files",
	"move": "Moving", "uninstall": "Uninstalling", "download": "Downloading",
}
const STATE_LABEL := {
	"queued": "Waiting", "installing": "Installing", "updating": "Updating",
	"verifying": "Checking files", "moving": "Moving", "uninstalling": "Uninstalling",
	"downloading": "Downloading", "paused": "Paused", "installed": "Installed",
	"not_installed": "Not installed", "update_required": "Update needed", "failed": "Failed",
}
## Short tile-corner wording for each busy state (percent replaces it when known).
const STATE_SHORT := {
	"queued": "Queued", "paused": "Paused", "verifying": "Checking", "moving": "Moving",
	"uninstalling": "Removing", "installing": "Installing", "updating": "Updating", "downloading": "Downloading",
}
## Past tense for the "Done" list and toasts.
const ACTION_DONE := {
	"install": "Installed", "update": "Updated", "verify": "Files checked",
	"move": "Moved", "uninstall": "Uninstalled", "download": "Downloaded",
}
const ACTION_NAME := {
	"install": "install", "update": "update", "verify": "check the files of", "move": "move",
	"uninstall": "uninstall", "launch_options": "change launch options for",
	"compat_tool": "change the compatibility tool for", "pause": "pause", "resume": "resume", "cancel": "cancel",
}

# ------------------------------------------------------------ game page

const MANAGE := "Manage"
const MANAGE_HINT := "Uninstall, move, check files, launch options"
const VERIFY := "Check and repair files"
const VERIFY_DETAIL := "Finds broken or missing files and fixes them."
const MOVE := "Move to another drive"
const MOVE_DETAIL := "Frees space here; the game plays the same from its new place."
const LAUNCH_OPTIONS := "Launch options"
const LAUNCH_OPTIONS_DETAIL_STEAM := "Extra settings Steam adds when the game starts."
const LAUNCH_OPTIONS_HOWTO_STEAM := "Put %command% where the game goes."
const LAUNCH_OPTIONS_DETAIL := "Extra words added when GameCove starts the game."
const LAUNCH_OPTIONS_EXAMPLE_STEAM := "Example: PROTON_LOG=1 %command%"
const LAUNCH_OPTIONS_EXAMPLE := "Example: -skipintro"
const COMPAT := "Compatibility tool"
const COMPAT_DETAIL := "Which Proton runs this game. Default suits most games."
const STEAM_STORE := "Store page in Steam"
const STEAM_STORE_DETAIL := "Opens the game's Steam page: reviews, DLC, news."
const STEAM_PROPS := "Steam properties"
const STEAM_PROPS_DETAIL := "Steam's own settings for this game: betas, cloud saves, DLC."
const UNINSTALL := "Uninstall"
const UNINSTALL_DETAIL := "Deletes the game's files. Saves synced to the cloud stay safe."
const UPDATE := "Update"
const UPDATE_DETAIL := "Downloads the latest version now."
const PAUSE := "Pause"
const RESUME := "Resume"
const CANCEL := "Cancel"
const CANCEL_DOWNLOAD := "Cancel download"
const CANCEL_DETAIL := "Stops and removes what's been downloaded so far."

const PENDING_TITLE := "Steam changes waiting"
const PENDING_LINE := "Steam reads them when it starts. Restart it to use them now."
const RESTART_STEAM := "Restart Steam to apply"
const RESTARTING := "Restarting Steam…"

const ACH_TITLE := "Achievements"
const ACH_LOADING := "Reading achievements…"
const ACH_NONE := "No achievements found. Steam keeps them once you've played this game while signed in."
const ACH_EMPTY_GAME := "This game has no achievements."
const ACH_HIDDEN := "Hidden achievement"
const ACH_HIDDEN_DETAIL := "Keep playing to find out."
const ACH_LOCKED := "Locked"
const ACH_RAREST := "Rarest"
const ACH_SHOW_ALL := "Show all %d"

const ABOUT := "About this game"
## Time to beat as three chips on the game page.
const TTB_MAIN := "Main"
const TTB_EXTRAS := "Extras"
const TTB_ALL := "100%"
const TTB_FROM := "Times from %d %s"
const SETTINGS_TITLE := "Launch settings"
const SETTINGS_HIDE := "Hide launch settings"
const SETTINGS_SUB := "Saved for this game and used every time it starts."

# ------------------------------------------------------------ install picker

const WHERE_TITLE := "Where should it go?"
const WHERE_SUB := "Pick a drive. You can move it later."
const MOVE_TITLE := "Move to"
const MOVE_SUB := "The game keeps working; this can take a few minutes."
const COMPAT_TITLE := "Compatibility tool"
const INTERNAL := "Internal storage"
const SD_CARD := "SD card or USB drive"
const CURRENT := "Current"
const LOW_SPACE := "Not much room left"

const CONFIRM_UNINSTALL := "Uninstall %s?"
const CONFIRM_UNINSTALL_SUB := "This deletes its files from this device. Cloud saves stay safe; local saves may not."
const CONFIRM_YES := "Uninstall"
const CONFIRM_NO := "Keep it"
const CONFIRM_CANCEL := "Cancel %s?"
const CONFIRM_CANCEL_SUB := "What's been downloaded so far is thrown away."
const CONFIRM_CANCEL_YES := "Cancel download"
const CONFIRM_CANCEL_NO := "Keep downloading"

# ------------------------------------------------------------ downloads

const DL_TITLE := "Downloads"
const DL_EMPTY := "Nothing downloading"
const DL_EMPTY_SUB := "Games you install or update show up here with their progress."
const DL_NOW := "Now"
const DL_NOW_PREFIX := "Now"
const DL_NEXT_NONE := "Nothing else in the queue."
const DL_DONE_NONE := "Nothing finished yet."
const DL_NEXT := "Up next"
const DL_DONE := "Finished"
const DL_OPTIONS := "Options"
const DL_UP := "Move up"
const DL_DOWN := "Move down"
const DL_PAGE := "Game page"
const DL_STEAM_PAGE := "Steam's downloads page"
const DL_BROWSE := "See games to install"
const QUEUED_AS := {"install": "Waiting to install", "update": "Waiting to update", "verify": "Waiting to check files", "move": "Waiting to move", "uninstall": "Waiting to uninstall"}

# ------------------------------------------------------------ Steam window

const STEAM_NEEDS := "Steam needs you for a moment"
const STEAM_REASON := {
	"install": "Steam is asking where to install %s. Answer it in Steam's window, then come back.",
	"uninstall": "Steam wants you to confirm removing %s.",
	"page": "Steam has opened a page for %s.",
	"manage": "Steam is showing a window for %s.",
}
const HEROIC_NEEDS := "Heroic needs you for a moment"
const BACK_TO_COVE := "Back to GameCove"
const STEAM_TIP := "We come back here on our own once Steam starts the job."

# ------------------------------------------------------------ main / toasts

const FAILED := "Couldn't %s %s"
const STARTED := {
	"install": "Installing %s", "update": "Updating %s", "verify": "Checking %s",
	"move": "Moving %s", "uninstall": "Uninstalling %s",
}
const SAVED := "Saved"
const SAVED_PENDING := "Saved. Steam applies it after a restart."
const AUTOTUNE_RAISE := "Can't hold %d fps at %d W"
const AUTOTUNE_RAISE_SUB := "Raise the power limit (TDP) in the quick menu to hold it."
const AUTOTUNE_LOWER := "This game can't hold %d fps here"
const AUTOTUNE_LOWER_SUB := "Lower its graphics settings or its frame rate limit."


## "4.2 GB", "820 MB". Binary units with plain names, like Steam shows them.
static func bytes(n: int) -> String:
	if n < 0:
		return "?"
	var units := ["B", "KB", "MB", "GB", "TB"]
	var v := float(n)
	var i := 0
	while v >= 1024.0 and i < units.size() - 1:
		v /= 1024.0
		i += 1
	if i == 0:
		return "%d B" % n
	return ("%.1f %s" % [v, units[i]]) if v < 100.0 else ("%d %s" % [int(v), units[i]])


## "18.4 MB/s"; "" when unknown.
static func rate(bytes_per_s: float) -> String:
	if bytes_per_s <= 0.0:
		return ""
	return bytes(int(bytes_per_s)) + "/s"


## "about 6 min left"; "" when unknown.
static func eta(seconds: int) -> String:
	if seconds < 0:
		return ""
	if seconds < 60:
		return "less than a minute left"
	var m := int(ceil(seconds / 60.0))
	if m < 60:
		return "about %d min left" % m
	return "about %d h %d min left" % [m / 60, m % 60] if m % 60 != 0 else "about %d h left" % (m / 60)


## One line of numbers for a job: "4.2 GB of 12.8 GB · 18.4 MB/s · about 6 min left".
## p: {"bytes_done", "bytes_total", "rate", "eta", "unit"} (any missing).
static func progress_line(p: Dictionary) -> String:
	var parts: Array[String] = []
	var done := int(p.get("bytes_done", -1))
	var total := int(p.get("bytes_total", 0))
	if str(p.get("unit", "bytes")) == "files":
		if total > 0:
			parts.append("%d of %d files" % [maxi(done, 0), total])
	elif total > 0 and done >= 0:
		parts.append("%s of %s" % [bytes(done), bytes(total)])
	elif done > 0:
		parts.append(bytes(done))
	var r := rate(float(p.get("rate", 0.0)))
	if r != "":
		parts.append(r)
	var e := eta(int(p.get("eta", -1)))
	if e != "":
		parts.append(e)
	return " · ".join(parts)


## 0..1 or -1 when unknown.
static func fraction(p: Dictionary) -> float:
	if p.has("percent") and p["percent"] != null and float(p["percent"]) >= 0.0:
		return clampf(float(p["percent"]) / 100.0, 0.0, 1.0)
	var total := int(p.get("bytes_total", 0))
	if total > 0:
		return clampf(float(p.get("bytes_done", 0)) / total, 0.0, 1.0)
	return -1.0


## "Couldn't install Hollow Tide".
static func failed(action: String, title: String) -> String:
	return FAILED % [ACTION_NAME.get(action, action), title if title != "" else "this game"]


## Toast for Power.autotune_limit(cant_reach, info): raise the TDP when the
## ceiling is under the device's max, else lower the game's settings.
## Returns [title, detail] or [] when there's nothing to say.
static func autotune_message(cant_reach: bool, info: Dictionary) -> Array:
	if not cant_reach:
		return []
	var fps := int(round(float(info.get("target_fps", 0))))
	var ceiling := float(info.get("ceiling_w", -1))
	var tdp_max := float(info.get("tdp_max", -1))
	if ceiling > 0.0 and tdp_max > 0.0 and ceiling < tdp_max - 0.5:
		return [AUTOTUNE_RAISE % [fps, int(round(ceiling))], AUTOTUNE_RAISE_SUB]
	return [AUTOTUNE_LOWER % fps, AUTOTUNE_LOWER_SUB]


## The line under a disabled action: the service's own reason, or a fallback.
static func why(caps: Dictionary, cap: String) -> String:
	var w: Variant = caps.get("why", {}).get(cap, "")
	return str(w) if str(w) != "" else "Not available for this game"


## Store-bound reasons that only say "it's in the other state" are hidden, not explained.
static func is_state_reason(reason: String) -> bool:
	return reason in ["Not installed", "Already installed", "Nothing running for this game"]


## "just now", "4 min ago", "2 h ago", "yesterday".
static func ago(ts: int, now: int) -> String:
	if ts <= 0:
		return ""
	var s := maxi(0, now - ts)
	if s < 60:
		return "just now"
	if s < 3600:
		return "%d min ago" % (s / 60)
	if s < 86400:
		return "%d h ago" % (s / 3600)
	return "yesterday" if s < 172800 else "%d days ago" % (s / 86400)
