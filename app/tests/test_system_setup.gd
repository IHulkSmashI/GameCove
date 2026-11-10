extends "res://tests/test_case.gd"
## Setup checklist persistence, store sign-in status and flows, device fixes.
## Commands go to the fake runner; files to user://test_setup.

const SetupScript := preload("res://scripts/system/setup.gd")
const Login := preload("res://scripts/system/store_login.gd")
const Fake := preload("res://tests/fixtures/system/fake_runner.gd")

const CLAW := {"id": "msi-claw-8-ex", "fixes": ["claw8ex-buttons", "claw8ex-vrr", "claw8ex-gyro"]}


func _dir(test_name: String) -> String:
	var d := ProjectSettings.globalize_path("user://test_setup/" + test_name)
	_rmdir(d)
	DirAccess.make_dir_recursive_absolute(d)
	return d


func _rmdir(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	d.include_hidden = true
	for f in d.get_files():
		DirAccess.remove_absolute(path + "/" + f)
	for sub in d.get_directories():
		_rmdir(path + "/" + sub)
	DirAccess.remove_absolute(path)


func _copy(src: String, dst: String) -> void:
	DirAccess.make_dir_recursive_absolute(dst)
	var d := DirAccess.open(src)
	d.include_hidden = true
	for f in d.get_files():
		DirAccess.copy_absolute(src + "/" + f, dst + "/" + f)
	for sub in d.get_directories():
		_copy(src + "/" + sub, dst + "/" + sub)


func _setup(test_name: String, fake: RefCounted, home := "") -> Node:
	var d := _dir(test_name)
	var s: Node = SetupScript.new()
	s.setup(fake, home if home != "" else fixture("system/home"), d + "/setup.cfg", CLAW, fixture("system/bin"))
	return s


func test_first_run_steps_and_persistence() -> void:
	var s := _setup("persist", Fake.new())
	ok(s.is_first_run(), "first run")
	eq(s.next_step(), "welcome")
	ok(s.complete("welcome"), "complete")
	eq(s.next_step(), "theme")
	ok(s.skip("theme"), "theme is optional")
	ok(not s.skip("welcome"), "welcome can't be skipped")
	ok(not s.complete("nope"), "unknown step")
	eq(s.next_step(), "stores")
	var steps: Array = s.steps()
	eq(steps.map(func(x): return x["id"]), ["welcome", "theme", "stores", "steamgriddb", "keys", "device_fixes", "done"])
	ok(steps[1]["skipped"] and steps[1]["optional"], "theme skipped")
	ok(s.complete("done"), "done")
	ok(not s.is_first_run(), "finished")
	# a new instance reads the same file
	var again: Node = SetupScript.new()
	again.setup(Fake.new(), fixture("system/home"), s.config_path, CLAW)
	ok(again.is_done("welcome") and again.is_skipped("theme") and not again.is_first_run(), "persisted")
	again.reset()
	ok(again.is_first_run(), "reset")
	s.free()
	again.free()


func test_steamgriddb_key() -> void:
	var s := _setup("sgdb", Fake.new())
	ok(not s.set_steamgriddb_key("short"), "rejected")
	ok(s.set_steamgriddb_key("0123456789abcdef0123456789ABCDEF"), "32 hex")
	eq(s.steamgriddb_key(), "0123456789abcdef0123456789ABCDEF")
	ok(s.steps()[3]["status"]["has_key"], "status")
	var perms := FileAccess.get_unix_permissions(ProjectSettings.globalize_path(s.config_path))
	eq(perms & 0x3F, 0, "setup.cfg (it holds the key) is readable by this user only")
	ok(s.set_steamgriddb_key(""), "removed")
	eq(s.steamgriddb_key(), "")
	s.free()


func test_store_status_reads_each_store() -> void:
	var st := Login.status(fixture("system/home"), fixture("system/bin"))
	ok(st["steam"]["signed_in"], "steam")
	eq(st["steam"]["account"], "HulkSmash")
	ok(st["epic"]["signed_in"], "epic via Heroic's legendary")
	eq(st["epic"]["account"], "HulkEpic")
	ok(st["epic"]["config"].ends_with("/.config/heroic/legendaryConfig/legendary"), "Heroic's copy")
	ok(st["gog"]["signed_in"], "gog")
	eq(st["gog"]["tool"], fixture("system/bin") + "/gogdl")
	ok(not st["amazon"]["signed_in"], "amazon not signed in")
	eq(st["amazon"]["how"], "redirect_url")
	ok(st["amazon"]["config"].ends_with("/nile_config/nile"), "Heroic's nile folder")


func test_store_status_without_tools_or_heroic() -> void:
	var home := _dir("empty_home")
	var st := Login.status(home, home + "/nobin")
	ok(not st["steam"]["signed_in"] and not st["epic"]["signed_in"], "nothing")
	eq(st["epic"]["how"], "unavailable")
	eq(st["gog"]["how"], "unavailable")
	eq(st["steam"]["how"], "steam")


func test_code_helpers() -> void:
	eq(Login.epic_code("{\"redirectUrl\":\"x\",\"authorizationCode\":\"abc123\",\"sid\":null}"), "abc123")
	eq(Login.epic_code("  \"abc123\" "), "abc123")
	eq(Login.code_from("https://embed.gog.com/on_login_success?origin=client&code=XyZ%2D1&x=2", "code"), "XyZ-1")
	eq(Login.code_from("XyZ", "code"), "XyZ")
	eq(Login.code_from("https://www.amazon.com/?openid.oa2.authorization_code=ANabc&openid.mode=id_res", "openid.oa2.authorization_code"), "ANabc")
	eq(Login.env_for("amazon", "/h/.config/heroic/nile_config/nile", "/h"), {"NILE_CONFIG_PATH": "/h/.config/heroic/nile_config"})
	eq(Login.env_for("epic", "/h/.config/legendary", "/h"), {})


func test_epic_login_flow() -> void:
	var f: RefCounted = Fake.new()
	f.responses["env*"] = {"code": 0, "out": "[cli] INFO: Successfully logged in as \"HulkEpic\"\n"}
	var s := _setup("epic", f)
	var started: Array = []
	var done: Array = []
	s.login_started.connect(func(store, info): started.append(info))
	s.login_finished.connect(func(store, okk, msg): done.append([store, okk, msg]))
	ok(s.start_login("epic"), "started")
	eq(started[0]["url"], "https://legendary.gl/epiclogin")
	eq(started[0]["needs"], "code")
	ok(f.calls.is_empty(), "no process to start Epic's sign-in")
	ok(s.finish_login("epic", "{\"authorizationCode\":\"c0de\"}"), "finishing")
	var cmd: String = f.calls[0]
	ok(cmd.begins_with("env LEGENDARY_CONFIG_PATH=" + fixture("system/home") + "/.config/heroic/legendaryConfig/legendary "), "Heroic's legendary folder")
	ok(cmd.ends_with("/legendary auth --code c0de"), cmd)
	eq(done[0], ["epic", true, ""])
	ok(not s.finish_login("epic", "again"), "nothing pending after success")
	s.free()


func test_amazon_login_flow_checks_saved_login() -> void:
	var home := _dir("amazon_home") + "/home"
	_copy(fixture("system/home"), home)
	var f: RefCounted = Fake.new()
	var nile_dir := home + "/.config/heroic/nile_config/nile"
	f.handler = func(cmd: String):
		if cmd.ends_with("auth --login --non-interactive"):
			return {"code": 0, "out": "{\"client_id\": \"cid\", \"code_verifier\": \"ver\", \"serial\": \"SER\", \"url\": \"https://amazon.com/ap/signin?x=1\"}\n"}
		if " register " in cmd and "--code good" in cmd:
			var w := FileAccess.open(nile_dir + "/current_user.json", FileAccess.WRITE)
			w.store_string("{\"name\": \"Mena\", \"user_id\": \"amzn1.account.X\"}")
			w.close()
			return {"code": 0, "out": ""}
		if " register " in cmd:
			return {"code": 0, "out": "[AUTH] ERROR: Failed to register\n"}
		return null
	var s := _setup("amazon", f, home)
	var started: Array = []
	var done: Array = []
	s.login_started.connect(func(store, info): started.append(info))
	s.login_finished.connect(func(store, okk, msg): done.append([store, okk, msg]))
	ok(s.start_login("amazon"), "started")
	ok(f.calls[0].begins_with("env NILE_CONFIG_PATH=" + home + "/.config/heroic/nile_config "), f.calls[0])
	eq(started[0]["url"], "https://amazon.com/ap/signin?x=1")
	eq(started[0]["param"], "openid.oa2.authorization_code")
	# the tool exits 0 but no login was saved: failure
	s.finish_login("amazon", "https://www.amazon.com/?openid.oa2.authorization_code=bad&x=1")
	eq(done[0][1], false)
	s.finish_login("amazon", "https://www.amazon.com/?openid.oa2.authorization_code=good")
	ok(f.calls.back().ends_with("register --code good --client-id cid --code-verifier ver --serial SER"), f.calls.back())
	eq(done[1], ["amazon", true, ""])
	ok(s.store_status()["amazon"]["signed_in"], "signed in")
	eq(s.store_status()["amazon"]["account"], "Mena")
	s.free()


func test_steam_login_points_to_steam() -> void:
	var s := _setup("steam", Fake.new())
	var started: Array = []
	s.login_started.connect(func(store, info): started.append(info))
	ok(s.start_login("steam"), "accepted")
	eq(started[0]["needs"], "steam")
	eq(started[0]["url"], "")
	ok(not s.finish_login("steam", "x"), "nothing to finish")
	s.free()


func test_check_fixes_lists_suggested_and_present() -> void:
	var f: RefCounted = Fake.new()
	f.responses["/usr/libexec/gamecove/gamecove-fix --list"] = {"code": 0, "out": "charge-limit\nclaw8ex-gyro\nclaw8ex-vrr\nfan\n"}
	f.responses["/usr/libexec/gamecove/gamecove-fix claw8ex-gyro status"] = {"code": 0, "out": "applies=yes\ninstalled=no\nstate=off\n"}
	f.responses["/usr/libexec/gamecove/gamecove-fix claw8ex-vrr status"] = {"code": 0, "out": "applies=yes\ninstalled=yes\nstate=restart\nnext=reboot\n"}
	var s := _setup("fixes", f)
	var got: Array = []
	s.fixes_checked.connect(func(list): got.append(list))
	eq(s.suggested_fixes(), ["claw8ex-buttons", "claw8ex-vrr", "claw8ex-gyro"])
	s.check_fixes()
	var list: Array = got[0]
	eq(list.map(func(x): return x["name"]), ["claw8ex-vrr", "claw8ex-gyro"])
	eq(list[0]["state"], "restart")
	ok(list[0]["installed"] and not list[1]["installed"], "installed flags")
	ok(not f.called("pkexec"), "status needs no root")
	ok(s.steps()[5]["status"]["checked"], "step status updated")
	s.free()


func test_no_fixes_for_unknown_device() -> void:
	var f: RefCounted = Fake.new()
	var s: Node = SetupScript.new()
	s.setup(f, fixture("system/home"), _dir("nofix") + "/setup.cfg", {})
	var got: Array = []
	s.fixes_checked.connect(func(list): got.append(list))
	s.check_fixes()
	eq(got[0], [])
	eq(f.calls.size(), 0)
	s.free()
