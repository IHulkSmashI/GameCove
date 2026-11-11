extends RefCounted
## Words for the Fixes page and the Fixes service (app/data/fixes.json holds each
## fix's own title and one-line explanation).

const PAGE_TITLE := "Fixes"
const PAGE_LINE := "Fixes for things that don't work out of the box on your %s. GameCove applied the ones marked Applied by GameCove when it was installed; every fix can be undone."
const NO_FIXES_TITLE := "Nothing to fix"
const NO_FIXES_LINE := "We don't know of anything on this handheld that needs fixing."
const GENERIC_LINE := "GameCove doesn't know this handheld yet, so it offers no device fixes."

## Page status (Fixes.status_of) -> chip text and tone.
const STATUS := {
	"applied": ["Applied", "good"],
	"restart": ["Restart to finish", "warn"],
	"partial": ["Partly working", "warn"],
	"needed": ["Needed", "warn"],
	"available": ["Available", ""],
	"not-needed": ["Not needed", ""],
	"os-fixed": ["Already fixed by the system", "good"],
	"retired": ["Not needed any more", "good"],
	"advice": ["Advice", "warn"],
	"blocked": ["Something else is in the way", "bad"],
	"checking": ["Checking…", ""],
	"working": ["Working…", ""],
	"unknown": ["Couldn't check", "bad"],
}
## A short note under the line, by status.
const STATUS_NOTES := {
	"not-needed": "This handheld doesn't have the part this fix is for.",
	"os-fixed": "Your system already does this, so GameCove's copy isn't needed.",
	"blocked": "Another setting or file already changed this. Remove that first to use GameCove's fix.",
	"unknown": "The fix helper didn't answer. Is GameCove fully installed?",
	"partial": "Only part of it is in place. Undo, then Apply again.",
}
const AUTO_APPLIED := "Applied by GameCove"
const AUTO_NOT_YET := "Easy setup turns this one on; it isn't on here yet"
const OPTIONAL := "Optional"
const RESTART := {
	"restart": "Takes effect after a restart.",
	"cold-boot": "Takes effect after a full shutdown and power on.",
	"session": "Takes effect next time Gaming Mode starts.",
}
const NEEDS_DESKTOP_NOTE := "Apply and Undo ask for your admin password: use Desktop Mode."
const APPLY := "Apply"
const UNDO := "Undo"
const CHECK := "Check again"
const SOURCES := "Sources"

const SUMMARY_TITLE := "On this handheld"
const SUMMARY_APPLIED := "%d applied by GameCove"
const SUMMARY_AVAILABLE := "%d you can turn on"
const SUMMARY_OS := "%d already fixed by the system"
const SUMMARY_NOT_NEEDED := "%d not needed here"

const CHANGES_TITLE := "What changed"
const CHANGES_FIRST := "First check on this system: every fix was checked."
const CHANGES_NONE := "Nothing changed since the last start."
const CHANGES_LINE := "%s: %s → %s"
const CHANGES_RECHECKED := "Every fix was checked again after the update."
const CHANGES_NOW_OS := "%s is now fixed by the system itself; you can undo GameCove's copy."
const CHANGE_LABELS := {"kernel": "Kernel", "os": "System", "quirks": "Gamescope session", "inputplumber": "Controller service",
	"bios": "BIOS", "ec": "Controller firmware (EC)"}

## Badges on every fix (the owner's words: exactly these two).
const LEVEL := {"recommended": "Recommended", "optional": "Optional", "advice": "Advice"}
const TESTED_BADGE := "Tested on hardware"
const GROUP_TITLES := {"applied": "Applied", "recommended": "Recommended for your %s", "optional": "Optional",
	"retired": "Not needed any more"}
const GROUP_LINES := {
	"applied": "In place on this handheld. Each can be undone.",
	"recommended": "Fixes for things that break everyday use on this model. Proven, safe and undone in one press.",
	"optional": "Not needed by everyone, or not proven enough to switch on for you.",
	"retired": "Your system does these itself now, so GameCove leaves them out.",
}
const DETAILS := "Details"
const HIDE_DETAILS := "Hide details"
const CHANGES_HEAD := "What it changes"
const UNDO_HEAD := "How it's undone"
const WHY_HEAD := "Why your %s"
const RISK_HEAD := "Risk"
const RISK := {"low": "Low", "medium": "Medium", "high": "High"}
const TESTED_HEAD := "Tested on hardware"
const TESTED_NONE := "Not yet. It comes from the sources below."
const AUDITED := "Last checked against its sources: %s"
const SOURCES_QR := "Scan for the source"
const REMOVE_NOW := "Remove now"
const UPDATE_NOW := "Update now"
const KEEP := "Keep it anyway"
const KEPT_NOTE := "You chose to keep this one, so GameCove won't remove it by itself."
const NEWER_NOTE := "A newer version of this fix comes with the next GameCove update."
const RETIRED_NATIVE := "Your system does this itself now."
const RETIRED_WITHDRAWN := "We withdrew this fix: %s"
const PENDING_RETIRE := "Your system does this itself now. GameCove removes its workaround next time it runs in Desktop Mode, or press Remove now there."
const PENDING_WITHDRAWN := "We withdrew this fix (%s). GameCove removes it next time it runs in Desktop Mode, or press Remove now there."
const PENDING_UPDATE := "A newer version of this fix is ready. GameCove updates it next time it runs in Desktop Mode, or press Update now there."
const HISTORY_TITLE := "History"
const HISTORY_EMPTY := "GameCove hasn't changed any fix by itself."
const HISTORY := {
	"removed": "Removed %s: your system does it itself now.",
	"removed-withdrawn": "Removed %s: we withdrew the fix.",
	"updated": "Updated %s to the newest version.",
	"update-failed": "Couldn't update %s; the old version was put back.",
	"update-removed": "Couldn't update %s; it was taken out cleanly.",
	"remove-failed": "Couldn't remove %s.",
	"kept": "You kept %s.",
}
const HISTORY_UNDONE := " (you kept it)"
const SUMMARY_RECOMMENDED := "%d recommended"
const SUMMARY_OPTIONAL := "%d optional"
const SUMMARY_RETIRED := "%d your system does itself now"
const SUMMARY_HIDDEN := "%d not needed on this unit"
## Under the counts when nothing recommended is left to apply and nothing is in the system's way.
const SUMMARY_NOTHING_LEFT := "Nothing left to fix on your %s."
const SUMMARY_HARMFUL := "%d in your system's way: remove in Desktop Mode"
const DATA_LINES := {
	"verified": "Fix list checked today: signed by GameCove.",
	"bad": "Today's fix list didn't pass its signature check, so it wasn't used.",
	"schema": "Today's fix list is for a newer GameCove, so the built-in one is used.",
	"older": "The fix list offered was older than the one here, so it wasn't used.",
	"no-cosign": "No signature checker here, so GameCove uses its built-in fix list.",
	"offline": "Couldn't fetch today's fix list; using the one already here.",
}
const NATIVE_REMOVED := "Your system now takes care of \"%s\" itself, so GameCove removed its workaround."
const WITHDRAWN_REMOVED := "GameCove removed its \"%s\" workaround: %s"
const UPDATED := "GameCove updated its \"%s\" fix to the newest version."
const UPDATE_FAILED := "GameCove couldn't update its \"%s\" fix, so it put the old version back. Nothing changed."
const UPDATE_REMOVED := "GameCove couldn't update its \"%s\" fix and took it out cleanly. Apply it again in Settings > Device > Fixes."
const REMOVE_FAILED := "Your system now takes care of \"%s\" itself, but GameCove couldn't remove its workaround%s. Try Undo in Settings > Device > Fixes."
const WAITING_NATIVE := "Your system now takes care of \"%s\" itself. GameCove removes its workaround next time it runs in Desktop Mode (that needs your admin password)."
const WAITING_WITHDRAWN := "We withdrew the \"%s\" fix: %s GameCove removes it next time it runs in Desktop Mode (that needs your admin password)."
const WAITING_UPDATE := "A newer version of the \"%s\" fix is ready. GameCove updates it next time it runs in Desktop Mode (that needs your admin password)."

## Shown over the home screen at start while a fix that does harm waits to come out
## (fix_attention_dialog.gd; fixes.gd attention()).
const ATTN_TITLE_ONE := "Our %s fix is in your system's way"
const ATTN_TITLE_MANY := "%d of our fixes are in your system's way"
const ATTN_NATIVE := "%s: your system fixes this itself now, and our copy clashes with it."
const ATTN_WITHDRAWN := "%s: we withdrew this fix. %s"
const ATTN_GAMING := "Taking ours out needs your admin password, and Gaming Mode can't ask for it. Switch to Desktop Mode (Quick menu > Switch to Desktop Mode) and open GameCove there: it takes them out by itself."
const ATTN_DESKTOP := "Taking ours out needs your admin password. Remove now asks for it."
const ATTN_AGAIN := "Until then we'll show this each time GameCove starts. Keep it anyway is on the Fixes page."
const ATTN_OPEN := "Open Fixes"
const ATTN_LATER := "Later"
## The status chip of such a fix on the page.
const HARMFUL_CHIP := "In your system's way"
const HARMFUL_NOTE := "Your system fixes this itself now, and our copy clashes with it. GameCove takes ours out next time it runs in Desktop Mode, or press Remove now there."


static func attention_title(items: Array) -> String:
	if items.size() == 1:
		return ATTN_TITLE_ONE % str(items[0].get("title", ""))
	return ATTN_TITLE_MANY % items.size()


static func attention_line(it: Dictionary) -> String:
	if str(it.get("reason", "")) == "withdrawn":
		return ATTN_WITHDRAWN % [str(it.get("title", "")), str(it.get("withdrawn", ""))]
	return ATTN_NATIVE % str(it.get("title", ""))


## The one line said when GameCove removed a fix by itself.
static func removed(title: String, reason: String, withdrawn_reason := "") -> String:
	return WITHDRAWN_REMOVED % [title, withdrawn_reason] if reason == "withdrawn" else NATIVE_REMOVED % title


## The one line said when a change has to wait for Desktop Mode.
static func waiting(title: String, action: String, reason: String, withdrawn_reason := "") -> String:
	if action == "update":
		return WAITING_UPDATE % title
	return WAITING_WITHDRAWN % [title, withdrawn_reason] if reason == "withdrawn" else WAITING_NATIVE % title


static func history_line(e: Dictionary) -> String:
	var key := str(e.get("action", ""))
	if key == "removed" and str(e.get("reason", "")) == "withdrawn":
		key = "removed-withdrawn"
	var line: String = str(HISTORY.get(key, "%s")) % str(e.get("title", e.get("fix", "")))
	return line + (HISTORY_UNDONE if bool(e.get("undone", false)) else "")


const DONE_APPLY := "%s applied."
const DONE_UNDO := "%s undone."
const FAILED := "Couldn't %s %s%s."
const NO_PASSWORD := "No admin password given, so nothing changed."
const NEEDS_DESKTOP := "Nothing changed: this one needs your admin password, and Gaming Mode can't ask for it. Use Desktop Mode."


static func status_text(status: String) -> String:
	return STATUS.get(status, [status.capitalize(), ""])[0]


static func status_tone(status: String) -> String:
	return STATUS.get(status, ["", ""])[1]


static func result(title: String, verb: String, ok: bool, code: int, detail := "", restart := "") -> String:
	if ok:
		var t: String = (DONE_APPLY if verb == "apply" else DONE_UNDO) % title
		if verb == "apply" and RESTART.has(restart):
			t += " " + RESTART[restart]
		return t
	if code == 126 or code == 127:
		return NEEDS_DESKTOP
	return FAILED % [verb, title.to_lower(), ": " + detail if detail != "" else ""]
