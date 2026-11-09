extends RefCounted
## CREDITS.md for the in-app viewer: finds the file and turns its Markdown
## (headings, tables, lists, bold, links) into BBCode for a RichTextLabel.

## res://CREDITS.md is the copy exported into the pck (app/CREDITS.md links to the repo's file; export_presets.cfg
## include_filter), so every build has it; the packaged copies are fallbacks.
const CANDIDATES := ["res://CREDITS.md", "/usr/share/licenses/gamecove/CREDITS.md", "/usr/share/doc/gamecove/CREDITS.md",
	"/usr/share/gamecove/CREDITS.md"]
## Bundled licence texts, shown under their own headings after the credits (review H8).
const LICENSE_FILES := [
	["Outfit (SIL Open Font License 1.1)", "res://fonts/OFL-Outfit.txt"],
	["Plus Jakarta Sans (SIL Open Font License 1.1)", "res://fonts/OFL-PlusJakartaSans.txt"],
	["JetBrains Mono (SIL Open Font License 1.1)", "res://fonts/OFL-JetBrainsMono.txt"],
	["QR code encoder, kenyoni-software (MIT)", "res://addons/kenyoni/qr_code/LICENSE.md"],
]


## Path of the first CREDITS.md found ("" if none): packaged copies, then the
## repo's own file next to app/ when running from a checkout.
static func find() -> String:
	var dev := ProjectSettings.globalize_path("res://").path_join("../CREDITS.md").simplify_path()
	for p in CANDIDATES + [dev]:
		if FileAccess.file_exists(p):
			return p
	return ""


static func load_text() -> String:
	var p := find()
	return FileAccess.get_file_as_string(p) if p != "" else ""


## Everything the "Credits and licenses" page shows, as Markdown: CREDITS.md, then Godot's licence and the
## components compiled into the engine (from the engine itself, so always the ones this binary has), then the
## bundled fonts' and addons' licence texts. Licence bodies are kept as plain paragraphs.
static func full_text() -> String:
	var parts := PackedStringArray()
	var credits := load_text()
	if credits != "":
		parts.append(credits)
	parts.append("## Godot Engine\n\nGameCove is built with Godot Engine %s (godotengine.org). Its licence:\n\n%s" % [
		Engine.get_version_info().get("string", ""), _plain(Engine.get_license_text())])
	var comps := PackedStringArray()
	for c in Engine.get_copyright_info():
		var who := PackedStringArray()
		for part in c.get("parts", []):
			who.append(", ".join(PackedStringArray(part.get("copyright", []))) + " (" + str(part.get("license", "")) + ")")
		comps.append("- %s: %s" % [c.get("name", ""), "; ".join(who)])
	if not comps.is_empty():
		parts.append("### Components in Godot Engine\n\n" + "\n".join(comps))
	for lf in LICENSE_FILES:
		if FileAccess.file_exists(lf[1]):
			parts.append("## %s\n\n%s" % [lf[0], _plain(FileAccess.get_file_as_string(lf[1]))])
	return "\n\n".join(parts)


## A licence text as Markdown-safe paragraphs: no line starts a heading, table or list by accident.
static func _plain(t: String) -> String:
	var out := PackedStringArray()
	for l in t.replace("\r", "").split("\n"):
		var s := l.strip_edges()
		while s.begins_with("#") or s.begins_with("|") or s.begins_with("- ") or s.begins_with("* "):
			s = s.substr(1).strip_edges()
		out.append(s)
	return "\n".join(out)


static func _inline(s: String) -> String:
	var out := s.replace("[", "[lb]")
	# links [text](url) -> text (the [ was escaped above)
	out = RegEx.create_from_string("\\[lb\\]([^\\]]+)\\]\\(([^)]+)\\)").sub(out, "$1", true)
	out = RegEx.create_from_string("\\*\\*([^*]+)\\*\\*").sub(out, "[b]$1[/b]", true)
	out = RegEx.create_from_string("`([^`]+)`").sub(out, "$1", true)
	out = RegEx.create_from_string("(?<![\\w*])\\*([^*]+)\\*(?![\\w*])").sub(out, "[i]$1[/i]", true)
	return out


## BBCode for `md`. `head` / `quiet` are colours as #rrggbb for headings and
## table detail.
static func to_bbcode(md: String, head := "#ffffff", quiet := "#aab4c3") -> String:
	var lines: PackedStringArray = []
	for raw in md.split("\n"):
		var l := raw.strip_edges()
		if l.begins_with("|"):
			var cells: Array = Array(l.trim_prefix("|").trim_suffix("|").split("|")).map(func(c): return c.strip_edges())
			if cells.all(func(c): return c.replace("-", "").replace(":", "").strip_edges() == ""):
				continue
			if cells.size() >= 2 and cells[0] in ["Project", "What", "Source", "Name"]:
				continue   # header row
			var first := _inline(cells[0])
			var rest: Array = cells.slice(1).filter(func(c): return c != "").map(func(c): return _inline(c))
			lines.append("•  [b]%s[/b]  [color=%s]%s[/color]" % [first, quiet, "  ·  ".join(rest)])
		elif l.begins_with("# "):
			continue   # the viewer has its own title
		elif l.begins_with("## ") or l.begins_with("### "):
			lines.append("\n[font_size=22][b][color=%s]%s[/color][/b][/font_size]" % [head, _inline(l.lstrip("# "))])
		elif l.begins_with("- ") or l.begins_with("* "):
			lines.append("•  " + _inline(l.substr(2)))
		else:
			lines.append(_inline(l))
	return "\n".join(lines).strip_edges()
