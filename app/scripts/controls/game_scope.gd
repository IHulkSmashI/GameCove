extends RefCounted
## The game the per-game controls act on, shared between the main thread (the
## quick menu and the game page change it) and the Controls worker (providers
## read it while they detect and write).
##
## It used to be two keys in the Controls context, ctx["game"] and
## ctx["game_key"], added and erased by whoever changed the game. A Dictionary
## isn't safe to read on one thread while another adds or erases a key, so a
## game change on the main thread could crash a provider reading on the worker
## (SIGABRT in perf.gd game(), seen in a full e2e run). Now the context holds
## one of these under "game_scope" from setup on, the context's own keys never
## change again, and the game is swapped and read under a mutex. The stored
## game is a private deep copy that is replaced, never changed, so a reader
## keeps a consistent one for as long as it holds it.

const KEY := "game_scope"

var _mutex := Mutex.new()
var _game := {}
var _key := ""


## The scope of a Controls context; null when it has none (a bare test context).
static func of(context: Dictionary) -> RefCounted:
	var s: Variant = context.get(KEY)
	return s if s is RefCounted and s.has_method("swap") else null


## The scope of a context, made when missing. Controls.setup() calls this on
## the main thread before any worker exists, so no later call ever adds a key.
static func ensure(context: Dictionary) -> RefCounted:
	var s := of(context)
	if s == null:
		s = load("res://scripts/controls/game_scope.gd").new()
		context[KEY] = s
	return s


## Any thread: the game from now on ({} = none).
func swap(game: Dictionary) -> void:
	var g := game.duplicate(true)
	var k := "" if g.is_empty() else str(g.get("key", "%s:%s" % [g.get("store", ""), g.get("id", "")]))
	_mutex.lock()
	_game = g
	_key = k
	_mutex.unlock()


## Any thread: the game ({} = none). Read-only: it is shared with other readers.
func game() -> Dictionary:
	_mutex.lock()
	var g := _game
	_mutex.unlock()
	return g


func key() -> String:
	_mutex.lock()
	var k := _key
	_mutex.unlock()
	return k
