extends RefCounted
## The performance overlay's presets and look, as MangoHud options for the
## session's mangoapp (PerfMonitor / mangohud.gd write them).
##
## Presets: off, fps, compact and full are mangohud.gd's levels 0-3 (MangoHud's
## built-in presets 0-3, src/overlay_params.cpp presets()). "bar" is one thin
## row with only what a handheld player looks at (fps, frame time graph,
## CPU/GPU load, battery watts), stretched across the top like Steam Deck's
## level 2; "custom" shows the items the user ticked. Lines for the full
## preset and the item names are MangoHud README "List of parameters"
## (checked 2026-11-08: position, horizontal, horizontal_stretch, hud_compact,
## background_alpha, font_scale, frame_timing, battery_watt, time).
## MangoPeel (Gawah/MangoPeel, main.py STEAM_CONFIG and src/util/config/
## config_main.ts) rewrites the same session file and offers the same knobs
## (position, offsets, background_alpha 0-1 in 0.01 steps); its font_size entry
## is disabled there, so size goes through font_scale here.

const PRESETS := ["off", "fps", "compact", "bar", "full", "custom"]
## preset -> mangohud.gd level (0 off, 1 fps, 2 compact, 3 full)
const LEVEL := {"off": 0, "fps": 1, "compact": 2, "bar": 2, "full": 3, "custom": 3}
const BAR := ["horizontal", "horizontal_stretch", "legacy_layout=0", "table_columns=12", "hud_no_margin",
	"hud_compact", "fps", "frametime=0", "frame_timing=1", "cpu_stats", "gpu_stats", "battery", "battery_watt"]
const POSITIONS := ["top-left", "top-center", "top-right", "middle-left", "middle-right",
	"bottom-left", "bottom-center", "bottom-right"]
## custom items: id -> MangoHud options it turns on
const ITEMS := {
	"fps": ["fps"],
	"frametime": ["frametime"],
	"graph": ["frame_timing=1"],
	"cpu": ["cpu_stats"],
	"gpu": ["gpu_stats"],
	"temps": ["cpu_temp", "gpu_temp"],
	"power": ["cpu_power", "gpu_power"],
	"clocks": ["cpu_mhz", "gpu_core_clock"],
	"ram": ["ram", "vram"],
	"battery": ["battery", "battery_watt", "battery_time"],
	"time": ["time"],
}
const ITEM_TITLES := {
	"fps": "Frame rate", "frametime": "Frame time", "graph": "Frame time graph", "cpu": "CPU load",
	"gpu": "GPU load", "temps": "Temperatures", "power": "CPU and GPU watts", "clocks": "Clock speeds",
	"ram": "Memory use", "battery": "Battery", "time": "Clock",
}
const DEFAULT_ITEMS := ["fps", "graph", "cpu", "gpu", "battery"]


## Lines that replace the level's own ([] = the level's).
static func override_lines(preset: String, items: Array) -> Array:
	match preset:
		"bar":
			return BAR.duplicate()
		"custom":
			var out := ["legacy_layout=0", "cpu_stats=0", "gpu_stats=0", "frametime=0"]
			for id in ITEMS:
				if id in items:
					out.append_array(ITEMS[id])
			if out.size() == 4:
				out.append("fps")      # nothing ticked: at least the frame rate
			return out
	return []


## Lines added to every visible preset: position, background opacity (0-100 %)
## and text size (50-200 %). Defaults add nothing (MangoHud's own defaults).
static func extra_lines(position: String, opacity_pct: float, scale_pct: float) -> Array:
	var out := []
	if position in POSITIONS and position != "top-left":
		out.append("position=" + position)
	if opacity_pct >= 0.0 and not is_equal_approx(opacity_pct, 50.0):
		out.append("background_alpha=%.2f" % clampf(opacity_pct / 100.0, 0.0, 1.0))
	if scale_pct > 0.0 and not is_equal_approx(scale_pct, 100.0):
		out.append("font_scale=%.2f" % clampf(scale_pct / 100.0, 0.5, 2.0))
	return out


## The preset the overlay shows now: the remembered one when its level is
## still the current level (someone may have used the old 0-3 slider since).
static func preset_for(level: int, remembered: String) -> String:
	if remembered in PRESETS and LEVEL[remembered] == level:
		return remembered
	return ["off", "fps", "compact", "full"][clampi(level, 0, 3)]
