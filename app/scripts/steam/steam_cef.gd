extends Node
## Talks to the running Steam client through its CEF remote-debugging port, the
## way Decky Loader does (decky-loader backend/decky_loader/injector.py): GET
## http://127.0.0.1:8080/json, open the WebSocket of the "SharedJSContext" tab and
## send Chrome DevTools Protocol Runtime.evaluate calls that use Steam's own
## `SteamClient` JS API (method names from @decky/ui src/globals/steam-client).
##
## Strictly opt-in (StoreSettings "steam_cef"). Steam only opens the port when
## <steam root>/.cef-enable-remote-debugging exists at Steam start (what Decky's
## installer creates). Anything on this machine that can reach 127.0.0.1:8080
## can then run code inside Steam's signed-in client, so we never create the file
## without the user turning the setting on, remove it again when they turn it
## off (only if we created it), only connect to a loopback address, and build
## every script from JSON-encoded values, never from raw strings.
##
## Nothing runs while idle: the socket is polled in _process only while a call is
## pending or a subscription (download progress) is open, and closes after
## IDLE_CLOSE_S without either.

signal status_changed(status: String)
## A JS callback called window.<name>(payload) (Runtime.addBinding).
signal binding_called(name: String, payload: String)

const HOST := "127.0.0.1"
const PORT := 8080
const FLAG_FILE := ".cef-enable-remote-debugging"
## Tab titles of Steam's shared JS context across client versions (Decky's list).
const SHARED_CTX_NAMES := ["SharedJSContext", "Steam Shared Context presented by Valve™", "Steam", "SP"]
const IDLE_CLOSE_S := 15.0
const CALL_TIMEOUT_S := 20.0

## off: not opted in. flag_missing: opted in, but Steam was started without the
## flag file (restart Steam). connecting. ready. unreachable: Steam isn't
## answering on the port.
var status := "off"
var enabled := false
var steam_root := ""

var _http: HTTPRequest
var _ws: WebSocketPeer
var _ws_open := false
var _next_id := 0
var _pending := {}        # id -> {"cb": Callable, "t": seconds}
var _waiting: Array = []  # [expression, Callable] until the socket opens
var _bindings := {}       # name -> true
var _idle := 0.0


func _ready() -> void:
	set_process(false)


## Turns CEF control on or off. On: creates the flag file Steam reads at start
## (returns true if we created it, so the caller can remember to remove it).
func set_enabled(on: bool, created_flag_before := false) -> bool:
	enabled = on
	var created := false
	var flag := flag_path(steam_root)
	if on and steam_root != "" and not FileAccess.file_exists(flag):
		var f := FileAccess.open(flag, FileAccess.WRITE)
		if f != null:
			f.close()
			created = true
	elif not on:
		close()
		if created_flag_before and FileAccess.file_exists(flag):
			DirAccess.remove_absolute(flag)
	# "connecting" until the first call answers or fails.
	_set_status("off" if not on else ("flag_missing" if not FileAccess.file_exists(flag) else "connecting"))
	return created


static func flag_path(root: String) -> String:
	return root.path_join(FLAG_FILE) if root != "" else ""


## True once a call has gone through on this connection.
func is_ready() -> bool:
	return enabled and status == "ready"


## Worth trying: opted in and the flag file is there (Steam may still need a restart).
func is_usable() -> bool:
	return enabled and steam_root != "" and FileAccess.file_exists(flag_path(steam_root))


## Runs a JS expression in Steam's shared context; `cb` gets {"ok", "value", "error"}.
## Returns false when CEF control is off.
func evaluate(expression: String, cb := Callable()) -> bool:
	if not is_usable():
		return false
	_waiting.append([expression, cb])
	_idle = 0.0
	if _ws_open:
		_flush()
	elif _http == null and _ws == null:
		_discover()
	return true


## Registers a window.<name>() callback that arrives as binding_called. Kept
## across reconnects until remove_binding().
func add_binding(name: String) -> void:
	_bindings[name] = true
	if _ws_open:
		_send("Runtime.addBinding", {"name": name})


func remove_binding(name: String) -> void:
	_bindings.erase(name)


func close() -> void:
	if _http != null:
		_http.queue_free()
		_http = null
	if _ws != null:
		_ws.close()
		_ws = null
	_ws_open = false
	for id in _pending:
		_answer(_pending[id]["cb"], {"ok": false, "value": null, "error": "closed"})
	_pending.clear()
	for w in _waiting:
		_answer(w[1], {"ok": false, "value": null, "error": "closed"})
	_waiting.clear()
	set_process(false)


func _discover() -> void:
	_set_status("connecting")
	if not is_inside_tree():
		_fail_all("unreachable")   # HTTPRequest only works in the tree
		return
	_http = HTTPRequest.new()
	_http.timeout = 3.0
	add_child(_http)
	_http.request_completed.connect(_on_tabs)
	if _http.request("http://%s:%d/json" % [HOST, PORT]) != OK:
		_fail_all("unreachable")


func _on_tabs(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if _http != null:
		_http.queue_free()
		_http = null
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_fail_all("unreachable")
		return
	var json := JSON.new()
	var url := pick_tab(json.data if json.parse(body.get_string_from_utf8()) == OK else null)
	if url == "":
		_fail_all("unreachable")
		return
	_ws = WebSocketPeer.new()
	_ws.inbound_buffer_size = 4 * 1024 * 1024
	if _ws.connect_to_url(url) != OK:
		_ws = null
		_fail_all("unreachable")
		return
	set_process(true)


## webSocketDebuggerUrl of Steam's shared JS context in a /json answer, or "" if
## missing or not on a loopback address.
static func pick_tab(tabs: Variant) -> String:
	if not (tabs is Array):
		return ""
	for name in SHARED_CTX_NAMES:
		for t in tabs:
			if t is Dictionary and str(t.get("title", "")) == name:
				var url := str(t.get("webSocketDebuggerUrl", ""))
				if is_loopback_ws(url):
					return url
	return ""


static func is_loopback_ws(url: String) -> bool:
	return url.begins_with("ws://127.0.0.1:") or url.begins_with("ws://localhost:") or url.begins_with("ws://[::1]:")


func _process(delta: float) -> void:
	if _ws == null:
		set_process(false)
		return
	_ws.poll()
	var st := _ws.get_ready_state()
	if st == WebSocketPeer.STATE_OPEN:
		if not _ws_open:
			_ws_open = true
			for b in _bindings:
				_send("Runtime.addBinding", {"name": b})
			_flush()
		while _ws.get_available_packet_count() > 0:
			handle_message(_ws.get_packet().get_string_from_utf8())
	elif st == WebSocketPeer.STATE_CLOSED:
		_ws = null
		_ws_open = false
		_fail_all("unreachable")
		return
	for id in _pending.keys():
		_pending[id]["t"] += delta
		if _pending[id]["t"] > CALL_TIMEOUT_S:
			var cb: Callable = _pending[id]["cb"]
			_pending.erase(id)
			_answer(cb, {"ok": false, "value": null, "error": "timeout"})
	if _pending.is_empty() and _waiting.is_empty() and _bindings.is_empty():
		_idle += delta
		if _idle > IDLE_CLOSE_S:
			close()
	else:
		_idle = 0.0


## Handles one DevTools message (public for tests).
func handle_message(text: String) -> void:
	var json := JSON.new()
	if json.parse(text) != OK:
		return
	var msg: Variant = json.data
	if not (msg is Dictionary):
		return
	if msg.has("id"):
		var id := int(msg["id"])
		if not _pending.has(id):
			return
		var cb: Callable = _pending[id]["cb"]
		_pending.erase(id)
		_set_status("ready")
		_answer(cb, parse_eval_result(msg))
	elif str(msg.get("method", "")) == "Runtime.bindingCalled":
		var p: Dictionary = msg.get("params", {})
		binding_called.emit(str(p.get("name", "")), str(p.get("payload", "")))


## {"ok", "value", "error"} from a Runtime.evaluate answer.
static func parse_eval_result(msg: Dictionary) -> Dictionary:
	if msg.has("error"):
		return {"ok": false, "value": null, "error": str(msg["error"].get("message", "error"))}
	var r: Dictionary = msg.get("result", {})
	if r.has("exceptionDetails"):
		var ex: Dictionary = r["exceptionDetails"]
		var desc := str(ex.get("exception", {}).get("description", ex.get("text", "exception")))
		return {"ok": false, "value": null, "error": desc}
	var res: Dictionary = r.get("result", {})
	return {"ok": true, "value": res.get("value", null), "error": ""}


func _flush() -> void:
	for w in _waiting:
		var id := _send("Runtime.evaluate", {"expression": w[0], "awaitPromise": true, "returnByValue": true, "userGesture": true})
		_pending[id] = {"cb": w[1], "t": 0.0}
	_waiting.clear()


func _send(method: String, params: Dictionary) -> int:
	_next_id += 1
	if _ws != null:
		_ws.send_text(JSON.stringify({"id": _next_id, "method": method, "params": params}))
	return _next_id


func _fail_all(new_status: String) -> void:
	# lists taken first: a callback may call evaluate() again (re-entering here)
	var waiting := _waiting
	var pend := _pending
	_waiting = []
	_pending = {}
	_set_status(new_status)
	set_process(false)
	for w in waiting:
		_answer(w[1], {"ok": false, "value": null, "error": new_status})
	for id in pend:
		_answer(pend[id]["cb"], {"ok": false, "value": null, "error": new_status})


func _answer(cb: Callable, r: Dictionary) -> void:
	if cb.is_valid():
		cb.call(r)


func _set_status(s: String) -> void:
	if s != status:
		status = s
		status_changed.emit(s)


# --- Scripts (static, so tests check the exact text) ---

## A JS literal for any JSON value. JSON is valid JS except for U+2028/U+2029.
static func lit(v: Variant) -> String:
	return JSON.stringify(v).replace("\u2028", "\\u2028").replace("\u2029", "\\u2029")


static func _wrap(body: String) -> String:
	return "(async () => { %s })()" % body


static func js_set_launch_options(appid: int, options: String) -> String:
	return _wrap("SteamClient.Apps.SetAppLaunchOptions(%d, %s); return true;" % [appid, lit(options)])


static func js_set_compat_tool(appid: int, tool: String) -> String:
	return _wrap("SteamClient.Apps.SpecifyCompatTool(%d, %s); return true;" % [appid, lit(tool)])


static func js_compat_tools(appid: int) -> String:
	return _wrap("const t = await SteamClient.Apps.GetAvailableCompatTools(%d); return t.map(x => ({id: x.strToolName, name: x.strDisplayName}));" % appid)


static func js_run(appid: int, args: String) -> String:
	return _wrap("SteamClient.Apps.RunGame(%s, %s, -1, 100); return true;" % [lit(str(appid)), lit(args)])


static func js_verify(appid: int) -> String:
	return _wrap("await SteamClient.Apps.VerifyApp(%d); return true;" % appid)


static func js_uninstall(appid: int) -> String:
	return _wrap("SteamClient.Installs.OpenUninstallWizard([%d], true); return true;" % appid)


static func js_update(appid: int) -> String:
	return _wrap("SteamClient.Downloads.QueueAppUpdate(%d); return true;" % appid)


static func js_pause(appid: int) -> String:
	return _wrap("SteamClient.Downloads.PauseAppUpdate(%d); return true;" % appid)


static func js_resume(appid: int) -> String:
	return _wrap("SteamClient.Downloads.QueueAppUpdate(%d); SteamClient.Downloads.ResumeAppUpdate(%d); return true;" % [appid, appid])


static func js_cancel(appid: int) -> String:
	return _wrap("SteamClient.Downloads.RemoveFromDownloadList(%d); return true;" % appid)


## Index of the Steam library folder at `path` ("" = Steam's default folder);
## adds it as a library folder when it isn't one yet.
static func _js_folder_index(path: String) -> String:
	return ("const want = %s; const fs = await SteamClient.InstallFolder.GetInstallFolders(); " % lit(path)) \
		+ "let idx = -1; for (const f of fs) { if (want === '' ? f.bIsDefaultFolder : f.strFolderPath === want) idx = f.nFolderIndex; } " \
		+ "if (idx < 0 && want !== '') idx = await SteamClient.InstallFolder.AddInstallFolder(want); "


## Opens Steam's install wizard, picks the folder and confirms it, so no Steam
## window is needed. Answers "started", or "wizard" when the wizard didn't report
## back in time and is waiting in Steam for the user.
static func js_install(appid: int, library_path: String) -> String:
	return _wrap(_js_folder_index(library_path)
		+ "return await new Promise((done) => { let fin = false; "
		+ "const reg = SteamClient.Installs.RegisterForShowInstallWizard(() => { if (fin) return; fin = true; reg.unregister(); "
		+ "if (idx >= 0) SteamClient.Installs.SetInstallFolder(idx); SteamClient.Installs.ContinueInstall(); done('started'); }); "
		+ ("SteamClient.Installs.OpenInstallWizard([%d]); " % appid)
		+ "setTimeout(() => { if (!fin) { fin = true; reg.unregister(); done('wizard'); } }, 5000); });")


static func js_move(appid: int, library_path: String) -> String:
	return _wrap(_js_folder_index(library_path)
		+ ("if (idx < 0) return false; SteamClient.InstallFolder.MoveInstallFolderForApp(%d, idx); return true;" % appid))


const DOWNLOADS_BINDING := "gamecoveDownloads"

## Pushes Steam's download queue and the current download's numbers to
## window.gamecoveDownloads() on every change (RegisterForDownloadItems and
## RegisterForDownloadOverview).
static func js_watch_downloads() -> String:
	return _wrap("const w = window; if (w.__gamecoveDl) w.__gamecoveDl.forEach(r => r.unregister()); "
		+ "const send = (o) => { try { w.%s(JSON.stringify(o)); } catch (e) {} }; " % DOWNLOADS_BINDING
		+ "w.__gamecoveDl = [SteamClient.Downloads.RegisterForDownloadItems((active, items) => send({kind: 'items', active, "
		+ "items: items.map(i => ({appid: i.appid, active: i.active, paused: i.paused, completed: i.completed, "
		+ "downloaded_bytes: i.downloaded_bytes, total_bytes: i.total_bytes, queue_index: i.queue_index, error: i.update_error}))})), "
		+ "SteamClient.Downloads.RegisterForDownloadOverview((o) => send({kind: 'overview', appid: o.update_appid, "
		+ "bytes_done: o.update_bytes_downloaded, bytes_total: o.update_bytes_to_download, rate: o.update_network_bytes_per_second, "
		+ "eta: o.update_seconds_remaining, paused: o.paused, state: o.update_state}))]; return true;")


static func js_unwatch_downloads() -> String:
	return _wrap("const w = window; if (w.__gamecoveDl) { w.__gamecoveDl.forEach(r => r.unregister()); w.__gamecoveDl = null; } return true;")
