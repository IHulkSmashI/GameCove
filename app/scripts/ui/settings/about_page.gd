extends "res://scripts/ui/settings/page.gd"
## About GameCove: version, licence, the setup checklist (each step can be
## opened again), credits viewer and links.

const Icons := preload("res://scripts/ui/icons.gd")


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
