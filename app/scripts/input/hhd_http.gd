extends RefCounted
## Blocking HTTP to Handheld Daemon's local API (http://127.0.0.1:5335). Only
## ever called from a service's worker thread, never the main thread. Tests use
## a fake with the same request() (see tests/test_input_hhd.gd).

var host := "127.0.0.1"
var port := 5335
## Whole request, connect included. hhd answers at once; a stuck daemon must not
## hold the worker for long.
var timeout_ms := 1500


## {"code": HTTP status (0 = no answer), "body": String}.
func request(method: String, path: String, headers: PackedStringArray, body := "") -> Dictionary:
	var c := HTTPClient.new()
	if c.connect_to_host(host, port) != OK:
		return {"code": 0, "body": ""}
	var deadline := Time.get_ticks_msec() + timeout_ms
	while c.get_status() in [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING]:
		c.poll()
		if Time.get_ticks_msec() > deadline:
			c.close()
			return {"code": 0, "body": ""}
		OS.delay_msec(5)
	if c.get_status() != HTTPClient.STATUS_CONNECTED:
		c.close()
		return {"code": 0, "body": ""}
	var m := HTTPClient.METHOD_POST if method == "POST" else HTTPClient.METHOD_GET
	var h := headers.duplicate()
	if method == "POST":
		h.append("Content-Type: application/json")
	if c.request(m, path, h, body) != OK:
		c.close()
		return {"code": 0, "body": ""}
	while c.get_status() == HTTPClient.STATUS_REQUESTING:
		c.poll()
		if Time.get_ticks_msec() > deadline:
			c.close()
			return {"code": 0, "body": ""}
		OS.delay_msec(5)
	if not c.has_response():
		c.close()
		return {"code": 0, "body": ""}
	var code := c.get_response_code()
	var out := PackedByteArray()
	while c.get_status() == HTTPClient.STATUS_BODY:
		c.poll()
		var chunk := c.read_response_body_chunk()
		if chunk.is_empty():
			if Time.get_ticks_msec() > deadline:
				break
			OS.delay_msec(2)
		else:
			out.append_array(chunk)
	c.close()
	return {"code": code, "body": out.get_string_from_utf8()}
