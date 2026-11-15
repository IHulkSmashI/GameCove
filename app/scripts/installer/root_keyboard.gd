extends RefCounted
## The admin password prompt (pkexec's polkit dialog) is a window of the desktop, not of GameCove, so
## GameCove's own on-screen keyboard (and Steam's, which can't type into a KDE Wayland dialog) can't fill
## it in. On a handheld there is no physical keyboard: KDE Plasma has its own virtual keyboard, an input
## method of KWin (Plasma 6.4+: plasma-keyboard; older: maliit). While the password dialog is open it is
## switched on for the session (kwinrc [Wayland] InputMethod) and put back as it was afterwards, so the
## dialog's password field can raise it. Best effort: nothing here ever blocks or fails the install.
##
## Only the installer calls this (installer_service.gd, around the one root batch). Plain commands through
## the runner (kreadconfig6 / kwriteconfig6 and KWin's reconfigure over D-Bus), nothing of ours stays
## running.

const DESKTOP_FILES := ["/usr/share/applications/org.kde.plasma.keyboard.desktop", "/usr/share/applications/com.github.maliit.keyboard.desktop"]
const FILE := "kwinrc"
const GROUP := "Wayland"
const KEY := "InputMethod"


## KDE Plasma on Wayland, the only place this applies (X11 sessions type with xvkbd-style tools; GNOME has its own).
static func applies(desktop: String, session_type: String) -> bool:
	return desktop.to_upper().contains("KDE") and session_type.to_lower() == "wayland"


## The keyboard's .desktop file this system has ("" = none).
static func keyboard_file(root := "") -> String:
	for f in DESKTOP_FILES:
		if FileAccess.file_exists(root + f):
			return f
	return ""


## Switches the virtual keyboard on. Returns {"on": bool, "changed": bool, "was": String, "file": String}.
static func prepare(runner: RefCounted, desktop: String, session_type: String, root := "") -> Dictionary:
	var st := {"on": false, "changed": false, "was": "", "file": ""}
	if not applies(desktop, session_type):
		return st
	var f := keyboard_file(root)
	if f == "":
		return st
	st["file"] = f
	var cur: Dictionary = runner.run("kreadconfig6", PackedStringArray(["--file", FILE, "--group", GROUP, "--key", KEY]))
	var was := str(cur.get("out", "")).strip_edges() if int(cur.get("code", 1)) == 0 else ""
	st["was"] = was
	if was == f:
		st["on"] = true
		return st
	var w: Dictionary = runner.run("kwriteconfig6", PackedStringArray(["--file", FILE, "--group", GROUP, "--key", KEY, f]))
	if int(w.get("code", 1)) != 0:
		return st
	_reconfigure(runner)
	st["on"] = true
	st["changed"] = true
	return st


## Puts the setting back as `prepare` found it.
static func restore(runner: RefCounted, st: Dictionary) -> void:
	if not bool(st.get("changed", false)):
		return
	var was := str(st.get("was", ""))
	if was == "":
		runner.run("kwriteconfig6", PackedStringArray(["--file", FILE, "--group", GROUP, "--key", KEY, "--delete"]))
	else:
		runner.run("kwriteconfig6", PackedStringArray(["--file", FILE, "--group", GROUP, "--key", KEY, was]))
	_reconfigure(runner)


static func _reconfigure(runner: RefCounted) -> void:
	var r: Dictionary = runner.run("qdbus6", PackedStringArray(["org.kde.KWin", "/KWin", "reconfigure"]))
	if int(r.get("code", 1)) != 0:
		runner.run("dbus-send", PackedStringArray(["--session", "--dest=org.kde.KWin", "/KWin", "org.kde.KWin.reconfigure"]))
