extends "res://tests/test_case.gd"
## data_repo.gd: every data download and every pinned signing identity names the GameCove-data repo, and nothing in
## the app still downloads data from the app repo's own releases (those are only the v* app releases now).

const DataRepo := preload("res://scripts/system/data_repo.gd")
const Index := preload("res://scripts/system/firmware_index.gd")
const PhotoSvc := preload("res://scripts/device/photo.gd")
const Calendar := preload("res://scripts/discover/calendar.gd")
const GameDb := preload("res://scripts/library/gamedb.gd")

const BASE := "https://github.com/IHulkSmashI/GameCove-data/releases/download/"
const WF := "https://github.com/IHulkSmashI/GameCove-data/.github/workflows/"


func test_every_download_is_on_the_data_repo() -> void:
	eq(DataRepo.RELEASES, BASE)
	eq(DataRepo.REPO, "IHulkSmashI/GameCove-data")
	eq(GameDb.URL, BASE + "gamedb/gamedb.json.gz", "game database")
	eq(Calendar.URL, BASE + "gamedb/upcoming.json.gz", "release calendar")
	eq(Index.URL, BASE + "firmware/firmware.json.gz", "firmware index")
	eq(PhotoSvc.RELEASE, BASE + "device-photos/", "device photos")
	eq(DataRepo.UPSCALERS_URL, BASE + "upscalers/upscalers.json", "upscaler list (the helper's mirror.py has the same)")


func test_signer_identities_are_the_data_workflows_on_main() -> void:
	eq(Index.OIDC_ISSUER, "https://token.actions.githubusercontent.com")
	eq(Index.SIGNER_IDENTITY, DataRepo.FIRMWARE_SIGNER)
	var cases := {DataRepo.FIRMWARE_SIGNER: "firmware.yml", DataRepo.UPSCALERS_SIGNER: "upscalers.yml"}
	for pattern in cases:
		var wf: String = cases[pattern]
		var r := RegEx.create_from_string(pattern)
		ok(r.search(WF + wf + "@refs/heads/main") != null, wf + " on main")
		ok(r.search((WF + wf + "@refs/heads/main").to_lower()) != null, wf + " any case")
		for other in [
			"https://github.com/IHulkSmashI/GameCove/.github/workflows/" + wf + "@refs/heads/main",   # the old home
			WF + wf + "@refs/heads/dev", WF + wf + "@refs/tags/v1.0.0", WF + wf + "@refs/heads/main2",
			"https://github.com/someone/GameCove-data/.github/workflows/" + wf + "@refs/heads/main",  # a fork
			WF + "release.yml@refs/heads/main",
		]:
			ok(r.search(other) == null, wf + " must refuse " + other)
	ok(RegEx.create_from_string(DataRepo.FIRMWARE_SIGNER).search(WF + "upscalers.yml@refs/heads/main") == null,
		"the firmware identity refuses the upscalers workflow")


func test_no_script_downloads_from_the_app_repo_releases() -> void:
	var found: Array = []
	_scan("res://scripts", found)
	eq(found, [], "app scripts naming the app repo's releases/download")


func _scan(dir: String, found: Array) -> void:
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd"):
			var text := FileAccess.get_file_as_string(dir.path_join(f))
			if text.containsn("IHulkSmashI/GameCove/releases/download"):
				found.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		_scan(dir.path_join(d), found)
