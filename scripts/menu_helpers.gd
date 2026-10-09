class_name MenuHelpers
extends RefCounted

const MUSIC_DB_MIN := -45.0
const MUSIC_DB_MAX := 0.0
const IROH_GAME_ID_MIN_LENGTH := 20
const IROH_GAME_ID_MAX_LENGTH := 256

# Settings state
static var retro_enabled: bool = false
static var music_db: float = -16.0
static var mouse_sens_mult: float = 1.0
static var stick_sens_mult: float = 1.0
static var movement_tilt_enabled: bool = true
static var player_name: String = ""

const SETTINGS_PATH := "user://settings.cfg"

static var settings_changed_callback: Callable
static var player_name_committed_callback: Callable

# Styling used for premium flat/glassmorphic panels
static func menu_panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.08, 0.1, 0.95)
	sb.border_color = Color(0.35, 0.7, 1.0)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 24
	sb.content_margin_right = 24
	sb.content_margin_top = 22
	sb.content_margin_bottom = 22
	return sb

# Build slider row helper
static func build_slider_row(label_text: String, value: float, min_val: float, max_val: float, step: float, value_text: String) -> Dictionary:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	row.custom_minimum_size = Vector2(0, 36)
	
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(128, 0)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.95))
	label.add_theme_font_size_override("font_size", 14)
	row.add_child(label)
	
	var slider := HSlider.new()
	slider.min_value = min_val
	slider.max_value = max_val
	slider.step = step
	slider.value = value
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(0, 32)
	row.add_child(slider)
	
	var val_lbl := Label.new()
	val_lbl.text = value_text
	val_lbl.custom_minimum_size = Vector2(45, 0)
	val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	val_lbl.add_theme_color_override("font_color", Color(0.74, 0.78, 0.9))
	val_lbl.add_theme_font_size_override("font_size", 14)
	row.add_child(val_lbl)
	
	return {"row": row, "slider": slider, "value_label": val_lbl}

# Music volume label translation
static func music_label_for(db: float) -> String:
	if db <= MUSIC_DB_MIN + 0.5:
		return "Off"
	var vol := roundf(remap(db, MUSIC_DB_MIN, MUSIC_DB_MAX, 0.0, 100.0))
	return "%d%%" % vol

# Validation: Extract Iroh node ID
static func extract_iroh_node_id(text: String) -> String:
	var stripped := text.strip_edges()
	var pieces := stripped.split("\n", false)
	if pieces.size() == 1:
		pieces = stripped.split("\t", false)
	for raw_piece in pieces:
		var piece := str(raw_piece).strip_edges()
		if is_valid_iroh_node_id(piece):
			return piece
	return stripped

# Validation: Check if string is a valid Iroh node ID
static func is_valid_iroh_node_id(text: String) -> bool:
	var id := text.strip_edges()
	if id.length() < IROH_GAME_ID_MIN_LENGTH or id.length() > IROH_GAME_ID_MAX_LENGTH:
		return false
	if id.contains(" "):
		return false
	return true

# Validation: Check if it matches own hosted room ID
static func is_own_iroh_game_id(game_id: String) -> bool:
	var own_id := NetworkManager.current_iroh_game_id.strip_edges()
	if own_id.is_empty():
		return false
	return game_id.strip_edges() == own_id

# Focus helpers
static func find_focusable_menu_control(node: Node) -> Control:
	if node is Control:
		var control := node as Control
		if not control.visible:
			return null
		if control.focus_mode != Control.FOCUS_NONE and not (control is LineEdit):
			var disabled := false
			if control is BaseButton:
				disabled = (control as BaseButton).disabled
			if not disabled:
				return control
	for child in node.get_children():
		var focusable := find_focusable_menu_control(child)
		if focusable:
			return focusable
	return null

static func grab_first_menu_focus(root: Node) -> void:
	if root == null:
		return
	var focus_target := find_focusable_menu_control(root)
	if focus_target:
		focus_target.grab_focus()
		focus_target.call_deferred("grab_focus")

# Settings operations
static func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	retro_enabled = cfg.get_value("video", "retro", cfg.get_value("video", "dither", false))
	var music_legacy: bool = cfg.get_value("audio", "music", true)
	var music_legacy_default: float = music_db if music_legacy else MUSIC_DB_MIN
	music_db = float(cfg.get_value("audio", "music_db", music_legacy_default))
	mouse_sens_mult = float(cfg.get_value("input", "mouse_sens_mult", 1.0))
	stick_sens_mult = float(cfg.get_value("input", "stick_sens_mult", 1.0))
	movement_tilt_enabled = cfg.get_value("input", "movement_tilt", true)
	player_name = String(cfg.get_value("player", "name", ""))

static func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("video", "retro", retro_enabled)
	cfg.set_value("audio", "music_db", music_db)
	cfg.set_value("input", "mouse_sens_mult", mouse_sens_mult)
	cfg.set_value("input", "stick_sens_mult", stick_sens_mult)
	cfg.set_value("input", "movement_tilt", movement_tilt_enabled)
	cfg.set_value("player", "name", player_name)
	cfg.save(SETTINGS_PATH)

static func build_settings_panel(parent: Node, close_callback: Callable, left_align: bool = false) -> Control:
	var root := Control.new()
	root.name = "SettingsPanel"
	root.anchor_right = 1.0
	root.anchor_bottom = 1.0
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	parent.add_child(root)
	
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.55)
	bg.anchor_right = 1.0
	bg.anchor_bottom = 1.0
	root.add_child(bg)
	
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", menu_panel_style())
	
	if left_align:
		root.add_child(panel)
		panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_LEFT)
		panel.anchor_top = 0.5
		panel.anchor_bottom = 0.5
		panel.offset_left = 62.0
		panel.offset_right = 412.0 # 62 + 350 width
		panel.grow_vertical = 2
		panel.custom_minimum_size = Vector2(350, 0)
		panel.size = Vector2.ZERO
	else:
		var center := CenterContainer.new()
		center.anchor_right = 1.0
		center.anchor_bottom = 1.0
		root.add_child(center)
		center.add_child(panel)
	
	var margin := MarginContainer.new()
	margin.name = "SettingsMargin"
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", 18)
	margin.add_theme_constant_override("margin_bottom", 18)
	panel.add_child(margin)
	
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	vb.custom_minimum_size = Vector2(300, 0)
	margin.add_child(vb)
	
	var title := Label.new()
	title.name = "SettingsTitle"
	title.text = "SETTINGS"
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", Color(1, 0.9, 0.45))
	title.add_theme_color_override("font_outline_color", Color(0.4, 0.0, 0.1))
	title.add_theme_constant_override("outline_size", 4)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)
	
	var title_gap := Control.new()
	title_gap.custom_minimum_size = Vector2(0, 6)
	vb.add_child(title_gap)
	
	# Player Name
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 14)
	name_row.custom_minimum_size = Vector2(0, 36)
	var name_label := Label.new()
	name_label.text = "Player name"
	name_label.custom_minimum_size = Vector2(128, 0)
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.95))
	name_label.add_theme_font_size_override("font_size", 14)
	name_row.add_child(name_label)
	
	var name_input := LineEdit.new()
	name_input.text = player_name
	name_input.placeholder_text = "Your callsign…"
	name_input.max_length = 20
	name_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_input.custom_minimum_size = Vector2(0, 34)
	name_row.add_child(name_input)
	vb.add_child(name_row)
	
	var commit_name := func() -> void:
		var entered: String = name_input.text.strip_edges()
		if entered.is_empty() or entered == player_name:
			name_input.text = player_name
			return
		player_name = entered
		NetworkManager.local_player_name = entered
		save_settings()
		if settings_changed_callback.is_valid():
			settings_changed_callback.call()
		if player_name_committed_callback.is_valid():
			player_name_committed_callback.call(entered)
			
	name_input.text_submitted.connect(func(_t: String) -> void: commit_name.call())
	name_input.focus_exited.connect(commit_name)
	
	# Retro look
	var retro_toggle := CheckButton.new()
	retro_toggle.text = "Retro shader look"
	retro_toggle.custom_minimum_size = Vector2(0, 34)
	retro_toggle.button_pressed = retro_enabled
	retro_toggle.toggled.connect(func(on: bool) -> void:
		retro_enabled = on
		save_settings()
		if settings_changed_callback.is_valid():
			settings_changed_callback.call()
	)
	vb.add_child(retro_toggle)
	
	# Music volume
	var music_row := build_slider_row("Music", music_db, MUSIC_DB_MIN, MUSIC_DB_MAX, 1.0, music_label_for(music_db))
	vb.add_child(music_row["row"])
	var music_slider: HSlider = music_row["slider"]
	var music_val_lbl: Label = music_row["value_label"]
	music_slider.value_changed.connect(func(v: float) -> void:
		music_db = v
		if music_val_lbl:
			music_val_lbl.text = music_label_for(v)
		save_settings()
		if settings_changed_callback.is_valid():
			settings_changed_callback.call()
	)
	
	# Mouse sensitivity
	var mouse_row := build_slider_row("Mouse sensitivity", mouse_sens_mult, 0.3, 3.0, 0.05, "%.2fx" % mouse_sens_mult)
	vb.add_child(mouse_row["row"])
	var mouse_slider: HSlider = mouse_row["slider"]
	var mouse_val_lbl: Label = mouse_row["value_label"]
	mouse_slider.value_changed.connect(func(v: float) -> void:
		mouse_sens_mult = v
		if mouse_val_lbl:
			mouse_val_lbl.text = "%.2fx" % v
		save_settings()
		if settings_changed_callback.is_valid():
			settings_changed_callback.call()
	)
	
	# Right-stick look sensitivity (all local pads)
	var stick_row := build_slider_row("Stick sensitivity", stick_sens_mult, 0.3, 2.5, 0.05, "%.2fx" % stick_sens_mult)
	vb.add_child(stick_row["row"])
	var stick_slider: HSlider = stick_row["slider"]
	var stick_val_lbl: Label = stick_row["value_label"]
	stick_slider.value_changed.connect(func(v: float) -> void:
		stick_sens_mult = v
		if stick_val_lbl:
			stick_val_lbl.text = "%.2fx" % v
		save_settings()
		if settings_changed_callback.is_valid():
			settings_changed_callback.call()
	)
	
	# Movement tilt
	var tilt_toggle := CheckButton.new()
	tilt_toggle.text = "Movement tilt"
	tilt_toggle.custom_minimum_size = Vector2(0, 34)
	tilt_toggle.button_pressed = movement_tilt_enabled
	tilt_toggle.toggled.connect(func(on: bool) -> void:
		movement_tilt_enabled = on
		save_settings()
		if settings_changed_callback.is_valid():
			settings_changed_callback.call()
	)
	vb.add_child(tilt_toggle)
	
	var spacer2 := Control.new()
	spacer2.custom_minimum_size = Vector2(0, 8)
	vb.add_child(spacer2)
	
	var back_btn := Button.new()
	back_btn.text = "BACK"
	back_btn.custom_minimum_size = Vector2(0, 38)
	vb.add_child(back_btn)
	back_btn.pressed.connect(func() -> void:
		commit_name.call()
		close_callback.call()
	)
	
	return root
