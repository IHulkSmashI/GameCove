extends RefCounted
## Which game stores are signed in, and the commands that sign in. Pure
## functions over files under `home`; Setup runs the commands on its worker.
##
## Sign-in flows (read from each tool's source, see docs/SYSTEM.md):
##   steam   Steam's own client. We only read config/loginusers.vdf.
##   epic    legendary: open https://legendary.gl/epiclogin (redirects to Epic's
##           login, then shows JSON with "authorizationCode"), then
##           `legendary auth --code <code>` (legendary/cli.py).
##   gog     heroic-gogdl: open GOG's OAuth page (Heroic's client id); after sign
##           in GOG redirects to embed.gog.com/on_login_success?...&code=<code>;
##           `gogdl --auth-config-path <heroic>/gog_store/auth.json auth --code <code>`.
##   amazon  nile: `nile auth --login --non-interactive` prints JSON {client_id,
##           code_verifier, serial, url}; after sign in Amazon redirects to
##           amazon.com/?openid.oa2.authorization_code=<code>...; then
##           `nile register --code .. --client-id .. --code-verifier .. --serial ..`.
## None of them has a device-code flow: the person signs in on a phone (QR of
## the URL) and types the code back. Codes are passed as arguments, as Heroic does.

const SteamStore := preload("res://scripts/library/stores/steam.gd")
const Epic := preload("res://scripts/library/stores/epic.gd")
const Amazon := preload("res://scripts/library/stores/amazon.gd")
const Common := preload("res://scripts/library/stores/common.gd")
const Vdf := preload("res://scripts/launch/vdf.gd")

const STORES: Array[String] = ["steam", "epic", "gog", "amazon"]
const EPIC_LOGIN_URL := "https://legendary.gl/epiclogin"
const GOG_CLIENT_ID := "46899977096215655"
const GOG_LOGIN_URL := "https://auth.gog.com/auth?client_id=46899977096215655&redirect_uri=https%3A%2F%2Fembed.gog.com%2Fon_login_success%3Forigin%3Dclient&response_type=code&layout=galaxy"


## Steam's loginusers.vdf: the most recent account's persona name, "" if none.
static func steam_account(vdf_text: String) -> String:
	var users := Vdf.find_ci(Vdf.parse(vdf_text), "users")
	var first := ""
	for id in users:
		var u: Variant = users[id]
		if not u is Dictionary:
			continue
		var name := str(Vdf.get_ci(u, "PersonaName", Vdf.get_ci(u, "AccountName", "")))
		if first == "":
			first = name if name != "" else id
		if str(Vdf.get_ci(u, "MostRecent", "0")) == "1":
			return name if name != "" else id
	return first


static func gogdl_path(path_env: String) -> String:
	var p := Common.which("gogdl", path_env)
	if p != "":
		return p
	for dir in Common.HEROIC_BIN_DIRS:
		if FileAccess.file_exists(dir + "/gogdl"):
			return dir + "/gogdl"
	return ""


## Per store: {"signed_in": bool, "account": String, "tool": path or "",
##  "how": steam|code|redirect_url|heroic|unavailable, "config": folder used}.
## how = what start_login() will ask for; "heroic" = sign in from Heroic in
## Desktop Mode (no CLI tool we can run), "unavailable" = store tool missing.
static func status(home: String, path_env: String) -> Dictionary:
	var tools := Common.find_tools(home, path_env)
	var out := {}
	# Steam
	var steam := {"signed_in": false, "account": "", "tool": Common.which("steam", path_env), "how": "steam", "config": ""}
	for r in SteamStore.STEAM_ROOTS:
		var root := SteamStore.expand(r, home)
		var vdf := root + "/config/loginusers.vdf"
		if FileAccess.file_exists(vdf):
			var acct := steam_account(FileAccess.get_file_as_string(vdf))
			if acct != "":
				steam["signed_in"] = true
				steam["account"] = acct
				steam["config"] = root
				break
	out["steam"] = steam
	# Epic (legendary; Heroic's copy first, as the library reads it)
	var epic := {"signed_in": false, "account": "", "tool": tools["legendary"], "how": "code", "config": ""}
	var epic_dirs := Epic.config_dirs(home)
	for d in epic_dirs:
		var user = Common.read_json(d["dir"] + "/user.json", {})
		if user is Dictionary and str(user.get("displayName", "")) != "":
			epic["signed_in"] = true
			epic["account"] = str(user["displayName"])
			epic["config"] = d["dir"]
			break
	if epic["config"] == "":
		epic["config"] = epic_dirs[0]["dir"] if not epic_dirs.is_empty() else home + "/.config/legendary"
	if epic["tool"] == "":
		epic["how"] = "heroic" if not Common.heroic_roots(home).is_empty() else "unavailable"
	out["epic"] = epic
	# GOG (Heroic's gogdl auth file; our library reads GOG only from Heroic)
	var gog := {"signed_in": false, "account": "", "tool": gogdl_path(path_env), "how": "code", "config": ""}
	var roots := Common.heroic_roots(home)
	for h in roots:
		var auth = Common.read_json(h["root"] + "/gog_store/auth.json", {})
		if auth is Dictionary and auth.get(GOG_CLIENT_ID) is Dictionary:
			gog["signed_in"] = true
			gog["config"] = h["root"] + "/gog_store/auth.json"
			var info = Common.read_json(h["root"] + "/store/config.json", {})
			if info is Dictionary and info.get("userData") is Dictionary:
				gog["account"] = str(info["userData"].get("username", ""))
			break
	if gog["config"] == "" and not roots.is_empty():
		gog["config"] = roots[0]["root"] + "/gog_store/auth.json"
	if roots.is_empty():
		gog["how"] = "unavailable"
	elif gog["tool"] == "":
		gog["how"] = "heroic"
	out["gog"] = gog
	# Amazon (nile)
	var amz := {"signed_in": false, "account": "", "tool": tools["nile"], "how": "redirect_url", "config": ""}
	var amz_dirs := Amazon.config_dirs(home)
	for d in amz_dirs:
		var cur = Common.read_json(d["dir"] + "/current_user.json", {})
		if cur is Dictionary and str(cur.get("user_id", "")) != "":
			amz["signed_in"] = true
			amz["account"] = str(cur.get("name", ""))
			amz["config"] = d["dir"]
			break
	if amz["config"] == "":
		amz["config"] = amz_dirs[0]["dir"] if not amz_dirs.is_empty() else home + "/.config/nile"
	if amz["tool"] == "":
		amz["how"] = "heroic" if not roots.is_empty() else "unavailable"
	out["amazon"] = amz
	return out


## legendary reads LEGENDARY_CONFIG_PATH; nile reads NILE_CONFIG_PATH and adds "/nile".
static func env_for(store: String, config_dir: String, home: String) -> Dictionary:
	if store == "epic" and config_dir != home + "/.config/legendary":
		return {"LEGENDARY_CONFIG_PATH": config_dir}
	if store == "amazon" and config_dir != home + "/.config/nile":
		return {"NILE_CONFIG_PATH": config_dir.get_base_dir()}
	return {}


## Wraps a command in `env K=V ...` when env is not empty.
static func with_env(env: Dictionary, cmd: Array) -> Array:
	if env.is_empty():
		return cmd
	return Common.with_env(env, cmd)


## Epic: the authorizationCode from what the person typed (a bare code, a
## quoted code or the whole JSON page).
static func epic_code(text: String) -> String:
	var t := text.strip_edges()
	if t.begins_with("{"):
		var d: Variant = _json(t)
		if d is Dictionary:
			return str(d.get("authorizationCode", "")).strip_edges()
		var re := RegEx.new()
		re.compile("\"authorizationCode\"\\s*:\\s*\"([^\"]+)\"")
		var m := re.search(t)
		return m.get_string(1) if m else ""
	return t.strip_edges().trim_prefix("\"").trim_suffix("\"")


## A query parameter from a pasted URL, or the text itself when it has no "=".
static func code_from(text: String, param: String) -> String:
	var t := text.strip_edges()
	var i := t.find(param + "=")
	if i < 0:
		return "" if "=" in t or "/" in t else t
	var v := t.substr(i + param.length() + 1)
	var amp := v.find("&")
	if amp >= 0:
		v = v.substr(0, amp)
	var hash := v.find("#")
	if hash >= 0:
		v = v.substr(0, hash)
	return v.uri_decode()


## nile's --non-interactive login JSON: {client_id, code_verifier, serial, url} or {}.
static func nile_login_data(text: String) -> Dictionary:
	for line in text.split("\n", false):
		var l := line.strip_edges()
		if l.begins_with("{"):
			var d: Variant = _json(l)
			if d is Dictionary and d.has("url") and d.has("code_verifier"):
				return d
	return {}


## JSON.parse_string without the engine's error line on bad input.
static func _json(text: String) -> Variant:
	var j := JSON.new()
	return j.data if j.parse(text) == OK else null
