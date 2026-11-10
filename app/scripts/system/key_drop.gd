extends Node
## "Send the key from your phone": a tiny one-time web page GameCove serves on
## your own network while the Game art step is open. There's no browser in
## Gaming Mode and typing a 32-character key with a controller is no fun, so
## the step shows a QR code of this page; the phone opens it, the person
## pastes their SteamGridDB key and taps Send, and the key arrives here.
##
## Safety (docs/PRIVACY.md, "Game art: the phone page"):
##   - listens only while start() .. stop(), on one LAN address (never on all
##     interfaces), on a random port the system picks;
##   - every address carries a one-time token (128 random bits); anything else
##     gets 404, and after MAX_BAD wrong requests the page closes;
##   - closes by itself after the first well-formed key, or after `lifetime`
##     seconds (10 minutes);
##   - a request has 10 s and 8 KiB to arrive; at most MAX_CLIENTS at once;
##   - a POST from another site (an Origin that isn't this page) is refused;
##   - the page has no scripts, no outside resources, no caching, no referrer.
## Plain HTTP on the local network: the key crosses your Wi-Fi once, like the
## QR sign-in codes. It never leaves your network through GameCove.
##
##   var drop := KeyDrop.new()
##   add_child(drop)
##   drop.key_received.connect(func(k): ...)
##   if drop.start(): show_qr(drop.url)

signal key_received(key: String)
## why: "timeout" (lifetime passed) | "too_many" (MAX_BAD wrong requests)
signal expired(why: String)

const LIFETIME := 600.0
const CLIENT_TIMEOUT := 10.0
const MAX_REQUEST := 8192
const MAX_CLIENTS := 4
const MAX_BAD := 30
const SGDB_API_PAGE := "https://www.steamgriddb.com/profile/preferences/api"

var lifetime := LIFETIME
## "" = pick this device's LAN address (IP.get_local_interfaces()); tests use 127.0.0.1.
var bind_address := ""
## Tests: the interface list pick_lan_ip() reads.
var interfaces_fn: Callable = func() -> Array: return IP.get_local_interfaces()
var token := ""
var url := ""
var port := 0
var address := ""
var bad_requests := 0

var _server: TCPServer
var _clients: Array = []   # [{"peer": StreamPeerTCP, "buf": PackedByteArray, "age": float}]
var _age := 0.0


func _init() -> void:
	name = "KeyDrop"
	set_process(false)


func is_running() -> bool:
	return _server != null and _server.is_listening()


## Opens the page. False when this device has no LAN address or can't listen.
func start() -> bool:
	stop()
	address = bind_address if bind_address != "" else pick_lan_ip(interfaces_fn.call())
	if address == "":
		return false
	_server = TCPServer.new()
	if _server.listen(0, address) != OK:
		_server = null
		return false
	port = _server.get_local_port()
	token = new_token()
	url = "http://%s:%d/k/%s" % [address, port, token]
	_age = 0.0
	bad_requests = 0
	set_process(true)
	return true


func stop() -> void:
	for c in _clients:
		(c["peer"] as StreamPeerTCP).disconnect_from_host()
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


## One step: accept, read, answer, time out. _process calls it; tests call it directly.
func poll(delta: float) -> void:
	if not is_running():
		return
	_age += delta
	if _age >= lifetime:
		stop()
		expired.emit("timeout")
		return
	while _server != null and _server.is_connection_available():
		var peer := _server.take_connection()
		if _clients.size() >= MAX_CLIENTS:
			peer.disconnect_from_host()
			continue
		_clients.append({"peer": peer, "buf": PackedByteArray(), "age": 0.0})
	for c in _clients.duplicate():
		if not is_running():
			return
		_serve(c, delta)


func _serve(c: Dictionary, delta: float) -> void:
	var peer: StreamPeerTCP = c["peer"]
	peer.poll()
	c["age"] = float(c["age"]) + delta
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_clients.erase(c)
		return
	var n := mini(peer.get_available_bytes(), MAX_REQUEST + 1 - (c["buf"] as PackedByteArray).size())
	if n > 0:
		var got: Array = peer.get_data(n)
		if int(got[0]) == OK:
			var grown: PackedByteArray = c["buf"]   # packed arrays are values: write it back
			grown.append_array(got[1])
			c["buf"] = grown
	var buf: PackedByteArray = c["buf"]
	var req := parse_request(buf)
	if req.is_empty() and buf.size() <= MAX_REQUEST and float(c["age"]) < CLIENT_TIMEOUT:
		return   # not all here yet
	var ans: Dictionary
	if req.is_empty():
		ans = {"status": 413 if buf.size() > MAX_REQUEST else 408, "body": page("Something went wrong. Scan the code on your handheld again.", false), "key": ""}
	else:
		ans = respond(req, token, origin())
	if int(ans["status"]) == 404:
		bad_requests += 1
	peer.put_data(http_response(int(ans["status"]), str(ans["body"])))
	peer.disconnect_from_host()
	_clients.erase(c)
	var key := str(ans["key"])
	if key != "":
		stop()
		key_received.emit(key)
	elif bad_requests >= MAX_BAD:
		stop()
		expired.emit("too_many")


## "http://<address>:<port>": the only Origin a form POST may come from.
func origin() -> String:
	return "http://%s:%d" % [address, port]


# ---- pure parts (tests) --------------------------------------------------------

## 32 hex characters from the system's secure random source.
static func new_token() -> String:
	return Crypto.new().generate_random_bytes(16).hex_encode()


## The LAN address to listen on: a private IPv4 (10/8, 172.16/12, 192.168/16)
## of a real interface, Wi-Fi first, then Ethernet, then anything else that
## isn't a container or VM bridge. "" when there's none (offline).
static func pick_lan_ip(interfaces: Array) -> String:
	var best := ""
	var best_rank := 99
	for i in interfaces:
		if not i is Dictionary:
			continue
		var nm := str(i.get("name", "")).to_lower()
		if nm == "lo" or nm.begins_with("docker") or nm.begins_with("br-") or nm.begins_with("virbr") \
				or nm.begins_with("veth") or nm.begins_with("tun") or nm.begins_with("tap") or nm.begins_with("podman"):
			continue
		var rank := 0 if nm.begins_with("wl") else (1 if nm.begins_with("en") or nm.begins_with("eth") else 2)
		for a in i.get("addresses", []):
			if is_private_ipv4(str(a)) and rank < best_rank:
				best = str(a)
				best_rank = rank
	return best


static func is_private_ipv4(a: String) -> bool:
	var p := a.split(".")
	if p.size() != 4:
		return false
	for x in p:
		if not x.is_valid_int() or int(x) < 0 or int(x) > 255:
			return false
	var b0 := int(p[0])
	var b1 := int(p[1])
	return b0 == 10 or (b0 == 172 and b1 >= 16 and b1 <= 31) or (b0 == 192 and b1 == 168)


## {"method", "path", "headers": {lowercase name: value}, "body": String} once
## the whole request is in `buf` ({} while it isn't, or when it's malformed).
static func parse_request(buf: PackedByteArray) -> Dictionary:
	var text := buf.get_string_from_ascii()
	var end := text.find("\r\n\r\n")
	if end < 0:
		return {}
	var lines := text.substr(0, end).split("\r\n")
	var first := lines[0].split(" ")
	if first.size() != 3 or not first[2].begins_with("HTTP/1."):
		return {}
	var headers := {}
	for l in lines.slice(1):
		var c := l.find(":")
		if c > 0:
			headers[l.substr(0, c).strip_edges().to_lower()] = l.substr(c + 1).strip_edges()
	var length := int(headers.get("content-length", "0")) if str(headers.get("content-length", "0")).is_valid_int() else -1
	if length < 0 or length > MAX_REQUEST:
		return {}
	var body_bytes := buf.slice(end + 4)
	if body_bytes.size() < length:
		return {}
	return {"method": first[0], "path": first[1], "headers": headers, "body": body_bytes.slice(0, length).get_string_from_utf8()}


## What to answer: {"status", "body", "key"} (key "" unless one arrived).
static func respond(req: Dictionary, tok: String, own_origin: String) -> Dictionary:
	var path := str(req.get("path", ""))
	if tok == "" or not same_token(path, "/k/" + tok):
		return {"status": 404, "body": "Not found", "key": ""}
	match str(req.get("method", "")):
		"GET":
			return {"status": 200, "body": page("", false), "key": ""}
		"POST":
			var o := str((req.get("headers", {}) as Dictionary).get("origin", ""))
			if o != "" and o != "null" and o != own_origin:
				return {"status": 403, "body": page("This page only takes keys sent from itself.", false), "key": ""}
			var k := key_from_form(str(req.get("body", "")))
			if k == "":
				return {"status": 400, "body": page("That doesn't look like a SteamGridDB key (32 letters and digits). Copy it again and paste it here.", false), "key": ""}
			return {"status": 200, "body": page("", true), "key": k}
	return {"status": 405, "body": "Not allowed", "key": ""}


## Compares the whole path in constant time (no early exit on the first difference).
static func same_token(a: String, b: String) -> bool:
	var x := a.to_utf8_buffer()
	var y := b.to_utf8_buffer()
	var diff := x.size() ^ y.size()
	for i in mini(x.size(), y.size()):
		diff |= x[i] ^ y[i]
	return diff == 0


## The key from a "key=..." form body: the first run of exactly 32 hex
## characters (a paste may carry spaces or a label around it). "" if none.
static func key_from_form(body: String) -> String:
	var raw := ""
	for pair in body.split("&"):
		if pair.begins_with("key="):
			raw = pair.substr(4).replace("+", " ").uri_decode()
	var m := RegEx.create_from_string("(?<![0-9A-Fa-f])[0-9A-Fa-f]{32}(?![0-9A-Fa-f])").search(raw)
	return m.get_string() if m != null else ""


static func http_response(status: int, body: String) -> PackedByteArray:
	var reason: String = {200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
		408: "Request Timeout", 413: "Payload Too Large"}.get(status, "OK")
	var b := body.to_utf8_buffer()
	var head := "HTTP/1.1 %d %s\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: %d\r\n" % [status, reason, b.size()] \
		+ "Cache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\n" \
		+ "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'\r\n" \
		+ "Connection: close\r\n\r\n"
	var out := head.to_utf8_buffer()
	out.append_array(b)
	return out


## The phone page: the steps, a link to SteamGridDB's API page, the paste box.
## `note`: a problem to show; `sent`: the key arrived.
static func page(note: String, sent: bool) -> String:
	var css := "body{font-family:system-ui,sans-serif;background:#0b1020;color:#eef2ff;margin:0;padding:24px;line-height:1.45}" \
		+ "main{max-width:480px;margin:auto}h1{font-size:1.4em;margin:0 0 12px}ol{padding-left:1.3em}li{margin:8px 0}" \
		+ "a.btn,button{display:block;width:100%;box-sizing:border-box;text-align:center;padding:14px;border-radius:12px;font-size:1.05em;font-weight:600;border:0;margin:12px 0;text-decoration:none}" \
		+ "a.btn{background:#1f2a48;color:#eef2ff}button{background:#4f8cff;color:#fff}" \
		+ "input{width:100%;box-sizing:border-box;padding:14px;border-radius:12px;border:1px solid #33406a;background:#121a33;color:#eef2ff;font-size:1em;font-family:monospace}" \
		+ ".note{background:#3a1d24;border-radius:12px;padding:12px}.ok{background:#173a2a;border-radius:12px;padding:16px}.q{color:#9aa6c8;font-size:.9em}"
	var inner := ""
	if sent:
		inner = "<h1>Key sent</h1><p class=\"ok\">GameCove has your key and is checking it with SteamGridDB. Look at your handheld. You can close this page.</p>"
	else:
		inner = "<h1>GameCove: game art</h1>" \
			+ "<ol><li>Open SteamGridDB and sign in with Steam.</li>" \
			+ "<li>Tap <b>Generate API key</b> and copy the key.</li>" \
			+ "<li>Come back to this page, paste the key below and tap <b>Send to GameCove</b>.</li></ol>" \
			+ "<a class=\"btn\" href=\"" + SGDB_API_PAGE + "\" target=\"_blank\" rel=\"noopener noreferrer\">Open SteamGridDB</a>" \
			+ "<p class=\"q\">If SteamGridDB shows its home page after you sign in, tap Open SteamGridDB again.</p>" \
			+ ("<p class=\"note\">" + note.xml_escape() + "</p>" if note != "" else "") \
			+ "<form method=\"post\"><input name=\"key\" placeholder=\"Paste your API key\" autocomplete=\"off\" autocapitalize=\"off\" autocorrect=\"off\" spellcheck=\"false\" required>" \
			+ "<button type=\"submit\">Send to GameCove</button></form>" \
			+ "<p class=\"q\">This page works only while the Game art step is open on your handheld, for 10 minutes at most, and only on your own network.</p>"
	return "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" \
		+ "<meta name=\"referrer\" content=\"no-referrer\"><title>GameCove: game art</title><style>" + css + "</style></head><body><main>" + inner + "</main></body></html>"


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE or what == NOTIFICATION_EXIT_TREE:
		stop()
