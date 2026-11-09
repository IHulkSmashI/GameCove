extends RefCounted
## Steam app ids are checked before they go into any steam:// URI. Ids reach
## us from files and the network (gamedb's upcoming list: Wikidata P1733, IGDB;
## CheapShark, GG.deals, the Steam wishlist; appmanifests), and an id like
## "620/../uninstall/440" or "620//-console" would turn into another command.
## Only plain ASCII digits pass, 1 to 10 of them, not all zeros.

const PATTERN := "^[0-9]{1,10}$"

static var _re: RegEx


static func valid(appid: Variant) -> bool:
	if not (appid is String or appid is StringName or appid is int):
		return false
	var s := str(appid)
	if _re == null:
		_re = RegEx.create_from_string(PATTERN)
	return _re.search(s) != null and s.lstrip("0") != ""


## steam://store/<appid>, or "" when the id isn't valid.
static func store_uri(appid: Variant) -> String:
	return "steam://store/" + str(appid) if valid(appid) else ""
