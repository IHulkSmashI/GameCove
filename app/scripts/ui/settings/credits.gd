extends RefCounted
## CREDITS.md for the in-app viewer: finds the file and turns its Markdown
## (headings, tables, lists, bold, links) into BBCode for a RichTextLabel.

const CANDIDATES := ["res://CREDITS.md", "/usr/share/doc/gamecove/CREDITS.md", "/usr/share/gamecove/CREDITS.md"]


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
