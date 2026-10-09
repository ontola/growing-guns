extends Control

enum Type { SHIFT, LMB, RMB }
@export var icon_type: Type = Type.LMB
@export var icon_color: Color = Color.WHITE

static var use_controller_icons := false

# Mouse/keyboard names in prompt text ("RMB: call a rocket") rewritten for a
# pad, matching the bindings in game.gd _install_controller_input_map.
const PAD_PROMPTS := [["RMB", "LT"], ["LMB", "RT"], ["Shift", "RB"], ["SHIFT", "RB"]]


static func prompt_text(text: String, controller: bool) -> String:
	if not controller:
		return text
	for pair: Array in PAD_PROMPTS:
		text = text.replace(pair[0], pair[1])
	return text


func _ready() -> void:
	add_to_group("hud_input_icons")
	_refresh_input_device()

func _refresh_input_device() -> void:
	for child in get_children():
		if child is Label:
			child.visible = false
	queue_redraw()

func _draw() -> void:
	if use_controller_icons:
		match icon_type:
			Type.SHIFT:
				_draw_button_label("RB")
			Type.LMB:
				_draw_trigger_label("RT")
			Type.RMB:
				_draw_trigger_label("LT")
	else:
		match icon_type:
			Type.SHIFT:
				_draw_key_label("SHIFT")
			Type.LMB:
				_draw_mouse_icon(true)
			Type.RMB:
				_draw_mouse_icon(false)

func _draw_key_label(text: String) -> void:
	var r := Rect2(Vector2.ZERO, size)
	draw_rect(r, icon_color, false, 1.5)
	_draw_centered_text(text, 10)

func _draw_button_label(text: String) -> void:
	var rect := Rect2(Vector2(1.0, 1.0), size - Vector2(2.0, 2.0))
	draw_rect(rect, Color(icon_color.r, icon_color.g, icon_color.b, 0.12), true)
	draw_rect(rect, icon_color, false, 1.5)
	_draw_centered_text(text, 10)

func _draw_trigger_label(text: String) -> void:
	var top := size.y * 0.18
	var rect := Rect2(Vector2(1.0, top), Vector2(size.x - 2.0, size.y - top - 1.0))
	draw_rect(rect, Color(icon_color.r, icon_color.g, icon_color.b, 0.12), true)
	draw_rect(rect, icon_color, false, 1.5)
	draw_line(Vector2(size.x * 0.25, top), Vector2(size.x * 0.75, top), icon_color, 1.5)
	_draw_centered_text(text, 10)

func _draw_centered_text(text: String, font_size: int) -> void:
	var font := get_theme_default_font()
	if font == null:
		return
	var text_size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size)
	var pos := Vector2(
		(size.x - text_size.x) * 0.5,
		(size.y - text_size.y) * 0.5 + font.get_ascent(font_size)
	)
	draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, icon_color)

func _draw_mouse_icon(left_filled: bool) -> void:
	var w := size.x
	var h := size.y
	var center := size * 0.5

	# Mouse body outline
	var points := PackedVector2Array()
	var sides := 16
	for i in range(sides + 1):
		var ang := PI + (float(i) / sides) * PI
		points.append(center + Vector2(cos(ang) * w * 0.4, sin(ang) * h * 0.4))
	for i in range(sides + 1):
		var ang := (float(i) / sides) * PI
		points.append(center + Vector2(cos(ang) * w * 0.4, sin(ang) * h * 0.3 + h * 0.2))

	draw_polyline(points, icon_color, 1.5, true)

	# Split line
	draw_line(center + Vector2(0, -h * 0.4), center, icon_color, 1.5)

	# Filled button
	if left_filled:
		var left_poly := PackedVector2Array()
		for i in range(int(sides/2) + 1):
			var ang := PI + (float(i) / sides) * PI
			left_poly.append(center + Vector2(cos(ang) * w * 0.4, sin(ang) * h * 0.4))
		left_poly.append(center)
		draw_colored_polygon(left_poly, icon_color)
	else:
		var right_poly := PackedVector2Array()
		for i in range(int(sides/2), sides + 1):
			var ang := PI + (float(i) / sides) * PI
			right_poly.append(center + Vector2(cos(ang) * w * 0.4, sin(ang) * h * 0.4))
		right_poly.append(center)
		draw_colored_polygon(right_poly, icon_color)
