@tool
extends Node3D

# Builds a stylized first-person rifle from primitive meshes. Every @export
# below has a setter that rebuilds the gun, so tweaking values in the editor
# inspector updates the viewport in real time.
#
# Usage:
#   • Open scenes/gun_preview.tscn in the editor to iterate visually.
#   • Or attach this script to a Node3D in any scene to use the gun in-game.

@export_group("Receiver")
@export var receiver_size: Vector3 = Vector3(0.075, 0.10, 0.26) : set = _set_receiver_size
@export var receiver_color: Color = Color(0.13, 0.14, 0.17) : set = _set_receiver_color
@export var receiver_metallic: float = 0.85 : set = _set_receiver_metallic
@export var receiver_roughness: float = 0.32 : set = _set_receiver_roughness
@export var furniture_color: Color = Color(0.3, 0.25, 0.18) : set = _set_furniture_color

@export_group("Barrel")
@export var barrel_count: int = 1 : set = _set_barrel_count
@export var barrel_length: float = 0.42 : set = _set_barrel_length
@export var barrel_radius: float = 0.022 : set = _set_barrel_radius
@export var muzzle_flare: float = 1.55 : set = _set_muzzle_flare  # muzzle radius = barrel_radius × this
@export var muzzle_length: float = 0.05 : set = _set_muzzle_length
@export var wide_muzzle: bool = false : set = _set_wide_muzzle
@export var is_minigun: bool = false : set = _set_is_minigun

@export_group("Magazine")
@export var mag_size: Vector3 = Vector3(0.08, 0.16, 0.06) : set = _set_mag_size
@export var mag_offset_z: float = 0.04 : set = _set_mag_offset_z
@export var mag_tilt_deg: float = 0.0 : set = _set_mag_tilt_deg
@export var mag_drum: bool = false : set = _set_mag_drum  # circular drum magazine (Tommy-gun style)

@export_group("Furniture")
@export var foregrip_length: float = 0.12 : set = _set_foregrip_length
@export var foregrip_radius: float = 0.022 : set = _set_foregrip_radius
@export var foregrip_offset_z: float = 0.26 : set = _set_foregrip_offset_z
@export var handguard_height: float = 0.025 : set = _set_handguard_height
@export var sight_rail_height: float = 0.02 : set = _set_sight_rail_height
@export var sight_post_height: float = 0.04 : set = _set_sight_post_height
@export var rear_sight_radius: float = 0.022 : set = _set_rear_sight_radius
@export var has_scope: bool = false : set = _set_has_scope
@export var scope_length: float = 0.18 : set = _set_scope_length
@export var pistol_grip_length: float = 0.13 : set = _set_pistol_grip_length
@export var pistol_grip_radius: float = 0.024 : set = _set_pistol_grip_radius
@export var pistol_grip_tilt_deg: float = -36.0 : set = _set_pistol_grip_tilt_deg
@export var trigger_guard_radius: float = 0.028 : set = _set_trigger_guard_radius
@export var stock_size: Vector3 = Vector3(0.05, 0.09, 0.2) : set = _set_stock_size
@export var stock_taper: float = 0.7 : set = _set_stock_taper  # front height as fraction of back
@export var has_stock: bool = true : set = _set_has_stock
@export var has_foregrip: bool = true : set = _set_has_foregrip

@export_group("Barrel Shroud")
# Vented metal shroud wrapping the barrel — high projectiles/sec builds (hidden
# once minigun rotation takes over). Length scales with sustained fire rate;
# width wraps multi-barrel layouts. Slot count stays fixed — only coverage grows.
@export var has_shroud: bool = false : set = _set_has_shroud
@export var shroud_extent: float = 0.05 : set = _set_shroud_extent       # horizontal half-width (X)
@export var shroud_length_frac: float = 0.65 : set = _set_shroud_length_frac # fraction of barrel_length covered
@export var shroud_slot_count: int = 5 : set = _set_shroud_slot_count

@export_group("Launcher Tube")
# Shouldered RPG-style tube behind the stock — any explosive rounds.
@export var has_launcher_tube: bool = false : set = _set_has_launcher_tube
@export var launcher_tube_radius: float = 0.045 : set = _set_launcher_tube_radius
@export var launcher_tube_length: float = 0.14 : set = _set_launcher_tube_length

@export_group("Charging Handle")
# Bolt / charging handle: a small cylindrical knob sticking out sideways
# from a slot in the receiver (axis perpendicular to the barrel, like an
# AK charging handle). Snaps fully back the instant the gun fires, then
# slides forward to rest over bolt_cycle_time.
# bolt_travel is expressed as a fraction of the receiver length so it
# scales with whatever receiver size the weapon stats produce.
@export var bolt_travel_frac: float = 0.8 # travel = receiver_z * this
@export var bolt_cycle_time: float = 0.08 # fallback cycle (Player normally passes fire interval)
@export var bolt_radius: float = 0.009
@export var bolt_length: float = 0.04     # how far the knob sticks out sideways

@export_group("Casings")
# Spent shell casings ejected from the top-right of the receiver on each
# shot. Free-falling RigidBody3D's. Instead of a fixed despawn timer (which
# made a lone casing vanish almost immediately), we cap how many live at once
# and retire the oldest — so few shots linger but a firefight stays bounded.
@export var casing_radius_frac: float = 0.7   # fraction of barrel_radius
@export var casing_length_frac: float = 0.4   # fraction of receiver length
@export var max_casings: int = 30             # oldest casing retires past this (active rigid bodies are the top frame-hitch driver)
@export var casing_eject_speed: float = 2.8   # base m/s (jittered ±30%)
@export var casing_color: Color = Color(0.85, 0.65, 0.25)  # brass
# FIFO of this gun's live casings (oldest first). Casings live in current_scene,
# so we free them on _exit_tree to avoid leaking when the player respawns.
var _live_casings: Array[RigidBody3D] = []
var _casing_mat: StandardMaterial3D = null  # shared by this gun's casings

@export_group("Heat")
# Barrels glow when fired a lot. add_heat() pumps in per-shot heat (Player
# scales it by damage_mult); we decay exponentially each frame and map the
# resulting 0..1+ value through a blackbody-like emission curve.
@export var heat_glow_threshold: float = 0.15      # below this, barrel stays cold (subtle floor)
@export var heat_decay_per_sec: float = 0.3        # exponential decay rate
@export var heat_max_emission_energy: float = 6.0  # emission_energy_multiplier at heat=1
@export var heat_emits_light: bool = true          # OmniLight at muzzle, runtime only
@export var heat_add_factor: float = 0.01           # The amount of heat added per shot (depends on damage)
const RECEIVER_HEAT_FRACTION := 0.1  # receiver glows at 40% of barrel intensity
const SHROUD_BPS_APPEAR := 6.0
const SHROUD_BPS_FULL := 42.0

@export_group("Indicator (Emissive)")
@export var indicator_color: Color = Color(0.4, 1.0, 0.95) : set = _set_indicator_color
@export var indicator_size: Vector3 = Vector3(0.012, 0.012, 0.05) : set = _set_indicator_size
@export var indicator_energy: float = 4.0 : set = _set_indicator_energy
# Default off — the OmniLight gizmo clutters the preview. Flip on for game.
@export var indicator_emits_light: bool = false : set = _set_indicator_emits_light

@export_group("Preview From Weapon Stats")
# Flip this on, then tweak the stats below — they'll drive every gun part
# via apply_weapon_stats(), letting you preview how a card-modified weapon
# looks. Flip off to manually tweak individual exports above.
@export var preview_apply_stats: bool = false : set = _set_preview_apply_stats
@export var preview_spread_deg: float = 0.46 : set = _set_preview_spread_deg
@export var preview_bullet_scale: float = 1.0 : set = _set_preview_bullet_scale
@export var preview_damage_mult: float = 1.0 : set = _set_preview_damage_mult
@export var preview_mag_size: int = 5 : set = _set_preview_mag_size
@export var preview_fire_rate_mult: float = 1.0 : set = _set_preview_fire_rate_mult
@export var preview_shots_per_trigger: int = 1 : set = _set_preview_shots_per_trigger

# ---- Setters: each export rebuilds when changed ----
func _set_receiver_size(v: Vector3) -> void:        receiver_size = v;        _rebuild()
func _set_receiver_color(v: Color) -> void:         receiver_color = v;       _rebuild()
func _set_receiver_metallic(v: float) -> void:      receiver_metallic = v;    _rebuild()
func _set_receiver_roughness(v: float) -> void:     receiver_roughness = v;   _rebuild()
func _set_furniture_color(v: Color) -> void:        furniture_color = v;      _rebuild()
func _set_barrel_count(v: int) -> void:             barrel_count = max(1, v); _rebuild()
func _set_barrel_length(v: float) -> void:          barrel_length = v;        _rebuild()
func _set_barrel_radius(v: float) -> void:          barrel_radius = v;        _rebuild()
func _set_muzzle_flare(v: float) -> void:           muzzle_flare = v;         _rebuild()
func _set_muzzle_length(v: float) -> void:          muzzle_length = v;        _rebuild()
func _set_wide_muzzle(v: bool) -> void:             wide_muzzle = v;          _rebuild()
func _set_is_minigun(v: bool) -> void:             is_minigun = v;           _rebuild()
func _set_mag_size(v: Vector3) -> void:             mag_size = v;             _rebuild()
func _set_mag_offset_z(v: float) -> void:           mag_offset_z = v;         _rebuild()
func _set_mag_tilt_deg(v: float) -> void:           mag_tilt_deg = v;         _rebuild()
func _set_mag_drum(v: bool) -> void:                mag_drum = v;             _rebuild()
func _set_foregrip_length(v: float) -> void:        foregrip_length = v;      _rebuild()
func _set_foregrip_radius(v: float) -> void:        foregrip_radius = v;      _rebuild()
func _set_foregrip_offset_z(v: float) -> void:      foregrip_offset_z = v;    _rebuild()
func _set_handguard_height(v: float) -> void:       handguard_height = v;     _rebuild()
func _set_sight_rail_height(v: float) -> void:      sight_rail_height = v;    _rebuild()
func _set_sight_post_height(v: float) -> void:      sight_post_height = v;    _rebuild()
func _set_rear_sight_radius(v: float) -> void:      rear_sight_radius = v;    _rebuild()
func _set_has_scope(v: bool) -> void:               has_scope = v;            _rebuild()
func _set_scope_length(v: float) -> void:           scope_length = v;         _rebuild()
func _set_pistol_grip_length(v: float) -> void:     pistol_grip_length = v;   _rebuild()
func _set_pistol_grip_radius(v: float) -> void:     pistol_grip_radius = v;   _rebuild()
func _set_pistol_grip_tilt_deg(v: float) -> void:   pistol_grip_tilt_deg = v; _rebuild()
func _set_trigger_guard_radius(v: float) -> void:   trigger_guard_radius = v; _rebuild()
func _set_stock_size(v: Vector3) -> void:           stock_size = v;           _rebuild()
func _set_stock_taper(v: float) -> void:            stock_taper = v;          _rebuild()
func _set_has_stock(v: bool) -> void:               has_stock = v;            _rebuild()
func _set_has_foregrip(v: bool) -> void:            has_foregrip = v;         _rebuild()
func _set_has_shroud(v: bool) -> void:              has_shroud = v;           _rebuild()
func _set_shroud_extent(v: float) -> void:          shroud_extent = v;        _rebuild()
func _set_shroud_length_frac(v: float) -> void:     shroud_length_frac = v;   _rebuild()
func _set_shroud_slot_count(v: int) -> void:        shroud_slot_count = max(1, v); _rebuild()
func _set_has_launcher_tube(v: bool) -> void:       has_launcher_tube = v;    _rebuild()
func _set_launcher_tube_radius(v: float) -> void:  launcher_tube_radius = v; _rebuild()
func _set_launcher_tube_length(v: float) -> void:  launcher_tube_length = v; _rebuild()
func _set_indicator_color(v: Color) -> void:        indicator_color = v;      _rebuild()
func _set_indicator_size(v: Vector3) -> void:       indicator_size = v;       _rebuild()
func _set_indicator_energy(v: float) -> void:       indicator_energy = v;     _rebuild()
func _set_indicator_emits_light(v: bool) -> void:   indicator_emits_light = v; _rebuild()

func _set_preview_apply_stats(v: bool) -> void:     preview_apply_stats = v;     _request_preview()
func _set_preview_spread_deg(v: float) -> void:     preview_spread_deg = v;      _request_preview()
func _set_preview_bullet_scale(v: float) -> void:   preview_bullet_scale = v;    _request_preview()
func _set_preview_damage_mult(v: float) -> void:    preview_damage_mult = v;     _request_preview()
func _set_preview_mag_size(v: int) -> void:         preview_mag_size = v;        _request_preview()
func _set_preview_fire_rate_mult(v: float) -> void: preview_fire_rate_mult = v;  _request_preview()
func _set_preview_shots_per_trigger(v: int) -> void: preview_shots_per_trigger = max(1, v); _request_preview()

# Setters can fire during scene-load before sibling properties settle, which
# briefly leaves them as Nil. Coalesce calls with a deferred apply so we
# only run once everything is initialised.
var _preview_pending: bool = false
func _request_preview() -> void:
	if _preview_pending:
		return
	_preview_pending = true
	_apply_preview.call_deferred()

# Build a temporary Weapon from the preview exports and pump it through the
# normal mapping. No-op when the toggle is off, so manual tweaks to the
# part exports above keep working.
func _apply_preview() -> void:
	_preview_pending = false
	if not preview_apply_stats:
		return
	var w := Weapon.new()
	if w == null:
		return
	w.spread = deg_to_rad(float(preview_spread_deg))
	w.bullet_scale = float(preview_bullet_scale)
	w.damage_mult = float(preview_damage_mult)
	w.mag_size_bonus = int(preview_mag_size) - Weapon.BASE_MAG_SIZE
	w.fire_rate_mult = float(preview_fire_rate_mult)
	w.extra_projectiles = max(0, int(preview_shots_per_trigger) - 1)
	apply_weapon_stats(w)

var _suppress_rebuild: bool = false

# --- Heat state ---
# Barrel material is rebuilt with the rest of the gun, but heat persists
# across rebuilds so swapping cards mid-spam doesn't cool the gun instantly.
var heat: float = 0.0
var _barrel_material: StandardMaterial3D = null
var _barrel_group: Node3D = null
var _barrel_spin: float = 0.0
var _receiver_material: StandardMaterial3D = null
var _heat_light: OmniLight3D = null
var _muzzle_exit_local: Vector3 = Vector3(0.0, 0.0, -0.35)

# --- Bolt / charging handle state ---
# `_bolt_back` is the current backward offset (0 = rest, _bolt_travel = max).
# Snaps to _bolt_travel on cycle_bolt(), decays linearly back to zero over
# `_bolt_cycle_seconds` (Player passes the current fire interval, so the
# bolt arrives at rest exactly as the next shot snaps it back again).
# Travel is computed at rebuild time from receiver size × bolt_travel_frac.
# Two bolts (left + right) cycle in lock-step, so a single offset drives both.
var _bolts: Array[MeshInstance3D] = []
var _bolt_rest_z: float = 0.0
var _bolt_back: float = 0.0
var _bolt_travel: float = 0.0
var _bolt_cycle_seconds: float = 0.08

# --- Growth animation state ---
# Card-pick "the gun grows" moment: lerp the previous Weapon's stats into the
# new ones and re-run apply_weapon_stats at a bounded cadence, so barrels
# stretch, receivers swell and new parts pop in over ~2s instead of snapping.
# _grow_to is the player's LIVE Weapon (held by reference), so stat pushes
# that land mid-animation (round modifiers) fold into the final form.
var _grow_from: Weapon = null
var _grow_to: Weapon = null
var _grow_elapsed: float = 0.0
var _grow_duration: float = 2.0
var _grow_next_apply: float = 0.0
var _grow_applying: bool = false
const GROW_APPLY_INTERVAL := 1.0 / 24.0  # rebuild cadence — per-frame would thrash meshes

func _ready() -> void:
	_rebuild()
	_request_preview()

func _exit_tree() -> void:
	# This gun's casings live in the scene, not under us — free our own when the
	# gun goes away (player respawn / scene change) so they don't leak.
	for c in _live_casings:
		if is_instance_valid(c):
			c.queue_free()
	_live_casings.clear()

func _process(delta: float) -> void:
	var _pt := Time.get_ticks_usec() if Trace.enabled else 0
	# Minigun barrel rotation
	if _barrel_group and is_minigun:
		_barrel_group.rotate_z(_barrel_spin * delta)
		_barrel_spin *= exp(-2.5 * delta)
	if Engine.is_editor_hint():
		return
	# Growth animation — re-apply lerped stats at a bounded cadence. Clamp the
	# step so a hitch frame (arena swap, shader warmup) can't swallow the
	# whole morph in one delta.
	if _grow_to != null:
		_grow_elapsed += minf(delta, 0.05)
		if _grow_elapsed >= _grow_duration:
			var final_w := _grow_to
			_grow_from = null
			_grow_to = null
			apply_weapon_stats(final_w)
		elif _grow_elapsed >= _grow_next_apply:
			_grow_next_apply = _grow_elapsed + GROW_APPLY_INTERVAL
			_grow_applying = true
			apply_weapon_stats(_lerp_weapon(_grow_from, _grow_to, _grow_ease(_grow_elapsed / _grow_duration)))
			_grow_applying = false
	# Heat — exponential decay. Snappier than linear and matches how a hot
	# object actually radiates away energy.
	if heat > 0.0:
		heat *= exp(-heat_decay_per_sec * delta)
		if heat < 0.001:
			heat = 0.0
		_update_heat_visual()
	# Bolt — linear return from full back to rest. Snap-back is instant on
	# cycle_bolt(); only the forward stroke needs to be animated here.
	if _bolts.size() > 0 and _bolt_back > 0.0:
		var return_speed: float = _bolt_travel / maxf(0.001, _bolt_cycle_seconds)
		_bolt_back = maxf(0.0, _bolt_back - return_speed * delta)
		var z: float = _bolt_rest_z + _bolt_back
		for b in _bolts:
			b.position = Vector3(b.position.x, b.position.y, z)
	if Trace.enabled:
		Trace.prof("gun", Time.get_ticks_usec() - _pt)

# Spawn a brass casing as a free-falling RigidBody3D in world space. Pops
# out the top-right of the receiver with a randomised impulse and tumble.
# Lives in current_scene so it persists when the gun moves with the player.
func clear_live_casings() -> void:
	_live_casings.clear()


func eject_casing() -> void:
	if Engine.is_editor_hint():
		return
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		return
	# Bench A/B: skip casing spawning to attribute physics cost. One static
	# bool branch outside the bench (BenchFlags.active = false).
	if BenchFlags.active and BenchFlags.no_casings:
		return
	# Governor shed tier 1: casings are pure cosmetics but each is an active
	# rigid body with contact monitoring — on struggling machines skip them.
	if PerfGovernor and not PerfGovernor.casings_enabled:
		return
	BenchFlags.inc("casings_spawned")

	var c_radius: float = barrel_radius * casing_radius_frac
	var c_length: float = receiver_size.z * casing_length_frac

	var rb := RigidBody3D.new()
	rb.add_to_group("brass_casings")
	rb.mass = 0.02
	# Layer 0 so casings don't block anything; mask 1 so they collide with
	# world geometry only (not players, not other casings, not bullets).
	rb.collision_layer = 0
	rb.collision_mask = 1
	# contact_monitor lets us hear body_entered for the metallic ping sound.
	rb.contact_monitor = true
	rb.max_contacts_reported = 4
	var pmat := PhysicsMaterial.new()
	pmat.bounce = 0.35
	pmat.friction = 0.6
	rb.physics_material_override = pmat

	# Mesh — slight nose taper for shell look. Rotated so the cylinder's
	# long axis lies along local Z (matches the rotated collision shape).
	var mi := MeshInstance3D.new()
	mi.mesh = _cached_cylinder_mesh(c_radius * 0.85, c_radius, c_length, 6)
	if _casing_mat == null:
		_casing_mat = StandardMaterial3D.new()
		_casing_mat.albedo_color = casing_color
		_casing_mat.metallic = 0.9
		_casing_mat.roughness = 0.35
	mi.material_override = _casing_mat
	mi.rotation = Vector3(PI * 0.5, 0, 0)
	rb.add_child(mi)

	var cs := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = c_radius
	shape.height = c_length
	cs.shape = shape
	cs.rotation = Vector3(PI * 0.5, 0, 0)
	rb.add_child(cs)

	# Spawn just outside the top-right corner of the receiver. global_transform
	# is the gun's world transform (it's parented under the camera/muzzle),
	# so this places the casing wherever the gun is being held.
	var local_spawn := Vector3(receiver_size.x * 0.5 + c_radius * 1.5, receiver_size.y * 0.5 + c_radius, 0)
	var spawn_pos: Vector3 = global_transform * local_spawn
	# Inherit the gun's orientation so the casing starts aligned with the
	# barrel before the random tumble takes over.
	rb.transform = Transform3D(global_transform.basis, spawn_pos)
	tree.current_scene.add_child(rb)

	# Eject toward up + right in the gun's own frame, jittered. Speed is
	# randomised ±30%, tumble axes are uniformly random.
	var basis: Basis = global_transform.basis
	var dir: Vector3 = (basis.y * 1.4 + basis.x * 1.0).normalized()
	dir = (dir + Vector3(
		randf_range(-0.25, 0.25),
		randf_range(-0.15, 0.15),
		randf_range(-0.25, 0.25),
	)).normalized()
	rb.linear_velocity = dir * casing_eject_speed * randf_range(0.7, 1.3)
	rb.angular_velocity = Vector3(
		randf_range(-12.0, 12.0),
		randf_range(-12.0, 12.0),
		randf_range(-12.0, 12.0),
	)

	# Metallic ping on every ground contact, throttled per-casing so a single
	# bounce doesn't trigger a flurry of pings from multiple contact points.
	# Volume scales with the casing's current speed so the initial fall is
	# loud and subsequent bounces taper off naturally as energy drains.
	# Pitch jitter is small — variation reads as the same shell hitting the
	# same surface, not as different objects.
	rb.set_meta("last_ping", -1.0)
	var ref_speed: float = casing_eject_speed
	# Bigger casings ring lower. barrel_radius=0.022 is the default; cards
	# that fatten the barrel produce heavier rounds and lower-pitched pings.
	# Exponent 0.7 ≈ an octave drop per ~2.7× size change. Clamped so the
	# extremes don't sound like a sub-bass thud or a chipmunk ping.
	var size_pitch: float = clampf(pow(0.022 / maxf(0.001, barrel_radius), 0.7), 0.55, 1.4)
	rb.body_entered.connect(func(_other: Node) -> void:
		var now: float = Time.get_ticks_msec() / 1000.0
		if now - float(rb.get_meta("last_ping")) < 0.06:
			return
		rb.set_meta("last_ping", now)
		# Speed is the post-impact value here — still a good proxy because
		# bouncier hits retain more energy. Map [low, ref] → [-22, +2] dB.
		var speed: float = rb.linear_velocity.length()
		var loudness: float = clampf(speed / ref_speed, 0.05, 1.2)
		var vol_db: float = lerpf(-22.0, 2.0, loudness)
		SFX.casing_drop(rb.global_position, size_pitch * randf_range(0.96, 1.04), vol_db)
	)

	# Count-cap instead of a despawn timer: track this casing and, once we're
	# over max_casings, retire the oldest still-alive one. A handful of casings
	# lingers; a sustained firefight can't pile up past the cap.
	_live_casings.append(rb)
	var casing_cap := maxi(1, int(round(float(max_casings) * PerfGovernor.quality_scale))) if PerfGovernor else max_casings
	while _live_casings.size() > casing_cap:
		var oldest: RigidBody3D = _live_casings.pop_front()
		if is_instance_valid(oldest):
			oldest.queue_free()

# Called by Player on every shot — slams the bolt to its rear stop. The
# forward return happens in _process so rapid fire keeps it pinned back.
# `cycle_seconds` is the time the bolt should take to return to rest;
# pass the weapon's current fire interval so it arrives just as the next
# shot snaps it back again. <= 0 falls back to the bolt_cycle_time export.
func cycle_bolt(cycle_seconds: float = -1.0) -> void:
	if is_minigun:
		_barrel_spin = minf(_barrel_spin + 12.0, 45.0)
	if _bolts.size() == 0:
		return
	_bolt_back = _bolt_travel
	_bolt_cycle_seconds = cycle_seconds if cycle_seconds > 0.0 else bolt_cycle_time
	var z: float = _bolt_rest_z + _bolt_back
	for b in _bolts:
		b.position = Vector3(b.position.x, b.position.y, z)

# Called by Player on every shot. amount is typically a small base value
# scaled by damage_mult so heavy-hitting builds heat up faster.
func add_heat(amount: float) -> void:
	amount *= heat_add_factor
	if amount <= 0.0:
		return
	heat = clampf(heat + amount, 0.0, 1.5)
	_update_heat_visual()

func reset_heat() -> void:
	if heat <= 0.0:
		return
	heat = 0.0
	_update_heat_visual()

func _update_heat_visual() -> void:
	if _barrel_material == null:
		return
	# Below the threshold, barrel reads as cold steel (no emission). Above it,
	# colour walks from dull red → bright red → orange → yellow-white,
	# roughly tracking how heated iron actually looks.
	var glow_t: float = clampf(smoothstep(heat_glow_threshold, 1.0, heat), 0.0, 1.0)
	if glow_t <= 0.0:
		_barrel_material.emission_energy_multiplier = 0.0
		if _receiver_material:
			_receiver_material.emission_energy_multiplier = 0.0
		if _heat_light:
			_heat_light.visible = false
		return
	var r: float = 1.0
	var g: float = lerpf(0.0, 0.7, pow(glow_t, 1.4))
	var b: float = lerpf(0.0, 0.3, pow(glow_t, 3.0))
	var emission := Color(r, g, b)
	var barrel_energy: float = lerpf(0.0, heat_max_emission_energy, glow_t)
	_barrel_material.emission = emission
	_barrel_material.emission_energy_multiplier = barrel_energy
	# Receiver heats up too (it's bolted to the barrel) but only partially —
	# the chamber/breech area is hot while the grip end stays cool. Mid-body
	# emissive at 40% sells the conduction without overpowering the barrel.
	if _receiver_material:
		_receiver_material.emission = emission
		_receiver_material.emission_energy_multiplier = barrel_energy * RECEIVER_HEAT_FRACTION
	if _heat_light:
		_heat_light.visible = true
		_heat_light.light_color = emission
		_heat_light.light_energy = lerpf(0.0, 0.45, glow_t)

# Map a Weapon's gameplay stats onto the gun's visual parameters. Bulk-set
# everything inside _suppress_rebuild so we only rebuild meshes once.
#   Accuracy (low spread)   → longer barrel
#   Bullet size             → fatter barrel + flare
#   Damage                  → bigger receiver + deeper magazine
#   Mag size                → taller magazine
#   Fire rate > 1.5×        → stock + foregrip appear (bracing for full-auto)
func apply_weapon_stats(w: Weapon) -> void:
	if w == null:
		return
	if not _grow_applying and _grow_to != null:
		if w == _grow_to:
			return  # growth animation in flight — it lands on these stats
		_grow_from = null
		_grow_to = null  # retargeted to a different weapon — cancel the morph
	_suppress_rebuild = true

	# Barrel length curve: a steep power so the default gun stays modest and
	# only very tight-spread builds (SNIPER, stacked accuracy) earn the long
	# barrel. Max ~1.4 m at spread 0; ~0.42 m at default spread.
	var spread_factor: float = clampf(1.0 - w.spread / 0.05, 0.0, 1.0)
	barrel_length = lerpf(0.20, 1.4, pow(spread_factor, 10.0))

	# Damage and bullet size both fatten the barrel — heavier rounds need a
	# beefier barrel; the muzzle flare scales with it automatically.
	var dmg_factor: float = clampf((w.damage_mult - 1.0) / 4.0, 0.0, 1.0)
	var dmg_barrel_scale: float = lerpf(1.0, 1.7, dmg_factor)
	# Use max(w.bullet_scale, 1.0) so high-precision rounds (which often reduce
	# bullet_scale for gameplay balance) don't make the barrel look like a needle.
	barrel_radius = clampf(0.022 * maxf(w.bullet_scale, 1.0) * dmg_barrel_scale, 0.012, 0.10)
	barrel_count = w.get_shots_per_trigger()

	# Receiver grows with damage — heavy rounds need a deeper, taller chamber.
	# X (width) auto-expands later to wrap multi-barrel layouts. Y (height)
	# scales up to ~1.6×; Z (length) up to ~2.1×, which also lengthens the
	# bolt slot, casing length, and stock offset that derive from it.
	receiver_size = Vector3(0.075, lerpf(0.10, 0.16, dmg_factor), lerpf(0.26, 0.55, dmg_factor))
	var rounds: int = w.get_mag_size()
	mag_drum = rounds > 30
	if mag_drum:
		# For drums: mag_size.y becomes the drum diameter, mag_size.x the thickness.
		var drum_d: float = clampf(0.18 + 0.006 * float(rounds - 30), 0.18, 0.36)
		mag_size = Vector3(0.07, drum_d, lerpf(0.06, 0.11, dmg_factor))
	else:
		var mag_h: float = clampf(0.04 + 0.024 * float(rounds), 0.06, 0.6)
		var mag_z: float = lerpf(0.06, 0.11, dmg_factor)
		mag_size = Vector3(0.08, mag_h, mag_z)

	# Long-barrelled guns need a shoulder stock + foregrip to brace.
	# Threshold is roughly mid-range — short SMG / pistol stays bare,
	# rifle-length barrels gain the bracing furniture.
	has_stock = barrel_length > 0.55
	has_foregrip = barrel_length > 0.55
	# Pin-point accuracy gets a scope. Default base spread is ~0.008 rad (~0.46°);
	# SNIPER drops it to 0. Threshold 0.003 rad (~0.17°) fires for any sniper-
	# class build but not casual accuracy buffs.
	has_scope = w.spread < 0.003
	is_minigun = w.fire_rate_mult >= 5.0
	# Very heavy hitters get a Havoc-style wide rectangular muzzle.
	wide_muzzle = w.damage_mult >= 3.0
	# Vented barrel shroud — sleeve length tracks projectiles/sec; width wraps
	# however many barrels are mounted. Dropped at minigun tier (spinning barrels
	# read as the cooling solution instead).
	var bps: float = w.get_projectiles_per_second()
	var bps_factor: float = clampf((bps - SHROUD_BPS_APPEAR) / (SHROUD_BPS_FULL - SHROUD_BPS_APPEAR), 0.0, 1.0)
	has_shroud = bps >= SHROUD_BPS_APPEAR and not is_minigun
	shroud_length_frac = lerpf(0.34, 0.92, bps_factor)
	shroud_slot_count = 5
	var n_barrels: int = max(1, barrel_count)
	var barrel_pitch: float = barrel_radius * 2.4
	var barrel_span: float = barrel_pitch * float(n_barrels - 1)
	var single_clearance: float = barrel_radius + 0.012
	if n_barrels > 1:
		shroud_extent = barrel_span * 0.5 + single_clearance
	else:
		shroud_extent = single_clearance
	# Any explosive stack replaces the rifle stock with a plain launcher tube.
	var blast_factor: float = clampf((w.explosive_radius - 4.0) / 10.0, 0.0, 1.0) if w.explosive_radius > 0.0 else 0.0
	has_launcher_tube = w.explosive_radius > 0.0
	launcher_tube_length = lerpf(0.14, 0.46, blast_factor)
	if has_launcher_tube:
		has_stock = false
		launcher_tube_radius = receiver_size.y * 0.5

	_suppress_rebuild = false
	_rebuild()

func get_muzzle_exit_local() -> Vector3:
	return _muzzle_exit_local

# Start a ~2s morph from one weapon's visual form into another's (see the
# growth-animation state block above). Pass the player's live Weapon as
# `to_w` so late stat pushes retarget instead of cancelling.
func animate_weapon_growth(from_w: Weapon, to_w: Weapon, duration: float = 2.0) -> void:
	if from_w == null or to_w == null or Engine.is_editor_hint():
		return
	_grow_from = from_w
	_grow_to = to_w
	_grow_duration = maxf(0.1, duration)
	_grow_elapsed = 0.0
	_grow_next_apply = 0.0
	# Snap to the OLD form right now — callers apply the final stats before
	# arming the morph, and even one rendered frame of the finished gun
	# spoils the reveal.
	_grow_applying = true
	apply_weapon_stats(_lerp_weapon(from_w, to_w, 0.0))
	_grow_applying = false

func is_growing() -> bool:
	return _grow_to != null

# Smootherstep: slow start, the growth through the middle, a soft landing.
# It used to be easeInOutBack, but its dip below 0 and overshoot past 1 sent
# the on/off parts (stock, scope, drum mag, shroud) back and forth across
# their thresholds, so they popped in and out mid-morph: the glitch Joep saw
# (2026-10-21). A monotonic curve crosses each threshold once.
static func _grow_ease(t: float) -> float:
	t = clampf(t, 0.0, 1.0)
	return t * t * t * (t * (t * 6.0 - 15.0) + 10.0)

# Blend only the fields apply_weapon_stats reads; everything else stays at
# Weapon defaults. Floors stay clamped in case a caller passes t outside 0..1.
static func _lerp_weapon(a: Weapon, b: Weapon, t: float) -> Weapon:
	var w := Weapon.new()
	w.spread = maxf(0.0, lerpf(a.spread, b.spread, t))
	w.bullet_scale = maxf(0.05, lerpf(a.bullet_scale, b.bullet_scale, t))
	w.damage_mult = maxf(0.05, lerpf(a.damage_mult, b.damage_mult, t))
	w.fire_rate_mult = maxf(0.05, lerpf(a.fire_rate_mult, b.fire_rate_mult, t))
	w.mag_size_bonus = int(round(lerpf(float(a.mag_size_bonus), float(b.mag_size_bonus), t)))
	w.extra_projectiles = maxi(0, int(round(lerpf(float(a.extra_projectiles), float(b.extra_projectiles), t))))
	w.explosive_radius = maxf(0.0, lerpf(a.explosive_radius, b.explosive_radius, t))
	return w

# ---- Build ----
# Forward is local -Z (Godot convention); +Y up; +X right.
# Receiver is centred at origin, barrel pokes forward (-Z), magazine drops
# below (+Y down), sights sit on top.
func _rebuild() -> void:
	if _suppress_rebuild:
		return
	# Bucketed separately from "gun" (which is _process bolt animation): the
	# pick-time rebuild cost was invisible to every trace bucket for weeks.
	var _pt := 0
	if not Engine.is_editor_hint() and Trace.enabled:
		_pt = Time.get_ticks_usec()
	_rebuild_impl()
	if _pt != 0:
		Trace.prof("gun_rebuild", Time.get_ticks_usec() - _pt)


func _rebuild_impl() -> void:
	# remove_child is synchronous; queue_free is deferred. Detach first so
	# new children added below don't collide with old names (which would
	# auto-rename them to @MeshInstance3D@N and break get_node lookups).
	for c in get_children():
		remove_child(c)
		c.queue_free()

	var metal := _make_material(receiver_color, receiver_metallic, receiver_roughness)
	var darker_metal := _make_material(receiver_color * 0.6, 0.95, 0.22)
	# Grips, stock, handguard and magazine: matte polymer in a warm tan, so
	# the gun reads as two-tone instead of one dark lump.
	var polymer := _make_polymer(furniture_color)
	# Barrels + muzzles get their own material so heat-driven emission
	# doesn't bleed onto the stock / sights that share darker_metal.
	_barrel_material = _make_material(receiver_color * 0.6, 0.95, 0.22)
	# Heat glow only changes the energy; emission stays enabled from the
	# start, so the first hot barrel doesn't compile a new shader variant.
	_barrel_material.emission_enabled = true
	_barrel_material.emission_energy_multiplier = 0.0
	metal.emission_enabled = true
	metal.emission_energy_multiplier = 0.0
	# Receiver tracks barrel heat at a reduced fraction (see _update_heat_visual).
	# `metal` is only used by the Receiver mesh, so we can mutate it freely.
	_receiver_material = metal

	# Multi-barrel layout: barrels spread horizontally with a small gap. The
	# receiver widens to wrap them all so it doesn't look detached.
	var n_barrels: int = max(1, barrel_count)
	var barrel_pitch: float = barrel_radius * 2.4    # centre-to-centre spacing
	var barrel_span: float = barrel_pitch * float(n_barrels - 1)

	var muzzle_r: float = barrel_radius * muzzle_flare
	var bundle_radius: float = barrel_radius * 1.8

	# We calculate the final "effective" size once. The receiver widens to wrap
	# multiple barrels (X-axis), but we keep the height (Y-axis) dependent
	# only on the receiver's base stats so the sights don't move up with
	# barrel thickness.
	var min_receiver_w: float = (bundle_radius + barrel_radius) * 2.2 if is_minigun else barrel_span + barrel_radius * 3.0
	var effective_receiver_size := Vector3(maxf(receiver_size.x, min_receiver_w), receiver_size.y, receiver_size.z)

	# Receiver body
	_add_box("Receiver", effective_receiver_size, Vector3.ZERO, metal)
	# Break up the receiver box: a darker anodised lower receiver, an
	# ejection port on the right.
	var rs := effective_receiver_size
	var recess := _make_material(receiver_color * 0.2, 0.3, 0.8)
	_add_box("LowerReceiver", Vector3(rs.x * 1.04, rs.y * 0.34, rs.z * 0.92), Vector3(0, -rs.y * 0.34, rs.z * 0.02), darker_metal)
	_add_box("EjectionPort", Vector3(0.004, rs.y * 0.26, rs.z * 0.3), Vector3(rs.x * 0.5 + 0.001, rs.y * 0.14, -rs.z * 0.12), recess)


	# Charging handle (bolt) — a horizontal knob sticking out perpendicular
	# to the barrel from a slot on each side of the receiver, mirrored.
	# AK-style: the cylinder's axis runs along X (sideways), and the knob
	# slides along Z when fired. Both bolts cycle together via cycle_bolt
	# + _process.
	_bolt_travel = effective_receiver_size.z * clampf(bolt_travel_frac, 0.0, 0.95)
	var slot_x_abs: float = effective_receiver_size.x * 0.5
	# Slot just barely contains the bolt's full Z-range (bolt diameter at
	# each end). slot_z_center sits in the middle so travel is symmetric
	# around the receiver centre.
	var slot_depth_z: float = _bolt_travel + bolt_radius * 2.0
	var slot_z_center: float = 0.0
	var slot_h: float = bolt_radius * 2.4   # slot just taller than the knob
	var slot_thickness: float = 0.012
	var slot_mat := _make_material(receiver_color * 0.25, 0.4, 0.85)  # dark recess
	var bolt_mat := _make_material(Color(0.55, 0.57, 0.62), 0.95, 0.18)  # bright steel
	# Rest position: forward end of the slot, so the bolt has _bolt_travel
	# worth of room to slide back into.
	_bolt_rest_z = slot_z_center - _bolt_travel * 0.5
	_bolts.clear()
	for side in [-1.0, 1.0]:
		var sign_str: String = "L" if side < 0.0 else "R"
		_add_box("BoltSlot" + sign_str,
			Vector3(slot_thickness, slot_h, slot_depth_z),
			Vector3(side * (slot_x_abs + slot_thickness * 0.5), 0, slot_z_center),
			slot_mat)
		# _add_cylinder lays the axis along Z; rotate 90° around Y to swing
		# the axis to X, so the knob protrudes sideways from the receiver.
		var bolt := _add_cylinder("ChargingHandle" + sign_str,
			bolt_radius, bolt_radius, bolt_length,
			Vector3(side * (slot_x_abs + slot_thickness + bolt_length * 0.5), 0, _bolt_rest_z),
			bolt_mat)
		bolt.rotation = Vector3(PI * 0.5, PI * 0.5, 0)
		# Re-apply current back-offset so a rebuild mid-cycle doesn't pop the bolt.
		bolt.position = Vector3(bolt.position.x, bolt.position.y, _bolt_rest_z + _bolt_back)
		_bolts.append(bolt)

	# Barrels + muzzles — laid out side by side, centred on x = 0.
	var receiver_front_z: float = -effective_receiver_size.z * 0.5
	var barrel_centre_z: float = receiver_front_z - barrel_length * 0.5
	var muzzle_centre_z: float = receiver_front_z - barrel_length - muzzle_length * 0.5
	_muzzle_exit_local = Vector3(0.0, 0.0, muzzle_centre_z - muzzle_length * 0.5)

	# Sight rail repositioned after effective_receiver_size is final.
	# It sits exactly on top of the receiver (half-height + half-rail-height).
	# Capped at 4cm wide.
	var rail_y: float = effective_receiver_size.y * 0.5 + sight_rail_height * 0.5
	var rail_w: float = minf(effective_receiver_size.x * 0.8, 0.04)
	_add_picatinny_rail(Vector3(0, rail_y, 0), Vector3(rail_w, sight_rail_height, effective_receiver_size.z * 0.85), darker_metal)

	if is_minigun:
		_barrel_group = Node3D.new()
		_barrel_group.name = "BarrelGroup"
		add_child(_barrel_group)
		_finalize_owner(_barrel_group)
		for i in 6:
			var angle: float = float(i) * PI * 2.0 / 6.0
			var bx: float = cos(angle) * bundle_radius
			var by: float = sin(angle) * bundle_radius
			_add_cylinder("Barrel%d" % i, barrel_radius, barrel_radius, barrel_length, Vector3(bx, by, barrel_centre_z), _barrel_material, _barrel_group)
			_add_cylinder("Muzzle%d" % i, muzzle_r, muzzle_r * 0.85, muzzle_length, Vector3(bx, by, muzzle_centre_z), _barrel_material, _barrel_group)
	else:
		_barrel_group = null
		for i in n_barrels:
			var bx: float = (float(i) - float(n_barrels - 1) * 0.5) * barrel_pitch
			_add_cylinder("Barrel%d" % i, barrel_radius, barrel_radius, barrel_length, Vector3(bx, 0, barrel_centre_z), _barrel_material)
			if wide_muzzle:
				var slab_size := Vector3(barrel_radius * 4.5, barrel_radius * 1.6, muzzle_length)
				_add_box("Muzzle%d" % i, slab_size, Vector3(bx, 0, muzzle_centre_z), _barrel_material)
			else:
				_add_cylinder("Muzzle%d" % i, muzzle_r, muzzle_r * 0.85, muzzle_length, Vector3(bx, 0, muzzle_centre_z), _barrel_material)

	# Vented barrel shroud (high fire-rate builds — see apply_weapon_stats).
	if has_shroud:
		var s_length: float = barrel_length * clampf(shroud_length_frac, 0.05, 0.95)
		var s_centre_z: float = receiver_front_z - s_length * 0.5
		var s_half_x: float = maxf(shroud_extent, barrel_radius + 0.012)
		var s_half_y: float = barrel_radius + 0.012
		_add_barrel_shroud(s_centre_z, s_length, s_half_x, s_half_y, shroud_slot_count, darker_metal)

	# Magazine — box (default) or drum (Tommy-gun style cylinder, axis along X)
	# when mag_drum is on.
	if mag_drum:
		# Drum diameter = mag_size.y; thickness = mag_size.x. Centred just
		# below the receiver so the top of the drum touches the receiver bottom.
		var drum_radius: float = mag_size.y * 0.5
		var drum_thickness: float = mag_size.x
		var drum_y: float = -effective_receiver_size.y * 0.5 - drum_radius
		var drum := MeshInstance3D.new()
		drum.name = "Magazine"
		drum.mesh = _cached_cylinder_mesh(drum_radius, drum_radius, drum_thickness)
		drum.material_override = darker_metal
		# Cylinder default axis = Y; rotate 90° around X so the axis lies along Z
		# (drum face visible from the front, thin edge from the side).
		drum.rotation = Vector3(PI * 0.5, 0, 0)
		drum.position = Vector3(0, drum_y, mag_offset_z)
		add_child(drum)
		_finalize_owner(drum)
	else:
		var mag_y: float = -effective_receiver_size.y * 0.5 - mag_size.y * 0.5
		var mag := _add_box("Magazine", mag_size, Vector3(0, mag_y, mag_offset_z), polymer)
		mag.rotation = Vector3(deg_to_rad(mag_tilt_deg), 0, 0)
		mag.position = Vector3(0, mag_y, mag_offset_z)
		# A metal base plate closes the magazine off at the bottom.
		_add_box("MagBase", Vector3(mag_size.x * 1.1, 0.012, mag_size.z * 1.15), Vector3(0, -mag_size.y * 0.5, 0), darker_metal, mag)

	# Handguard + foregrip (only when the gun bracing is "on" — full-auto)
	if has_foregrip:
		var foregrip_z: float = receiver_front_z - foregrip_offset_z
		var hg_z: float = (receiver_front_z + foregrip_z) * 0.5
		var hg_length: float = receiver_front_z - foregrip_z
		var hg_y: float = -barrel_radius - handguard_height * 0.5
		_add_box("Handguard", Vector3(barrel_radius * 2.4, handguard_height, hg_length), Vector3(0, hg_y, hg_z), polymer)

		var foregrip_y: float = hg_y - handguard_height * 0.5 - foregrip_length * 0.5
		var grip := _add_cylinder("Foregrip", foregrip_radius, foregrip_radius * 0.85, foregrip_length, Vector3(0, foregrip_y, foregrip_z), polymer)
		grip.rotation = Vector3(deg_to_rad(-8.0), 0, 0)

	# Pistol grip — angled cylinder at back-bottom of the receiver
	var pgrip_z: float = effective_receiver_size.z * 0.32
	var pgrip_y: float = -effective_receiver_size.y * 0.5 - pistol_grip_length * 0.5
	var pgrip := _add_cylinder("PistolGrip", pistol_grip_radius, pistol_grip_radius * 1.05, pistol_grip_length, Vector3(0, pgrip_y, pgrip_z), polymer)
	# Tilt grip backwards (toward shooter) for ergonomic feel
	pgrip.rotation = Vector3(deg_to_rad(pistol_grip_tilt_deg), 0, 0)

	# Trigger guard — torus between magazine and pistol grip
	var tg_z: float = (mag_offset_z + pgrip_z) * 0.5
	var tg_y: float = -effective_receiver_size.y * 0.5 - trigger_guard_radius * 0.5
	var tg := _add_torus("TriggerGuard", trigger_guard_radius, trigger_guard_radius * 0.18, Vector3(0, tg_y, tg_z), darker_metal)
	# Rotate so the loop opens downward (axis along X) instead of forward.
	tg.rotation = Vector3(0, 0, PI * 0.5)

	# Stock (only when bracing is "on")
	var stock_bottom_y: float = -effective_receiver_size.y * 0.5
	var stock_rear_z: float = effective_receiver_size.z * 0.5
	if has_stock:
		var back_h: float = stock_size.y
		var front_h: float = stock_size.y * clampf(stock_taper, 0.05, 1.0)
		var half_z: float = stock_size.z * 0.5
		var bottom_y: float = stock_bottom_y
		var back_z: float = effective_receiver_size.z * 0.5 + half_z * 1.5   # rear half of total depth
		var front_z: float = effective_receiver_size.z * 0.5 + half_z * 0.5  # front half (closer to receiver)
		stock_rear_z = back_z + half_z
		_add_box("StockBack", Vector3(stock_size.x, back_h, half_z), Vector3(0, bottom_y + back_h * 0.5, back_z), polymer)
		_add_box("StockFront", Vector3(stock_size.x * 0.95, front_h, half_z), Vector3(0, bottom_y + front_h * 0.5, front_z), polymer)
		# Rubber butt pad: a dark end cap, so the stock ends in something.
		var pad_d: float = 0.012
		_add_box("ButtPad", Vector3(stock_size.x * 1.04, back_h * 1.04, pad_d), Vector3(0, bottom_y + back_h * 0.5, stock_rear_z + pad_d * 0.5), _make_polymer(Color(0.07, 0.07, 0.075)))
		stock_rear_z += pad_d

	# Plain launcher tube off the receiver rear — replaces the rifle stock.
	# Diameter matches receiver height so the tube reads as the same body.
	if has_launcher_tube:
		var tube_r: float = effective_receiver_size.y * 0.5
		var tube_len: float = launcher_tube_length
		var receiver_rear_z: float = effective_receiver_size.z * 0.5
		var tube_start_z: float = receiver_rear_z + tube_r * 0.12
		var tube_centre_z: float = tube_start_z + tube_len * 0.5
		_add_cylinder("LauncherTube", tube_r, tube_r, tube_len, Vector3(0, 0.0, tube_centre_z), darker_metal)

	# Iron sights — only when no scope is mounted (otherwise they overlap).
	if not has_scope:
		# Front sight post — thin vertical box near the muzzle
		var front_sight_y: float = barrel_radius + sight_post_height * 0.5
		var front_sight_z: float = receiver_front_z - barrel_length * 0.85
		_add_box("FrontSight", Vector3(0.005, sight_post_height, 0.012), Vector3(0, front_sight_y, front_sight_z), darker_metal)
		# Rear sight — torus on the back of the rail
		var rear_sight_y: float = rail_y + sight_rail_height * 0.5 + rear_sight_radius * 0.4
		var rear_sight_z: float = effective_receiver_size.z * 0.32
		_add_torus("RearSight", rear_sight_radius, rear_sight_radius * 0.25, Vector3(0, rear_sight_y, rear_sight_z), darker_metal)
	else:
		# Scope: main tube + objective / eyepiece bells + glowing front lens.
		var tube_r: float = 0.018
		var bell_r: float = 0.028
		var bell_len: float = 0.04
		var scope_y: float = rail_y + sight_rail_height * 0.5 + 0.025
		var scope_z: float = 0.0

		# Scope rings (mounts)
		var ring_w: float = 0.02
		var ring_h: float = scope_y - (rail_y + sight_rail_height * 0.5)
		var ring_y: float = rail_y + sight_rail_height * 0.5 + ring_h * 0.5
		var ring_offset_z: float = scope_length * 0.3
		for rz in [-ring_offset_z, ring_offset_z]:
			_add_box("ScopeRing", Vector3(tube_r * 2.2, ring_h, ring_w), Vector3(0, ring_y, rz), darker_metal)

		_add_cylinder("ScopeTube", tube_r, tube_r, scope_length, Vector3(0, scope_y, scope_z), darker_metal)
		_add_cylinder("ScopeFrontBell", bell_r, bell_r, bell_len, Vector3(0, scope_y, scope_z - scope_length * 0.5 - bell_len * 0.5), darker_metal)
		_add_cylinder("ScopeBackBell", bell_r, bell_r, bell_len, Vector3(0, scope_y, scope_z + scope_length * 0.5 + bell_len * 0.5), darker_metal)
		# Front lens — emissive disc inside the objective bell.
		var lens_mat := StandardMaterial3D.new()
		lens_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		lens_mat.albedo_color = Color(0.45, 0.75, 1.0)
		lens_mat.emission_enabled = true
		lens_mat.emission = Color(0.35, 0.7, 1.0)
		lens_mat.emission_energy_multiplier = 1.8
		_add_cylinder("ScopeLens", bell_r * 0.85, bell_r * 0.85, 0.005, Vector3(0, scope_y, scope_z - scope_length * 0.5 - bell_len - 0.004), lens_mat)

	# Charge indicator — tiny emissive panel on the side of the receiver
	var ind_mat := StandardMaterial3D.new()
	ind_mat.albedo_color = indicator_color
	ind_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ind_mat.emission_enabled = true
	ind_mat.emission = indicator_color
	ind_mat.emission_energy_multiplier = indicator_energy
	var ind_x: float = receiver_size.x * 0.5 + indicator_size.x * 0.5
	_add_box("Indicator", indicator_size, Vector3(ind_x, 0, 0), ind_mat)

	if indicator_emits_light:
		var light := OmniLight3D.new()
		light.name = "IndicatorLight"
		light.light_color = indicator_color
		light.light_energy = 0.6
		light.omni_range = 0.6
		light.position = Vector3(ind_x + 0.04, 0, 0)
		add_child(light)
		_finalize_owner(light)

	# Heat light — sits at the muzzle, off until heat builds. Skip in editor
	# so the OmniLight gizmo doesn't clutter the gun preview.
	_heat_light = null
	if heat_emits_light and not Engine.is_editor_hint():
		var hl := OmniLight3D.new()
		hl.name = "HeatLight"
		hl.position = Vector3(0, 0, muzzle_centre_z)
		hl.omni_range = 0.55
		hl.light_specular = 0.0
		hl.light_volumetric_fog_energy = 0.0
		hl.visible = false
		add_child(hl)
		_heat_light = hl

	# Re-apply current heat to the freshly-built barrel material so swapping
	# weapons mid-burst doesn't visually reset the temperature.
	_update_heat_visual()


# Vented square shroud — 4 slotted plates around the barrel. Each plate
# has a front and back end cap (full tangential width), two long edge
# rails along its X edges, and N-1 inner ribs creating N slots between
# them. The 4 sides are siblings under per-side Node3D parents that we
# rotate around Z so each plate ends up on its own face of the box.
# Picatinny-style mounting rail -- an array of rectangular teeth on a base slab.
# Standard Picatinny is very specific, but we use a stylized version that
# scales with the receiver.
func _add_picatinny_rail(pos: Vector3, size: Vector3, mat: Material) -> void:
	var rail_parent := Node3D.new()
	rail_parent.name = "SightRail"
	rail_parent.position = pos
	add_child(rail_parent)
	_finalize_owner(rail_parent)

	# Base rail (continuous lower part)
	var base_h: float = size.y * 0.5
	_add_box("Base", Vector3(size.x, base_h, size.z), Vector3(0, -size.y * 0.5 + base_h * 0.5, 0), mat, rail_parent)

	# Mounting teeth
	var tooth_z: float = 0.012  # approx 12mm thick teeth
	var tooth_gap: float = 0.01 # approx 10mm gaps
	var period: float = tooth_z + tooth_gap
	var num_teeth: int = max(1, int(size.z / period))

	# Center the teeth along the length of the rail
	var start_z: float = -((num_teeth - 1) * period) * 0.5

	for i in num_teeth:
		var tz: float = start_z + i * period
		# Teeth are slightly wider than the base for that Picatinny look
		_add_box("Tooth%d" % i, Vector3(size.x * 1.2, base_h, tooth_z), Vector3(0, size.y * 0.5 - base_h * 0.5, tz), mat, rail_parent)

func _add_barrel_shroud(
	centre_z: float,
	length: float,
	half_extent_x: float,
	half_extent_y: float,
	slot_count: int,
	mat: Material,
) -> void:
	if length <= 0.0 or half_extent_x <= 0.0 or half_extent_y <= 0.0 or slot_count <= 0:
		return
	var plate_thickness: float = 0.006    # radial wall thickness
	# Wide rails — they overlap with the adjacent plate's rails at each
	# corner, forming substantial L-shaped corner posts that close off the
	# diagonal "see-through" gaps that made earlier versions look caged.
	var rail_width: float = 0.022
	var rib_z_thickness: float = 0.025    # axial thickness of inner ribs
	var end_cap_thickness: float = 0.024  # axial thickness of front/back caps
	var inner_length: float = maxf(0.001, length - 2.0 * end_cap_thickness)
	var ribs: int = max(0, slot_count - 1)
	var slot_length: float = maxf(0.001,
		(inner_length - float(ribs) * rib_z_thickness) / float(slot_count))
	var z_back: float = centre_z + length * 0.5
	var z_front: float = centre_z - length * 0.5
	for side_idx in 4:
		# Even sides = top/bottom (Y); odd sides = left/right (X). Multi-barrel
		# only widens X — vertical clearance stays single-barrel height.
		var radial_half: float = half_extent_y if side_idx % 2 == 0 else half_extent_x
		var tangential_half: float = half_extent_x if side_idx % 2 == 0 else half_extent_y
		var plate_y: float = radial_half - plate_thickness * 0.5
		var plate_width: float = 2.0 * tangential_half
		var rib_x_width: float = maxf(0.001, plate_width - 2.0 * rail_width)
		var side := Node3D.new()
		side.name = "Shroud%d" % side_idx
		side.rotation = Vector3(0.0, 0.0, float(side_idx) * PI * 0.5)
		add_child(side)
		_finalize_owner(side)
		var cap_size := Vector3(plate_width, plate_thickness, end_cap_thickness)
		_add_box("FrontCap", cap_size,
			Vector3(0.0, plate_y, z_front + end_cap_thickness * 0.5), mat, side)
		_add_box("BackCap", cap_size,
			Vector3(0.0, plate_y, z_back - end_cap_thickness * 0.5), mat, side)
		var rail_x: float = tangential_half - rail_width * 0.5
		var rail_size := Vector3(rail_width, plate_thickness, inner_length)
		_add_box("RailL", rail_size, Vector3(-rail_x, plate_y, centre_z), mat, side)
		_add_box("RailR", rail_size, Vector3(+rail_x, plate_y, centre_z), mat, side)
		var rib_size := Vector3(rib_x_width, plate_thickness, rib_z_thickness)
		for i in ribs:
			var rib_z: float = z_front + end_cap_thickness + slot_length \
				+ float(i) * (slot_length + rib_z_thickness) + rib_z_thickness * 0.5
			_add_box("Rib%d" % i, rib_size, Vector3(0.0, plate_y, rib_z), mat, side)

# ---- Helpers ----

# Shared mesh cache: _rebuild() runs on every card pick (for BOTH gun rigs)
# and every inspector tweak; creating ~40 fresh Box/Cylinder meshes per pass
# re-uploaded GPU buffers each time — measured ~100ms engine-side at
# pick-confirm. Part dims derive from weapon stats, so quantized keys re-hit
# across rebuilds. Materials deliberately stay per-rebuild: heat glow and
# the indicator mutate them per gun instance.
static var _mesh_cache: Dictionary = {}


static func _cached_box_mesh(size: Vector3) -> Mesh:
	var key := ["b",
		snappedf(size.x, 0.0005), snappedf(size.y, 0.0005), snappedf(size.z, 0.0005)]
	var m: Mesh = _mesh_cache.get(key)
	if m == null:
		m = _chamfered_box(size)
		_mesh_cache[key] = m
	return m


## A box with its edges bevelled. Hard 90-degree box edges were most of why
## the guns looked like grey lumps: a small chamfer catches the light along
## every edge, which is what makes machined metal read as metal.
static func _chamfered_box(size: Vector3) -> ArrayMesh:
	var h := size * 0.5
	var b := minf(minf(size.x, minf(size.y, size.z)) * 0.22, 0.008)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var cycle: Array[Vector2] = [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]
	for a in 3:
		var u := (a + 1) % 3
		var v := (a + 2) % 3
		for sa: float in [-1.0, 1.0]:
			# The flat face on this side.
			var face: Array[Vector3] = []
			for c in cycle:
				var s := Vector3.ZERO
				s[a] = sa; s[u] = c.x; s[v] = c.y
				face.append(_chamfer_point(h, b, s, a))
			_chamfer_polygon(st, face)
		for c in cycle:
			# The bevel along the edge parallel to axis a.
			var lo := Vector3.ZERO
			lo[a] = -1.0; lo[u] = c.x; lo[v] = c.y
			var hi := lo
			hi[a] = 1.0
			_chamfer_polygon(st, [_chamfer_point(h, b, lo, u), _chamfer_point(h, b, hi, u),
				_chamfer_point(h, b, hi, v), _chamfer_point(h, b, lo, v)])
	for x: float in [-1.0, 1.0]:
		for y: float in [-1.0, 1.0]:
			for z: float in [-1.0, 1.0]:
				var s := Vector3(x, y, z)
				_chamfer_polygon(st, [_chamfer_point(h, b, s, 0), _chamfer_point(h, b, s, 1), _chamfer_point(h, b, s, 2)])
	return st.commit()


## The corner `s` (signs per axis) of the face that looks along `axis`.
static func _chamfer_point(h: Vector3, b: float, s: Vector3, axis: int) -> Vector3:
	var p := Vector3.ZERO
	for i in 3:
		p[i] = s[i] * (h[i] if i == axis else h[i] - b)
	return p


## A flat convex polygon around the origin, fanned into triangles that face
## outward (Godot's front faces wind clockwise).
static func _chamfer_polygon(st: SurfaceTool, pts: Array) -> void:
	var centre := Vector3.ZERO
	for p: Vector3 in pts:
		centre += p
	centre /= float(pts.size())
	var a: Vector3 = pts[0]
	var n: Vector3 = (pts[1] - a).cross(pts[2] - a)
	var flip := n.dot(centre) > 0.0
	var normal := (-n if flip else n).normalized() * -1.0
	for i in range(1, pts.size() - 1):
		var tri: Array = [a, pts[i], pts[i + 1]]
		if flip:
			tri = [a, pts[i + 1], pts[i]]
		for p: Vector3 in tri:
			st.set_normal(normal)
			st.add_vertex(p)


static func _cached_cylinder_mesh(
	top_r: float, bottom_r: float, height: float, segments: int = 8
) -> CylinderMesh:
	var key := ["c", snappedf(top_r, 0.0005), snappedf(bottom_r, 0.0005),
		snappedf(height, 0.0005), segments]
	var m: CylinderMesh = _mesh_cache.get(key)
	if m == null:
		m = CylinderMesh.new()
		m.top_radius = top_r
		m.bottom_radius = bottom_r
		m.height = height
		m.radial_segments = segments
		_mesh_cache[key] = m
	return m


## Machined metal: real metallic/roughness (the old flat toon shading threw
## both away). Metal albedo is its reflection colour, so near-black steel
## reads as a hole; lift it to gunmetal. A touch of rim keeps the edges.
func _make_material(col: Color, metallic: float, roughness: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	var lift := lerpf(0.06, 0.3, clampf(metallic, 0.0, 1.0))
	m.albedo_color = col.lerp(Color(0.62, 0.64, 0.68), lift)
	m.metallic = clampf(metallic, 0.0, 1.0)
	m.roughness = clampf(roughness + 0.1, 0.0, 1.0)
	m.rim_enabled = true
	m.rim = 0.2
	m.rim_tint = 0.6
	return m


## Matte polymer for grips, stock, handguard and magazine.
func _make_polymer(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.metallic = 0.0
	m.roughness = 0.7
	m.rim_enabled = true
	m.rim = 0.15
	m.rim_tint = 0.5
	return m

func _add_box(part_name: String, size: Vector3, pos: Vector3, mat: Material, parent: Node3D = null) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = part_name
	mi.mesh = _cached_box_mesh(size)
	mi.material_override = mat
	mi.position = pos
	var p: Node3D = parent if parent != null else self
	p.add_child(mi)
	_finalize_owner(mi)
	return mi

func _add_cylinder(part_name: String, top_r: float, bottom_r: float, height: float, pos: Vector3, mat: Material, parent: Node3D = null) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = part_name
	mi.mesh = _cached_cylinder_mesh(top_r, bottom_r, height)
	mi.material_override = mat
	mi.position = pos
	# Cylinder height is along local Y. Rotate 90° around X so it lies along Z.
	mi.rotation = Vector3(PI * 0.5, 0, 0)
	var p: Node3D = parent if parent != null else self
	p.add_child(mi)
	_finalize_owner(mi)
	return mi

func _add_torus(part_name: String, outer_r: float, ring_r: float, pos: Vector3, mat: Material, parent: Node3D = null) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = part_name
	var tm := TorusMesh.new()
	tm.outer_radius = outer_r
	tm.inner_radius = maxf(0.001, outer_r - ring_r)
	tm.rings = 8
	tm.ring_segments = 6
	mi.mesh = tm
	mi.material_override = mat
	mi.position = pos
	# Torus default sits in XZ plane (axis = Y). Rotate 90° around X so the
	# hole faces forward along Z.
	mi.rotation = Vector3(PI * 0.5, 0, 0)
	var p: Node3D = parent if parent != null else self
	p.add_child(mi)
	_finalize_owner(mi)
	return mi

# In-editor preview: ensure rebuilt children show in the scene tree dock and
# get cleaned up next rebuild. At runtime owner doesn't matter.
func _finalize_owner(node: Node) -> void:
	if not Engine.is_editor_hint():
		return
	var tree := get_tree()
	if tree == null:
		return
	var root := tree.edited_scene_root
	if root != null:
		node.owner = root
