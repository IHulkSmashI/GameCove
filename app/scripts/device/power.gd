extends Node
## Power, fan and charge limit. Talks to PowerStation / steamos-manager over
## D-Bus. Owner: device agent. Stub today: reports nothing supported.

signal changed(state: Dictionary)


## Shape is fixed by docs/CONTRACTS.md; the UI shows only what "supported" allows.
func state() -> Dictionary:
	var p: Dictionary = Device.profile
	var tdp: Dictionary = p.get("tdp", {})
	return {
		"backend": "none",
		"tdp_w": -1.0,
		"tdp_min": float(tdp.get("min", -1)),
		"tdp_max": float(tdp.get("battery_max", -1)),
		"profile": "",
		"profiles": [],
		"charge_limit": -1,
		"fan_mode": "",
		"fan_modes": [],
		"supported": {"tdp": false, "profiles": false, "charge_limit": false, "fan": false},
	}


func set_tdp(_watts: float) -> bool:
	return false


func set_profile(_name: String) -> bool:
	return false


func set_charge_limit(_percent: int) -> bool:
	return false


func set_fan_mode(_mode: String) -> bool:
	return false
