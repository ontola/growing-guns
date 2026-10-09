class_name RenderPlayer
extends SubViewportContainer

signal card_selected(player_id: int, card_id: String)

const CROSSHAIR_SCRIPT := preload("res://scripts/crosshair.gd")
const HIT_MARKER_SCRIPT := preload("res://scripts/hit_marker.gd")
const DAMAGE_INDICATOR_SCRIPT := preload("res://scripts/damage_indicator.gd")
const LENS_FLARE_OVERLAY_SCRIPT := preload("res://scripts/lens_flare_overlay.gd")
const HUD_ICON_SCRIPT := preload("res://scripts/hud_icon.gd")
const PICKUP_ITEM_SCRIPT := preload("res://scripts/pickup_item.gd")
const ROUND_MODIFIERS_SCRIPT := preload("res://scripts/round_modifiers.gd")
const PLAYER_VISUAL_LAYER_BASE := 8
# Per-view first-person gun layers (render layer bits 1..7). Each local
# view's camera includes ONLY its own FP-gun bit, so every splitscreen player
# sees their own first-person rig and nobody else's floating gun. Body layers
# use bits 8..18 (above), the stadium TV screens bit 19.
const FP_GUN_LAYER_BASE := 1
const FP_GUN_LAYER_MASK := 0b11111110  # bits 1..7
# Higher than the gameplay look-deadzone — casual stick drift shouldn't
# advance the selection while the card pick UI is up.
const CARD_NAV_STICK_DEADZONE := 0.55
# Base card geometry used everywhere (creation in _make_card, scaling in
# _scale_card, width-fill calculation in layout_for_size).
const CARD_BASE_WIDTH := 220.0
const CARD_BASE_HEIGHT := 300.0
const CARD_BASE_SEPARATION := 10.0

var game: Node = null
var player_id: int = 0
var input_device: int = -1

var viewport: SubViewport = null
var camera: Camera3D = null
var _flare_overlay: Control = null
var _hud: Dictionary = {}
var _card_ids: Array = []
var _card_selected_index: int = 0
var _card_pick_locked: bool = false
var _card_exit_animating: bool = false
# Edge-trigger state for left-stick X card nav: only fires once per push past
# the deadzone, has to return to neutral before the next nav can register.
var _card_stick_x_engaged: bool = false
var _pickup_toast_timer: Timer = null
var _modifier_toast_timer: Timer = null


func setup(game_node: Node, id: int, device: int = -1) -> void:
	game = game_node
	player_id = id
	input_device = device
	# Sized by hand (see _apply_render_size): stretch would size the
	# SubViewport in canvas units, i.e. the 1281x720 design size, so the 3D
	# world rendered at 720p even on a 4K TV.
	stretch = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if viewport == null:
		_build()


func _process(_delta: float) -> void:
	var _pt := Time.get_ticks_usec() if Trace.enabled else 0
	var player := _player()
	if player == null:
		return
	_apply_owner_cull(player)
	var source := player.get_node_or_null("Camera") as Camera3D
	if source:
		# The *interpolated* transform, not the raw one. The project renders
		# with physics interpolation on (project.godot), so everything in the
		# world — including the first-person rig, which hangs off this very
		# camera — is drawn smoothly between physics ticks. Copying the raw
		# transform pinned the view to the 60 Hz tick while the gun in it kept
		# moving at frame rate, so the gun appeared to swim around the corner
		# of the screen whenever the player did anything.
		camera.global_transform = source.get_global_transform_interpolated()
		camera.fov = source.fov
	if _flare_overlay and viewport:
		_flare_overlay.camera = camera
	_update_hud(player)
	if Trace.enabled:
		Trace.prof("render_pl", Time.get_ticks_usec() - _pt)


func handle_input(event: InputEvent) -> bool:
	if not is_card_pick_visible():
		return false
	# Track left-stick X across the lock window too, so a hold during the
	# 0.75s reveal doesn't get re-fired the moment the lock releases.
	if input_device >= 0 and event is InputEventJoypadMotion and event.device == input_device:
		return _handle_card_nav_stick(event)
	if _card_pick_locked:
		return true
	if input_device >= 0:
		if not (event is InputEventJoypadButton) or not event.pressed or event.device != input_device:
			return false
		match event.button_index:
			JOY_BUTTON_DPAD_LEFT:
				_select_card(_card_selected_index - 1)
				return true
			JOY_BUTTON_DPAD_RIGHT:
				_select_card(_card_selected_index + 1)
				return true
			JOY_BUTTON_A, JOY_BUTTON_X:
				_emit_selected_card()
				return true
		return true
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_A, KEY_LEFT:
				_select_card(_card_selected_index - 1)
				return true
			KEY_D, KEY_RIGHT:
				_select_card(_card_selected_index + 1)
				return true
			KEY_SPACE, KEY_ENTER, KEY_KP_ENTER:
				_emit_selected_card()
				return true
	return false


func flash_impact(world_pos: Vector3, intensity: float = 1.0) -> void:
	if _flare_overlay:
		_flare_overlay.trigger_impact_flash(world_pos, intensity)


func show_card_pick(card_ids: Array) -> void:
	hide_round_win()
	_blend_death_into_card_pick()
	_card_ids = card_ids.duplicate()
	_card_selected_index = 0
	_card_pick_locked = true
	var row: HBoxContainer = _hud.card_row
	for child in row.get_children():
		child.queue_free()
	var index := 0
	for raw_id in _card_ids:
		var card := CardLibrary.by_id(str(raw_id))
		if card.is_empty():
			continue
		row.add_child(_make_card(str(raw_id), card, index))
		index += 1
	var bg: ColorRect = _hud.card_bg
	if bg.has_meta("tween"):
		var old_tw: Tween = bg.get_meta("tween")
		if old_tw and old_tw.is_valid():
			old_tw.kill()
	bg.color.a = 0.0
	var title: Label = _hud.card_title
	if title:
		if game and game.has_method("is_coop_mode") and game.is_coop_mode():
			title.text = "WAVE COMPLETE - PICK A CARD"
		else:
			title.text = "PICK A CARD"
		title.modulate.a = 1.0
		title.position.y = 0.0
		if title.has_meta("tween"):
			var old_title_tw: Tween = title.get_meta("tween")
			if old_title_tw and old_title_tw.is_valid():
				old_title_tw.kill()
	_hud.card_overlay.visible = true
	_hud.crosshair.visible = false
	if size.x > 1.0 and size.y > 1.0:
		layout_for_size(size)
	# Block the mouse on cards belonging to controller-using players, so the
	# global cursor can't steal their selection while they navigate with
	# DPAD/stick. Mouse-using players (incl. a kbd+mouse player who joined
	# splitscreen via click-to-join) keep MOUSE_FILTER_STOP so they can still
	# click their own cards.
	mouse_filter = Control.MOUSE_FILTER_IGNORE if input_device >= 0 else Control.MOUSE_FILTER_STOP
	# Treat the stick as already-engaged if the user happens to be holding it
	# right now; the next push (after returning to neutral) will fire nav.
	_card_stick_x_engaged = _stick_x_past_deadzone()
	await get_tree().create_timer(0.75, true).timeout
	if is_card_pick_visible():
		_card_pick_locked = false
		_select_card(0)
		_card_stick_x_engaged = _stick_x_past_deadzone()
		if game and game.has_method("_sync_mouse_mode"):
			game.call("_sync_mouse_mode")


func hide_card_pick() -> void:
	if is_card_pick_visible() and _card_pick_locked and not _card_ids.is_empty() and not _card_exit_animating:
		_animate_card_pick_exit()
		return
	if _card_exit_animating:
		return
	_clear_card_pick_now()


func _clear_card_pick_now() -> void:
	_card_ids.clear()
	_card_pick_locked = false
	_card_stick_x_engaged = false
	_card_exit_animating = false
	_hud.crosshair.visible = true
	var bg: ColorRect = _hud.card_bg
	if bg.has_meta("tween"):
		var old_tw: Tween = bg.get_meta("tween")
		if old_tw and old_tw.is_valid():
			old_tw.kill()
	bg.color.a = 0.0
	_hud.card_overlay.visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var row: HBoxContainer = _hud.card_row
	for child in row.get_children():
		child.queue_free()


func _handle_card_nav_stick(event: InputEventJoypadMotion) -> bool:
	if event.axis != JOY_AXIS_LEFT_X:
		return false
	var x: float = event.axis_value
	if absf(x) >= CARD_NAV_STICK_DEADZONE:
		if not _card_stick_x_engaged:
			_card_stick_x_engaged = true
			if not _card_pick_locked:
				_select_card(_card_selected_index + (1 if x > 0.0 else -1))
	else:
		_card_stick_x_engaged = false
	return true


func _stick_x_past_deadzone() -> bool:
	if input_device < 0:
		return false
	return absf(Input.get_joy_axis(input_device, JOY_AXIS_LEFT_X)) >= CARD_NAV_STICK_DEADZONE


func _is_splitscreen_active() -> bool:
	if game == null:
		return false
	var ss: Variant = game.get("_splitscreen")
	if ss == null or not is_instance_valid(ss):
		return false
	if not ss.has_method("is_enabled"):
		return false
	return bool(ss.is_enabled())


func is_card_pick_visible() -> bool:
	return bool(_hud.get("card_overlay").visible)


func is_card_pick_blocking() -> bool:
	return is_card_pick_visible() and not _card_pick_locked


func show_hitmarker(kind: String) -> void:
	_hud.hitmarker.flash(kind)


func show_damage_direction(from_pos: Vector3) -> void:
	var player := _player()
	if player == null:
		return
	var delta: Vector3 = from_pos - player.global_position
	delta.y = 0.0
	if delta.length_squared() < 0.0001:
		return
	var yaw: float = player.rotation.y
	var c := cos(yaw)
	var s := sin(yaw)
	var local_x := c * delta.x - s * delta.z
	var local_z := s * delta.x + c * delta.z
	_hud.damage.flash(atan2(local_x, -local_z))


func show_death_effect(show: bool) -> void:
	Trace.mark("death effect %s (render_player id=%d)" % ["SHOW→opaque" if show else "hide", player_id])
	if show:
		hide_round_win()
	var death: ColorRect = _hud.death
	if death.has_meta("tween"):
		var old_tw: Tween = death.get_meta("tween")
		if old_tw and old_tw.is_valid():
			old_tw.kill()
	var tw := death.create_tween()
	death.set_meta("tween", tw)
	if show:
		death.color.a = 0.6
		tw.tween_property(death, "color", Color(0.65, 0.0, 0.0, 1.0), 0.4).set_trans(Tween.TRANS_SINE)
	else:
		tw.tween_property(death, "color:a", 0.0, 0.5).set_trans(Tween.TRANS_CUBIC)


func _stop_death_tween() -> ColorRect:
	var death: ColorRect = _hud.death
	if death.has_meta("tween"):
		var old_tw: Tween = death.get_meta("tween")
		if old_tw and old_tw.is_valid():
			old_tw.kill()
	return death


func _blend_death_into_card_pick() -> void:
	var death := _stop_death_tween()
	var tw := death.create_tween()
	death.set_meta("tween", tw)
	if game and game.has_method("is_coop_mode") and game.is_coop_mode():
		tw.tween_property(death, "color", Color(0.05, 0.05, 0.08, 0.5), 0.6)\
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	else:
		tw.tween_property(death, "color", Color(0.30, 0.0, 0.0, 1.0), 0.55)\
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		tw.tween_property(death, "color", Color(0.09, 0.0, 0.0, 1.0), 0.65)\
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


func _fade_card_pick_to_game() -> void:
	var death := _stop_death_tween()
	var bg: ColorRect = _hud.card_bg
	if bg.has_meta("tween"):
		var old_bg_tw: Tween = bg.get_meta("tween")
		if old_bg_tw and old_bg_tw.is_valid():
			old_bg_tw.kill()
	var tw := create_tween().set_parallel(true)
	death.set_meta("tween", tw)
	bg.set_meta("tween", tw)
	tw.tween_property(death, "color:a", 0.0, 0.18).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(bg, "color:a", 0.0, 0.18).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	var title: Label = _hud.card_title
	if title and title.modulate.a > 0.01:
		tw.tween_property(title, "modulate:a", 0.0, 0.20).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tw.tween_property(title, "position:y", title.position.y - 22.0, 0.24).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)


func _fade_card_title_after_pick() -> void:
	var title: Label = _hud.card_title
	if title == null:
		return
	if title.has_meta("tween"):
		var old_tw: Tween = title.get_meta("tween")
		if old_tw and old_tw.is_valid():
			old_tw.kill()
	var tw := title.create_tween()
	title.set_meta("tween", tw)
	tw.tween_property(title, "modulate:a", 0.0, 0.12).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func layout_for_size(view_size: Vector2) -> void:
	_apply_render_size(view_size)
	var scale: float = clampf(minf(view_size.x / 960.0, view_size.y / 540.0), 0.58, 1.0)
	var margin := roundf(14.0 * scale)
	var font_big := maxi(13, int(round(22.0 * scale)))
	var font_small := maxi(11, int(round(16.0 * scale)))

	# Retro/fisheye compensation. The shader bows the image outward, so HUD
	# elements need to be pulled toward center to land where they should after
	# distortion. The pull is proportional to the element's distance from
	# centre — a flat sign-based offset (the previous approach) over-pulls
	# centre-adjacent panels, which made the bottom-row icons overlap and look
	# squished under retro.
	var fisheye_pull_x := 0.0           # multiplicative: shift each item by base_x * pull
	var fisheye_y_offset := 0.0         # additive: shift bottom row up by this many px
	if game and game.has_method("_is_fisheye_enabled") and game.call("_is_fisheye_enabled"):
		fisheye_pull_x = 0.08
		# Pull the row toward the vertical centre by the same fraction the x
		# pull uses — view_size.y is the reference, so a half-screen split gets
		# a smaller (proportional) lift than full-screen. Without this the
		# bottom panels were getting clipped under the lens warp.
		fisheye_y_offset = view_size.y * 0.5 * fisheye_pull_x

	var crosshair: Control = _hud.crosshair
	crosshair.set("line_width", maxf(1.0, 1.5 * scale))
	crosshair.set("line_length", maxf(5.0, 8.0 * scale))
	crosshair.set("base_gap", maxf(3.0, 4.0 * scale))

	var panel_h := 30.0 * scale
	var y := view_size.y - margin - 32.0 * scale
	for item in [
		{"node": _hud.hp_panel, "x": -290.0, "w": 130.0, "font": font_big},
		{"node": _hud.ammo_panel, "x": -140.0, "w": 130.0, "font": font_big},
		{"node": _hud.special_panel, "x": 10.0, "w": 130.0, "font": font_small},
		{"node": _hud.dash_panel, "x": 160.0, "w": 130.0, "font": font_small},
	]:
		var panel: Control = item.node
		panel.set_meta("font_size", item.font)
		panel.anchor_left = 0.5
		panel.anchor_right = 0.5
		panel.anchor_top = 0.0
		panel.anchor_bottom = 0.0
		var base_x: float = float(item.x) * scale
		# Multiplicative pull: outer panels travel more than inner ones, which
		# matches the non-linear distortion and keeps the row's relative
		# spacing consistent under retro.
		var compensated_x: float = base_x * (1.0 - fisheye_pull_x)
		panel.offset_left = compensated_x
		panel.offset_right = panel.offset_left + float(item.w) * scale
		# Y: bottom edge gets pushed down by fisheye, so move upward (negative offset)
		panel.offset_top = y - fisheye_y_offset
		panel.offset_bottom = y + panel_h - fisheye_y_offset

	var revive_label: Label = _hud.get("revive_panel") as Label
	if revive_label:
		revive_label.add_theme_font_size_override("font_size", font_big)

	# Cards get their own scale so the row fills the view width — the HUD
	# scale above caps at 1.0, which leaves big gaps in splitscreen halves
	# (and even more space wasted on a single full-screen view).
	var card_count := maxi(1, _card_ids.size())
	var cards_total_base: float = CARD_BASE_WIDTH * card_count + CARD_BASE_SEPARATION * (card_count - 1)
	var width_fit: float = (view_size.x * 0.92) / cards_total_base
	# Title + breathing room above the row.
	var height_fit: float = maxf(0.0, (view_size.y - 100.0)) / CARD_BASE_HEIGHT
	var card_scale: float = clampf(minf(width_fit, height_fit), CARD_SCALE_MIN, CARD_SCALE_MAX)
	var title: Label = _hud.card_title
	title.add_theme_font_size_override("font_size", maxi(16, int(round(24.0 * card_scale))))
	var row: HBoxContainer = _hud.card_row
	row.add_theme_constant_override("separation", maxi(6, int(round(CARD_BASE_SEPARATION * card_scale))))
	for child in row.get_children():
		_scale_card(child as Control, card_scale)


# Constants that drive `card_scale` in layout_for_size.
# Upper bound was 2.2 — that was visually right for a small splitscreen half
# but blew the cards up huge on a 1080p single-player viewport. Lowering the
# cap also avoids cards crowding the screen on very tall displays.
const CARD_SCALE_MIN := 0.7
const CARD_SCALE_MAX := 1.5


var _layout_size := Vector2.ZERO


# Render the view at the window's real pixel count. The project stretches
# canvas_items from a 1281x720 design size, so `view_size` is in design units;
# the screen has `content_scale` times more pixels. The SubViewport gets the
# full pixel size, its 2D (HUD, cards) keeps laying out in design units via
# size_2d_override, and this container is scaled back down so the texture
# lands on exactly view_size in the parent's canvas.
func _apply_render_size(view_size: Vector2) -> void:
	if viewport == null or view_size.x < 1.0 or view_size.y < 1.0:
		return
	_layout_size = view_size
	var content_scale: Vector2 = get_viewport().get_final_transform().get_scale().max(Vector2.ONE)
	viewport.size = Vector2i((view_size * content_scale).round()).max(Vector2i.ONE)
	viewport.size_2d_override = Vector2i(view_size.round()).max(Vector2i.ONE)
	viewport.size_2d_override_stretch = true
	scale = Vector2.ONE / content_scale


# The window can change size without the design-unit layout changing (a
# GameNight game warms minimised and goes fullscreen at start), so follow the
# real window too.
func _on_window_size_changed() -> void:
	if _layout_size != Vector2.ZERO:
		_apply_render_size(_layout_size)


func _build() -> void:
	viewport = SubViewport.new()
	viewport.disable_3d = false
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.world_3d = get_viewport().world_3d
	viewport.add_to_group(&"player_views")
	viewport.scaling_3d_scale = PerfGovernor.render_scale()
	add_child(viewport)
	get_viewport().size_changed.connect(_on_window_size_changed)

	camera = Camera3D.new()
	camera.current = true
	# We drive this camera ourselves, every frame, from the player's own (see
	# _process). Letting the engine interpolate it as well would smear a
	# transform that is already up to date, one frame behind where we put it.
	camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	viewport.add_child(camera)

	var hud_layer := CanvasLayer.new()
	hud_layer.layer = 10
	viewport.add_child(hud_layer)
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_layer.add_child(root)

	var hp_panel := _build_hp_panel()
	root.add_child(hp_panel)
	var ammo_panel := _build_value_panel(HUD_ICON_SCRIPT.Type.LMB, Color(1.0, 0.94, 0.62))
	root.add_child(ammo_panel)
	var special_panel := _build_value_panel(HUD_ICON_SCRIPT.Type.RMB, Color(0.7, 1.0, 0.55))
	root.add_child(special_panel)
	var dash_panel := _build_dash_panel()
	root.add_child(dash_panel)
	for panel in [hp_panel, ammo_panel, special_panel, dash_panel]:
		panel.z_index = 10

	_flare_overlay = LENS_FLARE_OVERLAY_SCRIPT.new()
	_flare_overlay.name = "LensFlareOverlay"
	_flare_overlay.z_index = 1
	root.add_child(_flare_overlay)

	var crosshair := Control.new()
	crosshair.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	crosshair.z_index = 10
	crosshair.set_script(CROSSHAIR_SCRIPT)
	root.add_child(crosshair)
	var hitmarker := Control.new()
	hitmarker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hitmarker.z_index = 10
	hitmarker.set_script(HIT_MARKER_SCRIPT)
	root.add_child(hitmarker)
	var damage := Control.new()
	damage.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	damage.z_index = 10
	damage.set_script(DAMAGE_INDICATOR_SCRIPT)
	root.add_child(damage)
	var death := ColorRect.new()
	death.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	death.mouse_filter = Control.MOUSE_FILTER_IGNORE
	death.z_index = 25
	death.color = Color(0.8, 0.0, 0.0, 0.0)
	root.add_child(death)
	var ghost := ColorRect.new()
	ghost.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ghost.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ghost.color = Color(0.25, 0.55, 0.85, 0.0)
	root.add_child(ghost)

	var card_overlay := _build_card_overlay(root)

	var pickup_toast := Label.new()
	pickup_toast.name = "PickupToast"
	pickup_toast.visible = false
	pickup_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pickup_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pickup_toast.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	pickup_toast.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	pickup_toast.offset_top = 72.0
	pickup_toast.offset_bottom = 132.0
	pickup_toast.offset_left = -180.0
	pickup_toast.offset_right = 180.0
	pickup_toast.add_theme_font_size_override("font_size", 22)
	pickup_toast.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.92))
	pickup_toast.add_theme_constant_override("outline_size", 5)
	root.add_child(pickup_toast)

	_pickup_toast_timer = Timer.new()
	_pickup_toast_timer.one_shot = true
	_pickup_toast_timer.timeout.connect(func() -> void: pickup_toast.visible = false)
	root.add_child(_pickup_toast_timer)

	var modifier_toast := Label.new()
	modifier_toast.name = "ModifierToast"
	modifier_toast.visible = false
	modifier_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	modifier_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	modifier_toast.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	modifier_toast.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	modifier_toast.offset_top = 36.0
	modifier_toast.offset_bottom = 116.0
	modifier_toast.offset_left = -190.0
	modifier_toast.offset_right = 190.0
	modifier_toast.add_theme_font_size_override("font_size", 24)
	modifier_toast.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.92))
	modifier_toast.add_theme_constant_override("outline_size", 5)
	root.add_child(modifier_toast)

	_modifier_toast_timer = Timer.new()
	_modifier_toast_timer.one_shot = true
	_modifier_toast_timer.timeout.connect(func() -> void: modifier_toast.visible = false)
	root.add_child(_modifier_toast_timer)

	var round_win := Label.new()
	round_win.name = "RoundWinStrip"
	round_win.visible = false
	round_win.z_index = 20
	round_win.mouse_filter = Control.MOUSE_FILTER_IGNORE
	round_win.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	round_win.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	round_win.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	round_win.offset_top = 8.0
	round_win.offset_bottom = 56.0
	round_win.add_theme_font_size_override("font_size", 28)
	round_win.add_theme_color_override("font_color", Color(1.0, 0.92, 0.42))
	round_win.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.95))
	round_win.add_theme_constant_override("outline_size", 7)
	root.add_child(round_win)

	var revive_panel := _build_revive_panel()
	revive_panel.z_index = 15
	root.add_child(revive_panel)

	_hud = {
		"hp_panel": hp_panel,
		"ammo_panel": ammo_panel,
		"special_panel": special_panel,
		"dash_panel": dash_panel,
		"crosshair": crosshair,
		"hitmarker": hitmarker,
		"damage": damage,
		"death": death,
		"ghost": ghost,
		"card_overlay": card_overlay.overlay,
		"card_bg": card_overlay.bg,
		"card_row": card_overlay.row,
		"card_title": card_overlay.title,
		"pickup_toast": pickup_toast,
		"modifier_toast": modifier_toast,
		"round_win": round_win,
		"revive_panel": revive_panel,
	}


# Whether this view's player is on a pad, so prompts name pad buttons. Under
# GameNight the party plays on the couch even when no pad index is bound.
func uses_controller() -> bool:
	return input_device >= 0 or HUD_ICON_SCRIPT.use_controller_icons or GameNight.launched_by_daemon


func show_pickup_toast(kind: String, subtitle_override: String = "") -> void:
	var toast: Label = _hud.get("pickup_toast") as Label
	if toast == null:
		return
	var info: Dictionary = PICKUP_ITEM_SCRIPT.display_info(kind)
	var subtitle: String = subtitle_override if not subtitle_override.is_empty() else str(info.subtitle)
	subtitle = HUD_ICON_SCRIPT.prompt_text(subtitle, uses_controller())
	toast.text = info.title if subtitle.is_empty() else "%s\n%s" % [info.title, subtitle]
	toast.add_theme_color_override("font_color", info.color)
	toast.visible = true
	if _pickup_toast_timer:
		_pickup_toast_timer.wait_time = 1.35
		_pickup_toast_timer.start()


func show_round_modifier(mod_id: String) -> void:
	var toast: Label = _hud.get("modifier_toast") as Label
	if toast == null:
		return
	var info: Dictionary = ROUND_MODIFIERS_SCRIPT.display_info(mod_id)
	var subtitle: String = str(info.subtitle)
	toast.text = info.title if subtitle.is_empty() else "%s\n%s" % [info.title, subtitle]
	toast.add_theme_color_override("font_color", info.color)
	toast.visible = true
	if _modifier_toast_timer:
		_modifier_toast_timer.wait_time = 2.5
		_modifier_toast_timer.start()


func show_round_win(text: String) -> void:
	var label: Label = _hud.get("round_win") as Label
	if label == null:
		return
	label.text = text
	label.visible = true
	if label.get_parent():
		label.get_parent().move_child(label, -1)


func hide_round_win() -> void:
	var label: Label = _hud.get("round_win") as Label
	if label:
		label.visible = false


# Bottom-row HUD panels. Each one is a plain Control with named children
# whose layout is finalised in _layout_bottom_panel(). The panels themselves
# are positioned by layout_for_size; their internals get sized + repositioned
# every frame from _update_hud so reload progress + dash recharge can drive
# the visible state without having to rebuild anything.
func _build_hp_panel() -> Control:
	var panel := Control.new()
	panel.name = "HpPanel"
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var cross := CrossDraw.new()
	cross.name = "Cross"
	cross.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(cross)
	var label := _label(Color(1.0, 0.95, 0.82))
	label.name = "Label"
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	panel.add_child(label)
	return panel


func _build_value_panel(icon_type: int, text_color: Color) -> Control:
	var panel := Control.new()
	panel.name = "ValuePanel"
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var icon := Control.new()
	icon.name = "Icon"
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.set_script(HUD_ICON_SCRIPT)
	icon.set("icon_type", icon_type)
	panel.add_child(icon)
	var label := _label(text_color)
	label.name = "Label"
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	panel.add_child(label)
	var bar_bg := ColorRect.new()
	bar_bg.name = "BarBg"
	bar_bg.color = Color(0, 0, 0, 0.55)
	bar_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar_bg.visible = false
	panel.add_child(bar_bg)
	var bar_fill := ColorRect.new()
	bar_fill.name = "BarFill"
	bar_fill.color = text_color
	bar_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar_fill.visible = false
	panel.add_child(bar_fill)
	return panel


func _build_revive_panel() -> Label:
	var label := _label(Color(0.72, 0.92, 1.0))
	label.name = "ReviveLabel"
	label.visible = false
	label.z_index = 18
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	label.offset_left = -180.0
	label.offset_right = 180.0
	label.offset_top = -118.0
	label.offset_bottom = -78.0
	label.add_theme_font_size_override("font_size", 24)
	label.text = "REVIVING..."
	return label


func _build_dash_panel() -> Control:
	var panel := Control.new()
	panel.name = "DashPanel"
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var icon := Control.new()
	icon.name = "Icon"
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.set_script(HUD_ICON_SCRIPT)
	icon.set("icon_type", HUD_ICON_SCRIPT.Type.SHIFT)
	panel.add_child(icon)
	var dash_color := Color(0.65, 0.9, 1.0)
	for i in 2:
		var bg := ColorRect.new()
		bg.name = "Bar%dBg" % i
		bg.color = Color(0, 0, 0, 0.55)
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(bg)
		var fill := ColorRect.new()
		fill.name = "Bar%dFill" % i
		fill.color = dash_color
		fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(fill)
	return panel


# Inner class that just draws a thick "+" cross using the panel-anchored size.
class CrossDraw extends Control:
	var cross_color: Color = Color(1.0, 0.35, 0.35)
	func set_cross_color(c: Color) -> void:
		if c == cross_color:
			return
		cross_color = c
		queue_redraw()
	func _draw() -> void:
		var thick: float = size.x * 0.34
		var horizontal := Rect2(0, (size.y - thick) * 0.5, size.x, thick)
		var vertical := Rect2((size.x - thick) * 0.5, 0, thick, size.y)
		draw_rect(horizontal, cross_color, true)
		draw_rect(vertical, cross_color, true)
		# Outline so the cross stays readable against bright surfaces.
		draw_rect(horizontal, Color(0, 0, 0, 0.85), false, 1.5)
		draw_rect(vertical, Color(0, 0, 0, 0.85), false, 1.5)


func _build_card_overlay(root: Control) -> Dictionary:
	var overlay := Control.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.z_index = 30
	overlay.visible = false
	overlay.process_mode = Node.PROCESS_MODE_ALWAYS
	root.add_child(overlay)
	var bg := ColorRect.new()
	bg.color = Color(0.0, 0.0, 0.0, 0.70)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(bg)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(center)
	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 12)
	center.add_child(vb)
	var title := _label(Color(1.0, 0.9, 0.45))
	title.text = "PICK A CARD"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_child(row)
	return {"overlay": overlay, "bg": bg, "row": row, "title": title}


func _label(color: Color) -> Label:
	var label := Label.new()
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	label.add_theme_constant_override("outline_size", 5)
	return label


func _make_card(card_id: String, card: Dictionary, index: int) -> Control:
	var rarity := str(card.get("rarity", "common"))
	var root := Control.new()
	root.custom_minimum_size = Vector2(220, 300)
	root.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	root.set_meta("card_id", card_id)

	var idle := Control.new()
	idle.name = "Idle"
	idle.size = Vector2(200, 280)
	idle.position = (root.custom_minimum_size - idle.size) * 0.5
	idle.pivot_offset = idle.size * 0.5
	root.add_child(idle)

	var panel := Panel.new()
	panel.name = "Body"
	panel.custom_minimum_size = Vector2(200, 280)
	panel.size = panel.custom_minimum_size
	panel.pivot_offset = panel.size * 0.5
	idle.add_child(panel)
	root.set_meta("body", panel)
	root.set_meta("idle", idle)

	var sb := StyleBoxFlat.new()
	var col: Color = card.get("color", Color.WHITE)
	if rarity == "rare":
		sb.bg_color = Color(0.06, 0.07, 0.18, 0.98)
		sb.border_color = Color(0.8, 0.9, 1.0)
		sb.shadow_color = Color(0.4, 0.6, 1.0, 0.4)
		sb.shadow_size = 25
	else:
		sb.bg_color = Color(col.r * 0.15, col.g * 0.15, col.b * 0.15, 0.96)
		sb.border_color = col.lerp(Color.WHITE, 0.2)
		sb.shadow_color = Color(0, 0, 0, 0.3)
		sb.shadow_size = 8
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(12)
	panel.add_theme_stylebox_override("panel", sb)

	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 10)
	vb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 14)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(vb)
	root.set_meta("content", vb)

	var title := _label(Color.WHITE)
	title.text = str(card.get("name", card_id)).to_upper()
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.add_theme_font_size_override("font_size", 18)
	vb.add_child(title)
	root.set_meta("title_label", title)

	var desc := _label(Color(0.9, 0.9, 0.9))
	desc.text = HUD_ICON_SCRIPT.prompt_text(str(card.get("desc", "")), uses_controller())
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.add_theme_font_size_override("font_size", 14)
	vb.add_child(desc)
	root.set_meta("desc_label", desc)

	var stats_vbox := VBoxContainer.new()
	stats_vbox.add_theme_constant_override("separation", 1)
	vb.add_child(stats_vbox)
	root.set_meta("stats_vbox", stats_vbox)
	for diff_line in _card_stat_diff(card_id):
		var slbl := _label(Color(0.75, 0.85, 1.0, 0.85))
		slbl.text = diff_line
		slbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		slbl.add_theme_font_size_override("font_size", 12)
		stats_vbox.add_child(slbl)

	if rarity == "rare":
		_add_holo_overlay(panel, sb)

	var button := Button.new()
	button.flat = true
	button.focus_mode = Control.FOCUS_ALL
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	button.pressed.connect(func() -> void:
		_card_selected_index = _card_ids.find(card_id)
		_emit_selected_card()
	)
	button.mouse_entered.connect(func() -> void:
		if _card_pick_locked:
			return
		var idx := _card_ids.find(card_id)
		if idx >= 0:
			_select_card(idx)
	)
	button.focus_entered.connect(func() -> void:
		if _card_pick_locked:
			return
		var idx := _card_ids.find(card_id)
		if idx >= 0:
			_select_card(idx)
	)
	panel.add_child(button)

	var float_tw := idle.create_tween().set_loops()
	float_tw.tween_property(idle, "position:y", idle.position.y + 4.0, 2.2).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	float_tw.tween_property(idle, "position:y", idle.position.y - 4.0, 2.2).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	root.set_meta("float_tween", float_tw)

	var rot_tw := idle.create_tween().set_loops()
	var rot_mag := randf_range(1.5, 3.5)
	rot_tw.tween_property(idle, "rotation_degrees", rot_mag, 3.1).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	rot_tw.tween_property(idle, "rotation_degrees", -rot_mag, 3.1).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	root.set_meta("rot_tween", rot_tw)

	var front_style := sb
	var back_style := StyleBoxFlat.new()
	back_style.bg_color = Color(0.12, 0.12, 0.15, 1.0)
	back_style.border_color = Color(0.3, 0.3, 0.4)
	back_style.set_corner_radius_all(12)
	panel.add_theme_stylebox_override("panel", back_style)
	panel.position.y = 400.0
	panel.scale.x = 0.001
	vb.visible = false
	var reveal_delay := index * 0.15
	var reveal := panel.create_tween()
	reveal.tween_property(panel, "position:y", 0.0, 0.4)\
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT).set_delay(index * 0.04)
	reveal.tween_interval(reveal_delay)
	reveal.tween_property(panel, "scale:x", 0.001, 0.1)
	reveal.tween_callback(func() -> void:
		vb.visible = true
		panel.add_theme_stylebox_override("panel", front_style)
		SFX.card_flip(0.8 + (index * 0.15))
	)
	reveal.tween_property(panel, "scale:x", 1.0, 0.15).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	return root


func _select_card(index: int) -> void:
	if _card_ids.is_empty():
		return
	_card_selected_index = posmod(index, _card_ids.size())
	var row: HBoxContainer = _hud.card_row
	for i in range(row.get_child_count()):
		_set_card_highlight(row.get_child(i) as Control, i == _card_selected_index)


func _emit_selected_card() -> void:
	if _card_ids.is_empty() or _card_pick_locked:
		return
	_card_pick_locked = true
	_fade_card_title_after_pick()
	var card_id := str(_card_ids[_card_selected_index])
	card_selected.emit(player_id, card_id)


func _animate_card_pick_exit() -> void:
	_card_exit_animating = true
	_fade_card_pick_to_game()
	var row: HBoxContainer = _hud.card_row
	var picked := row.get_child(_card_selected_index) as Control
	for i in range(row.get_child_count()):
		var card := row.get_child(i) as Control
		var body := card.get_meta("body") as Control
		if body == null:
			continue
		var tw := body.create_tween().set_parallel(true)
		if card == picked:
			tw.tween_property(body, "scale", Vector2(1.5, 1.5), 0.42).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
			tw.tween_property(body, "position:y", -100.0, 0.42).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
			tw.tween_property(body, "rotation_degrees", 0.0, 0.2)
			tw.tween_property(body, "modulate:a", 0.0, 0.34).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
		else:
			tw.tween_property(body, "scale", Vector2(0.5, 0.5), 0.35).set_trans(Tween.TRANS_CUBIC)
			tw.tween_property(body, "modulate:a", 0.0, 0.28)
	await get_tree().create_timer(0.48, true).timeout
	_clear_card_pick_now()


func _set_card_highlight(card: Control, highlighted: bool) -> void:
	if card == null:
		return
	var body := card.get_meta("body") as Control
	var idle := card.get_meta("idle") as Control
	if body == null or idle == null:
		card.scale = Vector2(1.08, 1.08) if highlighted else Vector2.ONE
		return
	var float_tw: Tween = card.get_meta("float_tween") as Tween
	var rot_tw: Tween = card.get_meta("rot_tween") as Tween
	var style := body.get_theme_stylebox("panel") as StyleBoxFlat
	var tw := body.create_tween().set_parallel(true)
	if highlighted:
		if float_tw and float_tw.is_running():
			float_tw.pause()
		if rot_tw and rot_tw.is_running():
			rot_tw.pause()
		tw.tween_property(body, "scale", Vector2(1.12, 1.12), 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tw.tween_property(body, "position:y", -10.0, 0.18).set_trans(Tween.TRANS_CUBIC)
		tw.tween_property(idle, "rotation_degrees", 0.0, 0.14).set_trans(Tween.TRANS_CUBIC)
		body.modulate = Color(1.12, 1.12, 1.12, 1.0)
		if style:
			style.shadow_size = max(style.shadow_size, 36)
			style.shadow_color.a = 0.72
	else:
		tw.tween_property(body, "scale", Vector2.ONE, 0.22).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
		tw.tween_property(body, "position:y", 0.0, 0.22).set_trans(Tween.TRANS_CUBIC)
		body.modulate = Color.WHITE
		if style:
			style.shadow_size = 25 if str(CardLibrary.by_id(str(card.get_meta("card_id"))).get("rarity", "common")) == "rare" else 8
			style.shadow_color.a = 0.4 if style.shadow_size == 25 else 0.3
		if float_tw:
			float_tw.play()
		if rot_tw:
			rot_tw.play()


func _scale_card(card: Control, scale: float) -> void:
	if card == null:
		return
	card.custom_minimum_size = Vector2(220.0, 300.0) * scale
	var idle := card.get_meta("idle") as Control
	var body := card.get_meta("body") as Control
	if idle:
		idle.size = Vector2(200.0, 280.0) * scale
		idle.position = (card.custom_minimum_size - idle.size) * 0.5
		idle.pivot_offset = idle.size * 0.5
	if body:
		body.custom_minimum_size = Vector2(200.0, 280.0) * scale
		body.size = body.custom_minimum_size
		body.pivot_offset = body.size * 0.5
	# Inner text scales with the card so a small splitscreen card doesn't
	# render with chunky default fonts and a big single-screen card doesn't
	# render with tiny ones. Base sizes match the values used in _make_card.
	var title := card.get_meta("title_label") as Label
	if title:
		title.add_theme_font_size_override("font_size", maxi(10, int(round(18.0 * scale))))
	var desc := card.get_meta("desc_label") as Label
	if desc:
		desc.add_theme_font_size_override("font_size", maxi(9, int(round(14.0 * scale))))
	var stats := card.get_meta("stats_vbox") as VBoxContainer
	if stats:
		var stat_size: int = maxi(8, int(round(12.0 * scale)))
		for s in stats.get_children():
			if s is Label:
				(s as Label).add_theme_font_size_override("font_size", stat_size)


func _add_holo_overlay(panel: Control, style: StyleBoxFlat) -> void:
	var tw_border := panel.create_tween().set_loops()
	tw_border.tween_property(style, "border_color", Color(0.6, 0.9, 1.0), 1.8)
	tw_border.tween_property(style, "border_color", Color(0.9, 0.6, 1.0), 1.8)
	var holo_shader := Shader.new()
	holo_shader.code = "
		shader_type canvas_item;
		render_mode blend_add;
		uniform sampler2D gradient : source_color;
		uniform float speed = 0.5;
		uniform float angle = 0.5;
		uniform float intensity = 0.16;
		uniform vec2 card_size = vec2(200.0, 280.0);
		uniform float corner_radius = 12.0;

		void fragment() {
			vec2 uv = UV;
			float s = sin(angle);
			float c = cos(angle);
			vec2 rot_uv = vec2(uv.x * c - uv.y * s, uv.x * s + uv.y * c);
			float pos = fract(rot_uv.x * 1.5 + TIME * speed);
			vec4 holo_color = texture(gradient, vec2(pos, 0.5));
			float noise = fract(sin(dot(uv, vec2(12.9898, 78.233))) * 43758.5453);
			holo_color.rgb += noise * 0.15;
			vec2 px = uv * card_size;
			vec2 d = max(vec2(0.0), abs(px - card_size * 0.5) - (card_size * 0.5 - corner_radius));
			float dist = length(d) - corner_radius;
			float mask = smoothstep(1.0, -1.0, dist);
			COLOR = vec4(holo_color.rgb * intensity * mask, 1.0);
		}
	"
	var holo_mat := ShaderMaterial.new()
	holo_mat.shader = holo_shader
	var grad := Gradient.new()
	grad.set_offsets(PackedFloat32Array([0.0, 0.25, 0.5, 0.75, 1.0]))
	grad.set_colors(PackedColorArray([
		Color(1.0, 0.3, 0.3),
		Color(1.0, 0.9, 0.3),
		Color(0.3, 1.0, 0.3),
		Color(0.3, 0.6, 1.0),
		Color(1.0, 0.3, 1.0),
	]))
	var grad_tex := GradientTexture1D.new()
	grad_tex.gradient = grad
	holo_mat.set_shader_parameter("gradient", grad_tex)
	var holo_overlay := ColorRect.new()
	holo_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holo_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	holo_overlay.material = holo_mat
	panel.add_child(holo_overlay)
	panel.move_child(holo_overlay, 0)


func _card_stat_diff(card_id: String) -> Array[String]:
	var out: Array[String] = []
	var player := _player()
	if player == null:
		return out
	var base_w: Weapon = player.get("weapon")
	if base_w == null:
		return out
	var card := CardLibrary.by_id(card_id)
	if card.is_empty():
		return out
	var next_w: Weapon = base_w.duplicate()
	card.apply.call(next_w)
	if abs(base_w.damage_mult - next_w.damage_mult) > 0.001:
		out.append("%+d%% Damage" % int(round((next_w.damage_mult / base_w.damage_mult - 1.0) * 100.0)))
	if abs(base_w.fire_rate_mult - next_w.fire_rate_mult) > 0.001:
		out.append("%+d%% Fire Rate" % int(round((next_w.fire_rate_mult / base_w.fire_rate_mult - 1.0) * 100.0)))
	if base_w.mag_size_bonus != next_w.mag_size_bonus:
		out.append("%+d Ammo Capacity" % (next_w.mag_size_bonus - base_w.mag_size_bonus))
	if abs(base_w.reload_mult - next_w.reload_mult) > 0.001:
		out.append("%+d%% Reload Speed" % int(round((next_w.reload_mult / base_w.reload_mult - 1.0) * 100.0)))
	if abs(base_w.special_cooldown_mult - next_w.special_cooldown_mult) > 0.001:
		var recharge_pct: int = int(round((1.0 - next_w.special_cooldown_mult / maxf(0.001, base_w.special_cooldown_mult)) * 100.0))
		if recharge_pct != 0:
			out.append("%+d%% RMB Recharge" % recharge_pct)
	if base_w.extra_projectiles != next_w.extra_projectiles:
		out.append("%+d Projectiles" % (next_w.extra_projectiles - base_w.extra_projectiles))
	if base_w.ricochet_count != next_w.ricochet_count:
		out.append("%+d Bounces" % (next_w.ricochet_count - base_w.ricochet_count))
	if abs(base_w.move_speed_mult - next_w.move_speed_mult) > 0.001:
		out.append("%+d%% Move Speed" % int(round((next_w.move_speed_mult / base_w.move_speed_mult - 1.0) * 100.0)))
	if abs(base_w.spread - next_w.spread) > 0.00001:
		var acc_pct: int = int(round((1.0 - next_w.spread / maxf(base_w.spread, 0.00001)) * 100.0))
		if acc_pct != 0:
			out.append("%+d%% Accuracy" % acc_pct)
	if abs(base_w.recoil_per_shot - next_w.recoil_per_shot) > 0.00001:
		var stab_pct: int = int(round((1.0 - next_w.recoil_per_shot / maxf(base_w.recoil_per_shot, 0.00001)) * 100.0))
		if stab_pct != 0:
			out.append("%+d%% Stability" % stab_pct)
	if abs(base_w.bullet_speed_mult - next_w.bullet_speed_mult) > 0.001:
		out.append("%+d%% Bullet Speed" % int(round((next_w.bullet_speed_mult / base_w.bullet_speed_mult - 1.0) * 100.0)))
	if next_w.explosive_radius > base_w.explosive_radius:
		out.append("Explosive Payload")
	if base_w.max_hp_bonus != next_w.max_hp_bonus:
		out.append("%+d Max HP" % (next_w.max_hp_bonus - base_w.max_hp_bonus))
	if base_w.extra_jumps != next_w.extra_jumps:
		out.append("%+d Extra Jumps" % (next_w.extra_jumps - base_w.extra_jumps))
	return out


func _update_hud(player: Node) -> void:
	var is_ghost := bool(player.get("ghost_mode"))
	var weapon: Weapon = player.get("weapon")

	_layout_hp_panel(player, is_ghost)

	var reload_progress := 0.0
	if not is_ghost and bool(player.get("reloading")):
		var rifle_cd := float(player.get("rifle_cooldown"))
		var reload_dur: float = maxf(0.01, weapon.get_reload_time())
		reload_progress = clampf(1.0 - rifle_cd / reload_dur, 0.0, 1.0)
	var ammo_text := "GHOST" if is_ghost else "%d / %d" % [int(player.get("mag")), weapon.get_mag_size()]
	_layout_value_panel(_hud.ammo_panel, ammo_text, reload_progress, is_ghost)

	var special_progress := 0.0
	var special_text: String
	if is_ghost:
		special_text = "MINE"
	else:
		var air_strike_charges := int(player.get("_air_strike_charges"))
		if air_strike_charges > 0:
			special_text = "AIR STRIKE" if air_strike_charges == 1 else "AIR STRIKE x%d" % air_strike_charges
		else:
			match weapon.special:
				Weapon.SPECIAL_CLUSTER_GRENADE:
					special_text = "CLUSTER"
				Weapon.SPECIAL_AIR_STRIKE:
					special_text = "AIR STRIKE"
				Weapon.SPECIAL_ION_CANNON:
					special_text = "ION CANNON"
				_:
					special_text = weapon.special.to_upper()
		var special_cd := float(player.get("grenade_cooldown"))
		var special_max: float = float(player.get("special_cooldown_max"))
		if special_cd > 0.0 and special_max > 0.0:
			special_progress = clampf(1.0 - special_cd / special_max, 0.0, 1.0)
	_layout_value_panel(_hud.special_panel, special_text, special_progress, is_ghost)

	_layout_dash_panel(player)

	_layout_revive_panel(player)

	_hud.crosshair.set("spread", player.call("get_effective_spread"))
	_hud.ghost.color.a = 0.28 if is_ghost and not bool(_hud.card_overlay.visible) else 0.0


func _layout_hp_panel(player: Node, is_ghost: bool) -> void:
	var panel: Control = _hud.hp_panel
	var w: float = panel.size.x
	var h: float = panel.size.y
	if h <= 0.0:
		return
	var cross: CrossDraw = panel.get_node("Cross") as CrossDraw
	var label: Label = panel.get_node("Label") as Label
	var cross_size: float = h * 0.85
	cross.position = Vector2(0.0, (h - cross_size) * 0.5)
	cross.size = Vector2(cross_size, cross_size)
	cross.set_cross_color(Color(0.65, 0.85, 1.0) if is_ghost else Color(1.0, 0.35, 0.35))
	var label_x: float = cross_size + 8.0
	label.position = Vector2(label_x, 0.0)
	label.size = Vector2(maxf(0.0, w - label_x), h)
	var font_size: int = int(panel.get_meta("font_size", 22))
	label.add_theme_font_size_override("font_size", font_size)
	label.text = "GHOST" if is_ghost else str(int(player.get("health")))


func _layout_value_panel(panel: Control, text: String, progress: float, is_ghost: bool) -> void:
	var w: float = panel.size.x
	var h: float = panel.size.y
	if h <= 0.0:
		return
	var icon: Control = panel.get_node("Icon")
	var label: Label = panel.get_node("Label") as Label
	var bar_bg: ColorRect = panel.get_node("BarBg") as ColorRect
	var bar_fill: ColorRect = panel.get_node("BarFill") as ColorRect
	var icon_size: float = h * 0.95
	icon.position = Vector2(0.0, (h - icon_size) * 0.5)
	icon.size = Vector2(icon_size, icon_size)
	icon.queue_redraw()
	var content_x: float = icon_size + 8.0
	var content_w: float = maxf(0.0, w - content_x)
	var font_size: int = int(panel.get_meta("font_size", 22))
	if progress > 0.0 and not is_ghost:
		label.visible = false
		bar_bg.visible = true
		bar_fill.visible = true
		var bar_h: float = h * 0.5
		var bar_y: float = (h - bar_h) * 0.5
		bar_bg.position = Vector2(content_x, bar_y)
		bar_bg.size = Vector2(content_w, bar_h)
		bar_fill.position = Vector2(content_x, bar_y)
		bar_fill.size = Vector2(content_w * progress, bar_h)
	else:
		bar_bg.visible = false
		bar_fill.visible = false
		label.visible = true
		label.position = Vector2(content_x, 0.0)
		label.size = Vector2(content_w, h)
		label.add_theme_font_size_override("font_size", font_size)
		label.text = text


func _layout_revive_panel(_player: Node) -> void:
	var label: Label = _hud.get("revive_panel") as Label
	if label == null or game == null:
		return
	var show: bool = game.has_method("is_coop_reviving") and game.is_coop_reviving(player_id)
	label.visible = show
	if not show:
		return
	var font_size: int = int(label.get_meta("font_size", 24))
	label.add_theme_font_size_override("font_size", maxi(16, font_size))
	label.text = "REVIVING..."


func _layout_dash_panel(player: Node) -> void:
	var panel: Control = _hud.dash_panel
	var w: float = panel.size.x
	var h: float = panel.size.y
	if h <= 0.0:
		return
	var icon: Control = panel.get_node("Icon")
	var icon_size: float = h * 0.95
	icon.position = Vector2(0.0, (h - icon_size) * 0.5)
	icon.size = Vector2(icon_size, icon_size)
	icon.queue_redraw()
	var charges: int = int(player.get("dash_charges"))
	var recharge: float = float(player.get("dash_recharge_timer"))
	var recharge_total: float = 3.0  # matches Player.DASH_RECHARGE_TIME
	# Two horizontal slots; each shows full / partial / empty depending on the
	# next charge being recharged.
	var slot_x: float = icon_size + 8.0
	var slot_total_w: float = maxf(0.0, w - slot_x)
	var slot_gap: float = 6.0
	var slot_w: float = (slot_total_w - slot_gap) * 0.5
	var bar_h: float = h * 0.5
	var bar_y: float = (h - bar_h) * 0.5
	for i in 2:
		var bg: ColorRect = panel.get_node("Bar%dBg" % i) as ColorRect
		var fill: ColorRect = panel.get_node("Bar%dFill" % i) as ColorRect
		var slot_left: float = slot_x + i * (slot_w + slot_gap)
		bg.position = Vector2(slot_left, bar_y)
		bg.size = Vector2(slot_w, bar_h)
		var fill_amount: float
		if i < charges:
			fill_amount = 1.0
		elif i == charges:
			fill_amount = clampf(recharge / recharge_total, 0.0, 1.0)
		else:
			fill_amount = 0.0
		fill.position = Vector2(slot_left, bar_y)
		fill.size = Vector2(slot_w * fill_amount, bar_h)


func _player() -> Node3D:
	if game == null:
		return null
	return game.players_root.get_node_or_null(str(player_id)) as Node3D


func _apply_owner_cull(player: Node) -> void:
	var owner_bit := _player_layer_bit(player_id)
	_assign_player_visual_layer(player, owner_bit)
	# The third-person rig doesn't exist yet when that one-time walk runs (it
	# waits for the character model to finish loading) and is rebuilt whenever
	# the gun grows or the skin changes, so its meshes keep coming back on the
	# default layer — which every camera renders, the owner's included. In
	# splitscreen that put a second copy of your own rifle in your own view,
	# hanging off your hand at whatever angle the third-person mount uses.
	# Re-walked every frame like the FP rig, and just as cheap: the setter
	# only writes when the layer actually differs.
	var tp_rig: Node = player.get("_third_person_gun")
	if tp_rig != null and is_instance_valid(tp_rig):
		_set_visual_layer_recursive(tp_rig, owner_bit)
	# FP rig onto this view's gun layer. Re-walked every frame (writes only on
	# change) because the procedural gun rebuilds its meshes on every card.
	var fp_bit := _fp_gun_layer_bit(player_id)
	var fp_rig := player.get_node_or_null("Camera/Muzzle")
	if fp_rig:
		_set_fp_layer_recursive(fp_rig, fp_bit)
	camera.cull_mask = (0xfffff & ~owner_bit & ~FP_GUN_LAYER_MASK) | fp_bit


func _assign_player_visual_layer(player: Node, layer_bit: int) -> void:
	if bool(player.get_meta("render_player_layer_assigned", false)) \
			and int(player.get_meta("render_player_layer_bit", 0)) == layer_bit:
		return
	var body := player.get_node_or_null("BodyModel")
	if body:
		_set_visual_layer_recursive(body, layer_bit)
	player.set_meta("render_player_layer_assigned", true)
	player.set_meta("render_player_layer_bit", layer_bit)


func _set_visual_layer_recursive(node: Node, layer_bit: int) -> void:
	if node is VisualInstance3D:
		var vi := node as VisualInstance3D
		if vi.layers != layer_bit:
			vi.layers = layer_bit
	for child in node.get_children():
		_set_visual_layer_recursive(child, layer_bit)


func _player_layer_bit(id: int) -> int:
	if id >= 10000:
		return 1 << (PLAYER_VISUAL_LAYER_BASE + 1 + posmod(id - 10000, 10))
	return 1 << PLAYER_VISUAL_LAYER_BASE


func _fp_gun_layer_bit(id: int) -> int:
	if id >= 10000:
		return 1 << (FP_GUN_LAYER_BASE + 1 + posmod(id - 10000, 6))
	return 1 << FP_GUN_LAYER_BASE


func _set_fp_layer_recursive(node: Node, layer_bit: int) -> void:
	if node is VisualInstance3D:
		var vi := node as VisualInstance3D
		if vi.layers != layer_bit:
			vi.layers = layer_bit
	for child in node.get_children():
		_set_fp_layer_recursive(child, layer_bit)
