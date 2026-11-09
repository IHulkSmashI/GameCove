extends RefCounted
## Stand-in for Handheld Daemon's HTTP API (hhd_http.gd's request()). Holds a
## state dictionary; POST /api/v1/state deep-merges the body into it and
## answers with the whole state, like hhd. Records every request. `clamp_tdp`
## imitates hhd keeping a TDP inside its limits. Nothing touches the network.

var state := {}
var requests: Array = []     # [method, path, headers, body]
var token := ""              # when set, requests without "Bearer <token>" get 401
var down := false
var clamp_tdp := -1


func _init(initial: Dictionary = {}) -> void:
	state = initial.duplicate(true)


func request(method: String, path: String, headers: PackedStringArray, body := "") -> Dictionary:
	requests.append([method, path, headers, body])
	if down:
		return {"code": 0, "body": ""}
	if token != "" and not ("Authorization: Bearer " + token) in headers:
		return {"code": 401, "body": "Handheld Daemon Error: Authentication is on"}
	match path:
		"/api/v1/version":
			return {"code": 200, "body": "{\"version\": 5}"}
		"/api/v1/state":
			if method == "POST":
				var patch: Variant = JSON.parse_string(body)
				if not (patch is Dictionary):
					return {"code": 400, "body": "bad json"}
				_merge(state, patch)
				if clamp_tdp > 0:
					_clamp(state)
			return {"code": 200, "body": JSON.stringify(state)}
	return {"code": 404, "body": "not found"}


func posts() -> Array:
	return requests.filter(func(r): return r[0] == "POST").map(func(r): return JSON.parse_string(r[3]))


static func _merge(into: Dictionary, patch: Dictionary) -> void:
	for k in patch:
		if patch[k] is Dictionary and into.get(k) is Dictionary:
			_merge(into[k], patch[k])
		else:
			into[k] = patch[k]


func _clamp(d: Variant) -> void:
	if not (d is Dictionary):
		return
	for k in d:
		if k == "tdp" and (d[k] is int or d[k] is float) and d[k] > clamp_tdp:
			d[k] = clamp_tdp
		else:
			_clamp(d[k])


## A ROG Ally as hhd reports it (trimmed to what GameCove reads).
static func ally_state(tdp_enable := true) -> Dictionary:
	return {
		"controllers": {"rog_ally": {
			"imu": true, "swap_xbox": false,
			"controller_mode": {"mode": "dualsense", "dualsense": {"paddles_as": "steam_input", "led_support": false}},
			"limits": {"mode": "default", "manual": {"vibration": 100}},
		}},
		"rgb": {"handheld": {"mode": {"mode": "solid", "solid": {"hue": 30, "saturation": 100, "brightness": 50}}}},
		"tdp": {"asus": {"tdp_v2": {"mode": "custom", "custom": {"tdp": 15, "boost": true}}}},
		"hhd": {"settings": {"tdp_enable": tdp_enable}, "http": {"enable": true, "localhost": true, "token": true}},
		"info": {"version": "x"},
	}


## A Legion Go S: lenovo TDP driver, "imu" switch, Xbox Elite output (no paddles_as).
static func legion_go_s_state() -> Dictionary:
	return {
		"controllers": {"legion_gos": {"imu": false, "controller_mode": {"mode": "xbox_elite", "xbox_elite": {}}}},
		"tdp": {"lenovo": {"tdp": {"mode": "performance", "custom": {"tdp": 20, "boost": true}}}},
		"hhd": {"settings": {"tdp_enable": true}},
	}
