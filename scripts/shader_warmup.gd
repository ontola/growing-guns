class_name ShaderWarmup extends RefCounted

const GRENADE_SCRIPT := preload("res://scripts/grenade.gd")
const ION_CANNON_SCRIPT := preload("res://scripts/ion_cannon.gd")
const PLAYER_SCRIPT := preload("res://scripts/player.gd")
const PROCEDURAL_GUN_SCRIPT := preload("res://scripts/procedural_gun.gd")
const DEMON_GROWTH_SCRIPT := preload("res://scripts/demon_growth.gd")

# Process-wide — GPU PSOs stay compiled after the first warmup pass.
static var effect_shaders_warmed: bool = false


static func find_arena_generator(root: Node) -> ArenaGenerator:
	if root == null:
		return null
	if root is ArenaGenerator:
		return root as ArenaGenerator
	for child in root.get_children():
		var found := find_arena_generator(child)
		if found != null:
			return found
	return null


# Compile every combat effect + destructible rock shader once per session.
# Call from the menu during idle time so match start never waits on this.
static func warmup_effect_shaders(scene_root: Node, force_draw: bool = true) -> void:
	if effect_shaders_warmed or scene_root == null:
		return
	var arena_gen := find_arena_generator(scene_root)
	if arena_gen == null:
		return
	effect_shaders_warmed = true
	Trace.span_begin("shader_warmup (session)")
	Violence.prewarm_disintegration_cache()
	GRENADE_SCRIPT.warmup_shaders(scene_root)
	GRENADE_SCRIPT.warmup_scene(scene_root)
	Violence.warmup_blast_materials(scene_root)
	ION_CANNON_SCRIPT.warmup_shaders(scene_root)
	PLAYER_SCRIPT.warmup_phoenix_shaders(scene_root)
	Violence.warmup_gib_render(scene_root)
	GpuDebris.warmup(scene_root)
	arena_gen.warmup_gpu_materials(scene_root)
	_warmup_gun_growth(scene_root)
	_warmup_card_holo(scene_root)
	if force_draw and DisplayServer.get_name() != "headless":
		RenderingServer.force_draw(true)
	Trace.span_end("shader_warmup (session)")


# GameNight warms the match minimised, and a minimised window draws nothing:
# the warmup above built every effect, but no frame ever drew them, so their
# pipelines still compiled mid-match on first use (a headshot's gore, the
# card pick). Run it again on the first frames the party actually sees, while
# the cages are still lowering everyone in.
static var _rewarmed_on_screen := false

static func rewarm_on_screen(scene_root: Node) -> void:
	if _rewarmed_on_screen:
		return  # pipelines stay compiled for the rest of the process
	_rewarmed_on_screen = true
	# Give the window a moment to come back from minimised first.
	await scene_root.get_tree().create_timer(0.3).timeout
	if not is_instance_valid(scene_root) or not scene_root.is_inside_tree():
		_rewarmed_on_screen = false
		return
	effect_shaders_warmed = false
	warmup_effect_shaders(scene_root)


# The card pick's holo sheen is a canvas shader drawn over every card. Draw
# it once, one pixel, nearly transparent, so the first pick doesn't compile it.
static func _warmup_card_holo(scene_root: Node) -> void:
	var layer := CanvasLayer.new()
	layer.name = "CardHoloWarmup"
	scene_root.add_child(layer)
	var rect := ColorRect.new()
	rect.size = Vector2.ONE
	rect.modulate.a = 0.01
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	mat.shader = RenderPlayer.holo_shader()
	rect.material = mat
	layer.add_child(rect)
	scene_root.get_tree().create_timer(0.6).timeout.connect(layer.queue_free)


# The living-gun growth (gun_flesh.gdshader + bone/eye materials) only exists
# once cards stack corruption, so its first draw used to land mid-match at
# card-pick time — a measured ~100ms engine-side pipeline stall. Build a
# max-corruption growth on a throwaway gun at sub-pixel scale (same pattern
# as Violence.warmup_material: visible to the camera so the PSOs actually
# compile, too small to see) and free it after the warmup frames.
static func _warmup_gun_growth(scene_root: Node) -> void:
	var rig := Node3D.new()
	rig.name = "GunGrowthWarmup"
	rig.position = Vector3(0.0, 2.0, 0.0)
	rig.scale = Vector3.ONE * 0.001
	scene_root.add_child(rig)
	var gun: Node3D = PROCEDURAL_GUN_SCRIPT.new()
	gun.name = "WarmupGun"
	rig.add_child(gun)
	var growth: Node3D = DEMON_GROWTH_SCRIPT.new()
	growth.name = "WarmupGrowth"
	growth.set("gun_path", NodePath("../WarmupGun"))
	rig.add_child(growth)
	growth.set("corruption", 1.0)  # every stage's parts: flesh, bone, teeth, eye
	var cleanup := scene_root.get_tree().create_timer(0.6)
	cleanup.timeout.connect(rig.queue_free)
