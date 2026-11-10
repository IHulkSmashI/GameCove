extends RefCounted
## Handheld Daemon (hhd) over ctx.runner, for the controller Controls.
##
## hhd serves the same REST API on two doors (hhd src/hhd/http/api.py):
##   /run/hhd/api      UNIX socket, mode 0666, no token (hhd >= 3.x)
##   127.0.0.1:5335    TCP, "Authorization: Bearer <token>" when hhd.http.token is on
## We talk to it with curl through ctx.runner (curl ships on Bazzite and
## SteamOS), so tests and the device matrix see every request in their fake
## runner and nothing ever opens a real socket. When <sys_root>/run/hhd does not
## exist hhd isn't running and nothing is spawned at all (Bazzite's default).
##
##   GET  /api/v1/settings   the settings schema: {section: {name: node}}, node =
##                           {"type": container|mode|bool|int|multiple|discrete|..,
##                            "children": {...}, "modes": {...}, "options": {...},
##                            "min", "max", "step", "default"}
##   GET  /api/v1/state      current values, same nesting without type/children
##   POST /api/v1/state      only the keys to change; answers with the whole state
##                           once hhd applied it (a refused value comes back unchanged)

const SOCKET := "/run/hhd/api"
const PORT := 5335

var runner: RefCounted
## Optional HTTP transport with hhd_http.gd's request(method, path, headers, body)
## -> {code, body} (ctx.hhd_transport: the device matrix's fake hhd); else curl.
var transport: RefCounted
var sys_root := ""
var home := ""
## Seconds curl may take. hhd answers at once; a stuck daemon must not hold the
## Controls worker.
var timeout_s := 2


func _init(command_runner: RefCounted = null, root := "", home_dir := "") -> void:
	runner = command_runner
	sys_root = root
	home = home_dir


## hhd's runtime folder exists (it creates /run/hhd at start).
func present() -> bool:
	return runner != null and DirAccess.dir_exists_absolute(sys_root + "/run/hhd")


func token() -> String:
	for f in [sys_root + "/tmp/hhd/token", sys_root + "/etc/hhd/.token", home.path_join(".config/hhd/token")]:
		if FileAccess.file_exists(f):
			var t := FileAccess.get_file_as_string(f).strip_edges()
			if t != "":
				return t
	return ""


## hhd's TCP port: hhd.http.port in ~/.config/hhd/state.yml, else 5335 (as
## hhd-decky reads it: github.com/hhd-dev/hhd-decky main.py, retrieve_http_port).
func port() -> int:
	var f := home.path_join(".config/hhd/state.yml")
	if not FileAccess.file_exists(f):
		return PORT
	var in_http := false
	for line in FileAccess.get_file_as_string(f).split("\n"):
		var t := line.strip_edges()
		if t == "http:":
			in_http = true
		elif in_http and t.begins_with("port:"):
			var v := t.trim_prefix("port:").strip_edges()
			return int(v) if v.is_valid_int() and int(v) > 0 and int(v) < 65536 else PORT
	return PORT


func get_settings() -> Variant:
	return _json(request("GET", "/api/v1/settings"))


func get_state() -> Variant:
	return _json(request("GET", "/api/v1/state"))


func set_state(partial: Dictionary) -> Variant:
	return _json(request("POST", "/api/v1/state", JSON.stringify(ints(partial), "", false)))


## Whole floats back to ints (JSON parsing made every number a float; hhd's int
## settings should get "5", not "5.0").
static func ints(v: Variant) -> Variant:
	if v is Dictionary:
		var out := {}
		for k in v:
			out[k] = ints(v[k])
		return out
	if v is Array:
		return (v as Array).map(func(x): return ints(x))
	if v is float and is_equal_approx(v, roundf(v)) and absf(v) < 1e15:
		return int(v)
	return v


## {"code": HTTP status (0 = no answer), "body": String}. Socket first, then TCP.
func request(method: String, path: String, body := "") -> Dictionary:
	if not present():
		return {"code": 0, "body": ""}
	if transport != null and transport.has_method("request"):
		var headers := PackedStringArray()
		var t := token()
		if t != "":
			headers.append("Authorization: Bearer " + t)
		if method == "POST":
			headers.append("Content-Type: application/json")
		var tr: Variant = transport.request(method, path, headers, body)
		return {"code": int(tr.get("code", 0)), "body": str(tr.get("body", ""))} if tr is Dictionary else {"code": 0, "body": ""}
	var r := _curl(method, path, body, true)
	if int(r["code"]) == 0:
		r = _curl(method, path, body, false)
	return r


static var _hdr_seq := 0
static var _hdr_lock := Mutex.new()


## Where one call's header file goes (user data folder, only this user can read it). A new name for every call
## (process id, a counter, a random part): the main thread and the Controls worker may both call at once, and
## one fixed file let one call overwrite or delete the other's token (review problem 9).
static func auth_header_path() -> String:
	_hdr_lock.lock()
	_hdr_seq += 1
	var n := _hdr_seq
	_hdr_lock.unlock()
	return ProjectSettings.globalize_path("user://hhd-auth-%d-%d-%08x.header" % [OS.get_process_id(), n, randi()])


static func _write_auth_header(t: String) -> String:
	var p := auth_header_path()
	var f := FileAccess.open(p, FileAccess.WRITE)
	if f == null:
		return ""
	f.close()
	FileAccess.set_unix_permissions(p, FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER)
	f = FileAccess.open(p, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_string("Authorization: Bearer " + t + "\n")
	f.close()
	FileAccess.set_unix_permissions(p, FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER)
	return p


func _curl(method: String, path: String, body: String, unix: bool) -> Dictionary:
	var args := PackedStringArray(["-sS", "-m", str(timeout_s), "-X", method, "-w", "\n%{http_code}"])
	var hdr := ""
	if unix:
		args.append_array(["--unix-socket", SOCKET])
	else:
		# the token goes in a 0600 header file (curl -H @file), never on the command line where any local
		# process can read it in /proc (review L32); the file lives only for this call
		var t := token()
		if t != "":
			hdr = _write_auth_header(t)
			if hdr == "":
				return {"code": 0, "body": ""}
			args.append_array(["-H", "@" + hdr])
	if method == "POST":
		args.append_array(["-H", "Content-Type: application/json", "--data-binary", body])
	args.append(("http://localhost" if unix else "http://127.0.0.1:%d" % port()) + path)
	var r: Dictionary = runner.run("curl", args)
	if hdr != "":
		DirAccess.remove_absolute(hdr)
	if int(r.get("code", -1)) != 0:
		return {"code": 0, "body": ""}
	var out := str(r.get("out", ""))
	var nl := out.rfind("\n")
	var status := out.substr(nl + 1).strip_edges() if nl >= 0 else out.strip_edges()
	return {"code": int(status) if status.is_valid_int() else 0, "body": out.substr(0, nl) if nl >= 0 else ""}


static func _json(r: Dictionary) -> Variant:
	if int(r.get("code", 0)) != 200:
		return null
	var v: Variant = JSON.parse_string(str(r.get("body", "")))
	return v if v is Dictionary else null


# ---- schema / state helpers (pure) ---------------------------------------------

static func dig(d: Variant, path: Array) -> Variant:
	var cur: Variant = d
	for k in path:
		if not (cur is Dictionary) or not cur.has(k):
			return null
		cur = cur[k]
	return cur


## {"a": {"b": value}} for ["a", "b"].
static func nest(path: Array, value: Variant) -> Dictionary:
	var out: Variant = value
	for i in range(path.size() - 1, -1, -1):
		out = {path[i]: out}
	return out


## Deep merge (patch wins), returns a new Dictionary.
static func merge(a: Dictionary, b: Dictionary) -> Dictionary:
	var out := a.duplicate(true)
	for k in b:
		if b[k] is Dictionary and out.get(k) is Dictionary:
			out[k] = merge(out[k], b[k])
		else:
			out[k] = b[k] if not (b[k] is Dictionary) else (b[k] as Dictionary).duplicate(true)
	return out


## The schema node for a state path (["controllers", "rog_ally", "controller_mode",
## "dualsense", "paddles_as"]): sections hold names directly, containers have
## "children", modes have "modes" (their "mode" key is the mode switch itself,
## returned as the mode node). null when hhd's schema has no such setting.
static func schema_node(settings: Variant, path: Array) -> Variant:
	if path.size() < 2:
		return null
	var node: Variant = dig(settings, [path[0], path[1]])
	for i in range(2, path.size()):
		if not (node is Dictionary):
			return null
		var k: String = str(path[i])
		if str(node.get("type", "")) == "mode":
			if k == "mode":
				return node
			node = dig(node, ["modes", k])
		else:
			node = dig(node, ["children", k])
	return node


## The option values of a "multiple"/"discrete" node or the modes of a "mode"
## node, in hhd's order. [] when none.
static func options_of(node: Variant) -> Array:
	if not (node is Dictionary):
		return []
	match str(node.get("type", "")):
		"mode":
			return (node.get("modes", {}) as Dictionary).keys() if node.get("modes") is Dictionary else []
		"multiple":
			return (node.get("options", {}) as Dictionary).keys() if node.get("options") is Dictionary else []
		"discrete":
			return node.get("options", []) if node.get("options") is Array else []
	return []


## {value: label} of a multiple node / {mode: title} of a mode node.
static func labels_of(node: Variant) -> Dictionary:
	var out := {}
	if not (node is Dictionary):
		return out
	if node.get("options") is Dictionary:
		for k in node["options"]:
			out[k] = str(node["options"][k])
	if node.get("modes") is Dictionary:
		for k in node["modes"]:
			var m: Variant = node["modes"][k]
			out[k] = str(m.get("title", k)) if m is Dictionary else str(k)
	return out


## The controller section's name ("rog_ally", "legion_go", "claw"...), "" when none.
static func controller_key(state: Variant) -> String:
	var c: Variant = dig(state, ["controllers"])
	if not (c is Dictionary):
		return ""
	var keys: Array = c.keys()
	keys.sort()
	for k in keys:
		if c[k] is Dictionary:
			return str(k)
	return ""
