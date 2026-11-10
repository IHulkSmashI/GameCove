extends RefCounted
## How the Controls are laid out: the cards of each settings page and the
## quick menu's tabs. Ids only; titles, help, ranges and availability come
## from the controls themselves. Ids ending in "*" match every control with
## that prefix (one back-button row per paddle). Any control a page's groups
## have that isn't listed here still shows, in an "Other" card, so a new
## provider's settings are never hidden.
##
## Each card: [title, icon, main ids, more ids]. Main ids show at once;
## "more" ids (advanced) and every control that isn't available on this
## handheld sit behind the card's "More settings" row.

const CARDS := {
	"power": [
		["Power limit", "bolt", ["power.profile", "power.tdp", "power.boost", "power.boost_on"],
			["power.power_mode", "power.platform_profile", "power.sppt", "power.fppt", "power.thermal_limit"]],
		["Auto TDP", "sparkle", ["power.autotune_target", "power.autotune_auto_fps"],
			["power.autotune_keep", "power.autotune_floor", "power.autotune_plugged"]],
		["Fan", "fan", ["power.fan_mode", "power.fan_curve"], []],
		["Battery", "battery_leaf", ["power.battery_saver", "power.battery_saver_at", "power.charge_limit", "power.battery_long_life"],
			["power.sleep_mode", "power.mcu_powersave"]],
		["CPU", "cpu", ["power.cpu_boost", "power.epp"], ["power.smt", "power.cpu_cores", "power.governor", "power.cpu_max"]],
		["Graphics", "screen", ["power.gpu_level", "power.gpu_profile"], ["power.gpu_clock", "power.gpu_min", "power.gpu_max"]],
	],
	"display": [
		["Screen", "sun", ["display.brightness", "display.refresh_rate", "display.fps_limit", "display.vrr"],
			["display.allow_tearing", "display.refresh_unlock", "display.rotation"]],
		["Colour", "palette", ["display.night_light", "display.night_light_strength", "display.night_light_schedule", "display.vibrance", "display.color_temp"], []],
		["Scaling", "scaling", ["display.upscale_filter", "display.upscale_scaler", "display.sharpness"], []],
		["HDR", "sparkle", ["display.hdr", "display.hdr_itm", "display.sdr_brightness"], []],
		["Screen effects", "overlay", ["display.effect"], []],
		["Screen off", "moon", ["display.dim_after", "display.screen_off_after"], []],
	],
	"audio": [
		["Sound", "volume", ["audio.volume", "audio.mute", "audio.output"], []],
		["Microphone", "mic", ["audio.mic_mute", "audio.input"], []],
	],
	"controller": [
		["Controller", "gamepad", ["controller.emulation", "controller.nintendo_layout", "controller.rumble", "controller.rumble_strength", "controller.rumble_test"], []],
		["Gyro", "motion", ["controller.gyro", "controller.gyro_source", "controller.gyro_accel"], ["controller.gyro_aim"]],
		["Back buttons", "paddle", ["controller.paddles_as", "controller.paddle.*"], ["controller.button.*"]],
		["Sticks and triggers", "stick", ["controller.deadzone_left_stick", "controller.deadzone_right_stick"],
			["controller.deadzone_left_trigger", "controller.deadzone_right_trigger"]],
		["Trackpad", "mouse", ["controller.trackpad"], []],
		["Lights", "light", ["controller.led_effect", "controller.led_color", "controller.led_brightness"], ["controller.led_color_2", "controller.led_speed"]],
		["Mouse mode", "mouse", ["controller.desktop_mode", "controller.desktop_speed"], []],
		["Start over", "reset", [], ["controller.reset_layout"]],
	],
	"perf": [
		["Overlay", "overlay", ["perf.overlay", "perf.overlay_position"],
			["perf.overlay_opacity", "perf.overlay_scale", "perf.overlay_item.*"]],
		["Upscaling", "upscale", ["perf.upscaler", "perf.frame_gen", "perf.upscale_recommended", "perf.upscale_game_update",
			"perf.upscaler_update"], ["perf.upscale_undo"]],
		["Frame generation", "frames", ["perf.lsfg", "perf.lsfg_multiplier"], ["perf.lsfg_flow_scale", "perf.lsfg_performance"]],
		["Latency", "latency", ["perf.low_latency"], []],
		["Compatibility", "wrench", ["perf.proton"], ["perf.launch_wrapper"]],
		["Shaders", "shader", ["perf.shader_threads"], ["perf.clear_shader_cache"]],
	],
	"network": [
		["Wireless", "wifi", ["network.wifi", "network.bluetooth", "network.airplane"], ["network.wifi_power_save"]],
	],
	"system": [
		["Sleep and screenshots", "moon", ["system.keep_awake", "system.screenshot", "system.sleep"], []],
	],
}

## Quick menu tabs: the most used first. Unavailable ones are left out there.
const QUICK := {
	"game": ["perf.overlay", "display.fps_limit", "power.tdp", "power.autotune", "power.autotune_target",
		"perf.upscaler", "perf.frame_gen", "perf.lsfg", "perf.lsfg_multiplier", "perf.low_latency", "display.upscale_filter"],
	"power": ["power.profile", "power.tdp", "power.fan_mode", "power.battery_saver", "power.charge_limit",
		"power.cpu_boost", "power.boost", "power.epp"],
	"display": ["display.brightness", "display.refresh_rate", "display.fps_limit", "display.vrr", "display.night_light",
		"display.vibrance", "display.upscale_filter", "display.sharpness", "display.effect"],
	"audio": ["audio.volume", "audio.mute", "audio.output", "audio.mic_mute", "audio.input"],
	"controller": ["controller.emulation", "controller.gyro", "controller.gyro_source", "controller.nintendo_layout",
		"controller.rumble", "controller.led_effect", "controller.led_color", "controller.led_brightness", "controller.desktop_mode"],
	"device": ["network.wifi", "network.bluetooth", "network.airplane", "system.keep_awake", "system.screenshot"],
}

## Short titles for the quick menu, where the full ones don't fit.
const SHORT_TITLES := {
	"power.autotune_target": "Auto TDP target",
	"perf.lsfg": "Lossless frame gen",
	"display.upscale_filter": "Screen upscaler",
	"display.fps_limit": "Frame limit",
}

## Icons per control in the quick menu (left of the title).
const ICONS := {
	"perf.overlay": "overlay", "display.fps_limit": "latency", "power.tdp": "bolt", "power.autotune": "sparkle",
	"perf.upscaler": "upscale", "perf.frame_gen": "frames", "perf.lsfg": "frames", "display.brightness": "sun",
	"audio.volume": "volume", "audio.mic_mute": "mic", "network.wifi": "wifi", "network.bluetooth": "bluetooth",
	"network.airplane": "airplane", "controller.gyro": "motion", "controller.led_effect": "light",
	"power.fan_mode": "fan", "power.battery_saver": "battery_leaf", "display.night_light": "moon",
}


## The cards for a list of Controls groups, with "*" ids expanded against
## `all` (the ids that exist) and every leftover id in an "Other" card.
## Returns [[title, icon, main ids, more ids], ...] with only existing ids.
static func cards_for(groups: Array, all: Array) -> Array:
	var out := []
	var used := {}
	for g in groups:
		for card in CARDS.get(g, []):
			var main := expand(card[2], all, used)
			var more := expand(card[3], all, used)
			if not main.is_empty() or not more.is_empty():
				out.append([card[0], card[1], main, more])
	var rest := []
	for id in all:
		if not used.has(id):
			rest.append(id)
	if not rest.is_empty():
		out.append(["Other", "sliders", rest, []])
	return out


## Ids from `patterns` that exist in `all`, in pattern order, each once.
static func expand(patterns: Array, all: Array, used: Dictionary) -> Array:
	var out := []
	for p in patterns:
		var pat := str(p)
		for id in all:
			var hit: bool = (id == pat) or (pat.ends_with("*") and str(id).begins_with(pat.trim_suffix("*")))
			if hit and not used.has(id):
				used[id] = true
				out.append(id)
	return out
