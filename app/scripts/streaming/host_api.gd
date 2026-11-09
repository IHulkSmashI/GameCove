extends RefCounted
## The few GameStream HTTP(S) calls GameCove makes itself, as curl commands run
## through the command runner (tests answer them from fixtures). curl ships on
## Bazzite and SteamOS; Godot's HTTPClient can't present a client certificate,
## and the paired calls need Moonlight's.
##
##   serverinfo over HTTP (47989): is the PC there, its name, uuid, codecs; the
##     TCP connect time is our latency estimate.
##   serverinfo over HTTPS (47984) with Moonlight's certificate: MAC (for
##     Wake-on-LAN), the app running now, Apollo/Vibepollo permissions.
##   applist / appasset over HTTPS: the PC's apps and their box art.
##   power-actions/v1/sleep (Vibepollo): put the PC to sleep, if the PC allows
##     this device to.
##
## -k: the PC's certificate is self-signed and doesn't name its address
## (Moonlight pins it instead). We only read lists and pictures this way, and
## send nothing secret: the client certificate is public by design.

const GameStream := preload("res://scripts/streaming/gamestream.gd")

## The line curl adds after the body: http code and connect time in seconds.
const MARK := "\n@@gamecove %{http_code} %{time_connect}"
const CONNECT_TIMEOUT_S := 2
const MAX_TIME_S := 4


static func _base(timeout := MAX_TIME_S) -> Array:
	return ["-s", "-S", "--connect-timeout", str(CONNECT_TIMEOUT_S), "-m", str(timeout), "-w", MARK]


static func _auth(identity: Dictionary) -> Array:
	return ["-k", "--cert", str(identity.get("cert", "")), "--key", str(identity.get("key", ""))]


static func serverinfo_http(address: String, port: int) -> Array:
	return ["curl"] + _base() + ["http://%s:%d/serverinfo?uniqueid=%s" % [GameStream.url_host(address), port, GameStream.UNIQUE_ID]]


static func serverinfo_https(address: String, port: int, identity: Dictionary) -> Array:
	return ["curl"] + _base() + _auth(identity) + ["https://%s:%d/serverinfo?uniqueid=%s" % [GameStream.url_host(address), port, GameStream.UNIQUE_ID]]


static func applist(address: String, port: int, identity: Dictionary) -> Array:
	return ["curl"] + _base(8) + _auth(identity) + ["https://%s:%d/applist?uniqueid=%s" % [GameStream.url_host(address), port, GameStream.UNIQUE_ID]]


## Box art (PNG) straight into `out_file`; AssetType=2 AssetIdx=0 is the cover.
static func appasset(address: String, port: int, identity: Dictionary, app_id: int, out_file: String) -> Array:
	return ["curl"] + _base(10) + _auth(identity) + ["-o", out_file,
		"https://%s:%d/appasset?uniqueid=%s&appid=%d&AssetType=2&AssetIdx=0" % [GameStream.url_host(address), port, GameStream.UNIQUE_ID, app_id]]


static func sleep_pc(address: String, port: int, identity: Dictionary) -> Array:
	return ["curl"] + _base() + _auth(identity) + ["-X", "POST",
		"https://%s:%d/power-actions/v1/sleep?uniqueid=%s" % [GameStream.url_host(address), port, GameStream.UNIQUE_ID]]


## A runner answer split into {"ok": reached and 2xx, "code": http status (0 = no answer),
## "body", "ms": connect time in ms (-1 unknown)}.
static func split(res: Dictionary) -> Dictionary:
	var out: String = str(res.get("out", ""))
	var at := out.rfind("@@gamecove ")
	var body := out
	var http := 0
	var ms := -1
	if at >= 0:
		body = out.substr(0, at).trim_suffix("\n")
		var f := out.substr(at + 11).strip_edges().split(" ")
		http = f[0].to_int()
		if f.size() > 1 and f[1].is_valid_float() and http > 0:
			ms = int(roundf(f[1].to_float() * 1000.0))
	return {"ok": int(res.get("code", 1)) == 0 and http >= 200 and http < 300, "code": http, "body": body, "ms": ms}
