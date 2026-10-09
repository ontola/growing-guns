extends CharacterBody3D

const Violence = preload("res://scripts/violence.gd")
const Blast = preload("res://scripts/blast.gd")
const GRENADE_SCENE := preload("res://scenes/grenade.tscn")

# All ragdoll, death, impact, and gore logic lives in scripts/violence.gd.
# The @rpc methods + a few thin wrappers stay here because they need to live
# on this Node, but their bodies just delegate to Violence.

# --- Movement ---
const WALK_SPEED := 14.0
const AIR_ACCEL := 70.0
const GROUND_ACCEL := 100.0
const FRICTION := 8.0
const JUMP_VELOCITY := 9.01
const DOUBLE_JUMP_VELOCITY := 8.5
const WALL_JUMP_V := 10.5
const WALL_JUMP_H := 4.0
const WALL_JUMP_COOLDOWN := 0.14
const DASH_SPEED := 28.0
const DASH_TIME := 0.18
const MAX_DASH_CHARGES := 2
const DASH_RECHARGE_TIME := 3.0
const NINJA_MELEE_DAMAGE_MULT := 0.42
const NINJA_MELEE_RANGE_MULT := 0.62
const GRAVITY := 30.0
const MOUSE_SENS := 0.0022
# Max right-stick turn rate (rad/s) at full deflection. Was 4.2 (~240°/s),
# which Joep found far too twitchy on a couch pad; ~150°/s matches typical
# console shooters. The response curve below keeps small deflections slow so
# fine aim stays possible; MenuHelpers.stick_sens_mult scales it per player.
const CONTROLLER_LOOK_SENS := 2.6
const CONTROLLER_LOOK_CURVE := 1.5
const CONTROLLER_LOOK_DEADZONE := 0.18

# --- First-person gun feel ---
const GUN_BOB_AMP_Y := 0.012        # vertical bob amplitude
const GUN_BOB_AMP_X := 0.007        # horizontal sway amplitude (half-frequency)
const GUN_JUMP_BUMP := 0.06         # downward kick on jump, decays
const GUN_STRAFE_TILT_DEG := 3.5    # max gun roll while strafing

# --- View Feel ---
const TILT_MAX_DEG := 2.5
const TILT_SPEED := 6.0

# --- Combat ---
const MAX_HEALTH := 100
const ROUND_MODIFIERS_SCRIPT := preload("res://scripts/round_modifiers.gd")
const RIFLE_RANGE := 200.0
const RIFLE_RECOIL_PITCH := 0.018         # radians added to camera pitch per shot
const RIFLE_RECOIL_KICK := 0.08           # muzzle pushed back (meters) per shot
const RIFLE_RECOIL_YAW_JITTER := 0.004    # tiny yaw nudge per shot
const RIFLE_SHAKE := 0.015                # camera shake impulse
# Flashlight (blackout rounds): off-hand low-left origin + a soft turn lag.
const FLASHLIGHT_OFFSET := Vector3(-0.32, -0.18, 0.0)  # left + slightly down, head-relative
const FLASHLIGHT_TURN_RATE := 14.0                     # lower = more lag/trailing
const MAX_FIRST_PERSON_CASINGS_PER_TRIGGER := 4
const MAX_SHOT_FX_PER_FRAME := 1
const MAX_THIRD_PERSON_CASINGS_PER_FRAME := 3
const HIGH_RATE_REMOTE_CASING_BPS := 90.0
# Global cap on live third-person shell casings (RigidBody3D ejected by every
# remote shooter / bot). Previously only per-frame + 4s-lifetime limited, so
# RPM-spam piled 100+ active bodies — the dominant rigid-body source under heavy
# fire. FP casings are capped separately in procedural_gun (max_casings).
const MAX_ACTIVE_TP_CASINGS := 28
static var _tp_casing_fifo: Array[RigidBody3D] = []

static func clear_tp_casing_fifo() -> void:
	_tp_casing_fifo.clear()


static func _enroll_tp_casing(rb: RigidBody3D) -> void:
	_tp_casing_fifo.append(rb)
	rb.tree_exiting.connect(func() -> void: _tp_casing_fifo.erase(rb))
	while _tp_casing_fifo.size() > MAX_ACTIVE_TP_CASINGS:
		var oldest: RigidBody3D = _tp_casing_fifo.pop_front()
		if is_instance_valid(oldest):
			oldest.queue_free()
const HIGH_RATE_REMOTE_CASING_INTERVAL_MS := 90
const GRENADE_RELOAD := 3.0
const CLUSTER_GRENADE_RELOAD := 4.0
const AIR_STRIKE_RELOAD := 9.5
const ION_CANNON_RELOAD := 14.0
const AIR_STRIKE_AIM_RANGE := 800.0
const GRENADE_LAUNCH_SPEED := 22.0
const GRENADE_LAUNCH_LIFT := 4.0
const MELEE_RELOAD := 0.5
const MELEE_RANGE := 5.0
const MELEE_BACKSTAB := 9999  # guaranteed kill
const VFX_TRANSIENT_LIGHTS := false  # gameplay-wide override; the impact/blood
									 # paths now spawn lights based on damage instead.
const VFX_MAX_IMPACT_DUST := 12
const VFX_MAX_BLOOD_DROPS := 16
const REMOTE_INTERP_SPEED := 24.0
const REMOTE_SNAP_DISTANCE := 8.0
const MINE_RELOAD := 2.5
const MINE_FORWARD_OFFSET := 0.9
const GHOST_ALPHA := 0.06

@onready var camera: Camera3D = $Camera
@onready var muzzle: Node3D = $Camera/Muzzle
@onready var body_model: Node3D = $BodyModel
@onready var character_visual: CharacterVisual = $BodyModel/CharacterVisual
@onready var blob_rig: Node3D = $BodyModel/BlobRig
@onready var blob_core: MeshInstance3D = $BodyModel/BlobRig/BlobCore
@onready var head_blob: MeshInstance3D = $BodyModel/BlobRig/HeadBlob
@onready var face_plate: MeshInstance3D = $BodyModel/BlobRig/HeadBlob/FacePlate
@onready var eye_left: MeshInstance3D = $BodyModel/BlobRig/HeadBlob/EyeLeft
@onready var eye_right: MeshInstance3D = $BodyModel/BlobRig/HeadBlob/EyeRight
@onready var pupil_left: MeshInstance3D = $BodyModel/BlobRig/HeadBlob/PupilLeft
@onready var pupil_right: MeshInstance3D = $BodyModel/BlobRig/HeadBlob/PupilRight
@onready var hit_eye_left: Node3D = $BodyModel/BlobRig/HeadBlob/HitEyeLeft
@onready var hit_eye_right: Node3D = $BodyModel/BlobRig/HeadBlob/HitEyeRight
@onready var mouth: MeshInstance3D = $BodyModel/BlobRig/HeadBlob/Mouth
@onready var hand_anchor: Node3D = $BodyModel/BlobRig/HandAnchor
@onready var head_hitbox: Area3D = $HeadHitbox

var _third_person_gun: Node3D = null
var _third_person_procedural_gun: Node3D = null
var _third_person_gun_rest_pos: Vector3 = Vector3.ZERO
var _third_person_gun_rest_rot: Vector3 = Vector3.ZERO
var _flashlight: SpotLight3D = null
@onready var torso_hitbox: Area3D = $TorsoHitbox
@onready var legs_hitbox: Area3D = $LegsHitbox
@onready var name_label: Label3D = $NameLabel
@onready var gun_body: MeshInstance3D = $Camera/Muzzle/GunMesh
var gun_barrel: MeshInstance3D = null
var gun_magazine: MeshInstance3D = null
var _procedural_gun: Node3D = null
# Living-gun growth layers (see demon_growth.gd) — siblings of the procedural
# guns, not children: ProceduralGun._rebuild frees all of its own children.
var _demon_growth: DemonGrowth = null
var _third_person_demon_growth: DemonGrowth = null
# Card-growth moment bookkeeping: how many owned cards the gun's visual form
# already reflects. rebuild_weapon_from_cards animates any newer cards.
var _grown_card_count: int = 0
# Round-start growth is armed by rebuild_weapon_from_cards but only STARTED
# by set_launching(true): the arena swap + shader warmup between the two
# produces one giant frame, and starting earlier lets that hitch-delta eat
# the whole animation before the player's first visible frame.
var _pending_card_growth: bool = false
var _gun_inspect: float = 0.0  # 0..1 "look at the growing gun" viewmodel blend
var _spawn_cage: Node3D = null  # round-start cage (spawn_cage.gd), lives in current_scene
var _cage_descent_tween: Tween = null
var _ragdoll_pieces: Array[Node] = []
var _blood_wounds: Array[Node] = []

var jumps_left := 2
var dash_timer := 0.0
var dash_dir := Vector3.ZERO
var dash_charges: int = MAX_DASH_CHARGES
var dash_recharge_timer := 0.0
var _dash_iframe_timer := 0.0
var _dash_iframe_visual_timer := 0.0
var _dash_iframe_visual_active := false
var rifle_cooldown := 0.0
var grenade_cooldown := 0.0
var melee_cooldown := 0.0
# Last duration the special cooldown was set to. HUD progress = grenade_cooldown / special_cooldown_max.
var special_cooldown_max: float = 0.0
var wall_jump_cooldown := 0.0
var weapon: Weapon = Weapon.new()
var _owned_cards: Array[String] = []
var mag: int = Weapon.BASE_MAG_SIZE
var reloading: bool = false
var frozen: bool = false
# Multiplier on top of the base MOUSE_SENS — game.gd writes this from the
# settings panel slider so each peer can tune their own look speed.
var mouse_sens_mult: float = 1.0
# Toggle for the strafe-driven camera + gun roll. game.gd writes this from
# the settings panel; off zeroes out both the view roll (TILT_MAX_DEG) and
# the gun roll (GUN_STRAFE_TILT_DEG) without touching anything else.
var tilt_enabled: bool = true
# Round-start "rocket spawn": physics drives the descent but input is gated
# until the server flips this back off. Distinct from `frozen` because we DO
# want gravity + move_and_slide to run while it's on.
var launching: bool = false
var _phoenix_ascending: bool = false
var _coop_phoenix_held: bool = false
var _phoenix_start_pos: Vector3 = Vector3.ZERO
var _phoenix_start_ms: int = 0
var _phoenix_finish_requested: bool = false
var _phoenix_column_root: Node3D = null
var _phoenix_column: MeshInstance3D = null
var _phoenix_light: OmniLight3D = null
const PHOENIX_ASCENT_HEIGHT := 10.0
const PHOENIX_ASCENT_DURATION := 2.0
const PHOENIX_ALPHA_START := 0.5
const PHOENIX_ALPHA_END := 0.0
const PHOENIX_LIGHT_ENERGY := 22.0
const PHOENIX_COLUMN_HEIGHT := 360.0
const PHOENIX_COLUMN_RADIUS := 0.5
const HELL_CAPSULE_HEIGHT := 1.8
const HELL_EMERGE_BURIAL_EXTRA := 0.5
const HELL_EMERGE_DEPTH := HELL_CAPSULE_HEIGHT + HELL_EMERGE_BURIAL_EXTRA
const HELL_EMERGE_DURATION := 2.5
const HELL_EMERGE_GLOW := 0.45
const HELL_EMERGE_SHAKE := 0.4
const COOP_DOWN_CROSS_BOB_HEIGHT := 0.16
var _hell_emerging: bool = false
var _hell_emerge_finished: bool = false
var _hell_emerge_start: Vector3 = Vector3.ZERO
var _hell_emerge_target: Vector3 = Vector3.ZERO
var _hell_emerge_start_ms: int = 0
var _hell_emerge_light: OmniLight3D = null
var _hell_emerge_depth: float = HELL_EMERGE_DEPTH
var _hell_emerge_rise_seconds: float = HELL_EMERGE_DURATION
var _hell_emerge_glow_seconds: float = HELL_EMERGE_GLOW
var _hell_emerge_pentagram_fade_seconds: float = HELL_EMERGE_DURATION * 0.5
var _hell_emerge_shake_seed: float = 0.0
var _hell_emerge_telegraph_dismissed: bool = false
var _hell_emerge_elapsed: float = 0.0
var ghost_mode: bool = false
var coop_downed: bool = false
var _coop_down_pos: Vector3 = Vector3.ZERO
var _coop_down_marker_root: Node3D = null
var _coop_down_marker_cross: Node3D = null
var _coop_down_marker_light: OmniLight3D = null
var _coop_down_marker_phase: float = 0.0
var is_zooming: bool = false
var _poison_damage_left: float = 0.0
var _poison_dps: float = 0.0
var _poison_from_id: int = 0
var _poison_tick_accum: float = 0.0
var _slow_timer: float = 0.0
var _slow_mult: float = 1.0
var _chill_vfx_timer: float = 0.0
var _chill_vfx_strength: float = 0.0
var _chill_visual_active: bool = false
var _phoenix_charges_left: int = 0
var _air_strike_charges: int = 0

# Last broadcast state — avoids flooding the wire when idle.
var _last_sync_pos: Vector3 = Vector3.INF
var _last_sync_yaw: float = INF
var _last_sync_pitch: float = INF
var _remote_target_pos: Vector3 = Vector3.INF
var _remote_target_yaw: float = 0.0
var _remote_target_pitch: float = 0.0
var _remote_has_target := false

# Camera / gun feel — updated by fire, decayed per frame.
var look_pitch := 0.0
var recoil_pitch := 0.0
var tilt_z := 0.0
var muzzle_kick_z := 0.0
var shake_amt := 0.0
var melee_offset := Vector3.ZERO
var _muzzle_rest_pos: Vector3
var _walk_bob_phase: float = 0.0
var _gun_jump_bump: float = 0.0
var _gun_tilt_z: float = 0.0
# Long barrels sit further back against the shoulder; updated when the
# weapon changes via _update_gun_visuals.
var _gun_pull_back: Vector3 = Vector3.ZERO
# Movement multiplies the gun's BASE spread (never a flat floor), so only the
# gun's own inaccuracy is amplified while moving — a very accurate gun stays
# accurate on the move; only sloppy guns walk wide. Kept gentle on purpose;
# the real spray comes from the recoil bloom below.
const MOVEMENT_SPREAD_MULT := 1.0        # full walk speed → ×(1 + 1) = ×2 base spread
const MAX_EFFECTIVE_SPREAD := 0.14       # ~8°; upper cap for cards + movement + recoil bloom

# Shot-to-shot "shaking hand" bloom: each shot adds weapon.recoil_per_shot, and
# it eases back to zero (RECOIL_DECAY_RATE). Holding the trigger / full-auto
# walks the spread wide and it recovers when you let off. Spray builds crank
# recoil_per_shot; precision builds shrink it.
const RECOIL_DECAY_RATE := 4.0           # higher = recovers accuracy faster
var _recoil_spread: float = 0.0

# Total effective spread used at fire time AND shown by the crosshair so the
# UI always matches what bullets will actually do.
func get_effective_spread() -> float:
	var horiz_speed: float = Vector2(velocity.x, velocity.z).length()
	var move_factor: float = clampf(horiz_speed / WALK_SPEED, 0.0, 1.0)
	var raw_spread := weapon.get_spread() * (1.0 + move_factor * MOVEMENT_SPREAD_MULT) + _recoil_spread
	return minf(raw_spread, MAX_EFFECTIVE_SPREAD)
var _head_hitbox_rest_y: float = 0.86
var _torso_hitbox_rest_y: float = 0.12
var _legs_hitbox_rest_y: float = -0.55
var reload_offset: Vector3 = Vector3.ZERO
var _reload_tween: Tween = null
var _mag_reload_tween: Tween = null
var _reload_audio: Node = null
var _camera_rest_pos: Vector3
var _landing_bump_y: float = 0.0
var _was_on_floor: bool = true
var _step_distance: float = 0.0
const STEP_STRIDE := 2.2  # meters of ground travel between footstep SFX
var _view_punch_rot: Vector3 = Vector3.ZERO
var _view_punch_pos: Vector3 = Vector3.ZERO
var _melee_tween: Tween = null
# PhysicsBody3D, not RigidBody3D: blob corpses hand us a RigidBody3D chunk,
# knight corpses a PhysicalBone3D (the hips). Only global_transform is read.
var _ragdoll_head: PhysicsBody3D = null
var _suppress_next_death_sound := false
var _suppress_next_death_ragdoll := false
var _pending_lava_death := false
var _pending_lava_death_fall := false
var _lava_death_active := false
var _rocket_descent_player: Node = null
var _last_lava_contact_sizzle_ms: int = -10000
var _shot_fx_frame: int = -1
var _shot_fx_count: int = 0
var _third_person_casing_frame: int = -1
var _third_person_casing_count: int = 0
var _last_high_rate_remote_casing_ms: int = -10000
var _body_materials: Dictionary = {}
var _blob_rig_rest_pos: Vector3 = Vector3.ZERO
var _blob_core_rest_scale: Vector3 = Vector3.ONE
var _head_blob_rest_pos: Vector3 = Vector3.ZERO
var _head_blob_rest_scale: Vector3 = Vector3.ONE
var _hand_anchor_rest_pos: Vector3 = Vector3.ZERO
var _blob_phase: float = 0.0
var _visual_prev_pos: Vector3 = Vector3.INF
var _knight_was_grounded: bool = true
var _hit_face_timer: float = 0.0
const HIT_FACE_DURATION := 0.22

@export var player_id: int = 1
@export var player_name: String = "Player"
@export var is_bot: bool = false
@export var appearance_seed: int = 0
var enemy_archetype: String = ""
@export var local_input_device: int = -1
@export var split_screen_local: bool = false

# --- Bot AI ---
const BOT_MOVE_SPEED := 8.0
const BOT_FOLLOW_DIST := 7.0
const BOT_ROT_SPEED := 6.0
const BOT_SPREAD := 0.09                 # ~5.2° — miss-prone but threatening
const BOT_MISS_CHANCE := 0.45            # fraction of shots that get huge extra spread
const BOT_JUMP_CHANCE := 0.008           # per physics tick, when on floor
const BOT_DASH_CHANCE := 0.018           # per physics tick, when charge available
const BOT_EDGE_PROBE_DIST := 1.8
const BOT_LAVA_EDGE_PROBE_DIST := 3.0
const BOT_LAVA_MISTAKE_CHANCE := 0.07
const BOT_LAVA_JUMP_CHANCE := 0.0015
const BOT_AIR_STRIKE_FLEE_RADIUS := 40.0
const BOT_AIR_STRIKE_PANIC_RADIUS := 22.0
const BOT_GAP_JUMP_MIN_LANDING := 4.5
const BOT_GAP_JUMP_MAX_LANDING := 12.0
const BOT_REACTION_MIN := 0.2            # seconds of LOS before the first shot
const BOT_REACTION_MAX := 0.55
const BOT_AIM_TURN_SPEED := 3.2          # rad/s crosshair slew — close strafers outrun it
const BOT_PICKUP_RANGE := 22.0
const BOT_PICKUP_NOTICE_CHANCE := 0.55   # per ~2s scan — bots miss pickups sometimes
const BOT_CLIMB_MIN_HEIGHT := 1.0        # ledge heights worth a deliberate climb
const BOT_CLIMB_MAX_HEIGHT := 2.6        # jump (~1.35m) + double jump (~1.2m)
const EXPLOSION_EDGE_FALLOFF := 0.2

var _bot_target: Node3D = null
var _bot_shoot_cooldown: float = 0.0
var _bot_strafe_timer: float = 0.0
var _bot_strafe_side: float = 0.0        # -1 left, 0 none, +1 right
var _bot_approach: float = 1.0           # -1 retreat, 0 hold, +1 chase
var _bot_jump_cooldown: float = 0.0
var _bot_stuck_timer: float = 0.0
var _bot_dash_cooldown: float = 0.0
# --- Bot humanization ---
# Aim error is a slow random walk (correlated across shots, like a wobbling
# hand) plus a reaction delay after (re)acquiring line of sight — white noise
# per shot reads as a machine.
var _bot_aim_wander := Vector3.ZERO
var _bot_aim_wander_target := Vector3.ZERO
var _bot_aim_retarget: float = 0.0
var _bot_aim_point := Vector3.ZERO       # where the "mouse hand" currently points
var _bot_los_time: float = 0.0
var _bot_reaction: float = 0.35
var _bot_special_think: float = 0.0      # RMB decision cadence
var _bot_pickup_target: Node3D = null
var _bot_pickup_scan: float = 0.0
var _bot_pickup_give_up: float = 0.0
var _bot_climb_probe: float = 0.0
var _bot_climb_until: float = 0.0        # >0: mid-climb, may spend the double jump
var _bot_climb_target_y: float = 0.0
# Lava "mistake" is a timed lapse, not per-call dice — fresh dice on every
# safety probe meant dozens of independent chances per second to stroll in.
var _bot_lava_risk_timer: float = 0.0
var _bot_lava_risk_roll: float = 0.0
var _prev_local_actions: Dictionary = {}

var health: int = MAX_HEALTH
var god_mode: bool = false

func get_max_health() -> int:
	var base := MAX_HEALTH + weapon.max_hp_bonus
	if is_bot:
		return base
	var game := get_tree().current_scene
	if game and game.has_method("is_coop_mode") and game.is_coop_mode() \
			and game.has_method("_is_human_player_id") and game._is_human_player_id(player_id) \
			and game.has_method("coop_human_max_health"):
		return game.coop_human_max_health(weapon)
	return base

signal died(killer_id: int)
signal cooldowns_changed  # emitted on local player for HUD

func _enter_tree() -> void:
	# Bots are server-owned — their player_id isn't a real peer.
	set_multiplayer_authority(1 if (is_bot or split_screen_local) else player_id)

@rpc("authority", "call_local", "reliable")
func set_display_name(new_name: String) -> void:
	# Mid-match rename: keep the player_name field + floating name tag in sync
	# so other peers see the new callsign without having to leave + rejoin.
	player_name = new_name
	if name_label:
		name_label.text = new_name


func _ready() -> void:
	name_label.text = player_name
	_muzzle_rest_pos = muzzle.position
	_camera_rest_pos = camera.position
	_build_flashlight()
	# Capture authored hitbox positions so body-scaling can shift them cleanly.
	if head_hitbox:
		_head_hitbox_rest_y = head_hitbox.position.y
	if torso_hitbox:
		_torso_hitbox_rest_y = torso_hitbox.position.y
	if legs_hitbox:
		_legs_hitbox_rest_y = legs_hitbox.position.y
	_setup_gun_visuals()
	_apply_identity_cosmetics()
	_capture_body_materials()  # after gun setup so we capture the original gun material too
	_update_gun_visuals()
	_update_body_scale()
	_refresh_authority_view()
	if blob_rig:
		_blob_rig_rest_pos = blob_rig.position
	if blob_core:
		_blob_core_rest_scale = blob_core.scale
	if head_blob:
		_head_blob_rest_pos = head_blob.position
		_head_blob_rest_scale = head_blob.scale
		# Bots get a cube head — visually distinguishes them from human players
		# at a glance. Sized to match the sphere's footprint (0.42 radius).
		if is_bot:
			var box := BoxMesh.new()
			box.size = Vector3(0.78, 0.78, 0.78)
			head_blob.mesh = box
	if hand_anchor:
		_hand_anchor_rest_pos = hand_anchor.position
	_visual_prev_pos = global_position
	_set_hit_face_state(false)
	_setup_third_person_gun()
	_sync_weapon_visibility()
	add_to_group("players")
	# Pre-bake gib chunk meshes off-thread so the first kill doesn't hitch.
	Violence.gib_warm_tree(body_model, Violence.GIB_CHUNK_COUNT)

# Attach the third-person gun to the hand anchor (knight or blob) so other
# players see the same procedural rifle + mount tuning as character_lab.
func _setup_third_person_gun() -> void:
	if _third_person_gun != null:
		return
	if character_visual != null and not character_visual.is_active():
		call_deferred("_setup_third_person_gun")
		return

	var gun_root: Node3D = null
	if character_visual and character_visual.is_active():
		_third_person_procedural_gun = preload("res://scripts/procedural_gun.gd").new()
		_third_person_procedural_gun.name = "ThirdPersonProceduralGun"
		gun_root = character_visual.mount_third_person_weapon(_third_person_procedural_gun)
		if gun_root == null:
			_third_person_procedural_gun.queue_free()
			_third_person_procedural_gun = null
		else:
			# Growth shares the gun's mount offset so the flesh hugs the rifle.
			_third_person_demon_growth = DemonGrowth.new()
			_third_person_demon_growth.name = "DemonGrowth"
			_third_person_demon_growth.gun_path = NodePath("../ThirdPersonProceduralGun")
			_third_person_demon_growth.position = _third_person_procedural_gun.position
			_third_person_demon_growth.rotation = _third_person_procedural_gun.rotation
			gun_root.add_child(_third_person_demon_growth)
	elif hand_anchor and (character_visual == null or not character_visual.enabled):
		var gun := MeshInstance3D.new()
		var body_mesh := BoxMesh.new()
		body_mesh.size = Vector3(0.14, 0.14, 0.44)
		gun.mesh = body_mesh
		var mat := _make_mat(Color(0.18, 0.18, 0.22), 1.0, 0.0)
		gun.material_override = mat
		gun_root = Node3D.new()
		gun_root.name = "ThirdPersonGun"
		gun_root.rotation_degrees = Vector3(10.0, 0.0, 0.0)
		hand_anchor.add_child(gun_root)
		gun.position = Vector3(0.0, -0.03, -0.18)
		gun_root.add_child(gun)
	else:
		return

	_third_person_gun = gun_root
	_third_person_gun_rest_pos = gun_root.position
	_third_person_gun_rest_rot = gun_root.rotation
	_update_third_person_gun_visuals()
	_sync_weapon_visibility()


func _apply_archetype_skin(archetype: String) -> void:
	if character_visual == null:
		return
	var v: int = COOP_ARCHETYPE_VARIANTS.get(archetype, 2)
	if character_visual.set_variant(v):
		_remount_third_person_gun()


# The weapon anchor is a BoneAttachment3D inside the model — a variant swap
# frees it along with the old skeleton, so rebuild the whole mount.
func _remount_third_person_gun() -> void:
	if _third_person_gun and is_instance_valid(_third_person_gun):
		_third_person_gun.queue_free()
	_third_person_gun = null
	_third_person_procedural_gun = null
	_third_person_demon_growth = null
	_setup_third_person_gun()


func _third_person_shot_anchor() -> Node3D:
	if _third_person_procedural_gun:
		return _third_person_procedural_gun
	return _third_person_gun


func _update_third_person_gun_visuals() -> void:
	if _third_person_procedural_gun and _third_person_procedural_gun.has_method("apply_weapon_stats"):
		_third_person_procedural_gun.apply_weapon_stats(weapon)


# Per-player flashlight. Childed to the body (inherits yaw) at head height; its
# pitch is driven from look_pitch each frame so it points where the player aims
# for local AND remote players (both yaw + look_pitch are synced). Lives on the
# player node so every peer sees the cone sweeping. Off until the blackout round
# modifier turns it on via set_flashlight_active().
func _build_flashlight() -> void:
	_flashlight = SpotLight3D.new()
	_flashlight.name = "Flashlight"
	# Narrow, focused beam (a wide cone spilled light onto distant buildings).
	_flashlight.spot_range = 40.0
	_flashlight.spot_angle = 20.0
	_flashlight.spot_attenuation = 1.0
	_flashlight.light_energy = 14.0
	_flashlight.light_color = Color(1.0, 0.97, 0.88)
	_flashlight.light_volumetric_fog_energy = 0.0
	# Cast shadows for the dramatic flashlight-in-the-dark look. Only ~N players,
	# only during blackout rounds, so the per-light shadow cost is acceptable.
	_flashlight.shadow_enabled = true
	_flashlight.shadow_bias = 0.04
	_flashlight.shadow_normal_bias = 1.5
	# We drive its world transform ourselves (top_level) so the beam can lag a
	# touch behind the player's turn — a handheld off-hand feel — and so the
	# off-left origin holds regardless of body scale.
	_flashlight.top_level = true
	_flashlight.visible = false
	_flashlight.add_to_group("flashlight_flares")
	add_child(_flashlight)


func set_flashlight_active(on: bool) -> void:
	if _flashlight:
		_flashlight.visible = on
		if on:
			# Snap to the current aim so it doesn't visibly swing in on activation.
			var target := _flashlight_target_xform()
			_flashlight.global_position = target.origin
			_flashlight.global_basis = target.basis
			_update_flashlight_flare_meta()


func _update_flashlight_flare_meta() -> void:
	if _flashlight == null or not _flashlight.visible:
		return
	_flashlight.set_meta("flare_world_pos", _flashlight.global_position)
	_flashlight.set_meta("flare_intensity", 1.0)


# Where the flashlight wants to be this frame: head + off-left origin, aimed
# along the player's yaw + look pitch. The beam slerps toward this for the lag.
func _flashlight_target_xform() -> Transform3D:
	var origin := to_global(_camera_rest_pos + FLASHLIGHT_OFFSET)
	return Transform3D(_flashlight_aim_basis(), origin)


func _flashlight_aim_basis() -> Basis:
	# Humans: match the live camera aim exactly (same cone the owner sees).
	if is_multiplayer_authority() and not is_bot:
		return camera.global_transform.basis
	var pitch := _aim_pitch()
	return Basis.from_euler(Vector3(pitch, rotation.y, 0.0))


# Vertical aim: live look_pitch for humans, blob rig pitch for bots, synced
# pitch for remote players viewed on another peer.
func _aim_pitch() -> float:
	if is_bot:
		if character_visual != null and character_visual.is_active():
			return look_pitch
		return blob_rig.rotation.x
	if is_multiplayer_authority():
		return look_pitch
	return _remote_target_pitch

func _coop_enemy_archetype_color(archetype: String) -> Color:
	match archetype:
		"sniper":
			return Color(0.62, 0.32, 0.92)
		"grenadier":
			return Color(0.92, 0.52, 0.18)
		"flat_fragger":
			return Color(0.92, 0.38, 0.58)
		"demolition":
			return Color(0.88, 0.28, 0.22)
		_:
			return Color(0.88, 0.76, 0.22)


func _coop_identity_color(seed: int) -> Color:
	if is_bot:
		if not enemy_archetype.is_empty():
			return _coop_enemy_archetype_color(enemy_archetype)
		return _coop_enemy_archetype_color("grunt")
	var hue := (210.0 + float((seed >> 5) % 21)) / 360.0
	var sat := 0.58 + float((seed >> 9) % 17) / 100.0
	var val := 0.68 + float((seed >> 13) % 20) / 100.0
	return Color.from_hsv(hue, sat, val, 1.0)


func _identity_skin_color() -> Color:
	var seed := _identity_seed()
	var game := get_tree().current_scene
	if game and game.has_method("is_coop_mode") and game.is_coop_mode():
		return _coop_identity_color(seed)
	var hue := float(seed % 360) / 360.0
	var sat := 0.44 + float((seed >> 3) % 24) / 100.0
	var val := 0.72 + float((seed >> 7) % 18) / 100.0
	return Color.from_hsv(hue, sat, val, 1.0)


func _apply_identity_skin_materials() -> StandardMaterial3D:
	if head_blob == null:
		return null
	var skin := _identity_skin_color()
	var face := skin.lerp(Color(1.0, 0.96, 0.88), 0.64)
	var skin_mat := _make_mat(skin, 0.95, 0.0)
	var face_mat := _make_mat(face, 0.86, 0.0)
	if blob_core:
		blob_core.material_override = skin_mat
		_body_materials[blob_core] = skin_mat
	if head_blob:
		head_blob.material_override = skin_mat
		_body_materials[head_blob] = skin_mat
	if face_plate:
		face_plate.material_override = face_mat
		_body_materials[face_plate] = face_mat
	return face_mat


func restore_body_materials() -> void:
	var lava_mat: Material = Violence.get_lava_body_material()
	for mesh in _body_meshes():
		if _body_materials.has(mesh):
			mesh.material_override = _body_materials[mesh]
		elif mesh.material_override == lava_mat:
			mesh.material_override = null
	if gun_body and _body_materials.has(gun_body):
		gun_body.material_override = _body_materials[gun_body]
	if gun_barrel and _body_materials.has(gun_barrel):
		gun_barrel.material_override = _body_materials[gun_barrel]
	if gun_magazine and _body_materials.has(gun_magazine):
		gun_magazine.material_override = _body_materials[gun_magazine]
	_apply_identity_skin_materials()
	_apply_ghost_visuals()


func _apply_identity_cosmetics() -> void:
	if head_blob == null:
		return
	var face_mat := _apply_identity_skin_materials()
	var seed := _identity_seed()

	var eye_kind := int((seed >> 11) % 3)
	var has_glasses := ((seed >> 15) & 1) == 1
	var mouth_kind := int((seed >> 16) % 3)
	_apply_eye_variant(eye_kind, face_mat)
	if has_glasses:
		_add_glasses()
	_apply_mouth_variant(mouth_kind)

func _identity_seed() -> int:
	if appearance_seed != 0:
		return appearance_seed & 0x7fffffff
	var s := "%d:%s" % [player_id, player_name]
	var h := 2166136261
	for i in s.length():
		h = int((h ^ s.unicode_at(i)) * 16777619) & 0x7fffffff
	return h

func _make_mat(color: Color, roughness: float = 0.8, metallic: float = 0.0) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color.lightened(0.06)
	mat.roughness = 1.0
	mat.metallic = 0.0
	mat.diffuse_mode = BaseMaterial3D.DIFFUSE_TOON
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return mat

func _apply_eye_variant(kind: int, eyelid_mat: StandardMaterial3D) -> void:
	if eye_left == null or eye_right == null or pupil_left == null or pupil_right == null:
		return
	match kind:
		1:
			eye_left.scale.y *= 0.78
			eye_right.scale.y *= 0.78
			pupil_left.scale.y *= 0.72
			pupil_right.scale.y *= 0.72
		2:
			eye_left.scale.y *= 0.52
			eye_right.scale.y *= 0.52
			pupil_left.scale.y *= 0.45
			pupil_right.scale.y *= 0.45
			_add_eyelid(-0.14, eyelid_mat)
			_add_eyelid(0.14, eyelid_mat)

func _add_eyelid(x: float, mat: StandardMaterial3D) -> void:
	var lid := MeshInstance3D.new()
	lid.name = "BoredEyelid"
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.17, 0.06, 0.025)
	lid.mesh = mesh
	lid.material_override = mat
	lid.position = Vector3(x, 0.065, -0.456)
	head_blob.add_child(lid)

func _add_glasses() -> void:
	if head_blob == null:
		return
	var mat := _make_mat(Color(0.035, 0.03, 0.025), 0.35, 0.15)
	var root := Node3D.new()
	root.name = "Glasses"
	head_blob.add_child(root)
	for x in [-0.14, 0.14]:
		_add_face_bar(root, mat, Vector3(x, 0.088, -0.482), Vector3(0.2, 0.018, 0.018))
		_add_face_bar(root, mat, Vector3(x, -0.018, -0.482), Vector3(0.2, 0.018, 0.018))
		_add_face_bar(root, mat, Vector3(x - 0.09, 0.035, -0.482), Vector3(0.018, 0.12, 0.018))
		_add_face_bar(root, mat, Vector3(x + 0.09, 0.035, -0.482), Vector3(0.018, 0.12, 0.018))
	_add_face_bar(root, mat, Vector3(0.0, 0.04, -0.485), Vector3(0.08, 0.018, 0.018))

func _add_face_bar(parent: Node3D, mat: StandardMaterial3D, pos: Vector3, size: Vector3) -> MeshInstance3D:
	var bar := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	bar.mesh = mesh
	bar.material_override = mat
	bar.position = pos
	parent.add_child(bar)
	return bar

func _apply_mouth_variant(kind: int) -> void:
	if mouth == null:
		return
	mouth.visible = kind != 2
	match kind:
		0:
			_add_mouth_corner(-0.16, true)
			_add_mouth_corner(0.16, true)
		1:
			mouth.position.y -= 0.015
			_add_mouth_corner(-0.16, false)
			_add_mouth_corner(0.16, false)
		2:
			_add_o_mouth()

func _add_mouth_corner(x: float, smile: bool) -> void:
	var corner := MeshInstance3D.new()
	corner.name = "MouthCorner"
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.025, 0.085, 0.025)
	corner.mesh = mesh
	corner.material_override = mouth.material_override
	corner.position = Vector3(x, -0.135 if smile else -0.17, -0.425)
	corner.rotation.z = deg_to_rad(-34.0 if (x < 0.0) == smile else 34.0)
	corner.scale = Vector3(1.0, 0.75, 1.0)
	head_blob.add_child(corner)

func _add_o_mouth() -> void:
	var o := MeshInstance3D.new()
	o.name = "OMouth"
	var mesh := TorusMesh.new()
	mesh.inner_radius = 0.018
	mesh.outer_radius = 0.055
	mesh.rings = 6
	mesh.ring_segments = 6
	o.mesh = mesh
	o.material_override = mouth.material_override
	o.position = Vector3(0.0, -0.145, -0.43)
	o.rotation.x = PI * 0.5
	o.scale = Vector3(0.85, 1.15, 0.85)
	head_blob.add_child(o)

func _process(delta: float) -> void:
	if _ragdoll_head and is_instance_valid(_ragdoll_head):
		camera.global_transform = _ragdoll_head.global_transform
		return

	if coop_downed and is_multiplayer_authority() and not is_bot:
		_apply_controller_look(delta)
		_apply_camera_aim_rotation()

	_tick_coop_down_marker(delta)

	if _phoenix_ascending:
		_update_phoenix_ascent()

	if not is_multiplayer_authority():
		if not _phoenix_ascending and not _coop_phoenix_held and not _hell_emerging:
			_interpolate_remote_state(delta)
	_update_blob_motion(delta)
	_update_third_person_aim_pitch(delta)
	_update_flashlight_aim(delta)
	if _hit_face_timer > 0.0:
		_hit_face_timer = maxf(0.0, _hit_face_timer - delta)
		if _hit_face_timer <= 0.0:
			_set_hit_face_state(false)
	if _dash_iframe_visual_timer > 0.0:
		_dash_iframe_visual_timer = maxf(0.0, _dash_iframe_visual_timer - delta)
		_apply_dash_iframe_visual()
	elif _dash_iframe_visual_active:
		_clear_dash_iframe_visual()
	if is_bot:
		return
	# Re-assert camera state every frame until authority is established.
	# Guards against a connection-state race where is_multiplayer_authority()
	# is false during _ready (peer id == 0 before connected_to_server fires).
	if is_multiplayer_authority() and not split_screen_local and not camera.current \
			and not coop_downed and not _phoenix_ascending:
		_refresh_authority_view()

	if is_multiplayer_authority():
		# Sniper zoom snaps the FOV instantly so RMB feels like an ADS toggle,
		# not a lens animation.
		camera.fov = 30.0 if is_zooming else 75.0
		camera.rotation.z = lerp_angle(camera.rotation.z, deg_to_rad(tilt_z), delta * TILT_SPEED)


func _update_flashlight_aim(delta: float) -> void:
	if _flashlight == null or not _flashlight.visible:
		return
	var target := _flashlight_target_xform()
	_flashlight.global_position = target.origin
	_flashlight.global_basis = _flashlight.global_basis.slerp(
		target.basis, clampf(delta * FLASHLIGHT_TURN_RATE, 0.0, 1.0))
	_update_flashlight_flare_meta()


func _interpolate_remote_state(delta: float) -> void:
	if not _remote_has_target:
		return
	var alpha := clampf(delta * REMOTE_INTERP_SPEED, 0.0, 1.0)
	global_position = global_position.lerp(_remote_target_pos, alpha)
	rotation.y = lerp_angle(rotation.y, _remote_target_yaw, alpha)
	if global_position.distance_squared_to(_remote_target_pos) < 0.0004:
		global_position = _remote_target_pos
	if absf(angle_difference(rotation.y, _remote_target_yaw)) < 0.001:
		rotation.y = _remote_target_yaw
	# Interpolate pitch for third-person blob body tilt only (knight uses gun mount).
	var use_knight := character_visual != null and character_visual.is_active()
	if not use_knight and blob_rig:
		blob_rig.rotation.x = lerp_angle(blob_rig.rotation.x, _remote_target_pitch, clampf(delta * 12.0, 0.0, 1.0))

func _refresh_authority_view() -> void:
	if is_bot:
		# Bot is always third-person: full body visible, no camera takeover.
		camera.clear_current()
		body_model.visible = true
		name_label.visible = health > 0
		_sync_weapon_visibility()
		return
	if is_multiplayer_authority():
		if split_screen_local:
			camera.clear_current()
		else:
			camera.make_current()
		body_model.visible = split_screen_local
		name_label.visible = false
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		Input.use_accumulated_input = false
	else:
		camera.clear_current()
		body_model.visible = true
		name_label.visible = true
	_apply_ghost_visuals()

func _capture_body_materials() -> void:
	_body_materials.clear()
	for mesh in _body_meshes():
		_body_materials[mesh] = mesh.material_override
	# Gun meshes are added at runtime by _setup_gun_visuals() — capture their
	# rest material too so ghost mode can be reverted after respawn.
	if gun_body:
		_body_materials[gun_body] = gun_body.material_override
	if gun_barrel:
		_body_materials[gun_barrel] = gun_barrel.material_override
	if gun_magazine:
		_body_materials[gun_magazine] = gun_magazine.material_override

func _body_meshes() -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if body_model == null:
		return out
	Violence.collect_meshes(body_model, out)
	return out

func _play_knight_jump() -> void:
	if character_visual != null and character_visual.is_active():
		character_visual.play_jump()

func _update_blob_motion(delta: float) -> void:
	if body_model == null or blob_rig == null:
		return
	var use_knight := character_visual != null and character_visual.is_active()
	if use_knight and blob_rig:
		blob_rig.visible = false
	if not use_knight and blob_core == null:
		return
	if _hell_emerging:
		return

	var prev_pos := _visual_prev_pos
	if prev_pos == Vector3.INF:
		prev_pos = global_position
	var world_delta := global_position - prev_pos
	_visual_prev_pos = global_position

	var planar_velocity := Vector3.ZERO
	if is_multiplayer_authority() or is_bot:
		planar_velocity = Vector3(velocity.x, 0.0, velocity.z)
	else:
		planar_velocity = Vector3(world_delta.x, 0.0, world_delta.z) / maxf(delta, 0.001)

	var speed := planar_velocity.length()
	var speed_ratio := clampf(speed / maxf(0.1, WALK_SPEED * weapon.move_speed_mult), 0.0, 1.8)
	var vertical_speed := velocity.y if (is_multiplayer_authority() or is_bot) else world_delta.y / maxf(delta, 0.001)
	var airborne := (not is_on_floor()) if (is_multiplayer_authority() or is_bot) else absf(vertical_speed) > 1.5
	var dash_boost := 1.0 if dash_timer > 0.0 else 0.0

	if use_knight:
		var grounded := not airborne
		if grounded:
			character_visual.notify_landed()
		elif not _knight_was_grounded and vertical_speed > 1.5:
			if not is_multiplayer_authority() and not is_bot:
				character_visual.play_jump()
		_knight_was_grounded = grounded
		if is_bot and _bot_target != null and is_instance_valid(_bot_target):
			var from_y := global_position.y + 0.7
			var to_y := _bot_target.global_position.y + 0.4
			var aim_h := global_position.distance_to(_bot_target.global_position)
			look_pitch = -atan2(to_y - from_y, aim_h)
		character_visual.rotation = Vector3.ZERO
		character_visual.update_locomotion(speed, WALK_SPEED * weapon.move_speed_mult)
		return

	if blob_rig:
		blob_rig.visible = true

	var body_tilt: Node3D = blob_rig
	_blob_phase = wrapf(_blob_phase + delta * lerpf(1.8, 8.0, minf(speed_ratio, 1.0)), 0.0, TAU)
	var bob := sin(_blob_phase) * (0.02 + 0.04 * speed_ratio) + 0.04
	if airborne:
		bob += 0.05
	if dash_boost > 0.0:
		bob += 0.03
	var target_pos := _blob_rig_rest_pos + Vector3(0.0, bob, 0.0)
	blob_rig.position = blob_rig.position.lerp(target_pos, clampf(delta * 10.0, 0.0, 1.0))

	var local_vel := global_transform.basis.inverse() * planar_velocity
	var target_roll := deg_to_rad(clampf(-local_vel.x * 1.3, -10.0, 10.0))
	if is_bot and _bot_target != null and is_instance_valid(_bot_target):
		var from_y := global_position.y + 0.7
		var to_y := _bot_target.global_position.y + 0.4
		var aim_h := global_position.distance_to(_bot_target.global_position)
		var bot_pitch := -atan2(to_y - from_y, aim_h)
		body_tilt.rotation.x = lerp_angle(body_tilt.rotation.x, bot_pitch, clampf(delta * 12.0, 0.0, 1.0))
		look_pitch = blob_rig.rotation.x
	elif is_multiplayer_authority():
		var target_pitch := deg_to_rad(clampf(-local_vel.z * 0.7 - vertical_speed * 1.6, -14.0, 14.0))
		body_tilt.rotation.x = lerp_angle(body_tilt.rotation.x, target_pitch, clampf(delta * 8.0, 0.0, 1.0))
	body_tilt.rotation.z = lerp_angle(body_tilt.rotation.z, target_roll, clampf(delta * 8.0, 0.0, 1.0))

	var floor_squash := 0.12 * minf(speed_ratio, 1.0) + 0.16 * dash_boost
	var air_stretch := 0.12 if airborne else 0.0
	var vertical_stretch := clampf(absf(vertical_speed) / 18.0, 0.0, 0.16)
	var target_scale := _blob_core_rest_scale
	target_scale.x *= 1.0 + floor_squash - air_stretch * 0.35
	target_scale.z *= 1.0 + floor_squash - air_stretch * 0.35
	target_scale.y *= 1.0 - floor_squash * 0.75 + air_stretch + vertical_stretch
	blob_core.scale = blob_core.scale.lerp(target_scale, clampf(delta * 10.0, 0.0, 1.0))

	if head_blob:
		var nod := sin(_blob_phase * 0.5 + 0.7) * (0.02 + 0.015 * speed_ratio)
		var head_target_pos := _head_blob_rest_pos + Vector3(0.0, nod + air_stretch * 0.04, -0.015 * speed_ratio)
		head_blob.position = head_blob.position.lerp(head_target_pos, clampf(delta * 8.0, 0.0, 1.0))
		# For head blob pitch: use blob_rig.rotation.x (which already reflects
		# aim for bots / movement for authority / remote pitch for network).
		head_blob.rotation.x = lerp_angle(head_blob.rotation.x, -blob_rig.rotation.x * 0.25, clampf(delta * 6.0, 0.0, 1.0))
		head_blob.rotation.z = lerp_angle(head_blob.rotation.z, -target_roll * 0.2, clampf(delta * 6.0, 0.0, 1.0))
		var head_scale := _head_blob_rest_scale
		head_scale.x *= 1.0 - floor_squash * 0.18 + air_stretch * 0.12
		head_scale.z *= 1.0 - floor_squash * 0.18 + air_stretch * 0.12
		head_scale.y *= 1.0 + floor_squash * 0.12 + air_stretch * 0.18
		head_blob.scale = head_blob.scale.lerp(head_scale, clampf(delta * 8.0, 0.0, 1.0))

	if hand_anchor:
		var sway := sin(_blob_phase * 1.35 + 0.8) * (0.02 + 0.04 * speed_ratio)
		var hand_target := _hand_anchor_rest_pos + Vector3(0.05 * speed_ratio, sway, -0.02 * dash_boost)
		hand_anchor.position = hand_anchor.position.lerp(hand_target, clampf(delta * 10.0, 0.0, 1.0))

func _show_first_person_gun() -> bool:
	# Splitscreen locals included: render_player.gd puts the FP rig on a
	# per-view gun layer that ONLY the owning view's camera renders, so rigs
	# never bleed across splitscreen views (which is why this used to exclude
	# split_screen_local — leaving those players with no visible gun at all).
	return is_multiplayer_authority() and not is_bot


func _sync_weapon_visibility() -> void:
	var blocked := ghost_mode or coop_downed or _coop_phoenix_held \
		or _phoenix_ascending or _hell_emerging or health <= 0
	var show_fp := _show_first_person_gun() and not blocked
	# Splitscreen locals show BOTH rigs: FP for their own view (per-view gun
	# layer) and third-person on the body for everyone else's views (the body
	# layer is culled from their own camera).
	var show_tp := (not show_fp or split_screen_local) and not blocked
	if muzzle:
		muzzle.visible = show_fp
	if _procedural_gun:
		_procedural_gun.visible = show_fp
	if _demon_growth:
		_demon_growth.visible = show_fp
	if _third_person_gun:
		_third_person_gun.visible = show_tp


func _update_third_person_aim_pitch(delta: float) -> void:
	# Visibility, not _show_first_person_gun(): splitscreen locals run BOTH
	# rigs, and their third-person gun (seen by other views) must keep aiming.
	if _third_person_gun == null or not _third_person_gun.visible:
		return
	# The reload flourish tweens the SAME rotation property — fighting it
	# every frame left the gun wedged between the two writers.
	if _reload_tween and _reload_tween.is_valid() and _reload_tween.is_running():
		return
	var pitch := _aim_pitch()
	var want_x := _third_person_gun_rest_rot.x + pitch
	_third_person_gun.rotation.x = lerp_angle(
		_third_person_gun.rotation.x, want_x, clampf(delta * 12.0, 0.0, 1.0))


func _apply_ghost_visuals() -> void:
	if body_model == null:
		return
	if _phoenix_ascending:
		_apply_phoenix_visuals()
		return
	if _hell_emerging:
		_apply_hell_emerge_visuals(_hell_emerge_heat())
		return
	if _coop_phoenix_held:
		_apply_phoenix_visuals(PHOENIX_ALPHA_END)
		return
	if coop_downed:
		_apply_coop_downed_visuals()
		return
	var show_body := is_bot or split_screen_local or not is_multiplayer_authority()
	if health <= 0 and not ghost_mode and not _lava_death_active:
		show_body = false
	body_model.visible = show_body
	name_label.visible = health > 0 and not ghost_mode and (is_bot or (not split_screen_local and not is_multiplayer_authority()))
	_sync_weapon_visibility()

	var gun_meshes: Array[MeshInstance3D] = []
	if gun_body: gun_meshes.append(gun_body)
	if gun_barrel: gun_meshes.append(gun_barrel)
	if gun_magazine: gun_meshes.append(gun_magazine)

	for mesh in _body_meshes() + gun_meshes:
		if ghost_mode:
			var mat := StandardMaterial3D.new()
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.albedo_color = Color(0.45, 0.95, 1.0, GHOST_ALPHA)
			mat.emission_enabled = true
			mat.emission = Color(0.25, 0.75, 0.9)
			mat.emission_energy_multiplier = 0.05
			mat.metallic = 0.0
			mat.roughness = 1.0
			mesh.material_override = mat
		else:
			mesh.material_override = _body_materials.get(mesh, mesh.material_override)


# Transparent per-pixel body material used while a player ascends (Phoenix
# revive). Distinct PSO from the unshaded effect materials, so it gets its own
# warmup. Rebuilt each frame as `body_alpha` fades 0.5 → 0.0.
static func _make_phoenix_body_material(body_alpha: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 1.0, 1.0, body_alpha)
	mat.metallic = 0.0
	mat.roughness = 0.55
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


# Additive-looking emissive column that shoots skyward during the ascension.
# Unshaded alpha-blended PSO (same variant as the grenade cluster-pop core).
static func _make_phoenix_column_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 1.0, 1.0, 0.18)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 1.0, 1.0)
	mat.emission_energy_multiplier = 14.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return mat


static func _make_coop_down_cross_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.82, 0.94, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(0.45, 0.78, 1.0)
	mat.emission_energy_multiplier = 3.2
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return mat


static func _make_hell_emerge_material(heat: float, skin_color: Color, skin_blend: float = 0.0) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var emerge_col := Violence.hell_emerge_hot_albedo_color().lerp(
		Violence.hell_emerge_warm_body_color(),
		1.0 - heat,
	)
	var blend := clampf(skin_blend, 0.0, 1.0)
	mat.albedo_color = emerge_col.lerp(skin_color, blend)
	mat.albedo_color.a = lerpf(0.92, 1.0, lerpf(1.0 - heat * 0.25, 1.0, blend))
	var glow := clampf(heat, 0.0, 1.0) * (1.0 - blend)
	mat.emission_enabled = glow > 0.001
	mat.emission = Violence.hell_emerge_hot_emission_color()
	mat.emission_energy_multiplier = lerpf(0.0, 18.0, glow)
	mat.metallic = 0.0
	mat.roughness = lerpf(0.42, 0.95, blend)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


func _apply_hell_emerge_visuals(heat: float, skin_blend: float = 0.0) -> void:
	if body_model == null:
		return
	body_model.visible = true
	name_label.visible = false
	muzzle.visible = false
	if _procedural_gun:
		_procedural_gun.visible = false
	if _third_person_gun:
		_third_person_gun.visible = false
	var skin := _identity_skin_color()
	for mesh in _body_meshes():
		mesh.material_override = _make_hell_emerge_material(heat, skin, skin_blend)
	if _hell_emerge_light and is_instance_valid(_hell_emerge_light):
		var eased := _hell_emerge_eased_progress()
		var light_t := smoothstep(0.0, 0.38, eased) * (1.0 - smoothstep(0.82, 1.0, eased))
		var glow := (1.0 - clampf(skin_blend, 0.0, 1.0)) * Violence.ease_out_cubic(light_t)
		_hell_emerge_light.light_energy = lerpf(0.0, 9.0, glow)
		var cool := Violence.hell_emerge_cool_color()
		var hot := Violence.hell_emerge_peak_light_color()
		var ash := Violence.hell_emerge_ash_color()
		var col := cool.lerp(hot, smoothstep(0.0, 0.45, eased))
		col = col.lerp(ash, smoothstep(0.78, 1.0, eased))
		col = col.lerp(skin, skin_blend)
		_hell_emerge_light.light_color = col


func _hell_emerge_rise_t() -> float:
	return clampf(_hell_emerge_elapsed / maxf(_hell_emerge_rise_seconds, 0.001), 0.0, 1.0)


func _hell_emerge_eased_progress() -> float:
	return Violence.ease_out_cubic(_hell_emerge_rise_t())


func _hell_emerge_heat() -> float:
	return clampf(1.0 - _hell_emerge_eased_progress(), 0.0, 1.0)


func _reset_blob_emerge_rest() -> void:
	if blob_rig:
		blob_rig.position = _blob_rig_rest_pos
		blob_rig.rotation = Vector3.ZERO
	if blob_core:
		blob_core.scale = _blob_core_rest_scale
	if head_blob:
		head_blob.position = _head_blob_rest_pos
		head_blob.rotation = Vector3.ZERO
		head_blob.scale = _head_blob_rest_scale
	if hand_anchor:
		hand_anchor.position = _hand_anchor_rest_pos


func _apply_hell_emerge_shake(linear: float) -> void:
	if body_model == null:
		return
	var intensity := pow(1.0 - linear, 0.55) * HELL_EMERGE_SHAKE
	if intensity <= 0.0001:
		body_model.position = Vector3.ZERO
		body_model.rotation.x = 0.0
		body_model.rotation.z = 0.0
		return
	var t := Time.get_ticks_msec() * 0.001
	var s := _hell_emerge_shake_seed
	body_model.position = Vector3(
		sin(t * (41.0 + s) * 1.7) * 0.035,
		sin(t * (53.0 + s) * 2.1) * 0.018,
		sin(t * (37.0 + s) * 1.9) * 0.035,
	) * intensity * 4.0
	body_model.rotation.x = sin(t * (29.0 + s) * 2.3) * 0.07 * intensity
	body_model.rotation.z = cos(t * (31.0 + s) * 2.0) * 0.05 * intensity


func _clear_hell_emerge_shake() -> void:
	if body_model == null:
		return
	body_model.position = Vector3.ZERO
	body_model.rotation.x = 0.0
	body_model.rotation.z = 0.0


func _dismiss_hell_emerge_telegraph() -> void:
	if _hell_emerge_telegraph_dismissed:
		return
	_hell_emerge_telegraph_dismissed = true
	var scene := get_tree().current_scene
	if scene == null:
		return
	Violence.dismiss_enemy_incoming_telegraph_at(
		scene,
		_hell_emerge_target,
		_hell_emerge_pentagram_fade_seconds,
	)


func _update_hell_emerge(delta: float) -> void:
	_hell_emerge_elapsed += delta
	var rise_t := _hell_emerge_rise_t()
	global_position = _hell_emerge_start.lerp(_hell_emerge_target, rise_t)
	var skin_blend := 0.0
	if _hell_emerge_elapsed > _hell_emerge_rise_seconds:
		skin_blend = clampf(
			(_hell_emerge_elapsed - _hell_emerge_rise_seconds) / maxf(_hell_emerge_glow_seconds, 0.001),
			0.0,
			1.0,
		)
		skin_blend = Violence.ease_out_cubic(skin_blend)
	_apply_hell_emerge_visuals(_hell_emerge_heat(), skin_blend)
	_apply_hell_emerge_shake(rise_t)
	if is_multiplayer_authority():
		velocity = Vector3.ZERO
		_last_sync_pos = global_position
		_last_sync_yaw = rotation.y
		_broadcast_state.rpc(global_position, rotation.y, look_pitch)
		_last_sync_pitch = look_pitch
	var done := _hell_emerge_elapsed >= _hell_emerge_rise_seconds + _hell_emerge_glow_seconds
	if done and not _hell_emerge_finished:
		_finish_hell_emerge()
	elif not is_multiplayer_authority():
		_remote_target_pos = global_position
		_remote_target_yaw = rotation.y
		_remote_has_target = true
		_visual_prev_pos = global_position


func _spawn_hell_emerge_light(at_world: Vector3) -> void:
	if _hell_emerge_light and is_instance_valid(_hell_emerge_light):
		_hell_emerge_light.queue_free()
	_hell_emerge_light = null
	var scene := get_tree().current_scene
	if scene == null:
		return
	var light := OmniLight3D.new()
	light.name = "HellEmergeLight"
	light.light_color = Violence.hell_emerge_cool_color()
	light.light_energy = 0.0
	light.omni_range = 7.5
	light.shadow_enabled = false
	Violence._attach_world_3d(scene, light, at_world + Vector3.UP * 0.35)
	_hell_emerge_light = light


func _clear_hell_emerge_fx() -> void:
	if _hell_emerge_light and is_instance_valid(_hell_emerge_light):
		_hell_emerge_light.queue_free()
	_hell_emerge_light = null
	$CollisionShape3D.disabled = false


func _abort_hell_emerge() -> void:
	if not _hell_emerging:
		return
	_hell_emerging = false
	_hell_emerge_finished = true
	_hell_emerge_elapsed = 0.0
	_hell_emerge_start_ms = 0
	_clear_hell_emerge_shake()
	_clear_hell_emerge_fx()
	if not _hell_emerge_telegraph_dismissed:
		_dismiss_hell_emerge_telegraph()
	for mesh in _body_meshes():
		mesh.material_override = _body_materials.get(mesh, mesh.material_override)
	_apply_identity_skin_materials()


func _finish_hell_emerge() -> void:
	_hell_emerge_finished = true
	_hell_emerging = false
	_hell_emerge_elapsed = 0.0
	_hell_emerge_start_ms = 0
	$CollisionShape3D.disabled = false
	global_position = _hell_emerge_target
	_clear_hell_emerge_shake()
	_reset_blob_emerge_rest()
	var scene := get_tree().current_scene
	if scene and not _hell_emerge_telegraph_dismissed:
		_dismiss_hell_emerge_telegraph()
	_clear_hell_emerge_fx()
	for mesh in _body_meshes():
		# Default to null (the imported textured materials), NOT the current
		# override: skinned-rig meshes are never registered in
		# _body_materials, and keeping the override left wave enemies wearing
		# the final flat emerge-skin material (solid yellow) forever.
		mesh.material_override = _body_materials.get(mesh, null)
	# The emerge tint also stomped the procedural gun parts' material
	# overrides — rebuild the third-person gun outright (bot-safe, unlike
	# _restore_weapon_visuals which early-outs for bots).
	_update_third_person_gun_visuals()
	if _third_person_gun and is_instance_valid(_third_person_gun):
		_third_person_gun.visible = true
	_apply_identity_skin_materials()
	_apply_ghost_visuals()
	_restore_weapon_visuals()
	if is_multiplayer_authority():
		velocity = Vector3.ZERO
		_last_sync_pos = global_position
		_last_sync_yaw = rotation.y
		_last_sync_pitch = look_pitch
		_broadcast_state.rpc(global_position, rotation.y, look_pitch)


@rpc("any_peer", "call_local", "reliable")
func begin_hell_emerge(
	surface_pos: Vector3,
	start_ms: int = 0,
	depth: float = -1.0,
	duration: float = -1.0,
	telegraph_cooldown: float = -1.0,
) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 1 and sender != 0:
		return
	_hell_emerge_rise_seconds = duration if duration > 0.0 else HELL_EMERGE_DURATION
	_hell_emerge_glow_seconds = telegraph_cooldown if telegraph_cooldown > 0.0 else HELL_EMERGE_GLOW
	_hell_emerge_pentagram_fade_seconds = _hell_emerge_rise_seconds * 0.5
	_hell_emerge_shake_seed = randf() * 10.0
	_hell_emerge_telegraph_dismissed = false
	_hell_emerge_elapsed = 0.0
	_hell_emerging = true
	_hell_emerge_finished = false
	if depth > 0.0:
		_hell_emerge_depth = depth
	elif is_bot:
		_hell_emerge_depth = _hell_emerge_burial_depth()
	else:
		_hell_emerge_depth = HELL_EMERGE_DEPTH
	var stand := surface_pos
	var scene := get_tree().current_scene
	if scene:
		var half_h := 0.9
		if is_bot:
			half_h = _hell_emerge_half_height()
		stand = Violence.hell_emerge_stand_pos(scene, surface_pos, half_h)
	_hell_emerge_target = stand
	_hell_emerge_start = stand - Vector3.UP * _hell_emerge_depth
	_hell_emerge_start_ms = Time.get_ticks_msec()
	$CollisionShape3D.disabled = true
	global_position = _hell_emerge_start
	velocity = Vector3.ZERO
	_reset_blob_emerge_rest()
	_spawn_hell_emerge_light(stand)
	_apply_hell_emerge_visuals(1.0)
	get_tree().create_timer(_hell_emerge_rise_seconds * 0.5).timeout.connect(
		func() -> void: call_deferred("_dismiss_hell_emerge_telegraph"),
		CONNECT_ONE_SHOT,
	)
	if is_multiplayer_authority():
		_last_sync_pos = global_position
		_last_sync_yaw = rotation.y
		_last_sync_pitch = look_pitch
		_broadcast_state.rpc(global_position, rotation.y, look_pitch)
	else:
		_remote_target_pos = global_position
		_remote_target_yaw = rotation.y
		_remote_has_target = true
		_visual_prev_pos = global_position


func _apply_coop_downed_visuals() -> void:
	if body_model:
		body_model.visible = false
	name_label.visible = false
	muzzle.visible = false
	if _procedural_gun:
		_procedural_gun.visible = false
	if _third_person_gun:
		_third_person_gun.visible = false


func _restore_weapon_visuals() -> void:
	if is_bot or ghost_mode or coop_downed or _coop_phoenix_held or _phoenix_ascending or _hell_emerging or health <= 0:
		return
	_sync_weapon_visibility()
	_update_gun_visuals()


func _clear_coop_down_marker() -> void:
	if _coop_down_marker_root and is_instance_valid(_coop_down_marker_root):
		_coop_down_marker_root.queue_free()
	_coop_down_marker_root = null
	_coop_down_marker_cross = null
	_coop_down_marker_light = null
	_coop_down_marker_phase = 0.0


func _build_coop_down_cross() -> Node3D:
	var cross := Node3D.new()
	cross.name = "Cross"
	var mat := _make_coop_down_cross_material()
	var vertical := MeshInstance3D.new()
	var v_mesh := BoxMesh.new()
	v_mesh.size = Vector3(0.14, 1.15, 0.14)
	vertical.mesh = v_mesh
	vertical.material_override = mat
	vertical.position = Vector3(0.0, 0.58, 0.0)
	cross.add_child(vertical)
	var horizontal := MeshInstance3D.new()
	var h_mesh := BoxMesh.new()
	h_mesh.size = Vector3(0.78, 0.14, 0.14)
	horizontal.mesh = h_mesh
	horizontal.material_override = mat
	horizontal.position = Vector3(0.0, 0.78, 0.0)
	cross.add_child(horizontal)
	return cross


func _spawn_coop_down_marker(at_world: Vector3) -> void:
	_clear_coop_down_marker()
	var scene := get_tree().current_scene
	if scene == null:
		return
	var anchor := Node3D.new()
	anchor.name = "CoopDownMarker"
	_coop_down_marker_cross = _build_coop_down_cross()
	anchor.add_child(_coop_down_marker_cross)
	var light := OmniLight3D.new()
	light.name = "ReviveLight"
	light.light_color = Color(0.55, 0.82, 1.0)
	light.light_energy = 6.0
	light.omni_range = 11.0
	light.omni_attenuation = 0.55
	light.shadow_enabled = false
	light.position = Vector3(0.0, 0.85, 0.0)
	anchor.add_child(light)
	_coop_down_marker_light = light
	Violence._attach_world_3d(scene, anchor, at_world)
	_coop_down_marker_root = anchor


func _tick_coop_down_marker(delta: float) -> void:
	if _coop_down_marker_root == null or not is_instance_valid(_coop_down_marker_root):
		return
	_coop_down_marker_phase += delta * 4.2
	var bob := sin(_coop_down_marker_phase) * COOP_DOWN_CROSS_BOB_HEIGHT
	if _coop_down_marker_cross and is_instance_valid(_coop_down_marker_cross):
		_coop_down_marker_cross.position.y = bob
	if _coop_down_marker_light and is_instance_valid(_coop_down_marker_light):
		_coop_down_marker_light.light_energy = 5.0 + sin(_coop_down_marker_phase * 2.0) * 1.8
		_coop_down_marker_light.position.y = 0.85 + bob


# Pre-compile the phoenix body + column material PSOs so the first revive of
# the match doesn't hitch. Built from the real factories and rendered sub-pixel
# for a few frames via Violence.warmup_material.
static func warmup_phoenix_shaders(scene: Node) -> void:
	if scene == null:
		return
	Violence.warmup_material(scene, _make_phoenix_body_material(PHOENIX_ALPHA_START))
	Violence.warmup_material(scene, _make_phoenix_column_material())


func _apply_phoenix_visuals(body_alpha: float = PHOENIX_ALPHA_START) -> void:
	if body_model == null:
		return
	body_model.visible = body_alpha > 0.01
	name_label.visible = false
	muzzle.visible = false
	if _procedural_gun:
		_procedural_gun.visible = false
	if _third_person_gun:
		_third_person_gun.visible = false
	for mesh in _body_meshes():
		mesh.material_override = _make_phoenix_body_material(body_alpha)


func _phoenix_elapsed_s() -> float:
	if _phoenix_start_ms <= 0:
		return 0.0
	return maxf(0.0, (Time.get_ticks_msec() - _phoenix_start_ms) / 1000.0)


func _phoenix_progress() -> float:
	return clampf(_phoenix_elapsed_s() / PHOENIX_ASCENT_DURATION, 0.0, 1.0)


func _phoenix_rise_amount() -> float:
	return PHOENIX_ASCENT_HEIGHT * _phoenix_progress()


func _phoenix_fade_alpha(progress: float) -> float:
	# Coop down: flash peaks early, screen is clear by apex so the player can
	# spectate. Card phoenix keeps rising white until the sky-drop fade-out.
	if coop_downed:
		return clampf(1.0 - progress, 0.0, 1.0)
	return progress


func _update_phoenix_ascent() -> void:
	var progress := _phoenix_progress()
	var rise := _phoenix_rise_amount()
	var pos := _phoenix_start_pos + Vector3(0.0, rise, 0.0)
	global_position = pos
	var body_alpha := lerpf(PHOENIX_ALPHA_START, PHOENIX_ALPHA_END, progress)
	_apply_phoenix_visuals(body_alpha)
	_tick_phoenix_column(progress)
	var game := get_tree().current_scene
	if is_multiplayer_authority():
		if game and game.has_method("set_phoenix_fade"):
			game.set_phoenix_fade(player_id, _phoenix_fade_alpha(progress))
		velocity = Vector3.ZERO
		_last_sync_pos = global_position
		_last_sync_yaw = rotation.y
		_broadcast_state.rpc(global_position, rotation.y, look_pitch)
		_last_sync_pitch = look_pitch
	if progress >= 1.0 and not _phoenix_finish_requested:
		_phoenix_finish_requested = true
		if coop_downed:
			_hold_coop_phoenix_at_apex()
		elif game and game.has_method("finish_phoenix_revive"):
			if multiplayer.is_server():
				game.finish_phoenix_revive(player_id)
			else:
				game.finish_phoenix_revive.rpc_id(1, player_id)
	elif not is_multiplayer_authority():
		_remote_target_pos = pos
		_remote_target_yaw = rotation.y
		_remote_has_target = true
		_visual_prev_pos = pos


func _spawn_phoenix_column(at_world: Vector3) -> void:
	_clear_phoenix_fx()
	var scene := get_tree().current_scene
	if scene == null:
		return
	var anchor := Node3D.new()
	anchor.name = "PhoenixColumnAnchor"
	var column := MeshInstance3D.new()
	column.name = "PhoenixColumn"
	var mesh := CylinderMesh.new()
	mesh.height = PHOENIX_COLUMN_HEIGHT
	mesh.top_radius = PHOENIX_COLUMN_RADIUS * 0.88
	mesh.bottom_radius = PHOENIX_COLUMN_RADIUS
	mesh.radial_segments = 8
	mesh.rings = 1
	column.mesh = mesh
	column.material_override = _make_phoenix_column_material()
	anchor.add_child(column)
	var light := OmniLight3D.new()
	light.name = "PhoenixLight"
	light.light_color = Color(1.0, 1.0, 1.0)
	light.light_energy = PHOENIX_LIGHT_ENERGY
	light.omni_range = 28.0
	light.omni_attenuation = 0.4
	light.shadow_enabled = false
	column.add_child(light)
	light.position = Vector3.ZERO
	Violence._attach_world_3d(scene, anchor, at_world)
	_phoenix_column_root = anchor
	_phoenix_column = column
	_phoenix_light = light


func _clear_phoenix_fx() -> void:
	if _phoenix_column_root and is_instance_valid(_phoenix_column_root):
		_phoenix_column_root.queue_free()
	_phoenix_column_root = null
	_phoenix_column = null
	_phoenix_light = null


func _tick_phoenix_column(progress: float) -> void:
	if _phoenix_column == null or not is_instance_valid(_phoenix_column):
		return
	var pulse := 1.0 + 0.25 * sin(Time.get_ticks_msec() * 0.016)
	var fade := 1.0 - progress * progress
	_phoenix_column.visible = fade > 0.02
	if _phoenix_light and is_instance_valid(_phoenix_light):
		_phoenix_light.light_energy = PHOENIX_LIGHT_ENERGY * pulse * fade
	var mat := _phoenix_column.material_override as StandardMaterial3D
	if mat:
		mat.emission_energy_multiplier = 12.0 * pulse * fade
		mat.albedo_color.a = 0.22 * fade


func _hold_coop_phoenix_at_apex() -> void:
	_phoenix_ascending = false
	_coop_phoenix_held = true
	frozen = true
	var apex := _phoenix_start_pos + Vector3(0.0, PHOENIX_ASCENT_HEIGHT, 0.0)
	global_position = apex
	_apply_phoenix_visuals(PHOENIX_ALPHA_END)
	_clear_phoenix_fx()
	var game := get_tree().current_scene
	if is_multiplayer_authority():
		velocity = Vector3.ZERO
		if game and game.has_method("set_phoenix_fade"):
			game.set_phoenix_fade(player_id, 0.0)
		_last_sync_pos = global_position
		_last_sync_yaw = rotation.y
		_last_sync_pitch = look_pitch
		_broadcast_state.rpc(global_position, rotation.y, look_pitch)
	else:
		_remote_target_pos = apex
		_remote_target_yaw = rotation.y
		_remote_has_target = true
		_visual_prev_pos = apex


func _apply_chill_visual() -> void:
	if body_model == null or ghost_mode or _phoenix_ascending:
		return
	var active := _chill_vfx_timer > 0.0 and _chill_vfx_strength > 0.01
	if not active and not _chill_visual_active:
		return
	_chill_visual_active = active
	for mesh in _body_meshes():
		if active:
			var mat := StandardMaterial3D.new()
			var frost: float = 0.2 + _chill_vfx_strength * 0.75
			mat.albedo_color = Color(0.62, 0.84, 1.0)
			mat.emission_enabled = true
			mat.emission = Color(0.3, 0.72, 1.0)
			mat.emission_energy_multiplier = frost
			mat.metallic = 0.12
			mat.roughness = 0.58
			mesh.material_override = mat
		else:
			mesh.material_override = _body_materials.get(mesh, mesh.material_override)

func _clear_chill_visual() -> void:
	_chill_vfx_timer = 0.0
	_chill_vfx_strength = 0.0
	if _chill_visual_active:
		_apply_chill_visual()


func _apply_dash_iframe_visual() -> void:
	if body_model == null or ghost_mode or _phoenix_ascending:
		return
	_dash_iframe_visual_active = true
	var alpha := 0.38 + 0.12 * sin(Time.get_ticks_msec() * 0.04)
	for mesh in _body_meshes():
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(0.92, 0.98, 1.0, alpha)
		mat.emission_enabled = true
		mat.emission = Color(0.75, 0.92, 1.0)
		mat.emission_energy_multiplier = 0.35
		mat.metallic = 0.0
		mat.roughness = 0.85
		mesh.material_override = mat


func _clear_dash_iframe_visual() -> void:
	if not _dash_iframe_visual_active:
		return
	_dash_iframe_visual_active = false
	if ghost_mode or _phoenix_ascending:
		return
	for mesh in _body_meshes():
		mesh.material_override = _body_materials.get(mesh, mesh.material_override)


func _start_dash(input_dir: Vector3) -> void:
	if dash_charges <= 0:
		return
	if input_dir.length_squared() < 0.0001:
		input_dir = -global_transform.basis.z
	dash_dir = input_dir.normalized()
	dash_timer = DASH_TIME
	dash_charges -= 1
	if not ghost_mode:
		SFX.dash(global_position)
	if weapon.dash_iframes:
		_dash_iframe_timer = DASH_TIME
		_begin_dash_iframe_vfx.rpc()
	if weapon.dash_spawn_bomb:
		var bomb_pos := global_position + Vector3.UP * 0.08
		if multiplayer.is_server():
			_spawn_dash_bomb.rpc(bomb_pos, player_id)
		elif is_multiplayer_authority():
			_request_dash_bomb.rpc_id(1, bomb_pos)


func _on_dash_ended() -> void:
	if weapon.dash_end_melee and not ghost_mode and health > 0:
		var origin := global_position + Vector3.UP * 0.9
		var dir := dash_dir if dash_dir.length_squared() > 0.001 else -global_transform.basis.z
		_melee_swung.rpc(origin, dir.normalized(), player_id, NINJA_MELEE_DAMAGE_MULT, NINJA_MELEE_RANGE_MULT)


@rpc("any_peer", "call_local", "reliable")
func _begin_dash_iframe_vfx() -> void:
	_dash_iframe_visual_timer = DASH_TIME


@rpc("any_peer", "reliable")
func _request_dash_bomb(pos: Vector3) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = player_id
	_spawn_dash_bomb.rpc(pos, sender)


@rpc("any_peer", "call_local", "reliable")
func _spawn_dash_bomb(pos: Vector3, shooter: int) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 0 and sender != 1:
		return
	var bomb_id: int = hash([pos.x, pos.y, pos.z, shooter]) & 0x7fffffff
	var uname := "DB_%d_%x" % [shooter, bomb_id]
	var parent := get_tree().current_scene
	if parent == null or parent.get_node_or_null(uname):
		return
	var scene: PackedScene = GRENADE_SCENE
	var g := scene.instantiate()
	g.name = uname
	g.shooter_id = shooter
	g.is_dash_bomb = true
	parent.add_child(g)
	g.global_position = pos

func _set_hit_face_state(active: bool) -> void:
	Violence.set_hit_face_state(self, active)

@rpc("any_peer", "call_local", "reliable")
func _show_hit_face(duration: float = HIT_FACE_DURATION) -> void:
	_hit_face_timer = maxf(_hit_face_timer, duration)
	Violence.set_hit_face_state(self, true)

func _unhandled_input(event: InputEvent) -> void:
	if is_bot or not is_multiplayer_authority():
		return
	if local_input_device >= 0:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var sens := MOUSE_SENS * mouse_sens_mult
		if is_zooming:
			sens *= 0.4 # Slower aim when zoomed
		rotate_y(-event.relative.x * sens)
		look_pitch = clamp(look_pitch - event.relative.y * sens, -1.4, 1.4)
		camera.rotation.x = look_pitch + recoil_pitch
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT \
			and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		var g := get_tree().current_scene
		if g and g.has_method("is_any_modal_open") and g.is_any_modal_open():
			return
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _physics_process(delta: float) -> void:
	if _hell_emerging:
		if health <= 0:
			return
		_update_hell_emerge(delta)
		if is_multiplayer_authority():
			velocity = Vector3.ZERO
		return

	if not is_multiplayer_authority():
		return
	_tick_status_effects(delta)

	if health <= 0 and not _phoenix_ascending and not coop_downed:
		velocity = Vector3.ZERO
		return

	if coop_downed:
		if is_multiplayer_authority() and not is_bot:
			_apply_controller_look(delta)
			_apply_camera_aim_rotation()
		velocity = Vector3.ZERO
		return

	if is_bot:
		if _phoenix_ascending:
			_physics_phoenix(delta)
			return
		_bot_physics(delta)
		return

	if launching:
		_physics_launching(delta)
		return

	if frozen:
		velocity = Vector3.ZERO
		# Frozen stops you *playing*, not looking. The mouse could always look
		# around in here (`_unhandled_input` never asked whether the player was
		# frozen), so a stick that can't was the only thing punishing whoever
		# picked up a controller — and the cage, with the arena turning around
		# you, is exactly where you want to look.
		_apply_controller_look(delta)
		_apply_camera_aim_rotation()
		_update_gun_inspect(delta)
		return

	if _phoenix_ascending:
		_physics_phoenix(delta)
		return

	_tick_cooldowns(delta)
	_decay_view_recoil(delta)
	_apply_controller_look(delta)
	_apply_camera_aim_rotation()
	_update_gun_feel(delta)
	_update_gravity_and_landing(delta)
	_update_jump_and_dash()
	_update_movement(delta)
	_handle_combat_input()
	_handle_fell_off_map()

func _physics_launching(delta: float) -> void:
	# Rocket-spawn descent. Constant downward velocity (set in set_launching),
	# no gravity ramp, no input, no combat. Apply the tilt-down camera + shake
	# jitter every frame; on the first floor contact we end the launch ourselves
	# and play the existing landing thump scaled by impact velocity.
	var pre_impact_y: float = velocity.y
	move_and_slide()
	if not is_bot:
		camera.rotation.x = look_pitch + recoil_pitch + _view_punch_rot.x
		camera.position = _camera_rest_pos + Vector3(
			randf_range(-1.0, 1.0) * shake_amt,
			randf_range(-1.0, 1.0) * shake_amt,
			0.0,
		)
	if is_on_floor():
		if launching:
			_sync_launching.rpc(false)
		_rocket_descent_player = null
		if not is_bot:
			SFX.landing(absf(pre_impact_y), global_position)
	elif global_position.y < -30.0:
		# If a spawn point is ever invalid, do not leave the player alive in
		# launch state forever. Launch state gates shooting/movement, and
		# environmental damage intentionally ignores it during valid descents.
		if launching:
			_sync_launching.rpc(false)
		_handle_fell_off_map()

func _physics_phoenix(delta: float) -> void:
	# Revive ascent: float upward, no movement/combat. We still tick weapon
	# cooldowns and decay recoil/shake so the player resumes in a clean state.
	# (muzzle_kick_z / _landing_bump_y also decay here but are invisible — the
	# gun-feel block that consumes them is skipped during the ascent.)
	_tick_weapon_cooldowns(delta)
	_decay_view_recoil(delta)
	_apply_controller_look(delta)
	_apply_camera_aim_rotation()
	if not is_bot and camera:
		camera.fov = 30.0 if is_zooming else 75.0

func _tick_weapon_cooldowns(delta: float) -> void:
	rifle_cooldown = max(0.0, rifle_cooldown - delta)
	grenade_cooldown = max(0.0, grenade_cooldown - delta)
	melee_cooldown = max(0.0, melee_cooldown - delta)

func _tick_cooldowns(delta: float) -> void:
	_tick_weapon_cooldowns(delta)
	wall_jump_cooldown = max(0.0, wall_jump_cooldown - delta)
	# Dash charges recharge one at a time while below max.
	if dash_charges < MAX_DASH_CHARGES:
		dash_recharge_timer += delta
		if dash_recharge_timer >= DASH_RECHARGE_TIME:
			dash_charges += 1
			dash_recharge_timer = 0.0
	else:
		dash_recharge_timer = 0.0
	# Reload completes when the cooldown set to the weapon's reload time runs out.
	if reloading and rifle_cooldown <= 0.0:
		mag = weapon.get_mag_size()
		reloading = false
	cooldowns_changed.emit()

func _decay_view_recoil(delta: float) -> void:
	# Recoil decay + apply
	recoil_pitch = lerp(recoil_pitch, 0.0, delta * 9.0)
	muzzle_kick_z = lerp(muzzle_kick_z, 0.0, delta * 14.0)
	_recoil_spread = lerp(_recoil_spread, 0.0, clampf(delta * RECOIL_DECAY_RATE, 0.0, 1.0))
	shake_amt = lerp(shake_amt, 0.0, delta * 14.0)
	_landing_bump_y = lerp(_landing_bump_y, 0.0, delta * 10.0) # Smooth recovery
	# View punch decay
	_view_punch_pos = _view_punch_pos.lerp(Vector3.ZERO, delta * 12.0)
	_view_punch_rot = _view_punch_rot.lerp(Vector3.ZERO, delta * 12.0)

func _apply_controller_look(delta: float) -> void:
	if _can_accept_gameplay_input() and (local_input_device >= 0 or not split_screen_local):
		var look_device := local_input_device if local_input_device >= 0 else 0
		var look_input := Vector2(
			Input.get_joy_axis(look_device, JOY_AXIS_RIGHT_X),
			Input.get_joy_axis(look_device, JOY_AXIS_RIGHT_Y)
		)
		if look_input.length() > CONTROLLER_LOOK_DEADZONE:
			var look_mag := inverse_lerp(CONTROLLER_LOOK_DEADZONE, 1.0, minf(look_input.length(), 1.0))
			var look_dir := look_input.normalized() * pow(look_mag, CONTROLLER_LOOK_CURVE)
			var sens := CONTROLLER_LOOK_SENS * MenuHelpers.stick_sens_mult
			if is_zooming:
				sens *= 0.4
			rotate_y(-look_dir.x * sens * delta)
			look_pitch = clamp(look_pitch - look_dir.y * sens * delta, -1.4, 1.4)

func _apply_camera_aim_rotation() -> void:
	camera.rotation.x = look_pitch + recoil_pitch + _view_punch_rot.x
	camera.rotation.y = _view_punch_rot.y
	camera.rotation.z = deg_to_rad(tilt_z) + _view_punch_rot.z

# Card-growth inspect: while the first-person gun is mid-growth, pull it
# toward screen center and yaw the muzzle LEFT so the right flank (where the
# eye grows) squares up to the camera. Pure viewmodel motion on the gun
# nodes — the muzzle stays authoritative for fire direction. Called from
# _update_gun_feel AND from the frozen branch of _physics_process: the morph
# plays inside the spawn cage, where the player is frozen and normal gun
# feel is skipped.
func _update_gun_inspect(delta: float) -> void:
	var inspecting: bool = _show_first_person_gun() and _procedural_gun != null \
		and _procedural_gun.has_method("is_growing") and _procedural_gun.is_growing()
	_gun_inspect = lerpf(_gun_inspect, 1.0 if inspecting else 0.0, clampf(delta * 5.0, 0.0, 1.0))
	if _procedural_gun:
		var s: float = _gun_inspect if _gun_inspect > 0.001 else 0.0
		var inspect_pos := Vector3(-0.14, 0.04, 0.14) * s
		var inspect_rot := Vector3(0.12, 1.0, 0.08) * s
		_procedural_gun.position = inspect_pos
		_procedural_gun.rotation = inspect_rot
		if _demon_growth:
			_demon_growth.position = inspect_pos
			_demon_growth.rotation = inspect_rot

func _update_gun_feel(delta: float) -> void:
	# --- Gun feel: walk bob, jump bump, strafe tilt ---
	# Phase advances by π per STEP_STRIDE meters travelled — one bob per
	# footstep, so the gun visibly thumps in sync with the step audio.
	var horiz_speed: float = Vector2(velocity.x, velocity.z).length()
	var moved_this_tick: float = horiz_speed * delta
	var bob_intensity: float = 0.0
	if is_on_floor() and horiz_speed > 0.5:
		bob_intensity = clampf(horiz_speed / WALK_SPEED, 0.0, 1.4)
		_walk_bob_phase += (moved_this_tick / STEP_STRIDE) * PI
	var bob_y: float = sin(_walk_bob_phase) * GUN_BOB_AMP_Y * bob_intensity
	# Horizontal sway runs at half the vertical frequency — classic figure-8 feel.
	var bob_x: float = sin(_walk_bob_phase * 0.5) * GUN_BOB_AMP_X * bob_intensity
	_gun_jump_bump = lerp(_gun_jump_bump, 0.0, clampf(delta * 8.0, 0.0, 1.0))
	# Tilt the gun proportional to actual lateral velocity, not button state —
	# blocked-against-a-wall strafe shouldn't tilt, momentum-only sideways slide
	# should. velocity.dot(basis.x) is positive when sliding right.
	var gun_lateral_factor: float = clampf(velocity.dot(global_transform.basis.x) / WALK_SPEED, -1.0, 1.0)
	if not tilt_enabled:
		gun_lateral_factor = 0.0
	_gun_tilt_z = lerp(_gun_tilt_z, deg_to_rad(gun_lateral_factor * GUN_STRAFE_TILT_DEG), clampf(delta * 8.0, 0.0, 1.0))

	muzzle.position = _muzzle_rest_pos + Vector3(bob_x, bob_y - _gun_jump_bump, muzzle_kick_z) + melee_offset + reload_offset + _gun_pull_back
	# Don't fight the melee tween while it's running.
	if not (_melee_tween and _melee_tween.is_valid()):
		muzzle.rotation.z = _gun_tilt_z
	_update_gun_inspect(delta)
	# Height scales with body_scale (and the per-axis Y warp) so the viewpoint
	# follows the taller head — SLENDERMAN sees the world from way up high.
	var cam_y: float = (_camera_rest_pos.y * maxf(0.1, weapon.body_scale) * maxf(0.1, weapon.body_scale_axes.y)) - _landing_bump_y
	camera.position = Vector3(
		_camera_rest_pos.x + randf_range(-1.0, 1.0) * shake_amt,
		cam_y + randf_range(-1.0, 1.0) * shake_amt,
		_camera_rest_pos.z,
	) + _view_punch_pos # Apply hit punch offset

func _update_gravity_and_landing(delta: float) -> void:
	# --- Gravity ---
	if not is_on_floor():
		velocity.y -= GRAVITY * _gravity_mult() * delta
	else:
		# Detect landing
		if not _was_on_floor:
			var impact_vel := absf(velocity.y)
			# Scale bump by impact velocity (e.g. 10m/s -> 0.2m dip)
			_landing_bump_y = clampf(impact_vel * 0.02, 0.0, 0.4)
			if not ghost_mode: SFX.landing(impact_vel, global_position)

		# Default: 1 ground jump + 1 air double-jump = 2 total.
		# ACROBAT and similar cards extend this via weapon.extra_jumps.
		jumps_left = 2 + weapon.extra_jumps

	_was_on_floor = is_on_floor()

func _update_jump_and_dash() -> void:
	# --- Jump / wall-jump / double-jump ---
	# Wall-jump takes priority over double-jump so you can chain WJ → WJ → dash → WJ
	# to climb a building. Each WJ imparts strong up + gentle outward push, so the
	# player must strafe/dash back toward the wall to chain.
	var jump_pressed := _action_just_pressed_local("jump")
	var dash_pressed := _action_just_pressed_local("dash")

	if jump_pressed:
		if is_on_floor():
			velocity.y = JUMP_VELOCITY
			jumps_left = 1 + weapon.extra_jumps
			_gun_jump_bump = GUN_JUMP_BUMP
			_play_knight_jump()
			if not ghost_mode: SFX.jump(global_position)
		elif is_on_wall() and wall_jump_cooldown <= 0.0:
			var n := get_wall_normal()
			velocity.y = WALL_JUMP_V
			velocity.x += n.x * WALL_JUMP_H
			velocity.z += n.z * WALL_JUMP_H
			wall_jump_cooldown = WALL_JUMP_COOLDOWN
			jumps_left = 1 + weapon.extra_jumps  # wall-jump refreshes all air-jumps
			_gun_jump_bump = GUN_JUMP_BUMP
			_play_knight_jump()
			if not ghost_mode: SFX.jump(global_position)
		elif jumps_left > 0:
			velocity.y = DOUBLE_JUMP_VELOCITY
			jumps_left -= 1
			_gun_jump_bump = GUN_JUMP_BUMP * 0.7
			_play_knight_jump()
			if not ghost_mode: SFX.jump(global_position)

	# --- Dash ---
	if dash_pressed and dash_charges > 0:
		_start_dash(_input_vector())

func _update_movement(delta: float) -> void:
	# --- Movement ---
	# Camera roll keys off lateral velocity so tilt fades when the player is
	# blocked, slows naturally with momentum carryover, and amps up during a
	# sideways dash. (Sign matches the old input-based version: +basis.x dot
	# velocity > 0 when strafing right → positive tilt_z.)
	var lateral_factor: float = clampf(velocity.dot(global_transform.basis.x) / WALK_SPEED, -1.0, 1.0)
	if not tilt_enabled:
		lateral_factor = 0.0
	tilt_z = lateral_factor * TILT_MAX_DEG

	var wish_dir := _input_vector()
	var current_walk_speed := WALK_SPEED * weapon.move_speed_mult * _slow_mult
	var target_vel := wish_dir * current_walk_speed

	# Horizontal velocity only for momentum calculations
	var horizontal_vel := Vector3(velocity.x, 0.0, velocity.z)
	var is_speeding := horizontal_vel.length() > current_walk_speed + 0.1

	var accel: float
	if dash_timer > 0.0:
		dash_timer -= delta
		velocity.y = max(velocity.y, 0.0)
		# Taper dash speed at the end (last 50% of duration).
		var dash_factor := clampf(dash_timer / (DASH_TIME * 0.5), 0.0, 1.0)
		var dash_vel := dash_dir * DASH_SPEED * _slow_mult
		# Blend between dash velocity and walk velocity.
		target_vel = target_vel.lerp(dash_vel, dash_factor)
		accel = 2000.0 # Snap to dash trajectory
		if dash_timer <= 0.0:
			_on_dash_ended()
	elif is_on_floor():
		# If we're moving faster than walk speed (e.g. from explosion), use low friction
		# instead of high acceleration to stop us.
		if is_speeding and wish_dir.dot(horizontal_vel.normalized()) <= 0.5:
			accel = FRICTION
		else:
			accel = GROUND_ACCEL
	else:
		accel = AIR_ACCEL

	velocity.x = move_toward(velocity.x, target_vel.x, accel * delta)
	velocity.z = move_toward(velocity.z, target_vel.z, accel * delta)

	if is_on_floor() and wish_dir == Vector3.ZERO and dash_timer <= 0.0 and not is_speeding:
		velocity.x = move_toward(velocity.x, 0.0, FRICTION * delta * current_walk_speed * 0.1)
		velocity.z = move_toward(velocity.z, 0.0, FRICTION * delta * current_walk_speed * 0.1)
	move_and_slide()
	_maybe_broadcast_state()
	_tick_footsteps(delta)

func _handle_combat_input() -> void:
	# --- Combat actions ---
	# Hold LMB to keep firing — the weapon's fire_interval gates the cadence.
	var shoot_pressed := _action_pressed_local("shoot")
	var shoot_just_pressed := _action_just_pressed_local("shoot")
	var reload_pressed := _action_just_pressed_local("reload")
	var special_pressed := _action_just_pressed_local("shoot_grenade")
	# Zoom is hold-to-aim (sniper scope), not a toggle — track held state so
	# is_zooming follows the button instead of flipping each press.
	var special_held := _action_pressed_local("shoot_grenade")

	var can_fire := _can_accept_gameplay_input()
	var fire_input := shoot_pressed and can_fire
	if ghost_mode:
		fire_input = false
		if shoot_just_pressed and grenade_cooldown <= 0.0 and can_fire:
			grenade_cooldown = MINE_RELOAD
			_place_mine()
	if fire_input and not reloading and mag > 0 and rifle_cooldown <= 0.0:
		rifle_cooldown = weapon.get_fire_interval()
		mag -= 1
		_fire_rifle()
		# Schedule the bolt-cycling click for the gap before the next shot.
		# Skip on very fast weapons (uzi-class) where the click would just
		# muddy the rapid bang stream.
		var fi: float = weapon.get_fire_interval()
		if fi >= 0.18:
			var click_delay: float = minf(fi * 0.45, 0.13)
			# Connect a method, NOT a self-capturing lambda: the signal
			# auto-disconnects if this player frees before the timer fires
			# (death/respawn), so a freed shooter is a silent no-op instead of a
			# "Lambda capture was freed" error.
			get_tree().create_timer(click_delay).timeout.connect(_play_bolt_click)
		if mag <= 0:
			_start_reload()
	elif shoot_just_pressed and can_fire and not ghost_mode and (reloading or mag <= 0):
		# Trigger pulled while the gun isn't ready — the dull "click of nothing".
		if muzzle:
			SFX.empty_chamber(muzzle.global_position)
	if reload_pressed and not ghost_mode and can_fire:
		_start_reload()
	if not ghost_mode and can_fire:
		if weapon.special == Weapon.SPECIAL_ZOOM:
			# Hold-to-zoom: scope follows the button, releases when let go.
			is_zooming = special_held
		elif special_pressed and grenade_cooldown <= 0.0:
			_use_special()

	if weapon.special != Weapon.SPECIAL_ZOOM:
		is_zooming = false # Auto-cancel zoom if weapon special changes (e.g. card reset)

func _input_vector() -> Vector3:
	var input := _move_vector()
	var dir := (global_transform.basis * Vector3(input.x, 0.0, input.y))
	dir.y = 0.0
	return dir

func _can_accept_gameplay_input() -> bool:
	var g := get_tree().current_scene
	# In splitscreen, a card pick on a teammate's view must not freeze this
	# player — only THIS player's modal (or a global one) should gate input.
	if g and g.has_method("is_modal_blocking_player") and g.is_modal_blocking_player(player_id):
		return false
	return split_screen_local or Input.mouse_mode == Input.MOUSE_MODE_CAPTURED

# Players are named by their peer id under a shared parent ("Players" in game,
# whatever container the labs use). Look up a sibling player by id — returns
# null if absent (freed mid-flight, not yet spawned, etc.).
func _sibling_player(id: int) -> Node3D:
	var parent := get_parent()
	return parent.get_node_or_null(str(id)) as Node3D if parent else null

func _handle_fell_off_map() -> void:
	if global_position.y >= -30.0:
		return
	if ghost_mode:
		global_position = Vector3(0, 5, 0)
		reset_physics_interpolation()
		velocity = Vector3.ZERO
		_last_sync_pos = Vector3.INF
	else:
		var lethal_amount: int = max(health, MAX_HEALTH)
		_apply_damage(lethal_amount, player_id)


func handle_environmental_death(_reason: String = "void") -> void:
	# Called by external triggers (lava Area3D, future hazards) when the
	# player crosses into a lethal volume. Each peer's local hitbox fires its
	# own area-entered signal, so the authority guard prevents duplicate
	# damage. Self-attribution keeps it out of the kill-credit log without
	# inventing a fake from_id.
	if not is_multiplayer_authority():
		return
	if ghost_mode or god_mode or health <= 0 or frozen or launching or _phoenix_ascending or _hell_emerging:
		return
	var lethal_amount: int = max(health, MAX_HEALTH)
	_apply_damage(lethal_amount, player_id)


func kill_environmental(_reason: String = "hazard") -> void:
	if not is_multiplayer_authority():
		return
	if ghost_mode or god_mode or health <= 0 or _phoenix_ascending:
		return
	_sync_launching.rpc(false)
	if _reason == "lava_fall":
		_stop_rocket_descent_audio()
	if _reason.begins_with("lava"):
		_pending_lava_death = true
		_pending_lava_death_fall = (_reason == "lava_fall")
		_suppress_next_death_ragdoll = true
		_play_lava_sizzle.rpc(global_position, true)
	var saved_phoenix_charges := _phoenix_charges_left
	_phoenix_charges_left = 0
	var lethal_amount: int = max(health, MAX_HEALTH + weapon.max_hp_bonus)
	_apply_damage(lethal_amount, player_id)
	if health > 0:
		_phoenix_charges_left = saved_phoenix_charges


func apply_environmental_damage(amount: int, _reason: String = "hazard") -> void:
	if not is_multiplayer_authority():
		return
	if ghost_mode or god_mode or health <= 0 or frozen or launching or _phoenix_ascending or _hell_emerging:
		return
	if _reason == "lava":
		var now := Time.get_ticks_msec()
		if now - _last_lava_contact_sizzle_ms > 900:
			_last_lava_contact_sizzle_ms = now
			_play_lava_sizzle.rpc(global_position, false)
		if amount >= health:
			_pending_lava_death = true
			_pending_lava_death_fall = false
			_suppress_next_death_ragdoll = true
			_play_lava_sizzle.rpc(global_position, true)
	_apply_damage(max(0, amount), 0)

func _move_vector() -> Vector2:
	if not _can_accept_gameplay_input():
		return Vector2.ZERO
	if local_input_device < 0:
		return _keyboard_move_vector()
	var raw := Vector2(
		Input.get_joy_axis(local_input_device, JOY_AXIS_LEFT_X),
		Input.get_joy_axis(local_input_device, JOY_AXIS_LEFT_Y)
	)
	if raw.length() < 0.18:
		return Vector2.ZERO
	return raw.limit_length(1.0)

func _move_axis_x() -> float:
	if not _can_accept_gameplay_input():
		return 0.0
	if local_input_device < 0:
		var right := 1.0 if Input.is_physical_key_pressed(KEY_D) else 0.0
		var left := 1.0 if Input.is_physical_key_pressed(KEY_A) else 0.0
		return right - left
	var x := Input.get_joy_axis(local_input_device, JOY_AXIS_LEFT_X)
	return 0.0 if absf(x) < 0.18 else x

func _action_pressed_local(action: StringName) -> bool:
	if not _can_accept_gameplay_input():
		return false
	if local_input_device < 0:
		return _keyboard_action_pressed(action)
	match action:
		&"shoot":
			return Input.get_joy_axis(local_input_device, JOY_AXIS_TRIGGER_RIGHT) > 0.35
		&"shoot_grenade":
			return Input.get_joy_axis(local_input_device, JOY_AXIS_TRIGGER_LEFT) > 0.35 \
				or Input.is_joy_button_pressed(local_input_device, JOY_BUTTON_B)
		&"jump":
			return Input.is_joy_button_pressed(local_input_device, JOY_BUTTON_LEFT_SHOULDER) \
				or Input.is_joy_button_pressed(local_input_device, JOY_BUTTON_A)
		&"reload":
			return Input.is_joy_button_pressed(local_input_device, JOY_BUTTON_X)
		&"dash":
			return Input.is_joy_button_pressed(local_input_device, JOY_BUTTON_RIGHT_SHOULDER) \
				or Input.is_joy_button_pressed(local_input_device, JOY_BUTTON_Y)
	return false

func _action_just_pressed_local(action: StringName) -> bool:
	if not _can_accept_gameplay_input():
		_prev_local_actions[action] = false
		return false
	var pressed := _action_pressed_local(action)
	var was_pressed := bool(_prev_local_actions.get(action, false))
	_prev_local_actions[action] = pressed
	return pressed and not was_pressed

func _keyboard_move_vector() -> Vector2:
	var input := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_A):
		input.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D):
		input.x += 1.0
	if Input.is_physical_key_pressed(KEY_W):
		input.y -= 1.0
	if Input.is_physical_key_pressed(KEY_S):
		input.y += 1.0
	return input.limit_length(1.0)

func _keyboard_action_pressed(action: StringName) -> bool:
	match action:
		&"shoot":
			return Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
		&"shoot_grenade":
			return Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
		&"jump":
			return Input.is_physical_key_pressed(KEY_SPACE)
		&"reload":
			return Input.is_physical_key_pressed(KEY_R)
		&"dash":
			return Input.is_physical_key_pressed(KEY_SHIFT)
	return false

# -------------------- RIFLE (hitscan) --------------------

func _fire_rifle() -> void:
	var cam_origin: Vector3 = camera.global_position
	var cam_dir: Vector3 = -camera.global_transform.basis.z
	# Bullet visually leaves the gun, but aims at whatever the crosshair sees —
	# raycast from the camera, then point the muzzle at that hit point. Far
	# enough away the parallax is invisible; close range stays believable.
	var origin: Vector3 = muzzle.global_position if muzzle else cam_origin
	var aim_dist: float = RIFLE_RANGE
	var space := get_world_3d().direct_space_state
	var aim_q := PhysicsRayQueryParameters3D.create(cam_origin, cam_origin + cam_dir * aim_dist)
	aim_q.collision_mask = 1 | 2  # world + players
	aim_q.collide_with_areas = true
	aim_q.exclude = get_hitbox_rids()
	var aim_hit := space.intersect_ray(aim_q)
	var aim_point: Vector3 = aim_hit.position if not aim_hit.is_empty() else (cam_origin + cam_dir * aim_dist)
	var base_dir: Vector3 = (aim_point - origin).normalized()
	# Local feel (authority-only; these fields are driven by the local physics loop).
	var last_shot := mag <= 0
	# Scale recoil and kick by the fired round — last bullet can hit harder
	# without resizing the procedural gun mesh.
	var scale_f := weapon.get_bullet_scale_for_shot(last_shot)
	var recoil_scale := scale_f * clampf(weapon.get_recoil_per_shot() / Weapon.BASE_RECOIL, 0.2, 2.5)
	recoil_pitch += RIFLE_RECOIL_PITCH * recoil_scale
	muzzle_kick_z = max(muzzle_kick_z, RIFLE_RECOIL_KICK * recoil_scale)
	shake_amt = max(shake_amt, RIFLE_SHAKE * recoil_scale)
	rotate_y(randf_range(-RIFLE_RECOIL_YAW_JITTER, RIFLE_RECOIL_YAW_JITTER) * recoil_scale)
	# Physical recoil push — opposite to where you're aiming. Negligible at
	# base damage; meaningful when you stack DAMAGE / HAYMAKER / BAZOOKA.
	# Power 1.6 means scaling is gentle until damage is well above 1×.
	var dmg_ratio: float = weapon.get_damage_for_shot(last_shot) / Weapon.BASE_DAMAGE
	var kick_strength: float = clampf(0.4 * pow(dmg_ratio, 1.6), 0.1, 12.0)
	velocity -= cam_dir * kick_strength * float(weapon.get_shots_per_trigger())
	# Snapshot spread BEFORE this shot's bloom so the first shot is still crisp,
	# then add the per-shot recoil so each successive held shot walks wider.
	var spread: float = get_effective_spread()
	_recoil_spread = minf(_recoil_spread + weapon.get_recoil_per_shot(), MAX_EFFECTIVE_SPREAD)
	# Multi-shot: fire N rays with random yaw+pitch spread (MULTI-SHOT card).
	var shots: int = weapon.get_shots_per_trigger()
	var cam_right: Vector3 = camera.global_transform.basis.x
	var cam_up: Vector3 = camera.global_transform.basis.y
	for i in shots:
		var dir := base_dir
		if spread > 0.0:
			var theta: float = randf() * TAU
			var r: float = spread * randf() * randf()
			dir = base_dir.rotated(cam_up, r * cos(theta)).rotated(cam_right, r * sin(theta)).normalized()
		_rifle_fired.rpc(origin, dir, player_id, last_shot)
	_cycle_first_person_gun(shots)

# First-person gun mechanics: heat glow, bolt cycle, brass ejection. These are
# cosmetic and FIRST-PERSON ONLY, so _bot_shoot deliberately does NOT call this
# (bots have a _procedural_gun too, but ejecting physical casings per shot is a
# real per-tick cost the perf bench tracks — see AGENTS.md). Anything that must
# affect gameplay for BOTH humans and bots belongs in _rifle_fired (the shared,
# call_local RPC sink), NOT here and NOT in either fire path.
func _cycle_first_person_gun(shots: int) -> void:
	if not _procedural_gun:
		return
	# Barrel overheating — pump in heat per shot, scaled by damage. Cooldown
	# happens passively in procedural_gun._process. Heavy / fast builds
	# steady-state into a red glow; the base gun stays under the threshold.
	if _procedural_gun.has_method("add_heat"):
		_procedural_gun.add_heat(weapon.damage_mult * float(shots))
	# Cycle the bolt — charging handles on the receiver snap back on every
	# trigger pull and slide forward over the fire interval, arriving at
	# rest exactly as the next shot snaps them back again.
	if _procedural_gun.has_method("cycle_bolt"):
		_procedural_gun.cycle_bolt(weapon.get_fire_interval())
	# Eject one brass casing per bullet — multi-barrel / multi-shot weapons
	# spit out a small capped burst from the same ejection port. The cap keeps
	# stacked miniguns from turning every projectile into a physics body.
	if _procedural_gun.has_method("eject_casing"):
		for _i in mini(shots, MAX_FIRST_PERSON_CASINGS_PER_TRIGGER):
			_procedural_gun.eject_casing()

@rpc("any_peer", "call_local", "reliable")
func _rifle_fired(
	origin: Vector3,
	dir: Vector3,
	shooter_id: int,
	last_in_mag: bool = false,
) -> void:
	# Music: jump to high intensity the moment anyone fires this round.
	# call_local means this RPC fires on every peer, but only the server
	# drives _set_round_music_level (which then broadcasts via _set_music_energy).
	if multiplayer.is_server():
		var game_scene: Node = get_tree().current_scene
		if game_scene and game_scene.has_method("_on_player_shot"):
			game_scene._on_player_shot()
	var shooter_node: Node3D = _sibling_player(shooter_id)
	var w: Weapon = shooter_node.weapon if shooter_node else Weapon.new()
	# `is_self` = the local human is the shooter. Their copy plays a 2D
	# variant with its own volume curve (no 3D bus reverb / distance shaping).
	var is_self: bool = shooter_id == multiplayer.get_unique_id()
	var silenced: bool = w.silencer_stacks > 0
	var spawn_shot_fx := true
	if shooter_node and shooter_node.has_method("_consume_shot_fx_budget"):
		spawn_shot_fx = bool(shooter_node.call("_consume_shot_fx_budget"))
	if spawn_shot_fx and not (BenchFlags.active and BenchFlags.no_shot_audio):
		SFX.shot(w, origin, is_self, silenced, last_in_mag)

	# Bench A/B: skip bullet spawning entirely (one static bool branch out
	# of bench mode). See scripts/bench_flags.gd.
	if BenchFlags.active and BenchFlags.no_bullets:
		return
	var bullet_script: GDScript = preload("res://scripts/bullet.gd")
	var bullet := Node3D.new()
	bullet.set_script(bullet_script)
	get_tree().current_scene.add_child(bullet)
	bullet.setup(origin, dir, shooter_id, w, last_in_mag, is_self)
	BenchFlags.inc("bullets_spawned")

	# Muzzle flash scales with bullet size — get_bullet_scale already folds
	# in damage_mult, so no extra sqrt(dmg_ratio) factor here.
	var local_first_person := (
		shooter_id == multiplayer.get_unique_id()
		and is_multiplayer_authority()
		and not is_bot
	)
	var visual_anchor := muzzle if local_first_person else _third_person_shot_anchor()
	if visual_anchor == null:
		visual_anchor = muzzle
	if spawn_shot_fx and not silenced and not (BenchFlags.active and BenchFlags.no_muzzle_flash):
		var dmg_ratio := w.get_damage_for_shot(last_in_mag) / Weapon.BASE_DAMAGE
		var flash_brightness := clampf(pow(dmg_ratio, 0.88) * 1.5, 0.85, 8.0)
		_spawn_muzzle_flash(w.bullet_color, w.get_bullet_scale_for_shot(last_in_mag), visual_anchor, local_first_person, flash_brightness)
	if spawn_shot_fx and not local_first_person:
		if _third_person_procedural_gun:
			if _third_person_procedural_gun.has_method("cycle_bolt"):
				_third_person_procedural_gun.cycle_bolt(w.get_fire_interval())
			if _third_person_procedural_gun.has_method("add_heat"):
				_third_person_procedural_gun.add_heat(w.damage_mult)
		_spawn_third_person_casing(w)

func _play_bolt_click() -> void:
	if muzzle:
		SFX.next_round(muzzle.global_position)

func _consume_shot_fx_budget() -> bool:
	var frame := Engine.get_physics_frames()
	if _shot_fx_frame != frame:
		_shot_fx_frame = frame
		_shot_fx_count = 0
	if _shot_fx_count >= MAX_SHOT_FX_PER_FRAME:
		return false
	_shot_fx_count += 1
	return true

func _apply_bullet_splash(pos: Vector3, radius: float, damage: float, shooter_id: int) -> void:
	var kb_mult := 1.0
	var shooter := _sibling_player(shooter_id)
	if shooter and shooter.get("weapon") != null:
		kb_mult = shooter.weapon.knockback_mult
	Blast.apply(
		get_tree().current_scene,
		pos,
		radius,
		damage,
		shooter_id,
		EXPLOSION_EDGE_FALLOFF,
		0.5,
		kb_mult,
		0.25,
		Blast.LOS_TORSO,
		true
	)


func _apply_air_strike_splash(pos: Vector3, radius: float, damage: float, shooter_id: int) -> void:
	_apply_bullet_splash(pos, radius, damage, shooter_id)


func _apply_ion_cannon_splash(
	pos: Vector3,
	radius: float,
	damage: float,
	shooter_id: int,
	bottom_y: float,
	top_y: float,
) -> void:
	# Sky beam: vertical cylinder at the strike point — cover does not block it.
	_apply_artillery_splash(pos, radius, damage, shooter_id, bottom_y, top_y)


func _apply_artillery_splash(
	pos: Vector3,
	radius: float,
	damage: float,
	shooter_id: int,
	bottom_y: float,
	top_y: float,
) -> void:
	var shooter := _sibling_player(shooter_id)
	var game_scene := get_tree().current_scene
	for p: Node3D in get_tree().get_nodes_in_group("players"):
		if not is_instance_valid(p):
			continue
		if p.get("ghost_mode") == true:
			continue
		if p.player_id != shooter_id and game_scene and game_scene.has_method("should_block_player_damage") \
				and game_scene.should_block_player_damage(p.player_id, shooter_id):
			continue
		var player_y := p.global_position.y
		if player_y < bottom_y or player_y > top_y:
			continue
		var flat_dist: float = Vector2(
			p.global_position.x - pos.x,
			p.global_position.z - pos.z
		).length()
		if flat_dist > radius:
			continue
		var dist_ratio := clampf(flat_dist / radius, 0.0, 1.0)
		var falloff := lerpf(0.58, 1.0, 1.0 - dist_ratio)
		var dmg: int = int(damage * falloff)
		if p.player_id == shooter_id:
			dmg = int(dmg * 0.5)
		var dir: Vector3 = p.global_position - pos
		if dir.length_squared() > 0.001:
			dir = dir.normalized()
		else:
			dir = Vector3.UP
		var kb := Weapon.knockback_from_damage(float(dmg), 1.0, true)
		var impulse: Vector3 = dir * kb + Vector3.UP * kb * 0.25
		if dmg > 0:
			p.take_damage.rpc_id(
				p.get_multiplayer_authority(),
				dmg,
				shooter_id,
				pos,
				dir,
				impulse.length(),
				radius,
				falloff
			)
			if p.player_id != shooter_id and shooter and is_instance_valid(shooter):
				shooter._hit_confirm.rpc_id(shooter.get_multiplayer_authority(), false, dmg, p.global_position + Vector3.UP * 0.6)
				if shooter.has_method("_on_dealt_damage"):
					shooter._on_dealt_damage.rpc_id(shooter.get_multiplayer_authority(), dmg)
		p.apply_knockback.rpc_id(p.get_multiplayer_authority(), impulse)


@rpc("any_peer", "call_local", "reliable")
func _on_dealt_damage(damage: int) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 1 and sender != 0:
		return
	if not is_multiplayer_authority():
		return
	if damage <= 0:
		return
	if weapon.reload_on_hit > 0:
		mag = mini(weapon.get_mag_size(), mag + weapon.reload_on_hit)
		if mag > 0 and reloading:
			reloading = false
			rifle_cooldown = 0.0
			_stop_reload_audio()
	if weapon.special_cooldown_refund_on_hit > 0.0:
		grenade_cooldown = maxf(0.0, grenade_cooldown - weapon.special_cooldown_refund_on_hit)
	if weapon.lifesteal > 0.0:
		var heal_amt := int(float(damage) * weapon.lifesteal)
		if heal_amt > 0:
			health = mini(get_max_health(), health + heal_amt)
	cooldowns_changed.emit()

@rpc("any_peer", "call_local", "reliable")
func apply_damage_over_time(total_damage: int, duration: float, from_id: int) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 1 and sender != 0:
		return
	if not is_multiplayer_authority():
		return
	if total_damage <= 0 or duration <= 0.0:
		return
	_poison_damage_left += float(total_damage)
	_poison_dps += float(total_damage) / duration
	_poison_from_id = from_id

@rpc("any_peer", "call_local", "reliable")
func apply_slow(multiplier: float, duration: float) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 1 and sender != 0:
		return
	if not is_multiplayer_authority():
		return
	_slow_mult = minf(_slow_mult, clampf(multiplier, 0.22, 1.0))
	_slow_timer = maxf(_slow_timer, duration)
	_sync_chill_visual.rpc(_slow_mult, _slow_timer)

@rpc("any_peer", "call_local", "reliable")
func _sync_chill_visual(slow_mult: float, timer: float) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 0 and sender != get_multiplayer_authority():
		return
	_chill_vfx_timer = timer
	_chill_vfx_strength = clampf(1.0 - slow_mult, 0.0, 1.0)
	_apply_chill_visual()

func _tick_status_effects(delta: float) -> void:
	if _dash_iframe_timer > 0.0:
		_dash_iframe_timer = maxf(0.0, _dash_iframe_timer - delta)
	if _slow_timer > 0.0:
		_slow_timer = maxf(0.0, _slow_timer - delta)
		if _slow_timer <= 0.0:
			_slow_mult = 1.0
			if is_multiplayer_authority():
				_sync_chill_visual.rpc(1.0, 0.0)
	if _chill_vfx_timer > 0.0:
		_chill_vfx_timer = maxf(0.0, _chill_vfx_timer - delta)
		if _chill_vfx_timer <= 0.0 and _chill_visual_active:
			_chill_vfx_strength = 0.0
			_apply_chill_visual()
	if _poison_damage_left <= 0.0 or _poison_dps <= 0.0:
		return
	_poison_tick_accum += delta
	if _poison_tick_accum < 0.25:
		return
	var tick_dt := _poison_tick_accum
	_poison_tick_accum = 0.0
	var amount := mini(int(ceil(_poison_dps * tick_dt)), int(ceil(_poison_damage_left)))
	if amount <= 0:
		return
	_poison_damage_left -= float(amount)
	if _poison_damage_left <= 0.0:
		_poison_dps = 0.0
	_apply_damage(amount, _poison_from_id)

func _player_from_hit_collider(collider: Node) -> Node:
	if collider == null:
		return null
	if collider.is_in_group("players"):
		return collider
	if collider.is_in_group("player_hitboxes"):
		var parent := collider.get_parent()
		if parent and parent.is_in_group("players"):
			return parent
	return null

func _is_head_hit(collider: Node) -> bool:
	return collider != null and collider.is_in_group("player_head_hitboxes")

func get_hitbox_rids() -> Array[RID]:
	var rids: Array[RID] = [get_rid()]
	for child in get_children():
		if child is CollisionObject3D and child.is_in_group("player_hitboxes"):
			rids.append(child.get_rid())
	return rids

func _spawn_bullet_blast(pos: Vector3, radius: float, color: Color, play_audio: bool = false) -> void:
	var scene: Node = get_tree().current_scene
	var lp: Node = scene.get("local_player") if scene else null
	var _t := Time.get_ticks_usec()
	Violence.spawn_bullet_blast(scene, pos, radius, color, lp, play_audio)
	Trace.prof("blast_vfx", Time.get_ticks_usec() - _t)

func apply_explosion_view_punch(pos: Vector3, radius: float, peak: float = 1.0) -> void:
	Violence.apply_explosion_view_punch(self, pos, radius, peak)

func _muzzle_flash_exit_local(anchor: Node3D) -> Vector3:
	if anchor == null:
		return Vector3(0.0, 0.0, -0.35)
	var pg: Node = anchor.get_node_or_null("ProceduralGun")
	if pg and pg.has_method("get_muzzle_exit_local"):
		return (pg as Node3D).position + pg.get_muzzle_exit_local()
	return Vector3(0.0, 0.0, -0.35)

func _spawn_muzzle_flash(
	color: Color = Color(1.0, 0.88, 0.45),
	scale_f: float = 1.0,
	anchor: Node3D = null,
	first_person: bool = true,
	brightness_mult: float = 1.0,
) -> void:
	if anchor == null:
		anchor = muzzle
	if anchor == null:
		return
	var bright: float = maxf(0.1, brightness_mult)
	var energy: float = 6.0 * pow(bright, 1.18)
	var light_energy: float = 2.75 * pow(bright, 1.12)
	var gun_light_energy: float = 1.6 * pow(bright, 1.08)
	var flash_pos: Vector3 = _muzzle_flash_exit_local(anchor)
	# Directional flash: a short starburst plus a forward flame plume reads
	# better than a glowing orb and stays cheap enough for multiplayer.
	var flash_root := Node3D.new()
	flash_root.position = flash_pos
	flash_root.rotation.z = randf_range(0.0, TAU)
	anchor.add_child(flash_root)

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(color.r, color.g, color.b, 0.96)
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = energy
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var cross_mesh := BoxMesh.new()
	cross_mesh.size = Vector3(0.04 * scale_f, 0.26 * scale_f, 0.04 * scale_f)
	for angle in [0.0, PI * 0.5]:
		var arm := MeshInstance3D.new()
		arm.mesh = cross_mesh
		arm.material_override = mat
		arm.rotation.z = angle
		flash_root.add_child(arm)

	var plume := MeshInstance3D.new()
	var plume_mesh := BoxMesh.new()
	plume_mesh.size = Vector3(0.07 * scale_f, 0.07 * scale_f, 0.34 * scale_f)
	plume.mesh = plume_mesh
	plume.material_override = mat
	plume.position = Vector3(0.0, 0.0, -0.18 * scale_f)
	flash_root.add_child(plume)

	var tw := flash_root.create_tween().set_parallel(true)
	tw.tween_property(flash_root, "scale", Vector3(1.35, 0.82, 1.8), 0.045)\
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.tween_property(flash_root, "position:z", flash_pos.z - 0.13 * scale_f, 0.045)\
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.tween_property(mat, "albedo_color", Color(1, 1, 1, 0.0), 0.06)
	tw.tween_property(mat, "emission_energy_multiplier", 0.0, 0.06)
	# Keep muzzle flashes bright even when the broader transient-light VFX
	# budget is disabled; this is a tiny, short-lived light and sells the shot.
	var light := OmniLight3D.new()
	light.light_color = color.lerp(Color(1.0, 0.95, 0.82), 0.45)
	light.light_energy = light_energy
	light.omni_range = 5.0 * scale_f * pow(bright, 0.55)
	light.shadow_enabled = false
	light.position = Vector3(0.0, 0.0, -0.42)
	flash_root.add_child(light)
	tw.tween_property(light, "light_energy", 0.0, 0.07)
	tw.chain().tween_callback(light.queue_free)

	# Small bounce light slightly behind the muzzle so the first-person weapon
	# itself catches a warm flash instead of staying flat during shots.
	var gun_light := OmniLight3D.new()
	gun_light.light_color = color.lerp(Color(1.0, 0.92, 0.8), 0.6)
	gun_light.light_energy = gun_light_energy
	gun_light.omni_range = 2.0 * scale_f * pow(bright, 0.5)
	gun_light.shadow_enabled = false
	gun_light.position = Vector3(0.0, 0.0, 0.06)
	anchor.add_child(gun_light)
	tw.tween_property(gun_light, "light_energy", 0.0, 0.08)
	tw.chain().tween_callback(gun_light.queue_free)
	tw.chain().tween_callback(flash_root.queue_free)

	if not first_person:
		var rest_pos := anchor.position
		anchor.position = rest_pos + Vector3(0.0, 0.0, 0.05 * scale_f)
		var kick_tw := create_tween()
		kick_tw.tween_property(anchor, "position", rest_pos, 0.08)\
			.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)

func clear_live_casings() -> void:
	if _procedural_gun and _procedural_gun.has_method("clear_live_casings"):
		_procedural_gun.clear_live_casings()


func _spawn_third_person_casing(w: Weapon) -> void:
	if BenchFlags.active and BenchFlags.no_casings:
		return
	if w.get_projectiles_per_second() >= HIGH_RATE_REMOTE_CASING_BPS:
		var now := Time.get_ticks_msec()
		if now - _last_high_rate_remote_casing_ms < HIGH_RATE_REMOTE_CASING_INTERVAL_MS:
			return
		_last_high_rate_remote_casing_ms = now
	var frame := Engine.get_physics_frames()
	if _third_person_casing_frame != frame:
		_third_person_casing_frame = frame
		_third_person_casing_count = 0
	if _third_person_casing_count >= MAX_THIRD_PERSON_CASINGS_PER_FRAME:
		return
	if _third_person_gun == null:
		return
	var scene := get_tree().current_scene
	if scene == null:
		return
	_third_person_casing_count += 1
	BenchFlags.inc("casings_spawned")
	var rb := RigidBody3D.new()
	rb.add_to_group("brass_casings")
	rb.mass = 0.018
	rb.collision_layer = 0
	rb.collision_mask = 1
	var pmat := PhysicsMaterial.new()
	pmat.bounce = 0.3
	pmat.friction = 0.6
	rb.physics_material_override = pmat

	var size := clampf(w.get_bullet_scale(), 0.65, 2.2)
	if not BenchFlags.active:
		var mi := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.035 * size
		cm.bottom_radius = 0.04 * size
		cm.height = 0.16 * size
		cm.radial_segments = 8
		mi.mesh = cm
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.95, 0.66, 0.28)
		mat.metallic = 0.9
		mat.roughness = 0.38
		mi.material_override = mat
		mi.rotation = Vector3(PI * 0.5, 0.0, 0.0)
		rb.add_child(mi)

	var cs := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 0.04 * size
	shape.height = 0.16 * size
	cs.shape = shape
	cs.rotation = Vector3(PI * 0.5, 0.0, 0.0)
	rb.add_child(cs)

	var basis: Basis
	var spawn_pos: Vector3
	if _third_person_procedural_gun and _third_person_procedural_gun.has_method("get_muzzle_exit_local"):
		var gt := _third_person_procedural_gun.global_transform
		basis = gt.basis
		spawn_pos = gt * _third_person_procedural_gun.get_muzzle_exit_local()
	else:
		basis = _third_person_gun.global_transform.basis
		spawn_pos = _third_person_gun.global_position + basis.x * 0.16 + basis.y * 0.08 + basis.z * -0.08
	rb.transform = Transform3D(basis, spawn_pos)
	scene.add_child(rb)

	var dir := (basis.x * 1.0 + basis.y * 1.3 + basis.z * 0.15).normalized()
	dir = (dir + Vector3(
		randf_range(-0.25, 0.25),
		randf_range(-0.1, 0.2),
		randf_range(-0.25, 0.25),
	)).normalized()
	rb.linear_velocity = dir * randf_range(2.3, 4.2)
	rb.angular_velocity = Vector3(
		randf_range(-10.0, 10.0),
		randf_range(-10.0, 10.0),
		randf_range(-10.0, 10.0),
	)
	# Cap the total live third-person casings (oldest retires past the cap) so a
	# sustained firefight can't pile up active rigid bodies.
	_enroll_tp_casing(rb)
	# Bind the casing's own queue_free: if the casing is freed earlier (round
	# reset clears the world), the timeout connection auto-disconnects instead
	# of firing a lambda whose captured `rb` was already freed.
	get_tree().create_timer(2.5).timeout.connect(rb.queue_free)

@rpc("any_peer", "call_local", "reliable")
func _hit_confirm(is_headshot: bool, dmg: int = 0, hit_pos: Vector3 = Vector3.INF) -> void:
	# Only accept from the server.
	var sender := multiplayer.get_remote_sender_id()
	if sender != 1 and sender != 0:
		return
	if is_bot:
		return  # bot has no HUD
	var g := get_tree().current_scene
	if g and g.has_method("show_hitmarker_for"):
		g.show_hitmarker_for(player_id, "head" if is_headshot else "body", dmg, hit_pos)
	elif g and g.has_method("show_hitmarker"):
		g.show_hitmarker("head" if is_headshot else "body", dmg, hit_pos)

@rpc("any_peer", "call_local", "reliable")
func confirm_kill() -> void:
	# Server tells the killer's client to pop a kill-colored hitmarker.
	var sender := multiplayer.get_remote_sender_id()
	if sender != 1 and sender != 0:
		return
	if not is_multiplayer_authority():
		return
	if is_bot:
		return
	var g := get_tree().current_scene
	if g and g.has_method("show_hitmarker_for"):
		g.show_hitmarker_for(player_id, "kill")
	elif g and g.has_method("show_hitmarker"):
		g.show_hitmarker("kill")

func _spawn_impact(pos: Vector3, color: Color = Color(1.0, 0.9, 0.3), scale_f: float = 1.0, dmg_ratio: float = 1.0, normal: Vector3 = Vector3.UP, explosive_radius: float = 0.0, collider: Node = null) -> void:
	Violence.spawn_impact(get_tree().current_scene, pos, color, scale_f, dmg_ratio, VFX_MAX_IMPACT_DUST, normal, explosive_radius, collider)

func _spawn_blood(pos: Vector3, dir: Vector3, dmg_ratio: float) -> void:
	Violence.spawn_blood(get_tree().current_scene, pos, dir, dmg_ratio, VFX_MAX_BLOOD_DROPS)

func _spawn_blood_wound(
	hit_pos: Vector3,
	normal: Vector3,
	dir: Vector3,
	collider: Node,
	strength: float,
) -> void:
	Violence.spawn_player_blood_wound(self, collider, hit_pos, normal, dir, strength)

func _spawn_laser_tracer(from: Vector3, to: Vector3, alpha: float = 1.0) -> void:
	Violence.spawn_laser_tracer(get_tree().current_scene, from, to, alpha)

# -------------------- RAGDOLL / DEATH --------------------

@rpc("any_peer", "call_local", "reliable")
func _ragdoll(
	push_dir: Vector3,
	force_origin: Vector3 = Vector3.INF,
	gib_force: float = 0.0,
	blast_radius: float = 0.0,
	blast_severity: float = 0.0,
	is_head: bool = false,
	overkill_disintegrate: bool = false,
	overkill_severity: float = 0.0,
) -> void:
	Violence.do_ragdoll(
		self, push_dir, force_origin, gib_force, blast_radius, blast_severity, is_head,
		overkill_disintegrate, overkill_severity,
	)


@rpc("any_peer", "call_local", "reliable")
func _lava_death(fall_death: bool) -> void:
	_ragdoll_head = null
	_lava_death_active = true
	_set_dead_visuals(true)
	if head_blob:
		head_blob.rotation = Vector3.ZERO
	if camera:
		camera.rotation.z = 0.0
	if body_model:
		body_model.visible = true
	var scene := get_tree().current_scene
	if is_multiplayer_authority() and not split_screen_local:
		if scene and scene.has_method("show_death_effect_for"):
			scene.show_death_effect_for(player_id, true)
		elif scene and scene.has_method("show_death_effect"):
			scene.show_death_effect(true)
	Violence.play_lava_death(self, fall_death)

# Hide the first-person gun mesh and turn off the hit areas so a corpse
# can't be shot or seen with a floating gun. Wrapper kept because the
# server_respawn() path also flips visuals back on.
func _set_dead_visuals(dead: bool) -> void:
	Violence.set_dead_visuals(self, dead)

@rpc("any_peer", "call_local", "reliable")
func clear_ragdoll() -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 1 and sender != 0:
		return
	Violence.clear_ragdoll(self)
	# Restore body visibility on every peer except the local authority
	# (their body stays hidden in first-person, same as normal).
	_apply_ghost_visuals()

# -------------------- SPECIAL (RMB) --------------------

const TELEPORT_RELOAD := 2.0
const TELEPORT_RANGE := 45.0
const TELEPORT_OFFSET := 0.8

func _use_special() -> void:
	if _air_strike_charges > 0:
		_air_strike_charges -= 1
		var mult: float = weapon.special_cooldown_mult
		grenade_cooldown = AIR_STRIKE_RELOAD * mult
		special_cooldown_max = grenade_cooldown
		if weapon.special_reload_amount > 0:
			mag = mini(weapon.get_mag_size(), mag + weapon.special_reload_amount)
			if mag > 0 and reloading:
				reloading = false
				rifle_cooldown = 0.0
				_stop_reload_audio()
		cooldowns_changed.emit()
		_call_air_strike()
		return
	var mult: float = weapon.special_cooldown_mult
	match weapon.special:
		Weapon.SPECIAL_TELEPORT:
			grenade_cooldown = TELEPORT_RELOAD * mult
		Weapon.SPECIAL_SWORD:
			grenade_cooldown = MELEE_RELOAD * mult
		Weapon.SPECIAL_AIR_STRIKE:
			grenade_cooldown = AIR_STRIKE_RELOAD * mult
		Weapon.SPECIAL_ION_CANNON:
			grenade_cooldown = ION_CANNON_RELOAD * mult
		Weapon.SPECIAL_CLUSTER_GRENADE:
			grenade_cooldown = CLUSTER_GRENADE_RELOAD * mult
		_:
			grenade_cooldown = GRENADE_RELOAD * mult
	# Snapshot for HUD progress display — _update_hud divides current cooldown
	# by this to render the fill bar.
	special_cooldown_max = grenade_cooldown
	if weapon.special_reload_amount > 0:
		mag = mini(weapon.get_mag_size(), mag + weapon.special_reload_amount)
		if mag > 0 and reloading:
			reloading = false
			rifle_cooldown = 0.0
			_stop_reload_audio()
	cooldowns_changed.emit()
	_activate_special_effect()
	for i in weapon.special_echo_count:
		var delay := 0.16 * float(i + 1)
		# Method connection (not a self-capturing lambda) so a player freed
		# before the echo fires auto-disconnects rather than erroring.
		get_tree().create_timer(delay).timeout.connect(_activate_special_echo)

func _activate_special_echo() -> void:
	if not ghost_mode and health > 0:
		_activate_special_effect()

func _activate_special_effect() -> void:
	match weapon.special:
		Weapon.SPECIAL_TELEPORT:
			_use_teleport()
		Weapon.SPECIAL_SWORD:
			_swing_melee()
		Weapon.SPECIAL_AIR_STRIKE:
			_call_air_strike()
		Weapon.SPECIAL_ION_CANNON:
			_call_ion_cannon()
		Weapon.SPECIAL_CLUSTER_GRENADE:
			_fire_cluster_grenade()
		Weapon.SPECIAL_GRENADE:
			_fire_grenade()
		_:
			_fire_grenade()

# -------------------- RELOAD --------------------

func _start_reload() -> void:
	if reloading:
		return
	if mag >= weapon.get_mag_size():
		return
	reloading = true
	var duration := weapon.get_reload_time()
	rifle_cooldown = duration
	_stop_reload_audio()
	_reload_started.rpc(duration)

@rpc("any_peer", "call_local", "reliable")
func _reload_started(duration: float) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 0 and sender != 1 and sender != get_multiplayer_authority():
		return
	var local_first_person := is_multiplayer_authority() and not is_bot
	if local_first_person:
		_animate_reload(duration)
		_stop_reload_audio()
		_reload_audio = SFX.reload(duration)
	else:
		_animate_third_person_reload(duration)
		_stop_reload_audio()
		var at := _third_person_gun.global_position if _third_person_gun else global_position
		_reload_audio = SFX.reload(duration, at)

func _stop_reload_audio() -> void:
	if _reload_audio and is_instance_valid(_reload_audio):
		_reload_audio.queue_free()
	_reload_audio = null

func _reset_weapon_combat_state() -> void:
	reloading = false
	rifle_cooldown = 0.0
	if _reload_tween and _reload_tween.is_valid():
		_reload_tween.kill()
		_reload_tween = null
	if _mag_reload_tween and _mag_reload_tween.is_valid():
		_mag_reload_tween.kill()
		_mag_reload_tween = null
	reload_offset = Vector3.ZERO
	if muzzle:
		muzzle.rotation.x = 0.0
	if _third_person_gun:
		_third_person_gun.position = _third_person_gun_rest_pos
		_third_person_gun.rotation = _third_person_gun_rest_rot
	if _procedural_gun:
		if _procedural_gun.has_method("reset_heat"):
			_procedural_gun.reset_heat()
		if _procedural_gun.has_method("apply_weapon_stats"):
			# Reload tweens can leave the magazine mid-drop; snap parts back.
			_procedural_gun.apply_weapon_stats(weapon)
	if _third_person_procedural_gun:
		if _third_person_procedural_gun.has_method("reset_heat"):
			_third_person_procedural_gun.reset_heat()
		_update_third_person_gun_visuals()
	_stop_reload_audio()
	if is_multiplayer_authority():
		cooldowns_changed.emit()

func _animate_reload(duration: float) -> void:
	if muzzle == null:
		return
	if _reload_tween and _reload_tween.is_valid():
		_reload_tween.kill()
	if _mag_reload_tween and _mag_reload_tween.is_valid():
		_mag_reload_tween.kill()
	reload_offset = Vector3.ZERO

	# Phased timeline (fractions of `duration`):
	#   0.00–0.18  gun rises + tilts back
	#   0.12–0.28  magazine drops out (overlaps with gun rise tail)
	#   0.28–0.45  gun sways right
	#   0.45–0.62  gun sways back to centre
	#   0.55–0.70  magazine slides back in (overlaps end of sway)
	#   0.70–0.92  gun lowers + levels out
	var gun_up := Vector3(0.0, 0.14, -0.02)
	var gun_up_right := gun_up + Vector3(0.06, 0.0, 0.0)
	var tilt_rad: float = deg_to_rad(22.0)

	_reload_tween = create_tween().set_parallel(true)
	# Rise + tilt.
	_reload_tween.tween_method(_set_reload_offset, Vector3.ZERO, gun_up, duration * 0.18) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_reload_tween.tween_property(muzzle, "rotation:x", tilt_rad, duration * 0.18) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	# Sway right.
	_reload_tween.tween_method(_set_reload_offset, gun_up, gun_up_right, duration * 0.17) \
		.set_delay(duration * 0.28).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	# Sway back to centre.
	_reload_tween.tween_method(_set_reload_offset, gun_up_right, gun_up, duration * 0.17) \
		.set_delay(duration * 0.45).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	# Lower + level out.
	_reload_tween.tween_method(_set_reload_offset, gun_up, Vector3.ZERO, duration * 0.22) \
		.set_delay(duration * 0.70).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_reload_tween.tween_property(muzzle, "rotation:x", 0.0, duration * 0.22) \
		.set_delay(duration * 0.70).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)

	# Magazine drop + return on its own timeline.
	var mag_node: Node3D = null
	if _procedural_gun:
		mag_node = _procedural_gun.get_node_or_null("Magazine") as Node3D
	if mag_node:
		var mag_rest_pos: Vector3 = mag_node.position
		var mag_drop: Vector3 = mag_rest_pos + Vector3(0, -1.2, 0)
		_mag_reload_tween = create_tween().set_parallel(true)
		_mag_reload_tween.tween_property(mag_node, "position", mag_drop, duration * 0.16) \
			.set_delay(duration * 0.12).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
		_mag_reload_tween.tween_property(mag_node, "position", mag_rest_pos, duration * 0.15) \
			.set_delay(duration * 0.55).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

func _set_reload_offset(v: Vector3) -> void:
	reload_offset = v

func _animate_third_person_reload(duration: float) -> void:
	if _third_person_gun == null:
		return
	_third_person_gun.position = _third_person_gun_rest_pos
	_third_person_gun.rotation = _third_person_gun_rest_rot
	var lift := _third_person_gun_rest_pos + Vector3(0.0, 0.1, 0.04)
	var tilt := _third_person_gun_rest_rot + Vector3(deg_to_rad(-22.0), deg_to_rad(10.0), deg_to_rad(7.0))
	if _reload_tween and _reload_tween.is_valid():
		_reload_tween.kill()
	_reload_tween = create_tween().set_parallel(true)
	_reload_tween.tween_property(_third_person_gun, "position", lift, duration * 0.22)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_reload_tween.tween_property(_third_person_gun, "rotation", tilt, duration * 0.22)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_reload_tween.tween_property(_third_person_gun, "position", _third_person_gun_rest_pos, duration * 0.24)\
		.set_delay(duration * 0.68).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	_reload_tween.tween_property(_third_person_gun, "rotation", _third_person_gun_rest_rot, duration * 0.24)\
		.set_delay(duration * 0.68).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)

# -------------------- TELEPORT --------------------

func _call_air_strike() -> void:
	var target := _air_strike_target()
	if multiplayer.is_server():
		_spawn_player_air_strike(target)
	else:
		_request_air_strike.rpc_id(1, target)


func _air_strike_target() -> Vector3:
	var origin: Vector3 = camera.global_position
	var dir: Vector3 = -camera.global_transform.basis.z
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * AIR_STRIKE_AIM_RANGE)
	q.collision_mask = 1 | 2
	q.collide_with_areas = true
	if has_method("get_hitbox_rids"):
		q.exclude = get_hitbox_rids()
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return origin + dir * AIR_STRIKE_AIM_RANGE
	return hit.get("position", origin) + Vector3.UP * 0.05


@rpc("any_peer", "reliable")
func _request_air_strike(target: Vector3) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = int(get_multiplayer_authority())
	if sender != int(get_multiplayer_authority()):
		return
	_spawn_player_air_strike(target)


func _spawn_player_air_strike(target: Vector3) -> void:
	var game := get_tree().current_scene
	if game and game.has_method("begin_player_air_strike"):
		game.begin_player_air_strike(target, player_id)


func _call_ion_cannon() -> void:
	var target := _air_strike_target()
	if multiplayer.is_server():
		_spawn_player_ion_cannon(target)
	else:
		_request_ion_cannon.rpc_id(1, target)


@rpc("any_peer", "reliable")
func _request_ion_cannon(target: Vector3) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = int(get_multiplayer_authority())
	if sender != int(get_multiplayer_authority()):
		return
	_spawn_player_ion_cannon(target)


func _spawn_player_ion_cannon(target: Vector3) -> void:
	var game := get_tree().current_scene
	if game and game.has_method("begin_player_ion_cannon"):
		game.begin_player_ion_cannon(target, player_id)


func _use_teleport() -> void:
	var origin: Vector3 = camera.global_position
	var dir: Vector3 = -camera.global_transform.basis.z
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * TELEPORT_RANGE)
	q.collision_mask = 1  # world only
	q.exclude = get_hitbox_rids() if has_method("get_hitbox_rids") else [get_rid()]
	var result := space.intersect_ray(q)
	var target: Vector3
	if result.is_empty():
		target = origin + dir * TELEPORT_RANGE
	else:
		target = result.position + result.normal * TELEPORT_OFFSET
	var from: Vector3 = global_position
	_teleport_fx.rpc(from, target)
	global_position = target
	reset_physics_interpolation()  # hard jump — don't smear across one frame
	velocity = Vector3.ZERO
	if weapon.teleport_blast_radius > 0.0:
		_request_special_blast.rpc_id(1, from, weapon.teleport_blast_radius, 55.0, player_id, weapon.bullet_color)
		_request_special_blast.rpc_id(1, target, weapon.teleport_blast_radius, 55.0, player_id, weapon.bullet_color)
	_last_sync_pitch = look_pitch
	_broadcast_state.rpc(global_position, rotation.y, look_pitch)
	_last_sync_pos = global_position
	_last_sync_yaw = rotation.y

@rpc("authority", "call_local", "reliable")
func _teleport_fx(from_pos: Vector3, to_pos: Vector3) -> void:
	_spawn_teleport_vfx(from_pos)
	_spawn_teleport_vfx(to_pos)

func _spawn_teleport_vfx(pos: Vector3) -> void:
	var scene := get_tree().current_scene
	var mesh := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.6
	sphere.height = 1.2
	sphere.radial_segments = 8
	sphere.rings = 4
	mesh.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.7, 0.3, 1.0, 0.6)
	mat.emission_enabled = true
	mat.emission = Color(0.7, 0.3, 1.0)
	mat.emission_energy_multiplier = 6.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.material_override = mat
	mesh.position = pos
	scene.add_child(mesh)
	var tw := mesh.create_tween().set_parallel(true)
	tw.tween_property(mesh, "scale", Vector3.ONE * 3.0, 0.3)\
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.tween_property(mat, "albedo_color", Color(0.7, 0.3, 1.0, 0.0), 0.35)
	tw.tween_property(mat, "emission_energy_multiplier", 0.0, 0.35)
	tw.chain().tween_callback(mesh.queue_free)
	if VFX_TRANSIENT_LIGHTS:
		var light := OmniLight3D.new()
		light.light_color = Color(0.7, 0.3, 1.0)
		light.light_energy = 5.0
		light.omni_range = 4.0
		light.position = pos
		scene.add_child(light)
		var ltw := light.create_tween()
		ltw.tween_property(light, "light_energy", 0.0, 0.3)
		ltw.tween_callback(light.queue_free)

@rpc("any_peer", "call_local", "reliable")
func _request_special_blast(pos: Vector3, radius: float, damage: float, shooter_id: int, color: Color) -> void:
	if not multiplayer.is_server():
		return
	if multiplayer.get_remote_sender_id() != 0 and multiplayer.get_remote_sender_id() != shooter_id:
		return
	_spawn_bullet_blast(pos, radius, color, true)
	_apply_bullet_splash(pos + Vector3.UP * 0.1, radius, damage, shooter_id)

# -------------------- GRENADE --------------------

func _fire_grenade() -> void:
	_fire_grenade_internal(false)


func _fire_cluster_grenade() -> void:
	_fire_grenade_internal(true)


func _fire_grenade_internal(cluster: bool) -> void:
	var origin: Vector3 = muzzle.global_position
	var dir: Vector3 = -camera.global_transform.basis.z
	if multiplayer.is_server():
		var prefix := "C" if cluster else "G"
		var uname := "%s_%d_%d" % [prefix, player_id, Time.get_ticks_usec()]
		_spawn_grenade.rpc(origin, dir, player_id, uname, cluster)
	else:
		var prefix := "C" if cluster else "G"
		var uname := "%s_%d_%d" % [prefix, player_id, Time.get_ticks_usec()]
		_spawn_predicted_grenade(origin, dir, player_id, uname, cluster)
		_request_grenade.rpc_id(1, origin, dir, uname, cluster)

@rpc("any_peer", "reliable")
func _request_grenade(origin: Vector3, dir: Vector3, uname: String, cluster: bool = false) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = player_id
	var expected_prefix := ("C" if cluster else "G") + "_%d_" % sender
	if not uname.begins_with(expected_prefix):
		var prefix := "C" if cluster else "G"
		uname = "%s_%d_%d" % [prefix, sender, Time.get_ticks_usec()]
	_spawn_grenade.rpc(origin, dir, sender, uname, cluster)

@rpc("any_peer", "call_local", "reliable")
func _spawn_grenade(origin: Vector3, dir: Vector3, shooter: int, uname: String, cluster: bool = false) -> void:
	# Only the server may authorize grenade spawns.
	var sender := multiplayer.get_remote_sender_id()
	if sender != 0 and sender != 1:
		return
	var parent := get_tree().current_scene
	var existing := parent.get_node_or_null(uname) if parent else null
	if existing:
		if "predicted_visual" in existing:
			existing.predicted_visual = false
		return
	SFX.grenade_launch(origin)
	_spawn_grenade_visual(origin, dir, shooter, uname, false, cluster)

func _spawn_predicted_grenade(origin: Vector3, dir: Vector3, shooter: int, uname: String, cluster: bool = false) -> void:
	SFX.grenade_launch(origin)
	_spawn_grenade_visual(origin, dir, shooter, uname, true, cluster)

func _spawn_grenade_visual(origin: Vector3, dir: Vector3, shooter: int, uname: String, predicted: bool, cluster: bool = false) -> void:
	var scene: PackedScene = GRENADE_SCENE
	var g := scene.instantiate()
	g.name = uname
	g.shooter_id = shooter
	if cluster:
		g.is_cluster_parent = true
	if "predicted_visual" in g:
		g.predicted_visual = predicted
	get_tree().current_scene.add_child(g)
	g.global_position = origin + dir * 0.6
	g.linear_velocity = dir * GRENADE_LAUNCH_SPEED + Vector3(0.0, GRENADE_LAUNCH_LIFT, 0.0)

func _place_mine() -> void:
	var pos := _mine_position()
	if multiplayer.is_server():
		var uname := "M_%d_%d" % [player_id, Time.get_ticks_usec()]
		_spawn_mine.rpc(pos, player_id, uname)
	else:
		_request_mine.rpc_id(1, pos)

func _mine_position() -> Vector3:
	var start := global_position + Vector3.UP * 0.6 - global_transform.basis.z * MINE_FORWARD_OFFSET
	var end := start + Vector3.DOWN * 3.0
	var q := PhysicsRayQueryParameters3D.create(start, end)
	q.collision_mask = 1
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return start + Vector3.DOWN * 0.6
	return Vector3(hit.position.x, hit.position.y + 0.12, hit.position.z)

@rpc("any_peer", "reliable")
func _request_mine(pos: Vector3) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = player_id
	var p := _sibling_player(sender)
	if p == null or p.get("ghost_mode") != true:
		return
	var uname := "M_%d_%d" % [sender, Time.get_ticks_usec()]
	_spawn_mine.rpc(pos, sender, uname)

@rpc("any_peer", "call_local", "reliable")
func _spawn_mine(pos: Vector3, shooter: int, uname: String) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 0 and sender != 1:
		return
	var scene: PackedScene = GRENADE_SCENE
	var g := scene.instantiate()
	g.name = uname
	g.shooter_id = shooter
	g.is_mine = true
	get_tree().current_scene.add_child(g)
	g.global_position = pos
	g.freeze = true
	g.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	g.scale = Vector3(1.35, 0.35, 1.35)
	var mesh := g.get_node_or_null("Mesh")
	if mesh is MeshInstance3D:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.05, 0.35, 0.32, 0.78)
		mat.emission_enabled = true
		mat.emission = Color(0.0, 0.9, 0.75)
		mat.emission_energy_multiplier = 0.45
		(mesh as MeshInstance3D).material_override = mat

	var shooter_node: Node3D = _sibling_player(shooter)
	if shooter_node == null or shooter_node.get("ghost_mode") != true:
		SFX.mine_plant(pos)

func _spawn_impact_mine(pos: Vector3, shooter: int) -> void:
	if not multiplayer.is_server():
		return
	var uname := "IM_%d_%d" % [shooter, Time.get_ticks_usec()]
	_spawn_mine.rpc(pos, shooter, uname)

# -------------------- MELEE --------------------

func _swing_melee() -> void:
	var origin: Vector3 = camera.global_position
	var dir: Vector3 = -camera.global_transform.basis.z
	_melee_swung.rpc(origin, dir, player_id)

@rpc("any_peer", "call_local", "reliable")
func _melee_swung(origin: Vector3, dir: Vector3, attacker_id: int, damage_mult: float = 1.0, range_mult: float = 1.0) -> void:
	var shooter_node := _sibling_player(attacker_id)
	var w: Weapon = shooter_node.weapon if shooter_node else Weapon.new()

	SFX.melee(origin, int(float(w.get_melee_damage()) * damage_mult))
	# Gun swing + blade trail play on every peer.
	_animate_gun_slash(w.melee_scale * range_mult)
	_spawn_slice_trail(origin, dir, w.melee_scale * range_mult)
	# Camera shake only for the attacker.
	if is_multiplayer_authority():
		shake_amt = max(shake_amt, 0.035 * w.melee_scale)
	# Only the server runs hit detection.
	if not multiplayer.is_server():
		return
	var space := get_world_3d().direct_space_state
	var dir_n: Vector3 = dir.normalized()
	var swing_range: float = MELEE_RANGE * w.melee_scale * range_mult
	var swing_radius: float = 1.2 * w.melee_scale * range_mult

	# Forward-pointing capsule (width = swing_radius, length = swing_range).
	# Capsule is wider than a ray so close-range hugs land, and long enough
	# to keep the same reach as the old raycast. Bottom rounded cap sits at
	# the attacker's chest — no rearward coverage.
	var cap := CapsuleShape3D.new()
	cap.radius = swing_radius
	cap.height = maxf(swing_range, swing_radius * 2.5)

	# Build a basis whose +Y aligns with dir (Godot capsules extend along Y).
	var ref: Vector3 = Vector3.RIGHT if absf(dir_n.dot(Vector3.UP)) > 0.95 else Vector3.UP
	var right: Vector3 = ref.cross(dir_n).normalized()
	var fwd_axis: Vector3 = dir_n.cross(right).normalized()
	var sw_basis: Basis = Basis(right, dir_n, fwd_axis)
	var center: Vector3 = origin + dir_n * (cap.height * 0.5)

	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = cap
	q.transform = Transform3D(sw_basis, center)
	q.collision_mask = 2  # player_hitboxes layer
	q.collide_with_areas = true
	q.collide_with_bodies = false
	if shooter_node:
		if shooter_node.has_method("get_hitbox_rids"):
			q.exclude = shooter_node.get_hitbox_rids()
		else:
			q.exclude = [shooter_node.get_rid()]

	var hits: Array = space.intersect_shape(q, 16)
	# Dedupe by player — head/torso/legs hitboxes for the same player would
	# otherwise show up as 3 separate hits.
	var hit_targets: Dictionary = {}
	var game_scene := get_tree().current_scene
	for hit in hits:
		var collider: Node = hit.get("collider")
		var target := _player_from_hit_collider(collider)
		if target == null or hit_targets.has(target.player_id):
			continue
		if target.get("ghost_mode") == true:
			continue
		if target.player_id == attacker_id:
			continue
		if game_scene and game_scene.has_method("should_block_player_damage") \
				and game_scene.should_block_player_damage(target.player_id, attacker_id):
			continue
		# Line-of-sight gate: don't slash through walls.
		var los_q := PhysicsRayQueryParameters3D.create(origin, target.global_position + Vector3.UP * 0.6)
		los_q.collision_mask = 1
		if shooter_node:
			los_q.exclude = [shooter_node.get_rid()]
		if not space.intersect_ray(los_q).is_empty():
			continue
		hit_targets[target.player_id] = target

	if hit_targets.is_empty():
		return

	for raw_pid in hit_targets:
		var target: Node3D = hit_targets[raw_pid]
		var hit_pos: Vector3 = target.global_position + Vector3.UP * 0.6
		var v_fwd: Vector3 = -target.global_transform.basis.z
		var backstab: bool = v_fwd.dot(dir_n) > 0.4
		var dmg: int
		if backstab and damage_mult >= 0.99:
			dmg = MELEE_BACKSTAB
		else:
			var base := float(w.get_melee_damage()) * damage_mult
			if backstab:
				base *= 2.0
			dmg = int(base)
		var kb_mag := w.get_knockback_force(float(dmg))
		target.take_damage.rpc_id(
			target.get_multiplayer_authority(),
			dmg,
			attacker_id,
			hit_pos,
			dir_n,
			kb_mag,
			0.0
		)
		if kb_mag > 0.0:
			var melee_impulse: Vector3 = dir_n * kb_mag + Vector3.UP * kb_mag * 0.25
			target.apply_knockback.rpc_id(target.get_multiplayer_authority(), melee_impulse)
		if shooter_node:
			_hit_confirm.rpc_id(shooter_node.get_multiplayer_authority(), backstab, dmg, hit_pos)
			if shooter_node.has_method("_on_dealt_damage"):
				shooter_node._on_dealt_damage.rpc_id(shooter_node.get_multiplayer_authority(), dmg)

func _animate_gun_slash(m_scale: float = 1.0) -> void:
	if muzzle == null:
		return
	if _melee_tween and _melee_tween.is_valid():
		_melee_tween.kill()
	# Reset starting pose so repeated slashes always begin from rest.
	muzzle.rotation = Vector3.ZERO
	melee_offset = Vector3.ZERO
	# End-of-slash pose: the blade has swept diagonally across the view, down-and-left,
	# the gun has lunged slightly forward. Rotation + translation together give the
	# blade a large visible path (pure rotation around the muzzle pivot is too tight).
	var slash_rot := Vector3(-0.45, 0.15, -1.25)         # pitch down, slight yaw, hard left roll
	var slash_pos := Vector3(-0.28, -0.16, -0.2) * m_scale # shove gun left+down+forward
	_melee_tween = create_tween().set_parallel(true)
	# STRIKE (0.045 s): rest → slash end. EXPO ease-IN peaks velocity at contact.
	_melee_tween.tween_property(muzzle, "rotation", slash_rot, 0.045)\
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_IN)
	_melee_tween.tween_method(_set_melee_offset, Vector3.ZERO, slash_pos, 0.045)\
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_IN)
	# RECOVERY (0.12 s): slash end → rest. Smooth follow-through.
	_melee_tween.chain().set_parallel(true)
	_melee_tween.tween_property(muzzle, "rotation", Vector3.ZERO, 0.12)\
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_melee_tween.tween_method(_set_melee_offset, slash_pos, Vector3.ZERO, 0.12)\
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)

func _set_melee_offset(v: Vector3) -> void:
	melee_offset = v

func _spawn_slice_trail(origin: Vector3, dir: Vector3, m_scale: float = 1.0) -> void:
	# A bright emissive bar placed in world-space along the diagonal arc the
	# blade sweeps through. Grows outward on X (length) to suggest speed, then
	# fades out. Visible to every peer because it lives in the world.
	var trail := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(2.4 * m_scale, 0.07 * m_scale, 0.04 * m_scale)
	trail.mesh = box
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.9, 0.95, 1.0, 0.95)
	mat.emission_enabled = true
	mat.emission = Color(0.75, 0.9, 1.0)
	mat.emission_energy_multiplier = 6.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	trail.material_override = mat

	var light: OmniLight3D = null
	if VFX_TRANSIENT_LIGHTS:
		light = OmniLight3D.new()
		light.light_color = Color(0.75, 0.9, 1.0)
		light.light_energy = 3.5 * m_scale
		light.omni_range = 5.0 * m_scale
		trail.add_child(light)

	get_tree().current_scene.add_child(trail)
	trail.global_position = origin + dir * 1.6 * m_scale
	trail.look_at(origin, Vector3.UP)
	# Tilt the bar along a top-right → bottom-left diagonal (matches the gun swing).
	trail.rotate_object_local(Vector3.FORWARD, deg_to_rad(-55.0))
	trail.scale = Vector3(0.2, 1.0, 1.0)

	var tw := trail.create_tween().set_parallel(true)
	# Bar shoots to full length during the strike (~45 ms) then fades out fast.
	tw.tween_property(trail, "scale", Vector3(1.35, 1.0, 1.0), 0.045)\
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.tween_property(mat, "albedo_color", Color(1, 1, 1, 0.0), 0.07).set_delay(0.02)
	tw.tween_property(mat, "emission_energy_multiplier", 0.0, 0.07).set_delay(0.02)
	if light:
		tw.tween_property(light, "light_energy", 0.0, 0.06)
	tw.chain().tween_callback(trail.queue_free)

# -------------------- DAMAGE / DEATH --------------------

@rpc("any_peer", "call_local", "reliable")
func take_damage(
	amount: int,
	from_id: int,
	force_origin: Vector3 = Vector3.INF,
	hit_dir: Vector3 = Vector3.ZERO,
	gib_force: float = 0.0,
	blast_radius: float = 0.0,
	blast_severity: float = 0.0,
	is_head: bool = false,
) -> void:
	if not is_multiplayer_authority():
		return
	_apply_damage(amount, from_id, force_origin, hit_dir, gib_force, blast_radius, blast_severity, is_head)

func _apply_damage(
	amount: int,
	from_id: int,
	force_origin: Vector3 = Vector3.INF,
	hit_dir: Vector3 = Vector3.ZERO,
	gib_force: float = 0.0,
	blast_radius: float = 0.0,
	blast_severity: float = 0.0,
	is_head: bool = false,
) -> void:
	if ghost_mode or coop_downed or frozen or health <= 0 or god_mode or _phoenix_ascending:
		return
	if _hell_emerging and not is_bot:
		return
	var game_scene := get_tree().current_scene
	if from_id != player_id and game_scene and game_scene.has_method("should_block_player_damage") \
			and game_scene.should_block_player_damage(player_id, from_id):
		return
	if _dash_iframe_timer > 0.0:
		return
	var new_health := health - amount
	var overkill_disintegrate := new_health <= Violence.OVERKILL_DISINTEGRATE_HEALTH
	var overkill_severity := 0.0
	if overkill_disintegrate:
		overkill_severity = clampf(float(-new_health - Violence.OVERKILL_DISINTEGRATE_HEALTH) / 50.0, 0.4, 2.5)
	health = maxi(0, new_health)
	if game_scene and game_scene.has_method("_report_player_damage"):
		if multiplayer.is_server():
			game_scene._report_player_damage(player_id, from_id, amount, health)
		else:
			game_scene._report_player_damage.rpc_id(1, player_id, from_id, amount, health)
	_show_hit_face.rpc(HIT_FACE_DURATION)
	if from_id != player_id and not is_bot:
		_notify_damage_source(from_id)
		# Scale feedback by damage so a 1hp poison tick is a whisper and a
		# 50hp shotgun hit slams the camera. 25 is "normal hit" — feels like
		# the current pre-scaling response.
		var hit_intensity: float = clampf(float(amount) / 25.0, 0.04, 2.0)
		SFX.hit_received(hit_intensity)

		# View punch: shift camera in the direction of the hit, scaled by
		# the same intensity so poison ticks stop yanking the camera.
		var attacker := _sibling_player(from_id)
		if attacker and is_multiplayer_authority():
			var attacker_hit_dir: Vector3 = (attacker.global_position - global_position).normalized()
			# Transform world hit dir to local space
			var local_dir: Vector3 = global_transform.basis.inverse() * attacker_hit_dir
			# Punch camera away from hit
			_view_punch_pos = -local_dir * 0.15 * hit_intensity
			# Add some random rotational kick
			var rot_kick: float = 0.1 * hit_intensity
			_view_punch_rot = Vector3(
				randf_range(-rot_kick, rot_kick),
				randf_range(-rot_kick, rot_kick),
				randf_range(-rot_kick, rot_kick),
			)
	if health <= 0 and _phoenix_charges_left > 0:
		_phoenix_charges_left -= 1
		var fx_pos: Vector3 = global_position
		var game := get_tree().current_scene
		if game and game.has_method("execute_phoenix_revive"):
			if multiplayer.is_server():
				game.execute_phoenix_revive(player_id, fx_pos)
			else:
				game.execute_phoenix_revive.rpc_id(1, player_id, fx_pos)
		return
	if health <= 0 and not is_bot:
		var suppress_death_sound := _suppress_next_death_sound
		var suppress_death_ragdoll := _suppress_next_death_ragdoll
		_suppress_next_death_sound = false
		_suppress_next_death_ragdoll = false
		if game_scene and game_scene.has_method("is_coop_mode") and game_scene.is_coop_mode():
			if multiplayer.is_server():
				if game_scene.handle_coop_human_death(
					player_id,
					global_position,
					from_id,
					force_origin,
					hit_dir,
					gib_force,
					blast_radius,
					blast_severity,
					is_head,
					suppress_death_sound,
					suppress_death_ragdoll,
				):
					return
			else:
				game_scene.request_coop_human_death.rpc_id(
					1,
					player_id,
					global_position,
					from_id,
					force_origin,
					hit_dir,
					gib_force,
					blast_radius,
					blast_severity,
					is_head,
					suppress_death_sound,
					suppress_death_ragdoll,
				)
				return
		_execute_lethal_death(
			from_id,
			force_origin,
			hit_dir,
			gib_force,
			blast_radius,
			blast_severity,
			is_head,
			suppress_death_sound,
			suppress_death_ragdoll,
			overkill_disintegrate,
			overkill_severity,
		)
		return
	if health > 0:
		_play_hurt_sound.rpc(global_position)
		return
	var suppress_death_sound := _suppress_next_death_sound
	var suppress_death_ragdoll := _suppress_next_death_ragdoll
	_suppress_next_death_sound = false
	_suppress_next_death_ragdoll = false
	_execute_lethal_death(
		from_id,
		force_origin,
		hit_dir,
		gib_force,
		blast_radius,
		blast_severity,
		is_head,
		suppress_death_sound,
		suppress_death_ragdoll,
		overkill_disintegrate,
		overkill_severity,
	)


func _execute_lethal_death(
	killer_id: int,
	force_origin: Vector3,
	hit_dir: Vector3,
	gib_force: float,
	blast_radius: float,
	blast_severity: float,
	is_head: bool,
	suppress_death_sound: bool,
	suppress_death_ragdoll: bool,
	overkill_disintegrate: bool,
	overkill_severity: float,
) -> void:
	if not suppress_death_sound:
		_play_death_sound.rpc(global_position)
	if _hell_emerging:
		_abort_hell_emerge()
	if is_bot:
		_bot_target = null
		_bot_shoot_cooldown = 999.0
		velocity = Vector3.ZERO
	var push: Vector3 = Vector3.UP
	var kb_mag := gib_force
	if kb_mag <= 0.0:
		var kb_damage := 25.0
		kb_mag = Weapon.knockback_from_damage(kb_damage)
	var launch := clampf(kb_mag / Weapon.REFERENCE_KNOCKBACK, 0.15, 8.0)
	if hit_dir.length_squared() > 0.001:
		push = hit_dir.normalized()
		if push.y < 0.15:
			push.y = 0.15
	var killer := _sibling_player(killer_id)
	if killer and killer is Node3D and hit_dir.length_squared() <= 0.001:
		push = (global_position - killer.global_position).normalized() + Vector3.UP * 0.6
	var launch_max := 8.0
	var upward_bias := 0.25
	var upward_scale := 0.12
	if blast_radius > 0.0:
		launch_max = 4.0
		upward_bias = 0.16
		upward_scale = 0.06
	launch = clampf(launch, 0.15, launch_max)
	push = push.normalized() * launch + Vector3.UP * (upward_bias + upward_scale * launch)
	if _pending_lava_death:
		var fall_death: bool = _pending_lava_death_fall
		_pending_lava_death = false
		_pending_lava_death_fall = false
		_lava_death.rpc(fall_death)
	elif suppress_death_ragdoll:
		_lava_death.rpc(true)
	else:
		_ragdoll.rpc(
			push,
			force_origin,
			kb_mag,
			blast_radius,
			blast_severity,
			is_head,
			overkill_disintegrate,
			overkill_severity,
		)
	died.emit(killer_id)
	_report_death.rpc_id(1, killer_id)


@rpc("authority", "call_local", "reliable")
func _execute_lethal_death_rpc(
	killer_id: int,
	force_origin: Vector3,
	hit_dir: Vector3,
	gib_force: float,
	blast_radius: float,
	blast_severity: float,
	is_head: bool,
	suppress_death_sound: bool,
	suppress_death_ragdoll: bool,
) -> void:
	_execute_lethal_death(
		killer_id,
		force_origin,
		hit_dir,
		gib_force,
		blast_radius,
		blast_severity,
		is_head,
		suppress_death_sound,
		suppress_death_ragdoll,
		false,
		0.0,
	)

@rpc("any_peer", "call_local", "unreliable")
func _play_hurt_sound(pos: Vector3) -> void:
	# `is_self` = this peer owns the player who got hit. Their copy plays a
	# quieter 2D variant; everyone else hears the spatial 3D version.
	SFX.hurt(pos, is_multiplayer_authority() and not is_bot)
	CrowdAudio.on_player_hurt(pos)

@rpc("any_peer", "call_local", "unreliable")
func _play_death_sound(pos: Vector3) -> void:
	SFX.death(pos, is_multiplayer_authority() and not is_bot)
	CrowdAudio.on_player_death(pos)


@rpc("any_peer", "call_local", "unreliable")
func _play_lava_sizzle(pos: Vector3, fall_death: bool = false) -> void:
	SFX.lava_sizzle(pos, fall_death)

@rpc("any_peer", "call_local", "reliable")
func apply_knockback(impulse: Vector3) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 1 and sender != 0:
		return
	Violence.apply_knockback(self, impulse)

func _notify_damage_source(from_id: int) -> void:
	var attacker := _sibling_player(from_id)
	if not attacker:
		return
	var g := get_tree().current_scene
	if g and g.has_method("show_damage_direction_for"):
		g.show_damage_direction_for(player_id, attacker.global_position)
	elif g and g.has_method("show_damage_direction"):
		g.show_damage_direction(attacker.global_position)

@rpc("any_peer", "call_local", "reliable")
func _report_death(killer_id: int) -> void:
	# Server-side: tell the game controller the round ended. Respawn is handled
	# by the game controller at the start of the next round (after card pick).
	# The RPC is invoked on the victim's Player node, so `player_id` IS the
	# victim. Using get_remote_sender_id() here misidentifies server-hosted
	# bot deaths as a self-kill by the host (sender=1 for server-to-self RPCs).
	if not multiplayer.is_server():
		return
	var game := get_tree().current_scene
	if game and game.has_method("report_kill"):
		game.report_kill(killer_id, player_id)

@rpc("any_peer", "call_local", "reliable")
func server_respawn(pos: Vector3, yaw: float = 0.0) -> void:
	if multiplayer.get_remote_sender_id() != 1 and multiplayer.get_remote_sender_id() != 0:
		return
	Violence.end_lava_death(self)
	Violence.clear_ragdoll(self)
	_lava_death_active = false
	_phoenix_ascending = false
	_coop_phoenix_held = false
	_phoenix_finish_requested = false
	_phoenix_start_ms = 0
	_phoenix_start_pos = Vector3.ZERO
	_clear_phoenix_fx()
	_hell_emerging = false
	_hell_emerge_finished = false
	_hell_emerge_elapsed = 0.0
	_hell_emerge_start_ms = 0
	_clear_hell_emerge_fx()
	launching = false
	_stop_rocket_descent_audio()
	_reset_weapon_combat_state()
	global_position = pos
	rotation.y = yaw
	_visual_prev_pos = pos
	_remote_target_pos = pos
	_remote_target_yaw = yaw
	_remote_has_target = true
	ghost_mode = false
	coop_downed = false
	_clear_coop_down_marker()
	frozen = false
	if not is_multiplayer_authority():
		_apply_ghost_visuals()
		return
	velocity = Vector3.ZERO
	health = MAX_HEALTH + weapon.max_hp_bonus
	_phoenix_charges_left = weapon.phoenix_revives
	_poison_damage_left = 0.0
	_poison_dps = 0.0
	_poison_tick_accum = 0.0
	_slow_timer = 0.0
	_slow_mult = 1.0
	_clear_chill_visual()
	grenade_cooldown = 0.0
	melee_cooldown = 0.0
	wall_jump_cooldown = 0.0
	# Bots get their fire cooldown clamped to 999s on death so a corpse can't
	# shoot during the death animation; without resetting it here, the same
	# bot node is "frozen" silent for the rest of the match after its first
	# kill.
	_bot_shoot_cooldown = 0.0
	mag = weapon.get_mag_size()
	dash_charges = MAX_DASH_CHARGES
	dash_timer = 0.0
	_dash_iframe_timer = 0.0
	_dash_iframe_visual_timer = 0.0
	_clear_dash_iframe_visual()
	jumps_left = 2 + weapon.extra_jumps
	_hit_face_timer = 0.0
	_set_hit_face_state(false)

	_ragdoll_head = null
	camera.transform = Transform3D(Basis.IDENTITY, _camera_rest_pos)
	var scene := get_tree().current_scene
	if scene and scene.has_method("show_death_effect_for"):
		scene.show_death_effect_for(player_id, false)
	elif scene and scene.has_method("show_death_effect"):
		scene.show_death_effect(false)

	_apply_ghost_visuals()
	_restore_weapon_visuals()
	# Push the teleport to every peer immediately so they don't see us at the
	# old position for a frame while waiting for the next _physics_process.
	_broadcast_state.rpc(global_position, rotation.y, look_pitch)
	_last_sync_pos = global_position
	_last_sync_yaw = rotation.y
	_last_sync_pitch = look_pitch


@rpc("any_peer", "call_local", "reliable")
func set_spawn_health(amount: int) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 1 and sender != 0:
		return
	if not is_multiplayer_authority():
		return
	health = maxi(1, amount)


static func _apply_coop_archetype_body(archetype: String, w: Weapon) -> void:
	w.body_scale = 1.0
	w.body_scale_axes = Vector3.ONE
	w.head_scale = 1.0
	match archetype:
		"sniper":
			w.body_scale = 0.92
			# 2.4x turned the humanoid rig into a featureless pole — the
			# softer stretch keeps "tall marksman" readable as a person.
			w.body_scale_axes *= Vector3(0.75, 1.6, 0.75)
		"grenadier":
			w.body_scale = 1.28
		"flat_fragger":
			w.body_scale = 0.86
			w.body_scale_axes *= Vector3(0.65, 1.0, 1.45)
		"demolition":
			w.body_scale = 1.08
		_:
			w.body_scale = 0.78
			w.head_scale = 0.9


static func coop_enemy_body_footprint(archetype: String) -> float:
	var w := Weapon.new()
	_apply_coop_archetype_body(archetype, w)
	return maxf(w.body_scale * w.body_scale_axes.x, w.body_scale * w.body_scale_axes.z)


static func coop_enemy_body_height_scale(archetype: String) -> float:
	var w := Weapon.new()
	_apply_coop_archetype_body(archetype, w)
	return w.body_scale * w.body_scale_axes.y


static func coop_enemy_pentagram_star_radius(archetype: String) -> float:
	return clampf(1.05 * coop_enemy_body_footprint(archetype), 0.48, 2.05)


static func coop_enemy_pentagram_beam_height(archetype: String) -> float:
	return clampf(Violence.PENTAGRAM_BEAM_HEIGHT * coop_enemy_body_height_scale(archetype), 10.0, 48.0)


static func coop_enemy_hell_emerge_half_height(archetype: String) -> float:
	return HELL_CAPSULE_HEIGHT * 0.5 * coop_enemy_body_height_scale(archetype)


static func coop_enemy_hell_emerge_depth(archetype: String) -> float:
	return HELL_CAPSULE_HEIGHT * coop_enemy_body_height_scale(archetype) + HELL_EMERGE_BURIAL_EXTRA


func _hell_emerge_half_height() -> float:
	return HELL_CAPSULE_HEIGHT * 0.5 * maxf(0.1, weapon.body_scale) * maxf(0.1, weapon.body_scale_axes.y)


func _hell_emerge_burial_depth() -> float:
	return HELL_CAPSULE_HEIGHT * maxf(0.1, weapon.body_scale) * maxf(0.1, weapon.body_scale_axes.y) + HELL_EMERGE_BURIAL_EXTRA


# Wave-enemy skins: each archetype wears a fixed roster model so the threat
# reads at a glance (the horde is zombies, the tall marksman is the paladin).
# ch10 pulls double duty at very different silhouettes (1.28x bulk vs
# flattened) — 5 archetypes, 4 models.
const COOP_ARCHETYPE_VARIANTS := {
	"grunt": 2,         # ch10 — the shambling zombie horde
	"sniper": 1,        # paladin — tall marksman
	"grenadier": 2,     # ch10, scaled up to 1.28x bulk
	"flat_fragger": 0,  # knight, squashed wide
	"demolition": 0,    # knight
}


@rpc("authority", "call_local", "reliable")
func apply_enemy_archetype(archetype: String, wave: int = 1) -> void:
	if not is_bot:
		return
	enemy_archetype = archetype
	weapon.reset()
	_apply_coop_archetype_body(archetype, weapon)
	_apply_archetype_skin(archetype)
	match archetype:
		"sniper":
			weapon.damage_mult = 1.45 + float(wave) * 0.04
			weapon.fire_rate_mult = 0.38
			weapon.reload_mult = 0.85
			weapon.mag_size_bonus = -3
			weapon.spread = 0.0018
			weapon.recoil_per_shot = 0.006
			weapon.bullet_speed_mult = 2.8
			weapon.bullet_drop = 0.0
			weapon.headshot_mult = 1.35
			weapon.bullet_color = Color(0.72, 0.38, 1.0)
			weapon.special = Weapon.SPECIAL_ZOOM
		"grenadier":
			weapon.damage_mult = 0.62 + float(wave) * 0.03
			weapon.fire_rate_mult = 0.32
			weapon.reload_mult = 0.72
			weapon.move_speed_mult = 0.72
			weapon.mag_size_bonus = -1
			weapon.spread = 0.014
			weapon.recoil_per_shot = 0.018
			weapon.bullet_speed_mult = 0.68
			weapon.max_hp_bonus += 60
			weapon.explosive_radius = 3.4 + minf(float(wave) * 0.12, 1.6)
			weapon.explosive_damage = 28.0 + float(wave) * 3.0
			weapon.bullet_color = Color(1.0, 0.48, 0.14)
		"flat_fragger":
			weapon.damage_mult = 0.72 + float(wave) * 0.028
			weapon.fire_rate_mult = 0.28
			weapon.reload_mult = 0.62
			weapon.mag_size_bonus = -2
			weapon.extra_projectiles += 2
			weapon.spread = deg_to_rad(4.0)
			weapon.recoil_per_shot = 0.022
			weapon.bullet_speed_mult = 0.7
			weapon.bullet_color = Color(1.0, 0.42, 0.62)
		"demolition":
			weapon.damage_mult = 0.72 + float(wave) * 0.025
			weapon.fire_rate_mult = 0.52
			weapon.reload_mult = 0.8
			weapon.mag_size_bonus = -2
			weapon.spread = 0.018
			weapon.bullet_speed_mult = 0.72
			weapon.explosive_radius = 3.2 + minf(float(wave) * 0.18, 2.8)
			weapon.explosive_damage = 35.0 + float(wave) * 4.0
			weapon.special = Weapon.SPECIAL_CLUSTER_GRENADE if wave >= 10 else Weapon.SPECIAL_GRENADE
			weapon.special_cooldown_mult = 0.78
			weapon.bullet_color = Color(1.0, 0.42, 0.12)
		_:
			weapon.damage_mult = 0.48 + float(wave) * 0.025
			weapon.fire_rate_mult = 0.9 + minf(float(wave) * 0.035, 0.5)
			weapon.reload_mult = 1.12
			weapon.mag_size_bonus = -2
			weapon.spread = 0.018
			weapon.recoil_per_shot = 0.012
			weapon.bullet_speed_mult = 0.82
			weapon.bullet_color = Color(1.0, 0.82, 0.28)
	mag = weapon.get_mag_size()
	_update_body_scale()
	_update_gun_visuals()
	_apply_identity_skin_materials()

@rpc("any_peer", "call_local", "reliable")
func enter_coop_downed(corpse_pos: Vector3) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 1 and sender != 0:
		return
	coop_downed = true
	_coop_phoenix_held = false
	_coop_down_pos = corpse_pos
	health = 0
	frozen = false
	velocity = Vector3.ZERO
	Violence.clear_ragdoll(self)
	_ragdoll_head = null
	_spawn_coop_down_marker(corpse_pos)
	_start_phoenix_ascent(corpse_pos, Time.get_ticks_msec(), true)
	if is_multiplayer_authority() and not is_bot:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		if camera:
			camera.transform = Transform3D(Basis.IDENTITY, _camera_rest_pos)
		var game := get_tree().current_scene
		if game and game.has_method("set_phoenix_fade"):
			game.set_phoenix_fade(player_id, 0.0)


@rpc("any_peer", "call_local", "reliable")
func clear_coop_downed_state() -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 1 and sender != 0:
		return
	coop_downed = false
	_coop_phoenix_held = false
	_phoenix_ascending = false
	_phoenix_finish_requested = false
	_phoenix_start_ms = 0
	_phoenix_start_pos = Vector3.ZERO
	_clear_phoenix_fx()
	launching = false
	_stop_rocket_descent_audio()
	frozen = false
	_clear_coop_down_marker()
	if health <= 0 and not ghost_mode:
		health = MAX_HEALTH + weapon.max_hp_bonus
	_apply_ghost_visuals()
	_restore_weapon_visuals()


@rpc("any_peer", "call_local", "reliable")
func begin_phoenix_ascension(revive_pos: Vector3, start_ms: int = 0) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 1 and sender != 0:
		return
	var scene := get_tree().current_scene
	if scene and scene.has_method("show_death_effect_for"):
		scene.show_death_effect_for(player_id, false)
	_start_phoenix_ascent(revive_pos, start_ms, false)


func _start_phoenix_ascent(revive_pos: Vector3, start_ms: int, keep_coop_downed: bool) -> void:
	Violence.clear_ragdoll(self)
	_set_dead_visuals(false)
	if not keep_coop_downed:
		coop_downed = false
		_clear_coop_down_marker()
		frozen = false
		health = maxi(1, int(float(MAX_HEALTH + weapon.max_hp_bonus) * 0.35))
	_coop_phoenix_held = false
	_phoenix_ascending = true
	_phoenix_finish_requested = false
	_phoenix_start_pos = revive_pos
	_phoenix_start_ms = start_ms if start_ms > 0 else Time.get_ticks_msec()
	_spawn_phoenix_column(revive_pos)
	_apply_phoenix_visuals(PHOENIX_ALPHA_START)
	global_position = revive_pos
	velocity = Vector3.ZERO
	if is_multiplayer_authority():
		var game_start := get_tree().current_scene
		if game_start and game_start.has_method("set_phoenix_fade"):
			game_start.set_phoenix_fade(player_id, 0.0)
		_poison_damage_left = 0.0
		_poison_dps = 0.0
		_poison_tick_accum = 0.0
		_slow_timer = 0.0
		_slow_mult = 1.0
		_clear_chill_visual()
		_ragdoll_head = null
		if camera:
			camera.transform = Transform3D(Basis.IDENTITY, _camera_rest_pos)
		_last_sync_pos = global_position
		_last_sync_yaw = rotation.y
		_last_sync_pitch = look_pitch
		_broadcast_state.rpc(global_position, rotation.y, look_pitch)
	else:
		_remote_target_pos = revive_pos
		_remote_target_yaw = rotation.y
		_remote_has_target = true
		_visual_prev_pos = revive_pos


@rpc("any_peer", "call_local", "reliable")
func _finish_phoenix_ascension(spawn_pos: Vector3, spawn_yaw: float = 0.0) -> void:
	if not _phoenix_ascending and not _coop_phoenix_held:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender != 1 and sender != 0:
		return
	_phoenix_ascending = false
	_coop_phoenix_held = false
	_phoenix_finish_requested = false
	_phoenix_start_ms = 0
	_phoenix_start_pos = Vector3.ZERO
	_clear_phoenix_fx()
	coop_downed = false
	_clear_coop_down_marker()
	frozen = false
	for mesh in _body_meshes():
		mesh.material_override = _body_materials.get(mesh, mesh.material_override)
	global_position = spawn_pos
	rotation.y = spawn_yaw
	if is_multiplayer_authority():
		velocity = Vector3.ZERO
		_ragdoll_head = null
		if camera:
			camera.transform = Transform3D(Basis.IDENTITY, _camera_rest_pos)
		var game := get_tree().current_scene
		if game and game.has_method("begin_phoenix_fade_out"):
			game.begin_phoenix_fade_out(player_id)
	_refresh_authority_view()
	_apply_ghost_visuals()
	_restore_weapon_visuals()
	if is_multiplayer_authority():
		_last_sync_pos = global_position
		_last_sync_yaw = rotation.y
		_last_sync_pitch = look_pitch
		_broadcast_state.rpc(global_position, rotation.y, look_pitch)
	else:
		_remote_target_pos = spawn_pos
		_remote_target_yaw = spawn_yaw
		_remote_has_target = true
		_visual_prev_pos = spawn_pos


@rpc("any_peer", "call_local", "reliable")
func set_ghost_mode(enabled: bool) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 1 and sender != 0:
		return
	ghost_mode = enabled
	if enabled:
		Violence.end_lava_death(self)
		_lava_death_active = false
		frozen = false
		health = 0
		# Detach the death-cam from the tumbling ragdoll head so the camera
		# snaps back to the body at the death position. Otherwise we'd watch
		# the corpse fly off into the void.
		_ragdoll_head = null
		if camera:
			camera.transform = Transform3D(Basis.IDENTITY, _camera_rest_pos)
		# Make the body itself solid + visible (was hidden + de-collided on death).
		if body_model:
			body_model.visible = true
		_set_dead_visuals(false)
		if is_multiplayer_authority() and not is_bot:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		health = MAX_HEALTH + weapon.max_hp_bonus
		_phoenix_charges_left = weapon.phoenix_revives
	_apply_ghost_visuals()

# -------------------- STATE REPLICATION --------------------

func _maybe_broadcast_state() -> void:
	if global_position.distance_squared_to(_last_sync_pos) < 0.0001 \
			and absf(rotation.y - _last_sync_yaw) < 0.001 \
			and absf(look_pitch - _last_sync_pitch) < 0.005:
		return
	_last_sync_pos = global_position
	_last_sync_yaw = rotation.y
	_last_sync_pitch = look_pitch
	_broadcast_state.rpc(global_position, rotation.y, look_pitch)

@rpc("authority", "unreliable_ordered")
func _broadcast_state(pos: Vector3, yaw: float, pitch: float) -> void:
	if is_multiplayer_authority():
		return
	if not _remote_has_target or global_position.distance_to(pos) > REMOTE_SNAP_DISTANCE:
		global_position = pos
		rotation.y = yaw
		_visual_prev_pos = pos
	_remote_target_pos = pos
	_remote_target_yaw = yaw
	_remote_target_pitch = pitch
	_remote_has_target = true

@rpc("any_peer", "call_local", "reliable")
func set_frozen(f: bool) -> void:
	# Server-authorized only. Match the pattern used by server_respawn.
	var sender := multiplayer.get_remote_sender_id()
	if sender != 1 and sender != 0:
		return
	frozen = f
	if f:
		velocity = Vector3.ZERO
	elif is_multiplayer_authority() and not is_bot:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


# Round-start gladiator cage: freeze inside a hanging cage that a crane
# lowers `descend` meters into the arena while the card-growth morph plays;
# game.gd releases everyone together once the hold expires. Frozen physics
# means the cage needs no collision — it's pure set dressing, built locally
# on every peer from this broadcast. The cage tweens itself on every peer;
# the player rides along via an identical tween on the authority peer only
# (remote copies follow the normal position sync).
@rpc("any_peer", "call_local", "reliable")
func enter_spawn_cage(descend: float = 0.0, descend_seconds: float = 2.6) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 1 and sender != 0:
		return
	frozen = true
	velocity = Vector3.ZERO
	_clear_spawn_cage()
	var cage := SpawnCage.new()
	cage.name = "SpawnCage_%d" % player_id
	# Parent to the scene, NOT get_parent(): the player's parent is the
	# Players container, and several game.gd loops iterate its children
	# assuming everything there is a Player (coop revive checks crashed on
	# `bool(cage.get("coop_downed"))` → Nil).
	get_tree().current_scene.add_child(cage)
	# Player origin is capsule-center; the cage floor sits just under the feet.
	cage.global_position = global_position + Vector3(0.0, -1.1, 0.0)
	_spawn_cage = cage
	if descend > 0.0:
		cage.descend(descend, descend_seconds)
		if is_multiplayer_authority():
			# Same curve as SpawnCage.descend — keep trans/ease in sync.
			_cage_descent_tween = create_tween()
			_cage_descent_tween.tween_property(
				self, "global_position",
				global_position + Vector3(0.0, -descend, 0.0), descend_seconds) \
				.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	# The gun grows while the crowd waits for the floor to drop.
	if _pending_card_growth:
		_pending_card_growth = false
		_play_card_growth()


@rpc("any_peer", "call_local", "reliable")
func release_spawn_cage() -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 1 and sender != 0:
		return
	frozen = false
	if _cage_descent_tween and _cage_descent_tween.is_valid():
		_cage_descent_tween.kill()  # gravity owns the player from here
	_cage_descent_tween = null
	if is_multiplayer_authority() and not is_bot:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if _spawn_cage and is_instance_valid(_spawn_cage):
		_spawn_cage.open()  # cage frees itself after the winch-up
	_spawn_cage = null


func _clear_spawn_cage() -> void:
	if _spawn_cage and is_instance_valid(_spawn_cage):
		_spawn_cage.queue_free()
	_spawn_cage = null


func _exit_tree() -> void:
	# The cage lives in current_scene, not under us — free it when this player
	# despawns mid-hold so it doesn't dangle from the sky forever.
	_clear_spawn_cage()


@rpc("any_peer", "call_local", "reliable")
func _sync_launching(active: bool) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 0 and sender != get_multiplayer_authority():
		return
	launching = active
	if not active:
		_restore_weapon_visuals()


@rpc("any_peer", "call_local", "reliable")
func set_launching(v: bool, downward_vel: float = 0.0) -> void:
	# Round-start rocket-spawn: when v=true, set constant downward velocity,
	# tilt camera down so the player sees the ground rushing up, and pump
	# shake_amt for a sustained "we're being rocketed" rumble. Server-only.
	var sender := multiplayer.get_remote_sender_id()
	if sender != 1 and sender != 0:
		return
	launching = v
	# Drop begins = the player can see again — play the armed card growth now.
	# Before the authority gate so remote/third-person guns morph too.
	if v and _pending_card_growth:
		_pending_card_growth = false
		_play_card_growth()
	if is_multiplayer_authority():
		if v:
			velocity = Vector3(0.0, -downward_vel, 0.0)
			if not is_bot:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
				# ~25° down — enough to see where you're rocketing into without
				# losing the horizon.
				look_pitch = -0.44
				# Sustained rumble during the descent. The launching path skips
				# the normal shake-decay step, so this stays high until landing.
				shake_amt = 0.06
				_rocket_descent_player = SFX.rocket_descent()
		else:
			velocity = Vector3.ZERO
			_stop_rocket_descent_audio()


func _stop_rocket_descent_audio() -> void:
	if _rocket_descent_player and is_instance_valid(_rocket_descent_player):
		_rocket_descent_player.queue_free()
	_rocket_descent_player = null

@rpc("any_peer", "call_local", "reliable")
func heal(amount: int) -> void:
	if multiplayer.get_remote_sender_id() != 1 and multiplayer.get_remote_sender_id() != 0:
		return
	if not is_multiplayer_authority():
		return
	health = min(get_max_health(), health + amount)

@rpc("any_peer", "call_local", "reliable")
func apply_round_pickup(kind: String) -> void:
	# Mirror apply_card — mutate every peer's copy of this player so online
	# clients stay in sync and the server can see pickup effects for remotes.
	var game := get_tree().current_scene
	if is_bot and game and game.has_method("is_coop_mode") and game.is_coop_mode():
		return
	var dice_detail := ""
	var owner := is_multiplayer_authority()
	match kind:
		"heart":
			health += 50
		"mushroom":
			health += 100
			weapon.body_scale *= 3.0
			weapon.head_scale *= 3.0
			weapon.bullet_color = weapon.bullet_color.lerp(Color(0.95, 0.2, 0.18), 0.55)
		"bomb":
			_apply_explosive_pickup_stack()
			_apply_explosive_pickup_stack()
		"plus_one":
			_phoenix_charges_left += 1
		"laser":
			var shots_before: int = weapon.get_shots_per_trigger()
			var mag_before: int = weapon.get_mag_size()
			weapon.bullet_speed_mult *= 10.0
			weapon.spread = maxf(weapon.spread * 0.1, 0.0002)
			weapon.recoil_per_shot *= 0.1
			weapon.fire_rate_mult *= 10.0
			weapon.extra_projectiles += max(0, shots_before * 9)
			weapon.mag_size_bonus += max(0, mag_before * 9)
			weapon.damage_mult *= 0.1
			weapon.bullet_color = weapon.bullet_color.lerp(Color(0.35, 1.0, 1.0), 0.75)
		"dice":
			dice_detail = _apply_dice_roll()
		"air_strike":
			_air_strike_charges += 1
		_:
			return
	mag = min(weapon.get_mag_size(), max(mag, weapon.get_mag_size()))
	_update_gun_visuals()
	_update_body_scale()
	if owner:
		SFX.pling(1.15)
		var g := game
		if g and g.has_method("show_pickup_collected_for"):
			g.show_pickup_collected_for(player_id, kind, dice_detail)

func _apply_explosive_pickup_stack() -> void:
	if weapon.explosive_radius <= 0.0:
		weapon.explosive_radius += 4.0
	else:
		weapon.explosive_radius += 2.5
	weapon.explosive_damage += 25.0
	weapon.bullet_color = weapon.bullet_color.lerp(Color(1.0, 0.45, 0.08), 0.45)


func _apply_dice_roll() -> String:
	var pool: Array[String] = [
		"damage_mult", "fire_rate_mult", "move_speed_mult", "bullet_speed_mult", "reload_mult", "spread",
	]
	pool.shuffle()
	var up_key: String = pool[0]
	var down_key: String = pool[1]
	_dice_mult_stat(up_key, 2.0)
	_dice_mult_stat(down_key, 0.5)
	return "%s ×2, %s ×½" % [_dice_stat_label(up_key), _dice_stat_label(down_key)]


func _dice_mult_stat(key: String, factor: float) -> void:
	match key:
		"damage_mult":
			weapon.damage_mult *= factor
		"fire_rate_mult":
			weapon.fire_rate_mult *= factor
		"move_speed_mult":
			weapon.move_speed_mult *= factor
		"bullet_speed_mult":
			weapon.bullet_speed_mult *= factor
		"reload_mult":
			weapon.reload_mult *= factor
		"spread":
			weapon.spread *= factor
		_:
			pass


func _dice_stat_label(key: String) -> String:
	match key:
		"damage_mult":
			return "Damage"
		"fire_rate_mult":
			return "Fire rate"
		"move_speed_mult":
			return "Speed"
		"bullet_speed_mult":
			return "Bullet speed"
		"reload_mult":
			return "Reload"
		"spread":
			return "Spread"
		_:
			return key

# -------------------- CARDS (ROUNDS-style) --------------------

@rpc("any_peer", "call_local", "reliable")
func apply_card(card_id: String) -> void:
	# Anyone can call (for debug). In a real round flow, only the card owner's
	# authority would be allowed. Broadcast so every peer's copy of this
	# player's weapon stays in sync.
	var card := CardLibrary.by_id(card_id)
	if card.is_empty():
		return
	# Mid-round card adds (dev panel / labs) grow the gun live. During the
	# real card-pick screen (state == PICKING_CARD) the growth is deferred to
	# the round-start rebuild so it plays during the sky drop instead.
	var grow_from: Weapon = weapon.duplicate() if _is_round_playing() else null
	if grow_from != null:
		# duplicate() shares Array references — snapshot the card list before
		# the append below mutates it, or the growth delta reads as zero.
		grow_from.applied_cards = weapon.applied_cards.duplicate()
	card.apply.call(weapon)
	_owned_cards.append(card_id)
	weapon.applied_cards.append(card_id)
	# If the mag cap grew, refill up to the new cap immediately.
	mag = min(weapon.get_mag_size(), max(mag, weapon.get_mag_size() if weapon.applied_cards.size() == 1 else mag))
	# Top up HP if the card just raised the cap.
	if is_multiplayer_authority():
		health = max(health, MAX_HEALTH + weapon.max_hp_bonus)
		_phoenix_charges_left = max(_phoenix_charges_left, weapon.phoenix_revives)
	_update_gun_visuals()
	_update_body_scale()
	if grow_from != null:
		_animate_gun_growth(grow_from)
		_grown_card_count = _owned_cards.size()

@rpc("any_peer", "call_local", "reliable")
func rebuild_weapon_from_cards() -> void:
	# Strip round-only pickup buffs while keeping stacked cards.
	if _owned_cards.is_empty() and not weapon.applied_cards.is_empty():
		for card_id in weapon.applied_cards:
			_owned_cards.append(str(card_id))
	var cards: Array = _owned_cards.duplicate()
	weapon.reset()
	for card_id in cards:
		var card := CardLibrary.by_id(str(card_id))
		if card.is_empty():
			continue
		card.apply.call(weapon)
		weapon.applied_cards.append(str(card_id))
	mag = weapon.get_mag_size()
	_update_gun_visuals()
	_update_body_scale()
	# Round-start growth moment: a card was picked since the gun last showed
	# its final form — arm the morph; it starts when the sky drop launches.
	if _owned_cards.size() > _grown_card_count:
		_pending_card_growth = true
	_grown_card_count = _owned_cards.size()


@rpc("any_peer", "call_local", "reliable")
func apply_swapped_cards(cards: Array) -> void:
	# Temporary round loadout — does not change _owned_cards.
	var sender := multiplayer.get_remote_sender_id()
	if sender != 1 and sender != 0:
		return
	weapon.reset()
	for card_id in cards:
		var card := CardLibrary.by_id(str(card_id))
		if card.is_empty():
			continue
		card.apply.call(weapon)
		weapon.applied_cards.append(str(card_id))
	mag = weapon.get_mag_size()
	_update_gun_visuals()
	_update_body_scale()


@rpc("any_peer", "call_local", "reliable")
func apply_round_modifier_weapon(mod_id: String) -> void:
	if multiplayer.get_remote_sender_id() != 1 and multiplayer.get_remote_sender_id() != 0:
		return
	ROUND_MODIFIERS_SCRIPT.apply_weapon(weapon, mod_id)
	mag = min(weapon.get_mag_size(), max(mag, weapon.get_mag_size()))
	_update_gun_visuals()


func _gravity_mult() -> float:
	var game := get_tree().current_scene
	if game and game.has_method("get_gravity_mult"):
		return game.get_gravity_mult()
	return 1.0


@rpc("any_peer", "call_local", "reliable")
func reset_weapon() -> void:
	weapon.reset()
	_owned_cards.clear()
	_grown_card_count = 0
	_pending_card_growth = false
	mag = weapon.get_mag_size()
	_reset_weapon_combat_state()
	_phoenix_charges_left = weapon.phoenix_revives
	_air_strike_charges = 0
	_poison_damage_left = 0.0
	_poison_dps = 0.0
	_slow_timer = 0.0
	_slow_mult = 1.0
	_clear_chill_visual()
	_update_gun_visuals()
	_update_body_scale()

# -------------------- GUN VISUALS --------------------

func _setup_gun_visuals() -> void:
	# Hide the legacy GunMesh boxes — replaced by the procedural gun below.
	# (Leaving the nodes around so existing references like _apply_ghost_visuals
	# don't crash; they're just invisible.)
	if gun_body:
		gun_body.visible = false
	gun_barrel = MeshInstance3D.new()
	gun_barrel.visible = false
	muzzle.add_child(gun_barrel)
	gun_magazine = MeshInstance3D.new()
	gun_magazine.visible = false
	muzzle.add_child(gun_magazine)

	# Procedural gun — its parts react to weapon stats via apply_weapon_stats.
	_procedural_gun = preload("res://scripts/procedural_gun.gd").new()
	_procedural_gun.name = "ProceduralGun"
	muzzle.add_child(_procedural_gun)
	_demon_growth = DemonGrowth.new()
	_demon_growth.name = "DemonGrowth"
	_demon_growth.gun_path = NodePath("../ProceduralGun")
	_demon_growth.corruption = 0.0
	muzzle.add_child(_demon_growth)

func _update_gun_visuals() -> void:
	# Push the current weapon stats into the procedural gun. All
	# stat→geometry mapping lives in procedural_gun.gd.
	if _procedural_gun and _procedural_gun.has_method("apply_weapon_stats"):
		_procedural_gun.apply_weapon_stats(weapon)
		# Long barrels = pull the gun back against the shoulder (positive Z is
		# behind the camera). 0.5 m barrel = no offset; 1.4 m = 0.3 m back.
		var bl: float = float(_procedural_gun.get("barrel_length"))
		var pull: float = clampf((bl - 0.5) * 0.3, 0.0, 0.3)
		_gun_pull_back = Vector3(0.0, 0.0, pull)
	_update_third_person_gun_visuals()
	# Corruption tracks how far the weapon has mutated from stock — the gun
	# grows more alive as cards stack. Set AFTER apply_weapon_stats on both
	# guns: the growth reads the gun's final geometry when it rebuilds.
	var corruption := DemonGrowth.corruption_from_weapon(weapon)
	if _demon_growth:
		_demon_growth.corruption = corruption
	if _third_person_demon_growth:
		_third_person_demon_growth.corruption = corruption

# Rebuild the weapon as it was before the newest card, then animate both guns
# (and their flesh) from that form into the current one — timed with the
# round-start sky drop so the player watches their gun grow mid-fall.
func _play_card_growth(duration: float = 1.5) -> void:
	if _owned_cards.is_empty():
		return
	var from_w := Weapon.new()
	for card_id in _owned_cards.slice(0, _owned_cards.size() - 1):
		var card := CardLibrary.by_id(str(card_id))
		if card.is_empty():
			continue
		card.apply.call(from_w)
		# corruption_from_weapon paces flesh by card count — keep it honest.
		from_w.applied_cards.append(str(card_id))
	_animate_gun_growth(from_w, duration)

func _animate_gun_growth(from_w: Weapon, duration: float = 2.0) -> void:
	if from_w == null:
		return
	if _procedural_gun and _procedural_gun.has_method("animate_weapon_growth"):
		_procedural_gun.animate_weapon_growth(from_w, weapon, duration)
	if _third_person_procedural_gun and _third_person_procedural_gun.has_method("animate_weapon_growth"):
		_third_person_procedural_gun.animate_weapon_growth(from_w, weapon, duration)
	var c_from := DemonGrowth.corruption_from_weapon(from_w)
	var c_to := DemonGrowth.corruption_from_weapon(weapon)
	if _demon_growth:
		_demon_growth.animate_corruption(c_from, c_to, duration)
	if _third_person_demon_growth:
		_third_person_demon_growth.animate_corruption(c_from, c_to, duration)

# True while a round is actively being played (or in a lab scene exposing
# state == PLAYING). During PICKING_CARD we defer growth to round start.
func _is_round_playing() -> bool:
	var scene := get_tree().current_scene
	if scene == null:
		return true
	var st: Variant = scene.get("state")
	if st == null:
		return true
	return int(st) == 1  # Game.State.PLAYING

func _update_body_scale() -> void:
	# BodyModel holds the visual mesh parts; hitboxes are siblings under the
	# Player root and must be kept in sync with the visual body size + height.
	if body_model == null:
		return
	var bs: float = maxf(0.1, weapon.body_scale)
	var hs: float = maxf(0.1, weapon.head_scale)
	# Per-axis warp lets cards like SLENDERMAN / FLATFISH stretch the body
	# without changing overall mass. Clamped so a 0 axis doesn't squash to nothing.
	var axes: Vector3 = Vector3(
		maxf(0.1, weapon.body_scale_axes.x),
		maxf(0.1, weapon.body_scale_axes.y),
		maxf(0.1, weapon.body_scale_axes.z),
	)
	body_model.scale = axes * bs
	if character_visual:
		# Foot pinning: BodyModel's scale drags the model's -0.9 foot offset
		# down with it, burying CHONKY feet in the floor. Counter-divide so
		# the feet stay planted at the capsule bottom at any scale.
		if character_visual.foot_align_capsule:
			character_visual.position.y = CharacterVisual.FOOT_OFFSET_Y / (bs * axes.y)
		# Per-bone warps: BIG HEAD grows the actual head (matching the head
		# hitbox below), plus whatever bone scales cards put on the weapon.
		var warps: Dictionary = weapon.bone_warps.duplicate()
		if not is_equal_approx(hs, 1.0):
			warps["Head"] = warps.get("Head", Vector3.ONE) * hs
		character_visual.apply_bone_warps(warps)
	# On the humanoid rig head_scale ALSO scales the Head bone (above); the
	# hitbox below keeps gameplay in sync with the visual.
	# Hitboxes are siblings under the Player root — shift their y so they sit
	# where the scaled visual parts actually are, and scale them to match.
	if head_hitbox:
		head_hitbox.position.y = _head_hitbox_rest_y * bs * axes.y
		head_hitbox.scale = axes * (bs * hs)
	if torso_hitbox:
		torso_hitbox.position.y = _torso_hitbox_rest_y * bs * axes.y
		torso_hitbox.scale = axes * bs
	if legs_hitbox:
		legs_hitbox.position.y = _legs_hitbox_rest_y * bs * axes.y
		legs_hitbox.scale = axes * bs
	# Camera sits at head height — scale the rest position so a CHONKY player
	# looks out from their actual (taller) head rather than mid-torso.
	if camera:
		camera.position = Vector3(
			_camera_rest_pos.x,
			_camera_rest_pos.y * bs * axes.y,
			_camera_rest_pos.z,
		)
	# Gun feels smaller in the hands of a bigger player (inverse sqrt scaling
	# keeps it gently smaller, not microscopic, as the body grows).
	if muzzle:
		muzzle.scale = Vector3.ONE * (1.0 / sqrt(bs))

# -------------------- BOT AI --------------------

func _bot_physics(delta: float) -> void:
	var _pt := Time.get_ticks_usec() if Trace.enabled else 0
	if health <= 0 or ghost_mode:
		velocity = Vector3.ZERO
		_bot_target = null
		_bot_shoot_cooldown = 999.0
		_bot_aim_point = Vector3.ZERO
		_bot_los_time = 0.0
		_trace_bot_phys(_pt)
		return
	if launching:
		move_and_slide()
		if is_on_floor() and launching:
			_sync_launching.rpc(false)
		_trace_bot_phys(_pt)
		return
	if frozen:
		velocity = Vector3.ZERO
		_trace_bot_phys(_pt)
		return

	# Passive AI mode: do absolutely nothing.
	var game_scene: Node = get_tree().current_scene
	if game_scene and game_scene.get("bots_hold_fire") == true:
		if not is_on_floor():
			velocity.y -= GRAVITY * _gravity_mult() * delta
		else:
			velocity.y = 0.0
		velocity.x = move_toward(velocity.x, 0.0, BOT_MOVE_SPEED * 3.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, BOT_MOVE_SPEED * 3.0 * delta)
		move_and_slide()
		_trace_bot_phys(_pt)
		return

	_bot_shoot_cooldown = maxf(0.0, _bot_shoot_cooldown - delta)
	_bot_jump_cooldown = maxf(0.0, _bot_jump_cooldown - delta)
	_bot_dash_cooldown = maxf(0.0, _bot_dash_cooldown - delta)
	# Ticks rifle + grenade + melee — bots return before the human cooldown
	# path, and a frozen grenade_cooldown meant bots could never use RMB.
	_tick_weapon_cooldowns(delta)
	_bot_special_think = maxf(0.0, _bot_special_think - delta)
	_bot_climb_probe = maxf(0.0, _bot_climb_probe - delta)
	_bot_climb_until = maxf(0.0, _bot_climb_until - delta)
	_bot_pickup_scan -= delta
	_bot_pickup_give_up -= delta
	# Lava lapse window (see var comment): roll once a second, and a failed
	# roll opens a short window where every safety check agrees to be wrong.
	_bot_lava_risk_timer = maxf(0.0, _bot_lava_risk_timer - delta)
	_bot_lava_risk_roll -= delta
	if _bot_lava_risk_roll <= 0.0:
		_bot_lava_risk_roll = 1.0
		if randf() < BOT_LAVA_MISTAKE_CHANCE:
			_bot_lava_risk_timer = 0.6
	# Aim wobble drifts like a hand: retarget at irregular intervals, chase
	# exponentially (same recipe as the demon eye's gaze walk).
	_bot_aim_retarget -= delta
	if _bot_aim_retarget <= 0.0:
		_bot_aim_retarget = randf_range(0.25, 0.7)
		_bot_aim_wander_target = Vector3(
			randf_range(-1.0, 1.0), randf_range(-0.6, 0.6), randf_range(-1.0, 1.0)
		) * randf_range(0.1, 0.9)
	_bot_aim_wander = _bot_aim_wander.lerp(_bot_aim_wander_target, 1.0 - exp(-5.0 * delta))

	if reloading and rifle_cooldown <= 0.0:
		mag = weapon.get_mag_size()
		reloading = false

	# Dash charges tick back up the same as for real players.
	if dash_charges < MAX_DASH_CHARGES:
		dash_recharge_timer += delta
		if dash_recharge_timer >= DASH_RECHARGE_TIME:
			dash_charges += 1
			dash_recharge_timer = 0.0
	else:
		dash_recharge_timer = 0.0

	# Gravity
	if not is_on_floor():
		velocity.y -= GRAVITY * _gravity_mult() * delta
	else:
		jumps_left = 2 + weapon.extra_jumps

	if _bot_target == null or not is_instance_valid(_bot_target) or _bot_target.get("ghost_mode") == true:
		_bot_target = _bot_find_target()
	if _bot_target == null:
		velocity.x = move_toward(velocity.x, 0.0, BOT_MOVE_SPEED * 3.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, BOT_MOVE_SPEED * 3.0 * delta)
		move_and_slide()
		_maybe_broadcast_state()
		return

	var to_target: Vector3 = _bot_target.global_position - global_position
	var flat := Vector3(to_target.x, 0.0, to_target.z)
	var dist := flat.length()

	# Re-roll the movement intent every so often so the bot weaves instead of
	# marching in a straight line. Values are blended with a forced
	# approach/retreat if it drifts way off the follow distance.
	_bot_strafe_timer -= delta
	if _bot_strafe_timer <= 0.0:
		_bot_strafe_timer = randf_range(0.5, 1.6)
		_bot_strafe_side = [-1.0, -0.7, 0.0, 0.7, 1.0].pick_random()
		_bot_approach = [-0.6, 0.0, 0.0, 0.6, 1.0].pick_random()

	var fwd_dir: Vector3 = flat.normalized() if dist > 0.01 else -global_transform.basis.z
	var right_dir := Vector3(-fwd_dir.z, 0.0, fwd_dir.x)
	var chase: float = _bot_approach
	if dist > BOT_FOLLOW_DIST * 1.8:
		chase = 1.0          # too far — close the gap
	elif dist < BOT_FOLLOW_DIST * 0.45:
		chase = -0.7         # too close — back off
	var move_dir: Vector3 = fwd_dir * chase + right_dir * _bot_strafe_side
	if move_dir.length() > 1.0:
		move_dir = move_dir.normalized()

	# Pickup seeking: notice a grounded pickup every couple of seconds (not
	# always — bots are allowed to miss them) and drift toward it while still
	# fighting. Skipped in co-op, where pickups ignore bots anyway.
	if _bot_pickup_target != null and (not is_instance_valid(_bot_pickup_target) or _bot_pickup_give_up <= 0.0):
		_bot_pickup_target = null
	if _bot_pickup_target == null and _bot_pickup_scan <= 0.0:
		_bot_pickup_scan = randf_range(1.4, 2.8)
		var coop: bool = game_scene != null and game_scene.has_method("is_coop_mode") and game_scene.is_coop_mode()
		if not coop and randf() < BOT_PICKUP_NOTICE_CHANCE:
			_bot_pickup_target = _bot_find_pickup()
			_bot_pickup_give_up = randf_range(4.0, 7.0)
	if _bot_pickup_target != null:
		var to_pick: Vector3 = _bot_pickup_target.global_position - global_position
		to_pick.y = 0.0
		if to_pick.length() > 0.3:
			# Blend, don't beeline — the bot keeps strafing and fighting.
			move_dir = (to_pick.normalized() * 0.85 + move_dir * 0.45).normalized()

	var strike_dist := _bot_nearest_strike_flat_dist()
	var flee_dir := Vector3.ZERO
	if strike_dist < BOT_AIR_STRIKE_FLEE_RADIUS:
		flee_dir = _bot_strike_flee_dir()
		if flee_dir.length_squared() > 0.01:
			move_dir = flee_dir
			chase = 0.0
			_bot_approach = 0.0
			_bot_strafe_side = 0.0
	elif _bot_on_lava_map() and not _bot_may_take_lava_risk():
		move_dir = _bot_lava_safe_move_dir(move_dir)

	var edge_probe := _bot_edge_probe_dist()
	var gap_jump_started := false
	if is_on_floor() and move_dir.length_squared() > 0.01 and not _bot_has_floor_ahead(move_dir, edge_probe):
		var landing_dist := _bot_gap_landing_distance(move_dir)
		if landing_dist > 0.0:
			velocity.y = JUMP_VELOCITY
			jumps_left = 1 + weapon.extra_jumps
			_bot_jump_cooldown = randf_range(0.8, 1.8)
			gap_jump_started = true
			if not ghost_mode:
				SFX.jump(global_position)
			if landing_dist > 7.0 and dash_timer <= 0.0 and dash_charges > 0 and _bot_dash_cooldown <= 0.0:
				_start_dash(move_dir.normalized())
				_bot_dash_cooldown = randf_range(2.0, 4.0)
		else:
			if _bot_jump_cooldown <= 0.0 and is_on_floor():
				velocity.y = JUMP_VELOCITY
				jumps_left = 1 + weapon.extra_jumps
				_bot_jump_cooldown = randf_range(0.8, 1.6)
				gap_jump_started = true
				if not ghost_mode:
					SFX.jump(global_position)
			else:
				move_dir = Vector3.ZERO
				_bot_strafe_timer = 0.0
	elif not is_on_floor() and velocity.y < 1.0 and jumps_left > 0 and move_dir.length_squared() > 0.01:
		if not _bot_has_floor_ahead(move_dir, edge_probe) and _bot_gap_landing_distance(move_dir) > 0.0:
			velocity.y = DOUBLE_JUMP_VELOCITY
			jumps_left -= 1
			gap_jump_started = true
			if not ghost_mode:
				SFX.jump(global_position)

	# Climb buildings: when a wall blocks the way (or the target holds high
	# ground), look for a mountable rooftop and jump; the mid-air block below
	# spends the double jump to finish the climb.
	if not gap_jump_started and is_on_floor() and _bot_climb_probe <= 0.0 \
			and move_dir.length_squared() > 0.01:
		if to_target.y > 1.6 or randf() < 0.35:
			var ledge_h := _bot_climbable_ledge_height(move_dir)
			if ledge_h > 0.0:
				velocity.y = JUMP_VELOCITY
				jumps_left = 1 + weapon.extra_jumps
				_bot_climb_until = 1.4
				_bot_climb_target_y = global_position.y + ledge_h
				_bot_jump_cooldown = randf_range(0.8, 1.6)
				gap_jump_started = true
				if not ghost_mode:
					SFX.jump(global_position)
		_bot_climb_probe = randf_range(1.2, 2.8)
	# Mid-climb: the first jump tops out below the ledge — spend the double
	# jump at the apex to mount it.
	if _bot_climb_until > 0.0 and not is_on_floor() and velocity.y < 1.0 \
			and jumps_left > 0 and global_position.y < _bot_climb_target_y - 0.2:
		velocity.y = DOUBLE_JUMP_VELOCITY
		jumps_left -= 1
		if not ghost_mode:
			SFX.jump(global_position)

	# Occasional hop — keeps the bot moving vertically, harder to track.
	var hop_chance := BOT_LAVA_JUMP_CHANCE if _bot_on_lava_map() else BOT_JUMP_CHANCE
	if not gap_jump_started and is_on_floor() and _bot_jump_cooldown <= 0.0 and randf() < hop_chance:
		# Never hop toward lava — the jump carries current momentum, so the
		# probable landing must be safe even during a lapse window.
		if not _bot_on_lava_map() or _bot_move_is_lava_safe(move_dir, _bot_edge_probe_dist() + 1.5):
			velocity.y = JUMP_VELOCITY
			_bot_jump_cooldown = randf_range(2.0, 4.5)
			if not ghost_mode: SFX.jump(global_position)

	# Occasional dash — usually in the current move direction, sometimes sideways.
	var dash_ok := move_dir.length_squared() > 0.01
	if dash_ok and _bot_on_lava_map() and not _bot_may_take_lava_risk():
		dash_ok = _bot_move_is_lava_safe(move_dir, _bot_edge_probe_dist() + 1.2)
	var panic_dash := strike_dist < BOT_AIR_STRIKE_PANIC_RADIUS
	if dash_timer <= 0.0 and dash_charges > 0 and _bot_dash_cooldown <= 0.0 \
			and (panic_dash or (randf() < BOT_DASH_CHANCE and dash_ok)):
		var wish: Vector3 = move_dir if move_dir.length_squared() > 0.01 else fwd_dir
		if panic_dash and flee_dir.length_squared() > 0.01:
			wish = flee_dir
		dash_dir = wish.normalized()
		_start_dash(wish)
		_bot_dash_cooldown = randf_range(2.5, 5.5)

	# Face the target so strafing doesn't spin the body every reroll.
	var face_dir := Vector3.ZERO
	if dash_timer > 0.0 and dash_dir.length_squared() > 0.01:
		face_dir = dash_dir
	elif dist > 0.05:
		face_dir = flat
	elif move_dir.length_squared() > 0.02:
		face_dir = move_dir
	if face_dir.length_squared() > 0.0001:
		var want_yaw := atan2(-face_dir.x, -face_dir.z)
		rotation.y = lerp_angle(rotation.y, want_yaw, delta * BOT_ROT_SPEED)

	# --- Movement ---
	var target_vel := move_dir * BOT_MOVE_SPEED * weapon.move_speed_mult * _slow_mult
	var accel := GROUND_ACCEL if is_on_floor() else AIR_ACCEL

	if dash_timer > 0.0:
		dash_timer -= delta
		velocity.y = max(velocity.y, 0.0)
		# Taper dash speed at the end.
		var dash_factor := clampf(dash_timer / (DASH_TIME * 0.5), 0.0, 1.0)
		target_vel = target_vel.lerp(dash_dir * DASH_SPEED * _slow_mult, dash_factor)
		accel = 2000.0
		if dash_timer <= 0.0:
			_on_dash_ended()

	velocity.x = move_toward(velocity.x, target_vel.x, accel * delta)
	velocity.z = move_toward(velocity.z, target_vel.z, accel * delta)

	move_and_slide()

	var wants_move := target_vel.length_squared() > 0.25
	var flat_speed := Vector2(velocity.x, velocity.z).length()
	if wants_move and flat_speed < 1.1 and is_on_floor() and dash_timer <= 0.0:
		_bot_stuck_timer += delta
		if _bot_stuck_timer > 0.5 and _bot_jump_cooldown <= 0.0:
			velocity.y = JUMP_VELOCITY
			jumps_left = maxi(jumps_left, 1)
			_bot_jump_cooldown = randf_range(0.8, 1.6)
			_bot_stuck_timer = 0.0
			if not ghost_mode:
				SFX.jump(global_position)
	else:
		_bot_stuck_timer = 0.0

	_maybe_broadcast_state()
	_tick_footsteps(delta)

	# Fell off map.
	_handle_fell_off_map()

	# --- Aim tracking: the "mouse hand" ---
	# The aim point chases the target at a capped angular speed, so a close
	# strafing player outruns the crosshair (huge deg/sec) while a distant or
	# standing one is easy to keep centered. Shots aim at THIS point, not at
	# the target's true position.
	var eye: Vector3 = global_position + Vector3.UP * 0.7
	var want_aim: Vector3 = _bot_target.global_position + Vector3.UP * 0.4
	var want_dir: Vector3 = want_aim - eye
	var aim_range: float = maxf(want_dir.length(), 0.5)
	var cur_dir: Vector3 = _bot_aim_point - eye
	if cur_dir.length_squared() < 0.01:
		cur_dir = -global_transform.basis.z * aim_range
	var aim_ang: float = cur_dir.angle_to(want_dir)
	var max_turn: float = BOT_AIM_TURN_SPEED * delta
	if aim_ang > max_turn and aim_ang > 0.0001:
		var axis: Vector3 = cur_dir.cross(want_dir)
		if axis.length_squared() < 0.000001:
			axis = Vector3.UP
		cur_dir = cur_dir.rotated(axis.normalized(), max_turn)
	else:
		cur_dir = want_dir
	_bot_aim_point = eye + cur_dir.normalized() * aim_range

	# Reaction time: hold fire briefly after (re)acquiring line of sight.
	var has_los: bool = _bot_has_los(_bot_target)
	if has_los:
		_bot_los_time += delta
	else:
		if _bot_los_time > 0.0:
			_bot_reaction = randf_range(BOT_REACTION_MIN, BOT_REACTION_MAX)
		_bot_los_time = 0.0

	if health > 0 and not ghost_mode and has_los and _bot_los_time >= _bot_reaction:
		# Round must be live (no shooting at corpses during card pick / match
		# over), and the dev toggle in the F1 panel can hold fire entirely.
		var game_scene_shoot: Node = get_tree().current_scene
		var is_playing: bool = game_scene_shoot and int(game_scene_shoot.get("state")) == 1  # State.PLAYING == 1
		if is_playing:
			if _bot_shoot_cooldown <= 0.0 and not reloading:
				if _bot_shoot():
					# Bots auto-fire at the weapon's natural cadence, but now obey
					# the same magazine and reload gates as humans.
					_bot_shoot_cooldown = weapon.get_fire_interval()
			# RMB: consider the special once the cooldown is up, on a lazy
			# think cadence so it fires when it makes sense, not on refresh.
			if grenade_cooldown <= 0.0 and _bot_special_think <= 0.0:
				_bot_special_think = randf_range(1.2, 3.2)
				_bot_try_special(dist)

	_trace_bot_phys(_pt)


func _trace_bot_phys(t0: int) -> void:
	if Trace.enabled and t0 > 0:
		Trace.prof("bot_ai", Time.get_ticks_usec() - t0)


func _bot_get_arena() -> Node:
	var game := get_tree().current_scene
	return game.get_node_or_null("Arena") if game else null


func _bot_on_lava_map() -> bool:
	var arena := _bot_get_arena()
	return arena != null and arena.has_method("is_all_floor_lava") and arena.is_all_floor_lava()


func _bot_is_lava_safe_at(world_pos: Vector3) -> bool:
	if not _bot_on_lava_map():
		return true
	var arena := _bot_get_arena()
	if arena and arena.has_method("is_lava_spawn_safe"):
		return arena.is_lava_spawn_safe(world_pos)
	return true


func _bot_may_take_lava_risk() -> bool:
	# Timed lapse window set in _bot_physics — every safety probe within one
	# maneuver agrees, instead of each call rolling its own dice.
	return _bot_lava_risk_timer > 0.0


func _bot_edge_probe_dist() -> float:
	return BOT_LAVA_EDGE_PROBE_DIST if _bot_on_lava_map() else BOT_EDGE_PROBE_DIST


func _bot_has_floor_at(world_pos: Vector3) -> bool:
	var origin: Vector3 = world_pos + Vector3.UP * 0.8
	var target: Vector3 = origin + Vector3.DOWN * 3.5
	var q: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(origin, target, 1)
	q.exclude = [get_rid()]
	return not get_world_3d().direct_space_state.intersect_ray(q).is_empty()


func _bot_move_is_lava_safe(move_dir: Vector3, look_ahead: float = -1.0) -> bool:
	if not _bot_on_lava_map() or move_dir.length_squared() < 0.001:
		return true
	if look_ahead < 0.0:
		look_ahead = _bot_edge_probe_dist()
	var dir: Vector3 = move_dir.normalized()
	for dist in [0.9, 1.6, look_ahead]:
		var probe: Vector3 = global_position + dir * dist
		if not _bot_is_lava_safe_at(probe):
			return false
		if not _bot_has_floor_at(probe):
			return false
	return true


func _bot_lava_safe_move_dir(preferred: Vector3) -> Vector3:
	if preferred.length_squared() > 0.01 and _bot_move_is_lava_safe(preferred):
		return preferred.normalized()
	var arena := _bot_get_arena()
	var center: Vector3 = arena.global_position if arena else Vector3.ZERO
	var to_center := Vector3(center.x - global_position.x, 0.0, center.z - global_position.z)
	var candidates: Array[Vector3] = []
	if to_center.length_squared() > 0.01:
		var tc := to_center.normalized()
		candidates.append(tc)
		candidates.append(Vector3(-tc.z, 0.0, tc.x))
		candidates.append(Vector3(tc.z, 0.0, -tc.x))
	for cand in candidates:
		if _bot_move_is_lava_safe(cand):
			return cand
	for fallback in [Vector3.BACK, Vector3.FORWARD, Vector3.LEFT, Vector3.RIGHT]:
		var world_fallback: Vector3 = (global_transform.basis * fallback).normalized()
		world_fallback.y = 0.0
		if world_fallback.length_squared() > 0.01 and _bot_move_is_lava_safe(world_fallback):
			return world_fallback.normalized()
	return Vector3.ZERO


func _bot_nearest_strike_flat_dist() -> float:
	var best := INF
	for group_name in ["air_strike_markers", "ion_cannon_markers"]:
		for node in get_tree().get_nodes_in_group(group_name):
			if not is_instance_valid(node):
				continue
			if not node.has_method("get"):
				continue
			var target_pos_val: Variant = node.get("target_pos")
			if typeof(target_pos_val) != TYPE_VECTOR3:
				continue
			var target: Vector3 = target_pos_val
			var flat_dist: float = Vector2(
				global_position.x - target.x,
				global_position.z - target.z,
			).length()
			best = minf(best, flat_dist)
	return best


func _bot_strike_flee_dir() -> Vector3:
	var best_target: Vector3 = Vector3.ZERO
	var best_dist := INF
	for group_name in ["air_strike_markers", "ion_cannon_markers"]:
		for node in get_tree().get_nodes_in_group(group_name):
			if not is_instance_valid(node):
				continue
			if not node.has_method("get"):
				continue
			var target_pos_val: Variant = node.get("target_pos")
			if typeof(target_pos_val) != TYPE_VECTOR3:
				continue
			var target: Vector3 = target_pos_val
			var flat_dist: float = Vector2(
				global_position.x - target.x,
				global_position.z - target.z,
			).length()
			if flat_dist < best_dist:
				best_dist = flat_dist
				best_target = target
	if best_dist >= BOT_AIR_STRIKE_FLEE_RADIUS:
		return Vector3.ZERO
	var away := global_position - best_target
	away.y = 0.0
	if away.length_squared() < 0.01:
		away = Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0))
	away = away.normalized()
	if _bot_on_lava_map() and not _bot_may_take_lava_risk():
		return _bot_lava_safe_move_dir(away)
	return away


func _bot_has_floor_ahead(move_dir: Vector3, distance: float) -> bool:
	if move_dir.length_squared() <= 0.001:
		return true
	var dir: Vector3 = move_dir.normalized()
	var origin: Vector3 = global_position + dir * distance + Vector3.UP * 0.8
	var target: Vector3 = origin + Vector3.DOWN * 3.0
	var q: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(origin, target, 1)
	q.exclude = [get_rid()]
	var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return false
	if _bot_on_lava_map() and not _bot_may_take_lava_risk():
		var ahead: Vector3 = global_position + dir * distance
		if not _bot_is_lava_safe_at(ahead):
			return false
		var landing: Vector3 = hit.get("position", ahead)
		if not _bot_is_lava_safe_at(landing + Vector3.UP * 0.9):
			return false
	return true

func _bot_gap_landing_distance(move_dir: Vector3) -> float:
	if move_dir.length_squared() <= 0.001:
		return 0.0
	var dir: Vector3 = move_dir.normalized()
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var landing_probes: Array[float] = [BOT_GAP_JUMP_MIN_LANDING, 6.5, 8.5, 10.5, BOT_GAP_JUMP_MAX_LANDING]
	for distance: float in landing_probes:
		var origin: Vector3 = global_position + dir * distance + Vector3.UP * 3.0
		var target: Vector3 = origin + Vector3.DOWN * 9.0
		var q: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(origin, target, 1)
		q.exclude = [get_rid()]
		var hit: Dictionary = space.intersect_ray(q)
		if hit.is_empty():
			continue
		var landing_pos: Vector3 = hit.get("position", origin)
		if _bot_on_lava_map() and not _bot_may_take_lava_risk():
			if not _bot_is_lava_safe_at(landing_pos + Vector3.UP * 0.9):
				continue
		var landing_y := landing_pos.y
		if landing_y >= global_position.y - 4.5 and landing_y <= global_position.y + 3.5:
			return float(distance)
	return 0.0

func _tick_footsteps(delta: float) -> void:
	if ghost_mode or not is_on_floor() or dash_timer > 0.0:
		_step_distance = 0.0
		return
	var moved: float = Vector2(velocity.x, velocity.z).length() * delta
	if moved < 0.01:
		_step_distance = 0.0
		return
	_step_distance += moved
	if _step_distance >= STEP_STRIDE:
		_step_distance = 0.0
		# Body-scale-driven footstep weight. Use the geometric mean of all
		# three axes so SLENDERMAN-style stretch (tall, narrow) reads close
		# to 1.0, while CHONKY (uniform 1.5×) clearly thumps deeper.
		var axes := weapon.body_scale_axes
		var ax: float = pow(maxf(0.05, axes.x * axes.y * axes.z), 1.0 / 3.0)
		var size: float = weapon.body_scale * ax
		SFX.footstep(global_position, size)

func _bot_find_target() -> Node3D:
	# Pick the nearest non-ghost enemy. In versus, bots fight everything; in
	# co-op, the game scene defines bot-vs-human teams.
	var best: Node3D = null
	var best_d: float = INF
	var game_scene := get_tree().current_scene
	for p in get_parent().get_children():
		if p == self:
			continue
		if not p.is_in_group("players"):
			continue
		if p.get("ghost_mode") == true:
			continue
		if game_scene and game_scene.has_method("are_players_allied") \
				and game_scene.are_players_allied(player_id, int(p.get("player_id"))):
			continue
		var p3 := p as Node3D
		if p3 == null:
			continue
		var d: float = global_position.distance_squared_to(p3.global_position)
		if d < best_d:
			best_d = d
			best = p3
	return best

func _bot_has_los(target: Node3D) -> bool:
	var from := global_position + Vector3.UP * 0.7
	var to: Vector3 = target.global_position + Vector3.UP * 0.4
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = 1  # world only
	q.exclude = get_hitbox_rids()
	return get_world_3d().direct_space_state.intersect_ray(q).is_empty()


func _bot_find_pickup() -> Node3D:
	# Nearest landed, uncollected pickup within notice range and roughly on
	# our level. Lava-unsafe drop spots are ignored outright.
	var best: Node3D = null
	var best_d := BOT_PICKUP_RANGE * BOT_PICKUP_RANGE
	for node in get_tree().get_nodes_in_group("pickups"):
		var p := node as Node3D
		if p == null or not is_instance_valid(p):
			continue
		if p.get("_grounded") != true or p.get("_collected") == true:
			continue
		var dy: float = p.global_position.y - global_position.y
		if dy > 3.0 or dy < -6.0:
			continue
		if not _bot_is_lava_safe_at(p.global_position):
			continue
		var d: float = global_position.distance_squared_to(p.global_position)
		if d < best_d:
			best_d = d
			best = p
	return best


# A wall within ~2.2m at chest height whose top is reachable with jump +
# double jump → return the ledge height (0 = nothing mountable). Too-tall
# walls fail naturally: the roof probe starts inside the building and rays
# don't hit from inside.
func _bot_climbable_ledge_height(move_dir: Vector3) -> float:
	var dir: Vector3 = move_dir.normalized()
	var space := get_world_3d().direct_space_state
	var from: Vector3 = global_position + Vector3.UP * 0.9
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * 2.2, 1)
	q.exclude = [get_rid()]
	var wall: Dictionary = space.intersect_ray(q)
	if wall.is_empty():
		return 0.0
	var wall_pos: Vector3 = wall.get("position", from)
	var over := Vector3(wall_pos.x, global_position.y + BOT_CLIMB_MAX_HEIGHT + 0.8, wall_pos.z) + dir * 0.6
	var q2 := PhysicsRayQueryParameters3D.create(over, over + Vector3.DOWN * (BOT_CLIMB_MAX_HEIGHT + 1.2), 1)
	q2.exclude = [get_rid()]
	var roof: Dictionary = space.intersect_ray(q2)
	if roof.is_empty():
		return 0.0
	var h: float = float((roof.get("position") as Vector3).y) - global_position.y
	if h < BOT_CLIMB_MIN_HEIGHT or h > BOT_CLIMB_MAX_HEIGHT:
		return 0.0
	if _bot_on_lava_map() and not _bot_is_lava_safe_at((roof.get("position") as Vector3) + Vector3.UP * 0.9):
		return 0.0
	return h


# RMB: cast the special when it makes sense for its kind. Called on a lazy
# think cadence with cooldown ready and line of sight held.
func _bot_try_special(dist: float) -> void:
	var sp: String = weapon.special
	if _air_strike_charges > 0:
		sp = Weapon.SPECIAL_AIR_STRIKE  # pickup charge overrides the equipped special
	match sp:
		Weapon.SPECIAL_ZOOM:
			return  # aiming aid — nothing for a bot to cast
		Weapon.SPECIAL_SWORD:
			if dist > 4.5:
				return
		Weapon.SPECIAL_TELEPORT:
			# Blink toward far targets. Skipped on lava maps — the destination
			# ray is blind to what it lands on.
			if dist < 13.0 or _bot_on_lava_map() or randf() < 0.4:
				return
		Weapon.SPECIAL_AIR_STRIKE, Weapon.SPECIAL_ION_CANNON:
			if dist < 9.0 or randf() < 0.35:
				return
		_:
			# Grenade / cluster — lob at mid range.
			if dist < 5.0 or dist > 30.0 or randf() < 0.35:
				return
	_bot_aim_camera_at_target(sp)
	_use_special()


# Specials aim along the camera; bots park theirs on the tracked aim point
# (same wobble as gunfire), lofted for grenade arcs.
func _bot_aim_camera_at_target(sp: String) -> void:
	if camera == null or _bot_target == null or not is_instance_valid(_bot_target):
		return
	var aim: Vector3 = _bot_aim_point if _bot_aim_point != Vector3.ZERO \
		else _bot_target.global_position + Vector3.UP * 0.4
	if sp == Weapon.SPECIAL_GRENADE or sp == Weapon.SPECIAL_CLUSTER_GRENADE:
		aim += Vector3.UP * global_position.distance_to(aim) * 0.22
	if camera.global_position.distance_squared_to(aim) > 0.01:
		camera.look_at(aim, Vector3.UP)

func _bot_shoot() -> bool:
	if _bot_target == null or not is_instance_valid(_bot_target):
		return false
	if reloading:
		return false
	if mag <= 0:
		_start_reload()
		return false
	mag -= 1
	var last_in_mag := mag <= 0
	var from := global_position + Vector3.UP * 0.7
	# Shoot at where the crosshair IS (the slew-limited aim point tracked in
	# _bot_physics), not at the target's true position — a fast close strafe
	# means the bullets land behind the strafe, like a human losing the track.
	var to: Vector3 = _bot_aim_point if _bot_aim_point != Vector3.ZERO \
		else _bot_target.global_position + Vector3.UP * 0.4
	var dist := from.distance_to(to)

	# --- Target Leading (Projectiles) ---
	# To be "realistic", the bot should try to lead the target based on its velocity.
	# We'll add some intentional error to this leading so it's not perfect.
	var target_vel := Vector3.ZERO
	if "velocity" in _bot_target:
		target_vel = _bot_target.velocity

	var bullet_speed := weapon.get_bullet_speed()
	var time_to_hit := dist / maxf(bullet_speed, 1.0)

	# Lead the target, but with sloppier "reaction lag" so prediction whiffs.
	var lead_multiplier := randf_range(0.55, 1.15)
	var predicted_pos := to + target_vel * time_to_hit * lead_multiplier

	# Error scales with how fast the target is moving — a standing player is
	# an easy shot, a dashing one genuinely hard to track — and shrinks the
	# longer the bot has held line of sight (settling in).
	var speed_err: float = clampf(target_vel.length() / 7.0, 0.2, 1.4)
	var settle: float = clampf(1.6 - _bot_los_time * 0.45, 0.6, 1.6)
	predicted_pos += _bot_aim_wander * clampf(dist / 16.0, 0.5, 2.2) * settle * speed_err

	var dir := (predicted_pos - from).normalized()

	# --- Refined Spread ---
	# Wobble grows with target speed and distance so long-range fights don't
	# feel like a sniper duel, but a stationary target gets punished.
	var base_spread := 0.018 + 0.03 * speed_err
	var dist_factor := clampf(dist / 40.0, 0.0, 2.0)
	var spread := base_spread + (BOT_SPREAD * 0.7 * dist_factor) * (0.4 + 0.6 * speed_err)

	# Every so often the bot whiffs harder — mostly against movers.
	if randf() < BOT_MISS_CHANCE * speed_err:
		spread *= randf_range(2.5, 5.0)

	var shots := weapon.get_shots_per_trigger()
	var right := Vector3.UP.cross(dir)
	if right.length_squared() <= 0.0001:
		right = Vector3.RIGHT
	else:
		right = right.normalized()
	for _i in shots:
		var shot_dir := dir
		var yaw := randf_range(-spread, spread)
		var pitch := randf_range(-spread, spread)
		shot_dir = shot_dir.rotated(Vector3.UP, yaw).rotated(right, pitch)
		_rifle_fired.rpc(from, shot_dir.normalized(), player_id, last_in_mag)
	# NOTE: intentionally no _cycle_first_person_gun() here — bots skip the
	# first-person heat/bolt/casing-eject for perf. All shared gameplay effects
	# (bullet spawn, damage, music, third-person casing, SFX) live in _rifle_fired.
	if mag <= 0:
		_start_reload()
	return true
