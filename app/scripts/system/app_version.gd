extends RefCounted
class_name AppVersion
## GameCove's version, from one place: the RPM spec's `Version:`.
##
## A release build carries it as application/config/version: the Release workflow
## stamps the spec's Version into project.godot before it exports, and fails when
## the exported app says anything else (.github/workflows/release.yml). It is not
## written in project.godot in the repository, so the number can't drift from the
## spec and the tag.
##
## A build run from a checkout (`godot --path app`) reads the same spec next to it
## and says "<version>-dev", so About GameCove, bug reports and the User-Agent
## name what the build is based on. With neither (a copy of app/ on its own) it
## is "dev".

const SPEC := "../packaging/rpm/gamecove.spec"

static var _dev := ""
static var _dev_read := false


## The version a release was built as; "" in a development build.
static func stamped() -> String:
	return str(ProjectSettings.get_setting("application/config/version", "")).strip_edges()


## "0.1.0" in a release, "0.1.0-dev" from a checkout, "dev" otherwise.
static func text() -> String:
	return text_for(stamped(), _checkout_version())


static func text_for(stamp: String, spec_version: String) -> String:
	if stamp != "":
		return stamp
	return spec_version + "-dev" if spec_version != "" else "dev"


## True when this build is a release (it has a stamped version).
static func is_release() -> bool:
	return stamped() != ""


## `Version:` out of an RPM spec's text; "" when there is none or it isn't a plain version.
static func spec_version(spec_text: String) -> String:
	for line in spec_text.split("\n"):
		if line.begins_with("Version:"):
			var v := line.trim_prefix("Version:").strip_edges()
			var re := RegEx.create_from_string("^[0-9]+(\\.[0-9]+)*([-~+.][0-9A-Za-z.]+)*$")
			return v if re.search(v) != null else ""
	return ""


static func _checkout_version() -> String:
	if _dev_read:
		return _dev
	_dev_read = true
	var base := ProjectSettings.globalize_path("res://")
	if base == "" or base.begins_with("res://"):
		return ""
	var f := FileAccess.open(base.path_join(SPEC), FileAccess.READ)
	if f != null:
		_dev = spec_version(f.get_as_text())
	return _dev
