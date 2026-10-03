extends Node

# File-based music player. Loads pre-recorded stems from assets/music/ and
# crossfades them based on a 0–4 "energy" target driven by gameplay (waiting
# → playing → damage seen → late round). Two complete loop sets are bundled;
# rebake() switches to the next one (called per match by game.gd).
#
# Each loop set ships three stems — low / mid / high — which all play in
# lock-step on their own AudioStreamPlayer. Per-frame we set every stem's
# volume_db from its current crossfade gain (see _stem_gains). The class
# preserves the old ProceduralMusic public surface (set_energy / get_energy /
# duck / generate_track / rebake / enabled / music_db) so game.gd and sfx.gd
# don't need to change.

# Each entry is one loop set. Order: [low, mid, high].
const LOOP_SETS: Array[Array] = [
	[
		preload("res://assets/music/5-low.wav"),
		preload("res://assets/music/5-mid.wav"),
		preload("res://assets/music/5-high.wav"),
	],
	[
		preload("res://assets/music/6-low.wav"),
		preload("res://assets/music/6-mid.wav"),
		preload("res://assets/music/6-high.wav"),
	],
]

# Energy → stem-peak map. Round-state semantics:
#   1 = round started, nobody's shot yet → low stem
#   2 = shots fired but no hit yet         → mid stem
#   3 = a player has been hit              → high stem
# Each stem fades out across STEM_SPACING energy units away from its peak.
# Below energy = 1 the whole mix fades down to silence (lobby / card pick
# wants quiet but still uses the low stem so the track stays continuous).
const STEM_PEAKS := [1.0, 2.0, 3.0]
const STEM_SPACING := 1.0
const MAX_ENERGY := 3

# Each loop set gets its own audio bus + low-pass filter so we can muffle
# the "old / retiring" track without dragging the new track through the
# same filter. MUSIC_BUS_NAMES[i] is the bus that LOOP_SETS[i] routes to.
const MUSIC_BUS_NAMES := ["MusicA", "MusicB"]

# Low-pass cutoff endpoints (Hz) for the card-pick muffle. Lerped log-wise
# so equal steps in muffle amount sound like equal steps in tone.
const MUFFLE_CUTOFF_OPEN := 18000.0
const MUFFLE_CUTOFF_CLOSED := 700.0
const MUFFLE_TRANSITION_SECONDS := 1.0

# When a set retires (rebake → it's no longer "current"), it holds its
# stem-mix at the retirement energy and fades visibility to 0 over this
# many seconds so the previous track tapers out instead of cutting hard.
const RETIRE_FADE_SECONDS := 3.0

# Seconds over which the next-round track's low stem fades in once card
# pick starts — slower than the muffle so the preview "creeps in" rather
# than slamming on at the same time the current track muffles.
const PREVIEW_FADE_SECONDS := 3.0

# Tempo of the bundled loops, used to snap energy-level changes to the
# next bar boundary instead of fading between stems mid-beat. If the loops
# get re-authored at a different tempo, change this.
const MUSIC_BPM := 120.0
const BEATS_PER_BAR := 4
const BAR_SECONDS := 60.0 / MUSIC_BPM * float(BEATS_PER_BAR)

var enabled: bool = true
var music_db: float = -16.0

var _target_energy: float = 0.0
var _energy: float = 0.0
var _external_duck: float = 0.0
var _current_set_idx: int = 0
# All sets play simultaneously in lock-step. _all_players[set_idx][stem_idx]
# is the player for stem N of loop set N. _apply_volumes decides who's
# audible — the current set rides _energy, the other set's low stem fades
# in during card pick (preview of the next round's track).
var _all_players: Array[Array] = []
# Per-set low-pass filter (one per MUSIC_BUS_NAMES bus). Driven by per-set
# muffle amount — each set fades its own filter independently, so the new
# track stays clean while the retiring track stays muffled.
var _set_filter: Array[AudioEffectLowPassFilter] = [null, null]
var _set_muffle_amount: Array[float] = [0.0, 0.0]
# game.gd → set_muffle(true/false). Per-set muffle target is computed each
# frame from this plus the per-set retire state.
var _global_muffle_active: bool = false
# Slow preview fade for the next-round track's low stem. 0 = silent,
# 1 = full preview level. Driven by set_muffle (active = card pick on).
var _preview_amount: float = 0.0
var _preview_target: float = 0.0
# Per-set "I just stopped being the current set" fade. _set_retire_fade goes
# 1 → 0 over RETIRE_FADE_SECONDS once that set is no longer current; while
# > 0 the set's stems play at _set_frozen_energy (the energy at retirement)
# so the previous track tapers out cleanly instead of jumping to silence
# when energy snaps to 1 on the new round.
var _set_retire_fade: Array[float] = [0.0, 0.0]
var _set_frozen_energy: Array[float] = [0.0, 0.0]
# Tracks which bar of the current set we last saw — used to snap _energy
# from its previous value to _target_energy only when the playhead crosses
# the next bar boundary. -1 means "haven't seen a bar yet".
var _last_bar_index: int = -1


## Host music takes priority over our soundtrack, never over game effects.
## Keep player volume/enabled preferences intact so they apply when it stops.
func set_host_music_playing(playing: bool) -> void:
	for bus_name in MUSIC_BUS_NAMES:
		var index := AudioServer.get_bus_index(bus_name)
		if index >= 0: AudioServer.set_bus_mute(index,playing)

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ensure_music_bus()
	randomize()
	_current_set_idx = randi() % LOOP_SETS.size()
	_start_stems()
	set_process(true)


func _process(delta: float) -> void:
	if BenchFlags.active:
		_target_energy = 0.0
		_energy = 0.0
		_apply_volumes(true)
		_update_muffle(delta)
		return
	if not enabled:
		_target_energy = 0.0
	_apply_bar_aligned_energy()
	_external_duck = maxf(0.0, _external_duck - delta * 2.5)
	_tick_retire_fade(delta)
	_apply_volumes()
	_update_muffle(delta)


# Snap _energy to _target_energy only when the current loop crosses a bar
# boundary, so the level change lands musically instead of fading mid-beat.
# Reads the playhead from the current set's first stem (all stems in a set
# play in lock-step). set_energy(immediate=true) bypasses this and snaps
# immediately on its own.
func _apply_bar_aligned_energy() -> void:
	if _all_players.is_empty():
		return
	if _current_set_idx >= _all_players.size():
		return
	var set_players: Array = _all_players[_current_set_idx]
	if set_players.is_empty():
		return
	var p: AudioStreamPlayer = set_players[0]
	if p == null or not p.playing:
		return
	var pos: float = p.get_playback_position()
	var bar_index: int = int(floor(pos / BAR_SECONDS))
	if bar_index != _last_bar_index:
		_last_bar_index = bar_index
		if not is_equal_approx(_energy, _target_energy):
			_energy = _target_energy


func _tick_retire_fade(delta: float) -> void:
	var step: float = delta / maxf(0.01, RETIRE_FADE_SECONDS)
	for set_idx in _set_retire_fade.size():
		if set_idx == _current_set_idx:
			continue
		_set_retire_fade[set_idx] = move_toward(_set_retire_fade[set_idx], 0.0, step)


# ---- public API -----------------------------------------------------------


func set_energy(level: int, immediate: bool = false, _next_bar: bool = false) -> void:
	# `next_bar` was needed by the procedural synth to align changes to a bar
	# boundary; with file-based playback we just lerp via move_toward.
	var clamped := clampi(level, 0, MAX_ENERGY)
	_target_energy = float(clamped)
	if immediate:
		_energy = _target_energy


func get_energy() -> int:
	return int(round(_target_energy))


func duck(amount: float = 0.75) -> void:
	_external_duck = maxf(_external_duck, clampf(amount, 0.0, 1.0))


# Kept as a no-op for game.gd compatibility. The synth-era version mutated
# dozens of internal params; with baked stems there's nothing to randomise
# beyond the loop choice (which rebake() handles).
func generate_track(_seed: int, _round_index: int = 0) -> void:
	pass


# Cycle to the next loop set. Called once per round from game.gd. Cheap —
# every set's players are already running in lock-step; this just changes
# which one is "current" and which is "other" (preview). The previously-
# current set goes into a retire fade-out so its mix tapers off cleanly
# instead of cutting when _energy snaps to the new round's value.
func rebake() -> void:
	var old_idx := _current_set_idx
	if old_idx < _set_retire_fade.size():
		_set_retire_fade[old_idx] = 1.0
		_set_frozen_energy[old_idx] = _energy
	_current_set_idx = (_current_set_idx + 1) % LOOP_SETS.size()
	# A set that's becoming current again (back-to-back rebakes) shouldn't
	# also be "retiring" — clear that state.
	if _current_set_idx < _set_retire_fade.size():
		_set_retire_fade[_current_set_idx] = 0.0
	# Restart the incoming set from its downbeat so a fresh track begins at 0.
	# rebake() now only fires on a deliberate song change (the 2-minute
	# boundary), so this is the "new song" moment — the retiring set keeps
	# playing from its own position as it fades out.
	if _current_set_idx < _all_players.size():
		for p in _all_players[_current_set_idx]:
			if p:
				p.seek(0.0)
	_last_bar_index = 0


# ---- internals ------------------------------------------------------------


func _ensure_music_bus() -> void:
	# One bus per loop set so we can drive an independent low-pass on each.
	# Each bus chain: low-pass (idx 0) → compressor → limiter → Master.
	for set_idx in MUSIC_BUS_NAMES.size():
		var bus_name: String = MUSIC_BUS_NAMES[set_idx]
		var idx := AudioServer.get_bus_index(bus_name)
		if idx < 0:
			idx = AudioServer.bus_count
			AudioServer.add_bus(idx)
			AudioServer.set_bus_name(idx, bus_name)
			AudioServer.set_bus_send(idx, "Master")
			var lp := AudioEffectLowPassFilter.new()
			lp.cutoff_hz = MUFFLE_CUTOFF_OPEN
			AudioServer.add_bus_effect(idx, lp)
			var comp := AudioEffectCompressor.new()
			comp.threshold = -9.0
			comp.ratio = 4.0
			comp.attack_us = 2500.0
			comp.release_ms = 140.0
			comp.gain = 0.0
			AudioServer.add_bus_effect(idx, comp)
			var lim := AudioEffectLimiter.new()
			lim.threshold_db = -2.0
			lim.ceiling_db = -0.5
			lim.soft_clip_db = 1.5
			AudioServer.add_bus_effect(idx, lim)
		# Cache the per-set low-pass reference (whether we just created the
		# bus or it survived a script reload).
		_set_filter[set_idx] = null
		for i in AudioServer.get_bus_effect_count(idx):
			var eff := AudioServer.get_bus_effect(idx, i)
			if eff is AudioEffectLowPassFilter:
				_set_filter[set_idx] = eff
				break


# Called by game.gd when the round-over muffle should engage. Per-set
# muffle is computed in _update_muffle from this plus retire state — the
# muffle stays attached to the leaving set so the new track is never
# filtered. Also drives the slow next-track preview fade-in.
func set_muffle(active: bool) -> void:
	_global_muffle_active = active
	_preview_target = 1.0 if active else 0.0


func _update_muffle(delta: float) -> void:
	# Slow preview fade — the next-round track creeps in over
	# PREVIEW_FADE_SECONDS, slower than the muffle's faster sweep, so it
	# doesn't slam on at the same time the current track muffles.
	var preview_step: float = delta / maxf(0.01, PREVIEW_FADE_SECONDS)
	_preview_amount = move_toward(_preview_amount, _preview_target, preview_step)
	# Per-set muffle: the current set takes the muffle while card pick is
	# up; once it retires the muffle stays on it for the duration of the
	# retire fade. The new current is never muffled.
	var muffle_step: float = delta / maxf(0.01, MUFFLE_TRANSITION_SECONDS)
	var open_log: float = log(MUFFLE_CUTOFF_OPEN)
	var closed_log: float = log(MUFFLE_CUTOFF_CLOSED)
	for set_idx in _set_filter.size():
		var should_muffle: bool
		if set_idx == _current_set_idx:
			should_muffle = _global_muffle_active
		else:
			should_muffle = _set_retire_fade[set_idx] > 0.0
		var target: float = 1.0 if should_muffle else 0.0
		_set_muffle_amount[set_idx] = move_toward(_set_muffle_amount[set_idx], target, muffle_step)
		var f: AudioEffectLowPassFilter = _set_filter[set_idx]
		if f:
			f.cutoff_hz = exp(lerpf(open_log, closed_log, _set_muffle_amount[set_idx]))


func _start_stems() -> void:
	# Tear down anything left over (e.g. hot reload) and spin up every
	# (set, stem) player together so all loops play in lock-step. rebake()
	# no longer touches these — it just toggles _current_set_idx.
	for set_players in _all_players:
		for p in set_players:
			if is_instance_valid(p):
				p.stop()
				p.queue_free()
	_all_players.clear()
	for set_idx in LOOP_SETS.size():
		var set_players: Array[AudioStreamPlayer] = []
		for stream in LOOP_SETS[set_idx]:
			var wav := stream as AudioStreamWAV
			# Belt-and-braces: the .import files set loop_mode=1, but the QOA-
			# compressed WAVs come back with loop=[0..0] (empty range), which
			# silences playback. Force the loop range to span the whole file
			# using the stream's reported length × mix-rate.
			if wav:
				wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
				wav.loop_begin = 0
				if wav.loop_end <= 0:
					var samples: int = int(round(wav.get_length() * float(wav.mix_rate)))
					if samples > 0:
						wav.loop_end = samples
			var p := AudioStreamPlayer.new()
			p.name = "MusicSet%d_Stem%d" % [set_idx, set_players.size()]
			p.stream = stream
			# Each set lives on its own bus so the per-set low-pass can
			# muffle one without affecting the other.
			p.bus = MUSIC_BUS_NAMES[set_idx] if set_idx < MUSIC_BUS_NAMES.size() else "Master"
			p.volume_db = -80.0
			add_child(p)
			set_players.append(p)
		_all_players.append(set_players)
	# Start every player in the same frame so the loops stay aligned.
	for set_players in _all_players:
		for p in set_players:
			p.play()


func _apply_volumes(silent: bool = false) -> void:
	if _all_players.is_empty():
		return
	var duck_db: float = -18.0 * clampf(_external_duck, 0.0, 1.0)
	var energy_active := _energy > 0.001 and enabled
	# Three modes per set:
	#   • current → ride the live _energy at full visibility.
	#   • retiring (just stopped being current) → hold the frozen energy
	#     mix and fade visibility from 1 to 0 over RETIRE_FADE_SECONDS so
	#     the previous track tapers off cleanly.
	#   • preview → energy=1 (low stem only), visibility = _muffle_amount,
	#     so the next-round track is audible underneath the card pick.
	var current_gains := _stem_gains(_energy)
	var preview_gains := _stem_gains(1.0)
	for set_idx in _all_players.size():
		var is_current := set_idx == _current_set_idx
		var retire_fade: float = _set_retire_fade[set_idx] if set_idx < _set_retire_fade.size() else 0.0
		var gains_vec: Vector3
		var visibility: float
		if is_current:
			gains_vec = current_gains
			visibility = 1.0
		elif retire_fade > 0.0:
			gains_vec = _stem_gains(_set_frozen_energy[set_idx])
			visibility = retire_fade
		else:
			gains_vec = preview_gains
			visibility = _preview_amount
		var arr := [gains_vec.x, gains_vec.y, gains_vec.z]
		var set_players: Array = _all_players[set_idx]
		for stem_idx in set_players.size():
			var p: AudioStreamPlayer = set_players[stem_idx]
			if p == null:
				continue
			var gain: float = (arr[stem_idx] if stem_idx < arr.size() else 0.0) * visibility
			if silent or not energy_active or gain <= 0.0001:
				p.volume_db = -80.0
			else:
				p.volume_db = music_db + linear_to_db(gain) + duck_db


# Triangle-shaped gain envelope for each stem: 1.0 at its peak, falling to 0
# STEM_SPACING energy units away. Multiplied by a global fade-in for the
# 0..1 region so the very-low-energy "lobby/menu" reads as silence.
func _stem_gains(energy: float) -> Vector3:
	if energy <= 0.0:
		return Vector3.ZERO
	var low: float = clampf(1.0 - absf(energy - STEM_PEAKS[0]) / STEM_SPACING, 0.0, 1.0)
	var mid: float = clampf(1.0 - absf(energy - STEM_PEAKS[1]) / STEM_SPACING, 0.0, 1.0)
	var high: float = clampf(1.0 - absf(energy - STEM_PEAKS[2]) / STEM_SPACING, 0.0, 1.0)
	var fade_in: float = clampf(energy, 0.0, 1.0)
	return Vector3(low, mid, high) * fade_in
