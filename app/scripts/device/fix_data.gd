extends RefCounted
## Fix definitions: the ones built into this GameCove (res://data/fixes.json, generated from
## fixes/<id>/fix.json) and the nightly "fixes" data release laid over them, so a handheld learns
## that a fix is no longer needed, or was withdrawn, without a GameCove update (docs/FIXES.md).
##
## The release is data only. It can change a known fix's lifecycle rules, withdraw it, and update
## its words, sources and audit notes; it can add advice (text). It can never add or change what
## runs as root: scripts come with GameCove itself, and who a fix is offered to (its selectors),
## its kind and its password rule always come from the built-in definition.
##
## It is used only when cosign proved, on this device, that the data repo's .github/workflows/fixes.yml
## signed it on main (no cosign, a bad signature, an unknown schema, or a file older than the one already
## held: the built-in definitions stay in charge). Pure static functions; fixes.gd runs the
## commands (fetch_steps) through its runner.

const SettingsFile := preload("res://scripts/system/settings_file.gd")

const BUNDLED := "res://data/fixes.json"
const DataRepo := preload("res://scripts/system/data_repo.gd")
## The rolling "fixes" release of the data repo (data_repo.gd: the one place the app names it).
const URL := DataRepo.FIXES_URL
## The schema this build understands. A release with another one is ignored whole.
const SCHEMA := 1
const MAX_BYTES := 2 * 1024 * 1024
const CHECK_EVERY_S := 24 * 3600
const SIGNER_IDENTITY := DataRepo.FIXES_SIGNER
const OIDC_ISSUER := DataRepo.OIDC_ISSUER
const FILE := "fixes.json"
const VERIFIED_SUFFIX := ".verified"
## What the release may change on a fix this build knows.
const OVERLAY_KEYS := ["title", "line", "symptom", "why", "risk", "risk_note", "tested", "bazzite", "steamos",
	"sources", "lifecycle", "withdrawn", "audited", "audit"]
const OVERLAY_TYPES := {"title": TYPE_STRING, "line": TYPE_STRING, "symptom": TYPE_STRING, "why": TYPE_STRING,
	"risk": TYPE_STRING, "risk_note": TYPE_STRING, "tested": TYPE_ARRAY, "bazzite": TYPE_STRING, "steamos": TYPE_STRING,
	"sources": TYPE_ARRAY, "lifecycle": TYPE_DICTIONARY, "audited": TYPE_STRING, "audit": TYPE_DICTIONARY}


## {"schema", "built", "serial", "fixes": [...]} from JSON text, or {} when it isn't a schema-1 document.
static func parse(text: String) -> Dictionary:
	if text.length() > MAX_BYTES:
		return {}
	var j := JSON.new()
	if j.parse(text) != OK or not j.data is Dictionary:
		return {}
	var d: Dictionary = j.data
	if not d.has("schema") or not (d["schema"] is float or d["schema"] is int) or int(d["schema"]) != SCHEMA or float(d["schema"]) != float(SCHEMA):
		return {}
	if not d.get("fixes") is Array:
		return {}
	d["fixes"] = (d["fixes"] as Array).filter(func(e): return e is Dictionary and _id_ok(str(e.get("id", ""))))
	return d


static func _id_ok(id: String) -> bool:
	return RegEx.create_from_string("^[a-z0-9][a-z0-9-]{1,63}$").search(id) != null


static func bundled(path := BUNDLED) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	return parse(f.get_as_text()) if f != null else {}


## The release held in `dir`, only when it is the very file cosign accepted (its sha256 is in
## fixes.json.verified); {} otherwise.
static func cached(dir: String) -> Dictionary:
	var path := dir.path_join(FILE)
	if not FileAccess.file_exists(path) or not FileAccess.file_exists(path + VERIFIED_SUFFIX):
		return {}
	if FileAccess.get_file_as_string(path + VERIFIED_SUFFIX).strip_edges() != FileAccess.get_sha256(path):
		return {}
	return parse(FileAccess.get_file_as_string(path))


static func serial(doc: Dictionary) -> int:
	return int(doc.get("serial", 0)) if (doc.get("serial") is float or doc.get("serial") is int) else 0


static func _withdrawn_ok(v: Variant) -> bool:
	return v == null or (v is Dictionary and v.get("reason") is String and v.get("date") is String)


## The built-in definitions with the release laid over them. Each entry gets "remote": true when
## the release changed it, and "newer_revision": true when the release describes a newer revision
## of the fix than the script this GameCove carries.
static func merge(built_in: Array, remote: Dictionary) -> Array:
	var by := {}
	for e in remote.get("fixes", []) if remote.get("fixes") is Array else []:
		if e is Dictionary:
			by[str(e.get("id", ""))] = e
	var out: Array = []
	var seen := {}
	for e in built_in:
		var m: Dictionary = (e as Dictionary).duplicate(true)
		seen[str(m.get("id", ""))] = true
		var r: Variant = by.get(str(m.get("id", "")))
		if r is Dictionary:
			for k in OVERLAY_KEYS:
				if not r.has(k):
					continue
				if k == "withdrawn":
					if _withdrawn_ok(r[k]):
						m[k] = r[k]
				elif typeof(r[k]) == OVERLAY_TYPES[k]:
					m[k] = r[k]
			m["remote"] = true
			if int(r.get("revision", 0)) > int(m.get("revision", 1)):
				m["newer_revision"] = true
		out.append(m)
	# advice the release adds: text only, never anything to apply
	for id in by:
		var r: Dictionary = by[id]
		if seen.has(id) or str(r.get("kind", "")) != "advice":
			continue
		if not (r.get("title") is String and r.get("line") is String and r.get("sources") is Array):
			continue
		out.append({"id": id, "kind": "advice", "page": "fixes", "password": "none", "restart": "",
			"title": str(r["title"]), "line": str(r["line"]), "symptom": str(r.get("symptom", "")), "why": str(r.get("why", "")),
			"level": "optional", "must_fix": true, "breaks": str(r.get("breaks", "")), "default": "advice-only",
			"risk": "low", "risk_note": "", "auto": [], "optional": r.get("optional", []), "exclude": {},
			"changes": [], "undo": "", "tested": [], "bazzite": str(r.get("bazzite", "")), "steamos": str(r.get("steamos", "")),
			"sources": r["sources"], "lifecycle": r.get("lifecycle", {}) if r.get("lifecycle") is Dictionary else {},
			"watch": [], "withdrawn": r.get("withdrawn") if _withdrawn_ok(r.get("withdrawn")) else null,
			"audited": str(r.get("audited", "")), "revision": 1, "remote": true})
	return out


## The three commands of a download, in order: the file, its Sigstore bundle, cosign's check.
## Each is [program, args]; the next runs only when the one before exited 0.
static func fetch_steps(dir: String, cosign: String) -> Array:
	var part := dir.path_join(FILE + ".part")
	var bundle := part + ".sigstore.json"
	var curl := ["--proto", "=https", "--proto-redir", "=https", "-fsSL", "--max-filesize", str(MAX_BYTES)]
	return [
		["curl", PackedStringArray(curl + ["--max-time", "60", "-o", part, "--", URL])],
		["curl", PackedStringArray(curl + ["--max-time", "20", "-o", bundle, "--", URL + ".sigstore.json"])],
		[cosign, PackedStringArray(["verify-blob", "--bundle", bundle, "--certificate-oidc-issuer", OIDC_ISSUER,
			"--certificate-identity-regexp", SIGNER_IDENTITY, part])],
	]


static func discard(dir: String) -> void:
	for f in [FILE + ".part", FILE + ".part.sigstore.json"]:
		if FileAccess.file_exists(dir.path_join(f)):
			DirAccess.remove_absolute(dir.path_join(f))


## After cosign said yes: keep the download when it is a schema-1 document no older than the
## one already held. "verified" | "schema" | "older" | "missing".
static func accept(dir: String) -> String:
	var part := dir.path_join(FILE + ".part")
	if not FileAccess.file_exists(part):
		return "missing"
	var doc := parse(FileAccess.get_file_as_string(part))
	var result := "verified"
	if doc.is_empty():
		result = "schema"
	elif serial(doc) < serial(cached(dir)):
		result = "older"   # a replayed old file must not bring a withdrawn fix back
	if result == "verified":
		var sha := FileAccess.get_sha256(part)
		DirAccess.rename_absolute(part, dir.path_join(FILE))
		SettingsFile.save_text(dir.path_join(FILE) + VERIFIED_SUFFIX, sha + "\n")
	discard(dir)
	return result
