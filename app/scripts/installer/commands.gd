extends RefCounted
## Every command the installer runs, built here and nowhere else, so tests can
## check them without running anything. Tasks are plain dictionaries the
## InstallerService carries out in order:
##
##   {"id", "kind": "cmd"|"internal", "cmd": [program, args...], "privileged": bool,
##    "undo": [cmd] or [] (kind cmd) / internal undo id, "fallback": [cmd] (tried when cmd fails),
##    "needs_live": bool (only once GameCove is in /usr; otherwise left pending),
##    "optional": bool (a failure doesn't stop the run), "fix": name}
##
## Privileged commands always go through pkexec, so the desktop's polkit agent
## asks for the admin password with its own dialog. Nothing else needs root.

const RPM_OSTREE := "rpm-ostree"
const PKEXEC := "pkexec"
const STEAMOSCTL := "steamosctl"
const SYSEXT_PATH := "/var/lib/extensions/gamecove.raw"
## SteamOS: /var is writable even with the read-only /usr (steamos-readonly
## stays on), so a sysext needs no unlock. systemd-sysext.service merges it at
## every boot; refresh merges it now. polkit re-reads our policy on reload.
const SYSEXT_INSTALL := "set -e; mkdir -p /var/lib/extensions; install -m 0644 \"$1\" " + SYSEXT_PATH \
	+ "; systemctl enable systemd-sysext.service >/dev/null 2>&1 || true; systemd-sysext refresh; systemctl reload polkit >/dev/null 2>&1 || true"
const SYSEXT_REMOVE := "set -e; rm -f " + SYSEXT_PATH + "; systemd-sysext refresh; systemctl reload polkit >/dev/null 2>&1 || true"
## A Steam game (Steam's launch wrapper) or one of ours (app-steam-app<id> scope) is running.
const GAME_PATTERN := "SteamLaunch AppId=|app-steam-app[0-9]"


static func pkexec(cmd: Array) -> Array:
	return [PKEXEC] + cmd


## Bazzite / Fedora Atomic: layer the package. --apply-live makes it usable
## right away (fixes, session) and keeps it for the next boot; when that
## isn't possible the fallback just stages it for the next boot.
static func rpm_install(rpm: String, live := true) -> Array:
	var c := [RPM_OSTREE, "install", "--idempotent"]
	if live:
		c.append("--apply-live")
	c.append(rpm)
	return pkexec(c)


static func rpm_uninstall() -> Array:
	return pkexec([RPM_OSTREE, "uninstall", "gamecove"])


## A newer local RPM in place of the layered one, in one transaction (next boot).
static func rpm_update(rpm: String) -> Array:
	return pkexec([RPM_OSTREE, "uninstall", "gamecove", "--install", rpm])


static func sysext_install(raw: String) -> Array:
	return pkexec(["sh", "-c", SYSEXT_INSTALL, "sh", raw])


static func sysext_remove() -> Array:
	return pkexec(["sh", "-c", SYSEXT_REMOVE])


static func fix(helper: String, fix_name: String, verb: String) -> Array:
	return pkexec([helper, fix_name, verb])


## XeSS XMX driver (xess-xmx-linux), the same install ClawDeck does: downloaded,
## its install.sh run as the desktop user (no pkexec). Intel Arc with XMX only.
static func xess_install(helper: String, home: String) -> Array:
	return [helper, "xess-install", "--home", home, "--gpu", "vendor=intel,xmx=1"]


static func xess_remove(helper: String, home: String) -> Array:
	return [helper, "xess-remove", "--home", home]


## Default session without switching now (needs the package live).
static func session_default(select: String, startup: String) -> Array:
	if startup == "gamecove":
		return [select, "gamecove", "--default", "--no-switch"]
	return [select, "steam", "--default", "--no-switch"]


## Undo "Boot into GameCove": the default desktop session (Plasma/GNOME) and the
## boot mode from before GameCove, so Steam's "Switch to Desktop" never names a
## removed gamecove.desktop. Works with or without our package: the copy of
## gamecove-session-select that `--default` keeps in the data folder first, then
## the installed one, else steamosctl directly (desktop default back to a real
## desktop session if it names GameCove, boot back to Steam Gaming Mode).
const SESSION_RESTORE_SH := "for s in \"$1\" \"$2\"; do if [ -f \"$s\" ]; then sh \"$s\" restore && exit 0; fi; done; " \
	+ "command -v steamosctl >/dev/null 2>&1 || exit 0; " \
	+ "if [ \"$(steamosctl get-default-desktop-session 2>/dev/null)\" = gamecove.desktop ]; then " \
	+ "for d in plasma.desktop gnome.desktop; do steamosctl set-default-desktop-session \"$d\" 2>/dev/null && break; done; fi; " \
	+ "steamosctl set-default-login-mode game"


static func session_restore(paths: RefCounted = null) -> Array:
	var guard_copy: String = "" if paths == null else paths.data_dir() + "/gamecove-session-guard"
	var select: String = "/usr/bin/gamecove-session-select" if paths == null else paths.session_select()
	return ["sh", "-c", SESSION_RESTORE_SH, "sh", guard_copy, select]


static func game_check() -> Array:
	return ["pgrep", "-f", GAME_PATTERN]


static func reboot() -> Array:
	return ["systemctl", "reboot"]


static func daemon_reload() -> Array:
	return ["systemctl", "--user", "daemon-reload"]


static func _cmd(id: String, cmd: Array, extra := {}) -> Dictionary:
	var t := {"id": id, "kind": "cmd", "cmd": cmd, "privileged": cmd.size() > 0 and cmd[0] == PKEXEC,
		"undo": [], "fallback": [], "needs_live": false, "optional": false, "fix": ""}
	t.merge(extra, true)
	return t


static func _internal(id: String, extra := {}) -> Dictionary:
	var t := {"id": id, "kind": "internal", "cmd": [], "privileged": false, "undo": "", "fallback": [],
		"needs_live": false, "optional": false, "fix": ""}
	t.merge(extra, true)
	return t


static func package_task(method: String, pkg: String, verb := "install") -> Dictionary:
	if method == "rpm-ostree":
		if verb == "update":
			return _cmd("package_update", rpm_update(pkg))
		return _cmd("package", rpm_install(pkg, true), {"undo": rpm_uninstall(), "fallback": rpm_install(pkg, false)})
	return _cmd("package_update" if verb == "update" else "package", sysext_install(pkg), {"undo": sysext_remove()})


static func fix_task(paths: RefCounted, fix_name: String, verb := "install") -> Dictionary:
	var undo_verb := "remove" if verb == "install" else "install"
	return _cmd("fix_" + verb, fix(paths.fix_helper(), fix_name, verb),
		{"undo": fix(paths.fix_helper(), fix_name, undo_verb), "needs_live": true, "fix": fix_name,
		 "optional": verb == "remove"})


## The tasks for `action` (install | change | repair | update | uninstall | finish).
## `choices` from the plan; `target` from Target.detect.
static func tasks_for(action: String, choices: Dictionary, target: Dictionary, paths: RefCounted) -> Array:
	var method := str(target.get("method", "none"))
	var pkg := str(target.get("package", ""))
	var state: Dictionary = target.get("state", {})
	var had_fixes: Array = state.get("fixes", []) if state.get("fixes", []) is Array else []
	var want_fixes: Array = choices.get("fixes", [])
	var present := bool(target.get("installed", false)) or bool(target.get("staged", false))
	var had_xess := bool(state.get("choices", {}).get("xess_driver", false)) if state.get("choices") is Dictionary else false
	var want_xess := bool(choices.get("xess_driver", false))
	var out: Array = [_internal("check_game")]
	match action:
		"install", "change", "repair":
			if method != "none" and pkg != "" and (action != "change" or not present):
				out.append(package_task(method, pkg))
			for f in want_fixes:
				if action == "repair" or not f in had_fixes:
					out.append(fix_task(paths, f, "install"))
			if action == "change":
				for f in had_fixes:
					if not f in want_fixes:
						out.append(fix_task(paths, f, "remove"))
			out.append(_internal("user_files", {"undo": "remove_user_files"}))
			# the helper ships in the package: after a staged install it waits for the reboot
			if want_xess and (action != "change" or not had_xess):
				out.append(_cmd("xess_install", xess_install(paths.upscale_helper(), paths.home),
					{"needs_live": true, "optional": true, "undo": xess_remove(paths.upscale_helper(), paths.home)}))
			elif action == "change" and had_xess and not want_xess:
				out.append(_cmd("xess_remove", xess_remove(paths.upscale_helper(), paths.home), {"needs_live": true, "optional": true}))
			out.append(_internal("pending", {"undo": "remove_pending"}))
			if method != "none":
				out.append(_cmd("apply_now", [paths.apply_helper()], {"needs_live": true, "optional": true}))
			out.append(_internal("state"))
		"update":
			if method != "none" and pkg != "":
				out.append(package_task(method, pkg, "update"))
			out.append(_internal("user_files"))
			out.append(_internal("state"))
		"uninstall":
			out.append(_cmd("session_restore", session_restore(paths), {"optional": true}))
			# GameCove's launcher out of every Steam game's launch options (stops Steam first)
			out.append(_internal("steam_unwrap", {"optional": true}))
			if bool(choices.get("remove_fixes", true)) and bool(target.get("installed", false)):
				for f in had_fixes:
					out.append(fix_task(paths, f, "remove"))
			if had_xess and bool(target.get("installed", false)):
				out.append(_cmd("xess_remove", xess_remove(paths.upscale_helper(), paths.home), {"optional": true}))
			if method == "rpm-ostree":
				out.append(_cmd("package_remove", rpm_uninstall()))
			elif method == "sysext":
				out.append(_cmd("package_remove", sysext_remove()))
			out.append(_internal("remove_user_files"))
			if not bool(choices.get("keep_settings", true)):
				out.append(_internal("remove_settings"))
			out.append(_internal("forget"))
		"finish":
			for f in want_fixes:
				out.append(fix_task(paths, f, "install"))
			out.append(_internal("pending", {"undo": "remove_pending"}))
			out.append(_internal("state"))
	return out
