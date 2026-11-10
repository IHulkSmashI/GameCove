extends SceneTree
## Records the showcase's Discover answers from the live sources (CheapShark,
## Steam's store API for Canadian prices, GameCove's calendar file; the two
## feeds cut by fetch.py are read from pinned/) into snapshot/:
##   godot --headless --path app -s ../tools/showcase/record_discover.gd


func _initialize() -> void:
	var SD = load(get_script().resource_path.get_base_dir().path_join("showcase_discover.gd"))
	var d: Node = SD.make("record")
	print("deals: %d  calendar: %d  wishlist: %d  inbox: %d  status: %s" % [d.deals.size(), d.calendar.size(),
		d.wishlist.size(), d.alerts_inbox.size(), d.status])
	for w in d.wishlist:
		var p: Variant = w["best_deal"].get("price") if w["best_deal"] is Dictionary else null
		print("  %-36s %s" % [w["title"], p["text"] if p is Dictionary else "-"])
	for x in d.deals.slice(0, 8):
		print("  deal %-30s %-18s %s" % [x["title"], x["store_name"], x["price"]["text"] if x["price"] != null else "see price"])
	d.free()
	quit()
