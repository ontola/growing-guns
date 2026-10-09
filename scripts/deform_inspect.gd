extends Node3D

# Visual inspector for GPU brick deformation. Each brick uses the same material
# setup as DestructibleSolid (R=decal, G=deform, dmg_vertex_deform on/off).
#
#   godot --path . res://scenes/deform_inspect.tscn -- capture=/tmp/inspect.png

const DestructibleSolid := preload("res://scripts/destructible_solid.gd")
const ArenaGenerator := preload("res://scripts/arena_generator.gd")

const BRICK := 2.0
const SPACING := 3.0
const NUM_CASES := 5
const RES := 384  # damage texture size, matches Splat2D.res

var _cam: Camera3D


class Splat2D:
	extends Node2D
	var pending: Array = []
	var brush: Texture2D
	var res: float = 384.0

	func _draw() -> void:
		for s: Dictionary in pending:
			var c: Vector2 = (s["uv"] as Vector2) * res
			var ru: float = float(s["ru"]) * res
			var rv: float = float(s["rv"]) * res
			draw_texture_rect(
				brush, Rect2(c - Vector2(ru, rv), Vector2(ru * 2.0, rv * 2.0)),
				false, Color(float(s["decal"]), float(s["deform"]), 0.0, 1.0))
		pending.clear()


func _ready() -> void:
	_build_world()
	var cases := [
		{"label": "centre-weak", "pos": Vector3(0.0, 0.0, 1.0), "nrm": Vector3(0, 0, 1), "dmg": 16.0, "deform": false, "shots": 1},
		{"label": "centre-strong", "pos": Vector3(0.0, 0.0, 1.0), "nrm": Vector3(0, 0, 1), "dmg": 20.0, "deform": true, "shots": 4},
		{"label": "corner-strong", "pos": Vector3(0.9, 0.9, 1.0), "nrm": Vector3(0, 0, 1), "dmg": 20.0, "deform": true, "shots": 4},
		{"label": "side-strong", "pos": Vector3(1.0, 0.3, 0.3), "nrm": Vector3(1, 0, 0), "dmg": 20.0, "deform": true, "shots": 4},
		{"label": "almost-dead", "pos": Vector3(0.0, 0.0, 1.0), "nrm": Vector3(0, 0, 1), "dmg": 22.0, "deform": true, "shots": 14},
	]
	var x0 := -float(cases.size() - 1) * 0.5 * SPACING
	for i in cases.size():
		var c: Dictionary = cases[i]
		_make_brick(
			Vector3(x0 + float(i) * SPACING, 0.0, 0.0),
			c["pos"] as Vector3,
			c["nrm"] as Vector3,
			float(c["dmg"]),
			bool(c["deform"]),
			str(c["label"]),
			int(c.get("shots", 1)),
		)
	print("[deforminspect] subdiv=%d  order L→R: %s"
		% [DestructibleSolid.CHUNK_MESH_SUBDIVIDE, " | ".join(cases.map(func(c): return c["label"]))])
	_run_capture()


func _build_world() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.07, 0.08, 0.11)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.46, 0.48, 0.53)
	env.ambient_light_energy = 0.55
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-38.0, -28.0, 0.0)
	sun.light_energy = 1.2
	add_child(sun)
	_cam = Camera3D.new()
	_cam.fov = 48.0
	add_child(_cam)


func _make_brick(
	world_pos: Vector3,
	hit_norm_pos: Vector3,
	hit_normal: Vector3,
	dmg: float,
	use_deform: bool,
	label: String,
	shots: int = 1,
) -> void:
	var xform := Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * BRICK), world_pos)

	var vp := SubViewport.new()
	vp.size = Vector2i(RES, RES)
	vp.transparent_bg = false
	vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(vp)
	var sp := Splat2D.new()
	sp.brush = _brush()
	sp.res = float(RES)
	var cm := CanvasItemMaterial.new()
	cm.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	sp.material = cm
	vp.add_child(sp)

	var mat := (ArenaGenerator.make_rock_material(Color(0.55, 0.51, 0.46), 0.95, 7) as ShaderMaterial).duplicate() as ShaderMaterial
	mat.set_shader_parameter("damage_enabled", 1.0)
	mat.set_shader_parameter("dmg_vertex_deform", 1.0 if use_deform else 0.0)
	mat.set_shader_parameter("damage_tex", vp.get_texture())
	mat.set_shader_parameter("dmg_world_to_local", xform.affine_inverse())
	mat.set_shader_parameter("dmg_box_size", Vector3.ONE * BRICK)
	mat.set_shader_parameter("dmg_tex_size", float(RES))
	mat.set_shader_parameter("dmg_crater_depth", 0.72)

	var mmi := MultiMeshInstance3D.new()
	mmi.name = label
	mmi.material_override = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = DestructibleSolid.get_deform_chunk_mesh()
	mm.instance_count = 1
	mm.set_instance_transform(0, xform)
	mm.set_instance_custom_data(0, Color(0.3, 1.0, 1.0, 0.65))
	mmi.multimesh = mm
	mmi.custom_aabb = AABB(Vector3.ONE * -BRICK, Vector3.ONE * BRICK * 2.0)
	add_child(mmi)

	var local := hit_norm_pos * (BRICK * 0.5)
	var shots_n := shots if use_deform else 1
	for k in shots_n:
		var jitter := Vector3(
			sin(float(k) * 2.17) * 0.08,
			cos(float(k) * 1.83) * 0.08,
			0.0)
		_splat(sp, local + jitter, hit_normal, dmg, use_deform)


func _splat(sp: Splat2D, local_pos: Vector3, n: Vector3, dmg: float, use_deform: bool) -> void:
	var region := _region(n)
	var t := local_pos / BRICK + Vector3(0.5, 0.5, 0.5)
	var ruv := Vector2(t.x, t.y)
	var plane := Vector2(BRICK, BRICK)
	if region < 2:
		ruv = Vector2(t.z, t.y)
	elif region < 4:
		ruv = Vector2(t.x, t.z)
	var col := region % 3
	var row := region / 3
	var dec_r := 0.18
	var crater := 0.7 * 1.4 + 0.25
	var uv := Vector2((float(col) + ruv.x) / 3.0, (float(row) + ruv.y) / 2.0)
	sp.pending.append({
		"uv": uv,
		"ru": (dec_r / plane.x) / 3.0,
		"rv": (dec_r / plane.y) / 2.0,
		"decal": clampf(0.12 + dmg * 0.004, 0.12, 0.32),
		"deform": 0.0,
	})
	if use_deform:
		sp.pending.append({
			"uv": uv,
			"ru": (crater / plane.x) / 3.0,
			"rv": (crater / plane.y) / 2.0,
			"decal": 0.0,
			"deform": clampf(dmg * 0.013, 0.08, 0.72),
		})
	sp.queue_redraw()


func _region(n: Vector3) -> int:
	var a := n.abs()
	if a.x >= a.y and a.x >= a.z:
		return 0 if n.x > 0.0 else 1
	if a.y >= a.x and a.y >= a.z:
		return 2 if n.y > 0.0 else 3
	return 4 if n.z > 0.0 else 5


func _brush() -> Texture2D:
	var n := 128
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var p := Vector2(float(x) / float(n - 1) - 0.5, float(y) / float(n - 1) - 0.5)
			var d := p.length() * 2.0
			var core := clampf(1.0 - d * 0.72, 0.0, 1.0)
			core = core * core
			var halo := clampf(1.0 - d, 0.0, 1.0)
			halo = halo * halo * 0.22
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, maxf(core, halo)))
	return ImageTexture.create_from_image(img)


func _cli_capture() -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("capture="):
			return a.substr(8)
	return ""


func _run_capture() -> void:
	var size := Vector2i(1800, 560)
	DisplayServer.window_set_size(size)
	get_viewport().size = size
	var width := float(NUM_CASES) * SPACING
	_cam.position = Vector3(width * 0.42, 2.2, width * 0.72)
	_cam.look_at(Vector3(0.0, -0.1, 0.0), Vector3.UP)
	for _i in 30:
		await get_tree().process_frame
	RenderingServer.force_draw(true)
	await RenderingServer.frame_post_draw
	var path := _cli_capture()
	if path == "":
		path = "user://deform_inspect.png"
	get_viewport().get_texture().get_image().save_png(path)
	print("[deforminspect] captured: ", path)
	get_tree().quit()
