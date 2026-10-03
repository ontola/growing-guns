extends SceneTree
const Settings = preload("res://scripts/gamenight_settings.gd")
const Rules = preload("res://scripts/gamenight_rules.gd")
const Modifiers = preload("res://scripts/round_modifiers.gd")
class Host extends Node:
	signal setting_changed(key: String, value: Variant)
	var specs: Array = []
	func declare_settings(value: Array) -> void: specs = value
class Game extends Node:
	var rounds_to_win := 10
	var rules := {}
	@rpc("authority", "call_local", "reliable")
	func _set_gamenight_rules(value: Dictionary) -> void: rules = value
	@rpc("authority", "call_local", "reliable")
	func _set_rounds_to_win(value: int) -> void: rounds_to_win = value

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var settings = Settings.new()
	var host = Host.new()
	root.add_child(host)
	settings.connect_host(host)
	assert(host.specs.size() == 7)
	for spec in host.specs:
		assert(settings.change(spec.key, spec.min))
		assert(settings.change(spec.key, spec.max))
		for invalid in [true, "10", 1.5, null, spec.min - 1, spec.max + 1]:
			assert(not settings.change(spec.key, invalid))
		assert(settings.change(spec.key, spec.default))
	assert(not settings.change("unknown", 10))
	var game = Game.new()
	root.add_child(game)
	host.setting_changed.emit("rounds_to_win", 4)
	assert(game.rounds_to_win == 10)
	settings.apply_match(game)
	assert(game.rounds_to_win == 4)
	host.setting_changed.emit("rounds_to_win", 8)
	assert(game.rounds_to_win == 4, "active match goal must remain unchanged")
	settings.apply_match(game)
	assert(game.rounds_to_win == 8)
	host.setting_changed.emit("card_pick_seconds", 6)
	var active_deadline = settings.card_pick_seconds()
	host.setting_changed.emit("card_pick_seconds", 20)
	assert(active_deadline == 6 and settings.card_pick_seconds() == 20)
	for percent in [0, 100]:
		host.setting_changed.emit("modifier_chance", percent)
		for i in 100:
			var modifier = Modifiers.pick_for_round(settings.modifier_chance())
			assert(modifier == "" if percent == 0 else modifier in Modifiers.IDS)
	settings.apply_round(game)
	assert(game.rules.gravity == 1.0 and game.rules.body_damage == 1.0)
	host.setting_changed.emit("gravity", 50)
	host.setting_changed.emit("body_damage", 150)
	assert(game.rules.gravity == 1.0, "Current round keeps its snapshot")
	settings.apply_round(game)
	assert(game.rules.gravity == .5 and game.rules.body_damage == 1.5)
	var snapshot = settings.round_rules()
	snapshot.gravity = 99
	assert(settings.round_rules().gravity == .5, "Callers cannot mutate preferences")
	var rules = Rules.new()
	assert(rules.apply(settings.round_rules()))
	assert(rules.scale("gravity", 2.0) == 1.0, "Combines with a double-gravity modifier")
	assert(rules.scale("body_damage", .5) == .75, "Preserves card/round modifier scaling")
	assert(not rules.apply({"gravity": 0}), "Partial snapshots refused")
	var invalid = settings.round_rules()
	invalid.gravity = 99
	assert(not rules.apply(invalid))
	assert(rules.scale("gravity", 2.0) == 1.0)
	settings.change("pickup_rate", 0)
	assert(rules.apply(settings.round_rules()))
	assert(rules.scale("pickup_rate", 2.0) == 0.0, "Can disable random pickup spawns")
	seed(1234)
	var modified = 0
	for i in 1000:
		if Modifiers.pick_for_round() != "": modified += 1
	assert(modified > 200 and modified < 400, "standalone default remains 30%")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--settings-output="):
			var file = FileAccess.open(arg.trim_prefix("--settings-output="), FileAccess.WRITE)
			file.store_string(JSON.stringify({"growing-guns": host.specs}))
	print("GROWING_GUNS_SETTINGS_PASS")
	quit()
