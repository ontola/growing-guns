extends RefCounted
## Party-owned preferences. Changing a value never restarts an active match.
const SPECS := [
	{"key":"rounds_to_win", "label":"Rounds to win (next match)", "kind":"number", "default":10, "min":1, "max":30},
	{"key":"modifier_chance", "label":"Modifiers % (next round)", "kind":"number", "default":30, "min":0, "max":100},
	{"key":"card_pick_seconds", "label":"Card time, s (next pick)", "kind":"number", "default":10, "min":3, "max":30},
]
var _values: Dictionary = {"rounds_to_win":10, "modifier_chance":30, "card_pick_seconds":10}

func connect_host(host: Node) -> void:
	host.setting_changed.connect(change)
	host.declare_settings(SPECS.duplicate(true))

func change(key: String, value: Variant) -> bool:
	for spec: Dictionary in SPECS:
		if spec.key != key:
			continue
		if typeof(value) != TYPE_INT or value < spec.min or value > spec.max:
			return false
		_values[key] = value
		return true
	return false

func apply_match(game: Node) -> void:
	# Called only by the authoritative game when starting a new match.
	game._set_rounds_to_win.rpc(int(_values.rounds_to_win))

func modifier_chance() -> float:
	return float(_values.modifier_chance) / 100.0

func card_pick_seconds() -> float:
	return float(_values.card_pick_seconds)
