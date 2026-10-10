extends Node3D

# Crowd-audio lab: pokes CrowdAudio directly — state sliders (with a hold
# toggle that defeats decay), every gameplay event as a button, chant
# audition/reroll, and live mix knobs. Builds a real colosseum so the ring
# registers and 3D reactions (scream bursts, chants) have somewhere to play
# from. Reaches into CrowdAudio's privates on purpose; it's a lab.

var _hold_check: CheckBox
var _enth_slider: HSlider
var _fear_slider: HSlider
var _status: Label
var _reroll_btn: Button
var _rebake_btn: Button


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_build_world()
	_build_ui()


func _build_world() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	ColosseumBuilder.build(self, rng, 60.0, 5.0, Color(0.45, 0.42, 0.39), true)
	var floor_mesh := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 62.0
	cyl.bottom_radius = 62.0
	cyl.height = 0.4
	floor_mesh.mesh = cyl
	var fmat := StandardMaterial3D.new()
	fmat.albedo_color = Color(0.35, 0.33, 0.3)
	fmat.roughness = 1.0
	floor_mesh.material_override = fmat
	floor_mesh.position.y = -0.2
	add_child(floor_mesh)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48.0, 35.0, 0.0)
	sun.light_energy = 1.2
	add_child(sun)
	var world_env := WorldEnvironment.new()
	var env := Environment.new()
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.7
	world_env.environment = env
	add_child(world_env)
	var cam := Camera3D.new()
	add_child(cam)
	cam.position = Vector3(0.0, 7.0, 0.0)
	cam.look_at(Vector3(60.0, 22.0, 0.0))
	cam.current = true


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var panel := PanelContainer.new()
	panel.anchor_bottom = 1.0
	panel.custom_minimum_size = Vector2(380, 0)
	layer.add_child(panel)
	var scroll := ScrollContainer.new()
	panel.add_child(scroll)
	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vb)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 13)
	vb.add_child(_status)

	_section(vb, "State")
	_hold_check = CheckBox.new()
	_hold_check.text = "Hold state (disable decay)"
	vb.add_child(_hold_check)
	_enth_slider = _slider(vb, "Enthusiasm", 0.0, 1.0, 0.0,
		func(v: float) -> void: CrowdAudio.enthusiasm = v)
	_fear_slider = _slider(vb, "Fear", 0.0, 1.0, 0.0,
		func(v: float) -> void: CrowdAudio.fear = v)

	_section(vb, "Events")
	var grid := GridContainer.new()
	grid.columns = 2
	vb.add_child(grid)
	_btn(grid, "Hurt", func() -> void: CrowdAudio.on_player_hurt(Vector3.ZERO))
	_btn(grid, "Kill", func() -> void: CrowdAudio.on_player_death(Vector3.ZERO))
	_btn(grid, "Explosion (arena)", func() -> void: CrowdAudio.on_explosion(Vector3(10.0, 1.0, 5.0), 8.0))
	_btn(grid, "Explosion (stands)", func() -> void: CrowdAudio.on_explosion(_stands_point(), 8.0))
	_btn(grid, "Bullet into crowd", func() -> void: CrowdAudio.on_crowd_bullet_hit(_stands_point()))
	_btn(grid, "Round start", func() -> void: CrowdAudio.on_round_start())
	_btn(grid, "Round win", func() -> void: CrowdAudio.on_round_win())

	_section(vb, "Chants")
	var cgrid := GridContainer.new()
	cgrid.columns = 3
	vb.add_child(cgrid)
	for i in CrowdAudio.CHANT_COUNT:
		var idx := i
		_btn(cgrid, "Chant %d" % (i + 1), func() -> void: _play_chant(idx))
	_btn(cgrid, "Random", func() -> void:
		CrowdAudio._chant_player.stop()
		CrowdAudio._start_chant())
	_btn(cgrid, "Stop", func() -> void: CrowdAudio._chant_fading = true)
	_reroll_btn = _btn(cgrid, "Reroll melodies", _reroll_chants)

	_section(vb, "Claps (bake-time — hit Rebake to hear)")
	_slider(vb, "Pats vs roar", 0.0, 2.0, CrowdAudio.clap_fore_gain,
		func(v: float) -> void: CrowdAudio.clap_fore_gain = v)
	_slider(vb, "Wash vs roar", 0.0, 1.0, CrowdAudio.clap_wash_gain,
		func(v: float) -> void: CrowdAudio.clap_wash_gain = v)
	_slider(vb, "Pat centre Hz", 700.0, 2200.0, CrowdAudio.clap_center_hz,
		func(v: float) -> void: CrowdAudio.clap_center_hz = v)
	_slider(vb, "Pats /s /side", 6.0, 80.0, CrowdAudio.clap_rate,
		func(v: float) -> void: CrowdAudio.clap_rate = v)
	_rebake_btn = _btn(vb, "Rebake cheer loop", _rebake_cheer)

	_section(vb, "Mix (dB)")
	_slider(vb, "Murmur", -40.0, 0.0, CrowdAudio.murmur_db,
		func(v: float) -> void: CrowdAudio.murmur_db = v)
	_slider(vb, "Cheer", -40.0, 0.0, CrowdAudio.cheer_db,
		func(v: float) -> void: CrowdAudio.cheer_db = v)
	_slider(vb, "Claps", -40.0, 0.0, CrowdAudio.claps_db,
		func(v: float) -> void: CrowdAudio.claps_db = v)
	_slider(vb, "Panic", -40.0, 0.0, CrowdAudio.panic_db,
		func(v: float) -> void: CrowdAudio.panic_db = v)
	_slider(vb, "Reactions", -40.0, 0.0, CrowdAudio.reaction_db,
		func(v: float) -> void: CrowdAudio.reaction_db = v)
	_slider(vb, "Chant", -40.0, 0.0, CrowdAudio.chant_db,
		func(v: float) -> void: CrowdAudio.chant_db = v)


func _process(_delta: float) -> void:
	if _hold_check and _hold_check.button_pressed:
		CrowdAudio.enthusiasm = _enth_slider.value
		CrowdAudio.fear = _fear_slider.value
	if _status == null:
		return
	var chant_state: String
	if CrowdAudio._chant_player != null and CrowdAudio._chant_player.playing:
		chant_state = "PLAYING (%.1f dB)" % CrowdAudio._chant_player.volume_db
	elif CrowdAudio._chant_force_delay > 0.0:
		chant_state = "starting in %.1f s" % CrowdAudio._chant_force_delay
	else:
		chant_state = "cooldown %.1f s" % CrowdAudio._chant_cd
	_status.text = "enthusiasm %.2f    fear %.2f\ngains  murmur %.2f  cheer %.2f  panic %.2f  claps %.2f\nchant  %s\nring %s    chant synths %s" % [
		CrowdAudio.enthusiasm, CrowdAudio.fear,
		CrowdAudio._murmur_gain, CrowdAudio._cheer_gain, CrowdAudio._panic_gain, CrowdAudio._clap_gain,
		chant_state,
		"active" if CrowdAudio.ring_active else "NONE",
		"ready (%d)" % CrowdAudio._chant_wavs.size() if not CrowdAudio._chant_wavs.is_empty() else "synthesizing...",
	]


func _play_chant(idx: int) -> void:
	if CrowdAudio._chant_wavs.is_empty():
		return
	CrowdAudio._chant_player.stop()
	CrowdAudio._chant_fading = false
	CrowdAudio._chant_bag.clear()
	CrowdAudio._chant_bag.append(clampi(idx, 0, CrowdAudio._chant_wavs.size() - 1))
	CrowdAudio._start_chant()


# Re-compose all chant melodies with fresh random seeds — audition until a
# batch feels right, then bake the good seeds into crowd_audio.gd.
func _reroll_chants() -> void:
	if _reroll_btn:
		_reroll_btn.disabled = true
	var fresh: Array[AudioStream] = []
	var seeds := PackedInt32Array()
	for i in CrowdAudio.CHANT_COUNT:
		var seed_v := randi() % 1000000
		seeds.append(seed_v)
		var buf: PackedVector2Array = await CrowdAudio._synth_chant(seed_v)
		fresh.append(CrowdAudio._to_wav(CrowdAudio._normalize(buf, 0.6), false))
	CrowdAudio._chant_wavs = fresh
	CrowdAudio._chant_bag.clear()
	print("crowd_lab: new chant seeds ", seeds)
	if _reroll_btn:
		_reroll_btn.disabled = false


# Re-synth the cheer loop (and the roar/surge one-shots that share its
# engine) with the current clap knob values, then swap the streams live.
func _rebake_cheer() -> void:
	if _rebake_btn:
		_rebake_btn.disabled = true
		_rebake_btn.text = "Rebaking..."
	var loop: PackedVector2Array = await CrowdAudio._synth_cheer(
		CrowdAudio.LOOP_SECONDS + CrowdAudio.SEAM_SECONDS, true, 0.0, true)
	CrowdAudio._cheer_player.stream = CrowdAudio._to_wav(CrowdAudio._finish_loop(loop), true)
	CrowdAudio._cheer_player.play()
	CrowdAudio._clap_player.stream = CrowdAudio._to_wav(
		CrowdAudio._finish_loop(CrowdAudio._split_claps), true)
	CrowdAudio._split_claps = PackedVector2Array()
	CrowdAudio._clap_player.play()
	var roar: PackedVector2Array = await CrowdAudio._synth_cheer(2.6, false, 1.0)
	CrowdAudio._roar_wav = CrowdAudio._to_wav(CrowdAudio._normalize(roar, 0.75), false)
	var surge: PackedVector2Array = await CrowdAudio._synth_cheer(3.5, false, 2.0)
	CrowdAudio._surge_wav = CrowdAudio._to_wav(CrowdAudio._normalize(surge, 0.7), false)
	print("crowd_lab: rebaked cheer — fore %.2f wash %.2f centre %.0f Hz rate %.0f/s" % [
		CrowdAudio.clap_fore_gain, CrowdAudio.clap_wash_gain,
		CrowdAudio.clap_center_hz, CrowdAudio.clap_rate])
	if _rebake_btn:
		_rebake_btn.disabled = false
		_rebake_btn.text = "Rebake cheer loop"


func _stands_point() -> Vector3:
	var ang := randf() * TAU
	var r: float = CrowdAudio._r_inner + 4.0
	return Vector3(cos(ang) * r, CrowdAudio._y_base + 4.0, sin(ang) * r)


func _section(parent: Container, title: String) -> void:
	var lab := Label.new()
	lab.text = "— %s —" % title
	lab.add_theme_font_size_override("font_size", 15)
	parent.add_child(lab)


func _btn(parent: Container, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


func _slider(parent: Container, label_text: String, lo: float, hi: float, value: float, cb: Callable) -> HSlider:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var lab := Label.new()
	lab.text = label_text
	lab.custom_minimum_size = Vector2(100, 0)
	row.add_child(lab)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = 0.01
	s.value = value
	s.custom_minimum_size = Vector2(200, 0)
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.value_changed.connect(cb)
	row.add_child(s)
	return s
