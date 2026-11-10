extends Node
## "Send to phone" for a clip: a one-time web page on your own network, shown
## as a QR code. The phone opens it, can watch the clip and taps Download. The
## same idea and the same safety rules as the key page (key_drop.gd), whose
## pure parts this reuses:
##   - listens only while start() .. stop(), on one LAN address (never on all
##     interfaces), on a random port the system picks;
##   - every address carries a one-time token (128 random bits); anything else
##     gets 404, and past KeyDrop.MAX_BAD wrong requests a minute new
##     connections are closed unanswered for the rest of that minute;
##   - serves exactly one file, read-only; the page has no scripts, no outside
##     resources, no caching, no referrer;
##   - closes by itself once the clip has been downloaded in full (sent()), or
##     after `lifetime` seconds (10 minutes) with nothing being sent.
## Plain HTTP on the local network: the clip crosses your Wi-Fi once. It never
## leaves your network through GameCove.
##
## The watch-on-the-page player asks for byte ranges (HTTP 206), so phones can
## seek; the Download link asks for the whole file with ?dl=1, which is the
## download that closes the page.
##
## Runs in _process only while the page is open (like the key page); nothing
## when it's closed.

signal sent
## why: "timeout"
signal expired(why: String)

const KeyDrop := preload("res://scripts/system/key_drop.gd")
const LIFETIME := 600.0
const CLIENT_TIMEOUT := 10.0
const MAX_REQUEST := 8192
const MAX_CLIENTS := 8
## Bytes written per client per frame at most (the socket takes what it can).
const CHUNK := 262144
const PER_FRAME := 8 * CHUNK

var lifetime := LIFETIME
## "" = this device's LAN address; tests use 127.0.0.1.
var bind_address := ""
var interfaces_fn: Callable = func() -> Array: return IP.get_local_interfaces()
var file_path := ""
var title := ""
var token := ""
var url := ""
var address := ""
var port := 0
var _server: TCPServer
var _clients: Array = []   # {"peer", "buf", "age", "file": FileAccess, "left": int, "full": bool, "head": PackedByteArray}
var _age := 0.0
var _bad_times: Array[float] = []


func _init() -> void:
	name = "ClipDrop"
	set_process(false)


func is_running() -> bool:
	return _server != null and _server.is_listening()


## Opens the page for one clip. False without a LAN address, a readable file or a port.
func start(path: String, clip_title := "") -> bool:
	stop()
	if not FileAccess.file_exists(path):
		return false
	address = bind_address if bind_address != "" else KeyDrop.pick_lan_ip(interfaces_fn.call())
	if address == "":
		return false
	_server = TCPServer.new()
	if _server.listen(0, address) != OK:
		_server = null
		return false
	file_path = path
	title = clip_title if clip_title != "" else path.get_file().get_basename()
	port = _server.get_local_port()
	token = KeyDrop.new_token()
	url = "http://%s:%d/c/%s" % [address, port, token]
	_age = 0.0
	_bad_times.clear()
	set_process(true)
	return true


func stop() -> void:
	for c in _clients:
		_close(c)
	_clients.clear()
	if _server != null:
		_server.stop()
	_server = null
	token = ""
	url = ""
	set_process(false)


func seconds_left() -> int:
	return maxi(0, int(ceil(lifetime - _age))) if is_running() else 0


func _process(delta: float) -> void:
	poll(delta)


## One step: accept, read, answer, send, time out. Tests call it directly.
func poll(delta: float) -> void:
	if not is_running():
		return
	_age += delta
	var sending := _clients.any(func(c): return c["file"] != null)
	if _age >= lifetime and not sending:
		stop()
		expired.emit("timeout")
		return
	while not _bad_times.is_empty() and _age - _bad_times[0] >= 60.0:
		_bad_times.pop_front()
	while _server != null and _server.is_connection_available():
		var peer := _server.take_connection()
		if _bad_times.size() >= KeyDrop.MAX_BAD or _clients.size() >= MAX_CLIENTS:
			peer.disconnect_from_host()
			continue
		_clients.append({"peer": peer, "buf": PackedByteArray(), "age": 0.0, "file": null, "left": 0, "full": false, "head": PackedByteArray()})
	for c in _clients.duplicate():
		if not is_running():
			return
		_serve(c, delta)


func _close(c: Dictionary) -> void:
	if c["file"] != null:
		(c["file"] as FileAccess).close()
		c["file"] = null
	(c["peer"] as StreamPeerTCP).disconnect_from_host()


func _serve(c: Dictionary, delta: float) -> void:
	var peer: StreamPeerTCP = c["peer"]
	peer.poll()
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_close(c)
		_clients.erase(c)
		return
	if c["file"] != null or not (c["head"] as PackedByteArray).is_empty():
		_send_more(c)
		return
	c["age"] = float(c["age"]) + delta
	var n := mini(peer.get_available_bytes(), MAX_REQUEST + 1 - (c["buf"] as PackedByteArray).size())
	if n > 0:
		var got: Array = peer.get_data(n)
		if int(got[0]) == OK:
			var grown: PackedByteArray = c["buf"]
			grown.append_array(got[1])
			c["buf"] = grown
	var buf: PackedByteArray = c["buf"]
	var req := KeyDrop.parse_request(buf)
	if req.is_empty() and buf.size() <= MAX_REQUEST and float(c["age"]) < CLIENT_TIMEOUT:
		return
	if req.is_empty():
		_close(c)
		_clients.erase(c)
		return
	var ans := respond(req, token, title, FileAccess.get_size(file_path))
	if int(ans["status"]) == 404:
		_bad_times.append(_age)
	if ans.has("range"):
		var f := FileAccess.open(file_path, FileAccess.READ)
		if f == null:
			ans = {"status": 404, "headers": {"Content-Type": "text/plain; charset=utf-8"}, "body": "Not found".to_utf8_buffer()}
		else:
			var r: Array = ans["range"]
			f.seek(int(r[0]))
			c["file"] = f
			c["left"] = int(r[1]) - int(r[0]) + 1
			c["full"] = bool(ans.get("full", false))
	c["head"] = http_head(int(ans["status"]), ans["headers"], ans.get("body", PackedByteArray()))
	if str(req.get("method", "")) == "HEAD" and c["file"] != null:
		(c["file"] as FileAccess).close()
		c["file"] = null
		c["left"] = 0
	_send_more(c)


## Writes the headers, then file bytes, as far as the socket takes them this frame.
func _send_more(c: Dictionary) -> void:
	var peer: StreamPeerTCP = c["peer"]
	var budget := PER_FRAME
	var head: PackedByteArray = c["head"]
	if not head.is_empty():
		var r: Array = peer.put_partial_data(head)
		if int(r[0]) != OK:
			_close(c)
			_clients.erase(c)
			return
		c["head"] = head.slice(int(r[1]))
		if not (c["head"] as PackedByteArray).is_empty():
			return
	var f: FileAccess = c["file"]
	while f != null and int(c["left"]) > 0 and budget > 0:
		var want := mini(CHUNK, int(c["left"]))
		var pos := f.get_position()
		var data := f.get_buffer(want)
		if data.is_empty():
			break
		var r: Array = peer.put_partial_data(data)
		if int(r[0]) != OK:
			_close(c)
			_clients.erase(c)
			return
		var put := int(r[1])
		c["left"] = int(c["left"]) - put
		budget -= put
		if put < data.size():
			f.seek(pos + put)   # the socket is full: the rest next frame
			return
	if int(c["left"]) <= 0:
		var whole: bool = c["full"] and c["file"] != null
		_close(c)
		_clients.erase(c)
		if whole:
			stop()
			sent.emit()


# ---- pure parts (tests) --------------------------------------------------------

## What to answer: {"status", "headers", "body"?, "range": [first, last]?, "full": bool}.
static func respond(req: Dictionary, tok: String, clip_title: String, size: int) -> Dictionary:
	var path := str(req.get("path", ""))
	var query := ""
	var q := path.find("?")
	if q >= 0:
		query = path.substr(q + 1)
		path = path.substr(0, q)
	var html := {"Content-Type": "text/html; charset=utf-8"}
	if tok == "" or size <= 0:
		return {"status": 404, "headers": html, "body": "Not found".to_utf8_buffer()}
	var method := str(req.get("method", ""))
	if not method in ["GET", "HEAD"]:
		return {"status": 405, "headers": html, "body": "Not allowed".to_utf8_buffer()}
	if KeyDrop.same_token(path, "/c/" + tok):
		return {"status": 200, "headers": html, "body": page(clip_title, tok, size).to_utf8_buffer()}
	if not KeyDrop.same_token(path, "/c/" + tok + "/clip.mp4"):
		return {"status": 404, "headers": html, "body": "Not found".to_utf8_buffer()}
	var headers := {"Content-Type": "video/mp4", "Accept-Ranges": "bytes"}
	var download := query.split("&").has("dl=1")
	if download:
		headers["Content-Disposition"] = "attachment; filename=\"%s\"; filename*=UTF-8''%s" % [ascii_name(clip_title), (clip_title + ".mp4").uri_encode()]
	var range := parse_range(str((req.get("headers", {}) as Dictionary).get("range", "")), size)
	if range.is_empty():
		headers["Content-Length"] = str(size)
		return {"status": 200, "headers": headers, "range": [0, size - 1], "full": download}
	if range[0] < 0:
		headers["Content-Range"] = "bytes */%d" % size
		return {"status": 416, "headers": headers, "body": PackedByteArray()}
	headers["Content-Range"] = "bytes %d-%d/%d" % [range[0], range[1], size]
	headers["Content-Length"] = str(range[1] - range[0] + 1)
	return {"status": 206, "headers": headers, "range": range, "full": download and range[0] == 0 and range[1] == size - 1}


## "bytes=a-b" / "bytes=a-" / "bytes=-n" -> [first, last]; [] without a range
## header; [-1, -1] when it can't be satisfied. Only one range.
static func parse_range(value: String, size: int) -> Array:
	var v := value.strip_edges().to_lower()
	if not v.begins_with("bytes="):
		return []
	var spec := v.substr(6)
	if spec.contains(","):
		return []
	var dash := spec.find("-")
	if dash < 0:
		return [-1, -1]
	var a := spec.substr(0, dash).strip_edges()
	var b := spec.substr(dash + 1).strip_edges()
	if a == "" and b.is_valid_int():
		var n := mini(int(b), size)
		return [size - n, size - 1] if n > 0 else [-1, -1]
	if not a.is_valid_int():
		return [-1, -1]
	var first := int(a)
	var last := int(b) if b.is_valid_int() else size - 1
	last = mini(last, size - 1)
	if first >= size or first > last:
		return [-1, -1]
	return [first, last]


## The file name without anything but plain ASCII (for old clients).
static func ascii_name(clip_title: String) -> String:
	var s := ""
	for ch in clip_title:
		var c := ch.unicode_at(0)
		s += ch if c >= 32 and c < 127 and ch != "\"" and ch != "\\" else "_"
	return (s.strip_edges() if s.strip_edges() != "" else "clip") + ".mp4"


static func http_head(status: int, headers: Dictionary, body: PackedByteArray) -> PackedByteArray:
	var reason: String = {200: "OK", 206: "Partial Content", 404: "Not Found", 405: "Method Not Allowed",
		416: "Range Not Satisfiable"}.get(status, "OK")
	var h := "HTTP/1.1 %d %s\r\n" % [status, reason]
	var all := headers.duplicate()
	if not all.has("Content-Length"):
		all["Content-Length"] = str(body.size())
	all["Cache-Control"] = "no-store"
	all["Referrer-Policy"] = "no-referrer"
	all["X-Content-Type-Options"] = "nosniff"
	all["Content-Security-Policy"] = "default-src 'none'; style-src 'unsafe-inline'; media-src 'self'; frame-ancestors 'none'"
	all["Connection"] = "close"
	for k in all:
		h += "%s: %s\r\n" % [k, all[k]]
	h += "\r\n"
	var out := h.to_utf8_buffer()
	out.append_array(body)
	return out


## The phone page: the clip to watch and a Download button.
static func page(clip_title: String, tok: String, size: int) -> String:
	var css := "body{font-family:system-ui,sans-serif;background:#0b1020;color:#eef2ff;margin:0;padding:20px;line-height:1.45}" \
		+ "main{max-width:640px;margin:auto}h1{font-size:1.3em;margin:0 0 4px}.q{color:#9aa6c8;font-size:.9em;margin:0 0 14px}" \
		+ "video{width:100%;border-radius:12px;background:#000}" \
		+ "a.btn{display:block;box-sizing:border-box;text-align:center;padding:14px;border-radius:12px;font-size:1.05em;font-weight:600;margin:14px 0;text-decoration:none;background:#4f8cff;color:#fff}"
	var src := "/c/%s/clip.mp4" % tok
	var SizeText = load("res://scripts/system/clips.gd")
	return "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" \
		+ "<meta name=\"referrer\" content=\"no-referrer\"><title>GameCove clip</title><style>" + css + "</style></head><body><main>" \
		+ "<h1>" + clip_title.xml_escape() + "</h1><p class=\"q\">" + SizeText.size_text(size) + " · MP4 video</p>" \
		+ "<video controls playsinline preload=\"metadata\" src=\"" + src + "\"></video>" \
		+ "<a class=\"btn\" href=\"" + src + "?dl=1\" download>Download to this phone</a>" \
		+ "<p class=\"q\">This page closes once the clip is downloaded, or after 10 minutes. It only works on your own network.</p>" \
		+ "</main></body></html>"


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE or what == NOTIFICATION_EXIT_TREE:
		stop()
