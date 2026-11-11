extends RefCounted
## The version the screenshot tools print in the hint bar ("GameCove 0.1"): the one a release
## shows, from packaging/rpm/gamecove.spec (AppVersion), without a trailing ".0". One place, so
## no picture says a version nothing ever had.


static func short() -> String:
	var spec := FileAccess.get_file_as_string(ProjectSettings.globalize_path("res://").path_join("../packaging/rpm/gamecove.spec"))
	var v: String = AppVersion.spec_version(spec)
	if v == "":
		return "0.1"
	var parts := v.split(".")
	return ".".join(parts.slice(0, 2)) if parts.size() >= 3 and parts[2] == "0" else v
