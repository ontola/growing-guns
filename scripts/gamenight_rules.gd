extends RefCounted
## Applied round snapshot. Independent of saved/pending host preferences.
var values := {"gravity":1.0, "bullet_drop":1.0, "body_damage":1.0, "pickup_rate":1.0}
const LIMITS := {"gravity": Vector2(.25,1.75), "bullet_drop": Vector2(0,2),
	"body_damage": Vector2(.5,2), "pickup_rate": Vector2(0,2)}

func apply(incoming: Dictionary) -> bool:
	if incoming.size() != LIMITS.size(): return false
	for key in LIMITS:
		var value: Variant = incoming.get(key)
		if typeof(value) not in [TYPE_FLOAT, TYPE_INT] or not is_finite(float(value)): return false
		if value < LIMITS[key].x or value > LIMITS[key].y: return false
	values = incoming.duplicate()
	return true

func scale(key: String, modifier: float) -> float:
	return modifier * float(values[key])
