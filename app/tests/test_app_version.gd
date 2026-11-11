extends "res://tests/test_case.gd"
## The app's version (final review, high 8): one source, the RPM spec's Version. Releases get
## it stamped by the Release workflow; a checkout reads the spec and says "<version>-dev".

const Boot := preload("res://scripts/installer/boot.gd")
const RunMode := preload("res://scripts/system/run_mode.gd")
const Http := preload("res://scripts/discover/http.gd")


func _spec() -> String:
	return FileAccess.get_file_as_string(ProjectSettings.globalize_path("res://").path_join("../packaging/rpm/gamecove.spec"))


func test_spec_version_is_read() -> void:
	eq(AppVersion.spec_version("Name: gamecove\nVersion:        0.1.0\nRelease: 1\n"), "0.1.0", "plain")
	eq(AppVersion.spec_version("Version: 1.2.0~rc.1\n"), "1.2.0~rc.1", "pre-release")
	eq(AppVersion.spec_version("Name: x\n"), "", "no Version line")
	eq(AppVersion.spec_version("Version: %{ver}\n"), "", "a macro isn't a version")
	eq(AppVersion.spec_version("Version: 1.0 \"; rm\n"), "", "nothing but a version")


func test_release_and_checkout_text() -> void:
	eq(AppVersion.text_for("0.1.0", "0.2.0"), "0.1.0", "a stamped release says its own version")
	eq(AppVersion.text_for("", "0.1.0"), "0.1.0-dev", "a checkout says the spec's version, marked dev")
	eq(AppVersion.text_for("", ""), "dev", "a bare copy of app/")


func test_this_checkout_has_a_version_everywhere() -> void:
	var want := AppVersion.spec_version(_spec())
	ok(want != "", "the spec has a Version")
	eq(AppVersion.stamped(), "", "project.godot carries no version in the repository: the export stamps it")
	eq(AppVersion.text(), want + "-dev", "version text")
	eq(Device.gamecove_version(), want + "-dev", "bug reports and About this device")
	ok(Http.user_agent().begins_with("GameCove/%s-dev (+" % want), "User-Agent: " + Http.user_agent())
	var main: GDScript = load("res://scripts/main.gd")
	eq(main._version(), want + "-dev", "About GameCove and the hint bar")
	eq(Boot.version_line(), "GameCove %s-dev" % want, "--version")


func test_stamped_release_is_what_every_reader_says() -> void:
	ProjectSettings.set_setting("application/config/version", "9.8.7")
	var main: GDScript = load("res://scripts/main.gd")
	var got := [AppVersion.text(), Device.gamecove_version(), Http.user_agent(), main._version(), Boot.version_line()]
	ProjectSettings.set_setting("application/config/version", null)
	eq(got, ["9.8.7", "9.8.7", "GameCove/9.8.7 (+%s)" % Http.REPO, "9.8.7", "GameCove 9.8.7"], "release build")
	eq(AppVersion.stamped(), "", "test leaves no version behind")


func test_project_file_has_no_version_line() -> void:
	# the Release workflow adds the line after config/name; a committed one would be there twice
	var text := FileAccess.get_file_as_string("res://project.godot")
	ok(not text.contains("config/version="), "project.godot must not carry config/version")
	ok(text.contains("\nconfig/name=\"GameCove\"\n"), "the line the workflow's stamp goes after")


func test_version_run_starts_no_services() -> void:
	ok(Boot.wants_version(PackedStringArray(["--version"])), "--version")
	ok(not Boot.wants_version(PackedStringArray(["--installer"])), "not for other runs")
	RunMode.test_args = ["--version"]
	var helper := RunMode.helper()
	RunMode.test_args = null
	ok(helper, "a --version run is a helper run: no store manager, no network, no watchers")


func test_screenshot_tools_print_the_real_version() -> void:
	# The README's pictures all come from these scripts: not one may print a version of its own
	# ("GameCove 0.4" sat in the Fixes pictures next to "GameCove 0.1" in the rest).
	var dir := ProjectSettings.globalize_path("res://").path_join("../tools/screenshots")
	var checked := 0
	var uses := 0
	for f in DirAccess.get_files_at(dir):
		if not f.ends_with(".gd"):
			continue
		var src := FileAccess.get_file_as_string(dir.path_join(f))
		checked += 1
		uses += 1 if "ShotVersion.short()" in src else 0
		for line in src.split("\n"):
			if "hint_status.text" in line and "GameCove" in line and "GameCove 0" in line:
				ok(false, "%s prints a version of its own (use ShotVersion.short()): %s" % [f, line.strip_edges()])
	ok(checked > 5 and uses >= 4, "the screenshot scripts were found and use ShotVersion")
	var short: String = load(dir.path_join("shot_version.gd")).short()
	ok(AppVersion.spec_version(_spec()).begins_with(short), "ShotVersion.short() (%s) is the spec's version" % short)
