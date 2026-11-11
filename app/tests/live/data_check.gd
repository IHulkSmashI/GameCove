extends SceneTree
## Live check of the app's data downloads against the real GameCove-data releases (NOT a test: it uses the network,
## so it's never part of the gates). Each check runs the app's own code end to end, with only temp folders swapped in:
##   gamedb    GameDb.update_if_stale(): HTTPRequest download of DataRepo.GAMEDB_URL, accept_download(), `updated`
##   calendar  Discover._step_calendar() through http.gd: DataRepo.UPCOMING_URL, Calendar.load_file()
##   photos    DevicePhoto.photo_for() through http.gd for every device in the published manifest: manifest
##             parse (licence allowlist), download, size + sha256 check (store_part), `photo_ready`
##   firmware  Updates.load_index() with the real command runner: curl, .sha256, cosign verify-blob with the pinned
##             identity (firmware_index.gd), index_verified()
##   fixes     FixData.fetch_steps() with the real command runner: curl of DataRepo.FIXES_URL and its bundle, cosign
##             verify-blob as DataRepo.FIXES_SIGNER, FixData.accept() and merge() over the bundled definitions
## usage (tools/data_check/run.sh sets it up):
##   godot --headless --path app -s res://tests/live/data_check.gd -- <work dir> [gamedb] [calendar] [photos] [firmware] [fixes]
## It lives under res://tests/ so the app's autoloads stay idle (no device reads, no background requests of their own);
## it isn't a test file (only res://tests/test_*.gd run in the unit suite).
## Behind an HTTPS proxy (HTTPS_PROXY, and GAMECOVE_CA_BUNDLE for a proxy that re-signs TLS) the app's HTTPRequests
## are pointed at it when they're created; on a handheld nothing of the sort is needed.

const DataRepo := preload("res://scripts/system/data_repo.gd")
const GameDbScript := preload("res://scripts/library/gamedb.gd")
const DiscoverScript := preload("res://scripts/discover/discover.gd")
const HttpScript := preload("res://scripts/discover/http.gd")
const PhotoSvc := preload("res://scripts/device/photo.gd")
const UpdatesScript := preload("res://scripts/system/updates.gd")
const CommandRunner := preload("res://scripts/device/command_runner.gd")
const Cal := preload("res://scripts/discover/calendar.gd")
const Index := preload("res://scripts/system/firmware_index.gd")
const FixData := preload("res://scripts/device/fix_data.gd")

var work := ""
var failures: Array[String] = []
var _proxy_host := ""
var _proxy_port := 0
var _ca: X509Certificate = null


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		printerr("usage: -- <work dir> [gamedb] [calendar] [photos] [firmware] [fixes]")
		quit(2)
		return
	work = args[0]
	var which: Array = Array(args.slice(1))
	if which.is_empty():
		which = ["gamedb", "calendar", "photos", "firmware", "fixes"]
	_proxy_from_env()
	_run.call_deferred(which)


func _proxy_from_env() -> void:
	var p := OS.get_environment("HTTPS_PROXY")
	if p == "":
		p = OS.get_environment("https_proxy")
	if p != "":
		var hostport := p.trim_prefix("http://").trim_prefix("https://").trim_suffix("/")
		_proxy_host = hostport.get_slice(":", 0)
		_proxy_port = int(hostport.get_slice(":", 1))
	var ca := OS.get_environment("GAMECOVE_CA_BUNDLE")
	if ca != "" and FileAccess.file_exists(ca):
		_ca = X509Certificate.new()
		if _ca.load(ca) != OK:
			_ca = null


## Every HTTPRequest `n` creates goes through the proxy (set before its request() call, which follows add_child).
func _proxied(n: Node) -> void:
	n.child_entered_tree.connect(func(c: Node):
		if c is HTTPRequest:
			if _proxy_host != "":
				c.set_https_proxy(_proxy_host, _proxy_port)
			if _ca != null:
				c.set_tls_options(TLSOptions.client(_ca)))


func _ok(cond: bool, what: String) -> void:
	print(("PASS " if cond else "FAIL ") + what)
	if not cond:
		failures.append(what)


func _wait(cond: Callable, seconds: float) -> bool:
	var end := Time.get_ticks_msec() + int(seconds * 1000)
	while not cond.call() and Time.get_ticks_msec() < end:
		await process_frame
	return cond.call()


func _run(which: Array) -> void:
	DirAccess.make_dir_recursive_absolute(work)
	for w in which:
		match w:
			"gamedb": await _gamedb()
			"calendar": await _calendar()
			"photos": await _photos()
			"firmware": _firmware()
			"fixes": _fixes()
			_: _ok(false, "unknown check " + str(w))
	print("%d failed" % failures.size())
	# let the freed HTTPRequests go first, and drop the CA before the TLS module shuts down
	for i in 3:
		await process_frame
	_ca = null
	quit(1 if failures.size() > 0 else 0)


func _gamedb() -> void:
	var g: Node = GameDbScript.new()
	g.cache_path = work.path_join("gamedb.json.gz")
	_proxied(g)
	root.add_child(g)
	var got := [false]
	g.updated.connect(func(): got[0] = true)
	g.update_if_stale()
	await _wait(func(): return got[0], 300.0)
	_ok(got[0], "gamedb: %s downloaded and accepted by GameDb (accept_download)" % GameDbScript.URL)
	var doc: Dictionary = GameDbScript.load_file(g.cache_path)
	var n: int = doc.get("games", []).size()
	_ok(n > 1000, "gamedb: %d games, built %s" % [n, doc.get("built", "?")])
	g.queue_free()


func _calendar() -> void:
	var http: Node = HttpScript.new()
	_proxied(http)
	root.add_child(http)
	var d: Node = DiscoverScript.new()
	d.http = http
	d.data_dir = work.path_join("discover")
	d.privacy_path = work.path_join("discover/settings.cfg")
	d.home = work
	d.detected_region = {"country": "US", "source": "default"}
	d.load_all()
	var done := [false]
	d._step_calendar(func(): done[0] = true)
	await _wait(func(): return done[0], 180.0)
	_ok(done[0] and d.status.get("calendar", "") == "ok",
		"calendar: %s downloaded and loaded by Discover (status %s)" % [Cal.URL, d.status.get("calendar", "none")])
	var cal: Dictionary = d.get("_upcoming")
	_ok(int(cal.get("count", 0)) > 0, "calendar: %d releases, built %s" % [int(cal.get("count", 0)), cal.get("built", "?")])
	d.free()
	http.queue_free()


func _photos() -> void:
	var http: Node = HttpScript.new()
	_proxied(http)
	root.add_child(http)
	var p: Node = PhotoSvc.new()
	p.http = http
	p.cache_dir = work.path_join("device_photos")
	p.prefs_path = work.path_join("photo_settings.cfg")
	p.bundled_sources = {}          # only the published free photos, never a picture shipped in the app
	p.maker_sources = {}            # nor a maker's image
	p.maker_enabled = false
	var ready := {}
	p.photo_ready.connect(func(id: String, path: String): ready[id] = path)
	# the first ask fetches and parses the manifest, then downloads that device's photo
	p.photo_for("steam-deck-lcd")
	await _wait(func(): return p.get("_manifest_loaded") and not p.get("_manifest_fetching"), 60.0)
	var manifest: Dictionary = p.get("_manifest")
	_ok(not manifest.is_empty(), "photos: %smanifest.json parsed (%d devices pass the licence allowlist)" % [PhotoSvc.RELEASE, manifest.size()])
	for id in manifest:
		p.photo_for(id)
	await _wait(func(): return ready.size() >= manifest.size() or p.get("_failed").size() + ready.size() >= manifest.size(), 300.0)
	for id in manifest:
		var path: String = ready.get(id, "")
		var e: Dictionary = manifest[id]
		_ok(path != "" and FileAccess.get_sha256(path) == e["sha256"],
			"photos: %s (%s, %s) downloaded, size and sha256 checked" % [id, e["asset"], e["credit"]["license"]])
	p.free()
	http.queue_free()


func _firmware() -> void:
	var u: Node = UpdatesScript.new()
	u.cache_dir = work.path_join("firmware")
	var fsroot := work.path_join("fsroot")      # no /sys, no NetworkManager: downloads are allowed
	DirAccess.make_dir_recursive_absolute(fsroot)
	u.setup(CommandRunner.new(), fsroot, OS.get_environment("HOME"), OS.get_environment("PATH"))
	_ok(u._cosign() != "", "firmware: cosign found (%s)" % u._cosign())
	var index: Dictionary = u.load_index()
	_ok(not index.is_empty(), "firmware: %s downloaded, sha256 matched and parsed (%d devices, built %s)" % [
		Index.URL, index.get("devices", {}).size(), index.get("built", "?")])
	_ok(u.index_verified(), "firmware: cosign verify-blob accepted the signature as %s (issuer %s)" % [
		Index.SIGNER_IDENTITY, Index.OIDC_ISSUER])
	u.free()


func _fixes() -> void:
	var u: Node = UpdatesScript.new()   # only for the cosign it finds (the same lookup fixes.gd makes)
	var fsroot := work.path_join("fsroot")
	DirAccess.make_dir_recursive_absolute(fsroot)
	u.setup(CommandRunner.new(), fsroot, OS.get_environment("HOME"), OS.get_environment("PATH"))
	var cos: String = u._cosign()
	u.free()
	_ok(cos != "", "fixes: cosign found (%s)" % cos)
	var dir := work.path_join("fixes")
	DirAccess.make_dir_recursive_absolute(dir)
	var runner = CommandRunner.new()
	var names := ["fixes.json", "its .sigstore.json", "cosign verify-blob as %s" % FixData.SIGNER_IDENTITY]
	var steps: Array = FixData.fetch_steps(dir, cos)
	for i in steps.size():
		var r: Dictionary = runner.run(steps[i][0], steps[i][1])
		_ok(int(r.get("code", 1)) == 0, "fixes: %s (%s)" % [names[i], FixData.URL if i < 2 else "exit %d" % int(r.get("code", 1))])
		if int(r.get("code", 1)) != 0:
			FixData.discard(dir)
			return
	var got := FixData.accept(dir)
	_ok(got == "verified", "fixes: accepted (%s)" % got)
	var doc := FixData.cached(dir)
	var merged: Array = FixData.merge(FixData.bundled()["fixes"], doc)
	_ok(not merged.is_empty(), "fixes: serial %d, built %s, %d fixes after merging over the built-in list" % [
		FixData.serial(doc), str(doc.get("built", "?")), merged.size()])
