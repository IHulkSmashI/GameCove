extends Node
## Talks to gamescope: frame limit, refresh rate, overlay focus. Owner: session
## agent. Stub today: reports not running under gamescope.

func is_running() -> bool:
	return OS.get_environment("GAMESCOPE_WAYLAND_DISPLAY") != "" or OS.get_environment("GAMESCOPE") != ""


func set_fps_limit(_fps: int) -> bool:
	return false


func set_refresh_rate(_hz: int) -> bool:
	return false


## Marks our window as the overlay on top of the running game (quick menu open).
func set_overlay(_open: bool) -> void:
	pass
