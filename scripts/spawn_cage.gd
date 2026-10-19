class_name SpawnCage
extends Node3D

# Round-start gladiator cage (player.gd enter_spawn_cage / release_spawn_cage):
# hangs from a chain above the spawn point, holds the fighter while their gun
# growth morph plays, then the floor swings open, the fighter drops, and the
# cage is winched back up into the sky and freed.
#
# Pure set dressing — the caged player is `frozen` (physics skipped), so the
# cage needs no collision. Every peer builds its own copy from the same RPC,
# nothing to sync.

const IRON := Color(0.13, 0.13, 0.15)
const W := 2.6         # inner width
const H := 3.4         # bar height
const BAR_R := 0.035
const BAR_SPACING := 0.42
# Long enough that the chain top stays hidden in the sky haze even at the
# low hold position — the cage should read as hanging from nowhere visible.
const CHAIN_LEN := 90.0
# Winched far past the fog ceiling before freeing, so the cage visibly
# leaves the arena instead of vanishing in thin air.
const WINCH_RISE := 140.0
const WINCH_SECONDS := 7.0

var _floor_l: Node3D = null
var _floor_r: Node3D = null
var _mat: StandardMaterial3D = null
var _descend_tween: Tween = null

func _ready() -> void:
	_mat = StandardMaterial3D.new()
	_mat.albedo_color = IRON
	_mat.roughness = 0.55
	_mat.metallic = 0.5
	var hw := W * 0.5
	# Corner posts + top/bottom rim frames.
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			_box(Vector3(0.1, H, 0.1), Vector3(sx * hw, H * 0.5, sz * hw))
	for y in [0.0, H]:
		_box(Vector3(W + 0.2, 0.09, 0.14), Vector3(0.0, y, -hw))
		_box(Vector3(W + 0.2, 0.09, 0.14), Vector3(0.0, y, hw))
		_box(Vector3(0.14, 0.09, W + 0.2), Vector3(-hw, y, 0.0))
		_box(Vector3(0.14, 0.09, W + 0.2), Vector3(hw, y, 0.0))
	# Bars on all four sides.
	var n := int(W / BAR_SPACING)
	for i in n:
		var off := (float(i) + 0.5) / float(n) * W - hw
		_bar(Vector3(off, H * 0.5, -hw))
		_bar(Vector3(off, H * 0.5, hw))
		_bar(Vector3(-hw, H * 0.5, off))
		_bar(Vector3(hw, H * 0.5, off))
	# Solid top plate + chain up into the sky.
	_box(Vector3(W + 0.1, 0.07, W + 0.1), Vector3(0.0, H + 0.05, 0.0))
	var chain := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.05
	cm.bottom_radius = 0.05
	cm.height = CHAIN_LEN
	cm.radial_segments = 6
	chain.mesh = cm
	chain.material_override = _mat
	chain.position = Vector3(0.0, H + CHAIN_LEN * 0.5, 0.0)
	chain.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(chain)
	# Trapdoor floor: two halves hinged at the side rims, swung down by open().
	_floor_l = _floor_half(-1.0)
	_floor_r = _floor_half(1.0)

func _floor_half(side: float) -> Node3D:
	var pivot := Node3D.new()
	pivot.position = Vector3(side * W * 0.5, 0.0, 0.0)
	add_child(pivot)
	var plate := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(W * 0.5, 0.08, W)
	plate.mesh = bm
	plate.material_override = _mat
	plate.position = Vector3(-side * W * 0.25, 0.0, 0.0)
	plate.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pivot.add_child(plate)
	return pivot

# Crane descent: lower the cage by `drop` meters, decelerating into the hold
# position. The caged player is tweened on its authority peer with the SAME
# curve (player.gd enter_spawn_cage) — keep trans/ease in sync.
func descend(drop: float, duration: float) -> void:
	_descend_tween = create_tween()
	# Same tick as the player's matching descent (Player.enter_spawn_cage).
	_descend_tween.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	_descend_tween.tween_property(self, "position:y", position.y - drop, duration) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

# Swing the trapdoors open, hold a beat, then winch the cage up and free it.
func open() -> void:
	if _descend_tween and _descend_tween.is_valid():
		_descend_tween.kill()
	var tw := create_tween()
	tw.set_parallel(true)
	# Left pivot's plate extends +x: dropping it is a NEGATIVE z-rotation
	# (+x swings to -y); mirrored for the right half.
	tw.tween_property(_floor_l, "rotation:z", -1.9, 0.3) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tw.tween_property(_floor_r, "rotation:z", 1.9, 0.34) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tw.set_parallel(false)
	tw.tween_interval(0.8)
	# Slow crane retrieval — accelerates away and exits through the sky haze
	# long before it's freed.
	tw.tween_property(self, "position:y", position.y + WINCH_RISE, WINCH_SECONDS) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_callback(queue_free)

func _box(size: Vector3, pos: Vector3) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = _mat
	mi.position = pos
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)

func _bar(pos: Vector3) -> void:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = BAR_R
	cm.bottom_radius = BAR_R
	cm.height = H
	cm.radial_segments = 6
	mi.mesh = cm
	mi.material_override = _mat
	mi.position = pos
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
