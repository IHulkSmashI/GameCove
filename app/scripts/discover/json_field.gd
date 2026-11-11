extends RefCounted
## Fields of JSON that came off the network, read without trusting their type.
## A store's API sends null for what it doesn't know, and int(null) or a loop
## over null is a script error in GDScript: it stops the parser, the request's
## callback never returns to Discover, and the refresh waiting on it never
## finishes. These never fail.


## As an int: 0 for null, a list, an object or text that isn't a number.
static func i(v: Variant) -> int:
	if v is int or v is float or v is bool:
		return int(v)
	return int(float(str(v))) if v is String and str(v).is_valid_float() else 0


## As text: "" for null (str(null) is "<null>"), a list or an object. A whole
## number reads without ".0" (JSON numbers arrive as floats: an id of 7 is "7").
static func s(v: Variant) -> String:
	if v is String:
		return v
	if v is float and is_finite(v) and v == floorf(v) and absf(v) < 9.0e15:
		return str(int(v))
	return str(v) if v is int or v is float or v is bool else ""


## As a list: [] for anything that isn't one.
static func list(v: Variant) -> Array:
	return v if v is Array else []
