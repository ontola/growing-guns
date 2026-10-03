extends SceneTree
var failed := false
func _initialize(): call_deferred("run")
func run():
	var music = root.get_node("ProceduralMusic")
	var bridge = root.get_node("GameNightBridge")
	if ProjectSettings.get_setting("display/window/size/mode") != DisplayServer.WINDOW_MODE_MINIMIZED:
		push_error("GameNight must start minimized before scripts load")
		failed = true
	if not ProjectSettings.get_setting("display/window/size/no_focus"):
		push_error("Startup must not acquire focus")
		failed = true
	var screen = load("res://addons/gamenight/screen.gd").new()
	screen._on_focus_in()
	if screen._epoch != 0:
		push_error("OS focus must not start or resume a game")
		failed = true
	screen.free()
	var preference: bool = music.enabled
	var volume: float = music.music_db
	bridge._sync_host_music({"now_playing":{"playing":true}})
	for bus in music.MUSIC_BUS_NAMES:
		if not AudioServer.is_bus_mute(AudioServer.get_bus_index(bus)): failed = true
	if AudioServer.is_bus_mute(AudioServer.get_bus_index("Master")): failed = true
	bridge._sync_host_music({"now_playing":{"playing":false}})
	for bus in music.MUSIC_BUS_NAMES:
		if AudioServer.is_bus_mute(AudioServer.get_bus_index(bus)): failed = true
	bridge._sync_host_music({"now_playing":{"playing":true}})
	bridge._sync_host_music({})
	for bus in music.MUSIC_BUS_NAMES:
		if AudioServer.is_bus_mute(AudioServer.get_bus_index(bus)): failed = true
	if music.enabled != preference or music.music_db != volume: failed = true
	print("WINDOW_CONTRACT_PASS" if not failed else "WINDOW_CONTRACT_FAIL")
	quit(1 if failed else 0)
