class_name CardFace
extends Control
## The front of a pick card, drawn as a fight poster: a category band, an art
## panel with a sunburst and the card's icon, the name in poster type, the
## description, and the stat changes as coloured chips. Everything is drawn
## from `size`, so a card scales cleanly from a splitscreen quarter to 4K.

const GOLD := Color(1.0, 0.78, 0.25)
const GOOD := Color(0.55, 1.0, 0.45)
const BAD := Color(1.0, 0.38, 0.36)

## Card id -> icon. Cards not listed get a star.
const ICONS := {
	"dmg_up": "skull", "headhunter": "skull", "glass_cannon": "skull", "haymaker": "fist",
	"healthy": "heart", "lifesteal": "heart",
	"steady_hands": "crosshair", "precision": "crosshair", "hitscan": "crosshair",
	"sniper": "crosshair", "homing": "homing",
	"sneakers": "wing", "acrobat": "wing", "dodge": "wing",
	"rapid_fire": "bullets", "uzi": "bullets", "minigun": "bullets", "spray": "bullets",
	"extra_barrel": "bullets", "shotgun": "bullets",
	"bullet_speed": "bullet", "heavy_rounds": "bullet", "last_bullet": "bullet",
	"wind_up": "bullet", "grow": "bullet", "drill_rounds": "bullet", "careful_planning": "bullet",
	"big_mag": "mag", "scavenger": "mag", "tactical_reload": "mag",
	"quick_reload": "reload", "refreshed": "reload", "echo": "reload",
	"ricochet": "bounce", "silencer": "silencer",
	"explosive": "bomb", "landmine_rounds": "bomb", "backblast": "bomb", "bazooka": "bomb",
	"cluster_grenade": "bomb", "air_strike": "bomb",
	"poison": "drop", "chilling_rounds": "snow",
	"big_head": "body", "chonky": "body", "slenderman": "body", "flatfish": "body",
	"phoenix": "flame", "teleport": "swirl", "sword": "sword", "ninja": "sword",
	"ion_cannon": "beam",
}
const BODY_CARDS := ["big_head", "chonky", "slenderman", "flatfish", "healthy", "glass_cannon", "phoenix"]

var card_id := ""
var card: Dictionary = {}
var desc := ""
var stats: Array[String] = []


func setup(id: String, data: Dictionary, description: String, stat_lines: Array[String]) -> void:
	card_id = id
	card = data
	desc = description
	stats = stat_lines
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	queue_redraw()


func is_rare() -> bool:
	return str(card.get("rarity", "common")) == "rare"


func accent() -> Color:
	return card.get("color", Color.WHITE)


## The band at the top: what kind of card this is.
func category() -> String:
	var text := str(card.get("desc", ""))
	if text.begins_with("RMB"):
		return "SPECIAL"
	if text.begins_with("Shift"):
		return "MOVE"
	if card_id in BODY_CARDS:
		return "BODY"
	if (card.get("tags", []) as Array).has("firepower"):
		return "FIREPOWER"
	return "PERK"


func _draw() -> void:
	var k := size.x / 200.0
	if k <= 0.0:
		return
	var col := accent()
	var edge := GOLD if is_rare() else col
	var full := Rect2(Vector2.ZERO, size)

	# Ground: near black, tinted with the card colour. Plain: the diagonal
	# hatching that used to be here went (Joep, 2026-10-21).
	draw_rect(full, UiStyle.INK.lerp(col, 0.06))

	# Art panel with a soft glow behind the icon. It had a striped sunburst,
	# which went with the hatching (Joep, 2026-10-21).
	var art_h := (112.0 - maxf(0.0, stats.size() - 2.0) * 15.0) * k
	art_h = maxf(art_h, 70.0 * k)
	var art := Rect2(10.0 * k, 32.0 * k, size.x - 18.0 * k, art_h)
	draw_rect(art, UiStyle.INK.darkened(0.35))
	var c := art.get_center()
	for i in 6:
		draw_circle(c, art.size.y * lerpf(0.5, 0.38, float(i) / 5.0), Color(edge, 0.045))
	draw_circle(c, art.size.y * 0.36, Color(edge, 0.18))
	var icon_s := minf(art.size.y * 0.72, 80.0 * k)
	var icon_rect := Rect2(c - Vector2(icon_s, icon_s) * 0.5, Vector2(icon_s, icon_s))
	draw_icon(self, str(ICONS.get(card_id, "star")), icon_rect, Color(0, 0, 0, 0.55), Vector2(3, 3) * k)
	draw_icon(self, str(ICONS.get(card_id, "star")), icon_rect, edge.lerp(UiStyle.BONE, 0.25), Vector2.ZERO)
	draw_rect(art, Color(UiStyle.BONE, 0.18), false, maxf(1.0, k))

	# Category band, slanted like the HUD plates.
	var band_h := 20.0 * k
	var band_w := 96.0 * k
	draw_colored_polygon(PackedVector2Array([
		Vector2(0, 6.0 * k), Vector2(band_w + band_h * UiStyle.SKEW, 6.0 * k),
		Vector2(band_w, 6.0 * k + band_h), Vector2(0, 6.0 * k + band_h)]), edge)
	var cat_size := int(round(13.0 * k))
	_text(UiStyle.BOLD, Vector2(12.0 * k, 6.0 * k + band_h * 0.5), category(), cat_size, UiStyle.INK, HORIZONTAL_ALIGNMENT_LEFT, -1.0)
	if is_rare():
		_text(UiStyle.DISPLAY, Vector2(size.x - 10.0 * k, 6.0 * k + band_h * 0.5), "RARE", int(round(14.0 * k)), GOLD, HORIZONTAL_ALIGNMENT_RIGHT, -1.0)

	# Name: poster type, shrunk until it fits on one line.
	var name_text := str(card.get("name", card_id)).to_upper()
	var name_size := int(round(30.0 * k))
	var max_w := size.x - 22.0 * k
	while name_size > 10 and UiStyle.DISPLAY.get_string_size(name_text, HORIZONTAL_ALIGNMENT_LEFT, -1, name_size).x > max_w:
		name_size -= 1
	var name_y := art.end.y + 10.0 * k + UiStyle.DISPLAY.get_ascent(name_size)
	var shadow := maxf(1.0, 2.0 * k)
	draw_string(UiStyle.DISPLAY, Vector2(11.0 * k + shadow, name_y + shadow), name_text, HORIZONTAL_ALIGNMENT_CENTER, max_w, name_size, UiStyle.RED)
	draw_string(UiStyle.DISPLAY, Vector2(11.0 * k, name_y), name_text, HORIZONTAL_ALIGNMENT_CENTER, max_w, name_size, UiStyle.BONE)

	# Description.
	var y := name_y + UiStyle.DISPLAY.get_descent(name_size) + 4.0 * k
	if not desc.is_empty():
		var desc_size := int(round(14.0 * k))
		y += UiStyle.BODY.get_ascent(desc_size)
		draw_multiline_string(UiStyle.BODY, Vector2(14.0 * k, y), desc, HORIZONTAL_ALIGNMENT_CENTER, size.x - 28.0 * k, desc_size, 3 if stats.size() < 3 else 2, UiStyle.BONE_DIM)

	# Stat chips, stacked up from the bottom edge.
	var row_h := 15.0 * k
	var by := size.y - 10.0 * k - row_h * stats.size()
	for line in stats:
		_draw_stat(line, Rect2(12.0 * k, by, size.x - 22.0 * k, row_h - 2.0 * k), k)
		by += row_h

	# Thick colour edge on the left and a fine inner frame.
	draw_rect(Rect2(0, 0, 6.0 * k, size.y), edge)
	draw_rect(full.grow(-3.0 * k), Color(UiStyle.BONE, 0.12), false, maxf(1.0, k))
	if is_rare():
		draw_rect(full, GOLD, false, maxf(2.0, 2.5 * k))


func _draw_stat(line: String, rect: Rect2, k: float) -> void:
	var value := ""
	var label := line
	var space := line.find(" ")
	if space > 0 and (line.begins_with("+") or line.begins_with("-")):
		value = line.substr(0, space)
		label = line.substr(space + 1)
	var good := not value.begins_with("-")
	var tint := GOOD if good else BAD
	draw_rect(rect, Color(tint, 0.12))
	draw_rect(Rect2(rect.position, Vector2(3.0 * k, rect.size.y)), tint)
	var mid := rect.position.y + rect.size.y * 0.5
	var size_v := int(round(13.0 * k))
	var size_l := int(round(12.0 * k))
	var value_w := 44.0 * k
	if not value.is_empty():
		_text(UiStyle.DISPLAY, Vector2(rect.position.x + value_w, mid), value, size_v, tint, HORIZONTAL_ALIGNMENT_RIGHT, -1.0)
	_text(UiStyle.BOLD, Vector2(rect.position.x + value_w + 6.0 * k, mid), label.to_upper(), size_l, UiStyle.BONE_DIM, HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - value_w - 8.0 * k)


## Text vertically centred on `anchor.y`; x is the left edge, or the right
## edge for right alignment.
func _text(font: Font, anchor: Vector2, text: String, font_size: int, color: Color, align: HorizontalAlignment, width: float) -> void:
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var x := anchor.x - w if align == HORIZONTAL_ALIGNMENT_RIGHT else anchor.x
	var baseline := anchor.y + (font.get_ascent(font_size) - font.get_descent(font_size)) * 0.5
	draw_string(font, Vector2(x, baseline), text, HORIZONTAL_ALIGNMENT_LEFT, width, font_size, color)


## Keep a sunburst ray inside the art panel.
static func _clip_poly(poly: PackedVector2Array, rect: Rect2) -> PackedVector2Array:
	var box := PackedVector2Array([rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)])
	var parts := Geometry2D.intersect_polygons(poly, box)
	return parts[0] if not parts.is_empty() else PackedVector2Array()


# ── Card icons ──────────────────────────────────────────────────────────
# Flat shapes in one colour, sized to `r`; `off` shifts the whole icon (for
# the drop shadow).

static func draw_icon(ci: CanvasItem, kind: String, r: Rect2, color: Color, off: Vector2) -> void:
	r.position += off
	var c := r.get_center()
	var s := r.size.x
	var line := maxf(2.0, s * 0.09)
	match kind:
		"skull":
			ci.draw_circle(c + Vector2(0, -s * 0.08), s * 0.34, color)
			ci.draw_rect(Rect2(c + Vector2(-s * 0.2, s * 0.12), Vector2(s * 0.4, s * 0.24)), color)
			var hole := UiStyle.INK
			ci.draw_circle(c + Vector2(-s * 0.13, -s * 0.06), s * 0.1, hole)
			ci.draw_circle(c + Vector2(s * 0.13, -s * 0.06), s * 0.1, hole)
			ci.draw_colored_polygon(PackedVector2Array([c + Vector2(0, s * 0.06), c + Vector2(-s * 0.05, s * 0.15), c + Vector2(s * 0.05, s * 0.15)]), hole)
			for i in 3:
				ci.draw_rect(Rect2(c + Vector2(-s * 0.13 + i * s * 0.1, s * 0.26), Vector2(s * 0.04, s * 0.1)), hole)
		"heart":
			UiStyle.draw_heart(ci, r, color, false)
		"crosshair":
			ci.draw_arc(c, s * 0.34, 0, TAU, 40, color, line, true)
			for d: Vector2 in [Vector2.UP, Vector2.DOWN, Vector2.LEFT, Vector2.RIGHT]:
				ci.draw_line(c + d * s * 0.16, c + d * s * 0.5, color, line)
			ci.draw_circle(c, s * 0.06, color)
		"homing":
			ci.draw_arc(c + Vector2(-s * 0.05, s * 0.1), s * 0.3, PI * 0.9, PI * 1.9, 24, color, line, true)
			var tip := c + Vector2(-s * 0.05, s * 0.1) + Vector2(cos(PI * 1.9), sin(PI * 1.9)) * s * 0.3
			ci.draw_colored_polygon(PackedVector2Array([tip + Vector2(s * 0.14, s * 0.02), tip + Vector2(-s * 0.06, -s * 0.12), tip + Vector2(-s * 0.04, s * 0.12)]), color)
			ci.draw_arc(c + Vector2(s * 0.28, -s * 0.28), s * 0.12, 0, TAU, 20, color, line * 0.7, true)
		"wing":
			for i in 4:
				var y := c.y - s * 0.3 + i * s * 0.15
				var w := s * (0.75 - i * 0.14)
				ci.draw_colored_polygon(PackedVector2Array([
					Vector2(c.x - s * 0.38, y), Vector2(c.x - s * 0.38 + w, y - s * 0.06),
					Vector2(c.x - s * 0.38 + w * 0.9, y + s * 0.07), Vector2(c.x - s * 0.38, y + s * 0.1)]), color)
		"bullets":
			for i in 3:
				UiStyle.draw_bullet(ci, Rect2(r.position + Vector2(s * (0.05 + i * 0.25), s * 0.05 * (1 - i % 2)), Vector2(s * 0.42, s * 0.9)), color)
		"bullet":
			ci.draw_set_transform(c, 0.6, Vector2.ONE)
			UiStyle.draw_bullet(ci, Rect2(-Vector2(s * 0.4, s * 0.5), Vector2(s * 0.8, s)), color)
			ci.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
			for i in 3:
				var y := c.y + s * (0.05 + i * 0.12)
				ci.draw_line(Vector2(r.position.x + s * 0.02, y), Vector2(r.position.x + s * (0.3 - i * 0.06), y), color, line * 0.6)
		"mag":
			ci.draw_colored_polygon(PackedVector2Array([
				c + Vector2(-s * 0.22, -s * 0.4), c + Vector2(s * 0.12, -s * 0.4),
				c + Vector2(s * 0.3, s * 0.42), c + Vector2(-s * 0.04, s * 0.42)]), color)
			for i in 4:
				ci.draw_rect(Rect2(c + Vector2(-s * 0.12 + i * s * 0.04, -s * 0.28 + i * s * 0.17), Vector2(s * 0.22, s * 0.05)), UiStyle.INK)
		"reload":
			ci.draw_arc(c, s * 0.32, PI * 0.15, PI * 0.95, 24, color, line * 1.2, true)
			ci.draw_arc(c, s * 0.32, PI * 1.15, PI * 1.95, 24, color, line * 1.2, true)
			for a: float in [PI * 0.95, PI * 1.95]:
				var p := c + Vector2(cos(a), sin(a)) * s * 0.32
				var t := Vector2(-sin(a), cos(a))
				var n := Vector2(cos(a), sin(a))
				ci.draw_colored_polygon(PackedVector2Array([p + t * s * 0.16, p + n * s * 0.13, p - n * s * 0.13]), color)
		"bounce":
			var pts := PackedVector2Array([c + Vector2(-s * 0.45, -s * 0.3), c + Vector2(-s * 0.1, s * 0.3), c + Vector2(s * 0.2, -s * 0.15), c + Vector2(s * 0.42, s * 0.2)])
			ci.draw_polyline(pts, color, line, true)
			ci.draw_rect(Rect2(c + Vector2(-s * 0.5, s * 0.34), Vector2(s, s * 0.08)), color)
			ci.draw_circle(pts[3], s * 0.08, color)
		"silencer":
			ci.draw_rect(Rect2(c + Vector2(-s * 0.48, -s * 0.12), Vector2(s * 0.3, s * 0.16)), color)
			ci.draw_rect(Rect2(c + Vector2(-s * 0.2, -s * 0.2), Vector2(s * 0.66, s * 0.32)), color)
			for i in 4:
				ci.draw_rect(Rect2(c + Vector2(-s * 0.1 + i * s * 0.14, -s * 0.2), Vector2(s * 0.03, s * 0.32)), UiStyle.INK)
			ci.draw_rect(Rect2(c + Vector2(-s * 0.46, s * 0.04), Vector2(s * 0.12, s * 0.26)), color)
		"bomb":
			ci.draw_circle(c + Vector2(-s * 0.05, s * 0.08), s * 0.3, color)
			ci.draw_rect(Rect2(c + Vector2(s * 0.05, -s * 0.3), Vector2(s * 0.16, s * 0.14)), color)
			ci.draw_line(c + Vector2(s * 0.14, -s * 0.3), c + Vector2(s * 0.3, -s * 0.42), color, line * 0.7)
			for i in 6:
				var a := TAU * i / 6.0
				ci.draw_line(c + Vector2(s * 0.36, -s * 0.44) + Vector2(cos(a), sin(a)) * s * 0.05, c + Vector2(s * 0.36, -s * 0.44) + Vector2(cos(a), sin(a)) * s * 0.13, color, line * 0.5)
		"drop":
			var pts := PackedVector2Array([c + Vector2(0, -s * 0.46)])
			for i in 15:
				var a := lerpf(-PI * 0.15, PI * 1.15, i / 14.0)
				pts.append(c + Vector2(0, s * 0.12) + Vector2(cos(a), sin(a)) * s * 0.3)
			ci.draw_colored_polygon(pts, color)
		"snow":
			for i in 3:
				var a := PI * i / 3.0
				var d := Vector2(cos(a), sin(a)) * s * 0.46
				ci.draw_line(c - d, c + d, color, line)
				for e: Vector2 in [d * 0.6, -d * 0.6]:
					var n := e.orthogonal().normalized() * s * 0.1
					ci.draw_line(c + e, c + e * 1.35 + n, color, line * 0.7)
					ci.draw_line(c + e, c + e * 1.35 - n, color, line * 0.7)
		"body":
			ci.draw_circle(c + Vector2(0, -s * 0.28), s * 0.15, color)
			ci.draw_colored_polygon(PackedVector2Array([
				c + Vector2(-s * 0.3, -s * 0.08), c + Vector2(s * 0.3, -s * 0.08),
				c + Vector2(s * 0.22, s * 0.46), c + Vector2(-s * 0.22, s * 0.46)]), color)
		"flame":
			for layer in 2:
				var k := 1.0 - layer * 0.45
				var base := c + Vector2(0, s * 0.16)
				var pts := PackedVector2Array()
				for i in 13:
					var a := lerpf(0.0, PI, i / 12.0)
					pts.append(base + Vector2(cos(a), sin(a)) * s * 0.28 * k)
				# Up the left side to a tip leaning right, and back down.
				pts.append(base + Vector2(-s * 0.3, -s * 0.2) * k)
				pts.append(base + Vector2(-s * 0.12, -s * 0.42) * k)
				pts.append(base + Vector2(s * 0.08, -s * 0.62) * k)
				pts.append(base + Vector2(s * 0.06, -s * 0.38) * k)
				pts.append(base + Vector2(s * 0.24, -s * 0.3) * k)
				ci.draw_colored_polygon(pts, color if layer == 0 else Color(UiStyle.INK, 0.55))
		"swirl":
			var pts := PackedVector2Array()
			for i in 50:
				var t := i / 49.0
				var a := t * TAU * 2.2
				pts.append(c + Vector2(cos(a), sin(a)) * s * (0.04 + 0.42 * t))
			ci.draw_polyline(pts, color, line, true)
		"sword":
			ci.draw_colored_polygon(PackedVector2Array([
				c + Vector2(s * 0.42, -s * 0.42), c + Vector2(s * 0.3, -s * 0.12),
				c + Vector2(-s * 0.12, s * 0.2), c + Vector2(-s * 0.2, s * 0.12)]), color)
			ci.draw_line(c + Vector2(-s * 0.3, s * 0.06), c + Vector2(-s * 0.06, s * 0.3), color, line * 1.3)
			ci.draw_line(c + Vector2(-s * 0.16, s * 0.2), c + Vector2(-s * 0.38, s * 0.42), color, line * 1.5)
		"beam":
			ci.draw_rect(Rect2(c + Vector2(-s * 0.1, -s * 0.5), Vector2(s * 0.2, s * 0.8)), color)
			ci.draw_arc(c + Vector2(0, s * 0.34), s * 0.22, PI, TAU, 20, color, line, true)
			ci.draw_arc(c + Vector2(0, s * 0.34), s * 0.36, PI * 1.1, PI * 1.9, 20, Color(color, 0.6), line * 0.7, true)
		"fist":
			ci.draw_rect(Rect2(c + Vector2(-s * 0.3, -s * 0.2), Vector2(s * 0.56, s * 0.44)), color)
			for i in 4:
				ci.draw_circle(c + Vector2(-s * 0.22 + i * s * 0.14, -s * 0.2), s * 0.08, color)
			ci.draw_rect(Rect2(c + Vector2(-s * 0.2, s * 0.24), Vector2(s * 0.36, s * 0.2)), color)
			ci.draw_line(c + Vector2(-s * 0.24, s * 0.02), c + Vector2(s * 0.1, s * 0.02), UiStyle.INK, line * 0.5)
		_:
			var pts := PackedVector2Array()
			for i in 10:
				var a := -PI * 0.5 + TAU * i / 10.0
				pts.append(c + Vector2(cos(a), sin(a)) * s * (0.46 if i % 2 == 0 else 0.2))
			ci.draw_colored_polygon(pts, color)
