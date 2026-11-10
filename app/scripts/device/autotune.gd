extends RefCounted
## Auto TDP, ported from ClawDeck's autotune (py_modules/clawdeck/autotune.py, 2026-11-08,
## commit cf349a6 "target: fast to move, then locked"; same author, GPL-3.0). The rules,
## constants and phases are ClawDeck's; what differs is only plumbing: no timer or files here
## (Power feeds one sample a second while a game runs and nothing at all otherwise), and the
## levers go through a `levers` object so every handheld's backend can drive them.
##
## Policy (the owner's): find the most frames the set TDP (your limit) gives, share that power
## between CPU and GPU so the game gets the most out of it, then find the lowest TDP that still
## gives nearly as many frames (within KEEP_PCT or KEEP_FPS). Frames per watt is shown, not
## chased: it improves all the way down to the minimum TDP.
##
## Rendered frames only: with frame generation the game presents 2-4 frames per rendered one.
## sample["source"] says which: "rendered" (XeLL's figure, or presented / multiplier) or
## "presented"; with fg >= 2 and presented frames, the base rate is fps / fg.
##
## Phases, decided on WINDOW_S-second windows (one change per window):
##   measure  at the set TDP, the median of MAX_WINDOWS windows is max_fps
##   balance  one lever at a time toward the side that holds the game back (GPU-bound: GPU
##            efficiency mode off, then GPU floor +100 MHz; CPU-bound: CPU boost on, CPU ceiling
##            100 %, EPP toward performance, drop a GPU floor); a lever stays only if it adds
##            BALANCE_GAIN, else it is undone and balancing ends
##   lower    TDP down while the fps stay within the margin of max_fps: -BIG_STEP_W while clearly
##            above the line and the last step was flat, else -1 W; plateau / knee rules; a miss
##            is measured again, a second miss goes back to the last TDP that held
##   hold     below the line for two windows -> +1 W; a SHIFT either way, a frame-generation
##            change or RESCAN_S -> measure again
##   target   optional target fps (DeckyTDPTuner's governor, GPL-3): the fewest watts that hold
##            it, judged every second; Auto FPS when it is out of reach
## Heavy scenes in lower/hold get watts back at once (_fast_miss). Loading screens, menus and
## pauses are skipped (_not_gameplay). A thermal step (thermal_guard.gd) caps the TDP.
##
## Levers (all optional except tdp; a method that is missing means "this handheld can't"):
##   tdp(w: int) -> bool                     the TDP, read back
##   gpu_floor_ok() -> bool, gpu_limits() -> [efficient MHz, ceiling MHz] (-1 unknown),
##   gpu_floor(mhz: int, -1 = drop) -> bool
##   gpu_profile_now() -> String ("" none), gpu_profiles() -> Array, gpu_profile(v) -> bool
##   boost_ok() -> bool, boost(on) -> bool
##   cpu_ceiling_ok() -> bool, cpu_ceiling(pct) -> bool
##   epp_now() -> String, epp_choices() -> Array, epp(v) -> bool
##   tau_ok() -> bool, set_tau(us) -> bool, restore_tau() -> bool
## Power restores every lever autotune moved when it stops.
##
## A second, GameCove-only signal (not a rule): `cant_reach` for a game's frame limit
## (set_frame_limit), so the UI can say "raise the TDP" or "this game can't hold N fps here".

const CPU_MIN_PCT := 60
const GPU_STEP_MHZ := 100
const WINDOW_S := 10
const MAX_WINDOWS := 3
const KEEP_PCT := 5.0
const KEEP_FPS := 2.0
const BIG_STEP_W := 3
const FLAT_FPS_PER_W := 0.2
const STEEP_FPS_PER_W := 1.0
const BALANCE_GAIN := 0.02
const SHIFT := 0.15
const RESCAN_S := 1200.0
const OFF_LO := 0.35
const OFF_HI := 2.5
const DIP := 0.4
const MAX_SKIPS := 3
const LEARN_TAU_US := 8_000_000
const SETTLED_WINDOWS := 3
const NO_FPS_S := 30
# target fps (DeckyTDPTuner's governor)
const G_WIN := 3
const G_MISS := 0.93
const G_RAISE := 2
const G_RAISE_BIG := 4
const G_RAISE_GAP := 2.0
const G_LOWER_AFTER := 12.0
const G_LOWER_FAST := 5.0
const G_FAR := 1.15
const G_STEP_MAX := 6
const G_LOWER_OK := 0.97
const G_BLAME := 20.0
const G_FLOOR_DECAY := 300.0
const G_BUSY := 85
const AUTO_FPS_S := 60.0
const AUTO_FPS_UP_S := 30.0
const MIN_TARGET := 20
# frame-limit "can't reach" (GameCove UI)
const CANT_REACH_N := 10
const RECOVER_N := 5
const LEARNED_KEYS := ["tdp", "cpu_max_pct", "gpu_min_mhz", "boost", "gpu_profile", "epp", "bound",
	"max_fps", "fps", "ceiling", "samples", "target", "target_eff"]


## What a game ended up with (saved per game and power source).
class Learned extends RefCounted:
	var tdp := 0
	var cpu_max_pct := 100
	var gpu_min_mhz := -1        # -1 = none set
	var boost := true
	var gpu_profile := ""        # "" = left as it was
	var epp := ""                # "" = left as it was (GameCove: CPU-bound lever)
	var bound := "balanced"
	var max_fps := 0.0
	var fps := 0.0
	var ceiling := 0
	var samples := 0
	var target := 0
	var target_eff := 0.0

	func to_dict() -> Dictionary:
		var d := {}
		for k in LEARNED_KEYS:
			d[k] = get(k)
		return d


class Session extends RefCounted:
	var appid := ""
	var floor_tdp := 0
	var ceiling_tdp := 0
	var learned: Learned
	var keep_pct := KEEP_PCT
	var settle := WINDOW_S
	var phase := "measure"
	var paused := false
	var window: Array[float] = []
	var watts: Array[float] = []
	var shown: Array[float] = []
	var max_runs: Array[float] = []
	var misses := 0
	var balance_undo: Array = []          # [name, undo, before, words, delta]
	var balance_tried: Dictionary = {}
	var multiplier := 0.0
	var measured_at := -1.0
	var last_change_at := -1.0
	var last_action := ""
	var last_delta := ""
	var avg_fps := 0.0
	var low_fps := 0.0
	var fps_per_w := 0.0
	var source := "presented"
	var thermal_cap := -1
	var no_fps_s := 0
	var no_frames := false
	var quiet := 0
	var skips := 0
	var settled := false
	var short_tau := false
	var tau_refused := false
	var eff_trial := false
	var eff_tried := false
	var last_good: Array = []             # [tdp, fps]
	var fine := false
	var fg := 0
	var target := 0.0
	var user_target := 0
	var auto_fps := true
	var g_hist: Array[float] = []
	var g_last_change := 0.0
	var g_last_miss := 0.0
	var g_last_drop := -1.0
	var g_drop_from := 0
	var g_floor := 0
	var g_floor_at := 0.0
	var g_maxed: Array[float] = []
	var g_maxed_since := -1.0
	var g_up_since := -1.0
	var g_under_since := -1.0
	var best_fps := 0.0
	var unreachable := false


var levers: Object
## Seconds, monotonic. Tests set their own.
var clock: Callable = func() -> float: return Time.get_ticks_msec() / 1000.0
var session: Session
var plugged := false
## frame limit "can't reach"
var frame_limit := 0.0
## The Auto TDP target the user picked (0 = most frames). What runs is
## effective_target(): never above the game's frame limit, which it can't reach.
var wanted_target := 0
var cant_reach := false
var last_fps := 0.0
var _short := 0
var _on_target := 0


func _now() -> float:
	return float(clock.call())


func _can(m: String) -> bool:
	return levers != null and levers.has_method(m)


func _ok(m: String) -> bool:
	return _can(m) and bool(levers.call(m))


# ---- lifecycle -----------------------------------------------------------------------------------

## Start for a game. A saved result measured at the same ceiling starts in hold; anything else
## measures the most the ceiling gives. opts: keep_pct, target, auto_fps, fg.
func start(appid: String, learned: Dictionary, floor_tdp: int, ceiling_tdp: int, opts := {}) -> void:
	var known := {}
	for k in learned:
		if k in LEARNED_KEYS:
			known[k] = learned[k]
	var reuse: bool = int(known.get("ceiling", -1)) == ceiling_tdp and float(known.get("max_fps", 0.0)) > 0.0 and known.has("tdp")
	var l := Learned.new()
	if reuse:
		for k in known:
			l.set(k, _typed(k, known[k]))
	else:
		l.tdp = ceiling_tdp
		l.cpu_max_pct = int(known.get("cpu_max_pct", 100))
		l.gpu_min_mhz = int(known.get("gpu_min_mhz", -1)) if known.get("gpu_min_mhz") != null else -1
		l.boost = bool(known.get("boost", true))
	l.tdp = clampi(l.tdp, floor_tdp, maxi(floor_tdp, ceiling_tdp))
	l.ceiling = ceiling_tdp
	var s := Session.new()
	s.appid = appid
	s.floor_tdp = floor_tdp
	s.ceiling_tdp = maxi(floor_tdp, ceiling_tdp)
	s.learned = l
	s.keep_pct = float(opts.get("keep_pct", KEEP_PCT)) if float(opts.get("keep_pct", 0.0)) > 0.0 else KEEP_PCT
	s.phase = "hold" if reuse else "measure"
	s.measured_at = _now() if reuse else -1.0
	s.quiet = SETTLED_WINDOWS if reuse else 0
	s.settled = reuse
	s.fg = int(opts.get("fg", 0))
	session = s
	wanted_target = int(opts.get("target", 0))
	var target := effective_target(wanted_target, frame_limit)
	if target > 0:
		_start_target(s, known, target, bool(opts.get("auto_fps", true)))
	_apply(l)
	_tau(s, target > 0 or not reuse)


static func _typed(k: String, v: Variant) -> Variant:
	match k:
		"tdp", "cpu_max_pct", "ceiling", "samples", "target":
			return int(v)
		"gpu_min_mhz":
			return int(v) if v != null else -1
		"boost":
			return bool(v)
		"max_fps", "fps", "target_eff":
			return float(v) if v != null else 0.0
	return str(v) if v != null else ""


func _start_target(s: Session, known: Dictionary, target: int, auto_fps: bool) -> void:
	var l := s.learned
	s.phase = "target"
	s.user_target = target
	s.auto_fps = auto_fps
	s.target = float(target)
	var same: bool = int(known.get("target", 0)) == target and known.has("tdp")
	if same:
		l.tdp = clampi(int(known["tdp"]), s.floor_tdp, s.ceiling_tdp)
		if auto_fps and float(known.get("target_eff", 0.0)) > 0.0:
			s.target = minf(target, float(known["target_eff"]))
	else:
		l.tdp = clampi(int(ceilf((s.floor_tdp + s.ceiling_tdp) / 2.0)), s.floor_tdp, s.ceiling_tdp)
	l.target = target
	l.target_eff = s.target
	var now := _now()
	s.g_hist = []
	s.g_last_change = now
	s.g_last_miss = now
	s.g_last_drop = -1.0
	s.g_floor = s.floor_tdp
	s.g_floor_at = now
	s.g_maxed = []
	s.g_maxed_since = -1.0
	s.g_up_since = -1.0
	s.unreachable = false
	s.best_fps = 0.0
	s.settled = same
	s.last_action = "holding %d fps from %d W" % [int(s.target), l.tdp]


## The target Auto TDP holds: the user's, but never above the game's frame limit
## (a 60 fps target under a 45 fps cap could never be met and would only pin
## the TDP at the ceiling). 0 stays 0 (most frames, which the cap bounds anyway).
static func effective_target(target: int, limit: float) -> int:
	if target > 0 and limit > 0.0 and float(target) > limit:
		return int(limit)
	return target


## The target was changed while a game runs (0 = back to most-frames mode).
func set_target(target: int, auto_fps := true) -> void:
	wanted_target = target
	_retarget(effective_target(target, frame_limit), auto_fps)


func _retarget(target: int, auto_fps: bool) -> void:
	var s := session
	if s == null:
		return
	if target > 0:
		_start_target(s, {}, target, auto_fps)
		_tdp(s.learned, mini(s.learned.tdp, _top(s)))
		_tau(s, true)
		s.paused = false
	elif s.phase == "target":
		s.target = 0.0
		s.user_target = 0
		s.learned.target = 0
		s.learned.target_eff = 0.0
		_remeasure(s, "target switched off")
		s.paused = false


## The user picked a profile or moved the TDP slider: the new set TDP; measured again from it
## (and a manual pause ends). Returns the watts applied, -1 without a session.
func set_ceiling(watts: int) -> int:
	var s := session
	if s == null:
		return -1
	s.ceiling_tdp = maxi(s.floor_tdp, watts)
	s.thermal_cap = -1
	if s.phase == "target":
		_tdp(s.learned, s.ceiling_tdp)
		s.g_hist = []
		s.g_last_change = _now()
		s.g_maxed_since = -1.0
		s.unreachable = false
		s.g_floor = mini(s.g_floor, s.ceiling_tdp)
	else:
		_remeasure(s, "TDP set to %d W" % s.ceiling_tdp)
	s.paused = false
	_clear_limit()
	return s.learned.tdp


## The lowest TDP autotune may use (min_w: the device minimum).
func set_floor(watts: int, min_w: int) -> void:
	var s := session
	if s == null:
		return
	s.floor_tdp = clampi(watts, min_w, s.ceiling_tdp)
	if s.learned.tdp < s.floor_tdp:
		_tdp(s.learned, s.floor_tdp)


func set_keep(pct: float) -> void:
	if session != null:
		session.keep_pct = clampf(pct, 1.0, 25.0)


## The temperature guard brings the TDP down: autotune works under `watts` from now on.
func thermal_step(watts: int) -> bool:
	var s := session
	if s == null:
		return false
	s.thermal_cap = watts
	var l := s.learned
	if not s.balance_undo.is_empty():
		s.balance_undo[1].call()
		s.balance_undo = []
	if not _tdp(l, s.thermal_cap):
		return false
	s.window = []
	s.watts = []
	s.shown = []
	s.misses = 0
	if s.phase == "measure":
		s.max_runs = []
	_did(s, "thermal: stepped to %d W" % l.tdp, "thermal")
	return true


## The package cooled down: up to `watts` again (the set TDP: the step is gone, measure again).
func thermal_release(watts: int) -> bool:
	var s := session
	if s == null or s.thermal_cap < 0:
		return false
	if watts >= s.ceiling_tdp:
		s.thermal_cap = -1
		if s.phase == "target":
			_did(s, "thermal: cooled, the full TDP allowed again", "thermal")
		else:
			_remeasure(s, "cooled down")
	else:
		s.thermal_cap = watts
		_did(s, "thermal: cooled, up to %d W allowed" % s.thermal_cap, "thermal")
	return true


func _top(s: Session) -> int:
	return s.ceiling_tdp if s.thermal_cap < 0 else mini(s.ceiling_tdp, s.thermal_cap)


## Never fight the user: a manual change stops autotune for the rest of the session.
func pause(_reason := "manual change") -> void:
	if session != null and not session.paused:
		session.paused = true


func running() -> bool:
	return session != null


## End the session: {"learned", "samples", "settled", "summary"}, {} without one. The caller
## restores the levers and the user's TDP.
func stop() -> Dictionary:
	var s := session
	session = null
	frame_limit = 0.0
	wanted_target = 0
	_clear_limit()
	if s == null:
		return {}
	if s.short_tau and _can("restore_tau"):
		levers.restore_tau()
	return {"learned": s.learned.to_dict(), "samples": s.learned.samples, "settled": s.settled, "summary": summary(s)}


static func summary(s: Session) -> String:
	var l := s.learned
	if not s.settled or l.max_fps <= 0.0:
		return "Auto TDP was still learning; nothing new saved. It goes on next time."
	var fps := l.fps if l.fps > 0.0 else l.max_fps
	var ceiling := l.ceiling if l.ceiling > 0 else s.ceiling_tdp
	var saved := ceiling - l.tdp
	return "Auto TDP used %d W of your %d W: %d of %d fps%s" % [l.tdp, ceiling, roundi(fps), roundi(l.max_fps),
		(", saves %d W" % saved) if saved > 0 else ""]


func _apply(l: Learned) -> void:
	_tdp_raw(l.tdp)
	if _ok("cpu_ceiling_ok") and l.cpu_max_pct < 100:
		levers.cpu_ceiling(l.cpu_max_pct)
	if _ok("boost_ok") and not l.boost:
		levers.boost(false)
	if l.gpu_min_mhz > 0 and _ok("gpu_floor_ok"):
		levers.gpu_floor(l.gpu_min_mhz)
	if l.gpu_profile != "":
		_gpu_profile(l, l.gpu_profile, true)
	if l.epp != "" and _can("epp"):
		levers.epp(l.epp)


# ---- one sample a second -------------------------------------------------------------------------

## sample: {"fps" (rendered or presented, see source), "source", "shown_fps", "gpu_busy" (-1),
## "cpu_pct" (-1), "gpu_mhz" (-1), "gpu_max_mhz" (-1), "pkg_w" (-1)}.
func step(smp: Dictionary) -> void:
	var s := session
	if s == null:
		return
	var fps := float(smp.get("fps", 0.0))
	if s.paused:
		_tau(s, false)
	if fps <= 0.0 and not s.paused and s.learned.samples == 0:
		s.no_fps_s += 1
		if s.no_fps_s >= NO_FPS_S:
			s.paused = true
			s.no_frames = true
			_tau(s, false)
	if fps <= 0.0 or s.paused:
		return
	var base := fps
	if str(smp.get("source", "presented")) == "presented" and s.fg >= 2:
		base = fps / s.fg
		s.multiplier = float(s.fg)
	_track_limit(base)
	s.learned.samples += 1
	s.source = str(smp.get("source", "presented")) if str(smp.get("source", "")) == "rendered" or s.fg < 2 else "frame-gen pick"
	if s.phase == "target":
		_govern(s, base, smp)
		_tau(s, true)
		return
	if (s.phase == "lower" or s.phase == "hold") and _fast_miss(s, base):
		return
	s.window.append(base)
	if float(smp.get("pkg_w", -1.0)) > 0.0:
		s.watts.append(float(smp["pkg_w"]))
	if float(smp.get("shown_fps", -1.0)) > 0.0:
		s.shown.append(float(smp["shown_fps"]))
	if s.window.size() < s.settle:
		return
	var avg := _mean(s.window)
	var low: float = s.window.min()
	if _not_gameplay(s, avg, low):
		s.window = []
		s.watts = []
		s.shown = []
		return
	s.avg_fps = avg
	s.low_fps = low
	s.fps_per_w = avg / _mean(s.watts) if not s.watts.is_empty() else 0.0
	_multiplier(s)
	s.window = []
	s.watts = []
	s.shown = []
	var l := s.learned
	l.bound = classify(smp)
	var changed_at := s.last_change_at
	match s.phase:
		"measure": _measure(s, avg)
		"balance": _balance(s, avg)
		"lower": _lower(s, avg)
		_: _hold(s, avg)
	s.quiet = 0 if s.last_change_at != changed_at else s.quiet + 1
	if s.phase == "hold" and s.quiet >= SETTLED_WINDOWS:
		s.settled = true
	_tau(s, s.phase != "hold" or s.quiet < SETTLED_WINDOWS)


static func _mean(a: Array) -> float:
	if a.is_empty():
		return 0.0
	var t := 0.0
	for v in a:
		t += float(v)
	return t / a.size()


static func _median(a: Array) -> float:
	var b := a.duplicate()
	b.sort()
	var n := b.size()
	if n == 0:
		return 0.0
	return float(b[n / 2]) if n % 2 == 1 else (float(b[n / 2 - 1]) + float(b[n / 2])) / 2.0


static func classify(smp: Dictionary) -> String:
	var busy := int(smp.get("gpu_busy", -1))
	var cpu := float(smp.get("cpu_pct", -1.0))
	if busy >= 0:
		if busy >= 90 and (cpu < 0.0 or cpu < 60.0):
			return "gpu"
		if cpu >= 0.0 and cpu > 85.0 and busy < 80:
			return "cpu"
		return "balanced"
	var mhz := float(smp.get("gpu_mhz", -1.0))
	var mx := float(smp.get("gpu_max_mhz", -1.0))
	var pinned := mhz >= 0.0 and mx > 0.0 and mhz >= 0.95 * mx
	if pinned and (cpu < 0.0 or cpu < 60.0):
		return "gpu"
	if cpu >= 0.0 and cpu > 85.0 and not pinned:
		return "cpu"
	return "balanced"


func _fast_miss(s: Session, fps: float) -> bool:
	var l := s.learned
	var now := _now()
	var ref := l.fps if l.fps > 0.0 else l.max_fps
	if ref <= 0.0 or fps < ref * OFF_LO:
		return false
	s.g_hist.append(fps)
	while s.g_hist.size() > G_WIN:
		s.g_hist.pop_front()
	var lim := _line(s) - _margin(s)
	var win := _mean(s.g_hist)
	if not (s.g_hist.size() >= G_WIN and win < lim and fps < lim) or l.tdp >= _top(s):
		return false
	if now - s.g_last_change < G_RAISE_GAP:
		return true
	var back: int = s.last_good[0] if not s.last_good.is_empty() and s.last_good[0] > l.tdp else 0
	var w := mini(_top(s), maxi(back, l.tdp + (G_RAISE_BIG if win < ref * 0.75 else G_RAISE)))
	var was := l.tdp
	if _tdp(l, w):
		s.g_last_change = now
		s.g_hist = []
		s.window = []
		s.watts = []
		s.shown = []
		s.misses = 0
		s.floor_tdp = maxi(s.floor_tdp, mini(w, _top(s)))
		s.phase = "hold"
		_did(s, "%d fps, well under %d: back up to %d W at once" % [roundi(win), roundi(_line(s)), w], "+%d W" % (w - was))
	return true


func _govern(s: Session, fps: float, smp: Dictionary) -> void:
	var l := s.learned
	var now := _now()
	var t := s.target
	if t <= 0.0 or fps < t * OFF_LO:
		return
	s.g_hist.append(fps)
	while s.g_hist.size() > G_WIN:
		s.g_hist.pop_front()
	var win := _mean(s.g_hist)
	s.avg_fps = win
	s.low_fps = s.g_hist.min()
	if float(smp.get("pkg_w", -1.0)) > 0.0:
		s.fps_per_w = fps / float(smp["pkg_w"])
	var top := _top(s)
	var lim := t * G_MISS
	var busy := int(smp.get("gpu_busy", -1))
	if s.g_hist.size() >= 2 and win < lim and fps < lim:
		s.g_last_miss = now
		s.g_up_since = -1.0
		var blamed := s.g_last_drop >= 0.0 and now - s.g_last_drop < G_BLAME and s.g_drop_from > l.tdp
		if blamed and s.g_drop_from > s.g_floor:
			s.g_floor = s.g_drop_from
			s.g_floor_at = now
		if l.tdp >= top:
			_out_of_reach(s, win, now)
			return
		if now - s.g_last_change < G_RAISE_GAP:
			return
		var need := int(ceilf(floorf(l.tdp * (t / maxf(win, 1.0) - 1.0) * 10.0) / 10.0))
		var step_w := maxi(G_RAISE_BIG if win < t * 0.75 else G_RAISE, mini(G_STEP_MAX, need))
		var w := mini(top, l.tdp + step_w)
		var was := l.tdp
		if blamed:
			w = mini(top, maxi(s.g_drop_from, l.tdp + 1))
			s.g_last_drop = -1.0
		if _tdp(l, w):
			s.g_last_change = now
			s.g_hist = []
			_did(s, "%d fps, under the %d target: raised TDP to %d W" % [roundi(win), roundi(t), w], "+%d W" % (w - was))
		return
	s.g_maxed_since = -1.0
	var band := t * (G_MISS + G_LOWER_OK) / 2.0
	if s.g_last_drop >= 0.0 and now - s.g_last_drop < G_BLAME and s.g_hist.size() >= G_WIN and win < band and s.g_drop_from > l.tdp:
		var was := l.tdp
		if _tdp(l, mini(top, s.g_drop_from)):
			s.g_floor = maxi(s.g_floor, l.tdp)
			s.g_floor_at = now
			s.g_last_drop = -1.0
			s.g_last_change = now
			s.g_hist = []
			_did(s, "%d fps at %d W is just under the %d target: back to %d W" % [roundi(win), was, roundi(t), l.tdp], "+%d W" % (l.tdp - was))
		return
	if win < band and l.tdp < top:
		if s.g_under_since < 0.0:
			s.g_under_since = now
		if now - s.g_under_since >= G_LOWER_AFTER and now - s.g_last_change >= G_LOWER_AFTER:
			if _tdp(l, l.tdp + 1):
				s.g_under_since = -1.0
				s.g_last_change = now
				s.g_hist = []
				_did(s, "%d fps, just under the %d target: TDP %d W" % [roundi(win), roundi(t), l.tdp], "+1 W")
			return
	else:
		s.g_under_since = -1.0
	if s.auto_fps and s.user_target > 0 and t < s.user_target and l.tdp < top and win >= t * 1.08:
		if s.g_up_since < 0.0:
			s.g_up_since = now
		if now - s.g_up_since >= AUTO_FPS_UP_S:
			s.target = minf(s.user_target, floorf(win * 0.95))
			l.target_eff = s.target
			s.g_up_since = -1.0
			s.unreachable = s.target < s.user_target
			_did(s, "Auto FPS: room again, holding %d fps (yours %d)" % [roundi(s.target), s.user_target], "target up")
			return
	else:
		s.g_up_since = -1.0
	var lighter := win >= t * G_FAR or (busy >= 0 and busy < 60)
	if lighter and s.g_floor > s.floor_tdp and now - s.g_last_miss > G_FLOOR_DECAY and now - s.g_floor_at > G_FLOOR_DECAY:
		s.g_floor -= 1
		s.g_floor_at = now
	if now - s.g_last_change >= 60.0 and now - s.g_last_miss >= 60.0:
		s.settled = true
	var headroom := busy < 0 or busy < G_BUSY
	var low := maxi(s.floor_tdp, s.g_floor)
	var far := win >= t * G_FAR
	var wait := G_LOWER_FAST if far else G_LOWER_AFTER
	if headroom and l.tdp > low and s.g_hist.size() >= G_WIN and win >= t * G_LOWER_OK \
			and now - s.g_last_change >= wait and now - s.g_last_miss >= wait:
		var step_w := maxi(1, mini(G_STEP_MAX, int((l.tdp - l.tdp * t / win) / 2.0))) if far else 1
		var w := maxi(low, l.tdp - step_w)
		var was := l.tdp
		if _tdp(l, w):
			s.g_drop_from = was
			s.g_last_drop = now
			s.g_last_change = now
			s.g_hist = []
			_did(s, "%d fps holds the %d target: lowered TDP to %d W" % [roundi(win), roundi(t), w], "-%d W" % (was - w))


func _out_of_reach(s: Session, win: float, now: float) -> void:
	if s.g_maxed_since < 0.0:
		s.g_maxed_since = now
		s.g_maxed = []
	s.g_maxed.append(win)
	if now - s.g_maxed_since < AUTO_FPS_S:
		return
	s.best_fps = _median(s.g_maxed)
	s.g_maxed_since = -1.0
	var t := s.target
	if s.auto_fps:
		var nt := float(maxi(MIN_TARGET, int(s.best_fps * 0.95)))
		if nt < t:
			s.target = nt
			s.learned.target_eff = nt
			s.unreachable = true
			s.g_hist = []
			s.g_last_change = now
			_did(s, "Auto FPS: %d fps is out of reach (%d W gives %d): holding %d fps" % [roundi(t), _top(s), roundi(s.best_fps), roundi(nt)], "target down")
	elif not s.unreachable:
		s.unreachable = true
		_did(s, "%d fps is out of reach: %d W gives %d fps" % [roundi(t), _top(s), roundi(s.best_fps)], "out of reach")


## RAPL averages PL1 over ~56 s: while learning, an 8 s window so a 10 s window sees sustained
## power; once learned, the firmware's again (ClawDeck findings §22.2).
func _tau(s: Session, learning: bool) -> void:
	if learning and not s.short_tau and not s.tau_refused and _ok("tau_ok"):
		if levers.set_tau(LEARN_TAU_US):
			s.short_tau = true
		else:
			s.tau_refused = true
			levers.restore_tau()
	elif not learning and s.short_tau:
		if _can("restore_tau"):
			levers.restore_tau()
		s.short_tau = false


func _not_gameplay(s: Session, fps: float, low: float) -> bool:
	var ref := s.learned.fps if s.learned.fps > 0.0 else s.learned.max_fps
	var off := ref > 0.0 and not (ref * OFF_LO <= fps and fps <= ref * OFF_HI)
	if (off or low < fps * DIP) and s.skips + 1 < MAX_SKIPS:
		s.skips += 1
		return true
	s.skips = 0
	return false


func _margin(s: Session) -> float:
	var m := s.learned.max_fps
	return maxf(m * s.keep_pct / 100.0, KEEP_FPS) if m > 0.0 else 0.0


func _line(s: Session) -> float:
	return s.learned.max_fps - _margin(s)


func _did(s: Session, action: String, delta: String) -> void:
	s.last_action = action
	s.last_delta = delta
	s.last_change_at = _now()


func _remeasure(s: Session, why: String) -> void:
	var l := s.learned
	s.phase = "measure"
	s.max_runs = []
	s.misses = 0
	s.balance_undo = []
	s.balance_tried = {}
	s.eff_trial = false
	s.eff_tried = false
	s.last_good = []
	s.fine = false
	s.window = []
	s.watts = []
	s.shown = []
	var top := _top(s)
	if l.tdp != top:
		_tdp(l, top)
	l.ceiling = s.ceiling_tdp
	s.quiet = 0
	_tau(s, true)
	_did(s, "measuring the most %d W gives (%s)" % [top, why], "%d W" % top)


func _measure(s: Session, fps: float) -> void:
	s.max_runs.append(fps)
	if s.max_runs.size() < MAX_WINDOWS:
		return
	var l := s.learned
	l.max_fps = _median(s.max_runs)
	l.fps = l.max_fps
	s.measured_at = _now()
	s.phase = "balance"
	s.balance_tried = {}
	_did(s, "%d W gives %d fps" % [_top(s), roundi(l.max_fps)], "measured")


## [name, apply, undo, words, delta] for the next untried lever toward the side that holds the
## game back.
func _levers(s: Session) -> Array:
	var l := s.learned
	var out := []
	if l.bound == "gpu":
		if _gpu_active() == "power_saving":
			out.append(["gpu_base", func(): return _gpu_profile(l, "base"), func(): return _gpu_profile(l, "power_saving"),
				"turned GPU efficiency mode off (clocks up faster)", "GPU efficiency off"])
		if _ok("gpu_floor_ok"):
			var lim: Array = levers.gpu_limits() if _can("gpu_limits") else [-1, -1]
			var rpe: int = int(lim[0]) if int(lim[0]) > 0 else 0
			var top: int = int(lim[1])
			var nxt: int = (l.gpu_min_mhz if l.gpu_min_mhz > 0 else rpe) + GPU_STEP_MHZ
			if top < 0 or nxt <= top:
				var was := l.gpu_min_mhz
				out.append(["gpu_floor_up", func(): return _gpu_floor(l, nxt), func(): return _gpu_floor(l, was),
					"raised GPU floor to %d MHz" % nxt, "+%d MHz GPU floor" % GPU_STEP_MHZ])
	elif l.bound == "cpu":
		if _ok("boost_ok") and not l.boost:
			out.append(["boost_on", func(): return _boost(l, true), func(): return _boost(l, false), "turned CPU boost on", "CPU boost on"])
		if _ok("cpu_ceiling_ok") and l.cpu_max_pct < 100:
			var was := l.cpu_max_pct
			out.append(["cpu_up", func(): return _cpu(l, 100), func(): return _cpu(l, was), "raised CPU ceiling to 100 %", "CPU ceiling 100 %"])
		# GameCove: an energy preference that holds the CPU back is the same kind of lever as boost
		var epp_now: String = levers.epp_now() if _can("epp_now") else ""
		if epp_now in ["balance_power", "power"] and _can("epp_choices") and "balance_performance" in levers.epp_choices():
			out.append(["epp_up", func(): return _epp(l, "balance_performance"), func(): return _epp(l, epp_now),
				"CPU energy mode to balance_performance", "CPU energy up"])
		if l.gpu_min_mhz > 0:
			var was := l.gpu_min_mhz
			out.append(["gpu_floor_off", func(): return _gpu_floor(l, -1), func(): return _gpu_floor(l, was),
				"dropped the GPU floor (budget back to the CPU)", "GPU floor off"])
	return out.filter(func(x): return not s.balance_tried.has(x[0]))


func _balance(s: Session, fps: float) -> void:
	var l := s.learned
	if not s.balance_undo.is_empty():
		var u := s.balance_undo
		s.balance_undo = []
		var before: float = u[2]
		if fps >= before * (1.0 + BALANCE_GAIN):
			s.balance_tried.erase(u[0])
			l.fps = fps
			if l.tdp == _top(s):
				l.max_fps = maxf(l.max_fps, fps)
			_did(s, "%s: %d -> %d fps, kept" % [u[3], roundi(before), roundi(fps)], u[4])
		else:
			u[1].call()
			_did(s, "%s didn't help (%d -> %d fps), undone" % [u[3], roundi(before), roundi(fps)], "undone")
			s.phase = "lower" if l.tdp > s.floor_tdp else "hold"
			return
	var lv := _levers(s)
	if lv.is_empty():
		s.phase = "lower"
		_lower(s, fps)
		return
	var x: Array = lv[0]
	s.balance_tried[x[0]] = true
	if bool(x[1].call()):
		s.balance_undo = [x[0], x[2], fps, x[3], x[4]]
		_did(s, "trying: %s" % x[3], x[4])


func _lower(s: Session, fps: float) -> void:
	var l := s.learned
	var line := _line(s)
	var margin := _margin(s)
	var prev := s.last_good
	var cost := -1.0
	if not prev.is_empty() and prev[0] > l.tdp:
		cost = maxf(0.0, float(prev[1]) - fps) / float(prev[0] - l.tdp)
	var flat := cost >= 0.0 and cost <= FLAT_FPS_PER_W
	if fps >= line or (flat and fps >= line - margin / 2.0):
		s.misses = 0
		l.fps = fps
		if cost >= 0.0 and fps < line + margin and cost > STEEP_FPS_PER_W and not prev.is_empty() and prev[0] - l.tdp <= 1:
			s.phase = "hold"
			_did(s, "holding at %d W: the last watt cost %.1f fps" % [l.tdp, cost], "knee")
			s.last_good = [l.tdp, fps]
			return
		s.last_good = [l.tdp, fps]
		if l.tdp <= s.floor_tdp:
			s.phase = "hold"
			_try_efficiency(s)
			return
		var step_w := BIG_STEP_W if not s.fine and fps >= line + margin / 2.0 and (cost < 0.0 or cost <= FLAT_FPS_PER_W) else 1
		var w := maxi(s.floor_tdp, l.tdp - step_w)
		var was := l.tdp
		if _tdp(l, w):
			s.balance_tried = {}
			s.phase = "balance"
			_did(s, "lowered TDP to %d W (%d fps, %d %% of %d)" % [w, roundi(fps), roundi(100.0 * fps / l.max_fps), roundi(l.max_fps)], "-%d W" % (was - w))
		else:
			s.phase = "hold"
		return
	s.misses += 1
	if s.misses < 2:
		return
	s.misses = 0
	if not prev.is_empty() and prev[0] - l.tdp > 1 and not s.fine:
		s.fine = true
		var w: int = prev[0] - 1
		var was := l.tdp
		if _tdp(l, w):
			s.phase = "balance"
			s.balance_tried = {}
			_did(s, "%d fps at %d W is below %d: trying %d W" % [roundi(fps), was, roundi(line), w], "+%d W" % (w - was))
		return
	var back: int = prev[0] if not prev.is_empty() and prev[0] > l.tdp else l.tdp + 1
	var w2 := mini(_top(s), back)
	var was2 := l.tdp
	if w2 != l.tdp and _tdp(l, w2):
		_did(s, "%d fps is below %d: back up to %d W, holding" % [roundi(fps), roundi(line), w2], "+%d W" % (w2 - was2))
	s.phase = "hold"


func _try_efficiency(s: Session) -> void:
	var l := s.learned
	if s.eff_tried or _gpu_active() != "base" or not _can("gpu_profiles") or not "power_saving" in levers.gpu_profiles():
		return
	s.eff_tried = true
	if _gpu_profile(l, "power_saving"):
		s.eff_trial = true
		s.window = []
		s.watts = []
		s.shown = []
		_did(s, "at the %d W floor: trying GPU efficiency mode" % s.floor_tdp, "GPU efficiency on")


func _hold(s: Session, fps: float) -> void:
	var l := s.learned
	if s.eff_trial:
		s.eff_trial = false
		if fps < _line(s):
			_gpu_profile(l, "base")
			_did(s, "GPU efficiency mode cost frames (%d fps, under %d), undone" % [roundi(fps), roundi(_line(s))], "undone")
		else:
			_did(s, "GPU efficiency mode kept (%d fps)" % roundi(fps), "kept")
		return
	var ref := l.fps if l.fps > 0.0 else (l.max_fps if l.max_fps > 0.0 else fps)
	var shifted := ref > 0.0 and absf(fps - ref) / ref >= SHIFT
	if shifted:
		s.misses += 1
		if s.misses >= 2:
			_remeasure(s, "fps moved from %d to %d" % [roundi(ref), roundi(fps)])
		return
	if s.measured_at >= 0.0 and _now() - s.measured_at >= RESCAN_S:
		_remeasure(s, "routine check")
		return
	if l.max_fps > 0.0 and fps < _line(s):
		s.misses += 1
		if s.misses >= 2 and l.bound == "gpu" and _gpu_active() == "power_saving":
			s.misses = 0
			if _gpu_profile(l, "base"):
				_did(s, "%d fps is below %d: GPU efficiency mode off" % [roundi(fps), roundi(_line(s))], "GPU efficiency off")
			return
		if s.misses >= 2 and l.tdp < _top(s):
			s.misses = 0
			if _tdp(l, l.tdp + 1):
				_did(s, "%d fps is below %d: raised TDP to %d W" % [roundi(fps), roundi(_line(s)), l.tdp], "+1 W")
		return
	s.misses = 0


func _multiplier(s: Session) -> void:
	var m := 0.0
	if s.source == "rendered" and not s.shown.is_empty() and s.avg_fps > 0.0:
		m = snappedf(_mean(s.shown) / s.avg_fps, 0.1)
	var old := s.multiplier
	s.multiplier = m
	if s.phase != "measure" and old > 0.0 and m > 0.0 and absf(m - old) >= 0.5:
		_remeasure(s, "frame generation changed: %sx -> %sx" % [str(old), str(m)])


# ---- levers --------------------------------------------------------------------------------------

func _tdp_raw(w: int) -> bool:
	return levers != null and bool(levers.tdp(w))


## Set the TDP and record it only when really applied; never above the thermal step.
func _tdp(l: Learned, watts: int) -> bool:
	var s := session
	if s != null and s.thermal_cap >= 0 and watts > s.thermal_cap:
		watts = s.thermal_cap
		if watts == l.tdp:
			return false
	if not _tdp_raw(watts):
		return false
	l.tdp = watts
	return true


func _gpu_floor(l: Learned, mhz: int) -> bool:
	if not _ok("gpu_floor_ok") or mhz == l.gpu_min_mhz:
		return false
	if levers.gpu_floor(mhz):
		l.gpu_min_mhz = mhz
		return true
	return false


func _gpu_active() -> String:
	return str(levers.gpu_profile_now()) if _can("gpu_profile_now") else ""


func _gpu_profile(l: Learned, value: String, force := false) -> bool:
	if not _can("gpu_profile") or (not force and _gpu_active() == value):
		return false
	if levers.gpu_profile(value):
		l.gpu_profile = value
		return true
	return false


func _cpu(l: Learned, pct: int) -> bool:
	pct = clampi(pct, CPU_MIN_PCT, 100)
	if pct == l.cpu_max_pct or not _ok("cpu_ceiling_ok"):
		return false
	if levers.cpu_ceiling(pct):
		l.cpu_max_pct = pct
		return true
	return false


func _boost(l: Learned, on: bool) -> bool:
	if not _ok("boost_ok") or l.boost == on:
		return false
	if levers.boost(on):
		l.boost = on
		return true
	return false


func _epp(l: Learned, value: String) -> bool:
	if not _can("epp"):
		return false
	if levers.epp(value):
		l.epp = value
		return true
	return false


# ---- frame limit (GameCove UI only) --------------------------------------------------------------

## The game's frame limit (0 = none): feeds `cant_reach`, never the TDP rule.
## A target above it follows it down (and back up to the user's when it's raised).
func set_frame_limit(fps: float) -> void:
	frame_limit = maxf(0.0, fps)
	_clear_limit()
	var s := session
	if s != null and wanted_target > 0 and s.phase == "target":
		var eff := effective_target(wanted_target, frame_limit)
		if eff != s.user_target:
			_retarget(eff, s.auto_fps)


func _clear_limit() -> void:
	cant_reach = false
	_short = 0
	_on_target = 0


## True while the TDP can't go higher for this game: at the ceiling, or its measured best is
## already under the limit.
func at_limit() -> bool:
	var s := session
	if s == null:
		return false
	if s.learned.tdp >= _top(s):
		return true
	return s.phase != "measure" and s.learned.max_fps > 0.0 and s.learned.max_fps < frame_limit * (1.0 - KEEP_PCT / 100.0)


func _track_limit(fps: float) -> void:
	last_fps = fps
	var s := session
	var goal := frame_limit
	if s != null and s.phase == "target":
		cant_reach = s.unreachable
		return
	if goal <= 0.0:
		return
	if fps >= goal * (1.0 - KEEP_PCT / 100.0):
		_short = 0
		_on_target += 1
		if cant_reach and _on_target >= RECOVER_N:
			cant_reach = false
		return
	_on_target = 0
	if at_limit():
		_short += 1
		if _short >= CANT_REACH_N:
			cant_reach = true
	else:
		_short = 0


## What the UI needs to explain cant_reach.
func limit_info() -> Dictionary:
	var s := session
	var target := frame_limit
	if s != null and s.phase == "target":
		target = float(s.user_target)
	return {"cant_reach": cant_reach, "target_fps": target, "fps": last_fps,
		"tdp_w": float(s.learned.tdp) if s != null else -1.0,
		"ceiling_w": float(_top(s)) if s != null else -1.0,
		"ref_fps": s.learned.max_fps if s != null else 0.0}


func status() -> Dictionary:
	var s := session
	if s == null:
		return {"running": false}
	var l := s.learned
	return {"running": true, "appid": s.appid, "paused": s.paused, "phase": s.phase, "learned": l.to_dict(),
		"bound": l.bound, "tdp": l.tdp, "ceiling_tdp": s.ceiling_tdp, "floor_tdp": s.floor_tdp,
		"keep_pct": s.keep_pct, "saves_w": (s.ceiling_tdp - l.tdp) if (s.phase in ["hold", "target"] and s.ceiling_tdp > l.tdp) else 0,
		"max_fps": l.max_fps, "avg_fps": s.avg_fps, "low_fps": s.low_fps,
		"pct_of_max": roundi(100.0 * s.avg_fps / l.max_fps) if l.max_fps > 0.0 and s.avg_fps > 0.0 else -1,
		"fps_per_w": s.fps_per_w, "source": s.source, "multiplier": s.multiplier, "thermal_cap": s.thermal_cap,
		"no_frames": s.no_frames, "learning": s.short_tau or s.phase != "hold" or s.quiet < SETTLED_WINDOWS,
		"last_action": s.last_action, "last_delta": s.last_delta, "target": roundi(s.target),
		"user_target": s.user_target, "auto_fps": s.auto_fps, "unreachable": s.unreachable, "best_fps": s.best_fps}
