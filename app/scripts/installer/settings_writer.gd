extends RefCounted
## Writes the installer's choices into the app's own settings, through the same
## services and files the app reads, so the first start in the GameCove session
## needs nothing. Every call is optional: a service that's missing is skipped.
##
##   theme, match art, reduce motion  -> UiPrefs (user://ui.cfg)
##   Steam control                    -> Library.set_store_setting("steam_cef")
##   gg.deals key, Steam profile, region, SteamGridDB key -> Discover.set_settings
##                                       (+ Setup.set_steamgriddb_key)
##   Auto TDP on / off                -> Launcher.set_default_goal(balanced | smooth)
##   default power profile            -> user://power.cfg [profile] battery / plugged
##                                       (what Power.restore() reads at start)
##   charge limit (steamos-manager)   -> user://power.cfg [device] charge_limit
##   first-run steps the installer covered -> Setup.complete / skip

const SettingsFile := preload("res://scripts/system/settings_file.gd")
const UiPrefs := preload("res://scripts/ui/ui_prefs.gd")
const POWER_CFG := "user://power.cfg"


## svc: {"setup", "library", "discover", "launcher", "power_cfg": path, "ui_prefs": bool}.
## Returns lines for the log.
static func apply(choices: Dictionary, svc: Dictionary) -> Array:
	var log: Array = []
	if svc.get("ui_prefs", true):
		UiPrefs.set_values({"theme": choices["theme"], "match_art": choices["match_art"], "reduce_motion": choices["reduce_motion"]})
		UiPrefs.save_prefs()
		log.append("look: theme %s, match art %s, reduce motion %s" % [choices["theme"], choices["match_art"], choices["reduce_motion"]])
	var lib: Object = svc.get("library")
	if lib != null and lib.has_method("set_store_setting"):
		lib.set_store_setting("steam_cef", bool(choices["steam_control"]))
		log.append("steam control %s" % ("on" if choices["steam_control"] else "off"))
	var disc: Object = svc.get("discover")
	if disc != null and disc.has_method("set_settings"):
		var patch := {}
		for k in ["ggdeals_key", "steam_id", "country", "steamgriddb_key"]:
			if str(choices.get(k, "")) != "":
				patch[k] = choices[k]
		if not patch.is_empty():
			disc.set_settings(patch)
			log.append("discover: " + ", ".join(PackedStringArray(patch.keys())))
	var setup: Object = svc.get("setup")
	if setup != null and str(choices.get("steamgriddb_key", "")) != "" and setup.has_method("set_steamgriddb_key"):
		setup.set_steamgriddb_key(str(choices["steamgriddb_key"]))
	var launcher: Object = svc.get("launcher")
	if launcher != null and launcher.has_method("set_default_goal"):
		launcher.set_default_goal("balanced" if choices["auto_tdp"] else "smooth")
		log.append("auto tdp %s" % ("on" if choices["auto_tdp"] else "off"))
	var cfg_path := str(svc.get("power_cfg", POWER_CFG))
	if cfg_path != "":
		SettingsFile.update_cfg(cfg_path, func(cfg: ConfigFile):
			cfg.set_value("profile", "battery", choices["power_profile"])
			cfg.set_value("profile", "plugged", choices["power_profile"])
			if int(choices["charge_limit"]) < 100:
				cfg.set_value("device", "charge_limit", int(choices["charge_limit"])))
		log.append("power: profile %s, charge limit %d" % [choices["power_profile"], int(choices["charge_limit"])])
	return log


## Marks the first-run steps the installer covered, so the in-app setup only
## shows what's left (nothing, usually). `skipped`: plan.skipped.
static func mark_setup(setup: Object, choices: Dictionary, skipped: Dictionary, signed_in_any: bool) -> void:
	if setup == null or not setup.has_method("complete"):
		return
	setup.complete("welcome")
	setup.complete("theme")
	if signed_in_any:
		setup.complete("stores")
	else:
		setup.skip("stores")
	# Fixes were installed here, or wait for Desktop Mode (the installer opens
	# itself there); either way the in-app step has nothing to add.
	if skipped.has("device") or (choices.get("fixes", []) as Array).is_empty():
		setup.skip("device_fixes")
	else:
		setup.complete("device_fixes")
	if str(choices.get("steamgriddb_key", "")) != "":
		setup.complete("steamgriddb")
	else:
		setup.skip("steamgriddb")
	if str(choices.get("ggdeals_key", "")) != "":
		setup.complete("keys")
	else:
		setup.skip("keys")
	setup.complete("done")
