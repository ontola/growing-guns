extends RefCounted
## Party-owned preferences. Changing a value never restarts an active match.
const SPECS := [
	{"key":"rounds_to_win", "label":"Rounds to win (next match)", "kind":"number", "default":10, "min":1, "max":30},
	{"key":"modifier_chance", "label":"Modifiers % (next round)", "kind":"number", "default":30, "min":0, "max":100},
	{"key":"card_pick_seconds", "label":"Card time, s (next pick)", "kind":"number", "default":10, "min":3, "max":30},
	{"key": "gravity", "label": "Gravity % (next round)", "kind": "number", "default": 100, "min": 25, "max": 175},
	{"key": "bullet_drop", "label": "Bullet drop % (next round)", "kind": "number", "default": 100, "min": 0, "max": 200},
	{"key": "body_damage", "label": "Body shot damage % (next round)", "kind": "number", "default": 100, "min": 50, "max": 200},
	{"key": "pickup_rate", "label": "Random pickup rate % (next round)", "kind": "number", "default": 100, "min": 0, "max": 200},
]
var _values: Dictionary = {}

func _init() -> void:
	for spec in SPECS: _values[spec.key] = spec.default

func connect_host(host: Node) -> void:
	host.setting_changed.connect(change)
	host.declare_settings(SPECS.duplicate(true))

func change(key: String, value: Variant) -> bool:
	for spec: Dictionary in SPECS:
		if spec.key != key:
			continue
		if typeof(value) not in [TYPE_INT, TYPE_FLOAT]:
			return false
		if not is_finite(float(value)) or value != floor(float(value)) or value < spec.min or value > spec.max:
			return false
		_values[key] = int(value)
		write_probe()
		return true
	return false

func apply_match(game: Node) -> void:
	# Called only by the authoritative game when starting a new match.
	game._set_rounds_to_win.rpc(int(_values.rounds_to_win))

func modifier_chance() -> float:
	return float(_values.modifier_chance) / 100.0

func card_pick_seconds() -> float:
	return float(_values.card_pick_seconds)


func round_rules() -> Dictionary:
	return {"gravity": _values.gravity / 100.0, "bullet_drop": _values.bullet_drop / 100.0,
		"body_damage": _values.body_damage / 100.0, "pickup_rate": _values.pickup_rate / 100.0}

func apply_round(game: Node) -> void:
	game._set_gamenight_rules.rpc(round_rules())


func write_probe() -> void:
	var path := OS.get_environment("GAMENIGHT_SETTINGS_PROBE")
	if path.is_empty(): return
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file: file.store_string(JSON.stringify({"settings": _values}))
