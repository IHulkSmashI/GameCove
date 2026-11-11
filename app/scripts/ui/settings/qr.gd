extends RefCounted
## QR codes for store sign-in addresses. Encoding by kenyoni-software's MIT
## QR encoder (app/addons/kenyoni/qr_code, see its README.GameCove.md).

const QRCode := preload("res://addons/kenyoni/qr_code/qr_code.gd")


## Module matrix for `text` (byte mode, medium error correction), row by row:
## 1 = dark. Empty when it can't be encoded.
static func modules(text: String) -> Dictionary:
	if text == "":
		return {"size": 0, "data": PackedByteArray()}
	var q := QRCode.new(QRCode.ErrorCorrection.MEDIUM)
	q.put_byte(text.to_utf8_buffer())
	var raw: PackedByteArray = q.encode()
	var n := int(sqrt(raw.size()))
	var data := PackedByteArray()
	data.resize(raw.size())
	for i in raw.size():
		data[i] = 1 if raw[i] == 1 else 0
	return {"size": n, "data": data}


## A crisp texture: `px` per module, a 4-module quiet zone, dark on light
## (phones read dark-on-light best, so this ignores the theme on purpose).
static func texture(text: String, px := 6, dark := Color(0.04, 0.06, 0.1), light := Color.WHITE) -> Texture2D:
	var m := modules(text)
	var n: int = m["size"]
	if n == 0:
		return null
	var quiet := 4
	var side := (n + quiet * 2) * px
	var img := Image.create_empty(side, side, false, Image.FORMAT_RGB8)
	img.fill(light)
	var data: PackedByteArray = m["data"]
	for y in n:
		for x in n:
			if data[y * n + x] == 1:
				img.fill_rect(Rect2i((x + quiet) * px, (y + quiet) * px, px, px), dark)
	return ImageTexture.create_from_image(img)


## Puts the code on a TextureRect with nearest filtering: the modules stay hard-edged at any scale
## (a 4K screen draws a 205 px code 2.7 times bigger; linear filtering would blur every edge).
static func show_on(rect: TextureRect, text: String, px := 6) -> void:
	rect.texture = texture(text, px)
	rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
