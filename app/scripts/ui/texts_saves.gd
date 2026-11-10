extends RefCounted
## Words for cloud saves (game page card, conflict choice, backups, Settings > Saves),
## battery history and drain (game page, About this device) and Sleep at low battery.

const TG := preload("res://scripts/ui/texts_games.gd")

# ---- cloud saves -------------------------------------------------------------------------------

const CARD := "Cloud saves"
const STORE_NAMES := {"epic": "Epic", "gog": "GOG"}
const SYNC_TOGGLE := "Sync this game's saves"
const SYNC_TOGGLE_HELP := "%s cloud, before and after play"
const SYNC_NOW := "Sync now"
const SYNCING := "Syncing saves…"
const SYNC_LAUNCH := "Getting your cloud save…"
const CHOOSE := "Choose which save to keep"
const BACKUPS := "Restore a backup"
const NO_BACKUPS := "None yet"
const HINT_ON := "Turn on"
const HINT_OFF := "Turn off"
const HINT_CHOOSE := "Choose"
const HINT_RESTORE := "Pick one"
const DISABLED_LINE := "Cloud saves are off for every game (Settings > Saves)."
const OFF_LINE := "Not syncing this game: its saves stay on this handheld."

## state -> line. %s = how long ago (TG.ago) where the line has one.
const STATE := {
	"never": "Not synced yet: we'll sync when you next play.",
	"synced": "Saves synced %s",
	"uploaded": "Saves uploaded %s",
	"downloaded": "Cloud save downloaded %s",
	"restored": "Backup restored %s",
	"no_saves": "No saves yet, here or in the cloud (checked %s)",
	"pending_up": "This handheld has a newer save: it goes up after you play.",
	"pending_down": "The cloud has a newer save: it comes down before you play.",
	"conflict": "Both this handheld and the cloud have newer saves.",
	"offline": "Couldn't reach the store %s, so saves weren't synced. We'll try again next time.",
	"failed": "Sync didn't finish %s. Your saves are safe on this handheld.",
	"backup_failed": "We couldn't back your saves up, so we didn't download anything.",
	"too_big": "This game's save folder is too big to back up, so we only send saves up, never down.",
	"not_set_up": "We'll sync after you play once (the game's folders don't exist yet).",
	"unsupported": "This game has no cloud saves.",
	"signed_out": "Sign in to the store (Settings > Stores) to sync saves.",
	"no_tool": "Needs legendary or Heroic to sync saves.",
	"linux": "The store's cloud saves only cover the Windows version of this game.",
	"off": OFF_LINE,
	"disabled": DISABLED_LINE,
}
## state -> tone for the status line.
const TONE := {"synced": "good", "uploaded": "good", "downloaded": "good", "restored": "good", "conflict": "warn",
	"offline": "warn", "failed": "bad", "backup_failed": "bad", "too_big": "warn", "pending_up": "", "pending_down": ""}

const CONFLICT_TITLE := "Which save do we keep?"
const CONFLICT_LINE := "%s changed here and in the cloud since the last sync. The other one is backed up on this handheld first, so nothing is lost."
const KEEP_LOCAL := "Keep this handheld's save"
const KEEP_CLOUD := "Keep the cloud save"
const DECIDE_LATER := "Decide later"
const DECIDE_LATER_DETAIL := "Play without syncing this time"
const NEWER := "Newer"
const RESTORED_BADGE := "Restored"
const RESTORED_DETAIL := "The backup you just restored"
const SAVED_AT := "Saved %s"
const UNKNOWN_TIME := "Time unknown"
const KEPT_LOCAL := "Kept this handheld's save."
const KEPT_CLOUD := "Kept the cloud save."

const BACKUPS_TITLE := "Restore a backup"
const BACKUPS_LINE := "Your saves right now are backed up first, so you can always come back."
const REASONS := {"before_download": "Before a cloud download", "before_upload": "Before keeping this handheld's save",
	"cloud_copy": "The cloud's save, before it was replaced", "before_restore": "Before a restore"}
const RESTORED := "Backup restored."
const RESTORE_FAILED := "Couldn't restore that backup: %s"
const RESTORE_RUNNING := "Close the game first."
const RESOLVE_RUNNING := "Close the game first, then choose. We never swap saves under a running game."

const SYNC_FAILED_TOAST := "%s: saves didn't sync. They're safe on this handheld."
const CONFLICT_TOAST := "%s: saves changed here and in the cloud. Open the game to choose."
const UPLOADED_TOAST := "%s: saves uploaded."

# ---- Settings > Saves --------------------------------------------------------------------------

const PAGE_LINE := "Epic and GOG cloud saves, synced just before a game starts and just after it ends."
const SWITCH := "Sync cloud saves"
const SWITCH_HELP := {true: "On: Epic games sync through legendary, GOG games through Heroic's gogdl, with your store sign-in. Never while you play.",
	false: "Off: nothing is synced and saves stay on this handheld."}
const HOW_TITLE := "How it works"
const HOW_LINES := [
	"Before a game starts we get the newest save from the store's cloud; after it ends we send yours up.",
	"Before anything replaces a save on this handheld, we back it up here. We keep the last 10 per game, plus the last 10 from a choice or a restore.",
	"When both sides changed, you choose. The newest one is highlighted.",
	"No connection? The game starts anyway and we sync next time.",
]
const AMAZON_NOTE := "Amazon games aren't covered: nile, Amazon's tool, has no save sync."
const GAMES_TITLE := "Your games"
const NO_GAMES := "No installed Epic or GOG games yet."
const BACKUP_COUNT := {0: "no backups", 1: "1 backup"}
const BACKUPS_N := "%d backups"


static func backup_count(n: int) -> String:
	return str(BACKUP_COUNT[n]) if BACKUP_COUNT.has(n) else BACKUPS_N % n


## The status line for a saves status (saves_service.gd status()).
static func status_line(st: Dictionary, now: int) -> String:
	if str(st.get("busy", "")) != "":
		return SYNCING
	var state := str(st.get("state", "never"))
	var line := str(STATE.get(state, STATE["never"]))
	if line.contains("%s"):
		var when := TG.ago(int(st.get("at", 0)), now)
		line = line % (when if when != "" else "")
	return line.replace("  ", " ").strip_edges()


static func tone(st: Dictionary) -> String:
	return "" if str(st.get("busy", "")) != "" else str(TONE.get(str(st.get("state", "")), ""))


## "Saved 2 h ago" for a side of a conflict.
static func saved_at(ts: int, now: int) -> String:
	return SAVED_AT % TG.ago(ts, now) if ts > 0 else UNKNOWN_TIME


# ---- battery -----------------------------------------------------------------------------------

const DRAIN := "Drains about %s W, ~%s h on a full charge"
const DRAIN_NO_FULL := "Drains about %s W on battery"
const HISTORY_CARD := "Battery history"
const HISTORY_LINE := "The last 7 days, from game starts and ends, sleep and the charger. Nothing runs in between."
const HISTORY_EMPTY := "Nothing yet: play a game on battery and it shows up here."
const DRAIN_TITLE := "Drain per game"
const DRAIN_EMPTY := "A game shows up after about 20 minutes on battery."
const DRAIN_HEAD := ["Game", "Drain", "Full charge"]
const CHART_DAYS := 7
const CHARGING := "Charging"


static func watts(w: float) -> String:
	return ("%.0f" % w) if w >= 10.0 else ("%.1f" % w)


static func hours(h: float) -> String:
	return ("%.0f" % h) if h >= 10.0 else ("%.1f" % h)


static func drain_line(d: Dictionary) -> String:
	if d.is_empty():
		return ""
	if float(d.get("hours", -1.0)) > 0.0:
		return DRAIN % [watts(float(d["watts"])), hours(float(d["hours"]))]
	return DRAIN_NO_FULL % watts(float(d["watts"]))


# ---- Sleep at low battery ----------------------------------------------------------------------

const LOW_TITLE := "Battery at %d %%"
const LOW_LINE := "Going to sleep to save your game. Press any button to stay awake."
const LOW_COUNT := "Sleeping in %d s"
const LOW_STAY := "Stay awake"
const LOW_SECONDS := 30
