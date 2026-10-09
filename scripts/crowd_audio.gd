extends "res://addons/crowd_sound/crowd_sound.gd"

# Colosseum crowd audio. The sound engine itself (synthesized beds, reactions,
# chants) is the shared crowd_sound addon from the GameNight SDK; this layer
# adds what is Growing Guns-specific:
#
# - The crowd ring: ColosseumBuilder.build registers the bowl geometry + the
#   crowd's ShaderMaterial here. Bullets and blasts that land in the stands
#   scare the crowd; the rest of the arena only excites it.
# - One-shots go through SFX._play_stream, inheriting reverb, HDR culling,
#   distance delay and splitscreen ghosts. Directional reactions (screams,
#   chants) play 3D at the nearest point on the crowd ring.
# - SFX's HDR loudness tracker ducks the beds under heavy combat.
# - The enthusiasm/fear pair also drives the shader's excitement/panic
#   uniforms so the silhouettes jump when they roar and cower when they scream.
#
# Perf: per frame a few float ops + at most 2 set_shader_parameter calls; the
# per-bullet stands test exits on a single Y comparison for any bullet below
# stand height.

# The crowd exists while a colosseum ring is registered.
var ring_active: bool:
	get:
		return active
	set(v):
		active = v

var _ring_id: int = 0
var _ring_node: Node3D = null
var _ring_center := Vector3.ZERO
var _ring_center_ok := false
var _r_inner: float = 0.0
var _r_outer: float = 0.0
var _r_inner_sq: float = 0.0
var _r_outer_sq: float = 0.0
var _y_base: float = 0.0
var _y_top: float = 0.0
var _crowd_mat: ShaderMaterial = null
var _shader_excitement: float = -1.0
var _shader_panic: float = -1.0


# -------------------- ring registration --------------------

# Called by ColosseumBuilder.build once the bowl exists. The ring is the
# torus-ish band the spectators occupy: radii [r_inner, r_outer] between
# heights [y_base, y_top] around the colosseum root's origin.
func register_ring(
	root: Node3D,
	r_inner: float,
	r_outer: float,
	y_base: float,
	y_top: float,
	crowd_mat: ShaderMaterial,
) -> void:
	_ring_id = root.get_instance_id()
	_ring_node = root
	_ring_center_ok = false
	_r_inner = r_inner
	_r_outer = r_outer
	_r_inner_sq = r_inner * r_inner
	_r_outer_sq = r_outer * r_outer
	_y_base = y_base
	_y_top = y_top
	_crowd_mat = crowd_mat
	_shader_excitement = -1.0
	_shader_panic = -1.0
	ring_active = true


func unregister_ring(id: int) -> void:
	if id != _ring_id:
		return  # a newer arena already registered its own ring
	ring_active = false  # also zeroes enthusiasm and fear
	_ring_node = null
	_crowd_mat = null


# Lazy center resolution: the colosseum root may not be inside the tree yet
# when register_ring runs (editor-owner builds), so global_position is read
# on first use and cached.
func _resolve_center() -> bool:
	if _ring_center_ok:
		return true
	if _ring_node == null or not is_instance_valid(_ring_node) or not _ring_node.is_inside_tree():
		return false
	_ring_center = _ring_node.global_position
	_ring_center_ok = true
	return true


# -------------------- geometry queries --------------------

# Hot path: called per bullet per physics tick. Y test first — nearly every
# bullet flies below the stands, so this usually exits on one comparison.
func point_in_crowd(p: Vector3) -> bool:
	if not ring_active:
		return false
	if p.y < _y_base or p.y > _y_top:
		return false
	if not _resolve_center():
		return false
	var dx := p.x - _ring_center.x
	var dz := p.z - _ring_center.z
	var rr := dx * dx + dz * dz
	return rr >= _r_inner_sq and rr <= _r_outer_sq


# Hitscan companion: does the segment cross into the stands band? Solves the
# ray/cylinder crossing for the inner radius analytically — no stepping.
func check_segment(from: Vector3, to: Vector3) -> void:
	if not ring_active or not _resolve_center():
		return
	var p := Vector2(from.x - _ring_center.x, from.z - _ring_center.z)
	var d := Vector2(to.x - from.x, to.z - from.z)
	var a := d.dot(d)
	if a < 0.0001:
		return
	var b := 2.0 * p.dot(d)
	var c := p.dot(p) - _r_inner_sq
	var disc := b * b - 4.0 * a * c
	if disc <= 0.0:
		return
	var sq := sqrt(disc)
	for t: float in [(-b - sq) / (2.0 * a), (-b + sq) / (2.0 * a)]:
		if t < 0.0 or t > 1.0:
			continue
		var y := from.y + (to.y - from.y) * t
		if y >= _y_base and y <= _y_top:
			on_crowd_bullet_hit(from.lerp(to, t))
			return


# Distance from a point to the crowd band (0 when inside it).
func _dist_to_crowd(p: Vector3) -> float:
	var pr := Vector2(p.x - _ring_center.x, p.z - _ring_center.z).length()
	var dr := maxf(maxf(_r_inner - pr, pr - _r_outer), 0.0)
	var dy := maxf(maxf(_y_base - p.y, p.y - _y_top), 0.0)
	return Vector2(dr, dy).length()


# Nearest seat to a world position — where directional reactions play from.
func _ring_point_toward(p: Vector3) -> Vector3:
	var dir := Vector2(p.x - _ring_center.x, p.z - _ring_center.z)
	if dir.length_squared() < 0.01:
		dir = Vector2.RIGHT
	dir = dir.normalized()
	var r := _r_inner + 3.0
	var y := _y_base + (_y_top - _y_base) * 0.35
	return Vector3(_ring_center.x + dir.x * r, y, _ring_center.z + dir.y * r)


# -------------------- crowd_sound hooks --------------------

func _play_oneshot(stream: AudioStream, volume_db: float, at: Vector3, pitch: float,
		label: String, priority_spl: float, attenuation: float, big_tail: bool) -> void:
	SFX._play_stream(stream, volume_db, at, pitch, label, attenuation, false,
		priority_spl, big_tail)


func _loudness_db() -> float:
	return SFX._hdr_max_spl - 112.0


func _suppressed() -> bool:
	return BenchFlags.active


func _chant_position() -> Vector3:
	if not _resolve_center():
		return Vector3.INF
	var ang := randf() * TAU
	return _ring_point_toward(_ring_center + Vector3(cos(ang), 0.0, sin(ang)))


# -------------------- gameplay events --------------------

func on_round_start() -> void:
	kickoff()


func on_round_win() -> void:
	celebrate()


func on_player_hurt(_pos: Vector3) -> void:
	hit()


func on_player_death(_pos: Vector3) -> void:
	roar()


func on_explosion(pos: Vector3, radius: float) -> void:
	if not ring_active or _suppressed() or not _resolve_center():
		return
	var reach := radius * 1.2 + 1.5
	var d := _dist_to_crowd(pos)
	if d <= reach:
		# Blast into (or right next to) the stands — terror, scaled by size
		# and proximity. Cheering collapses: survivors don't applaud that.
		var proximity := 1.0 - 0.5 * (d / reach)
		scare((0.3 + radius * 0.03) * proximity, _ring_point_toward(pos), 1.0, 0.45)
		# ...and the spectators inside the blast don't scream at all. The KILL
		# radius is half the scream reach — a blast should terrify a section
		# but only delete the seats it directly lands on.
		if ColosseumCrowd.active:
			var kills := ColosseumCrowd.active.apply_blast(pos, reach * 0.5)
			fear = clampf(fear + float(kills) * 0.01, 0.0, 1.0)
	else:
		# Fireworks in the arena — the crowd loves it.
		excite(clampf(0.05 + radius * 0.012, 0.0, 0.3))


func on_crowd_bullet_hit(pos: Vector3) -> void:
	if not ring_active or _suppressed():
		return
	scare(0.09, _ring_point_toward(pos), 0.55)
	if ColosseumCrowd.active:
		ColosseumCrowd.active.apply_bullet(pos)


# A bullet already resolved a kill inside the stands (analytic body hit —
# spectators have no colliders). Reaction only; kill + gore happened upstream.
func notify_crowd_kill(pos: Vector3) -> void:
	if not ring_active or _suppressed():
		return
	scare(0.12, _ring_point_toward(pos), 0.7)


# -------------------- per-frame --------------------

func _process(delta: float) -> void:
	super(delta)
	# Drive the silhouette shader so the crowd's body language matches the
	# sound: excited → higher/faster hops, afraid → cowering tremble.
	if _crowd_mat != null:
		if absf(enthusiasm - _shader_excitement) > 0.01:
			_shader_excitement = enthusiasm
			_crowd_mat.set_shader_parameter("excitement", enthusiasm)
		if absf(fear - _shader_panic) > 0.01:
			_shader_panic = fear
			_crowd_mat.set_shader_parameter("panic", fear)
