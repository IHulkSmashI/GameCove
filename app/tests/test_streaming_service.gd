extends "res://tests/test_case.gd"
## The Streaming service against fake mDNS (avahi-browse output), fake HTTP
## (curl answered from serverinfo/applist fixtures), a fake Moonlight (Flatpak
## folder + Moonlight.conf in a fixture root) and a fake process spawner.

const Streaming := preload("res://scripts/streaming/streaming.gd")
const FakeRunner := preload("res://tests/fixtures/system/fake_runner.gd")
const FakeSpawn := preload("res://tests/fixtures/streaming/fake_spawn.gd")
const Moonlight := preload("res://scripts/streaming/moonlight.gd")

const UUID := "A1B2C3D4-0000-4E5F-8899-AABBCCDDEEFF"
const HOME := "/home/deck"

var root := ""
var runner: RefCounted
var spawn: RefCounted
var clock := 1_800_000_000
## url part -> fixture file or "" (no answer)
var answers := {}
var signals: Array = []


func _f(name: String) -> String:
	return fixture("streaming/" + name)


func _make(with_moonlight := true, with_conf := false) -> Node:
	root = ProjectSettings.globalize_path("user://test_streaming_svc_%d" % randi())
	DirAccess.make_dir_recursive_absolute(root + "/usr/bin")
	DirAccess.make_dir_recursive_absolute(root + "/run/user/1000/systemd")
	for b in ["flatpak", "systemd-run", "curl"]:
		FileAccess.open(root + "/usr/bin/" + b, FileAccess.WRITE).store_string("#!/bin/sh\n")
	if with_moonlight:
		DirAccess.make_dir_recursive_absolute(root + HOME + "/.local/share/flatpak/app/" + Moonlight.FLATPAK_ID + "/current")
	if with_conf:
		_write_conf(FileAccess.get_file_as_string(_f("Moonlight.conf")))
	runner = FakeRunner.new()
	runner.handler = _answer
	spawn = FakeSpawn.new()
	signals = []
	var s: Node = Streaming.new()
	s.sync_mode = true
	s.setup({"runner": runner, "spawn": spawn, "home": HOME, "path_env": "/usr/bin", "sys_root": root,
		"runtime_dir": "/run/user/1000", "data_dir": root + "/data",
		"display": {"width": 1920, "height": 1200, "hz": 120, "hdr": false}, "gpu_family": "intel-xe2",
		"clock": func() -> int: return clock, "reaper": "/usr/libexec/gamecove/reaper",
		"probe": func(addrs, _port): return ["192.168.1.20"] if "192.168.1.20" in addrs else [],
		"send": func(_a, _p, _b): return true})
	s.changed.connect(func(): signals.append("changed"))
	s.apps_changed.connect(func(id): signals.append("apps:" + id))
	s.pair_changed.connect(func(id, st, info): signals.append(["pair", id, st, info]))
	s.notice.connect(func(t, tone): signals.append(["notice", t, tone]))
	s.install_changed.connect(func(st, line): signals.append(["install", st, line]))
	return s


func _write_conf(text: String) -> void:
	var d := root + HOME + "/.var/app/" + Moonlight.FLATPAK_ID + "/config/" + Moonlight.ORG
	DirAccess.make_dir_recursive_absolute(d)
	var f := FileAccess.open(d + "/Moonlight.conf", FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _fx(code: int, body: String, http := 200, connect := "0.004000") -> Dictionary:
	return {"code": code, "out": body + "\n@@gamecove %03d %s" % [http, connect]}


func _answer(cmd: String) -> Variant:
	if cmd.begins_with("curl"):
		for part in answers:
			if cmd.contains(part):
				var v: Variant = answers[part]
				if v is Dictionary:
					return v
				if str(v) == "":
					return _fx(7, "curl: (7) Failed to connect", 0, "0.000000")
				if str(v).ends_with(".png"):
					# appasset: write a tiny PNG where curl's -o points
					var out := cmd.get_slice(" -o ", 1).get_slice(" ", 0)
					var img := Image.create(4, 6, false, Image.FORMAT_RGB8)
					img.save_png(out)
					return _fx(0, "")
				return _fx(0, FileAccess.get_file_as_string(_f(str(v))))
		return _fx(7, "curl: (7) Failed to connect", 0, "0.000000")
	return null


func after_each(s: Node) -> void:
	s.free()
	OS.move_to_trash(root)


func test_discovers_with_avahi_and_checks() -> void:
	answers = {"192.168.1.20:47989/serverinfo": "serverinfo_vibepollo_http.xml"}
	var s := _make()
	runner.responses["avahi-browse -rpt _nvstream._tcp"] = {"code": 0, "file": _f("avahi.txt")}
	s.refresh()
	ok(s.hosts.has(UUID), "found by mDNS and keyed by uuid after serverinfo")
	var h: Dictionary = s.host(UUID)
	eq(h["name"], "GAMING-PC", "name from serverinfo")
	eq(h["status"], "online", "online")
	eq(h["latency_ms"], 4, "connect time")
	eq(h["flavor"], "vibepollo", "flavor")
	eq(h["paired"], false, "not paired")
	eq(h["remote"], false, "LAN")
	ok(s.hosts.size() == 2, "the second (offline) PC is listed too")
	var other: Dictionary = s.host("addr:fd00::31")
	eq(other["status"], "offline", "no answer, no MAC: offline")
	eq(other["name"], "Living Room.PC", "mDNS name kept")
	ok(not runner.called("ip -o -4"), "no port probe when mDNS found PCs")
	after_each(s)


func test_probe_when_no_mdns() -> void:
	answers = {"192.168.1.20:47989/serverinfo": "serverinfo_sunshine_http.xml"}
	var s := _make()
	runner.responses["avahi-browse -rpt _nvstream._tcp"] = {"code": 127, "out": ""}
	runner.responses["ip -o -4 addr show"] = {"code": 0, "file": _f("ip_addr.txt")}
	s.refresh()
	ok(s.hosts.has("5C2B7E9A-1111-2222-3333-444455556666"), "found by port probe")
	eq(s.host("5C2B7E9A-1111-2222-3333-444455556666")["source"], "probe", "source")
	after_each(s)


func test_moonlight_known_hosts_and_paired_check() -> void:
	answers = {"192.168.1.20:47989/serverinfo": "serverinfo_vibepollo_http.xml",
		"192.168.1.20:47984/serverinfo": "serverinfo_vibepollo_https.xml",
		"192.168.1.20:47984/applist": "applist.xml",
		"/appasset": "art.png"}
	var s := _make(true, true)
	s.refresh()
	var h: Dictionary = s.host(UUID)
	eq(h["paired"], true, "paired in Moonlight")
	eq(h["mac"], "D8:BB:C1:12:34:56", "MAC")
	eq(h["status"], "busy", "busy from the paired serverinfo")
	eq(h["current_app"], 1093255277, "running app")
	eq(h["sleep_allowed"], true, "Vibepollo sleep allowed")
	eq(h["apps_state"], "ready", "apps loaded after a paired check")
	eq(h["apps"].size(), 3, "apps")
	ok(FileAccess.file_exists(str(h["apps"][0]["art"])), "box art downloaded")
	ok(runner.calls.any(func(c): return c.contains("--cert") and c.contains("client.pem")), "Moonlight's certificate used")
	var pem := root + "/run/user/1000/gamecove-stream/client.pem"
	ok(FileAccess.file_exists(pem), "identity written to the runtime folder")
	eq(FileAccess.get_unix_permissions(pem) & 63, 0, "only the user can read it")
	var laptop: Dictionary = s.host("77777777-8888-9999-AAAA-BBBBBBBBBBBB")
	eq(laptop["paired"], false, "unpaired Moonlight host")
	eq(laptop["remote"], true, "Tailscale address is remote")
	# saved and loaded again
	var again: Node = Streaming.new()
	again.sync_mode = true
	again.setup(s.ctx)
	eq(again.host(UUID)["apps"].size(), 3, "apps cached on disk")
	eq(again.host(UUID)["mac"], "D8:BB:C1:12:34:56", "MAC kept")
	again.free()
	after_each(s)


func test_apps_fallback_to_moonlight_list_and_denied() -> void:
	answers = {"192.168.1.20:47989/serverinfo": "serverinfo_vibepollo_http.xml",
		"192.168.1.20:47984/serverinfo": "serverinfo_vibepollo_https.xml"}
	var s := _make(true, true)
	runner.responses["/usr/bin/flatpak run --branch=stable com.moonlight_stream.Moonlight list 192.168.1.20 --csv"] = {"code": 0, "file": _f("moonlight_list_csv.txt")}
	s.refresh()
	var h: Dictionary = s.host(UUID)
	eq(h["apps_state"], "ready", "moonlight list used when curl applist fails")
	eq(h["apps"].size(), 3, "csv apps")
	answers["192.168.1.20:47984/applist"] = "applist_denied.xml"
	s.load_apps(UUID)
	eq(s.host(UUID)["apps_state"], "denied", "Vibepollo permission placeholder")
	answers["192.168.1.20:47984/applist"] = _fx(0, FileAccess.get_file_as_string(_f("applist_unauthorized.xml")), 401)
	runner.responses.clear()
	runner.responses["/usr/bin/flatpak run --branch=stable com.moonlight_stream.Moonlight list 192.168.1.20 --csv"] = {"code": 255, "out": "Computer GAMING-PC has not been paired. Please open Moonlight to pair before retrieving games list."}
	s.load_apps(UUID)
	eq(s.host(UUID)["paired"], false, "PC forgot us: unpaired")
	after_each(s)


func test_manual_add() -> void:
	answers = {"100.101.102.103:47989/serverinfo": "serverinfo_vibepollo_http.xml"}
	var s := _make()
	eq(s.add_manual("not an address"), s.T.BAD_ADDRESS, "rejected")
	eq(s.add_manual("100.101.102.103"), "", "queued")
	var h: Dictionary = s.host(UUID)
	eq(h["manual"], true, "manual")
	eq(h["remote"], true, "Tailscale: remote")
	eq(h["status"], "online", "checked")
	eq(s.add_manual("192.168.9.9"), "", "offline address accepted")
	eq(s.host("addr:192.168.9.9")["status"], "offline", "kept as offline")
	ok(signals.any(func(x): return x is Array and x[0] == "notice" and str(x[1]).contains("192.168.9.9")), "told it isn't answering")
	s.remove_host("addr:192.168.9.9")
	ok(not s.hosts.has("addr:192.168.9.9"), "forgotten")
	after_each(s)


func test_pairing_flow() -> void:
	answers = {"192.168.1.20:47989/serverinfo": "serverinfo_vibepollo_http.xml"}
	var s := _make(true, false)
	s.add_manual("192.168.1.20")
	ok(s.pair(UUID), "pairing starts")
	var cmd: Array = spawn.last()
	ok("pair" in cmd and "--pin" in cmd and "--env=QT_QPA_PLATFORM=offscreen" in cmd, "moonlight pair --pin, no window")
	var pin: String = cmd[cmd.find("--pin") + 1]
	eq(pin.length(), 4, "4-digit PIN")
	ok(pin.is_valid_int(), "digits")
	var waiting: Array = signals.filter(func(x): return x is Array and x[0] == "pair" and x[2] == "waiting")
	eq(waiting[0][3]["pin"], pin, "PIN shown")
	eq(waiting[0][3]["url"], "https://192.168.1.20:47990", "web UI address")
	ok(not s.pair(UUID), "one pairing at a time")
	s.poll_pair()
	eq(s.pairing_host(), UUID, "still waiting")
	# Moonlight writes the PC's certificate when the user typed the PIN
	_write_conf(FileAccess.get_file_as_string(_f("Moonlight.conf")))
	answers["192.168.1.20:47984/serverinfo"] = "serverinfo_vibepollo_https.xml"
	answers["192.168.1.20:47984/applist"] = "applist.xml"
	answers["/appasset"] = "art.png"
	s.poll_pair()
	eq(s.pairing_host(), "", "done")
	ok(signals.any(func(x): return x is Array and x[0] == "pair" and x[2] == "paired"), "paired signal")
	ok(spawn.killed.size() == 1, "Moonlight's pair window closed")
	eq(s.host(UUID)["paired"], true, "paired")
	eq(s.host(UUID)["mac"], "D8:BB:C1:12:34:56", "MAC from Moonlight")
	eq(s.host(UUID)["apps"].size(), 3, "apps loaded")
	after_each(s)


func test_pairing_timeout_and_cancel() -> void:
	answers = {"192.168.1.20:47989/serverinfo": "serverinfo_vibepollo_http.xml"}
	var s := _make()
	s.add_manual("192.168.1.20")
	s.pair(UUID)
	clock += 200
	s.poll_pair()
	ok(signals.any(func(x): return x is Array and x[0] == "pair" and x[2] == "failed"), "timed out")
	s.pair(UUID)
	s.cancel_pair()
	ok(signals.any(func(x): return x is Array and x[0] == "pair" and x[2] == "cancelled"), "cancelled")
	eq(spawn.alive.size(), 0, "no Moonlight left running")
	s.pair(UUID)
	spawn.alive.clear()   # Moonlight closed by itself
	s.poll_pair()
	eq(signals.filter(func(x): return x is Array and x[0] == "pair" and x[2] == "failed").size(), 2, "stopped = failed")
	after_each(s)


func test_wake_and_asleep() -> void:
	answers = {}
	var s := _make(true, true)
	DirAccess.make_dir_recursive_absolute(root + "/proc/net")
	DirAccess.copy_absolute(_f("arp.txt"), root + "/proc/net/arp")
	runner.responses["ip -o -4 addr show"] = {"code": 0, "file": _f("ip_addr.txt")}
	s.refresh()
	eq(s.host(UUID)["status"], "asleep", "known MAC, no answer: asleep")
	eq(s.host("77777777-8888-9999-AAAA-BBBBBBBBBBBB")["status"], "offline", "no MAC: offline")
	ok(s.can_wake(UUID), "can wake")
	var sent: Array = []
	s.ctx["send"] = func(a, p, b): sent.append([a, p]); return b.size() == 102
	ok(s.wake(UUID), "wake")
	ok(["192.168.1.255", 9] in sent and ["192.168.1.20", 9] in sent, "broadcast and direct")
	eq(s.host(UUID)["status"], "waking", "waking")
	answers["192.168.1.20:47989/serverinfo"] = "serverinfo_vibepollo_http.xml"
	s.check_host(UUID)
	eq(s.host(UUID)["status"], "online", "awake")
	ok(signals.any(func(x): return x is Array and x[0] == "notice" and x[2] == "good"), "woke notice")
	after_each(s)


func test_arp_gives_mac() -> void:
	answers = {}
	var s := _make()
	DirAccess.make_dir_recursive_absolute(root + "/proc/net")
	DirAccess.copy_absolute(_f("arp.txt"), root + "/proc/net/arp")
	s.add_manual("192.168.1.20")
	eq(s.host("addr:192.168.1.20")["mac"], "D8:BB:C1:12:34:56", "MAC from the ARP cache")
	eq(s.host("addr:192.168.1.20")["status"], "asleep", "wakeable")
	after_each(s)


func test_launch_command() -> void:
	answers = {"192.168.1.20:47989/serverinfo": "serverinfo_vibepollo_http.xml",
		"192.168.1.20:47984/serverinfo": "serverinfo_vibepollo_https.xml",
		"192.168.1.20:47984/applist": "applist.xml", "/appasset": "art.png"}
	var s := _make(true, true)
	s.refresh()
	var app: Dictionary = s.host(UUID)["apps"][2]
	var r: Dictionary = s.launch(UUID, app)
	eq(r["ok"], true, "started")
	eq(r["scoped"], true, "scoped")
	var game: Dictionary = s.game_for(UUID, app)
	eq(game["key"], "stream:%s:1450239417" % UUID, "game key")
	eq(r["app_id"], s.app_id_for(game["key"]), "app id for gamescope")
	ok(r["app_id"] & 0x40000000 != 0, "our id range")
	var cmd: Array = spawn.last()
	eq(cmd.slice(0, 5), ["/usr/bin/systemd-run", "--user", "--scope", "--collect", "--quiet"], "scope")
	eq(str(cmd[5]), "--unit=app-steam-app%d-%d" % [r["app_id"], clock % 100000000], "unit named for gamescope")
	var at := cmd.find("/usr/libexec/gamecove/reaper")
	ok(at > 0 and cmd[at + 1] == "SteamLaunch" and cmd[at + 2] == "AppId=%d" % r["app_id"] and cmd[at + 3] == "--", "reaper wrapper")
	ok("stream" in cmd and "Cyberpunk 2077 & Phantom Liberty" in cmd, "moonlight stream app")
	ok(cmd[cmd.find("--resolution") + 1] == "1920x1200" and cmd[cmd.find("--video-codec") + 1] == "AV1", "matched to the panel and decoder")
	# per-app settings
	s.set_app_override(UUID, 1450239417, true)
	s.set_pick(UUID, "resolution", "720p", 1450239417)
	eq(s.resolved(UUID, 1450239417)["width"], 1280, "app override")
	eq(s.resolved(UUID)["width"], 1920, "PC setting untouched")
	s.set_pick(UUID, "quality", "best")
	eq(s.effective_picks(UUID)["quality"], "best", "PC pick")
	s.set_app_override(UUID, 1450239417, false)
	eq(s.resolved(UUID, 1450239417)["width"], 1920, "back to the PC's")
	eq(s.launch(UUID, app)["ok"], true, "second launch")
	spawn.fail = true
	var bad: Dictionary = s.launch(UUID, app)
	eq([bad["ok"], bad["app_id"]], [false, 0], "spawn failure")
	ok(s.quit_app(UUID) == false, "quit fails while spawn fails")
	spawn.fail = false
	ok(s.quit_app(UUID), "quit")
	ok("quit" in spawn.last(), "moonlight quit")
	after_each(s)


func test_launch_refused() -> void:
	answers = {"192.168.1.20:47989/serverinfo": "serverinfo_vibepollo_http.xml"}
	var s := _make(false)
	s.add_manual("192.168.1.20")
	eq(s.launch(UUID, {"id": 1, "title": "Desktop"})["why"], s.T.NEED_MOONLIGHT, "no Moonlight")
	s.moonlight = {"kind": "native", "program": "/usr/bin/moonlight", "prefix": [], "config": "", "cache": ""}
	eq(s.launch(UUID, {"id": 1, "title": "Desktop"})["why"], s.T.NOT_PAIRED, "not paired")
	eq(spawn.spawned.size(), 0, "nothing started")
	after_each(s)


func test_install_moonlight() -> void:
	var s := _make(false)
	eq(s.has_moonlight(), false, "missing")
	runner.handler = func(cmd: String) -> Variant:
		if cmd.contains("flatpak install"):
			DirAccess.make_dir_recursive_absolute(root + HOME + "/.local/share/flatpak/app/" + Moonlight.FLATPAK_ID + "/current")
		if cmd.begins_with("/usr/bin/flatpak"):
			return {"code": 0, "out": ""}
		return null
	ok(s.install_moonlight(), "started")
	ok(runner.called("/usr/bin/flatpak remote-add --user --if-not-exists flathub"), "user remote")
	ok(runner.called("/usr/bin/flatpak install --user --noninteractive -y flathub com.moonlight_stream.Moonlight"), "user install, no password")
	eq(s.has_moonlight(), true, "found after install")
	ok(signals.any(func(x): return x is Array and x[0] == "install" and x[1] == "done"), "done")
	after_each(s)


func test_install_failure() -> void:
	var s := _make(false)
	runner.handler = func(cmd: String) -> Variant:
		return {"code": 1, "out": "error: Unable to load summary from remote flathub: Could not resolve hostname"} if cmd.begins_with("/usr/bin/flatpak") else null
	s.install_moonlight()
	var last: Array = signals.filter(func(x): return x is Array and x[0] == "install").back()
	eq(last[1], "failed", "failed")
	ok(str(last[2]).contains("Could not resolve"), "flatpak's reason shown")
	after_each(s)


func test_sleep_pc() -> void:
	answers = {"192.168.1.20:47989/serverinfo": "serverinfo_vibepollo_http.xml",
		"192.168.1.20:47984/serverinfo": "serverinfo_vibepollo_https.xml",
		"192.168.1.20:47984/applist": "applist.xml", "/appasset": "art.png",
		"power-actions/v1/sleep": _fx(0, "{\"status\":\"accepted\"}", 202)}
	var s := _make(true, true)
	s.refresh()
	ok(s.can_sleep(UUID), "allowed")
	ok(s.sleep_pc(UUID), "sent")
	eq(s.host(UUID)["status"], "asleep", "asleep")
	ok(runner.calls.any(func(c): return c.contains("-X POST") and c.contains("power-actions/v1/sleep")), "POST")
	after_each(s)


func test_game_running_and_idle() -> void:
	var s := _make()
	eq(runner.calls.size(), 0, "nothing runs at setup")
	s.set_active(false)
	eq(runner.calls.size(), 0, "nor while the tab is closed")
	runner.responses["vainfo --display drm"] = {"code": 0, "file": _f("vainfo_rdna2.txt")}
	runner.responses["avahi-browse -rpt _nvstream._tcp"] = {"code": 0, "out": ""}
	s.set_active(true)
	eq(s.decode["av1"], false, "vainfo read when the tab opens")
	s.set_active(true)
	eq(runner.calls.filter(func(c): return c.begins_with("vainfo")).size(), 1, "once")
	s.set_game_running(true)
	ok(s._game_running, "flag")
	after_each(s)


## A job still running when the service leaves the tree (GameCove quits with the
## Stream tab's network probe going) used to outlive the engine: a heap crash at
## exit ("double free or corruption"). Leaving the tree now stops it and waits.
## Found by the end-to-end suite (Stream tab visited, then the app quits).
func test_leaving_the_tree_waits_for_a_running_job() -> void:
	var s: Node = _make()
	s.sync_mode = false
	s.force_threads = true   # the test runner's root isn't "in the tree" yet
	var box := {"started": false, "done": false, "stopped_early": false}
	s._run(func():
		box["started"] = true
		var t0 := Time.get_ticks_msec()
		while Time.get_ticks_msec() - t0 < 3000:
			if s._quitting:
				box["stopped_early"] = true
				break
			OS.delay_msec(5)
		box["done"] = true
		return {})
	s._run(func():
		box["second"] = true
		return {})
	var t0 := Time.get_ticks_msec()
	while not box["started"] and Time.get_ticks_msec() - t0 < 2000:
		OS.delay_msec(5)
	ok(box["started"], "the job runs on a worker")
	s.stop_jobs()   # what _exit_tree does
	ok(box["done"], "leaving the tree waited for the running job")
	ok(box["stopped_early"], "and told it to stop early")
	ok(not box.has("second"), "queued jobs don't start any more")
	eq(s._task, -1, "no task left behind")
	s.free()


func test_probe_stops_when_asked() -> void:
	var calls := [0]
	var t0 := Time.get_ticks_msec()
	var out: Array = Streaming.tcp_probe(PackedStringArray(["10.255.255.1"]), 47989, func():
		calls[0] += 1
		return true)
	ok(Time.get_ticks_msec() - t0 < Streaming.PROBE_TIMEOUT_MS, "returns before its timeout")
	eq(out, [], "nothing found")
	ok(calls[0] >= 1, "asked whether to stop")
