extends RefCounted
## Where the installer reads and writes, all under the user's home (tests point
## `home` at a temp folder). Nothing here touches the system.

const APP_ID := "io.github.ihulksmashi.GameCoveInstaller"

var home := OS.get_environment("HOME")
## Filesystem root prefix for system files (/usr/lib/gamecove, ...). "" = real.
var root := ""


static func for_home(h: String, r := "") -> RefCounted:
	var p: RefCounted = load("res://scripts/installer/paths.gd").new()
	p.home = h
	p.root = r
	return p


func data_dir() -> String:
	return home + "/.local/share/gamecove"


func installer_dir() -> String:
	return data_dir() + "/installer"


func log_file() -> String:
	return data_dir() + "/installer.log"


## KEY=value choices for after the package is live (read by gamecove-apply-choices).
func pending_file() -> String:
	return data_dir() + "/pending-choices"


## What the installer did: method, version, choices, fixes (JSON).
func state_file() -> String:
	return data_dir() + "/install-state.json"


## Written by get-gamecove.sh: TAG, VERSION, OS, PACKAGE, APP.
func release_file() -> String:
	return installer_dir() + "/release.env"


func env_conf() -> String:
	return home + "/.config/environment.d/gamecove.conf"


func unit_dir() -> String:
	return home + "/.config/systemd/user"


func unit_file() -> String:
	return unit_dir() + "/gamecove-apply-choices.service"


func unit_link() -> String:
	return unit_dir() + "/default.target.wants/gamecove-apply-choices.service"


func apps_dir() -> String:
	return home + "/.local/share/applications"


func installer_entry() -> String:
	return apps_dir() + "/" + APP_ID + ".desktop"


func switch_entry() -> String:
	return apps_dir() + "/io.github.ihulksmashi.GameCoveSwitch.desktop"


func window_entry() -> String:
	return apps_dir() + "/io.github.ihulksmashi.GameCoveWindow.desktop"


## Opens the installer once in Desktop Mode to finish fixes left for later.
func autostart_entry() -> String:
	return home + "/.config/autostart/io.github.ihulksmashi.GameCoveFinish.desktop"


## The desktop folder (XDG user-dirs.dirs, else ~/Desktop).
func desktop_dir() -> String:
	var dirs := home + "/.config/user-dirs.dirs"
	if FileAccess.file_exists(dirs):
		for line in FileAccess.get_file_as_string(dirs).split("\n", false):
			var l := line.strip_edges()
			if l.begins_with("XDG_DESKTOP_DIR="):
				var v := l.substr(16).strip_edges().trim_prefix("\"").trim_suffix("\"")
				return v.replace("$HOME", home)
	return home + "/Desktop"


func desktop_shortcut() -> String:
	return desktop_dir() + "/Install GameCove.desktop"


## The live, installed app (package in /usr).
func installed_binary() -> String:
	return root + "/usr/lib/gamecove/gamecove.x86_64"


func fix_helper() -> String:
	return root + "/usr/libexec/gamecove/gamecove-fix"


## Per-game upscaling helper; also installs the XeSS XMX driver (Intel Arc, as the user).
func upscale_helper() -> String:
	return root + "/usr/libexec/gamecove/gamecove-upscale"


func apply_helper() -> String:
	return root + "/usr/libexec/gamecove/gamecove-apply-choices"


func session_select() -> String:
	return root + "/usr/bin/gamecove-session-select"
