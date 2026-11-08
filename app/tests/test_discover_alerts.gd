extends "res://tests/test_case.gd"
## Price and release alert rules, once-only behaviour.

const Alerts := preload("res://scripts/discover/alerts.gd")
const Wish := preload("res://scripts/discover/wishlist.gd")


func _item(target: Variant = null) -> Dictionary:
	var it := Wish.make_item({"title": "Game", "appid": "5", "target_price": target, "notify_release": true}, 100)
	return it


func _deal(price: float, savings: int) -> Dictionary:
	return {"price_user": price, "savings_pct": savings}


func test_target_price_fires_once_then_again_after_rise() -> void:
	var seen := {}
	var it := _item(10.0)
	eq(Alerts.check_price(it, _deal(12.0, 20), seen), {}, "above target")
	var a := Alerts.check_price(it, _deal(9.99, 30), seen)
	eq(a.get("kind"), "price", "at/below target fires")
	eq(a.get("id"), "price:steam:5:999", "id holds the price")
	eq(Alerts.check_price(it, _deal(9.99, 30), seen), {}, "same price: once only")
	eq(Alerts.check_price(it, _deal(9.99, 30), seen), {}, "still once")
	ok(not Alerts.check_price(it, _deal(7.5, 50), seen).is_empty(), "a lower price fires again")
	eq(Alerts.check_price(it, _deal(8.0, 40), seen), {}, "back up a bit but under target: quiet")
	eq(Alerts.check_price(it, _deal(15.0, 0), seen), {}, "above target clears memory")
	ok(not seen.has("price:steam:5"), "memory cleared")
	ok(not Alerts.check_price(it, _deal(9.0, 35), seen).is_empty(), "next sale fires")
	ok(not Alerts.check_price(it, _deal(10.0, 0), {}).is_empty(), "exactly the target")


func test_any_drop() -> void:
	var seen := {}
	var it := _item(null)
	eq(Alerts.check_price(it, _deal(20.0, 0), seen), {}, "full price")
	ok(not Alerts.check_price(it, _deal(15.0, 25), seen).is_empty(), "on sale")
	eq(Alerts.check_price(it, _deal(15.0, 25), seen), {}, "once")
	eq(Alerts.check_price(it, _deal(20.0, 0), seen), {}, "sale over")
	ok(not Alerts.check_price(it, _deal(16.0, 20), seen).is_empty(), "new sale fires even if pricier")


func test_price_alert_needs_comparable_price_and_switch() -> void:
	var it := _item(null)
	eq(Alerts.check_price(it, {"price_user": null, "savings_pct": 90}, {}), {}, "unconvertible price")
	eq(Alerts.check_price(it, {}, {}), {}, "no deal")
	it["notify_price"] = false
	eq(Alerts.check_price(it, _deal(1.0, 90), {}), {}, "price alerts off")


func test_release_once() -> void:
	var seen := {}
	var it := _item()
	eq(Alerts.check_release(it, {"released": false}, seen, 1), {}, "not out")
	eq(Alerts.check_release(it, {}, seen, 1), {}, "unknown")
	var a := Alerts.check_release(it, {"released": true}, seen, 2)
	eq(a, {"id": "release:steam:5", "kind": "release", "key": "steam:5", "title": "Game"}, "fires")
	eq(Alerts.check_release(it, {"released": true}, seen, 3), {}, "once")
	it["notify_release"] = false
	eq(Alerts.check_release(it, {"released": true}, {}, 3), {}, "not asked for")


func test_wishlist_items() -> void:
	var it := Wish.make_item({"title": " Hades ", "appid": 1145360, "game_id": "196149"}, 50)
	eq(it["key"], "steam:1145360", "key from appid")
	eq(it["ids"], {"steam": "1145360", "cheapshark": "196149"}, "ids")
	eq([it["added"], it["target_price"], it["notify_price"], it["notify_release"], it["source"]], [50, null, true, false, "manual"], "defaults")
	eq(Wish.make_item({"title": "DOOM™ Eternal"}, 1)["key"], "title:doometernal", "title key")
	var items := {}
	eq(Wish.merge_steam(items, [{"appid": "1", "added": 10}, {"appid": "2", "added": 0}], {"1": "One"}, 99), 2, "two new")
	eq(items["steam:2"]["added"], 99, "missing date -> now")
	eq(items["steam:2"]["title"], "", "title comes later")
	items["steam:1"]["target_price"] = 5.0
	eq(Wish.merge_steam(items, [{"appid": "1"}, {"appid": "2"}], {"2": "Two"}, 100), 0, "nothing new")
	eq(items["steam:1"]["target_price"], 5.0, "settings kept")
	eq(items["steam:2"]["title"], "Two", "title filled")
	eq(Wish.sorted(items).map(func(i): return i["key"]), ["steam:2", "steam:1"], "newest first")
