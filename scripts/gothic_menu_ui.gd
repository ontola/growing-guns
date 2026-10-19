class_name GothicMenuUi
extends RefCounted

const GothicMenuFrameScene = preload("res://scripts/gothic_menu_frame.gd")

const STONE_BASE := Color(0.11, 0.10, 0.095, 0.97)
const STONE_HI := Color(0.20, 0.18, 0.16, 1.0)
const STONE_LO := Color(0.06, 0.055, 0.05, 1.0)
const GOLD := Color(0.78, 0.58, 0.22, 1.0)
const GOLD_DIM := Color(0.48, 0.34, 0.14, 1.0)
const IRON := Color(0.04, 0.035, 0.04, 1.0)
const CREAM := Color(0.92, 0.82, 0.62, 1.0)
const MUTED := Color(0.62, 0.56, 0.48, 1.0)
const ACCENT := Color(0.95, 0.55, 0.32, 1.0)

const TITLE_FONT_SIZE := 48
const TITLE_OUTLINE := Color(0.32, 0.05, 0.06, 1.0)


static func apply_start_screen(ui: CanvasLayer) -> void:
	var panel := ui.get_node_or_null("MenuPanel")
	if panel == null:
		return
	_style_title(ui.get_node_or_null("Title") as Label)
	_style_menu_tree(panel)
	var dim := ui.get_node_or_null("Dim") as ColorRect
	if dim:
		dim.color = Color(0.02, 0.01, 0.015, 0.22)


static func apply_settings_panel(panel: PanelContainer) -> void:
	if panel == null:
		return
	panel.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	var frame: Control = GothicMenuFrameScene.new()
	frame.name = "GothicFrame"
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(frame)
	panel.move_child(frame, 0)
	var margin := panel.get_node_or_null("SettingsMargin") as MarginContainer
	if margin:
		margin.add_theme_constant_override("margin_left", 30)
		margin.add_theme_constant_override("margin_right", 30)
		margin.add_theme_constant_override("margin_top", 56)
		margin.add_theme_constant_override("margin_bottom", 28)
	_style_menu_tree(panel)


static func _style_title(title: Label) -> void:
	if title == null:
		return
	UiStyle.display_label(title, 60)


static func _style_menu_tree(root: Node) -> void:
	for child in root.get_children():
		if child is Label:
			_style_label(child as Label)
		elif child is Button:
			_style_button(child as Button)
		elif child is LineEdit:
			_style_line_edit(child as LineEdit)
		elif child is CheckButton:
			_style_check_button(child as CheckButton)
		elif child is HSeparator:
			_style_separator(child as HSeparator)
		if child.get_child_count() > 0:
			_style_menu_tree(child)


static func _style_label(label: Label) -> void:
	if label.name == "ExitNote":
		label.add_theme_color_override("font_color", MUTED.darkened(0.08))
		label.add_theme_font_size_override("font_size", 11)
		return
	if label.name == "Notice":
		return
	if label.name == "SettingsTitle":
		label.add_theme_font_size_override("font_size", 26)
		label.add_theme_color_override("font_color", Color(0.98, 0.82, 0.38))
		label.add_theme_color_override("font_outline_color", TITLE_OUTLINE)
		label.add_theme_constant_override("outline_size", 5)
		return
	label.add_theme_color_override("font_color", CREAM.lightened(0.02))
	label.add_theme_font_size_override("font_size", 14)


static func _style_button(button: Button) -> void:
	var styles := _button_styleboxes()
	button.add_theme_stylebox_override("normal", styles["normal"])
	button.add_theme_stylebox_override("hover", styles["hover"])
	button.add_theme_stylebox_override("pressed", styles["pressed"])
	button.add_theme_stylebox_override("focus", styles["focus"])
	button.add_theme_stylebox_override("disabled", styles["disabled"])
	button.add_theme_color_override("font_color", CREAM)
	button.add_theme_color_override("font_hover_color", Color(1.0, 0.92, 0.72))
	button.add_theme_color_override("font_pressed_color", GOLD)
	button.add_theme_color_override("font_disabled_color", MUTED.darkened(0.25))
	button.add_theme_color_override("font_focus_color", Color(1.0, 0.94, 0.78))
	button.add_theme_font_size_override("font_size", 15)


static func _style_line_edit(field: LineEdit) -> void:
	var styles := _input_styleboxes()
	field.add_theme_stylebox_override("normal", styles["normal"])
	field.add_theme_stylebox_override("focus", styles["focus"])
	field.add_theme_stylebox_override("read_only", styles["read_only"])
	field.add_theme_color_override("font_color", CREAM.lightened(0.05))
	field.add_theme_color_override("font_placeholder_color", MUTED.darkened(0.12))
	field.add_theme_font_size_override("font_size", 13)
	field.custom_minimum_size.y = maxf(field.custom_minimum_size.y, 34.0)


static func _style_check_button(toggle: CheckButton) -> void:
	toggle.add_theme_color_override("font_color", CREAM.lightened(0.02))
	toggle.add_theme_color_override("font_hover_color", Color(1.0, 0.92, 0.72))
	toggle.add_theme_color_override("font_pressed_color", GOLD)
	toggle.add_theme_font_size_override("font_size", 14)
	toggle.custom_minimum_size.y = maxf(toggle.custom_minimum_size.y, 34.0)


static func _style_separator(sep: HSeparator) -> void:
	var line := StyleBoxLine.new()
	line.color = GOLD_DIM
	line.grow_begin = 2
	line.grow_end = 2
	line.thickness = 1
	sep.add_theme_stylebox_override("separator", line)


static func _button_styleboxes() -> Dictionary:
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.13, 0.11, 0.10, 0.98)
	normal.border_color = GOLD_DIM
	normal.set_border_width_all(1)
	normal.set_corner_radius_all(2)
	normal.content_margin_top = 6
	normal.content_margin_bottom = 6

	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(0.18, 0.14, 0.11, 0.98)
	hover.border_color = GOLD

	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = Color(0.09, 0.07, 0.06, 1.0)
	pressed.border_color = ACCENT

	var focus := hover.duplicate() as StyleBoxFlat
	focus.border_color = Color(0.95, 0.72, 0.28)
	focus.set_border_width_all(2)

	var disabled := normal.duplicate() as StyleBoxFlat
	disabled.bg_color = Color(0.10, 0.09, 0.08, 0.75)
	disabled.border_color = GOLD_DIM.darkened(0.35)

	return {
		"normal": normal,
		"hover": hover,
		"pressed": pressed,
		"focus": focus,
		"disabled": disabled,
	}


static func _input_styleboxes() -> Dictionary:
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.07, 0.06, 0.055, 0.98)
	normal.border_color = GOLD_DIM.darkened(0.15)
	normal.set_border_width_all(1)
	normal.set_corner_radius_all(2)
	normal.content_margin_left = 10
	normal.content_margin_right = 10
	normal.content_margin_top = 6
	normal.content_margin_bottom = 6

	var focus := normal.duplicate() as StyleBoxFlat
	focus.border_color = GOLD

	var read_only := normal.duplicate() as StyleBoxFlat
	read_only.bg_color = Color(0.06, 0.055, 0.05, 0.92)

	return {"normal": normal, "focus": focus, "read_only": read_only}


static func draw_frame(canvas: CanvasItem, rect: Rect2, seed: int) -> void:
	if rect.size.x < 8.0 or rect.size.y < 8.0:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var spike_h := 16.0
	var outer := rect.grow(2.0)
	outer.position.y -= spike_h

	_draw_stone_fill(canvas, outer, rng)
	_draw_iron_outer(canvas, outer, spike_h, rng)
	_draw_gold_inner(canvas, rect.grow(-5.0))
	_draw_corner_brackets(canvas, rect.grow(-3.0))
	_draw_skull_crest(canvas, rect, spike_h)


static func _draw_stone_fill(canvas: CanvasItem, rect: Rect2, rng: RandomNumberGenerator) -> void:
	canvas.draw_rect(rect, STONE_BASE, true)
	var cell := 14.0
	var cols := int(ceil(rect.size.x / cell))
	var rows := int(ceil(rect.size.y / cell))
	for y in rows:
		for x in cols:
			var tile := Rect2(
				rect.position.x + float(x) * cell,
				rect.position.y + float(y) * cell,
				cell - 1.0,
				cell - 1.0,
			)
			var n := rng.randf()
			var c := STONE_BASE
			if n < 0.22:
				c = STONE_LO
			elif n > 0.82:
				c = STONE_HI
			canvas.draw_rect(tile, c, true)
			if rng.randf() > 0.72:
				var speck := tile.position + Vector2(rng.randf_range(2.0, tile.size.x - 3.0), rng.randf_range(2.0, tile.size.y - 3.0))
				canvas.draw_rect(Rect2(speck, Vector2(2.0, 1.0)), STONE_HI.lightened(0.08), true)


static func _draw_iron_outer(canvas: CanvasItem, rect: Rect2, spike_h: float, rng: RandomNumberGenerator) -> void:
	canvas.draw_rect(rect, IRON, false, 3.0)
	var top_y := rect.position.y
	var left_x := rect.position.x
	var right_x := rect.position.x + rect.size.x
	var spike_w := 18.0
	var count := maxi(3, int(floor(rect.size.x / spike_w)))
	var span := rect.size.x / float(count)
	for i in count:
		var cx := left_x + span * (float(i) + 0.5)
		var h := spike_h * rng.randf_range(0.75, 1.05)
		var half_w := span * 0.34
		var pts := PackedVector2Array([
			Vector2(cx - half_w, top_y + 2.0),
			Vector2(cx, top_y - h),
			Vector2(cx + half_w, top_y + 2.0),
		])
		canvas.draw_colored_polygon(pts, IRON)
		canvas.draw_polyline(pts, GOLD_DIM.darkened(0.35), 1.0, true)
	# Side buttresses
	for side in [-1.0, 1.0]:
		var x := left_x if side < 0.0 else right_x
		var pts := PackedVector2Array([
			Vector2(x, rect.position.y + rect.size.y * 0.18),
			Vector2(x + 8.0 * side, rect.position.y + rect.size.y * 0.28),
			Vector2(x, rect.position.y + rect.size.y * 0.38),
		])
		canvas.draw_colored_polygon(pts, IRON)


static func _draw_gold_inner(canvas: CanvasItem, rect: Rect2) -> void:
	canvas.draw_rect(rect, GOLD_DIM, false, 1.0)
	canvas.draw_rect(rect.grow(-1.0), GOLD.darkened(0.25), false, 1.0)


static func _draw_corner_brackets(canvas: CanvasItem, rect: Rect2) -> void:
	var len := 16.0
	var inset := 4.0
	var corners := [
		Vector2(rect.position.x + inset, rect.position.y + inset),
		Vector2(rect.end.x - inset, rect.position.y + inset),
		Vector2(rect.position.x + inset, rect.end.y - inset),
		Vector2(rect.end.x - inset, rect.end.y - inset),
	]
	var dirs := [
		[Vector2(1, 0), Vector2(0, 1)],
		[Vector2(-1, 0), Vector2(0, 1)],
		[Vector2(1, 0), Vector2(0, -1)],
		[Vector2(-1, 0), Vector2(0, -1)],
	]
	for i in 4:
		var c: Vector2 = corners[i]
		var d: Array = dirs[i]
		canvas.draw_line(c, c + d[0] * len, GOLD, 2.0)
		canvas.draw_line(c, c + d[1] * len, GOLD, 2.0)


static func _draw_skull_crest(canvas: CanvasItem, rect: Rect2, spike_h: float) -> void:
	var cx := rect.position.x + rect.size.x * 0.5
	var cy := rect.position.y + spike_h + 18.0
	var cranium := Vector2(11.0, 13.0)
	_draw_ellipse(canvas, Vector2(cx, cy), cranium.x, cranium.y, Color(0.72, 0.68, 0.62))
	_draw_ellipse(canvas, Vector2(cx, cy), cranium.x - 1.0, cranium.y - 1.0, Color(0.58, 0.54, 0.50))
	canvas.draw_circle(Vector2(cx - 4.5, cy - 1.0), 2.6, Color(0.08, 0.06, 0.05))
	canvas.draw_circle(Vector2(cx + 4.5, cy - 1.0), 2.6, Color(0.08, 0.06, 0.05))
	var nose := PackedVector2Array([
		Vector2(cx, cy + 2.0),
		Vector2(cx - 2.5, cy + 7.0),
		Vector2(cx + 2.5, cy + 7.0),
	])
	canvas.draw_colored_polygon(nose, Color(0.10, 0.08, 0.07))
	var jaw_y := cy + cranium.y - 1.0
	canvas.draw_line(Vector2(cx - 7.0, jaw_y), Vector2(cx + 7.0, jaw_y), Color(0.12, 0.10, 0.09), 2.0)
	for t in 5:
		var tx := cx - 5.0 + float(t) * 2.5
		canvas.draw_line(Vector2(tx, jaw_y), Vector2(tx, jaw_y + 3.0), Color(0.14, 0.12, 0.11), 1.0)
	canvas.draw_arc(Vector2(cx, cy - 2.0), cranium.x + 2.0, PI * 1.08, PI * 1.92, 18, GOLD_DIM, 1.5, true)


static func _draw_ellipse(canvas: CanvasItem, center: Vector2, rx: float, ry: float, col: Color) -> void:
	if rx <= 0.0 or ry <= 0.0:
		return
	var pts := PackedVector2Array()
	const SEG := 22
	for i in SEG:
		var a := TAU * float(i) / float(SEG)
		pts.append(center + Vector2(cos(a) * rx, sin(a) * ry))
	canvas.draw_colored_polygon(pts, col)
