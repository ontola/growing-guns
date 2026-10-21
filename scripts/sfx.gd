extends Node

# Procedural SFX. Every sound is generated fresh into a short
# AudioStreamGenerator buffer and played one-shot. No samples on disk.
#
# World sounds take an optional `at: Vector3` — when supplied, the sound
# plays through an AudioStreamPlayer3D on a reverb bus, so distance,
# stereo panning, and environment tail come "for free" from Godot's 3D
# audio pipeline. Pass Vector3.INF (or omit) for a plain 2D/UI sound.
#
# Public API: SFX.shot(w, at?), SFX.explosion(at?), SFX.melee(at?),
# SFX.grenade_launch(at?), SFX.jump(at?), SFX.landing(impact_vel, at?),
# SFX.dash(at?), SFX.footstep(at?),
# SFX.hit_received(), SFX.kill_confirm(), SFX.hitmarker(kind, dmg).

const MIX_RATE := 44100.0
# 3D sounds run through RaytracedAudioPlayer3D (raytraced-audio addon): a
# pure-GDScript wrapper over AudioStreamPlayer3D that adds a per-source
# AudioEffectLowPassFilter animated by occlusion raycasts (the "muffled
# behind walls" effect). The plugin auto-creates RaytracedReverb +
# RaytracedAmbient buses on enable; players default to RaytracedReverb.
const NO_POS := Vector3.INF
# Number of distinct sample variations per radius bucket. A random variant is
# picked per explosion call so 10 rockets/sec don't sound like the same sample
# fired 10×. Each variant is lazily synthed + cached on first request.
const EXPLOSION_VARIANTS := 5
# Same idea for gun shots — uzi-rate fire stays varied per pull.
const SHOT_VARIANTS := 5
# Bullet-on-surface ticks. Cached per [damage_bucket, variant]; full-auto
# fire ends up cycling through 5 distinct samples per damage class.
const IMPACT_VARIANTS := 5
const CASING_VARIANTS := 8
# m/s — used to delay 3D sound playback by distance/SPEED_OF_SOUND so far
# explosions arrive late, like real physics.
const SPEED_OF_SOUND := 343.0

var _sample_cache: Dictionary = {}
# Pre-converted AudioStreamWAV per cache key. Without this, every _play call
# re-converts the cached PackedVector2Array to a fresh WAV — which dominated
# the per-physics-tick cost of explosions in the perf bench (~1 ms per blast,
# 10+ blasts/sec).
var _wav_cache: Dictionary = {}
var _warmup_specials_started: bool = false
var _hurt_sounds: Array[AudioStreamWAV] = []
var _death_sounds: Array[AudioStreamWAV] = []
var _gun_sounds: Array[AudioStreamWAV] = []
var _step_sounds: Array[AudioStream] = []
# Card flip — 3 procedural variants. Played in shuffled order (each cycle
# through the 3 reshuffles) so consecutive flips don't repeat the same sample
# but you also never hear a flat round-robin pattern.
const CARD_FLIP_VARIANTS := 3
var _card_flip_order: Array[int] = []
var _card_flip_idx: int = 0

# Tunable mix knobs — adjust live via scenes/action_lab.tscn.
# Own shots: +8 dB after the Mancave playtest (Joep, 2026-10-21: "mogen wel
# wat harder"); the master limiter keeps stacked bursts from clipping.
var shot_self_db: float = -2.0
var shot_world_db: float = 5.0
var shot_dmg_per_double_db: float = 6.0
var shot_pitch_per_double: float = 0.20  # 0..1; pitch drop per damage doubling
var explosion_bang_db: float = 12.0
var explosion_rumble_db: float = 10.0
var footstep_db: float = -30.0
var jump_db: float = -7.5
var landing_max_db: float = 5.0
var hurt_self_db: float = -25.0
var hurt_world_db: float = -17.5
var death_self_db: float = -12.0
var death_world_db: float = -8.0
var lava_sizzle_db: float = -18.0
var lava_fall_sizzle_db: float = -26.0
var hit_received_db: float = -12.0
# Round-start rocket spawn — heavy rumble that ramps in over the descent.
# 2D (UI-style) so each player hears their own "rocket cabin" without
# spatial attenuation. Impact thump reuses SFX.landing() so it shares the
# rest of the game's foot-impact tuning.
var rocket_descent_db: float = -4.0
var air_strike_inbound_db: float = -4.0
var air_strike_inbound_distant_db: float = -18.0
var ion_cannon_charge_db: float = -14.0
var ion_cannon_burst_db: float = -2.0
# Mine plant — short low-thud + electronic arm-beep cue when a player drops
# a proximity mine. 3D so listeners can locate it.
var mine_plant_db: float = -10.0
# Bullet-on-surface tick. Heavier rounds add a low thump on top, so this
# baseline level governs the lightest "plink" — the synth scales the body
# upward with damage internally.
var impact_db: float = -16.0
# Brass shell hitting a hard surface. Quiet but bright — short ping that
# cuts through without ducking anything important.
var casing_db: float = -18.0
var bullet_zip_close_db: float = -24.0
var bullet_zip_far_db: float = -36.0
# Bullet-zip pitch knobs. nominal = base + speed_coef * speed_factor (Hz).
# speed_factor itself is bullet_speed / 165 m/s, clamped 0.2..5.0.
var bullet_zip_base_hz: float = 2400.0
var bullet_zip_speed_hz: float = 1300.0
const BULLET_ZIP_VARIANTS := 6
const BULLET_ZIP_MIN_INTERVAL_MS := 32
var _last_bullet_zip_ms: int = -10000
# Subsonic rumble layered under big-damage shots — same piping as the
# explosion bang+rumble pair. Default -12 dB so it sits under the gun bang.
var shot_rumble_db: float = -12.0
# Wet send for shots — a quieter copy of the bang routed through the reverb
# bus so the environmental tail is audible without smearing the dry transient.
var shot_wet_db: float = -10.0
# Same idea for explosion bang + click — adds a wet companion so the sharp
# transient picks up the room reverb (otherwise dry-only bypasses it).
var explosion_wet_db: float = -2.0
# HDR sliding-window mixing. Each sound declares a `priority_db_spl` (real-
# world Sound Pressure Level approximation). SFX tracks the rolling loudest
# active SPL; any new sound below `max_spl - HDR_WINDOW_DB` is CULLED
# entirely instead of being passed to the comp. After max_spl decays back
# toward the floor, the window slides down and quiet sounds return.
const HDR_WINDOW_DB := 35.0           # below max_spl - this many dB → culled
const HDR_RELEASE_DB_PER_SEC := 110.0 # how fast the window slides back down
const HDR_FLOOR_DB := 60.0            # ambient floor — typical room
var hdr_enabled: bool = true
var _hdr_max_spl: float = HDR_FLOOR_DB

# "Big tail" reverb — second, longer-tailed reverb bus that ALL 3D sounds
# send a copy to. The bus's output volume is driven by a dedicated combat-
# intensity tracker that decays SLOWER than _hdr_max_spl, so a one-off
# grenade explosion holds the bus open long enough for the rumble tail to
# actually build. During calm the bus is all-but-muted; during heavy fire
# (or just after a single loud event) the hall is open.
var big_tail_send_db: float = -24.0  # per-source send level into the bus
var big_tail_min_db: float = -50.0   # bus output during silence
var big_tail_max_db: float = -22.0   # bus output at peak intensity (~165 SPL)
# Intensity ramps to 1.0 on a peak event (165+ SPL). Exponential decay; rate
# 0.22 → half-life ~3 s. Slow enough that a single loud event still gets a
# trailing tail, but fast enough that stacked upgrades don't keep the hall
# open continuously and drown ambient sounds (footsteps).
const BIG_TAIL_DECAY_RATE := 0.22
const BIG_TAIL_FLOOR := 0.002  # snap-to-zero threshold so it actually settles
var _big_tail_intensity: float = 0.0
# AudioStreamPlayer3D unit_size — distance at which the inverse-distance
# attenuation curve starts falling off. Sounds want different values:
# footsteps are intimate (small unit_size), explosions carry far (large).
# The per-call attenuation_dist override lets each public function pick.
var unit_size: float = 12.0
# Audio-lab solo: when non-empty, only sounds whose debug_label starts with
# this string are played. "" = play all. Compared in _play / _play_stream;
# inner forwarded calls have empty label, so the gate ignores them.
var solo_kind: String = ""


func _ready() -> void:
	_ensure_master_chain()
	_load_assets()
	set_process(true)

func _process(delta: float) -> void:
	var _pt := Time.get_ticks_usec() if Trace.enabled else 0
	# Slide the HDR window back down toward the ambient floor at a fixed
	# release rate. New plays push the max back up via _hdr_blocks().
	if _hdr_max_spl > HDR_FLOOR_DB:
		_hdr_max_spl = maxf(HDR_FLOOR_DB, _hdr_max_spl - HDR_RELEASE_DB_PER_SEC * delta)
	# Exponential big-tail intensity decay — smooth ease-out so the bus
	# closes gradually instead of cutting the reverb tail abruptly.
	_big_tail_intensity *= exp(-BIG_TAIL_DECAY_RATE * delta)
	if _big_tail_intensity < BIG_TAIL_FLOOR:
		_big_tail_intensity = 0.0
	var idx := AudioServer.get_bus_index("BigTailReverb")
	if idx >= 0:
		# sqrt curve on the intensity → bus mapping. The linear contribution
		# formula `(SPL-60)/100` only puts mid-loud events (SPL 100, e.g. hurt
		# or hit_received) at intensity ~0.4, which on a linear ramp barely
		# opens the bus. sqrt(0.4) ≈ 0.63 nudges the hall open early while
		# keeping the peak at big_tail_max_db unchanged.
		var curve: float = sqrt(_big_tail_intensity)
		AudioServer.set_bus_volume_db(idx, lerpf(big_tail_min_db, big_tail_max_db, curve))
	if Trace.enabled:
		Trace.prof("sfx", Time.get_ticks_usec() - _pt)

# HDR gate: returns true if the sound should be CULLED entirely because it
# falls below the sliding window. Otherwise lifts max_spl and lets it play.
# Inner forwarded calls (debug_label == "") skip the gate so the recursion
# from _play() -> _play_stream() doesn't double-count.
func _hdr_blocks(priority_db_spl: float, debug_label: String) -> bool:
	if not hdr_enabled or debug_label == "":
		return false
	if priority_db_spl < _hdr_max_spl - HDR_WINDOW_DB:
		return true
	_hdr_max_spl = maxf(_hdr_max_spl, priority_db_spl)
	return false

func _load_assets() -> void:
	for i in range(1, 15):
		var path := "res://assets/audio/hurt%d.wav" % i
		if ResourceLoader.exists(path):
			_hurt_sounds.append(load(path))
	for i in range(1, 10):
		var path := "res://assets/audio/death%d.wav" % i
		if ResourceLoader.exists(path):
			_death_sounds.append(load(path))
	# Procedural gun synth handles all weapons now — gun1.wav was a single
	# fixed-character sample that didn't differentiate weapon types.

	for i in range(1, 14):
		var path := "res://assets/audio/Step-%d.wav" % i
		if ResourceLoader.exists(path):
			_step_sounds.append(load(path))

# Master chain (two stacked compressors + limiter):
#   1. Fast transient comp — instant attack, ~60 ms release. Catches sharp
#      peaks (gun clicks, explosion bangs) and ducks the rest of the mix
#      briefly so each transient PUNCHES through, recovering quickly.
#   2. Slow loudness comp — instant attack, 500 ms release. Handles sustained
#      loudness (stacked rumble) so the comp follows natural decay.
#   3. Brick-wall limiter — absolute peak safety.
func _ensure_master_chain() -> void:
	var master_idx := AudioServer.get_bus_index("Master")
	if master_idx < 0:
		return
	# Idempotent — bail if our chain is already installed.
	for i in AudioServer.get_bus_effect_count(master_idx):
		if AudioServer.get_bus_effect(master_idx, i) is AudioEffectCompressor:
			return
	# HDR sliding-window mixing now handles "loud sound dominates" by culling
	# quiet sounds at spawn time, so the master comps only need gentle peak
	# safety. Both stages are softer than pre-HDR.
	var transient_comp := AudioEffectCompressor.new()
	transient_comp.threshold = -3.0   # only catches truly hot peaks
	transient_comp.ratio = 3.0        # gentle — HDR already removed the hierarchy issues
	transient_comp.attack_us = 1.0    # instant
	transient_comp.release_ms = 80.0
	transient_comp.gain = 0.0
	transient_comp.mix = 1.0
	AudioServer.add_bus_effect(master_idx, transient_comp)
	var comp := AudioEffectCompressor.new()
	comp.threshold = -1.0     # near-ceiling, just to keep stacks under the limiter
	comp.ratio = 2.0          # gentle 2:1
	comp.attack_us = 1.0
	comp.release_ms = 400.0
	comp.gain = 0.0
	comp.mix = 1.0
	AudioServer.add_bus_effect(master_idx, comp)
	# Brick-wall as final safety — only fires if multiple loud sounds stack
	# above the ceiling despite the compressor.
	var lim := AudioEffectLimiter.new()
	lim.ceiling_db = -0.3
	# Catch peaks earlier and brick-wall harder. soft_clip_db is the knee
	# softness: HIGHER = gentler / more pass-through (counter-intuitive).
	# 1.0 gives near-brick-wall behaviour so stacked overshoots don't escape.
	lim.threshold_db = -3.0
	lim.soft_clip_db = 1.0
	AudioServer.add_bus_effect(master_idx, lim)
	_ensure_big_tail_bus()
	_tame_raytraced_reverb()

# The raytraced-audio plugin creates RaytracedReverb with default
# AudioEffectReverb params (predelay_feedback ~0.4, room_size ~0.8) which
# rings like a spring at runtime. We zero the feedback and tighten the room
# size so the bus reverb sounds like a room, not a metal coil.
func _tame_raytraced_reverb() -> void:
	var idx := AudioServer.get_bus_index("RaytracedReverb")
	if idx < 0:
		return
	var count := AudioServer.get_bus_effect_count(idx)
	for i in count:
		var fx := AudioServer.get_bus_effect(idx, i)
		if fx is AudioEffectReverb:
			var r := fx as AudioEffectReverb
			r.predelay_feedback = 0.0  # kill spring-flutter
			r.room_size = 0.55         # small-medium room
			r.damping = 0.55
			r.spread = 0.7
			r.wet = 0.35               # subtle send so dry stays dominant
			break

# Lush, long-tail reverb bus. Only loud sounds get a send (see _play_stream),
# so the room-sized "hall" only swells during combat bursts.
func _ensure_big_tail_bus() -> void:
	if AudioServer.get_bus_index("BigTailReverb") >= 0:
		return
	var idx := AudioServer.bus_count
	AudioServer.add_bus(idx)
	AudioServer.set_bus_name(idx, "BigTailReverb")
	AudioServer.set_bus_send(idx, "Master")
	# Bus output volume is driven dynamically in _process from _hdr_max_spl
	# (combat intensity) — see big_tail_min_db / big_tail_max_db.
	var rev := AudioEffectReverb.new()
	# predelay_feedback = 0 kills the "spring reverb" metallic flutter that
	# Godot's reverb gets at high room_size with non-zero feedback.
	rev.predelay_msec = 60.0
	rev.predelay_feedback = 0.0
	# Larger room → longer natural reverb tail (~3-4 s vs ~1.5 s at 0.92).
	# Means even brief inputs (small explosion's short rumble) produce an
	# audible tail since the bus stays open via slow intensity decay.
	rev.room_size = 0.97
	# damping high → high frequencies decay FAST, lows linger. Mimics how
	# distant boom reverb sounds in real life (air absorbs treble first).
	rev.damping = 0.85
	rev.spread = 0.85
	# hipass at 0 → keep the low end intact, since that's what we want to tail.
	rev.hipass = 0.0
	rev.dry = 0.0            # bus output is wet only
	rev.wet = 0.55           # softer wet so it sums more gracefully under stacks
	AudioServer.add_bus_effect(idx, rev)

func _listener_position() -> Vector3:
	var vp := get_viewport()
	if vp == null:
		return NO_POS
	# In splitscreen the cameras live inside SubViewports, so the main
	# viewport has no current Camera3D. We park an AudioListener3D at the
	# midpoint of all local players (see splitscreen_manager.gd) — prefer
	# that over the camera so distance-based effects use the midpoint.
	var listener := vp.get_audio_listener_3d()
	if listener:
		return listener.global_position
	var cam := vp.get_camera_3d()
	return cam.global_position if cam else NO_POS

# -------------------- dispatch --------------------

func _configure_3d_player(p: AudioStreamPlayer3D) -> void:
	p.unit_size = unit_size
	# Close-range cap — was 24 dB, which let close stacked rumbles overshoot
	# the master comp+limiter chain into hard clipping. 18 dB still allows a
	# modest close-range boost above the loudest source vol_db (~+19 max for
	# big-damage shots) without saturating the chain.
	p.max_db = 18.0
	p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	# Distance-based air absorption — distant sounds lose treble, like reality.
	# Cutoff = 8 kHz, max -12 dB at far range; subtle but audible.
	p.attenuation_filter_cutoff_hz = 8000.0
	p.attenuation_filter_db = -12.0
	# The plugin sets `bus` to RaytracedReverb itself on _enter_tree.

func _log_sfx(label: String, vol_db: float, at: Vector3) -> void:
	if label == "" or label.begins_with("_"):
		return
	if at == NO_POS:
		return
	var listener := _listener_position()
	var dist: float = listener.distance_to(at) if listener != NO_POS else -1.0

func _samples_to_wav(samples: PackedVector2Array) -> AudioStreamWAV:
	# Convert in-memory PackedVector2Array → 16-bit stereo WAV so the same
	# AudioStream resource can be fed to a RaytracedAudioPlayer3D's stream.
	var n := samples.size()
	var data := PackedByteArray()
	data.resize(n * 4)
	for i in n:
		var v: Vector2 = samples[i]
		var l: int = int(clampf(v.x, -1.0, 1.0) * 32767.0)
		var r: int = int(clampf(v.y, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 4, l)
		data.encode_s16(i * 4 + 2, r)
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.stereo = true
	wav.mix_rate = int(MIX_RATE)
	wav.data = data
	return wav

func _play(samples: PackedVector2Array, volume_db: float = -6.0, at: Vector3 = NO_POS, debug_label: String = "", attenuation_dist: float = -1.0, dry: bool = false, priority_db_spl: float = 80.0, big_tail: bool = true, center: bool = false) -> Node:
	if _solo_blocks(debug_label):
		return null
	if _hdr_blocks(priority_db_spl, debug_label):
		return null
	_log_sfx(debug_label, volume_db, at)
	if samples.is_empty():
		return null
	# Empty label avoids a second log line via _play_stream's own logger.
	# The empty label also skips the HDR gate inside _play_stream — already
	# admitted here, don't double-count.
	return _play_stream(_samples_to_wav(samples), volume_db, at, 1.0, "", attenuation_dist, dry, priority_db_spl, big_tail, center)

# Empty `label` is treated as a forwarded inner call (already gated upstream).
# Leading `_` means "wet companion" — silent in the log but still solo-gated by
# the rest (e.g. "_shot" matches a "shot" solo).
func _solo_blocks(label: String) -> bool:
	if solo_kind == "" or label == "":
		return false
	var key: String = label.substr(1) if label.begins_with("_") else label
	return not key.begins_with(solo_kind)

# `attenuation_dist`: per-call unit_size for 3D sounds. <= 0 means use the
# global SFX.unit_size. Sounds that should "carry" (explosions) pass a much
# larger value than incidentals (footsteps).
# `dry`: if true, plays through plain AudioStreamPlayer3D on Master (no muffle
# filter, no reverb). Use for sharp transients that should hit clean.
# `priority_db_spl`: real-world SPL approximation for HDR gating. See
# _hdr_blocks() — sounds below `max_spl - HDR_WINDOW_DB` are culled.
func _play_stream(stream: AudioStream, volume_db: float = -6.0, at: Vector3 = NO_POS, pitch_scale: float = 1.0, debug_label: String = "", attenuation_dist: float = -1.0, dry: bool = false, priority_db_spl: float = 80.0, big_tail: bool = true, center: bool = false) -> Node:
	if _solo_blocks(debug_label):
		return null
	if _hdr_blocks(priority_db_spl, debug_label):
		return null
	_log_sfx(debug_label, volume_db, at)
	if stream == null:
		return null
	# All 3D sounds (unless `big_tail=false`) send a copy to the BigTailReverb
	# bus. Bus output volume is driven by `_big_tail_intensity` in _process —
	# and we lift that intensity HERE (synchronously, before the speed-of-sound
	# delay) so the bus is already open by the time the sound and tail land.
	if at != NO_POS and big_tail:
		var contribution: float = clampf((priority_db_spl - HDR_FLOOR_DB) / 100.0, 0.0, 1.0)
		_big_tail_intensity = maxf(_big_tail_intensity, contribution)
	if at == NO_POS:
		var p := AudioStreamPlayer.new()
		p.stream = stream
		p.volume_db = volume_db
		p.pitch_scale = pitch_scale
		# 2D plays equally left and right: dead centre on any setup. A
		# receiver's upmixer (DTS:X, Dolby Surround) steers that to the centre
		# speaker by itself. MIX_TARGET_CENTER is not the way: Godot mixes a
		# stereo stream into its centre/LFE pair, left into the centre and
		# right into the sub, and on Joep's DTS:X setup that left his own
		# shots nearly silent (2026-10-21).
		# `center` sounds were 3D at the muzzle, about a metre away, before
		# they moved here; give them the level that had (inverse distance at
		# 1 m, capped like _configure_3d_player). Played flat they came out
		# ~16 dB quieter, the other half of "I can't hear my shots".
		if center:
			var unit: float = attenuation_dist if attenuation_dist > 0.0 else unit_size
			p.volume_db = minf(volume_db + 20.0 * log(unit) / log(10.0), 18.0)
		add_child(p)
		p.play()
		var life_2d: float = stream.get_length() / maxf(0.1, pitch_scale) + 0.15
		get_tree().create_timer(life_2d).timeout.connect(p.queue_free)
		return p
	# 3D — delay playback by distance/SPEED_OF_SOUND so far sounds arrive late.
	# Listener position is captured at call time; if the listener moves during
	# the delay, attenuation still re-resolves at play time on the live position.
	var listener_pos := _listener_position()
	var delay: float = 0.0
	if listener_pos != NO_POS:
		delay = listener_pos.distance_to(at) / SPEED_OF_SOUND
	if delay < 0.01:
		var p2 := _spawn_3d_player(stream, volume_db, at, pitch_scale, attenuation_dist, dry)
		if big_tail:
			_spawn_big_tail_send(stream, volume_db + big_tail_send_db, at, pitch_scale, debug_label)
		for ghost_pos in _splitscreen_ghost_positions(at):
			_spawn_3d_player(stream, volume_db, ghost_pos, pitch_scale, attenuation_dist, dry)
			if big_tail:
				_spawn_big_tail_send(stream, volume_db + big_tail_send_db, ghost_pos, pitch_scale, debug_label)
		return p2
	get_tree().create_timer(delay).timeout.connect(func() -> void:
		_spawn_3d_player(stream, volume_db, at, pitch_scale, attenuation_dist, dry)
		if big_tail:
			_spawn_big_tail_send(stream, volume_db + big_tail_send_db, at, pitch_scale, debug_label)
		for ghost_pos in _splitscreen_ghost_positions(at):
			_spawn_3d_player(stream, volume_db, ghost_pos, pitch_scale, attenuation_dist, dry)
			if big_tail:
				_spawn_big_tail_send(stream, volume_db + big_tail_send_db, ghost_pos, pitch_scale, debug_label))
	return null


# In splitscreen, fan a 3D source out across each non-primary local player so
# every player's perspective gets mixed into the single audio output. The
# ghost positions are computed so the host-anchored listener perceives them
# the way each secondary player would have perceived the original source.
func _splitscreen_ghost_positions(at: Vector3) -> Array:
	var scene := get_tree().current_scene
	if scene == null:
		return []
	var ss := scene.get_node_or_null("Splitscreen")
	if ss == null or not ss.has_method("ghost_positions_for"):
		return []
	return ss.ghost_positions_for(at)

# Spawns a quieter copy of a stream that plays into the BigTailReverb bus,
# producing the long-tail hall sound for loud events. The player auto-frees
# after the stream finishes; the bus continues to render the reverb tail.
func _spawn_big_tail_send(stream: AudioStream, volume_db: float, at: Vector3, pitch_scale: float, debug_label: String = "") -> void:
	if _solo_blocks(debug_label):
		return
	if at == NO_POS:
		var p := AudioStreamPlayer.new()
		p.stream = stream
		p.volume_db = volume_db
		p.pitch_scale = pitch_scale
		p.bus = "BigTailReverb"
		add_child(p)
		p.play()
		var life: float = stream.get_length() / maxf(0.1, pitch_scale) + 0.2
		get_tree().create_timer(life).timeout.connect(p.queue_free)
		return
	var p3 := AudioStreamPlayer3D.new()
	_configure_3d_player(p3)
	p3.bus = "BigTailReverb"
	# ATTENUATION_DISABLED — wet send stays at constant volume regardless of
	# distance, while keeping 3D positioning (stereo pan + plugin muffle).
	# This implements the real-world "diffuse reverberant field is roughly
	# constant in a room" behavior: the dry signal attenuates with distance,
	# the wet doesn't, so the wet/dry ratio increases for far sources →
	# distant explosions get a hangar-style tail without changing the dry mix.
	p3.attenuation_model = AudioStreamPlayer3D.ATTENUATION_DISABLED
	p3.stream = stream
	p3.volume_db = volume_db
	p3.pitch_scale = pitch_scale
	add_child(p3)
	p3.global_position = at
	p3.play()
	var life: float = stream.get_length() / maxf(0.1, pitch_scale) + 0.3
	get_tree().create_timer(life).timeout.connect(p3.queue_free)

func _spawn_3d_player(stream: AudioStream, volume_db: float, at: Vector3, pitch_scale: float, attenuation_dist: float, dry: bool = false) -> Node:
	# Dry path uses plain AudioStreamPlayer3D on Master so it bypasses both
	# the per-source muffle filter AND the RaytracedReverb bus.
	var p: AudioStreamPlayer3D = AudioStreamPlayer3D.new() if dry else RaytracedAudioPlayer3D.new()
	_configure_3d_player(p)
	if dry:
		p.bus = "Master"
	if attenuation_dist > 0.0:
		p.unit_size = attenuation_dist
	p.stream = stream
	p.volume_db = volume_db
	p.pitch_scale = pitch_scale
	add_child(p)
	p.global_position = at
	p.play()
	# +1.5 s buffer so the shared reverb bus's tail can play out before the
	# player is freed (and its bus removed, which would silence in-flight tail).
	var life: float = stream.get_length() / maxf(0.1, pitch_scale) + 1.5
	get_tree().create_timer(life).timeout.connect(p.queue_free)
	return p

func _cached_samples(key: String, generator: Callable) -> PackedVector2Array:
	if not _sample_cache.has(key):
		_sample_cache[key] = generator.call()
	return _sample_cache[key]

# Returns a cached AudioStreamWAV for the given key, generating + converting
# the PackedVector2Array on first request. Hot paths (explosion / shot /
# casing) call this instead of `_samples_to_wav(_cached_samples(...))` so
# they avoid re-allocating a fresh WAV (and its byte-array data) per call.
func _cached_wav(key: String, generator: Callable) -> AudioStreamWAV:
	if not _wav_cache.has(key):
		var samples: PackedVector2Array = _cached_samples(key, generator)
		_wav_cache[key] = _samples_to_wav(samples)
	return _wav_cache[key]

# Pre-cache shot + explosion samples for the given weapons / radii so first-
# fire stutters (30-50ms of synth on the audio thread) are paid during a
# quiet warmup window — round start or post-card-pick — instead of mid-fight.
# Spreads the work across frames via `await get_tree().process_frame` between
# tasks so a long warmup pass never freezes the simulation. Cache hits are
# instant no-ops so re-calling with overlapping inputs is cheap.
func warmup_async(weapons: Array, radii: Array) -> void:
	for w in weapons:
		if w == null:
			continue
		for v in SHOT_VARIANTS:
			var key := _shot_cache_key(w, v)
			_cached_wav(key, Callable(self, "_synth_shot").bind(w, v))
			await get_tree().process_frame
		# Its near-miss zips too (same buckets as bullet_zip).
		var speed_bucket := int(round(clampf((w as Weapon).get_bullet_speed() / 165.0, 0.2, 5.0) * 10.0))
		var scale_bucket := int(round(clampf((w as Weapon).get_bullet_scale_for_shot(false), 0.5, 4.0) * 10.0))
		for v in BULLET_ZIP_VARIANTS:
			_cached_wav("bullet_zip:%d:%d:%d" % [speed_bucket, scale_bucket, v],
				Callable(self, "_synth_bullet_zip").bind(float(speed_bucket) / 10.0, float(scale_bucket) / 10.0))
			await get_tree().process_frame
	for radius in radii:
		var r_bucket: int = int(round(clampf(float(radius), 2.0, 24.0)))
		for v in EXPLOSION_VARIANTS:
			var bang_key := "explosion_bang:%d:%d" % [r_bucket, v]
			_cached_wav(bang_key, Callable(self, "_synth_explosion").bind(float(r_bucket), v))
			await get_tree().process_frame
			var rumble_key := "explosion_rumble:%d:%d" % [r_bucket, v]
			_cached_wav(rumble_key, Callable(self, "_synth_explosion_rumble").bind(float(r_bucket), v))
			await get_tree().process_frame


# One-time warmup (called once at game boot from Game._ready) for the
# procedurally-synthesized effect sounds that warmup_async — shots + explosions,
# re-run each round — doesn't cover. Each first synth is otherwise a main-thread
# hitch the first time the effect fires; the ion charge is the worst (a 3.8s
# buffer). One synth per frame, like warmup_async, so boot doesn't spike. The
# keys/buckets mirror the live call sites — keep them in sync if those change.
func warmup_specials() -> void:
	if _warmup_specials_started:
		return
	_warmup_specials_started = true
	_warmup_specials_async()


func _warmup_specials_async() -> void:
	# Ion cannon. Charge bucket from IonCannon.CHARGE_SECONDS (3.8); detonation
	# from BLAST_RADIUS (38) — its burst zap plus the bucket-24 explosion boom
	# it layers on top (radius 38 clamps to the bang/rumble bucket 24, which the
	# [4,6,8,10] per-round warmup never reaches).
	_cached_wav("ion_cannon_charge:3.80", Callable(self, "_synth_ion_cannon_charge").bind(3.8))
	await get_tree().process_frame
	for v in 3:
		_cached_wav("ion_cannon_burst:38:%d" % v, Callable(self, "_synth_ion_cannon_burst").bind(38.0, v))
		await get_tree().process_frame
	for v in EXPLOSION_VARIANTS:
		_cached_wav("explosion_bang:24:%d" % v, Callable(self, "_synth_explosion").bind(24.0, v))
		await get_tree().process_frame
		_cached_wav("explosion_rumble:24:%d" % v, Callable(self, "_synth_explosion_rumble").bind(24.0, v))
		await get_tree().process_frame
	# Standard grenade blast radius (6 m) — first RMB throw otherwise synths here.
	for v in EXPLOSION_VARIANTS:
		_cached_wav("explosion_bang:6:%d" % v, Callable(self, "_synth_explosion").bind(6.0, v))
		await get_tree().process_frame
		_cached_wav("explosion_rumble:6:%d" % v, Callable(self, "_synth_explosion_rumble").bind(6.0, v))
		await get_tree().process_frame
	# Grenade launcher foomp + round-start rocket descent whistle.
	for v in 5:
		_cached_samples("grenade_launch:%d" % v, Callable(self, "_synth_grenade_launch").bind(v))
		await get_tree().process_frame
	_cached_samples("rocket_descent", Callable(self, "_synth_rocket_descent"))
	await get_tree().process_frame
	# Air strike inbound whistle. Bucket from AirStrike.ROCKET_TRAVEL_SECONDS
	# (2.3 → 2.25); warm both the near and distant timbre.
	for distant in [0, 1]:
		_cached_wav("air_strike_inbound:2.25:%d" % distant,
			Callable(self, "_synth_air_strike_inbound").bind(2.25, distant == 1))
		await get_tree().process_frame
	# Lava sizzle — contact + fall, 3 variants each.
	for fall in [false, true]:
		var mode := "fall" if fall else "contact"
		for v in 3:
			_cached_wav("lava_sizzle2:%s:%d" % [mode, v], Callable(self, "_synth_lava_sizzle").bind(v, fall))
			await get_tree().process_frame
	# Brass casing pings — every shot drops one, but warm the pool so the very
	# first casing of the match doesn't synth mid-frame either.
	for v in CASING_VARIANTS:
		_cached_wav("casing_drop:%d" % v, Callable(self, "_synth_casing_drop").bind(v))
		await get_tree().process_frame
	# Proximity-mine arm beep.
	_cached_samples("mine_plant", Callable(self, "_synth_mine_plant"))
	await get_tree().process_frame
	# Everything else that used to synth on its first play mid-match. Timed
	# on a laptop CPU: explosions 40-85 ms each, reload 20 ms, pickup drop and
	# enemy siren ~16 ms, the rest 1-5 ms (but a frame's budget is 16).
	# Small blasts: fragments, dash bombs, cluster pops and explosive rounds
	# land in buckets 2-12, and only 4/6/8/10/24 were warmed.
	for r_bucket: int in range(2, 13):
		if r_bucket in [4, 6, 8, 10]:
			continue
		for v in EXPLOSION_VARIANTS:
			_cached_wav("explosion_bang:%d:%d" % [r_bucket, v], Callable(self, "_synth_explosion").bind(float(r_bucket), v))
			await get_tree().process_frame
			_cached_wav("explosion_rumble:%d:%d" % [r_bucket, v], Callable(self, "_synth_explosion_rumble").bind(float(r_bucket), v))
			await get_tree().process_frame
	var one_offs := {
		"pickup_drop": Callable(self, "_synth_pickup_drop"),
		"enemy_incoming": Callable(self, "_synth_enemy_incoming"),
		"hit_received": Callable(self, "_synth_hit_received"),
		"kill_confirm": Callable(self, "_synth_kill_confirm"),
		"next_round": Callable(self, "_synth_next_round"),
		"empty_chamber": Callable(self, "_synth_empty_chamber"),
		"dash": Callable(self, "_synth_dash"),
	}
	for key: String in one_offs:
		_cached_samples(key, one_offs[key])
		await get_tree().process_frame
	for step in 3:
		_cached_samples("pick_beep_%d" % step, Callable(self, "_synth_pick_beep").bind(step))
		await get_tree().process_frame
	for v in CARD_FLIP_VARIANTS:
		_cached_samples("card_flip:%d" % v, Callable(self, "_synth_card_flip").bind(v))
		await get_tree().process_frame
	# Hits at base damage and at a headshot's double, every variant.
	for dmg_ratio: float in [1.0, 2.0]:
		var dmg_bucket := int(round(dmg_ratio * 4.0))
		for v in IMPACT_VARIANTS:
			_cached_samples("impact:%d:%d" % [dmg_bucket, v], Callable(self, "_synth_impact").bind(dmg_ratio, v))
			await get_tree().process_frame
	for kind: String in ["body", "head"]:
		for dmg: int in [0, int(Weapon.BASE_DAMAGE), int(Weapon.BASE_DAMAGE * 2.0)]:
			var ratio := 1.0 if dmg == 0 else clampf(float(dmg) / Weapon.BASE_DAMAGE, 0.5, 5.0)
			_cached_samples(_hitmarker_cache_key(kind, dmg), Callable(self, "_synth_hitmarker").bind(kind, ratio))
			await get_tree().process_frame
	# Bullets flying past at the base speed and size.
	for v in BULLET_ZIP_VARIANTS:
		_cached_wav("bullet_zip:10:10:%d" % v, Callable(self, "_synth_bullet_zip").bind(1.0, 1.0))
		await get_tree().process_frame


func _shot_cache_key(w: Weapon, variant: int, last_in_mag: bool = false) -> String:
	if w == null:
		return "shot:default:%d" % variant
	var damage_bucket := int(round(w.get_damage_for_shot(last_in_mag) / 5.0))
	var spread_bucket := int(round(w.spread * 1000.0))
	var fire_bucket := int(round(w.fire_rate_mult * 10.0))
	var speed_bucket := int(round(w.bullet_speed_mult * 4.0))  # 0.25 increments
	return "shot:%d:%d:%d:%d:%d" % [damage_bucket, spread_bucket, fire_bucket, speed_bucket, variant]

func _hitmarker_cache_key(kind: String, dmg: int) -> String:
	var dmg_bucket := 0
	if dmg > 0:
		dmg_bucket = int(round(clampf(float(dmg) / Weapon.BASE_DAMAGE, 0.5, 5.0) * 4.0))
	return "hitmarker:%s:%d" % [kind, dmg_bucket]

# -------------------- sounds --------------------

func shot(w: Weapon = null, at: Vector3 = NO_POS, is_self: bool = false, silenced: bool = false, last_in_mag: bool = false) -> void:
	# Use a random real-gun sample when available; fall back to the synth.
	# Higher-damage weapons pitch down (heavier report) AND get louder.
	# Self-shots play 2D at their own volume so the local BANG can be tuned
	# independently of distance attenuation / world reverb.
	var dmg_db: float = 0.0
	if w != null:
		var dmg_ratio: float = maxf(0.5, w.get_damage_for_shot(last_in_mag) / Weapon.BASE_DAMAGE)
		dmg_db = clampf(log(dmg_ratio) / log(2.0) * shot_dmg_per_double_db, -4.0, 14.0)
	var pitch := 1.0
	if w != null:
		var dmg_ratio_p: float = maxf(1.0, w.get_damage_for_shot(last_in_mag) / Weapon.BASE_DAMAGE)
		pitch = clampf(1.0 - (log(dmg_ratio_p) / log(2.0)) * shot_pitch_per_double, 0.35, 1.15)
		pitch *= randf_range(0.97, 1.03)
	# Self vs world base levels (knobs let the audio lab tune them live).
	var self_base: float = shot_self_db + randf_range(-1.5, 1.5)
	var world_base: float = shot_world_db + randf_range(-1.5, 1.5)
	if silenced:
		self_base -= 10.0
		world_base -= 12.0
		pitch *= 1.08
	# unit_size for shots — past this, treble rolls off and volume drops with
	# inverse-distance. 6 m gives noticeable close/mid/far distinction in a
	# typical arena while still carrying audibly to the far walls.
	var shot_dist: float = 6.0
	# Self shots play 3D at the muzzle (1 m from listener -> within unit_size,
	# full volume) so they route through RaytracedReverb and pick up the
	# environment tail. Pure 2D self-shots sounded thin / dry.
	var shot_variant: int = randi() % SHOT_VARIANTS
	# Two spawns: dry primary on Master (preserves the sharp transient) +
	# quieter wet copy through RaytracedReverb (adds environmental tail).
	# `shot_wet_db` is the offset from the dry level for the wet copy.
	var dry_vol: float = (self_base if is_self else world_base) + dmg_db
	var wet_vol: float = dry_vol + shot_wet_db
	var label := "shot_self" if is_self else "shot"
	# Real-world rifle SPL is ~150-165 dB at the muzzle. Scale with damage so
	# bigger guns push the HDR window higher, ducking weaker sounds harder.
	var dmg_log: float = 0.0 if w == null else log(maxf(1.0, w.get_damage_for_shot(last_in_mag) / Weapon.BASE_DAMAGE)) / log(2.0)
	# Game-mixed SPL — real rifles read 148+ dB at the muzzle but that pushes
	# the HDR window so high a single shot mutes everything else. Compressed
	# baseline at 105 dB lets footsteps (78 SPL) survive a base rifle but
	# upgraded weapons (2× dmg → 119, 4× → 133) still duck them.
	var spl: float = 105.0 + dmg_log * 7.0
	ProceduralMusic.duck(0.18 + clampf(dmg_log * 0.08, 0.0, 0.32))
	# Wet companion uses "_<label>" — silent in the log, still solo-gated.
	var wet_label := "_" + label
	# Your own bang comes from the middle (the centre speaker in 5.1), not
	# from the muzzle: the muzzle sits off to one side of the listener, so
	# strafing used to throw your own shots into the left or right speaker
	# (Joep, 2026-10-19). The quieter wet copy stays in the room for the tail.
	var dry_at: Vector3 = NO_POS if is_self else at
	if not _gun_sounds.is_empty():
		var stream: AudioStream = _gun_sounds.pick_random()
		_play_stream(stream, dry_vol, dry_at, pitch, label, shot_dist, true, spl, true, is_self)
		_play_stream(stream, wet_vol, at, pitch, wet_label, shot_dist, false, spl)
	else:
		var key := _shot_cache_key(w, shot_variant, last_in_mag)
		var wav := _cached_wav(key, Callable(self, "_synth_shot").bind(w, shot_variant))
		_play_stream(wav, dry_vol, dry_at, pitch, label, shot_dist, true, spl, true, is_self)
		_play_stream(wav, wet_vol, at, pitch, wet_label, shot_dist, false, spl)
	# Rumble layer — only for hard-hitting weapons (>1.4× base damage). Reuses
	# the explosion rumble synth + cache (same brown-noise body) but at a much
	# lower dB so it sits under the bang. Snipers, bazookas, etc. get a real
	# subsonic punch; default rifles stay clean.
	if w != null:
		var dmg_ratio_r: float = w.get_damage_for_shot(last_in_mag) / Weapon.BASE_DAMAGE
		if dmg_ratio_r > 1.4:
			var rumble_radius: int = int(round(clampf(dmg_ratio_r * 1.5, 2.0, 12.0)))
			var rumble_variant: int = randi() % EXPLOSION_VARIANTS
			var rumble_key := "explosion_rumble:%d:%d" % [rumble_radius, rumble_variant]
			var rumble_dist: float = clampf(float(rumble_radius) * 0.8, 4.0, 12.0)
			_play(_cached_samples(rumble_key, Callable(self, "_synth_explosion_rumble").bind(float(rumble_radius), rumble_variant)),
				shot_rumble_db, dry_at, "shot_rumble", rumble_dist, false, spl, true, is_self)
func grenade_launch(at: Vector3 = NO_POS) -> void:
	var variant := randi() % 5
	var key := "grenade_launch:%d" % variant
	_play(_cached_samples(key, Callable(self, "_synth_grenade_launch").bind(variant)), -6.0, at, "grenade_launch", -1.0, false, 110.0)

# Brief metallic click — bolt cycling / next round chambering between shots.
# dry=true so the click stays crisp instead of washing through reverb.
func next_round(at: Vector3 = NO_POS) -> void:
	_play(_cached_samples("next_round", Callable(self, "_synth_next_round")), -16.0, at, "next_round", 5.0, true, 65.0)

# Tiny dry click — "nothing happens" when trigger pulled but gun isn't ready.
func empty_chamber(at: Vector3 = NO_POS) -> void:
	_play(_cached_samples("empty_chamber", Callable(self, "_synth_empty_chamber")), -10.0, at, "empty_chamber", 5.0, true, 55.0)

# Zip-by sound for a bullet passing the listener. Synthesised fresh each
# time so per-call jitter (pitch wobble, doppler sweep) varies naturally;
# the synth itself is cheap (≤4k samples, mono) and fires at most once per
# bullet. Out-of-range bullets bail before any allocation.
func bullet_zip(speed: float, scale: float, at: Vector3) -> void:
	if BenchFlags.active and BenchFlags.no_bullet_zips:
		return
	var listener := _listener_position()
	if listener == NO_POS:
		return
	var dist_sq: float = listener.distance_squared_to(at)
	# Quick reject: well outside the audible bubble.
	if dist_sq > 144.0:  # 12 m
		return
	var now := Time.get_ticks_msec()
	if now - _last_bullet_zip_ms < BULLET_ZIP_MIN_INTERVAL_MS:
		return
	_last_bullet_zip_ms = now
	var speed_factor: float = clampf(speed / 165.0, 0.2, 5.0)
	var scale_factor: float = clampf(scale, 0.5, 4.0)
	# Range-driven volume: gentle sqrt falloff so a 5 m miss isn't dramatically
	# quieter than a 1 m miss — keeps the perceived "lots of bullets around me"
	# wash instead of every shot being a punchy near-miss or inaudible.
	var dist: float = sqrt(dist_sq)
	var prox: float = clampf(1.0 - dist / 12.0, 0.0, 1.0)
	prox = sqrt(prox)
	var dist_db: float = lerpf(bullet_zip_far_db, bullet_zip_close_db, prox)
	# Speed-driven boost: slow grenades (sf≈0.2) sit ~14 dB below sniper rounds
	# (sf=4) so a faster bullet feels meaningfully more violent passing by, not
	# just slightly different. Hypersonic (sf=5) tops out a few dB louder again.
	var speed_norm: float = clampf((speed_factor - 0.2) / 4.8, 0.0, 1.0)
	var speed_db: float = lerpf(-10.0, 6.0, speed_norm)
	var vol_db: float = dist_db + speed_db
	var speed_bucket := int(round(speed_factor * 10.0))
	var scale_bucket := int(round(scale_factor * 10.0))
	var variant := randi() % BULLET_ZIP_VARIANTS
	var key := "bullet_zip:%d:%d:%d" % [speed_bucket, scale_bucket, variant]
	var wav := _cached_wav(
		key,
		Callable(self, "_synth_bullet_zip").bind(float(speed_bucket) / 10.0, float(scale_bucket) / 10.0)
	)
	# Real near-miss zips read ~95 dB; supersonic rounds peak well above 130 dB
	# from the ballistic crack alone. Scale priority high enough that the
	# sniper zip survives HDR culling next to its own ~157 dB gunshot
	# (cull threshold = max_spl - HDR_WINDOW_DB ≈ 122).
	var spl: float = lerpf(95.0, 135.0, speed_norm)
	# Dry primary — clean transient, no tail smear.
	_play_stream(wav, vol_db, at, 1.0, "bullet_zip", -1.0, true, spl, false)
	# Manual reverb companion at a much hotter level than the default
	# big_tail_send_db (-24): supersonic zips need a noticeable hangar tail.
	# Send level scales with speed (slow grenades stay dry, fast rounds get
	# a wide spatial impression). Also push intensity so the bus opens up
	# even when no other loud event has primed it.
	if speed_norm > 0.0:
		var send_db: float = vol_db + lerpf(-30.0, -2.0, speed_norm)
		_big_tail_intensity = maxf(_big_tail_intensity, lerpf(0.3, 1.0, speed_norm))
		_spawn_big_tail_send(wav, send_db, at, 1.0, "bullet_zip")

# Bullet hitting world geometry — small click for tiny rounds, fatter thump
# the bigger the bullet. Cached per damage bucket × variant so a full-auto
# stream rotates through 5 distinct samples.
func impact(at: Vector3 = NO_POS, dmg_ratio: float = 1.0) -> void:
	var dmg_clamped: float = clampf(dmg_ratio, 0.5, 6.0)
	var dmg_bucket: int = int(round(dmg_clamped * 4.0))  # 0.25 increments
	var variant: int = randi() % IMPACT_VARIANTS
	var key := "impact:%d:%d" % [dmg_bucket, variant]
	var samples := _cached_samples(key, Callable(self, "_synth_impact").bind(dmg_clamped, variant))
	# Damage-driven loudness: small rounds stay clicky, big rounds boom on
	# the surface. Scaling matches the synth's internal body gain.
	var dmg_db: float = clampf(log(maxf(1.0, dmg_clamped)) / log(2.0) * 4.0, 0.0, 9.0)
	# Real bullet impact SPL ~85-100 dB depending on caliber. Scaled with
	# damage so heavy rounds duck more of the mix. dry=true, big_tail=false:
	# crisp tick that doesn't smear through reverb.
	var spl: float = 90.0 + dmg_db
	_play(samples, impact_db + dmg_db, at, "impact", 8.0, true, spl, false)

func casing_drop(at: Vector3 = NO_POS, pitch_scale: float = 1.0, volume_offset_db: float = 0.0) -> void:
	# Brass shell ping — short, bright, metallic. Pitch jitter per call gives
	# a pile of casings the variety it needs even with a small variant pool.
	# volume_offset_db lets the caller scale loudness with impact momentum
	# so the first hard hit is loud and subsequent bounces are softer.
	var variant: int = randi() % CASING_VARIANTS
	var key := "casing_drop:%d" % variant
	var wav := _cached_wav(key, Callable(self, "_synth_casing_drop").bind(variant))
	# ~75 dB SPL — quiet but cuts cleanly through ambient mix. Dry, no big tail.
	_play_stream(wav, casing_db + volume_offset_db, at, pitch_scale, "casing", 6.0, true, 75.0, false)

func explosion(at: Vector3 = NO_POS, radius: float = 6.0) -> void:
	# Layered: punchy transient bang + a deep brown-noise rumble that
	# decays longer for larger blasts. The rumble samples are bucketed
	# by radius so we don't synth a fresh one per call.
	# unit_size is the distance at which attenuation BEGINS — anything closer
	# plays at full volume_db. So we want it relatively small (a grenade at
	# 5 m and 30 m should sound very different) but scaled with radius so a
	# bazooka still carries far before falling off.
	# Bang and rumble use DIFFERENT unit_sizes so the body of the explosion
	# carries far further than the transient. Bang at radius*0.8 attenuates
	# normally with distance (sharp at close range, dimmer far away). Rumble
	# at radius*2.5 stays bass-heavy at distance — that's what gives a
	# bazooka 30 m out its weight instead of sounding "thin".
	var bang_dist: float = clampf(radius * 0.8, 4.0, 24.0)
	# Rumble carries far — bumped from 2.5x to 4.5x radius so a 30 m bazooka
	# bystander still gets the bass body at near-full volume.
	var rumble_dist: float = clampf(radius * 4.5, 20.0, 100.0)
	var r_bucket: int = int(round(clampf(radius, 2.0, 24.0)))
	var variant: int = randi() % EXPLOSION_VARIANTS
	var bang_key := "explosion_bang:%d:%d" % [r_bucket, variant]
	# Real explosion SPL is 165-180 dB at the source — scales with radius so
	# bigger blasts push the HDR window highest, ducking everything else
	# hardest.
	var ex_spl: float = 165.0 + log(maxf(1.0, radius / 6.0)) / log(2.0) * 5.0
	ProceduralMusic.duck(clampf(0.55 + radius * 0.025, 0.55, 0.95))
	# Bang plays dry primary (crisp transient) PLUS a wet companion through
	# RaytracedReverb — same pattern as gun shots. The wet companion is what
	# gives a sharp transient an audible reverb tail; without it the dry
	# bang bypasses the reverb bus entirely and the explosion sounds tail-less.
	# _cached_wav avoids a fresh AudioStreamWAV allocation per call. Bench
	# attributed ~1 ms / explosion of physics tick to the previous re-conversion.
	var bang_wav := _cached_wav(bang_key, Callable(self, "_synth_explosion").bind(float(r_bucket), variant))
	_play_stream(bang_wav, explosion_bang_db, at, 1.0, "explosion_bang", bang_dist, true, ex_spl)
	_play_stream(bang_wav, explosion_bang_db + explosion_wet_db, at, 1.0, "_explosion_bang", bang_dist, false, ex_spl)
	var rumble_key := "explosion_rumble:%d:%d" % [r_bucket, variant]
	var rumble_wav := _cached_wav(rumble_key, Callable(self, "_synth_explosion_rumble").bind(float(r_bucket), variant))
	_play_stream(rumble_wav, explosion_rumble_db, at, 1.0, "explosion_rumble", rumble_dist, false, ex_spl)
	# (The distance-bucketed bandpass click was removed — its high-Q resonator
	# rang at ~350 Hz at mid-range distances and read as a tonal "pong". The
	# air-absorption filter on the regular 3D player handles the distance
	# frequency shift more naturally via lowpass.)
func melee(at: Vector3 = NO_POS, damage: int = 50) -> void:
	var pitch_ratio: float = clampf(50.0 / float(damage), 0.5, 1.2)
	var key := "melee_%d" % int(round(pitch_ratio * 100.0))
	_play(_cached_samples(key, Callable(self, "_synth_melee").bind(pitch_ratio)), -6.0, at, "melee", -1.0, false, 90.0)
func jump(at: Vector3 = NO_POS) -> void:
	# Jump = a thick "oof" built from two step samples layered an octave apart.
	# Significantly louder than a footstep (~20 dB over) so the takeoff reads.
	if _step_sounds.is_empty():
		return
	_play_stream(_step_sounds.pick_random(), jump_db + randf_range(-1.5, 1.5), at, randf_range(1.02, 1.12), "jump", -1.0, false, 75.0)
	_play_stream(_step_sounds.pick_random(), jump_db - 3.0 + randf_range(-1.5, 1.5), at, randf_range(0.55, 0.65), "jump_low", -1.0, false, 75.0)
func landing(impact_vel: float, at: Vector3 = NO_POS) -> void:
	# Landing thump: scaled by impact velocity. Tiny drops (<~2 m/s, e.g. a
	# 5 cm step-off) are silent; jump-land is moderate; big falls slam.
	if _step_sounds.is_empty():
		return
	if impact_vel < 2.0:
		return
	var t: float = clampf((impact_vel - 2.0) / 23.0, 0.0, 1.0)
	var vol: float = lerpf(-22.0, landing_max_db, t)
	var pitch: float = lerpf(1.05, 0.55, t)
	# SPL 75 (light land) → 95 (slam) so big drops carry through other sounds.
	var spl: float = lerpf(75.0, 95.0, t)
	_play_stream(_step_sounds.pick_random(), vol, at, pitch, "landing", -1.0, false, spl)
	# Sub-octave layer for extra thud on hard landings only.
	if t > 0.25:
		_play_stream(_step_sounds.pick_random(), vol - 4.0, at, pitch * 0.5, "landing_low", -1.0, false, spl)
func footstep(at: Vector3 = NO_POS, size: float = 1.0) -> void:
	# `size` is the player's effective body size (1.0 = default). Bigger
	# bodies thump deeper and louder; smaller ones tap softer and higher.
	if _step_sounds.is_empty():
		return
	var s: float = clampf(size, 0.4, 3.0)
	# log2(size) shifts symmetrically: 2× size → −6 dB pitch + same dB louder.
	var size_db: float = clampf(log(s) / log(2.0) * 6.0, -6.0, 10.0)
	# Pitch: 1.0 at size 1, ~0.5 at size 2, ~1.4 at size 0.5.
	var size_pitch: float = clampf(1.0 / sqrt(s), 0.5, 1.6)
	# Footsteps mid priority — they should survive light combat (base
	# rifle SPL 105 with 35 dB window admits anything ≥ 70) but get culled
	# by upgraded weapons / explosions / hurts.
	_play_stream(
		_step_sounds.pick_random(),
		footstep_db + randf_range(-2.0, 2.0) + size_db,
		at,
		size_pitch * randf_range(0.92, 1.08),
		"footstep",
		-1.0,
		false,
		78.0,
	)
func dash(at: Vector3 = NO_POS) -> void:
	_play(_cached_samples("dash", Callable(self, "_synth_dash")), -24.0, at, "dash", -1.0, false, 75.0)
func hurt(at: Vector3 = NO_POS, is_self: bool = false) -> void:
	if _hurt_sounds.is_empty(): return
	if is_self:
		_play_stream(_hurt_sounds.pick_random(), hurt_self_db, NO_POS, 1.0, "hurt_self", -1.0, false, 100.0)
	else:
		_play_stream(_hurt_sounds.pick_random(), hurt_world_db + randf_range(-1.5, 1.5), at, 1.0, "hurt", -1.0, false, 80.0)
func death(at: Vector3 = NO_POS, is_self: bool = false) -> void:
	if _death_sounds.is_empty(): return
	if is_self:
		_play_stream(_death_sounds.pick_random(), death_self_db, NO_POS, 1.0, "death_self", -1.0, false, 110.0)
	else:
		_play_stream(_death_sounds.pick_random(), death_world_db + randf_range(-1.5, 1.5), at, 1.0, "death", -1.0, false, 85.0)
func lava_sizzle(at: Vector3 = NO_POS, fall_death: bool = false) -> void:
	var variant := randi() % 3
	var mode := "fall" if fall_death else "contact"
	var key := "lava_sizzle2:%s:%d" % [mode, variant]
	var wav := _cached_wav(key, Callable(self, "_synth_lava_sizzle").bind(variant, fall_death))
	var db := lava_fall_sizzle_db if fall_death else lava_sizzle_db - 5.0
	var reach := 72.0 if fall_death else 95.0
	_play_stream(wav, db + randf_range(-1.0, 1.0), at, randf_range(0.96, 1.04), "lava_sizzle", 18.0, false, reach, false)
func rocket_descent() -> Node:
	# Heavy, soft-distorted rumble for the round-start rocket spawn. 2D so
	# the local player hears their own "cabin" loud regardless of where the
	# fall is happening in world space.
	return _play(_cached_samples("rocket_descent", Callable(self, "_synth_rocket_descent")), rocket_descent_db, NO_POS, "rocket_descent", -1.0, false, 130.0)


func attach_air_strike_inbound(parent: Node3D, travel_seconds: float, distant: bool = false) -> AudioStreamPlayer3D:
	if parent == null:
		return null
	var dur_bucket: float = snappedf(clampf(travel_seconds, 1.75, 6.5), 0.25)
	var key := "air_strike_inbound:%0.2f:%d" % [dur_bucket, 1 if distant else 0]
	var wav := _cached_wav(key, Callable(self, "_synth_air_strike_inbound").bind(dur_bucket, distant))
	var p: AudioStreamPlayer3D = RaytracedAudioPlayer3D.new()
	_configure_3d_player(p)
	p.unit_size = 88.0 if distant else 58.0
	p.stream = wav
	p.volume_db = air_strike_inbound_distant_db if distant else air_strike_inbound_db
	parent.add_child(p)
	p.play()
	var tail_db: float = (air_strike_inbound_distant_db if distant else air_strike_inbound_db) + big_tail_send_db + (-2.0 if distant else 0.0)
	_big_tail_intensity = maxf(_big_tail_intensity, 0.28 if distant else 0.42)
	_spawn_big_tail_send(wav, tail_db, parent.global_position, 1.0, "air_strike_inbound")
	return p


# `world_pos` is where the charge should sound from — pass the ground-level
# strike target. The visual column root it's parented to sits ~1km up in the
# sky (SKY_HEIGHT), and a RaytracedAudioPlayer3D that far from the listener is
# culled past its auto max_distance → dead silent. Parenting keeps lifetime
# tied to the column; the explicit position keeps it audible at ground level.
func attach_ion_cannon_charge(parent: Node3D, charge_seconds: float, world_pos: Vector3 = NO_POS) -> AudioStreamPlayer3D:
	if parent == null:
		return null
	var dur_bucket: float = snappedf(clampf(charge_seconds, 2.5, 6.5), 0.1)
	var key := "ion_cannon_charge:%0.2f" % dur_bucket
	var wav := _cached_wav(key, Callable(self, "_synth_ion_cannon_charge").bind(dur_bucket))
	var p: AudioStreamPlayer3D = RaytracedAudioPlayer3D.new()
	_configure_3d_player(p)
	p.unit_size = 140.0
	p.stream = wav
	p.volume_db = ion_cannon_charge_db
	parent.add_child(p)
	if world_pos != NO_POS:
		p.global_position = world_pos
	p.play()
	var pos: Vector3 = world_pos if world_pos != NO_POS else parent.global_position
	var tail_db: float = ion_cannon_charge_db + big_tail_send_db + 10.0
	_big_tail_intensity = maxf(_big_tail_intensity, 0.52)
	_spawn_big_tail_send(wav, tail_db, pos, 1.0, "ion_cannon_charge")
	_play_stream(wav, ion_cannon_charge_db + explosion_wet_db + 6.0, pos, 1.0, "_ion_cannon_charge", 140.0, false, 118.0)
	return p


func ion_cannon_detonate(at: Vector3 = NO_POS, radius: float = 38.0) -> void:
	# Base boom + a custom phased-square zap layered on top.
	var r_bucket: int = int(round(clampf(radius, 8.0, 48.0)))
	var variant: int = randi() % 3
	explosion(at, radius)
	var burst_key := "ion_cannon_burst:%d:%d" % [r_bucket, variant]
	var burst_wav := _cached_wav(burst_key, Callable(self, "_synth_ion_cannon_burst").bind(float(r_bucket), variant))
	var ex_spl: float = 168.0 + log(maxf(1.0, radius / 6.0)) / log(2.0) * 4.0
	var burst_dist: float = clampf(radius * 1.6, 16.0, 72.0)
	_big_tail_intensity = maxf(_big_tail_intensity, 0.62)
	_play_stream(burst_wav, ion_cannon_burst_db, at, 1.0, "ion_cannon_burst", burst_dist, false, ex_spl)
	_play_stream(burst_wav, ion_cannon_burst_db + explosion_wet_db + 4.0, at, 1.0, "_ion_cannon_burst", burst_dist, false, ex_spl)
	_spawn_big_tail_send(burst_wav, ion_cannon_burst_db + big_tail_send_db + 6.0, at, 1.0, "ion_cannon_burst")


func mine_plant(at: Vector3 = NO_POS) -> void:
	# Subtle "click + arm beep" as a player drops a proximity mine. 3D so
	# nearby players hear it positioned and can hunt the planter down.
	_play(_cached_samples("mine_plant", Callable(self, "_synth_mine_plant")), mine_plant_db, at, "mine_plant", -1.0, false, 90.0)


func hit_received(intensity: float = 1.0) -> void:
	# Critical UI feedback — high SPL so it always plays through combat noise.
	# Intensity scales perceived volume: a 1-damage poison tick should barely
	# whisper while a 50-damage shotgun hit should hit hard. linear_to_db
	# converts the linear scale (1.0 == base db, 0.1 == -20dB quieter, 2.0 ==
	# +6dB louder).
	var db: float = hit_received_db + linear_to_db(clampf(intensity, 0.05, 2.0))
	_play(_cached_samples("hit_received", Callable(self, "_synth_hit_received")), db, NO_POS, "hit_received", -1.0, false, 130.0)
func kill_confirm() -> void:
	# Critical UI feedback — same priority tier as hit_received.
	_play(_cached_samples("kill_confirm", Callable(self, "_synth_kill_confirm")), -6.0, NO_POS, "kill_confirm", -1.0, false, 130.0)

func pick_countdown_beep(seconds_left: int) -> void:
	# Short rising-pitch warning that the card pick is about to time out.
	# seconds_left = 3 → base pitch; 2 → +1 semitone; 1 → +2 semitones.
	var step: int = clampi(3 - seconds_left, 0, 2)
	var key := "pick_beep_%d" % step
	_play(_cached_samples(key, Callable(self, "_synth_pick_beep").bind(step)), -8.0, NO_POS, "pick_beep", -1.0, false, 140.0)
func pling(pitch_ratio: float = 1.0) -> void:
	var key := "pling_%d" % int(round(pitch_ratio * 100.0))
	_play(_cached_samples(key, Callable(self, "_synth_pling").bind(pitch_ratio)), -10.0, NO_POS, "pling", -1.0, false, 70.0)

func pickup_drop(at: Vector3 = NO_POS) -> void:
	_play(_cached_samples("pickup_drop", Callable(self, "_synth_pickup_drop")), -11.0, at, "pickup_drop", -1.0, false, 75.0)

func enemy_incoming(at: Vector3 = NO_POS) -> void:
	_play(_cached_samples("enemy_incoming", Callable(self, "_synth_enemy_incoming")), -8.5, at, "enemy_incoming", -1.0, false, 95.0)

func card_flip(_pitch_ratio: float = 1.0) -> void:
	# pitch_ratio kept for callsite compatibility but no longer used —
	# variation comes from the 3 deterministic synthesised variants instead.
	var variant := _next_card_flip_variant()
	var key := "card_flip:%d" % variant
	_play(_cached_samples(key, Callable(self, "_synth_card_flip").bind(variant)), -10.0, NO_POS, "card_flip", -1.0, false, 60.0)

func _next_card_flip_variant() -> int:
	if _card_flip_idx >= _card_flip_order.size():
		var ids: Array[int] = []
		for i in CARD_FLIP_VARIANTS:
			ids.append(i)
		ids.shuffle()
		_card_flip_order = ids
		_card_flip_idx = 0
	var v := _card_flip_order[_card_flip_idx]
	_card_flip_idx += 1
	return v
func reload(duration: float, at: Vector3 = NO_POS) -> Node:
	# Continuous rattle for the full reload duration. Returns the player node
	# so the caller can stop it early (e.g. on respawn / round end).
	# Cached per 0.05 s: synthesising the rattle took ~20 ms on every reload.
	var bucket := snappedf(clampf(duration, 0.2, 6.0), 0.05)
	return _play(_cached_samples("reload:%0.2f" % bucket, Callable(self, "_synth_reload").bind(bucket)), -14.0, at, "reload", -1.0, false, 70.0)

func hitmarker(kind: String = "body", dmg: int = 0) -> void:
	# Scale pitch down and volume up with damage — heavy guns land with a
	# bassy thunk, baseline pistol keeps the sharp "tink".
	var dmg_ratio: float = 1.0
	if dmg > 0:
		dmg_ratio = clampf(float(dmg) / Weapon.BASE_DAMAGE, 0.5, 5.0)
	var vol_bonus: float = clampf(log(dmg_ratio) / log(2.0) * 2.0, 0.0, 4.0)
	# Critical UI feedback — high SPL so the hitmarker always plays through
	# combat noise (you need to know you landed a hit even mid-explosion).
	_play(_cached_samples(_hitmarker_cache_key(kind, dmg), Callable(self, "_synth_hitmarker").bind(kind, dmg_ratio)), -5.0 + vol_bonus, NO_POS, "hitmarker_" + kind, -1.0, false, 130.0)

# -------------------- synthesis --------------------

func _synth_shot(w: Weapon, variant: int) -> PackedVector2Array:
	# Layered like the explosion bang: thwack (broadband impulse, the muzzle
	# blast attack) + bass thump + lowpass-swept noise tail + brief crack
	# (lowpass-filtered noise impulse) for accurate rifles. Per-variant RNG
	# seeding gives 5 distinct samples per weapon config — caches share
	# (damage, spread, fire) bucket but variant differentiates them.
	var dmg_ratio := 1.0
	var accuracy := 1.0  # 1.0 = perfectly accurate, 0.0 = fully sprayed
	var velocity := 1.0  # 1.0 = baseline; >1 = high-velocity (sharper)
	if w:
		dmg_ratio = maxf(1.0, w.get_damage() / Weapon.BASE_DAMAGE)
		accuracy = clampf(1.0 - w.spread / 0.06, 0.0, 1.0)
		velocity = clampf(w.bullet_speed_mult, 0.5, 3.0)

	var rng := RandomNumberGenerator.new()
	rng.seed = hash([dmg_ratio, accuracy, velocity, variant, "shot"])

	# Per-variant param jitter (deterministic per variant for stable cache).
	var bright_jit: float = lerpf(0.85, 1.15, rng.randf())
	var click_freq_jit: float = lerpf(0.80, 1.25, rng.randf())
	# High-velocity weapons have a sharper transient — faster thwack decay
	# (sonic crack), more harmonic drive, less low-end body. Mimics how a
	# real sniper rifle reads as a "snap" vs a slow rifle's "boom".
	var thwack_decay: float = lerpf(180.0, 280.0, rng.randf()) * sqrt(velocity)
	var thwack_drive: float = lerpf(4.0, 8.0, rng.randf()) * lerpf(0.9, 1.3, clampf((velocity - 1.0) / 2.0, 0.0, 1.0))
	var dur_jit: float = lerpf(0.90, 1.12, rng.randf())

	# Kick-drum bass: sine with rapid pitch sweep from f0 (click pitch) down
	# to f1 (body pitch) over ~12 ms. f1 scales with damage so big guns thump
	# lower. f0 stays in the click range regardless. Lowpassed to smooth the
	# sweep into a punchy "boom" instead of a chirp.
	var kick_f0: float = 220.0 * lerpf(0.88, 1.12, rng.randf())
	var kick_f1: float = clampf(55.0 / sqrt(dmg_ratio), 28.0, 80.0) * lerpf(0.92, 1.10, rng.randf())
	# Kick body is DAMAGE-driven only — velocity governs the transient/noise
	# crispness, but the deep kick should grow with damage regardless of
	# velocity. Sniper still gets a proper boom; SMG stays light.
	var kick_sweep_rate: float = lerpf(70.0, 95.0, rng.randf())
	var kick_decay: float = clampf(35.0 / sqrt(dmg_ratio), 10.0, 40.0)
	var kick_gain: float = lerpf(0.55, 1.10, clampf((dmg_ratio - 1.0) / 3.0, 0.0, 1.0))

	# High-velocity guns are SHORTER overall — the entire bang collapses.
	# Slow guns: full duration. Sniper at velocity ~3: dur cut to ~half.
	var dur: float = clampf((0.08 + 0.08 * log(dmg_ratio) / log(2.0)) * dur_jit / sqrt(velocity), 0.04, 0.35)
	var n := int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)

	var noise_brightness: float = clampf(lerpf(0.18, 0.55, accuracy) * bright_jit, 0.05, 0.95)
	# Dedicated noise-tail decay so the lowpass-swept noise dies fast for
	# high-velocity weapons (sharp crack, no lingering hiss). Slow guns
	# keep a longer noise wash.
	var noise_decay: float = lerpf(8.0, 16.0, rng.randf()) * sqrt(velocity)
	var click_gain := accuracy * 0.3
	var click_freq := 2400.0 * click_freq_jit

	var lp := 0.0
	var thwack_low_acc := 0.0
	var kick_phase: float = 0.0
	var kick_lp: float = 0.0
	# Damage-scaled high-pass on the final mix — low-damage rifles were
	# coming out muddy because the kick + thwack body sat too low for their
	# energy. Curve drops fast: base rifles get cleared up to ~220 Hz,
	# bazooka-class weapons (dmg>4) keep nearly the full subharmonic since
	# cutoff drops below the kick fundamental. Implemented as 1-pole IIR
	# lowpass subtracted from the sample.
	var hp_cutoff: float = clampf(220.0 / pow(dmg_ratio, 1.4), 25.0, 220.0)
	var hp_k: float = clampf(TAU * hp_cutoff / MIX_RATE, 0.005, 0.5)
	var bass_acc: float = 0.0
	for i in range(n):
		var t := float(i) / MIX_RATE
		var env := pow(clampf(1.0 - t / dur, 0.0, 1.0), 1.6)
		var noise := rng.randf_range(-1.0, 1.0)
		# WIDE distorted transient — broadband impulse, sub-bass roll-off,
		# tanh-saturated for harmonic crack character.
		var raw_thwack := rng.randf_range(-1.0, 1.0)
		thwack_low_acc = lerpf(thwack_low_acc, raw_thwack, 0.06)
		var hp := raw_thwack - thwack_low_acc
		var thwack := tanh(hp * thwack_drive) * 1.5 * exp(-t * thwack_decay)
		# Kick: phase-accumulated swept sine. Phase integration handles the
		# time-varying frequency correctly (a plain sin(2πft) would mis-track
		# the sweep).
		var kick_freq: float = kick_f1 + (kick_f0 - kick_f1) * exp(-t * kick_sweep_rate)
		kick_phase += 2.0 * PI * kick_freq / float(MIX_RATE)
		var kick_raw: float = sin(kick_phase)
		# Lowpass smooths the sweep edges so it reads as a thump, not a chirp.
		kick_lp = lerpf(kick_lp, kick_raw, 0.30)
		var kick: float = kick_lp * exp(-t * kick_decay)
		# Lowpass-swept noise tail with its own fast envelope (scales with
		# velocity → sniper has very short tail, slow gun has longer wash).
		lp = lerpf(lp, noise, noise_brightness)
		var lp_env: float = exp(-t * noise_decay)
		var click := sin(2.0 * PI * click_freq * t) * exp(-t * 280.0) * click_gain
		var s := tanh((thwack + lp * 0.5 * lp_env + kick * kick_gain + click) * env * 1.4)
		# Damage-scaled high-pass: subtract the slow-moving bass average.
		bass_acc = lerpf(bass_acc, s, hp_k)
		s -= bass_acc
		out[i] = Vector2(s, s)
	return out

func _synth_grenade_launch(variant: int = 0) -> PackedVector2Array:
	# Grenade launcher "foomp": rising pressurized gas, a short breech tick,
	# then a steady 160 Hz tube/body resonance that eases smoothly to silence.
	var dur := 0.18
	var n := int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([variant, "grenade_launch_v3"])
	var pitch_offsets := [-5.0, -2.0, 0.0, 2.0, 4.0]
	var body_hz: float = 160.0 + pitch_offsets[clampi(variant, 0, pitch_offsets.size() - 1)]
	var noise_lp_hi := 0.0
	var noise_lp_lo := 0.0
	var tick_lp_lo := 0.0
	var body_phase := 0.0
	for i in range(n):
		var t: float = float(i) / MIX_RATE

		# Gas layer: white noise band sweeps upward over the first ~65 ms.
		var sweep_phase: float = clampf(t / 0.065, 0.0, 1.0)
		var sweep_t: float = sweep_phase * sweep_phase * (3.0 - 2.0 * sweep_phase)
		var center_hz: float = lerpf(650.0, 4300.0, sweep_t)
		var lp_hi_k: float = clampf(center_hz * TAU * 1.8 / MIX_RATE, 0.04, 0.92)
		var lp_lo_k: float = clampf(center_hz * TAU * 0.35 / MIX_RATE, 0.004, 0.45)
		var gas_env: float = sin(sweep_phase * PI) * exp(-maxf(0.0, t - 0.06) * 55.0)
		var noise: float = rng.randf_range(-1.0, 1.0)
		noise_lp_hi = lerpf(noise_lp_hi, noise, lp_hi_k)
		noise_lp_lo = lerpf(noise_lp_lo, noise_lp_hi, lp_lo_k)
		var gas: float = (noise_lp_hi - noise_lp_lo) * gas_env * 0.55

		# Mechanical tick: a tiny high-passed snap after pressure builds.
		var tick_t: float = t - 0.038
		var tick_env: float = exp(-tick_t * 420.0) if tick_t >= 0.0 else 0.0
		var tick_noise: float = rng.randf_range(-1.0, 1.0) * tick_env
		tick_lp_lo = lerpf(tick_lp_lo, tick_noise, 0.035)
		var tick: float = (tick_noise - tick_lp_lo) * 0.75

		# Launcher tube/body resonance. Fixed pitch; harmonics are almost
		# absent, just enough to keep the sine from feeling synthetic.
		var body_t: float = maxf(0.0, t - 0.026)
		var body_phase_norm: float = clampf(body_t / maxf(0.001, dur - 0.026), 0.0, 1.0)
		var body_attack: float = clampf(body_t / 0.012, 0.0, 1.0)
		body_attack = body_attack * body_attack * (3.0 - 2.0 * body_attack)
		var body_release: float = 1.0 - body_phase_norm
		body_release = body_release * body_release * (3.0 - 2.0 * body_release)
		var body_env: float = body_attack * body_release
		body_phase += TAU * body_hz / MIX_RATE
		var body: float = (
			sin(body_phase) * 0.86
			+ sin(body_phase * 2.0) * 0.018
			+ sin(body_phase * 3.0) * 0.006
		) * body_env

		# A small sub push gives the launch mass without turning it into an
		# explosion; it decays with the body resonance.
		var sub: float = sin(body_phase * 0.5) * body_env * 0.06
		var s: float = tanh((gas + tick + body + sub) * 1.35) * 0.72
		out[i] = Vector2(s, s)
	return out

func _synth_next_round() -> PackedVector2Array:
	# Real bolt cycling = two broadband metallic clicks ~20 ms apart:
	# (1) bolt unlocks + retracts, (2) bolt returns to battery / locks.
	# Both are pure noise bandpass-filtered to the 2-6 kHz "metal" range —
	# real impacts are inharmonic so any sine content reads as "bell".
	var dur := 0.07
	var n := int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)
	var lp_low := 0.0   # accumulator for highpass (subtract slow LP from input)
	var lp_high := 0.0  # accumulator for the bandpass lowpass stage
	var t_back := 0.0
	var t_fwd := 0.022  # second click 22 ms after the first
	for i in range(n):
		var t := float(i) / MIX_RATE
		var env_back: float = exp(-(t - t_back) * 260.0) if t >= t_back else 0.0
		var env_fwd: float = exp(-(t - t_fwd) * 200.0) * 0.75 if t >= t_fwd else 0.0
		var noise: float = randf_range(-1.0, 1.0)
		var burst: float = noise * (env_back + env_fwd)
		# Bandpass via cascaded 1-pole filters:
		#   lp_low ≈ ~280 Hz LP -> subtract from burst -> highpass result
		#   lp_high ≈ ~3.4 kHz LP applied to the highpassed signal
		lp_low = lerpf(lp_low, burst, 0.04)
		var hp: float = burst - lp_low
		lp_high = lerpf(lp_high, hp, 0.48)
		var s: float = lp_high * 0.85
		out[i] = Vector2(s, s)
	return out

func _synth_empty_chamber() -> PackedVector2Array:
	# Single short bandpass noise burst — the firing pin clicking on an empty
	# chamber. No second cycle (nothing was chambered), no ring.
	var dur := 0.025
	var n := int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)
	var lp_low := 0.0
	var lp_high := 0.0
	for i in range(n):
		var t := float(i) / MIX_RATE
		var env := exp(-t * 280.0)
		var burst := randf_range(-1.0, 1.0) * env
		lp_low = lerpf(lp_low, burst, 0.04)
		var hp := burst - lp_low
		lp_high = lerpf(lp_high, hp, 0.42)
		var s: float = lp_high * 0.9
		out[i] = Vector2(s, s)
	return out

func _synth_explosion(radius: float, variant: int) -> PackedVector2Array:
	# Same layered architecture as `_synth_shot` (thick, saturated, percussive)
	# but scaled to explosion proportions: longer duration, lower kick body,
	# slower envelope. Layers: thwack + LP-swept noise tail + kick drum +
	# lowpassed sub-noise rumble; final tanh wrap drives everything into
	# global saturation.
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([radius, variant, "bang"])

	# Per-variant param jitter.
	var bright_jit: float = lerpf(0.85, 1.15, rng.randf())
	var thwack_decay: float = lerpf(180.0, 280.0, rng.randf())
	var thwack_drive: float = lerpf(4.0, 8.0, rng.randf())
	var dur_jit: float = lerpf(0.92, 1.10, rng.randf())

	# Kick drum — match gun's kick parameters exactly (just driven by radius
	# instead of damage). Earlier the explosion kick was clamped higher
	# (50 Hz min) and slower-decaying, which made it read as a tonal "pong".
	# Now: deep floor (28 Hz), fast snap (10-40 ms), gun-equivalent gain.
	var r_norm: float = clampf(radius / 6.0, 0.3, 4.0)
	var kick_f0: float = 220.0 * lerpf(0.88, 1.12, rng.randf())
	var kick_f1: float = clampf(55.0 / sqrt(r_norm), 28.0, 80.0) * lerpf(0.92, 1.10, rng.randf())
	var kick_sweep_rate: float = lerpf(70.0, 95.0, rng.randf())
	var kick_decay: float = clampf(35.0 / sqrt(r_norm), 10.0, 40.0)
	var kick_gain: float = lerpf(0.55, 0.95, clampf((r_norm - 1.0) / 3.0, 0.0, 1.0))

	# Sub-bass rumble: heavily lowpassed noise (~35-65 Hz) for inharmonic
	# body. Bigger blasts get lower cutoffs and slower decay → fatter rumble.
	var sub_cutoff_k: float = lerpf(0.005, 0.010, rng.randf())
	var sub_decay: float = clampf(3.5 / sqrt(r_norm), 1.2, 4.0)

	# Duration scales with radius — bigger = longer body.
	var dur: float = clampf((0.4 + radius * 0.08) * dur_jit, 0.4, 1.6)
	var n := int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)

	var thwack_cutoff_k: float = lerpf(0.10, 0.16, rng.randf())
	var noise_brightness: float = clampf(0.45 * bright_jit, 0.05, 0.95)
	# Noise-tail decay 8-15 → ~70-125 ms. Without this the LP-swept noise
	# rides the full envelope (up to 1.6 s) and reads as a long hiss sweep.
	var noise_decay: float = lerpf(8.0, 15.0, rng.randf())

	var lp := 0.0
	var thwack_lp := 0.0
	var sub_lp := 0.0
	var kick_phase: float = 0.0
	var kick_lp: float = 0.0
	for i in range(n):
		var t := float(i) / MIX_RATE
		# Slower decay than gun (gun = pow(1-t/dur, 1.6) only). Explosion adds
		# an exp tail on top so the body sustains longer before the convex
		# fadeout takes over.
		var env := exp(-t * 1.4) * pow(1.0 - t / dur, 0.6)
		var noise := rng.randf_range(-1.0, 1.0)
		# WIDE distorted transient — broadband impulse, sub-bass roll-off,
		# tanh-saturated for harmonic crack.
		var raw_thwack := rng.randf_range(-1.0, 1.0)
		thwack_lp = lerpf(thwack_lp, raw_thwack, thwack_cutoff_k)
		var thwack := tanh(thwack_lp * thwack_drive) * 1.5 * exp(-t * thwack_decay)
		# Lowpass-swept noise tail with its own fast envelope so it dies
		# in ~80-125 ms instead of riding the full bang.
		lp = lerpf(lp, noise, noise_brightness)
		var lp_env: float = exp(-t * noise_decay)
		# Kick: phase-accumulated swept sine, lowpassed.
		var kick_freq: float = kick_f1 + (kick_f0 - kick_f1) * exp(-t * kick_sweep_rate)
		kick_phase += 2.0 * PI * kick_freq / float(MIX_RATE)
		kick_lp = lerpf(kick_lp, sin(kick_phase), 0.30)
		var kick: float = kick_lp * exp(-t * kick_decay)
		# Sub-bass rumble (inharmonic, fills out the body after the kick dies).
		sub_lp = lerpf(sub_lp, rng.randf_range(-1.0, 1.0), sub_cutoff_k)
		var sub: float = sub_lp * 3.5 * exp(-t * sub_decay)
		# Final mix wrapped in tanh — same trick as shot. Drives the layered
		# sum into saturation for a thick, dense character.
		var s := tanh((thwack + lp * 0.5 * lp_env + kick * kick_gain + sub * 0.7) * env * 1.4)
		out[i] = Vector2(s, s)
	return out

# Deep rumble layer that pairs with the transient explosion bang. Brown-noise
# generated by integrating white noise, then aggressively low-passed. Bigger
# radius → longer duration AND lower-frequency rumble.
func _synth_explosion_rumble(radius: float, variant: int) -> PackedVector2Array:
	# Quadratic length scaling: tiny pops stay tiny, big bazookas get the
	# full multi-second roar. Per-variant jitter on cutoff, attack, and
	# decay rate so 5 stacked rumbles aren't identical.
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([radius, variant, "rumble"])
	var r_norm: float = clampf(radius, 2.0, 24.0) / 24.0
	var dur: float = clampf(0.3 + r_norm * r_norm * 4.7, 0.3, 5.0)
	var n: int = int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)
	# Bigger blast = lower cutoff = deeper rumble. Per-variant ±15 Hz wobble.
	var cutoff_base: float = clampf(220.0 - radius * 7.0, 55.0, 200.0)
	var cutoff: float = cutoff_base + rng.randf_range(-15.0, 15.0)
	var lp_k: float = clampf(TAU * cutoff / MIX_RATE, 0.005, 0.4)
	var brown: float = 0.0
	var lp: float = 0.0
	# Variant jitter on attack + ease curve.
	var attack_dur: float = lerpf(0.05, 0.12, rng.randf())
	# Power-law ease-out across the whole tail. Higher = faster initial drop,
	# longer near-silent fade. ~2.6 gives the perceptual feel of "loud, then
	# softens continuously toward silence" without a plateau in the middle.
	var ease_power: float = lerpf(2.4, 3.0, rng.randf())
	# Per-sample gain. Bazooka-class blasts (large radius) have a longer +
	# deeper rumble whose total acoustic energy would otherwise drown the
	# bang. sqrt(6/radius) keeps small blasts at full level (radius=6 -> 1.5)
	# and trims big ones (radius=24 -> ~0.75).
	var gain: float = 1.5 * sqrt(6.0 / maxf(6.0, radius))
	var body_dur: float = maxf(dur - attack_dur, 0.0001)
	for i in range(n):
		var t: float = float(i) / MIX_RATE
		var attack: float = clampf(t / attack_dur, 0.0, 1.0)
		# Single monotone ease-out from 1.0 (right after the attack) down to
		# 0.0 at t = dur. Replaces the previous exp(-decay) * smoothstep_release
		# combo, which plateaued around 15 % of peak before finally fading and
		# read as "loud → middle → middle → silent".
		var decay_phase: float = clampf((t - attack_dur) / body_dur, 0.0, 1.0)
		var decay: float = pow(1.0 - decay_phase, ease_power)
		var env: float = attack * decay
		# Brown noise: integrated white noise with a tiny leak so it can't
		# drift into DC offset territory.
		brown = brown * 0.998 + rng.randf_range(-1.0, 1.0) * 0.03
		lp = lerpf(lp, brown, lp_k)
		var s: float = lp * env * gain
		# Soft-clip stray peaks so the integrator can't blow up the buffer.
		s = tanh(s)
		out[i] = Vector2(s, s)
	return out

func _synth_hit_received() -> PackedVector2Array:
	# Low thud: pitch drops from 160 → 70 Hz over the first 80 ms.
	var dur := 0.18
	var n := int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)
	for i in range(n):
		var t := float(i) / MIX_RATE
		var env := pow(1.0 - t / dur, 2.0)
		var pitch := lerpf(160.0, 70.0, clampf(t / 0.08, 0.0, 1.0))
		var tone := sin(2.0 * PI * pitch * t)
		var noise := randf_range(-1.0, 1.0) * exp(-t * 80.0)
		var s := (tone * 0.8 + noise * 0.4) * env * 0.75
		out[i] = Vector2(s, s)
	return out

func _synth_pick_beep(semitones_up: int) -> PackedVector2Array:
	# ~160ms sine blip with a snappy attack + exponential tail. Pitch climbs
	# one semitone per step so the picker hears the "1 second closer" cue.
	var dur := 0.16
	var n := int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)
	var freq := 440.0 * pow(2.0, float(semitones_up) / 12.0)
	for i in range(n):
		var t := float(i) / MIX_RATE
		var env := exp(-t * 14.0) * (1.0 - exp(-t * 200.0))
		var s := sin(2.0 * PI * freq * t) * env * 0.4
		out[i] = Vector2(s, s)
	return out


func _synth_kill_confirm() -> PackedVector2Array:
	# G4 + D5 perfect fifth, bell-like exponential decay.
	var dur := 0.28
	var n := int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)
	for i in range(n):
		var t := float(i) / MIX_RATE
		var env := exp(-t * 9.0)
		var tone := sin(2.0 * PI * 392.0 * t) * 0.45 + sin(2.0 * PI * 587.0 * t) * 0.3
		var s := tone * env * 0.5
		out[i] = Vector2(s, s)
	return out

func _synth_melee(pitch_ratio: float = 1.0) -> PackedVector2Array:
	# Hump-enveloped lowpass-swept noise — a short swoosh.
	var dur := 0.20
	var n := int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)
	var lp := 0.0
	for i in range(n):
		var t := float(i) / MIX_RATE
		var env := sin(PI * clampf(t / dur, 0.0, 1.0))
		var noise := randf_range(-1.0, 1.0)
		var cutoff_k := lerpf(0.7, 0.18, t / dur) * pitch_ratio
		lp = lerpf(lp, noise, clampf(cutoff_k, 0.01, 0.99))
		var s := lp * env * 0.45
		out[i] = Vector2(s, s)
	return out

func _synth_reload(duration: float) -> PackedVector2Array:
	# Two clusters of metallic clicks with silence between: mag-out clatter
	# at the start, then the magazine is in the air, then the mag slams home
	# + slide racks at the end. Each click = short bandpass-filtered noise
	# burst at a slightly randomized high pitch.
	var n := int(duration * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)
	for i in n:
		out[i] = Vector2.ZERO

	# Cluster boundaries as fractions of duration.
	var c1_start := 0.00
	var c1_end := 0.12 # Faster start
	var c2_start := 0.88 # Later end
	var c2_end := 0.98
	# Mag-out: starts HIGH (release catch / latch) then trails lower as the
	# mag drops down the well. Mag-in is the mirror: starts lower (mag seats)
	# and climbs to HIGH (slide racking at the top of the receiver).
	_reload_cluster(out, duration * c1_start, duration * c1_end, 2.2, 0.4)
	_reload_cluster(out, duration * c2_start, duration * c2_end, 0.4, 2.0)

	# Soft-clip the whole buffer to avoid overlapping-tap clipping.
	for i in n:
		var s: Vector2 = out[i]
		out[i] = Vector2(tanh(s.x), tanh(s.y))
	return out

func _reload_cluster(out: PackedVector2Array, t_start: float, t_end: float, pitch_begin: float, pitch_end: float) -> void:
	# Each cluster progresses from pitch_begin to pitch_end — the iron tapping
	# its way up or down the weapon. A little jitter per tap keeps it organic.
	var span := maxf(t_end - t_start, 0.02)
	var num_taps := randi_range(6, 10) # More taps
	for tap_i in num_taps:
		# Staggered with jitter so clicks don't land on a metronome.
		var frac := (float(tap_i) + randf_range(-0.15, 0.15)) / float(num_taps)
		frac = clampf(frac, 0.0, 1.0)
		var t_tap := t_start + span * frac
		var pitch_ratio := lerpf(pitch_begin, pitch_end, frac) * randf_range(0.95, 1.05)
		var amp := randf_range(0.3, 0.5) # Softer taps
		_reload_tap(out, t_tap, pitch_ratio, amp)

func _reload_tap(out: PackedVector2Array, start_time: float, pitch_ratio: float, amp: float) -> void:
	var tap_dur := 0.025 # Sharper
	var start_idx := int(start_time * MIX_RATE)
	if start_idx < 0:
		start_idx = 0
	if start_idx >= out.size():
		return
	var tap_n := int(tap_dur * MIX_RATE)
	var center := 1700.0 * pitch_ratio
	var fc_hi := center * 1.5
	var fc_lo := maxf(40.0, center * 0.6)
	var k_hi := 1.0 - exp(-TAU * fc_hi / MIX_RATE)
	var k_lo := 1.0 - exp(-TAU * fc_lo / MIX_RATE)

	var lp_hi := 0.0
	var lp_lo := 0.0
	for i in range(tap_n):
		var idx := start_idx + i
		if idx >= out.size(): break
		var t := float(i) / MIX_RATE
		var env := exp(-t * 280.0) # Faster decay, less plucky
		var noise := randf_range(-1.0, 1.0)
		lp_hi += k_hi * (noise - lp_hi)
		lp_lo += k_lo * (noise - lp_lo)
		var s: float = (lp_hi - lp_lo) * env * amp
		var existing: Vector2 = out[idx]
		out[idx] = Vector2(existing.x + s, existing.y + s)

func _synth_bullet_zip(speed_factor: float, scale_factor: float) -> PackedVector2Array:
	# Per-call jitter so consecutive zips never sound identical.
	var pitch_jit: float = randf_range(0.92, 1.08)
	var dur_jit: float = randf_range(0.85, 1.18)
	var bright_jit: float = randf_range(0.85, 1.15)
	# Pitch = base + speed_coef * speed_factor, both tunable via the F2 panel.
	# Capped at 6 kHz so it stays in the speaker sweet spot — going higher
	# (8-12 kHz) ends up perceptually thin / inaudible on most listening setups.
	var nominal: float = clampf(bullet_zip_base_hz + bullet_zip_speed_hz * speed_factor, 300.0, 6000.0) * pitch_jit
	# Doppler ratio derived from real v/c (c≈343 m/s): approach freq is
	# nominal*c/(c-v), recede is nominal*c/(c+v). Slow rounds get a mild glide;
	# transonic rounds get a dramatic one; supersonic is capped so the formula
	# doesn't explode. base_high capped at 7 kHz to keep the sweep audible.
	var v_bullet: float = clampf(speed_factor * 165.0, 10.0, 280.0)
	var c_sound: float = 343.0
	var base_high: float = minf(nominal * c_sound / (c_sound - v_bullet), 7000.0)
	var base_low: float = nominal * c_sound / (c_sound + v_bullet)
	# Duration: slow grenade ~250 ms whoosh, default round ~120 ms, sniper
	# ~80 ms (long enough for the doppler glide and tanh saturation to be
	# perceptible — was 20 ms which read as a click).
	var dur: float = clampf(0.06 + 0.06 / speed_factor, 0.07, 0.40) * dur_jit
	var n: int = int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)
	# Attack fraction also shrinks with speed: slow whoosh swells in slowly
	# (sin-like), hypersonic crack hits instantly with exp-decay tail.
	var attack_frac: float = clampf(0.45 / speed_factor, 0.04, 0.5)
	# Soft saturation that engages above ~Mach 0.9. Below sf=3, drive≈1 (clean
	# tanh, near-linear). At sf=5 hypersonic, drive=3.5 — peaks soft-clip into a
	# crackly ballistic edge. tanh is symmetric and has no harsh corners, so it
	# adds harmonics without sounding like digital clipping.
	var drive_amount: float = clampf((speed_factor - 3.0) / 2.0, 0.0, 1.0)
	var drive: float = lerpf(1.0, 3.5, drive_amount)
	var lp_hi := 0.0
	var lp_lo := 0.0
	for i in range(n):
		var t := float(i) / MIX_RATE
		var phase: float = clampf(t / dur, 0.0, 1.0)
		# Smootherstep sweep — flat on the ends, steep through the middle, so
		# the fastest pitch slide lines up with the closest-pass moment.
		var sweep_t: float = phase * phase * phase * (phase * (phase * 6.0 - 15.0) + 10.0)
		var center: float = lerpf(base_high, base_low, sweep_t) * bright_jit
		# 2-octave bandpass with geometric center == `center`. The 1-pole IIR
		# cutoff is f_c ≈ k * MIX_RATE / (2π), so multiplying by 2π puts the
		# band edges in real Hz: lp_hi at 2×center, lp_lo at 0.5×center.
		var lp_k: float = clampf(center * (TAU * 2.0) / MIX_RATE, 0.04, 0.98)
		var hp_k: float = clampf(center * (TAU * 0.5) / MIX_RATE, 0.003, 0.6)
		var env: float
		if phase < attack_frac:
			env = phase / attack_frac
		else:
			var d: float = (phase - attack_frac) / max(1.0 - attack_frac, 0.0001)
			env = exp(-d * 4.0)
		var noise: float = randf_range(-1.0, 1.0)
		lp_hi = lerpf(lp_hi, noise, lp_k)
		lp_lo = lerpf(lp_lo, lp_hi, hp_k)
		var bp: float = lp_hi - lp_lo
		var s: float = bp * env * 0.55 * scale_factor
		s = tanh(s * drive)
		out[i] = Vector2(s, s)
	return out

# Bullet-on-surface tick. Two layers: a high-passed noise click for the snap
# and a low-frequency sine thump that scales with damage. Per-variant RNG
# seeding gives 5 distinct samples per damage bucket, all stable across calls.
func _synth_impact(dmg_ratio: float, variant: int) -> PackedVector2Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([dmg_ratio, variant, "impact"])
	# Click pitch jitters per variant — feels random without recomputing.
	var click_freq: float = lerpf(2200.0, 4500.0, rng.randf())
	var click_decay: float = lerpf(180.0, 320.0, rng.randf())
	# Body thump only emerges above base damage. f0 starts mid-low and sweeps
	# down — like a tiny kick drum. dmg_norm is 0 at base damage, 1 at 5×.
	var dmg_norm: float = clampf((dmg_ratio - 1.0) / 4.0, 0.0, 1.0)
	var thump_f0: float = lerpf(160.0, 260.0, rng.randf())
	var thump_f1: float = lerpf(45.0, 80.0, rng.randf()) * lerpf(1.0, 0.7, dmg_norm)
	var thump_sweep: float = lerpf(60.0, 100.0, rng.randf())
	var thump_decay: float = lerpf(28.0, 42.0, rng.randf())
	var thump_gain: float = lerpf(0.0, 0.65, dmg_norm)
	# Heavier rounds tick longer (more body). Range 30 ms (light) to 80 ms (5×).
	var dur: float = lerpf(0.030, 0.080, dmg_norm) * lerpf(0.92, 1.10, rng.randf())
	var n: int = int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)
	# 1-pole highpass for the click — keeps it crisp by subtracting a slow
	# moving lowpass average from the noise.
	var lp_acc: float = 0.0
	var thump_phase: float = 0.0
	for i in range(n):
		var t: float = float(i) / MIX_RATE
		var noise: float = rng.randf_range(-1.0, 1.0)
		# Highpass click: noise minus its own slow average. Cutoff scales with
		# click_freq so different variants sit at different brightnesses.
		var hp_k: float = clampf(click_freq * (TAU * 0.4) / MIX_RATE, 0.05, 0.6)
		lp_acc = lerpf(lp_acc, noise, hp_k)
		var click: float = (noise - lp_acc) * exp(-t * click_decay)
		# Swept-sine thump for damage body — fades to nothing for base damage.
		var thump_freq: float = thump_f1 + (thump_f0 - thump_f1) * exp(-t * thump_sweep)
		thump_phase += TAU * thump_freq / float(MIX_RATE)
		var thump: float = sin(thump_phase) * exp(-t * thump_decay) * thump_gain
		var s: float = tanh((click + thump) * 1.4)
		out[i] = Vector2(s, s)
	return out

func _synth_casing_drop(variant: int) -> PackedVector2Array:
	# Brass shell on hard surface. Two sines:
	#   • Lower (~2 kHz), fast decay — the "body" of the impact
	#   • Higher (~10 kHz), slow decay — the metallic "ring" tail
	# Starting both at phase 0 produces a sample-instant attack which is
	# already as sharp as a click without needing a separate noise burst.
	# Variant ranges are tight so the pool sounds like one shell on one
	# surface; per-call pitch_scale in casing_drop() supplies micro-variation.
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([variant, "casing"])
	var dur: float = 0.18
	var n: int = int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)
	var f_low: float = lerpf(1900.0, 2150.0, rng.randf())
	var f_high: float = lerpf(9600.0, 10500.0, rng.randf())
	# Decay rates in 1/sec. f_low fades in ~30 ms; f_high rings for ~120 ms.
	var d_low: float = lerpf(95.0, 115.0, rng.randf())
	var d_high: float = lerpf(24.0, 32.0, rng.randf())
	var phase_low: float = 0.0
	var phase_high: float = 0.0
	for i in range(n):
		var t: float = float(i) / MIX_RATE
		phase_low += TAU * f_low / MIX_RATE
		phase_high += TAU * f_high / MIX_RATE
		var p_low: float = sin(phase_low) * exp(-t * d_low) * 0.45
		var p_high: float = sin(phase_high) * exp(-t * d_high) * 0.55
		var s: float = tanh((p_low + p_high) * 1.1)
		out[i] = Vector2(s, s)
	return out

func _synth_dash() -> PackedVector2Array:
	# Soft air whoosh — low cutoff + gentle envelope, generous headroom so
	# the dB setting controls loudness rather than the synth clipping it.
	var dur := 0.16
	var n := int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)
	var lp := 0.0
	for i in range(n):
		var t := float(i) / MIX_RATE
		# Slightly slower attack so there's no "pop" at the start.
		var env_phase := clampf(t / dur, 0.0, 1.0)
		var env := pow(sin(PI * env_phase), 1.6)
		var noise := randf_range(-1.0, 1.0)
		# Tighter band around ~200–600 Hz reads as "rush of air" rather than hiss.
		var cutoff_k := lerpf(0.08, 0.22, t / dur)
		lp = lerpf(lp, noise, cutoff_k)
		var s := lp * env * 0.18
		out[i] = Vector2(s, s)
	return out


func _synth_lava_sizzle(variant: int, fall_death: bool = false) -> PackedVector2Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([variant, "lava_sizzle", fall_death])
	var dur: float = lerpf(1.55, 1.95, rng.randf()) if fall_death else lerpf(0.42, 0.58, rng.randf())
	var n: int = int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)
	var hiss_lp: float = 0.0
	var low_lp: float = 0.0
	var bubble_phase: float = rng.randf() * TAU
	for i in range(n):
		var t: float = float(i) / MIX_RATE
		var u: float = t / dur
		var attack_time := 0.42 if fall_death else 0.075
		var attack: float = smoothstep(0.0, attack_time, t)
		var fade_start := 0.38
		var fade_u := clampf((u - fade_start) / (1.0 - fade_start), 0.0, 1.0)
		var fall_tail := pow(cos(fade_u * PI * 0.5), 1.65)
		var fall_body := smoothstep(0.0, 0.18, u) * fall_tail
		var body: float = fall_body if fall_death else exp(-u * 4.2)
		var env: float = attack * body
		var noise: float = rng.randf_range(-1.0, 1.0)
		hiss_lp = lerpf(hiss_lp, noise, 0.08)
		var hiss: float = (noise - hiss_lp) * env * (0.11 if fall_death else 0.26)
		var low_noise: float = rng.randf_range(-1.0, 1.0)
		low_lp = lerpf(low_lp, low_noise, 0.018)
		bubble_phase += TAU * lerpf(22.0, 38.0, rng.randf()) / MIX_RATE
		var bubble_env: float = body * (0.55 + 0.45 * sin(bubble_phase))
		var bubble: float = tanh(low_lp * 4.0) * bubble_env * 0.18
		var s: float = tanh((hiss + bubble) * (1.05 if fall_death else 1.35))
		out[i] = Vector2(s, s)
	return out


func _synth_card_flip(variant: int) -> PackedVector2Array:
	# Wide-band noise wash (the card travelling) then a short, brighter
	# highpass-noise click (the card landing flat). Both layers are pure
	# noise — no sine — so the result reads as paper/airy clatter rather
	# than a pitched tone. Per-variant RNG seeding gives 3 stable samples.
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([variant, "card_flip"])
	var dur: float = lerpf(0.16, 0.22, rng.randf())
	var noise_dur: float = dur * lerpf(0.65, 0.80, rng.randf())
	var tick_start: float = dur * lerpf(0.78, 0.90, rng.randf())
	var tick_decay: float = lerpf(180.0, 320.0, rng.randf())
	# Phase-1 lowpass coefficient — broad lowpass so the wash stays "white"
	# rather than nasal/banded. Higher = brighter wash.
	var wash_lp_k: float = lerpf(0.20, 0.45, rng.randf())
	# Phase-2 highpass cutoff — the tick subtracts a slow average of the
	# noise from itself, leaving only the high-frequency burst. Higher k =
	# more low-end chopped, brighter click.
	var tick_hp_k: float = lerpf(0.30, 0.55, rng.randf())
	var n: int = int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)
	var wash_lp: float = 0.0
	var tick_lp: float = 0.0
	for i in range(n):
		var t: float = float(i) / MIX_RATE
		var s: float = 0.0
		# Phase 1 — broadband noise with sin-envelope swell. Lightly lowpassed
		# (warm hiss) instead of band-passed (nasal whistle).
		if t < noise_dur:
			var noise_phase: float = t / noise_dur
			var env: float = sin(PI * noise_phase) * 0.20
			var noise: float = rng.randf_range(-1.0, 1.0)
			wash_lp = lerpf(wash_lp, noise, wash_lp_k)
			s += wash_lp * env
		# Phase 2 — short highpass-noise click. exp decay → ~10-20 ms burst.
		if t >= tick_start:
			var dt: float = t - tick_start
			var n_t: float = rng.randf_range(-1.0, 1.0)
			tick_lp = lerpf(tick_lp, n_t, tick_hp_k)
			s += (n_t - tick_lp) * exp(-dt * tick_decay) * 0.5
		out[i] = Vector2(s, s)
	return out

func _synth_air_strike_inbound(travel_seconds: float, distant: bool = false) -> PackedVector2Array:
	# Brown-noise missile whoosh that swells toward impact. Length matches the
	# rocket flight so the synth envelope lines up with the visual approach.
	var dur: float = clampf(travel_seconds, 1.75, 6.5)
	var n: int = int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)
	var sample_dt: float = 1.0 / float(MIX_RATE)
	var lp: float = 0.0
	var lp2: float = 0.0
	var brown: float = 0.0
	var start_env: float = 0.52 if distant else 0.46
	var start_cutoff: float = 45.0 if distant else 60.0
	for i in range(n):
		var t: float = float(i) / float(MIX_RATE)
		var u: float = t / dur
		var env: float = lerpf(start_env, 1.0, u * u)
		var cutoff: float = lerpf(start_cutoff, 320.0, u)
		var rc: float = 1.0 / (TAU * cutoff)
		var alpha: float = sample_dt / (rc + sample_dt)
		brown = brown * 0.998 + randf_range(-1.0, 1.0) * 0.04
		lp = lp + alpha * (brown - lp)
		lp2 = lp2 + alpha * (lp - lp2)
		var s: float = tanh(lp2 * 6.5) * 0.62 * env
		out[i] = Vector2(s, s)
	return out


func _synth_ion_cannon_charge(charge_seconds: float) -> PackedVector2Array:
	# Ambient Am7-ish pad that swells from a ghostly whisper into full charge.
	# Layered sines + soft harmonics + filtered noise bed; length matches the beam.
	var dur: float = clampf(charge_seconds, 2.5, 6.5)
	var n: int = int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)
	var freqs: Array[float] = [220.0, 261.63, 329.63, 392.0, 440.0, 554.37]
	var gains: Array[float] = [0.34, 0.28, 0.24, 0.20, 0.18, 0.12]
	var detune: Array[float] = [1.0, 1.002, 0.998, 1.004, 0.996, 1.001]
	var phases: Array[float] = []
	phases.resize(freqs.size())
	for j in freqs.size():
		phases[j] = randf() * TAU
	var noise_lp: float = 0.0
	for i in range(n):
		var t: float = float(i) / float(MIX_RATE)
		var u: float = t / dur
		var swell: float = pow(u, 3.4)
		var bloom: float = smoothstep(0.42, 1.0, u)
		var pulse: float = 1.0 + sin(t * 8.6) * 0.035 * bloom
		var chord: float = 0.0
		for j in freqs.size():
			var hz: float = freqs[j] * detune[j]
			phases[j] += TAU * hz / MIX_RATE
			chord += sin(phases[j]) * gains[j]
			chord += sin(phases[j] * 2.0) * gains[j] * 0.07 * bloom
			chord += sin(phases[j] * 3.0) * gains[j] * 0.03 * bloom * bloom
		var noise: float = randf_range(-1.0, 1.0)
		noise_lp = lerpf(noise_lp, noise, 0.014)
		var bed: float = noise_lp * lerpf(0.05, 0.18, swell)
		var env: float = lerpf(0.10, 1.0, swell)
		var s: float = tanh((chord * 0.22 + bed) * env * pulse) * 0.68
		out[i] = Vector2(s, s * 0.98)
	return out


func _synth_ion_cannon_burst(radius: float, variant: int) -> PackedVector2Array:
	# Deep ~40 Hz sawtooth boom — the body of the ion detonation, layered on top
	# of the regular explosion bang. Two slightly-detuned saws (fundamental +
	# octave) give weight without mud; the raw saw edge is tamed by a one-pole
	# low-pass so it reads as a round, chest-thumping boom rather than a buzz. A
	# brief noise crack adds the initial zap transient. Steady pitch (no sweep).
	# Waveshaped through tanh — loud, never clips.
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([radius, variant, "ion_burst"])
	var r_norm: float = clampf(radius / 38.0, 0.6, 1.4)
	var dur: float = clampf(lerpf(0.55, 0.85, r_norm) * lerpf(0.95, 1.05, rng.randf()), 0.5, 0.95)
	var n: int = int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)
	# ~40 Hz fundamental, a touch lower for bigger blasts; octave-up partner
	# detuned for thickness. Small per-cast variation keeps repeats from phasing.
	var f0: float = 40.0 * lerpf(0.97, 1.03, rng.randf()) * lerpf(1.0, 0.9, r_norm - 0.6)
	var f1: float = f0 * 2.0 * lerpf(0.992, 1.008, rng.randf())
	var ph0: float = rng.randf() * TAU
	var ph1: float = rng.randf() * TAU
	var lp: float = 0.0
	var crack_lp: float = 0.0
	for i in range(n):
		var t: float = float(i) / MIX_RATE
		var u: float = t / dur
		ph0 = fmod(ph0 + TAU * f0 / MIX_RATE, TAU)
		ph1 = fmod(ph1 + TAU * f1 / MIX_RATE, TAU)
		var saw: float = (ph0 / PI - 1.0) * 0.85 + (ph1 / PI - 1.0) * 0.3
		# One-pole low-pass rounds off the saw's buzzy upper harmonics.
		lp = lerpf(lp, saw, 0.45)
		var crack: float = rng.randf_range(-1.0, 1.0)
		crack_lp = lerpf(crack_lp, crack, 0.5)
		var crack_env: float = exp(-t * 85.0)
		var env: float = exp(-t * lerpf(4.6, 3.0, r_norm)) * pow(1.0 - u, 0.5)
		var s: float = tanh((lp * 2.4 + crack_lp * crack_env * 1.1) * env) * 0.7
		out[i] = Vector2(s, s * 0.99)
	return out


func _synth_rocket_descent() -> PackedVector2Array:
	# ~0.85s heavy rumble that swells as the rocket nears impact. Brown-ish
	# noise (white noise + one-pole low-pass) waveshaped through tanh for
	# soft saturation that stays well below clipping. Cutoff opens slightly
	# over time so the late phase has more "presence." Length tuned to the
	# 0.75s spawn-to-impact descent + a tiny tail.
	var dur: float = 0.85
	var n: int = int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)
	var sample_dt: float = 1.0 / float(MIX_RATE)
	var lp: float = 0.0
	var lp2: float = 0.0
	for i in range(n):
		var t: float = float(i) / float(MIX_RATE)
		var u: float = t / dur
		# Volume ramp: starts audible, swells to full near landing.
		var env: float = lerpf(0.45, 1.0, u * u)
		# Cutoff opens 70Hz -> 280Hz so the late phase is brighter.
		var cutoff: float = lerpf(70.0, 280.0, u)
		var rc: float = 1.0 / (TAU * cutoff)
		var alpha: float = sample_dt / (rc + sample_dt)
		var noise: float = randf_range(-1.0, 1.0)
		# Two stacked one-pole LPs = a 12 dB/oct slope (smoother low end).
		lp = lp + alpha * (noise - lp)
		lp2 = lp2 + alpha * (lp - lp2)
		# Pre-gain into tanh saturator. Pushes the rumble into "heavy" without
		# ever exceeding ±0.6 — guaranteed no digital clipping.
		var s: float = tanh(lp2 * 5.5) * 0.55 * env
		out[i] = Vector2(s, s)
	return out


func _synth_mine_plant() -> PackedVector2Array:
	# Two-part cue: ~80Hz "thud" as the mine touches ground (first 100ms),
	# then a 1200Hz "arm beep" fading in/out over the next 200ms. Tanh
	# saturates the mix so it stays warm and never clips.
	var dur: float = 0.35
	var n: int = int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)
	for i in range(n):
		var t: float = float(i) / float(MIX_RATE)
		var thud_env: float = exp(-t * 35.0)
		var thud: float = sin(2.0 * PI * 80.0 * t) * thud_env * 0.6
		var beep_env: float = 0.0
		if t > 0.10:
			var bt: float = t - 0.10
			beep_env = exp(-bt * 16.0) * (1.0 - exp(-bt * 50.0))
		var beep: float = sin(2.0 * PI * 1200.0 * t) * beep_env * 0.35
		var s: float = tanh((thud + beep) * 1.2) * 0.55
		out[i] = Vector2(s, s)
	return out


func _synth_pling(pitch_ratio: float = 1.0) -> PackedVector2Array:
	# Simple high-pitched sine pling with exponential decay.
	var dur := 0.25
	var n := int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)
	var freq := 880.0 * pitch_ratio
	for i in range(n):
		var t := float(i) / MIX_RATE
		var env := exp(-t * 22.0)
		var s := sin(2.0 * PI * freq * t) * env * 0.5
		out[i] = Vector2(s, s)
	return out

func _synth_pickup_drop() -> PackedVector2Array:
	# Descending whoosh with a bright chime at the end — sky-drop telegraph.
	var dur := 0.62
	var n := int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)
	for i in range(n):
		var t := float(i) / MIX_RATE
		var u := t / dur
		var whoosh_env := (1.0 - u) * exp(-t * 4.5)
		var whoosh_freq := lerpf(920.0, 180.0, u * u)
		var whoosh := sin(2.0 * PI * whoosh_freq * t) * whoosh_env * 0.22
		var chime_start := dur * 0.58
		var chime := 0.0
		if t >= chime_start:
			var ct := t - chime_start
			var chime_env := exp(-ct * 18.0)
			chime = sin(2.0 * PI * 1180.0 * ct) * chime_env * 0.42
		var s := tanh((whoosh + chime) * 1.35) * 0.55
		out[i] = Vector2(s, s)
	return out

func _synth_enemy_incoming() -> PackedVector2Array:
	# Hostile ground-rift stutter: low rasp + clipped bursts, not a sky whoosh.
	var dur := 0.42
	var n := int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)
	var sample_dt := 1.0 / float(MIX_RATE)
	var lp := 0.0
	for i in range(n):
		var t := float(i) / MIX_RATE
		var u := t / dur
		var env := exp(-t * 5.8) * smoothstep(0.0, 0.06, u)
		var burst := 0.0
		if fmod(t, 0.07) < 0.022:
			burst = randf_range(-1.0, 1.0) * 0.55
		var tone_freq := lerpf(210.0, 95.0, u)
		var tone := sin(2.0 * PI * tone_freq * t) * 0.28
		var noise := randf_range(-1.0, 1.0)
		var rc := 1.0 / (TAU * lerpf(180.0, 70.0, u))
		var alpha := sample_dt / (rc + sample_dt)
		lp = lp + alpha * (noise - lp)
		var s := tanh((burst + tone + lp * 0.35) * env * 1.45) * 0.62
		out[i] = Vector2(s, s)
	return out

func _synth_hitmarker(kind: String, dmg_ratio: float = 1.0) -> PackedVector2Array:
	# Short metallic "tink" — CoD-style hit confirm. Built from:
	#   • a ~3ms noise transient (the "click" on attack),
	#   • two close harmonics for the tonal ring,
	#   • a fast exponential decay so the whole thing is gone in ~40ms.
	# Heavier hits drop pitch, slow the decay, and extend duration so the
	# low end has room to resonate into a thunk.
	var pitch_factor: float = 1.0 / pow(dmg_ratio, 0.45)
	var decay_factor: float = lerpf(1.0, 0.45, clampf((dmg_ratio - 1.0) / 4.0, 0.0, 1.0))
	var dur: float = clampf(0.05 / decay_factor, 0.05, 0.14)
	var n := int(dur * MIX_RATE)
	var out := PackedVector2Array()
	out.resize(n)
	var f1 := 2500.0
	var f2 := 1700.0
	if kind == "head":
		f1 = 3400.0
		f2 = 2250.0
	elif kind == "kill":
		f1 = 1800.0
		f2 = 1200.0
	f1 *= pitch_factor
	f2 *= pitch_factor
	for i in range(n):
		var t := float(i) / MIX_RATE
		var env := exp(-t * 100.0 * decay_factor)
		var attack_env := exp(-t * 600.0 * decay_factor)
		var noise := randf_range(-1.0, 1.0) * attack_env * 0.5
		var tone := sin(2.0 * PI * f1 * t) * 0.55 + sin(2.0 * PI * f2 * t) * 0.35
		var s := tanh((noise + tone * env) * 0.9)
		out[i] = Vector2(s, s)
	return out
