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
const AUTO_NOT_YET := "GameCove applies this one at install"
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
const CHANGE_LABELS := {"kernel": "Kernel", "os": "System", "quirks": "Gamescope session", "inputplumber": "Controller service"}

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
