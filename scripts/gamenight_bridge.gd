extends Node
## Bridges the GameNight autoload (addons/gamenight/gamenight.gd) to this
## game's scene lifecycle. Owns the prepare -> ready -> start -> finished ->
## dispose state machine across both start_screen.tscn and game.tscn, since
## GameNight's signals fire on a Node that survives scene swaps while
## start_screen.gd / game.gd get freed and reloaded each transition.
##
## Zero effect on standalone play: everything below is gated behind
## GameNight.launched_by_daemon, which is only true when the daemon spawned
## this process with GAMENIGHT=1.

var settings := preload("res://scripts/gamenight_settings.gd").new()

const GAME_SCENE := "res://scenes/game.tscn"
const START_SCENE := "res://scenes/start_screen.tscn"

## Player ids at or above this one were invented by the game rather than
## seated by the party: bots (game.gd's BOT_ID_BASE) and splitscreen joiners
## (splitscreen_manager.gd's SPLIT_PLAYER_ID_BASE, well above it).
##
## They need forgetting between sessions. The roster lives on NetworkManager,
## an autoload, so it outlives the scene swap — and the next session's spawn
## loop rebuilds everyone on it as a plain single-view player, having no idea
## one was a bot and another a splitscreen guest. That left the party's second
## match of the night with a motionless "player" in it and a seat short.
const CARRIED_OVER_ID_BASE := 9000

## Session id of the session currently being played/prepared. game.gd reads
## this (GameNightBridge.current_session_id) so notify_finished can fire
## without threading a session id argument through every call site.
var current_session_id: String = ""

var _pending_seats: Array = []
var _pending_players: Array = []
## How many of this session's seats hold a local human. The party decided
## this in the lobby; the game never adds to it or subtracts from it.
var _local_seat_count: int = 0


func _ready() -> void:
	# Fallback game id for standalone runs / before the daemon's env override
	# is read. GameNight._ready() already applied GAMENIGHT_GAME_ID if the
	# daemon set one — don't clobber that.
	if OS.get_environment("GAMENIGHT_GAME_ID") == "":
		GameNight.game_id = "growing-guns"

	if not GameNight.launched_by_daemon:
		# Playing normally: go fullscreen, which is what `window/size/mode=3`
		# used to do for us. It doesn't any more — booting fullscreen under a
		# daemon means a warm game taking the party's screen — so it's a
		# runtime decision, made here. Same code either way; GameNightScreen
		# only declines to wire itself up automatically without a daemon.
		GameNightScreen.take_the_screen("standalone")
		return

	# Warm means frozen, and freezing means pausing the tree — so this bridge
	# says up front that it must keep running while the rest of the game is
	# stopped. (GameNight and GameNightScreen do the same for themselves.)
	# Without that the game pauses itself and never hears the `start` that
	# would unpause it.
	process_mode = Node.PROCESS_MODE_ALWAYS

	# Taking the screen is what `start` means, and nothing before it: the
	# daemon launches us long before anybody asks to play, so the party is
	# looking at the lobby when our window turns up.
	#
	# Which is why `window/size/mode` in project.godot is now 0 (windowed)
	# rather than 3 (fullscreen), with standalone play going fullscreen from
	# `_ready` above instead.
	#
	# That setting applied before a single line of this script ran: the process
	# opened *fullscreen*, covering the lobby and dragging the desktop onto its
	# own macOS Space, and the first thing we then did was minimise it again.
	# On macOS a fullscreen window minimises by way of windowed, so the party
	# watched a game they hadn't asked for open fullscreen, shrink and vanish.
	# Nothing this script can do at `_ready()` is early enough to prevent that
	# — and neither is the command line: Godot 4.7 ignores `--windowed`,
	# `--position` and `--resolution` when the project setting says fullscreen
	# (measured, all three). The setting itself was the only lever.
	settings.connect_host(GameNight)
	GameNight.prepared.connect(_on_prepared)
	GameNight.started.connect(_on_started)
	GameNight.paused.connect(_on_paused)
	GameNight.resumed.connect(_on_resumed)
	GameNight.disposed.connect(_on_disposed)


## ── Session lifecycle ──────────────────────────────────────────────────────

func _on_prepared(session_id: String, seats: Array, players: Array) -> void:
	print("[gamenight] prepare %s (%d seats)" % [session_id, seats.size()])
	current_session_id = session_id
	_pending_seats = seats
	_pending_players = players
	GameNight.notify_progress(session_id, 5, "setting up the match")
	_forget_last_sessions_players()
	_configure_meta_from_seats(seats)
	GameNight.notify_progress(session_id, 20, "loading the arena")
	get_tree().change_scene_to_file(GAME_SCENE)
	_notify_ready_once_loaded.call_deferred(session_id)


## Forget everyone the *game* seated last session: its bots and its
## splitscreen joiners. The party's own seats are re-read from `prepare`
## either way, so nothing real is lost.
func _forget_last_sessions_players() -> void:
	for pid in NetworkManager.players.keys():
		if int(pid) >= CARRIED_OVER_ID_BASE:
			NetworkManager.players.erase(pid)


func _configure_meta_from_seats(seats: Array) -> void:
	NetworkManager.set_meta("game_mode", "versus")
	if NetworkManager.has_meta("coop_mode"):
		NetworkManager.remove_meta("coop_mode")

	_local_seat_count = 0
	var bots := 0
	for seat in seats:
		if typeof(seat) != TYPE_DICTIONARY:
			continue
		var occupant: Dictionary = seat.get("occupant", {})
		match str(occupant.get("kind", "empty")):
			"local":
				_local_seat_count += 1
			"ai":
				bots += 1

	# Versus needs two (see _maybe_start_match), and the party is allowed to
	# be one person warming up. The daemon fills the gap with `ai` seats when
	# it knows our minimum; assume one when it doesn't, rather than sitting at
	# a "waiting for player 2" screen the party can do nothing about.
	if _local_seat_count + bots < 2:
		bots = 2 - _local_seat_count
	NetworkManager.set_meta("spawn_bot_on_start", bots > 0)
	NetworkManager.set_meta("bot_count_on_start", bots)

	# Two humans on this couch means splitscreen. Which pad drives which seat
	# is decided at `start`, not here: while warm we are minimised and in the
	# background, where a freshly connected pad may not be enumerated yet —
	# see _bind_gamenight_seats.
	NetworkManager.set_meta("splitscreen_on_start", _local_seat_count >= 2)
	NetworkManager.set_meta("splitscreen_primary_device", -1)
	NetworkManager.set_meta("host_started", true)


## Wait for game.gd's _ready() to finish (a couple of frames after the scene
## swap lands) before telling the daemon we're ready. The _gamenight_start_gate
## in game.gd is what actually blocks gameplay from starting early, so this
## timing only needs to be "after _ready has run", not exact.
func _notify_ready_once_loaded(session_id: String) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if session_id != current_session_id:
		return  # a newer prepare (or dispose) superseded this one
	GameNight.notify_progress(session_id, 70, "generating terrain")
	# The arena generator is the slow part and it runs across several frames
	# after the scene lands, so keep the lobby's screen moving until it's
	# actually done rather than jumping 70 -> ready with a silent gap.
	await _report_arena_progress(session_id)
	print("[gamenight] ready %s" % session_id)
	GameNight.notify_progress(session_id, 100, "ready")
	GameNight.notify_ready(session_id)
	# Loaded, and now frozen until somebody asks for us. `_gamenight_start_gate`
	# only holds back the match *state machine*: the arena is still simulating,
	# the bots are still fighting, the players still answer the sticks. So a
	# warm process that becomes visible for even a moment isn't a game about to
	# start — it's a game already in progress that the party can walk into.
	# (It also spends a whole core on a match nobody is watching.) Warm should
	# mean loaded, not playing.
	# Pausing stops the simulation but not the renderer, which happily keeps
	# drawing the frozen frame as fast as the GPU allows — GameNightScreen
	# caps the frame rate for exactly this window of time, off the back of the
	# `ready` we just sent.
	get_tree().paused = true


## Follow the arena generator, which is the slow part of warming and runs
## across several frames after the scene lands. Completion is real (the
## generator's own `regenerated` signal); the number in between is a
## time-based ramp, because the generator reports no intermediate progress.
##
## Gives up after a couple of seconds: progress is a courtesy to the people
## waiting, never a gate on play.
func _report_arena_progress(session_id: String) -> void:
	var game := get_tree().current_scene
	var arena: Node = game.get_node_or_null("Arena") if game != null else null
	if arena == null or not arena.has_signal("regenerated"):
		return
	var done := [false]
	arena.regenerated.connect(func(_stats: Dictionary) -> void: done[0] = true, CONNECT_ONE_SHOT)
	var waited := 0.0
	while not done[0] and waited < 2.0:
		if session_id != current_session_id:
			return
		GameNight.notify_progress(
			session_id, 70 + int(minf(waited / 2.0, 1.0) * 25.0), "generating terrain"
		)
		await get_tree().process_frame
		waited += get_process_delta_time()


## Seat the party GameNight handed us. Nobody presses anything to get in: the
## lobby already knows who is playing, and a second way in (the game's own
## "press X to join") only lets the two disagree.
##
## Done at `start` rather than at `prepare` because this is where the pads
## actually are. Warming happens minimised and unfocused, and a pad that
## connects — or is picked up — while the party is still in the lobby isn't
## necessarily enumerated for us yet. Binding early got seat 1 the
## keyboard/mouse "device" as a fallback, which on the host means the same
## mouse turning both players' heads.
func _bind_gamenight_seats() -> void:
	if _local_seat_count <= 0:
		return
	var game := get_tree().current_scene
	if game == null:
		return
	var splitscreen: Node = game.get("_splitscreen")
	if splitscreen == null or not splitscreen.has_method("bind_seats"):
		return
	var devices := GameNight.devices_for_local_seats(_local_seat_count)
	if _local_seat_count >= 2:
		splitscreen.bind_seats(devices)
	elif not devices.is_empty():
		_bind_solo_seat(game, int(devices[0]))
	# A seat we can't drive would otherwise sit empty and hold the whole match
	# at "waiting for players", with nothing the party can do about it from
	# the lobby. Give it to a bot instead: a short-handed match still plays.
	var unseated := _local_seat_count - devices.size()
	if unseated > 0 and game.has_method("_spawn_bots"):
		push_warning("[gamenight] %d seat(s) without an input device — bots stand in" % unseated)
		game._spawn_bots(unseated)


## One seated human, so no splitscreen — but still a controller player. The
## party is on the couch and the game is on the TV; nobody is at the keyboard.
##
## Worth doing explicitly because a player left on the default device (-1)
## can *aim* with a pad but not walk with one: movement on -1 reads the WASD
## keys directly, not the input map the pad is bound through.
func _bind_solo_seat(game: Node, device: int) -> void:
	var player: Node = game.players_root.get_node_or_null(str(multiplayer.get_unique_id()))
	if player == null:
		return
	player.set("local_input_device", device)
	if not game.has_method("_ensure_render_player"):
		return
	# The view was built during warm, before we knew the device; a stale one
	# reads the wrong stick during a card pick.
	var renderer := game._ensure_render_player(int(player.get("player_id")), device) as RenderPlayer
	if renderer:
		renderer.input_device = device


func _on_started(session_id: String) -> void:
	if session_id != current_session_id:
		return
	# This is the transition: the screen, the speakers and the simulation all
	# become ours in the same frame the match is allowed to run. Unpause first
	# — the gate below starts the match, and starting a match inside a paused
	# tree gets the party a still image of one.
	get_tree().paused = false
	# Seats first, gate second: _maybe_start_match counts the players it can
	# see, so seating everybody after opening the gate means the match starts
	# a player short.
	_bind_gamenight_seats()
	var game := get_tree().current_scene
	if game and game.has_method("_open_gamenight_start_gate"):
		game._open_gamenight_start_gate()


func _on_paused(session_id: String) -> void:
	_freeze_all_players(session_id, true)
	if session_id != current_session_id:
		return
	# Getting out of the way is part of pausing — the party asked for the
	# lobby, and macOS won't let a background app take focus from the
	# frontmost one, which while we're paused is us. GameNightScreen does it
	# off the same `pause` signal.


func _on_resumed(session_id: String) -> void:
	if session_id != current_session_id:
		return
	# GameNightScreen takes the screen back off the same `resume` signal:
	# calling up the party doesn't draw an overlay on top of us, it hands the
	# couch's attention to another app, so coming back is a real window
	# activation rather than just unfreezing.
	_freeze_all_players(session_id, false)


func _freeze_all_players(session_id: String, frozen: bool) -> void:
	if session_id != current_session_id:
		return
	var game := get_tree().current_scene
	if game == null:
		return
	var players_root: Node = game.get("players_root")
	if players_root == null:
		return
	for child in players_root.get_children():
		if child.has_method("set_frozen"):
			child.set_frozen.rpc(frozen)


func _on_disposed(session_id: String) -> void:
	if session_id != current_session_id:
		return
	current_session_id = ""
	_local_seat_count = 0
	# Unpause before swapping scenes: the next `prepare` pauses again once it
	# has finished loading, and a scene change into a paused tree would never
	# get the frames it needs to load at all.
	get_tree().paused = false
	if get_tree().current_scene and get_tree().current_scene.scene_file_path == GAME_SCENE:
		get_tree().change_scene_to_file(START_SCENE)
	# The process stays resident and may be prepared again later in the night;
	# GameNightScreen puts us back off-screen off the same `dispose`.
