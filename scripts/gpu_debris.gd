class_name GpuDebris
extends RefCounted

const DestructibleManager = preload("res://scripts/destructible_manager.gd")
const SHADER := preload("res://shaders/gpu_debris.gdshader")

# GPU debris: destruction rubble simulated entirely on the GPU (prototype).
#
# When a blast removes chunks, we snapshot the post-blast world around it as a
# boolean occupancy 3D texture (rasterized from the alive chunk AABBs — the
# pre-split chunk grid IS the collision world, no SDF bake needed) and hand it
# to a one-shot GPUParticles3D whose process shader integrates gravity and
# bounces particles off solid voxels. Positions never come back to the CPU, so
# this debris is cosmetic only.
#
# The snapshot is built one frame AFTER the carve flush, so every chunk this
# tick's blasts removed is already marked destroyed — debris never bounces off
# the wall its own explosion vaporised. Chunks still queued on OTHER bodies
# (flush budget spillover) may show up solid for a tick; acceptable.
#
# This is THE debris system: it replaced the CPU parabola chips (which never
# collided with anything). Two tiers:
#   "burst" — chunk removals: big shards, big snapshot region, 2.6 s.
#   "chips" — per-hit flecks from the deform path: few tiny shards, a small
#             snapshot (bullets land many times per second), short life.
# `enabled` is a kill-switch (PerfGovernor / debugging), not an opt-in.

static var enabled := true

const VOXEL := 0.5
const BURST_DIMS := Vector3i(48, 44, 48)  # ~24 x 22 x 24 m, ~101 KB
const CHIP_DIMS := Vector3i(24, 20, 24)   # ~12 x 10 x 12 m, ~12 KB
const MERGE_DIST_SQ := 64.0
const CHIP_MERGE_DIST_SQ := 9.0
const MAX_CHIP_JOBS_PER_FLUSH := 6
const DEBRIS_LIFETIME := 2.6
const CHIP_LIFETIME := 1.4

# Device-adaptive budget: burst sizes and the global live-particle pool both
# scale with PerfGovernor's quality_scale (via Violence.vfx_quality_scale(),
# same signal the CPU VFX budgets use — weak machines shed debris first).
# NEW bursts take precedence: when the pool is full, the OLDEST live emitters
# are evicted to make room (their rocks are settled or faded anyway), so blast
# spam never silences the freshest explosion. Each emitter is also one draw
# call + one snapshot texture, so the emitter FIFO caps that too.
const MAX_LIVE_PARTICLES := 3600  # at full quality
const MAX_LIVE_EMITTERS := 20
const MIN_BURST_AMOUNT := 4
# Wall-clock backstop: GPU particle sims pause while off-screen, so `finished`
# can stay unfired indefinitely; reclaim such emitters after this many real
# seconds (generously past any on-screen sim's lifetime, even in low-fps
# slow-motion).
const EMITTER_MAX_AGE_SEC := 20.0

static var _pending: Array[Dictionary] = []
static var _flusher: Node = null
static var _chip_mat: StandardMaterial3D = null
static var _live: Array[GPUParticles3D] = []
static var _live_particles: int = 0
static var _bursts_total: int = 0  # bench counter (reset via reset_debug_counters)


# One-frame deferral: collects every burst request made during this physics
# tick, so a multi-body blast becomes ONE snapshot + emitter, built after all
# of the tick's removals have been applied.
class Flusher:
	extends Node

	func _process(_dt: float) -> void:
		GpuDebris.flush_pending()


static func request_burst(
	scene: Node,
	blast_world: Vector3,
	blast_radius: float,
	chunks_removed: int,
	color: Color,
) -> void:
	if not _accepting(scene):
		return
	for job: Dictionary in _pending:
		if str(job["kind"]) != "burst":
			continue
		if (job["blast"] as Vector3).distance_squared_to(blast_world) <= MERGE_DIST_SQ:
			job["chunks"] = int(job["chunks"]) + maxi(chunks_removed, 1)
			job["radius"] = maxf(float(job["radius"]), blast_radius)
			return
	_pending.append({
		"kind": "burst",
		"scene": scene,
		"blast": blast_world,
		"radius": blast_radius,
		"chunks": maxi(chunks_removed, 1),
		"color": color,
	})
	_ensure_flusher(scene)


# Per-hit flecks (deform path). count_scale 0..1 scales the shard count the
# way the old CPU path did; chip_size is the longest-axis size in metres.
static func request_chips(
	scene: Node,
	world_pos: Vector3,
	radius: float,
	color: Color,
	chip_size: float,
	count_scale: float,
) -> void:
	if not _accepting(scene):
		return
	var amount := clampi(int(round(16.0 * count_scale)), 2, 20)
	var chip_jobs := 0
	for job: Dictionary in _pending:
		if str(job["kind"]) != "chips":
			continue
		if (job["blast"] as Vector3).distance_squared_to(world_pos) <= CHIP_MERGE_DIST_SQ:
			job["amount"] = mini(int(job["amount"]) + amount, 32)
			job["chip_size"] = maxf(float(job["chip_size"]), chip_size)
			return
		chip_jobs += 1
	if chip_jobs >= MAX_CHIP_JOBS_PER_FLUSH:
		return
	_pending.append({
		"kind": "chips",
		"scene": scene,
		"blast": world_pos,
		"radius": radius,
		"amount": amount,
		"chip_size": chip_size,
		"color": color,
	})
	_ensure_flusher(scene)


static func _accepting(scene: Node) -> bool:
	if not enabled or scene == null:
		return false
	if BenchFlags.active and BenchFlags.no_explosion_visuals:
		return false
	return true


static func flush_pending() -> void:
	if _pending.is_empty():
		return
	var t0 := Time.get_ticks_usec()
	# Governor shed tier 1: the occupancy raster is the expensive part of a
	# spawn (3-7 ms CPU on multi-blast frames), so under pressure build at
	# most `debris_jobs_per_flush` snapshots per frame and roll the rest to
	# the next flush. Deferred jobs still merge with new requests, and they
	# snapshot LATER — after more removals applied — which is harmless.
	var budget := _pending.size()
	var gov := _governor()
	if gov != null:
		budget = mini(budget, int(gov.debris_jobs_per_flush))
	if budget < _pending.size():
		# Bursts (chunk removals) read louder than per-hit chips — spend the
		# constrained budget on bursts first.
		var ordered: Array[Dictionary] = []
		for job: Dictionary in _pending:
			if str(job["kind"]) == "burst":
				ordered.append(job)
		for job: Dictionary in _pending:
			if str(job["kind"]) != "burst":
				ordered.append(job)
		_pending = ordered
	var n := mini(budget, _pending.size())
	for i: int in n:
		_spawn_burst(_pending.pop_front())
	# Backstop so a long shed period can't grow an unbounded queue (excess
	# trailing jobs are chips — bursts were sorted to the front above).
	if _pending.size() > 12:
		_pending.resize(12)
	Trace.prof("gpu_debris", Time.get_ticks_usec() - t0)


static var _gov: Node = null


static func _governor() -> Node:
	if _gov == null or not is_instance_valid(_gov):
		var loop := Engine.get_main_loop()
		if loop is SceneTree:
			_gov = (loop as SceneTree).root.get_node_or_null("PerfGovernor")
	return _gov


# Compiles the particle-process + draw PSOs before the first real blast
# (same idea as Violence.warmup_blast_materials): sub-pixel burst in view.
static func warmup(scene: Node) -> void:
	_spawn_burst({
		"kind": "burst",
		"scene": scene,
		"blast": Vector3(0.0, 2.0, 0.0),
		"radius": 1.0,
		"chunks": 1,
		"color": Color(0.5, 0.5, 0.5),
		"scale_mult": 0.001,
	})


static func _ensure_flusher(scene: Node) -> void:
	if _flusher != null and is_instance_valid(_flusher) and _flusher.is_inside_tree():
		return
	var tree := scene.get_tree()
	if tree == null:
		return
	_flusher = Flusher.new()
	_flusher.name = "GpuDebrisFlusher"
	tree.root.add_child.call_deferred(_flusher)


# Rasterize every alive chunk AABB around the blast into a 0/255 occupancy
# volume. Runs once per blast (not per particle, not per frame).
static func _build_snapshot(blast: Vector3, dims: Vector3i, y_offset: float) -> Dictionary:
	var size := Vector3(dims) * VOXEL
	var origin := blast + Vector3(0.0, y_offset, 0.0) - size * 0.5
	var boxes: Array[Vector3] = []  # flat (world center, half-extent) pairs
	for vol: Node3D in DestructibleManager.volumes_overlapping_aabb(AABB(origin, size)):
		if vol.has_method("alive_chunk_world_boxes"):
			vol.call("alive_chunk_world_boxes", boxes)
	var data := PackedByteArray()
	data.resize(dims.x * dims.y * dims.z)
	var inv := 1.0 / VOXEL
	var i := 0
	while i < boxes.size():
		var c := boxes[i]
		var ext := boxes[i + 1]
		i += 2
		var mn := (c - ext - origin) * inv
		var mx := (c + ext - origin) * inv
		var x0 := maxi(int(floorf(mn.x)), 0)
		var x1 := mini(int(floorf(mx.x)), dims.x - 1)
		var y0 := maxi(int(floorf(mn.y)), 0)
		var y1 := mini(int(floorf(mx.y)), dims.y - 1)
		var z0 := maxi(int(floorf(mn.z)), 0)
		var z1 := mini(int(floorf(mx.z)), dims.z - 1)
		if x1 < x0 or y1 < y0 or z1 < z0:
			continue
		for z: int in range(z0, z1 + 1):
			var zbase := z * dims.x * dims.y
			for y: int in range(y0, y1 + 1):
				var row := zbase + y * dims.x
				for x: int in range(x0, x1 + 1):
					data[row + x] = 255
	var slices: Array[Image] = []
	var slice_n := dims.x * dims.y
	for z: int in dims.z:
		slices.append(Image.create_from_data(
			dims.x, dims.y, false, Image.FORMAT_L8,
			data.slice(z * slice_n, (z + 1) * slice_n)))
	var tex := ImageTexture3D.new()
	tex.create(Image.FORMAT_L8, dims.x, dims.y, dims.z, false, slices)
	return {"tex": tex, "origin": origin, "size": size}


static func _spawn_burst(job: Dictionary) -> void:
	var scene: Node = job["scene"] as Node
	if scene == null or not is_instance_valid(scene) or not scene.is_inside_tree():
		return
	var blast: Vector3 = job["blast"] as Vector3
	var radius: float = maxf(float(job["radius"]), 1.0)
	var chips := str(job["kind"]) == "chips"
	var want: int
	if chips:
		want = int(job["amount"])
	else:
		want = clampi(int(job["chunks"]) * 70, 128, 900)
	var q: float = Violence.vfx_quality_scale()
	var amount := maxi(int(ceilf(float(want) * q)), MIN_BURST_AMOUNT)
	var cap := int(float(MAX_LIVE_PARTICLES) * q)
	while _live_particles + amount > cap and not _live.is_empty():
		_evict_oldest()
	var snap := _build_snapshot(
		blast,
		CHIP_DIMS if chips else BURST_DIMS,
		-1.5 if chips else -3.0)
	var p := GPUParticles3D.new()
	p.amount = amount
	p.lifetime = CHIP_LIFETIME if chips else DEBRIS_LIFETIME
	p.one_shot = true
	p.explosiveness = 1.0
	p.fixed_fps = 60
	p.local_coords = false
	# Same perf choice as the old chips: shadow passes redrew every chip and
	# multiplied thousands of chips into 20k+ draw calls.
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.visibility_aabb = AABB(snap["origin"] as Vector3, snap["size"] as Vector3)
	var m := ShaderMaterial.new()
	m.shader = SHADER
	m.set_shader_parameter("occupancy", snap["tex"])
	m.set_shader_parameter("grid_origin", snap["origin"])
	m.set_shader_parameter("grid_size", snap["size"])
	m.set_shader_parameter("voxel_size", VOXEL)
	m.set_shader_parameter("blast_pos", blast)
	m.set_shader_parameter("blast_radius", radius)
	m.set_shader_parameter("base_color", job["color"])
	if chips:
		m.set_shader_parameter("speed", clampf(3.0 + radius * 1.5, 3.5, 8.0))
		m.set_shader_parameter("chip_size", float(job["chip_size"]))
	else:
		m.set_shader_parameter("speed", clampf(5.0 + radius * 1.1, 7.0, 17.0))
		m.set_shader_parameter("chip_size", clampf(0.3 + radius * 0.09, 0.35, 1.0))
	m.set_shader_parameter("scale_mult", float(job.get("scale_mult", 1.0)))
	m.set_shader_parameter("kill_y", blast.y - 60.0)
	p.process_material = m
	# The 5 pre-baked shard meshes from the CPU chips — one variant per burst;
	# per-particle squash + tumble in the shader hides the shared silhouette.
	p.draw_pass_1 = Violence._get_impact_chip_mesh()
	p.material_override = _chip_material()
	p.set_meta("gpu_debris_amount", amount)
	# Same group the old chips used: Trace's dbr counter, bench group counts,
	# and clear_round_combat_vfx's round-reset free all keep working.
	p.add_to_group("destruction_debris")
	scene.add_child(p)
	p.emitting = true
	_bursts_total += 1
	_live.append(p)
	_live_particles += amount
	p.tree_exiting.connect(func() -> void: _untrack(p))
	var cleanup := p.get_tree().create_timer(EMITTER_MAX_AGE_SEC)
	# A weak reference: the emitter is usually freed long before this fires,
	# and a lambda holding the node itself logs an error every time it is.
	var ref: WeakRef = weakref(p)
	cleanup.timeout.connect(func() -> void:
		var live := ref.get_ref() as GPUParticles3D
		if live:
			_untrack(live)
			live.queue_free()
	)
	while _live.size() > MAX_LIVE_EMITTERS:
		_evict_oldest()
	# Free when the SIM says every particle is dead — not on a wall-clock
	# timer. Particle sim time advances per rendered frame (fixed_fps), so at
	# low fps a real-time timer would delete debris mid-flight.
	p.finished.connect(p.queue_free)


static func debug_live_emitters() -> int:
	return _live.size()


static func debug_live_particles() -> int:
	return _live_particles


static func debug_bursts_total() -> int:
	return _bursts_total


static func reset_debug_counters() -> void:
	_bursts_total = 0


# Synchronous bookkeeping (queue_free's tree_exiting is deferred, so eviction
# loops must not rely on it to see the counter drop).
static func _untrack(p: GPUParticles3D) -> void:
	var idx := _live.find(p)
	if idx < 0:
		return
	_live.remove_at(idx)
	_live_particles = maxi(0, _live_particles - int(p.get_meta("gpu_debris_amount", 0)))


static func _evict_oldest() -> void:
	if _live.is_empty():
		return
	var oldest: GPUParticles3D = _live[0]
	_untrack(oldest)
	if is_instance_valid(oldest):
		oldest.queue_free()


static func _chip_material() -> StandardMaterial3D:
	if _chip_mat == null:
		_chip_mat = StandardMaterial3D.new()
		_chip_mat.vertex_color_use_as_albedo = true
		_chip_mat.roughness = 0.9
		_chip_mat.metallic = 0.0
	return _chip_mat
