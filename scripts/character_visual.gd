class_name CharacterVisual
extends Node3D

const KNIGHT_SCENE := preload("res://assets/models/knight.fbx")

# Character variants — Mixamo-rigged humanoids. Any FBX with a Mixamo
# skeleton drops in unmodified: bone lookups are prefix-tolerant (plain,
# mixamorig_*, mixamorig5_*, …) and animation clips are retargeted onto the
# actual rig at import time (_retarget_clip_to_skeleton). Ragdolls, gibs and
# wounds are generated from the skeleton, so variants inherit all of it.
const VARIANT_SCENES: Array[PackedScene] = [
	preload("res://assets/models/knight.fbx"),
	preload("res://assets/models/paladin.fbx"),
	preload("res://assets/models/ch10.fbx"),  # the classic shambling zombie
	# zombie.fbx (the hulking Avelange brute) is benched: its skeleton's rest
	# pose diverges from the knight-authored animation tracks, so the spine
	# bends ~90° when our clips play. Bringing it back needs real retargeting
	# (SkeletonProfile/BoneMap), not just track renaming.
]

const ANIM_FILES := {
	"pistol_idle": "res://assets/animations/Pistol Idle.fbx",
	"pistol_run": "res://assets/animations/Pistol Run.fbx",
	"pistol_jump": "res://assets/animations/Pistol Jump.fbx",
}

const ONE_SHOT_CLIPS: Array[String] = ["pistol_jump"]

# Mixamo knight rest pose faces +Z; rotate 180° so mesh forward matches Godot -Z.
const MODEL_ROTATION_DEGREES := Vector3(0.0, 180.0, 0.0)
# Capsule bottom is y=-0.9; idle toe bones sit near y=0 in model space.
# Third-person weapon mount — matches player.gd _setup_third_person_gun layering:
# WeaponAnchor (offset) → ThirdPersonGun (aim pitch) → gun (offset + barrel align).
# The WeaponAnchor is aligned with the BODY (x right, y up, -z forward), not
# with the hand bone, so these read in plain body terms: the gun sits level,
# magazine down, with its pistol grip in the palm. (The old hand-space Euler
# mount rolled the rifle 180°, so every third-person gun was upside down.)
const WEAPON_ROOT_ROTATION_DEGREES := Vector3.ZERO
const WEAPON_MOUNT_POSITION := Vector3(0.0, 0.085, -0.143)
const WEAPON_MOUNT_ROTATION_DEGREES := Vector3.ZERO
const FOOT_OFFSET_Y := -0.9
const LEG_TWIST_MAX := deg_to_rad(65.0)

@export var foot_align_capsule: bool = true
# -1 = derive from the owning player's player_id, so every peer independently
# picks the same skin with zero netcode. Set explicitly in labs/tools.
@export var variant: int = -1

var enabled: bool = true
var ready_ok: bool = false

var _model_scene: PackedScene = KNIGHT_SCENE
var _pending_bone_warps: Dictionary = {}  # survives set_variant rebuilds
var _warped_bones: Array[int] = []
var _model: Node3D
var _skeleton: Skeleton3D
var _anim_player: AnimationPlayer
var _anim_tree: AnimationTree
var _weapon_anchor: Node3D
var _blob_rig: Node3D
var _loco_blend: float = 0.0
var _jump_active: bool = false
var _aim_pose: AimPose = null
var _leg_yaw: float = 0.0
var _identity_color := Color(0, 0, 0, 0)  # alpha 0 = none
var _crest: MeshInstance3D = null
var _head_attach: BoneAttachment3D = null
var _play_dir: float = 1.0
## Vertical aim in radians, positive = looking up (same sign as the camera's
## rotation.x). The spine bends toward it and the gun pitches with it.
var aim_pitch: float = 0.0:
	set(v):
		aim_pitch = clampf(v, -1.4, 1.4)
		if _aim_pose:
			_aim_pose.pitch = aim_pitch


func _ready() -> void:
	if get_parent() != null:
		_blob_rig = get_parent().get_node_or_null("BlobRig") as Node3D
	if enabled:
		_build()


func is_active() -> bool:
	return ready_ok and enabled and visible


func get_weapon_anchor() -> Node3D:
	return _weapon_anchor if ready_ok else null


func mount_third_person_weapon(node: Node3D) -> Node3D:
	if _weapon_anchor == null:
		return null
	var root := Node3D.new()
	root.name = "ThirdPersonGun"
	root.rotation_degrees = WEAPON_ROOT_ROTATION_DEGREES
	_weapon_anchor.add_child(root)
	node.position = WEAPON_MOUNT_POSITION
	node.rotation_degrees = WEAPON_MOUNT_ROTATION_DEGREES
	root.add_child(node)
	return root


func apply_weapon_transform(weapon: Node3D, _mount_root: Node3D, pos: Vector3, rot_deg: Vector3) -> void:
	if weapon == null:
		return
	weapon.position = pos
	weapon.rotation_degrees = rot_deg


func set_blob_rig(blob: Node3D) -> void:
	_blob_rig = blob
	if ready_ok and _blob_rig:
		_blob_rig.visible = false


func update_locomotion(planar_speed: float, reference_speed: float) -> void:
	if not is_active() or _anim_tree == null:
		return
	var ref := maxf(0.1, reference_speed)
	var blend := clampf(planar_speed / ref, 0.0, 1.0)
	set_locomotion_blend(blend)


## Direction-aware locomotion. `local_velocity` is the planar velocity in the
## player's own frame (-Z forward). The run clip only runs forward, so
## sideways movement turns the legs toward the travel direction while the
## spine keeps the chest and gun facing the aim, and backwards movement plays
## the run in reverse instead of moonwalking.
func update_locomotion_directional(local_velocity: Vector3, reference_speed: float, delta: float) -> void:
	if not is_active() or _anim_tree == null:
		return
	var planar := Vector2(local_velocity.x, -local_velocity.z)
	var speed := planar.length()
	var ref := maxf(0.1, reference_speed)
	set_locomotion_blend(clampf(speed / ref, 0.0, 1.0))
	var want_yaw := 0.0
	var want_dir := 1.0
	if speed > 0.6:
		var travel := planar / speed
		want_dir = -1.0 if travel.y < -0.2 else 1.0
		# Face the legs along the travel line, mirrored when backpedalling.
		var leg := travel * want_dir
		want_yaw = clampf(atan2(-leg.x, leg.y), -LEG_TWIST_MAX, LEG_TWIST_MAX)
	var k := clampf(delta * 10.0, 0.0, 1.0)
	_leg_yaw = lerpf(_leg_yaw, want_yaw, k)
	_play_dir = lerpf(_play_dir, want_dir, clampf(delta * 14.0, 0.0, 1.0))
	if _aim_pose:
		_aim_pose.hips_yaw = _leg_yaw
	# Cadence follows ground speed: a slowed player shouldn't sprint in place.
	var cadence := clampf(speed / ref, 0.75, 1.5) if speed > 0.6 else 1.0
	_anim_tree.set("parameters/speed/scale", _play_dir * cadence)


func set_locomotion_blend(blend: float) -> void:
	if not is_active() or _anim_tree == null:
		return
	_loco_blend = clampf(blend, 0.0, 1.0)
	if _jump_active:
		return
	use_locomotion_tree()
	_anim_tree.set("parameters/locomotion/blend_position", _loco_blend)


func play_jump() -> void:
	if not is_active() or _anim_player == null:
		return
	if not _anim_player.has_animation(&"loco/pistol_jump"):
		return
	_jump_active = true
	if _anim_tree:
		_anim_tree.active = false
	_anim_player.play(&"loco/pistol_jump")


func notify_landed() -> void:
	if _jump_active:
		_finish_jump()


func _finish_jump() -> void:
	_jump_active = false
	if _anim_tree == null:
		return
	use_locomotion_tree()
	_anim_tree.set("parameters/locomotion/blend_position", _loco_blend)


func use_locomotion_tree() -> void:
	if _anim_tree:
		_anim_tree.active = true


func get_clip_names() -> PackedStringArray:
	var out := PackedStringArray()
	if _anim_player == null:
		return out
	var lib: AnimationLibrary = _anim_player.get_animation_library("loco")
	if lib == null:
		return out
	for anim_name: String in lib.get_animation_list():
		out.append(anim_name)
	return out


func play_clip(clip_name: String) -> void:
	if not is_active() or _anim_player == null:
		return
	if _anim_tree:
		_anim_tree.active = false
	_jump_active = clip_name == "pistol_jump"
	var path := "loco/%s" % clip_name
	if _anim_player.has_animation(path):
		_anim_player.play(path)


func import_animation_clip(slot_name: String, path: String) -> bool:
	if not ready_ok or _anim_player == null:
		return false
	var lib: AnimationLibrary = _anim_player.get_animation_library("loco")
	if lib == null:
		return false
	if lib.has_animation(slot_name):
		return true
	_import_anim_clip(lib, slot_name, path)
	return lib.has_animation(slot_name)


func scan_animation_dir(dir_path: String = "res://assets/animations/") -> PackedStringArray:
	var added := PackedStringArray()
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return added
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(".fbx"):
			var slot := file_name.get_basename()
			slot = slot.to_lower().replace(" ", "_")
			var full := dir_path.path_join(file_name)
			if import_animation_clip(slot, full):
				added.append(slot)
		file_name = dir.get_next()
	dir.list_dir_end()
	return added


func collect_meshes(out: Array[MeshInstance3D]) -> void:
	if _model == null:
		return
	Violence.collect_meshes(_model, out)


func get_camera_pivot() -> Vector3:
	if _skeleton != null:
		var hips_idx := find_bone_any(_skeleton, "Hips")
		if hips_idx >= 0:
			var local := _skeleton.get_bone_global_pose(hips_idx).origin
			return _skeleton.global_transform * local
	return global_position + Vector3(0.0, 1.0, 0.0)


# Case-exact bone lookup first, then tolerate Mixamo namespace prefixes
# ("mixamorig:Hips" imports as "mixamorig_Hips", numbered rigs as
# "mixamorig5_Hips"). Suffix match is safe: "_Spine" never matches "Spine1".
static func find_bone_any(skel: Skeleton3D, plain: String) -> int:
	var idx := skel.find_bone(plain)
	if idx >= 0:
		return idx
	var suffix := "_" + plain
	for i in skel.get_bone_count():
		if skel.get_bone_name(i).ends_with(suffix):
			return i
	return -1


func get_model_scene() -> PackedScene:
	return _model_scene


# Swap to a different roster model at runtime (co-op enemy skins). Returns
# true when the model actually changed — the caller must re-mount the
# third-person weapon, since the hand anchor died with the old skeleton.
func set_variant(v: int) -> bool:
	v = posmod(v, VARIANT_SCENES.size())
	if ready_ok and v == variant:
		return false
	variant = v
	_teardown()
	if enabled:
		_build()
	return true


# Per-bone visual scales by plain Mixamo bone name ("Head" -> Vector3(1.8,
# 1.8, 1.8)) — how cards warp PARTS of the body instead of shearing the whole
# model. Bone pose scale persists because our clips carry no scale tracks
# (position + rotation only); if future animations animate scale, this needs
# to move into a SkeletonModifier3D. Scale inherits down the bone chain, so
# counter-scale children explicitly in the map if that's unwanted. Kept and
# re-applied across variant swaps; ragdoll clones copy the pose, so a BIG
# HEAD corpse keeps its big head.
func apply_bone_warps(by_plain_name: Dictionary) -> void:
	_pending_bone_warps = by_plain_name
	_apply_pending_bone_warps()


func _apply_pending_bone_warps() -> void:
	if _skeleton == null:
		return
	# Reset bones warped by a previous map that the new one no longer touches
	# (round reset clears cards; DICE can reroll body stats).
	for idx in _warped_bones:
		_skeleton.set_bone_pose_scale(idx, Vector3.ONE)
	_warped_bones.clear()
	for plain in _pending_bone_warps:
		var idx := find_bone_any(_skeleton, str(plain))
		if idx >= 0:
			_skeleton.set_bone_pose_scale(idx, _pending_bone_warps[plain])
			_warped_bones.append(idx)


func _teardown() -> void:
	ready_ok = false
	_jump_active = false
	_hand_frame = null
	if _anim_tree:
		_anim_tree.queue_free()
		_anim_tree = null
	if _anim_player:
		_anim_player.queue_free()
		_anim_player = null
	if _model:
		_model.queue_free()
		_model = null
	_skeleton = null
	_weapon_anchor = null
	_aim_pose = null
	_crest = null
	_head_attach = null


func _derive_variant() -> int:
	# Walk up to the owning Player for its player_id — same id on every peer,
	# so everyone renders the same skin. Bots have consecutive ids and cycle
	# through the roster.
	var n: Node = get_parent()
	while n != null:
		var pid: Variant = n.get("player_id")
		if typeof(pid) == TYPE_INT:
			return posmod(int(pid), VARIANT_SCENES.size())
		n = n.get_parent()
	return randi() % VARIANT_SCENES.size()


func _build() -> void:
	if variant < 0:
		variant = _derive_variant()
	_model_scene = VARIANT_SCENES[variant % VARIANT_SCENES.size()]
	_model = (_model_scene.instantiate() as Node3D)
	if _model == null:
		push_warning("CharacterVisual: failed to instance character variant %d" % variant)
		return
	_model.name = "KnightModel"
	add_child(_model)
	_model.rotation_degrees = MODEL_ROTATION_DEGREES
	position.y = FOOT_OFFSET_Y if foot_align_capsule else 0.0

	_skeleton = _model.find_child("Skeleton3D", true, false) as Skeleton3D
	if _skeleton == null:
		push_warning("CharacterVisual: knight has no Skeleton3D")
		_model.queue_free()
		_model = null
		return

	# Pre-bake this rig's gib variants off-thread so the first disintegration
	# doesn't Voronoi a many-thousand-tri skinned mesh synchronously mid-death.
	# All knights share the FBX's mesh resources, so this warms once per process.
	Violence.gib_warm_tree(_model, Violence.KNIGHT_GIB_CHUNK_COUNT)

	_anim_player = AnimationPlayer.new()
	_anim_player.name = "AnimationPlayer"
	add_child(_anim_player)
	_anim_player.root_node = _anim_player.get_path_to(_model)
	_anim_player.animation_finished.connect(_on_animation_finished)

	var loco_lib := AnimationLibrary.new()
	_anim_player.add_animation_library("loco", loco_lib)
	for slot_name: String in ANIM_FILES:
		_import_anim_clip(loco_lib, slot_name, ANIM_FILES[slot_name])

	if not _has_locomotion_clips(loco_lib):
		push_warning("CharacterVisual: missing locomotion clips (need pistol_idle + pistol_run)")
		_model.queue_free()
		_model = null
		return

	_setup_anim_tree()
	_anim_tree.set("parameters/speed/scale", 1.0)
	_aim_pose = AimPose.new()
	_aim_pose.body = self
	_aim_pose.pitch = aim_pitch
	_aim_pose.setup(_skeleton)
	# Applied right after the clips write their pose (both the blend tree and
	# the jump one-shot are mixers), so the layer never accumulates.
	_anim_tree.mixer_applied.connect(_aim_pose.apply)
	_anim_player.mixer_applied.connect(_aim_pose.apply)
	_attach_weapon_anchor()
	_apply_identity()
	_warped_bones.clear()  # fresh skeleton — no stale indices
	_apply_pending_bone_warps()

	ready_ok = true
	if _blob_rig:
		_blob_rig.visible = false
	_anim_tree.set("parameters/locomotion/blend_position", 0.0)


func _import_anim_clip(loco_lib: AnimationLibrary, slot_name: String, path: String) -> void:
	if not ResourceLoader.exists(path):
		push_warning("CharacterVisual: missing animation %s" % path)
		return
	var inst: Node = (load(path) as PackedScene).instantiate()
	var src_ap: AnimationPlayer = inst.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if src_ap == null:
		inst.free()
		return
	for lib_name: String in src_ap.get_animation_library_list():
		var lib: AnimationLibrary = src_ap.get_animation_library(lib_name)
		for anim_name: String in lib.get_animation_list():
			var anim: Animation = lib.get_animation(anim_name).duplicate()
			anim.loop_mode = (
				Animation.LOOP_NONE if slot_name in ONE_SHOT_CLIPS else Animation.LOOP_LINEAR
			)
			_retarget_clip_to_skeleton(anim)
			loco_lib.add_animation(slot_name, anim)
			break
	inst.free()


# Anim FBXs address bones as "Armature/Skeleton3D:PlainName" (the knight's
# layout). Other rigs park the skeleton elsewhere and prefix bone names, so
# rewrite every track to THIS model's skeleton path + actual bone names.
#
# The knight rig animates the PELVIS via an extra "root" bone (parent of
# Hips; Hips itself has NO track and inherits). Rigs without a root bone
# can't just drop that track — the whole body loses its yaw frame and stands
# 90° twisted. Instead, synthesize a Hips rotation track on the target:
# q_hips(t) = q_root(t) * knight_hips_rest.
static var _src_hips_rest := Basis.IDENTITY
static var _src_skel_frame := Basis.IDENTITY
static var _src_frames_ok := false

# Basis of `node` relative to `root` (composition of node transforms).
static func _frame_in(root: Node3D, node: Node3D) -> Basis:
	var b := Basis.IDENTITY
	var n: Node = node
	while n != null and n != root and n is Node3D:
		b = (n as Node3D).transform.basis * b
		n = n.get_parent()
	return b.orthonormalized()


static func _bake_source_frames() -> void:
	if _src_frames_ok:
		return
	var inst := KNIGHT_SCENE.instantiate() as Node3D
	var skel := inst.find_child("Skeleton3D", true, false) as Skeleton3D
	if skel:
		_src_skel_frame = _frame_in(inst, skel)
		var i := skel.find_bone("Hips")
		if i >= 0:
			_src_hips_rest = skel.get_bone_rest(i).basis.orthonormalized()
	inst.free()
	_src_frames_ok = true


func _retarget_clip_to_skeleton(anim: Animation) -> void:
	if _model == null or _skeleton == null:
		return
	var skel_path := str(_model.get_path_to(_skeleton))
	var root_keys: Array = []  # [time, Quaternion] from the dropped root track
	# Pass 1: capture the dropped root rotation keys, remove tracks for
	# bones this rig doesn't have.
	for t in range(anim.get_track_count() - 1, -1, -1):
		var p := str(anim.track_get_path(t))
		var colon := p.find(":")
		if colon < 0:
			continue
		var bone := p.substr(colon + 1)
		if find_bone_any(_skeleton, bone) >= 0:
			continue
		if bone == "root" and anim.track_get_type(t) == Animation.TYPE_ROTATION_3D:
			for k in anim.track_get_key_count(t):
				root_keys.append([anim.track_get_key_time(t, k), anim.track_get_key_value(t, k)])
		anim.remove_track(t)
	# Pass 2: rename surviving tracks to this rig's skeleton path/bone names.
	for t in anim.get_track_count():
		var p := str(anim.track_get_path(t))
		var colon := p.find(":")
		if colon < 0:
			continue
		var idx := find_bone_any(_skeleton, p.substr(colon + 1))
		if idx < 0:
			continue
		var want := skel_path + ":" + _skeleton.get_bone_name(idx)
		if p != want:
			anim.track_set_path(t, NodePath(want))
	# Pass 3: synthesize the Hips rotation track from the dropped root.
	if root_keys.is_empty():
		return
	var hips_idx := find_bone_any(_skeleton, "Hips")
	if hips_idx < 0:
		return
	var hips_path := NodePath(skel_path + ":" + _skeleton.get_bone_name(hips_idx))
	for t in anim.get_track_count():
		if anim.track_get_type(t) == Animation.TYPE_ROTATION_3D and anim.track_get_path(t) == hips_path:
			return  # rig already had an animated Hips — nothing to synthesize
	# World pose the knight plays: src_skel_frame * root(t) * hips_rest.
	# This rig's Hips local sits directly in ITS skeleton frame, so conjugate:
	# q(t) = dst_frame⁻¹ * src_frame * root(t) * knight_hips_rest.
	_bake_source_frames()
	var dst_frame := _frame_in(_model, _skeleton)
	var pre := dst_frame.inverse() * _src_skel_frame
	var tr := anim.add_track(Animation.TYPE_ROTATION_3D)
	anim.track_set_path(tr, hips_path)
	for rk in root_keys:
		var q := (pre * Basis(rk[1] as Quaternion) * _src_hips_rest).get_rotation_quaternion()
		anim.rotation_track_insert_key(tr, float(rk[0]), q)


func _setup_anim_tree() -> void:
	_anim_tree = AnimationTree.new()
	_anim_tree.name = "AnimationTree"
	add_child(_anim_tree)
	_anim_tree.anim_player = _anim_player.get_path()

	var tree := AnimationNodeBlendTree.new()
	_anim_tree.tree_root = tree

	var idle_node := AnimationNodeAnimation.new()
	idle_node.animation = _loco_idle_clip()
	var run_node := AnimationNodeAnimation.new()
	run_node.animation = _loco_run_clip()

	var space := AnimationNodeBlendSpace1D.new()
	space.add_blend_point(idle_node, 0.0)
	space.add_blend_point(run_node, 1.0)
	space.min_space = 0.0
	space.max_space = 1.0
	space.sync = true

	tree.add_node("locomotion", space)
	var speed := AnimationNodeTimeScale.new()
	tree.add_node("speed", speed)
	tree.connect_node(&"speed", 0, &"locomotion")
	tree.connect_node(&"output", 0, &"speed")

	_anim_tree.active = true


func _has_locomotion_clips(loco_lib: AnimationLibrary) -> bool:
	var has_idle := loco_lib.has_animation("pistol_idle") or loco_lib.has_animation("idle")
	var has_run := loco_lib.has_animation("pistol_run") or loco_lib.has_animation("run")
	return has_idle and has_run


func _loco_idle_clip() -> StringName:
	if _anim_player.has_animation(&"loco/pistol_idle"):
		return &"loco/pistol_idle"
	return &"loco/idle"


func _loco_run_clip() -> StringName:
	if _anim_player.has_animation(&"loco/pistol_run"):
		return &"loco/pistol_run"
	return &"loco/run"


func _on_animation_finished(anim_name: StringName) -> void:
	if not _jump_active:
		return
	if String(anim_name).ends_with("pistol_jump"):
		_finish_jump()


# The weapon mount constants were hand-tuned against the KNIGHT's RightHand
# axes in the animated idle pose. Other rigs orient the hand bone differently
# (raw Mixamo vs the Blender-processed knight, extra twist bones on some),
# which left rifles rolled/floating. Rather than predicting the difference
# analytically, the corrective HandFrame is CALIBRATED one frame after build
# against the rig's real animated pose: whatever the hand's world orientation
# turns out to be, the frame maps it onto the knight's measured reference.
# REF_HAND_BASIS = the knight's animated RightHand attachment basis in
# CharacterVisual space (baked offline; re-bake if knight.fbx or the idle
# clip changes — see memory: character-variant-pipeline).
const REF_HAND_BASIS := Basis(Quaternion(-0.026479, 0.719259, -0.694106, -0.013500))

var _hand_frame: Node3D = null


func _attach_weapon_anchor() -> void:
	var attach := BoneAttachment3D.new()
	attach.name = "WeaponBoneAttachment"
	var hand_idx := find_bone_any(_skeleton, "RightHand")
	attach.bone_name = _skeleton.get_bone_name(hand_idx) if hand_idx >= 0 else "RightHand"
	_skeleton.add_child(attach)
	_hand_frame = Node3D.new()
	_hand_frame.name = "HandFrame"
	# top_level: the frame's POSITION rides the hand bone but its transform
	# is driven in WORLD space, outside the (possibly non-uniformly warped)
	# body hierarchy — SLENDERMAN/FLATFISH scale must neither shear nor
	# stretch the rifle.
	_hand_frame.top_level = true
	attach.add_child(_hand_frame)
	_weapon_anchor = Node3D.new()
	_weapon_anchor.name = "WeaponAnchor"
	# Undo the hand reference so the anchor's axes are the body's (pitched by
	# aim). Its origin stays on the hand bone.
	_weapon_anchor.basis = REF_HAND_BASIS.inverse()
	_hand_frame.add_child(_weapon_anchor)
	# Update in lock-step with the skeleton so the gun never lags the hand.
	_skeleton.skeleton_updated.connect(_update_hand_frame)
	_update_hand_frame()


# The gun's position follows the hand bone; its ORIENTATION is pinned to the
# knight-reference frame in body space every frame, so every rig's rifle sits
# level and magazine-down regardless of how its hand bone is oriented or how
# its idle animation drifts. The gun scales uniformly with overall body size
# (cbrt of the warp determinant), never with per-axis warps.
func _update_hand_frame() -> void:
	if _hand_frame == null or not is_instance_valid(_hand_frame) or not _hand_frame.is_inside_tree():
		return
	var attach := _hand_frame.get_parent() as Node3D
	var body: Basis = global_transform.basis
	var s: float = pow(maxf(absf(body.determinant()), 0.000001), 1.0 / 3.0)
	var rot: Basis = body.orthonormalized() * Basis(Vector3.RIGHT, aim_pitch) * REF_HAND_BASIS
	_hand_frame.global_transform = Transform3D(rot * s, attach.global_position)
	if _crest and is_instance_valid(_crest) and _head_attach:
		# Same trick as the hand: ride the head bone, but stay in body axes
		# so warped heads and odd bone rolls never tip the crest over.
		var up: Vector3 = body.orthonormalized().y
		var crest_basis: Basis = body.orthonormalized() * Basis(Vector3.RIGHT, aim_pitch * 0.5)
		_crest.global_transform = Transform3D(crest_basis * s, _head_attach.global_position + up * CREST_HEIGHT * s)


# Procedural upper-body layer on top of the clips: bends the spine toward the
# aim pitch (so the arms, and the gun in them, follow where the player looks)
# and twists the pelvis toward the travel direction for strafing while the
# spine untwists so the chest keeps facing the aim. Runs after each mixer
# pass, on bones the clips animate every frame, so nothing accumulates.
# (A SkeletonModifier3D would be the textbook tool, but with more than one
# rig on screen it blanked the whole frame under directional shadows.)
class AimPose extends RefCounted:
	## Share of the aim pitch taken by the spine. The rest is carried by the
	## gun's own pitch at the hand, so the bend never folds the torso in half.
	const SPINE_PITCH_SHARE := 0.75
	var pitch: float = 0.0
	var hips_yaw: float = 0.0
	var body: Node3D
	var _skel: Skeleton3D
	var _pelvis := -1
	var _spine: PackedInt32Array = []

	func setup(skel: Skeleton3D) -> void:
		_skel = skel
		# The knight animates a "root" bone above Hips (Hips itself has no
		# track); the other rigs animate Hips. Twist whichever one moves.
		var hips := CharacterVisual.find_bone_any(skel, "Hips")
		var parent := skel.get_bone_parent(hips) if hips >= 0 else -1
		_pelvis = parent if parent >= 0 and skel.get_bone_name(parent) == "root" else hips
		for b in ["Spine", "Spine1", "Spine2"]:
			var i := CharacterVisual.find_bone_any(skel, b)
			if i >= 0:
				_spine.append(i)

	func apply() -> void:
		if _skel == null or not is_instance_valid(_skel) or body == null or _spine.is_empty():
			return
		if is_zero_approx(pitch) and is_zero_approx(hips_yaw):
			return
		var to_skel := _skel.global_transform.basis.orthonormalized().inverse()
		var right := (to_skel * body.global_transform.basis.x).normalized()
		var up := (to_skel * body.global_transform.basis.y).normalized()
		if _pelvis >= 0 and not is_zero_approx(hips_yaw):
			_rotate_bone(_pelvis, up, hips_yaw)
		var n := float(_spine.size())
		for i in _spine:
			if not is_zero_approx(hips_yaw):
				_rotate_bone(i, up, -hips_yaw / n)
			# A positive turn about the body's right axis leans the chest back,
			# which is what looking up is.
			_rotate_bone(i, right, pitch * SPINE_PITCH_SHARE / n)

	# Rotate bone `idx` by `angle` about `axis` given in skeleton space.
	func _rotate_bone(idx: int, axis: Vector3, angle: float) -> void:
		var parent := _skel.get_bone_parent(idx)
		var parent_basis := _skel.get_bone_global_pose(parent).basis.orthonormalized() if parent >= 0 else Basis.IDENTITY
		var local_axis := (parent_basis.inverse() * axis).normalized()
		_skel.set_bone_pose_rotation(idx, Quaternion(local_axis, angle) * _skel.get_bone_pose_rotation(idx))


## Per-player colour so players can tell each other apart at a glance, also
## when two of them drew the same model: the outfit takes a tint of it and a
## bright crest in that colour rides on top of the head.
const CREST_HEIGHT := 0.24
const OUTFIT_TINT := 0.38

func set_identity_color(c: Color) -> void:
	_identity_color = c
	if ready_ok:
		_apply_identity()


func _apply_identity() -> void:
	if _model == null or _skeleton == null or _identity_color.a <= 0.0:
		return
	var meshes: Array[MeshInstance3D] = []
	Violence.collect_meshes(_model, meshes)
	var tint := Color.WHITE.lerp(_identity_color, OUTFIT_TINT)
	for mi in meshes:
		if mi.mesh == null:
			continue
		for i in mi.mesh.get_surface_count():
			var src := mi.mesh.surface_get_material(i) as BaseMaterial3D
			if src == null:
				continue
			# Duplicate: every player shares the FBX's materials.
			var mat := src.duplicate() as BaseMaterial3D
			mat.albedo_color = src.albedo_color * tint
			mi.set_surface_override_material(i, mat)
	if _crest == null:
		var head := find_bone_any(_skeleton, "Head")
		if head < 0:
			return
		_head_attach = BoneAttachment3D.new()
		_head_attach.name = "HeadAttachment"
		_head_attach.bone_name = _skeleton.get_bone_name(head)
		_skeleton.add_child(_head_attach)
		_crest = MeshInstance3D.new()
		_crest.name = "IdentityCrest"
		_crest.top_level = true
		_crest.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var box := BoxMesh.new()
		box.size = Vector3(0.05, 0.1, 0.3)
		_crest.mesh = box
		_head_attach.add_child(_crest)
	var crest_mat := StandardMaterial3D.new()
	crest_mat.albedo_color = _identity_color
	crest_mat.emission_enabled = true
	crest_mat.emission = _identity_color
	crest_mat.emission_energy_multiplier = 0.6
	crest_mat.roughness = 0.6
	_crest.material_override = crest_mat
