extends Node
## Interface sounds, synthesised at start (no files, nothing to credit):
## move (a soft tick), select (rising two-note), back (falling), toast (a
## chime). Levels Off / Low / Medium / High; default Low. Nothing plays, and
## no player node exists, while the level is Off.

const LEVEL_DB := {"off": -80.0, "low": -24.0, "medium": -16.0, "high": -9.0}
const RATE := 22050
const MOVE_GAP_MS := 45

var level := "low"
var _streams := {}
var _players: Array[AudioStreamPlayer] = []
var _next := 0
var _last_move := 0


func _init() -> void:
	name = "Sounds"


func set_level(l: String) -> void:
	level = l if LEVEL_DB.has(l) else "low"
	for p in _players:
		p.volume_db = LEVEL_DB[level]


func play(kind: String) -> void:
	if level == "off" or not is_inside_tree():
		return
	if AudioServer.get_driver_name() == "Dummy" and not OS.has_feature("editor"):
		return
	if kind == "move":
		var now := Time.get_ticks_msec()
		if now - _last_move < MOVE_GAP_MS:
			return
		_last_move = now
	if _players.is_empty():
		for i in 3:
			var p := AudioStreamPlayer.new()
			p.volume_db = LEVEL_DB[level]
			add_child(p)
			_players.append(p)
	var p := _players[_next]
	_next = (_next + 1) % _players.size()
	p.stream = stream(kind)
	p.play()


func stream(kind: String) -> AudioStreamWAV:
	if _streams.has(kind):
		return _streams[kind]
	var s: AudioStreamWAV
	match kind:
		"move": s = tone([[1760.0, 0.022]], 0.6)
		"select": s = tone([[880.0, 0.045], [1318.5, 0.07]], 0.7)
		"back": s = tone([[1174.7, 0.045], [784.0, 0.07]], 0.7)
		"toast": s = tone([[1046.5, 0.08], [1568.0, 0.16]], 0.55)
		_: s = tone([[1000.0, 0.03]], 0.5)
	_streams[kind] = s
	return s


## Notes [[hz, seconds], ...] played one after another, sine with a quick
## attack and exponential decay, 16-bit mono.
static func tone(notes: Array, gain: float) -> AudioStreamWAV:
	var data := PackedByteArray()
	for n in notes:
		var hz: float = n[0]
		var count := int(RATE * float(n[1]))
		for i in count:
			var t := float(i) / RATE
			var env := minf(1.0, t / 0.004) * exp(-t / (float(n[1]) * 0.35))
			var v := sin(TAU * hz * t) * 0.6 + sin(TAU * hz * 2.0 * t) * 0.15
			var sample := clampi(int(v * env * gain * 32767.0), -32768, 32767)
			data.append(sample & 0xFF)
			data.append((sample >> 8) & 0xFF)
	var s := AudioStreamWAV.new()
	s.format = AudioStreamWAV.FORMAT_16_BITS
	s.mix_rate = RATE
	s.stereo = false
	s.data = data
	return s
