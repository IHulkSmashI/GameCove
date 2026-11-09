extends Node
## Streaming: play games from a PC running Vibepollo (or Apollo / Sunshine) on
## this handheld through Moonlight. Finds PCs, pairs, reads their apps with box
## art, wakes them, starts a stream sized for this screen and hands it to the
## GameSession like any other game. See docs/STREAMING.md.
##
## Every call returns at once. Process and network work runs one job at a time
## on a WorkerThreadPool task (sync_mode runs it inline, for tests); results
## come back on the main thread as signals. Nothing polls while the Streaming
## page is closed: set_active(true) (page open) checks the PCs every
## CHECK_INTERVAL_S, and only while no game or stream runs.
##
## ctx (setup): {"runner": run(program, args) -> {code, out}, "spawn": object with
## spawn(cmd: Array) -> pid, kill(pid), running(pid) -> bool, "home", "path_env",
## "sys_root", "runtime_dir", "data_dir" (default user://streaming), "display":
## {"width", "height", "hz", "hdr"}, "gpu_family", "probe": func(addresses, port) -> Array
## (responding addresses; default TCP connect), "send": WoL sender (tests), "clock":
## func() -> int unix seconds, "reaper": path of the app-id wrapper ("" = none)}.

const SettingsFile := preload("res://scripts/system/settings_file.gd")
const DeviceScript := preload("res://scripts/device/device.gd")
signal changed
signal apps_changed(host_id: String)
## state: "waiting" (info: {"pin", "url", "name"}) | "paired" | "failed" (info: {"why"}) | "cancelled"
signal pair_changed(host_id: String, state: String, info: Dictionary)
## state: "running" | "done" | "failed"; line: what's happening / why it failed
signal install_changed(state: String, line: String)
signal notice(text: String, tone: String)

const GameStream := preload("res://scripts/streaming/gamestream.gd")
const Moonlight := preload("res://scripts/streaming/moonlight.gd")
const HostApi := preload("res://scripts/streaming/host_api.gd")
const Wol := preload("res://scripts/streaming/wol.gd")
const StreamSettings := preload("res://scripts/streaming/stream_settings.gd")
const T := preload("res://scripts/ui/texts_streaming.gd")

const CHECK_INTERVAL_S := 15.0
const PAIR_POLL_S := 2.0
const PAIR_TIMEOUT_S := 180.0
const WAKE_POLL_S := 4.0
const WAKE_WAIT_S := 90.0
const PROBE_TIMEOUT_MS := 700
const STORE := "stream"
## Where GameCove installs its app-id wrapper (packaging/libexec/reaper).
const REAPER_PATH := "/usr/libexec/gamecove/reaper"

var ctx := {}
var sync_mode := false
## id -> host. id is the PC's GameStream uniqueid once known, else "addr:<address>".
var hosts := {}
## Moonlight.locate() result; kind "" = not installed.
var moonlight := {"kind": ""}
## {"h264", "hevc", "hevc10", "av1"} this handheld can decode.
var decode := {}
var install_state := "idle"
var discovering := false

var _jobs: Array = []
var _busy := false
var _task := -1          # the WorkerThreadPool task running a job, -1 when none
var _quitting := false   # leaving the tree: running jobs stop early, none start
## Tests: jobs on the worker pool even outside the scene tree.
var force_threads := false
var _active := false
var _check_timer: Timer
var _pair := {}            # {"host", "pid", "pin", "started", "timer"}
var _waking := {}          # host id -> deadline (unix)
var _wake_timer: Timer
var _picks := ConfigFile.new()
var _identity := {}        # {"cert", "key"} file paths
var _game_running := false
var _stream_pid := 0
var _decode_checked := false


func setup(c: Dictionary) -> void:
	ctx = c.duplicate()
	if not ctx.has("data_dir"):
		ctx["data_dir"] = "user://streaming"
	if not ctx.has("clock"):
		ctx["clock"] = func() -> int: return int(Time.get_unix_time_from_system())
	if not ctx.has("reaper"):
		ctx["reaper"] = REAPER_PATH if FileAccess.file_exists(REAPER_PATH) else ""
	if not ctx.has("spawn"):
		ctx["spawn"] = load("res://scripts/streaming/spawner.gd").new()
	DirAccess.make_dir_recursive_absolute(_dir())
	_load()
	locate_moonlight()
	decode = StreamSettings.decode_for_family(str(ctx.get("gpu_family", "")))
	_decode_checked = false


## What this handheld decodes, asked once (vainfo) the first time the tab opens;
## the GPU family's table until then and where vainfo is missing.
func _check_decode() -> void:
	if _decode_checked:
		return
	_decode_checked = true
	_run(func(): return _r("vainfo", ["--display", "drm"]), func(res: Dictionary):
		if int(res.get("code", 1)) == 0 and str(res.get("out", "")).contains("VAProfile"):
			decode = StreamSettings.parse_vainfo(str(res["out"])))


func _ready() -> void:
	_check_timer = Timer.new()
	_check_timer.wait_time = CHECK_INTERVAL_S
	_check_timer.timeout.connect(func():
		if not _game_running:
			check_all())
	add_child(_check_timer)
	_wake_timer = Timer.new()
	_wake_timer.wait_time = WAKE_POLL_S
	_wake_timer.timeout.connect(_on_wake_tick)
	add_child(_wake_timer)


func _dir() -> String:
	return str(ctx["data_dir"])


func now() -> int:
	return int(ctx["clock"].call())


func _r(program: String, args: Array) -> Dictionary:
	var runner: Object = ctx.get("runner")
	if runner == null:
		return {"code": 127, "out": ""}
	return runner.run(program, PackedStringArray(args.map(func(a): return str(a))))


func _rc(cmd: Array) -> Dictionary:
	return _r(str(cmd[0]), cmd.slice(1))


# ---------------------------------------------------------------- jobs

## One job at a time off the main thread: work() -> result, then done(result) on the main thread.
func _run(work: Callable, done: Callable = Callable()) -> void:
	_jobs.append([work, done])
	_pump()


func _pump() -> void:
	if _busy or _jobs.is_empty() or _quitting:
		return
	var j: Array = _jobs.pop_front()
	_busy = true
	if sync_mode or not (is_inside_tree() or force_threads):
		var res: Variant = j[0].call()
		_busy = false
		if j[1].is_valid():
			j[1].call(res)
		_pump()
		return
	_task = WorkerThreadPool.add_task(func():
		var res: Variant = j[0].call()
		_finish_job.call_deferred(j[1], res), false, "GameCove streaming job")


func _finish_job(done: Callable, res: Variant) -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	_busy = false
	if done.is_valid():
		done.call(res)
	_pump()


func is_busy() -> bool:
	return _busy or not _jobs.is_empty()


# ---------------------------------------------------------------- page / session

## The Streaming page is showing: check the PCs now and every CHECK_INTERVAL_S.
func set_active(on: bool) -> void:
	_active = on
	if on:
		_refresh_display()
	if _check_timer != null and _check_timer.is_inside_tree():
		if on:
			_check_timer.start()
		else:
			_check_timer.stop()
	if on:
		_check_decode()
		refresh()


## main.gd: a game or stream has the screen; no checks meanwhile.
func set_game_running(on: bool) -> void:
	_game_running = on


# ---------------------------------------------------------------- Moonlight

func locate_moonlight() -> Dictionary:
	moonlight = Moonlight.locate(str(ctx.get("home", "")), str(ctx.get("path_env", "")), str(ctx.get("sys_root", "")))
	return moonlight


func has_moonlight() -> bool:
	return str(moonlight.get("kind", "")) != ""


## One-time Flatpak install of Moonlight for this user (no password, so it works
## in Gaming Mode). Progress through install_changed.
func install_moonlight() -> bool:
	if install_state == "running":
		return false
	var flatpak := _flatpak_bin()
	if flatpak == "":
		install_changed.emit("failed", T.INSTALL_NO_FLATPAK)
		return false
	install_state = "running"
	install_changed.emit("running", T.INSTALL_RUNNING)
	_run(func():
		for cmd in Moonlight.install_commands(flatpak):
			var r := _rc(cmd)
			if int(r["code"]) != 0:
				return {"ok": false, "why": _last_line(str(r["out"]))}
		return {"ok": true, "why": ""},
		func(res: Dictionary):
			locate_moonlight()
			var ok: bool = res["ok"] and has_moonlight()
			install_state = "done" if ok else "failed"
			install_changed.emit(install_state, T.INSTALL_DONE if ok else (str(res["why"]) if str(res["why"]) != "" else T.INSTALL_FAILED))
			changed.emit())
	return true


func _flatpak_bin() -> String:
	var root := str(ctx.get("sys_root", ""))
	for d in str(ctx.get("path_env", "")).split(":", false):
		if FileAccess.file_exists(root + d.path_join("flatpak")):
			return d.path_join("flatpak")
	return ""


static func _last_line(s: String) -> String:
	var lines := s.strip_edges().split("\n", false)
	return lines[lines.size() - 1].strip_edges() if lines.size() > 0 else ""


## Moonlight's client certificate as files curl can use (0600, in the runtime
## folder, which only this user can read). {} until Moonlight has made one.
func _ensure_identity() -> Dictionary:
	if not _identity.is_empty() and FileAccess.file_exists(str(_identity["cert"])):
		return _identity
	var conf := Moonlight.read_conf(str(moonlight.get("config", "")))
	if str(conf["cert"]) == "" or str(conf["key"]) == "":
		return {}
	var base := str(ctx.get("runtime_dir", ""))
	base = str(ctx.get("sys_root", "")) + base if base != "" else ProjectSettings.globalize_path(_dir())
	var d := base.path_join("gamecove-stream")
	DirAccess.make_dir_recursive_absolute(d)
	var paths := {"cert": d.path_join("client.pem"), "key": d.path_join("client.key")}
	for k in paths:
		var f := FileAccess.open(paths[k], FileAccess.WRITE)
		if f == null:
			return {}
		f.store_string(str(conf[k]))
		f.close()
		FileAccess.set_unix_permissions(paths[k], FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER)
	_identity = paths
	return _identity


func _exit_tree() -> void:
	stop_jobs()
	cancel_pair()


## A job still running (a network probe takes seconds) would outlive the engine
## and crash GameCove on its way out: tell it to stop early, drop the queued
## ones and wait for it. Leaving the tree does this.
func stop_jobs() -> void:
	_quitting = true
	_jobs.clear()
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	_busy = false
	for k in _identity:
		DirAccess.remove_absolute(str(_identity[k]))


# ---------------------------------------------------------------- hosts

static func blank_host(id: String) -> Dictionary:
	return {"id": id, "uuid": "", "name": "", "addresses": [], "address": "", "port": GameStream.HTTP_PORT,
		"https_port": GameStream.HTTPS_PORT, "mac": "", "manual": false, "source": "",
		"status": "unknown", "paired": false, "latency_ms": -1, "remote": false, "flavor": "",
		"version": "", "current_app": 0, "permission": -1, "last_seen": 0, "apps": [],
		"apps_state": "none", "info": {}, "sleep_allowed": false}


## Hosts in the order the page shows them: online first, then by name.
func host_list() -> Array:
	var out: Array = hosts.values()
	var rank := {"busy": 0, "online": 0, "waking": 1, "asleep": 2, "checking": 2, "unknown": 3, "offline": 3}
	out.sort_custom(func(a, b):
		var ra: int = rank.get(a["status"], 3)
		var rb: int = rank.get(b["status"], 3)
		if ra != rb:
			return ra < rb
		return str(a["name"]).naturalnocasecmp_to(str(b["name"])) < 0)
	return out


func host(id: String) -> Dictionary:
	return hosts.get(id, {})


func display_name(h: Dictionary) -> String:
	if str(h.get("name", "")) != "":
		return str(h["name"])
	return str(h.get("address", h.get("id", "")))


## Find the host that is `uuid` or has `address`; "" when new.
func _find(uuid: String, address: String) -> String:
	if uuid != "" and hosts.has(uuid):
		return uuid
	for id in hosts:
		var h: Dictionary = hosts[id]
		if address != "" and address in h["addresses"]:
			return id
	return ""


## Merge what we learned into the host list. Returns the host's id.
func _merge(uuid: String, address: String, fields: Dictionary) -> String:
	var id := _find(uuid, address)
	if id == "":
		id = uuid if uuid != "" else "addr:" + address
		hosts[id] = blank_host(id)
	elif uuid != "" and id != uuid:
		# an address-only host turned out to be this PC
		var old: Dictionary = hosts[id]
		hosts.erase(id)
		if hosts.has(uuid):
			for a in old["addresses"]:
				if not a in hosts[uuid]["addresses"]:
					hosts[uuid]["addresses"].append(a)
			hosts[uuid]["manual"] = hosts[uuid]["manual"] or old["manual"]
		else:
			old["id"] = uuid
			hosts[uuid] = old
		_move_picks(id, uuid)
		id = uuid
	var h: Dictionary = hosts[id]
	if uuid != "":
		h["uuid"] = uuid
	if address != "" and not address in h["addresses"]:
		h["addresses"].append(address)
	for k in fields:
		if k == "addresses":
			for a in fields[k]:
				if not a in h["addresses"]:
					h["addresses"].append(a)
		elif k == "mac":
			if str(fields[k]) != "":
				h["mac"] = fields[k]
		elif k == "name":
			if str(fields[k]) != "":
				h["name"] = fields[k]
		elif k == "manual":
			h["manual"] = h["manual"] or bool(fields[k])
		else:
			h[k] = fields[k]
	if str(h["address"]) == "" and not (h["addresses"] as Array).is_empty():
		h["address"] = h["addresses"][0]
	h["remote"] = not GameStream.is_lan(str(h["address"])) and str(h["address"]) != ""
	return id


## Find PCs (mDNS, else a port probe of this network), add the ones Moonlight
## already knows, then check every PC. Emits changed as answers come in.
func refresh() -> void:
	if discovering:
		return
	discovering = true
	changed.emit()
	var conf_path := str(moonlight.get("config", ""))
	_run(func(): return _discover_job(conf_path, hosts.is_empty()), func(res: Dictionary):
		for m in res["known"]:
			_merge(str(m["uuid"]), "", {"name": m["name"], "mac": m["mac"], "addresses": m["addresses"],
				"paired": m["paired"], "source": "moonlight"})
		for f in res["found"]:
			_merge(str(f.get("uuid", "")), str(f["address"]), {"name": f.get("name", ""), "port": int(f.get("port", GameStream.HTTP_PORT)),
				"source": str(f.get("source", "mdns"))})
		discovering = false
		_save()
		changed.emit()
		check_all())


func _discover_job(conf_path: String, allow_probe: bool) -> Dictionary:
	var known: Array = Moonlight.read_conf(conf_path)["hosts"] if conf_path != "" else []
	var found: Array = []
	var r := _r("avahi-browse", ["-rpt", GameStream.MDNS_SERVICE])
	if int(r["code"]) == 0:
		for e in GameStream.parse_avahi(str(r["out"])):
			found.append({"address": e["address"], "name": e["name"], "port": e["port"], "source": "mdns"})
	if found.is_empty() and known.is_empty() and allow_probe:
		found = _probe_job()
	return {"known": known, "found": found}


## No mDNS answer and no PCs yet: try the GameStream port on every address of
## this network (/22 or smaller), then ask the ones that answer who they are.
func _probe_job() -> Array:
	var out: Array = []
	var r := _r("ip", ["-o", "-4", "addr", "show"])
	if int(r["code"]) != 0:
		return out
	var probe: Callable = ctx.get("probe", Callable())
	if not probe.is_valid():
		probe = func(addrs: PackedStringArray, port: int) -> Array: return tcp_probe(addrs, port, func(): return _quitting)
	for net in GameStream.parse_ip_addr(str(r["out"])):
		if _quitting:
			break
		var addrs := GameStream.subnet_hosts(str(net["address"]), int(net["prefix"]))
		for a in probe.call(addrs, GameStream.HTTP_PORT):
			if _quitting:
				break
			var info := _serverinfo_job(str(a), GameStream.HTTP_PORT)
			if not info.is_empty():
				out.append({"address": a, "uuid": info["uuid"], "name": info["name"], "port": GameStream.HTTP_PORT, "source": "probe"})
	return out


## Which of `addresses` accept a TCP connection on `port`, all tried at once, for
## up to PROBE_TIMEOUT_MS. Runs on the worker.
static func tcp_probe(addresses: PackedStringArray, port: int, should_stop := Callable()) -> Array:
	var peers := {}
	for a in addresses:
		var p := StreamPeerTCP.new()
		if p.connect_to_host(a, port) == OK:
			peers[a] = p
	var out: Array = []
	var start := Time.get_ticks_msec()
	while not peers.is_empty() and Time.get_ticks_msec() - start < PROBE_TIMEOUT_MS:
		if should_stop.is_valid() and bool(should_stop.call()):
			break
		for a in peers.keys():
			var p: StreamPeerTCP = peers[a]
			p.poll()
			var s := p.get_status()
			if s == StreamPeerTCP.STATUS_CONNECTED:
				out.append(a)
				p.disconnect_from_host()
				peers.erase(a)
			elif s == StreamPeerTCP.STATUS_ERROR or s == StreamPeerTCP.STATUS_NONE:
				peers.erase(a)
		OS.delay_msec(15)
	for p in peers.values():
		p.disconnect_from_host()
	return out


func _serverinfo_job(address: String, port: int) -> Dictionary:
	var res := HostApi.split(_rc(HostApi.serverinfo_http(address, port)))
	if not res["ok"]:
		return {}
	var info := GameStream.parse_serverinfo(str(res["body"]))
	if not info.is_empty():
		info["ms"] = res["ms"]
	return info


## Check every PC (one job each, in order).
func check_all() -> void:
	for id in hosts.keys():
		check_host(id)


## Is this PC there, is it busy, how far away; paired PCs also give their MAC.
func check_host(id: String) -> void:
	if not hosts.has(id):
		return
	var h: Dictionary = hosts[id]
	if h["status"] in ["unknown", "offline"]:
		h["status"] = "checking"
	var addrs: Array = (h["addresses"] as Array).duplicate()
	if str(h["address"]) != "":
		addrs.erase(h["address"])
		addrs.push_front(h["address"])
	var port := int(h["port"])
	var paired := bool(h["paired"])
	_run(func(): return _check_job(addrs, port, paired), func(res: Dictionary): _apply_check(id, res))


func _check_job(addrs: Array, port: int, paired: bool) -> Dictionary:
	for a in addrs:
		var info := _serverinfo_job(str(a), port)
		if info.is_empty():
			continue
		var out := {"address": a, "info": info, "secure": {}}
		var ident := _ensure_identity() if paired else {}
		if not ident.is_empty():
			var s := HostApi.split(_rc(HostApi.serverinfo_https(str(a), int(info["https_port"]), ident)))
			if s["ok"]:
				out["secure"] = GameStream.parse_serverinfo(str(s["body"]), true)
		return out
	# not answering: maybe the ARP cache still knows its MAC
	var arp_path := str(ctx.get("sys_root", "")) + "/proc/net/arp"
	# /proc reports a size of 0: read to the real end (get_file_as_string() gives "")
	var arp_file := FileAccess.open(arp_path, FileAccess.READ) if FileAccess.file_exists(arp_path) else null
	var arp := DeviceScript.read_all(arp_file) if arp_file != null else ""
	return {"address": "", "arp": GameStream.parse_arp(arp), "addrs": addrs}


func _apply_check(id: String, res: Dictionary) -> void:
	if not hosts.has(id):
		return
	if str(res.get("address", "")) == "":
		var h: Dictionary = hosts[id]
		for a in res.get("addrs", []):
			if res["arp"].has(a) and str(h["mac"]) == "":
				h["mac"] = res["arp"][a]
		h["status"] = "waking" if _waking.has(id) else ("asleep" if str(h["mac"]) != "" else "offline")
		h["latency_ms"] = -1
		h["current_app"] = 0
		_save()
		changed.emit()
		return
	var info: Dictionary = res["info"]
	var sec: Dictionary = res["secure"]
	var fields := {"name": info["name"], "port": info["http_port"], "https_port": info["https_port"],
		"latency_ms": info.get("ms", -1), "flavor": info["flavor"], "version": info["version"],
		"info": info, "last_seen": now(), "address": res["address"]}
	if not sec.is_empty():
		fields["paired"] = true
		fields["mac"] = sec["mac"]
		fields["current_app"] = sec["current_app"]
		fields["permission"] = sec["permission"]
		fields["sleep_allowed"] = sec["sleep_allowed"]
		fields["flavor"] = sec["flavor"]
		fields["status"] = "busy" if int(sec["current_app"]) > 0 else "online"
	else:
		fields["current_app"] = 0
		fields["status"] = "online"
		if bool(hosts[id]["paired"]) and has_moonlight():
			# Moonlight's certificate was refused: the PC forgot this handheld
			fields["paired"] = _conf_says_paired(str(info["uuid"]))
	var was_waking := _waking.has(id)
	_waking.erase(id)
	var nid := _merge(str(info["uuid"]), str(res["address"]), fields)
	if was_waking:
		notice.emit(T.WOKE % display_name(hosts[nid]), "good")
	_save()
	changed.emit()
	var h: Dictionary = hosts[nid]
	if bool(h["paired"]) and h["apps_state"] == "none":
		load_apps(nid)


func _conf_says_paired(uuid: String) -> bool:
	for m in Moonlight.read_conf(str(moonlight.get("config", "")))["hosts"]:
		if str(m["uuid"]) == uuid:
			return bool(m["paired"])
	return false


## A PC by address: LAN IP, name, Tailscale address. Returns "" when queued,
## else why it can't be an address. The PC is kept even when it doesn't answer
## yet (asleep, or a remote PC behind a VPN that isn't up).
func add_manual(text: String) -> String:
	var a := GameStream.parse_address(text)
	if a.is_empty():
		return T.BAD_ADDRESS
	var address := str(a["address"])
	var port := int(a["port"])
	_run(func(): return _serverinfo_job(address, port), func(info: Dictionary):
		var id := _merge(str(info.get("uuid", "")), address, {"manual": true, "port": port,
			"name": info.get("name", ""), "source": "manual"})
		hosts[id]["address"] = address
		hosts[id]["remote"] = not GameStream.is_lan(address)
		_save()
		changed.emit()
		if info.is_empty():
			notice.emit(T.ADDED_OFFLINE % address, "warn")
		check_host(id))
	return ""


## Forget a PC here (Moonlight and the PC keep their pairing).
func remove_host(id: String) -> void:
	if hosts.erase(id):
		_waking.erase(id)
		_save()
		changed.emit()


# ---------------------------------------------------------------- apps

## The PC's apps with box art, through Moonlight's certificate (curl), falling
## back to `moonlight list --csv`. Art is cached in data_dir/art/<uuid>/<id>.png.
func load_apps(id: String) -> void:
	if not hosts.has(id) or not has_moonlight():
		return
	var h: Dictionary = hosts[id]
	h["apps_state"] = "loading"
	apps_changed.emit(id)
	var address := str(h["address"])
	var https_port := int(h["https_port"])
	var uuid := str(h["uuid"])
	var art_dir := ProjectSettings.globalize_path(_dir().path_join("art").path_join(uuid.validate_filename()))
	var m := moonlight.duplicate()
	_run(func(): return _apps_job(address, https_port, uuid, art_dir, m), func(res: Dictionary):
		if not hosts.has(id):
			return
		var hh: Dictionary = hosts[id]
		hh["apps_state"] = res["state"]
		if res["state"] == "ready" or res["state"] == "denied":
			hh["apps"] = res["apps"]
		if res["state"] == "unpaired":
			hh["paired"] = false
			hh["apps_state"] = "none"
		_save()
		apps_changed.emit(id)
		changed.emit())


func _apps_job(address: String, https_port: int, uuid: String, art_dir: String, m: Dictionary) -> Dictionary:
	var apps: Array = []
	var ident := _ensure_identity()
	var state := "error"
	if not ident.is_empty():
		var r := HostApi.split(_rc(HostApi.applist(address, https_port, ident)))
		if r["ok"]:
			var parsed := GameStream.parse_applist(str(r["body"]))
			if parsed["ok"]:
				state = "denied" if parsed["denied"] else "ready"
				apps = parsed["apps"]
		elif int(r["code"]) == 401 or int(r["code"]) == 403:
			state = "unpaired"
	if state == "error":
		var r2 := _rc(Moonlight.command(m, Moonlight.list_args(address)))
		if int(r2["code"]) == 0:
			apps = GameStream.parse_list_csv(str(r2["out"]))
			state = "ready"
		elif str(r2["out"]).contains("has not been paired"):
			state = "unpaired"
	if state != "ready":
		return {"state": state, "apps": []}
	DirAccess.make_dir_recursive_absolute(art_dir)
	for app in apps:
		var file := art_dir.path_join("%d.png" % int(app["id"]))
		if not FileAccess.file_exists(file):
			var cached := str(app.get("art", ""))
			if cached == "" or not FileAccess.file_exists(cached):
				cached = Moonlight.cached_art(m, uuid, int(app["id"]))
			if cached != "":
				DirAccess.copy_absolute(cached, file)
			elif not ident.is_empty():
				var tmp := file + ".part"
				var a := HostApi.split(_rc(HostApi.appasset(address, https_port, ident, int(app["id"]), tmp)))
				if a["ok"] and _is_image(tmp):
					DirAccess.rename_absolute(tmp, file)
				else:
					DirAccess.remove_absolute(tmp)
		app["art"] = file if FileAccess.file_exists(file) else ""
	return {"state": "ready", "apps": apps}


static func _is_image(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null or f.get_length() < 8:
		return false
	var head := f.get_buffer(4)
	return (head[0] == 0x89 and head[1] == 0x50) or (head[0] == 0xFF and head[1] == 0xD8)


## The app as a game for GameSession, tiles and the quick menu.
func game_for(id: String, app: Dictionary) -> Dictionary:
	var h := host(id)
	return {"key": "%s:%s:%d" % [STORE, str(h.get("uuid", id)), int(app.get("id", 0))],
		"store": STORE, "id": str(app.get("id", 0)), "title": str(app.get("title", "")),
		"installed": true, "playtime_min": 0, "last_played": 0,
		"art": {"cover": str(app.get("art", "")), "hero": "", "logo": "", "icon": ""}, "info": {},
		"stream": {"host": id, "host_name": display_name(h), "app_id": int(app.get("id", 0)), "hdr": bool(app.get("hdr", false))}}


func app_by_id(id: String, app_id: int) -> Dictionary:
	for a in host(id).get("apps", []):
		if int(a["id"]) == app_id:
			return a
	return {}


# ---------------------------------------------------------------- pairing

## Starts pairing: a fresh 4-digit PIN to type into the PC's web UI. Moonlight
## runs `pair --pin` without a window; we watch its settings for the PC's
## certificate. pair_changed reports each step.
func pair(id: String) -> bool:
	if not hosts.has(id) or not has_moonlight() or not _pair.is_empty():
		return false
	var h: Dictionary = hosts[id]
	var pin := "%04d" % (randi() % 10000)
	var cmd := Moonlight.command(moonlight, Moonlight.pair_args(str(h["address"]), pin), {"QT_QPA_PLATFORM": "offscreen"})
	var pid := int(ctx["spawn"].spawn(cmd))
	if pid <= 0:
		pair_changed.emit(id, "failed", {"why": T.PAIR_NO_START})
		return false
	_pair = {"host": id, "pid": pid, "pin": pin, "started": now(), "checking": false}
	if is_inside_tree():
		var t := Timer.new()
		t.wait_time = PAIR_POLL_S
		t.timeout.connect(poll_pair)
		add_child(t)
		t.start()
		_pair["timer"] = t
	pair_changed.emit(id, "waiting", {"pin": pin, "url": web_ui_url(h), "name": display_name(h)})
	return true


## https://<pc>:47990 (Vibepollo / Apollo / Sunshine web UI, PIN page under it).
static func web_ui_url(h: Dictionary) -> String:
	var port := int(h.get("port", GameStream.HTTP_PORT)) + 1
	return "https://%s:%d" % [GameStream.url_host(str(h.get("address", ""))), port]


func pairing_host() -> String:
	return str(_pair.get("host", ""))


func pairing_pin() -> String:
	return str(_pair.get("pin", ""))


## One look at Moonlight's settings for the PC's certificate (timer, or tests).
func poll_pair() -> void:
	if _pair.is_empty() or bool(_pair["checking"]):
		return
	var id := str(_pair["host"])
	var uuid := str(host(id).get("uuid", ""))
	var addr := str(host(id).get("address", ""))
	var conf_path := str(moonlight.get("config", ""))
	_pair["checking"] = true
	_run(func():
		for m in Moonlight.read_conf(conf_path)["hosts"]:
			if (uuid != "" and str(m["uuid"]) == uuid) or (uuid == "" and addr in m["addresses"]):
				return {"paired": bool(m["paired"]), "mac": m["mac"], "uuid": m["uuid"]}
		return {"paired": false},
		func(res: Dictionary):
			if _pair.is_empty() or str(_pair["host"]) != id:
				return
			_pair["checking"] = false
			if bool(res["paired"]):
				_end_pair()
				var nid := _merge(str(res["uuid"]), addr, {"paired": true, "mac": res.get("mac", "")})
				_save()
				pair_changed.emit(nid, "paired", {})
				changed.emit()
				check_host(nid)
				load_apps(nid)
			elif now() - int(_pair["started"]) > PAIR_TIMEOUT_S:
				_end_pair()
				pair_changed.emit(id, "failed", {"why": T.PAIR_TIMEOUT})
			elif not bool(ctx["spawn"].running(int(_pair["pid"]))):
				_end_pair()
				pair_changed.emit(id, "failed", {"why": T.PAIR_STOPPED}))


func cancel_pair() -> void:
	if _pair.is_empty():
		return
	var id := str(_pair["host"])
	_end_pair()
	pair_changed.emit(id, "cancelled", {})


func _end_pair() -> void:
	if _pair.is_empty():
		return
	if ctx.has("spawn") and bool(ctx["spawn"].running(int(_pair["pid"]))):
		ctx["spawn"].kill(int(_pair["pid"]))
	if _pair.has("timer") and is_instance_valid(_pair["timer"]):
		_pair["timer"].queue_free()
	_pair = {}


# ---------------------------------------------------------------- wake / sleep

func can_wake(id: String) -> bool:
	return str(host(id).get("mac", "")) != ""


## Wake-on-LAN, then watch for the PC (every WAKE_POLL_S for up to WAKE_WAIT_S).
func wake(id: String) -> bool:
	if not can_wake(id):
		return false
	var h: Dictionary = hosts[id]
	var mac := str(h["mac"])
	var addrs: Array = (h["addresses"] as Array).duplicate()
	var port := int(h["port"])
	var send: Callable = ctx.get("send", Callable())
	_waking[id] = now() + int(WAKE_WAIT_S)
	h["status"] = "waking"
	changed.emit()
	_run(func():
		var r := _r("ip", ["-o", "-4", "addr", "show"])
		var brd: Array = []
		for n in GameStream.parse_ip_addr(str(r.get("out", ""))):
			brd.append(n["broadcast"])
		return Wol.wake(mac, addrs, port, brd, send),
		func(ok: bool):
			if not ok:
				_waking.erase(id)
				if hosts.has(id):
					hosts[id]["status"] = "asleep"
				notice.emit(T.WAKE_FAILED, "bad")
				changed.emit()
			elif _wake_timer != null and _wake_timer.is_inside_tree():
				_wake_timer.start())
	return true


func _on_wake_tick() -> void:
	if _waking.is_empty():
		_wake_timer.stop()
		return
	for id in _waking.keys():
		if now() > int(_waking[id]):
			_waking.erase(id)
			if hosts.has(id) and hosts[id]["status"] == "waking":
				hosts[id]["status"] = "asleep"
				notice.emit(T.WAKE_NO_ANSWER % display_name(hosts[id]), "warn")
				changed.emit()
		else:
			check_host(id)


func can_sleep(id: String) -> bool:
	var h := host(id)
	return bool(h.get("sleep_allowed", false)) and h.get("status", "") in ["online", "busy"]


## Vibepollo: put the PC to sleep (when it lets this handheld).
func sleep_pc(id: String) -> bool:
	if not can_sleep(id):
		return false
	var h: Dictionary = hosts[id]
	var address := str(h["address"])
	var port := int(h["https_port"])
	_run(func():
		var ident := _ensure_identity()
		return HostApi.split(_rc(HostApi.sleep_pc(address, port, ident))) if not ident.is_empty() else {"ok": false},
		func(res: Dictionary):
			if bool(res["ok"]) or int(res.get("code", 0)) == 202:
				if hosts.has(id):
					hosts[id]["status"] = "asleep"
				notice.emit(T.SLEEPING % display_name(host(id)), "good")
			else:
				notice.emit(T.SLEEP_FAILED, "bad")
			changed.emit())
	return true


# ---------------------------------------------------------------- streaming

## Starts the stream. Returns Library.launch()'s shape for GameSession.begin:
## {"ok", "app_id", "pid", "scoped", "why", "settings"}. Moonlight runs in a
## systemd scope named for its app id, behind a small "reaper" wrapper so
## gamescope finds the app id even for the Flatpak (which moves itself into its
## own scope): gamescope reads it from the cgroup, else from a parent process
## named reaper with "SteamLaunch AppId=<id>" (gamescope src/Utils/Process.cpp).
func launch(id: String, app: Dictionary) -> Dictionary:
	var out := {"ok": false, "app_id": 0, "pid": 0, "scoped": false, "why": "", "settings": {}}
	var h := host(id)
	if h.is_empty():
		out["why"] = T.NO_HOST
		return out
	if not has_moonlight():
		out["why"] = T.NEED_MOONLIGHT
		return out
	if not bool(h["paired"]):
		out["why"] = T.NOT_PAIRED
		return out
	_refresh_display()
	var s := resolved(id, int(app.get("id", 0)))
	out["settings"] = s
	var cmd: Array = Moonlight.command(moonlight, Moonlight.stream_args(str(h["address"]), str(app.get("title", "")), s))
	var game := game_for(id, app)
	var app_id := app_id_for(str(game["key"]))
	var reaper := str(ctx.get("reaper", ""))
	if reaper != "":
		cmd = [reaper, "SteamLaunch", "AppId=%d" % app_id, "--"] + cmd
	var systemd_run := _which("systemd-run")
	var runtime := str(ctx.get("runtime_dir", ""))
	if systemd_run != "" and runtime != "" and DirAccess.dir_exists_absolute(str(ctx.get("sys_root", "")) + runtime.path_join("systemd")):
		cmd = [systemd_run, "--user", "--scope", "--collect", "--quiet",
			"--unit=app-steam-app%d-%d" % [app_id, now() % 100000000], "--"] + cmd
		out["scoped"] = true
	var pid := int(ctx["spawn"].spawn(cmd))
	_stream_pid = maxi(pid, 0)
	out["ok"] = pid > 0
	out["pid"] = maxi(pid, 0)
	out["app_id"] = app_id if (pid > 0 and (out["scoped"] or reaper != "")) else 0
	if not out["ok"]:
		out["why"] = T.STREAM_NO_START
	return out


func _which(name: String) -> String:
	var root := str(ctx.get("sys_root", ""))
	for d in str(ctx.get("path_env", "")).split(":", false):
		if FileAccess.file_exists(root + d.path_join(name)):
			return d.path_join(name)
	return ""


## The same ids Library gives games it starts itself (bit 30 set, from sha256).
static func app_id_for(key: String) -> int:
	return (key.sha256_text().substr(0, 8).hex_to_int() & 0x3FFFFFFF) | 0x40000000


## Ends the stream (Exit game): stops our wrapper and, for the Flatpak, which
## moved itself out of our scope, `flatpak kill`. The game keeps running on the
## PC, so it can be resumed; quit_app() ends it there.
func stop_stream() -> void:
	if _stream_pid > 0 and bool(ctx["spawn"].running(_stream_pid)):
		ctx["spawn"].kill(_stream_pid)
	_stream_pid = 0
	if str(moonlight.get("kind", "")) == "flatpak":
		ctx["spawn"].spawn([str(moonlight["program"]), "kill", Moonlight.FLATPAK_ID])


## The screen as it is now (HDR may have been switched since start-up).
func _refresh_display() -> void:
	var fn: Variant = ctx.get("display_fn")
	if fn is Callable and fn.is_valid():
		ctx["display"] = fn.call()


## Quit the app running on the PC (the stream itself ends with Exit game).
func quit_app(id: String) -> bool:
	var h := host(id)
	if h.is_empty() or not has_moonlight():
		return false
	var cmd := Moonlight.command(moonlight, Moonlight.quit_args(str(h["address"])), {"QT_QPA_PLATFORM": "offscreen"})
	var pid := int(ctx["spawn"].spawn(cmd))
	if pid <= 0:
		return false
	if is_inside_tree():
		get_tree().create_timer(4.0).timeout.connect(func():
			if bool(ctx["spawn"].running(pid)):
				ctx["spawn"].kill(pid)
			check_host(id))
	return true


# ---------------------------------------------------------------- settings

func picks_for(id: String, app_id := 0) -> Dictionary:
	var sec := _section(id, app_id)
	var out := {}
	if _picks.has_section(sec):
		for k in _picks.get_section_keys(sec):
			out[k] = _picks.get_value(sec, k)
	return out


func has_app_picks(id: String, app_id: int) -> bool:
	return app_id > 0 and _picks.has_section(_section(id, app_id))


## A pick for the PC (app_id 0) or for one app on it.
func set_pick(id: String, key: String, value: Variant, app_id := 0) -> void:
	if not StreamSettings.DEFAULTS.has(key):
		return
	_picks.set_value(_section(id, app_id), key, value)
	_save_picks()


## Per-app picks start as a copy of the PC's; clearing them goes back to the PC's.
func set_app_override(id: String, app_id: int, on: bool) -> void:
	var sec := _section(id, app_id)
	if on and not _picks.has_section(sec):
		var base := StreamSettings.merged(picks_for(id), {}, bool(host(id).get("remote", false)))
		for k in base:
			_picks.set_value(sec, k, base[k])
	elif not on and _picks.has_section(sec):
		_picks.erase_section(sec)
	_save_picks()


## Picks with defaults: the app's when it has its own, else the PC's.
func effective_picks(id: String, app_id := 0) -> Dictionary:
	var app_layer := picks_for(id, app_id) if has_app_picks(id, app_id) else {}
	return StreamSettings.merged(picks_for(id), app_layer, bool(host(id).get("remote", false)))


## What Moonlight gets for this PC (and app).
func resolved(id: String, app_id := 0) -> Dictionary:
	var info: Dictionary = host(id).get("info", {})
	var hostcaps := {"hevc": info.get("hevc", true), "av1": info.get("av1", false), "hdr": info.get("hdr", false)}
	return StreamSettings.resolve(effective_picks(id, app_id), ctx.get("display", {}), decode, hostcaps)


func hdr_available(id: String) -> bool:
	var info: Dictionary = host(id).get("info", {})
	return StreamSettings.hdr_possible(ctx.get("display", {}), decode, {"hdr": info.get("hdr", false)})


func _section(id: String, app_id: int) -> String:
	var uuid := str(host(id).get("uuid", id))
	if uuid == "":
		uuid = id
	return ("host:%s" % uuid) if app_id <= 0 else ("app:%s:%d" % [uuid, app_id])


func _move_picks(old_id: String, new_uuid: String) -> void:
	var prefix := "host:" + old_id
	for sec in _picks.get_sections():
		if sec == prefix:
			for k in _picks.get_section_keys(sec):
				_picks.set_value("host:" + new_uuid, k, _picks.get_value(sec, k))
			_picks.erase_section(sec)
	_save_picks()


# ---------------------------------------------------------------- storage

const SAVED := ["id", "uuid", "name", "addresses", "address", "port", "https_port", "mac", "manual",
	"source", "paired", "flavor", "version", "last_seen", "apps", "info", "sleep_allowed", "remote"]


func _save() -> void:
	var list: Array = []
	for h in hosts.values():
		var e := {}
		for k in SAVED:
			e[k] = h.get(k)
		list.append(e)
	SettingsFile.save_json(_dir().path_join("hosts.json"), {"schema": 1, "hosts": list}, "\t")


func _save_picks() -> void:
	SettingsFile.save_cfg(_picks, _dir().path_join("settings.cfg"))


func _load() -> void:
	hosts = {}
	var path := _dir().path_join("hosts.json")
	if FileAccess.file_exists(path):
		var data: Variant = SettingsFile.load_json(path)["data"]
		if data is Dictionary and data.get("hosts") is Array:
			for e in data["hosts"]:
				if not e is Dictionary or str(e.get("id", "")) == "":
					continue
				var h := blank_host(str(e["id"]))
				for k in SAVED:
					if e.has(k) and e[k] != null:
						h[k] = e[k]
				h["port"] = int(h["port"])
				h["https_port"] = int(h["https_port"])
				h["apps_state"] = "ready" if not (h["apps"] as Array).is_empty() else "none"
				for a in h["apps"]:
					a["id"] = int(a.get("id", 0))
				hosts[h["id"]] = h
	_picks = SettingsFile.load_cfg(_dir().path_join("settings.cfg"))
