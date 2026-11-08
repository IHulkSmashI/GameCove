extends RefCounted
## Gets local art for Discover views from the Art service (which downloads in
## the background) and tells the screens when a picture arrives, so a tile or
## hero can show it without rebuilding.
##
##   link.fill(view, ["cover"])         # sets view.art.cover now if cached
##   link.arrived.connect(func(key, kind, path): ...)

signal arrived(key: String, kind: String, path: String)

var art: Object = null          # the Art autoload, or a fake with request()/art_ready


func _init(art_service: Object = null) -> void:
	art = art_service
	if art != null and art.has_signal("art_ready"):
		art.art_ready.connect(_on_ready)


## Ask for each kind; fills view.art[kind] when the file is already cached.
func fill(view: Dictionary, kinds: Array) -> void:
	if art == null:
		return
	var urls: Dictionary = view.get("art_urls", {})
	for k in kinds:
		if str(view["art"].get(k, "")) != "":
			continue
		var hints := {"title": view.get("title", "")}
		if str(view.get("appid", "")) != "":
			hints["appid"] = view["appid"]
		var url := str(urls.get(k, ""))
		if url.begins_with("https://"):
			hints["url"] = url
		var p: String = art.request(view["key"], k, hints)
		if p != "":
			view["art"][k] = p


func _on_ready(key: String, kind: String, path: String) -> void:
	if path != "":
		arrived.emit(key, kind, path)


## Put an arrived picture into every view in `views` with that key; true if any.
static func apply(views: Array, key: String, kind: String, path: String) -> bool:
	var hit := false
	for v in views:
		if v is Dictionary and v.get("key", "") == key and v.has("art"):
			v["art"][kind] = path
			hit = true
	return hit
