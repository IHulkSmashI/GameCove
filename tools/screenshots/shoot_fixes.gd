extends SceneTree
## The Fixes page (Settings > Device > Fixes) with GameCove's real Fixes service on a fake root
## helper, for three handhelds, plus the start dialog for a fix in the system's way:
##   fixes_claw          MSI Claw 8 EX on Bazzite: three applied (tested on hardware), one
##                       recommended, one optional, an update in History
##   fixes_claw_details  the same with the VRR fix's Details open (changes, undo, risk, QR)
##   fixes_claw_clash    InputPlumber now ships the buttons map and ours still shadows it
##   fixes_claw_dialog   the start dialog for that case (Gaming Mode)
##   fixes_ally          ROG Ally on SteamOS: the fingerprint fix the system now does itself,
##                       removed by GameCove (History, Keep it anyway), the optional one
##   fixes_deck          Steam Deck OLED: nothing needed
##
##   SHOOT_SCRIPT=shoot_fixes.gd tools/screenshots/shoot.sh /tmp/shots 1920x1200 [only,these]
##   SHOOT_THEME=light renders the light theme (default: cove).

const ShotVersion := preload("shot_version.gd")
const LifeTests := preload("res://tests/test_fix_lifecycle.gd")
const FixesSvc := preload("res://scripts/device/fixes.gd")
const SHOTS := ["fixes_claw", "fixes_claw_details", "fixes_claw_clash", "fixes_claw_dialog", "fixes_ally", "fixes_deck"]
const NOW := 1794268800   # 2026-11-10

var out := "/tmp/gamecove-shots/"
var only: Array = []
var suffix := ""
var main: Control
var tmp := "/tmp/gamecove-shots/fixes-home"


class ShotDevice extends Object:
	var names := {"msi-claw-8-ex": "MSI Claw 8 EX AI+", "asus-rog-ally": "ROG Ally", "steam-deck-oled": "Steam Deck OLED"}
	var device_id := ""
	func display_name() -> String: return names.get(device_id, device_id)
	func support_level() -> String: return "full"


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		match args[i]:
			"--out": out = args[i + 1].trim_suffix("/") + "/"
			"--only": only = Array(args[i + 1].split(","))
			"--suffix": suffix = args[i + 1]
	_run.call_deferred()


func frames(n: int) -> void:
	for i in n:
		await process_frame


func want(name: String) -> bool:
	return only.is_empty() or name in only


func shot(name: String) -> void:
	if not want(name):
		return
	await frames(40)
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(out)
	root.get_texture().get_image().save_png(out + name + suffix + ".png")
	print("saved ", out + name + suffix + ".png")


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _run() -> void:
	OS.low_processor_usage_mode = false
	var prefs = load("res://scripts/ui/ui_prefs.gd")
	prefs.path = "/tmp/gamecove-shots/ui-fixes.cfg"
	DirAccess.remove_absolute(prefs.path)
	load("res://scripts/main.gd").boot_splash = false
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await frames(3)
	main._live_timer.stop()
	main._live_timer.wait_time = 9999
	var flow_script = load("res://scripts/ui/setup/setup_flow.gd")
	if flow_script.instance != null:
		flow_script.instance.finish()
	var th := OS.get_environment("SHOOT_THEME")
	if th != "":
		prefs.theme = th
		prefs.match_art = th != "light"
		main.apply_theme()
	main.hint_status.text = "● GameCove %s" % ShotVersion.short()
	await frames(4)

	if want("fixes_claw") or want("fixes_claw_details"):
		var c := _claw("claw", false)
		await _open(c[0], c[2], "MSI Claw 8 EX AI+")
		await shot("fixes_claw")
		if want("fixes_claw_details"):
			var page: Control = main.settings.find_child("Panel_fixes", true, false)
			# Details opens and takes focus, so the column scrolls to it
			page.press("claw8ex-vrr", "details")
			await shot("fixes_claw_details")
	if want("fixes_claw_clash") or want("fixes_claw_dialog"):
		var c := _claw("clash", true)
		c[0].check_changes()
		await _open(c[0], c[2], "MSI Claw 8 EX AI+")
		await shot("fixes_claw_clash")
		if want("fixes_claw_dialog"):
			main.show_screen("home")
			await frames(10)
			main.home.focus_later(main.home.default_focus())
			main.fixes = c[0]
			# what the start pass hands main.gd (attention_needed)
			main._on_fix_attention(c[0].attention())
			await shot("fixes_claw_dialog")
			if main.fix_dialog != null:
				main.fix_dialog.finish("later")
			await frames(4)
	if want("fixes_ally"):
		var a := _ally()
		await _open(a[0], a[2], "ROG Ally")
		# down to Not needed any more and History (Keep it anyway focused)
		var page: Control = main.settings.find_child("Panel_fixes", true, false)
		if page != null and page.buttons.has("keep:ally-fingerprint-drain"):
			page.buttons["keep:ally-fingerprint-drain"].grab_focus()
		await shot("fixes_ally")
	if want("fixes_deck"):
		var d := _deck()
		await _open(d[0], d[2], "Steam Deck OLED")
		await shot("fixes_deck")
	quit()


## Opens Settings > Device > Fixes on `svc` with `dev` as the device.
func _open(svc: Node, dev: Object, title: String) -> void:
	main.top_bar.set_status(title, {"percent": 72, "status": "Discharging", "watts": 9.4}, "8:42 PM", {"connected": true, "strength": 0.8})
	var s: Dictionary = main.settings.services.duplicate()
	s["fixes"] = svc
	s["device"] = dev
	s.erase("photo")
	main.settings.set_services(s)
	main.show_screen("settings")
	await frames(4)
	main.settings.open_category("device", "fixes")
	await frames(14)


func _helper(fixes: Dictionary) -> RefCounted:
	var r = LifeTests.FakeHelper.new()
	r.fixes = fixes
	return r


func _svc(id: String, r: RefCounted, sys: Dictionary, history: Array, installed: Array, can_prompt := false) -> Array:
	var h := tmp + "_" + id + "_" + str(randi())
	for f in sys:
		_write(h + "/root" + f, sys[f])
	_write(h + "/.local/share/gamecove/install-state.json", JSON.stringify({"fixes": installed}))
	if not history.is_empty():
		_write(h + "/.local/share/gamecove/fixes-lifecycle.json", JSON.stringify({"schema": 1, "keep": {}, "pending": {},
			"history": history, "data_checked": NOW}))
	var s: Node = FixesSvc.new()
	s.name = "ShotFixes"
	s.path_env = h + "/bin"
	s.now_unix = NOW
	s.setup({"runner": r, "home": h, "device": id, "sys_root": h + "/root", "can_prompt": can_prompt, "background": false})
	s.data_result = "verified"
	s.last_changes = {"changed": [], "first_run": false}
	s.refresh()
	var dev := ShotDevice.new()
	dev.device_id = id
	return [s, r, dev]


const CLAW_SYS := {"/proc/sys/kernel/osrelease": "6.17.7-ba25.fc43.x86_64\n",
	"/etc/os-release": "NAME=\"Bazzite\"\nID=bazzite\nVERSION_ID=44\nOSTREE_VERSION='44.20261105.0'\n",
	"/usr/bin/rpm-ostree": "", "/sys/module/xe/version": "0\n"}


## clash: InputPlumber ships its own map and the rebuild couldn't settle it.
func _claw(tag: String, clash: bool) -> Array:
	var r = _helper({
		"claw8ex-buttons": {"installed": true, "os_fixed": clash, "conflict": clash},
		"claw8ex-vrr": {"installed": true, "os_fixed": false},
		"claw8ex-gyro": {"installed": true, "os_fixed": false},
		"claw-kbd-wakeup": {"installed": false, "os_fixed": false},
		"claw-wifi-d3cold": {"installed": false, "os_fixed": false}})
	r.refresh_resolves = false
	var sys := CLAW_SYS.duplicate()
	sys[FixesSvc.IP_STOCK] = "capability_map_id: %s\n" % ("claw8ex_upstream" if clash else "claw2")
	var hist := [] if clash else [{"time": NOW - 3 * 86400, "device": "msi-claw-8-ex", "fix": "claw8ex-gyro", "title": "Gyro",
		"action": "updated", "reason": "revision", "detail": "revision 2", "undone": false}]
	var out_ := _svc("msi-claw-8-ex", r, sys, hist, ["claw8ex-buttons", "claw8ex-vrr", "claw8ex-gyro"])
	var _t := tag
	return out_


func _ally() -> Array:
	var r = _helper({
		"ally-fingerprint-drain": {"installed": false, "os_fixed": true},
		"ally-mcu-powersave": {"installed": false, "os_fixed": false},
		"ally-controller-wakeup": {"installed": false, "os_fixed": false, "hw": false},
		"ax210-d3cold": {"installed": false, "os_fixed": false, "hw": false}})
	var sys := {"/proc/sys/kernel/osrelease": "6.11.11-valve27-1-neptune-611-gfd0dd251480d\n",
		"/etc/os-release": "NAME=\"SteamOS\"\nID=steamos\nVERSION_ID=3.10.2\n",
		"/sys/class/firmware-attributes/asus-armoury/attributes/mcu_powersave/current_value": "0\n",
		"/usr/bin/pacman": ""}
	var hist := [{"time": NOW - 86400, "device": "asus-rog-ally", "fix": "ally-fingerprint-drain", "title": "No drain while off",
		"action": "removed", "reason": "native", "detail": "", "undone": false}]
	return _svc("asus-rog-ally", r, sys, hist, ["ally-fingerprint-drain"])


func _deck() -> Array:
	# no AX210 in a Deck: the optional Wi-Fi fix says not needed and stays off the page
	var r = _helper({"ax210-d3cold": {"installed": false, "os_fixed": false, "hw": false}})
	return _svc("steam-deck-oled", r, {"/etc/os-release": "NAME=\"SteamOS\"\nID=steamos\nVERSION_ID=3.10.2\n"}, [], [])
