extends Node
## The only way Discover and Art reach the network. Each request runs in its
## own HTTPRequest with use_threads (the transfer never blocks the main
## thread), a timeout, our User-Agent and no cookies or personal headers. The
## callback always runs on the main thread.
##
## Backoff per host: a network failure, a 5xx or a 429 blocks that host for a
## while (Retry-After when the server sends one, else 60 s doubling up to 1 h);
## requests to a blocked host fail at once with error "backoff", so an offline
## device costs nothing. A success clears the block.
##
## Interface shared with fake_http.gd (tests and UI previews use that one):
##   request(url: String, opts: Dictionary, done: Callable) -> void
##     opts: {"headers": Array[String], "timeout": float, "download_file": String}
##     done.call(res) with res = {"ok": bool, "code": int, "body": PackedByteArray,
##       "error": "" | "offline" | "timeout" | "backoff" | "http <code>" | "busy",
##       "retry_after": int}
##   is_offline() -> bool: the last request failed for lack of network.

const REPO := "https://github.com/IHulkSmashI/GameCove"
const MAX_PARALLEL := 3
const MAX_QUEUE := 64
const BACKOFF_MIN := 60
const BACKOFF_MAX := 3600

var _active := 0
var _queue: Array = []
var _blocked := {}    # host -> {"until": unix, "wait": seconds}
var _offline := false


static func user_agent() -> String:
	var v := str(ProjectSettings.get_setting("application/config/version", ""))
	return "GameCove/%s (+%s)" % [v if v != "" else "dev", REPO]


static func host_of(url: String) -> String:
	var rest := url.split("://", true, 1)
	var h: String = (rest[1] if rest.size() > 1 else rest[0]).split("/", true, 1)[0]
	return h.to_lower()


func is_offline() -> bool:
	return _offline


func _now() -> int:
	return int(Time.get_unix_time_from_system())


func request(url: String, opts: Dictionary, done: Callable) -> void:
	var host := host_of(url)
	var b: Dictionary = _blocked.get(host, {})
	if not b.is_empty() and b["until"] > _now():
		done.call({"ok": false, "code": 0, "body": PackedByteArray(), "error": "backoff", "retry_after": b["until"] - _now()})
		return
	if _queue.size() >= MAX_QUEUE:
		done.call({"ok": false, "code": 0, "body": PackedByteArray(), "error": "busy", "retry_after": 0})
		return
	_queue.append([url, opts, done])
	_pump()


func _pump() -> void:
	while _active < MAX_PARALLEL and not _queue.is_empty():
		var job: Array = _queue.pop_front()
		_start(job[0], job[1], job[2])


func _start(url: String, opts: Dictionary, done: Callable) -> void:
	var req := HTTPRequest.new()
	req.use_threads = true
	req.timeout = float(opts.get("timeout", 20.0))
	req.max_redirects = 5
	if str(opts.get("download_file", "")) != "":
		req.download_file = opts["download_file"]
		req.accept_gzip = false
	add_child(req)
	_active += 1
	var headers := PackedStringArray(["User-Agent: " + user_agent(), "Accept: */*"])
	for h in opts.get("headers", []):
		headers.append(str(h))
	req.request_completed.connect(_on_done.bind(req, url, done))
	if req.request(url, headers) != OK:
		_on_done(HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(), PackedByteArray(), req, url, done)


func _on_done(result: int, code: int, headers: PackedStringArray, body: PackedByteArray,
		req: HTTPRequest, url: String, done: Callable) -> void:
	_active -= 1
	req.queue_free()
	var res := classify(result, code, headers)
	res["body"] = body
	var host := host_of(url)
	if res["ok"] or (code >= 200 and code < 500 and code != 429):
		_blocked.erase(host)
	elif res["error"] in ["offline", "timeout"] or code == 429 or code >= 500:
		var prev := int(_blocked.get(host, {}).get("wait", 0))
		var wait := int(res["retry_after"]) if int(res["retry_after"]) > 0 else clampi(prev * 2, BACKOFF_MIN, BACKOFF_MAX)
		_blocked[host] = {"until": _now() + wait, "wait": wait}
	_offline = res["error"] == "offline"
	done.call(res)
	_pump()


## HTTPRequest outcome -> the contract's res dict (body filled in by caller).
static func classify(result: int, code: int, headers: PackedStringArray) -> Dictionary:
	var res := {"ok": false, "code": code, "body": PackedByteArray(), "error": "", "retry_after": 0}
	match result:
		HTTPRequest.RESULT_SUCCESS:
			if code >= 200 and code < 300:
				res["ok"] = true
			else:
				res["error"] = "http %d" % code
		HTTPRequest.RESULT_TIMEOUT:
			res["error"] = "timeout"
		HTTPRequest.RESULT_CANT_RESOLVE, HTTPRequest.RESULT_CANT_CONNECT, HTTPRequest.RESULT_CONNECTION_ERROR, \
		HTTPRequest.RESULT_NO_RESPONSE, HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			res["error"] = "offline"
		_:
			res["error"] = "failed (%d)" % result
	for h in headers:
		if h.to_lower().begins_with("retry-after:"):
			var v := h.split(":", true, 1)[1].strip_edges()
			if v.is_valid_int():
				res["retry_after"] = clampi(v.to_int(), 0, 24 * 3600)
	return res
