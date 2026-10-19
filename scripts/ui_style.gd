class_name UiStyle
extends RefCounted
## The "Arena" look (Joep picked it, 2026-10-19): fight-poster type, slanted
## plates with a red edge, bone white on arterial red. Everything that draws
## UI takes its fonts, colours and plates from here.

const DISPLAY: FontFile = preload("res://assets/fonts/Anton-Regular.ttf")
const BOLD: FontFile = preload("res://assets/fonts/BarlowCondensed-ExtraBold.ttf")
const BODY: FontFile = preload("res://assets/fonts/BarlowCondensed-SemiBold.ttf")

const RED := Color(0.843, 0.149, 0.239)
const RED_DARK := Color(0.42, 0.04, 0.09)
const BONE := Color(0.965, 0.933, 0.886)
const BONE_DIM := Color(0.965, 0.933, 0.886, 0.72)
const PLATE := Color(0.07, 0.035, 0.04, 0.8)
const INK := Color(0.11, 0.065, 0.07)

## Plates lean like the type: x shifts by this fraction of the height.
const SKEW := 0.21

static var _installed := false


## Make the Arena fonts and controls the default for every Control, including
## the ones inside each player's SubViewport (which never see a Window theme).
static func install() -> void:
	if _installed:
		return
	_installed = true
	ThemeDB.fallback_font = BODY
	var theme := ThemeDB.get_default_theme()
	theme.default_font = BODY
	for type in ["Button", "CheckButton", "OptionButton"]:
		theme.set_font("font", type, BOLD)
		theme.set_color("font_color", type, BONE_DIM)
		theme.set_color("font_hover_color", type, BONE)
		theme.set_color("font_focus_color", type, BONE)
		theme.set_color("font_pressed_color", type, BONE)
		theme.set_color("font_hover_pressed_color", type, BONE)
		theme.set_color("font_disabled_color", type, Color(BONE, 0.3))
	theme.set_font_size("font_size", "Button", 22)
	var idle := plate(Color(0, 0, 0, 0), false)
	var lit := plate(RED, false)
	var held := plate(RED_DARK, false)
	theme.set_stylebox("normal", "Button", idle)
	theme.set_stylebox("disabled", "Button", idle)
	theme.set_stylebox("hover", "Button", lit)
	theme.set_stylebox("focus", "Button", lit)
	theme.set_stylebox("pressed", "Button", held)
	theme.set_stylebox("hover_pressed", "Button", held)
	theme.set_font("font", "Label", BODY)


## A slanted plate. `accent` paints the red edge on the left.
static func plate(bg: Color = PLATE, accent: bool = true, pad := Vector2(14, 6)) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.skew = Vector2(SKEW, 0.0)
	style.anti_aliasing = true
	if accent:
		style.border_color = RED
		style.border_width_left = 5
	style.content_margin_left = pad.x
	style.content_margin_right = pad.x
	style.content_margin_top = pad.y
	style.content_margin_bottom = pad.y
	return style


## The big framed panel behind a menu.
static func menu_panel() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.03, 0.035, 0.94)
	style.border_color = RED
	style.border_width_left = 6
	style.content_margin_left = 26
	style.content_margin_right = 26
	style.content_margin_top = 22
	style.content_margin_bottom = 22
	return style


## Poster-style display text: bone white with a hard red drop shadow.
static func display_label(label: Label, size: int, shadow: int = 0) -> void:
	label.add_theme_font_override("font", DISPLAY)
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", BONE)
	var offset := shadow if shadow > 0 else maxi(2, int(round(size * 0.07)))
	label.add_theme_color_override("font_shadow_color", RED)
	label.add_theme_constant_override("shadow_offset_x", offset)
	label.add_theme_constant_override("shadow_offset_y", offset)
	label.add_theme_constant_override("shadow_outline_size", 0)
	label.add_theme_constant_override("outline_size", 0)


# ── Icons ─────────────────────────────────────────────────────────────────
# Drawn as vectors inside `rect`, so they stay sharp at any size and in
# every split-screen view.

static func draw_heart(ci: CanvasItem, rect: Rect2, color: Color, plus: bool = true) -> void:
	var c := rect.get_center()
	var r := minf(rect.size.x, rect.size.y) * 0.5
	var lobe := r * 0.52
	var pts := PackedVector2Array()
	# Two lobes and a point, traced as one outline.
	for i in 13:
		var a := lerpf(PI * 0.75, PI * 2.0, float(i) / 12.0)
		pts.append(c + Vector2(-lobe * 0.92, -r * 0.28) + Vector2(cos(a), sin(a)) * lobe)
	for i in 13:
		var a := lerpf(PI, PI * 2.25, float(i) / 12.0)
		pts.append(c + Vector2(lobe * 0.92, -r * 0.28) + Vector2(cos(a), sin(a)) * lobe)
	pts.append(c + Vector2(0.0, r * 0.95))
	ci.draw_colored_polygon(pts, color)
	if plus:
		var t := r * 0.26
		var l := r * 0.62
		var pc := c + Vector2(0.0, -r * 0.05)
		ci.draw_rect(Rect2(pc - Vector2(l, t) * 0.5, Vector2(l, t)), BONE)
		ci.draw_rect(Rect2(pc - Vector2(t, l) * 0.5, Vector2(t, l)), BONE)


static func draw_bullet(ci: CanvasItem, rect: Rect2, color: Color) -> void:
	var w := rect.size.x * 0.36
	var x := rect.get_center().x - w * 0.5
	var top := rect.position.y + rect.size.y * 0.06
	var bottom := rect.end.y - rect.size.y * 0.04
	var tip := top + w * 1.15
	var pts := PackedVector2Array([Vector2(x, bottom), Vector2(x, tip)])
	for i in 9:
		var a := lerpf(PI, TAU, float(i) / 8.0)
		pts.append(Vector2(x + w * 0.5 + cos(a) * w * 0.5, tip + sin(a) * (tip - top)))
	pts.append(Vector2(x + w, bottom))
	ci.draw_colored_polygon(pts, color)
	ci.draw_rect(Rect2(x - w * 0.12, bottom - rect.size.y * 0.16, w * 1.24, rect.size.y * 0.16), Color(color, 0.55))


static func draw_grenade(ci: CanvasItem, rect: Rect2, color: Color) -> void:
	var s := minf(rect.size.x, rect.size.y)
	var c := rect.get_center() + Vector2(-s * 0.04, s * 0.1)
	ci.draw_circle(c, s * 0.33, color)
	ci.draw_rect(Rect2(c + Vector2(-s * 0.12, -s * 0.46), Vector2(s * 0.24, s * 0.14)), color)
	ci.draw_arc(c + Vector2(s * 0.2, -s * 0.36), s * 0.14, PI, TAU * 0.95, 8, color, maxf(1.5, s * 0.07))
	var groove := Color(0, 0, 0, 0.32)
	ci.draw_rect(Rect2(c + Vector2(-s * 0.26, -s * 0.08), Vector2(s * 0.52, s * 0.06)), groove)
	ci.draw_rect(Rect2(c + Vector2(-s * 0.26, s * 0.08), Vector2(s * 0.52, s * 0.06)), groove)


static func draw_dash(ci: CanvasItem, rect: Rect2, color: Color) -> void:
	var s := minf(rect.size.x, rect.size.y)
	var o := rect.get_center() - Vector2(s, s) * 0.5
	for k in 2:
		var x := o.x + s * (0.06 + k * 0.38)
		var col := color if k == 0 else Color(color, 0.6)
		ci.draw_colored_polygon(PackedVector2Array([
			Vector2(x, o.y + s * 0.15), Vector2(x + s * 0.24, o.y + s * 0.15),
			Vector2(x + s * 0.5, o.y + s * 0.5), Vector2(x + s * 0.24, o.y + s * 0.85),
			Vector2(x, o.y + s * 0.85), Vector2(x + s * 0.26, o.y + s * 0.5)]), col)


## A small button prompt ("LT", "RB") tucked into an icon's corner.
static func draw_prompt(ci: CanvasItem, rect: Rect2, text: String) -> void:
	var size := maxi(9, int(round(rect.size.y * 0.42)))
	var text_size := BOLD.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size)
	# Hangs off the bottom-right corner; a long one ("SHIFT") grows leftward
	# over the icon rather than into the number beside it.
	var box := Rect2(rect.end + Vector2(3, 2) - text_size - Vector2(6, 2), text_size + Vector2(6, 2))
	ci.draw_rect(box, RED)
	ci.draw_string(BOLD, Vector2(box.position.x + 3, box.position.y + 1 + BOLD.get_ascent(size)), text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size, BONE)
