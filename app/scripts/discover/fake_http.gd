extends RefCounted
## Stand-in for http.gd in tests and UI previews: answers by URL prefix from
## files or strings, synchronously (the callback runs before request()
## returns), and records every URL asked for. Nothing touches the network.
##
##   var http := FakeHttp.new()
##   http.route("https://www.cheapshark.com/api/1.0/deals", {"file": "/abs/deals.json"})
##   http.route("https://api.steampowered.com/", {"error": "offline"})
##   Discover.http = http
##
## A route is {"file": path} | {"text": String} | {"bytes": PackedByteArray}
## plus optional "code" (default 200) and "retry_after"; or {"error": "..."}.
## Unrouted URLs fail with error "offline". The longest matching prefix wins.
## opts["max_bytes"] is honoured like http.gd: a bigger body fails with "too big".
## opts are recorded in `options` (same order as `requests`).

var routes := {}
var requests: Array[String] = []
var options: Array = []
var offline := false


func route(prefix: String, answer: Dictionary) -> void:
	routes[prefix] = answer


func is_offline() -> bool:
	return offline


func count(prefix: String) -> int:
	var n := 0
	for u in requests:
		if u.begins_with(prefix):
			n += 1
	return n


func request(url: String, opts: Dictionary, done: Callable) -> void:
	requests.append(url)
	options.append(opts)
	var best := ""
	for p in routes:
		if url.begins_with(p) and p.length() > best.length():
			best = p
	var res := {"ok": false, "code": 0, "body": PackedByteArray(), "error": "offline", "retry_after": 0}
	if best != "" and not offline:
		var a: Dictionary = routes[best]
		if a.has("error"):
			res["error"] = a["error"]
			res["code"] = int(a.get("code", 0))
			res["retry_after"] = int(a.get("retry_after", 0))
		else:
			var body := PackedByteArray()
			if a.has("file"):
				body = FileAccess.get_file_as_bytes(a["file"])
			elif a.has("text"):
				body = str(a["text"]).to_utf8_buffer()
			elif a.has("bytes"):
				body = a["bytes"]
			var code := int(a.get("code", 200))
			if int(opts.get("max_bytes", 0)) > 0 and body.size() > int(opts["max_bytes"]):
				done.call({"ok": false, "code": code, "body": PackedByteArray(), "error": "too big", "retry_after": 0})
				return
			res = {"ok": code >= 200 and code < 300, "code": code, "body": body,
				"error": "" if code >= 200 and code < 300 else "http %d" % code, "retry_after": int(a.get("retry_after", 0))}
			if res["ok"] and str(opts.get("download_file", "")) != "":
				var f := FileAccess.open(opts["download_file"], FileAccess.WRITE)
				if f:
					f.store_buffer(body)
					f.close()
				res["body"] = PackedByteArray()
	done.call(res)
