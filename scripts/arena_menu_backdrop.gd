extends Control
## Behind the GameNight Start menu: a dark slab down the left with a slanted
## red edge, faint hatching, and the game dimmed (not hidden) to the right.

const SLAB_WIDTH := 0.42


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)


func _draw() -> void:
	var w := size.x
	var h := size.y
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.42))
	var top := w * SLAB_WIDTH
	var bottom := top - h * UiStyle.SKEW * 0.5
	var slab := PackedVector2Array([Vector2.ZERO, Vector2(top, 0), Vector2(bottom, h), Vector2(0, h)])
	draw_colored_polygon(slab, Color(UiStyle.INK.darkened(0.3), 0.94))
	var hatch := Color(UiStyle.RED, 0.05)
	var x := -h
	while x < top:
		var a := Vector2(x, h)
		var b := Vector2(x + h, 0)
		var clipped := Geometry2D.clip_polyline_with_polygon(PackedVector2Array([a, b]), slab)
		for part in clipped:
			draw_polyline(part, hatch, 3.0)
		x += 14.0
	# The red edge, and a thinner bone line just inside it.
	var edge := 8.0
	draw_colored_polygon(PackedVector2Array([
		Vector2(top, 0), Vector2(top + edge, 0), Vector2(bottom + edge, h), Vector2(bottom, h)]), UiStyle.RED)
	draw_line(Vector2(top - 14.0, 0), Vector2(bottom - 14.0, h), Color(UiStyle.BONE, 0.12), 2.0)
