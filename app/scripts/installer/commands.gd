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
## SteamOS: /usr is read-only, but a sysext needs no unlock (steamos-readonly stays on).
## Three SteamOS details (docs/SESSION.md, "SteamOS"):
##   - /var is a small partition per OS slot and SteamOS 3.6+ keeps only listed /etc
##     changes across an OS update (/etc/atomic-update.conf.d), so the image lives on
##     the big /home partition, root-owned, beside SteamOS's own offload folders
##     (SYSEXT_STORE, as Determinate's Nix installer does with /home/.steamos/offload/nix),
##     and is linked from /etc/extensions (a systemd-sysext search path);
##   - systemd-sysext.service isn't enabled by default: we enable it, and list that link
##     and ours in a keep list so the next OS update keeps both;
##   - polkit reads our policy after a reload (Type=notify-reload polkit; older ones
##     pick it up at the next boot).
## Elsewhere (no /etc/atomic-update.conf.d) the image goes to /var/lib/extensions as before.
const SYSEXT_STORE := "/home/.steamos/offload/gamecove"
const SYSEXT_ETC_LINK := "/etc/extensions/gamecove.raw"
const SYSEXT_KEEP := "/etc/atomic-update.conf.d/gamecove.conf"
const SYSEXT_UNIT_LINK := "/etc/systemd/system/sysinit.target.wants/systemd-sysext.service"
## Review H4: SDDM shows its login screen when the autologin session file is missing (a
## sysext that didn't merge, or on Bazzite a GameCove layer removed by hand with
## `rpm-ostree uninstall gamecove` while it was the boot default: final review, session). This
## root guard, copied out of the image into /etc so it outlives it, points autologin back at
## Steam before the login screen starts. Both installs put it there.
const GUARD_SRC := "/usr/lib/gamecove/session"
const GUARD_SCRIPT := "/etc/gamecove/autologin-guard"
const GUARD_UNIT := "/etc/systemd/system/gamecove-autologin-guard.service"
const GUARD_LINK := "/etc/systemd/system/multi-user.target.wants/gamecove-autologin-guard.service"
## systemd-sysext.service was off before GameCove turned it on (review L25: uninstall turns it
## off again only then, and only when no other extension is left).
const SYSEXT_ENABLED_MARK := "/etc/gamecove/sysext-enabled"
## The root helper's state (fix originals, logs). Removed on uninstall only with the fixes.
const STATE_DIR := "/var/lib/gamecove"
## The guard into /etc, as root, under `set -e`: a copy that fails stops the install (it used
## to end in `|| true`, which hid it; final review, low). On rpm-ostree the package may only be
## staged for the next boot (no --apply-live): then the files are taken from the new
## deployment's own /usr under /ostree/deploy. Only systemd's reload may fail.
const GUARD_INSTALL := "src=" + GUARD_SRC + "; " \
	+ "if [ ! -f \"$src/gamecove-autologin-guard\" ]; then for d in /ostree/deploy/*/deploy/*" + GUARD_SRC + "; do " \
	+ "if [ -f \"$d/gamecove-autologin-guard\" ]; then src=\"$d\"; fi; done; fi; " \
	+ "install -D -m 0755 \"$src/gamecove-autologin-guard\" " + GUARD_SCRIPT + "; " \
	+ "install -D -m 0644 \"$src/gamecove-autologin-guard.service\" " + GUARD_UNIT + "; " \
	+ "mkdir -p /etc/systemd/system/multi-user.target.wants; ln -sfn " + GUARD_UNIT + " " + GUARD_LINK + "; " \
	+ "systemctl daemon-reload >/dev/null 2>&1 || true"
const GUARD_REMOVE := "rm -f " + GUARD_LINK + " " + GUARD_UNIT + " " + GUARD_SCRIPT + "; rmdir /etc/gamecove 2>/dev/null || true"
const SYSEXT_INSTALL := "set -e; " \
	+ "if [ -d /etc/atomic-update.conf.d ] && [ -d /home/.steamos ]; then " \
	+ "mkdir -p -m 0755 " + SYSEXT_STORE + " /etc/extensions; " \
	+ "install -m 0644 \"$1\" " + SYSEXT_STORE + "/gamecove.raw.new; mv -f " + SYSEXT_STORE + "/gamecove.raw.new " + SYSEXT_STORE + "/gamecove.raw; " \
	+ "ln -sfn " + SYSEXT_STORE + "/gamecove.raw " + SYSEXT_ETC_LINK + "; rm -f " + SYSEXT_PATH + "; " \
	+ "printf '%s\\n' " + SYSEXT_ETC_LINK + " " + SYSEXT_UNIT_LINK + " " + GUARD_SCRIPT + " " + GUARD_UNIT + " " + GUARD_LINK + " " + SYSEXT_ENABLED_MARK + " > " + SYSEXT_KEEP + "; " \
	+ "else mkdir -p /var/lib/extensions; install -m 0644 \"$1\" " + SYSEXT_PATH + "; fi; " \
	+ "if ! systemctl is-enabled -q systemd-sysext.service 2>/dev/null; then mkdir -p /etc/gamecove && : > " + SYSEXT_ENABLED_MARK + "; fi; " \
	+ "systemctl enable systemd-sysext.service >/dev/null 2>&1 || true; systemd-sysext refresh; " \
	+ GUARD_INSTALL + "; " \
	+ "systemctl reload polkit.service >/dev/null 2>&1 || true"
const SYSEXT_REMOVE := "set -e; rm -f " + SYSEXT_ETC_LINK + " " + SYSEXT_PATH + " " + SYSEXT_KEEP + " " + SYSEXT_STORE + "/gamecove.raw " \
	+ GUARD_LINK + " " + GUARD_UNIT + " " + GUARD_SCRIPT + "; " \
	+ "rmdir " + SYSEXT_STORE + " 2>/dev/null || true; systemd-sysext refresh; " \
	+ "if [ -f " + SYSEXT_ENABLED_MARK + " ]; then rm -f " + SYSEXT_ENABLED_MARK + "; " \
	+ "other=0; for e in /etc/extensions/* /var/lib/extensions/* /run/extensions/* /usr/local/lib/extensions/*; do " \
	+ "if [ -e \"$e\" ]; then other=1; fi; done; " \
	+ "if [ \"$other\" = 0 ]; then systemctl disable systemd-sysext.service >/dev/null 2>&1 || true; fi; fi; " \
	+ "rmdir /etc/gamecove 2>/dev/null || true; " \
	+ "if [ \"${1:-}\" = purge ]; then rm -rf " + STATE_DIR + "; fi; " \
	+ "systemctl reload polkit.service >/dev/null 2>&1 || true"
## A Steam game (Steam's launch wrapper) or one of ours (app-steam-app<id> scope) is running.
const GAME_PATTERN := "SteamLaunch AppId=|app-steam-app[0-9]"


static func pkexec(cmd: Array) -> Array:
	return [PKEXEC] + cmd


## One password for the whole install: every queued root step of a run goes into one `sh` script that
## one pkexec runs, so the admin password is asked once. Each step keeps its own result: the script prints
## "@@GC start N", "@@GC end N <exit code>" (and "@@GC retry N" when the step's fallback ran, "@@GC pending N"
## when the step waits for GameCove to be in /usr) and the service reads them. A step that isn't optional and
## fails stops the script, as it would stop the run. `items`: [{"i", "cmd" (with or without the leading
## pkexec), "fallback", "optional", "needs_live"}]; `live`: files whose presence means GameCove is in /usr.
const MARK := "@@GC "


static func batch_script(items: Array, live: Array) -> String:
	var probe := " || ".join(PackedStringArray(live.map(func(f): return "[ -e %s ]" % _q(str(f))))) if not live.is_empty() else "false"
	var out: Array = []
	for it in items:
		var i := int(it["i"])
		var lines: Array = ["echo '%sstart %d'" % [MARK, i]]
		var body := _root_line(it["cmd"])
		var run := body + "; rc=$?"
		if not (it.get("fallback", []) as Array).is_empty():
			run += "; if [ $rc -ne 0 ]; then echo '%sretry %d'; %s; rc=$?; fi" % [MARK, i, _root_line(it["fallback"])]
		run += "; echo \"%send %d $rc\"" % [MARK, i]
		if not bool(it.get("optional", false)):
			run += "; if [ $rc -ne 0 ]; then exit 0; fi"
		if bool(it.get("needs_live", false)):
			lines.append("if %s; then %s; else echo '%spending %d'; fi" % [probe, run, MARK, i])
		else:
			lines.append(run)
		out.append("\n".join(PackedStringArray(lines)))
	return "\n".join(PackedStringArray(out)) + "\nexit 0"


static func _q(a: String) -> String:
	return "'" + a.replace("'", "'\\''") + "'"


static func _root_line(cmd: Array) -> String:
	var c: Array = (cmd as Array).duplicate()
	if not c.is_empty() and c[0] == PKEXEC:
		c.remove_at(0)
	return " ".join(PackedStringArray(c.map(func(a): return _q(str(a)))))


## The single pkexec command for a batch.
static func batch_command(script: String) -> Array:
	return pkexec(["sh", "-c", script])


## Bazzite / Fedora Atomic: layer the package. --apply-live makes it usable
## right away (fixes, session) and keeps it for the next boot; when that
## isn't possible the fallback just stages it for the next boot.
## Then, in the same root command (one password), the autologin guard goes into /etc
## (GUARD_INSTALL): without it a layer removed by hand while GameCove is the boot default
## leaves the login screen at a password prompt.
static func rpm_install(rpm: String, live := true, sha := "") -> Array:
	var text := "set -e; " + RPM_OSTREE + " install --idempotent " + ("--apply-live " if live else "") + "\"$1\"; " + GUARD_INSTALL
	if sha != "":
		return pkexec(["sh", "-c", _checked(text, "gamecove.rpm"), "sh", rpm, sha])
	return pkexec(["sh", "-c", text, "sh", rpm])


## The root step re-checks the package (review 9 L9): the file was verified by get-gamecove.sh as the user, in a
## folder the user can write, and is installed later as root. The script copies "$1" into a root-only folder,
## compares it with the sha256 in "$2" and goes on with the copy, so what was checked is what is installed.
static func _checked(text: String, name: String) -> String:
	return "set -e; d=$(mktemp -d); trap 'rm -rf \"$d\"' EXIT; cp -- \"$1\" \"$d/" + name + "\"; " \
		+ "echo \"$2  $d/" + name + "\" | sha256sum -c - >/dev/null; set -- \"$d/" + name + "\"; " \
		+ text.trim_prefix("set -e; ")


## The layer off again, and the guard with it: the installer puts the boot default back
## first (session_restore), so nothing names GameCove's session any more.
static func rpm_uninstall() -> Array:
	return pkexec(["sh", "-c", GUARD_REMOVE + "; exec " + RPM_OSTREE + " uninstall gamecove"])


## Uninstall with the fixes undone: the root helper's state goes too (review L25), one password.
static func rpm_remove(purge: bool) -> Array:
	if not purge:
		return rpm_uninstall()
	return pkexec(["sh", "-c", "rm -rf " + STATE_DIR + " && " + GUARD_REMOVE + "; exec " + RPM_OSTREE + " uninstall gamecove"])


## A newer local RPM in place of the layered one, in one transaction (next boot).
static func rpm_update(rpm: String, sha := "") -> Array:
	if sha != "":
		return pkexec(["sh", "-c", _checked("set -e; " + RPM_OSTREE + " uninstall gamecove --install \"$1\"", "gamecove.rpm"), "sh", rpm, sha])
	return pkexec([RPM_OSTREE, "uninstall", "gamecove", "--install", rpm])


static func sysext_install(raw: String, sha := "") -> Array:
	if sha != "":
		return pkexec(["sh", "-c", _checked(SYSEXT_INSTALL, "gamecove.raw"), "sh", raw, sha])
	return pkexec(["sh", "-c", SYSEXT_INSTALL, "sh", raw])


static func sysext_remove(purge := false) -> Array:
	var c := ["sh", "-c", SYSEXT_REMOVE, "sh"]
	if purge:
		c.append("purge")
	return pkexec(c)


static func fix(helper: String, fix_name: String, verb: String) -> Array:
	return pkexec([helper, fix_name, verb])


## Every fix in use on this machine undone, whoever applied it (installer, Fixes page, the charge
## limit, fan curve, LEDs, power-tune values): one password (review S2-5).
static func fix_remove_all(helper: String) -> Array:
	return pkexec([helper, "--remove-all"])


## XeSS XMX driver (xess-xmx-linux), the same install ClawDeck does: downloaded,
## its install.sh run as the desktop user (no pkexec). Intel Arc with XMX only.
static func xess_install(helper: String, home: String) -> Array:
	return [helper, "xess-install", "--home", home, "--gpu", "vendor=intel,xmx=1"]


static func xess_remove(helper: String, home: String) -> Array:
	return [helper, "xess-remove", "--home", home]


## Heroic Games Launcher (Epic, GOG and Amazon sign-in and games without separate tools) from Flathub,
## for this user: the same two commands the Stream page runs for Moonlight (scripts/streaming/moonlight.gd,
## install_commands), no password.
const HEROIC_ID := "com.heroicgameslauncher.hgl"


static func heroic_install(flatpak := "flatpak") -> Array:
	var Moonlight = load("res://scripts/streaming/moonlight.gd")
	var cmds: Array = Moonlight.install_commands(flatpak)
	cmds[1] = [flatpak, "install", "--user", "--noninteractive", "-y", "flathub", HEROIC_ID]
	return cmds


static func heroic_open(flatpak := "flatpak") -> Array:
	return [flatpak, "run", HEROIC_ID]


## Uninstall: everything upscaling put on this handheld goes (games as shipped,
## the XeSS XMX driver, lsfg-vk from us, the managed folders). Saves stay.
static func upscale_purge(helper: String, home: String) -> Array:
	return [helper, "purge", "--home", home]


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
	+ "if [ \"$(steamosctl get-default-desktop-session 2>/dev/null | head -n 1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '[:space:]')\" = gamecove.desktop ]; then " \
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


## Moonlight for the Stream tab: a Flatpak for this user (no password), the same
## commands the Stream page runs (scripts/streaming/moonlight.gd).
static func moonlight_tasks() -> Array:
	var Moonlight = load("res://scripts/streaming/moonlight.gd")
	var cmds: Array = Moonlight.install_commands("flatpak")
	return [
		_cmd("moonlight_remote", cmds[0], {"optional": true}),
		_cmd("moonlight_install", cmds[1], {"optional": true,
			"undo": ["flatpak", "uninstall", "--user", "--noninteractive", "-y", Moonlight.FLATPAK_ID]}),
	]


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


static func package_task(method: String, pkg: String, verb := "install", sha := "") -> Dictionary:
	if method == "rpm-ostree":
		if verb == "update":
			return _cmd("package_update", rpm_update(pkg, sha))
		return _cmd("package", rpm_install(pkg, true, sha), {"undo": rpm_uninstall(), "fallback": rpm_install(pkg, false, sha)})
	return _cmd("package_update" if verb == "update" else "package", sysext_install(pkg, sha), {"undo": sysext_remove()})


static func fix_task(paths: RefCounted, fix_name: String, verb := "install") -> Dictionary:
	var undo_verb := "remove" if verb == "install" else "install"
	return _cmd("fix_" + verb, fix(paths.fix_helper(), fix_name, verb),
		{"undo": fix(paths.fix_helper(), fix_name, undo_verb), "needs_live": true, "fix": fix_name,
		 "optional": true})   # one optional fix failing never stops the install: it is listed at the end with its own retry


## The tasks for `action` (install | change | repair | update | uninstall | finish).
## `choices` from the plan; `target` from Target.detect.
static func tasks_for(action: String, choices: Dictionary, target: Dictionary, paths: RefCounted) -> Array:
	var method := str(target.get("method", "none"))
	var pkg := str(target.get("package", ""))
	var pkg_sha := str(target.get("package_sha256", ""))
	var state: Dictionary = target.get("state", {})
	var had_fixes: Array = state.get("fixes", []) if state.get("fixes", []) is Array else []
	var want_fixes: Array = choices.get("fixes", [])
	var present := bool(target.get("installed", false)) or bool(target.get("staged", false))
	var had_xess := bool(state.get("choices", {}).get("xess_driver", false)) if state.get("choices") is Dictionary else false
	var want_xess := bool(choices.get("xess_driver", false))
	var had_moonlight := bool(state.get("choices", {}).get("moonlight", false)) if state.get("choices") is Dictionary else false
	var want_moonlight := bool(choices.get("moonlight", false))
	var out: Array = [_internal("check_game")]
	match action:
		"install", "change", "repair":
			if method != "none" and pkg != "" and (action != "change" or not present):
				out.append(package_task(method, pkg, "install", pkg_sha))
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
			# a change never removes Moonlight: the user may use it on its own
			if want_moonlight and (action != "change" or not had_moonlight):
				out.append_array(moonlight_tasks())
			out.append(_internal("pending", {"undo": "remove_pending"}))
			if method != "none":
				out.append(_cmd("apply_now", [paths.apply_helper()], {"needs_live": true, "optional": true}))
			out.append(_internal("state"))
		"update":
			if method != "none" and pkg != "":
				out.append(package_task(method, pkg, "update", pkg_sha))
			out.append(_internal("user_files"))
			out.append(_internal("state"))
		"uninstall":
			# review H4: both must work before the package goes, or the boot default could name a
			# session that no longer exists, and kernel arguments, rules and services would stay
			# with no helper left to undo them. A failure stops the uninstall (retry from the UI).
			out.append(_cmd("session_restore", session_restore(paths)))
			# GameCove's launcher out of every Steam game's launch options (stops Steam first)
			out.append(_internal("steam_unwrap", {"optional": true}))
			if bool(target.get("installed", false)):
				# every game back to the files it shipped with, the XeSS XMX driver and lsfg-vk we
				# installed out, our folder of upscaler files gone (as the user; upkeep.purge). Before the
				# root steps, which run as one batch (one password) and take the package with them.
				out.append(_cmd("upscale_purge", upscale_purge(paths.upscale_helper(), paths.home), {"optional": true}))
			if bool(choices.get("remove_fixes", true)) and bool(target.get("installed", false)):
				# not only what the installer recorded: every fix and device setting in use
				out.append(_cmd("fix_remove_all", fix_remove_all(paths.fix_helper())))
			var purge := bool(choices.get("remove_fixes", true)) and bool(target.get("installed", false))
			if method == "rpm-ostree":
				out.append(_cmd("package_remove", rpm_remove(purge)))
			elif method == "sysext":
				out.append(_cmd("package_remove", sysext_remove(purge)))
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
