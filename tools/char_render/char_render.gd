extends Node3D
# Renders the character roster with third-person guns for visual review.
#   xvfb-run godot --rendering-driver vulkan --path . res://tools/char_render/char_render.tscn -- --out=/tmp/chars --pitch=0 --blend=0
var out_dir := "/tmp/chars"
var pitch_deg := 0.0
var blend := 0.0
var anim_time := -1.0
var frames := 0
var chars: Array = []
var cam: Camera3D
var _retry_at := -1

func _arg(name: String, def: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % name):
			return a.split("=", true, 1)[1]
	return def

func _ready() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	out_dir = _arg("out", out_dir)
	pitch_deg = float(_arg("pitch", "0"))
	blend = float(_arg("blend", "0"))
	DirAccess.make_dir_recursive_absolute(out_dir)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.55, 0.6, 0.66)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.7, 0.7, 0.75)
	e.ambient_light_energy = 0.6
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	sun.shadow_enabled = _arg("shadows", "1") == "1"
	add_child(sun)
	var floor_mi := MeshInstance3D.new()
	var pm := PlaneMesh.new(); pm.size = Vector2(30, 30)
	floor_mi.mesh = pm
	floor_mi.position.y = -0.9
	add_child(floor_mi)
	var n := CharacterVisual.VARIANT_SCENES.size()
	var count := int(_arg("count", str(n)))
	for i in count:
		var holder := Node3D.new()
		holder.position = Vector3((i - (count - 1) * 0.5) * 1.6, 0, 0)
		holder.rotation_degrees.y = float(_arg("yaw", "-90"))
		add_child(holder)
		var cv := CharacterVisual.new()
		cv.variant = (i + int(_arg("variant", "0"))) % n
		holder.add_child(cv)
		if _arg("colors", "1") == "1":
			cv.set_identity_color([Color(0.95, 0.26, 0.21), Color(0.16, 0.55, 0.98), Color(1.0, 0.8, 0.1), Color(0.2, 0.82, 0.35)][i % 4])
		chars.append(cv)
	cam = Camera3D.new()
	cam.fov = 40
	add_child(cam)
	var view := _arg("view", "side")
	var width := count * 1.6
	if view == "front":
		cam.position = Vector3(0, 0.4, width * 1.25 + 1.5)
	else:
		cam.position = Vector3(0, 0.4, width * 1.25 + 1.5)
	var dist := float(_arg("dist", "0"))
	if dist > 0.0:
		cam.position = Vector3(float(_arg("camx", "0.3")), 0.55, dist)
		cam.look_at(Vector3(float(_arg("camx", "0.3")), 0.45, 0))
	else:
		cam.look_at(Vector3(0, 0.1, 0))
	cam.make_current()

func _process(_d: float) -> void:
	frames += 1

	for cv in chars:
		if not cv.is_active():
			continue
		cv.set_locomotion_blend(blend)
		var anchor: Node3D = cv.get_weapon_anchor()
		if anchor and anchor.get_child_count() == 0:
			var gun = preload("res://scripts/procedural_gun.gd").new()
			var root: Node3D = cv.mount_third_person_weapon(gun)
		cv.aim_pitch = deg_to_rad(pitch_deg)
		if float(_arg("strafe", "0")) != 0.0:
			cv.update_locomotion_directional(Vector3(float(_arg("strafe", "0")), 0, float(_arg("fwd", "0"))), 5.0, 0.1)
	if frames == int(_arg("frame", "40")) or frames == _retry_at:
		for cv in chars:
			var a: Node3D = cv.get_weapon_anchor()
			if a and a.get_child_count() > 0 and a.get_child(0).get_child_count() > 0:
				var g: Node3D = a.get_child(0).get_child(0)
				var pg: Node3D = g.find_child("PistolGrip", true, false)
				if pg: print("CHR grip local=", g.to_local(pg.global_position), " hand->grip world=", pg.global_position - a.global_position)
				print("CHR gun v", cv.variant, " up=", g.global_transform.basis.y.normalized(), " fwd(-z)=", -g.global_transform.basis.z.normalized(), " right=", g.global_transform.basis.x.normalized())
		print("CHR active=", chars.map(func(c): return c.is_active()), " cam=", get_viewport().get_camera_3d(), " vp=", get_viewport().size, " 3d_off=", get_viewport().disable_3d)
		_save()

func _save() -> void:
	var img := get_viewport().get_texture().get_image()
	if img.get_pixel(10, 10).v < 0.01 and frames < 100:
		for mi in find_children("*", "MeshInstance3D", true, false):
			var t: Transform3D = mi.global_transform
			var bad := not (t.origin.is_finite() and t.basis.x.is_finite() and t.basis.y.is_finite() and t.basis.z.is_finite())
			if bad or t.origin.length() > 50.0 or t.basis.get_scale().length() > 20.0:
				print("CHR BAD mesh ", mi.get_path(), " ", t)
		for sk in find_children("*", "Skeleton3D", true, false):
			for b in sk.get_bone_count():
				var g: Transform3D = sk.get_bone_global_pose(b)
				if not g.origin.is_finite() or g.origin.length() > 1000.0:
					print("CHR BAD bone ", sk.get_bone_name(b), " ", g.origin)
		print("CHR cam ", get_viewport().get_camera_3d().global_transform)
		# Nothing drawn yet (window still settling): try again later.
		_retry_at = frames + 30
		return
	print("CHR img ", img.get_size(), " px ", img.get_pixel(10, 10))
	img.save_png(out_dir + "/" + _arg("name", "chars") + ".png")
	get_tree().quit()
