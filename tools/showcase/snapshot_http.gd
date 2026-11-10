extends RefCounted
## http.gd's interface (request(url, opts, done), is_offline()) for the
## showcase, in three modes:
##   "record"  every request goes out through curl (proxy settings from the
##             environment) and its answer is saved under `dir` with a
##             manifest, so a later "replay" gives the app the same answers.
##   "replay"  answers only from the manifest (no network); anything not
##             recorded fails as offline.
##   "live"    curl, saved under `dir` too, then answered from there next time
##             (the art cache: images are fetched once and kept).
## `pinned` maps a URL prefix to a file answered instead of the network (the
## showcase's cut of CheapShark's deals and the release calendar).
## Callbacks run synchronously, like fake_http.gd.

const UA := "GameCove/showcase (+https://github.com/IHulkSmashI/GameCove)"

var mode := "replay"
var dir := ""
var pinned := {}
var manifest := {"routes": {}}
var requests: Array[String] = []
var _offline := false


func _init(p_mode: String, p_dir: String, p_pinned := {}) -> void:
	mode = p_mode
	dir = p_dir.trim_suffix("/")
	pinned = p_pinned
	DirAccess.make_dir_recursive_absolute(dir)
	var m := dir + "/manifest.json"
	if FileAccess.file_exists(m):
		var j = JSON.parse_string(FileAccess.get_file_as_string(m))
		if j is Dictionary and j.get("routes") is Dictionary:
			manifest = j


func is_offline() -> bool:
	return _offline


func save_manifest(extra := {}) -> void:
	manifest.merge(extra, true)
	var f := FileAccess.open(dir + "/manifest.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(manifest, " ", true))
	f.close()


func request(url: String, opts: Dictionary, done: Callable) -> void:
	requests.append(url)
	var body := PackedByteArray()
	var code := 0
	var best := ""
	for p in pinned:
		if url.begins_with(p) and p.length() > best.length():
			best = p
	if best != "":
		body = FileAccess.get_file_as_bytes(pinned[best])
		code = 200
	elif manifest["routes"].has(url) and mode != "record":
		var r: Dictionary = manifest["routes"][url]
		code = int(r["code"])
		body = FileAccess.get_file_as_bytes(dir + "/" + str(r["file"])) if str(r["file"]) != "" else PackedByteArray()
	elif mode == "replay":
		_offline = true
		done.call({"ok": false, "code": 0, "body": PackedByteArray(), "error": "offline", "retry_after": 0})
		return
	else:
		var got := _curl(url, opts)
		code = got[0]
		body = got[1]
		if code == 0:
			_offline = true
			done.call({"ok": false, "code": 0, "body": PackedByteArray(), "error": "offline", "retry_after": 0})
			return
		var ext := url.get_file().get_extension().get_slice("?", 0).to_lower()
		if not ext in ["jpg", "png", "webp", "gz", "json"]:
			ext = "bin"
		var file := "%s.%s" % [url.sha1_text().substr(0, 16), ext] if code >= 200 and code < 300 else ""
		if file != "":
			var f := FileAccess.open(dir + "/" + file, FileAccess.WRITE)
			f.store_buffer(body)
			f.close()
		manifest["routes"][url] = {"code": code, "file": file}
		save_manifest()
	_offline = false
	var ok := code >= 200 and code < 300
	if int(opts.get("max_bytes", 0)) > 0 and body.size() > int(opts["max_bytes"]):
		done.call({"ok": false, "code": code, "body": PackedByteArray(), "error": "too big", "retry_after": 0})
		return
	var res := {"ok": ok, "code": code, "body": body, "error": "" if ok else "http %d" % code, "retry_after": 0}
	if ok and str(opts.get("download_file", "")) != "":
		var f := FileAccess.open(opts["download_file"], FileAccess.WRITE)
		if f:
			f.store_buffer(body)
			f.close()
		res["body"] = PackedByteArray()
	done.call(res)


## [code, body] through curl; code 0 when it couldn't connect.
func _curl(url: String, opts: Dictionary) -> Array:
	var tmp := OS.get_cache_dir().path_join("gamecove-showcase-%d.part" % (randi() % 1000000))
	var args := PackedStringArray(["-sS", "-L", "--max-time", str(int(opts.get("timeout", 40.0))), "-A", UA,
		"-H", "Accept: */*", "-o", tmp, "-w", "%{http_code}"])
	for h in opts.get("headers", []):
		if not str(h).to_lower().begins_with("authorization"):
			args.append_array(["-H", str(h)])
	args.append(url)
	var out: Array = []
	OS.execute("curl", args, out, true)
	var code := str(out[0] if not out.is_empty() else "").strip_edges().right(3).to_int()
	var body := FileAccess.get_file_as_bytes(tmp) if FileAccess.file_exists(tmp) else PackedByteArray()
	DirAccess.remove_absolute(tmp)
	return [code, body]
