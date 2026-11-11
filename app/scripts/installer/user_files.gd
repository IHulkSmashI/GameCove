extends RefCounted
## The files the installer puts in the user's home, and takes away again. All
## of them are plain text, each says it was written by the installer, and each
## is removed by uninstall (remove_all).
##
##   ~/.config/environment.d/gamecove.conf         GAMECOVE_STEAM_MODE for the session
##   ~/.config/systemd/user/gamecove-apply-choices.service (+ default.target.wants link)
##   ~/.local/share/gamecove/pending-choices        what to do once the package is live
##   ~/.local/share/applications/…GameCoveSwitch    "GameCove" (switch to its session)
##   ~/.local/share/applications/…GameCoveWindow    "GameCove (window)" (try it on the desktop)
##   ~/.local/share/applications/…GameCoveInstaller "GameCove Installer" (if get-gamecove.sh didn't)
##   ~/.config/autostart/…GameCoveFinish            opens the installer once in Desktop Mode
##                                                  while fixes still wait for a password
## and one the app writes, which uninstall must also take away because every gamescope session
## reads it, Steam Gaming Mode included (a rotation or a refresh-rate unlock would stay with no
## GameCove left to turn it off):
##   ~/.config/environment.d/80-gamecove-display.conf   Display settings read at session start.
##       Uninstall moves it to ~/.local/share/gamecove/display-session.conf; the next install
##       puts it back, "Keep my settings" off deletes it.

const HEADER := "# Written by the GameCove installer. Remove GameCove from \"GameCove Installer\" to undo.\n"
const UNIT := """[Unit]
Description=GameCove: apply the installer's choices once GameCove is installed
# Quiet until the package is live (after the reboot) and while nothing waits.
ConditionPathExists=/usr/libexec/gamecove/gamecove-apply-choices
ConditionPathExists=%h/.local/share/gamecove/pending-choices
After=graphical-session.target

[Service]
Type=oneshot
ExecStart=/usr/libexec/gamecove/gamecove-apply-choices

[Install]
WantedBy=default.target
"""


static func _write(path: String, text: String) -> bool:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(text)
	f.close()
	return true


static func _remove(path: String) -> void:
	if FileAccess.file_exists(path) or DirAccess.dir_exists_absolute(path):
		DirAccess.remove_absolute(path)
	elif _is_link(path):
		DirAccess.remove_absolute(path)


static func _is_link(path: String) -> bool:
	var d := DirAccess.open(path.get_base_dir())
	return d != null and d.is_link(path.get_file())


static func env_text(steam_mode: String) -> String:
	return HEADER + "GAMECOVE_STEAM_MODE=%s\n" % steam_mode


static func entry_text(name: String, comment: String, exec: String, try_exec := "") -> String:
	var t := "[Desktop Entry]\nType=Application\nName=%s\nComment=%s\nExec=%s\n" % [name, comment, exec]
	if try_exec != "":
		t += "TryExec=%s\n" % try_exec
	return t + "Icon=applications-games\nTerminal=false\nCategories=Game;\nX-GameCove-Installer=true\n"


static func _quote(p: String) -> String:
	return "\"" + p.replace("\\", "\\\\").replace("\"", "\\\"") + "\""


## Installer command for desktop entries: the installed app once it's live,
## else this installer's own copy.
static func installer_exec(paths: RefCounted, exe: String) -> String:
	var bin: String = paths.installed_binary() if FileAccess.file_exists(paths.installed_binary()) else exe
	return _quote(bin) + " -- --installer"


## Everything but the pending file. Returns the paths written.
static func write_all(paths: RefCounted, choices: Dictionary, exe: String) -> Array:
	var wrote: Array = []
	if _write(paths.env_conf(), env_text(str(choices.get("steam_mode", "silent")))):
		wrote.append(paths.env_conf())
	if _write(paths.unit_file(), HEADER + UNIT):
		wrote.append(paths.unit_file())
	DirAccess.make_dir_recursive_absolute(paths.unit_link().get_base_dir())
	if not FileAccess.file_exists(paths.unit_link()) and not _is_link(paths.unit_link()):
		var wants := DirAccess.open(paths.unit_link().get_base_dir())
		if wants != null:
			wants.create_link(paths.unit_file(), paths.unit_link())
	wrote.append(paths.unit_link())
	var startup := str(choices.get("startup", "gamecove"))
	if startup in ["gamecove", "steam"]:
		_write(paths.switch_entry(), entry_text("GameCove", "Leave the desktop and start GameCove",
			"/usr/bin/gamecove-session-select gamecove", "/usr/bin/gamecove-session-select"))
		wrote.append(paths.switch_entry())
	else:
		_remove(paths.switch_entry())
	_write(paths.window_entry(), entry_text("GameCove (window)", "Try GameCove in a window on the desktop",
		"/usr/lib/gamecove/gamecove.x86_64 --windowed", "/usr/lib/gamecove/gamecove.x86_64"))
	wrote.append(paths.window_entry())
	if not FileAccess.file_exists(paths.installer_entry()):
		_write(paths.installer_entry(), entry_text("GameCove Installer", "Change, repair or remove GameCove",
			installer_exec(paths, exe)))
		wrote.append(paths.installer_entry())
	# Installed now: the "Install GameCove" desktop shortcut has done its job.
	_remove(paths.desktop_shortcut())
	# Display settings an earlier uninstall kept ("Keep my settings"): back in place, unless
	# there are newer ones already
	if FileAccess.file_exists(paths.display_env_kept()):
		if not FileAccess.file_exists(paths.display_env_conf()):
			DirAccess.make_dir_recursive_absolute(paths.display_env_conf().get_base_dir())
			if DirAccess.copy_absolute(paths.display_env_kept(), paths.display_env_conf()) == OK:
				wrote.append(paths.display_env_conf())
		_remove(paths.display_env_kept())
	return wrote


## The pending file (KEY=value) and, while fixes wait, the autostart entry.
static func write_pending(paths: RefCounted, pending: Dictionary, exe: String) -> bool:
	if pending.is_empty():
		_remove(paths.pending_file())
		_remove(paths.autostart_entry())
		return true
	var lines := PackedStringArray()
	for k in pending:
		lines.append("%s=%s" % [k, pending[k]])
	var ok := _write(paths.pending_file(), "\n".join(lines) + "\n")
	if str(pending.get("FIXES", "")) != "":
		_write(paths.autostart_entry(), entry_text("Finish installing GameCove",
			"Install the device fixes GameCove left for Desktop Mode", installer_exec(paths, exe)))
	else:
		_remove(paths.autostart_entry())
	return ok


static func remove_pending(paths: RefCounted) -> void:
	_remove(paths.pending_file())
	_remove(paths.autostart_entry())


## Uninstall: every file above (the installer's own app entry and download stay
## so it can be run again; remove_settings takes those too).
static func remove_all(paths: RefCounted) -> Array:
	var gone: Array = []
	var data: String = paths.data_dir()
	# review L25: the session's own leftovers too (crash guard, desktop bounce, guard marks)
	for p in [paths.env_conf(), paths.unit_link(), paths.unit_file(), paths.switch_entry(), paths.window_entry(),
			paths.pending_file(), paths.autostart_entry(), paths.desktop_shortcut(),
			data + "/crash-count", data + "/crash-fallback", data + "/crash-starts", data + "/left-for-steam",
			data + "/default-suspended"]:
		if FileAccess.file_exists(p) or _is_link(p):
			_remove(p)
			gone.append(p)
	# the app's display settings for the session: out of every gamescope session's way, a copy
	# kept for a later install (remove_settings_files deletes the copy)
	if FileAccess.file_exists(paths.display_env_conf()) or _is_link(paths.display_env_conf()):
		DirAccess.make_dir_recursive_absolute(data)
		if not _is_link(paths.display_env_conf()):
			DirAccess.copy_absolute(paths.display_env_conf(), paths.display_env_kept())
		_remove(paths.display_env_conf())
		gone.append(paths.display_env_conf())
	# the bootstrap's cosign download (a cache: it comes back if the installer runs again)
	if DirAccess.dir_exists_absolute(data + "/tools") and remove_tree(data + "/tools", data):
		gone.append(data + "/tools")
	return gone


## Uninstall without keeping settings: also the installer's app entry (its script goes with the
## download) and the per-game launch files.
static func remove_settings_files(paths: RefCounted) -> Array:
	var gone: Array = []
	var data: String = paths.data_dir()
	if FileAccess.file_exists(paths.installer_entry()) or _is_link(paths.installer_entry()):
		_remove(paths.installer_entry())
		gone.append(paths.installer_entry())
	if DirAccess.dir_exists_absolute(data + "/launch") and remove_tree(data + "/launch", data):
		gone.append(data + "/launch")
	if FileAccess.file_exists(paths.display_env_kept()):
		_remove(paths.display_env_kept())
		gone.append(paths.display_env_kept())
	return gone


## Deletes a folder tree (only below `under`, as a guard against bad paths).
static func remove_tree(path: String, under: String) -> bool:
	if under.length() < 2 or not path.begins_with(under + "/") or ".." in path:
		return false
	# a path that is itself a link (a folder kept on another drive and linked in) is removed as a link: its
	# files are not ours to delete (the same rule as proton_ge.gd, 21febb7)
	var parent := DirAccess.open(path.get_base_dir())
	if parent != null and parent.is_link(path.get_file()):
		return DirAccess.remove_absolute(path) == OK
	var d := DirAccess.open(path)
	if d == null:
		return false
	d.include_hidden = true
	for sub in d.get_directories():
		if d.is_link(sub):
			DirAccess.remove_absolute(path + "/" + sub)
		else:
			remove_tree(path + "/" + sub, under)
	for f in d.get_files():
		DirAccess.remove_absolute(path + "/" + f)
	return DirAccess.remove_absolute(path) == OK
