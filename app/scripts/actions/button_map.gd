extends RefCounted
## Button shortcuts as InputPlumber profile mappings: what a back button
## presses, and what a hold on one of the handheld's extra buttons does. Pure
## functions on profile Dictionaries (scripts/input/ip_profile.gd has the
## format); the controller Controls send the result through the profile lock
## like every other layout change.
##
## Everything lives in the profile, so per-game layouts, the everyday layout
## file, sleep / wake and a controller-type change carry it without extra work.
## Each button has at most one mapping of ours, named
##     "GameCove <Capability>[ press:<action>][ hold:<action>]"
##
## A back button (or an extra button GameCove leaves to the game) can press:
##   a gamepad button / a mouse button     as before (ip_edit.gd)
##   a key or a key combination            keyboard target events, pressed in
##        ("KeyLeftAlt+KeyEnter")           order and released in reverse by
##                                          InputPlumber itself: works with
##                                          GameCove closed, costs nothing
##   a GameCove action ("action:<id>")     a D-Bus target event (`dbus: ...`).
##        InputPlumber always hands a D-Bus event to its D-Bus target, even
##        while a game has the controller, so it arrives on the one `gdbus
##        monitor` GameCove already listens to (press, then release): nothing
##        polls and nothing new runs behind the game.
##
## The D-Bus names InputPlumber knows are a fixed list. No gamepad button
## produces ui_volume_up / ui_volume_down / ui_volume_mute, so those three carry
## GameCove's actions (SLOTS): one name per action, shared by every button set
## to that action. Three different GameCove actions fit on buttons at once;
## keys and gamepad buttons have no limit.
##
## A hold is for the buttons next to the screen that already belong to
## GameCove (Guide: home, Quick Access: quick menu, ...). Their short press
## stays what it was; the hold runs an action from scripts/actions/registry.gd.
## To see such a button while a game has focus it is mapped to its own D-Bus
## name (QuickAccess -> ui_quick); the intercept's activation button (Guide on
## most handhelds) already arrives and is left alone, so Steam's Guide chords
## keep working. Back buttons and A / B / X / Y get no hold: games hold them.
##
## Quick Access in a game opens GameCove's quick menu: while GameCove runs its
## session the button is mapped to ui_quick even with no hold set ("hold:none"
## keeps it ours without a hold). Who wants it to stay Steam's quick access
## menu in games sets it back ("GameCove QuickAccess steam", the button as the
## handheld sends it); Steam's menu is also one press away on the Shortcuts
## strip (Steam menu). for_other_sessions() takes every D-Bus mapping out
## before Steam Gaming Mode or the desktop take over, so there the button is
## Steam's again.

const Profile := preload("res://scripts/input/ip_profile.gd")
const IpEdit := preload("res://scripts/controls/input/ip_edit.gd")
const Buttons := preload("res://scripts/device/buttons.gd")
const Intercept := preload("res://scripts/input/intercept.gd")
const Registry := preload("res://scripts/actions/registry.gd")

const PREFIX := "GameCove "
const ACTION := "action:"
## D-Bus names that carry a GameCove action from a back button.
const SLOTS: Array[String] = ["ui_volume_up", "ui_volume_down", "ui_volume_mute"]
## A hold that was switched off on purpose (so the usual one isn't put back).
const NONE := "none"
## What the handheld's own button for an action does when held, unless changed.
## Guide stays free on purpose: Steam shows its chords on a long Guide.
const DEFAULT_HOLDS := {"quick_menu": "keyboard"}
## GameCove's own actions on the special buttons (Buttons.DEFAULT_ACTIONS).
const BUILT_IN := ["home", "quick_menu", "osk", "screenshot"]

const WHY := {
	"no_slot": "Three different GameCove actions fit on buttons at once. Set another button to a key or a gamepad button first.",
	"bad_action": "That action can't go on a button.",
	"bad_target": "That isn't something a button can press.",
	"not_special": "Only the buttons next to the screen can have a hold. Games hold the others themselves.",
	"same": "That's what a short press does already.",
	"steam": "Quick Access goes to Steam in games. Give it back to GameCove first.",
}
## The word in a mapping name that gives a button back to Steam in games.
const STEAM := "steam"


# ---- names ---------------------------------------------------------------------------------

## {"cap", "press", "hold"} from one of our mapping names, {} for any other name.
static func parse_name(mapping_name: String) -> Dictionary:
	if not mapping_name.begins_with(PREFIX):
		return {}
	var words := mapping_name.trim_prefix(PREFIX).split(" ", false)
	if words.is_empty():
		return {}
	var out := {"cap": words[0], "press": "", "hold": ""}
	for i in range(1, words.size()):
		if words[i] == STEAM:
			out["steam"] = true
		elif words[i].begins_with("press:"):
			out["press"] = words[i].trim_prefix("press:")
		elif words[i].begins_with("hold:"):
			out["hold"] = words[i].trim_prefix("hold:")
	return out


static func mapping_name(cap: String, press := "", hold := "") -> String:
	return PREFIX + cap + (" press:" + press if press != "" else "") + (" hold:" + hold if hold != "" else "")


## Our mapping whose source is `cap` (the Nintendo swap isn't one of these), or {}.
static func mapping_for(profile: Dictionary, cap: String) -> Dictionary:
	for m in profile.get("mapping", []) if profile.get("mapping") is Array else []:
		if m is Dictionary and Profile.button_of(m.get("source_event")) == cap and not parse_name(str(m.get("name", ""))).is_empty() \
				and not str(m.get("name", "")).begins_with("GameCove Nintendo"):
			return m
	return {}


# ---- which button is what --------------------------------------------------------------------

## The GameCove action a special button has on this device ("home", "quick_menu",
## "osk", "screenshot"), "" for a back button or a button left to the game.
static func built_in(device: Variant, cap: String) -> String:
	var a := Buttons.action_for(device, cap)
	return a if a in BUILT_IN else ""


## Buttons that can have a hold on this device: every special button that is
## GameCove's, in the profile's order, each once.
static func hold_caps(device: Variant) -> Array:
	var out: Array = []
	for b in Buttons.profile(device).get("special", []):
		var cap := str(b.get("capability", ""))
		if cap != "" and not cap in out and built_in(device, cap) != "":
			out.append(cap)
	return out


## The D-Bus name InputPlumber gives a special button ("QuickAccess" -> "ui_quick"), or "".
static func event_of(cap: String) -> String:
	var k: Variant = Buttons.DBUS_EVENTS.find_key(cap)
	return str(k) if k != null else ""


## True when InputPlumber already hands `cap` to GameCove while a game has focus
## (it is the intercept's one activation button), so it needs no mapping.
static func arrives_already(device: Variant, cap: String) -> bool:
	var act := Intercept.activation_for(device)
	var events: Array = act["events"]
	return events.size() == 1 and str(events[0]) == "Gamepad:Button:" + cap


## True when `cap` is the first half of a GameCove chord here (Quick Access + Y
## for the keyboard on a handheld without a keyboard button). Such a button
## already acts when it is let go; a hold fits in: held alone long enough it
## runs the hold action, with a second button it is the chord.
static func chord_modifier(device: Variant, cap: String) -> bool:
	for chord in Intercept.chords_for(device).values():
		if str(chord[0]) == cap:
			return true
	return false


## True when GameCove takes `cap` in games too unless the user gave it back to
## Steam: the quick-menu button, when it isn't the intercept's own button.
static func ours_in_game(device: Variant, cap: String) -> bool:
	return built_in(device, cap) == "quick_menu" and event_of(cap) != "" and not arrives_already(device, cap)


## True when the user gave `cap` back to Steam for games ("GameCove <cap> steam").
static func to_steam(profile: Dictionary, cap: String) -> bool:
	return bool(parse_name(str(mapping_for(profile, cap).get("name", ""))).get("steam", false))


## What `cap` does when held unless the user changed it: "action:<id>" or "".
static func default_hold(device: Variant, cap: String) -> String:
	var id := str(DEFAULT_HOLDS.get(built_in(device, cap), ""))
	if id == "" or arrives_already(device, cap):
		return ""
	return ACTION + id


# ---- reading ---------------------------------------------------------------------------------

## What a press of `cap` does: "" (itself), "disabled", a gamepad button, "mouse:Left",
## a key or key combination ("KeyLeftAlt+KeyEnter") or "action:<id>".
static func press_of(profile: Dictionary, cap: String) -> String:
	var m := mapping_for(profile, cap)
	if not m.is_empty():
		var n := parse_name(str(m.get("name", "")))
		if n["press"] != "":
			return ACTION + str(n["press"])
		if n["hold"] != "":
			return ""   # only there to carry the hold
	return IpEdit.button_target(profile, cap)


## What holding `cap` does on this device: "action:<id>" or "" (nothing).
static func hold_of(profile: Dictionary, cap: String, device: Variant) -> String:
	var m := mapping_for(profile, cap)
	if not m.is_empty():
		var n := parse_name(str(m.get("name", "")))
		if n.get("steam", false) or n["hold"] == NONE:
			return ""
		if n["hold"] != "":
			return ACTION + str(n["hold"])
	return default_hold(device, cap)


## Action -> D-Bus name for the GameCove actions back buttons run in `profile`.
static func slots_used(profile: Dictionary, skip_cap := "") -> Dictionary:
	var out := {}
	for m in profile.get("mapping", []) if profile.get("mapping") is Array else []:
		if not m is Dictionary:
			continue
		var n := parse_name(str(m.get("name", "")))
		if n.is_empty() or n["press"] == "" or n["cap"] == skip_cap:
			continue
		var t: Array = m.get("target_events", []) if m.get("target_events") is Array else []
		var ev := str(t[0].get("dbus", "")) if t.size() == 1 and t[0] is Dictionary else ""
		if ev in SLOTS:
			out[str(n["press"])] = ev
	return out


## The D-Bus name for `action` on a back button: the one it has already, else a
## free one, else "" (all three are taken by other actions).
static func slot_for(profile: Dictionary, action: String, skip_cap := "") -> String:
	var used := slots_used(profile, skip_cap)
	if used.has(action):
		return str(used[action])
	for s in SLOTS:
		if not s in used.values():
			return s
	return ""


# ---- what may be set -------------------------------------------------------------------------

## A target a back button's press can be set to.
static func valid_press(target: String) -> bool:
	if target.begins_with(ACTION):
		var a := Registry.action(target.trim_prefix(ACTION))
		return not a.is_empty() and bool(a["button"]) and a["kind"] != "key"
	if target.contains("+") or target.begins_with("Key"):
		return Registry.valid_combo(Registry.combo_keys(target))
	return IpEdit.valid_button_target(target)


static func valid_hold(action: String) -> bool:
	if action == "":
		return true
	if not action.begins_with(ACTION):
		return false
	var a := Registry.action(action.trim_prefix(ACTION))
	return not a.is_empty() and bool(a["button"])


## "" when `cap`'s press can be `target` in `profile`, else a WHY key.
static func press_problem(profile: Dictionary, cap: String, target: String) -> String:
	if not valid_press(target):
		return "bad_action" if target.begins_with(ACTION) else "bad_target"
	if target.begins_with(ACTION) and slot_for(profile, target.trim_prefix(ACTION), cap) == "":
		return "no_slot"
	return ""


## "" when holding `cap` can run `action` on this device, else a WHY key.
static func hold_problem(device: Variant, cap: String, action: String) -> String:
	if not valid_hold(action):
		return "bad_action"
	if action == "":
		return ""
	if built_in(device, cap) == "":
		return "not_special"
	# the built-in press under another name: Keyboard on the keyboard button, the menu on Quick Access
	var same := {"osk": "keyboard", "quick_menu": "quick_menu", "screenshot": "screenshot"}
	if str(same.get(built_in(device, cap), "")) == action.trim_prefix(ACTION):
		return "same"
	return ""


static func why_text(key: String) -> String:
	return str(WHY.get(key, "That can't be set here."))


# ---- writing ---------------------------------------------------------------------------------

static func _without(profile: Dictionary, cap: String) -> Dictionary:
	var p := Profile.normalize(profile)
	p["mapping"] = (p["mapping"] as Array).filter(func(m):
		return not (m is Dictionary and Profile.button_of(m.get("source_event")) == cap and not str(m.get("name", "")).begins_with("GameCove Nintendo")))
	return p


static func _source(cap: String) -> Dictionary:
	return {"gamepad": {"button": cap}}


## New profile with a press of `cap` doing `target` (press_of()'s forms). The
## profile comes back unchanged when press_problem() says no. `stock`: see
## IpEdit.set_button.
static func set_press(profile: Dictionary, cap: String, target: String, stock: Dictionary = {}) -> Dictionary:
	if press_problem(profile, cap, target) != "":
		return profile
	if target.begins_with(ACTION):
		var id := target.trim_prefix(ACTION)
		var p := _without(profile, cap)
		p["mapping"].append({"name": mapping_name(cap, id), "source_event": _source(cap),
			"target_events": [{"dbus": slot_for(profile, id, cap)}]})
		return p
	if target.contains("+"):
		var q := _without(profile, cap)
		var events: Array = []
		for k in Registry.combo_keys(target):
			events.append({"keyboard": k})
		q["mapping"].append({"name": mapping_name(cap), "source_event": _source(cap), "target_events": events})
		return q
	return IpEdit.set_button(profile, cap, target, stock)


## New profile with a hold on `cap` running `action` ("action:<id>", or "" for
## nothing). Unchanged when hold_problem() says no. A button GameCove takes in
## games (Quick Access) stays mapped to its D-Bus name with no hold too, and a
## hold takes it back from Steam if it was given back.
static func set_hold(profile: Dictionary, cap: String, action: String, device: Variant) -> Dictionary:
	if hold_problem(device, cap, action) != "":
		return profile
	var p := _without(profile, cap)
	var usual := default_hold(device, cap)
	var ours := ours_in_game(device, cap)
	if action == "" and usual == "" and not ours:
		return p   # nothing to remember: the button is as the device sends it
	var word := NONE if action == "" else action.trim_prefix(ACTION)
	var target: Dictionary = _source(cap)
	if (action != "" or ours) and not arrives_already(device, cap):
		target = {"dbus": event_of(cap)}
	p["mapping"].append({"name": mapping_name(cap, "", word), "source_event": _source(cap), "target_events": [target]})
	return p


## New profile with `cap` given back to Steam for games (`on`), or taken back by
## GameCove with its usual hold. Only for a button ours_in_game().
static func set_to_steam(profile: Dictionary, cap: String, on: bool, device: Variant) -> Dictionary:
	if not ours_in_game(device, cap):
		return profile
	if not on:
		return set_hold(_without(profile, cap), cap, default_hold(device, cap), device)
	var p := _without(profile, cap)
	p["mapping"].append({"name": PREFIX + cap + " " + STEAM, "source_event": _source(cap), "target_events": [_source(cap)]})
	return p


## The profile with every button shortcut back to this device's usual ones:
## each of `press_caps` presses itself again (a stock mapping InputPlumber's
## own profile had comes back, IpEdit.set_button), every hold button is as
## ensure_defaults() leaves it. Other mappings (Nintendo layout, gyro) stay.
static func reset(profile: Dictionary, device: Variant, press_caps: Array, stock: Dictionary = {}) -> Dictionary:
	var p := profile
	for cap in press_caps:
		p = IpEdit.set_button(_without(p, str(cap)), str(cap), "", stock)
	for cap in hold_caps(device):
		p = _without(p, str(cap))
	return ensure_defaults(p, device)


## The profile with this device's usual holds in place (Quick Access held:
## Keyboard, and mapped to GameCove in games) where the user hasn't chosen and
## nothing else maps the button.
## Returns `profile` itself when there is nothing to add.
static func ensure_defaults(profile: Dictionary, device: Variant) -> Dictionary:
	var out := profile
	for cap in hold_caps(device):
		var usual := default_hold(device, cap)
		if (usual == "" and not ours_in_game(device, cap)) or event_of(cap) == "":
			continue
		var mapped := false
		for m in out.get("mapping", []) if out.get("mapping") is Array else []:
			if m is Dictionary and Profile.button_of(m.get("source_event")) == cap:
				mapped = true
		if not mapped:
			out = set_hold(out, cap, usual, device)
	return out


## The profile as another session should find it: every mapping of ours that
## only GameCove can answer (a D-Bus name) is taken out, so the button is the
## device's own again under Steam or the desktop. Keys and gamepad buttons on
## back buttons stay; they need nobody. Returns `profile` itself when it has none.
static func for_other_sessions(profile: Dictionary) -> Dictionary:
	var list: Array = profile.get("mapping", []) if profile.get("mapping") is Array else []
	var kept: Array = list.filter(func(m): return not _ours_dbus(m))
	if kept.size() == list.size():
		return profile
	var p := Profile.normalize(profile)
	p["mapping"] = kept
	return p


static func _ours_dbus(m: Variant) -> bool:
	if not m is Dictionary or parse_name(str(m.get("name", ""))).is_empty():
		return false
	for e in m.get("target_events", []) if m.get("target_events") is Array else []:
		if e is Dictionary and e.get("dbus") is String:
			return true
	return false


# ---- what the intercept listens for ------------------------------------------------------------

## D-Bus name -> {"cap", "press": action id or "" (the button's built-in action),
## "hold": action id or "", "slot": bool} for everything `profile` asks GameCove
## to do on this device, the usual holds included.
static func table(profile: Dictionary, device: Variant) -> Dictionary:
	var out := {}
	for m in profile.get("mapping", []) if profile.get("mapping") is Array else []:
		if not m is Dictionary:
			continue
		var n := parse_name(str(m.get("name", "")))
		if n.is_empty() or str(m.get("name", "")).begins_with("GameCove Nintendo"):
			continue
		if n["press"] != "":
			var t: Array = m.get("target_events", []) if m.get("target_events") is Array else []
			var ev := str(t[0].get("dbus", "")) if t.size() == 1 and t[0] is Dictionary else ""
			if ev in SLOTS and Registry.has(str(n["press"])):
				out[ev] = {"cap": str(n["cap"]), "press": str(n["press"]), "hold": "", "slot": true}
	for cap in hold_caps(device):
		var h := hold_of(profile, cap, device)
		var ev2 := event_of(cap)
		if h != "" and ev2 != "" and Registry.has(h.trim_prefix(ACTION)):
			out[ev2] = {"cap": cap, "press": "", "hold": h.trim_prefix(ACTION), "slot": false}
	return out


# ---- labels ------------------------------------------------------------------------------------

## Plain words for a press or hold value.
static func label(value: String, button_labels: Dictionary = {}) -> String:
	if value == "":
		return "As itself"
	if value == "disabled":
		return "Off"
	if value.begins_with(ACTION):
		return str(Registry.action(value.trim_prefix(ACTION)).get("title", value))
	if value.begins_with("mouse:"):
		return "Mouse %s click" % value.trim_prefix("mouse:").to_lower()
	if value.begins_with("Key"):
		var keys := Registry.combo_keys(value)
		var known := Registry.key_action_for(keys)
		if known != "" and bool(Registry.action(known).get("needs", "") != ""):
			return "%s (%s)" % [Registry.action(known)["title"], Registry.combo_label(keys)]
		return Registry.combo_label(keys) if keys.size() > 1 else "Key " + Registry.key_label(value)
	return str(button_labels.get(value, value))
