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
	var rect := Rect2(Vector2.ZERO, size)
	match icon_type:
		Type.LMB:
			UiStyle.draw_bullet(self, rect, icon_color)
		Type.RMB:
			UiStyle.draw_grenade(self, rect, icon_color)
		Type.SHIFT:
			UiStyle.draw_dash(self, rect, icon_color)
	UiStyle.draw_prompt(self, rect, prompt_label(icon_type, use_controller_icons))


## The button a panel's action sits on, for the badge in the icon's corner.
static func prompt_label(type: Type, controller: bool) -> String:
	match type:
		Type.LMB:
			return "RT" if controller else "LMB"
		Type.RMB:
			return "LT" if controller else "RMB"
	return "RB" if controller else "SHIFT"
