extends RefCounted
## The two store tools' save sync, ported step for step from their sources so tests see
## what the real ones would do to a cloud and a folder (nothing here talks to a network):
##   Gog   heroic-gogdl gogdl/saves.py CloudStorageManager.sync + SyncClassifier
##   Epic  legendary cli.py sync_saves + core.py check_savegame_state / upload_save / download_saves
## Both keep their cloud in memory and work on real folders under the test's own directory.


static func walk(path: String, base := "") -> Array:
	var out: Array = []
	var d := DirAccess.open(path)
	if d == null:
		return out
	d.include_hidden = true
	for f in d.get_files():
		out.append(base + f)
	for sub in d.get_directories():
		out.append_array(walk(path.path_join(sub), base + sub + "/"))
	out.sort()
	return out


static func put(path: String, data: String, mtime := 0) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(data)
	f.close()
	if mtime > 0:
		OS.execute("touch", ["-d", "@%d" % mtime, path])


static func iso(t: int) -> String:
	return Time.get_datetime_string_from_unix_time(t, false) + "+00:00"


class Gog extends RefCounted:
	const DELETED := "aadd86936a80ee8a369579c3926f1b3c"
	## "<location name>/<relative path>" -> {"data", "t": upload time, "lt": the file's own time, "hash"}
	var cloud := {}
	## The clock gogdl sees; one second passes per run.
	var now := 1762800000
	## What it did, in order: "upload a", "download a", "delete cloud a", "delete local a".
	var did: Array = []
	## >= 0: a download writes this many files, leaves the next one cut short and is killed
	## (exit 124, as coreutils timeout reports it).
	var cut_download_after := -1
	## >= 0: an upload sends this many files and is killed (exit 124): the cloud is left a mix.
	var cut_upload_after := -1
	var _sent := 0
	## Leave the cloud's file list out of the log (a gogdl that words it differently).
	var hide_listing := false
	var offline := false
	## Location names whose runs fail (GOG answers with an error for that one).
	var fail_names: Array = []

	func seed(name: String, rel: String, data: String, t: int) -> void:
		cloud[name + "/" + rel] = {"data": data, "t": t, "lt": t, "hash": data.md5_text()}

	func files(name: String) -> Array:
		var out: Array = []
		for k in cloud:
			if str(k).begins_with(name + "/") and cloud[k]["hash"] != DELETED:
				out.append(str(k).trim_prefix(name + "/"))
		out.sort()
		return out

	func run(args: Array) -> Dictionary:
		now += 1
		if offline:
			return {"code": 1, "out": "requests.exceptions.ConnectionError: Max retries exceeded"}
		var i := args.find("save-sync")
		var path := str(args[args.find("--") + 1])   # path and id come after `--`
		var ts := float(str(args[args.find("--ts") + 1]))
		var name := str(args[args.find("--name") + 1])
		if name in fail_names:
			return {"code": 1, "out": "[SAVES] ERROR: 500 Server Error for location %s\n" % name}
		var prefer := ""
		for a in args:
			prefer = str({"--skip-download": "upload", "--skip-upload": "download", "--force-upload": "forceupload",
				"--force-download": "forcedownload"}.get(str(a), prefer))
		var out := PackedStringArray()
		if not DirAccess.dir_exists_absolute(path):
			out.append("[SAVES] WARNING: Provided path doesn't exist, creating")
			DirAccess.make_dir_recursive_absolute(path)
		var local: Array = []
		for rel in preload("res://tests/fixtures/saves/fake_clouds.gd").walk(path):
			local.append({"rel": rel, "abs": path.path_join(rel), "t": int(FileAccess.get_modified_time(path.path_join(rel)))})
		out.append("[SAVES] INFO: Local files: %d" % local.size())
		var listing := PackedStringArray()
		var cloud_files: Array = []
		for k in cloud:
			listing.append("{'name': '%s', 'hash': '%s', 'last_modified': '%s', 'bytes': 1}" % [k, cloud[k]["hash"],
				preload("res://tests/fixtures/saves/fake_clouds.gd").iso(int(cloud[k]["t"]))])
			if str(k).begins_with(name):
				cloud_files.append({"rel": str(k).replace(name + "/", ""), "key": k, "t": int(cloud[k]["t"]), "hash": cloud[k]["hash"]})
		if not cloud.is_empty():
			out.append("[SAVES] INFO: Files in cloud: %d" % cloud.size())
			if not hide_listing:
				out.append("[SAVES] DEBUG: Files: [%s]" % ", ".join(listing))
		var downloadable := cloud_files.filter(func(f): return f["hash"] != DELETED)
		_sent = 0
		if local.size() > 0 and cloud_files.is_empty():
			out.append("[SAVES] INFO: No files in cloud, uploading")
			for f in local:
				if not _upload(name, f):
					return {"code": 124, "out": "\n".join(out) + "\n"}
			return _end(out)
		if local.is_empty() and cloud_files.size() > 0:
			out.append("[SAVES] INFO: No files locally, downloading")
			return _download(path, downloadable, out)
		var updated_local := local.filter(func(f): return float(f["t"]) > ts)
		var updated_cloud := downloadable.filter(func(f): return float(f["t"]) > ts)
		var local_paths := local.map(func(f): return f["rel"])
		var cloud_paths := cloud_files.map(func(f): return f["rel"])
		var not_local := downloadable.filter(func(f): return not f["rel"] in local_paths)
		var not_remote := local.filter(func(f): return not f["rel"] in cloud_paths)
		var action := "none"
		if updated_local.is_empty() and not updated_cloud.is_empty():
			action = "download"
		elif not updated_local.is_empty() and updated_cloud.is_empty():
			action = "upload"
		elif not updated_local.is_empty():
			action = "conflict"
		if prefer == "forceupload":
			out.append("[SAVES] WARNING: Forcing upload")
			updated_local = local
			action = "upload"
		elif prefer == "forcedownload":
			out.append("[SAVES] WARNING: Forcing download")
			updated_cloud = downloadable
			action = "download"
		if prefer == "upload" and action == "download":
			out.append("[SAVES] WARNING: Refused to upload files, newer files in the cloud")
			out.append(str(args[args.find("--ts") + 1]))
			return {"code": 0, "out": "\n".join(out) + "\n"}
		if prefer == "download" and action == "upload":
			out.append("[SAVES] WARNING: Refused to download files, newer files locally")
			out.append(str(args[args.find("--ts") + 1]))
			return {"code": 0, "out": "\n".join(out) + "\n"}
		match action:
			"upload":
				out.append("[SAVES] INFO: Uploading files")
				for f in updated_local:
					if not _upload(name, f):
						return {"code": 124, "out": "\n".join(out) + "\n"}
				for f in not_local:
					out.append("[SAVES] INFO: DELETING IN CLOUD %s %s" % [f["hash"], f["rel"]])
					did.append("delete cloud " + str(f["rel"]))
					cloud.erase(f["key"])
			"download":
				out.append("[SAVES] INFO: Downloading files")
				var r := _download(path, updated_cloud, out, false)
				if int(r["code"]) != 0:
					return r
				for f in not_remote:
					out.append("[SAVES] INFO: DELETING LOCALLY %s" % f["abs"])
					did.append("delete local " + str(f["rel"]))
					DirAccess.remove_absolute(str(f["abs"]))
			"conflict":
				out.append("[SAVES] WARNING: Files in conflict force downloading or uploading of files")
			"none":
				out.append("[SAVES] INFO: Nothing to do")
		return _end(out)

	func _upload(name: String, f: Dictionary) -> bool:
		if cut_upload_after >= 0 and _sent >= cut_upload_after:
			return false
		_sent += 1
		var data := FileAccess.get_file_as_string(str(f["abs"]))
		cloud[name + "/" + str(f["rel"])] = {"data": data, "t": now, "lt": int(f["t"]), "hash": data.md5_text()}
		did.append("upload " + str(f["rel"]))
		return true

	func _download(path: String, list: Array, out: PackedStringArray, finish := true) -> Dictionary:
		var n := 0
		for f in list:
			var c: Dictionary = cloud[f["key"]]
			var dest := path.path_join(str(f["rel"]))
			if cut_download_after >= 0 and n >= cut_download_after:
				preload("res://tests/fixtures/saves/fake_clouds.gd").put(dest, str(c["data"]).left(1))
				return {"code": 124, "out": "\n".join(out) + "\n"}
			preload("res://tests/fixtures/saves/fake_clouds.gd").put(dest, str(c["data"]), int(c["lt"]))
			did.append("download " + str(f["rel"]))
			n += 1
		return _end(out) if finish else {"code": 0, "out": ""}

	func _end(out: PackedStringArray) -> Dictionary:
		# the timestamp is stdout without a newline; the log's last line follows on stderr
		return {"code": 0, "out": "\n".join(out) + "\n%d.5[SAVES] INFO: Done\n" % now}


class Epic extends RefCounted:
	## Cloud saves, oldest first: {"t": the manifest's time, "files": {rel: data}}. Epic keeps them all.
	var saves: Array = []
	## legendary's config folder (installed.json holds the save path) and the app.
	var config := ""
	var app := ""
	## What legendary computes the save folder as when none is kept yet.
	var computed := ""
	var did: Array = []
	## A download that is cut off after the old files are gone and one new file is half written.
	var cut_download := false
	## An upload killed before its manifest went up (legendary writes the manifest last).
	var cut_upload := false
	var offline := false

	func save_path() -> String:
		var j: Variant = JSON.parse_string(FileAccess.get_file_as_string(config.path_join("installed.json")))
		return str(Dictionary(Dictionary(j).get(app, {})).get("save_path", "")) if j is Dictionary else ""

	func _keep_path(p: String) -> void:
		var j: Variant = JSON.parse_string(FileAccess.get_file_as_string(config.path_join("installed.json")))
		var d: Dictionary = j if j is Dictionary else {}
		var g: Dictionary = d.get(app, {})
		g["save_path"] = p
		d[app] = g
		var f := FileAccess.open(config.path_join("installed.json"), FileAccess.WRITE)
		f.store_string(JSON.stringify(d))
		f.close()

	static func _utc(t: int) -> String:
		return Time.get_datetime_string_from_unix_time(t, true)

	func run(args: Array) -> Dictionary:
		if offline:
			return {"code": 1, "out": "[cli] ERROR: Login failed! Cannot continue with download process.\n"}
		var Fx := preload("res://tests/fixtures/saves/fake_clouds.gd")
		var out := PackedStringArray()
		var latest: Dictionary = saves[-1] if not saves.is_empty() else {}
		out.append("[cli] INFO: Got %d remote save game(s)" % (1 if not latest.is_empty() else 0))
		out.append("[cli] INFO: Checking \"%s\" (%s)" % [app, app])
		var path := save_path()
		var over := args.find("--save-path")
		if over >= 0:
			path = str(args[over + 1])
			out.append("[cli] INFO: Overriding save path with \"%s\"..." % path)
			_keep_path(path)
		if path == "":
			if "-y" in args and not "--accept-path" in args:
				out.append("[cli] INFO: Save path for this title has not been set, skipping due to --yes")
				return {"code": 0, "out": "\n".join(out) + "\n"}
			path = computed
			out.append("[cli] INFO: Computed save path: \"%s\"" % path)
			DirAccess.make_dir_recursive_absolute(path)
			_keep_path(path)
		var newest := 0
		for rel in Fx.walk(path):
			newest = maxi(newest, int(FileAccess.get_modified_time(path.path_join(rel))))
		var remote := int(latest.get("t", 0))
		var res := ""
		if newest == 0 and latest.is_empty():
			out.append("[cli] INFO: No cloud or local savegame found.")
			return {"code": 0, "out": "\n".join(out) + "\n"}
		if latest.is_empty():
			res = "local"
		elif newest == 0:
			res = "remote"
		elif absi(newest - remote) < 60:
			res = "same"
		else:
			res = "local" if newest > remote else "remote"
		var force_up := "--force-upload" in args
		var force_down := "--force-download" in args
		if res == "same" and not (force_up or force_down):
			out.append("[cli] INFO: Save game for \"%s\" is up to date, skipping..." % app)
			return {"code": 0, "out": "\n".join(out) + "\n"}
		if (res == "remote" and not force_up) or force_down:
			if res == "remote":
				out.append("[cli] INFO: Cloud save for \"%s\" is newer:" % app)
				out.append("[cli] INFO: - Cloud save date: " + _utc(remote).replace("T", " "))
				out.append("[cli] INFO: - Local save date: " + (_utc(newest).replace("T", " ") if newest > 0 else "N/A"))
			if "--skip-download" in args:
				out.append("[cli] INFO: Save game downloading is disabled, skipping...")
				return {"code": 0, "out": "\n".join(out) + "\n"}
			out.append("[cli] INFO: Downloading remote savegame...")
			for rel in Fx.walk(path):
				DirAccess.remove_absolute(path.path_join(rel))
			var n := 0
			for rel in latest["files"]:
				if cut_download and n == 0:
					Fx.put(path.path_join(rel), str(latest["files"][rel]).left(1))
					return {"code": 124, "out": "\n".join(out) + "\n"}
				Fx.put(path.path_join(rel), str(latest["files"][rel]), remote)
				n += 1
			did.append("download %d" % remote)
		elif res == "local" or force_up:
			if res == "local":
				out.append("[cli] INFO: Local save for \"%s\" is newer" % app)
				out.append("[cli] INFO: - Cloud save date: " + (_utc(remote).replace("T", " ") if remote > 0 else "N/A"))
				out.append("[cli] INFO: - Local save date: " + _utc(newest).replace("T", " "))
			if "--skip-upload" in args:
				out.append("[cli] INFO: Save game uploading is disabled, skipping...")
				return {"code": 0, "out": "\n".join(out) + "\n"}
			out.append("[cli] INFO: Uploading local savegame...")
			if cut_upload:
				return {"code": 124, "out": "\n".join(out) + "\n"}
			var files := {}
			for rel in Fx.walk(path):
				files[rel] = FileAccess.get_file_as_string(path.path_join(rel))
			# the manifest is named by the newest file's time, and the newest name is "the" cloud save
			saves.append({"t": newest, "files": files})
			saves.sort_custom(func(a, b): return int(a["t"]) < int(b["t"]))
			did.append("upload %d" % newest)
		return {"code": 0, "out": "\n".join(out) + "\n"}
