extends RefCounted
## Loads a picture file for the UI without trusting it: art comes from SteamGridDB and the
## stores, and a few KB of PNG or WebP can name a canvas of hundreds of megapixels that
## would be decoded (and its memory taken) every time it is shown.
##
## The file's first bytes say what it is (never its name) and how big it claims to be;
## anything past the device-photo limits (photo.gd MAX_SIDE, MAX_PIXELS: every real cover,
## hero and logo is far below them) is not decoded at all. Files that aren't PNG, JPEG or
## WebP by content are only decoded when their name doesn't claim to be one of those
## (local icons in other formats; nothing we download is saved under another name).
## Static and thread-safe: called from the art worker threads.

const Photo := preload("res://scripts/device/photo.gd")

const KNOWN_EXTS := ["png", "jpg", "jpeg", "webp"]


## The size the file's header names (Vector2i.ZERO when it isn't PNG, JPEG or WebP or
## can't be read).
static func size_of(path: String) -> Vector2i:
	return Photo.image_size(FileAccess.get_file_as_bytes(path)) if FileAccess.file_exists(path) else Vector2i.ZERO


## The decoded image, or null when the file is missing, isn't a picture, or names a size
## that may not be decoded.
static func load(path: String) -> Image:
	if path == "" or not FileAccess.file_exists(path):
		return null
	var bytes := FileAccess.get_file_as_bytes(path)
	var kind := Photo.sniff_image(bytes)
	if kind == "":
		if path.get_extension().to_lower() in KNOWN_EXTS:
			return null
		var other := Image.load_from_file(path)
		return other if other != null and not other.is_empty() else null
	if not Photo.size_ok(bytes):
		return null
	var img := Image.new()
	var err := OK
	match kind:
		"png": err = img.load_png_from_buffer(bytes)
		"jpg": err = img.load_jpg_from_buffer(bytes)
		"webp": err = img.load_webp_from_buffer(bytes)
	return img if err == OK and not img.is_empty() else null
