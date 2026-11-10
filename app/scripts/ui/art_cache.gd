extends RefCounted
## Game art, loaded off the main thread, shrunk to what the screen needs and
## cached (least recently used goes first). Kinds:
##   cover  cropped to 2:3, at most 360x540 (tiles draw at <= 180x270)
##   hero   at most 1920 wide (game page)
##   logo   at most 960x360
##   blur   a tiny copy smoothed back up to 320 px: the backdrop. Drawn
##          stretched with linear filtering it looks like a heavy blur, for
##          the cost of one small texture and no per-frame shader.
## The blur pass also picks the art's vibrant colour (accent()).
## Outside the scene tree (tests, tools) loads happen at once.

const ArtColor := preload("res://theme/art_color.gd")
const HeroInk := preload("res://scripts/ui/hero_ink.gd")

const LIMIT := {"cover": 160, "hero": 4, "logo": 24, "blur": 48}
const COVER := Vector2i(360, 540)

static var _tex := {}        # "kind|path" -> Texture2D (null = failed)
static var _order := {}      # kind -> Array of keys, oldest first
static var _pending := {}    # key -> Array[Callable]
static var _accent := {}     # path -> Color (a = 0 when grey)
static var _side := {}       # "kind|path" -> Color: how bright the art's text side is (HeroInk)
static var _tasks: Array[int] = []   # WorkerThreadPool ids still running
static var _closed := false          # set by shutdown(): late results are dropped


static func usable(path: String) -> bool:
	return path != "" and not path.contains("://") and FileAccess.file_exists(path)


## Texture if already loaded, else null (and nothing starts).
static func cached(kind: String, path: String) -> Texture2D:
	return _tex.get(kind + "|" + path)


static func is_pending(kind: String, path: String) -> bool:
	return _pending.has(kind + "|" + path)


static func pending_count() -> int:
	return _pending.size()


## Returns the texture if it's ready. Otherwise starts loading it and calls
## `done(texture)` on the main thread when it is (never for a missing file).
## `owner` decides threading: in the tree we load on a worker.
static func request(kind: String, path: String, done: Callable = Callable(), owner: Node = null) -> Texture2D:
	if not usable(path):
		return null
	_closed = false   # a new request after shutdown() (tests build main again)
	var key := kind + "|" + path
	if _tex.has(key):
		_touch(kind, key)
		return _tex[key]
	if owner == null or not owner.is_inside_tree():
		var r := _load(kind, path)
		_finish(kind, path, r[0], r[1], r[2])
		return _tex.get(key)
	if _pending.has(key):
		if done.is_valid():
			_pending[key].append(done)
		return null
	_pending[key] = [done] if done.is_valid() else []
	for t in _tasks.filter(func(t): return WorkerThreadPool.is_task_completed(t)):
		WorkerThreadPool.wait_for_task_completion(t)   # frees it; returns at once
		_tasks.erase(t)
	_tasks.append(WorkerThreadPool.add_task(func():
		var r := _load(kind, path)
		_finish.call_deferred(kind, path, r[0], r[1], r[2]),
		false, "GameCove art"))
	return null


## The art's vibrant colour (Color(0,0,0,0) if unknown/grey). Known once the
## "blur" kind of that path has loaded.
static func accent(path: String) -> Color:
	return _accent.get(path, Color(0, 0, 0, 0))


static func has_accent(path: String) -> bool:
	return _accent.has(path)


## How bright the text side (the left) of a loaded hero or cover is, for the
## scrim behind text on it (HeroInk.strength_for). Color(0,0,0,0) if unknown.
static func text_side(kind: String, path: String) -> Color:
	return _side.get(kind + "|" + path, Color(0, 0, 0, 0))


## Worker side: decode and shrink. Returns [Image or null, accent Color,
## text-side Color (heroes and covers)].
static func _load(kind: String, path: String) -> Array:
	var img := Image.load_from_file(path)
	if img == null or img.is_empty():
		return [null, Color(0, 0, 0, 0), Color(0, 0, 0, 0)]
	if img.is_compressed():
		img.decompress()
	if img.get_format() != Image.FORMAT_RGBA8 and img.get_format() != Image.FORMAT_RGB8:
		img.convert(Image.FORMAT_RGBA8)
	var acc := Color(0, 0, 0, 0)
	match kind:
		"cover":
			img = crop_to(img, 2.0 / 3.0)
			_fit(img, COVER)
		"hero":
			_fit(img, Vector2i(1920, 1080))
		"logo":
			_fit(img, Vector2i(960, 360))
		"blur":
			var r := blurred(img)
			img = r[0]
			acc = r[1]
	var side := Color(0, 0, 0, 0)
	if kind == "hero" or kind == "cover":
		side = HeroInk.text_side(img)
	if kind == "cover":
		img.generate_mipmaps()
	return [img, acc, side]


## [smooth 320 px Image, vibrant Color] from any image.
static func blurred(src: Image) -> Array:
	var img := src.duplicate()
	var aspect := float(img.get_width()) / maxf(1.0, img.get_height())
	var w := 40
	var h := maxi(2, int(round(w / aspect)))
	img.resize(w, h, Image.INTERPOLATE_LANCZOS)
	var acc := ArtColor.vibrant(img)
	img.resize(16, maxi(2, int(round(16 / aspect))), Image.INTERPOLATE_BILINEAR)
	img.resize(64, maxi(4, int(round(64 / aspect))), Image.INTERPOLATE_CUBIC)
	img.resize(320, maxi(4, int(round(320 / aspect))), Image.INTERPOLATE_CUBIC)
	return [img, acc]


## Centre crop to width/height = `ratio`.
static func crop_to(img: Image, ratio: float) -> Image:
	var w := img.get_width()
	var h := img.get_height()
	var cur := float(w) / h
	if absf(cur - ratio) < 0.01:
		return img
	var rect: Rect2i
	if cur > ratio:
		var nw := int(h * ratio)
		rect = Rect2i((w - nw) / 2, 0, nw, h)
	else:
		var nh := int(w / ratio)
		rect = Rect2i(0, (h - nh) / 4, w, nh)   # keep more of the top: titles live there
	return img.get_region(rect)


static func _fit(img: Image, max_size: Vector2i) -> void:
	var s := minf(1.0, minf(float(max_size.x) / img.get_width(), float(max_size.y) / img.get_height()))
	if s < 1.0:
		img.resize(maxi(1, int(img.get_width() * s)), maxi(1, int(img.get_height() * s)), Image.INTERPOLATE_LANCZOS)


static func _finish(kind: String, path: String, img: Image, acc: Color, side := Color(0, 0, 0, 0)) -> void:
	if _closed:
		return
	var key := kind + "|" + path
	if side.a > 0.0:
		_side[key] = side
	var tex: Texture2D = ImageTexture.create_from_image(img) if img != null else null
	_tex[key] = tex
	if kind == "blur":
		_accent[path] = acc
	_touch(kind, key)
	var cbs: Array = _pending.get(key, [])
	_pending.erase(key)
	if tex == null:
		return
	for cb in cbs:
		if cb.is_valid():
			cb.call(tex)


static func _touch(kind: String, key: String) -> void:
	var list: Array = _order.get(kind, [])
	list.erase(key)
	list.append(key)
	_order[kind] = list
	while list.size() > int(LIMIT.get(kind, 64)):
		var old: String = list.pop_front()
		_tex.erase(old)
		_side.erase(old)


## Call when the app quits (main.gd does): waits for loads still running and
## drops every texture. Static caches otherwise outlive the renderer at exit,
## which crashes the engine on shutdown.
static func shutdown() -> void:
	for t in _tasks:
		WorkerThreadPool.wait_for_task_completion(t)
	_tasks.clear()
	_pending.clear()
	_closed = true
	clear()


static func clear() -> void:
	_tex.clear()
	_order.clear()
	_accent.clear()
	_side.clear()
