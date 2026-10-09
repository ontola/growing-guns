class_name Violence extends RefCounted

const DestructibleManager = preload("res://scripts/destructible_manager.gd")

# Default chunk count when fracturing a body. Must match the value used by
# gib_warm_tree() at scene load — varying it forces synchronous bakes on the
# main thread (~200ms per mesh). Kept low: each gibbed mesh spawns this many
# RigidBody chunks, and active rigid bodies are the #1 driver of in-game frame
# hitches (a single overkill used to spawn ~60 bodies).
const GIB_CHUNK_COUNT := 3
# The knight rig is ONE big skinned mesh (the blob was 12-14 small primitives,
# each split by GIB_CHUNK_COUNT). Three cells on a whole humanoid leaves a
# giant T-pose torso slab — the knight needs a much finer split.
const KNIGHT_GIB_CHUNK_COUNT := 12
# Killing blow that would leave health here or lower → full body disintegrate.
const OVERKILL_DISINTEGRATE_HEALTH := -50
# Screen-space heat-shimmer + shockwave distortion read the framebuffer (a
# back-buffer copy) — expensive on rapid spam, so very small blasts still skip it.
const BLAST_DISTORTION_MIN_RADIUS := 5.0

# Single home for all death / ragdoll / impact / gore logic. Player.gd keeps
# RPC entry points (must live on the Node) as thin pass-throughs and exposes
# its state vars; everything else lives here as static helpers.
#
# Layout:
#   1. Gib mesh fracturing  — Voronoi splitter + ragdoll body builder.
#   2. VFX spawners         — bullet impact, blood, blast, heat distortion,
#                             shockwave ring (scene-scoped, no Player state).
#   3. Player-coupled       — view punch, hit-face, ragdoll spawn/clear,
#                             knockback. These take a player Node.

# -------------------- 1. GIB MESH FRACTURING --------------------
#
# Voronoi-splits a Mesh into random chunks and spawns each as a RigidBody3D.
# Triangles are bucketed by which random seed their centroid is nearest to.
# Each chunk's cut boundary is capped with a fan of flesh triangles (vertex-
# coloured dark red, double-sided) so tumbling chunks show meaty innards
# instead of reading as hollow shells.
#
# The Voronoi bake is expensive (~tens of ms per mesh), so results are
# cached and ideally pre-built on a worker thread via gib_warm_tree(node)
# at map load. `gib_explode()` picks one of the cached variants and just
# instantiates ArrayMeshes + RigidBody3Ds — near-free at runtime.

const _GIB_VARIANTS_PER_MESH := 3
const _GIB_QUANTIZE := 0.0001

# [mesh, chunk_count] → Array[variant]; each variant is Array[chunk_dict].
static var _gib_cache: Dictionary = {}
static var _gib_cache_mutex: Mutex = Mutex.new()
static var _gib_flesh_material_cached: StandardMaterial3D = null

# Hard cap on simultaneously-alive gib chunks. Active rigid bodies are the
# dominant cause of in-game frame hitches (≥40 active bodies tracked ~91% of
# spikes), so stacked overkills can't pile up unbounded — the oldest chunk is
# freed when a new one would exceed the cap. FIFO holds only alive chunks
# (entries erase themselves on tree_exiting).
const MAX_ACTIVE_GIB_CHUNKS := 32
static var _gib_chunk_fifo: Array[RigidBody3D] = []

static func _max_active_gib_chunks() -> int:
	return clampi(int(round(float(MAX_ACTIVE_GIB_CHUNKS) * vfx_quality_scale())), 8, MAX_ACTIVE_GIB_CHUNKS)


static func _gib_enroll_chunk(rb: RigidBody3D) -> void:
	_gib_chunk_fifo.append(rb)
	rb.tree_exiting.connect(func() -> void: _gib_chunk_fifo.erase(rb))
	while _gib_chunk_fifo.size() > _max_active_gib_chunks():
		var old: RigidBody3D = _gib_chunk_fifo.pop_front()
		if is_instance_valid(old):
			old.queue_free()


# Cosmetic face details (eyes, pupils, eye-strokes) are tiny — gibbing them just
# multiplies rigid-body chunks for debris nobody can read amid the meaty pieces.
static func _gib_is_cosmetic_mesh(mi: MeshInstance3D) -> bool:
	var n := String(mi.name)
	return n.begins_with("Eye") or n.begins_with("Pupil") or n.begins_with("Stroke")

# Kick off async bakes for every MeshInstance3D under `root`. Idempotent;
# subsequent calls with the same mesh/chunk_count are no-ops.
static func gib_warm_tree(root: Node, chunk_count: int = 4) -> void:
	if root == null:
		return
	var meshes: Array[Mesh] = []
	_gib_collect_meshes(root, meshes)
	for m in meshes:
		gib_warm(m, chunk_count)

static func gib_warm(mesh: Mesh, chunk_count: int = 4) -> void:
	if mesh == null:
		return
	var key: Array = [mesh, chunk_count]
	_gib_cache_mutex.lock()
	var present: bool = _gib_cache.has(key)
	if not present:
		_gib_cache[key] = null  # reserve slot so concurrent warms dedupe
	_gib_cache_mutex.unlock()
	if present:
		return
	WorkerThreadPool.add_task(_gib_warm_task.bind(mesh, chunk_count), false, "Violence.gib_warm")

static func gib_warm_sync(mesh: Mesh, chunk_count: int = GIB_CHUNK_COUNT) -> void:
	if mesh == null:
		return
	var key: Array = [mesh, chunk_count]
	_gib_cache_mutex.lock()
	var cached: Variant = _gib_cache.get(key)
	if cached is Array:
		_gib_cache_mutex.unlock()
		return
	_gib_cache_mutex.unlock()
	var variants: Array = _gib_build_variants(mesh, chunk_count)
	_gib_cache_mutex.lock()
	if _gib_cache.get(key) is Array:
		_gib_cache_mutex.unlock()
		return
	_gib_cache[key] = variants
	_gib_cache_mutex.unlock()

static func gib_warm_tree_sync(root: Node, chunk_count: int = GIB_CHUNK_COUNT) -> void:
	if root == null:
		return
	var meshes: Array[Mesh] = []
	_gib_collect_meshes(root, meshes)
	for m in meshes:
		gib_warm_sync(m, chunk_count)

# Bake every player-body gib variant up front so the first overkill /
# disintegration never hitches on the main thread.
static var _disintegration_prewarmed: bool = false

static func prewarm_disintegration_cache() -> void:
	if _disintegration_prewarmed:
		return
	_disintegration_prewarmed = true
	_gib_get_flesh_material()
	var player_scene: PackedScene = load("res://scenes/player.tscn") as PackedScene
	if player_scene:
		var temp: Node = player_scene.instantiate()
		var body_model: Node = temp.get_node_or_null("BodyModel")
		if body_model:
			gib_warm_tree_sync(body_model, GIB_CHUNK_COUNT)
		temp.free()
	# Bots swap HeadBlob to a box — warm that mesh too.
	var bot_head := BoxMesh.new()
	bot_head.size = Vector3(0.78, 0.78, 0.78)
	gib_warm_sync(bot_head, GIB_CHUNK_COUNT)


# Force the GPU to compile `mat`'s render pipeline (PSO) now, during a quiet
# window (round start), instead of synchronously on the material's first
# in-fight draw — that first draw stalls the render thread for ~100-250ms.
# Renders the material on a sub-pixel sphere at the scene origin for a few
# frames, then self-frees. Mirrors grenade.gd's warmup_shaders; the per-effect
# warmers (warmup_blast_materials, IonCannon.warmup_shaders,
# Player.warmup_phoenix_shaders) build their real materials and route them here.
static func warmup_material(scene: Node, mat: Material) -> void:
	if scene == null or mat == null:
		return
	var mi := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 1.0
	mi.mesh = sphere
	mi.material_override = mat
	# Park at the origin so it's actually rendered (compiles the PSO).
	# Big enough to not be frustum-culled, but far below the arena floor
	# so it's invisible to the player.
	_attach_world_3d(scene, mi, Vector3.ZERO)
	var t := Timer.new()
	t.wait_time = 0.4
	t.one_shot = true
	t.process_mode = Node.PROCESS_MODE_ALWAYS
	mi.add_child(t)
	t.start()
	t.timeout.connect(mi.queue_free)


# Pre-compile blast VFX materials. Screen-space heat/shock shaders are warmed
# separately by grenade.warmup_shaders().
static func warmup_blast_materials(scene: Node) -> void:
	if scene == null:
		return
	# Fused fire/smoke billow runs on a MultiMesh — instanced rendering is its own
	# PSO, so warm it with an actual (sub-pixel) MultiMesh, not a plain mesh.
	var billow := ShaderMaterial.new()
	billow.shader = _get_billow_mm_shader()
	billow.set_shader_parameter("anim", 0.3)
	billow.set_shader_parameter("sky_mode", 1.0)
	_warmup_mm_material(scene, billow)
	# Additive MultiMesh projectile shader (embers + shards) — its own PSO.
	var proj := ShaderMaterial.new()
	proj.shader = _get_blast_projectile_shader()
	proj.set_shader_parameter("anim", 0.3)
	_warmup_mm_material(scene, proj)
	# Screen-space heat-shimmer + shockwave (hint_screen_texture) — only big
	# blasts use them, but the back-buffer-reading PSO is pricey to compile, so
	# warm it with sub-pixel (invisible) instances so the first airstrike is smooth.
	spawn_heat_distortion(scene, Vector3.ZERO, 0.005, 0.25, 0.01)
	# Run the full bullet-blast path once at sub-pixel scale so every lazily-built
	# effect mesh/resource (billows, flame shards, embers, blast lights) is cached
	# before the first real explosion — otherwise that first blast pays for them.
	# defer_heavy=false: menu warmup must not queue jobs on an arena that is freed
	# when the player clicks Versus (flush would cast a freed scene ref).
	spawn_bullet_blast(scene, Vector3.ZERO, 0.005, Color(1.0, 0.6, 0.3), null, false, false)


# Like warmup_material but compiles the instanced (MultiMesh) PSO variant.
static func _warmup_mm_material(scene: Node, mat: Material) -> void:
	if scene == null or mat == null:
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = _get_smoke_billow_mesh()
	mm.instance_count = 1
	mm.set_instance_transform(0, Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.001), Vector3.ZERO))
	mm.set_instance_color(0, Color(1, 1, 1, 0.5))
	mm.set_instance_custom_data(0, Color(0.5, 0.0, 0.5, 0.0))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	_attach_world_3d(scene, mmi, Vector3.ZERO)
	var t := Timer.new()
	t.wait_time = 0.4
	t.one_shot = true
	t.process_mode = Node.PROCESS_MODE_ALWAYS
	mmi.add_child(t)
	t.start()
	t.timeout.connect(mmi.queue_free)


static func warmup_rock_multimesh(scene: Node, mat: Material) -> void:
	if scene == null or mat == null:
		return
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	box.subdivide_width = 5
	box.subdivide_height = 5
	box.subdivide_depth = 5
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = box
	mm.instance_count = 1
	mm.set_instance_transform(0, Transform3D(Basis.IDENTITY.scaled(Vector3(2.0, 1.5, 2.0)), Vector3.ZERO))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	_attach_world_3d(scene, mmi, Vector3.ZERO)
	var t := Timer.new()
	t.wait_time = 0.4
	t.one_shot = true
	t.process_mode = Node.PROCESS_MODE_ALWAYS
	mmi.add_child(t)
	t.start()
	t.timeout.connect(mmi.queue_free)

# Spawn a throwaway player-body gib burst far below the arena during the
# loading screen so the first real overkill doesn't freeze. prewarm_disintegration_cache()
# already caches the Voronoi variant meshes, but the GPU side is still cold: the
# chunk render compiles two fresh PSOs (the body material as a double-sided
# CULL_DISABLED variant + the interior flesh material with vertex colors) and
# the render thread stalls ~100-250ms on first draw. This exercises that exact
# path — real meshes, real materials, real chunk geometry — so force_draw()
# compiles the PSOs while the overlay hides everything. burst_strength 0 keeps
# the chunks at the hidden origin; the 0.5s lifetime frees them right after.
static func warmup_gib_render(scene: Node) -> void:
	if scene == null:
		return
	var player_scene: PackedScene = load("res://scenes/player.tscn") as PackedScene
	if player_scene == null:
		return
	var temp: Node = player_scene.instantiate()
	# Far below the arena floor: invisible, and the chunks have nothing to
	# collide with while they live out their short warmup lifetime.
	var origin := Transform3D(Basis(), Vector3(0.0, -1000.0, 0.0))
	var body_model: Node = temp.get_node_or_null("BodyModel")
	if body_model:
		var meshes: Array[MeshInstance3D] = []
		collect_meshes(body_model, meshes)
		for src in meshes:
			if src.mesh == null:
				continue
			gib_explode(
				src.mesh, origin, scene, src.get_active_material(0),
				Vector3.ZERO, 0.0, GIB_CHUNK_COUNT, 0.5,
			)
	# Chunks duplicate their own material and build meshes from the cache, so
	# they don't reference temp's nodes — safe to free immediately.
	temp.free()
	# The knight (CharacterVisual) only builds once inside the tree, so the
	# temp player above never contains it — warm its meshes straight from the
	# model scene, or the first knight gib stalls on a synchronous Voronoi
	# bake plus a fresh chunk PSO.
	var knight_scene: PackedScene = load("res://assets/models/knight.fbx") as PackedScene
	if knight_scene:
		var knight: Node = knight_scene.instantiate()
		if knight:
			var kmeshes: Array[MeshInstance3D] = []
			collect_meshes(knight, kmeshes)
			for src in kmeshes:
				if src.mesh == null:
					continue
				gib_explode(
					src.mesh, origin, scene, src.get_active_material(0),
					Vector3.ZERO, 0.0, GIB_CHUNK_COUNT, 0.5,
				)
			knight.free()

static func _gib_warm_task(mesh: Mesh, chunk_count: int) -> void:
	var variants: Array = _gib_build_variants(mesh, chunk_count)
	_gib_cache_mutex.lock()
	_gib_cache[[mesh, chunk_count]] = variants
	_gib_cache_mutex.unlock()

static func _gib_collect_meshes(node: Node, out: Array[Mesh]) -> void:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		var m: Mesh = (node as MeshInstance3D).mesh
		if not out.has(m):
			out.append(m)
	for child in node.get_children():
		_gib_collect_meshes(child, out)

# Grab (or synchronously build) the variants for this mesh+chunk_count.
# The synchronous fallback fires only if `gib_warm()` wasn't called in time —
# a first-kill hitch rather than a per-kill hitch.
static func _gib_get_variants(mesh: Mesh, chunk_count: int) -> Array:
	var key: Array = [mesh, chunk_count]
	_gib_cache_mutex.lock()
	var cached: Variant = _gib_cache.get(key)
	_gib_cache_mutex.unlock()
	if cached is Array:
		return cached
	var variants: Array = _gib_build_variants(mesh, chunk_count)
	_gib_cache_mutex.lock()
	var latest: Variant = _gib_cache.get(key)
	if latest is Array:
		variants = latest  # another thread raced us — prefer its result
	else:
		_gib_cache[key] = variants
	_gib_cache_mutex.unlock()
	return variants

static func gib_explode(
	mesh: Mesh,
	source_transform: Transform3D,
	scene: Node,
	material: Material,
	base_velocity: Vector3,
	burst_strength: float = 3.0,
	chunk_count: int = 4,
	lifetime: float = 12.0,
	force_origin_global: Vector3 = Vector3.INF,
	impact_blood_strength: float = 0.0,
) -> Array[RigidBody3D]:
	var out: Array[RigidBody3D] = []
	if mesh == null or scene == null:
		return out
	# Bucketed separately from death_gibs: a non-zero gib_bake means the
	# Voronoi cache MISSED and we baked synchronously mid-death — i.e. this
	# mesh was never warmed (or was regenerated after its warm).
	var _tv := Time.get_ticks_usec() if Trace.enabled else 0
	var variants: Array = _gib_get_variants(mesh, chunk_count)
	if Trace.enabled:
		Trace.prof("gib_bake", Time.get_ticks_usec() - _tv)
	if variants.is_empty():
		return out
	var chunks: Array = variants.pick_random()
	if chunks.is_empty():
		return out

	# Make the caller's material double-sided so open triangles don't disappear.
	var chunk_material: Material = material
	if material is StandardMaterial3D:
		var dup: StandardMaterial3D = (material as StandardMaterial3D).duplicate()
		dup.cull_mode = BaseMaterial3D.CULL_DISABLED
		chunk_material = dup
	var flesh_material: StandardMaterial3D = _gib_get_flesh_material()

	var body_basis: Basis = source_transform.basis.orthonormalized()
	for chunk in chunks:
		var rb: RigidBody3D = _gib_instantiate_chunk(
			chunk, chunk_material, flesh_material,
			source_transform, body_basis, scene,
			base_velocity, burst_strength, force_origin_global, impact_blood_strength,
		)
		if rb == null:
			continue
		# Bind the body's own queue_free: an early free (round reset clears the
		# world) auto-disconnects the connection instead of invoking a lambda
		# whose captured `rb` was already freed ("Lambda capture was freed").
		scene.get_tree().create_timer(lifetime).timeout.connect(rb.queue_free)
		out.append(rb)
	return out

static func _gib_instantiate_chunk(
	chunk: Dictionary,
	chunk_material: Material,
	flesh_material: StandardMaterial3D,
	source_transform: Transform3D,
	body_basis: Basis,
	scene: Node,
	base_velocity: Vector3,
	burst_strength: float,
	force_origin_global: Vector3,
	impact_blood_strength: float,
) -> RigidBody3D:
	var verts: PackedVector3Array = chunk["verts"]
	if verts.is_empty():
		return null

	var has_cap: bool = not (chunk["cap_verts"] as PackedVector3Array).is_empty()
	# Build the ArrayMesh ONCE per cached variant chunk and reuse it for every
	# later death — rebuilding from raw arrays per kill (two surface uploads
	# per chunk, x chunks x body meshes) was a measured slice of the
	# death-frame spike. Materials stay per-instance via surface overrides.
	var chunk_mesh: ArrayMesh = chunk.get("built_mesh")
	if chunk_mesh == null:
		chunk_mesh = ArrayMesh.new()
		var shell: Array = []
		shell.resize(Mesh.ARRAY_MAX)
		shell[Mesh.ARRAY_VERTEX] = verts
		var norms: PackedVector3Array = chunk["norms"]
		if norms.size() == verts.size():
			shell[Mesh.ARRAY_NORMAL] = norms
		var uvs: PackedVector2Array = chunk["uvs"]
		if uvs.size() == verts.size():
			shell[Mesh.ARRAY_TEX_UV] = uvs
		shell[Mesh.ARRAY_INDEX] = chunk["indices"]
		chunk_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, shell)
		if has_cap:
			var cap: Array = []
			cap.resize(Mesh.ARRAY_MAX)
			cap[Mesh.ARRAY_VERTEX] = chunk["cap_verts"]
			cap[Mesh.ARRAY_COLOR] = chunk["cap_colors"]
			cap[Mesh.ARRAY_INDEX] = chunk["cap_indices"]
			chunk_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, cap)
		chunk["built_mesh"] = chunk_mesh

	var centroid_src: Vector3 = chunk["centroid"]
	var chunk_aabb: AABB = chunk["aabb"]

	# Non-uniform warp from the source body (SLENDERMAN, FLATFISH, …). The
	# chunk geometry is cached in unwarped source-local space, so we apply the
	# warp visually on the MeshInstance3D and to the collision box. The rigid
	# body itself stays orthonormal so physics behaves cleanly.
	var warp: Vector3 = source_transform.basis.get_scale()

	var rb: RigidBody3D = RigidBody3D.new()
	rb.add_to_group("gib_chunks")
	rb.collision_layer = 0
	rb.collision_mask = 1
	rb.gravity_scale = 1.0
	rb.contact_monitor = true
	rb.max_contacts_reported = 1
	scene.add_child(rb)
	rb.global_transform = Transform3D(body_basis, source_transform * centroid_src)

	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = chunk_mesh
	mi.scale = warp
	if chunk_material:
		mi.set_surface_override_material(0, chunk_material)
	if has_cap and flesh_material:
		mi.set_surface_override_material(1, flesh_material)
	rb.add_child(mi)

	var cs: CollisionShape3D = CollisionShape3D.new()
	var box_shape: BoxShape3D = BoxShape3D.new()
	var sz: Vector3 = chunk_aabb.size * warp
	box_shape.size = Vector3(maxf(sz.x, 0.05), maxf(sz.y, 0.05), maxf(sz.z, 0.05))
	cs.shape = box_shape
	cs.position = (chunk_aabb.position + chunk_aabb.size * 0.5) * warp
	rb.add_child(cs)

	# If a force origin is provided (bullet hit point / explosion center),
	# burst away from that point; otherwise fall back to body-center fan-out.
	var centroid_global: Vector3 = source_transform * centroid_src
	var burst_dir: Vector3
	if force_origin_global != Vector3.INF:
		burst_dir = centroid_global - force_origin_global
		if burst_dir.length_squared() < 0.0001:
			burst_dir = body_basis * centroid_src
	else:
		burst_dir = body_basis * centroid_src
	if burst_dir.length_squared() < 0.0001:
		burst_dir = Vector3(randf_range(-1.0, 1.0), 1.0, randf_range(-1.0, 1.0))
	burst_dir = burst_dir.normalized()
	rb.linear_velocity = base_velocity \
		+ burst_dir * burst_strength \
		+ Vector3.UP * burst_strength * 0.2
	rb.angular_velocity = Vector3(
		randf_range(-10.0, 10.0),
		randf_range(-10.0, 10.0),
		randf_range(-10.0, 10.0),
	)
	rb.body_entered.connect(func(_body: Node) -> void:
		_gib_on_chunk_body_entered(rb, scene, impact_blood_strength)
	)
	_gib_enroll_chunk(rb)
	return rb

# Single rigid body containing every supplied mesh — used for non-explosive
# deaths so the corpse tumbles as one piece. `pivot_xform` is the world
# transform the body spawns at; child meshes get cloned into it preserving
# their position relative to the pivot. Collision is one BoxShape3D sized
# to the union AABB of all meshes — coarse but cheap and shape-stable.
static func gib_body_ragdoll(
	pivot_xform: Transform3D,
	meshes: Array,
	scene: Node,
	base_velocity: Vector3,
	spin: float = 4.0,
	lifetime: float = 14.0,
) -> RigidBody3D:
	if scene == null or meshes.is_empty():
		return null
	var rb := RigidBody3D.new()
	# Layer 2 + "corpses" group so bullets can still hit a downed body — the
	# corpse accumulates damage and disintegrates at CORPSE_DISINTEGRATE_DMG.
	rb.collision_layer = 2
	rb.collision_mask = 1
	rb.gravity_scale = 1.0
	rb.add_to_group("corpses")
	rb.set_meta("dmg_taken", 0.0)
	scene.add_child(rb)
	# Keep the rigid body itself orthonormal (physics doesn't like non-uniform
	# scale on bodies), but bake any pivot warp INTO the cloned mesh transforms
	# below. That way SLENDERMAN / FLATFISH ragdolls keep the same shape.
	var rb_xform := Transform3D(pivot_xform.basis.orthonormalized(), pivot_xform.origin)
	rb.global_transform = rb_xform

	var inv := rb_xform.affine_inverse()
	var union: AABB = AABB()
	var union_init := false
	for src: MeshInstance3D in meshes:
		if src.mesh == null:
			continue
		# Skip meshes that aren't actually rendered — lets the caller toggle
		# state-based visuals (e.g. squinty hit eyes) before snapshotting.
		if not src.is_visible_in_tree():
			continue
		var local_xform: Transform3D = inv * src.global_transform
		var mi := MeshInstance3D.new()
		mi.mesh = src.mesh
		if src.material_override:
			mi.material_override = src.material_override
		mi.transform = local_xform
		rb.add_child(mi)
		var aabb_local: AABB = local_xform * src.mesh.get_aabb()
		if union_init:
			union = union.merge(aabb_local)
		else:
			union = aabb_local
			union_init = true

	if union_init:
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(maxf(union.size.x, 0.1), maxf(union.size.y, 0.1), maxf(union.size.z, 0.1))
		cs.shape = box
		cs.position = union.position + union.size * 0.5
		rb.add_child(cs)

	rb.linear_velocity = base_velocity
	rb.angular_velocity = Vector3(
		randf_range(-spin, spin),
		randf_range(-spin, spin),
		randf_range(-spin, spin),
	)
	# Bind the body's own queue_free so an early free auto-disconnects instead
	# of erroring on a freed lambda capture (see other cleanup sites).
	scene.get_tree().create_timer(lifetime).timeout.connect(rb.queue_free)
	return rb


# Extra flying blood/meat spheres on top of Voronoi body chunks — reads
# gory even when the source mesh is a smooth blob.
static func spawn_blood_gib_blobs(
	scene: Node,
	origin: Vector3,
	dir: Vector3,
	intensity: float,
	chaos: float,
	base_velocity: Vector3,
	burst_strength: float,
	force_origin: Vector3,
	impact_blood_strength: float,
	lifetime: float = 12.0,
) -> Array[RigidBody3D]:
	var out: Array[RigidBody3D] = []
	if scene == null:
		return out
	var dir_n := dir.normalized() if dir.length_squared() > 0.001 else Vector3.UP
	var sev := clampf(intensity, 0.35, 2.8)
	var blob_count := clampi(int(round(lerpf(5.0, 20.0, sev / 2.5) + chaos * 6.0)), 4, 24)
	for i in blob_count:
		var radius := randf_range(0.035, 0.13) * lerpf(0.85, 1.55, sev / 2.5)
		var rb := RigidBody3D.new()
		rb.add_to_group("gib_chunks")
		rb.collision_layer = 0
		rb.collision_mask = 1
		rb.gravity_scale = 1.0
		rb.contact_monitor = true
		rb.max_contacts_reported = 1
		scene.add_child(rb)
		rb.global_position = origin + Vector3(
			randf_range(-0.35, 0.35),
			randf_range(-0.15, 0.45),
			randf_range(-0.35, 0.35),
		)
		var mi := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = radius
		sm.height = radius * 2.0
		sm.radial_segments = 5
		sm.rings = 3
		mi.mesh = sm
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		if randf() < 0.38:
			mat.albedo_color = _gib_flesh_color()
		else:
			mat.albedo_color = Color(randf_range(0.16, 0.34), 0.018, 0.012, 1.0)
		mat.emission_enabled = true
		mat.emission = Color(0.38, 0.02, 0.015)
		mat.emission_energy_multiplier = 0.07
		mi.material_override = mat
		mi.scale = Vector3(
			randf_range(0.75, 1.25),
			randf_range(0.65, 1.05),
			randf_range(0.75, 1.25),
		)
		rb.add_child(mi)
		var cs := CollisionShape3D.new()
		var shape := SphereShape3D.new()
		shape.radius = radius
		cs.shape = shape
		rb.add_child(cs)
		var burst_dir := rb.global_position - (force_origin if force_origin != Vector3.INF else origin)
		if burst_dir.length_squared() < 0.0001:
			burst_dir = dir_n + Vector3(
				randf_range(-0.7, 0.7),
				randf_range(0.15, 0.85),
				randf_range(-0.7, 0.7),
			)
		burst_dir = burst_dir.normalized()
		var burst := burst_strength * randf_range(0.85, 1.35) * (1.0 + chaos * 0.22)
		rb.linear_velocity = base_velocity + burst_dir * burst + Vector3.UP * burst * randf_range(0.15, 0.35)
		rb.angular_velocity = Vector3(
			randf_range(-14.0, 14.0),
			randf_range(-14.0, 14.0),
			randf_range(-14.0, 14.0),
		)
		rb.body_entered.connect(func(_body: Node) -> void:
			_gib_on_chunk_body_entered(rb, scene, impact_blood_strength)
		)
		# Bind the body's own queue_free: an early free (round reset clears the
		# world) auto-disconnects the connection instead of invoking a lambda
		# whose captured `rb` was already freed ("Lambda capture was freed").
		scene.get_tree().create_timer(lifetime).timeout.connect(rb.queue_free)
		out.append(rb)
	return out


static func spawn_disintegrate_gore(
	scene: Node,
	pos: Vector3,
	dir: Vector3,
	intensity: float,
	chaos: float = 0.0,
	base_velocity: Vector3 = Vector3.ZERO,
	burst_strength: float = 3.0,
	force_origin: Vector3 = Vector3.INF,
	impact_blood_strength: float = 0.6,
	skip_mist: bool = false,
) -> Array[RigidBody3D]:
	if scene == null:
		return []
	var dir_n := dir.normalized() if dir.length_squared() > 0.001 else Vector3.UP
	var sev := clampf(intensity, 0.35, 2.8)
	if not skip_mist:
		spawn_gib_mist(scene, pos, dir_n, sev * 2.4, 0.0, sev * 0.52 + chaos * 0.28)
		spawn_blood(scene, pos, dir_n, sev * 1.6, 16)
		spawn_blast_blood_splash(scene, pos, dir_n, clampf(sev * 0.78, 0.4, 1.0))
		_spawn_headshot_puffs(scene, pos, dir_n, sev, true)
	return spawn_blood_gib_blobs(
		scene, pos, dir_n, sev, chaos, base_velocity, burst_strength,
		force_origin, impact_blood_strength,
	)


# Cumulative damage at which a still-intact corpse falls apart into chunks.
const CORPSE_DISINTEGRATE_DMG := 50.0

# Bullet hit a non-disintegrated ragdoll body. Sprays blood on the wound,
# accumulates damage, and disintegrates the corpse once the running total
# crosses the threshold. Cosmetic-only — runs independently on each peer
# (the ragdoll itself was already a per-peer simulation).
static func hit_corpse(rb: RigidBody3D, hit_pos: Vector3, dir: Vector3, dmg: float) -> void:
	if rb == null or not is_instance_valid(rb):
		return
	var scene: Node = rb.get_tree().current_scene
	if scene == null:
		return
	# Squirt of blood at the wound + a faint mist behind so the impact reads
	# from any angle.
	spawn_blood(scene, hit_pos, dir, 0.7)
	var splash_dir: Vector3 = dir.normalized() if dir.length_squared() > 0.001 else Vector3.UP
	_gib_spawn_blood_splat(scene, hit_pos, -splash_dir, splash_dir, 0.5)
	# Push the body slightly so heavy rounds visibly shove the corpse —
	# positioned at the wound so it tumbles rather than translating.
	rb.apply_impulse(splash_dir * clampf(dmg * 0.05, 0.5, 4.0), hit_pos - rb.global_position)
	var taken: float = float(rb.get_meta("dmg_taken", 0.0)) + dmg
	rb.set_meta("dmg_taken", taken)
	if taken >= CORPSE_DISINTEGRATE_DMG:
		disintegrate_corpse(rb, splash_dir)

# Voronoi-shatter every mesh of an intact ragdoll body and free the body.
# Carries the rigid body's current velocity into the chunks so the burst
# continues whatever motion the corpse already had.
static func disintegrate_corpse(rb: RigidBody3D, push_dir: Vector3 = Vector3.ZERO) -> void:
	if rb == null or not is_instance_valid(rb):
		return
	_free_ragdoll_blood_wounds(rb)
	var scene: Node = rb.get_tree().current_scene
	if scene == null:
		return
	var carry: Vector3 = rb.linear_velocity + push_dir.normalized() * 4.0
	var origin: Vector3 = rb.global_position
	var push_n := push_dir.normalized() if push_dir.length_squared() > 0.001 else carry.normalized()
	spawn_disintegrate_gore(
		scene,
		origin,
		push_n,
		0.9,
		0.25,
		carry,
		3.0,
		origin,
		0.55,
	)
	for child in rb.get_children():
		if not (child is MeshInstance3D):
			continue
		var mi := child as MeshInstance3D
		if mi.mesh == null or not mi.is_visible_in_tree():
			continue
		gib_explode(
			mi.mesh,
			mi.global_transform,
			scene,
			mi.material_override,
			carry + Vector3(randf_range(-1.0, 1.0), randf_range(0.4, 1.4), randf_range(-1.0, 1.0)),
			3.2,
			GIB_CHUNK_COUNT,
			14.0,
			rb.global_position,
			0.6,
		)
	rb.queue_free()


# ---------------------------------------------------------------------------
# Knight soft ragdoll (skinned CharacterVisual corpses)
#
# The blob corpse clones its primitive meshes onto ONE rigid body — fine for
# a blob, but a humanoid handled that way tumbles as a hard T-pose statue.
# The knight instead gets real per-limb physics: clone the model, copy the
# death pose onto the clone's skeleton, generate capsule PhysicalBone3D
# bodies for the major Mixamo bones and let a PhysicalBoneSimulator3D run.
# Pin joints (no angular limits) plus angular damping read as floppy and are
# stable without per-joint tuning. Bones sit on layer 2 in the "corpses"
# group so bullets keep hitting downed bodies — hit_corpse_any pools limb
# damage on the corpse root and Voronoi-shatters it at the same
# CORPSE_DISINTEGRATE_DMG threshold as blob corpses.
#
# Each corpse is ~11 physical bodies (vs 1 for the blob torso), so the FIFO
# cap is tight; settled bodies sleep, and round reset frees the "corpses"
# group as before (the root node joins the group).

const _KNIGHT_RAGDOLL_BONES: Array = [
	# [bone, descendant bone giving the capsule its length, radius, mass]
	["Hips", "Spine", 0.13, 8.0],
	["Spine1", "Neck", 0.12, 6.0],
	["Head", "", 0.10, 3.0],
	["LeftArm", "LeftForeArm", 0.055, 1.6],
	["LeftForeArm", "LeftHand", 0.05, 1.2],
	["RightArm", "RightForeArm", 0.055, 1.6],
	["RightForeArm", "RightHand", 0.05, 1.2],
	["LeftUpLeg", "LeftLeg", 0.08, 3.5],
	["LeftLeg", "LeftFoot", 0.06, 2.0],
	["RightUpLeg", "RightLeg", 0.08, 3.5],
	["RightLeg", "RightFoot", 0.06, 2.0],
]
const MAX_KNIGHT_RAGDOLLS := 4
static var _knight_ragdolls: Array[Node3D] = []


# Returns the hips PhysicalBone3D (death-cam target) or null. The corpse root
# is in the hips' "knight_corpse_root" meta.
static func spawn_knight_ragdoll(
	knight: CharacterVisual,
	scene: Node,
	base_velocity: Vector3,
	push_dir: Vector3,
	is_head: bool,
	hit_pos: Vector3 = Vector3.INF,
	lifetime: float = 14.0,
) -> PhysicalBone3D:
	if knight == null or scene == null:
		return null
	var src_model: Node3D = knight._model
	var src_skel: Skeleton3D = knight._skeleton
	if src_model == null or src_skel == null:
		return null
	# Clone the SAME variant the dead player wore, not a hardcoded knight.
	var model := knight.get_model_scene().instantiate() as Node3D
	if model == null:
		return null
	var root := Node3D.new()
	root.name = "KnightCorpse"
	root.add_to_group("corpses")  # round reset frees the whole corpse
	root.set_meta("dmg_taken", 0.0)
	scene.add_child(root)
	root.add_child(model)
	model.global_transform = src_model.global_transform
	var skel := model.find_child("Skeleton3D", true, false) as Skeleton3D
	if skel == null:
		root.queue_free()
		return null
	# Freeze the death pose onto the clone (same asset — same bone indices).
	for i: int in src_skel.get_bone_count():
		skel.set_bone_pose_position(i, src_skel.get_bone_pose_position(i))
		skel.set_bone_pose_rotation(i, src_skel.get_bone_pose_rotation(i))
		skel.set_bone_pose_scale(i, src_skel.get_bone_pose_scale(i))
	var sim := PhysicalBoneSimulator3D.new()
	skel.add_child(sim)
	var hips: PhysicalBone3D = null
	var head_pb: PhysicalBone3D = null
	var pbs: Array[PhysicalBone3D] = []
	for spec: Array in _KNIGHT_RAGDOLL_BONES:
		var idx: int = CharacterVisual.find_bone_any(skel, str(spec[0]))
		if idx < 0:
			continue
		var bone_pose: Transform3D = skel.get_bone_global_pose(idx)
		# Capsule runs from the bone toward the named descendant (bone-local
		# space). Head has no target: give it a stub straight up the bone.
		var v := Vector3(0.0, 0.2, 0.0)
		if str(spec[1]) != "":
			var cidx: int = CharacterVisual.find_bone_any(skel, str(spec[1]))
			if cidx < 0:
				continue
			v = bone_pose.affine_inverse() * skel.get_bone_global_pose(cidx).origin
		var length: float = maxf(v.length(), 0.12)
		var up := Vector3.UP if absf(v.normalized().dot(Vector3.UP)) < 0.98 else Vector3.RIGHT
		# Same recipe as the editor's "Create Physical Skeleton": the body
		# offset looks down -Z at the child bone with the capsule midway.
		var off := Transform3D(Basis.looking_at(v, up), Vector3.ZERO)
		off.origin = off.basis * Vector3(0.0, 0.0, -length * 0.5)
		var pb := PhysicalBone3D.new()
		pb.name = "PB_%s" % str(spec[0])
		pb.bone_name = skel.get_bone_name(idx)  # actual (possibly prefixed) name
		pb.mass = float(spec[3])
		pb.joint_type = PhysicalBone3D.JOINT_TYPE_PIN
		pb.angular_damp = 2.0
		# World-only collisions (mask 1, bones don't see each other); layer 2
		# keeps the corpse shootable.
		pb.collision_layer = 2
		pb.collision_mask = 1
		pb.add_to_group("corpses")
		pb.set_meta("knight_corpse_root", root)
		pb.body_offset = off
		pb.joint_offset = Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, length * 0.5))
		var cs := CollisionShape3D.new()
		var cap := CapsuleShape3D.new()
		cap.radius = float(spec[2])
		cap.height = maxf(length, float(spec[2]) * 2.0 + 0.02)
		cs.shape = cap
		# Capsule axis (local Y) onto the body's Z, which points at the child.
		cs.transform = Transform3D(
			Basis(Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(0, -1, 0)), Vector3.ZERO)
		pb.add_child(cs)
		sim.add_child(pb)
		pbs.append(pb)
		if str(spec[0]) == "Hips":
			hips = pb
		elif str(spec[0]) == "Head":
			head_pb = pb
	if hips == null:
		root.queue_free()
		return null
	root.set_meta("hips_pb", hips)
	sim.physical_bones_start_simulation()
	# Kill impulse. A uniform velocity on every bone read as the whole statue
	# sliding backward; instead, most of the momentum lands as a POSITIONED
	# impulse concentrated on the bones nearest the bullet hole, so the body
	# folds and spins around the wound and only drifts with the remainder.
	var drift_frac: float = 0.35 if hit_pos != Vector3.INF else 1.0
	for pb in pbs:
		pb.apply_central_impulse(base_velocity * pb.mass * drift_frac)
	if hit_pos != Vector3.INF:
		var total_mass: float = 0.0
		for pb in pbs:
			total_mass += pb.mass
		# ~30 cm falloff: the struck limb takes the brunt, its neighbours a
		# shove, the far side of the body almost nothing.
		var weights: Array[float] = []
		var wsum: float = 0.0
		for pb in pbs:
			var d: float = hit_pos.distance_to(pb.global_position)
			var w: float = 1.0 / (1.0 + (d / 0.3) * (d / 0.3))
			weights.append(w)
			wsum += w
		var speed: float = maxf(base_velocity.length(), 0.001)
		var kick_dir: Vector3 = base_velocity / speed
		var point_momentum: float = speed * total_mass * (1.0 - drift_frac)
		for i in pbs.size():
			var pb := pbs[i]
			# Cap the resulting bone velocity so a hand hit whips hard
			# without launching the forearm into orbit.
			var j: float = minf(point_momentum * weights[i] / wsum, pb.mass * speed * 4.0)
			var at: Vector3 = hit_pos - pb.global_position
			if at.length() > 0.35:
				at = at.normalized() * 0.35
			pb.apply_impulse(kick_dir * j, at)
	if is_head and head_pb:
		head_pb.apply_central_impulse((push_dir + Vector3.UP * 0.6) * head_pb.mass * 5.0)
	scene.get_tree().create_timer(lifetime).timeout.connect(root.queue_free)
	_knight_ragdolls.append(root)
	root.tree_exiting.connect(func() -> void: _knight_ragdolls.erase(root))
	while _knight_ragdolls.size() > MAX_KNIGHT_RAGDOLLS:
		var old: Node3D = _knight_ragdolls.pop_front()
		if is_instance_valid(old):
			old.queue_free()
	return hips


# Corpse-hit dispatch: blob torsos are RigidBody3D, knight limbs are
# PhysicalBone3D. Keeps bullet.gd agnostic of corpse anatomy.
static func hit_corpse_any(body: Node, hit_pos: Vector3, dir: Vector3, dmg: float) -> void:
	if body is RigidBody3D:
		hit_corpse(body as RigidBody3D, hit_pos, dir, dmg)
		return
	if not (body is PhysicalBone3D) or not is_instance_valid(body):
		return
	var pb := body as PhysicalBone3D
	var scene: Node = pb.get_tree().current_scene
	if scene == null:
		return
	spawn_blood(scene, hit_pos, dir, 0.7)
	var splash_dir: Vector3 = dir.normalized() if dir.length_squared() > 0.001 else Vector3.UP
	_gib_spawn_blood_splat(scene, hit_pos, -splash_dir, splash_dir, 0.5)
	# Positioned impulse at the bullet hole so the limb twists around the
	# hit instead of the whole bone translating.
	pb.apply_impulse(splash_dir * clampf(dmg * 0.05, 0.5, 4.0), hit_pos - pb.global_position)
	var root := pb.get_meta("knight_corpse_root", null) as Node3D
	if root == null or not is_instance_valid(root):
		return
	# Shots into the downed body stain the limb they hit, same as live hits.
	var skel := root.find_child("Skeleton3D", true, false) as Skeleton3D
	if skel != null:
		var att := _bone_wound_attachment(skel, pb.bone_name)
		for b in _spawn_player_blood_cluster(att, hit_pos, -splash_dir, 0.6, 2):
			_fit_knight_wound_blob(b as MeshInstance3D, att)
	var taken: float = float(root.get_meta("dmg_taken", 0.0)) + dmg
	root.set_meta("dmg_taken", taken)
	if taken >= CORPSE_DISINTEGRATE_DMG:
		disintegrate_knight_corpse(root, splash_dir)


# Voronoi-shatter the knight corpse and free it. Chunks come from the bind-
# pose meshes (same cached variants as death disintegration).
static func disintegrate_knight_corpse(root: Node3D, push_dir: Vector3) -> void:
	if root == null or not is_instance_valid(root):
		return
	var scene: Node = root.get_tree().current_scene
	if scene == null:
		return
	var origin: Vector3 = root.global_position
	var hips := root.get_meta("hips_pb", null) as Node3D
	if hips != null and is_instance_valid(hips):
		origin = hips.global_position
	var push_n := push_dir.normalized() if push_dir.length_squared() > 0.001 else Vector3.UP
	spawn_disintegrate_gore(scene, origin, push_n, 0.9, 0.25, push_n * 4.0, 3.0, origin, 0.55)
	var meshes: Array[MeshInstance3D] = []
	collect_meshes(root, meshes)
	for mi in meshes:
		if mi.mesh == null:
			continue
		gib_explode(
			mi.mesh,
			mi.global_transform,
			scene,
			mi.get_active_material(0),
			push_n * 4.0 + Vector3(randf_range(-1.0, 1.0), randf_range(0.6, 1.6), randf_range(-1.0, 1.0)),
			3.2,
			KNIGHT_GIB_CHUNK_COUNT,
			14.0,
			origin,
			0.6,
		)
	root.queue_free()


static func _gib_on_chunk_body_entered(rb: RigidBody3D, scene: Node, strength: float) -> void:
	if rb == null or scene == null or not is_instance_valid(rb):
		return
	if rb.get_meta("blood_splatted", false):
		return
	rb.set_meta("blood_splatted", true)
	if strength <= 0.01:
		return
	var vel: Vector3 = rb.linear_velocity
	if vel.length_squared() < 0.01:
		vel = -rb.global_transform.basis.z
	var dir := vel.normalized()
	var start := rb.global_position + dir * 0.18
	var finish := rb.global_position - dir * 0.45
	var q := PhysicsRayQueryParameters3D.create(start, finish)
	q.collision_mask = 1
	var hit := rb.get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return
	_gib_spawn_blood_splat(scene, hit.position, hit.normal, dir, strength)

static func _gib_spawn_blood_splat(
	scene: Node,
	pos: Vector3,
	normal: Vector3,
	travel_dir: Vector3,
	strength: float,
) -> MeshInstance3D:
	if scene == null:
		return null
	var up := normal.normalized() if normal.length_squared() > 0.001 else Vector3.UP
	var sev := maxf(strength, 0.0)
	var count := clampi(int(round(lerpf(2.0, 8.0, clampf(sev / 2.5, 0.0, 1.0)))), 2, 10)
	var first: MeshInstance3D = null
	for i in count:
		var blob := _spawn_env_blood_stain(scene, pos, up, travel_dir, sev)
		if blob and first == null:
			first = blob
	return first


static func _spawn_env_blood_stain(
	scene: Node,
	pos: Vector3,
	normal: Vector3,
	travel_dir: Vector3,
	strength: float,
) -> MeshInstance3D:
	var up := normal.normalized()
	var tangent := travel_dir.slide(up).normalized()
	if tangent.length_squared() < 0.001:
		tangent = up.cross(Vector3.RIGHT).normalized()
		if tangent.length_squared() < 0.001:
			tangent = Vector3.FORWARD
	var blob := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	var sev := maxf(strength, 0.0)
	var size_mult := lerpf(0.9, 2.15, clampf(sev / 2.5, 0.0, 1.0))
	var radius := randf_range(0.055, 0.15) * size_mult
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 6
	mesh.rings = 4
	blob.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(randf_range(0.18, 0.34), 0.016, 0.01, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(0.32, 0.02, 0.015)
	mat.emission_energy_multiplier = 0.06
	blob.material_override = mat
	blob.add_to_group("blood_splats")
	scene.add_child(blob)
	_enroll_blood_splat(blob)
	blob.global_position = pos + up * 0.015 + tangent * randf_range(-0.08, 0.08) * size_mult \
		+ up.cross(tangent).normalized() * randf_range(-0.08, 0.08) * size_mult
	blob.look_at(blob.global_position + up, tangent)
	# Squash into the surface so it reads as a smear, not a floating orb.
	var spread := lerpf(1.0, 1.65, clampf(sev / 2.5, 0.0, 1.0))
	blob.scale = Vector3(
		randf_range(0.95, 1.45) * spread,
		randf_range(0.95, 1.45) * spread,
		randf_range(0.22, 0.42),
	)
	return blob


static func clear_blood_splats_near(scene_root: Node, pos: Vector3, radius: float) -> void:
	if scene_root == null or radius <= 0.0 or not is_instance_valid(scene_root):
		return
	var r2 := radius * radius
	for n in scene_root.get_tree().get_nodes_in_group("blood_splats"):
		if n is Node3D and is_instance_valid(n):
			if (n as Node3D).global_position.distance_squared_to(pos) <= r2:
				(n as Node3D).queue_free()


const PLAYER_BLOOD_WOUND_MAX := 32
const MAX_BLOOD_SPLATS := 140
static var _blood_splat_fifo: Array[Node] = []


static func _max_blood_splats() -> int:
	return clampi(int(round(float(MAX_BLOOD_SPLATS) * vfx_quality_scale())), 36, MAX_BLOOD_SPLATS)


static func _enroll_blood_splat(blob: Node) -> void:
	if blob == null:
		return
	_blood_splat_fifo.append(blob)
	blob.tree_exiting.connect(func() -> void: _blood_splat_fifo.erase(blob))
	while _blood_splat_fifo.size() > _max_blood_splats():
		var old: Node = _blood_splat_fifo.pop_front()
		if is_instance_valid(old):
			old.queue_free()


static func _spawn_player_blood_blob(
	attach_to: Node3D,
	hit_pos: Vector3,
	normal: Vector3,
	strength: float,
) -> MeshInstance3D:
	if attach_to == null:
		return null
	var blob := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	var radius := randf_range(0.05, 0.1) * lerpf(0.95, 1.4, clampf(strength, 0.0, 1.2))
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 6
	mesh.rings = 4
	blob.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.render_priority = 2
	mat.albedo_color = Color(randf_range(0.2, 0.36), 0.018, 0.012, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(0.35, 0.02, 0.015)
	mat.emission_energy_multiplier = 0.12
	blob.material_override = mat
	blob.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	blob.add_to_group("player_blood_wounds")
	attach_to.add_child(blob)
	attach_to.move_child(blob, -1)

	var up := normal.normalized() if normal.length_squared() > 0.001 else Vector3.UP
	# Sit slightly proud of the skin — embedding caused z-fighting / clipping.
	blob.global_position = hit_pos + up * radius * randf_range(0.08, 0.22)
	blob.scale = Vector3(
		randf_range(0.88, 1.22),
		randf_range(0.78, 1.12),
		randf_range(0.88, 1.22),
	)
	return blob


static func _spawn_player_blood_cluster(
	attach: Node3D,
	center: Vector3,
	normal: Vector3,
	strength: float,
	count: int,
) -> Array:
	var out: Array = []
	if attach == null:
		return out
	var up := normal.normalized() if normal.length_squared() > 0.001 else Vector3.UP
	for i in count:
		var jitter := Vector3(
			randf_range(-0.06, 0.06),
			randf_range(-0.06, 0.06),
			randf_range(-0.06, 0.06),
		)
		var blob := _spawn_player_blood_blob(
			attach,
			center + jitter,
			normal,
			strength * randf_range(0.85, 1.05),
		)
		if blob:
			out.append(blob)
	return out


static func _append_ragdoll_blood_wounds(rb: RigidBody3D, wounds: Array) -> void:
	if rb == null or wounds.is_empty():
		return
	var existing: Array = rb.get_meta("blood_wounds") if rb.has_meta("blood_wounds") else []
	existing.append_array(wounds)
	rb.set_meta("blood_wounds", existing)


# Knight wounds ride the skeleton: pick the nearest major bone (same set the
# ragdoll uses) and parent the blobs to a reused BoneAttachment3D on it, so a
# shoulder hit stays on the shoulder through run/jump animations and pose.
static func _knight_wound_attach(knight: CharacterVisual, hit_pos: Vector3) -> BoneAttachment3D:
	var skel: Skeleton3D = knight._skeleton
	if skel == null:
		return null
	var best := ""
	var best_d := INF
	for spec: Array in _KNIGHT_RAGDOLL_BONES:
		var idx: int = CharacterVisual.find_bone_any(skel, str(spec[0]))
		if idx < 0:
			continue
		var p: Vector3 = skel.global_transform * skel.get_bone_global_pose(idx).origin
		var d := p.distance_squared_to(hit_pos)
		if d < best_d:
			best_d = d
			best = skel.get_bone_name(idx)
	if best == "":
		return null
	return _bone_wound_attachment(skel, best)


static func _bone_wound_attachment(skel: Skeleton3D, bone: String) -> BoneAttachment3D:
	var attach_name := "WoundAttach_%s" % bone
	var existing := skel.get_node_or_null(attach_name)
	if existing is BoneAttachment3D:
		return existing
	var att := BoneAttachment3D.new()
	att.name = attach_name
	att.bone_name = bone
	skel.add_child(att)
	return att


# Blobs under a BoneAttachment3D inherit the skeleton's world scale (FBX rigs
# are often not unit-scale); divide it back out so wounds render at the same
# world size as on the blob body. Tags the blob for corpse transfer.
static func _fit_knight_wound_blob(blob: MeshInstance3D, attach: BoneAttachment3D) -> void:
	if blob == null or attach == null:
		return
	var ps: Vector3 = attach.global_transform.basis.get_scale()
	blob.scale = Vector3(
		blob.scale.x / maxf(ps.x, 0.0001),
		blob.scale.y / maxf(ps.y, 0.0001),
		blob.scale.z / maxf(ps.z, 0.0001),
	)
	blob.set_meta("wound_bone", attach.bone_name)


# Re-create the live player's wounds on the ragdoll clone's skeleton (same
# asset — same bones, same scale, so the stored bone-local transforms map
# 1:1), then clear them off the soon-hidden live body.
static func _transfer_knight_wounds(player: Node, corpse_root: Node3D) -> void:
	if player == null or corpse_root == null or not is_instance_valid(corpse_root):
		return
	var wounds: Array = player.get("_blood_wounds")
	if wounds.is_empty():
		return
	var skel := corpse_root.find_child("Skeleton3D", true, false) as Skeleton3D
	if skel != null:
		for w in wounds:
			if not (w is MeshInstance3D) or not is_instance_valid(w):
				continue
			var blob := w as MeshInstance3D
			var bone: String = str(blob.get_meta("wound_bone", ""))
			if bone == "":
				continue
			var att := _bone_wound_attachment(skel, bone)
			var copy := blob.duplicate() as MeshInstance3D
			att.add_child(copy)
			copy.transform = blob.transform
	clear_player_blood_wounds(player)


static func _player_blood_attach_mesh(player: Node, collider: Node) -> Node3D:
	if collider != null and collider.is_in_group("player_head_hitboxes"):
		var head: Variant = player.get("head_blob")
		if head is Node3D:
			return head
	var core: Variant = player.get("blob_core")
	if core is Node3D:
		return core
	var body: Variant = player.get("body_model")
	if body is Node3D:
		return body
	return null


static func spawn_player_blood_wound(
	player: Node,
	collider: Node,
	hit_pos: Vector3,
	normal: Vector3,
	travel_dir: Vector3,
	strength: float,
) -> void:
	if player == null or hit_pos == Vector3.INF:
		return
	# Knight bodies get bone-attached wounds (they follow limb animation);
	# blob bodies keep the mesh-parented path.
	var bone_attach: BoneAttachment3D = null
	var knight := player.get("character_visual") as CharacterVisual
	if knight != null and knight.is_active():
		bone_attach = _knight_wound_attach(knight, hit_pos)
	var attach: Node3D = bone_attach
	if attach == null:
		attach = _player_blood_attach_mesh(player, collider)
	if attach == null:
		return
	var wounds: Array = player.get("_blood_wounds")
	while wounds.size() >= PLAYER_BLOOD_WOUND_MAX:
		var old: Variant = wounds.pop_front()
		if old is Node and is_instance_valid(old):
			(old as Node).queue_free()
	var count := clampi(int(round(lerpf(2.0, 4.0, clampf(strength, 0.0, 1.2)))), 2, 5)
	var up := normal.normalized() if normal.length_squared() > 0.001 else Vector3.UP
	var tangent := travel_dir.slide(up).normalized()
	if tangent.length_squared() < 0.001:
		tangent = up.cross(Vector3.RIGHT).normalized()
		if tangent.length_squared() < 0.001:
			tangent = Vector3.FORWARD
	for i in count:
		var jitter := tangent * randf_range(-0.05, 0.05) \
			+ up.cross(tangent).normalized() * randf_range(-0.05, 0.05) \
			+ up * randf_range(-0.025, 0.025)
		var blob := _spawn_player_blood_blob(
			attach,
			hit_pos + jitter,
			normal,
			strength * randf_range(0.82, 1.05),
		)
		if blob:
			if bone_attach != null:
				_fit_knight_wound_blob(blob, bone_attach)
			wounds.append(blob)
	player.set("_blood_wounds", wounds)


static func clear_player_blood_wounds(player: Node) -> void:
	if player == null:
		return
	var wounds: Array = player.get("_blood_wounds")
	for d in wounds:
		if d is Node and is_instance_valid(d):
			(d as Node).queue_free()
	wounds.clear()
	player.set("_blood_wounds", wounds)
	var body_model: Node = player.get("body_model")
	if body_model:
		_clear_group_under(body_model, "player_blood_wounds")


static func _clear_group_under(root: Node, group_name: String) -> void:
	for child in root.get_children():
		if child.is_in_group(group_name):
			child.queue_free()
		_clear_group_under(child, group_name)


static func transfer_player_blood_wounds(player: Node, attach_rb: Node3D) -> void:
	if player == null or attach_rb == null or not is_instance_valid(attach_rb):
		return
	var wounds: Array = player.get("_blood_wounds")
	var transferred: Array = []
	for d in wounds:
		if not (d is Node3D) or not is_instance_valid(d):
			continue
		(d as Node3D).reparent(attach_rb, true)
		transferred.append(d)
	wounds.clear()
	player.set("_blood_wounds", wounds)
	_append_ragdoll_blood_wounds(attach_rb, transferred)
	var body_model: Node = player.get("body_model")
	if body_model:
		_clear_group_under(body_model, "player_blood_wounds")


static func _free_ragdoll_blood_wounds(rb: RigidBody3D) -> void:
	if rb == null or not is_instance_valid(rb):
		return
	if rb.has_meta("blood_wounds"):
		for d in rb.get_meta("blood_wounds"):
			if d is Node and is_instance_valid(d):
				(d as Node).queue_free()
		rb.remove_meta("blood_wounds")
	for child in rb.get_children():
		if child.is_in_group("player_blood_wounds"):
			child.queue_free()

# -------------------- baking (thread-safe) --------------------

static func _gib_build_variants(mesh: Mesh, chunk_count: int) -> Array:
	# Big skinned meshes (character rigs, ~13k tris) get one layout — baking
	# is O(tris × seeds) and three variants of a whole body buys little: the
	# physics scatter is what reads as variety.
	var n: int = _GIB_VARIANTS_PER_MESH
	if mesh.get_surface_count() > 0:
		var arr: Array = mesh.surface_get_arrays(0)
		var idx: Variant = arr[Mesh.ARRAY_INDEX]
		if idx != null and (idx as PackedInt32Array).size() > 15000:  # ~5k tris
			n = 1
	var variants: Array = []
	for _i in n:
		variants.append(_gib_bake_one(mesh, chunk_count))
	return variants

static func _gib_bake_one(mesh: Mesh, chunk_count: int) -> Array:
	var out: Array = []
	if mesh == null or mesh.get_surface_count() == 0:
		return out
	var arrays: Array = mesh.surface_get_arrays(0)
	var src_verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	if src_verts.is_empty():
		return out
	var src_norms_raw: Variant = arrays[Mesh.ARRAY_NORMAL]
	var src_uvs_raw: Variant = arrays[Mesh.ARRAY_TEX_UV]
	var src_idx_raw: Variant = arrays[Mesh.ARRAY_INDEX]

	var src_norms: PackedVector3Array = src_norms_raw if src_norms_raw != null else PackedVector3Array()
	var src_uvs: PackedVector2Array = src_uvs_raw if src_uvs_raw != null else PackedVector2Array()
	var indices: PackedInt32Array
	if src_idx_raw == null:
		indices = PackedInt32Array()
		indices.resize(src_verts.size())
		for i in src_verts.size():
			indices[i] = i
	else:
		indices = src_idx_raw

	var tri_count: int = indices.size() / 3
	if tri_count < 2:
		return out

	var aabb: AABB = AABB(src_verts[0], Vector3.ZERO)
	for v in src_verts:
		aabb = aabb.expand(v)

	# Seed cells from random points ON the surface (triangle centroids), not
	# uniform points in the AABB: for spread-out shapes (humanoid in bind
	# pose) empty-corner seeds carved degenerate splits — one huge center
	# slab plus slivers. A few placement attempts keep seeds apart so cells
	# stay roughly even.
	var min_sep: float = aabb.get_longest_axis_size() * 0.12
	var seeds: Array[Vector3] = []
	for _i in chunk_count:
		var best_c: Vector3 = Vector3.ZERO
		var best_sep: float = -1.0
		for _attempt in 4:
			var t: int = randi() % tri_count
			var c: Vector3 = (
				src_verts[indices[t * 3 + 0]]
				+ src_verts[indices[t * 3 + 1]]
				+ src_verts[indices[t * 3 + 2]]) / 3.0
			var sep: float = INF
			for s in seeds:
				sep = minf(sep, c.distance_to(s))
			if sep >= min_sep:
				best_c = c
				break
			if sep > best_sep:
				best_sep = sep
				best_c = c
		seeds.append(best_c)

	# Plain Arrays here, NOT PackedInt32Array: packed arrays are value types,
	# so the old copy-out/append/copy-back dance memcpy'd the whole bucket
	# once per triangle — O(tris²), minutes on a 13k-tri character mesh.
	# Reference-semantics Arrays append in place; pack once at the end.
	var buckets: Array = []
	for _i in chunk_count:
		buckets.append([])
	for t in tri_count:
		var i0: int = indices[t * 3 + 0]
		var i1: int = indices[t * 3 + 1]
		var i2: int = indices[t * 3 + 2]
		var tc: Vector3 = (src_verts[i0] + src_verts[i1] + src_verts[i2]) / 3.0
		var best: int = 0
		var best_d: float = INF
		for s in chunk_count:
			var d: float = tc.distance_squared_to(seeds[s])
			if d < best_d:
				best_d = d
				best = s
		var bucket: Array = buckets[best]
		bucket.append(i0)
		bucket.append(i1)
		bucket.append(i2)

	for b in chunk_count:
		var bucket_indices := PackedInt32Array(buckets[b])
		if bucket_indices.size() < 3:
			continue
		var chunk_dict: Dictionary = _gib_bake_chunk(bucket_indices, src_verts, src_norms, src_uvs)
		if not chunk_dict.is_empty():
			out.append(chunk_dict)
	return out

static func _gib_bake_chunk(
	bucket_indices: PackedInt32Array,
	src_verts: PackedVector3Array,
	src_norms: PackedVector3Array,
	src_uvs: PackedVector2Array,
) -> Dictionary:
	var local_verts: PackedVector3Array = PackedVector3Array()
	var local_norms: PackedVector3Array = PackedVector3Array()
	var local_uvs: PackedVector2Array = PackedVector2Array()
	var new_indices: PackedInt32Array = PackedInt32Array()
	var remap: Dictionary = {}
	for old_idx in bucket_indices:
		var new_idx: int
		if remap.has(old_idx):
			new_idx = int(remap[old_idx])
		else:
			new_idx = local_verts.size()
			remap[old_idx] = new_idx
			local_verts.append(src_verts[old_idx])
			if src_norms.size() > old_idx:
				local_norms.append(src_norms[old_idx])
			if src_uvs.size() > old_idx:
				local_uvs.append(src_uvs[old_idx])
		new_indices.append(new_idx)

	var chunk_centroid: Vector3 = Vector3.ZERO
	for v in local_verts:
		chunk_centroid += v
	chunk_centroid /= float(local_verts.size())
	for i in local_verts.size():
		local_verts[i] = local_verts[i] - chunk_centroid

	var chunk_aabb: AABB = AABB(local_verts[0], Vector3.ZERO)
	for v in local_verts:
		chunk_aabb = chunk_aabb.expand(v)

	var cap: Dictionary = _gib_build_cap(local_verts, new_indices)

	return {
		"verts": local_verts,
		"norms": local_norms,
		"uvs": local_uvs,
		"indices": new_indices,
		"centroid": chunk_centroid,
		"aabb": chunk_aabb,
		"cap_verts": cap.get("verts", PackedVector3Array()),
		"cap_colors": cap.get("colors", PackedColorArray()),
		"cap_indices": cap.get("indices", PackedInt32Array()),
	}

# Find boundary edges (appear exactly once) and fan-triangulate them to
# the chunk's local origin. Edges are matched by quantised vertex position
# so meshes with duplicate-position vertices (hard-edge normals, primitive
# meshes) still produce correct boundary detection.
static func _gib_build_cap(
	local_verts: PackedVector3Array,
	new_indices: PackedInt32Array,
) -> Dictionary:
	var out: Dictionary = {}
	var vert_count: int = local_verts.size()
	if vert_count == 0 or new_indices.is_empty():
		return out

	# Position-canonicalise vertices so duplicates share an identity.
	var canon: PackedInt32Array = PackedInt32Array()
	canon.resize(vert_count)
	var pos_to_canon: Dictionary = {}
	for i in vert_count:
		var p: Vector3 = local_verts[i]
		var key: Vector3i = Vector3i(
			int(round(p.x / _GIB_QUANTIZE)),
			int(round(p.y / _GIB_QUANTIZE)),
			int(round(p.z / _GIB_QUANTIZE)),
		)
		if pos_to_canon.has(key):
			canon[i] = int(pos_to_canon[key])
		else:
			var c: int = pos_to_canon.size()
			pos_to_canon[key] = c
			canon[i] = c

	var edge_counts: Dictionary = {}
	var edge_repr: Dictionary = {}  # canonical edge key → [local_a, local_b]
	var tri_count: int = new_indices.size() / 3
	for t in tri_count:
		var ia: int = new_indices[t * 3 + 0]
		var ib: int = new_indices[t * 3 + 1]
		var ic: int = new_indices[t * 3 + 2]
		# Unrolled edges — the old per-triangle nested-Array literal allocated
		# four Arrays per tri, a measurable slice of big-mesh bakes.
		for e in 3:
			var a: int = ia if e == 0 else (ib if e == 1 else ic)
			var b: int = ib if e == 0 else (ic if e == 1 else ia)
			var ca: int = canon[a]
			var cb: int = canon[b]
			var key := Vector2i(mini(ca, cb), maxi(ca, cb))
			edge_counts[key] = int(edge_counts.get(key, 0)) + 1
			if not edge_repr.has(key):
				edge_repr[key] = Vector2i(a, b)

	var boundary: Array = []
	for key: Vector2i in edge_counts.keys():
		if int(edge_counts[key]) == 1:
			boundary.append(edge_repr[key])
	if boundary.is_empty():
		return out

	var cap_verts: PackedVector3Array = PackedVector3Array()
	var cap_colors: PackedColorArray = PackedColorArray()
	var cap_indices: PackedInt32Array = PackedInt32Array()
	cap_verts.append(Vector3.ZERO)                  # apex at chunk centre
	cap_colors.append(Color(0.18, 0.01, 0.01))      # darkest deep inside
	for edge_pair in boundary:
		var v1: Vector3 = local_verts[edge_pair[0]]
		var v2: Vector3 = local_verts[edge_pair[1]]
		var i1: int = cap_verts.size()
		cap_verts.append(v1)
		cap_colors.append(_gib_flesh_color())
		var i2: int = cap_verts.size()
		cap_verts.append(v2)
		cap_colors.append(_gib_flesh_color())
		cap_indices.append(0)
		cap_indices.append(i1)
		cap_indices.append(i2)

	out["verts"] = cap_verts
	out["colors"] = cap_colors
	out["indices"] = cap_indices
	return out

static func _gib_flesh_color() -> Color:
	var t: float = randf()
	return Color(0.22, 0.015, 0.015).lerp(Color(0.92, 0.18, 0.12), t)

static func _gib_get_flesh_material() -> StandardMaterial3D:
	if _gib_flesh_material_cached != null:
		return _gib_flesh_material_cached
	var mat := StandardMaterial3D.new()
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.roughness = 0.9
	mat.metallic = 0.0
	mat.vertex_color_use_as_albedo = true
	_gib_flesh_material_cached = mat
	return _gib_flesh_material_cached

# -------------------- 2. VFX SPAWNERS (scene-scoped) --------------------

# Cached shaders + sphere meshes shared across all explosions. Lives on
# Violence so a single instance is reused process-wide; the player.gd
# version held one per Player instance.
static var _heat_mesh: SphereMesh = null
static var _heat_shader: Shader = null
static var _shock_mesh: SphereMesh = null
static var _shock_shader: Shader = null
static var _pentagram_glow_shader: Shader = null
static var _pentagram_beam_shader: Shader = null
static var _blast_budget_frame: int = -1
static var _full_blasts_this_frame: int = 0
static var _cheap_blasts_this_frame: int = 0
static var _blast_cluster_positions: Array[Vector3] = []
static var _full_blast_window_ms: int = -10000
static var _full_blasts_this_window: int = 0
static var _active_smoke_puffs: int = 0
static var _pending_smoke_puffs: int = 0
static var _active_blast_smoke_layers: int = 0
static var _smoke_burst_window_ms: int = -10000
static var _smoke_burst_count: int = 0
static var _explosion_sfx_window_ms: int = -10000
static var _explosion_sfx_count: int = 0
static var _cheap_light_window_ms: int = -10000
static var _cheap_light_count: int = 0

# Live smoke billow pivots — avoids get_nodes_in_group() on every blast push.
static var _blast_smoke_layer_pivots: Array[Node3D] = []

# Heavy billow/shard/ember spawns are deferred to process-frame flush so a burst
# of explosions in one physics tick can't spend 20ms+ synchronously.
static var _pending_blast_visuals: Array = []
static var _blast_visual_process_frame: int = -1
static var _blast_visual_process_usec: int = 0


static func _safe_scene_from_job(job: Dictionary) -> Node:
	var ref: Variant = job.get("scene")
	if ref == null or not is_instance_valid(ref):
		return null
	return ref as Node


static func discard_pending_blast_visuals() -> void:
	_pending_blast_visuals.clear()

const MAX_PENDING_BLAST_VISUALS := 32
const MAX_BLAST_HEAVY_JOBS_PER_PROCESS_FRAME := 2
const MAX_BLAST_HEAVY_USEC_PER_PROCESS_FRAME := 4500

# Bench-only spawn cost attribution (perf_benchmark reads via bench_blast_prof_summary).
static var _bench_blast_usec: Dictionary = {}
static var _bench_blast_n: Dictionary = {}


static func reset_bench_blast_prof() -> void:
	_bench_blast_usec.clear()
	_bench_blast_n.clear()


static func bench_blast_prof_summary() -> Dictionary:
	return {"usec": _bench_blast_usec.duplicate(), "n": _bench_blast_n.duplicate()}


static func _bench_blast_prof(bucket: String, usec: int) -> void:
	if not BenchFlags.active:
		return
	_bench_blast_usec[bucket] = int(_bench_blast_usec.get(bucket, 0)) + usec
	_bench_blast_n[bucket] = int(_bench_blast_n.get(bucket, 0)) + 1


static func _bench_blast_scope(bucket: String, fn: Callable) -> void:
	if not BenchFlags.active:
		fn.call()
		return
	var t0 := Time.get_ticks_usec()
	fn.call()
	_bench_blast_prof(bucket, Time.get_ticks_usec() - t0)


static func _register_blast_smoke_layer(pivot: Node3D) -> void:
	_blast_smoke_layer_pivots.append(pivot)
	pivot.tree_exiting.connect(func() -> void:
		_active_blast_smoke_layers = maxi(0, _active_blast_smoke_layers - 1)
		var idx := _blast_smoke_layer_pivots.find(pivot)
		if idx >= 0:
			_blast_smoke_layer_pivots.remove_at(idx))

const MAX_FULL_BLASTS_PER_FRAME := 3
const MAX_CHEAP_BLASTS_PER_FRAME := 10
const BLAST_CLUSTER_DIST_SQ := 9.0
const FULL_BLAST_WINDOW_MS := 500
const MAX_FULL_BLASTS_PER_WINDOW := 25   # ~50/sec sustained; bursts still capped by MAX_FULL_BLASTS_PER_FRAME + 3m cluster dedup
const MAX_ACTIVE_SMOKE_PUFFS := 36
const MAX_PENDING_SMOKE_PUFFS := 12
# Concurrent blast smoke-billow layers (the "blast_smoke_layers" group). Uncapped
# this pile grows with explosion rate, and _push_nearby_blast_smoke re-tweens the
# whole pile per blast → O(blasts × layers). Capping bounds that to O(blasts) and
# also trims draw calls/overdraw. Only bites during heavy explosion spam; isolated
# blasts stay well under it.
const MAX_ACTIVE_BLAST_SMOKE_LAYERS := 32
# Per-blast, only shove the nearest N smoke layers (the visually relevant ones).
# Caps push work even within the layer budget; isolated blasts with fewer live
# layers push all of them.
const MAX_SMOKE_PUSH_PER_BLAST := 12
const SMOKE_BURST_WINDOW_MS := 750
const MAX_SMOKE_BURSTS_PER_WINDOW := 1
const EXPLOSION_SFX_WINDOW_MS := 500
const MAX_EXPLOSION_SFX_PER_WINDOW := 25  # explosion audio is cheap (cached WAV); allow ~50/sec so explosive-round streams still sound like explosions
const CHEAP_LIGHT_WINDOW_MS := 180
const MAX_CHEAP_LIGHTS_PER_WINDOW := 2

# -------------------- world-space VFX attach --------------------

# Callers pass world positions; parent may be Arena (non-zero transform).
static func _attach_world_3d(scene: Node, node: Node3D, world_pos: Vector3) -> void:
	scene.add_child(node)
	if scene is Node3D:
		node.global_position = world_pos
	else:
		node.position = world_pos


static var _perf_governor: Node = null

static func _governor() -> Node:
	if _perf_governor == null or not is_instance_valid(_perf_governor):
		var loop := Engine.get_main_loop()
		if loop is SceneTree:
			_perf_governor = (loop as SceneTree).root.get_node_or_null("PerfGovernor")
	return _perf_governor


# Adaptive VFX quality in [PerfGovernor.MIN_SCALE, 1.0]; 1.0 (full quality) when
# the governor autoload is absent (isolated tool scripts / before tree is up).
static func vfx_quality_scale() -> float:
	var gov := _governor()
	return gov.quality_scale if gov else 1.0


# Governor shed tier 2: false means every blast renders as the cheap flare
# (no smoke/distortion/ember stack) — the single biggest per-blast cost on
# both axes (GPU fill and CPU spawn work).
static func _full_blasts_allowed() -> bool:
	var gov := _governor()
	return gov == null or gov.full_blasts_allowed


static func _begin_blast_frame() -> void:
	var frame := Engine.get_physics_frames()
	if _blast_budget_frame == frame:
		return
	_blast_budget_frame = frame
	_full_blasts_this_frame = 0
	_cheap_blasts_this_frame = 0
	_blast_cluster_positions.clear()


static func _blast_cluster_blocked(pos: Vector3) -> bool:
	for existing in _blast_cluster_positions:
		if existing.distance_squared_to(pos) <= BLAST_CLUSTER_DIST_SQ:
			return true
	return false


static func _claim_full_blast(pos: Vector3) -> bool:
	if not _full_blasts_allowed():
		return false
	_begin_blast_frame()
	if _blast_cluster_blocked(pos):
		return false
	var now := Time.get_ticks_msec()
	if now - _full_blast_window_ms >= FULL_BLAST_WINDOW_MS:
		_full_blast_window_ms = now
		_full_blasts_this_window = 0
	# Adaptive: under load, fewer blasts get the full (distortion + light + smoke
	# + cloud + ember) treatment; the rest fall back to the cheap flare. Never
	# below 1 so explosions always read as explosions.
	var max_full := maxi(1, int(round(MAX_FULL_BLASTS_PER_FRAME * vfx_quality_scale())))
	if _full_blasts_this_frame >= max_full:
		return false
	if _full_blasts_this_window >= MAX_FULL_BLASTS_PER_WINDOW:
		return false
	_full_blasts_this_frame += 1
	_full_blasts_this_window += 1
	_blast_cluster_positions.append(pos)
	return true


static func _claim_cheap_blast(pos: Vector3) -> bool:
	_begin_blast_frame()
	if _blast_cluster_blocked(pos):
		return false
	if _cheap_blasts_this_frame >= maxi(2, int(round(MAX_CHEAP_BLASTS_PER_FRAME * vfx_quality_scale()))):
		return false
	_cheap_blasts_this_frame += 1
	_blast_cluster_positions.append(pos)
	return true


static func _full_blast_eligible_except_frame_cap(pos: Vector3) -> bool:
	if not _full_blasts_allowed():
		return false
	_begin_blast_frame()
	if _blast_cluster_blocked(pos):
		return false
	var now := Time.get_ticks_msec()
	var window_count := _full_blasts_this_window
	if now - _full_blast_window_ms >= FULL_BLAST_WINDOW_MS:
		window_count = 0
	return window_count < MAX_FULL_BLASTS_PER_WINDOW


static func _reserve_full_blast_slot(pos: Vector3) -> void:
	var now := Time.get_ticks_msec()
	if now - _full_blast_window_ms >= FULL_BLAST_WINDOW_MS:
		_full_blast_window_ms = now
		_full_blasts_this_window = 0
	_full_blasts_this_window += 1
	_blast_cluster_positions.append(pos)


static func _sync_blast_visual_process_budget() -> void:
	var f := Engine.get_process_frames()
	if _blast_visual_process_frame != f:
		_blast_visual_process_frame = f
		_blast_visual_process_usec = 0


static func debug_pending_blast_visuals() -> int:
	return _pending_blast_visuals.size()


static func _enqueue_blast_visual_job(
	scene: Node,
	pos: Vector3,
	radius: float,
	color: Color,
	play_audio: bool,
	include_immediate: bool,
) -> void:
	if _pending_blast_visuals.size() >= MAX_PENDING_BLAST_VISUALS:
		return
	_pending_blast_visuals.append({
		"scene": scene,
		"pos": pos,
		"radius": radius,
		"color": color,
		"play_audio": play_audio,
		"immediate": include_immediate,
	})


static func flush_pending_blast_visuals() -> void:
	_sync_blast_visual_process_budget()
	if _pending_blast_visuals.is_empty():
		return
	var jobs_done := 0
	while not _pending_blast_visuals.is_empty():
		if jobs_done >= MAX_BLAST_HEAVY_JOBS_PER_PROCESS_FRAME:
			break
		if _blast_visual_process_usec >= MAX_BLAST_HEAVY_USEC_PER_PROCESS_FRAME:
			break
		var job: Dictionary = _pending_blast_visuals[0]
		var scene: Node = _safe_scene_from_job(job)
		if scene == null:
			_pending_blast_visuals.pop_front()
			continue
		var t0 := Time.get_ticks_usec()
		var pos: Vector3 = job.get("pos") as Vector3
		var radius: float = float(job.get("radius"))
		var color: Color = job.get("color") as Color
		var play_audio: bool = bool(job.get("play_audio"))
		if bool(job.get("immediate")):
			_spawn_bullet_blast_immediate_visuals(scene, pos, radius, color, play_audio)
		_spawn_bullet_blast_heavy_visuals(scene, pos, radius, color)
		_pending_blast_visuals.pop_front()
		jobs_done += 1
		_blast_visual_process_usec += Time.get_ticks_usec() - t0


# Read-only budget peek — lets bullet.gd skip the blast RPC when every layer
# is capped/clustered (common for minigun + explosive on one spot).
static func blast_vfx_will_spawn(pos: Vector3) -> bool:
	_begin_blast_frame()
	if _blast_cluster_blocked(pos):
		return false
	if _full_blast_eligible_except_frame_cap(pos):
		return true
	return _cheap_blasts_this_frame < maxi(2, int(round(MAX_CHEAP_BLASTS_PER_FRAME * vfx_quality_scale())))


static func _claim_explosion_sfx() -> bool:
	var now := Time.get_ticks_msec()
	if now - _explosion_sfx_window_ms >= EXPLOSION_SFX_WINDOW_MS:
		_explosion_sfx_window_ms = now
		_explosion_sfx_count = 0
	if _explosion_sfx_count >= MAX_EXPLOSION_SFX_PER_WINDOW:
		return false
	_explosion_sfx_count += 1
	return true


static func _claim_cheap_light() -> bool:
	var now := Time.get_ticks_msec()
	if now - _cheap_light_window_ms >= CHEAP_LIGHT_WINDOW_MS:
		_cheap_light_window_ms = now
		_cheap_light_count = 0
	if _cheap_light_count >= MAX_CHEAP_LIGHTS_PER_WINDOW:
		return false
	_cheap_light_count += 1
	return true


static func _can_spawn_smoke_puff() -> bool:
	return _active_smoke_puffs < MAX_ACTIVE_SMOKE_PUFFS


static func _claim_pending_smoke_puff() -> bool:
	if _active_smoke_puffs + _pending_smoke_puffs >= MAX_ACTIVE_SMOKE_PUFFS + MAX_PENDING_SMOKE_PUFFS:
		return false
	_pending_smoke_puffs += 1
	return true


static func _claim_smoke_burst() -> bool:
	var now := Time.get_ticks_msec()
	if now - _smoke_burst_window_ms >= SMOKE_BURST_WINDOW_MS:
		_smoke_burst_window_ms = now
		_smoke_burst_count = 0
	if _smoke_burst_count >= MAX_SMOKE_BURSTS_PER_WINDOW:
		return false
	_smoke_burst_count += 1
	return true


const BLAST_FRONT_SPEED := 343.0  # m/s — shockwave front + audio delay


static func _blast_fireball_timing(radius: float) -> Dictionary:
	# Bigger blasts flash bigger AND a touch longer (grenade ~0.27s, airstrike ~0.55s).
	var grow := clampf(0.12 + radius * 0.007, 0.12, 0.45)
	var fade := clampf(0.08 + radius * 0.005, 0.08, 0.28)
	return {"grow": grow, "fade": fade}


# ---- Stylized flame shards + embers --------------------------------------
# Radial flame petals + flying sparks for a stylized
# "burst" read. Performance notes:
#  - Meshes are built once and shared by every shard/ember ever (cached below).
#  - Each blast uses ONE additive material (a single shared fade tween, not one
#    per particle) configured exactly like the fireball — so it's the SAME
#    already-warmed PSO variant (warmup_blast_materials), no new shader compile.
#  - Only full blasts spawn them, so the per-frame blast budget caps the count.
# Live tuning hooks for the explosion lab (1.0 == production look; 0 == off).
static var blast_shard_count_scale: float = 1.0
static var blast_ember_count_scale: float = 1.0

static var _blast_shard_mesh: Mesh = null
static var _blast_ember_mesh: Mesh = null

static func _get_blast_shard_mesh() -> Mesh:
	if _blast_shard_mesh == null:
		# Blobby puff — a fast-expanding little fire cloud, not an angular petal.
		var c := SphereMesh.new()
		c.radius = 0.5
		c.height = 1.0
		c.radial_segments = 12
		c.rings = 7
		_blast_shard_mesh = c
	return _blast_shard_mesh

static func _get_blast_ember_mesh() -> Mesh:
	if _blast_ember_mesh == null:
		var s := SphereMesh.new()
		s.radius = 0.06
		s.height = 0.12
		s.radial_segments = 5
		s.rings = 3
		_blast_ember_mesh = s
	return _blast_ember_mesh


# Additive "projectile" layer (embers + flame shards) as a MultiMesh. Each
# instance flies outward from the blast centre to its travel target
# (decelerating) and fades. Orientation, scale, streak, growth and the fly-out
# are ALL computed in the shader from per-instance data, so the instance
# transform is plain identity and nothing depends on MODEL_MATRIX (which doesn't
# reliably expose the per-instance transform for MultiMesh). One draw call, one
# material, one tween for the whole burst.
#   INSTANCE_CUSTOM = (travel.xyz world-offset from centre, delay)
#   COLOR           = (size01, elong01, grow_start, brightness_jitter)
static var _blast_projectile_shader: Shader = null

const _BLAST_PROJECTILE_CODE := "
	shader_type spatial;
	render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled, blend_add;
	uniform float anim = 0.0;
	uniform vec3 tint : source_color = vec3(1.0, 0.7, 0.3);
	uniform float brightness = 6.0;
	uniform float size_scale = 1.0;
	uniform float elong_max = 8.0;
	uniform float fade_start = 0.35;
	varying float v_b;
	void vertex() {
		vec3 travel = INSTANCE_CUSTOM.xyz;     // world target offset from blast centre
		float delay = INSTANCE_CUSTOM.w;
		float size = COLOR.r * size_scale;
		float elong = 1.0 + COLOR.g * (elong_max - 1.0);
		float grow_start = COLOR.b;
		float age = clamp((anim - delay) / max(1.0 - delay, 0.001), 0.0, 1.0);
		float prog = 1.0 - pow(1.0 - age, 2.0);   // decelerating
		float dist = length(travel);
		vec3 dir = dist > 0.0001 ? travel / dist : vec3(0.0, 1.0, 0.0);
		// Orthonormal frame with Y aligned to the travel direction.
		vec3 upv = abs(dir.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
		vec3 ex = normalize(cross(upv, dir));
		vec3 ez = cross(dir, ex);
		float grow = mix(grow_start, 1.0, prog);
		vec3 v = VERTEX;
		v.x *= size * grow;
		v.z *= size * grow;
		v.y *= size * grow * mix(1.0, elong, prog);   // stretch into a streak/petal as it flies
		// Orient (mesh Y -> dir) then fly outward from centre to target.
		VERTEX = ex * v.x + dir * v.y + ez * v.z + travel * prog;
		v_b = (1.0 - smoothstep(fade_start, 1.0, age)) * COLOR.a;
	}
	void fragment() {
		ALBEDO = tint * brightness;   // additive (blend_add); HDR brightness blooms
		ALPHA = v_b;                  // fade modulates the added light
	}
"

static func _get_blast_projectile_shader() -> Shader:
	if _blast_projectile_shader == null:
		_blast_projectile_shader = Shader.new()
		_blast_projectile_shader.code = _BLAST_PROJECTILE_CODE
	return _blast_projectile_shader

static func _finish_projectile_layer(scene: Node, mm: MultiMesh, pos: Vector3, tint: Color, brightness: float, life: float, aabb_extent: float, size_scale: float, elong_max: float) -> MultiMeshInstance3D:
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.custom_aabb = AABB(Vector3.ONE * (-aabb_extent), Vector3.ONE * (2.0 * aabb_extent))
	var mat := ShaderMaterial.new()
	mat.shader = _get_blast_projectile_shader()
	mat.set_shader_parameter("anim", 0.0)
	mat.set_shader_parameter("tint", tint)
	mat.set_shader_parameter("brightness", brightness)
	mat.set_shader_parameter("size_scale", size_scale)
	mat.set_shader_parameter("elong_max", elong_max)
	mmi.material_override = mat
	_attach_world_3d(scene, mmi, pos)
	var tw := mmi.create_tween()
	tw.tween_property(mat, "shader_parameter/anim", 1.0, life).set_trans(Tween.TRANS_LINEAR)
	tw.tween_callback(mmi.queue_free)
	return mmi


static func spawn_blast_flame_shards(scene: Node, pos: Vector3, radius: float, color: Color) -> void:
	if scene == null or blast_shard_count_scale <= 0.0:
		return
	if BenchFlags.active and BenchFlags.no_explosion_visuals:
		return
	var count := int(round(clampi(int(radius * 0.7), 5, 12) * blast_shard_count_scale * vfx_quality_scale()))
	if count <= 0:
		return
	# Reuse the fire-cloud billow (lumpy orange->grey gradient) but elongate each
	# blob radially so it reads as a fast-stretching fire tongue, not a round puff.
	# Erupt a little after the initial fireball (delay_bias), each tongue staggered.
	_spawn_blast_billow(scene, pos, radius, count, true, color, 0.34 + radius * 0.05, 0.28, 0.6, radius * 0.28, 2.6, 0.14)


static func spawn_blast_embers(scene: Node, pos: Vector3, radius: float, color: Color) -> void:
	if scene == null or blast_ember_count_scale <= 0.0:
		return
	if BenchFlags.active and BenchFlags.no_explosion_visuals:
		return
	var count := int(round(clampi(int(radius * 5.0), 30, 110) * blast_ember_count_scale * vfx_quality_scale()))
	if count <= 0:
		return
	var rng := RandomNumberGenerator.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = _get_blast_ember_mesh()
	mm.instance_count = count
	var size_scale := 1.2   # max sz → COLOR.r normalised to [0,1]
	for i in count:
		var theta := rng.randf() * TAU
		var elev := rng.randf_range(-0.2, 1.35)
		var dir := Vector3(cos(theta) * cos(elev), sin(elev), sin(theta) * cos(elev)).normalized()
		var dist := radius * rng.randf_range(0.8, 2.0)
		var drop := radius * rng.randf_range(0.2, 0.7)
		var travel := dir * dist + Vector3.DOWN * drop
		# Streak along travel (faster/farther sparks trail longer).
		var sz := rng.randf_range(0.4, 1.15)
		var streak := 1.0 + clampf(dist / radius, 0.0, 2.0) * rng.randf_range(1.6, 3.6)
		mm.set_instance_transform(i, Transform3D.IDENTITY)
		# COLOR = (size01, elong01=streak, grow_start=1 (no grow-in), brightness_jitter)
		mm.set_instance_color(i, Color(sz / size_scale, clampf((streak - 1.0) / 7.0, 0.0, 1.0), 1.0, rng.randf_range(0.6, 1.0)))
		# CUSTOM = (travel.xyz, delay)
		mm.set_instance_custom_data(i, Color(travel.x, travel.y, travel.z, rng.randf_range(0.0, 0.15)))
	var hot := color.lerp(Color(1.0, 0.86, 0.5), 0.4)
	var ember_mmi := _finish_projectile_layer(
		scene, mm, pos, hot, 5.0, 0.3 + radius * 0.03, radius * 3.5, size_scale, 8.0)
	if ember_mmi:
		_enroll_alive_capped(_live_accent_billows, ember_mmi,
			maxi(8, int(round(MAX_LIVE_ACCENT_BILLOWS * vfx_quality_scale()))))


# Orthonormal basis whose +Y axis aligns with `dir` (for orienting the shard cone).
static func _basis_from_y(dir: Vector3) -> Basis:
	var y := dir.normalized()
	var x := y.cross(Vector3.FORWARD)
	if x.length_squared() < 0.001:
		x = y.cross(Vector3.RIGHT)
	x = x.normalized()
	var z := x.cross(y).normalized()
	return Basis(x, y, z)


# ---- Fused fire + smoke body (MultiMesh, GPU-animated) -------------------
# Billowing cauliflower clouds: lumpy puffs with DARK fresnel-rimmed edges, the
# fire ones emissive (hot white centre → orange outward), the smoke ones dark.
# Performance: each cloud layer is ONE MultiMesh (one draw call for every puff),
# ONE material, and ONE tween — all the per-puff motion (growth, fade, glow,
# lump, stagger) is baked into the shader and driven by a single `anim` uniform
# 0→1. Replaces the old per-puff path (~30 nodes + 30 materials + 90 tweens per
# layer) so blasts scale to hundreds/sec. Per-instance data: COLOR = (body.rgb,
# opacity_peak), INSTANCE_CUSTOM = (seed, delay, heat-or-glow, 0).
static var blast_smoke_count_scale: float = 1.0
static var blast_fire_cloud_count_scale: float = 1.0
static var bench_smoke_push_calls: int = 0
static var bench_smoke_layers_pushed: int = 0
static var _smoke_billow_mesh: Mesh = null
static var _billow_mm_shader: Shader = null

const _BILLOW_MM_CODE := "
	shader_type spatial;
	render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled;
	uniform float anim = 0.0;          // 0..1, tweened once per layer
	uniform float is_fire = 0.0;
	uniform float edge_power = 2.1;
	uniform float lump_amount = 0.32;
	uniform float growth_min = 0.35;
	uniform float tail_power = 1.5;    // <1 = long lingering tail, >1 = quick fade
	uniform float sky_mode = 0.0;      // 1 = persistent sky clouds (no blast fade)
	// Blackout rounds crush this toward 0 (set via RenderingServer global):
	// unshaded smoke/cloud bodies would otherwise keep their baked daytime
	// grey and read as glowing blobs against the dark sky. Fire stays bright.
	global uniform float world_light_dim;
	// Hue for the (otherwise greyscale) smoke body — white = classic smoke,
	// red = the colosseum's blood mist. Only the non-fire branch uses it.
	uniform vec3 smoke_tint : source_color = vec3(1.0);
	uniform vec3 warm_glow : source_color = vec3(1.0, 0.45, 0.12);
	uniform vec3 fire_cool : source_color = vec3(1.0, 0.5, 0.16);
	uniform vec3 fire_hot : source_color = vec3(1.0, 0.97, 0.86);
	uniform float fire_glow_lo = 14.0;
	uniform float fire_glow_hi = 65.0;
	uniform sampler2D depth_tex : hint_depth_texture, filter_linear;
	varying float v_age;
	varying float v_heat;
	varying vec3 v_body;
	varying float v_opk;
	varying float v_shade;   // per-region darkness variation (free — reuses lump noise)
	void vertex() {
		float seed = INSTANCE_CUSTOM.x;
		float delay = INSTANCE_CUSTOM.y;
		v_heat = INSTANCE_CUSTOM.z;
		v_body = COLOR.rgb;
		v_opk = COLOR.a;
		// Staggered local age so puffs don't all pop at once. Sky clouds use a
		// fixed hold age per puff (INSTANCE_CUSTOM.y) instead of the blast tween.
		if (sky_mode > 0.5) {
			v_age = clamp(delay, 0.0, 1.0);
		} else {
			v_age = clamp((anim - delay) * (1.0 + INSTANCE_CUSTOM.w) / max(1.0 - delay, 0.001), 0.0, 1.0);
		}
		// Per-instance lumpy displacement (seed varies every puff).
		float s = seed * 100.0;
		float a = sin(VERTEX.x * 6.3 + s) * sin(VERTEX.y * 5.1 + s * 1.7) * sin(VERTEX.z * 7.2 + s * 0.9);
		float b = sin(VERTEX.x * 13.0 + s * 2.1) * sin(VERTEX.z * 11.0 + s * 1.3);
		// Finer-frequency octave used only for shading so darkness varies across
		// the puff surface (mixed with the lump shape).
		float c = sin(VERTEX.x * 21.0 + s * 3.3) * sin(VERTEX.y * 18.0 + s * 2.1) * sin(VERTEX.z * 25.0 + s * 1.5);
		v_shade = (a * 0.7 + b * 0.3) * 0.55 + c * 0.45;
		VERTEX += NORMAL * (a * 0.7 + b * 0.3) * lump_amount;
		// Growth 0.35 -> 1.0 at a CONSTANT rate (linear — keeps expanding, no
		// ease-out settling at the end). The slow fade is the alpha's job.
		VERTEX *= mix(growth_min, 1.0, v_age);
	}
	void fragment() {
		float facing = abs(dot(normalize(NORMAL), normalize(VIEW)));
		float fres = pow(1.0 - facing, edge_power);
		float fade_in = smoothstep(0.0, 0.12, v_age);
		float t = clamp((v_age - 0.12) / 0.88, 0.0, 1.0);
		// Long lingering tail (tail_power < 1) but with a SOFT landing — the last
		// stretch eases gently to zero instead of dropping off a cliff at the end.
		float fade_out = pow(1.0 - t, tail_power) * (1.0 - smoothstep(0.5, 1.0, t));
		if (sky_mode > 0.5) {
			fade_in = 1.0;
			fade_out = 1.0;
		}
		ALPHA = v_opk * fade_in * fade_out * smoothstep(0.0, 0.85, facing);
		// Soft particles: dissolve where the puff meets solid geometry so it
		// doesn't slice into walls/ground with a hard polygon edge.
		float scene_d = texture(depth_tex, SCREEN_UV).r;
		vec4 vpos = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, scene_d, 1.0);
		float scene_z = (vpos.xyz / vpos.w).z;
		ALPHA *= clamp((VERTEX.z - scene_z) / 1.6, 0.0, 1.0);
		vec2 px_cell = floor(UV * vec2(8.0, 5.0));
		float cell_band = mod(px_cell.x + px_cell.y, 3.0) - 1.0;
		if (is_fire > 0.5) {
			float heat = clamp(v_heat + cell_band * 0.06, 0.0, 1.0);
			float age_cool = 1.0 - smoothstep(0.0, 0.75, v_age);
			float fire_band = clamp(heat * 0.6 + facing * 0.25 + age_cool * 0.15, 0.0, 1.0);
			// fire_band computed smoothly above (no hard banding).
			vec3 c0 = vec3(0.03, 0.025, 0.02);
			vec3 c1 = vec3(0.30, 0.09, 0.025);
			vec3 c2 = vec3(1.00, 0.24, 0.04);
			vec3 c3 = vec3(1.00, 0.62, 0.12);
			vec3 c4 = vec3(1.00, 0.95, 0.72);
			vec3 color = c0;
			color = mix(color, c1, smoothstep(0.05, 0.34, fire_band));
			color = mix(color, c2, smoothstep(0.30, 0.54, fire_band));
			color = mix(color, c3, smoothstep(0.52, 0.74, fire_band));
			color = mix(color, c4, smoothstep(0.74, 0.94, fire_band));
			ALBEDO = color * mix(0.45, 16.0, fire_band);
		} else {
			// Darkness varies across the surface — some patches near-black, some
			// lighter — for turbulent, non-uniform smoke.
			float shade = 0.45 + 0.85 * (v_shade * 0.5 + 0.5);
			shade = clamp(shade + cell_band * 0.05, 0.0, 1.0);
			float grey = dot(v_body, vec3(0.3333)) * shade * 0.42;
			grey = mix(grey, grey * 0.22, fres);
			if (sky_mode > 0.5) {
				vec3 warm = warm_glow * (0.18 + v_heat * 0.42) * (0.35 + fres * 0.65);
				grey = clamp(grey + warm.r * 0.55, 0.0, 1.0);
			}
			grey = floor(grey * 16.0 + 0.5) / 16.0;
			ALBEDO = vec3(grey * world_light_dim) * smoke_tint;
		}
	}
"

static func _get_smoke_billow_mesh() -> Mesh:
	if _smoke_billow_mesh == null:
		var s := SphereMesh.new()
		s.radius = 0.5
		s.height = 1.0
		s.radial_segments = 16
		s.rings = 9
		_smoke_billow_mesh = s
	return _smoke_billow_mesh

static func _get_billow_mm_shader() -> Shader:
	if _billow_mm_shader == null:
		_billow_mm_shader = Shader.new()
		_billow_mm_shader.code = _BILLOW_MM_CODE
	return _billow_mm_shader


# Builds one cloud layer as a single MultiMesh + material + tween.
static func _spawn_blast_billow(scene: Node, pos: Vector3, radius: float, count: int,
		is_fire: bool, tint: Color, layer_life: float, scale_lo: float, scale_hi: float, rise: float,
		stretch: float = 1.0, delay_bias: float = 0.0, smoke_tint: Color = Color.WHITE,
		pushable: bool = true, opacity_mult: float = 1.0) -> void:
	# Smoke layers (non-fire) join "blast_smoke_layers" and get re-tweened by every
	# later blast — bound how many can pile up. Bail before building the MultiMesh
	# so a capped layer costs nothing. Fire billows aren't pushed, so they skip this.
	# pushable=false opts a cloud out of the whole layer system (the colosseum's
	# blood mist is PART of its blast — being shoved away by it looked absurd).
	var smoke_layer_cap := maxi(4, int(round(MAX_ACTIVE_BLAST_SMOKE_LAYERS * vfx_quality_scale())))
	if not is_fire and pushable and _active_blast_smoke_layers >= smoke_layer_cap:
		return
	var rng := RandomNumberGenerator.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = _get_smoke_billow_mesh()
	mm.instance_count = count
	var spread := radius * (0.45 if is_fire else 0.65)
	for i in count:
		var ang := rng.randf() * TAU
		var rad := rng.randf_range(0.0, spread)
		var off := Vector3(cos(ang) * rad, rng.randf_range(-0.2, 0.6) * radius * 0.45, sin(ang) * rad)
		var end_scale := radius * rng.randf_range(scale_lo, scale_hi)
		var xform_basis := Basis.IDENTITY.scaled(Vector3.ONE * end_scale)
		if stretch > 1.01:
			# Each tongue fires off radially: uniform azimuth (full 360° horizontal
			# spread) with only a mild elevation range, so they don't all shoot up.
			var azim := rng.randf() * TAU
			var elev := rng.randf_range(-0.25, 0.85)
			var ce := cos(elev)
			var dir := Vector3(cos(azim) * ce, sin(elev), sin(azim) * ce)
			off = dir * (rad + radius * 0.15)
			var up := Vector3.UP if absf(dir.y) < 0.95 else Vector3.RIGHT
			var ex := up.cross(dir).normalized()
			var ez := dir.cross(ex)
			# Scale the COLUMNS (local axes) so the LONG axis follows dir. Using
			# Basis.scaled() scales in world space — that stretched every tongue
			# along world-up no matter which way it pointed.
			xform_basis.x = ex * end_scale
			xform_basis.y = dir * (end_scale * stretch)
			xform_basis.z = ez * end_scale
		mm.set_instance_transform(i, Transform3D(xform_basis, off))
		var seed := rng.randf()
		var delay := delay_bias + rng.randf_range(0.0, 0.22 if is_fire else 0.12)
		var heat: float
		var body: Color
		var opk: float
		if is_fire:
			heat = pow(1.0 - clampf(rad / maxf(spread, 0.001), 0.0, 1.0), 1.4)
			body = Color(1, 1, 1)
			opk = rng.randf_range(0.75, 0.95)
		else:
			heat = rng.randf_range(0.2, 0.55)   # warm underglow amount
			# Dark, dense neutral-grey smoke (one grey value with a fixed slight
			# warm bias — NOT independent per-channel randomness, which produced
			# random red/green/purple tints).
			var g := rng.randf_range(0.07, 0.26)
			body = Color(g * 1.08, g, g * 0.9)
			opk = rng.randf_range(0.6, 0.85)
		mm.set_instance_color(i, Color(body.r, body.g, body.b, opk * opacity_mult))
		# w = per-instance age-speed: some puffs/tongues burn out earlier, some later.
		mm.set_instance_custom_data(i, Color(seed, delay, heat, rng.randf_range(0.0, 0.8)))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	# Generous AABB so the grown/displaced puffs aren't frustum-culled early.
	mmi.custom_aabb = AABB(Vector3.ONE * (-radius * 2.5), Vector3.ONE * (radius * 5.0))
	var mat := ShaderMaterial.new()
	mat.shader = _get_billow_mm_shader()
	mat.set_shader_parameter("anim", 0.0)
	mat.set_shader_parameter("is_fire", 1.0 if is_fire else 0.0)
	if is_fire:
		mat.set_shader_parameter("tail_power", 2.2)   # fire fades fast
		mat.set_shader_parameter("fire_cool", tint.lerp(Color(1.0, 0.5, 0.16), 0.5))
		mat.set_shader_parameter("fire_hot", tint.lerp(Color(1.0, 0.97, 0.86), 0.7))
	else:
		mat.set_shader_parameter("tail_power", 0.38)   # smoke lingers with a long, slow tail
		mat.set_shader_parameter("warm_glow", tint.lerp(Color(1.0, 0.45, 0.12), 0.6))
		if smoke_tint != Color.WHITE:
			mat.set_shader_parameter("smoke_tint", smoke_tint)
	mmi.material_override = mat
	var base := pos + Vector3.UP * (radius * 0.1)
	var host: Node3D = mmi
	if is_fire or not pushable:
		_attach_world_3d(scene, mmi, base)
	else:
		var pivot := Node3D.new()
		pivot.add_to_group("blast_smoke_layers")
		# Count against the concurrency cap; tree_exiting fires on any free (tween
		# finish, round reset, clear_smoke_puffs) so the counter can't leak.
		_active_blast_smoke_layers += 1
		pivot.set_meta("billow_layer_life", layer_life)
		pivot.set_meta("billow_rise", rise)
		pivot.set_meta("billow_mat", mat)
		_register_blast_smoke_layer(pivot)
		_attach_world_3d(scene, pivot, base)
		pivot.add_child(mmi)
		mmi.position = Vector3.ZERO
		host = pivot
	var atw := host.create_tween()
	atw.tween_property(mat, "shader_parameter/anim", 1.0, layer_life).set_trans(Tween.TRANS_LINEAR)
	atw.tween_callback(host.queue_free)
	# Everything outside the pushable smoke-layer cap gets alive-bounded, or
	# sustained blast rates pile up hundreds of live MultiMesh nodes. Round
	# fire billows (the fireball itself) go to the protected fire pool;
	# stretched tongues (flame shards, stretch > 1) and unpushable clouds
	# (blood mist) are accents.
	if is_fire and stretch <= 1.01:
		_enroll_alive_capped(_live_fire_billows, host,
			maxi(10, int(round(MAX_LIVE_FIRE_BILLOWS * vfx_quality_scale()))))
	elif is_fire or not pushable:
		_enroll_alive_capped(_live_accent_billows, host,
			maxi(8, int(round(MAX_LIVE_ACCENT_BILLOWS * vfx_quality_scale()))))
	if rise > 0.0:
		var rise_tw := host.create_tween()
		rise_tw.tween_property(host, "global_position", base + Vector3.UP * rise, layer_life)\
			.set_trans(Tween.TRANS_LINEAR)
		if not is_fire:
			host.set_meta("billow_rise_tween", rise_tw)


# Persistent sky clouds — same lumpy billow MultiMesh as blast smoke, frozen in
# sky_mode so they don't pop/fade. One draw call per cluster.
static func spawn_sky_cloud_cluster(
	parent: Node3D,
	center: Vector3,
	rng: RandomNumberGenerator,
	tint: Color,
	puff_count: int = 7,
	cluster_radius: float = 14.0,
	scale_lo: float = 7.0,
	scale_hi: float = 15.0,
	hell_mode: bool = false,
) -> Node3D:
	if parent == null:
		return null
	var pivot := Node3D.new()
	pivot.name = "SkyCloudCluster"
	pivot.position = center
	pivot.rotation.y = rng.randf_range(-PI, PI)
	parent.add_child(pivot)

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = _get_smoke_billow_mesh()
	mm.instance_count = puff_count
	var spread := cluster_radius
	for i in puff_count:
		var ang := rng.randf() * TAU
		var rad := rng.randf_range(0.0, spread)
		var off := Vector3(
			cos(ang) * rad,
			rng.randf_range(-1.8, 2.4),
			sin(ang) * rad,
		)
		var end_scale := rng.randf_range(scale_lo, scale_hi)
		mm.set_instance_transform(i, Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * end_scale), off))
		var seed := rng.randf()
		var hold := rng.randf_range(0.48 if hell_mode else 0.42, 0.82 if hell_mode else 0.78)
		var heat := rng.randf_range(0.22 if hell_mode else 0.08, 0.48 if hell_mode else 0.22)
		var g := rng.randf_range(0.18 if hell_mode else 0.46, 0.38 if hell_mode else 0.72)
		var body: Color
		if hell_mode:
			body = Color(g * tint.r * 1.35, g * tint.g * 0.72, g * tint.b * 0.42)
		else:
			body = Color(g * tint.r, g * tint.g, g * tint.b)
		var opk := rng.randf_range(0.52 if hell_mode else 0.38, 0.78 if hell_mode else 0.58)
		mm.set_instance_color(i, Color(body.r, body.g, body.b, opk))
		mm.set_instance_custom_data(i, Color(seed, hold, heat, 0.0))

	var mmi := MultiMeshInstance3D.new()
	mmi.name = "SkyCloudBillows"
	mmi.multimesh = mm
	mmi.extra_cull_margin = 128.0
	mmi.ignore_occlusion_culling = true
	mmi.custom_aabb = AABB(Vector3.ONE * (-spread * 2.2), Vector3.ONE * (spread * 4.4))
	var mat := ShaderMaterial.new()
	mat.shader = _get_billow_mm_shader()
	mat.set_shader_parameter("anim", 0.0)
	mat.set_shader_parameter("is_fire", 0.0)
	mat.set_shader_parameter("sky_mode", 1.0)
	mat.set_shader_parameter("tail_power", 0.38)
	mat.set_shader_parameter("lump_amount", 0.34 if hell_mode else 0.28)
	mat.set_shader_parameter("edge_power", 1.65 if hell_mode else 2.1)
	mat.set_shader_parameter("warm_glow", tint.lerp(Color(1.0, 0.55, 0.18), 0.72 if hell_mode else 0.35))
	mmi.material_override = mat
	pivot.add_child(mmi)

	var drift := Vector3(rng.randf_range(-3.5, 3.5), rng.randf_range(-0.4, 0.4), rng.randf_range(-3.5, 3.5))
	if drift.length_squared() > 0.01:
		var tw := pivot.create_tween().set_loops()
		tw.tween_property(pivot, "position", center + drift, rng.randf_range(28.0, 44.0))\
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		tw.tween_property(pivot, "position", center - drift * 0.65, rng.randf_range(28.0, 44.0))\
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	return pivot


static func reset_smoke_push_bench() -> void:
	bench_smoke_push_calls = 0
	bench_smoke_layers_pushed = 0


static func _push_nearby_blast_smoke(scene: Node, blast_pos: Vector3, blast_radius: float) -> void:
	if scene == null:
		return
	bench_smoke_push_calls += 1
	var reach := blast_radius * 3.8 + 14.0
	var reach_sq := reach * reach
	var strength := clampf(blast_radius / 8.0, 0.55, 2.8)
	# Collect in-range layers with their distance, then shove only the nearest
	# MAX_SMOKE_PUSH_PER_BLAST — those are the ones the eye reads. Skipping the
	# far ones keeps a dense explosion-spam from re-tweening hundreds of clouds.
	var candidates: Array = []
	var compact := 0
	for ri in _blast_smoke_layer_pivots.size():
		var node := _blast_smoke_layer_pivots[ri]
		if not is_instance_valid(node):
			continue
		if compact != ri:
			_blast_smoke_layer_pivots[compact] = node
		compact += 1
		var dist_sq := node.global_position.distance_squared_to(blast_pos)
		if dist_sq >= reach_sq:
			continue
		candidates.append({"pivot": node, "dist": sqrt(dist_sq)})
	_blast_smoke_layer_pivots.resize(compact)
	if candidates.size() > MAX_SMOKE_PUSH_PER_BLAST:
		candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["dist"] < b["dist"])
		candidates.resize(MAX_SMOKE_PUSH_PER_BLAST)
	for cand in candidates:
		var pivot := cand["pivot"] as Node3D
		var cloud_pos := pivot.global_position
		var delta := cloud_pos - blast_pos
		var dist_3d: float = cand["dist"]
		var closeness := 1.0 - dist_3d / reach
		var away: Vector3
		var horiz_sq := delta.x * delta.x + delta.z * delta.z
		if horiz_sq < 1.0:
			# Repeat hits on the same pad — old smoke sits on the blast centre.
			var ang := float(pivot.get_instance_id() % 6283) / 1000.0
			away = Vector3(cos(ang), 0.0, sin(ang))
		else:
			var horiz := sqrt(horiz_sq)
			away = Vector3(delta.x / horiz, 0.0, delta.z / horiz)
		var push := away * blast_radius * 1.15 * closeness * strength
		push.y = blast_radius * 0.28 * closeness * strength
		var layer_life: float = pivot.get_meta("billow_layer_life", 1.0)
		var rise: float = pivot.get_meta("billow_rise", 0.0)
		var mat: ShaderMaterial = pivot.get_meta("billow_mat", null)
		var anim := 0.0
		if mat:
			anim = float(mat.get_shader_parameter("anim"))
		var remaining := maxf(0.05, layer_life * (1.0 - anim))
		var rise_remain := rise * (remaining / layer_life)
		var rise_tw: Tween = pivot.get_meta("billow_rise_tween", null)
		if rise_tw and rise_tw.is_valid():
			rise_tw.kill()
		var move_tw := pivot.create_tween()
		move_tw.tween_property(
			pivot,
			"global_position",
			pivot.global_position + push + Vector3.UP * rise_remain,
			remaining,
		).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		pivot.set_meta("billow_rise_tween", move_tw)
		bench_smoke_layers_pushed += 1


static func spawn_blast_fire_smoke(scene: Node, pos: Vector3, radius: float, color: Color) -> void:
	if scene == null or blast_smoke_count_scale <= 0.0:
		return
	if BenchFlags.active and BenchFlags.no_explosion_visuals:
		return
	var count := int(round(clampi(int(radius * 1.1), 8, 24) * blast_smoke_count_scale * vfx_quality_scale()))
	if count <= 0:
		return
	# Lifetime scales with blast size: a small grenade (r≈6) smokes ~1.3s, a huge
	# airstrike (r≈30) lingers ~4.4s.
	_spawn_blast_billow(scene, pos, radius, count, false, color, 0.5 + radius * 0.13, 0.5, 1.3, radius * 0.7)


# Fire as clouds: same lumpy billow puffs, but emissive — hot white near the
# centre cooling to orange outward. Alpha-blended like the smoke, so depth-mixed
# you get patches where smoke is in front (dark) and patches where fire is in
# front (glowing). Short-lived — the fire cools and dies into the smoke.
static func spawn_blast_fire_clouds(scene: Node, pos: Vector3, radius: float, color: Color) -> void:
	if scene == null or blast_fire_cloud_count_scale <= 0.0:
		return
	if BenchFlags.active and BenchFlags.no_explosion_visuals:
		return
	var count := int(round(clampi(int(radius * 0.8), 6, 18) * blast_fire_cloud_count_scale * vfx_quality_scale()))
	if count <= 0:
		return
	# Fire shape burns longer for bigger blasts (r≈6 → ~0.7s, r≈30 → ~2s).
	_spawn_blast_billow(scene, pos, radius, count, true, color, 0.35 + radius * 0.055, 0.3, 0.7, radius * 0.3)


# ---- Alive-population caps (new evicts oldest) ----------------------------
# The per-frame claim limiters bound SPAWNS; these bound the LIVE population
# under sustained fire. Lab attribution (Jul 2026, M5, 400 booms/s sweep,
# explosion_lab --benchmark --only=X): heat distortion ~58ms, blast lights
# ~52ms, fire billows/embers ~50ms, shockwaves ~23ms, smoke ~0.5ms. All
# resolution-independent costs (clustered-light binning, backbuffer copies,
# per-node vertex/tween churn) — the collapse showed a near-idle CPU and
# didn't respond to render scale. Caps scale with quality_scale; evicting
# the oldest is visually masked by the newest blast.
const MAX_LIVE_BLAST_LIGHTS := 10
const MAX_LIVE_HEAT_SHELLS := 3
const MAX_LIVE_SHOCK_SHELLS := 3
# Fireballs are THE explosion visual — they get their own generous pool so
# accents can never evict them (each is ONE MultiMesh node; the 400/s melt
# was ~280 live nodes, so two dozen is cheap). Flame tongues, embers and
# blood mist are accents: separate, tighter pool, evicted first.
const MAX_LIVE_FIRE_BILLOWS := 24
const MAX_LIVE_ACCENT_BILLOWS := 20

static var _live_blast_lights: Array[Node] = []
static var _live_heat_shells: Array[Node] = []
static var _live_shock_shells: Array[Node] = []
static var _live_fire_billows: Array[Node] = []
static var _live_accent_billows: Array[Node] = []


static func _enroll_alive_capped(pool: Array[Node], node: Node, cap: int) -> void:
	pool.append(node)
	node.tree_exiting.connect(func() -> void: pool.erase(node))
	while pool.size() > cap:
		var old: Node = pool.pop_front()
		if is_instance_valid(old):
			old.queue_free()


const BLAST_LIGHT_FLASH_HOLD := 0.045   # ~1–3 rendered frames before decay
const BLAST_LIGHT_FLASH_DECAY := 0.09
const BLAST_LIGHT_HOT := Color(1.0, 0.995, 0.98)
const BLAST_LIGHT_WARM := Color(1.0, 0.54, 0.12)
const BLAST_FIREBALL_LIGHT_REF_RADIUS := 30.0
const BLAST_FIREBALL_LIGHT_REF_PEAK := 178.0
const BLAST_FIREBALL_LIGHT_SIZE_EXP := 0.92


static func _tween_blast_light_pop(
	light: OmniLight3D,
	peak_energy: float,
	hold_s: float,
	decay_s: float,
	hot_color: Color = BLAST_LIGHT_HOT,
	warm_color: Color = BLAST_LIGHT_WARM,
) -> void:
	# Peak is set immediately (frame 0). Hold keeps energy flat for one flash
	# beat, then energy falls off fast while color drifts hot-white → orange.
	light.light_color = hot_color
	light.light_energy = peak_energy
	var total := hold_s + decay_s
	var ctw := light.create_tween()
	ctw.tween_property(light, "light_color", warm_color, total)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	var etw := light.create_tween()
	if hold_s > 0.0001:
		etw.tween_interval(hold_s)
	etw.tween_property(light, "light_energy", 0.0, decay_s)\
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	etw.tween_callback(light.queue_free)


static func _spawn_blast_flash_light(scene: Node, pos: Vector3, radius: float) -> void:
	var flash := OmniLight3D.new()
	# Scale brightness AND duration with blast size: small pops stay dim/brief, big
	# blasts flash brighter and linger. The old flat 45 base over-lit small blasts.
	var peak := 6.0 + radius * 6.5
	var hold := clampf(0.018 + radius * 0.0035, 0.018, 0.13)
	var decay := clampf(0.05 + radius * 0.008, 0.05, 0.32)
	flash.omni_range = clampf(radius * 6.5, 45.0, 190.0)
	flash.shadow_enabled = false
	_attach_world_3d(scene, flash, pos)
	_tween_blast_light_pop(flash, peak, hold, decay)
	_enroll_alive_capped(_live_blast_lights, flash,
		maxi(4, int(round(MAX_LIVE_BLAST_LIGHTS * vfx_quality_scale()))))


static func _blast_fireball_light_peak(radius: float, energy_mult: float = 1.0) -> float:
	# Sublinear vs blast radius — huge blasts stay hot, small pops stay subtle.
	var t := clampf(radius / BLAST_FIREBALL_LIGHT_REF_RADIUS, 0.0, 1.0)
	return BLAST_FIREBALL_LIGHT_REF_PEAK * pow(t, BLAST_FIREBALL_LIGHT_SIZE_EXP) * energy_mult


static func _tween_blast_fireball_light(
	light: OmniLight3D,
	radius: float,
	color: Color,
	energy_mult: float = 1.0,
	range_start: float = 12.0,
	range_end: float = 40.0,
) -> void:
	# Spike → sustained glow (matches fireball hold) → fade out with the fireball.
	var timing := _blast_fireball_timing(radius)
	var grow: float = timing.grow
	var fade: float = timing.fade
	# Hold through the tongue eruption (which starts ~0.14s after the blast and
	# lingers) before easing out, so the orange glow tracks the whole fireball —
	# not just the initial flash.
	var life: float = (grow + fade) * 1.8
	var hold: float = life * 0.5
	var sustain := _blast_fireball_light_peak(radius, energy_mult)
	var spike := sustain * 1.45
	var spike_s := minf(0.045, grow * 0.2)
	var settle_s := minf(0.055, grow * 0.25)
	var sustain_hold := maxf(0.0, hold - spike_s - settle_s)
	var fade_s := maxf(0.001, life - hold)
	var hot := color.lerp(BLAST_LIGHT_HOT, 0.45)
	var warm := color.lerp(BLAST_LIGHT_WARM, 0.5)
	var end_warm := hot.lerp(BLAST_LIGHT_WARM, 0.65)
	light.light_color = hot
	light.light_energy = spike
	light.omni_range = range_start
	var em_tw := light.create_tween()
	em_tw.tween_interval(spike_s)
	em_tw.tween_property(light, "light_energy", sustain, settle_s)\
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	if sustain_hold > 0.0001:
		em_tw.tween_interval(sustain_hold)
	em_tw.tween_property(light, "light_energy", 0.0, fade_s)\
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	em_tw.tween_callback(light.queue_free)
	light.create_tween().tween_property(light, "omni_range", range_end, life)\
		.set_trans(Tween.TRANS_LINEAR)
	var col_tw := light.create_tween()
	col_tw.tween_property(light, "light_color", warm, life * 0.45)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	col_tw.tween_property(light, "light_color", end_warm, life * 0.55)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)


static func _spawn_blast_fireball_light(scene: Node, pos: Vector3, radius: float, color: Color, energy_mult: float = 1.0) -> void:
	var glow := OmniLight3D.new()
	var ball_radius := maxf(0.5, radius * 0.58)
	var range_start := clampf(ball_radius * 1.2, 10.0, 36.0)
	var range_end := clampf(ball_radius * 3.8, 16.0, 92.0)
	glow.omni_attenuation = 0.42
	# No shadows: this is a ~0.27s flash, so the dual-paraboloid omni shadow map
	# (scene geometry re-rendered per frame, per concurrent fireball) is pure GPU
	# cost on weak hardware for a shadow that flickers by too fast to read.
	glow.shadow_enabled = false
	_attach_world_3d(scene, glow, pos)
	_tween_blast_fireball_light(glow, radius, color, energy_mult, range_start, range_end)
	_enroll_alive_capped(_live_blast_lights, glow,
		maxi(4, int(round(MAX_LIVE_BLAST_LIGHTS * vfx_quality_scale()))))


static func _spawn_bullet_blast_immediate_visuals(
	scene: Node,
	pos: Vector3,
	radius: float,
	color: Color,
	play_audio: bool,
) -> void:
	if radius >= BLAST_DISTORTION_MIN_RADIUS:
		_bench_blast_scope("heat_distortion", func() -> void:
			spawn_heat_distortion(
				scene, pos, radius,
				blast_heat_distortion_duration(radius),
				blast_heat_distortion_strength(radius)))
	_bench_blast_scope("flash_light", func() -> void:
		_spawn_blast_flash_light(scene, pos, radius))
	_bench_blast_scope("fireball_light", func() -> void:
		_spawn_blast_fireball_light(scene, pos, radius, color))
	# Crowd reaction is independent of the explosion-SFX rate limiter — it's
	# cheap state math with its own internal cooldowns.
	CrowdAudio.on_explosion(pos, radius)
	if play_audio and radius >= 3.5:
		if not (BenchFlags.active and BenchFlags.no_explosion_audio) and _claim_explosion_sfx():
			_bench_blast_scope("explosion_audio", func() -> void:
				SFX.explosion(pos, radius))


static func _spawn_bullet_blast_heavy_visuals(
	scene: Node,
	pos: Vector3,
	radius: float,
	color: Color,
) -> void:
	if scene == null or (BenchFlags.active and BenchFlags.no_explosion_visuals):
		return
	_bench_blast_scope("smoke_push", func() -> void:
		_push_nearby_blast_smoke(scene, pos, radius))
	_bench_blast_scope("smoke_billow", func() -> void:
		spawn_blast_fire_smoke(scene, pos, radius, color))
	_bench_blast_scope("fire_billow", func() -> void:
		spawn_blast_fire_clouds(scene, pos, radius, color))
	_bench_blast_scope("flame_shards", func() -> void:
		spawn_blast_flame_shards(scene, pos, radius, color))
	_bench_blast_scope("embers", func() -> void:
		spawn_blast_embers(scene, pos, radius, color))


static func _spawn_bullet_blast_feedback(
	scene: Node,
	pos: Vector3,
	radius: float,
	local_player: Node,
) -> void:
	if scene.has_method("trigger_explosion_sidechain"):
		_bench_blast_scope("sidechain", func() -> void:
			var sidechain_peak := clampf(radius / 5.0, 0.35, 3.0)
			scene.trigger_explosion_sidechain(pos, radius, sidechain_peak))
	if local_player and is_instance_valid(local_player) and local_player.has_method("apply_explosion_view_punch"):
		_bench_blast_scope("view_punch", func() -> void:
			var punch_peak := clampf(radius / 5.0, 0.45, 1.6)
			local_player.apply_explosion_view_punch(pos, radius, punch_peak))


static func _spawn_cheap_blast_flare(scene: Node, pos: Vector3, radius: float, color: Color) -> void:
	if scene == null or radius <= 0.0 or not _claim_cheap_blast(pos):
		return
	_spawn_blast_fireball_light(scene, pos, radius, color, 0.65)
	if _claim_cheap_light():
		_spawn_blast_flash_light(scene, pos, radius)
	# A blast with no fireball reads as a misfire. The budget flare gets the
	# FULL original fireball (spawn_blast_fire_clouds — one MultiMesh node
	# regardless of puff count, protected by the fire-billow pool); what the
	# flare skips is the trimmings: smoke, distortion, shards, embers. Added
	# after a playtest where governor shed 2 stripped every fireball from a
	# whole fight.
	spawn_blast_fire_clouds(scene, pos, radius, color)


# Bigger blasts expand further, hold a hotter core, and pump a brighter
# point light — stacked EXPLOSIVE ROUNDS cards should feel earth-shaking.
# `local_player` (optional) is the local human's player; if provided, gets a
# view-punch + is checked against the scene's exposure sidechain hook.
static func spawn_bullet_blast(
	scene: Node,
	pos: Vector3,
	radius: float,
	color: Color,
	local_player: Node = null,
	play_audio: bool = true,
	defer_heavy: bool = true,
) -> void:
	if scene == null:
		return
	var t0 := Time.get_ticks_usec() if BenchFlags.active else 0
	var eligible := _full_blast_eligible_except_frame_cap(pos)
	var full_blast := eligible and _claim_full_blast(pos)
	if full_blast:
		_spawn_bullet_blast_feedback(scene, pos, radius, local_player)
		_spawn_bullet_blast_immediate_visuals(scene, pos, radius, color, play_audio)
		if defer_heavy:
			_enqueue_blast_visual_job(scene, pos, radius, color, play_audio, false)
	elif eligible:
		_spawn_bullet_blast_feedback(scene, pos, radius, local_player)
		_reserve_full_blast_slot(pos)
		if defer_heavy:
			_enqueue_blast_visual_job(scene, pos, radius, color, play_audio, true)
	else:
		_bench_blast_scope("cheap_flare", func() -> void:
			_spawn_cheap_blast_flare(scene, pos, radius, color))
		if BenchFlags.active:
			_bench_blast_prof("blast_total", Time.get_ticks_usec() - t0)
			_bench_blast_n["blast_calls"] = int(_bench_blast_n.get("blast_calls", 0)) + 1
			_bench_blast_n["blast_cheap"] = int(_bench_blast_n.get("blast_cheap", 0)) + 1
		return
	if BenchFlags.active:
		_bench_blast_prof("blast_total", Time.get_ticks_usec() - t0)
		_bench_blast_n["blast_calls"] = int(_bench_blast_n.get("blast_calls", 0)) + 1
		_bench_blast_n["blast_full"] = int(_bench_blast_n.get("blast_full", 0)) + 1

static func spawn_smoke_puff(
	scene: Node,
	pos: Vector3,
	size: float = 1.0,
	drift: Vector3 = Vector3.UP,
	lifetime: float = 2.5,
	tint: Color = Color(0.42, 0.40, 0.36, 0.52),
	rise_mult: float = 1.0,
) -> void:
	if scene == null or (BenchFlags.active and BenchFlags.no_explosion_visuals):
		return
	if not _can_spawn_smoke_puff():
		return
	_active_smoke_puffs += 1
	var puff := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.35 * size
	mesh.height = 0.7 * size
	mesh.radial_segments = 8
	mesh.rings = 4
	puff.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color(tint.r, tint.g, tint.b, 0.0)
	puff.material_override = mat
	puff.position = pos
	puff.scale = Vector3.ONE * 0.06
	puff.add_to_group("smoke_puffs")
	scene.add_child(puff)
	var drift_norm := drift
	if drift_norm.length_squared() < 0.0001:
		drift_norm = Vector3.UP
	else:
		drift_norm = drift_norm.normalized()
	var horizontal := Vector3(drift_norm.x, 0.0, drift_norm.z)
	var lateral_dist := size * randf_range(0.35, 1.05)
	if horizontal.length_squared() > 0.0001:
		horizontal = horizontal.normalized() * lateral_dist
	else:
		horizontal = Vector3.ZERO
	var rise_dist := size * randf_range(2.6, 5.4) * rise_mult
	var end_pos := pos + horizontal + Vector3.UP * rise_dist
	var end_scale := Vector3.ONE * randf_range(1.2, 2.1) * maxf(size, 0.35)
	var peak := Color(tint.r, tint.g, tint.b, tint.a)
	var tw := puff.create_tween().set_parallel(true)
	tw.tween_property(puff, "position", end_pos, lifetime)\
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(puff, "scale", end_scale, lifetime * 0.88)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	var atw := puff.create_tween()
	atw.tween_property(mat, "albedo_color", peak, lifetime * 0.22)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	atw.tween_property(mat, "albedo_color", Color(tint.r, tint.g, tint.b, 0.0), lifetime * 0.72)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	atw.tween_callback(func() -> void:
		_active_smoke_puffs = maxi(0, _active_smoke_puffs - 1)
		if is_instance_valid(puff):
			puff.queue_free()
	)


static func spawn_exhaust_smoke(scene: Node, pos: Vector3, size: float, drift: Vector3) -> void:
	var tint := Color(
		randf_range(0.58, 0.68),
		randf_range(0.54, 0.62),
		randf_range(0.48, 0.56),
		randf_range(0.10, 0.18),
	)
	spawn_smoke_puff(
		scene,
		pos,
		size * 0.28,
		drift,
		randf_range(0.75, 1.35),
		tint,
		1.85,
	)


static func spawn_blast_smoke(scene: Node, pos: Vector3, radius: float) -> void:
	if scene == null or radius <= 0.0 or (BenchFlags.active and BenchFlags.no_explosion_visuals):
		return
	if not _claim_smoke_burst():
		return
	var ground := pos + Vector3.UP * 0.35
	var scale := clampf(radius / 14.0, 0.55, 2.4)
	for i in int(clampf(radius * 0.18, 4, 10)):
		var ang := randf() * TAU
		var rad := randf_range(0.0, radius * 0.34)
		var offset := Vector3(cos(ang) * rad, randf_range(0.0, 1.2), sin(ang) * rad)
		var dark := i % 3 == 0
		var tint := Color(
			randf_range(0.18, 0.28) if dark else randf_range(0.42, 0.50),
			randf_range(0.16, 0.24) if dark else randf_range(0.40, 0.46),
			randf_range(0.14, 0.22) if dark else randf_range(0.36, 0.42),
			randf_range(0.22, 0.36),
		)
		spawn_smoke_puff(
			scene,
			ground + offset,
			randf_range(1.8, 3.8) * scale,
			Vector3(
				randf_range(-1.0, 1.0),
				randf_range(1.6, 4.0),
				randf_range(-1.0, 1.0),
			).normalized(),
			randf_range(4.0, 7.0),
			tint,
		)
	var column_count := int(clampf(radius * 0.12, 2, 6))
	for j in column_count:
		if not _claim_pending_smoke_puff():
			continue
		var delay := float(j) * 0.16
		# .bind a static helper (not a capturing lambda): if `scene` frees before
		# the timer fires (match restart), the helper still runs the budget
		# decrement — preventing a permanent _pending_smoke_puffs leak — then
		# bails on the freed scene. A capturing lambda would error and skip both.
		scene.get_tree().create_timer(delay).timeout.connect(
			_emit_delayed_smoke_puff.bind(scene, ground, radius, scale), CONNECT_ONE_SHOT)


static func _emit_delayed_smoke_puff(scene: Node, ground: Vector3, radius: float, scale: float) -> void:
	# Always release the budget slot first, even if the scene is already gone.
	_pending_smoke_puffs = maxi(0, _pending_smoke_puffs - 1)
	if not is_instance_valid(scene):
		return
	var ring := randf_range(0.0, radius * 0.16)
	var ang2 := randf() * TAU
	var col_offset := Vector3(cos(ang2) * ring, randf_range(1.0, 3.0), sin(ang2) * ring)
	spawn_smoke_puff(
		scene,
		ground + col_offset,
		randf_range(2.2, 4.5) * scale,
		Vector3(randf_range(-0.25, 0.25), randf_range(2.8, 5.0), randf_range(-0.25, 0.25)),
		randf_range(5.0, 8.5),
		Color(0.34, 0.32, 0.30, randf_range(0.18, 0.30)),
	)

static func blast_heat_distortion_duration(radius: float) -> float:
	return clampf(0.42 + radius * 0.018, 0.42, 0.95)


static func blast_heat_distortion_strength(radius: float) -> float:
	return clampf(radius * 0.026, 0.11, 0.26)


static func spawn_heat_distortion(scene: Node, pos: Vector3, radius: float, duration: float, strength: float) -> void:
	if scene == null:
		return
	var shell := MeshInstance3D.new()
	if _heat_mesh == null:
		_heat_mesh = SphereMesh.new()
		_heat_mesh.radius = 0.22
		_heat_mesh.height = 0.44
		_heat_mesh.radial_segments = 8
		_heat_mesh.rings = 4
	shell.mesh = _heat_mesh
	if _heat_shader == null:
		_heat_shader = Shader.new()
		_heat_shader.code = """
			shader_type spatial;
			render_mode unshaded, cull_disabled, depth_draw_never;

			uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
			uniform float distortion_strength = 0.04;
			uniform float zoom_strength = 0.015;
			uniform float opacity = 0.18;
			uniform float falloff = 1.0;

			void fragment() {
				vec3 n = normalize((VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
				float fresnel = pow(1.0 - abs(dot(normalize(VIEW), NORMAL)), 1.1);
				float weight = 0.38 + 0.62 * fresnel;
				vec2 offset = n.xy * distortion_strength * weight * falloff;
				vec2 zoom = (SCREEN_UV - vec2(0.5)) * zoom_strength * weight * falloff;
				vec2 uv = SCREEN_UV - zoom + offset;
				// smooth refraction — no pixel snap
				vec3 col = texture(screen_tex, uv).rgb;
				// smooth — no colour posterise
				ALBEDO = col;
				ALPHA = opacity * weight * falloff;
			}
		"""
	var mat := ShaderMaterial.new()
	mat.shader = _heat_shader
	# Static base magnitudes; a single `falloff` uniform animates the whole effect
	# out, so we tween one param instead of allocating three closures per blast.
	mat.set_shader_parameter("distortion_strength", strength * 5.2)
	mat.set_shader_parameter("zoom_strength", strength * 1.4)
	mat.set_shader_parameter("opacity", 1.0)
	mat.set_shader_parameter("falloff", 1.0)
	shell.material_override = mat
	_attach_world_3d(scene, shell, pos)
	# Each shell forces a backbuffer copy (hint_screen_texture) — the single
	# most expensive blast component under sustained fire. Overlapping heat
	# shimmer is visual mush anyway; hard-cap the live population.
	_enroll_alive_capped(_live_heat_shells, shell,
		maxi(1, int(round(MAX_LIVE_HEAT_SHELLS * vfx_quality_scale()))))

	var target_scale := Vector3.ONE * maxf(0.01, (radius * 2.2) / _heat_mesh.radius)
	var tw := shell.create_tween().set_parallel(true)
	tw.tween_property(shell, "scale", target_scale, duration)\
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.tween_method(
		func(v: float) -> void: mat.set_shader_parameter("falloff", v),
		1.0,
		0.0,
		duration * 0.9
	).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.chain().tween_callback(shell.queue_free)

# Thin-shell screen-space shockwave: sphere expanding at the speed of sound.
# High-power fresnel concentrates the pixel displacement on the silhouette
# ring so the camera sees a thin distorted halo travelling outward — the
# "shock front" — while the heat distortion handles the slower bloom.
static func spawn_shockwave_ring(scene: Node, pos: Vector3, radius: float) -> void:
	if scene == null:
		return
	var shell := MeshInstance3D.new()
	if _shock_mesh == null:
		_shock_mesh = SphereMesh.new()
		_shock_mesh.radius = 0.25
		_shock_mesh.height = 0.5
		_shock_mesh.radial_segments = 8
		_shock_mesh.rings = 4
	shell.mesh = _shock_mesh
	if _shock_shader == null:
		_shock_shader = Shader.new()
		_shock_shader.code = """
			shader_type spatial;
			render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
			uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
			uniform float opacity = 0.9;
			uniform float ring_thickness = 4.0;
			uniform float distortion_strength = 0.16;

			void fragment() {
				// High exponent -> energy concentrated on silhouette ring only.
				float fresnel = pow(1.0 - abs(dot(normalize(VIEW), NORMAL)), ring_thickness);
				vec3 n = normalize((VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
				vec2 offset = n.xy * distortion_strength * fresnel;
				vec2 uv = SCREEN_UV + offset;
				// smooth refraction — no pixel snap
				vec3 col = texture(screen_tex, uv).rgb;
				// smooth — no colour posterise
				ALBEDO = col;
				ALPHA = fresnel * opacity;
			}
		"""
	var mat := ShaderMaterial.new()
	mat.shader = _shock_shader
	mat.set_shader_parameter("distortion_strength", 0.16)
	mat.set_shader_parameter("ring_thickness", 4.0)
	mat.set_shader_parameter("opacity", 0.95)
	shell.material_override = mat
	_attach_world_3d(scene, shell, pos)
	_enroll_alive_capped(_live_shock_shells, shell,
		maxi(1, int(round(MAX_LIVE_SHOCK_SHELLS * vfx_quality_scale()))))
	# Roughly sound-speed expansion, slowed a touch + 0.12s floor so the shock
	# front is actually visible rather than a single-frame flicker.
	var dur: float = maxf(0.3, radius / 343.0 * 3.5)
	var target_scale := Vector3.ONE * maxf(0.01, (radius * 1.9) / _shock_mesh.radius)
	var tw := shell.create_tween().set_parallel(true)
	tw.tween_property(shell, "scale", target_scale, dur)\
		.set_trans(Tween.TRANS_LINEAR).set_ease(Tween.EASE_OUT)
	tw.tween_method(
		func(v: float) -> void: mat.set_shader_parameter("distortion_strength", v),
		0.16,
		0.0,
		dur
	).set_trans(Tween.TRANS_LINEAR).set_ease(Tween.EASE_OUT)
	tw.tween_method(
		func(v: float) -> void: mat.set_shader_parameter("opacity", v),
		0.95,
		0.0,
		dur * 0.9
	).set_trans(Tween.TRANS_LINEAR).set_ease(Tween.EASE_OUT)
	tw.chain().tween_callback(shell.queue_free)

# Coop enemy incoming: hot pentagram on the ground — hell's door before they rise.
# Warms up, holds at peak until dismiss_enemy_incoming_telegraph* is called on spawn.
const ENEMY_INCOMING_TELEGRAPH_COOLDOWN := 0.55
const PENTAGRAM_BEAM_HEIGHT := 20.0

# Shared orange-red hell-emerge palette (pentagram telegraph + rising character).
static func hell_emerge_cool_color() -> Color:
	return Color(0.5, 0.05, 0.015)

static func hell_emerge_warm_body_color() -> Color:
	return Color(0.72, 0.14, 0.04)

static func hell_emerge_hot_albedo_color() -> Color:
	return Color(1.0, 0.38, 0.06)

static func hell_emerge_hot_emission_color() -> Color:
	return Color(1.0, 0.42, 0.05)

static func hell_emerge_peak_light_color() -> Color:
	return Color(1.0, 0.48, 0.08)

static func hell_emerge_ash_color() -> Color:
	return Color(0.65, 0.1, 0.04)

static func hell_emerge_glow_color(heat: float) -> Color:
	var h := clampf(heat, 0.0, 1.0)
	var temp := hell_emerge_cool_color().lerp(hell_emerge_warm_body_color(), smoothstep(0.0, 0.35, h))
	temp = temp.lerp(hell_emerge_hot_emission_color(), smoothstep(0.35, 0.75, h))
	return temp.lerp(hell_emerge_peak_light_color(), smoothstep(0.75, 1.0, h))


static func ease_out_cubic(t: float) -> float:
	var x := clampf(t, 0.0, 1.0)
	return 1.0 - pow(1.0 - x, 3.0)
static func spawn_enemy_incoming_telegraph(
	scene: Node,
	pos: Vector3,
	warmup_duration: float = 0.65,
	star_radius: float = 1.05,
	beam_height: float = -1.0,
) -> Node3D:
	if scene == null or not is_instance_valid(scene):
		return null
	warmup_duration = clampf(warmup_duration, 0.2, 3.0)
	star_radius = maxf(0.4, star_radius)
	if beam_height <= 0.0:
		beam_height = PENTAGRAM_BEAM_HEIGHT
	beam_height = clampf(beam_height, 8.0, 52.0)
	var line_scale := star_radius / 1.05

	var ground := _ground_surface_at(scene, pos)

	var anchor := Node3D.new()
	anchor.name = "EnemyIncomingTelegraph"
	anchor.add_to_group("enemy_incoming_telegraph")
	anchor.set_meta("telegraph_pos", pos)
	scene.add_child(anchor)
	anchor.global_position = ground

	var pentagram := Node3D.new()
	pentagram.name = "Pentagram"
	anchor.add_child(pentagram)

	var star_mat := _make_pentagram_glow_material(Violence.hell_emerge_hot_emission_color())
	var core_mat := _make_pentagram_glow_material(Violence.hell_emerge_peak_light_color())
	var decal_y := 0.1
	_add_pentagram_decal(
		pentagram,
		_build_pentagram_circle_mesh(star_radius, 0.13 * line_scale, decal_y),
		star_mat,
	)
	_add_pentagram_decal(
		pentagram,
		_build_pentagram_star_mesh(star_radius, 0.18 * line_scale, decal_y + 0.008),
		star_mat,
	)
	_add_pentagram_decal(
		pentagram,
		_build_pentagram_star_mesh(star_radius, 0.08 * line_scale, decal_y + 0.012),
		core_mat,
	)

	var beam_mat := _make_pentagram_beam_material(Violence.hell_emerge_hot_emission_color())
	beam_mat.set_shader_parameter("beam_height", beam_height)
	var beam := MeshInstance3D.new()
	beam.name = "HeatBeam"
	var beam_mesh := CylinderMesh.new()
	beam_mesh.top_radius = star_radius
	beam_mesh.bottom_radius = star_radius
	beam_mesh.height = beam_height
	beam_mesh.radial_segments = 32
	beam_mesh.rings = 1
	beam.mesh = beam_mesh
	beam.material_override = beam_mat
	beam.position.y = beam_height * 0.5
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	anchor.add_child(beam)

	var ground_light := OmniLight3D.new()
	ground_light.light_color = Violence.hell_emerge_cool_color()
	ground_light.light_energy = 0.0
	ground_light.omni_range = 8.5 * line_scale
	ground_light.position.y = 0.35
	anchor.add_child(ground_light)

	var vfx := {
		"star_mat": star_mat,
		"core_mat": core_mat,
		"beam_mat": beam_mat,
		"ground_light": ground_light,
	}
	anchor.set_meta("pentagram_vfx", vfx)
	anchor.set_meta("pentagram_heat", 0.0)

	_apply_pentagram_heat(star_mat, core_mat, ground_light, 0.0, beam_mat)

	var apply_heat := func(h: float) -> void:
		if is_instance_valid(anchor):
			anchor.set_meta("pentagram_heat", h)
		_apply_pentagram_heat(star_mat, core_mat, ground_light, h, beam_mat)

	var tw := anchor.create_tween()
	anchor.set_meta("intro_tween", tw)
	tw.tween_method(apply_heat, 0.0, 1.0, warmup_duration)\
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_callback(func() -> void:
		if is_instance_valid(anchor):
			anchor.set_meta("pentagram_heat", 1.0)
			apply_heat.call(1.0)
	)
	return anchor


static func dismiss_enemy_incoming_telegraph(anchor: Node3D, cool_duration: float = 0.55) -> void:
	if anchor == null or not is_instance_valid(anchor):
		return
	var vfx: Variant = anchor.get_meta("pentagram_vfx", null)
	if vfx == null or not (vfx is Dictionary):
		anchor.queue_free()
		return
	var intro: Variant = anchor.get_meta("intro_tween", null)
	if intro is Tween and (intro as Tween).is_valid():
		(intro as Tween).kill()
	var star_mat: ShaderMaterial = vfx["star_mat"]
	var core_mat: ShaderMaterial = vfx["core_mat"]
	var beam_mat: ShaderMaterial = vfx.get("beam_mat")
	var ground_light: OmniLight3D = vfx["ground_light"]
	var start_heat := float(anchor.get_meta("pentagram_heat", 1.0))
	cool_duration = clampf(cool_duration, 0.15, 2.0)
	var apply_heat := func(h: float) -> void:
		if is_instance_valid(anchor):
			anchor.set_meta("pentagram_heat", h)
		_apply_pentagram_heat(star_mat, core_mat, ground_light, h, beam_mat)
	var tw := anchor.create_tween()
	tw.tween_method(apply_heat, start_heat, 0.0, cool_duration)\
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_callback(anchor.queue_free)


static func dismiss_enemy_incoming_telegraph_at(scene: Node, pos: Vector3, cool_duration: float = 0.55) -> void:
	if scene == null or not is_instance_valid(scene):
		return
	var best: Node3D = null
	var best_dist := 1.6
	for node in scene.get_tree().get_nodes_in_group("enemy_incoming_telegraph"):
		if not node is Node3D or not is_instance_valid(node):
			continue
		var flat := Vector2(node.global_position.x - pos.x, node.global_position.z - pos.z)
		var dist := flat.length()
		if dist < best_dist:
			best_dist = dist
			best = node as Node3D
	if best:
		dismiss_enemy_incoming_telegraph(best, cool_duration)


static func hell_emerge_stand_pos(scene: Node, world_pos: Vector3, half_height: float = 0.9) -> Vector3:
	var world: World3D = scene.get_world_3d() if scene else null
	var space: PhysicsDirectSpaceState3D = world.direct_space_state if world else null
	if space == null:
		return world_pos
	var from := world_pos + Vector3.UP * 3.0
	var to := world_pos + Vector3.DOWN * 24.0
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 1
	query.collide_with_areas = false
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		return world_pos
	var floor_y: float = hit.get("position", world_pos).y
	return Vector3(world_pos.x, floor_y + maxf(0.2, half_height), world_pos.z)


static func _ground_surface_at(scene: Node, world_pos: Vector3) -> Vector3:
	var world: World3D = scene.get_world_3d() if scene else null
	var space: PhysicsDirectSpaceState3D = world.direct_space_state if world else null
	if space == null:
		return world_pos
	var from := world_pos + Vector3.UP * 3.0
	var to := world_pos + Vector3.DOWN * 24.0
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 1
	query.collide_with_areas = false
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		return world_pos + Vector3.UP * 0.08
	var floor_y: float = hit.get("position", world_pos).y
	return Vector3(world_pos.x, floor_y + 0.14, world_pos.z)


static func _make_pentagram_beam_material(tint: Color) -> ShaderMaterial:
	if _pentagram_beam_shader == null:
		_pentagram_beam_shader = Shader.new()
		_pentagram_beam_shader.code = """
			shader_type spatial;
			render_mode unshaded, cull_disabled, depth_draw_never, blend_add;

			uniform vec3 tint_color = vec3(1.0, 0.35, 0.05);
			uniform float glow = 1.0;
			uniform float beam_height = 20.0;
			uniform float intensity = 0.32;

			varying float height_t;

			void vertex() {
				height_t = clamp((VERTEX.y + beam_height * 0.5) / beam_height, 0.0, 1.0);
			}

			void fragment() {
				float fade = pow(1.0 - height_t, 1.35);
				float strength = glow * intensity * fade;
				ALBEDO = tint_color * strength;
				ALPHA = strength;
			}
		"""
	var mat := ShaderMaterial.new()
	mat.shader = _pentagram_beam_shader
	mat.set_shader_parameter("tint_color", Vector3(tint.r, tint.g, tint.b))
	mat.set_shader_parameter("glow", 0.0)
	mat.set_shader_parameter("beam_height", PENTAGRAM_BEAM_HEIGHT)
	return mat


static func _make_pentagram_glow_material(tint: Color) -> ShaderMaterial:
	if _pentagram_glow_shader == null:
		_pentagram_glow_shader = Shader.new()
		_pentagram_glow_shader.code = """
			shader_type spatial;
			render_mode unshaded, cull_disabled, depth_draw_never, blend_add;

			uniform vec3 tint_color = vec3(1.0, 0.28, 0.05);
			uniform float glow = 1.0;

			void fragment() {
				ALBEDO = tint_color * glow;
				ALPHA = 1.0;
			}
		"""
	var mat := ShaderMaterial.new()
	mat.shader = _pentagram_glow_shader
	mat.set_shader_parameter("tint_color", Vector3(tint.r, tint.g, tint.b))
	mat.set_shader_parameter("glow", 0.0)
	return mat


static func _add_pentagram_decal(parent: Node3D, mesh: ArrayMesh, mat: Material) -> MeshInstance3D:
	var decal := MeshInstance3D.new()
	decal.mesh = mesh
	decal.material_override = mat
	decal.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(decal)
	return decal


static func _add_flat_quad(st: SurfaceTool, v0: Vector3, v1: Vector3, v2: Vector3, v3: Vector3, base: int) -> int:
	for v in [v0, v1, v2, v3]:
		st.set_normal(Vector3.UP)
		st.add_vertex(v)
	st.add_index(base)
	st.add_index(base + 2)
	st.add_index(base + 1)
	st.add_index(base)
	st.add_index(base + 3)
	st.add_index(base + 2)
	return base + 4


static func _build_pentagram_star_mesh(radius: float, line_width: float, y: float) -> ArrayMesh:
	var outer := _pentagram_points(radius, y)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var idx := 0
	for i in 5:
		var a: Vector3 = outer[i]
		var b: Vector3 = outer[(i + 2) % 5]
		var delta := Vector3(b.x - a.x, 0.0, b.z - a.z)
		var len := delta.length()
		if len < 0.001:
			continue
		var dir := delta / len
		var perp := Vector3(-dir.z, 0.0, dir.x) * (line_width * 0.5)
		var v0 := Vector3(a.x, y, a.z) + perp
		var v1 := Vector3(a.x, y, a.z) - perp
		var v2 := Vector3(b.x, y, b.z) - perp
		var v3 := Vector3(b.x, y, b.z) + perp
		idx = _add_flat_quad(st, v0, v1, v2, v3, idx)
	return st.commit()


static func _build_pentagram_circle_mesh(radius: float, line_width: float, y: float, segments: int = 64) -> ArrayMesh:
	var inner_r := maxf(0.05, radius - line_width * 0.5)
	var outer_r := radius + line_width * 0.5
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var idx := 0
	segments = maxi(segments, 24)
	for i in segments:
		var a0 := float(i) / float(segments) * TAU
		var a1 := float(i + 1) / float(segments) * TAU
		var p0i := Vector3(cos(a0) * inner_r, y, sin(a0) * inner_r)
		var p1i := Vector3(cos(a1) * inner_r, y, sin(a1) * inner_r)
		var p0o := Vector3(cos(a0) * outer_r, y, sin(a0) * outer_r)
		var p1o := Vector3(cos(a1) * outer_r, y, sin(a1) * outer_r)
		idx = _add_flat_quad(st, p0i, p1i, p1o, p0o, idx)
	return st.commit()


static func _pentagram_points(radius: float, y: float) -> PackedVector3Array:
	var pts := PackedVector3Array()
	pts.resize(5)
	for i in 5:
		var angle := -PI * 0.5 + float(i) * TAU / 5.0
		pts[i] = Vector3(cos(angle) * radius, y, sin(angle) * radius)
	return pts


static func _apply_pentagram_heat(
	star_mat: ShaderMaterial,
	core_mat: ShaderMaterial,
	ground_light: OmniLight3D,
	heat: float,
	beam_mat: ShaderMaterial = null,
) -> void:
	var h := clampf(heat, 0.0, 1.0)
	var eased := ease_out_cubic(h)
	var glow := eased * 1.5
	var star_col := hell_emerge_glow_color(eased)
	var core_col := star_col.lerp(hell_emerge_peak_light_color(), 0.35)
	star_mat.set_shader_parameter("tint_color", Vector3(star_col.r, star_col.g, star_col.b))
	star_mat.set_shader_parameter("glow", glow)
	core_mat.set_shader_parameter("tint_color", Vector3(core_col.r, core_col.g, core_col.b))
	core_mat.set_shader_parameter("glow", glow * 1.2)
	if beam_mat:
		var beam_col := star_col.lerp(hell_emerge_peak_light_color(), 0.2)
		beam_mat.set_shader_parameter("tint_color", Vector3(beam_col.r, beam_col.g, beam_col.b))
		beam_mat.set_shader_parameter("glow", glow * 0.35)
	if ground_light and is_instance_valid(ground_light):
		ground_light.light_energy = lerpf(0.0, 11.0, eased)
		ground_light.light_color = hell_emerge_cool_color().lerp(hell_emerge_peak_light_color(), eased)


# `vfx_max_*`: caller passes the budget caps so the global VFX flag stays
# in player.gd (along with all other dev toggles).
static func spawn_impact(scene: Node, pos: Vector3, color: Color = Color(1.0, 0.9, 0.3), scale_f: float = 1.0, dmg_ratio: float = 1.0, vfx_max_impact_dust: int = 5, normal: Vector3 = Vector3.UP, explosive_radius: float = 0.0, collider: Node = null) -> void:
	if scene == null:
		return
	# Explosive hits spawn a full blast VFX stack — skip the per-bullet spark,
	# dust, lights, and rock chips (major savings for minigun + explosive).
	if explosive_radius > 0.0:
		return
	# Heavier guns leave a bigger puff of dust + a brighter spark, and once
	# damage is very high we add a second "heat flash" — as if the slug is
	# hot enough to burn the ground it lands in. Surface scarring is handled
	# by DestructibleManager; no glow decals here.
	var sz: float = scale_f * dmg_ratio
	var spark_boost: float = lerpf(1.0, 2.5, clampf((dmg_ratio - 1.0) / 4.0, 0.0, 1.0))

	# Heavy hits flash a brief colored point light at the impact. Pistol-base
	# shots stay dark so the GPU doesn't burn cycles on every plink.
	if dmg_ratio > 1.4:
		var light := OmniLight3D.new()
		light.light_color = color
		light.light_energy = 3.5 * scale_f * spark_boost
		light.omni_range = 2.2 * sz
		light.position = pos
		scene.add_child(light)
		var ltw := light.create_tween()
		ltw.tween_property(light, "light_energy", 0.0, 0.12) \
			.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
		ltw.tween_callback(light.queue_free)

	# Heat flash: a very brief, almost-white burst for very-high-damage hits.
	if dmg_ratio > 2.2:
		var heat := OmniLight3D.new()
		heat.light_color = Color(1.0, 0.88, 0.65)
		heat.light_energy = 6.0 + 3.0 * dmg_ratio
		heat.omni_range = 1.4 + 0.45 * dmg_ratio
		heat.position = pos
		scene.add_child(heat)
		var htw := heat.create_tween()
		htw.tween_property(heat, "light_energy", 0.0, 0.08) \
			.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
		htw.tween_callback(heat.queue_free)

	var heavy_impact := dmg_ratio > 1.35 or scale_f > 1.35
	if heavy_impact:
		_spawn_impact_rock_chips(scene, pos, normal, scale_f, dmg_ratio, collider, color)

	# A handful of dust particles scattering outward and falling.
	var dust_count: int = int(clampf(3.0 * dmg_ratio, 2.0, 15.0))
	if heavy_impact:
		dust_count = 0
	var dust_color := _surface_color_from_collider(collider, color).lerp(Color(0.72, 0.66, 0.55), 0.35)
	for i in dust_count:
		var dust := MeshInstance3D.new()
		var m := SphereMesh.new()
		m.radius = 0.035 * sz
		m.height = 0.07 * sz
		m.radial_segments = 6
		m.rings = 3
		dust.mesh = m
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(dust_color.r, dust_color.g, dust_color.b, 0.6)
		dust.material_override = mat
		dust.position = pos
		scene.add_child(dust)
		var dir := Vector3(
			randf_range(-1.0, 1.0),
			randf_range(0.1, 1.0),
			randf_range(-1.0, 1.0),
		).normalized()
		var end := pos + dir * randf_range(0.25, 0.7) * sz
		var tw := dust.create_tween().set_parallel(true)
		tw.tween_property(dust, "position", end, 0.35) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tw.tween_property(mat, "albedo_color", Color(dust_color.r, dust_color.g, dust_color.b, 0.0), 0.4)
		tw.chain().tween_callback(dust.queue_free)

# Brief high-intensity beam for hitscan bullets — HDR additive line with bloom.
static var _laser_line_mesh: BoxMesh = null
static var _laser_tracer_shader: Shader = null
static var _laser_tracer_mat_templates: Dictionary = {}


static func _get_laser_line_mesh() -> BoxMesh:
	if _laser_line_mesh == null:
		_laser_line_mesh = BoxMesh.new()
		_laser_line_mesh.size = Vector3.ONE
	return _laser_line_mesh


static func _get_laser_tracer_shader() -> Shader:
	if _laser_tracer_shader == null:
		_laser_tracer_shader = load("res://shaders/laser_tracer.gdshader") as Shader
	return _laser_tracer_shader


static func _create_laser_tracer_material(alpha: float) -> ShaderMaterial:
	var key := int(clampf(alpha, 0.0, 1.0) * 32.0)
	var template: ShaderMaterial = _laser_tracer_mat_templates.get(key)
	if template == null:
		template = ShaderMaterial.new()
		template.shader = _get_laser_tracer_shader()
		var a := float(key) / 32.0
		template.set_shader_parameter("beam_color", Color(1.0, 0.96, 0.88, a if a > 0.01 else 1.0))
		template.set_shader_parameter("bloom_gain", 14.0 if alpha >= 0.99 else 7.0)
		template.set_shader_parameter("beam_radius", 0.013 if alpha >= 0.99 else 0.009)
		_laser_tracer_mat_templates[key] = template
	var mat := template.duplicate() as ShaderMaterial
	mat.set_shader_parameter("alpha_scale", 1.0)
	return mat


static var _laser_light_frame := -1

static func spawn_laser_tracer(scene: Node, from: Vector3, to: Vector3, alpha: float = 1.0) -> void:
	if scene == null:
		return
	var dist := from.distance_to(to)
	if dist < 0.1:
		return
	alpha = clampf(alpha, 0.0, 1.0)

	var line := MeshInstance3D.new()
	line.mesh = _get_laser_line_mesh()
	var mat := _create_laser_tracer_material(alpha)
	mat.set_shader_parameter("head_world", from)
	mat.set_shader_parameter("tail_world", to)
	line.material_override = mat

	scene.add_child(line)
	var thickness := 0.026 if alpha >= 1.0 else 0.016
	line.scale = Vector3(thickness, thickness, dist)
	line.global_position = from.lerp(to, 0.5)

	if absf((to - from).normalized().dot(Vector3.UP)) > 0.99:
		line.look_at(to, Vector3.RIGHT)
	else:
		line.look_at(to, Vector3.UP)

	# One flash light per frame: a laser trigger fires ten beams at once, and
	# ten stacked 10-energy lights at the muzzle white out the whole view.
	var light: OmniLight3D = null
	var frame := Engine.get_process_frames()
	if alpha >= 1.0 and frame != _laser_light_frame:
		_laser_light_frame = frame
		light = OmniLight3D.new()
		light.light_color = Color(1.0, 0.95, 0.85)
		light.light_energy = 10.0
		light.omni_range = 4.0
		scene.add_child(light)
		light.global_position = from

	var tw := line.create_tween()
	tw.tween_interval(0.03)
	tw.tween_method(
		func(v: float) -> void: mat.set_shader_parameter("alpha_scale", v),
		1.0, 0.0, 0.055)
	tw.tween_callback(line.queue_free)

	if light:
		var ltw := light.create_tween()
		ltw.tween_property(light, "light_energy", 0.0, 0.08)
		ltw.tween_callback(light.queue_free)

static var _impact_chip_meshes: Array[Mesh] = []

static func _build_impact_chip_mesh(variant: int) -> Mesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(["impact_chip", variant])
	var top := Vector3(0.0, rng.randf_range(0.42, 0.62), 0.0)
	var bottom := Vector3(0.0, -rng.randf_range(0.34, 0.52), 0.0)
	var upper: Array[Vector3] = []
	var lower: Array[Vector3] = []
	for i in 5:
		var a := float(i) / 5.0 * TAU + rng.randf_range(-0.18, 0.18)
		var r1 := rng.randf_range(0.36, 0.62)
		var r2 := rng.randf_range(0.28, 0.56)
		upper.append(Vector3(cos(a) * r1, rng.randf_range(0.04, 0.22), sin(a) * r1))
		lower.append(Vector3(cos(a + rng.randf_range(-0.16, 0.16)) * r2, rng.randf_range(-0.26, -0.05), sin(a) * r2))
	var min_v := top
	var max_v := top
	for p in [bottom]:
		min_v = min_v.min(p)
		max_v = max_v.max(p)
	for p in upper:
		min_v = min_v.min(p)
		max_v = max_v.max(p)
	for p in lower:
		min_v = min_v.min(p)
		max_v = max_v.max(p)
	var center := (min_v + max_v) * 0.5
	var extents := max_v - min_v
	var max_dim := maxf(0.001, maxf(extents.x, maxf(extents.y, extents.z)))
	top = (top - center) / max_dim
	bottom = (bottom - center) / max_dim
	for i in upper.size():
		upper[i] = (upper[i] - center) / max_dim
	for i in lower.size():
		lower[i] = (lower[i] - center) / max_dim
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in 5:
		var j := (i + 1) % 5
		st.add_vertex(top)
		st.add_vertex(upper[i])
		st.add_vertex(upper[j])
		st.add_vertex(upper[i])
		st.add_vertex(lower[i])
		st.add_vertex(lower[j])
		st.add_vertex(upper[i])
		st.add_vertex(lower[j])
		st.add_vertex(upper[j])
		st.add_vertex(bottom)
		st.add_vertex(lower[j])
		st.add_vertex(lower[i])
	st.generate_normals()
	return st.commit()


static func _get_impact_chip_mesh() -> Mesh:
	if _impact_chip_meshes.is_empty():
		for i in 5:
			_impact_chip_meshes.append(_build_impact_chip_mesh(i))
	return _impact_chip_meshes[randi() % _impact_chip_meshes.size()]


static func _surface_color_from_collider(collider: Node, fallback: Color) -> Color:
	if collider == null:
		return ArenaGenerator.rock_debris_color(null, fallback)
	if collider.has_method("_material_base_color"):
		return collider.call("_material_base_color")
	var mat: Material = _surface_material_from_node(collider)
	if mat != null:
		return ArenaGenerator.rock_debris_color(mat, fallback)
	return fallback


static func _surface_material_from_node(node: Node) -> Material:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		var mat := mi.get_active_material(0)
		if mat != null:
			return mat
		return mi.material_override
	if node is MultiMeshInstance3D:
		return (node as MultiMeshInstance3D).material_override
	for child in node.get_children():
		if child is MultiMeshInstance3D or child is MeshInstance3D:
			var mat := _surface_material_from_node(child)
			if mat != null:
				return mat
	return null


static func _animate_impact_chip(
	t: float,
	chip: MeshInstance3D,
	mat: StandardMaterial3D,
	start: Vector3,
	velocity: Vector3,
	gravity: Vector3,
	start_rot: Vector3,
	end_rot: Vector3,
	start_alpha: float,
) -> void:
	if not is_instance_valid(chip):
		return
	chip.global_position = start + velocity * t + gravity * (t * t)
	chip.rotation = start_rot.lerp(end_rot, t)
	var col := mat.albedo_color
	mat.albedo_color = Color(col.r, col.g, col.b, start_alpha * (1.0 - smoothstep(0.96, 1.0, t)))


static func _spawn_impact_rock_chips(scene: Node, pos: Vector3, normal: Vector3, scale_f: float, dmg_ratio: float, collider: Node, bullet_color: Color) -> void:
	if scene == null or (BenchFlags.active and BenchFlags.no_explosion_visuals):
		return
	var n: Vector3 = normal.normalized() if normal.length_squared() > 0.001 else Vector3.UP
	var damage_t := 0.0
	if dmg_ratio > 1.0:
		damage_t = pow(clampf(log(dmg_ratio) / log(24.0), 0.0, 1.0), 1.2)
	var travel_damage_scale := lerpf(0.45, 2.6, damage_t)
	var count_power := damage_t
	var count := int(clampf(2.0 + count_power * 11.0, 2.0, 13.0))
	var base_color := _surface_color_from_collider(collider, bullet_color)
	var tangent_a := n.cross(Vector3.UP)
	if tangent_a.length_squared() < 0.001:
		tangent_a = n.cross(Vector3.RIGHT)
	tangent_a = tangent_a.normalized()
	var tangent_b := n.cross(tangent_a).normalized()
	for i in count:
		var chip := MeshInstance3D.new()
		chip.mesh = _get_impact_chip_mesh()
		var mat := StandardMaterial3D.new()
		var tint := randf_range(0.72, 1.12)
		var start_alpha := randf_range(0.78, 0.95)
		mat.albedo_color = Color(
			clampf(base_color.r * tint, 0.0, 1.0),
			clampf(base_color.g * tint, 0.0, 1.0),
			clampf(base_color.b * tint, 0.0, 1.0),
			start_alpha
		)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.roughness = 0.88
		chip.material_override = mat
		var size_jitter := randf_range(0.85, 1.25)
		var target_longest_axis_m := clampf(lerpf(0.16, 0.9, damage_t) * size_jitter, 0.12, 1.0)
		var proportions := Vector3(
			randf_range(0.55, 1.0),
			randf_range(0.35, 0.9),
			randf_range(0.5, 1.0)
		)
		var prop_max := maxf(proportions.x, maxf(proportions.y, proportions.z))
		chip.scale = proportions * (target_longest_axis_m / prop_max)
		chip.rotation = Vector3(randf() * TAU, randf() * TAU, randf() * TAU)
		scene.add_child(chip)
		var start := pos + n * 0.035
		chip.global_position = start

		var angle := randf() * TAU
		var lateral := (tangent_a * cos(angle) + tangent_b * sin(angle)).normalized()
		var launch_dir := (lateral * randf_range(0.75, 1.8) + n * randf_range(0.15, 0.65)).normalized()
		var travel_jitter := pow(randf_range(0.85, 1.85), 1.1)
		var travel := randf_range(3.0, 7.5) * travel_damage_scale * travel_jitter
		var rise := randf_range(0.55, 1.8) * travel_damage_scale
		var bury_depth := randf_range(2.5, 5.5) * lerpf(0.85, 1.8, damage_t)
		var gravity_drop := rise + absf(launch_dir.y * travel) + bury_depth
		var velocity := launch_dir * travel + Vector3.UP * rise
		var gravity := Vector3.DOWN * gravity_drop - n * randf_range(0.2, 0.75)
		var start_rot := chip.rotation
		var end_rot := start_rot + Vector3(
			randf_range(-PI, PI) * 2.8,
			randf_range(-PI, PI) * 2.8,
			randf_range(-PI, PI) * 2.8
		)
		var life := randf_range(1.35, 2.35)
		var tw := chip.create_tween()
		tw.tween_method(
			Callable(Violence, "_animate_impact_chip").bind(chip, mat, start, velocity, gravity, start_rot, end_rot, start_alpha),
			0.0,
			1.0,
			life
		)\
			.set_trans(Tween.TRANS_LINEAR)
		tw.tween_callback(chip.queue_free)


static func clear_blood_splats(scene_root: Node) -> void:
	if scene_root == null:
		return
	for n in scene_root.get_tree().get_nodes_in_group("blood_splats"):
		if is_instance_valid(n):
			n.queue_free()
	for n in scene_root.get_tree().get_nodes_in_group("player_blood_wounds"):
		if is_instance_valid(n):
			n.queue_free()


static func clear_smoke_puffs(scene_root: Node) -> void:
	if scene_root == null:
		return
	_free_group(scene_root, "smoke_puffs")
	_free_group(scene_root, "blast_smoke_layers")
	_active_blast_smoke_layers = 0
	_blast_smoke_layer_pivots.clear()
	_active_smoke_puffs = 0
	_pending_smoke_puffs = 0


static func _free_group(scene_root: Node, group_name: String) -> void:
	if scene_root == null:
		return
	var tree := scene_root.get_tree()
	if tree == null:
		return
	for n in tree.get_nodes_in_group(group_name):
		if is_instance_valid(n):
			n.queue_free()


# Wipe leftover gore / explosion VFX and reset Violence FIFO counters so a new
# round or arena swap doesn't inherit the previous map's debris, gibs, or smoke.
static func clear_round_combat_vfx(scene_root: Node) -> void:
	if scene_root == null:
		return
	clear_blood_splats(scene_root)
	clear_smoke_puffs(scene_root)
	_free_group(scene_root, "destruction_debris")
	_free_group(scene_root, "gib_chunks")
	_free_group(scene_root, "corpses")
	_free_group(scene_root, "brass_casings")
	_gib_chunk_fifo.clear()
	_blood_splat_fifo.clear()
	DestructibleManager.reset_exposed_chunk_count()

static func spawn_blood(scene: Node, pos: Vector3, dir: Vector3, dmg_ratio: float, vfx_max_blood_drops: int = 8) -> void:
	if scene == null:
		return
	# Dark-red cloud with a short red-lit core. Spatter biases in the bullet's
	# travel direction (through the body) plus a random scatter cone.
	var sz: float = sqrt(dmg_ratio)
	var count: int = min(vfx_max_blood_drops, int(round(8.0 * sz)))

	# Hard hits emit a brief deep-red flash on the wound site.
	if dmg_ratio > 1.4:
		var light := OmniLight3D.new()
		light.light_color = Color(0.8, 0.05, 0.05)
		light.light_energy = 2.5 * sz
		light.omni_range = 1.3 * sz
		light.position = pos
		scene.add_child(light)
		var lt := light.create_tween()
		lt.tween_property(light, "light_energy", 0.0, 0.18)\
			.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
		lt.tween_callback(light.queue_free)

	for i in count:
		var drop := MeshInstance3D.new()
		var m := SphereMesh.new()
		m.radius = randf_range(0.04, 0.09) * sz
		m.height = m.radius * 2.0
		m.radial_segments = 5
		m.rings = 3
		drop.mesh = m
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		var shade := randf_range(0.28, 0.55)
		mat.albedo_color = Color(shade, 0.03, 0.02, 0.9)
		drop.material_override = mat
		drop.position = pos
		scene.add_child(drop)
		var scatter := Vector3(randf_range(-0.8, 0.8), randf_range(-0.3, 0.9),
			randf_range(-0.8, 0.8)).normalized()
		var spray: Vector3 = (dir * randf_range(0.3, 0.9) + scatter * randf_range(0.4, 1.1)).normalized()
		var travel := randf_range(0.45, 1.2) * sz
		var end := pos + spray * travel + Vector3.DOWN * 0.25 * sz
		var dur := randf_range(0.35, 0.55)
		var tw := drop.create_tween().set_parallel(true)
		tw.tween_property(drop, "position", end, dur)\
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tw.tween_property(mat, "albedo_color", Color(shade, 0.03, 0.02, 0.0), dur * 1.1)
		tw.chain().tween_callback(drop.queue_free)

static func spawn_gib_mist(
	scene: Node,
	pos: Vector3,
	dir: Vector3,
	intensity: float,
	blast_radius: float = 0.0,
	blast_severity: float = 0.0
) -> void:
	if scene == null:
		return
	var dir_n := dir.normalized() if dir.length_squared() > 0.001 else Vector3.UP
	var chaos := blast_severity * clampf(intensity / maxf(Weapon.REFERENCE_KNOCKBACK, 0.001), 0.6, 2.4)
	var count: int = clampi(int(round(8.0 + intensity * 2.5 + blast_radius * 0.25 + chaos * 10.0)), 8, 28)
	var spread: float = 0.45 + blast_radius * 0.03 + chaos * 0.14
	var base_travel: float = 0.9 + intensity * 0.22 + blast_radius * 0.05 + chaos * 0.9
	var base_size: float = 0.12 + intensity * 0.018 + chaos * 0.04

	for i in count:
		var puff := MeshInstance3D.new()
		var mesh := SphereMesh.new()
		mesh.radius = randf_range(base_size * 0.6, base_size * 1.2)
		mesh.height = mesh.radius * 2.0
		mesh.radial_segments = 6
		mesh.rings = 4
		puff.mesh = mesh
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		var shade := randf_range(0.28, 0.52)
		mat.albedo_color = Color(shade, 0.02, 0.02, randf_range(0.2, 0.42))
		mat.emission_enabled = true
		mat.emission = Color(0.4, 0.02, 0.02)
		mat.emission_energy_multiplier = 0.1
		puff.material_override = mat
		puff.position = pos + Vector3(
			randf_range(-0.08, 0.08),
			randf_range(-0.08, 0.08),
			randf_range(-0.08, 0.08)
		)
		scene.add_child(puff)

		var scatter := Vector3(
			randf_range(-spread, spread),
			randf_range(-0.22, 0.45),
			randf_range(-spread, spread)
		)
		var travel_dir := (dir_n + scatter).normalized()
		var end := puff.position + travel_dir * randf_range(base_travel * 0.65, base_travel * 1.2)
		var dur := randf_range(0.35, 0.68)
		var tw := puff.create_tween().set_parallel(true)
		tw.tween_property(puff, "position", end, dur)\
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tw.tween_property(puff, "scale", Vector3.ONE * randf_range(1.8, 2.8), dur)\
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		tw.tween_property(mat, "albedo_color", Color(shade, 0.02, 0.02, 0.0), dur)\
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		tw.chain().tween_callback(puff.queue_free)

static func spawn_blast_blood_splash(scene: Node, pos: Vector3, dir: Vector3, severity: float) -> void:
	if severity <= 0.08 or scene == null:
		return
	var dir_n := dir.normalized() if dir.length_squared() > 0.001 else Vector3.UP
	var count := clampi(int(round(5.0 + severity * 10.0)), 5, 14)
	for i in count:
		var splash := MeshInstance3D.new()
		var mesh := SphereMesh.new()
		mesh.radius = randf_range(0.06, 0.12) * lerpf(0.9, 1.5, severity)
		mesh.height = mesh.radius * 2.0
		mesh.radial_segments = 5
		mesh.rings = 3
		splash.mesh = mesh
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.albedo_color = Color(randf_range(0.3, 0.46), 0.02, 0.02, randf_range(0.18, 0.34))
		splash.material_override = mat
		splash.position = pos
		scene.add_child(splash)
		var scatter := Vector3(
			randf_range(-0.9, 0.9),
			randf_range(-0.25, 0.85),
			randf_range(-0.9, 0.9)
		)
		var end := pos + (dir_n + scatter).normalized() * randf_range(0.6, 1.5) * lerpf(0.8, 1.8, severity)
		var dur := randf_range(0.22, 0.42)
		var tw := splash.create_tween().set_parallel(true)
		tw.tween_property(splash, "position", end, dur)\
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tw.tween_property(splash, "scale", Vector3.ONE * randf_range(1.2, 1.9), dur)\
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		tw.tween_property(mat, "albedo_color", Color(mat.albedo_color.r, 0.02, 0.02, 0.0), dur)\
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		tw.chain().tween_callback(splash.queue_free)


# Headshot gore — red mist puffs radiating from the wound.
static func _spawn_headshot_puffs(
	scene: Node,
	pos: Vector3,
	dir: Vector3,
	severity: float,
	lethal: bool,
) -> void:
	if scene == null:
		return
	var dir_n := dir.normalized() if dir.length_squared() > 0.001 else Vector3.UP
	var sev := clampf(severity, 0.25, 3.0)
	var count := clampi(
		int(round(lerpf(6.0, 18.0, sev / 2.5) if lethal else lerpf(3.0, 9.0, sev / 1.8))),
		3, 20)
	var base_size := lerpf(0.12, 0.34, sev / 2.5) if lethal else lerpf(0.09, 0.22, sev / 1.6)
	var spread := lerpf(0.35, 0.75, sev / 2.5) if lethal else lerpf(0.28, 0.5, sev / 1.6)
	var travel := lerpf(0.55, 1.35, sev / 2.5) if lethal else lerpf(0.35, 0.85, sev / 1.6)

	for i in count:
		var puff := MeshInstance3D.new()
		var mesh := SphereMesh.new()
		mesh.radius = randf_range(base_size * 0.55, base_size * 1.25)
		mesh.height = mesh.radius * 2.0
		mesh.radial_segments = 6
		mesh.rings = 4
		puff.mesh = mesh
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		var shade := randf_range(0.32, 0.58)
		mat.albedo_color = Color(shade, 0.015, 0.01, randf_range(0.28, 0.55))
		mat.emission_enabled = true
		mat.emission = Color(0.55, 0.03, 0.02)
		mat.emission_energy_multiplier = lerpf(0.12, 0.35, sev / 2.5)
		puff.material_override = mat
		puff.position = pos + Vector3(
			randf_range(-0.06, 0.06),
			randf_range(-0.06, 0.06),
			randf_range(-0.06, 0.06),
		)
		scene.add_child(puff)

		var scatter := Vector3(
			randf_range(-spread, spread),
			randf_range(-0.18, 0.42),
			randf_range(-spread, spread),
		)
		var travel_dir := (dir_n + scatter).normalized()
		var end := puff.position + travel_dir * randf_range(travel * 0.55, travel * 1.15)
		var dur := randf_range(0.18, 0.42) if lethal else randf_range(0.22, 0.48)
		var tw := puff.create_tween().set_parallel(true)
		tw.tween_property(puff, "position", end, dur)\
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tw.tween_property(puff, "scale", Vector3.ONE * randf_range(2.0, 3.4), dur)\
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		tw.tween_property(mat, "albedo_color", Color(shade, 0.015, 0.01, 0.0), dur)\
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		tw.chain().tween_callback(puff.queue_free)


# Non-lethal head hit — extra red spray on top of the normal blood squirt.
static func spawn_headshot_spray(scene: Node, pos: Vector3, dir: Vector3, severity: float = 1.0) -> void:
	if scene == null:
		return
	var dir_n := dir.normalized() if dir.length_squared() > 0.001 else Vector3.UP
	var sev := clampf(severity, 0.35, 2.5)
	spawn_gib_mist(scene, pos, dir_n, sev * 1.35, 0.0, sev * 0.28)
	_spawn_headshot_puffs(scene, pos, dir_n, sev, false)


# Lethal headshot — head chunks + heavy red mist.
static func spawn_headshot_gore(scene: Node, pos: Vector3, dir: Vector3, intensity: float = 1.5) -> void:
	if scene == null:
		return
	var dir_n := dir.normalized() if dir.length_squared() > 0.001 else Vector3.UP
	var sev := clampf(intensity, 0.8, 3.0)

	var light := OmniLight3D.new()
	light.light_color = Color(0.95, 0.08, 0.06)
	light.light_energy = 5.5 * sev
	light.omni_range = 2.4 + sev * 0.9
	light.shadow_enabled = false
	_attach_world_3d(scene, light, pos)
	var lt := light.create_tween()
	lt.tween_property(light, "light_energy", 0.0, 0.2)\
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	lt.tween_callback(light.queue_free)

	spawn_gib_mist(scene, pos, dir_n, sev * 2.1, 0.0, sev * 0.55)
	spawn_blood(scene, pos, dir_n, sev * 1.75, 14)
	spawn_blast_blood_splash(scene, pos, dir_n, clampf(sev * 0.8, 0.5, 1.0))
	_spawn_headshot_puffs(scene, pos, dir_n, sev, true)


# Overkill gib — blood cloud + wall/floor splatter when a hit pulps the target.
static func spawn_overkill_gore(scene: Node, pos: Vector3, dir: Vector3, severity: float = 1.0) -> void:
	if scene == null:
		return
	var dir_n := dir.normalized() if dir.length_squared() > 0.001 else Vector3.UP
	var sev := clampf(severity, 0.4, 2.5)

	var light := OmniLight3D.new()
	light.light_color = Color(0.92, 0.06, 0.05)
	light.light_energy = 4.0 + sev * 3.5
	light.omni_range = 2.0 + sev * 1.4
	light.shadow_enabled = false
	_attach_world_3d(scene, light, pos)
	var lt := light.create_tween()
	lt.tween_property(light, "light_energy", 0.0, 0.24)\
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	lt.tween_callback(light.queue_free)

	spawn_gib_mist(scene, pos, dir_n, sev * 2.4, 0.0, sev * 0.65)
	spawn_blood(scene, pos, dir_n, sev * 2.0, 18)
	spawn_blast_blood_splash(scene, pos, dir_n, clampf(sev * 0.95, 0.55, 1.0))
	_spawn_headshot_puffs(scene, pos, dir_n, sev, true)
	spawn_overkill_blood_splats(scene, pos, dir_n, sev)


static func spawn_overkill_blood_splats(scene: Node, pos: Vector3, dir: Vector3, severity: float) -> void:
	if scene == null:
		return
	var qs := vfx_quality_scale()
	if qs <= 0.0:
		return
	var space: PhysicsDirectSpaceState3D = scene.get_world_3d().direct_space_state
	if space == null:
		return
	var dir_n := dir.normalized() if dir.length_squared() > 0.001 else Vector3.UP
	var sev := clampf(severity, 0.4, 2.5)
	var radius := clampf(1.8 + sev * sev * 2.2, 1.8, 10.0)
	var strength := clampf(0.55 + sev * 0.72, 0.55, 2.35)
	const CARDINAL: Array[Vector3] = [
		Vector3.DOWN, Vector3.UP,
		Vector3.RIGHT, Vector3.LEFT,
		Vector3.FORWARD, Vector3.BACK,
	]
	var cardinal_passes := 1 if sev < 1.2 else (2 if sev < 1.9 else 3)
	cardinal_passes = maxi(1, int(round(float(cardinal_passes) * qs)))
	for pass_i in cardinal_passes:
		var pass_strength := strength * lerpf(0.82, 1.0, float(pass_i) / maxf(float(cardinal_passes - 1), 1.0))
		for axis in CARDINAL:
			var offset := Vector3.ZERO
			if pass_i > 0:
				offset = Vector3(
					randf_range(-0.35, 0.35),
					randf_range(-0.35, 0.35),
					randf_range(-0.35, 0.35),
				)
			var origin := pos + offset
			var q := PhysicsRayQueryParameters3D.create(origin, origin + axis * radius)
			q.collision_mask = 1
			var hit := space.intersect_ray(q)
			if hit.is_empty():
				continue
			var hit_strength := pass_strength * (1.28 if axis == Vector3.DOWN else 1.0)
			_gib_spawn_blood_splat(scene, hit.position, hit.normal, dir_n, hit_strength)
	# Floor pool — big ground stain under the burst.
	var floor_count := clampi(int(round((2.0 + sev * sev * 5.0) * qs)), 1, 14)
	for i in floor_count:
		var offset := Vector3(
			randf_range(-0.55, 0.55) * sev,
			0.0,
			randf_range(-0.55, 0.55) * sev,
		)
		var origin := pos + offset + Vector3.UP * 0.2
		var qf := PhysicsRayQueryParameters3D.create(origin, origin + Vector3.DOWN * radius)
		qf.collision_mask = 1
		var floor_hit := space.intersect_ray(qf)
		if floor_hit.is_empty():
			continue
		_gib_spawn_blood_splat(
			scene,
			floor_hit.position,
			floor_hit.normal,
			dir_n,
			strength * randf_range(1.05, 1.35),
		)
	var spray_count := clampi(int(round((4.0 + sev * sev * 9.0) * qs)), 2, 28)
	for i in spray_count:
		var scatter := (-dir_n * lerpf(0.45, 0.85, sev / 2.5)) + Vector3(
			randf_range(-1.0, 1.0),
			randf_range(-0.35, 0.85),
			randf_range(-1.0, 1.0),
		)
		if scatter.length_squared() < 0.001:
			continue
		var ray_dir := scatter.normalized()
		var q2 := PhysicsRayQueryParameters3D.create(pos, pos + ray_dir * radius)
		q2.collision_mask = 1
		var hit2 := space.intersect_ray(q2)
		if hit2.is_empty():
			continue
		_gib_spawn_blood_splat(
			scene,
			hit2.position,
			hit2.normal,
			dir_n,
			strength * randf_range(0.78, 1.08),
		)


static func spawn_overkill_blood_splats_after_destruction(scene: Node, pos: Vector3, dir: Vector3, severity: float) -> void:
	if scene == null or not is_instance_valid(scene):
		return
	var tree := scene.get_tree()
	if tree == null:
		return
	tree.create_timer(0.0, false, true).timeout.connect(
		_spawn_deferred_overkill_blood_splats.bind(scene, pos, dir, severity),
		CONNECT_ONE_SHOT
	)


static func _spawn_deferred_overkill_blood_splats(scene: Node, pos: Vector3, dir: Vector3, severity: float) -> void:
	if scene == null or not is_instance_valid(scene):
		return
	DestructibleManager.flush()
	spawn_overkill_blood_splats(scene, pos, dir, severity)


# -------------------- 3. PLAYER-COUPLED HELPERS --------------------
#
# These take a `player` Node and read/mutate its state. Player.gd's @rpc
# methods delegate here.

# Apply / clear the squinty `>_<` hit face by toggling eye-mesh visibility.
static func set_hit_face_state(player: Node, active: bool) -> void:
	if player == null:
		return
	var eye_left: Node = player.get("eye_left")
	if eye_left:
		eye_left.visible = not active
	var eye_right: Node = player.get("eye_right")
	if eye_right:
		eye_right.visible = not active
	var pupil_left: Node = player.get("pupil_left")
	if pupil_left:
		pupil_left.visible = not active
	var pupil_right: Node = player.get("pupil_right")
	if pupil_right:
		pupil_right.visible = not active
	var hit_eye_left: Node = player.get("hit_eye_left")
	if hit_eye_left:
		hit_eye_left.visible = active
	var hit_eye_right: Node = player.get("hit_eye_right")
	if hit_eye_right:
		hit_eye_right.visible = active

# Authority-only: schedule the view punch with a speed-of-sound delay so the
# shake arrives in sync with the audio + visual shockwave.
static func apply_explosion_view_punch(player: Node, pos: Vector3, radius: float, peak: float = 1.0) -> void:
	if player == null or not player.is_multiplayer_authority():
		return
	var camera: Node = player.get("camera")
	if camera == null:
		return
	var to_player: Vector3 = player.global_position - pos
	var dist: float = to_player.length()
	# Felt-radius is 5× the visible blast — distant players still get a
	# tremor; nearby players get a real kick.
	var effect_radius := maxf(radius * 5.0, radius + 1.0)
	if dist >= effect_radius:
		return
	var delay: float = dist / 343.0
	if delay < 0.01:
		do_explosion_view_punch(player, pos, radius, peak)
	else:
		# .bind (not a capturing lambda) so a player freed during the speed-of-
		# sound delay doesn't error on a freed capture; do_explosion_view_punch
		# guards is_instance_valid(player) for that case.
		player.get_tree().create_timer(delay).timeout.connect(
			do_explosion_view_punch.bind(player, pos, radius, peak))

static func do_explosion_view_punch(player: Node, pos: Vector3, radius: float, peak: float) -> void:
	if not is_instance_valid(player) or player.get("camera") == null:
		return
	# Recompute distance — the player may have moved during the propagation.
	var to_player: Vector3 = player.global_position - pos
	var dist: float = to_player.length()
	var effect_radius := maxf(radius * 5.0, radius + 1.0)
	if dist >= effect_radius:
		return
	# Linear-ish falloff (was pow 1.6 — too steep for big blasts at range).
	# Now a 24m bazooka at 60m still hits at strength ~0.5 * peak.
	var linear: float = clampf(1.0 - dist / effect_radius, 0.0, 1.0)
	var strength: float = pow(linear, 1.0) * peak
	if strength <= 0.0:
		return
	var away_dir := to_player.normalized() if dist > 0.001 else Vector3.UP
	var local_dir: Vector3 = player.global_transform.basis.inverse() * away_dir
	player.set("_view_punch_pos", player.get("_view_punch_pos") + local_dir * (0.09 + 0.33 * strength))
	player.set("_view_punch_rot", player.get("_view_punch_rot") + Vector3(
		-local_dir.y * (0.045 + 0.165 * strength),
		local_dir.x * (0.018 + 0.084 * strength),
		-local_dir.x * (0.024 + 0.114 * strength),
	))
	player.set("shake_amt", maxf(player.get("shake_amt"), 0.015 + 0.15 * strength))

# -------------------- ragdoll / death --------------------

# Recursively gather all MeshInstance3D nodes under a subtree.
static func collect_meshes(node: Node, out: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		out.append(node)
	for child in node.get_children():
		collect_meshes(child, out)

# Hide first-person gun + drop hitboxes off their layer so a corpse can't be
# shot or seen with a floating gun.
static func set_dead_visuals(player: Node, dead: bool) -> void:
	var muzzle: Node = player.get("muzzle")
	if muzzle:
		muzzle.visible = not dead
	var name_label: Node = player.get("name_label")
	if name_label:
		name_label.visible = not dead
	var layer: int = 0 if dead else 2
	var head_hitbox: Node = player.get("head_hitbox")
	if head_hitbox:
		head_hitbox.collision_layer = layer
	var torso_hitbox: Node = player.get("torso_hitbox")
	if torso_hitbox:
		torso_hitbox.collision_layer = layer
	var legs_hitbox: Node = player.get("legs_hitbox")
	if legs_hitbox:
		legs_hitbox.collision_layer = layer

# Full death sequence: snap the hit face on, hide the body, spawn the
# Voronoi-shattered corpse, drop hitboxes off their layer.
static func do_ragdoll(
	player: Node,
	push_dir: Vector3,
	force_origin: Vector3 = Vector3.INF,
	gib_force: float = 0.0,
	blast_radius: float = 0.0,
	blast_severity: float = 0.0,
	is_head: bool = false,
	overkill_disintegrate: bool = false,
	overkill_severity: float = 0.0,
) -> void:
	if player == null:
		return
	# Switch to the squinty `>_<` face so the cloned ragdoll meshes inherit
	# that state. Done BEFORE hiding the body so visibility checks during
	# cloning still reflect the (about-to-be-hidden) authored tree.
	set_hit_face_state(player, true)
	player.set("_hit_face_timer", 0.0)  # don't let _process auto-revert on the dead body
	spawn_ragdoll(
		player, push_dir, force_origin, gib_force, blast_radius, blast_severity, is_head,
		overkill_disintegrate, overkill_severity,
	)
	if blast_radius > 0.0 or overkill_disintegrate:
		clear_player_blood_wounds(player)
	# Every peer simulates its own corpse — cosmetic desync is fine.
	var body_model: Node = player.get("body_model")
	if body_model:
		body_model.visible = false
	set_dead_visuals(player, true)

# How many body meshes get chunked per frame during a full disintegration.
# The whole-body blob is 12-14 meshes (~40 rigid bodies); doing them all in
# the death tick was a measured 10-19ms frame spike. The first batch runs
# synchronously, the rest one batch per frame — chunks arriving 1-3 frames
# late hide inside the blast flash.
const GIB_DISINTEGRATE_MESHES_PER_FRAME := 4


# Chunk ONE body mesh; returns the updated `first` flag (death cam target +
# death effect fire on the first successful mesh for the local human).
static func _gib_one_death_mesh(
	src: MeshInstance3D,
	scene: Node,
	player: Node,
	ragdoll_pieces: Array,
	base_vel: Vector3,
	burst_strength: float,
	chunk_count: int,
	force_origin: Vector3,
	impact_blood_strength: float,
	first: bool,
	local_is_authority: bool,
) -> bool:
	var _tp := Time.get_ticks_usec() if Trace.enabled else 0
	# Blob meshes carry material_override; the knight's FBX materials live on
	# the mesh surfaces — get_active_material resolves both (override wins).
	var chunks: Array[RigidBody3D] = gib_explode(
		src.mesh,
		src.global_transform,
		scene,
		src.get_active_material(0),
		base_vel + Vector3(randf_range(-1.5, 1.5), 0, randf_range(-1.5, 1.5)),
		burst_strength,
		chunk_count,
		14.0,
		force_origin,
		impact_blood_strength,
	)
	if Trace.enabled:
		Trace.prof("death_gibs", Time.get_ticks_usec() - _tp)
	if chunks.is_empty():
		return first
	if first and local_is_authority:
		player.set("_ragdoll_head", chunks[0])
		if scene.has_method("show_death_effect_for"):
			scene.show_death_effect_for(int(player.get("player_id")), true)
		elif scene.has_method("show_death_effect"):
			scene.show_death_effect(true)
	for c in chunks:
		ragdoll_pieces.append(c)
	return false


# Fire-and-forget coroutine: chunk the remaining death meshes in per-frame
# batches. Guards every step — the round can reset (scene freed) or the
# player can be freed mid-spread.
static func _spread_death_gibs(
	srcs: Array[MeshInstance3D],
	scene: Node,
	player: Node,
	ragdoll_pieces: Array,
	base_vel: Vector3,
	burst_strength: float,
	chunk_count: int,
	force_origin: Vector3,
	impact_blood_strength: float,
	first: bool,
	local_is_authority: bool,
) -> void:
	var tree: SceneTree = scene.get_tree()
	var i := 0
	while i < srcs.size():
		await tree.process_frame
		if not is_instance_valid(scene) or not is_instance_valid(player):
			return
		var end := mini(i + GIB_DISINTEGRATE_MESHES_PER_FRAME, srcs.size())
		while i < end:
			var src := srcs[i]
			i += 1
			if not is_instance_valid(src):
				continue
			first = _gib_one_death_mesh(
				src, scene, player, ragdoll_pieces, base_vel, burst_strength,
				chunk_count, force_origin, impact_blood_strength,
				first, local_is_authority,
			)


static func spawn_ragdoll(
	player: Node,
	push_dir: Vector3,
	force_origin: Vector3 = Vector3.INF,
	gib_force: float = 0.0,
	blast_radius: float = 0.0,
	blast_severity: float = 0.0,
	is_head: bool = false,
	overkill_disintegrate: bool = false,
	overkill_severity: float = 0.0,
) -> void:
	# Voronoi-split the blob's primitive meshes into chunks that fly apart.
	# body_model is hidden first so the user only reads the flying debris.
	# Chunks collide with world only — players and bullets ignore the corpse.
	var scene: Node = player.get_tree().current_scene
	var full_disintegrate := blast_radius > 0.0 or overkill_disintegrate
	var inferred_force: float = push_dir.length()
	if gib_force > 0.0:
		inferred_force = maxf(inferred_force, gib_force)
	# ×0.7 with a lower floor: the point-impulse ragdoll launch reads far more
	# violent than the old statue-slide at equal momentum, so the stock gun
	# was suddenly sending bodies flying. Weak hits soften ~30%; sqrt + the
	# 2.6 cap keep heavy weapons nearly unchanged.
	var kb_mag: float = clampf(sqrt(maxf(inferred_force, 1.0)) * 0.7, 0.8, 2.6)
	var dir_n: Vector3 = push_dir.normalized() if push_dir.length_squared() > 0.01 else Vector3.UP
	var chaos := 0.0
	if blast_radius > 0.0:
		chaos = clampf(blast_severity * clampf(gib_force / maxf(Weapon.REFERENCE_KNOCKBACK, 0.001), 0.6, 1.8), 0.0, 1.1)
	elif overkill_disintegrate:
		chaos = clampf(overkill_severity * 0.82, 0.35, 1.1)
	var blast_lift := 0.2
	if blast_radius > 0.0:
		blast_lift = 0.2 + chaos * 0.06
	elif overkill_disintegrate:
		blast_lift = 0.18 + chaos * 0.08
	var base_vel: Vector3 = dir_n * randf_range(2.2, 3.9) * kb_mag * (1.0 + chaos * 0.18) \
		+ Vector3.UP * randf_range(1.2, 2.8) * kb_mag * (1.0 + blast_lift)
	var burst_strength: float = 1.45 * kb_mag
	if blast_radius > 0.0:
		burst_strength *= 1.0 + clampf(blast_radius / 12.0, 0.0, 0.25) + chaos * 0.2
	elif overkill_disintegrate:
		burst_strength *= 1.0 + clampf(overkill_severity * 0.22, 0.0, 0.35) + chaos * 0.18

	var meshes: Array[MeshInstance3D] = []
	var body_model: Node = player.get("body_model")
	# The knight (CharacterVisual) and the legacy blob rig coexist under
	# BodyModel — the blob is merely hidden while the knight is active. Gib
	# whichever rig the player actually shows, or the corpse explodes into
	# the old blob pieces. (Deliberately NOT an is_visible_in_tree() filter:
	# the local player's whole body_model is hidden in first person and their
	# gibs must still spawn.)
	var knight: CharacterVisual = player.get("character_visual") as CharacterVisual
	var use_knight: bool = knight != null and knight.is_active()
	if use_knight:
		knight.collect_meshes(meshes)
	if meshes.is_empty() and body_model:
		use_knight = false
		collect_meshes(body_model, meshes)
	if meshes.is_empty():
		return
	var mist_origin: Vector3 = force_origin if force_origin != Vector3.INF else (player.global_position as Vector3) + Vector3.UP * 0.4
	if is_head and not full_disintegrate:
		var head_blob_for_fx: Node = player.get("head_blob")
		if head_blob_for_fx:
			mist_origin = (head_blob_for_fx as Node3D).global_position
	if overkill_disintegrate and blast_radius <= 0.0:
		spawn_overkill_gore(scene, mist_origin, dir_n, overkill_severity)
	elif is_head:
		spawn_headshot_gore(scene, mist_origin, dir_n, kb_mag)
	elif not full_disintegrate:
		spawn_gib_mist(scene, mist_origin, dir_n, kb_mag, blast_radius, blast_severity)
		if blast_radius > 0.0:
			spawn_blast_blood_splash(scene, mist_origin, dir_n, blast_severity)
	# Fixed chunk_count so the gib cache stays at one key per source mesh.
	# The knight's single skinned mesh gets a much finer split (see const).
	var chunk_count: int = KNIGHT_GIB_CHUNK_COUNT if use_knight else GIB_CHUNK_COUNT
	var impact_blood_strength := clampf(0.18 + kb_mag * 0.12 + chaos * 0.22, 0.15, 1.0)
	if overkill_disintegrate:
		impact_blood_strength = clampf(impact_blood_strength + overkill_severity * 0.18, 0.45, 1.0)

	# Death modes:
	#   • Explosion / overkill: chunk every body mesh — full disintegrate.
	#   • Headshot: head Voronoi-shatters, torso ragdolls intact.
	#   • Regular hit: whole body tumbles as a single rigid body.
	var local_is_authority: bool = player.is_multiplayer_authority() and not bool(player.get("is_bot"))
	var ragdoll_pieces: Array = player.get("_ragdoll_pieces")
	if full_disintegrate:
		var gore_int := kb_mag
		if overkill_disintegrate:
			gore_int = maxf(gore_int, overkill_severity)
		if blast_radius > 0.0:
			gore_int = maxf(gore_int, blast_severity * 1.15)
		var skip_mist := overkill_disintegrate and blast_radius <= 0.0
		var _tg := Time.get_ticks_usec() if Trace.enabled else 0
		var extra_gibs: Array = spawn_disintegrate_gore(
			scene,
			mist_origin,
			dir_n,
			gore_int,
			chaos,
			base_vel,
			burst_strength,
			force_origin,
			impact_blood_strength,
			skip_mist,
		)
		for g in extra_gibs:
			ragdoll_pieces.append(g)
		if blast_radius > 0.0:
			var splat_sev := clampf(blast_radius / 3.5 + blast_severity * 0.95, 1.0, 2.6)
			if overkill_disintegrate:
				splat_sev = maxf(splat_sev, overkill_severity)
			spawn_overkill_blood_splats_after_destruction(scene, mist_origin, dir_n, splat_sev)
		if Trace.enabled:
			Trace.prof("death_gore", Time.get_ticks_usec() - _tg)
		var srcs: Array[MeshInstance3D] = []
		# Never chunk the mounted weapon: the procedural gun's dozens of part
		# meshes are regenerated as UNIQUE resources on every card pick, so
		# the Voronoi cache has never seen them — chunking them baked
		# synchronously mid-death (measured gib_bake ~25ms/frame over six
		# frames). Gun shrapnel added nothing visually; flesh gibs are the show.
		var tp_gun: Node = player.get("_third_person_gun") as Node
		for src in meshes:
			if src.mesh == null or _gib_is_cosmetic_mesh(src):
				continue
			if tp_gun != null and is_instance_valid(tp_gun) and tp_gun.is_ancestor_of(src):
				continue
			srcs.append(src)
		# First batch synchronously — the death cam needs a chunk to follow
		# THIS frame and the explosion must read as instant; the remaining
		# meshes spread over the following frames so a 12-mesh body doesn't
		# burn one long frame on ~40 rigid-body spawns.
		var sync_n := mini(GIB_DISINTEGRATE_MESHES_PER_FRAME, srcs.size())
		var first: bool = true
		for i: int in sync_n:
			first = _gib_one_death_mesh(
				srcs[i], scene, player, ragdoll_pieces, base_vel, burst_strength,
				chunk_count, force_origin, impact_blood_strength,
				first, local_is_authority,
			)
		if sync_n < srcs.size():
			var rest: Array[MeshInstance3D] = []
			for i: int in range(sync_n, srcs.size()):
				rest.append(srcs[i])
			_spread_death_gibs(
				rest, scene, player, ragdoll_pieces, base_vel, burst_strength,
				chunk_count, force_origin, impact_blood_strength,
				first, local_is_authority,
			)
	elif use_knight:
		# Soft ragdoll: the knight clone gets per-limb PhysicalBone3D physics
		# (a single-rigid-body clone of skinned meshes tumbles as a hard
		# T-pose statue). Headshots kick the head bone extra instead of
		# detaching it — one skinned mesh, no separable head subtree.
		var hips: PhysicalBone3D = spawn_knight_ragdoll(
			knight, scene,
			base_vel + Vector3(randf_range(-0.6, 0.6), 0, randf_range(-0.6, 0.6)),
			dir_n, is_head, force_origin, 14.0,
		)
		if hips:
			ragdoll_pieces.append(hips.get_meta("knight_corpse_root"))
			_transfer_knight_wounds(player, hips.get_meta("knight_corpse_root"))
			if local_is_authority:
				player.set("_ragdoll_head", hips)
				if scene.has_method("show_death_effect_for"):
					scene.show_death_effect_for(int(player.get("player_id")), true)
				elif scene.has_method("show_death_effect"):
					scene.show_death_effect(true)
	else:
		# Split head subtree from torso so headshots can launch the head alone.
		var head_meshes: Array[MeshInstance3D] = []
		var head_blob: Node = player.get("head_blob")
		if is_head and head_blob:
			collect_meshes(head_blob, head_meshes)
		var torso_meshes: Array[MeshInstance3D] = []
		for m in meshes:
			if not head_meshes.has(m):
				torso_meshes.append(m)
		var torso_rb: RigidBody3D = gib_body_ragdoll(
			(body_model as Node3D).global_transform, torso_meshes, scene,
			base_vel + Vector3(randf_range(-0.6, 0.6), 0, randf_range(-0.6, 0.6)),
			4.0, 14.0,
		)
		if torso_rb:
			ragdoll_pieces.append(torso_rb)
			transfer_player_blood_wounds(player, torso_rb)
			if is_head and head_blob:
				var neck_wounds := _spawn_player_blood_cluster(
					torso_rb,
					(head_blob as Node3D).global_position,
					Vector3.UP,
					0.9,
					4,
				)
				_append_ragdoll_blood_wounds(torso_rb, neck_wounds)
			if local_is_authority:
				player.set("_ragdoll_head", torso_rb)
				if scene.has_method("show_death_effect_for"):
					scene.show_death_effect_for(int(player.get("player_id")), true)
				elif scene.has_method("show_death_effect"):
					scene.show_death_effect(true)
		if not head_meshes.is_empty():
			var head_pos: Vector3 = (head_blob as Node3D).global_position
			var head_vel: Vector3 = base_vel + dir_n * 9.0 + Vector3.UP * 11.0
			var head_burst: float = burst_strength * 2.1
			var head_blood: float = clampf(0.65 + kb_mag * 0.18, 0.55, 1.0)
			var first_head_chunk: bool = true
			for src in head_meshes:
				if src.mesh == null or _gib_is_cosmetic_mesh(src):
					continue
				var head_chunks: Array[RigidBody3D] = gib_explode(
					src.mesh,
					src.global_transform,
					scene,
					src.get_active_material(0),
					head_vel + Vector3(
						randf_range(-2.2, 2.2),
						randf_range(0.6, 2.8),
						randf_range(-2.2, 2.2),
					),
					head_burst,
					chunk_count,
					14.0,
					head_pos,
					head_blood,
				)
				for c in head_chunks:
					ragdoll_pieces.append(c)
					if first_head_chunk and local_is_authority:
						player.set("_ragdoll_head", c)
						first_head_chunk = false


# Free all spawned ragdoll pieces and restore body visibility / hitbox layers.
# Caller is responsible for calling _apply_ghost_visuals() afterward (since
# that touches Player-private rendering knobs).
static func _lava_surface_world_y(player: Node) -> float:
	var scene: Node = player.get_tree().current_scene if player else null
	if scene == null:
		return player.global_position.y - 2.0
	var arena: Node = scene.get_node_or_null("Arena")
	if arena != null and arena.has_method("get_lava_surface_world_y"):
		return float(arena.call("get_lava_surface_world_y"))
	return player.global_position.y - 2.0


# Lava death — body picks up the arena lava shader, then sinks. Tuned in lava_death_lab.tscn.
static var _lava_body_material: ShaderMaterial = null
static var lava_death_sink_y_fall: float = 0.75
static var lava_death_sink_y_stand: float = 0.5
static var lava_death_sink_dur_fall: float = 2.15
static var lava_death_sink_dur_stand: float = 1.35
static var lava_splash_pillar_height: float = 2.2
static var lava_splash_pillar_radius: float = 0.55
static var lava_splash_rise_dur: float = 0.18
static var lava_splash_sink_dur: float = 0.55


static func get_lava_body_material() -> ShaderMaterial:
	return _get_lava_body_material()


static func _get_lava_body_material() -> ShaderMaterial:
	if _lava_body_material == null:
		_lava_body_material = ArenaGenerator.make_lava_shader_material()
		_lava_body_material.render_priority = 1
	return _lava_body_material


static func _lava_fx_scene(player: Node) -> Node:
	var tree: SceneTree = player.get_tree() if player else null
	if tree == null:
		return null
	var scene: Node = tree.current_scene
	if scene == null:
		return null
	var arena: Node = scene.get_node_or_null("Arena")
	if arena is Node3D:
		return arena
	if scene is Node3D:
		return scene
	return null


static func _apply_lava_body(player: Node) -> void:
	var body_model: Node = player.get("body_model") as Node
	if body_model == null:
		return
	var lava_mat := _get_lava_body_material()
	var meshes: Array[MeshInstance3D] = []
	collect_meshes(body_model, meshes)
	for mesh: MeshInstance3D in meshes:
		mesh.material_override = lava_mat


static func spawn_lava_impact_splash(scene: Node, surface_pos: Vector3) -> void:
	if scene == null:
		return
	if BenchFlags.active and BenchFlags.no_explosion_visuals:
		return
	var height: float = lava_splash_pillar_height
	var radius: float = lava_splash_pillar_radius
	var cyl := CylinderMesh.new()
	cyl.top_radius = radius * 0.42
	cyl.bottom_radius = radius
	cyl.height = height
	cyl.radial_segments = 10
	cyl.rings = 1
	var pillar := MeshInstance3D.new()
	pillar.name = "LavaSplashPillar"
	pillar.mesh = cyl
	var mat := _get_lava_body_material().duplicate()
	mat.render_priority = 2
	pillar.material_override = mat
	var half_h: float = height * 0.5
	var start_y: float = surface_pos.y + half_h + 0.08
	var peak_y: float = surface_pos.y + height * 1.05
	var end_y: float = surface_pos.y - height * 0.7
	_attach_world_3d(scene, pillar, Vector3(surface_pos.x, start_y, surface_pos.z))
	var tw := pillar.create_tween()
	tw.tween_property(pillar, "global_position:y", peak_y, lava_splash_rise_dur)\
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(pillar, "global_position:y", end_y, lava_splash_sink_dur)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tw.tween_callback(pillar.queue_free)


static func play_lava_death(player: Node, fall_death: bool) -> void:
	if player == null:
		return
	if player.has_meta("lava_death_tween"):
		var old_tw: Variant = player.get_meta("lava_death_tween")
		if old_tw is Tween and (old_tw as Tween).is_valid():
			(old_tw as Tween).kill()
		player.remove_meta("lava_death_tween")
	player.set("_lava_death_active", true)
	set_dead_visuals(player, true)
	var body_model: Node3D = player.get("body_model") as Node3D
	if body_model:
		body_model.visible = true
	if player.has_method("_apply_ghost_visuals"):
		player.call("_apply_ghost_visuals")
	var lava_y: float = _lava_surface_world_y(player)
	var scene: Node = _lava_fx_scene(player)
	var splash_pos := Vector3(player.global_position.x, lava_y + 0.06, player.global_position.z)
	if fall_death and scene != null:
		spawn_lava_impact_splash(scene, splash_pos)
	var target_y: float = lava_y - lerpf(lava_death_sink_y_stand, lava_death_sink_y_fall, 1.0 if fall_death else 0.0)
	var duration: float = lerpf(lava_death_sink_dur_stand, lava_death_sink_dur_fall, 1.0 if fall_death else 0.0)
	var tw := player.create_tween()
	player.set_meta("lava_death_tween", tw)
	if fall_death:
		tw.tween_interval(lava_splash_rise_dur)
	tw.tween_callback(_apply_lava_body.bind(player))
	tw.tween_property(player, "global_position:y", target_y, duration)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)


static func end_lava_death(player: Node) -> void:
	if player == null:
		return
	player.set("_lava_death_active", false)
	if player.has_meta("lava_death_tween"):
		var tw: Variant = player.get_meta("lava_death_tween")
		if tw is Tween and (tw as Tween).is_valid():
			(tw as Tween).kill()
		player.remove_meta("lava_death_tween")
	if player.has_method("restore_body_materials"):
		player.call("restore_body_materials")


static func clear_ragdoll(player: Node) -> void:
	var pieces: Array = player.get("_ragdoll_pieces")
	for piece in pieces:
		if is_instance_valid(piece):
			if piece is RigidBody3D:
				_free_ragdoll_blood_wounds(piece as RigidBody3D)
			piece.queue_free()
	pieces.clear()
	clear_player_blood_wounds(player)
	end_lava_death(player)
	set_dead_visuals(player, false)

static func apply_knockback(player: Node, impulse: Vector3) -> void:
	if bool(player.get("ghost_mode")) or bool(player.get("frozen")) or not player.is_multiplayer_authority():
		return
	player.set("velocity", player.get("velocity") + impulse)
