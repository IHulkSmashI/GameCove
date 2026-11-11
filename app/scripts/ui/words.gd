extends RefCounted
## Says "device" where the texts say "handheld", and "power" where they say
## "battery", when GameCove runs on something that isn't a handheld: a Steam
## Machine, a mini PC, any box by the TV.
##
## The texts are written for handhelds (texts_*.gd). On a handheld nothing
## here is installed and nothing runs. Elsewhere install() adds a Translation
## whose lookup is fit(): every Label, Button and RichTextLabel shows its text
## through it (Godot's auto-translate), formatted strings included, so no
## screen has to remember. Text drawn by hand (draw_string) calls fit() itself.
##
## "your handheld" / "this handheld" / "the handheld" take the device's name
## when it has a short one ("your Steam Machine"), every other "handheld"
## becomes "device". Battery wording: PHRASES below, phrase by phrase; a test
## (test_words.gd) keeps the list complete.

## Device has its own screen, battery and controls: texts stay as written.
static var handheld := true
## A system battery exists (always true on a handheld).
static var battery := true
## Short name for "your <name>" ("Steam Machine"); "" = say "device".
static var name := ""

static var _translation: Translation
static var _re: RegEx
static var _re_named: RegEx

## Battery wording on a device without one, longest phrases first.
const PHRASES := [
	["Saved settings that switch by themselves: per game, and for battery or plugged in.", "Saved settings that switch by themselves, per game."],
	["A game's own settings win over battery or plugged-in ones, which win over everyday ones.", "A game's own settings win over everyday ones."],
	["Higher profiles run faster and drain the battery faster.", "Higher profiles run faster, hotter and louder."],
	["More watts: more fps, more heat and fan noise, shorter battery.", "More watts: more fps, more heat and fan noise."],
	["Full power. Fastest, shortest battery.", "Full power. Fastest, loudest."],
	["Lowest power. Longest battery, fine for older and 2D games.", "Lowest power. Coolest and quietest, fine for older and 2D games."],
	["steady play with decent battery life", "steady play that stays cool and quiet"],
	["Smoothest picture; costs battery and adds a little input lag.", "Smoothest picture; adds a little input lag."],
	["More fps and battery; the picture gets a little softer.", "More fps; the picture gets a little softer."],
	["Small programs inside the hardware (controller, battery, drives) via fwupd.", "Small programs inside the hardware (controller, drives) via fwupd."],
	["Everything: frame time graph, CPU, GPU, battery.", "Everything: frame time graph, CPU, GPU, power."],
	["Pick Longest battery or Balanced in This game", "Pick Cool and quiet or Balanced in This game"],
	["TDP, fan, battery.", "TDP and fan."],
	["what it costs in battery", "what it costs in power"],
	["uses less battery while asleep", "uses less power while asleep"],
	["Less battery used while asleep", "Less power used while asleep"],
	["Also saves a little battery.", "Also saves a little power."],
	["Saves a little battery.", "Saves a little power."],
	["saves a sliver of battery", "saves a sliver of power"],
	["saves battery and heat", "saves power and heat"],
	["Saves battery.", "Saves power."],
	["saves battery", "saves power"],
	["Longest battery", "Cool and quiet"],
	["Keep the handheld plugged in or charged.", "Keep the power on."],
	[", battery drain", ""],
	["battery drain, ", ""],
]
## Handheld wording that "device" alone wouldn't mend.
const HANDHELD_PHRASES := [
	["Steam's handheld screen", "Steam's Big Picture screen"],
	["80 % suits handheld screens", "80 % suits small screens"],
]


## Reads what the device is. `device`: the Device autoload (or anything with
## is_handheld(), has_battery(), profile).
static func setup(device: Object) -> void:
	handheld = true
	battery = true
	name = ""
	if device == null or not device.has_method("is_handheld"):
		return
	handheld = device.is_handheld()
	battery = handheld or (device.has_method("has_battery") and device.has_battery())
	var prof: Variant = device.get("profile")
	if not handheld and prof is Dictionary and str(prof.get("tier", "")) != "generic":
		name = str(prof.get("short_name", prof.get("name", "")))


## Plain setter for tests and tools.
static func use(is_handheld: bool, has_battery: bool, device_name := "") -> void:
	handheld = is_handheld
	battery = has_battery or is_handheld
	name = device_name if not is_handheld else ""


## Adds (or removes) the Translation so every control's text goes through
## fit(). Call after setup(); safe to call again.
static func install() -> void:
	if _translation != null:
		TranslationServer.remove_translation(_translation)
		_translation = null
	if handheld and battery:
		return
	_translation = Lookup.new()
	_translation.locale = TranslationServer.get_locale()
	TranslationServer.add_translation(_translation)


## Takes the Translation out again. Called on the way out: a Translation kept in
## a static variable outlives TranslationServer and crashed the exit on a box.
static func uninstall() -> void:
	if _translation != null:
		TranslationServer.remove_translation(_translation)
		_translation = null


static func installed() -> bool:
	return _translation != null


class Lookup extends Translation:
	const Words := preload("res://scripts/ui/words.gd")
	func _get_message(src: StringName, _context: StringName) -> StringName:
		return StringName(Words.fit(String(src)))
	func _get_plural_message(src: StringName, src_plural: StringName, n: int, _context: StringName) -> StringName:
		return StringName(Words.fit(String(src if n == 1 else src_plural)))


## `text` as this device should read it.
static func fit(text: String) -> String:
	if handheld and battery:
		return text
	var out := text
	if not battery and (out.findn("batter") >= 0 or out.findn("charged") >= 0):
		for p in PHRASES:
			out = out.replace(p[0], p[1])
	if not handheld and out.findn("handheld") >= 0:
		for p in HANDHELD_PHRASES:
			out = out.replace(p[0], p[1])
		out = _swap_handheld(out)
	return out


static func _swap_handheld(text: String) -> String:
	if _re == null:
		_re = RegEx.new()
		_re.compile("(?i)\\bhandheld(s?)\\b(?![ -]Daemon)")
		_re_named = RegEx.new()
		_re_named.compile("\\b(your|this|the|Your|This|The) handheld\\b(?!s)")
	var out := text
	if name != "":
		# "This handheld" at the start of a sentence stays a sentence: "This Steam Machine"
		out = _re_named.sub(out, "$1 " + name, true)
	var res := ""
	var at := 0
	for m in _re.search_all(out):
		var w := m.get_string(0)
		var repl := "device" + m.get_string(1).to_lower()
		if w == w.to_upper():
			repl = repl.to_upper()
		elif w[0] == w[0].to_upper():
			repl = repl.capitalize()
		# "a handheld" -> "a device": the article still fits; nothing else to mend
		res += out.substr(at, m.get_start(0) - at) + repl
		at = m.get_end(0)
	return res + out.substr(at)
