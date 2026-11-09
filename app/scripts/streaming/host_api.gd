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
## Trust (review M27): the PC's certificate is self-signed and doesn't name its
## address, so ordinary verification can't work (-k). Instead every HTTPS call is
## pinned, as Moonlight does: --pinnedpubkey with the public key of the certificate
## Moonlight stored for this PC when it paired (trust on first use, Moonlight.conf
## hosts\N\srvcert). curl checks the pin even with -k and refuses any other server.
## No pin (never paired): no HTTPS call is made at all.

const GameStream := preload("res://scripts/streaming/gamestream.gd")

## The line curl adds after the body: http code and connect time in seconds.
const MARK := "\n@@gamecove %{http_code} %{time_connect}"
const CONNECT_TIMEOUT_S := 2
const MAX_TIME_S := 4


static func _base(timeout := MAX_TIME_S) -> Array:
	return ["-s", "-S", "--connect-timeout", str(CONNECT_TIMEOUT_S), "-m", str(timeout), "-w", MARK]


## identity: {"cert", "key": Moonlight's client certificate files, "pin": "sha256//<base64>" of the PC's key}.
## Without a pin the call is pinned to an impossible key, so it fails closed instead of trusting anything.
static func _auth(identity: Dictionary) -> Array:
	var pin := str(identity.get("pin", ""))
	if not pin.begins_with("sha256//"):
		pin = "sha256//" + "A".repeat(43) + "="
	return ["-k", "--pinnedpubkey", pin, "--cert", str(identity.get("cert", "")), "--key", str(identity.get("key", ""))]


## curl's --pinnedpubkey value for a PEM certificate: "sha256//" + base64(sha256(SubjectPublicKeyInfo DER)),
## or "" when the PEM isn't a certificate we can read.
static func pin_for_pem(pem: String) -> String:
	var b := pem.find("-----BEGIN CERTIFICATE-----")
	var e := pem.find("-----END CERTIFICATE-----")
	if b < 0 or e <= b:
		return ""
	var body := pem.substr(b + 27, e - b - 27).replace("\n", "").replace("\r", "").replace(" ", "")
	var der := Marshalls.base64_to_raw(body)
	var spki := spki_of(der)
	if spki.is_empty():
		return ""
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(spki)
	return "sha256//" + Marshalls.raw_to_base64(ctx.finish())


## The SubjectPublicKeyInfo element (tag, length and content) of an X.509 certificate's DER, or empty.
## Certificate ::= SEQUENCE { tbsCertificate SEQUENCE { [0] version OPTIONAL, serialNumber, signature,
## issuer, validity, subject, subjectPublicKeyInfo, ... }, ... }
static func spki_of(der: PackedByteArray) -> PackedByteArray:
	var cert := _der_at(der, 0)
	if cert.is_empty() or cert["tag"] != 0x30:
		return PackedByteArray()
	var tbs := _der_at(der, cert["body"])
	if tbs.is_empty() or tbs["tag"] != 0x30:
		return PackedByteArray()
	var pos: int = tbs["body"]
	var first := _der_at(der, pos)
	if first.is_empty():
		return PackedByteArray()
	if first["tag"] == 0xA0:       # explicit version
		pos = first["end"]
	for i in 5:                     # serial, signature, issuer, validity, subject
		var el := _der_at(der, pos)
		if el.is_empty():
			return PackedByteArray()
		pos = el["end"]
	var spki := _der_at(der, pos)
	if spki.is_empty() or spki["tag"] != 0x30 or spki["end"] > tbs["end"]:
		return PackedByteArray()
	return der.slice(pos, spki["end"])


## One DER element at `pos`: {"tag", "body": content start, "end": just past it}, or {} when malformed.
static func _der_at(der: PackedByteArray, pos: int) -> Dictionary:
	if pos + 2 > der.size():
		return {}
	var tag := der[pos]
	var n_len := der[pos + 1]
	var body := pos + 2
	if n_len & 0x80:
		var n := n_len & 0x7f
		if n == 0 or n > 4 or body + n > der.size():
			return {}
		n_len = 0
		for i in n:
			n_len = (n_len << 8) | der[body + i]
		body += n
	if body + n_len > der.size():
		return {}
	return {"tag": tag, "body": body, "end": body + n_len}


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
