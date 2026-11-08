extends Node
## Per-game settings and the environment a game launches with (upscaler, frame
## generation, low latency, Proton choice). Owner: launch agent. Stub today.

## Per-game settings shape fixed by docs/CONTRACTS.md.
func settings_for(_game_key: String) -> Dictionary:
	return {
		"goal": "balanced",          # battery | balanced | smooth
		"fps_limit": 0,              # 0 = no limit
		"upscaler": "auto",          # auto | off | fsr | xess
		"frame_gen": false,
		"low_latency": true,
	}


func save_settings(_game_key: String, _settings: Dictionary) -> void:
	pass


## Environment variables to add when launching this game on this device.
func launch_env(_game: Dictionary) -> Dictionary:
	return {}
