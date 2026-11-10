extends "res://tests/test_case.gd"
## The Game art step's phone page (scripts/system/key_drop.gd) and the live
## SteamGridDB key check (sgdb.gd): token checks, what the page answers, the
## 10-minute close, the close after a key arrives. Live tests listen on
## 127.0.0.1 only and write no files.

const KeyDrop := preload("res://scripts/system/key_drop.gd")
const Sgdb := preload("res://scripts/library/art/sgdb.gd")
const KEY := "0123456789abcdef0123456789abcdef"


func test_picks_a_private_lan_address() -> void:
	var ifs := [
		{"name": "lo", "addresses": ["127.0.0.1", "::1"]},
		{"name": "docker0", "addresses": ["172.17.0.1"]},
		{"name": "enp3s0", "addresses": ["192.168.1.20"]},
		{"name": "wlan0", "addresses": ["fe80::1", "10.0.0.7"]},
	]
	eq(KeyDrop.pick_lan_ip(ifs), "10.0.0.7", "Wi-Fi first, never loopback or a container bridge")
	eq(KeyDrop.pick_lan_ip(ifs.slice(0, 3)), "192.168.1.20", "Ethernet next")
	eq(KeyDrop.pick_lan_ip([{"name": "wlan0", "addresses": ["8.8.8.8", "fe80::2"]}]), "", "public or IPv6-only: none")
	eq(KeyDrop.pick_lan_ip([]), "", "offline: none")
	ok(KeyDrop.is_private_ipv4("172.31.255.1") and not KeyDrop.is_private_ipv4("172.32.0.1"), "172.16/12 only")
	ok(not KeyDrop.is_private_ipv4("192.168.1") and not KeyDrop.is_private_ipv4("192.168.1.300"), "malformed")


func test_tokens_are_random_and_long() -> void:
	var a := KeyDrop.new_token()
	var b := KeyDrop.new_token()
	eq(a.length(), 32, "128 bits")
	ok(a != b and a.is_valid_hex_number(), "fresh each time")


func test_parse_request() -> void:
	eq(KeyDrop.parse_request("GET /k/abc HTTP/1.1\r\nHost: x".to_utf8_buffer()), {}, "headers not all here yet")
	var r := KeyDrop.parse_request("GET /k/abc HTTP/1.1\r\nHost: x\r\n\r\n".to_utf8_buffer())
	eq([r["method"], r["path"], r["headers"]["host"]], ["GET", "/k/abc", "x"], "parsed")
	eq(KeyDrop.parse_request("POST /k/a HTTP/1.1\r\nContent-Length: 10\r\n\r\nkey=".to_utf8_buffer()), {}, "body not all here yet")
	eq(KeyDrop.parse_request("POST /k/a HTTP/1.1\r\nContent-Length: 99999\r\n\r\n".to_utf8_buffer()), {}, "too big refused")
	eq(KeyDrop.parse_request("garbage\r\n\r\n".to_utf8_buffer()), {}, "not HTTP")
	eq(KeyDrop.parse_request("POST /k/a HTTP/1.1\r\nContent-Length: 4\r\n\r\nkey=extra".to_utf8_buffer())["body"], "key=", "body cut at its length")


func test_answers_only_the_token() -> void:
	var tok := "a".repeat(32)
	var own := "http://192.168.1.5:4000"
	eq(KeyDrop.respond({"method": "GET", "path": "/k/" + "b".repeat(32), "headers": {}}, tok, own)["status"], 404, "wrong token")
	eq(KeyDrop.respond({"method": "GET", "path": "/", "headers": {}}, tok, own)["status"], 404, "no token")
	eq(KeyDrop.respond({"method": "GET", "path": "/k/" + tok + "x", "headers": {}}, tok, own)["status"], 404, "token prefix isn't enough")
	eq(KeyDrop.respond({"method": "GET", "path": "/k/", "headers": {}}, "", own)["status"], 404, "stopped: nothing matches")
	var page := KeyDrop.respond({"method": "GET", "path": "/k/" + tok, "headers": {}}, tok, own)
	eq(page["status"], 200, "the page")
	ok(Sgdb.API_KEY_PAGE in str(page["body"]) and "Generate API key" in str(page["body"]), "links to SteamGridDB's API page with the steps")
	ok(not "<script" in str(page["body"]), "no scripts")
	eq(page["key"], "", "no key from a GET")
	var sent := KeyDrop.respond({"method": "POST", "path": "/k/" + tok, "headers": {"origin": own}, "body": "key=" + KEY}, tok, own)
	eq([sent["status"], sent["key"]], [200, KEY], "key arrives")
	ok("Key sent" in str(sent["body"]), "the phone is told")
	var bad := KeyDrop.respond({"method": "POST", "path": "/k/" + tok, "headers": {}, "body": "key=hello"}, tok, own)
	eq([bad["status"], bad["key"]], [400, ""], "not a key")
	ok("doesn't look like" in str(bad["body"]), "says why, form again")
	var csrf := KeyDrop.respond({"method": "POST", "path": "/k/" + tok, "headers": {"origin": "https://evil.example"}, "body": "key=" + KEY}, tok, own)
	eq([csrf["status"], csrf["key"]], [403, ""], "a POST from another site is refused")
	eq(KeyDrop.respond({"method": "PUT", "path": "/k/" + tok, "headers": {}}, tok, own)["status"], 405, "other methods")


func test_key_from_form() -> void:
	eq(KeyDrop.key_from_form("key=" + KEY), KEY, "plain")
	eq(KeyDrop.key_from_form("key=++" + KEY.to_upper() + "%0A"), KEY.to_upper(), "spaces and a newline around it")
	eq(KeyDrop.key_from_form("key=API+key%3A+" + KEY), KEY, "a label before it")
	eq(KeyDrop.key_from_form("key=" + KEY + "0"), "", "33 hex characters isn't a key")
	eq(KeyDrop.key_from_form("other=" + KEY), "", "only the key field")
	ok(KeyDrop.same_token("/k/abc", "/k/abc") and not KeyDrop.same_token("/k/abd", "/k/abc") and not KeyDrop.same_token("/k/ab", "/k/abc"), "token compare")


func test_response_headers() -> void:
	var r := KeyDrop.http_response(200, "hi").get_string_from_utf8()
	ok(r.begins_with("HTTP/1.1 200 OK\r\n"), "status line")
	for h in ["Cache-Control: no-store", "Referrer-Policy: no-referrer", "Content-Security-Policy: default-src 'none'", "Connection: close", "Content-Length: 2"]:
		ok(h in r, h)
	ok(r.ends_with("\r\n\r\nhi"), "body")


## Sends `raw` to the drop and pumps both ends until the whole answer is in.
func _ask(drop: Node, raw: String) -> String:
	var c := StreamPeerTCP.new()
	c.connect_to_host("127.0.0.1", drop.port)
	var sent := false
	var got := PackedByteArray()
	for i in 500:
		c.poll()
		drop.poll(0.01)
		var st := c.get_status()
		if st == StreamPeerTCP.STATUS_CONNECTED:
			if not sent:
				c.put_data(raw.to_utf8_buffer())
				sent = true
			var n := c.get_available_bytes()
			if n > 0:
				got.append_array(c.get_data(n)[1])
		if _complete(got) or (sent and st != StreamPeerTCP.STATUS_CONNECTED and st != StreamPeerTCP.STATUS_CONNECTING):
			break
		OS.delay_msec(2)
	c.disconnect_from_host()
	return got.get_string_from_utf8()


## A whole HTTP answer: headers and Content-Length bytes of body.
static func _complete(got: PackedByteArray) -> bool:
	var t := got.get_string_from_utf8()
	var end := t.find("\r\n\r\n")
	if end < 0:
		return false
	var m := RegEx.create_from_string("Content-Length: (\\d+)").search(t.substr(0, end))
	return m != null and got.size() - (end + 4) >= int(m.get_string(1))


func _drop() -> Node:
	var d: Node = KeyDrop.new()
	d.bind_address = "127.0.0.1"
	return d


func test_live_page_then_key_closes_it() -> void:
	var d := _drop()
	ok(d.start(), "listening")
	ok(d.port > 0 and d.url == "http://127.0.0.1:%d/k/%s" % [d.port, d.token], "address with the token")
	var keys: Array = []
	d.key_received.connect(func(k): keys.append(k))
	ok(_ask(d, "GET /k/nope HTTP/1.1\r\nHost: x\r\n\r\n").begins_with("HTTP/1.1 404"), "wrong token: 404")
	eq(d.bad_requests, 1, "counted")
	var page := _ask(d, "GET /k/%s HTTP/1.1\r\nHost: x\r\n\r\n" % d.token)
	ok(page.begins_with("HTTP/1.1 200") and "Send to GameCove" in page, "the page")
	var body := "key=" + KEY
	var ans := _ask(d, "POST /k/%s HTTP/1.1\r\nHost: x\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: %d\r\n\r\n%s" % [d.token, body.length(), body])
	ok(ans.begins_with("HTTP/1.1 200") and "Key sent" in ans, "phone told the key arrived")
	eq(keys, [KEY], "key received")
	ok(not d.is_running() and d.token == "", "closed after the key")
	d.free()


func test_live_times_out_after_ten_minutes() -> void:
	var d := _drop()
	eq(d.lifetime, 600.0, "10 minutes by default")
	ok(d.start(), "listening")
	var why: Array = []
	d.expired.connect(func(w): why.append(w))
	d.poll(599.0)
	ok(d.is_running() and d.seconds_left() == 1, "still open just before")
	d.poll(1.5)
	eq(why, ["timeout"], "expired")
	ok(not d.is_running() and d.url == "", "closed")
	d.free()


func test_live_closes_after_too_many_wrong_requests() -> void:
	var d := _drop()
	ok(d.start(), "listening")
	var why: Array = []
	d.expired.connect(func(w): why.append(w))
	d.bad_requests = KeyDrop.MAX_BAD - 1
	_ask(d, "GET /k/guess HTTP/1.1\r\n\r\n")
	eq(why, ["too_many"], "closed against guessing")
	ok(not d.is_running(), "not listening")
	d.free()


func test_no_lan_no_page() -> void:
	var d: Node = KeyDrop.new()
	d.interfaces_fn = func() -> Array: return [{"name": "lo", "addresses": ["127.0.0.1"]}]
	ok(not d.start(), "no LAN address: doesn't start")
	ok(not d.is_running() and d.url == "", "nothing listening")
	d.free()


func test_key_check_result() -> void:
	eq(Sgdb.check_url(), Sgdb.API + "games/steam/400", "one small request")
	eq(Sgdb.check_result({"ok": true, "code": 200, "body": '{"success":true,"data":{"id":1}}'.to_utf8_buffer()}), "ok", "works")
	eq(Sgdb.check_result({"ok": false, "code": 401, "body": '{"success":false,"errors":["Invalid API key"]}'.to_utf8_buffer(), "error": "http 401"}), "wrong", "wrong key")
	eq(Sgdb.check_result({"ok": false, "code": 403, "error": "http 403"}), "wrong", "forbidden")
	eq(Sgdb.check_result({"ok": false, "code": 0, "error": "offline"}), "offline", "no network")
	eq(Sgdb.check_result({"ok": false, "code": 0, "error": "timeout"}), "offline", "timed out")
	eq(Sgdb.check_result({"ok": false, "code": 503, "error": "http 503"}), "error", "SteamGridDB down")
	eq(Sgdb.check_result({"ok": true, "code": 200, "body": "<html>".to_utf8_buffer()}), "error", "not the API")
