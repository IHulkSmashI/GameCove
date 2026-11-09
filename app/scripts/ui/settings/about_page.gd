extends "res://scripts/ui/settings/page.gd"
## About GameCove: version, licence, the setup checklist (each step can be
## opened again), credits viewer and links.

const Icons := preload("res://scripts/ui/icons.gd")
const Privacy := preload("res://scripts/system/privacy.gd")
const TPhoto := preload("res://scripts/ui/texts_photo.gd")

## Where "Background lookups" is saved; tests use their own file.
var privacy_path := Privacy.PREFS_PATH


func _connect() -> void:
	var st := svc("setup")
	if st != null and st.has_signal("changed"):
		st.changed.connect(func(_steps):
			if is_inside_tree():
				rebuild.call_deferred())


func build() -> void:
	var head := add_card("GameCove", "info")
	head.add_child(Kit.label(TS.ABOUT_TAGLINE, "LeadLabel", true))
	var version: String = host.version if host != null and "version" in host else "Development build"
	head.add_child(SKit.fact("Version", version))
	var dev := svc("device")
	if dev != null and dev.has_method("display_name"):
		head.add_child(SKit.fact("Device", dev.display_name()))
	head.add_child(Kit.label(TS.ABOUT_LICENSE, "QuietLabel", true))
	head.add_child(Kit.label(TS.ABOUT_DATA, "QuietLabel", true))

	var st := svc("setup")
	if st != null and st.has_method("steps"):
		var box := add_card(TS.SETUP_CARD, "check", TS.SETUP_CARD_LINE)
		var steps: Array = st.steps()
		for ours in TS.SETUP_STEPS:
			if ours in ["welcome", "done"]:
				continue
			var s := _service_step(steps, TS.SETUP_SERVICE_IDS[ours])
			var state := "done" if s.get("done", false) else ("skipped" if s.get("skipped", false) else "todo")
			var r: VBoxContainer = action_row(box, "setup_" + ours, TS.SETUP_STEP_NAMES[ours], TS.SETUP_STATE[state], "", "")
			r.set_value(TS.SETUP_STATE[state], {"done": "good", "skipped": "muted", "todo": "warn"}[state])
			r.pressed.connect(func(): host.open_setup(ours))
		var open := action_row(box, "setup_open", TS.SETUP_OPEN, "", "", "rocket")
		open.pressed.connect(func(): host.open_setup(""))

	_privacy_card()

	var more := add_card("Credits and links", "star")
	var c := action_row(more, "credits", TS.ABOUT_CREDITS, "", TS.ABOUT_CREDITS_HELP, "star")
	c.pressed.connect(func(): host.open_credits())
	var src := action_row(more, "source", TS.ABOUT_SOURCE, "github.com", TS.LINK_OPENS, "library")
	src.pressed.connect(func(): host.open_url(TS.REPO_URL))
	var bug := action_row(more, "issues", TS.ABOUT_ISSUE, "", TS.LINK_OPENS, "alert")
	bug.pressed.connect(func(): host.open_url(TS.ISSUES_URL))


static func _service_step(steps: Array, sid: String) -> Dictionary:
	for s in steps:
		if s.get("id", "") == sid:
			return s
	return {}


## "Network and privacy" (review M22): the overall switch, the per-feature switches and every call GameCove makes.
func _privacy_card() -> void:
	var box := add_card(TS.PRIVACY_CARD, "shield", TS.PRIVACY_LINE)
	box.get_parent().name = "Card_privacy"
	var bg := toggle(box, "background_lookups", TS.PRIVACY_BACKGROUND, Privacy.background_allowed(privacy_path),
		by_value(TS.PRIVACY_BACKGROUND_HELP), "download")
	bg.changed.connect(func(v): Privacy.set_background_allowed(bool(v), privacy_path))
	var d := svc("discover")
	if d != null and d.has_method("get_settings"):
		var info: Dictionary = (d.get("SETTINGS_INFO") as Dictionary).get("price_lookups", {}) if d.get("SETTINGS_INFO") is Dictionary else {}
		var pl := toggle(box, "price_lookups", str(info.get("label", TS.PRIVACY_PRICES)), bool(d.get_settings().get("price_lookups", true)),
			fixed(str(info.get("help", TS.PRIVACY_PRICES_HELP))), "tag")
		pl.changed.connect(func(v): d.set_settings({"price_lookups": bool(v)}))
	var ph := svc("photo")
	if ph != null and ph.has_method("set_maker_enabled") and "maker_enabled" in ph:
		var m := toggle(box, "privacy_maker_photo", TPhoto.MAKER_SETTING_TITLE, bool(ph.maker_enabled), by_value(TPhoto.MAKER_SETTING_HELP), "handheld")
		m.changed.connect(func(v): ph.set_maker_enabled(bool(v)))
	box.add_child(Kit.label(TS.PRIVACY_CALLS, "HeaderLabel"))
	for c in Privacy.NETWORK_CALLS:
		box.add_child(Kit.label("%s: %s" % [c["who"], c["what"]], "", true))
		box.add_child(Kit.label("%s  ·  %s" % [c["when"], c["switch"]], "QuietLabel", true))
	box.add_child(Kit.label(TS.PRIVACY_NEVER, "QuietLabel", true))
