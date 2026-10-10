extends Node

# Crowd sound. The voiced parts (cheer and panic beds, roars, goal eruptions,
# "ooh"s, screams, chants) play short CC0 stadium recordings from samples/
# (sources in samples/CREDITS.md); the murmur and applause are synthesized at
# boot, chunked across frames. Set `use_samples = false` before adding the node
# for the fully procedural crowd. Started in Growing Guns; any
# Godot game with an audience can use it. Games keep their own copy of this
# addon in sync with joepio/godot-crowd-sound (sync.py).
#
# Two state values drive the whole mix:
#
#   enthusiasm 0..1 — exciting play: hits, goals, kills, fireworks.
#   fear       0..1 — the crowd ITSELF in danger (shot at, caught in blasts).
#
# Looping beds, crossfaded by those values:
#   murmur — idle "walla": lowpassed noise with ~4 Hz syllabic amplitude
#            flutter per channel (the classic crowd-chatter trick).
#   cheer  — roar: noise through two vocal-formant resonators. Gain follows
#            enthusiasm, suppressed by fear (a frightened crowd doesn't cheer).
#   claps  — applause, only near PEAK enthusiasm.
#   panic  — screams: higher formants, chaotic flutter, held wails. Gain
#            follows fear; fear also decays slower.
# One-shots: kick-off surge, roar, "ooh", scream burst. Chants: short
# pentatonic phrases a section sings when the mood is good.
#
# Use it as a plain node (add_child, set `active = true`, call the reaction
# methods) or extend it. Growing Guns extends it to add its colosseum ring
# geometry and route one-shots through its own SFX mixer; these are the
# overridable hooks:
#
#   _play_oneshot()   — how reactions are played (default: plain players).
#   _loudness_db()    — how far game noise is above "loud"; ducks the beds.
#   _chant_position() — where a chant comes from (Vector3.INF = 2D).
#   _suppressed()     — true mutes all reactions (benchmarks, menus).
#
# Perf: samples are streamed OGG; synthesis is boot-time. Per frame the node
# costs a few float ops.

signal synth_ready

const RATE := 22050
const LOOP_SECONDS := 6.0
const SEAM_SECONDS := 0.4  # tail crossfaded into the head for seamless loops
const CHUNK := 4096        # synth samples per frame during boot warmup

# Mix knobs (dB at full layer gain).
var murmur_db: float = -22.0
var cheer_db: float = -10.0
var panic_db: float = -9.0
var reaction_db: float = -8.0
var chant_db: float = -10.0
# Real recordings for the voiced layers (see the header). Read once in _ready.
var use_samples: bool = true
const SAMPLE_DIR := "res://addons/crowd_sound/samples/"
# Clap voicing — read at BAKE time by _synth_cheer; changing these at
# runtime needs a cheer-loop rebake (Growing Guns' crowd_lab has a button).
# The gains are RELATIVE TO THE ROAR'S MEASURED RMS (1.0 = as loud as the
# roar body) — the mix is measured, not guessed, because the formant
# resonators amplify ~40 dB and buried every hand-picked linear gain.
var clap_fore_gain: float = 0.7    # foreground pats loudness vs roar
var clap_wash_gain: float = 0.35   # fused applause bed loudness vs roar
# Applause is its own looping layer, split from the cheer bake. It only
# opens near PEAK enthusiasm (kill / round start / win) — a warm crowd
# roars but doesn't clap.
var claps_db: float = -12.0
var clap_center_hz: float = 1250.0 # foreground bandpass centre
var clap_rate: float = 32.0        # foreground pats/sec/side

# State — public so the dev panel / labs can poke it.
var enthusiasm: float = 0.0
var fear: float = 0.0
# Exponential decay rates (fraction per second). Fear lingers longer.
const ENTHUSIASM_DECAY := 0.38
const FEAR_DECAY := 0.20
# While active, enthusiasm settles here instead of 0 — a match in progress
# always has a lively (if quiet) crowd under it.
var enthusiasm_floor: float = 0.2
var chants_enabled: bool = true
# Host-set ducking input when _loudness_db isn't overridden: dB above "loud".
var loudness_db: float = 0.0
# Host-set mute for reactions when _suppressed isn't overridden.
var muted: bool = false

# Is there a crowd right now? Beds and reactions only play while true.
var active: bool = false:
	set(v):
		active = v
		if not v:
			enthusiasm = 0.0
			fear = 0.0

var _murmur_player: AudioStreamPlayer
var _cheer_player: AudioStreamPlayer
var _panic_player: AudioStreamPlayer
var _clap_player: AudioStreamPlayer
# Smoothed layer gains (0..1) so state spikes swell in instead of snapping.
var _murmur_gain: float = 0.0
var _cheer_gain: float = 0.0
var _panic_gain: float = 0.0
var _clap_gain: float = 0.0
# Claps-only mix stashed by _synth_cheer(split = true) for the caller.
var _split_claps := PackedVector2Array()
var _bus: StringName = &"Master"
var _synth_done := false

var _roar_wav: AudioStreamWAV = null
var _surge_wav: AudioStreamWAV = null  # kick-off anticipation swell
var _ooh_wav: AudioStreamWAV = null
var _scream_wav: AudioStreamWAV = null
# Recorded variants; when filled they replace the synthesized one-shot above.
var _roar_samples: Array[AudioStream] = []
var _goal_samples: Array[AudioStream] = []
var _ooh_samples: Array[AudioStream] = []
var _scream_samples: Array[AudioStream] = []
var _surge_sample: AudioStream = null
var _roar_cd: float = 0.0
var _ooh_cd: float = 0.0
var _scream_cd: float = 0.0
# While > 0, enthusiasm is pinned at 1.0 and the loudness duck is bypassed —
# the celebration owns the mix for a few seconds.
var _celebrate_hold: float = 0.0

# Chants: short pentatonic phrases a crowd section sings in rough unison,
# procedurally composed at boot (5 melodies, 3 reps baked per WAV). One
# plays at a time when enthusiasm is high; panic fades it out mid-song.
const CHANT_COUNT := 5
var _chant_wavs: Array[AudioStream] = []
var _chant_player_3d: AudioStreamPlayer3D = null
var _chant_player_2d: AudioStreamPlayer = null
# Whichever of the two the current/last chant used.
var _chant_player = null
var _chant_cd: float = 10.0
var _chant_bag: Array[int] = []
var _chant_fading: bool = false
var _chant_force_delay: float = 0.0


func _ready() -> void:
	_murmur_player = _make_loop_player()
	_cheer_player = _make_loop_player()
	_panic_player = _make_loop_player()
	_clap_player = _make_loop_player()
	_chant_player_3d = AudioStreamPlayer3D.new()
	_chant_player_3d.unit_size = 26.0
	_chant_player_3d.max_db = 6.0
	_chant_player_3d.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	_chant_player_3d.attenuation_filter_cutoff_hz = 6500.0
	_chant_player_3d.attenuation_filter_db = -12.0
	_chant_player_3d.finished.connect(_on_chant_finished)
	add_child(_chant_player_3d)
	_chant_player_2d = AudioStreamPlayer.new()
	_chant_player_2d.finished.connect(_on_chant_finished)
	add_child(_chant_player_2d)
	_chant_player = _chant_player_2d
	set_bus(_bus)
	_synth_all()


func _make_loop_player() -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.volume_db = -80.0
	add_child(p)
	return p


# Route every player this node owns (beds, chants, default one-shots).
func set_bus(bus_name: StringName) -> void:
	_bus = bus_name
	for p in [_murmur_player, _cheer_player, _panic_player, _clap_player,
			_chant_player_3d, _chant_player_2d]:
		if p != null:
			p.bus = bus_name


# True once every loop and reaction has been synthesized.
func is_ready() -> bool:
	return _synth_done


# -------------------- overridable hooks --------------------

# Plays a reaction one-shot. `at` is Vector3.INF for 2D. `priority_spl`,
# `attenuation` and `big_tail` are hints for games with their own mixer.
func _play_oneshot(stream: AudioStream, volume_db: float, at: Vector3, pitch: float,
		_label: String, _priority_spl: float, attenuation: float, _big_tail: bool) -> void:
	var p
	if at == Vector3.INF:
		p = AudioStreamPlayer.new()
	else:
		p = AudioStreamPlayer3D.new()
		if attenuation > 0.0:
			p.max_distance = attenuation * 4.0
	p.stream = stream
	p.volume_db = volume_db
	p.pitch_scale = pitch
	p.bus = _bus
	add_child(p)
	if at != Vector3.INF:
		p.global_position = at
	p.finished.connect(p.queue_free)
	p.play()


# dB the game is above "loud right now"; positive values duck the beds.
func _loudness_db() -> float:
	return loudness_db


# Where the next chant is sung from. Vector3.INF plays it 2D.
func _chant_position() -> Vector3:
	return Vector3.INF


func _suppressed() -> bool:
	return muted


# -------------------- reactions --------------------

# Kick-off / round start: the crowd roars in anticipation, old fear is
# forgotten, and enthusiasm starts high before settling to the baseline.
func kickoff() -> void:
	if not active or _suppressed():
		return
	fear = 0.0
	enthusiasm = maxf(enthusiasm, 0.85)
	# Pre-lift the cheer bed so the swell hands off into an already-roaring
	# crowd instead of tailing into a dip.
	_cheer_gain = maxf(_cheer_gain, 0.6)
	var surge: AudioStream = _surge_sample if _surge_sample != null else _surge_wav
	if surge != null:
		_roar_cd = 2.0
		_play_oneshot(surge, reaction_db, Vector3.INF,
			randf_range(0.96, 1.02), "crowd_roar", 100.0, -1.0, true)


# Win / goal — the loudest the crowd ever gets. Punchy roar on top of the
# slow surge for a sustained eruption, enthusiasm pinned at max for `hold`
# seconds so the beds stay at full roar instead of instantly decaying. A
# victory chant follows when `chant` is set.
func celebrate(hold: float = 4.0, chant: bool = true) -> void:
	if not active or _suppressed():
		return
	fear = 0.0
	enthusiasm = 1.0
	_cheer_gain = 1.0
	_celebrate_hold = hold
	_roar_cd = 2.5
	if chant:
		_chant_force_delay = 1.8
	# SPL 135: a stadium eruption really is that loud, and it has to clear an
	# HDR mixer's cull window even right after a huge explosion.
	if not _goal_samples.is_empty():
		# A recorded goal eruption already carries its own build and tail.
		_play_oneshot(_goal_samples.pick_random(), reaction_db + 4.0, Vector3.INF,
			randf_range(0.97, 1.03), "crowd_roar", 135.0, -1.0, true)
		return
	if _roar_wav != null:
		_play_oneshot(_roar_wav, reaction_db + 4.0, Vector3.INF,
			randf_range(0.96, 1.02), "crowd_roar", 135.0, -1.0, true)
	if _surge_wav != null:
		_play_oneshot(_surge_wav, reaction_db + 1.0, Vector3.INF,
			1.0, "crowd_roar", 135.0, -1.0, true)


# Something nasty-looking happened: a bump of enthusiasm and, sometimes, a
# collective "ooh" (so not every hit gets a vocal reaction).
func hit(amount: float = 0.18, ooh_chance: float = 0.4) -> void:
	if not active or _suppressed():
		return
	enthusiasm = clampf(enthusiasm + amount, 0.0, 1.0)
	var ooh := _pick(_ooh_samples, _ooh_wav)
	if _ooh_cd <= 0.0 and ooh != null and randf() < ooh_chance:
		_ooh_cd = 1.6
		_play_oneshot(ooh, reaction_db - 6.0 + enthusiasm * 3.0, Vector3.INF,
			randf_range(0.92, 1.1), "crowd_ooh", 88.0, -1.0, false)


# A big moment (a kill, a near miss): enthusiasm jumps and the whole bowl
# roars at once (2D).
func roar(amount: float = 0.6) -> void:
	if not active or _suppressed():
		return
	enthusiasm = clampf(enthusiasm + amount, 0.0, 1.0)
	var shot := _pick(_roar_samples, _roar_wav)
	if _roar_cd <= 0.0 and shot != null:
		_roar_cd = 1.4
		_play_oneshot(shot, reaction_db + enthusiasm * 3.0, Vector3.INF,
			randf_range(0.94, 1.06), "crowd_roar", 102.0, -1.0, true)


# Raise enthusiasm without a vocal reaction (fireworks, a good shot).
func excite(amount: float) -> void:
	if not active or _suppressed():
		return
	enthusiasm = clampf(enthusiasm + amount, 0.0, 1.0)


# The crowd is in danger: fear rises and a scream burst plays at `at`
# (a point in the stands; Vector3.INF for 2D). Cheering collapses by
# `cheer_keep`.
func scare(amount: float, at: Vector3 = Vector3.INF, intensity: float = 0.55,
		cheer_keep: float = 1.0) -> void:
	if not active or _suppressed():
		return
	fear = clampf(fear + amount, 0.0, 1.0)
	enthusiasm *= cheer_keep
	scream(at, intensity)


func scream(at: Vector3, intensity: float) -> void:
	var shot := _pick(_scream_samples, _scream_wav)
	if _scream_cd > 0.0 or shot == null:
		return
	_scream_cd = 0.55
	_play_oneshot(shot, reaction_db - 4.0 + intensity * 5.0, at,
		randf_range(0.9, 1.15), "crowd_scream", 96.0 + intensity * 8.0, 35.0, true)


# -------------------- per-frame mix --------------------

func _process(delta: float) -> void:
	# Enthusiasm decays toward the baseline floor (0 when inactive), so an
	# active crowd always keeps a lively undercurrent.
	var e_floor := enthusiasm_floor if active else 0.0
	enthusiasm = maxf(e_floor, enthusiasm - (enthusiasm - e_floor) * ENTHUSIASM_DECAY * delta)
	fear = maxf(0.0, fear - fear * FEAR_DECAY * delta)
	if _celebrate_hold > 0.0:
		_celebrate_hold -= delta
		enthusiasm = 1.0
	_update_chant(delta)
	_roar_cd = maxf(0.0, _roar_cd - delta)
	_ooh_cd = maxf(0.0, _ooh_cd - delta)
	_scream_cd = maxf(0.0, _scream_cd - delta)

	var murmur_t := 0.0
	var cheer_t := 0.0
	var panic_t := 0.0
	var clap_t := 0.0
	if active:
		murmur_t = clampf(0.55 + 0.3 * enthusiasm - 0.25 * fear, 0.15, 0.9)
		cheer_t = enthusiasm * (1.0 - fear * 0.75)
		panic_t = fear
		# Applause only at emotional peaks — kills / kick-off / wins push
		# enthusiasm into the 0.6..1.0 band; baseline warmth stays clap-free.
		clap_t = clampf((enthusiasm - 0.6) / 0.4, 0.0, 1.0) * (1.0 - fear * 0.75)
	# Swell up fast (crowds react quickly), settle down a bit slower.
	var k_up := minf(1.0, delta * 5.0)
	var k_down := minf(1.0, delta * 1.6)
	_murmur_gain += (murmur_t - _murmur_gain) * (k_up if murmur_t > _murmur_gain else k_down)
	_cheer_gain += (cheer_t - _cheer_gain) * (k_up if cheer_t > _cheer_gain else k_down)
	_panic_gain += (panic_t - _panic_gain) * (k_up if panic_t > _panic_gain else k_down)
	_clap_gain += (clap_t - _clap_gain) * (k_up if clap_t > _clap_gain else k_down)

	# Duck the beds under heavy action so it pushes the crowd into the
	# background naturally. Bypassed while celebrating: the winning blow's
	# loudness would otherwise shove the victory roar into the background.
	var duck: float = 0.0
	if _celebrate_hold <= 0.0:
		duck = clampf(_loudness_db() * 0.4, 0.0, 10.0)
	# While a chant runs, the free-form roar steps back only slightly — the
	# chant is ADDITIVE: the arena gets a bit louder overall when the crowd
	# organizes, with just enough duck that the beds don't smear the melody.
	var chant_duck := 0.0
	if _chant_playing() and not _chant_fading:
		chant_duck = 2.0
	_apply_gain(_murmur_player, _murmur_gain, murmur_db - duck - chant_duck * 0.3)
	_apply_gain(_cheer_player, _cheer_gain, cheer_db - duck - chant_duck)
	_apply_gain(_panic_player, _panic_gain, panic_db - duck * 0.5)
	_apply_gain(_clap_player, _clap_gain, claps_db - duck - chant_duck * 0.5)


# Layer gain (0..1) maps to a FIXED, fairly tight dB window below base_db.
# A squared-linear mapping spanned ~30 dB, so enthusiasm changes read as
# volume jumps instead of crowd-mood changes; dB-linear over 14 dB keeps
# the bed clearly present at baseline while full roar stays where it was.
const LAYER_DYN_RANGE_DB := 14.0

# -------------------- chants --------------------

func _chant_playing() -> bool:
	return _chant_player != null and _chant_player.playing


func _update_chant(delta: float) -> void:
	if _chant_player == null:
		return
	if _chant_player.playing:
		# Terror (or the crowd going away) kills the singing mid-song.
		if fear > 0.5 or not active:
			_chant_fading = true
		if _chant_fading:
			_chant_player.volume_db -= 50.0 * delta
			if _chant_player.volume_db <= -55.0:
				_chant_player.stop()
				_chant_fading = false
				_chant_cd = randf_range(16.0, 30.0)
			return
		# Heavy action ducks the chant like the beds; light fear thins it.
		var duck: float = clampf(_loudness_db() * 0.5, 0.0, 14.0)
		var target: float = chant_db - duck - fear * 10.0
		_chant_player.volume_db = lerpf(_chant_player.volume_db, target, minf(1.0, delta * 6.0))
		return
	_chant_fading = false
	if not active or not chants_enabled or _chant_wavs.is_empty() or _suppressed():
		return
	if _chant_force_delay > 0.0:
		_chant_force_delay -= delta
		if _chant_force_delay <= 0.0:
			_start_chant()
		return
	_chant_cd -= delta
	# Once armed and the mood is right, start within ~4 s (per-frame chance).
	if _chant_cd <= 0.0 and enthusiasm > 0.4 and fear < 0.25 and randf() < delta / 4.0:
		_start_chant()


func _on_chant_finished() -> void:
	_chant_cd = randf_range(14.0, 26.0)


func start_chant() -> void:
	_start_chant()


func _start_chant() -> void:
	if _chant_wavs.is_empty():
		return
	# Shuffle-bag so the same melody never repeats back-to-back.
	if _chant_bag.is_empty():
		for i in _chant_wavs.size():
			_chant_bag.append(i)
		_chant_bag.shuffle()
	var idx: int = _chant_bag.pop_back()
	var at := _chant_position()
	if at == Vector3.INF:
		_chant_player = _chant_player_2d
	else:
		_chant_player = _chant_player_3d
		_chant_player_3d.global_position = at
	_chant_player.stream = _chant_wavs[idx]
	_chant_player.volume_db = chant_db - 8.0  # swells in via the lerp above
	_chant_player.pitch_scale = randf_range(0.97, 1.03)
	_chant_player.play()
	_chant_cd = 999.0  # re-armed by finished / fade-out


# A random recorded variant, or the synthesized fallback when there are none.
func _pick(samples: Array[AudioStream], synth: AudioStream) -> AudioStream:
	return synth if samples.is_empty() else samples.pick_random()


func _apply_gain(p: AudioStreamPlayer, gain: float, base_db: float) -> void:
	if p == null or p.stream == null:
		return
	if gain < 0.005:
		p.volume_db = -80.0
		return
	p.volume_db = base_db - (1.0 - clampf(gain, 0.0, 1.0)) * LAYER_DYN_RANGE_DB


# -------------------- synthesis --------------------
# Everything below runs once at boot, chunked with process_frame awaits so
# no single frame eats a full loop's worth of synth.

func _synth_all() -> void:
	var recorded := use_samples and _load_samples()
	var murmur := await _synth_murmur(LOOP_SECONDS + SEAM_SECONDS)
	_murmur_player.stream = _to_wav(_finish_loop(murmur), true)
	_murmur_player.play()
	if not recorded:
		var cheer := await _synth_cheer(LOOP_SECONDS + SEAM_SECONDS, true, 0.0, true)
		_cheer_player.stream = _to_wav(_finish_loop(cheer), true)
	_cheer_player.play()
	_split_claps = PackedVector2Array()
	var applause := await _synth_applause(LOOP_SECONDS + SEAM_SECONDS)
	_clap_player.stream = _to_wav(_finish_loop(applause), true)
	_clap_player.play()
	if recorded:
		_panic_player.play()
		_synth_done = true
		synth_ready.emit()
		return
	var panic := await _synth_panic(LOOP_SECONDS + SEAM_SECONDS, true, 0.0)
	_panic_player.stream = _to_wav(_finish_loop(panic), true)
	_panic_player.play()
	# One-shots reuse the loop engines with an envelope instead of a seam.
	var roar := await _synth_cheer(2.6, false, 1.0)
	_roar_wav = _to_wav(_normalize(roar, 0.75), false)
	var surge := await _synth_cheer(3.5, false, 2.0)
	_surge_wav = _to_wav(_normalize(surge, 0.7), false)
	var scream := await _synth_panic(1.6, false, 1.0)
	_scream_wav = _to_wav(_normalize(scream, 0.75), false)
	var ooh := await _synth_ooh(1.1)
	_ooh_wav = _to_wav(_normalize(ooh, 0.6), false)
	for i in CHANT_COUNT:
		var chant := await _synth_chant(60101 + i * 977)
		_chant_wavs.append(_to_wav(_normalize(chant, 0.6), false))
	_synth_done = true
	synth_ready.emit()


# Time-sliced baking: yield to the next frame only once this frame has spent
# SLICE_USEC on synthesis, so fast machines finish in far fewer frames while
# no frame pays more than about that budget.
const SLICE_USEC := 2500
var _slice_start: int = 0


func _slice() -> void:
	if Time.get_ticks_usec() - _slice_start > SLICE_USEC:
		await get_tree().process_frame
		_slice_start = Time.get_ticks_usec()


# Loads the recorded layers. False (and nothing changed) when the set is
# incomplete, e.g. a game that vendored the script without samples/.
func _load_samples() -> bool:
	var cheer := _load_sample("cheer_loop")
	var panic := _load_sample("panic_loop")
	var surge := _load_sample("surge")
	var sets := {"roar": [], "goal": [], "ooh": [], "scream": [], "chant": []}
	for prefix in sets:
		for i in range(1, 10):
			var s := _load_sample("%s_%d" % [prefix, i])
			if s == null:
				break
			sets[prefix].append(s)
	if cheer == null or panic == null or surge == null:
		return false
	for prefix in sets:
		if sets[prefix].is_empty():
			return false
	_set_loop(cheer)
	_set_loop(panic)
	_cheer_player.stream = cheer
	_panic_player.stream = panic
	_surge_sample = surge
	_roar_samples.assign(sets["roar"])
	_goal_samples.assign(sets["goal"])
	_ooh_samples.assign(sets["ooh"])
	_scream_samples.assign(sets["scream"])
	_chant_wavs.assign(sets["chant"])
	return true


func _load_sample(sample_name: String) -> AudioStream:
	var path := SAMPLE_DIR + sample_name + ".ogg"
	if not ResourceLoader.exists(path):
		return null
	return load(path) as AudioStream


func _set_loop(stream: AudioStream) -> void:
	if stream is AudioStreamOggVorbis:
		stream.loop = true
	elif stream is AudioStreamWAV:
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD


func _finish_loop(buf: PackedVector2Array) -> PackedVector2Array:
	_normalize(buf, 0.7)
	# Blend the tail into the head, then drop the tail → seamless loop.
	var fade_n := int(SEAM_SECONDS * RATE)
	var body_n := buf.size() - fade_n
	for k in fade_n:
		var w := float(k) / float(fade_n)
		buf[k] = buf[k] * w + buf[body_n + k] * (1.0 - w)
	buf.resize(body_n)
	return buf


func _normalize(buf: PackedVector2Array, peak_target: float) -> PackedVector2Array:
	var peak := 0.0001
	for v in buf:
		peak = maxf(peak, maxf(absf(v.x), absf(v.y)))
	var g := peak_target / peak
	for i in buf.size():
		buf[i] = buf[i] * g
	return buf


func _to_wav(buf: PackedVector2Array, looped: bool) -> AudioStreamWAV:
	var n := buf.size()
	var data := PackedByteArray()
	data.resize(n * 4)
	for i in n:
		var v := buf[i]
		data.encode_s16(i * 4, int(clampf(v.x, -1.0, 1.0) * 32767.0))
		data.encode_s16(i * 4 + 2, int(clampf(v.y, -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.stereo = true
	wav.mix_rate = RATE
	wav.data = data
	if looped:
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = n
	return wav


# Idle crowd murmur: a small crowd of synthesized talkers. Each talker is a
# glottal pulse train (jittered, gliding intonation, phrase declination)
# through three time-varying vowel formants, with fricative/plosive noise
# for consonants and pauses between phrases. A few talkers sit close; the
# rest are lowpassed and quieter, then the whole bed goes through a small
# stadium reverb. Parameters were tuned with an AudioSet tagger as judge,
# maximizing similarity to real multi-talker babble (0.47 for the old
# noise-based walla, 0.86 for this, real babble scores 0.88).
# 6 synthesized talkers, each heard 3 times (resampled ±10%, shifted, panned
# apart) = 18 voices for the price of 6; the judge scores it the same as 16
# unique talkers.
const MURMUR_TALKERS := 6
const MURMUR_COPIES := 3
const MURMUR_NEAR := 3
# Vowel formants F1..F3 (adult average).
const VOWELS := [
	Vector3(750, 1220, 2600), Vector3(480, 1900, 2550), Vector3(300, 2250, 2950),
	Vector3(480, 880, 2550), Vector3(330, 900, 2350), Vector3(650, 1700, 2500),
	Vector3(600, 1150, 2450)]
# Talker voicing (from the search; see joepio/godot-crowd-sound tools).
var talk_f0_male: float = 114.0
var talk_f0_female: float = 210.0
var talk_phrase: float = 1.03     # max phrase length (s)
var talk_decl: float = 0.245      # pitch declination over a phrase
var talk_vowel: float = 0.112     # mean vowel length (s)
var talk_intonation: float = 0.164
var talk_env_pow: float = 0.914
var talk_pause: float = 0.228     # mean pause between phrases (s)
var talk_glide: float = 3.57      # pitch smoothing (Hz)
var talk_jitter: float = 0.021
var talk_open_q: float = 0.464    # glottal open quotient
var talk_tilt: float = 892.0      # source lowpass (Hz)
var talk_breath: float = 0.178
var talk_bw: float = 139.0        # F1 bandwidth (Hz)
var talk_fric: float = 0.022
var murmur_far_lp: float = 800.0
var murmur_far_gain: float = 0.247
var murmur_wet: float = 0.36
var murmur_seed: int = 1  # best of 8 seeds by the judge


func _synth_murmur(seconds: float) -> PackedVector2Array:
	var n := int(seconds * RATE)
	var out := PackedVector2Array()
	out.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = murmur_seed
	for k in MURMUR_TALKERS:
		var voice := await _synth_talker(n, rng)
		for copy in MURMUR_COPIES:
			var near := copy == 0 and k < MURMUR_NEAR
			var g := rng.randf_range(0.6, 1.0) if near else rng.randf_range(0.15, 0.5) * murmur_far_gain
			var pan := rng.randf()
			var gl := g * sqrt(1.0 - pan)
			var gr := g * sqrt(pan)
			var a := exp(-TAU * murmur_far_lp * rng.randf_range(0.7, 1.3) / RATE)
			var rate := 1.0 if copy == 0 else rng.randf_range(0.9, 1.12)
			var pos := 0.0 if copy == 0 else rng.randf() * n
			var lp := 0.0
			for i in n:
				var s: float
				if copy == 0:
					s = voice[i]
				else:
					var j := int(pos)
					var fr := pos - j
					s = voice[j] + (voice[(j + 1) % n] - voice[j]) * fr
					pos += rate
					if pos >= n:
						pos -= n
				if not near:
					lp = s + (lp - s) * a
					s = lp
				out[i] += Vector2(s * gl, s * gr)
			await _slice()
	return await _reverb(out, murmur_wet, 0.88)


# One talker, `n` samples, mono. Syllables are planned first, then rendered
# sample by sample with formant coefficients refreshed every 64 samples.
func _synth_talker(n: int, rng: RandomNumberGenerator) -> PackedFloat32Array:
	var f0 := rng.randf_range(talk_f0_male * 0.8, talk_f0_male * 1.25) if rng.randf() < 0.5 \
		else rng.randf_range(talk_f0_female * 0.85, talk_f0_female * 1.2)
	var fscale := 1.0 if f0 < 160.0 else 1.15
	# Syllable plan: start, consonant end, end (samples), pitch, target vowel, kind.
	var plan: Array = []
	var t := 0
	var cur := Vector3(600, 1150, 2450) * fscale
	while t < n:
		var phrase := int(rng.randf_range(0.6, talk_phrase) * RATE)
		var p0 := t
		var p_end := mini(n, t + phrase)
		while t < p_end:
			var cl := int(rng.randf_range(0.02, 0.06) * RATE)
			var vl := int(rng.randf_range(0.5, 1.5) * talk_vowel * RATE)
			var length := mini(cl + vl, n - t)
			if length <= 0:
				break
			var prog := float(t - p0) / float(phrase)
			var pitch := f0 * (1.0 + talk_decl - talk_decl * 1.3 * prog) \
				* (1.0 + rng.randf_range(-talk_intonation, talk_intonation))
			var tgt: Vector3 = VOWELS[rng.randi_range(0, VOWELS.size() - 1)] * fscale
			plan.append([t, t + mini(cl, length), t + length, pitch, cur, tgt,
				rng.randi_range(0, 2), rng.randf_range(0.3, 1.0)])
			cur = tgt
			t += length
		t += int(-log(maxf(rng.randf(), 1e-6)) * talk_pause * RATE)
	var voice := PackedFloat32Array()
	voice.resize(n)
	var fric := PackedFloat32Array()
	fric.resize(n)
	var r1 := exp(-PI * talk_bw / RATE)
	var r2 := exp(-PI * talk_bw * 1.4 / RATE)
	var r3 := exp(-PI * talk_bw * 2.0 / RATE)
	var c1 := 0.0
	var c2 := 0.0
	var c3 := 0.0
	var y1a := 0.0
	var y1b := 0.0
	var y2a := 0.0
	var y2b := 0.0
	var y3a := 0.0
	var y3b := 0.0
	var k_glide := 1.0 - exp(-TAU * talk_glide / RATE)
	var k_tilt := 1.0 - exp(-TAU * talk_tilt / RATE)
	var a_hp := exp(-TAU * 3000.0 / RATE)
	var k_fenv := 1.0 - exp(-TAU * 200.0 / RATE)
	var p_s1 := 0.0
	var p_s2 := 0.0
	var ph := 0.0
	var prev_g := 0.0
	var tilt := 0.0
	var hp_lp := 0.0
	var fenv := 0.0
	var oq := talk_open_q
	var vpeak := 0.0001
	var fpeak := 0.0001
	# Current syllable, unpacked into typed locals (Variant array reads per
	# sample were the hot spot).
	var si := -1
	var s_start := n
	var s_cend := n
	var s_end := -1
	var s_pitch := f0
	var s_from := Vector3.ZERO
	var s_to := Vector3.ZERO
	var s_kind := 0
	var s_fric := 0.0
	var s_vlen := 1.0
	var burst := int(0.012 * RATE)
	# Uniform noise with unit variance: randfn's Box-Muller is ~3x the cost.
	const U := 1.7320508
	var i := 0
	while i < n:
		var stop := mini(i + CHUNK, n)
		while i < stop:
			if i >= s_end:
				si += 1
				if si < plan.size():
					var syl: Array = plan[si]
					s_start = syl[0]
					s_cend = syl[1]
					s_end = syl[2]
					s_pitch = syl[3]
					s_from = syl[4]
					s_to = syl[5]
					s_kind = syl[6]
					s_fric = syl[7]
					s_vlen = maxf(float(s_end - s_cend), 1.0)
				else:
					s_start = n
					s_end = n + 1
			var amp := 0.0
			var fr_target := 0.0
			var pitch_target := f0
			if i >= s_start:
				pitch_target = s_pitch
				if i < s_cend:
					if s_kind == 0:
						fr_target = s_fric
					elif s_kind == 1:
						fr_target = 1.0 if i >= s_cend - burst else 0.0
					else:
						amp = 0.3
				else:
					amp = pow(sin(PI * float(i - s_cend) / s_vlen), talk_env_pow)
				if i % 64 == 0:
					var fv: Vector3
					if i < s_cend:
						fv = s_from * 0.8
					else:
						fv = (s_from * 0.85).lerp(s_to, float(i - s_cend) / s_vlen)
					c1 = 2.0 * r1 * cos(TAU * fv.x / RATE)
					c2 = 2.0 * r2 * cos(TAU * fv.y / RATE)
					c3 = 2.0 * r3 * cos(TAU * fv.z / RATE)
			# Pitch glides between syllable targets (two one-pole stages).
			p_s1 += (pitch_target - f0 - p_s1) * k_glide
			p_s2 += (p_s1 - p_s2) * k_glide
			var pitch := (f0 + p_s2) * (1.0 + talk_jitter * U * (2.0 * rng.randf() - 1.0))
			ph += pitch / RATE
			if ph >= 1.0:
				ph -= 1.0
			var g := 0.5 - 0.5 * cos(PI * ph / oq) if ph < oq \
				else maxf(cos(PI * (ph - oq) / (2.0 * (1.0 - oq))), 0.0)
			tilt += ((g - prev_g) * 30.0 - tilt) * k_tilt
			prev_g = g
			var w := U * (2.0 * rng.randf() - 1.0)
			var src := (tilt + w * talk_breath) * amp
			var o1 := (1.0 - r1) * src + c1 * y1a - r1 * r1 * y1b
			y1b = y1a
			y1a = o1
			var o2 := (1.0 - r2) * src + c2 * y2a - r2 * r2 * y2b
			y2b = y2a
			y2a = o2
			var o3 := (1.0 - r3) * src + c3 * y3a - r3 * r3 * y3b
			y3b = y3a
			y3a = o3
			var v := o1 + 0.6 * o2 + 0.3 * o3
			voice[i] = v
			vpeak = maxf(vpeak, absf(v))
			# Consonant hiss: highpassed noise under its own envelope.
			hp_lp = w + (hp_lp - w) * a_hp
			fenv += (fr_target - fenv) * k_fenv
			var f := (w - hp_lp) * fenv
			fric[i] = f
			fpeak = maxf(fpeak, absf(f))
			i += 1
		await _slice()
	var fg := vpeak * talk_fric / fpeak
	for j in n:
		voice[j] += fric[j] * fg
	return voice


# Small stereo Schroeder reverb (4 combs + 2 allpasses per channel): the
# stands' echo without convolution. `size` scales the delay lengths. All
# delay lines live in one flat buffer (packed arrays are copy-on-write, so
# per-line arrays would copy on every write).
func _reverb(buf: PackedVector2Array, wet: float, size: float) -> PackedVector2Array:
	var n := buf.size()
	var fb := 0.84
	var damp := 0.3
	var wet_buf := PackedVector2Array()
	wet_buf.resize(n)
	var peak_dry := 0.0001
	var peak_wet := 0.0001
	for ch in 2:
		var lens := PackedInt32Array()
		for base in [1557, 1617, 1491, 1422, 556, 225]:
			lens.append(int(base * size) + ch * 23)
		var offs := PackedInt32Array()
		var total := 0
		for l in lens:
			offs.append(total)
			total += l
		var d := PackedFloat32Array()
		d.resize(total)
		var p0 := 0
		var p1 := 0
		var p2 := 0
		var p3 := 0
		var p4 := 0
		var p5 := 0
		var s0 := 0.0
		var s1 := 0.0
		var s2 := 0.0
		var s3 := 0.0
		var i := 0
		while i < n:
			var stop := mini(i + CHUNK, n)
			while i < stop:
				var x: float = (buf[i].x if ch == 0 else buf[i].y) * 0.015
				var y0 := d[offs[0] + p0]
				s0 = y0 * (1.0 - damp) + s0 * damp
				d[offs[0] + p0] = x + s0 * fb
				p0 = (p0 + 1) % lens[0]
				var y1 := d[offs[1] + p1]
				s1 = y1 * (1.0 - damp) + s1 * damp
				d[offs[1] + p1] = x + s1 * fb
				p1 = (p1 + 1) % lens[1]
				var y2 := d[offs[2] + p2]
				s2 = y2 * (1.0 - damp) + s2 * damp
				d[offs[2] + p2] = x + s2 * fb
				p2 = (p2 + 1) % lens[2]
				var y3 := d[offs[3] + p3]
				s3 = y3 * (1.0 - damp) + s3 * damp
				d[offs[3] + p3] = x + s3 * fb
				p3 = (p3 + 1) % lens[3]
				var acc := y0 + y1 + y2 + y3
				var b4 := d[offs[4] + p4]
				d[offs[4] + p4] = acc + b4 * 0.5
				p4 = (p4 + 1) % lens[4]
				acc = b4 - acc
				var b5 := d[offs[5] + p5]
				d[offs[5] + p5] = acc + b5 * 0.5
				p5 = (p5 + 1) % lens[5]
				acc = b5 - acc
				var v := wet_buf[i]
				if ch == 0:
					v.x = acc
				else:
					v.y = acc
				wet_buf[i] = v
				peak_wet = maxf(peak_wet, absf(acc))
				i += 1
			await _slice()
	for v in buf:
		peak_dry = maxf(peak_dry, maxf(absf(v.x), absf(v.y)))
	var ws := peak_dry / peak_wet * wet
	for j in n:
		buf[j] = buf[j] * (1.0 - wet) + wet_buf[j] * ws
	return buf


# Applause: independent clappers, each clapping at their own steady rate
# (2-5 claps/s, ±8% timing) — periodicity per pair of hands is what makes it
# read as applause instead of rain. Each clap is a ~4 ms noise burst
# through the clapper's own bandpass. Tuned with the AudioSet tagger
# (Applause + Clapping about 1.4 of 2; the old Poisson pats read as rain).
var applause_clappers: int = 12
var applause_rate: float = 2.25    # slowest clapper (claps/s); range +2.5
var applause_hz: float = 1814.0    # bandpass centre, ±30% per clapper
var applause_bw: float = 491.0
var applause_decay: float = 0.0036 # clap burst decay (s)
var applause_raw: float = 0.077    # unfiltered share of the burst
var applause_wet: float = 0.1


func _synth_applause(seconds: float) -> PackedVector2Array:
	var n := int(seconds * RATE)
	var out := PackedVector2Array()
	out.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 55005
	for k in applause_clappers:
		var rate := rng.randf_range(applause_rate, applause_rate + 2.5)
		var f := rng.randf_range(applause_hz * 0.7, applause_hz * 1.3)
		var r := exp(-PI * applause_bw / RATE)
		var c := 2.0 * r * cos(TAU * f / RATE)
		var dec := exp(-1.0 / (applause_decay * RATE))
		var g := pow(rng.randf_range(0.3, 1.0), 1.5)
		var pan := rng.randf()
		var gl := g * sqrt(1.0 - pan)
		var gr := g * sqrt(pan)
		var next := int(rng.randf_range(0.0, 1.0 / rate) * RATE)
		var env := 0.0
		var ya := 0.0
		var yb := 0.0
		var i := 0
		while i < n:
			var stop := mini(i + CHUNK, n)
			while i < stop:
				if i == next:
					env += rng.randf_range(0.5, 1.0)
					next += int(RATE / rate * rng.randf_range(0.92, 1.08))
				env *= dec
				# Between claps the burst and its ring have died out: skip.
				if env < 0.0005 and absf(ya) < 0.0005:
					ya = 0.0
					yb = 0.0
					i += 1
					continue
				var x := 1.7320508 * (2.0 * rng.randf() - 1.0) * env
				var y := (1.0 - r) * x + c * ya - r * r * yb
				yb = ya
				ya = y
				var s := y + x * applause_raw
				out[i] += Vector2(s * gl, s * gr)
				i += 1
			await _slice()
	return await _reverb(out, applause_wet, 0.6)


# Roar engine: noise through two vocal-formant resonators (~650 / 1300 Hz,
# slowly wobbling) with a 5–6 Hz flutter — the "thousands yelling" texture —
# plus applause crackle (Poisson-triggered bright noise bursts).
# `one_shot` > 0 wraps it in a fast-attack / decaying kill-roar envelope.
func _synth_cheer(seconds: float, _looped: bool, one_shot: float, split: bool = false) -> PackedVector2Array:
	var n := int(seconds * RATE)
	# Components render into separate buffers and are mixed by MEASURED RMS
	# at the end — see the clap_*_gain comment up top.
	var roar_buf := PackedVector2Array()
	roar_buf.resize(n)
	var wash_buf := PackedVector2Array()
	wash_buf.resize(n)
	var fore_buf := PackedVector2Array()
	fore_buf.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 52002 + int(one_shot)
	# Resonator states: [y1, y2] per formant per channel.
	var f1l := Vector2.ZERO
	var f1r := Vector2.ZERO
	var f2l := Vector2.ZERO
	var f2r := Vector2.ZERO
	var c1 := 0.0
	var c2 := 0.0
	var r1 := exp(-PI * 140.0 / RATE)  # ~140 Hz formant bandwidth
	var r1sq := r1 * r1
	# Applause, two tiers. The dense WASH (~900 Poisson claps/s/side into a
	# leaky integrator) fuses into stadium crackle — that's the "thousands",
	# but by Campbell's theorem high-rate shot noise converges to a steady
	# level, so on its own it stops reading as claps at all. The FOREGROUND
	# tier (~20/s/side, heavy-tailed loudness, brighter/less filtered) rides
	# on top: the individually audible pats from the nearest rows.
	var wash_l := 0.0
	var wash_r := 0.0
	var wash_decay := exp(-1.0 / (0.009 * RATE))
	var wash_p := 1400.0 / RATE
	var clap_lp_l := 0.0
	var clap_lp_r := 0.0
	var clap_lp2_l := 0.0
	var clap_lp2_r := 0.0
	var fore_l := 0.0
	var fore_r := 0.0
	var fore_p := clap_rate / RATE
	# Foreground pats go through a two-pole BANDPASS (steep on BOTH sides)
	# around clap_center_hz. Plain lowpasses failed twice: shallow ones left
	# hiss on top (read as "high-pitched"), and cutting low enough to kill
	# the hiss sank the claps into the roar's 640-1350 Hz formant band where
	# they masked completely. A mid bandpass gives the "pok" its own slot.
	var rc := exp(-PI * 320.0 / RATE)
	var rcsq := rc * rc
	var cgain := 1.0 - rc  # input pre-scale ≈ unit peak gain at resonance
	# Per-channel filter tuning, re-rolled on every clap trigger — each pair
	# of hands gets its own centre pitch and decay length instead of every
	# pat being the identical "pok".
	var cc_l := 2.0 * rc * cos(TAU * clap_center_hz / RATE)
	var cc_r := cc_l
	var fore_decay_l := exp(-1.0 / (0.016 * RATE))
	var fore_decay_r := fore_decay_l
	var fb_l := Vector2.ZERO
	var fb_r := Vector2.ZERO
	var sw_ph := rng.randf() * TAU
	# Formant drift + loudness surge are RANDOM WALKS, not LFOs. A periodic
	# pitch wobble on a resonant filter makes the whole bed read as one siren
	# instead of thousands of voices; real crowd movement is aperiodic.
	var drift := 0.0
	var flut := 0.7
	var flut_target := 0.7
	var i := 0
	while i < n:
		var stop := mini(i + CHUNK, n)
		while i < stop:
			var t := float(i) / RATE
			if i % 64 == 0:
				drift = clampf(drift + rng.randf_range(-0.01, 0.01), -0.05, 0.05)
				var f1 := 640.0 * (1.0 + drift)
				if one_shot >= 2.0:
					# Anticipation swell: pitch climbs through the build and holds.
					f1 *= 1.0 + 0.12 * minf(t / 1.2, 1.0)
				elif one_shot > 0.0:
					# Kill roar rises in pitch as it swells, sags in the tail —
					# an envelope contour, not an oscillation.
					f1 *= 1.0 + 0.12 * minf(t / 0.45, 1.0) - 0.10 * maxf(t - 1.3, 0.0)
				c1 = 2.0 * r1 * cos(TAU * f1 / RATE)
				c2 = 2.0 * r1 * cos(TAU * f1 * 2.1 / RATE)
				# Aperiodic surging: occasionally pick a new loudness target
				# and slew toward it (~3-7 Hz feel, no fixed tremolo rate).
				if rng.randf() < 0.02:
					flut_target = rng.randf_range(0.45, 1.0)
			flut += (flut_target - flut) * 0.0005
			var swell := 0.78 + 0.22 * sin(TAU * 0.17 * t + sw_ph)
			# One-shot macro envelope — shapes voices AND applause below, so
			# the whole event tapers out instead of the claps cutting dead at
			# the end of the buffer.
			var osc_env := 1.0
			if one_shot >= 2.0:
				# Round-start anticipation: slow build, held, long release.
				osc_env = pow(minf(t / 0.6, 1.0), 1.2) * exp(-maxf(t - 1.8, 0.0) * 1.1)
			elif one_shot > 0.0:
				# Kill roar: punchy attack, quicker decay.
				osc_env = pow(minf(t / 0.14, 1.0), 1.5) * exp(-maxf(t - 0.55, 0.0) * 1.7)
			var env := flut * swell * osc_env
			var wl := rng.randf_range(-1.0, 1.0)
			var wr := rng.randf_range(-1.0, 1.0)
			var y1l := wl + c1 * f1l.x - r1sq * f1l.y
			f1l = Vector2(y1l, f1l.x)
			var y1r := wr + c1 * f1r.x - r1sq * f1r.y
			f1r = Vector2(y1r, f1r.x)
			var y2l := wl + c2 * f2l.x - r1sq * f2l.y
			f2l = Vector2(y2l, f2l.x)
			var y2r := wr + c2 * f2r.x - r1sq * f2r.y
			f2r = Vector2(y2r, f2r.x)
			# Wash: one draw decides L / R / neither; claps ADD so they fuse.
			var cr := rng.randf()
			if cr < wash_p:
				wash_l += rng.randf_range(0.2, 0.7)
			elif cr < wash_p * 2.0:
				wash_r += rng.randf_range(0.2, 0.7)
			wash_l *= wash_decay
			wash_r *= wash_decay
			clap_lp_l += (wl * wash_l - clap_lp_l) * 0.18
			clap_lp_r += (wr * wash_r - clap_lp_r) * 0.18
			clap_lp2_l += (clap_lp_l - clap_lp2_l) * 0.18
			clap_lp2_r += (clap_lp_r - clap_lp2_r) * 0.18
			# Foreground: rate breathes with the surge, amplitudes heavy-
			# tailed (pow 2.2) so most blend and the odd clap pops out.
			var fr := rng.randf()
			var fp := fore_p * (0.4 + 0.9 * flut)
			if fr < fp:
				fore_l = maxf(fore_l, 0.25 + 0.75 * pow(rng.randf(), 2.2))
				cc_l = 2.0 * rc * cos(TAU * clap_center_hz * rng.randf_range(0.72, 1.35) / RATE)
				fore_decay_l = exp(-1.0 / (rng.randf_range(0.010, 0.024) * RATE))
			elif fr < fp * 2.0:
				fore_r = maxf(fore_r, 0.25 + 0.75 * pow(rng.randf(), 2.2))
				cc_r = 2.0 * rc * cos(TAU * clap_center_hz * rng.randf_range(0.72, 1.35) / RATE)
				fore_decay_r = exp(-1.0 / (rng.randf_range(0.010, 0.024) * RATE))
			fore_l *= fore_decay_l
			fore_r *= fore_decay_r
			# Independent noise draws decorrelate the pats from the roar bed.
			var b_l := rng.randf_range(-1.0, 1.0) * fore_l * cgain + cc_l * fb_l.x - rcsq * fb_l.y
			fb_l = Vector2(b_l, fb_l.x)
			var b_r := rng.randf_range(-1.0, 1.0) * fore_r * cgain + cc_r * fb_r.x - rcsq * fb_r.y
			fb_r = Vector2(b_r, fb_r.x)
			# Both tiers breathe with the surges and follow the one-shot
			# macro envelope (osc_env is 1.0 in loops).
			var clap_mix := (0.5 + 0.5 * flut) * osc_env
			roar_buf[i] = Vector2((y1l + y2l * 0.55) * env, (y1r + y2r * 0.55) * env)
			wash_buf[i] = Vector2(clap_lp2_l, clap_lp2_r) * clap_mix
			fore_buf[i] = Vector2(b_l, b_r) * clap_mix
			i += 1
		await get_tree().process_frame
	# Measured mix: scale each clap tier so its RMS lands at the requested
	# fraction of the roar's RMS, whatever the filters did to the levels.
	var roar_rms := _rms(roar_buf)
	var wsc := roar_rms / maxf(_rms(wash_buf), 0.000001) * clap_wash_gain
	var fsc := roar_rms / maxf(_rms(fore_buf), 0.000001) * clap_fore_gain
	var out := PackedVector2Array()
	out.resize(n)
	if split:
		# Roar and applause become SEPARATE loops so runtime can gate the
		# claps on peak enthusiasm; relative fore/wash balance is preserved
		# inside the clap mix.
		var claps := PackedVector2Array()
		claps.resize(n)
		for j in n:
			out[j] = roar_buf[j]
			claps[j] = wash_buf[j] * wsc + fore_buf[j] * fsc
		_split_claps = claps
	else:
		for j in n:
			out[j] = roar_buf[j] + wash_buf[j] * wsc + fore_buf[j] * fsc
	return out


func _rms(buf: PackedVector2Array) -> float:
	var acc := 0.0
	for v in buf:
		acc += v.x * v.x + v.y * v.y
	return sqrt(acc / maxf(float(buf.size() * 2), 1.0))


# Panic engine: brighter formants (~1050 / 2450 Hz) with fast chaotic
# flutter, plus individual descending sine wails scattered through the
# buffer — the screams that read over the noise bed.
# `one_shot` > 0 packs the wails early and adds a burst envelope.
func _synth_panic(seconds: float, _looped: bool, one_shot: float) -> PackedVector2Array:
	var n := int(seconds * RATE)
	var out := PackedVector2Array()
	out.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 53003 + int(one_shot)
	# Many quiet screams over few loud ones — overlap is what makes it read
	# as a crowd panicking rather than individual performers.
	var wail_count := 18 if one_shot <= 0.0 else 9
	var w_start: Array[float] = []
	var w_dur: Array[float] = []
	var w_f0: Array[float] = []
	var w_pan: Array[float] = []
	var w_ph: Array[float] = []
	# All per-wail parameters are randomized PER SCREAM and UNCORRELATED —
	# variation lives between screams; within one scream the pitch holds.
	# The raw "baby-cry" edge comes from audio-rate AM (roughness modulation,
	# 35-90 Hz — subharmonic sidebands around every harmonic) driven into a
	# tanh saturator, NOT from pitch movement. Pitch swoops read as seagulls.
	var w_vib_hz: Array[float] = []
	var w_vib_ph: Array[float] = []
	var w_jit: Array[float] = []
	var w_rough_hz: Array[float] = []
	var w_rough_ph: Array[float] = []
	var w_rough_depth: Array[float] = []
	var w_drive: Array[float] = []
	var w_fall: Array[float] = []
	# Upper-harmonic gains, trimmed per scream so high-f0 shrieks don't push
	# harmonics past Nyquist (RATE/2 ≈ 11 kHz) and alias through the tanh.
	var w_h3: Array[float] = []
	var w_h4: Array[float] = []
	for k in wail_count:
		var span := seconds - 1.1 if one_shot <= 0.0 else seconds * 0.45
		w_start.append(rng.randf_range(0.0, maxf(span, 0.1)))
		w_dur.append(rng.randf_range(0.5, 1.0))
		w_f0.append(rng.randf_range(700.0, 2500.0))
		w_pan.append(rng.randf_range(0.15, 0.85))
		w_ph.append(rng.randf() * TAU)
		w_vib_hz.append(rng.randf_range(4.5, 7.5))
		w_vib_ph.append(rng.randf() * TAU)
		w_jit.append(0.0)
		w_rough_hz.append(rng.randf_range(35.0, 90.0))
		w_rough_ph.append(rng.randf() * TAU)
		w_rough_depth.append(rng.randf_range(0.35, 0.7))
		w_drive.append(rng.randf_range(1.6, 3.0))
		# Most screams hold dead flat; a few bend down only in the final
		# instant (pow 6 below keeps the hold clean until ~85% through).
		w_fall.append(0.0 if rng.randf() < 0.7 else rng.randf_range(0.03, 0.06))
		w_h3.append(0.35 if w_f0[k] * 3.0 < 9500.0 else 0.0)
		w_h4.append(0.2 if w_f0[k] * 4.0 < 9500.0 else 0.0)
	var f1l := Vector2.ZERO
	var f1r := Vector2.ZERO
	var f2l := Vector2.ZERO
	var f2r := Vector2.ZERO
	var c1 := 0.0
	var c2 := 0.0
	var r1 := exp(-PI * 190.0 / RATE)
	var r1sq := r1 * r1
	# Random-walk drift/surge, same reasoning as the cheer engine: no
	# periodic pitch LFO on the formants (instant siren), no fixed-rate
	# tremolo (instant helicopter). Panic just walks faster than cheer.
	var drift := 0.0
	var flut := 0.6
	var flut_target := 0.6
	var out_lp := Vector2.ZERO
	var out_lp2 := Vector2.ZERO
	var i := 0
	while i < n:
		var stop := mini(i + CHUNK, n)
		while i < stop:
			var t := float(i) / RATE
			if i % 64 == 0:
				drift = clampf(drift + rng.randf_range(-0.015, 0.015), -0.07, 0.07)
				var f1 := 1080.0 * (1.0 + drift)
				c1 = 2.0 * r1 * cos(TAU * f1 / RATE)
				c2 = 2.0 * r1 * cos(TAU * f1 * 2.3 / RATE)
				if rng.randf() < 0.035:
					flut_target = rng.randf_range(0.3, 1.0)
				# Tiny per-wail pitch jitter — humanizes the hold without
				# wobbling it; the harshness comes from the AM, not pitch.
				for k in wail_count:
					w_jit[k] = clampf(w_jit[k] + rng.randf_range(-0.008, 0.008), -0.025, 0.025)
			flut += (flut_target - flut) * 0.0007
			var env := flut
			if one_shot > 0.0:
				env *= pow(minf(t / 0.05, 1.0), 0.8) * exp(-maxf(t - 0.25, 0.0) * 2.1)
			var wl := rng.randf_range(-1.0, 1.0)
			var wr := rng.randf_range(-1.0, 1.0)
			var y1l := wl + c1 * f1l.x - r1sq * f1l.y
			f1l = Vector2(y1l, f1l.x)
			var y1r := wr + c1 * f1r.x - r1sq * f1r.y
			f1r = Vector2(y1r, f1r.x)
			var y2l := wl + c2 * f2l.x - r1sq * f2l.y
			f2l = Vector2(y2l, f2l.x)
			var y2r := wr + c2 * f2r.x - r1sq * f2r.y
			f2r = Vector2(y2r, f2r.x)
			var sl := (y1l + y2l * 0.7) * 0.016 * env
			var sr := (y1r + y2r * 0.7) * 0.016 * env
			# Screams: fast onset, then HELD at one pitch (tiny optional end
			# sag). Roughness AM at 35-90 Hz into tanh saturation supplies
			# the raw torn edge — the baby-cry mechanism (subharmonic
			# sidebands), with pitch kept nearly still.
			for k in wail_count:
				var u := (t - w_start[k]) / w_dur[k]
				if u < 0.0 or u >= 1.0:
					continue
				var vib := 1.0 + w_jit[k] + 0.01 * sin(TAU * w_vib_hz[k] * t + w_vib_ph[k])
				var rise := minf(u / 0.05, 1.0)
				var freq := w_f0[k] * (0.85 + 0.15 * rise) * (1.0 - w_fall[k] * pow(u, 6.0)) * vib
				w_ph[k] += TAU * freq / RATE
				var am := 1.0 - w_rough_depth[k] \
					+ w_rough_depth[k] * (0.5 + 0.5 * sin(TAU * w_rough_hz[k] * t + w_rough_ph[k]))
				var stack := sin(w_ph[k]) + 0.6 * sin(2.0 * w_ph[k]) \
					+ w_h3[k] * sin(3.0 * w_ph[k]) + w_h4[k] * sin(4.0 * w_ph[k])
				var body := tanh(stack * am * w_drive[k])
				# Fast attack, full-level hold, release over the last quarter.
				var wenv := minf(u / 0.06, 1.0) * clampf((1.0 - u) / 0.25, 0.0, 1.0)
				var wv := body * wenv * 0.055
				sl += wv * (1.0 - w_pan[k])
				sr += wv * w_pan[k]
			# Overall lowpass (~3 kHz, two poles) — softens the tanh edge and
			# pushes the screams back into the bed, like hearing them across
			# the arena instead of next to the mic.
			out_lp.x += (sl - out_lp.x) * 0.55
			out_lp.y += (sr - out_lp.y) * 0.55
			out_lp2 += (out_lp - out_lp2) * 0.55
			out[i] = out_lp2
			i += 1
		await get_tree().process_frame
	return out


# Stadium chant: a crowd section sings a short wordless phrase in rough
# unison, 3 repetitions per bake (quieter first rep — the section "joins in" —
# loudest middle, trailing third). Composition: 4-7 notes random-walked on a
# minor pentatonic (instant stadium flavor), chant rhythm of single/double
# units with a held final note resolving to the root, then a rest before the
# repeat. Timbre: four detuned harmonic-stack "sections" with shared
# portamento sliding into each note, syllable envelopes, breath noise and
# gentle tanh cohesion.
func _synth_chant(seed_v: int) -> PackedVector2Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	var scale := [0, 3, 5, 7, 10]  # minor pentatonic, semitones
	var root_hz := rng.randf_range(200.0, 280.0)
	var unit := rng.randf_range(0.24, 0.3)  # one rhythmic unit (~eighth note)
	var count := rng.randi_range(4, 7)
	var deg := rng.randi_range(0, 2)
	var degs: Array[int] = []
	var durs: Array[float] = []
	for n in count:
		degs.append(deg)
		if n == count - 1:
			durs.append(2.0 + float(rng.randi_range(0, 1)))  # held last note
		else:
			durs.append(1.0 if rng.randf() < 0.65 else 2.0)
		var step: int = [-1, 0, 1][rng.randi_range(0, 2)]
		if rng.randf() < 0.15:
			step = 2
		deg = clampi(deg + step, 0, scale.size() - 1)
	degs[count - 1] = 0 if rng.randf() < 0.7 else 2  # resolve home
	var rest := (2.0 + float(rng.randi_range(0, 1))) * unit
	# Flatten the 3 reps into one event list: x=start, y=end, z=freq, w=gain.
	var rep_gain := [0.65, 1.0, 0.8]
	var events: Array[Vector4] = []
	var t0 := 0.15
	for r in 3:
		for n in count:
			var f := root_hz * pow(2.0, float(scale[degs[n]]) / 12.0)
			var d: float = durs[n] * unit
			events.append(Vector4(t0, t0 + d * 0.92, f, rep_gain[r]))
			t0 += d
		t0 += rest
	var n_samp := int((t0 + 0.7) * RATE)
	# Three sub-sections of the crowd sing the same phrase SLOPPILY: each has
	# its own timing lag, detune, portamento speed, attack/release and a slow
	# individual gain wobble. Perfect sync read as one clean synth voice — the
	# smear BETWEEN sections is what makes it a crowd. Roar and melody
	# accumulate into separate buffers and are mixed by measured RMS at the
	# end (same trick as the cheer engine: resonator gains are huge and
	# hand-picked levels lie).
	var roar_acc := PackedVector2Array()
	roar_acc.resize(n_samp)
	var mel_acc := PackedVector2Array()
	mel_acc.resize(n_samp)
	var r1 := exp(-PI * 140.0 / RATE)
	var r1sq := r1 * r1
	# ~26 Hz band per partial: wide enough to sound like many voices on a
	# note, not a pure tone.
	var rm := exp(-PI * 26.0 / RATE)
	var rmsq := rm * rm
	for k in 3:
		var off: float = [0.0, 0.05, 0.09][k] + rng.randf_range(-0.02, 0.03)
		var det: float = [1.0, 1.012, 0.985][k] * rng.randf_range(0.996, 1.004)
		var porta := rng.randf_range(0.0008, 0.0018)
		var atk := rng.randf_range(0.0006, 0.0012)   # attack tau ~38-75 ms
		var rel := rng.randf_range(0.00025, 0.0005)  # release tau ~90-180 ms
		var sec_gain: float = [1.0, 0.75, 0.6][k]
		var sec_pan: float = [0.5, 0.33, 0.67][k]
		var lf := 2.0 * (1.0 - sec_pan)
		var rf := 2.0 * sec_pan
		var c1 := 0.0
		var c2 := 0.0
		var cm2 := 0.0
		var cm3 := 0.0
		var cm4 := 0.0
		var f1l := Vector2.ZERO
		var f1r := Vector2.ZERO
		var f2l := Vector2.ZERO
		var f2r := Vector2.ZERO
		var m2l := Vector2.ZERO
		var m2r := Vector2.ZERO
		var m3l := Vector2.ZERO
		var m3r := Vector2.ZERO
		var m4l := Vector2.ZERO
		var m4r := Vector2.ZERO
		var cur_f := root_hz * det
		var env := 0.0
		var ev_idx := 0
		var wob := 1.0
		var i := 0
		while i < n_samp:
			var stop := mini(i + CHUNK, n_samp)
			while i < stop:
				var t := float(i) / RATE - off
				while ev_idx < events.size() and t > events[ev_idx].y:
					ev_idx += 1
				var target_gain := 0.0
				var target_f := cur_f
				if ev_idx < events.size():
					target_f = events[ev_idx].z * det  # pre-glide toward next note
					if t >= events[ev_idx].x:
						target_gain = events[ev_idx].w
				cur_f += (target_f - cur_f) * porta
				env += (target_gain - env) * (atk if target_gain > env else rel)
				if i % 64 == 0:
					# This section drifts louder/softer on its own.
					wob = clampf(wob + rng.randf_range(-0.03, 0.03), 0.75, 1.25)
					# Formants track the note at half power — the mouth opens up
					# and the whole voice brightens on high notes.
					var track := pow(cur_f / root_hz, 0.5)
					var f1 := 640.0 * track
					c1 = 2.0 * r1 * cos(TAU * f1 / RATE)
					c2 = 2.0 * r1 * cos(TAU * f1 * 2.1 / RATE)
					# Pitched harmonics 2-4 only — the fundamental resonator was
					# a near-sine and read synthy. The ear reconstructs the pitch
					# from the overtone spacing (missing fundamental), and the
					# chant stays shouty instead of hummy.
					cm2 = 2.0 * rm * cos(TAU * cur_f * 2.0 / RATE)
					cm3 = 2.0 * rm * cos(TAU * cur_f * 3.0 / RATE)
					cm4 = 2.0 * rm * cos(TAU * cur_f * 4.0 / RATE)
				var wl := rng.randf_range(-1.0, 1.0)
				var wr := rng.randf_range(-1.0, 1.0)
				var y1l := wl + c1 * f1l.x - r1sq * f1l.y
				f1l = Vector2(y1l, f1l.x)
				var y1r := wr + c1 * f1r.x - r1sq * f1r.y
				f1r = Vector2(y1r, f1r.x)
				var y2l := wl + c2 * f2l.x - r1sq * f2l.y
				f2l = Vector2(y2l, f2l.x)
				var y2r := wr + c2 * f2r.x - r1sq * f2r.y
				f2r = Vector2(y2r, f2r.x)
				var p2l := wl + cm2 * m2l.x - rmsq * m2l.y
				m2l = Vector2(p2l, m2l.x)
				var p2r := wr + cm2 * m2r.x - rmsq * m2r.y
				m2r = Vector2(p2r, m2r.x)
				var p3l := wl + cm3 * m3l.x - rmsq * m3l.y
				m3l = Vector2(p3l, m3l.x)
				var p3r := wr + cm3 * m3r.x - rmsq * m3r.y
				m3r = Vector2(p3r, m3r.x)
				var p4l := wl + cm4 * m4l.x - rmsq * m4l.y
				m4l = Vector2(p4l, m4l.x)
				var p4r := wr + cm4 * m4r.x - rmsq * m4r.y
				m4r = Vector2(p4r, m4r.x)
				# Roar keeps sounding through the gaps at reduced level — the
				# crowd shouts the rhythm rather than switching on and off.
				var amp := env * sec_gain * wob
				var roar_amp := (0.3 + 0.7 * env) * sec_gain * wob
				roar_acc[i] = roar_acc[i] + Vector2(
					(y1l + y2l * 0.55) * roar_amp * lf,
					(y1r + y2r * 0.55) * roar_amp * rf)
				mel_acc[i] = mel_acc[i] + Vector2(
					(p2l + 0.6 * p3l + 0.35 * p4l) * amp * lf,
					(p2r + 0.6 * p3r + 0.35 * p4r) * amp * rf)
				i += 1
			await get_tree().process_frame
	# Measured mix (melody at 90% of the roar body), then a one-pole lowpass —
	# the section sings from across the arena.
	var roar_rms := _rms(roar_acc)
	var msc := roar_rms / maxf(_rms(mel_acc), 0.000001) * 0.9
	var out := PackedVector2Array()
	out.resize(n_samp)
	var lp := Vector2.ZERO
	for j in n_samp:
		var s := roar_acc[j] + mel_acc[j] * msc
		lp += (s - lp) * 0.5
		out[j] = lp
	return out


# Collective "ooh" — low soft formant swell for a nasty-looking hit.
func _synth_ooh(seconds: float) -> PackedVector2Array:
	var n := int(seconds * RATE)
	var out := PackedVector2Array()
	out.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 54004
	var f1l := Vector2.ZERO
	var f1r := Vector2.ZERO
	var r1 := exp(-PI * 110.0 / RATE)
	var r1sq := r1 * r1
	var c1 := 0.0
	var i := 0
	while i < n:
		var stop := mini(i + CHUNK, n)
		while i < stop:
			var t := float(i) / RATE
			if i % 64 == 0:
				# "ooh" formant — low, sliding down as the breath runs out.
				var f1 := 380.0 * (1.0 - 0.18 * (t / seconds))
				c1 = 2.0 * r1 * cos(TAU * f1 / RATE)
			var u := t / seconds
			var env := pow(sin(PI * clampf(u, 0.0, 1.0)), 1.4)
			var wl := rng.randf_range(-1.0, 1.0)
			var wr := rng.randf_range(-1.0, 1.0)
			var y1l := wl + c1 * f1l.x - r1sq * f1l.y
			f1l = Vector2(y1l, f1l.x)
			var y1r := wr + c1 * f1r.x - r1sq * f1r.y
			f1r = Vector2(y1r, f1r.x)
			out[i] = Vector2(y1l, y1r) * 0.03 * env
			i += 1
		await get_tree().process_frame
	return out
