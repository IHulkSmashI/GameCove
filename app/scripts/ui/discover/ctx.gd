extends RefCounted
## What every Discover screen shares: the services, the clock, art, and the
## few actions that cross screens (open a store page, open a link, toast,
## follow focus with the backdrop). Made by root.gd.

const Model := preload("res://scripts/ui/discover/model.gd")
const ArtLink := preload("res://scripts/ui/discover/art_link.gd")
const T := preload("res://scripts/ui/texts_discover.gd")

var discover: Object            # the Discover autoload (or a fake with the same API)
var library: Object             # Library (games), may be null
var art: ArtLink
var prefs: RefCounted
var clock: Callable = func() -> int: return int(Time.get_unix_time_from_system())
var toast_fn: Callable = Callable()
var open_game_fn: Callable = Callable()
## Set by root.gd.
var open_page_fn: Callable = Callable()
var focus_fn: Callable = Callable()
var hints_changed_fn: Callable = Callable()


func now() -> int:
	return int(clock.call())


func currency() -> String:
	if discover != null and discover.has_method("user_currency"):
		return discover.user_currency()
	return "USD"


func settings() -> Dictionary:
	return discover.get_settings() if discover != null else {}


func keyshops() -> bool:
	return bool(settings().get("ggdeals_keyshops", false))


func has_gg_key() -> bool:
	return str(settings().get("ggdeals_key", "")) != ""


func status(source: String) -> String:
	if discover == null:
		return ""
	var s: Variant = discover.get("status")
	return str(s.get(source, "")) if s is Dictionary else ""


func games() -> Array:
	if library == null:
		return []
	var g: Variant = library.get("games")
	return g if g is Array else []


func owned(view: Dictionary) -> Dictionary:
	return Model.owned_game(view, games())


func toast(text: String, icon := "info", tone := "", detail := "") -> void:
	if toast_fn.is_valid():
		toast_fn.call(text, icon, tone, detail)


func open_page(view: Dictionary) -> void:
	if open_page_fn.is_valid():
		open_page_fn.call(view)


func open_game(g: Dictionary) -> void:
	if open_game_fn.is_valid():
		open_game_fn.call(g)


func focus(view: Dictionary) -> void:
	if focus_fn.is_valid():
		focus_fn.call(view)


func hints_changed() -> void:
	if hints_changed_fn.is_valid():
		hints_changed_fn.call()


## Opens a store / credits link through Discover (Steam's browser in the session).
func open_link(link: Variant) -> bool:
	if not link is Dictionary or (link as Dictionary).is_empty() or discover == null:
		return false
	var ok: bool = discover.open_link(link)
	if not ok:
		toast(T.TOAST_NO_STEAM, "alert", "warn")
	return ok


## Wishlist toggle for any view; returns the new state.
func toggle_wishlist(view: Dictionary) -> bool:
	var d: Dictionary = view.get("data", {})
	var on := is_wishlisted(view)
	if on:
		var key := wish_key(view)
		discover.remove_from_wishlist(key)
		toast(T.TOAST_REMOVED, "star", "", str(view.get("title", "")))
		return false
	var src: Dictionary = d.duplicate()
	if src.get("title", "") == "":
		src["title"] = view.get("title", "")
	discover.add_to_wishlist(src)
	toast(T.TOAST_ADDED, "star", "wish", str(view.get("title", "")))
	return true


func is_wishlisted(view: Dictionary) -> bool:
	if discover == null:
		return false
	var key := wish_key(view)
	if key != "" and not discover.get_item(key).is_empty():
		return true
	return discover.is_wishlisted(view.get("data", {}))


func wish_key(view: Dictionary) -> String:
	var d: Dictionary = view.get("data", {})
	for k in ["wishlist_key"]:
		if str(d.get(k, "")) != "":
			return str(d[k])
	if view.get("kind", "") in ["wish", "release"]:
		return str(d.get("key", view.get("key", "")))
	return str(view.get("key", ""))


## Release alert for a calendar view (Notify me); returns the new state.
func toggle_notify(view: Dictionary) -> bool:
	var rel: Dictionary = view.get("data", {})
	var key := str(rel.get("key", view.get("key", "")))
	var item: Dictionary = discover.get_item(key)
	if item.is_empty() or not item.get("notify_release", false):
		discover.notify_me(rel)
		toast(T.TOAST_NOTIFY, "calendar", "new", str(view.get("title", "")))
		return true
	discover.set_notify(key, null, false)
	toast(T.TOAST_NOTIFY_OFF, "calendar", "", str(view.get("title", "")))
	return false


func is_notifying(view: Dictionary) -> bool:
	var rel: Dictionary = view.get("data", {})
	var item: Dictionary = discover.get_item(str(rel.get("key", view.get("key", ""))))
	return not item.is_empty() and bool(item.get("notify_release", false))
