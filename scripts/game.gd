extends Node3D

const MenuHelpers = preload("res://scripts/menu_helpers.gd")
const RetroFilter = preload("res://scripts/retro_filter.gd")
const PLAYER_SCENE := preload("res://scenes/player.tscn")
const HUD_ICON_SCRIPT := preload("res://scripts/hud_icon.gd")
const DEV_PANEL_SCRIPT := preload("res://scripts/dev_panel.gd")
const RENDER_PLAYER_SCRIPT := preload("res://scripts/render_player.gd")
const SPLITSCREEN_MANAGER_SCRIPT := preload("res://scripts/splitscreen_manager.gd")
const PICKUP_ITEM_SCRIPT := preload("res://scripts/pickup_item.gd")
const ROUND_MODIFIERS_SCRIPT := preload("res://scripts/round_modifiers.gd")
const AIR_STRIKE_SCRIPT := preload("res://scripts/air_strike.gd")
const ION_CANNON_SCRIPT := preload("res://scripts/ion_cannon.gd")
const PLAYER_SCRIPT := preload("res://scripts/player.gd")
const GRENADE_SCRIPT := preload("res://scripts/grenade.gd")

const PICKUP_SPAWN_MEAN := 20.0
const PICKUP_SPAWN_JITTER := 7.0
const PICKUP_MAX_ACTIVE := 4
const AIR_STRIKE_INTERVAL := 4.0
const AIR_STRIKE_INTERVAL_JITTER := 1.5
const AIR_STRIKE_RADIUS := 30.0
const AIR_STRIKE_DAMAGE := 165.0
const AIR_STRIKE_SPAWN_HEIGHT := 263.0
const AIR_STRIKE_SPAWN_HORIZ := 93.0
const ION_CANNON_INTERVAL := 5.5
const ION_CANNON_INTERVAL_JITTER := 1.5
const PICKUP_SPAWN_HEIGHT := 52.0

# Maps that can be picked at the start of each round. Server picks an index
# and broadcasts via _swap_arena.rpc(idx) so all peers agree. Add new maps
# here — they need at least one node in the "spawnpoints" group.
const MAP_POOL: Array[PackedScene] = [
	preload("res://scenes/arena_procedural.tscn"),
]
# Position offset applied to whichever arena is loaded — matches the static
# transform game.tscn used to apply to its embedded Arena instance, so spawn
# points and player coords stay consistent across both maps.
const ARENA_OFFSET := Vector3(1.7405052, 4.5380306, 16.383654)

enum State { WAITING, PLAYING, PICKING_CARD, MATCH_OVER }

const CARDS_PER_PICK := 3
# Round-start gladiator cages: fighters spawn caged at CAGE_SPAWN_HEIGHT, a
# crane lowers them to CAGE_DROP_HEIGHT over CAGE_DESCEND_SECONDS (the
# card-growth morph plays on the way down), and the trapdoors open the
# moment the descent settles — no hold.
const CAGE_SPAWN_HEIGHT := 45.0
# High enough that the trapdoor drop reads a little brutal — a real plunge
# past the castle towers, not a hop off a ledge.
const CAGE_DROP_HEIGHT := 22.0
const CAGE_DESCEND_SECONDS := 2.6
const GAME_MODE_VERSUS := "versus"
const GAME_MODE_COOP := "coop"
const COOP_BASE_ENEMIES := 3
const COOP_ENEMIES_PER_WAVE := 1
const COOP_MAX_ENEMIES := BOT_ID_LIMIT - BOT_ID_BASE
const COOP_PLAYER_HEALTH_MULT := 3.0
const COOP_ENEMY_HEALTH_MULT := 0.5
const COOP_ENEMY_SPAWN_INTERVAL := 1.35
const COOP_ENEMY_FIRST_SPAWN_DELAY := 0.65
const COOP_ENEMY_TELEGRAPH_SECONDS := 0.5
const COOP_ENEMY_TELEGRAPH_WARMUP := 0.9
const COOP_ENEMY_SPAWN_MIN_FROM_PLAYER := 8.0
const COOP_ENEMY_SPAWN_MIN_FROM_TARGET := 10.0
const COOP_ENEMY_SPAWN_MAX_FROM_TARGET := 24.0
const COOP_ENEMY_SPAWN_MAX_GROUND_HEIGHT := 5.0  # above arena origin — no rooftop/tower emerges
const COOP_ENEMY_SPAWN_MEMORY := 6               # recent sites the sampler spreads away from
const COOP_REVIVE_RADIUS := 1.4
const COOP_REVIVE_SECONDS := 3.0
const SPAWN_CAPSULE_RADIUS := 0.4
const SPAWN_CAPSULE_HEIGHT := 1.8
const SPAWN_CLEARANCE_RADIUS := 0.58
const SPAWN_CLEARANCE_HEIGHT := 2.0
const BOT_ID_BASE := 9000
const BOT_ID_LIMIT := 9100  # IDs 9000..9099 are reserved for bots
const BOT_NAME := "BOT"
const BOT_NAME_PREFIXES: PackedStringArray = [
	"Blitz", "Crank", "Dash", "Fang", "Fuse", "Glitch", "Hex", "Jolt",
	"Knock", "Pixel", "Quake", "Rift", "Scrap", "Spark", "Vex", "Zip",
]
const BOT_NAME_SUFFIXES: PackedStringArray = [
	"Byte", "Core", "Drift", "Flux", "Kick", "Loop", "Nail", "Patch",
	"Pulse", "Rush", "Scope", "Shift", "Slug", "Snap", "Volt", "Wire",
]
const SPLIT_PLAYER_ID_BASE := 10000
const IROH_GAME_ID_MIN_LENGTH := 20
const IROH_GAME_ID_MAX_LENGTH := 256
const JOIN_TIMEOUT_SECONDS := 12.0
const PING_PROBE_INTERVAL := 2.0
const PING_STALE_AFTER_MS := 7000
const HIGH_PING_WARN_MS := 180
const HIGH_PING_WARN_INTERVAL := 8.0
const KILL_FEED_LIFETIME := 3.0
const KILL_FEED_MAX_ITEMS := 6
const LAVA_LEAK_START_SECONDS := 30.0
const LAVA_LEAK_SPREAD_SECONDS := 20.0

func _is_bot_id(pid: int) -> bool:
	return pid >= BOT_ID_BASE and pid < BOT_ID_LIMIT

func _bot_ids() -> Array[int]:
	var out: Array[int] = []
	for raw_id in NetworkManager.players:
		var pid := int(raw_id)
		if _is_bot_id(pid):
			out.append(pid)
	return out

func _human_count() -> int:
	var n: int = 0
	for raw_id in NetworkManager.players:
		if not _is_bot_id(int(raw_id)):
			n += 1
	return n

func is_coop_mode() -> bool:
	return game_mode == GAME_MODE_COOP

func _is_human_player_id(pid: int) -> bool:
	return pid != 0 and not _is_bot_id(pid)

func are_players_allied(a: int, b: int) -> bool:
	if not is_coop_mode():
		return false
	if a == 0 or b == 0 or a == b:
		return false
	return _is_bot_id(a) == _is_bot_id(b)

func should_block_player_damage(victim_id: int, attacker_id: int) -> bool:
	return are_players_allied(victim_id, attacker_id)

func _cmdline_has(arg: String) -> bool:
	return arg in OS.get_cmdline_args() or arg in OS.get_cmdline_user_args()

func _configure_game_mode() -> void:
	game_mode = GAME_MODE_VERSUS
	if _cmdline_has("--coop"):
		game_mode = GAME_MODE_COOP
	if NetworkManager.has_meta("game_mode") and str(NetworkManager.get_meta("game_mode")) == GAME_MODE_COOP:
		game_mode = GAME_MODE_COOP
	if NetworkManager.has_meta("coop_mode") and bool(NetworkManager.get_meta("coop_mode")):
		game_mode = GAME_MODE_COOP
const SPAWN_MIN_SPACING := 8.0   # meters — two fresh spawns must be at least this far apart
const SPAWN_HARD_MIN_SPACING := 2.5  # never stack closer than this, even on tiny platforms

var rounds_to_win: int = 10

@onready var players_root: Node3D = $Players
@onready var scoreboard: Label = $HUD/Scoreboard
@onready var round_banner: Label = $HUD/RoundBanner
@onready var banner_timer: Timer = $HUD/BannerTimer

var state: int = State.WAITING
# GameNight gating: when this process was launched by the GameNight daemon,
# _maybe_start_match() must not flip WAITING -> PLAYING until the daemon's
# `start` message arrives (GameNightBridge opens the gate from GameNight's
# `started` signal). Standalone runs are unaffected — the gate starts open.
var _gamenight_start_gate_open: bool = not GameNight.launched_by_daemon
var game_mode: String = GAME_MODE_VERSUS
var coop_wave: int = 1
var _coop_enemy_spawn_queue: Array[String] = []
var _coop_enemy_spawn_timer: float = -1.0
var _coop_enemy_incoming: Dictionary = {}
var _recent_coop_enemy_spawns: Array[Vector3] = []
var _coop_wave_enemy_total: int = 0
var _coop_wave_kills: int = 0
var downed_players: Dictionary = {}
var _coop_revive_positions: Dictionary = {}
var coop_revive_channels: Dictionary = {}
var round_wins: Dictionary = {}
var current_round: int = 1
var pending_pick_cards: Array = []
# Server-side countdown until all round-start spawn cages release (see
# _start_round_now); <= 0 means no cages pending.
var _cage_release_timer: float = 0.0
var pending_picker_id: int = 0
var pending_pick_cards_by_player: Dictionary = {}
# Server-only countdown until each pending pick auto-resolves (player_id ->
# seconds remaining). Beeps fire at the integer crossings of the last 3s.
const CARD_PICK_TIMEOUT := 10.0
const ROUND_WIN_TO_CARD_PICK_DELAY := 0.35
var pending_pick_deadlines: Dictionary = {}
var completed_picks: Dictionary = {}
var eliminated_players: Dictionary = {}
var round_winner_id: int = 0
var _round_music_level: int = 1
var _round_damage_seen: bool = false
var _round_elapsed: float = 0.0
var _lava_leak_started: bool = false
var _lava_leak_start_ms: int = 0
var _lava_leak_spread_seconds: float = LAVA_LEAK_SPREAD_SECONDS
var _pickups_root: Node3D = null
var _pickup_spawn_timer: float = 0.0
var _pickup_spawn_serial: int = 0
var _air_strike_timer: float = -1.0
var _air_strike_cancel_gen: int = 0
var _air_strikes_armed: bool = false
var _air_strike_pending: bool = false
var _ion_cannon_timer: float = -1.0
var _ion_cannon_cancel_gen: int = 0
var _ion_cannons_armed: bool = false
var _ion_cannon_pending: bool = false
# Music keeps the same track across rounds and only switches at a round
# boundary once it has played at least this long — so short rounds don't
# whiplash the soundtrack. 0 = no track started yet (force one on first round).
const MUSIC_MIN_TRACK_SECONDS := 120.0
var _music_track_started_ms: int = 0
var local_player: Node3D

# --- Match over / rematch ---
var _rematch_overlay: Control = null
var _rematch_subtitle: Label = null
var _rematch_button: Button = null
var _extend_button: Button = null
var _exit_to_menu_button: Button = null
var _rematch_requested: bool = false
var _match_end_votes: Dictionary = {} # id -> "rematch" | "extend"
const REMATCH_VOTE_DELAY := 1.0
var _rematch_vote_unlock_timer: Timer = null
# Match-win banner gets an oversized animated treatment, and the rematch buttons
# fade in a beat later so the victory reads first.
const MATCH_WIN_FONT_SIZE := 92
const MATCH_WIN_BUTTONS_DELAY := 1.4
var _match_win_tween: Tween = null
var _match_win_pulse_tween: Tween = null

# --- Dev panel (`.`) ---
# Owned by scripts/dev_panel.gd, instantiated in _ready and added under $HUD.
# Stays null in release builds (no --dev flag) — cheats are unreachable.
var _dev_panel: Node = null


func _dev_tools_enabled() -> bool:
	# Editor + debug exports → on. Release exports → off unless the user
	# explicitly opts in by passing --dev on the command line.
	if OS.is_debug_build():
		return true
	return "--dev" in OS.get_cmdline_args()
# Dev-only: bots keep full AI (targeting, chasing, aiming) but never fire.
# Read by Player AI; mutated by F1 panel toggle and the P keybinding.
var bots_hold_fire: bool = false

# --- Tab scoreboard overlay ---
var _tab_root: PanelContainer = null
var _tab_content: VBoxContainer = null

# --- Pause menu (ESC) ---
var _pause_menu: Control = null
# Frame on which _input already handled a ui_cancel press. _process polls the
# same action as a cross-platform fallback (see the macOS note below); this
# guard stops it from re-toggling the menu in the same frame _input closed it —
# which otherwise reopened it instantly, so ESC never appeared to close.
var _ui_cancel_frame: int = -1
var _network_status_panel: PanelContainer = null
var _network_status_label: Label = null
var _kill_feed: VBoxContainer = null
var _pickup_toast: Label = null
var _pickup_toast_timer: Timer = null
var _modifier_toast: Label = null
var _modifier_toast_timer: Timer = null
var _splitscreen_hint: Label = null
var _join_auto_submit_text: String = ""
var _join_in_progress: bool = false
var _ping_ms_by_player: Dictionary = {}
var _ping_pending: Dictionary = {}
var _bot_appearance_seeds: Dictionary = {}
var _ping_seq: int = 0
var _ping_probe_timer: float = 0.0
var _high_ping_warn_timer: float = 0.0
var _tab_refresh_timer: float = 0.0
var _explosion_flash_overlay: ColorRect = null
var _arena_env: Environment = null
var current_round_modifier: String = ""
var gamenight_rules := preload("res://scripts/gamenight_rules.gd").new()
# Dev override: when _force_round_modifier is true, every round uses
# _forced_round_modifier instead of a random roll (set via the . dev menu).
var _force_round_modifier: bool = false
var _forced_round_modifier: String = ""

# Called by the dev panel: lock a modifier across rounds (force=true) or return
# to random rolls (force=false). Applies immediately too.
func dev_set_forced_modifier(mod_id: String, force: bool) -> void:
	_force_round_modifier = force
	_forced_round_modifier = mod_id if force else ""
	if force and multiplayer.is_server():
		_set_round_modifier.rpc(mod_id)
var current_arena_size_min: float = -1.0
var current_arena_size_max: float = -1.0
var _fog_base_saved: bool = false
var _fog_base_enabled: bool = true
var _fog_base_mode: int = 0
var _fog_base_density: float = 0.012
var _fog_base_depth_begin: float = 0.0
var _fog_base_depth_end: float = 0.0
var _fog_base_depth_curve: float = 1.0
var _fog_base_aerial_perspective: float = 0.0
var _blackout_base_saved: bool = false
var _blackout_base_ambient: float = 0.6
var _blackout_base_sun: float = 1.2
var _blackout_base_fill: float = 1.4
var _blackout_base_sky_contrib: float = 0.0
var _blackout_base_bg_energy: float = 1.0
var _blackout_base_bg_mode: int = Environment.BG_SKY
var _blackout_base_fog_enabled: bool = true
var _blackout_hidden_lights: Array[Light3D] = []
var _base_tonemap_exposure: float = 1.0
var _exposure_duck: float = 0.0
var _exposure_duck_vel: float = 0.0
# Sustained-blast guard: a single explosion may dim deep (dramatic), but rapid
# repeated explosions used to re-max the duck every frame and pin exposure at
# the near-black floor — leaving the whole screen dark during explosion spam.
# This "pressure" rises with trigger frequency and lifts the exposure floor so
# spam settles at a dim-but-visible level instead of going black.
var _sidechain_pressure: float = 0.0
const SIDECHAIN_PRESSURE_MAX := 6.0      # ~6 blasts in quick succession = full pressure
const SIDECHAIN_PRESSURE_DECAY := 3.0    # units/sec — ~2s of calm fully relaxes it
const SIDECHAIN_FLOOR_MIN := 0.08        # isolated blast can dip near-black (punchy)
const SIDECHAIN_FLOOR_MAX := 0.5         # under sustained spam, never darker than this
var _flash_alpha: float = 0.0
var _flash_alpha_vel: float = 0.0
# Target the alpha lerps TOWARD on the rise — instant set on _flash_alpha
# tears visibly with vsync off (a single frame jumping 0 -> 0.8 splits the
# screen). Ramping over a couple frames keeps per-frame change small.
var _flash_alpha_target: float = 0.0
var _flash_adsr_active: bool = false
var _flash_adsr_peak: float = 0.0
var _flash_adsr_sustain_end_ms: int = 0
var _flash_adsr_release_end_ms: int = 0
var _phoenix_fade_overlay: ColorRect = null
var _phoenix_fade_alpha: float = 0.0
var _phoenix_fade_out_per_s: float = 0.0
const PHOENIX_FADE_OUT_SECONDS := 0.9

var _last_input_was_controller := false
var _last_controller_device: int = -1
# Owned by scripts/splitscreen_manager.gd, instantiated in _ready as a child
# Node. Reads NetworkManager metadata to decide whether to build its layer.
var _splitscreen: Node = null
var _render_layer: CanvasLayer = null
var _render_root: Control = null
var _render_players: Dictionary = {}
var _audio_panel: AudioSettingsPanel = null

func _ready() -> void:
	Trace.mark("game._ready start (is_server=%s)" % multiplayer.is_server())
	# Menu shader warmup may have queued blast jobs against the old arena tree.
	Violence.discard_pending_blast_visuals()
	ProceduralMusic.set_energy(1, true)
	_install_controller_input_map()
	# Splitscreen manager: builds a CanvasLayer + per-device viewports if the
	# NetworkManager flag is set. Inert otherwise (still a Node, but no UI).
	_splitscreen = SPLITSCREEN_MANAGER_SCRIPT.new()
	_splitscreen.name = "Splitscreen"
	add_child(_splitscreen)
	_splitscreen.setup(self)
	# F2 brings up the live audio-tuning panel — same sliders as action_lab.
	_audio_panel = AudioSettingsPanel.new()
	add_child(_audio_panel)

	_pickups_root = Node3D.new()
	_pickups_root.name = "Pickups"
	add_child(_pickups_root)
	_reset_pickup_spawner()

	# Always-process so the retro-shader cursor + mouse-mode keep updating
	# while the world is paused (pause menu open). Gameplay-tickling parts of
	# _process and _input are guarded with explicit get_tree().paused checks
	# below so they still pause correctly.
	process_mode = Node.PROCESS_MODE_ALWAYS

	# Networking auto-bootstrap moved further down — see the IrohServer.start()
	# call right before the multiplayer.is_server() branch. Iroh is the only
	# transport now; LAN/ENet auto-connect was removed with the main menu.
	_configure_game_mode()

	NetworkManager.player_list_changed.connect(_update_scoreboard)
	NetworkManager.player_list_changed.connect(_refresh_bot_counter)
	if not NetworkManager.network_status_changed.is_connected(_on_network_status_changed):
		NetworkManager.network_status_changed.connect(_on_network_status_changed)
	if not NetworkManager.iroh_host_ready.is_connected(_on_iroh_host_ready):
		NetworkManager.iroh_host_ready.connect(_on_iroh_host_ready)
	banner_timer.timeout.connect(func() -> void: round_banner.visible = false)
	round_banner.visible = false
	scoreboard.visible = false
	_build_rematch_overlay()
	_build_custom_cursor()
	_build_explosion_flash_overlay()
	_build_phoenix_fade_overlay()
	_build_retro_filter()
	_build_network_status_panel()
	_build_kill_feed()
	_build_splitscreen_hint()
	Input.joy_connection_changed.connect(_on_joy_connection_changed)
	_refresh_splitscreen_hint()
	if NetworkManager.has_meta("network_notice"):
		var notice := str(NetworkManager.get_meta("network_notice"))
		NetworkManager.remove_meta("network_notice")
		_on_network_status_changed(notice, true)
	if not NetworkManager.last_network_error.is_empty():
		_on_network_status_changed(NetworkManager.last_network_error, true)
	MenuHelpers.load_settings()
	MenuHelpers.settings_changed_callback = _apply_settings
	MenuHelpers.player_name_committed_callback = _on_player_name_committed
	_apply_settings()
	# Web-zip distribution doesn't auto-update like the itch.io app does —
	# this fires a one-shot HTTPRequest against the repo's VERSION file and
	# pops a tiny "click to download" button if the released version is
	# newer than the build the user is running.
	add_child(preload("res://scripts/version_check.gd").new())
	_build_tab_overlay()
	# Dev panel (F1 / `.`) — cheats. Only built in debug runs (editor + debug
	# exports) or when --dev is on the command line. Released zips ship
	# without it so the `.` panel + G/P/M/1-5 cheat hotkeys are dormant.
	if _dev_tools_enabled():
		_dev_panel = DEV_PANEL_SCRIPT.new()
		_dev_panel.setup(self)
		$HUD.add_child(_dev_panel)
	var we := $Arena/WorldEnvironment
	if we and we.environment:
		_arena_env = we.environment
		_base_tonemap_exposure = _arena_env.tonemap_exposure

	# Don't gate boot on a name — solo/offline players shouldn't have to enter a
	# callsign before they can play, and a blocking modal at boot is fragile. If
	# we have no saved name (first launch), default to a generated handle and let
	# the player rename anytime from the pause menu. Saved name is used as-is.
	if MenuHelpers.player_name.is_empty():
		MenuHelpers.player_name = "Player_%d" % (randi() % 1000)
		MenuHelpers.save_settings()
	NetworkManager.local_player_name = MenuHelpers.player_name

	# Voronoi gib bakes are expensive — do them once at boot, not on first kill.
	# Also start synthesizing one-off effect sounds while the menu is still up
	# if the player came from start_screen (idempotent — safe to call again).
	SFX.warmup_specials()
	_boot_warmup_assets()

	# Solo vs bots never waits on iroh — register locally and let the player
	# opt in via pause-menu "Host online" (or a menu hand-off that's already live).
	NetworkManager.ensure_solo_registered(MenuHelpers.player_name)
	if NetworkManager.is_iroh_join_in_progress():
		NetworkManager.ensure_iroh_client_peer()

	if multiplayer.is_server():
		_set_game_mode.rpc(game_mode, coop_wave)
		if not multiplayer.peer_connected.is_connected(_on_peer_connected):
			multiplayer.peer_connected.connect(_on_peer_connected)
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
		var spawn_used: Array[Vector3] = []
		for pid in NetworkManager.players:
			round_wins[pid] = 0
			if players_root.has_node(str(pid)):
				var existing := players_root.get_node(str(pid)) as Node3D
				if existing:
					spawn_used.append(existing.global_position)
				continue
			var pick := _pick_spawn(spawn_used)
			spawn_used.append(pick["pos"])
			_do_spawn.rpc(pid, NetworkManager.players[pid], pick["pos"], false, -1, false, pick["yaw"])

		# Splitscreen, if we were told to come up in it, now that there is a
		# host player for it to configure. It cannot happen any earlier: the
		# manager is built before this loop runs (see above), so doing it from
		# its own _ready found no player and quietly left the host on
		# keyboard/mouse with a full-screen camera behind the split views.
		if _splitscreen and _splitscreen.has_method("enable_from_meta"):
			_splitscreen.enable_from_meta()

		var bot_requested: bool = NetworkManager.has_meta("spawn_bot_on_start") and NetworkManager.get_meta("spawn_bot_on_start")
		var requested_count: int = int(NetworkManager.get_meta("bot_count_on_start", 1)) if bot_requested else 0
		if is_coop_mode() and not bot_requested:
			requested_count = 0
		if bot_requested:
			_spawn_bots(requested_count, spawn_used)
		_maybe_start_match()

		# Solo-vs-AI fallback: with the main menu gone, every fresh launch
		# of game.tscn lands here as the iroh host with no peers yet — give
		# the player a bot to fight while the lobby waits for friends.
		# `host_started` meta lets a future flow (pause-menu "host empty
		# lobby"?) opt out; the splitscreen path also opts out because each
		# device adds its own real player.
		var host_started: bool = NetworkManager.has_meta("host_started") and NetworkManager.get_meta("host_started")
		if not is_coop_mode() and not bot_requested and not host_started and not _splitscreen.is_enabled():
			_spawn_bots.call_deferred(1, spawn_used)

		# Iroh host: re-show the "ID copied — share it" notice on the in-game
		# banner. Called locally (not .rpc) so only the host sees it. Sticks
		# until a friend joins and _maybe_start_match overwrites the banner.
		# Cleared so a manual restart-match later doesn't re-announce stale info.
		if NetworkManager.get_meta("iroh_host_announce_share", false):
			_announce("MATCH ID COPIED TO CLIPBOARD\nShare with your friends!", 99.0)
			NetworkManager.set_meta("iroh_host_announce_share", false)

		# Peers who connected while we were still in the menu sent their
		# _request_spawn into the void (no game.gd existed here to receive
		# it). Now that the game scene is live, invite them to re-send.
		if multiplayer.get_peers().size() > 0:
			_host_game_ready.rpc()
	else:
		# Instantly show the client state — makes it obvious when you thought
		# you were solo but actually joined an orphan on port 27015.
		if NetworkManager.is_iroh_join_in_progress() \
				and (multiplayer.multiplayer_peer == null or multiplayer.is_server()):
			var join_err := "Join setup failed after reload — could not restore client connection."
			push_error(join_err)
			NetworkManager.clear_iroh_join_state()
			NetworkManager.set_meta("network_notice", join_err)
			get_tree().change_scene_to_file("res://scenes/game.tscn")
			return
		round_banner.text = "CONNECTING TO HOST…"
		round_banner.visible = true
		banner_timer.stop()
		_client_request_spawn_when_ready()
		# If we're connected but nothing arrives, the host is sitting in the
		# menu and hasn't picked a game mode — say so instead of implying the
		# connection is still being established. Self-heals via
		# _host_game_ready once the host loads the game scene.
		get_tree().create_timer(2.0).timeout.connect(func() -> void:
			var peer := multiplayer.multiplayer_peer
			if local_player == null and not multiplayer.is_server() \
					and round_banner.visible and peer != null \
					and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
				round_banner.text = "CONNECTED — WAITING FOR HOST TO PICK A GAME MODE…")

	_update_scoreboard()
	# Splitscreen manager auto-builds its layer in its own _ready when enabled.

func _track_input_device(event: InputEvent) -> void:
	var controller_input := event is InputEventJoypadButton or event is InputEventJoypadMotion
	var keyboard_mouse_input := event is InputEventKey or event is InputEventMouseButton or event is InputEventMouseMotion
	if controller_input:
		if event is InputEventJoypadMotion and absf(event.axis_value) < 0.18:
			return
		_last_controller_device = event.device
		_set_controller_hud_icons(true)
	elif keyboard_mouse_input:
		if event is InputEventMouseMotion and event.relative.length_squared() < 0.01:
			return
		_set_controller_hud_icons(false)

func _set_controller_hud_icons(enabled: bool) -> void:
	if _last_input_was_controller == enabled:
		return
	_last_input_was_controller = enabled
	HUD_ICON_SCRIPT.use_controller_icons = enabled
	get_tree().call_group("hud_input_icons", "_refresh_input_device")
	_refresh_splitscreen_hint()

func _install_controller_input_map() -> void:
	_add_joy_axis_action("move_left", JOY_AXIS_LEFT_X, -1.0)
	_add_joy_axis_action("move_right", JOY_AXIS_LEFT_X, 1.0)
	_add_joy_axis_action("move_forward", JOY_AXIS_LEFT_Y, -1.0)
	_add_joy_axis_action("move_back", JOY_AXIS_LEFT_Y, 1.0)
	_add_joy_axis_action("shoot", JOY_AXIS_TRIGGER_RIGHT, 1.0)
	_add_joy_axis_action("shoot_grenade", JOY_AXIS_TRIGGER_LEFT, 1.0)
	_add_joy_button_action("shoot_grenade", JOY_BUTTON_B)
	_add_joy_button_action("jump", JOY_BUTTON_LEFT_SHOULDER)
	_add_joy_button_action("jump", JOY_BUTTON_A)
	_add_joy_button_action("reload", JOY_BUTTON_X)
	_add_joy_button_action("dash", JOY_BUTTON_RIGHT_SHOULDER)
	_add_joy_button_action("dash", JOY_BUTTON_Y)
	_add_joy_button_action("ui_accept", JOY_BUTTON_A)
	_add_joy_button_action("ui_accept", JOY_BUTTON_X)
	_add_joy_button_action("ui_cancel", JOY_BUTTON_START)
	_add_joy_button_action("ui_left", JOY_BUTTON_DPAD_LEFT)
	_add_joy_button_action("ui_right", JOY_BUTTON_DPAD_RIGHT)
	_add_joy_button_action("ui_up", JOY_BUTTON_DPAD_UP)
	_add_joy_button_action("ui_down", JOY_BUTTON_DPAD_DOWN)
	_add_joy_axis_action("ui_left", JOY_AXIS_LEFT_X, -1.0)
	_add_joy_axis_action("ui_right", JOY_AXIS_LEFT_X, 1.0)
	_add_joy_axis_action("ui_up", JOY_AXIS_LEFT_Y, -1.0)
	_add_joy_axis_action("ui_down", JOY_AXIS_LEFT_Y, 1.0)

func _add_joy_button_action(action: StringName, button_index: int) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var event := InputEventJoypadButton.new()
	event.button_index = button_index
	if not InputMap.action_has_event(action, event):
		InputMap.action_add_event(action, event)

func _add_joy_axis_action(action: StringName, axis: int, axis_value: float) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var event := InputEventJoypadMotion.new()
	event.axis = axis
	event.axis_value = axis_value
	if not InputMap.action_has_event(action, event):
		InputMap.action_add_event(action, event)

func _ensure_render_player(player_id: int, input_device: int = -1) -> RenderPlayer:
	if _render_players.has(player_id):
		return _render_players[player_id] as RenderPlayer
	_build_render_layer()
	var renderer := RENDER_PLAYER_SCRIPT.new() as RenderPlayer
	renderer.name = "RenderPlayer_%d" % player_id
	_render_root.add_child(renderer)
	renderer.setup(self, player_id, input_device)
	renderer.card_selected.connect(_on_render_player_card_selected)
	_render_players[player_id] = renderer
	# Every view is drawn by a RenderPlayer; the window's own 3D pass (the
	# local player's camera is current there too) would only render the whole
	# world a second time underneath them.
	get_viewport().disable_3d = true
	_update_render_player_layouts()
	return renderer

func _remove_render_player(player_id: int) -> void:
	var renderer := _render_players.get(player_id) as Node
	if renderer and is_instance_valid(renderer):
		renderer.queue_free()
	_render_players.erase(player_id)

func _clear_render_players() -> void:
	for id in _render_players.keys():
		_remove_render_player(int(id))
	get_viewport().disable_3d = false


func _exit_tree() -> void:
	# The window outlives this scene (menus draw 3D in it again).
	get_viewport().disable_3d = false

func _build_render_layer() -> void:
	if _render_layer:
		return
	_render_layer = CanvasLayer.new()
	_render_layer.name = "RenderLayer"
	_render_layer.layer = 0
	add_child(_render_layer)
	_render_root = Control.new()
	_render_root.name = "RenderPlayers"
	_render_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_render_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_render_layer.add_child(_render_root)
	_render_root.resized.connect(_update_render_player_layouts)

func _update_render_player_layouts() -> void:
	if _render_root == null:
		return
	var size := _render_root.get_rect().size
	if size.x <= 0.0 or size.y <= 0.0:
		size = get_viewport().get_visible_rect().size
	for renderer in _render_players.values():
		var rp := renderer as RenderPlayer
		rp.position = Vector2.ZERO
		rp.size = size
		rp.layout_for_size(size)

func _handle_render_player_input(event: InputEvent) -> bool:
	for renderer in _render_players.values():
		if renderer.handle_input(event):
			return true
	return false

func _client_request_spawn_when_ready() -> void:
	# The scene change happens before `connected_to_server` fires, so the
	# client can reach _ready with a peer that isn't fully connected yet.
	# RPCs sent in that window are dropped silently — wait for the signal.
	var peer := multiplayer.multiplayer_peer
	if peer and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		_request_spawn.rpc_id(1, NetworkManager.local_player_name)
		return
	multiplayer.connected_to_server.connect(
		func() -> void: _request_spawn.rpc_id(1, NetworkManager.local_player_name),
		CONNECT_ONE_SHOT,
	)
	get_tree().create_timer(JOIN_TIMEOUT_SECONDS).timeout.connect(_on_join_timeout)


func _on_join_timeout() -> void:
	var peer := multiplayer.multiplayer_peer
	if peer == null or peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		return
	var message := "Connection timed out. Confirm the match ID, make sure the host is still running, and allow the game through Windows Firewall."
	NetworkManager.last_network_error = message
	NetworkManager.set_meta("network_notice", message)
	NetworkManager.leave_game()
	get_tree().change_scene_to_file("res://scenes/game.tscn")


func _trace_game_process(t0: int) -> void:
	if Trace.enabled and t0 > 0:
		Trace.prof("game", Time.get_ticks_usec() - t0)


func _process(delta: float) -> void:
	var _pt := Time.get_ticks_usec() if Trace.enabled else 0
	Violence.flush_pending_blast_visuals()
	_update_explosion_sidechain(delta)
	_update_phoenix_fade(delta)
	_sync_mouse_mode()
	_update_ping_monitor(delta)
	if _tab_root and _tab_root.visible:
		_tab_refresh_timer -= delta
		if _tab_refresh_timer <= 0.0:
			_tab_refresh_timer = 0.5
			_refresh_tab_overlay()
	if multiplayer.is_server() and state == State.PLAYING:
		_update_coop_enemy_spawner(delta)
		_update_coop_revives(delta)
		_update_lava_leak(delta)
		_update_round_music_phase()
		_update_pickup_spawner(delta)
		_update_air_strikes(delta)
		_update_ion_cannons(delta)
	if multiplayer.is_server():
		_tick_card_pick_deadlines(delta)
		if _cage_release_timer > 0.0:
			_cage_release_timer -= delta
			if _cage_release_timer <= 0.0:
				for p in players_root.get_children():
					if p.has_method("release_spawn_cage"):
						p.release_spawn_cage.rpc()
		_update_music_muffle_broadcast()
	_update_custom_cursor()
	# Polling-based pause toggle. On macOS, pressing Esc while the mouse is
	# captured auto-uncaptures it at the engine level and the resulting
	# InputEventKey doesn't reliably propagate to Game._input — but the
	# Input singleton's action state still flips for one frame, which polls
	# fine from here. Gating on `paused` avoids double-toggling alongside
	# the pause menu's Resume-button Shortcut.
	if Input.is_action_just_pressed("ui_cancel") and not get_tree().paused \
			and _ui_cancel_frame != Engine.get_process_frames():
		if _dev_panel != null and _dev_panel.is_open():
			_dev_panel.toggle()
			_sync_mouse_mode()
		else:
			_toggle_pause_menu()
		_trace_game_process(_pt)
		return
	_update_render_player_layouts()
	_trace_game_process(_pt)

	# Tab is handled in _input — Godot's GUI focus navigation eats the Tab key
	# before _process polling can see it, so we intercept it earlier.

func _unhandled_key_input(event: InputEvent) -> void:
	if _handle_global_cancel_or_pause(event):
		get_viewport().set_input_as_handled()


func _handle_global_cancel_or_pause(event: InputEvent) -> bool:
	var cancel_pressed := event.is_action_pressed("ui_cancel")
	var enter_pressed := false
	if event is InputEventKey:
		cancel_pressed = cancel_pressed or (
			event.pressed
			and not event.echo
			and (event.keycode == KEY_ESCAPE or event.physical_keycode == KEY_ESCAPE)
		)
		enter_pressed = event.pressed and not event.echo and (
			event.keycode == KEY_ENTER
			or event.keycode == KEY_KP_ENTER
		)
	# Controller B backs out of pause/settings menus only. It is intentionally
	# not a gameplay pause shortcut because B is also grenade on controller.
	var menu_back_pressed: bool = cancel_pressed or (
		event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_B
	)
	if menu_back_pressed:
		if _settings_panel != null and _settings_panel.visible:
			_ui_cancel_frame = Engine.get_process_frames()
			_close_settings()
			return true
		if _pause_menu != null and _pause_menu.visible:
			_ui_cancel_frame = Engine.get_process_frames()
			_toggle_pause_menu()
			return true
	if _is_render_card_pick_visible():
		if menu_back_pressed:
			_ui_cancel_frame = Engine.get_process_frames()
			return true
		return false
	if cancel_pressed or enter_pressed:
		_ui_cancel_frame = Engine.get_process_frames()
		if _dev_panel != null and _dev_panel.is_open():
			_dev_panel.toggle()
			_sync_mouse_mode()
			return true
		_toggle_pause_menu()
		return true
	return false


func _input(event: InputEvent) -> void:
	_track_input_device(event)
	if _handle_global_cancel_or_pause(event):
		get_viewport().set_input_as_handled()
		return

	# When solo play pauses the scene tree, only pause/menu close handling
	# above should continue through Game._input.
	if get_tree().paused:
		return
	if _splitscreen and _splitscreen.handle_input(event):
		get_viewport().set_input_as_handled()
		return
	if _handle_render_player_input(event):
		get_viewport().set_input_as_handled()
		return

	# Tab hold = scoreboard overlay. Use _input (not _unhandled_input) so we
	# beat the viewport's GUI focus navigation, which would otherwise consume
	# Tab and prevent our polling from ever seeing it.
	if event is InputEventKey and not event.echo and event.keycode == KEY_TAB:
		if event.pressed:
			_show_tab_overlay()
		else:
			_hide_tab_overlay()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F1 or event.keycode == KEY_PERIOD:
			if _dev_panel != null:
				_dev_panel.toggle()
				_sync_mouse_mode()
				get_viewport().set_input_as_handled()
			return

	# Cheat hotkeys (G / P / M / L / I / 0 / 1-9 / ?) — only when dev tools are enabled.
	if event is InputEventKey and event.pressed and not event.echo and _dev_panel != null:
		var cheat_handled := true
		var shift: bool = event.shift_pressed
		match event.keycode:
			KEY_G:
				var t = _dev_panel.get_target()
				if t:
					t.god_mode = not t.god_mode
					_announce.rpc("GODMODE: %s" % ("ON" if t.god_mode else "OFF"), 1.0)
					_dev_panel.refresh_if_visible()
			KEY_P:
				bots_hold_fire = not bots_hold_fire
				_announce.rpc("PASSIVE AI: %s" % ("ON" if bots_hold_fire else "OFF"), 1.0)
				_dev_panel.refresh_if_visible()
			KEY_M:
				if multiplayer.is_server():
					_restart_match()
			KEY_L:
				if multiplayer.is_server():
					_trigger_lava_leak(LAVA_LEAK_SPREAD_SECONDS)
					_announce.rpc("LAVA TRIGGERED", 1.0)
			KEY_K:
				if multiplayer.is_server():
					dev_test_air_strike()
			KEY_J:
				if multiplayer.is_server():
					dev_test_ion_cannon()
			KEY_I:
				if multiplayer.is_server():
					dev_spawn_pickup()
					_announce.rpc("PICKUP DROPPED", 1.0)
			KEY_B:
				if multiplayer.is_server():
					var on := current_round_modifier != "blackout"
					dev_set_forced_modifier("blackout" if on else "", on)
					_announce.rpc("BLACKOUT %s" % ("ON" if on else "OFF"), 1.0)
			KEY_0:
				var t = _dev_panel.get_target()
				if t:
					t.reset_weapon.rpc()
					_announce.rpc("WEAPON RESET", 1.0)
					_dev_panel.refresh_if_visible()
			KEY_1:
				_dev_card_hotkey("dmg_up", "DAMAGE", shift)
			KEY_2:
				_dev_card_hotkey("rapid_fire", "RAPID FIRE", shift)
			KEY_3:
				_dev_card_hotkey("extra_barrel", "EXTRA BARREL", shift)
			KEY_4:
				_dev_card_hotkey("explosive", "EXPLOSIVE", shift)
			KEY_5:
				_dev_card_hotkey("ricochet", "RICOCHET", shift)
			KEY_6:
				_dev_card_hotkey("chilling_rounds", "CHILLING", shift)
			KEY_7:
				_dev_card_hotkey("big_mag", "BIG MAG", shift)
			KEY_8:
				_dev_card_hotkey("precision", "PRECISION", shift)
			KEY_9:
				_dev_card_hotkey("bullet_speed", "FAST ROUNDS", shift)
			KEY_SLASH:
				if event.shift_pressed: # '?'
					_dev_panel.show_help()
			_:
				cheat_handled = false

		if cheat_handled:
			get_viewport().set_input_as_handled()
			return

# -------------------- SPAWN / DESPAWN --------------------

func _dev_card_hotkey(card_id: String, label: String, remove: bool) -> void:
	if _dev_panel == null:
		return
	if remove:
		if _dev_panel.remove_card_from_target(card_id):
			_announce.rpc("REMOVED: %s" % label, 1.0)
		else:
			_announce.rpc("NOT STACKED: %s" % label, 1.0)
	else:
		if _dev_panel.apply_card_to_target(card_id):
			_announce.rpc("APPLIED: %s" % label, 1.0)
	_dev_panel.refresh_if_visible()

func _on_peer_connected(_id: int) -> void:
	if not multiplayer.is_server():
		return
	# The boot-time bot is only a solo fallback. As soon as a real remote peer
	# arrives, remove it before the joining player spawns so the default match
	# becomes humans-only.
	if not is_coop_mode():
		_clear_coop_enemies()


func _on_peer_disconnected(id: int) -> void:
	if not multiplayer.is_server():
		return
	var pname := str(NetworkManager.players.get(id, ""))
	if pname.is_empty():
		var existing := players_root.get_node_or_null(str(id))
		if existing:
			pname = str(existing.get("player_name"))
	var node := players_root.get_node_or_null(str(id))
	if node:
		_despawn.rpc(id)
	if not pname.is_empty() and not _is_bot_id(id):
		_announce.rpc("%s left" % pname, 2.0)
	round_wins.erase(id)
	_broadcast_scores.rpc(round_wins)
	if state == State.PICKING_CARD and id == pending_picker_id:
		_hide_card_pick.rpc()
		_set_game_state.rpc(State.PLAYING)
	pending_pick_cards_by_player.erase(id)
	pending_pick_deadlines.erase(id)
	completed_picks.erase(id)
	eliminated_players.erase(id)
	_ping_ms_by_player.erase(id)
	for seq in _ping_pending.keys():
		if int(_ping_pending[seq].get("peer", 0)) == id:
			_ping_pending.erase(seq)
	_broadcast_ping_ms.rpc(_ping_ms_by_player)
	if NetworkManager.players.size() < 2:
		_set_game_state.rpc(State.WAITING)
		_hide_card_pick.rpc()
		_hide_rematch_overlay.rpc()

# Host loaded the game scene after clients were already connected (they
# joined while the host browsed the menu) — their spawn requests went
# nowhere; ask them to re-send now that someone is listening.
@rpc("authority", "call_local", "reliable")
func _host_game_ready() -> void:
	if multiplayer.is_server():
		return
	if local_player == null:
		_request_spawn.rpc_id(1, NetworkManager.local_player_name)


@rpc("any_peer", "call_local", "reliable")
func _request_spawn(pname: String) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = 1
	# Captured before _spawn_player: a re-request from an already-spawned
	# peer (e.g. via _host_game_ready) must not hard-restart the match.
	var already_spawned := players_root.has_node(str(sender))
	# A real peer is joining — boot any SP fallback bots that are around.
	if not is_coop_mode():
		_despawn_all_bots()
	NetworkManager.players[sender] = pname
	if not round_wins.has(sender):
		round_wins[sender] = 0
	_ping_ms_by_player[sender] = -1
	# Ship the current map to the joiner before spawning them. The embedded
	# arena_procedural in game.tscn has regenerate_on_ready=false, so a
	# fresh client's local Arena has no floor / walls / spawnpoints until a
	# _swap_arena RPC arrives. That RPC normally only fires at round start,
	# so a mid-round join would otherwise teleport the player onto a server-
	# valid position that doesn't exist on their client → fall into lava.
	# Targeting just the joiner via rpc_id keeps existing peers untouched.
	if state != State.WAITING and current_map_index >= 0 and current_map_index < MAP_POOL.size():
		_swap_arena.rpc_id(sender, current_map_index, current_map_seed, current_arena_size_min, current_arena_size_max)
	if _lava_leak_started and _lava_leak_start_ms > 0:
		_start_lava_leak.rpc_id(sender, _lava_leak_spread_seconds, _lava_leak_start_ms)
	_spawn_player(sender, pname)
	for pid in NetworkManager.players:
		if players_root.has_node(str(pid)) and pid != sender:
			var existing := players_root.get_node(str(pid)) as Node3D
			if existing == null:
				continue
			_do_spawn.rpc_id(sender, pid, NetworkManager.players[pid],
				existing.global_position, _is_bot_id(int(pid)), -1, false, existing.rotation.y,
				int(_bot_appearance_seeds.get(pid, 0)))
	_broadcast_scores.rpc(round_wins)
	_set_gamenight_rules.rpc_id(sender, gamenight_rules.values)
	_set_game_mode.rpc_id(sender, game_mode, coop_wave)
	if is_coop_mode():
		_set_coop_wave_progress.rpc_id(sender, _coop_wave_kills, _coop_wave_enemy_total)
	if not is_coop_mode() and state != State.WAITING and not already_spawned:
		# A real player joined a versus match already underway (typically the
		# host warming up against the SP fallback bot). Don't drop them into
		# the middle of someone else's round — hard-restart: clear any live
		# card pick, then _restart_match -> WAITING -> _maybe_start_match,
		# which resets every weapon and opens round 1 clean for both.
		_hide_card_pick.rpc()
		pending_pick_cards_by_player.clear()
		pending_pick_deadlines.clear()
		completed_picks.clear()
		eliminated_players.clear()
		_restart_match()
	else:
		if state != State.WAITING:
			_set_game_state.rpc_id(sender, state)
		_maybe_start_match()
	if not _is_bot_id(sender):
		_announce.rpc("%s joined" % pname, 2.0)

func _spawn_player(id: int, pname: String) -> void:
	if players_root.has_node(str(id)):
		return
	var pick := _pick_spawn(_current_player_positions())
	_do_spawn.rpc(id, pname, pick["pos"], false, -1, false, pick["yaw"])

func _current_player_positions() -> Array[Vector3]:
	var out: Array[Vector3] = []
	for child in players_root.get_children():
		if child is Node3D:
			out.append((child as Node3D).global_position)
	return out


@rpc("any_peer", "call_local", "reliable")
func execute_phoenix_revive(player_id: int, fx_pos: Vector3) -> void:
	if not multiplayer.is_server():
		return
	downed_players.erase(player_id)
	var p := players_root.get_node_or_null(str(player_id))
	if p == null or not is_instance_valid(p):
		return
	p.clear_ragdoll.rpc()
	p.begin_phoenix_ascension.rpc(fx_pos, Time.get_ticks_msec())
	p.set_frozen.rpc(false)


@rpc("any_peer", "call_local", "reliable")
func finish_phoenix_revive(player_id: int) -> void:
	if not multiplayer.is_server():
		return
	if state != State.PLAYING:
		return
	var p := players_root.get_node_or_null(str(player_id))
	if p == null or not is_instance_valid(p):
		return
	if not bool(p.get("_phoenix_ascending")) and not (bool(p.get("coop_downed")) and bool(p.get("_coop_phoenix_held"))):
		return
	var preferred_ground: Vector3
	var spawn_yaw: float
	if _coop_revive_positions.has(player_id):
		preferred_ground = _coop_revive_positions[player_id]
		_coop_revive_positions.erase(player_id)
	else:
		preferred_ground = p.global_position
	var drop := _sky_drop_spawn(preferred_ground, player_id, _current_player_positions())
	var sky_pos: Vector3 = drop["pos"]
	spawn_yaw = drop["yaw"]
	p._finish_phoenix_ascension.rpc(sky_pos, spawn_yaw)
	_apply_coop_spawn_health(p)
	p.set_launching.rpc(true, 80.0)
	downed_players.erase(player_id)


func handle_coop_human_death(
	victim_id: int,
	corpse_pos: Vector3,
	killer_id: int,
	force_origin: Vector3,
	hit_dir: Vector3,
	gib_force: float,
	blast_radius: float,
	blast_severity: float,
	is_head: bool,
	suppress_death_sound: bool,
	suppress_death_ragdoll: bool,
) -> bool:
	if not multiplayer.is_server() or not is_coop_mode() or not _is_human_player_id(victim_id):
		return false
	if downed_players.has(victim_id):
		return true
	if _standing_human_ids(victim_id).is_empty():
		return false
	downed_players[victim_id] = {
		"pos": corpse_pos,
		"progress": 0.0,
		"reviver_id": 0,
	}
	_coop_revive_positions[victim_id] = corpse_pos
	var victim_name := str(NetworkManager.players.get(victim_id, "Player"))
	if not victim_name.is_empty():
		_announce.rpc("%s is down" % victim_name, 2.0)
	var p := players_root.get_node_or_null(str(victim_id))
	if p:
		p.enter_coop_downed.rpc(corpse_pos)
	if _standing_human_ids().is_empty():
		_end_coop_match()
	return true


@rpc("any_peer", "call_local", "reliable")
func request_coop_human_death(
	victim_id: int,
	corpse_pos: Vector3,
	killer_id: int,
	force_origin: Vector3,
	hit_dir: Vector3,
	gib_force: float,
	blast_radius: float,
	blast_severity: float,
	is_head: bool,
	suppress_death_sound: bool,
	suppress_death_ragdoll: bool,
) -> void:
	if not multiplayer.is_server():
		return
	if handle_coop_human_death(
		victim_id,
		corpse_pos,
		killer_id,
		force_origin,
		hit_dir,
		gib_force,
		blast_radius,
		blast_severity,
		is_head,
		suppress_death_sound,
		suppress_death_ragdoll,
	):
		return
	var p := players_root.get_node_or_null(str(victim_id))
	if p:
		p._execute_lethal_death_rpc.rpc(
			killer_id,
			force_origin,
			hit_dir,
			gib_force,
			blast_radius,
			blast_severity,
			is_head,
			suppress_death_sound,
			suppress_death_ragdoll,
		)


func _standing_human_ids(exclude_id: int = 0) -> Array[int]:
	var out: Array[int] = []
	for raw_id in NetworkManager.players:
		var pid := int(raw_id)
		if pid == exclude_id or not _is_human_player_id(pid):
			continue
		if eliminated_players.has(pid):
			continue
		if downed_players.has(pid):
			continue
		if not players_root.has_node(str(pid)):
			continue
		var p := players_root.get_node(str(pid))
		if bool(p.get("coop_downed")):
			continue
		if bool(p.get("ghost_mode")):
			continue
		if int(p.get("health")) <= 0 and not bool(p.get("_phoenix_ascending")):
			continue
		out.append(pid)
	return out


func _update_coop_revives(delta: float) -> void:
	if not is_coop_mode():
		return
	if downed_players.is_empty():
		if not coop_revive_channels.is_empty():
			coop_revive_channels = {}
			_sync_coop_revive_channels.rpc({})
		return
	for raw_id in downed_players.keys():
		var victim_id := int(raw_id)
		var entry: Dictionary = downed_players[victim_id]
		var corpse_pos: Vector3 = entry.get("pos", Vector3.ZERO)
		var reviver_id := _coop_reviver_for(victim_id, corpse_pos)
		if reviver_id == 0:
			entry["progress"] = 0.0
			entry["reviver_id"] = 0
		else:
			if int(entry.get("reviver_id", 0)) != reviver_id:
				entry["progress"] = 0.0
			entry["reviver_id"] = reviver_id
			entry["progress"] = float(entry.get("progress", 0.0)) + delta
			if float(entry["progress"]) >= COOP_REVIVE_SECONDS:
				_complete_coop_revive(victim_id, reviver_id)
				continue
		downed_players[victim_id] = entry
	_publish_coop_revive_channels()


func _publish_coop_revive_channels() -> void:
	if not multiplayer.is_server():
		return
	var channels := {}
	for raw_id in downed_players.keys():
		var victim_id := int(raw_id)
		var entry: Dictionary = downed_players[victim_id]
		var reviver_id := int(entry.get("reviver_id", 0))
		if reviver_id == 0:
			continue
		channels[reviver_id] = {
			"victim_id": victim_id,
			"progress": clampf(float(entry.get("progress", 0.0)) / COOP_REVIVE_SECONDS, 0.0, 1.0),
			"victim_name": str(NetworkManager.players.get(victim_id, "ALLY")),
		}
	if channels == coop_revive_channels:
		return
	coop_revive_channels = channels
	_sync_coop_revive_channels.rpc(channels)


@rpc("authority", "call_local", "reliable")
func _sync_coop_revive_channels(channels: Dictionary) -> void:
	coop_revive_channels = channels


func is_coop_reviving(reviver_id: int) -> bool:
	if not is_coop_mode() or state != State.PLAYING:
		return false
	if coop_revive_channels.has(reviver_id):
		return true
	var reviver := players_root.get_node_or_null(str(reviver_id))
	if reviver == null:
		return false
	for child in players_root.get_children():
		# != true also skips non-Player strays (null) instead of crashing in
		# the bool() constructor.
		if child.get("coop_downed") != true:
			continue
		if int(child.get("player_id")) == reviver_id:
			continue
		var flat := Vector2(
			reviver.global_position.x - child.global_position.x,
			reviver.global_position.z - child.global_position.z,
		)
		if flat.length() <= COOP_REVIVE_RADIUS:
			return true
	return false


func get_coop_revive_channel(reviver_id: int) -> Dictionary:
	return coop_revive_channels.get(reviver_id, {})


func _sky_drop_spawn(preferred_ground: Vector3, player_id: int, avoid: Array[Vector3] = [], height: float = 60.0) -> Dictionary:
	var ground := preferred_ground
	if not _spawn_is_valid(ground):
		var pick := _pick_spawn(avoid if not avoid.is_empty() else _current_player_positions())
		ground = pick["pos"]
	# Always face the arena center on the way down — inheriting the player's
	# stale yaw from last round left them staring at the crowd wall.
	var arena: Node = get_node_or_null("Arena")
	var arena_origin: Vector3 = (arena as Node3D).global_position if arena and arena is Node3D else Vector3.ZERO
	var yaw := _spawn_yaw_at(ground, arena_origin)
	return {"pos": ground + Vector3(0.0, height, 0.0), "yaw": yaw, "ground": ground}


func _coop_reviver_for(victim_id: int, corpse_pos: Vector3) -> int:
	var best_id := 0
	var best_dist := COOP_REVIVE_RADIUS
	for pid in _standing_human_ids(victim_id):
		var p := players_root.get_node_or_null(str(pid))
		if p == null:
			continue
		var flat := Vector2(
			p.global_position.x - corpse_pos.x,
			p.global_position.z - corpse_pos.z,
		)
		var dist := flat.length()
		if dist <= best_dist:
			best_dist = dist
			best_id = pid
	return best_id


func _complete_coop_revive(victim_id: int, _reviver_id: int) -> void:
	if not downed_players.has(victim_id):
		return
	var corpse_pos: Vector3 = downed_players[victim_id].get("pos", Vector3.ZERO)
	downed_players.erase(victim_id)
	_coop_revive_positions[victim_id] = corpse_pos
	finish_phoenix_revive(victim_id)


func _arena_spawnpoints() -> Array:
	var arena: Node = get_node_or_null("Arena")
	if arena == null:
		return get_tree().get_nodes_in_group("spawnpoints")
	var out: Array = []
	for sp in get_tree().get_nodes_in_group("spawnpoints"):
		if sp is Node and arena.is_ancestor_of(sp):
			out.append(sp)
	return out

func _pick_spawn(avoid: Array[Vector3] = []) -> Dictionary:
	# Returns {"pos": Vector3, "yaw": float}. Picks the spawnpoint that maximizes
	#   min_distance(other_spawns) - height_penalty
	# so respawning players land far from each other and at roughly the same
	# height as the first one already placed this round. Yaw faces the arena
	# center unless that direction is blocked by a wall within 3m, in which
	# case we try perpendicular and back-facing yaws.
	var spawns := _arena_spawnpoints()
	if spawns.is_empty():
		# Belt-and-suspenders: if we somehow get here while no arena spawn
		# nodes exist, plant the player at the arena's center at safe
		# height instead of world (0, 3, 0). The arena lives at
		# ARENA_OFFSET; world (0, 3, 0) sits in lava and outside the
		# floor — players spawning there fall straight to their death.
		var fb_arena: Node = get_node_or_null("Arena")
		var fb_origin: Vector3 = (fb_arena as Node3D).global_position if fb_arena and fb_arena is Node3D else Vector3.ZERO
		return {"pos": fb_origin + Vector3(0, 5, 0), "yaw": 0.0}

	# Anchor for the height-match bonus: the first spawn already placed this
	# pass, if any. With nothing placed yet, target_y is unused.
	var has_target_y: bool = not avoid.is_empty()
	var target_y: float = avoid[0].y if has_target_y else 0.0

	var arena: Node = get_node_or_null("Arena")
	var arena_origin: Vector3 = (arena as Node3D).global_position if arena and arena is Node3D else Vector3.ZERO

	# Shuffle so all-tied scores still rotate spawn picks across rounds.
	spawns.shuffle()

	var best_pos: Vector3 = Vector3.ZERO
	var best_yaw: float = 0.0
	var best_score: float = -INF
	var fallback_pos: Vector3 = Vector3.ZERO
	var fallback_yaw: float = 0.0
	var fallback_min_d: float = -INF
	var found_clear: bool = false
	var found_spaced: bool = false
	for spawn in spawns:
		var pos: Vector3 = spawn.global_position
		if not _spawn_is_valid(pos):
			continue
		found_clear = true
		var min_d: float = _min_distance(pos, avoid) if not avoid.is_empty() else 100.0
		var min_sp: float = _required_spawn_spacing(pos) if not avoid.is_empty() else 0.0
		var height_penalty: float = absf(pos.y - target_y) * 1.5 if has_target_y else 0.0
		var score: float = min_d - height_penalty
		if avoid.is_empty() or min_d >= min_sp:
			found_spaced = true
			if score > best_score:
				best_score = score
				best_pos = pos
				best_yaw = _spawn_yaw_at(pos, arena_origin)
		elif min_d > fallback_min_d:
			fallback_min_d = min_d
			fallback_pos = pos
			fallback_yaw = _spawn_yaw_at(pos, arena_origin)

	if found_clear and found_spaced:
		return _enforce_spawn_spacing(best_pos, best_yaw, avoid)
	if found_clear and fallback_min_d > -INF:
		return _enforce_spawn_spacing(fallback_pos, fallback_yaw, avoid)
	# Last-ditch fallback: every spawn was blocked by an obstacle or failed
	# validation. Never return a raw spawnpoint — on lava-platform maps that
	# can land in open lava or inside cover columns.
	for spawn in spawns:
		var pos: Vector3 = (spawn as Node3D).global_position
		if _spawn_is_valid(pos):
			return _enforce_spawn_spacing(pos, _spawn_yaw_at(pos, arena_origin), avoid)
	if arena and arena.has_method("is_all_floor_lava") and arena.is_all_floor_lava():
		if arena.has_method("get_lava_fallback_spawn_world"):
			var fb_lava: Vector3 = arena.get_lava_fallback_spawn_world()
			if _spawn_is_valid(fb_lava):
				return _enforce_spawn_spacing(fb_lava, _spawn_yaw_at(fb_lava, arena_origin), avoid)
	return _enforce_spawn_spacing(arena_origin + Vector3(0.0, 8.0, 0.0), 0.0, avoid)


func _min_distance(pos: Vector3, others: Array[Vector3]) -> float:
	var best: float = INF
	for o in others:
		var d: float = Vector2(pos.x, pos.z).distance_to(Vector2(o.x, o.z))
		if d < best:
			best = d
	return best


func _required_spawn_spacing(pos: Vector3) -> float:
	var arena: Node = get_node_or_null("Arena")
	if arena and arena.has_method("get_lava_spawn_platform_at"):
		var platform: Dictionary = arena.get_lava_spawn_platform_at(pos)
		if not platform.is_empty():
			var spawn_r: float = float(platform.get("spawn_radius", 0.0))
			# Small lava disks cannot fit 8 m apart — cap to what the platform allows.
			return maxf(SPAWN_HARD_MIN_SPACING, minf(SPAWN_MIN_SPACING, spawn_r * 1.65))
	return SPAWN_MIN_SPACING


func _pick_lava_platform_spawn(platform: Dictionary, avoid: Array[Vector3]) -> Dictionary:
	var center: Vector3 = platform.get("center", Vector3.ZERO)
	var spawn_r: float = float(platform.get("spawn_radius", 0.0))
	if spawn_r <= 0.05:
		return {}
	var arena: Node = get_node_or_null("Arena")
	var arena_origin: Vector3 = (arena as Node3D).global_position if arena and arena is Node3D else Vector3.ZERO
	var best_pos := center
	var best_min_d := -1.0
	for i in 24:
		var angle := float(i) / 24.0 * TAU
		var candidate := center + Vector3(cos(angle) * spawn_r, 0.0, sin(angle) * spawn_r)
		if not _spawn_is_valid(candidate):
			continue
		var d: float = _min_distance(candidate, avoid)
		if d > best_min_d:
			best_min_d = d
			best_pos = candidate
	if best_min_d < 0.0:
		return {}
	if avoid.is_empty() or best_min_d >= SPAWN_HARD_MIN_SPACING:
		return {"pos": best_pos, "yaw": _spawn_yaw_at(best_pos, arena_origin)}
	return {}


func _enforce_spawn_spacing(pos: Vector3, yaw: float, avoid: Array[Vector3]) -> Dictionary:
	var min_sp := _required_spawn_spacing(pos)
	if avoid.is_empty() or _min_distance(pos, avoid) >= min_sp:
		if _spawn_is_valid(pos):
			return {"pos": pos, "yaw": yaw}
		return _lava_safe_spawn_fallback(yaw, avoid)

	var arena: Node = get_node_or_null("Arena")
	var arena_origin: Vector3 = (arena as Node3D).global_position if arena and arena is Node3D else Vector3.ZERO
	if arena and arena.has_method("get_lava_spawn_platform_at"):
		var platform: Dictionary = arena.get_lava_spawn_platform_at(pos)
		if not platform.is_empty():
			var slot: Dictionary = _pick_lava_platform_spawn(platform, avoid)
			if not slot.is_empty():
				return slot

	var out := pos
	var out_yaw := yaw
	for _attempt in 16:
		if _min_distance(out, avoid) >= min_sp and _spawn_is_valid(out):
			return {"pos": out, "yaw": out_yaw}
		var nearest: Vector3 = avoid[0]
		var nearest_d: float = _min_distance(out, [nearest])
		for other: Vector3 in avoid:
			var d: float = _min_distance(out, [other])
			if d < nearest_d:
				nearest_d = d
				nearest = other
		var away := Vector3(out.x - nearest.x, 0.0, out.z - nearest.z)
		if away.length_squared() < 0.04:
			var angle: float = yaw + float(_attempt + 1) * (TAU / 8.0)
			away = Vector3(cos(angle), 0.0, sin(angle))
		away = away.normalized()
		var push: float = maxf(min_sp - nearest_d + 0.75, 1.25)
		var candidate := pos + away * push * float(_attempt + 1)
		candidate.y = pos.y
		if _spawn_is_valid(candidate):
			out = candidate
			out_yaw = _spawn_yaw_at(out, arena_origin)

	for ring in range(1, 10):
		var radius := min_sp * float(ring) * 0.4
		for i in 16:
			var angle := float(i) / 16.0 * TAU + yaw
			var candidate := pos + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
			candidate.y = pos.y
			if _min_distance(candidate, avoid) >= min_sp and _spawn_is_valid(candidate):
				return {"pos": candidate, "yaw": _spawn_yaw_at(candidate, arena_origin)}

	if _min_distance(out, avoid) >= min_sp and _spawn_is_valid(out):
		return {"pos": out, "yaw": out_yaw}
	return _lava_safe_spawn_fallback(yaw, avoid)


func _lava_safe_spawn_fallback(yaw: float, avoid: Array[Vector3]) -> Dictionary:
	var arena: Node = get_node_or_null("Arena")
	var arena_origin: Vector3 = (arena as Node3D).global_position if arena and arena is Node3D else Vector3.ZERO
	if arena and arena.has_method("get_lava_fallback_spawn_world"):
		var fb: Vector3 = arena.get_lava_fallback_spawn_world()
		if _spawn_is_valid(fb):
			var min_sp := _required_spawn_spacing(fb)
			if avoid.is_empty() or _min_distance(fb, avoid) >= min_sp:
				return {"pos": fb, "yaw": _spawn_yaw_at(fb, arena_origin)}
			if arena.has_method("get_lava_spawn_platform_at"):
				var platform: Dictionary = arena.get_lava_spawn_platform_at(fb)
				if not platform.is_empty():
					var slot: Dictionary = _pick_lava_platform_spawn(platform, avoid)
					if not slot.is_empty():
						return slot
	return {"pos": arena_origin + Vector3(0.0, 8.0, 0.0), "yaw": yaw}


func _spawn_yaw_at(pos: Vector3, arena_origin: Vector3) -> float:
	# Default: face the arena center. yaw is the body's rotation around Y;
	# at yaw=0 the player looks toward -Z, so atan2(dx, dz) gives the yaw
	# that turns -Z onto the (pos → center) → -Z direction.
	var dx: float = pos.x - arena_origin.x
	var dz: float = pos.z - arena_origin.z
	var center_yaw: float = atan2(dx, dz) if (dx * dx + dz * dz) > 0.01 else 0.0
	# If a wall blocks the center-facing direction within 3m, try perpendicular
	# yaws and finally a 180° flip. First non-blocked direction wins.
	var candidates: Array[float] = [
		center_yaw,
		center_yaw + PI * 0.5,
		center_yaw - PI * 0.5,
		center_yaw + PI,
	]
	for y in candidates:
		if not _wall_within(pos, y, 3.0):
			return y
	return center_yaw


func _wall_within(pos: Vector3, yaw: float, dist: float) -> bool:
	var fwd: Vector3 = Vector3(-sin(yaw), 0, -cos(yaw))
	var head: Vector3 = pos + Vector3(0, 1.6, 0)
	var to: Vector3 = head + fwd * dist
	var query := PhysicsRayQueryParameters3D.create(head, to, 1)
	var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(query)
	return not hit.is_empty()

func _spawn_is_clear(pos: Vector3) -> bool:
	var shape := CapsuleShape3D.new()
	shape.radius = SPAWN_CLEARANCE_RADIUS
	shape.height = SPAWN_CLEARANCE_HEIGHT
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(Basis.IDENTITY, pos)
	query.collision_mask = 1
	return get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty()


func _spawn_is_valid(pos: Vector3) -> bool:
	if not _spawn_is_clear(pos) or not _spawn_has_ground(pos):
		return false
	var arena: Node = get_node_or_null("Arena")
	if arena and arena.has_method("is_all_floor_lava") and arena.is_all_floor_lava():
		if arena.has_method("is_lava_spawn_safe") and not arena.is_lava_spawn_safe(pos):
			return false
	return true


# Cast a ray straight down from the spawn point — if nothing on layer 1
# (world geometry) catches it within ~12 m, this spawn is hanging over the
# floor hole or past the arena edge and the player would fall into the lava
# the instant they're respawned. Used to reject those spawns in _pick_spawn.
func _spawn_has_ground(pos: Vector3) -> bool:
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(pos + Vector3.UP * 0.2, pos + Vector3.DOWN * 20.0)
	query.collision_mask = 1
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return false
	var hit_pos: Vector3 = hit.get("position", pos)
	var normal: Vector3 = hit.get("normal", Vector3.UP)
	if normal.dot(Vector3.UP) < 0.65:
		return false
	var arena: Node = get_node_or_null("Arena")
	# Never at or below the lava surface — moat/edge maps aren't
	# "all floor lava" but their lava still burns spawners.
	if arena and arena.has_method("get_lava_surface_world_y") \
			and hit_pos.y <= float(arena.get_lava_surface_world_y()) + 0.25:
		return false
	if arena and arena.has_method("is_all_floor_lava") and arena.is_all_floor_lava():
		if arena.has_method("is_lava_spawn_safe"):
			if not arena.is_lava_spawn_safe(pos):
				return false
			if not arena.is_lava_spawn_safe(hit_pos + Vector3.UP * 0.9):
				return false
	return true

@rpc("authority", "call_local", "reliable")
func _do_spawn(
	id: int,
	pname: String,
	pos: Vector3,
	bot: bool = false,
	input_device: int = -1,
	split_local: bool = false,
	yaw: float = 0.0,
	appearance_seed: int = 0,
) -> void:
	if players_root.has_node(str(id)):
		return
	var p := PLAYER_SCENE.instantiate()
	p.name = str(id)
	p.player_id = id
	p.is_bot = bot
	p.player_name = pname
	p.appearance_seed = appearance_seed
	p.local_input_device = input_device
	p.split_screen_local = split_local
	p.set_multiplayer_authority(1 if (bot or split_local) else id)
	players_root.add_child(p, true)
	# global_position / rotation must be set after add_child — they require
	# being in-tree.
	p.global_position = pos
	p.rotation.y = yaw
	# Physics interpolation would otherwise smear the spawn across one frame
	# (interpolating from wherever the node was before the position write).
	p.reset_physics_interpolation()
	# Match the freshly-spawned player's flashlight to the active round modifier.
	if p.has_method("set_flashlight_active"):
		p.set_flashlight_active(current_round_modifier == "blackout")
	if id == multiplayer.get_unique_id():
		local_player = p
		# Push the saved mouse-sens slider value onto the freshly spawned
		# local player so first mouse-look frame already uses it.
		_apply_mouse_sens_to_local()
		# Attach the raytraced-audio listener under the local player's camera.
		# Only one listener should be in the scene at a time. Owner needs a
		# valid transform — the plugin reads owner.transform.basis.x for
		# ambient pan and crashes if it's null.
		var cam: Camera3D = p.get_node_or_null("Camera") as Camera3D
		if cam:
			var listener := RaytracedAudioListener.new()
			cam.add_child(listener)
			listener.owner = cam
		if not (_splitscreen and _splitscreen.is_enabled()):
			_ensure_render_player(id, p.local_input_device)
		# Joining clients that skipped the menu still need the one-time session warmup.
		if not multiplayer.is_server() and has_node("Arena"):
			ShaderWarmup.warmup_effect_shaders($Arena)
	if _splitscreen and _splitscreen.is_enabled() and split_local:
		# Manager owns the device→player_id map server-side; on clients we
		# just need the view layout refreshed so the new SubViewport appears.
		_splitscreen.update_views()

@rpc("authority", "call_local", "reliable")
func _despawn(id: int) -> void:
	var node := players_root.get_node_or_null(str(id))
	if node:
		node.queue_free()
	if id == multiplayer.get_unique_id():
		local_player = null
	_remove_render_player(id)

# -------------------- SINGLE-PLAYER BOT --------------------

func _spawn_bots(count: int, avoid: Array[Vector3] = []) -> void:
	if not multiplayer.is_server() or count <= 0:
		return
	var used: Array[Vector3] = avoid.duplicate()
	used.append_array(_current_player_positions())
	var spawned_any := false
	for _i in count:
		var pid := _next_bot_id()
		if pid == 0:
			continue
		var bot_name := _random_bot_name(pid)
		var appearance_seed := randi() & 0x7fffffff
		_bot_appearance_seeds[pid] = appearance_seed
		NetworkManager.players[pid] = bot_name
		round_wins[pid] = 0
		_ping_ms_by_player[pid] = -1
		var bot_pick := _pick_spawn(used)
		used.append(bot_pick["pos"])
		_do_spawn.rpc(pid, bot_name, bot_pick["pos"], true, -1, false, bot_pick["yaw"], appearance_seed)
		spawned_any = true
	if spawned_any:
		NetworkManager.player_list_changed.emit()
		_broadcast_scores.rpc(round_wins)
		if not is_coop_mode():
			_maybe_start_match()
		_refresh_bot_counter()


func _next_bot_id() -> int:
	for pid in range(BOT_ID_BASE, BOT_ID_LIMIT):
		if not NetworkManager.players.has(pid) and not players_root.has_node(str(pid)):
			return pid
	return 0


func _random_bot_name(pid: int) -> String:
	var prefix := BOT_NAME_PREFIXES[randi() % BOT_NAME_PREFIXES.size()]
	var suffix := BOT_NAME_SUFFIXES[randi() % BOT_NAME_SUFFIXES.size()]
	var serial := 10 + ((pid - BOT_ID_BASE + randi()) % 90)
	return "%s %s %02d" % [prefix, suffix, serial]


func _despawn_bot(pid: int) -> void:
	if not _is_bot_id(pid):
		return
	_despawn.rpc(pid)
	NetworkManager.players.erase(pid)
	round_wins.erase(pid)
	_ping_ms_by_player.erase(pid)
	_bot_appearance_seeds.erase(pid)
	pending_pick_cards_by_player.erase(pid)
	pending_pick_deadlines.erase(pid)
	completed_picks.erase(pid)
	eliminated_players.erase(pid)


func _despawn_one_bot() -> void:
	if not multiplayer.is_server():
		return
	var bot_ids := _bot_ids()
	if bot_ids.is_empty():
		return
	bot_ids.sort()
	_despawn_bot(int(bot_ids.back()))
	NetworkManager.player_list_changed.emit()
	_broadcast_scores.rpc(round_wins)
	_refresh_bot_counter()
	if NetworkManager.players.size() < 2:
		_set_game_state.rpc(State.WAITING)
		_hide_card_pick.rpc()
		_hide_rematch_overlay.rpc()

func _despawn_all_bots() -> void:
	var bot_ids := _bot_ids()
	if bot_ids.is_empty():
		return
	for pid in bot_ids:
		_despawn_bot(int(pid))
	NetworkManager.player_list_changed.emit()
	_broadcast_scores.rpc(round_wins)
	_refresh_bot_counter()
	if state == State.PICKING_CARD:
		_hide_card_pick.rpc()
	_hide_rematch_overlay.rpc()
	_set_game_state.rpc(State.WAITING)


func _clear_coop_enemies() -> void:
	var bot_ids := _bot_ids()
	if bot_ids.is_empty():
		return
	for pid in bot_ids:
		_despawn_bot(int(pid))
	NetworkManager.player_list_changed.emit()
	_broadcast_scores.rpc(round_wins)
	_refresh_bot_counter()


func _coop_enemy_count_for_wave(wave: int) -> int:
	var humans: int = maxi(1, _human_count())
	var count: int = COOP_BASE_ENEMIES + maxi(0, wave - 1) * COOP_ENEMIES_PER_WAVE
	count += max(0, humans - 1)
	return clampi(count, 1, COOP_MAX_ENEMIES)


func _ensure_coop_enemy_count() -> void:
	if not multiplayer.is_server() or not is_coop_mode():
		return
	var desired := _coop_enemy_count_for_wave(coop_wave)
	var current := _bot_ids().size()
	if current < desired:
		_spawn_bots(desired - current, _current_player_positions())
	elif current > desired:
		var ids := _bot_ids()
		ids.sort()
		for i in current - desired:
			_despawn_bot(int(ids.pop_back()))
		NetworkManager.player_list_changed.emit()
		_broadcast_scores.rpc(round_wins)
		_refresh_bot_counter()


func _begin_coop_enemy_wave() -> void:
	if not multiplayer.is_server() or not is_coop_mode():
		return
	_recent_coop_enemy_spawns.clear()
	_coop_enemy_spawn_queue = _coop_enemy_archetype_queue(coop_wave)
	_coop_enemy_spawn_timer = COOP_ENEMY_FIRST_SPAWN_DELAY if not _coop_enemy_spawn_queue.is_empty() else -1.0
	_coop_wave_enemy_total = _coop_enemy_spawn_queue.size()
	_coop_wave_kills = 0
	_set_coop_wave_progress.rpc(_coop_wave_kills, _coop_wave_enemy_total)
	_broadcast_scores.rpc(round_wins)

	# Announce the new wave with counts and types
	var counts := {}
	for arch in _coop_enemy_spawn_queue:
		counts[arch] = counts.get(arch, 0) + 1
	var parts: Array[String] = []
	for arch in ["grunt", "grenadier", "flat_fragger", "sniper", "demolition"]:
		if counts.has(arch):
			var display_name: String = arch
			match arch:
				"demolition":
					display_name = "bomber"
				"flat_fragger":
					display_name = "fragger"
			parts.append("%dx %s" % [counts[arch], display_name])
	for arch in counts:
		if not arch in ["grunt", "grenadier", "flat_fragger", "sniper", "demolition"]:
			parts.append("%dx %s" % [counts[arch], arch])
	
	var list_str := ", ".join(parts)
	var announcement := "WAVE %d\n%s" % [coop_wave, list_str]
	_announce.rpc(announcement, 3.0, 40)



func _update_coop_enemy_spawner(delta: float) -> void:
	if not is_coop_mode():
		return
	_tick_coop_enemy_incoming(delta)
	if not _coop_enemy_incoming.is_empty():
		return
	if _coop_enemy_spawn_queue.is_empty():
		return
	_coop_enemy_spawn_timer -= delta
	if _coop_enemy_spawn_timer > 0.0:
		return
	var archetype := str(_coop_enemy_spawn_queue.pop_front())
	_begin_coop_enemy_incoming(archetype)
	_coop_enemy_spawn_timer = COOP_ENEMY_SPAWN_INTERVAL


func _tick_coop_enemy_incoming(delta: float) -> void:
	if _coop_enemy_incoming.is_empty():
		return
	var timer: float = float(_coop_enemy_incoming.get("timer", 0.0)) - delta
	if timer > 0.0:
		_coop_enemy_incoming["timer"] = timer
		return
	var archetype := str(_coop_enemy_incoming.get("archetype", "grunt"))
	var ground_pos: Vector3 = _coop_enemy_incoming.get("pos", Vector3.ZERO)
	var spawn_yaw: float = float(_coop_enemy_incoming.get("yaw", 0.0))
	_coop_enemy_incoming = {}
	_spawn_coop_enemy(archetype, ground_pos, spawn_yaw)


func _begin_coop_enemy_incoming(archetype: String) -> void:
	if not multiplayer.is_server():
		return
	var pick := _pick_coop_enemy_spawn()
	var ground_pos: Vector3 = pick["pos"]
	var spawn_yaw: float = float(pick["yaw"])
	_telegraph_coop_enemy_spawn.rpc(ground_pos, archetype)
	_coop_enemy_incoming = {
		"archetype": archetype,
		"pos": ground_pos,
		"yaw": spawn_yaw,
		"timer": COOP_ENEMY_TELEGRAPH_SECONDS,
	}


@rpc("authority", "call_local", "reliable")
func _telegraph_coop_enemy_spawn(ground_pos: Vector3, archetype: String = "grunt") -> void:
	SFX.enemy_incoming(ground_pos)
	Violence.spawn_enemy_incoming_telegraph(
		self,
		ground_pos,
		COOP_ENEMY_TELEGRAPH_WARMUP,
		PLAYER_SCRIPT.coop_enemy_pentagram_star_radius(archetype),
		PLAYER_SCRIPT.coop_enemy_pentagram_beam_height(archetype),
	)


func _standing_human_positions() -> Array[Vector3]:
	var out: Array[Vector3] = []
	for pid in _standing_human_ids():
		var p := players_root.get_node_or_null(str(pid))
		if p and is_instance_valid(p):
			out.append((p as Node3D).global_position)
	return out


# Wave-enemy spawn: sample random GROUND points in a ring around a chosen
# human instead of reusing the handful of fixed spawnpoints. Candidates must
# be flat, lava-free, ground-level (no rooftops / side towers — demons rise
# from the dirt) and never within COOP_ENEMY_SPAWN_MIN_FROM_PLAYER of anyone.
# Recent spawn sites are remembered and scored against, so a wave pours in
# from many directions instead of farming one pentagram spot.
func _pick_coop_enemy_spawn() -> Dictionary:
	var humans := _standing_human_positions()
	var avoid := _current_player_positions()
	# Ring around a hunted human; with nobody standing (mid-descent, all
	# downed) sample a wide ring around the arena center instead — still
	# validated ground, not fixed rooftop spawnpoints.
	var target: Vector3
	var ring_min := COOP_ENEMY_SPAWN_MIN_FROM_TARGET
	var ring_max := COOP_ENEMY_SPAWN_MAX_FROM_TARGET
	if humans.is_empty():
		var arena: Node = get_node_or_null("Arena")
		target = (arena as Node3D).global_position if arena and arena is Node3D else Vector3.ZERO
		ring_min = 4.0
		ring_max = COOP_ENEMY_SPAWN_MAX_FROM_TARGET * 1.4
	else:
		target = humans[randi() % humans.size()]

	var best_pos := Vector3.INF
	var best_score: float = -INF
	for _i in 48:
		var ang := randf() * TAU
		var dist := randf_range(ring_min, ring_max)
		var ground := _coop_ground_spawn_at(target + Vector3(cos(ang) * dist, 0.0, sin(ang) * dist))
		if not ground.is_finite():
			continue
		if _min_distance(ground, avoid) < COOP_ENEMY_SPAWN_MIN_FROM_PLAYER:
			continue
		var spread: float = 30.0
		if not _recent_coop_enemy_spawns.is_empty():
			spread = minf(_min_distance(ground, _recent_coop_enemy_spawns), 30.0)
		var score: float = spread + randf_range(0.0, 4.0)
		if score > best_score:
			best_score = score
			best_pos = ground
	if not best_pos.is_finite():
		# Nothing sampled cleanly (tiny platform maps) — fixed spawnpoints,
		# still respecting spacing from players.
		var pick := _pick_spawn(avoid)
		best_pos = pick["pos"]
	_recent_coop_enemy_spawns.append(best_pos)
	while _recent_coop_enemy_spawns.size() > COOP_ENEMY_SPAWN_MEMORY:
		_recent_coop_enemy_spawns.pop_front()
	# Rise facing the hunted player.
	var yaw := atan2(-(target.x - best_pos.x), -(target.z - best_pos.z))
	return {"pos": best_pos, "yaw": yaw}


# Ray-validated ground point for a wave emerge; Vector3.INF when unusable.
func _coop_ground_spawn_at(probe: Vector3) -> Vector3:
	var arena: Node = get_node_or_null("Arena")
	var arena_y: float = (arena as Node3D).global_position.y if arena and arena is Node3D else 0.0
	var from := Vector3(probe.x, probe.y + 14.0, probe.z)
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 40.0, 1)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return Vector3.INF
	var normal: Vector3 = hit.get("normal", Vector3.UP)
	if normal.dot(Vector3.UP) < 0.75:
		return Vector3.INF
	var ground: Vector3 = hit.get("position", probe)
	var all_lava: bool = arena and arena.has_method("is_all_floor_lava") and arena.is_all_floor_lava()
	# Rooftops and towers are not emerge sites. Lava maps skip the height
	# cap — their platforms ARE the ground.
	if not all_lava and ground.y - arena_y > COOP_ENEMY_SPAWN_MAX_GROUND_HEIGHT:
		return Vector3.INF
	if arena and arena.has_method("get_lava_surface_world_y") \
			and ground.y <= float(arena.get_lava_surface_world_y()) + 0.25:
		return Vector3.INF
	# 1.7 up: the 2m clearance capsule's bottom floats 0.7 above the floor —
	# at +1.0 it grazed the ground and every sample read as "blocked".
	var pos := ground + Vector3.UP * 1.7
	if all_lava and arena.has_method("is_lava_spawn_safe") and not arena.is_lava_spawn_safe(pos):
		return Vector3.INF
	if not _spawn_is_clear(pos):
		return Vector3.INF
	return pos


func _spawn_coop_enemy(archetype: String, ground_pos: Vector3, spawn_yaw: float) -> void:
	var pid := _next_bot_id()
	if pid == 0:
		return
	var enemy_name := _coop_enemy_name(archetype, pid)
	var appearance_seed := randi() & 0x7fffffff
	_bot_appearance_seeds[pid] = appearance_seed
	NetworkManager.players[pid] = enemy_name
	round_wins[pid] = 0
	_ping_ms_by_player[pid] = -1
	var half_h := PLAYER_SCRIPT.coop_enemy_hell_emerge_half_height(archetype)
	var depth := PLAYER_SCRIPT.coop_enemy_hell_emerge_depth(archetype)
	var stand := Violence.hell_emerge_stand_pos(self, ground_pos, half_h)
	var bury_pos: Vector3 = stand - Vector3.UP * depth
	_do_spawn.rpc(pid, enemy_name, bury_pos, true, -1, false, spawn_yaw, appearance_seed)
	var p := players_root.get_node_or_null(str(pid))
	if p:
		p.apply_enemy_archetype.rpc(archetype, coop_wave)
		_apply_coop_spawn_health(p)
		p.begin_hell_emerge.rpc(stand, Time.get_ticks_msec(), depth)
	NetworkManager.player_list_changed.emit()
	_broadcast_scores.rpc(round_wins)
	_refresh_bot_counter()


func _coop_enemy_archetype_queue(wave: int) -> Array[String]:
	var total := _coop_enemy_count_for_wave(wave)
	var out: Array[String] = []
	for i in total:
		out.append(_pick_coop_enemy_archetype(wave, i))
	return out


func _pick_coop_enemy_archetype(wave: int, index: int) -> String:
	if wave >= 8 and index == 0:
		return "demolition"
	if wave >= 6 and index % 6 == 0:
		return "grenadier"
	if wave >= 5 and index % 5 == 0:
		return "sniper"
	if wave >= 4 and index % 4 == 0:
		return "flat_fragger"
	if wave >= 7 and randf() < 0.22:
		return "demolition"
	if wave >= 5 and randf() < 0.18:
		return "grenadier"
	if wave >= 4 and randf() < 0.24:
		return "sniper"
	if wave >= 3 and randf() < 0.2:
		return "flat_fragger"
	return "grunt"


func _coop_enemy_name(archetype: String, pid: int) -> String:
	var slot := pid - BOT_ID_BASE + 1
	match archetype:
		"sniper":
			return "SNIPER %02d" % slot
		"demolition":
			return "BOMBER %02d" % slot
		"grenadier":
			return "GRENADIER %02d" % slot
		"flat_fragger":
			return "FRAGGER %02d" % slot
		_:
			return "GRUNT %02d" % slot


func _update_ping_monitor(delta: float) -> void:
	if multiplayer.is_server():
		_ping_probe_timer -= delta
		if _ping_probe_timer <= 0.0:
			_ping_probe_timer = PING_PROBE_INTERVAL
			_send_ping_probes()
	_prune_stale_pings()
	_update_high_ping_warning(delta)


func _send_ping_probes() -> void:
	var now := Time.get_ticks_msec()
	_ping_ms_by_player[1] = 0
	var peers := multiplayer.get_peers()
	for raw_id in NetworkManager.players:
		var peer_id := int(raw_id)
		# Bots and splitscreen guests share the host's process: no peer to ping.
		if peer_id == 1 or not peers.has(peer_id):
			continue
		_ping_seq += 1
		_ping_pending[_ping_seq] = {"peer": peer_id, "sent_ms": now}
		_ping_probe.rpc_id(peer_id, _ping_seq, now)
	_broadcast_ping_ms.rpc(_ping_ms_by_player)


func _prune_stale_pings() -> void:
	var now := Time.get_ticks_msec()
	var changed := false
	for seq in _ping_pending.keys():
		var pending: Dictionary = _ping_pending[seq]
		if now - int(pending.get("sent_ms", now)) > PING_STALE_AFTER_MS:
			var peer_id := int(pending.get("peer", 0))
			if peer_id != 0:
				_ping_ms_by_player[peer_id] = -1
				changed = true
			_ping_pending.erase(seq)
	if changed and multiplayer.is_server():
		_broadcast_ping_ms.rpc(_ping_ms_by_player)


func _update_high_ping_warning(delta: float) -> void:
	if state != State.PLAYING:
		return
	_high_ping_warn_timer = maxf(0.0, _high_ping_warn_timer - delta)
	var my_id := multiplayer.get_unique_id()
	var ping := int(_ping_ms_by_player.get(my_id, 0))
	if my_id == 1:
		var worst := 0
		for raw_id in _ping_ms_by_player:
			worst = max(worst, int(_ping_ms_by_player[raw_id]))
		ping = worst
	if ping < HIGH_PING_WARN_MS or _high_ping_warn_timer > 0.0:
		return
	_high_ping_warn_timer = HIGH_PING_WARN_INTERVAL
	_on_network_status_changed("HIGH PING: %d ms" % ping, false)


@rpc("authority", "call_local", "unreliable")
func _ping_probe(seq: int, sent_ms: int) -> void:
	if multiplayer.is_server():
		return
	_ping_reply.rpc_id(1, seq, sent_ms)


@rpc("any_peer", "unreliable")
func _ping_reply(seq: int, sent_ms: int) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		return
	var pending: Dictionary = _ping_pending.get(seq, {})
	if int(pending.get("peer", 0)) != sender:
		return
	_ping_pending.erase(seq)
	_ping_ms_by_player[sender] = max(0, Time.get_ticks_msec() - sent_ms)
	_broadcast_ping_ms.rpc(_ping_ms_by_player)


@rpc("authority", "call_local", "unreliable")
func _broadcast_ping_ms(pings: Dictionary) -> void:
	_ping_ms_by_player = pings.duplicate()

# -------------------- ROUND FLOW --------------------

@rpc("authority", "call_local", "reliable")
func _set_game_state(new_state: int) -> void:
	# Client-side breadcrumb: state changes land in every peer's log file, so
	# a frozen/crashed client's godot.log shows where its round flow stopped.
	Trace.mark("state -> %d (round %d, wave %d)" % [new_state, current_round, coop_wave])
	state = new_state


@rpc("authority", "call_local", "reliable")
func _set_game_mode(mode: String, wave: int = 1) -> void:
	game_mode = GAME_MODE_COOP if mode == GAME_MODE_COOP else GAME_MODE_VERSUS
	coop_wave = max(1, wave)
	current_round = coop_wave if is_coop_mode() else current_round
	_update_scoreboard()


@rpc("authority", "call_local", "reliable")
func _set_coop_wave_progress(kills: int, total: int) -> void:
	_coop_wave_kills = max(0, kills)
	_coop_wave_enemy_total = max(0, total)
	_update_scoreboard()


func _maybe_start_match() -> void:
	if not _gamenight_start_gate_open:
		return
	if not multiplayer.is_server():
		return
	if state != State.WAITING:
		return
	if is_coop_mode():
		if _human_count() < 1:
			_set_music_energy.rpc(1)
			return
		_despawn_all_bots()
	elif NetworkManager.players.size() < 2:
		_set_music_energy.rpc(1)
		return
	if GameNight.launched_by_daemon:
		GameNightBridge.settings.apply_match(self)
	_set_game_state.rpc(State.PLAYING)
	current_round = 1
	coop_wave = 1
	_set_game_mode.rpc(game_mode, coop_wave)
	_music_track_started_ms = 0  # fresh soundtrack each match
	_reset_round_tracking()
	for pid in NetworkManager.players:
		var p := players_root.get_node_or_null(str(pid))
		if p:
			p.reset_weapon.rpc()
	_start_round_flashed()


## Called by GameNightBridge when the daemon's `start` message arrives.
## Opens the gate _maybe_start_match() checks first, then re-runs it so
## whichever of its normal callers already fired (bots spawning, _ready,
## etc.) can finally take effect.
func _open_gamenight_start_gate() -> void:
	_gamenight_start_gate_open = true
	_maybe_start_match()

func get_gravity_mult() -> float:
	return gamenight_rules.scale("gravity", ROUND_MODIFIERS_SCRIPT.gravity_mult(current_round_modifier))


func get_bullet_drop_mult() -> float:
	return gamenight_rules.scale("bullet_drop", ROUND_MODIFIERS_SCRIPT.bullet_drop_mult(current_round_modifier))


func get_body_damage_mult() -> float:
	return gamenight_rules.scale("body_damage", ROUND_MODIFIERS_SCRIPT.body_damage_mult(current_round_modifier))


func get_pickup_spawn_mult() -> float:
	return gamenight_rules.scale("pickup_rate", ROUND_MODIFIERS_SCRIPT.pickup_spawn_mult(current_round_modifier))


func _apply_gun_swap(round_players: Array[Node]) -> void:
	if round_players.size() < 2:
		return
	var card_sets: Array = []
	for p in round_players:
		card_sets.append(p._owned_cards.duplicate())
	var order := _gun_swap_permutation(round_players.size())
	for i in round_players.size():
		round_players[i].apply_swapped_cards.rpc(card_sets[order[i]])


func _gun_swap_permutation(n: int) -> Array[int]:
	var order: Array[int] = []
	for i in n:
		order.append(i)
	order.shuffle()
	for i in n:
		if order[i] != i:
			return order
	var rotated: Array[int] = []
	for i in n:
		rotated.append((i + 1) % n)
	return rotated


func _start_round_now() -> void:
	Trace.mark("_start_round_now (round %d)" % current_round)
	Trace.span_begin("_start_round_now total")
	if multiplayer.is_server() and GameNight.launched_by_daemon: GameNightBridge.settings.apply_round(self)
	_reset_round_tracking()
	if multiplayer.is_server() and is_coop_mode():
		_clear_coop_enemies()
	_round_damage_seen = false
	_hide_round_win_on_screens.rpc()
	if multiplayer.is_server():
		# A modifier forced via the dev menu sticks across rounds; otherwise roll.
		# In coop/wave mode, we do not use round modifiers (map variants).
		var mod := ""
		if not is_coop_mode():
			var chance: float = GameNightBridge.settings.modifier_chance() if GameNight.launched_by_daemon else ROUND_MODIFIERS_SCRIPT.MODIFIER_CHANCE
			mod = _forced_round_modifier if _force_round_modifier else ROUND_MODIFIERS_SCRIPT.pick_for_round(chance)
		_set_round_modifier.rpc(mod)
	# Round opens at "low" — the track plays calmly until the first shot.
	# Shooting bumps to mid, taking damage bumps to high.
	_round_music_level = 1
	_round_elapsed = 0.0
	_lava_leak_started = false
	# Only swap the track at this round boundary if the current one has played
	# for MUSIC_MIN_TRACK_SECONDS (or none has started yet). Otherwise the same
	# track carries over into the new round — switching happens "after 2 minutes
	# AND at the end of a round", not every round.
	var now_ms := Time.get_ticks_msec()
	var track_age_s := (now_ms - _music_track_started_ms) / 1000.0
	if _music_track_started_ms == 0 or track_age_s >= MUSIC_MIN_TRACK_SECONDS:
		# New track: cross-fade to the next loop set and hard-snap to calm — a
		# clean "fresh song" moment is fine here.
		_music_track_started_ms = now_ms
		var music_seed := randi()
		_set_music_track.rpc(music_seed, current_round)
		_rebake_music.rpc()
		_set_music_energy.rpc(1, true)
	else:
		# Same track carries over: no rebake (no retire-fade), and ease energy
		# back to calm on the next BAR instead of snapping immediately — so the
		# round transition flows and stays beat-synced, like a change mid-round.
		_set_music_energy.rpc(1, false)
	# Pick a random map for this round and broadcast the swap to all peers
	# before respawning, so _pick_spawn() reads the new arena's spawn
	# points (the call_local RPC runs the swap synchronously here too).
	if multiplayer.is_server() and MAP_POOL.size() >= 1:
		# Always swap so the procedural arena gets a fresh seed each round
		# (with a single-entry pool, the index is always 0).
		var arena_size := ROUND_MODIFIERS_SCRIPT.arena_size_range(current_round_modifier)
		_swap_arena.rpc(randi() % MAP_POOL.size(), randi(), arena_size.x, arena_size.y)
	# Respawn everyone, reset HP + cooldowns, unfreeze, announce.
	# Track already-assigned spawn positions so nobody lands on top of another.
	# The first pick anchors the height target so subsequent picks land near
	# the same elevation.
	var used: Array[Vector3] = []
	var round_players: Array[Node] = []
	for pid in NetworkManager.players:
		var p := players_root.get_node_or_null(str(pid))
		if not p:
			continue
		round_players.append(p)
		p.rebuild_weapon_from_cards.rpc()
	if multiplayer.is_server() and ROUND_MODIFIERS_SCRIPT.needs_gun_swap(current_round_modifier):
		_apply_gun_swap(round_players)
	for p in round_players:
		if ROUND_MODIFIERS_SCRIPT.applies_weapon(current_round_modifier):
			p.apply_round_modifier_weapon.rpc(current_round_modifier)
	# Stop any leftover revive sky-drops before picking fresh round spawns.
	for p in round_players:
		p.set_launching.rpc(false)
	for p in round_players:
		var pick := _pick_spawn(used)
		used.append(pick["pos"])
		p.set_ghost_mode.rpc(false)
		# Cage-spawn: the player starts frozen in a gladiator cage high over
		# the landing spot; a crane lowers it while the card-growth morph
		# plays, and _process opens every trapdoor together as soon as the
		# descent settles, dropping the fighters into the fight.
		var drop := _sky_drop_spawn(pick["pos"], int(p.get("player_id")), used, CAGE_SPAWN_HEIGHT)
		p.server_respawn.rpc(drop["pos"], drop["yaw"])
		_apply_coop_spawn_health(p)
		# Clear any leftover freeze (e.g. losers were frozen during card-pick
		# at the end of the previous round) before kicking off the launch —
		# otherwise the player lands and can't move.
		p.set_frozen.rpc(false)
		p.clear_ragdoll.rpc()
	_clear_projectiles.rpc()
	_clear_combat_vfx.rpc()
	_clear_pickups.rpc()
	_clear_air_strike_markers.rpc()
	_clear_ion_cannon_markers.rpc()
	if multiplayer.is_server() and ROUND_MODIFIERS_SCRIPT.spawn_starting_pickup(current_round_modifier):
		var kind: String = PICKUP_ITEM_SCRIPT.KINDS[randi() % PICKUP_ITEM_SCRIPT.KINDS.size()]
		_spawn_pickup_on_server(kind, _random_pickup_spawn_pos())
	_show_round_modifier_on_screens.rpc()
	if multiplayer.is_server() and ROUND_MODIFIERS_SCRIPT.lava_immediate(current_round_modifier):
		_trigger_lava_leak(LAVA_LEAK_SPREAD_SECONDS)
	_hide_rematch_overlay.rpc()
	Trace.span_begin("_warmup_round_audio")
	_warmup_round_audio()
	Trace.span_end("_warmup_round_audio")
	# Cage the fighters. Cranes lower everyone in; floors open together the
	# moment the descent settles (small buffer so the tweens have landed).
	for p in round_players:
		p.enter_spawn_cage.rpc(CAGE_SPAWN_HEIGHT - CAGE_DROP_HEIGHT, CAGE_DESCEND_SECONDS)
	_cage_release_timer = CAGE_DESCEND_SECONDS + 0.15
	if multiplayer.is_server() and is_coop_mode():
		_begin_coop_enemy_wave()
	if multiplayer.is_server() and ROUND_MODIFIERS_SCRIPT.needs_air_strikes(current_round_modifier):
		_air_strikes_armed = true
		_air_strike_timer = randf_range(0.5, 1.25)
	if multiplayer.is_server() and ROUND_MODIFIERS_SCRIPT.needs_ion_cannon(current_round_modifier):
		_ion_cannons_armed = true
		_ion_cannon_timer = randf_range(0.75, 1.5)
	Trace.span_end("_start_round_now total")
	Trace.mark("round %d PLAYING — players launched" % current_round)


func coop_human_max_health(weapon: Weapon) -> int:
	var base_health := 100
	if weapon != null:
		base_health += int(weapon.max_hp_bonus)
	return maxi(1, int(ceil(float(base_health) * COOP_PLAYER_HEALTH_MULT)))


func _apply_coop_spawn_health(p: Node) -> void:
	if not is_coop_mode() or p == null or not p.has_method("set_spawn_health"):
		return
	var pid := int(p.get("player_id"))
	var weapon: Weapon = p.get("weapon") as Weapon
	if _is_bot_id(pid):
		var base_health := 100
		if weapon != null:
			base_health += int(weapon.max_hp_bonus)
		p.set_spawn_health.rpc(maxi(1, int(ceil(float(base_health) * COOP_ENEMY_HEALTH_MULT))))
	else:
		p.set_spawn_health.rpc(coop_human_max_health(weapon))

func _update_air_strikes(delta: float) -> void:
	if not _air_strikes_armed or not ROUND_MODIFIERS_SCRIPT.needs_air_strikes(current_round_modifier):
		return
	if _air_strike_pending:
		return
	_air_strike_timer -= delta
	if _air_strike_timer > 0.0:
		return
	var target := _random_air_strike_target()
	var sky_from := _air_strike_sky_from(target)
	_begin_air_strike(sky_from, target)


func _begin_air_strike(sky_from: Vector3, target: Vector3, shooter_id: int = 0) -> void:
	if _air_strike_pending:
		return
	_air_strike_pending = true
	_air_strike_launch.rpc(sky_from, target, shooter_id)


func _air_strike_finished() -> void:
	if not multiplayer.is_server():
		return
	_air_strike_pending = false
	if not _air_strikes_armed or not ROUND_MODIFIERS_SCRIPT.needs_air_strikes(current_round_modifier):
		return
	_air_strike_timer = AIR_STRIKE_INTERVAL + randf_range(-AIR_STRIKE_INTERVAL_JITTER, AIR_STRIKE_INTERVAL_JITTER)


func _update_ion_cannons(delta: float) -> void:
	if not _ion_cannons_armed or not ROUND_MODIFIERS_SCRIPT.needs_ion_cannon(current_round_modifier):
		return
	if _ion_cannon_pending:
		return
	_ion_cannon_timer -= delta
	if _ion_cannon_timer > 0.0:
		return
	var target := _random_air_strike_target()
	_begin_ion_cannon(target)


func _begin_ion_cannon(target: Vector3, shooter_id: int = 0) -> void:
	if _ion_cannon_pending:
		return
	_ion_cannon_pending = true
	_ion_cannon_launch.rpc(target, shooter_id)


func _ion_cannon_finished() -> void:
	if not multiplayer.is_server():
		return
	_ion_cannon_pending = false
	if not _ion_cannons_armed or not ROUND_MODIFIERS_SCRIPT.needs_ion_cannon(current_round_modifier):
		return
	_ion_cannon_timer = ION_CANNON_INTERVAL + randf_range(-ION_CANNON_INTERVAL_JITTER, ION_CANNON_INTERVAL_JITTER)


func _random_air_strike_target() -> Vector3:
	# Pick random arena XZ, then raycast from the sky — not pickup height (~52 m).
	const RAY_TOP := 320.0
	const RAY_DEPTH := 420.0
	const MAX_TRIES := 14
	var space := get_world_3d().direct_space_state
	if space == null:
		return _random_arena_xz() + Vector3.UP * 0.05
	for _i in MAX_TRIES:
		var base := _random_arena_xz()
		var top := base + Vector3.UP * RAY_TOP
		var bottom := base - Vector3.UP * RAY_DEPTH
		var query := PhysicsRayQueryParameters3D.create(top, bottom, 1)
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			continue
		var normal: Vector3 = hit.get("normal", Vector3.UP)
		if normal.dot(Vector3.UP) < 0.55:
			continue
		return hit.get("position", base) + Vector3.UP * 0.05
	return _random_arena_xz() + Vector3.UP * 0.05


func _random_arena_xz() -> Vector3:
	var origin := ARENA_OFFSET
	var half := 32.0
	var arena: Node = get_node_or_null("Arena")
	if arena:
		origin = (arena as Node3D).global_position
		var gen: Node = arena.get_node_or_null("Generator")
		if gen:
			half = maxf(14.0, float(gen.get("arena_size")) * 0.5 - 6.0)
	var margin := 4.0
	var x := randf_range(-half + margin, half - margin)
	var z := randf_range(-half + margin, half - margin)
	return origin + Vector3(x, 0.0, z)


func _air_strike_sky_from(target: Vector3) -> Vector3:
	# Fixed spawn ring: same height + horizontal offset at each cardinal, pick
	# the first direction with clear LOS to the target.
	const CARDINALS: Array[Vector3] = [
		Vector3(1.0, 0.0, 0.0),
		Vector3(-1.0, 0.0, 0.0),
		Vector3(0.0, 0.0, 1.0),
		Vector3(0.0, 0.0, -1.0),
		Vector3(0.7071068, 0.0, 0.7071068),
		Vector3(-0.7071068, 0.0, 0.7071068),
		Vector3(0.7071068, 0.0, -0.7071068),
		Vector3(-0.7071068, 0.0, -0.7071068),
	]
	for dir in CARDINALS:
		var sky := _air_strike_sky_candidate(target, dir)
		if _air_strike_sky_path_clear(sky, target):
			return sky
	return _air_strike_sky_candidate(target, Vector3(0.0, 0.0, 1.0))


func _air_strike_sky_candidate(target: Vector3, horiz_dir: Vector3) -> Vector3:
	return target + horiz_dir * AIR_STRIKE_SPAWN_HORIZ + Vector3.UP * AIR_STRIKE_SPAWN_HEIGHT


func _air_strike_sky_path_clear(sky_from: Vector3, target: Vector3) -> bool:
	var space := get_world_3d().direct_space_state
	if space == null:
		return true
	var aim := target + Vector3.UP * 0.25
	if not _air_strike_ray_clear(space, sky_from, aim):
		return false
	# Second pass: offset rays so wide rocket body doesn't clip a ledge/corner.
	var dir := (aim - sky_from).normalized()
	if dir.length_squared() < 0.0001:
		return true
	var side := dir.cross(Vector3.UP)
	if side.length_squared() < 0.0001:
		side = Vector3.RIGHT
	else:
		side = side.normalized()
	var offset := side * 0.45
	return _air_strike_ray_clear(space, sky_from + offset, aim + offset * 0.35)


func _air_strike_ray_clear(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3) -> bool:
	var query := PhysicsRayQueryParameters3D.create(from, to, 1)
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return true
	var hit_pos: Vector3 = hit.get("position", from)
	return hit_pos.distance_to(to) < 2.5


func _air_strike_fx_root() -> Node3D:
	return _pickups_root if _pickups_root else self


@rpc("authority", "call_local", "reliable")
func _air_strike_launch(sky_from: Vector3, target: Vector3, shooter_id: int = 0) -> void:
	if state != State.PLAYING:
		push_warning("AirStrike: launch ignored — game state is %d (expected PLAYING)" % int(state))
		if multiplayer.is_server():
			_air_strike_pending = false
		return
	var fx_scene := $Arena if has_node("Arena") else self
	if fx_scene == null or not is_instance_valid(fx_scene):
		push_error("AirStrike: fx root is null/invalid — cannot spawn laser or blast FX")
		if multiplayer.is_server():
			_air_strike_pending = false
		return
	var marker := AIR_STRIKE_SCRIPT.new()
	if marker == null:
		push_error("AirStrike: failed to instantiate AirStrikeMarker")
		if multiplayer.is_server():
			_air_strike_pending = false
		return
	marker.name = "AirStrikeMarker"
	fx_scene.add_child(marker)
	marker.setup(
		fx_scene,
		sky_from,
		target,
		shooter_id,
		self,
		multiplayer.is_server(),
	)
	if not is_instance_valid(marker) or not marker.is_inside_tree():
		push_error("AirStrike: marker removed itself during setup — see prior AirStrike.* errors")
		if multiplayer.is_server():
			_air_strike_pending = false


func _apply_environment_explosion(pos: Vector3, radius: float, damage: float, shooter_id: int = 0) -> void:
	if players_root.get_child_count() == 0:
		return
	var anchor := players_root.get_child(0)
	if anchor and anchor.has_method("_apply_air_strike_splash"):
		anchor.call("_apply_air_strike_splash", pos + Vector3.UP * 0.1, radius, damage, shooter_id)


func _apply_ion_cannon_explosion(pos: Vector3, radius: float, damage: float, shooter_id: int = 0) -> void:
	if players_root.get_child_count() == 0:
		return
	var bounds: Dictionary = ION_CANNON_SCRIPT.damage_column_bounds(self, pos)
	var anchor := players_root.get_child(0)
	if anchor and anchor.has_method("_apply_ion_cannon_splash"):
		anchor.call(
			"_apply_ion_cannon_splash",
			pos,
			radius,
			damage,
			shooter_id,
			float(bounds.bottom_y),
			float(bounds.top_y),
		)


@rpc("authority", "call_local", "reliable")
func _clear_air_strike_markers() -> void:
	for node in get_tree().get_nodes_in_group("air_strike_markers"):
		if is_instance_valid(node):
			node.queue_free()
	for node in get_tree().get_nodes_in_group("air_strike_rockets"):
		if is_instance_valid(node):
			node.queue_free()


@rpc("authority", "call_local", "reliable")
func _ion_cannon_launch(target: Vector3, shooter_id: int = 0) -> void:
	if state != State.PLAYING:
		return
	var marker := ION_CANNON_SCRIPT.new()
	marker.name = "IonCannonMarker"
	var fx_scene := get_tree().current_scene
	_air_strike_fx_root().add_child(marker)
	marker.setup(fx_scene, target, shooter_id, self, multiplayer.is_server())


@rpc("authority", "call_local", "reliable")
func _clear_ion_cannon_markers() -> void:
	for node in get_tree().get_nodes_in_group("ion_cannon_markers"):
		if is_instance_valid(node):
			node.queue_free()
	for node in get_tree().get_nodes_in_group("ion_cannon_motes"):
		if is_instance_valid(node):
			node.queue_free()

func _update_lava_leak(delta: float) -> void:
	if is_coop_mode():
		return
	if _lava_leak_started:
		return
	_round_elapsed += delta
	if _round_elapsed < LAVA_LEAK_START_SECONDS:
		return
	_trigger_lava_leak(LAVA_LEAK_SPREAD_SECONDS)


func _trigger_lava_leak(spread_seconds: float) -> void:
	if not multiplayer.is_server() or _lava_leak_started or is_coop_mode():
		return
	var start_ms := Time.get_ticks_msec()
	_lava_leak_started = true
	_lava_leak_start_ms = start_ms
	_lava_leak_spread_seconds = spread_seconds
	_start_lava_leak.rpc(spread_seconds, start_ms)


@rpc("authority", "call_local", "reliable")
func _start_lava_leak(spread_seconds: float, start_ms: int = 0) -> void:
	if start_ms <= 0:
		start_ms = Time.get_ticks_msec()
	_lava_leak_started = true
	var elapsed := maxf(0.0, (Time.get_ticks_msec() - start_ms) / 1000.0)
	var arena := get_node_or_null("Arena")
	if arena and arena.has_method("start_lava_leak"):
		arena.start_lava_leak(spread_seconds, elapsed)
	if elapsed <= 0.05:
		_announce("LAVA LEAK", 1.5)

@rpc("authority", "call_local", "reliable")
func _stop_lava_leak() -> void:
	var arena := get_node_or_null("Arena")
	if arena and arena.has_method("stop_lava_leak"):
		arena.stop_lava_leak()

@rpc("authority", "call_local", "reliable")
func _set_music_energy(level: int, immediate: bool = false, next_bar: bool = false) -> void:
	if level > 0:
		_round_music_level = level
	if MenuHelpers.music_db <= MenuHelpers.MUSIC_DB_MIN + 0.5:
		ProceduralMusic.set_energy(0, true)
		return
	ProceduralMusic.set_energy(level, immediate, next_bar)

@rpc("authority", "call_local", "reliable")
func _set_music_track(seed: int, round_index: int) -> void:
	ProceduralMusic.generate_track(seed, round_index)

@rpc("authority", "call_local", "reliable")
func _rebake_music() -> void:
	if ProceduralMusic.has_method("rebake"):
		ProceduralMusic.rebake()

@rpc("any_peer", "call_local", "reliable")
func _report_player_damage(victim_id: int, attacker_id: int, amount: int, victim_health: int) -> void:
	if not multiplayer.is_server():
		return
	if state != State.PLAYING:
		return
	if amount <= 0 or attacker_id == victim_id:
		return
	_round_damage_seen = true
	# Damage = "high" — a player got hit.
	if _round_music_level < 3:
		_set_round_music_level(3)
	_update_round_music_phase()

func _update_round_music_phase() -> void:
	# Already at high on damage; the late-round low-HP heuristic just keeps it
	# locked there (no extra escalation tier above 3 in the new mapping).
	if _round_music_level >= 3:
		return
	if not _late_round_music_condition():
		return
	_set_round_music_level(3)

func _late_round_music_condition() -> bool:
	var alive := _alive_player_ids()
	if alive.size() != 2:
		return false
	for pid in alive:
		var p := players_root.get_node_or_null(str(pid))
		if not p:
			continue
		var hp := int(p.get("health"))
		var max_hp := 100
		var w = p.get("weapon")
		if w != null:
			max_hp += int(w.max_hp_bonus)
		if hp > 0 and hp <= int(ceil(float(max_hp) * 0.5)):
			return true
	return false

# Plain shooting no longer escalates music on its own — the player has to
# actually get a bullet near someone (→ mid via _on_player_near_miss) or
# land a hit (→ high via _report_player_damage). Kept as a no-op so the
# call from player._rifle_fired stays valid; remove the call entirely if
# you want to drop the hook.
func _on_player_shot() -> void:
	pass


# Server-only state for _update_music_muffle_broadcast — last value sent so
# we don't hammer the RPC every frame.
var _last_music_muffle_broadcast: bool = false


# Server-side: every frame, decide whether the card-pick low-pass should be
# engaged for *every* peer, then RPC the new state if it changed. Triggered
# whenever fewer than 2 players are alive and the round has actually moved
# into card-pick — so a peer without a local card pick UI still hears the
# muffle. While 2+ players are alive (the round is still being played out
# even if someone died), the muffle stays off.
func _update_music_muffle_broadcast() -> void:
	var muffle_on: bool = state == State.PICKING_CARD and _alive_player_ids().size() < 2
	if muffle_on == _last_music_muffle_broadcast:
		return
	_last_music_muffle_broadcast = muffle_on
	_set_music_muffle.rpc(muffle_on)


# Receives the broadcast on every peer (call_local also runs it on the
# server). ProceduralMusic owns the actual fade-in/fade-out timing.
@rpc("authority", "call_local", "reliable")
func _set_music_muffle(active: bool) -> void:
	if ProceduralMusic.has_method("set_muffle"):
		ProceduralMusic.set_muffle(active)


# Bullet's near-miss zip — fired locally on whichever peer's camera the
# bullet whizzed past, then RPC'd to the server (`rpc_id(1, ...)`) so the
# server can drive the music. Bumps to "mid" — exciting enough to step up
# from low, but not the full payoff of a hit (which goes to "high" via
# _report_player_damage).
@rpc("any_peer", "call_local", "reliable")
func _on_player_near_miss() -> void:
	if not multiplayer.is_server():
		return
	if state != State.PLAYING:
		return
	_set_round_music_level(2)


func _set_round_music_level(level: int) -> void:
	if level <= _round_music_level:
		return
	_round_music_level = level
	_set_music_energy.rpc(level, false, true)

@rpc("authority", "call_local", "reliable")
func _clear_projectiles() -> void:
	# Wipe in-flight bullets and grenades so leftovers from the previous round
	# can't deal damage in the new one.
	for node in get_tree().get_nodes_in_group("projectiles"):
		if is_instance_valid(node):
			node.queue_free()

@rpc("authority", "call_local", "reliable")
func _clear_combat_vfx() -> void:
	Violence.clear_round_combat_vfx(self)
	PLAYER_SCRIPT.clear_tp_casing_fifo()
	for p in players_root.get_children():
		if p.has_method("clear_live_casings"):
			p.clear_live_casings()


@rpc("authority", "call_local", "reliable")
func _clear_blood_splats() -> void:
	# Same logic as craters: blood decals from last round shouldn't bleed
	# into the new map.
	Violence.clear_blood_splats(self)

@rpc("authority", "call_local", "reliable")
func _clear_smoke_puffs() -> void:
	Violence.clear_smoke_puffs(self)

# Replace the current "Arena" child with the map at MAP_POOL[map_index].
# Called from _start_round_now via RPC — server picks the index, every peer
# (including the server thanks to call_local) swaps in lockstep.
# remove_child happens synchronously so the OLD spawnpoints leave the tree
# before _pick_spawn() runs; the deferred queue_free does the actual delete.
@rpc("authority", "call_local", "reliable")
func _swap_arena(map_index: int, map_seed: int = 0, arena_size_min: float = -1.0, arena_size_max: float = -1.0) -> void:
	if map_index < 0 or map_index >= MAP_POOL.size():
		return
	Trace.span_begin("_swap_arena (instantiate+apply_seed)")
	var existing := get_node_or_null("Arena")
	if existing:
		remove_child(existing)
		existing.queue_free()
	var new_arena: Node = MAP_POOL[map_index].instantiate()
	new_arena.name = "Arena"
	add_child(new_arena)
	if new_arena is Node3D:
		(new_arena as Node3D).position = ARENA_OFFSET
	# Procedural maps need the seed plumbed in so every peer regenerates the
	# same geometry. Synchronous: spawnpoints are in the tree before
	# _pick_spawn() runs in _start_round_now().
	if new_arena.has_method("apply_seed"):
		new_arena.apply_seed(map_seed, arena_size_min, arena_size_max)
	if new_arena is Node3D:
		DestructibleManager.update_play_bounds_from_arena(new_arena as Node3D)
	Trace.span_end("_swap_arena (instantiate+apply_seed)")
	current_map_index = map_index
	current_map_seed = map_seed
	current_arena_size_min = arena_size_min
	current_arena_size_max = arena_size_max
	_refresh_pause_seed_label()
	# Re-grab WorldEnvironment so explosion-tonemap-duck logic (_arena_env in
	# _process) keeps working against the new arena's environment resource.
	var we := new_arena.get_node_or_null("WorldEnvironment") as WorldEnvironment
	if we and we.environment:
		_arena_env = we.environment
		_base_tonemap_exposure = _arena_env.tonemap_exposure
	_fog_base_saved = false
	# The old arena's env/lights are gone with it — drop stale blackout state so
	# a blackout that spans the swap re-saves its baseline from the NEW env and
	# re-hides the NEW arena's decorative lights (a stale non-empty hidden-lights
	# list would otherwise skip that).
	_blackout_base_saved = false
	_blackout_hidden_lights.clear()
	_apply_round_modifier_environment()

func _clear_coop_downed_players() -> void:
	downed_players.clear()
	_coop_revive_positions.clear()
	coop_revive_channels = {}
	if multiplayer.is_server():
		_sync_coop_revive_channels.rpc({})
	for raw_id in NetworkManager.players:
		var pid := int(raw_id)
		if not _is_human_player_id(pid):
			continue
		var p := players_root.get_node_or_null(str(pid))
		if p and p.has_method("clear_coop_downed_state"):
			p.clear_coop_downed_state.rpc()


func _reset_round_tracking() -> void:
	pending_picker_id = 0
	pending_pick_cards.clear()
	pending_pick_cards_by_player.clear()
	pending_pick_deadlines.clear()
	completed_picks.clear()
	_clear_coop_downed_players()
	eliminated_players.clear()
	round_winner_id = 0
	_round_elapsed = 0.0
	_lava_leak_started = false
	_lava_leak_start_ms = 0
	_lava_leak_spread_seconds = LAVA_LEAK_SPREAD_SECONDS
	_air_strike_cancel_gen += 1
	_air_strike_timer = -1.0
	_air_strikes_armed = false
	_air_strike_pending = false
	_ion_cannon_cancel_gen += 1
	_ion_cannon_timer = -1.0
	_ion_cannons_armed = false
	_ion_cannon_pending = false
	_coop_enemy_spawn_queue.clear()
	_coop_enemy_spawn_timer = -1.0
	_coop_enemy_incoming = {}
	_coop_wave_enemy_total = 0
	_coop_wave_kills = 0
	_reset_pickup_spawner()

func _reset_pickup_spawner() -> void:
	_pickup_spawn_timer = randf_range(10.0, 24.0) / maxf(get_pickup_spawn_mult(), 0.1)

func _update_pickup_spawner(delta: float) -> void:
	if not multiplayer.is_server() or state != State.PLAYING:
		return
	if get_pickup_spawn_mult() <= 0.0: return
	if get_tree().get_nodes_in_group("pickups").size() >= PICKUP_MAX_ACTIVE:
		return
	_pickup_spawn_timer -= delta
	if _pickup_spawn_timer > 0.0:
		return
	_pickup_spawn_timer = (PICKUP_SPAWN_MEAN + randf_range(-PICKUP_SPAWN_JITTER, PICKUP_SPAWN_JITTER)) / maxf(get_pickup_spawn_mult(), 0.1)
	var kind: String = PICKUP_ITEM_SCRIPT.KINDS[randi() % PICKUP_ITEM_SCRIPT.KINDS.size()]
	_spawn_pickup_on_server(kind, _random_pickup_spawn_pos())

func dev_spawn_pickup(kind: String = "") -> void:
	if not multiplayer.is_server():
		return
	if kind.is_empty() or kind not in PICKUP_ITEM_SCRIPT.KINDS:
		kind = PICKUP_ITEM_SCRIPT.KINDS[randi() % PICKUP_ITEM_SCRIPT.KINDS.size()]
	_spawn_pickup_on_server(kind, _dev_pickup_spawn_pos())

func flash_air_strike_impact(world_pos: Vector3, intensity: float = 1.0) -> void:
	if _splitscreen and _splitscreen.is_enabled() and _splitscreen.has_method("flash_impact_all"):
		_splitscreen.flash_impact_all(world_pos, intensity)
		return
	for renderer in _render_players.values():
		var rp := renderer as RenderPlayer
		if rp:
			rp.flash_impact(world_pos, intensity)


func begin_player_air_strike(target: Vector3, shooter_id: int = 0) -> void:
	if not multiplayer.is_server():
		return
	if state != State.PLAYING:
		return
	if _air_strike_pending:
		return
	var sky_from := _air_strike_sky_from(target)
	_begin_air_strike(sky_from, target, shooter_id)


func dev_test_air_strike() -> void:
	if not multiplayer.is_server():
		return
	# Fire ONE strike — do not set the air_strikes modifier or arm the auto-loop.
	_air_strike_pending = false
	begin_player_air_strike(_dev_air_strike_target())
	_announce.rpc("AIR STRIKE INCOMING", 1.2)


func begin_player_ion_cannon(target: Vector3, shooter_id: int = 0) -> void:
	if not multiplayer.is_server():
		return
	if state != State.PLAYING:
		return
	if _ion_cannon_pending:
		return
	_begin_ion_cannon(target, shooter_id)


func dev_test_ion_cannon() -> void:
	if not multiplayer.is_server():
		return
	# Fire ONE beam — do not set the ion_cannon modifier or arm the auto-loop.
	_ion_cannon_pending = false
	begin_player_ion_cannon(_dev_air_strike_target())
	_announce.rpc("ION CANNON INCOMING", 1.2)

func _dev_air_strike_target() -> Vector3:
	if local_player and is_instance_valid(local_player) and local_player.has_method("_air_strike_target"):
		return local_player._air_strike_target()
	if _dev_panel != null and _dev_panel.has_method("get_target"):
		var target: Node = _dev_panel.get_target()
		if target and is_instance_valid(target):
			return _player_look_aim_point(target) + Vector3.UP * 0.05
	return _random_air_strike_target()

func _dev_pickup_spawn_pos() -> Vector3:
	if _dev_panel != null and _dev_panel.has_method("get_target"):
		var target: Node = _dev_panel.get_target()
		if target and is_instance_valid(target):
			var aim_point := _player_look_aim_point(target)
			return aim_point + Vector3(0.0, PICKUP_SPAWN_HEIGHT, 0.0)
	return _random_pickup_spawn_pos()

func _player_look_aim_point(player: Node) -> Vector3:
	var cam: Camera3D = player.get_node_or_null("Camera") as Camera3D
	if cam == null:
		return player.global_position
	var cam_origin: Vector3 = cam.global_position
	var cam_dir: Vector3 = -cam.global_transform.basis.z
	var aim_dist: float = 800.0
	var space := get_world_3d().direct_space_state
	var aim_q := PhysicsRayQueryParameters3D.create(cam_origin, cam_origin + cam_dir * aim_dist)
	aim_q.collision_mask = 1 | 2
	aim_q.collide_with_areas = true
	if player.has_method("get_hitbox_rids"):
		aim_q.exclude = player.call("get_hitbox_rids")
	var hit := space.intersect_ray(aim_q)
	if hit.is_empty():
		return cam_origin + cam_dir * aim_dist
	return hit.get("position", cam_origin + cam_dir * aim_dist)

func _random_pickup_spawn_pos() -> Vector3:
	return _random_arena_xz() + Vector3.UP * PICKUP_SPAWN_HEIGHT

func _spawn_pickup_on_server(kind: String, world_pos: Vector3) -> void:
	if not multiplayer.is_server():
		return
	_pickup_spawn_serial += 1
	_spawn_pickup_item_with_fx.rpc(kind, world_pos, _pickup_spawn_serial)


@rpc("authority", "call_local", "reliable")
func _spawn_pickup_item_with_fx(kind: String, world_pos: Vector3, pickup_id: int) -> void:
	if _pickups_root == null:
		return
	SFX.pickup_drop(world_pos)
	var pickup: Node3D = PICKUP_ITEM_SCRIPT.new()
	pickup.name = "Pickup_%d" % pickup_id
	_pickups_root.add_child(pickup)
	pickup.setup(kind, world_pos, pickup_id)


func _pickup_collected_by_player(pickup_id: int, player_id: int, kind: String) -> void:
	if not multiplayer.is_server():
		return
	_despawn_pickup.rpc(pickup_id)
	show_pickup_collected_for(player_id, kind)


@rpc("authority", "call_local", "reliable")
func _despawn_pickup(pickup_id: int) -> void:
	if _pickups_root == null or pickup_id < 0:
		return
	var node := _pickups_root.get_node_or_null("Pickup_%d" % pickup_id)
	if is_instance_valid(node):
		node.queue_free()

@rpc("authority", "call_local", "reliable")
func _spawn_pickup_item(kind: String, world_pos: Vector3) -> void:
	_spawn_pickup_on_server(kind, world_pos)

@rpc("authority", "call_local", "reliable")
func _clear_pickups() -> void:
	for node in get_tree().get_nodes_in_group("pickups"):
		if is_instance_valid(node):
			node.queue_free()

@rpc("authority", "call_local", "reliable")
func _set_round_modifier(mod_id: String) -> void:
	if is_coop_mode():
		current_round_modifier = ""
	else:
		current_round_modifier = mod_id if mod_id in ROUND_MODIFIERS_SCRIPT.IDS else ""
	Trace.mark("round modifier set: '%s' (is_server=%s)" % [current_round_modifier, multiplayer.is_server()])
	_apply_round_modifier_environment()

func _apply_round_modifier_environment() -> void:
	if _arena_env == null:
		return
	if current_round_modifier == "fog":
		if not _fog_base_saved:
			_fog_base_enabled = _arena_env.fog_enabled
			_fog_base_mode = _arena_env.fog_mode
			_fog_base_density = _arena_env.fog_density
			_fog_base_depth_begin = _arena_env.fog_depth_begin
			_fog_base_depth_end = _arena_env.fog_depth_end
			_fog_base_depth_curve = _arena_env.fog_depth_curve
			_fog_base_aerial_perspective = _arena_env.fog_aerial_perspective
			_fog_base_saved = true
		ROUND_MODIFIERS_SCRIPT.apply_fog_environment(_arena_env)
	elif _fog_base_saved:
		_arena_env.fog_enabled = _fog_base_enabled
		_arena_env.fog_mode = _fog_base_mode as Environment.FogMode
		_arena_env.fog_density = _fog_base_density
		_arena_env.fog_depth_begin = _fog_base_depth_begin
		_arena_env.fog_depth_end = _fog_base_depth_end
		_arena_env.fog_depth_curve = _fog_base_depth_curve
		_arena_env.fog_aerial_perspective = _fog_base_aerial_perspective
		_fog_base_saved = false

	# BLACKOUT: crush the global lights (ambient + sun + fill) so only the
	# players' flashlights illuminate the arena. We dim the global FILL lights,
	# not tonemap_exposure — exposure would dim the flashlight cones too.
	var arena := get_node_or_null("Arena")
	var sun: DirectionalLight3D = arena.get_node_or_null("Sun") as DirectionalLight3D if arena else null
	var fill: Light3D = arena.get_node_or_null("FillLight") as Light3D if arena else null
	if current_round_modifier == "blackout":
		if not _blackout_base_saved:
			_blackout_base_ambient = _arena_env.ambient_light_energy
			_blackout_base_sun = sun.light_energy if sun else 0.0
			_blackout_base_fill = fill.light_energy if fill else 0.0
			_blackout_base_sky_contrib = _arena_env.ambient_light_sky_contribution
			_blackout_base_bg_energy = _arena_env.background_energy_multiplier
			_blackout_base_bg_mode = _arena_env.background_mode
			_blackout_base_fog_enabled = _arena_env.fog_enabled
			_blackout_base_saved = true
		# Zero ALL global light so non-emissive surfaces go truly black — any
		# residual (even 0.02) + the Filmic tonemapper's toe was lifting walls
		# back into view. Only the flashlight + emissive accents light the scene.
		_arena_env.ambient_light_energy = 0.0
		_arena_env.ambient_light_sky_contribution = 0.0
		_arena_env.background_energy_multiplier = 0.0
		# Swap the bright procedural sky for a near-black background — the energy
		# multiplier doesn't darken the *visible* sky render, so it was glowing
		# and backlighting everything. A faint cool tint keeps a hint of horizon.
		_arena_env.background_mode = Environment.BG_COLOR
		_arena_env.background_color = Color(0.015, 0.012, 0.025)
		# The base palette fog tints the distance/sky with a light colour over the
		# black background — kill it so the horizon goes dark too.
		_arena_env.fog_enabled = false
		if sun:
			sun.light_energy = 0.0
		if fill:
			fill.light_energy = 0.0
		# The arena generator also scatters decorative point lights — torches,
		# building roof lights, lava glow, fort underglow — that global dimming
		# never touches; together they kept the whole arena readable. Hide them
		# for the round: visibility beats zeroing energy because the torch
		# flicker tweens keep rewriting light_energy every frame.
		if _blackout_hidden_lights.is_empty() and arena:
			for n: Node in arena.find_children("*", "Light3D", true, false):
				var l := n as Light3D
				if l == sun or l == fill or not l.visible:
					continue
				l.visible = false
				_blackout_hidden_lights.append(l)
		# Sky clouds are UNSHADED billboards — they ignore lighting entirely and
		# keep their baked daytime tint, reading as glowing blobs against the
		# blacked-out sky. Unlit clouds at night are invisible; hide them.
		if arena:
			var sky_clouds := arena.get_node_or_null("SkyClouds")
			if sky_clouds:
				sky_clouds.visible = false
		# Blast SMOKE uses the same unshaded billow shader (and lingers sky-high
		# after explosions, reading as more glowing clouds). The billow shader
		# multiplies its smoke body by this global; fire stays bright.
		RenderingServer.global_shader_parameter_set("world_light_dim", 0.06)
	elif _blackout_base_saved:
		_arena_env.ambient_light_energy = _blackout_base_ambient
		_arena_env.ambient_light_sky_contribution = _blackout_base_sky_contrib
		_arena_env.background_energy_multiplier = _blackout_base_bg_energy
		_arena_env.background_mode = _blackout_base_bg_mode as Environment.BGMode
		_arena_env.fog_enabled = _blackout_base_fog_enabled
		if sun:
			sun.light_energy = _blackout_base_sun
		if fill:
			fill.light_energy = _blackout_base_fill
		for l: Light3D in _blackout_hidden_lights:
			if is_instance_valid(l):
				l.visible = true
		_blackout_hidden_lights.clear()
		if arena:
			var sky_clouds := arena.get_node_or_null("SkyClouds")
			if sky_clouds:
				sky_clouds.visible = true
		RenderingServer.global_shader_parameter_set("world_light_dim", 1.0)
		_blackout_base_saved = false

	if Trace.enabled:
		print("[blackout-dbg] mod=%s amb=%.3f sun=%s fill=%s bg_mode=%d fog=%s exp=%.2f" % [
			current_round_modifier,
			_arena_env.ambient_light_energy,
			("%.3f" % sun.light_energy) if sun else "NULL",
			("%.3f" % fill.light_energy) if fill else "NULL",
			_arena_env.background_mode,
			str(_arena_env.fog_enabled),
			_arena_env.tonemap_exposure])

	# Toggle every player's flashlight to match (auto-on only in blackout).
	var blackout := current_round_modifier == "blackout"
	for child in players_root.get_children():
		if child.has_method("set_flashlight_active"):
			child.call("set_flashlight_active", blackout)

@rpc("authority", "call_local", "reliable")
func _show_round_modifier_on_screens() -> void:
	# Every peer passes through here exactly once per round start (the
	# modifier check below only gates the toast) — the colosseum crowd
	# roars in anticipation as the fight opens.
	CrowdAudio.on_round_start()
	if current_round_modifier.is_empty():
		return
	if _splitscreen and _splitscreen.is_enabled() and _splitscreen.has_method("show_round_modifier_for_all"):
		_splitscreen.show_round_modifier_for_all(current_round_modifier)
		return
	_show_modifier_toast(current_round_modifier)


func _build_modifier_toast() -> void:
	if _modifier_toast != null:
		return
	_modifier_toast = Label.new()
	_modifier_toast.name = "ModifierToast"
	_modifier_toast.visible = false
	_modifier_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_modifier_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_modifier_toast.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_modifier_toast.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_modifier_toast.offset_top = 56.0
	_modifier_toast.offset_bottom = 156.0
	_modifier_toast.offset_left = -240.0
	_modifier_toast.offset_right = 240.0
	_modifier_toast.add_theme_font_size_override("font_size", 32)
	_modifier_toast.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.92))
	_modifier_toast.add_theme_constant_override("outline_size", 6)
	$HUD.add_child(_modifier_toast)

	_modifier_toast_timer = Timer.new()
	_modifier_toast_timer.name = "ModifierToastTimer"
	_modifier_toast_timer.one_shot = true
	_modifier_toast_timer.timeout.connect(func() -> void:
		if _modifier_toast:
			_modifier_toast.visible = false)
	add_child(_modifier_toast_timer)


func _show_modifier_toast(mod_id: String) -> void:
	_build_modifier_toast()
	var info: Dictionary = ROUND_MODIFIERS_SCRIPT.display_info(mod_id)
	var subtitle: String = str(info.subtitle)
	_modifier_toast.text = info.title if subtitle.is_empty() else "%s\n%s" % [info.title, subtitle]
	_modifier_toast.add_theme_color_override("font_color", info.color)
	_modifier_toast.visible = true
	_modifier_toast_timer.wait_time = 2.5
	_modifier_toast_timer.start()


func report_kill(killer_id: int, victim_id: int) -> void:
	# Called on the server by Player._report_death. In 3+ player rounds,
	# deaths eliminate players; the last survivor wins the round.
	if not multiplayer.is_server():
		return
	if state != State.PLAYING:
		return
	if eliminated_players.has(victim_id):
		return
	eliminated_players[victim_id] = true
	if not _is_bot_id(victim_id):
		var victim_name := str(NetworkManager.players.get(victim_id, "Player"))
		if not victim_name.is_empty():
			_announce.rpc("%s died" % victim_name, 2.0)
	if killer_id != 0 and killer_id != victim_id:
		if _human_count() >= 3:
			var killer_name := str(NetworkManager.players.get(killer_id, "Player"))
			var victim_name := str(NetworkManager.players.get(victim_id, "Player"))
			_show_kill_feed.rpc(killer_name, victim_name)
		var killer_node := players_root.get_node_or_null(str(killer_id))
		if killer_node:
			# Route via authority so server-owned bots receive their own RPC.
			killer_node.confirm_kill.rpc_id(killer_node.get_multiplayer_authority())
	var victim_node := players_root.get_node_or_null(str(victim_id))
	if victim_node and NetworkManager.players.size() >= 3:
		var is_wave_enemy := is_coop_mode() and _is_bot_id(victim_id)
		if not is_wave_enemy:
			victim_node.set_ghost_mode.rpc(true)

	if is_coop_mode():
		if _is_bot_id(victim_id):
			_coop_wave_kills = mini(_coop_wave_enemy_total, _coop_wave_kills + 1)
			_set_coop_wave_progress.rpc(_coop_wave_kills, _coop_wave_enemy_total)
		if _standing_human_ids().is_empty():
			_end_coop_match()
		elif _alive_enemy_ids().is_empty() and _coop_enemy_spawn_queue.is_empty():
			_end_coop_wave()
		return

	var alive := _alive_player_ids()
	if alive.size() <= 1:
		var winner_id := int(alive[0]) if alive.size() == 1 else _fallback_round_winner(victim_id)
		_end_round(winner_id)
	else:
		# Only pick immediately if the round is still going (3+ players)
		_begin_card_pick_for_loser(victim_id)

func _alive_player_ids() -> Array[int]:
	var alive: Array[int] = []
	for raw_id in NetworkManager.players:
		var pid := int(raw_id)
		if eliminated_players.has(pid):
			continue
		if not players_root.has_node(str(pid)):
			continue
		alive.append(pid)
	return alive

func _alive_human_ids() -> Array[int]:
	var alive: Array[int] = []
	for pid in _alive_player_ids():
		if _is_human_player_id(pid):
			alive.append(pid)
	return alive

func _alive_enemy_ids() -> Array[int]:
	var alive: Array[int] = []
	for pid in _alive_player_ids():
		if _is_bot_id(pid):
			alive.append(pid)
	return alive

func _fallback_round_winner(victim_id: int) -> int:
	for raw_id in NetworkManager.players:
		var pid := int(raw_id)
		if pid != victim_id:
			return pid
	return 0

func _end_round(winner_id: int) -> void:
	round_winner_id = winner_id
	_round_damage_seen = false
	# Don't change music energy here — the track stays at whatever intensity
	# the round ended on (typically high). The picker's machine applies a
	# low-pass over the Music bus to muffle it during the card pick UI; see
	# game._process / ProceduralMusic.set_muffle.
	if winner_id != 0:
		round_wins[winner_id] = int(round_wins.get(winner_id, 0)) + 1
		_broadcast_scores.rpc(round_wins)
		# Show "<winner> WINS THE ROUND" on every peer before the card-pick UI
		# starts overwriting the banner. The await below gives the message
		# enough screen time to read; the match-over branch below uses its
		# own _match_over banner so we skip the announce when this is also
		# the final round.
		var winner_name: String = NetworkManager.players.get(winner_id, "Player")
		var is_final: bool = int(round_wins[winner_id]) >= rounds_to_win
		if not is_final:
			_show_round_win_on_screens.rpc(winner_id)
	# Match over?
	if winner_id != 0 and int(round_wins[winner_id]) >= rounds_to_win:
		_set_game_state.rpc(State.MATCH_OVER)
		for pid in NetworkManager.players:
			var pn := players_root.get_node_or_null(str(pid))
			if pn:
				# Freeze everyone except the winner so they can celebrate
				if int(pid) != winner_id:
					pn.set_frozen.rpc(true)
		_match_over.rpc(winner_id)
		if GameNight.launched_by_daemon:
			GameNight.notify_finished(GameNightBridge.current_session_id)
		return
	# Hold on the "X WINS THE ROUND" banner just long enough to register, then
	# let the card UI arrive while the death/blood effect is still playing.
	if winner_id != 0:
		await get_tree().create_timer(ROUND_WIN_TO_CARD_PICK_DELAY).timeout
	# Freeze the losers and wait for them to finish their picks.
	_set_game_state.rpc(State.PICKING_CARD)
	# Don't freeze losers during card pick — let everyone keep moving while
	# the round-pick UI is up. The picker's UI overlay captures their mouse
	# / clicks; movement keys still work in the background, which is fine
	# (it just means they can stretch their legs while picking).
	for raw_loser_id in eliminated_players.keys():
		var loser_id := int(raw_loser_id)
		if not completed_picks.has(loser_id) and not pending_pick_cards_by_player.has(loser_id):
			_begin_card_pick_for_loser(loser_id)
		elif completed_picks.has(loser_id) and not _is_bot_id(loser_id):
			_show_spectating.rpc_id(_peer_for_player(loser_id), _waiting_for_pickers_spectator_label())
	_show_round_winner_wait.rpc(winner_id, _active_picker_names())
	_maybe_finish_card_picks()


func _end_coop_wave() -> void:
	_clear_coop_downed_players()
	_round_damage_seen = false
	_set_game_state.rpc(State.PICKING_CARD)
	_announce.rpc("WAVE %d CLEARED" % coop_wave, 1.4)
	for raw_id in NetworkManager.players:
		var pid := int(raw_id)
		if _is_bot_id(pid):
			continue
		if not players_root.has_node(str(pid)):
			continue
		if not completed_picks.has(pid) and not pending_pick_cards_by_player.has(pid):
			_begin_card_pick_for_loser(pid)
	_show_round_winner_wait.rpc(0, _active_picker_names())
	_maybe_finish_card_picks()


func _end_coop_match() -> void:
	_clear_coop_downed_players()
	_coop_enemy_spawn_queue.clear()
	_coop_enemy_spawn_timer = -1.0
	_coop_enemy_incoming = {}
	_set_game_state.rpc(State.MATCH_OVER)
	for raw_id in NetworkManager.players:
		var p := players_root.get_node_or_null(str(raw_id))
		if p:
			p.set_frozen.rpc(true)
	_coop_match_over.rpc(coop_wave)
	if GameNight.launched_by_daemon:
		GameNight.notify_finished(GameNightBridge.current_session_id)


@rpc("authority", "call_local", "reliable")
func _coop_match_over(wave: int) -> void:
	_hide_card_pick()
	_hide_round_win_on_screens()
	_set_banner("WAVE %d FAILED" % wave, 99.0, MATCH_WIN_FONT_SIZE)
	if _rematch_overlay == null:
		_build_rematch_overlay()
	get_tree().create_timer(MATCH_WIN_BUTTONS_DELAY).timeout.connect(
		_show_rematch_overlay.bind(0), CONNECT_ONE_SHOT)
	_sync_mouse_mode()

func _begin_card_pick_for_loser(loser_id: int) -> void:
	if completed_picks.has(loser_id) or pending_pick_cards_by_player.has(loser_id):
		return

	var score_factor := _get_rarity_score_factor(loser_id)
	var cards := CardLibrary.random_ids(CARDS_PER_PICK, score_factor)
	pending_pick_cards_by_player[loser_id] = cards
	pending_picker_id = loser_id
	pending_pick_cards = cards
	var peer := _peer_for_player(loser_id)
	if peer != 0 and not _is_bot_id(loser_id):
		_show_card_pick.rpc_id(peer, loser_id, cards)
		# Bots resolve via _bot_auto_pick. Humans get a pick countdown, but
		# only when another HUMAN is waiting on them — the timeout exists to
		# stop players stalling each other, and bots don't mind waiting.
		if _human_count() > 1:
			pending_pick_deadlines[loser_id] = GameNightBridge.settings.card_pick_seconds() if GameNight.launched_by_daemon else CARD_PICK_TIMEOUT
	if _is_bot_id(loser_id):
		_bot_auto_pick.call_deferred(loser_id)

func _get_rarity_score_factor(pid: int) -> float:
	# Calculate score rank.
	# 1.0 = top score, >1.0 = trailing.
	var my_score := int(round_wins.get(pid, 0))
	var max_score := 0
	for other_id in NetworkManager.players:
		max_score = max(max_score, int(round_wins.get(int(other_id), 0)))

	if max_score <= 0:
		return 1.0

	# Trailing players get up to 4x better luck (if they have 0 and someone has 8)
	var diff := float(max_score - my_score)
	return 1.0 + (diff * 0.4)

func _bot_auto_pick(loser_id: int) -> void:
	await get_tree().create_timer(1.2).timeout
	if not pending_pick_cards_by_player.has(loser_id):
		return
	var cards: Array = pending_pick_cards_by_player[loser_id]
	if cards.is_empty():
		return
	var pick: String = str(cards[randi() % cards.size()])
	_finalize_card_pick(loser_id, pick)


# Server-only countdown driver. Decrements each pending human pick and fires
# the warning beep on integer crossings of the last 3 seconds; if the timer
# runs out the server force-finalises with a random card from that pick's
# pool, so a wandering player can't stall the round forever.
func _tick_card_pick_deadlines(delta: float) -> void:
	if pending_pick_deadlines.is_empty():
		return
	var expired: Array[int] = []
	for raw_pid in pending_pick_deadlines.keys():
		var pid := int(raw_pid)
		if not pending_pick_cards_by_player.has(pid):
			expired.append(pid)
			continue
		var prev: float = float(pending_pick_deadlines[pid])
		var next: float = prev - delta
		pending_pick_deadlines[pid] = next
		# Fire one beep as the remaining time crosses each of 3.0 / 2.0 / 1.0.
		# Pitch rises one semitone per beep so the picker hears the urgency.
		for threshold in [3.0, 2.0, 1.0]:
			if prev > threshold and next <= threshold:
				var peer := _peer_for_player(pid)
				if peer != 0 and not _is_bot_id(pid):
					_play_pick_countdown_beep.rpc_id(peer, int(threshold))
		if next <= 0.0:
			expired.append(pid)
	for pid in expired:
		if not pending_pick_cards_by_player.has(pid):
			pending_pick_deadlines.erase(pid)
			continue
		var cards: Array = pending_pick_cards_by_player[pid]
		if cards.is_empty():
			pending_pick_deadlines.erase(pid)
			continue
		var pick: String = str(cards[randi() % cards.size()])
		_finalize_card_pick(pid, pick)


# Plays a short rising-pitch warning blip on the picker's machine. Kept as an
# rpc so a network client picker hears the same cadence the server is timing.
@rpc("authority", "call_local", "reliable")
func _play_pick_countdown_beep(seconds_left: int) -> void:
	SFX.pick_countdown_beep(seconds_left)

func _finalize_card_pick(player_id_to_apply: int, card_id: String) -> void:
	var p := players_root.get_node_or_null(str(player_id_to_apply))
	if p:
		p.apply_card.rpc(card_id)
	completed_picks[player_id_to_apply] = true
	pending_pick_cards_by_player.erase(player_id_to_apply)
	pending_pick_deadlines.erase(player_id_to_apply)
	_maybe_finish_card_picks()
	# Bots have no HUD; routing UI RPCs to a bot's peer hits the server peer
	# (1), which would clobber the host human's overlay. Skip them entirely.
	if not _is_bot_id(player_id_to_apply):
		var peer := _peer_for_player(player_id_to_apply)
		if peer != 0:
			_hide_card_pick_for.rpc_id(peer, player_id_to_apply)
			if state == State.PICKING_CARD:
				_show_spectating.rpc_id(peer, _waiting_for_pickers_spectator_label())

func _warmup_round_audio() -> void:
	# Collect every live player's current Weapon (mutated by whatever cards
	# they've picked so far) so SFX.warmup_async caches the shot variants
	# they're actually about to fire. Always include a default Weapon so
	# fresh joiners / bots without applied cards aren't a cache miss.
	var weapons: Array = [Weapon.new()]
	for child in players_root.get_children():
		var w: Variant = child.get("weapon")
		if w != null:
			weapons.append(w)
	# Common explosion radii — covers BLAST cards (4–8m) and bazooka/grenade
	# blasts (6–10m). Bucketed integer-rounded inside warmup_async.
	SFX.warmup_async(weapons, [4.0, 6.0, 8.0, 10.0])


func _maybe_finish_card_picks() -> void:
	if state != State.PICKING_CARD:
		return
	if is_coop_mode():
		for raw_id in NetworkManager.players:
			var pid := int(raw_id)
			if _is_bot_id(pid):
				continue
			if not players_root.has_node(str(pid)):
				continue
			if not completed_picks.has(pid):
				return
		coop_wave += 1
		current_round = coop_wave
		_set_game_mode.rpc(game_mode, coop_wave)
		_set_game_state.rpc(State.PLAYING)
		_start_round_flashed()
		return
	for raw_loser_id in eliminated_players.keys():
		var loser_id := int(raw_loser_id)
		if not completed_picks.has(loser_id):
			return
	current_round += 1
	_set_game_state.rpc(State.PLAYING)
	_start_round_flashed()

func _peer_for_player(pid: int) -> int:
	var p := players_root.get_node_or_null(str(pid))
	if p:
		return int(p.get_multiplayer_authority())
	return pid

@rpc("authority", "call_local", "reliable")
func _show_spectating(text: String = "SPECTATING…") -> void:
	_hide_card_pick()
	_set_local_round_win_strip("")
	_sync_mouse_mode()

@rpc("authority", "call_local", "reliable")
func _show_round_winner_wait(winner_id: int, picker_names: PackedStringArray = PackedStringArray()) -> void:
	if winner_id not in _local_view_player_ids():
		return
	_set_local_round_win_strip(_waiting_for_pickers_label(picker_names))


func _waiting_for_pickers_label(picker_names: PackedStringArray) -> String:
	if is_coop_mode():
		if picker_names.is_empty():
			return "WAVE CLEARED — WAITING FOR PICKS…"
		if picker_names.size() == 1:
			return "WAVE CLEARED — WAITING FOR %s…" % picker_names[0]
		return "WAVE CLEARED — WAITING FOR %s…" % ", ".join(picker_names)
	if picker_names.is_empty():
		return "ROUND WON — WAITING FOR PICKS…"
	if picker_names.size() == 1:
		return "ROUND WON — WAITING FOR %s…" % picker_names[0]
	return "ROUND WON — WAITING FOR %s…" % ", ".join(picker_names)


# Server-only: build the spectator-side wait label (shown to losers who
# already picked, while other losers are still picking).
func _waiting_for_pickers_spectator_label() -> String:
	var names := _active_picker_names()
	if is_coop_mode():
		if names.is_empty():
			return "WAITING FOR TEAM PICKS…"
		if names.size() == 1:
			return "WAITING FOR %s…" % names[0]
		return "WAITING FOR %s…" % ", ".join(names)
	if names.is_empty():
		return "WAITING FOR OTHER PICKS…"
	if names.size() == 1:
		return "WAITING FOR %s…" % names[0]
	return "WAITING FOR %s…" % ", ".join(names)


# Server-only: collect display names of every player who still owes a card
# pick this round. Used by the winner-banner text (and the spectator banner
# for losers who finished their pick early).
func _active_picker_names() -> PackedStringArray:
	var out := PackedStringArray()
	if is_coop_mode():
		for raw_id in pending_pick_cards_by_player.keys():
			var pid := int(raw_id)
			if completed_picks.has(pid) or _is_bot_id(pid):
				continue
			var pname: String = NetworkManager.players.get(pid, "Player")
			out.append(pname)
		return out
	for raw_id in eliminated_players.keys():
		var pid := int(raw_id)
		if completed_picks.has(pid):
			continue
		# Skip bots — they auto-pick instantly and the human shouldn't see
		# the wait label list them.
		if _is_bot_id(pid):
			continue
		var pname: String = NetworkManager.players.get(pid, "Player")
		out.append(pname)
	return out

# -------------------- CARD PICK UI --------------------

@rpc("authority", "call_local", "reliable")
func _show_card_pick(loser_id: int, card_ids: Array) -> void:
	# The loser sees the card UI almost immediately after death, so clear the
	# round-win banner locally before the card title fades in.
	_set_banner("", 0.0)
	_show_render_card_pick(loser_id, card_ids)

func _show_render_card_pick(player_id: int, card_ids: Array) -> bool:
	if _splitscreen and _splitscreen.is_enabled() and _splitscreen.has_method("show_card_pick"):
		if _splitscreen.show_card_pick(player_id, card_ids):
			return true
	var renderer := _render_players.get(player_id) as RenderPlayer
	if renderer == null:
		return false
	renderer.show_card_pick(card_ids)
	return true

func _on_render_player_card_selected(player_id: int, card_id: String) -> void:
	if multiplayer.is_server():
		_server_card_picked_for_player(player_id, card_id)
	else:
		_server_card_picked.rpc_id(1, card_id)

@rpc("any_peer", "call_local", "reliable")
func _server_card_picked(card_id: String) -> void:
	if not multiplayer.is_server():
		return
	if state != State.PICKING_CARD and state != State.PLAYING:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = multiplayer.get_unique_id()
	if _splitscreen and _splitscreen.is_enabled() and not pending_pick_cards_by_player.has(sender) \
			and pending_picker_id >= SPLIT_PLAYER_ID_BASE:
		sender = pending_picker_id
	_server_card_picked_for_player(sender, card_id)

func _server_card_picked_for_player(player_id: int, card_id: String) -> void:
	if not multiplayer.is_server():
		return
	if state != State.PICKING_CARD and state != State.PLAYING:
		return
	if not pending_pick_cards_by_player.has(player_id):
		return
	var cards: Array = pending_pick_cards_by_player[player_id]
	if not cards.has(card_id):
		return
	_finalize_card_pick(player_id, card_id)

@rpc("authority", "call_local", "reliable")
func _hide_card_pick() -> void:
	for renderer in _render_players.values():
		renderer.hide_card_pick()
	if _splitscreen and _splitscreen.is_enabled():
		for player_id in pending_pick_cards_by_player.keys():
			if _splitscreen.has_method("hide_card_pick"):
				_splitscreen.hide_card_pick(int(player_id))
	_sync_mouse_mode()

@rpc("authority", "call_local", "reliable")
func _hide_card_pick_for(player_id: int) -> void:
	var hid_render := false
	if _splitscreen and _splitscreen.is_enabled() and _splitscreen.has_method("hide_card_pick"):
		hid_render = _splitscreen.hide_card_pick(player_id)
	var renderer := _render_players.get(player_id) as RenderPlayer
	if renderer:
		renderer.hide_card_pick()
		hid_render = true
	if hid_render:
		show_death_effect_for(player_id, false)
	_sync_mouse_mode()

@rpc("authority", "call_local", "reliable")
func _announce(text: String, duration: float, font_size: int = -1) -> void:
	_set_banner(text, duration, font_size)


# Local-only banner setter — body of _announce, callable from inside other
# RPCs that already run via call_local on every peer (so we don't need to
# re-broadcast).
func _set_banner(text: String, duration: float, font_size: int = -1) -> void:
	# Clear any leftover match-win pop/pulse so the shared banner is neutral.
	_reset_match_win_banner()
	if text == "" or duration <= 0:
		round_banner.visible = false
		banner_timer.stop()
		return

	round_banner.text = text
	round_banner.visible = true

	if font_size > 0:
		round_banner.add_theme_font_size_override("font_size", font_size)
	else:
		round_banner.remove_theme_font_size_override("font_size")

	banner_timer.stop()
	if duration < 90.0:
		banner_timer.wait_time = maxf(0.01, duration)
		banner_timer.start()


func _local_view_player_ids() -> Array[int]:
	if _splitscreen and _splitscreen.is_enabled() and _splitscreen.has_method("_local_player_ids"):
		return _splitscreen._local_player_ids()
	if local_player and is_instance_valid(local_player):
		return [int(local_player.get("player_id"))]
	return [multiplayer.get_unique_id()]


func _set_local_round_win_strip(text: String) -> void:
	for pid in _local_view_player_ids():
		var renderer := _render_players.get(pid) as RenderPlayer
		if renderer == null:
			continue
		if text.is_empty():
			renderer.hide_round_win()
		else:
			renderer.show_round_win(text)


@rpc("authority", "call_local", "reliable")
func _show_round_win_on_screens(winner_id: int) -> void:
	# The colosseum's biggest moment — every peer celebrates the victor.
	CrowdAudio.on_round_win()
	# Losers get the full-screen death flash — a banner behind it was unreadable.
	var winner_name: String = NetworkManager.players.get(winner_id, "Player")
	if _splitscreen and _splitscreen.is_enabled() and _splitscreen.has_method("show_round_win_for_all"):
		_splitscreen.show_round_win_for_all(winner_id, winner_name, eliminated_players)
		return
	for pid in _local_view_player_ids():
		var renderer := _render_players.get(pid) as RenderPlayer
		if renderer == null:
			continue
		if eliminated_players.has(pid):
			renderer.hide_round_win()
			continue
		var text := "YOU WIN THE ROUND" if pid == winner_id else "%s WINS THE ROUND" % winner_name
		renderer.show_round_win(text)


@rpc("authority", "call_local", "reliable")
func _hide_round_win_on_screens() -> void:
	if _splitscreen and _splitscreen.is_enabled() and _splitscreen.has_method("hide_round_win_for_all"):
		_splitscreen.hide_round_win_for_all()
	_set_local_round_win_strip("")


@rpc("authority", "call_local", "reliable")
func _match_over(winner_id: int) -> void:
	_hide_card_pick() # Ensure picker is gone
	_hide_round_win_on_screens()
	var winner_name: String = NetworkManager.players.get(winner_id, "Player")
	var is_me := winner_id == multiplayer.get_unique_id()
	round_banner.text = "YOU'RE THE WINNER" if is_me else "%s WINS THE MATCH" % winner_name
	banner_timer.stop()
	_animate_match_win_banner()
	# Let the victory land before the buttons appear — they fade in a beat later.
	get_tree().create_timer(MATCH_WIN_BUTTONS_DELAY).timeout.connect(
		_show_rematch_overlay.bind(winner_id), CONNECT_ONE_SHOT)
	_sync_mouse_mode()


# Oversized pop-in for the match-winner banner: scale up from small with an
# overshoot and fade in, then a subtle continuous pulse. Reuses round_banner, so
# _set_banner resets scale/modulate/font for ordinary round announcements.
func _animate_match_win_banner() -> void:
	var b := round_banner
	if _match_win_tween and _match_win_tween.is_valid():
		_match_win_tween.kill()
	b.add_theme_font_size_override("font_size", MATCH_WIN_FONT_SIZE)
	b.pivot_offset = b.size * 0.5
	b.scale = Vector2(0.4, 0.4)
	b.modulate.a = 0.0
	b.visible = true
	# Pop-in: overshoot scale up + fade, then a gentle looped breathing pulse.
	_match_win_tween = b.create_tween()
	_match_win_tween.tween_property(b, "scale", Vector2.ONE, 0.55)\
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_match_win_tween.parallel().tween_property(b, "modulate:a", 1.0, 0.3)
	# Breathing pulse (its own looped tween so the pop above stays one-shot).
	var pulse := b.create_tween().set_loops()
	pulse.tween_interval(0.55)
	pulse.tween_property(b, "scale", Vector2(1.05, 1.05), 0.9)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	pulse.tween_property(b, "scale", Vector2.ONE, 0.9)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_match_win_pulse_tween = pulse


# Stop the win-banner animation and restore neutral transform so the shared
# round_banner renders normally for the next round announcement.
func _reset_match_win_banner() -> void:
	if _match_win_tween and _match_win_tween.is_valid():
		_match_win_tween.kill()
	_match_win_tween = null
	if _match_win_pulse_tween and _match_win_pulse_tween.is_valid():
		_match_win_pulse_tween.kill()
	_match_win_pulse_tween = null
	round_banner.scale = Vector2.ONE
	round_banner.modulate.a = 1.0
	round_banner.remove_theme_font_size_override("font_size")

func _build_rematch_overlay() -> void:
	_rematch_overlay = Control.new()
	_rematch_overlay.name = "RematchOverlay"
	_rematch_overlay.anchor_right = 1.0
	_rematch_overlay.anchor_bottom = 1.0
	_rematch_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_rematch_overlay.visible = false
	$HUD.add_child(_rematch_overlay)

	var center := CenterContainer.new()
	center.anchor_right = 1.0
	center.anchor_bottom = 1.0
	_rematch_overlay.add_child(center)

	# No backdrop panel — buttons float over the world. The big "WINNER"
	# banner above is enough framing.
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	center.add_child(vb)

	_rematch_subtitle = Label.new()
	_rematch_subtitle.text = ""
	_rematch_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_rematch_subtitle.add_theme_font_size_override("font_size", 18)
	_rematch_subtitle.add_theme_color_override("font_color", Color(0.86, 0.86, 0.95))
	vb.add_child(_rematch_subtitle)

	_rematch_button = Button.new()
	_rematch_button.text = "REMATCH"
	_rematch_button.custom_minimum_size = Vector2(260, 46)
	_rematch_button.pressed.connect(_on_rematch_pressed)
	vb.add_child(_rematch_button)

	_extend_button = Button.new()
	_extend_button.text = "5 MORE ROUNDS"
	_extend_button.custom_minimum_size = Vector2(260, 46)
	_extend_button.pressed.connect(_on_extend_pressed)
	vb.add_child(_extend_button)

	_exit_to_menu_button = Button.new()
	_exit_to_menu_button.text = "EXIT GAME"
	_exit_to_menu_button.custom_minimum_size = Vector2(260, 46)
	_exit_to_menu_button.pressed.connect(_quit_game)
	vb.add_child(_exit_to_menu_button)

	_rematch_vote_unlock_timer = Timer.new()
	_rematch_vote_unlock_timer.name = "RematchVoteUnlockTimer"
	_rematch_vote_unlock_timer.one_shot = true
	_rematch_vote_unlock_timer.timeout.connect(_unlock_rematch_vote_buttons)
	add_child(_rematch_vote_unlock_timer)


func _show_rematch_overlay(_winner_id: int) -> void:
	if _rematch_overlay == null:
		_build_rematch_overlay()
	_rematch_requested = false
	if _rematch_button:
		_rematch_button.disabled = true
		_rematch_button.text = "TRY AGAIN FROM WAVE 1" if is_coop_mode() else "REMATCH"
	if _extend_button:
		_extend_button.disabled = true
		_extend_button.visible = not is_coop_mode()
		_extend_button.text = "5 MORE ROUNDS"
	if _exit_to_menu_button:
		_exit_to_menu_button.disabled = true
	_rematch_overlay.visible = true
	# Fade the buttons in so they ease onto the screen a beat after the win text.
	_rematch_overlay.modulate.a = 0.0
	_rematch_overlay.create_tween().tween_property(
		_rematch_overlay, "modulate:a", 1.0, 0.35).set_trans(Tween.TRANS_SINE)
	if _rematch_vote_unlock_timer:
		_rematch_vote_unlock_timer.start(REMATCH_VOTE_DELAY)


func _grab_rematch_overlay_focus() -> void:
	if _extend_button and is_instance_valid(_extend_button) and not _extend_button.disabled:
		_extend_button.grab_focus()
	elif _rematch_button and is_instance_valid(_rematch_button) and not _rematch_button.disabled:
		_rematch_button.grab_focus()


func _unlock_rematch_vote_buttons() -> void:
	if _rematch_overlay == null or not _rematch_overlay.visible:
		return
	if _rematch_button and (_rematch_button.text == "REMATCH" or _rematch_button.text == "TRY AGAIN FROM WAVE 1"):
		_rematch_button.disabled = false
	if _extend_button and _extend_button.visible and _extend_button.text == "5 MORE ROUNDS":
		_extend_button.disabled = false
	if _exit_to_menu_button:
		_exit_to_menu_button.disabled = false
	call_deferred("_grab_rematch_overlay_focus")

var _retro_material: ShaderMaterial = null
var _retro_layer: CanvasLayer = null

# -------------------- VIDEO SETTINGS --------------------
# Settings state is unified and handled via MenuHelpers static variables
func _is_retro_enabled() -> bool:
	return MenuHelpers.retro_enabled


func _is_fisheye_enabled() -> bool:
	return MenuHelpers.retro_enabled


func _apply_settings() -> void:
	RetroFilter.apply(_retro_layer, _retro_material, MenuHelpers.retro_enabled)
	var muted: bool = MenuHelpers.music_db <= MenuHelpers.MUSIC_DB_MIN + 0.5
	ProceduralMusic.enabled = not muted
	ProceduralMusic.music_db = MenuHelpers.music_db
	if not muted:
		ProceduralMusic.set_energy(_round_music_level, true)
	else:
		ProceduralMusic.set_energy(0, true)
	_apply_mouse_sens_to_local()
	_sync_mouse_mode()


func _apply_mouse_sens_to_local() -> void:
	if local_player and is_instance_valid(local_player):
		local_player.set("mouse_sens_mult", MenuHelpers.mouse_sens_mult)
		local_player.set("tilt_enabled", MenuHelpers.movement_tilt_enabled)

# Custom in-HUD cursor so the retro/fisheye shader distorts the cursor along
# with the rest of the UI. The OS cursor is hidden (MOUSE_MODE_HIDDEN) in
# menus; the mouse position Godot tracks is undistorted and matches the
# button's logical rect, so clicks land correctly while the cursor *visually*
# follows the warped UI.
var _custom_cursor: Polygon2D = null

func _build_custom_cursor() -> void:
	_custom_cursor = Polygon2D.new()
	_custom_cursor.name = "CustomCursor"
	# Classic arrow pointing up-left, tip at (0,0).
	_custom_cursor.polygon = PackedVector2Array([
		Vector2(0, 0), Vector2(0, 16), Vector2(4, 12),
		Vector2(7, 18), Vector2(9, 17), Vector2(6, 11),
		Vector2(11, 11),
	])
	_custom_cursor.color = Color(1, 1, 1)
	_custom_cursor.z_index = 4096
	_custom_cursor.visible = false
	$HUD.add_child(_custom_cursor)

func _update_custom_cursor() -> void:
	if _custom_cursor != null:
		_custom_cursor.visible = false
	if _retro_material == null or not _is_retro_enabled():
		if _retro_material:
			_retro_material.set_shader_parameter("cursor_visible", 0.0)
		return
	# In-shader cursor: drawn with fisheye so it aligns with warped UI. Godot
	# still tracks mouse in undistorted space for clicks; only the visual moves.
	var show: bool = Input.mouse_mode != Input.MOUSE_MODE_CAPTURED
	_retro_material.set_shader_parameter("cursor_visible", 1.0 if show else 0.0)
	if show:
		var vp := get_viewport()
		var size: Vector2 = vp.get_visible_rect().size
		if size.x > 0.0 and size.y > 0.0:
			var mp := vp.get_mouse_position()
			_retro_material.set_shader_parameter("mouse_uv", Vector2(mp.x / size.x, mp.y / size.y))

func _build_retro_filter() -> void:
	var built := RetroFilter.build(self)
	_retro_layer = built["layer"] as CanvasLayer
	_retro_material = built["material"] as ShaderMaterial

# --- Round-start flash --------------------------------------------------
# A deliberate camera-flash bumper covering the two long frames of the arena
# swap (~100ms synchronous regeneration + ~110ms first-render buffer upload).
# The white pops BEFORE the heavy frame and fades over 0.6s, so the hitch
# happens behind an intentional broadcast flash instead of a visible freeze.
var _round_flash_overlay: ColorRect = null
var _round_flash_tween: Tween = null


func _ensure_round_flash_overlay() -> void:
	if _round_flash_overlay != null and is_instance_valid(_round_flash_overlay):
		return
	var flash_layer := CanvasLayer.new()
	flash_layer.name = "RoundFlashLayer"
	flash_layer.layer = 51  # above HUD and the explosion flash
	add_child(flash_layer)
	_round_flash_overlay = ColorRect.new()
	_round_flash_overlay.name = "RoundFlashOverlay"
	_round_flash_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_round_flash_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_round_flash_overlay.color = Color(1.0, 0.98, 0.94, 0.0)
	flash_layer.add_child(_round_flash_overlay)


@rpc("authority", "call_local", "reliable")
func _round_start_flash() -> void:
	_ensure_round_flash_overlay()
	if _round_flash_tween != null and _round_flash_tween.is_valid():
		_round_flash_tween.kill()
	_round_flash_overlay.color.a = 1.0
	_round_flash_tween = create_tween()
	# Brief full-white hold covers the swap + first-render frames, then fade.
	_round_flash_tween.tween_interval(0.25)
	_round_flash_tween.tween_property(_round_flash_overlay, "color:a", 0.0, 0.45)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)


# Server-side round start with the flash on screen BEFORE the heavy frame:
# flash everyone (reliable RPC ordering puts it ahead of the swap RPC on
# clients too), render one frame so the white is actually visible, then run
# the synchronous swap. Fire-and-forget coroutine — callers don't await.
func _start_round_flashed() -> void:
	_round_start_flash.rpc()
	await get_tree().process_frame
	_start_round_now()


func _build_explosion_flash_overlay() -> void:
	# Dedicated CanvasLayer above HUD so the flash covers ability bars, health,
	# scoreboard etc. Otherwise the flash sits behind those widgets and you
	# only see white bars in the gaps between them.
	var flash_layer := CanvasLayer.new()
	flash_layer.name = "ExplosionFlashLayer"
	flash_layer.layer = 50  # well above HUD's default layer (1)
	add_child(flash_layer)
	_explosion_flash_overlay = ColorRect.new()
	_explosion_flash_overlay.name = "ExplosionFlashOverlay"
	_explosion_flash_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_explosion_flash_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_explosion_flash_overlay.color = Color(1.0, 0.96, 0.88, 0.0)
	flash_layer.add_child(_explosion_flash_overlay)


func _build_phoenix_fade_overlay() -> void:
	var fade_layer := CanvasLayer.new()
	fade_layer.name = "PhoenixFadeLayer"
	fade_layer.layer = 51
	add_child(fade_layer)
	_phoenix_fade_overlay = ColorRect.new()
	_phoenix_fade_overlay.name = "PhoenixFadeOverlay"
	_phoenix_fade_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_phoenix_fade_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_phoenix_fade_overlay.color = Color(1.0, 1.0, 1.0, 0.0)
	fade_layer.add_child(_phoenix_fade_overlay)


func _boot_warmup_assets() -> void:
	# Menu boot normally finishes this; if the player bailed early, warm without
	# blocking match start (no loading overlay / no await before _maybe_start_match).
	if not has_node("Arena") or ShaderWarmup.effect_shaders_warmed:
		return
	call_deferred("_finish_shader_warmup")


func _finish_shader_warmup() -> void:
	if has_node("Arena"):
		ShaderWarmup.warmup_effect_shaders($Arena)


func set_phoenix_fade(player_id: int, alpha: float) -> void:
	if player_id not in _local_view_player_ids():
		return
	_phoenix_fade_out_per_s = 0.0
	_phoenix_fade_alpha = clampf(alpha, 0.0, 1.0)
	if _phoenix_fade_overlay:
		_phoenix_fade_overlay.color = Color(1.0, 1.0, 1.0, _phoenix_fade_alpha)


func begin_phoenix_fade_out(player_id: int) -> void:
	if player_id not in _local_view_player_ids():
		return
	if _phoenix_fade_alpha <= 0.001:
		return
	_phoenix_fade_out_per_s = _phoenix_fade_alpha / PHOENIX_FADE_OUT_SECONDS


func _update_phoenix_fade(delta: float) -> void:
	if _phoenix_fade_overlay == null:
		return
	if _phoenix_fade_out_per_s > 0.0:
		_phoenix_fade_alpha = move_toward(_phoenix_fade_alpha, 0.0, _phoenix_fade_out_per_s * delta)
		if _phoenix_fade_alpha <= 0.001:
			_phoenix_fade_alpha = 0.0
			_phoenix_fade_out_per_s = 0.0
		_phoenix_fade_overlay.color = Color(1.0, 1.0, 1.0, _phoenix_fade_alpha)


func _build_network_status_panel() -> void:
	if _network_status_panel != null:
		return
	_network_status_panel = PanelContainer.new()
	_network_status_panel.name = "NetworkStatus"
	_network_status_panel.visible = false
	_network_status_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_network_status_panel.anchor_left = 1.0
	_network_status_panel.anchor_right = 1.0
	_network_status_panel.anchor_top = 0.0
	_network_status_panel.anchor_bottom = 0.0
	_network_status_panel.offset_left = -440.0
	_network_status_panel.offset_right = -18.0
	_network_status_panel.offset_top = 18.0
	_network_status_panel.offset_bottom = 0.0
	_network_status_panel.grow_vertical = Control.GROW_DIRECTION_END
	$HUD.add_child(_network_status_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	_network_status_panel.add_child(margin)

	_network_status_label = Label.new()
	_network_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_network_status_label.add_theme_font_size_override("font_size", 15)
	_network_status_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.95))
	_network_status_label.add_theme_constant_override("outline_size", 4)
	margin.add_child(_network_status_label)


func _build_kill_feed() -> void:
	if _kill_feed != null:
		return
	_kill_feed = VBoxContainer.new()
	_kill_feed.name = "KillFeed"
	_kill_feed.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_kill_feed.anchor_left = 1.0
	_kill_feed.anchor_right = 1.0
	_kill_feed.anchor_top = 0.0
	_kill_feed.anchor_bottom = 0.0
	_kill_feed.offset_left = -360.0
	_kill_feed.offset_right = -18.0
	_kill_feed.offset_top = 96.0
	_kill_feed.offset_bottom = 0.0
	_kill_feed.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_kill_feed.grow_vertical = Control.GROW_DIRECTION_END
	_kill_feed.alignment = BoxContainer.ALIGNMENT_BEGIN
	_kill_feed.add_theme_constant_override("separation", 6)
	$HUD.add_child(_kill_feed)


# Top-left hint that points the user at the SPLITSCREEN entry in the pause
# menu when a controller is connected. Hidden once splitscreen is engaged, the
# host loses control of the lobby (becomes a client), or no controller is
# attached.
func _build_splitscreen_hint() -> void:
	if _splitscreen_hint != null:
		return
	var hint := Label.new()
	hint.name = "SplitscreenHint"
	hint.text = "2-PLAYER: open menu (Esc) → SPLITSCREEN"
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint.add_theme_font_size_override("font_size", 14)
	hint.add_theme_color_override("font_color", Color(1.0, 0.9, 0.45))
	hint.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	hint.add_theme_constant_override("outline_size", 4)
	hint.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	hint.offset_left = 16.0
	hint.offset_top = 12.0
	hint.offset_right = 420.0
	hint.offset_bottom = 36.0
	hint.visible = false
	$HUD.add_child(hint)
	_splitscreen_hint = hint


func _on_joy_connection_changed(_device: int, _connected: bool) -> void:
	_refresh_splitscreen_hint()


func _refresh_splitscreen_hint() -> void:
	if _splitscreen_hint == null:
		return
	_splitscreen_hint.visible = _should_show_splitscreen_hint()


func _should_show_splitscreen_hint() -> bool:
	if GameNight.launched_by_daemon:
		# The party adds players in the lobby, not from our pause menu.
		return false
	if _splitscreen and _splitscreen.is_enabled():
		return false
	if not multiplayer.is_server():
		return false
	var pad_count := Input.get_connected_joypads().size()
	if pad_count == 0:
		return false
	if pad_count >= 2:
		return true
	# One controller: only nudge if the host is currently on keyboard/mouse —
	# otherwise that single pad is the host's own and a splitscreen partner
	# would need their own pad anyway.
	return not _last_input_was_controller


@rpc("authority", "call_local", "reliable")
func _show_kill_feed(killer_name: String, victim_name: String) -> void:
	if killer_name.is_empty() or victim_name.is_empty():
		return
	if _kill_feed == null:
		_build_kill_feed()

	var entry := PanelContainer.new()
	entry.mouse_filter = Control.MOUSE_FILTER_IGNORE
	entry.modulate.a = 1.0
	entry.custom_minimum_size = Vector2(0, 30)

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.02, 0.025, 0.03, 0.78)
	style.border_color = Color(1.0, 0.78, 0.35, 0.7)
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 5
	style.content_margin_bottom = 5
	entry.add_theme_stylebox_override("panel", style)

	var label := Label.new()
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	label.text = "%s => %s" % [killer_name, victim_name]
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_color", Color(1.0, 0.94, 0.80))
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.95))
	label.add_theme_constant_override("outline_size", 4)
	entry.add_child(label)

	_kill_feed.add_child(entry)
	while _kill_feed.get_child_count() > KILL_FEED_MAX_ITEMS:
		_kill_feed.get_child(0).queue_free()

	var tween := entry.create_tween()
	tween.tween_interval(KILL_FEED_LIFETIME)
	tween.tween_property(entry, "modulate:a", 0.0, 0.35)
	tween.tween_callback(entry.queue_free)


func _on_iroh_host_ready(_game_id: String) -> void:
	_pause_refresh_game_id()


func _on_network_status_changed(message: String, is_error: bool) -> void:
	if message.is_empty() or not is_error:
		return
	if _network_status_panel == null:
		_build_network_status_panel()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.22, 0.03, 0.035, 0.94)
	sb.border_color = Color(1.0, 0.35, 0.28, 0.9)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(6)
	_network_status_panel.add_theme_stylebox_override("panel", sb)

	_network_status_label.add_theme_color_override("font_color", Color(1.0, 0.84, 0.78))
	_network_status_label.text = message + "\nLogs: %s" % OS.get_user_data_dir().path_join("logs")
	_network_status_panel.visible = true

func trigger_explosion_sidechain(
	pos: Vector3, radius: float, peak: float = 1.0, sustain_sec: float = -1.0, release_sec: float = -1.0,
) -> void:
	if local_player == null or not is_instance_valid(local_player):
		return
	var dist := pos.distance_to(local_player.global_position)
	# Wider reach (was 3.2× radius) so distant big blasts still flash and
	# duck exposure — bazooka at r=24 now reaches 144 m, grenade r=6 → 36 m.
	var affect_radius := maxf(radius * 6.0, 12.0)
	if dist > affect_radius:
		return
	# Upper bound scales with peak so ion cannon (peak > 3) can flash harder than grenades.
	var amount_cap: float = maxf(3.0, peak)
	var amount := clampf((1.0 - dist / affect_radius) * peak, 0.0, amount_cap)
	if amount <= 0.0:
		return
	_exposure_duck = maxf(_exposure_duck, amount * 1.05)
	_exposure_duck_vel = maxf(_exposure_duck_vel, 4.6 + amount * 2.8)
	_sidechain_pressure = minf(_sidechain_pressure + 1.0, SIDECHAIN_PRESSURE_MAX)
	var alpha_peak := minf(amount * 0.62, 0.96)
	if sustain_sec >= 0.0 and release_sec > 0.0:
		var now_ms := Time.get_ticks_msec()
		_flash_adsr_peak = maxf(_flash_adsr_peak if _flash_adsr_active else 0.0, alpha_peak)
		_flash_alpha = _flash_adsr_peak
		_flash_adsr_sustain_end_ms = now_ms + int(sustain_sec * 1000.0)
		_flash_adsr_release_end_ms = _flash_adsr_sustain_end_ms + int(release_sec * 1000.0)
		_flash_adsr_active = true
	else:
		_flash_alpha_target = maxf(_flash_alpha_target, alpha_peak)
		_flash_alpha_vel = maxf(_flash_alpha_vel, 7.0 + amount * 4.0)

func _update_explosion_sidechain(delta: float) -> void:
	if _arena_env:
		# Floor rises with sustained-blast pressure: an isolated blast can dip to
		# SIDECHAIN_FLOOR_MIN (punchy near-black), but during spam the floor lifts
		# toward SIDECHAIN_FLOOR_MAX so the screen stays visible instead of black.
		var floor_exp: float = lerpf(SIDECHAIN_FLOOR_MIN, SIDECHAIN_FLOOR_MAX,
			clampf(_sidechain_pressure / SIDECHAIN_PRESSURE_MAX, 0.0, 1.0))
		var target_exposure := maxf(floor_exp, _base_tonemap_exposure - _exposure_duck * 0.75)
		_arena_env.tonemap_exposure = lerpf(_arena_env.tonemap_exposure, target_exposure, clampf(delta * 20.0, 0.0, 1.0))
	if _flash_adsr_active:
		var now_ms := Time.get_ticks_msec()
		if now_ms < _flash_adsr_sustain_end_ms:
			_flash_alpha = _flash_adsr_peak
		elif now_ms < _flash_adsr_release_end_ms:
			var release_ms := maxf(1, _flash_adsr_release_end_ms - _flash_adsr_sustain_end_ms)
			var t := float(now_ms - _flash_adsr_sustain_end_ms) / float(release_ms)
			_flash_alpha = lerpf(_flash_adsr_peak, 0.0, clampf(t, 0.0, 1.0))
		else:
			_flash_alpha = 0.0
			_flash_adsr_active = false
			_flash_adsr_peak = 0.0
	elif _flash_alpha_target > 0.0 or _flash_alpha > 0.001:
		# Lerp alpha toward the target on the rise (smooth attack so any tearing
		# shows minimal per-frame contrast), then move_toward 0 on the decay as
		# the target also decays. Attack rate ~25 reaches 80% of target in ~60 ms.
		_flash_alpha = lerpf(_flash_alpha, _flash_alpha_target, clampf(delta * 25.0, 0.0, 1.0))
		_flash_alpha_target = move_toward(_flash_alpha_target, 0.0, _flash_alpha_vel * delta)
	if _explosion_flash_overlay:
		_explosion_flash_overlay.color.a = _flash_alpha
	_exposure_duck = move_toward(_exposure_duck, 0.0, _exposure_duck_vel * delta)
	_sidechain_pressure = move_toward(_sidechain_pressure, 0.0, SIDECHAIN_PRESSURE_DECAY * delta)

func show_death_effect_for(player_id: int, show: bool) -> void:
	# Breadcrumb for the stuck-red-screen class of client freezes: if a log
	# ends with show=true and never hides, the death overlay was the last
	# thing standing when the render thread died.
	Trace.mark("death effect %s (player %d)" % ["SHOW" if show else "hide", player_id])
	if _splitscreen and _splitscreen.is_enabled() and _splitscreen.has_method("show_death_effect_for"):
		if _splitscreen.show_death_effect_for(player_id, show):
			return
	var renderer := _render_players.get(player_id) as RenderPlayer
	if renderer:
		renderer.show_death_effect(show)
		return

func _on_extend_pressed() -> void:
	_submit_match_end_vote("extend")


func _on_rematch_pressed() -> void:
	_submit_match_end_vote("rematch")


func _submit_match_end_vote(choice: String) -> void:
	if _rematch_button:
		_rematch_button.disabled = true
		_rematch_button.text = "VOTED REMATCH" if choice == "rematch" else "REMATCH"
	if _extend_button:
		_extend_button.disabled = true
		_extend_button.text = "VOTED 5 MORE" if choice == "extend" else "5 MORE ROUNDS"
	var vote_ids := _local_match_end_vote_ids()
	if multiplayer.is_server():
		for player_id in vote_ids:
			_server_match_end_vote(int(player_id), choice)
	else:
		for player_id in vote_ids:
			_server_match_end_vote.rpc_id(1, int(player_id), choice)


func _local_match_end_vote_ids() -> Array[int]:
	if _splitscreen and _splitscreen.is_enabled() and _splitscreen.has_method("_local_player_ids"):
		return _splitscreen._local_player_ids()
	return [multiplayer.get_unique_id()]

@rpc("any_peer", "call_local", "reliable")
func _server_match_end_vote(player_id: int, choice: String) -> void:
	if not multiplayer.is_server():
		return
	if state != State.MATCH_OVER:
		return
	if choice != "rematch" and choice != "extend":
		return
	_match_end_votes[player_id] = choice

	var all_humans_voted := true
	var all_extend := true
	for pid in NetworkManager.players:
		if _is_bot_id(int(pid)):
			continue
		if not _match_end_votes.has(pid):
			all_humans_voted = false
			break
		if str(_match_end_votes.get(pid)) != "extend":
			all_extend = false

	if not all_humans_voted:
		return
	if all_extend:
		_extend_match()
	else:
		_rematch_match()


func _rematch_match() -> void:
	_match_end_votes.clear()
	for player_id in NetworkManager.players:
		show_death_effect_for(int(player_id), false)
	_hide_rematch_overlay.rpc()
	_restart_match()

func _extend_match() -> void:
	# Increase goal, hide UI, continue match
	var new_goal := rounds_to_win + 5
	_set_rounds_to_win.rpc(new_goal)
	_match_end_votes.clear()
	for player_id in NetworkManager.players:
		show_death_effect_for(int(player_id), false)

	# Start a normal round pick flow for the loser of the last round.
	_set_game_state.rpc(State.PICKING_CARD)
	_hide_rematch_overlay.rpc()

	# Find who lost the last round (usually the one who triggered _match_over)
	# We'll let the person who didn't win pick a card.
	for pid in NetworkManager.players:
		if pid != round_winner_id:
			_begin_card_pick_for_loser(pid)

@rpc("authority", "call_local", "reliable")
func _set_gamenight_rules(values: Dictionary) -> void:
	# Authority sends the same round snapshot to every peer.
	gamenight_rules.apply(values)

@rpc("authority", "call_local", "reliable")
func _set_rounds_to_win(count: int) -> void:
	rounds_to_win = count

@rpc("authority", "call_local", "reliable")
func _hide_rematch_overlay() -> void:
	# A continued match ("5 MORE ROUNDS") doesn't reload the scene, so clear the
	# oversized win-banner pop/pulse here too.
	_reset_match_win_banner()
	_set_banner("", 0.0)
	if _rematch_vote_unlock_timer and _rematch_vote_unlock_timer.time_left > 0.0:
		_rematch_vote_unlock_timer.stop()
	if _rematch_overlay:
		_rematch_overlay.visible = false
	_rematch_requested = false
	_match_end_votes.clear()
	if _rematch_button:
		_rematch_button.disabled = false
		_rematch_button.text = "REMATCH"
	if _rematch_subtitle:
		_rematch_subtitle.text = ""
	if _extend_button:
		_extend_button.disabled = false
		_extend_button.visible = true
		_extend_button.text = "5 MORE ROUNDS"
	if _exit_to_menu_button:
		_exit_to_menu_button.disabled = false

@rpc("authority", "call_local", "reliable")
func _broadcast_scores(scores: Dictionary) -> void:
	round_wins = scores
	_update_scoreboard()

func show_pickup_collected_for(player_id: int, kind: String, subtitle_override: String = "") -> void:
	if _splitscreen and _splitscreen.is_enabled() and _splitscreen.has_method("show_pickup_collected_for"):
		if _splitscreen.show_pickup_collected_for(player_id, kind, subtitle_override):
			return
	if not _is_local_human_player(player_id):
		return
	_show_pickup_toast(kind, subtitle_override)


func _is_local_human_player(player_id: int) -> bool:
	if _splitscreen and _splitscreen.is_enabled() and _splitscreen.has_method("_local_player_ids"):
		return player_id in _splitscreen._local_player_ids()
	if local_player and is_instance_valid(local_player):
		return int(local_player.get("player_id")) == player_id
	return player_id == multiplayer.get_unique_id()


func _build_pickup_toast() -> void:
	if _pickup_toast != null:
		return
	_pickup_toast = Label.new()
	_pickup_toast.name = "PickupToast"
	_pickup_toast.visible = false
	_pickup_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pickup_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_pickup_toast.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_pickup_toast.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_pickup_toast.offset_top = 108.0
	_pickup_toast.offset_bottom = 188.0
	_pickup_toast.offset_left = -220.0
	_pickup_toast.offset_right = 220.0
	_pickup_toast.add_theme_font_size_override("font_size", 30)
	_pickup_toast.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.92))
	_pickup_toast.add_theme_constant_override("outline_size", 6)
	_pickup_toast.grow_horizontal = Control.GROW_DIRECTION_BOTH
	var toast_style := RenderPlayer._hud_plate_style(14)
	toast_style.content_margin_left = 24.0
	toast_style.content_margin_right = 24.0
	toast_style.content_margin_top = 6.0
	toast_style.content_margin_bottom = 8.0
	_pickup_toast.add_theme_stylebox_override("normal", toast_style)
	$HUD.add_child(_pickup_toast)

	_pickup_toast_timer = Timer.new()
	_pickup_toast_timer.name = "PickupToastTimer"
	_pickup_toast_timer.one_shot = true
	_pickup_toast_timer.timeout.connect(func() -> void:
		if _pickup_toast:
			_pickup_toast.visible = false)
	add_child(_pickup_toast_timer)


func _show_pickup_toast(kind: String, subtitle_override: String = "") -> void:
	_build_pickup_toast()
	var info: Dictionary = PICKUP_ITEM_SCRIPT.display_info(kind)
	var subtitle: String = subtitle_override if not subtitle_override.is_empty() else str(info.subtitle)
	_pickup_toast.text = info.title if subtitle.is_empty() else "%s\n%s" % [info.title, subtitle]
	_pickup_toast.add_theme_color_override("font_color", info.color)
	_pickup_toast.visible = true
	_pickup_toast_timer.wait_time = 1.35
	_pickup_toast_timer.start()


func show_hitmarker_for(player_id: int, kind: String, dmg: int = 0, world_pos: Vector3 = Vector3.INF) -> void:
	if _splitscreen and _splitscreen.is_enabled() and _splitscreen.has_method("show_hitmarker_for"):
		if _splitscreen.show_hitmarker_for(player_id, kind):
			if kind == "kill":
				SFX.kill_confirm()
			else:
				SFX.hitmarker(kind, dmg)
			if dmg > 0 and world_pos != Vector3.INF:
				_show_hit_damage_number(dmg, kind, world_pos)
			return
	var renderer := _render_players.get(player_id) as RenderPlayer
	if renderer:
		renderer.show_hitmarker(kind)
	else:
		return
	if kind == "kill":
		SFX.kill_confirm()
	else:
		SFX.hitmarker(kind, dmg)
	if dmg > 0 and world_pos != Vector3.INF:
		_show_hit_damage_number(dmg, kind, world_pos)

func _show_hit_damage_number(dmg: int, kind: String, world_pos: Vector3) -> void:
	# Floating world-space damage number anchored above the hit point.
	# Each call spawns a fresh Label3D so simultaneous hits stack rather than
	# overwriting each other; a small random offset keeps them from piling up.
	var label := Label3D.new()
	label.text = str(dmg)
	label.font_size = 64
	label.outline_size = 16
	label.outline_modulate = Color(0, 0, 0, 1)
	label.modulate = Color(1.0, 0.55, 0.45) if kind == "head" else Color(1.0, 0.95, 0.75)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true                  # always visible — gameplay info
	label.fixed_size = false
	label.pixel_size = 0.004
	add_child(label)
	var jitter := Vector3(
		randf_range(-0.35, 0.35),
		randf_range(0.05, 0.35),
		randf_range(-0.35, 0.35),
	)
	var start_pos: Vector3 = world_pos + Vector3.UP * 0.4 + jitter
	label.global_position = start_pos
	var end_pos: Vector3 = start_pos + Vector3.UP * 0.9
	var tw := label.create_tween().set_parallel(true)
	tw.tween_property(label, "global_position", end_pos, 1.0)\
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(label, "modulate:a", 0.0, 0.55)\
		.set_delay(0.45).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(label.queue_free)

func is_any_modal_open() -> bool:
	# Used by Player._unhandled_input to avoid recapturing the mouse when a
	# UI overlay (card pick, dev panel, pause menu, settings, rematch) is visible.
	if _is_render_card_pick_blocking():
		return true
	return _is_global_modal_open()


# Per-player modal check used by Player._can_accept_gameplay_input — a
# splitscreen teammate's card pick must NOT freeze everyone else on the
# same machine, only the picker themselves.
func is_modal_blocking_player(pid: int) -> bool:
	if _is_card_pick_blocking_for_player(pid):
		return true
	return _is_global_modal_open()

func _is_cursor_modal_open() -> bool:
	# Only mouse-using local pickers should force the cursor visible. A
	# controller-using teammate can navigate cards without the cursor, so
	# their pick shouldn't yank mouse capture away from a kbd+mouse player
	# who's still alive and running around.
	if _is_card_pick_blocking_for_mouse_player():
		return true
	if _dev_panel and _dev_panel.is_open():
		return true
	if _pause_menu and _pause_menu.visible:
		return true
	if _settings_panel and _settings_panel.visible:
		return true
	if _rematch_overlay and _rematch_overlay.visible:
		return true
	if _audio_panel and _audio_panel.visible:
		return true
	return false

func _is_global_modal_open() -> bool:
	if _dev_panel and _dev_panel.is_open():
		return true
	if _pause_menu and _pause_menu.visible:
		return true
	if _settings_panel and _settings_panel.visible:
		return true
	if _rematch_overlay and _rematch_overlay.visible:
		return true
	if _audio_panel and _audio_panel.visible:
		return true
	return false

func _is_render_card_pick_visible() -> bool:
	for renderer in _render_players.values():
		if renderer.is_card_pick_visible():
			return true
	if _splitscreen and _splitscreen.is_enabled() and _splitscreen.has_method("is_card_pick_visible"):
		return _splitscreen.is_card_pick_visible()
	return false


func _is_render_card_pick_blocking() -> bool:
	for renderer in _render_players.values():
		if renderer.is_card_pick_blocking():
			return true
	if _splitscreen and _splitscreen.is_enabled() and _splitscreen.has_method("is_card_pick_blocking"):
		return _splitscreen.is_card_pick_blocking()
	return false


func _is_card_pick_visible_for_player(pid: int) -> bool:
	var renderer := _render_players.get(pid) as RenderPlayer
	if renderer and renderer.is_card_pick_visible():
		return true
	if _splitscreen and _splitscreen.is_enabled() and _splitscreen.has_method("is_card_pick_visible_for"):
		return bool(_splitscreen.is_card_pick_visible_for(pid))
	return false


func _is_card_pick_blocking_for_player(pid: int) -> bool:
	var renderer := _render_players.get(pid) as RenderPlayer
	if renderer and renderer.is_card_pick_blocking():
		return true
	if _splitscreen and _splitscreen.is_enabled() and _splitscreen.has_method("is_card_pick_blocking_for"):
		return bool(_splitscreen.is_card_pick_blocking_for(pid))
	return false


func _is_card_pick_visible_for_mouse_player() -> bool:
	for pid in _render_players.keys():
		if not _is_card_pick_visible_for_player(int(pid)):
			continue
		if _player_uses_mouse(int(pid)):
			return true
	if _splitscreen and _splitscreen.is_enabled() and _splitscreen.has_method("_local_player_ids"):
		for pid in _splitscreen._local_player_ids():
			if not _is_card_pick_visible_for_player(int(pid)):
				continue
			if _player_uses_mouse(int(pid)):
				return true
	return false


func _is_card_pick_blocking_for_mouse_player() -> bool:
	for pid in _render_players.keys():
		if not _is_card_pick_blocking_for_player(int(pid)):
			continue
		if _player_uses_mouse(int(pid)):
			return true
	if _splitscreen and _splitscreen.is_enabled() and _splitscreen.has_method("_local_player_ids"):
		for pid in _splitscreen._local_player_ids():
			if not _is_card_pick_blocking_for_player(int(pid)):
				continue
			if _player_uses_mouse(int(pid)):
				return true
	return false


func _player_uses_mouse(pid: int) -> bool:
	var p := players_root.get_node_or_null(str(pid))
	if p == null:
		return false
	return int(p.get("local_input_device")) < 0

func _sync_mouse_mode() -> void:
	var modal_open := _is_cursor_modal_open()
	var desired := Input.MOUSE_MODE_CAPTURED
	if modal_open:
		# Hide the OS cursor when retro draws its own warped pointer in-shader.
		desired = Input.MOUSE_MODE_HIDDEN if _is_retro_enabled() else Input.MOUSE_MODE_VISIBLE
	if Input.mouse_mode != desired:
		Input.mouse_mode = desired

# -------------------- PAUSE MENU (ESC) --------------------

func _toggle_pause_menu() -> void:
	if _pause_menu == null:
		_build_pause_menu()
	_pause_menu.visible = not _pause_menu.visible
	if _pause_menu.visible:
		# Refresh the game-ID field — the iroh server may have come up after
		# _build_pause_menu ran (host_game_iroh in _ready races with the
		# pause menu's lazy build).
		_pause_refresh_game_id()
		_refresh_pause_seed_label()
		_update_join_form()
		_refresh_bot_counter()
		_refresh_pause_mode_buttons()
		_refresh_pause_splitscreen_btn()
		_sync_mouse_mode()
		MenuHelpers.grab_first_menu_focus(_pause_menu)
		# Pause the world if this is a solo match (local player + bots only).
		if _human_count() <= 1:
			get_tree().paused = true
	else:
		# Unpause if we were paused.
		get_tree().paused = false
		_sync_mouse_mode()

# Shared modal scaffold for the pause + settings screens: a full-screen dimmer
# with a centered, bordered panel. Adds the root under $HUD and returns
# {root, vb} — populate `vb`, store/show `root`. Keeps both screens visually
# identical (see _menu_panel_style / _make_menu_title for the shared theming).
func _build_modal_scaffold(node_name: String, vb_separation: int) -> Dictionary:
	var root := Control.new()
	root.name = node_name
	root.anchor_right = 1.0
	root.anchor_bottom = 1.0
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	root.process_mode = Node.PROCESS_MODE_ALWAYS
	$HUD.add_child(root)

	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.55)
	bg.anchor_right = 1.0
	bg.anchor_bottom = 1.0
	root.add_child(bg)

	var center := CenterContainer.new()
	center.anchor_right = 1.0
	center.anchor_bottom = 1.0
	root.add_child(center)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _menu_panel_style())
	center.add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", vb_separation)
	panel.add_child(vb)

	return {"root": root, "vb": vb}

func _menu_panel_style() -> StyleBoxFlat:
	return MenuHelpers.menu_panel_style()

func _make_menu_title(text: String, font_size: int, outline_size: int) -> Label:
	var title := Label.new()
	title.text = text
	title.add_theme_font_size_override("font_size", font_size)
	title.add_theme_color_override("font_color", Color(1, 0.9, 0.45))
	title.add_theme_color_override("font_outline_color", Color(0.4, 0.0, 0.1))
	title.add_theme_constant_override("outline_size", outline_size)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return title

func _build_pause_menu() -> void:
	var scaffold := _build_modal_scaffold("PauseMenu", 8)
	var root: Control = scaffold["root"]
	var vb: VBoxContainer = scaffold["vb"]

	var panel := vb.get_parent() as PanelContainer
	if panel:
		panel.custom_minimum_size = Vector2(350, 0)

	# Game title — readable from across the room. Moved out of the box to the top center.
	var title := _make_menu_title("GROWING GUNS", 42, 6)
	title.set_anchors_preset(Control.PRESET_CENTER_TOP)
	title.anchor_left = 0.5
	title.anchor_right = 0.5
	title.offset_left = -250.0
	title.offset_top = 35.0
	title.offset_right = 250.0
	title.offset_bottom = 95.0
	title.grow_horizontal = Control.GROW_DIRECTION_BOTH
	root.add_child(title)

	# ── Share my game ID ──
	var share_label := Label.new()
	share_label.text = "Share your match with friends:"
	share_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.85))
	vb.add_child(share_label)

	var id_row := HBoxContainer.new()
	id_row.add_theme_constant_override("separation", 8)
	vb.add_child(id_row)
	# LineEdit instead of Label so the user can drag-select + Cmd+C the ID
	# manually if the Copy button isn't enough.
	var id_field := LineEdit.new()
	id_field.editable = false
	id_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	id_field.custom_minimum_size = Vector2(0, 32)
	id_field.placeholder_text = "(offline — not hosting)"
	id_row.add_child(id_field)
	var host_btn := Button.new()
	host_btn.text = "HOST ONLINE"
	host_btn.custom_minimum_size = Vector2(110, 32)
	host_btn.pressed.connect(_pause_host_online)
	id_row.add_child(host_btn)
	_pause_host_button = host_btn
	var copy_btn := Button.new()
	copy_btn.text = "COPY"
	copy_btn.custom_minimum_size = Vector2(70, 32)
	id_row.add_child(copy_btn)
	# Stash so _toggle_pause_menu can refresh the field every time the menu opens.
	_pause_id_field = id_field
	_pause_copy_button = copy_btn
	copy_btn.pressed.connect(_pause_copy_game_id)

	# ── Join someone else's game ──
	var join_label := Label.new()
	join_label.text = "Or join a friend:"
	join_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.85))
	vb.add_child(join_label)

	var join_row := HBoxContainer.new()
	join_row.add_theme_constant_override("separation", 8)
	vb.add_child(join_row)
	var join_input := LineEdit.new()
	join_input.placeholder_text = "Paste a Game ID…"
	join_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	join_input.custom_minimum_size = Vector2(0, 32)
	join_input.text_changed.connect(_on_join_input_changed)
	join_input.text_submitted.connect(func(_t: String) -> void: _pause_join())
	join_row.add_child(join_input)
	var join_btn := Button.new()
	join_btn.text = "JOIN"
	join_btn.custom_minimum_size = Vector2(70, 32)
	join_btn.disabled = true
	join_btn.pressed.connect(_pause_join)
	join_row.add_child(join_btn)
	_pause_join_input = join_input
	_pause_join_button = join_btn

	var join_notice := Label.new()
	join_notice.text = "Paste an iroh game ID"
	join_notice.add_theme_font_size_override("font_size", 12)
	join_notice.add_theme_color_override("font_color", Color(0.55, 0.60, 0.72))
	vb.add_child(join_notice)
	_pause_join_notice = join_notice

	# ── Bot count ──
	var bot_label := Label.new()
	bot_label.text = "Bots:"
	bot_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.85))
	vb.add_child(bot_label)

	var bot_row := HBoxContainer.new()
	bot_row.add_theme_constant_override("separation", 8)
	vb.add_child(bot_row)

	var bot_minus := Button.new()
	bot_minus.text = "-"
	bot_minus.custom_minimum_size = Vector2(40, 32)
	bot_minus.pressed.connect(_pause_remove_bot)
	bot_row.add_child(bot_minus)

	var bot_count := Label.new()
	bot_count.text = "0"
	bot_count.custom_minimum_size = Vector2(0, 32)
	bot_count.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bot_count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bot_count.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	bot_count.add_theme_font_size_override("font_size", 16)
	bot_count.add_theme_color_override("font_color", Color(1.0, 0.95, 0.78))
	bot_row.add_child(bot_count)

	var bot_plus := Button.new()
	bot_plus.text = "+"
	bot_plus.custom_minimum_size = Vector2(40, 32)
	bot_plus.pressed.connect(_pause_add_bot)
	bot_row.add_child(bot_plus)

	_pause_bot_count_label = bot_count
	_pause_bot_minus_button = bot_minus
	_pause_bot_plus_button = bot_plus
	_refresh_bot_counter()

	# Spacer before action buttons.
	var spacer2 := Control.new()
	spacer2.custom_minimum_size = Vector2(0, 4)
	vb.add_child(spacer2)

	# Versus Button
	var versus_btn := Button.new()
	versus_btn.text = "VERSUS"
	versus_btn.custom_minimum_size = Vector2(0, 32)
	versus_btn.pressed.connect(func() -> void: _pause_change_mode(GAME_MODE_VERSUS))
	vb.add_child(versus_btn)
	_pause_versus_btn = versus_btn

	# Wave Survival Button
	var wave_btn := Button.new()
	wave_btn.text = "WAVE SURVIVAL"
	wave_btn.custom_minimum_size = Vector2(0, 32)
	wave_btn.pressed.connect(func() -> void: _pause_change_mode(GAME_MODE_COOP))
	vb.add_child(wave_btn)
	_pause_wave_btn = wave_btn

	var splitscreen_btn := Button.new()
	splitscreen_btn.text = "SPLITSCREEN"
	splitscreen_btn.custom_minimum_size = Vector2(0, 32)
	splitscreen_btn.pressed.connect(_pause_toggle_splitscreen)
	# Under a daemon the seats are the party's, and this button would silently
	# disagree with them: it despawns the bots and waits for a walk-up join
	# that GameNight mode no longer accepts.
	splitscreen_btn.visible = not GameNight.launched_by_daemon
	vb.add_child(splitscreen_btn)
	_pause_splitscreen_btn = splitscreen_btn

	var settings_btn := Button.new()
	settings_btn.text = "SETTINGS"
	settings_btn.custom_minimum_size = Vector2(0, 32)
	settings_btn.pressed.connect(_open_settings)
	vb.add_child(settings_btn)

	var resume := Button.new()
	resume.text = "RESUME"
	resume.custom_minimum_size = Vector2(0, 32)
	resume.pressed.connect(_toggle_pause_menu)
	# Esc / Enter close the menu; the _input handler also routes those keys
	# through here, but the Shortcut keeps focus-driven controllers happy.
	var shortcut := Shortcut.new()
	var ev := InputEventAction.new()
	ev.action = "ui_cancel"
	shortcut.events.append(ev)
	resume.shortcut = shortcut
	vb.add_child(resume)

	var exit_btn := Button.new()
	exit_btn.text = "EXIT GAME"
	exit_btn.custom_minimum_size = Vector2(0, 32)
	exit_btn.pressed.connect(_quit_game)
	vb.add_child(exit_btn)

	# Subtle map+seed readout pinned to the bottom-right corner of the screen
	# (sibling of the bg + panel so it's not constrained by the center column).
	var seed_label := Label.new()
	seed_label.name = "SeedLabel"
	seed_label.add_theme_color_override("font_color", Color(0.72, 0.72, 0.85, 0.85))
	seed_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	seed_label.add_theme_constant_override("outline_size", 3)
	seed_label.add_theme_font_size_override("font_size", 13)
	seed_label.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	seed_label.offset_left = -260
	seed_label.offset_top = -28
	seed_label.offset_right = -12
	seed_label.offset_bottom = -8
	seed_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	seed_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(seed_label)
	_pause_seed_label = seed_label
	_refresh_pause_seed_label()

	_pause_menu = root
	_pause_menu.visible = false


# Pause-menu controls — set in _build_pause_menu, used by the action handlers
# below so we don't need to walk the scene tree to find them.
var _pause_versus_btn: Button = null
var _pause_wave_btn: Button = null
var _pause_splitscreen_btn: Button = null
var _pause_id_field: LineEdit = null
var _pause_host_button: Button = null
var _pause_copy_button: Button = null
var _pause_join_input: LineEdit = null
var _pause_join_button: Button = null
var _pause_join_notice: Label = null
var _pause_bot_count_label: Label = null
var _pause_bot_minus_button: Button = null
var _pause_bot_plus_button: Button = null
var _pause_seed_label: Label = null
var _settings_panel: Control = null
func _open_settings() -> void:
	if _settings_panel:
		_settings_panel.queue_free()
	_settings_panel = MenuHelpers.build_settings_panel($HUD, _close_settings)
	if _pause_menu:
		_pause_menu.visible = false
	_settings_panel.visible = true
	MenuHelpers.grab_first_menu_focus(_settings_panel)


func _close_settings() -> void:
	if _settings_panel:
		_settings_panel.queue_free()
		_settings_panel = null
	if _pause_menu:
		_pause_menu.visible = true
		MenuHelpers.grab_first_menu_focus(_pause_menu)


func _on_player_name_committed(new_name: String) -> void:
	var my_id := multiplayer.get_unique_id()
	if my_id != 0:
		NetworkManager._register_player.rpc(my_id, new_name)
	var local_player_node := players_root.get_node_or_null(str(my_id))
	if local_player_node and local_player_node.has_method("set_display_name"):
		local_player_node.set_display_name.rpc(new_name)


func _build_slider_row(label_text: String, value: float, min_val: float, max_val: float, step: float, value_text: String) -> Dictionary:
	return MenuHelpers.build_slider_row(label_text, value, min_val, max_val, step, value_text)


# Last map swap inputs — used by the pause menu's seed label (and any future
# "rejoin same map" feature). Updated in _swap_arena.
var current_map_index: int = 0
var current_map_seed: int = 0


func _refresh_pause_seed_label() -> void:
	if _pause_seed_label == null:
		return
	var map_name: String = "?"
	if current_map_index >= 0 and current_map_index < MAP_POOL.size():
		map_name = MAP_POOL[current_map_index].resource_path.get_file().get_basename()
	_pause_seed_label.text = "%s · seed %d" % [map_name, current_map_seed]


func _pause_host_online() -> void:
	NetworkManager.request_online_host(MenuHelpers.player_name)
	_pause_refresh_game_id()


func _pause_refresh_game_id() -> void:
	# Called whenever the pause menu opens — the iroh server might have been
	# created after _build_pause_menu ran (or torn down because we became a
	# client), so the field is refreshed lazily.
	if _pause_id_field == null:
		return
	var id := NetworkManager.current_iroh_game_id
	var starting := NetworkManager.is_host_starting()
	_pause_id_field.text = id
	var hosting := id != ""
	if id.is_empty() and starting:
		_pause_id_field.placeholder_text = "Starting host..."
	elif id.is_empty():
		_pause_id_field.placeholder_text = "(offline — not hosting)"
	if _pause_host_button:
		_pause_host_button.visible = not hosting
		_pause_host_button.disabled = starting
		_pause_host_button.text = "STARTING..." if starting else "HOST ONLINE"
	_pause_copy_button.disabled = not hosting
	_pause_id_field.editable = false  # always read-only; copying via select+keyboard or button


func _pause_copy_game_id() -> void:
	var id := NetworkManager.current_iroh_game_id
	if id.is_empty():
		return
	DisplayServer.clipboard_set(id)
	# Brief affordance — flash the button label so the user sees something happened.
	if _pause_copy_button:
		var orig := _pause_copy_button.text
		_pause_copy_button.text = "COPIED!"
		await get_tree().create_timer(0.8).timeout
		if is_instance_valid(_pause_copy_button):
			_pause_copy_button.text = orig


func _on_join_input_changed(text: String) -> void:
	var extracted := _extract_iroh_node_id(text)
	if not extracted.is_empty() and extracted != text:
		var old_caret := _pause_join_input.caret_column if _pause_join_input else 0
		_pause_join_input.set_text(extracted)
		_pause_join_input.caret_column = mini(old_caret, extracted.length())
		text = extracted
	_update_join_form()
	if _is_valid_iroh_node_id(text) and not _join_in_progress and _join_auto_submit_text != text:
		_join_auto_submit_text = text
		if not _is_own_iroh_game_id(text):
			call_deferred("_pause_join")


func _update_join_form() -> void:
	var text := _pause_join_input.text.strip_edges() if _pause_join_input else ""
	var valid := _is_valid_iroh_node_id(text)
	var own_id := valid and _is_own_iroh_game_id(text)
	if _pause_join_button:
		_pause_join_button.disabled = _join_in_progress or not valid or own_id
		_pause_join_button.text = "..." if _join_in_progress else "JOIN"
	if _pause_join_notice:
		if _join_in_progress:
			_pause_join_notice.text = "Connecting..."
			_pause_join_notice.add_theme_color_override("font_color", Color(0.76, 0.92, 1.0))
		elif text.is_empty():
			_pause_join_notice.text = "Paste an iroh game ID"
			_pause_join_notice.add_theme_color_override("font_color", Color(0.55, 0.60, 0.72))
		elif own_id:
			_pause_join_notice.text = "That's your own game ID — share it with someone else"
			_pause_join_notice.add_theme_color_override("font_color", Color(1.0, 0.72, 0.42))
		elif valid:
			_pause_join_notice.text = "Valid ID - connecting automatically"
			_pause_join_notice.add_theme_color_override("font_color", Color(0.58, 1.0, 0.65))
		else:
			_pause_join_notice.text = "Paste the full iroh game ID"
			_pause_join_notice.add_theme_color_override("font_color", Color(1.0, 0.62, 0.50))


func _extract_iroh_node_id(text: String) -> String:
	return MenuHelpers.extract_iroh_node_id(text)


func _is_valid_iroh_node_id(text: String) -> bool:
	return MenuHelpers.is_valid_iroh_node_id(text)


func _is_own_iroh_game_id(game_id: String) -> bool:
	return MenuHelpers.is_own_iroh_game_id(game_id)


func _refresh_bot_counter() -> void:
	var count := _bot_ids().size()
	if _pause_bot_count_label:
		_pause_bot_count_label.text = str(count)
	if _pause_bot_minus_button:
		_pause_bot_minus_button.disabled = not multiplayer.is_server() or count <= 0
	if _pause_bot_plus_button:
		_pause_bot_plus_button.disabled = not multiplayer.is_server() or count >= BOT_ID_LIMIT - BOT_ID_BASE


func _pause_add_bot() -> void:
	if not multiplayer.is_server():
		_announce("BOTS ARE HOST-ONLY", 1.5)
		return
	_spawn_bots(1, _current_player_positions())


func _pause_remove_bot() -> void:
	if not multiplayer.is_server():
		_announce("BOTS ARE HOST-ONLY", 1.5)
		return
	_despawn_one_bot()


func _pause_join() -> void:
	if _pause_join_input == null:
		return
	if _join_in_progress:
		return
	var game_id := _extract_iroh_node_id(_pause_join_input.text)
	if not _is_valid_iroh_node_id(game_id):
		_update_join_form()
		return
	if _is_own_iroh_game_id(game_id):
		push_warning("Join blocked: pasted own iroh game ID")
		_update_join_form()
		return
	_pause_join_input.set_text(game_id)
	_join_in_progress = true
	_update_join_form()
	# Tear down the current iroh server (we're switching from host to client),
	# then reload the scene with the new IrohClient peer in place. The reload
	# branches into the `else` arm of _ready (multiplayer.is_server() == false)
	# which waits for connected_to_server before requesting a spawn.
	get_tree().paused = false
	NetworkManager.leave_game()
	if not NetworkManager.join_game_iroh(game_id, MenuHelpers.player_name if not MenuHelpers.player_name.is_empty() else "Player_%d" % (randi() % 1000)):
		_join_in_progress = false
		_update_join_form()
		if not NetworkManager.last_network_error.is_empty():
			_on_network_status_changed(NetworkManager.last_network_error, true)
		return
	get_tree().change_scene_to_file("res://scenes/game.tscn")


func _refresh_pause_splitscreen_btn() -> void:
	if _pause_splitscreen_btn:
		_pause_splitscreen_btn.text = (
			"STOP SPLITSCREEN" if (_splitscreen and _splitscreen.is_enabled())
			else "SPLITSCREEN")


func _pause_toggle_splitscreen() -> void:
	if _splitscreen and _splitscreen.is_enabled():
		_splitscreen.disable()
		_refresh_pause_splitscreen_btn()
		if _pause_menu and _pause_menu.visible:
			_toggle_pause_menu()
		get_tree().paused = false
		_sync_mouse_mode()
		_announce("SPLITSCREEN OFF", 2.0)
		return
	_pause_start_splitscreen()


func _pause_start_splitscreen() -> void:
	if not multiplayer.is_server():
		_announce("SPLITSCREEN IS HOST-ONLY", 2.0)
		return
	NetworkManager.set_meta("splitscreen_on_start", true)
	if _splitscreen and _splitscreen.has_method("enable"):
		var primary_device := _last_controller_device if _last_input_was_controller else -1
		_splitscreen.enable(primary_device)
	_despawn_all_bots()
	pending_picker_id = 0
	pending_pick_cards.clear()
	pending_pick_cards_by_player.clear()
	pending_pick_deadlines.clear()
	completed_picks.clear()
	eliminated_players.clear()
	round_winner_id = 0
	state = State.WAITING
	_hide_card_pick.rpc()
	_hide_rematch_overlay.rpc()
	_broadcast_scores.rpc(round_wins)
	_update_scoreboard()
	if _pause_menu and _pause_menu.visible:
		_toggle_pause_menu()
	get_tree().paused = false
	_sync_mouse_mode()
	# The "PRESS X TO JOIN" hint lives on the persistent _join_label managed
	# by splitscreen_manager — no central banner here, otherwise the host
	# sees the same prompt twice (and one of them sticks around).
	_refresh_splitscreen_hint()


func _pause_restart_match() -> void:
	# Close the pause menu first so the round-start banner is visible.
	if _pause_menu and _pause_menu.visible:
		_toggle_pause_menu()
	if multiplayer.is_server():
		_restart_match()


func _pause_change_mode(mode: String) -> void:
	if not multiplayer.is_server():
		_announce("ONLY HOST CAN CHANGE MODE", 2.0)
		return
	if game_mode == mode:
		_pause_restart_match()
		return

	game_mode = mode
	NetworkManager.set_meta("game_mode", mode)
	_set_game_mode.rpc(mode, 1)
	_update_scoreboard()

	if _pause_menu and _pause_menu.visible:
		_toggle_pause_menu()

	_restart_match()


func _refresh_pause_mode_buttons() -> void:
	if _pause_versus_btn == null or _pause_wave_btn == null:
		return

	var is_host := multiplayer.is_server()
	_pause_versus_btn.disabled = not is_host
	_pause_wave_btn.disabled = not is_host

	if game_mode == GAME_MODE_VERSUS:
		_pause_versus_btn.text = "★ VERSUS MODE (ACTIVE)"
		_pause_wave_btn.text = "SWITCH TO WAVE SURVIVAL"
	else:
		_pause_versus_btn.text = "SWITCH TO VERSUS MODE"
		_pause_wave_btn.text = "★ WAVE SURVIVAL (ACTIVE)"


func _quit_game() -> void:
	get_tree().paused = false
	get_tree().quit()

func show_damage_direction_for(player_id: int, from_pos: Vector3) -> void:
	if _splitscreen and _splitscreen.is_enabled() and _splitscreen.has_method("show_damage_direction_for"):
		if _splitscreen.show_damage_direction_for(player_id, from_pos):
			return
	var renderer := _render_players.get(player_id) as RenderPlayer
	if renderer:
		renderer.show_damage_direction(from_pos)

func _update_scoreboard() -> void:
	if is_coop_mode():
		scoreboard.visible = true
		scoreboard.text = "KILLED   %d/%d" % [
			_coop_wave_kills,
			_coop_wave_enemy_total,
		]
		return
	scoreboard.visible = false
	var lines: Array[String] = ["— ROUNDS —"]
	for id in NetworkManager.players:
		var wins := int(round_wins.get(id, 0))
		var marker := "  ★" if wins >= rounds_to_win else ""
		var pname := str(NetworkManager.players[id])
		lines.append("%s  %d/%d%s" % [pname, wins, rounds_to_win, marker])

	scoreboard.text = "\n".join(lines)

# -------------------- TAB SCOREBOARD OVERLAY --------------------

func _build_tab_overlay() -> void:
	_tab_root = PanelContainer.new()
	_tab_root.anchor_left = 0.5
	_tab_root.anchor_right = 0.5
	_tab_root.anchor_top = 0.12
	_tab_root.anchor_bottom = 0.88
	_tab_root.offset_left = -360.0
	_tab_root.offset_right = 360.0
	_tab_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tab_root.visible = false
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.04, 0.07, 0.93)
	style.set_border_width_all(2)
	style.border_color = Color(1.0, 0.85, 0.4, 0.8)
	style.set_corner_radius_all(6)
	style.content_margin_left = 20
	style.content_margin_right = 20
	style.content_margin_top = 16
	style.content_margin_bottom = 16
	_tab_root.add_theme_stylebox_override("panel", style)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_tab_root.add_child(scroll)
	_tab_content = VBoxContainer.new()
	_tab_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tab_content.add_theme_constant_override("separation", 10)
	scroll.add_child(_tab_content)
	$HUD.add_child(_tab_root)

func _show_tab_overlay() -> void:
	if _tab_root == null:
		_build_tab_overlay()
	_tab_refresh_timer = 0.5
	_refresh_tab_overlay()
	_tab_root.visible = true

func _hide_tab_overlay() -> void:
	if _tab_root:
		_tab_root.visible = false

func _refresh_tab_overlay() -> void:
	for c in _tab_content.get_children():
		c.queue_free()
	var header := Label.new()
	header.text = "CO-OP WAVE %d" % coop_wave if is_coop_mode() else "SCOREBOARD"
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.add_theme_font_size_override("font_size", 28)
	header.add_theme_color_override("font_color", Color(1, 0.9, 0.5))
	_tab_content.add_child(header)
	var sub := Label.new()
	sub.text = "clear the wave, choose cards, survive" if is_coop_mode() else "first to %d rounds wins" % rounds_to_win
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 13)
	sub.add_theme_color_override("font_color", Color(0.65, 0.65, 0.8))
	_tab_content.add_child(sub)
	_tab_content.add_child(HSeparator.new())
	for id in NetworkManager.players:
		_tab_content.add_child(_tab_player_row(int(id)))

func _tab_player_row(id: int) -> Control:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	# Name + kills line
	var hbox := HBoxContainer.new()
	var nlbl := Label.new()
	nlbl.text = str(NetworkManager.players.get(id, "Player"))
	nlbl.add_theme_font_size_override("font_size", 20)
	nlbl.add_theme_color_override("font_color", Color(1, 1, 1))
	nlbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(nlbl)
	var wins := int(round_wins.get(id, 0))
	var score_lbl := Label.new()
	if is_coop_mode():
		score_lbl.text = "ENEMY" if _is_bot_id(id) else "ALLY"
	else:
		score_lbl.text = "%d / %d" % [wins, rounds_to_win]
	score_lbl.add_theme_font_size_override("font_size", 20)
	score_lbl.add_theme_color_override("font_color", Color(1, 0.85, 0.4))
	hbox.add_child(score_lbl)
	var ping_lbl := Label.new()
	ping_lbl.text = _ping_label_for(id)
	ping_lbl.custom_minimum_size = Vector2(82, 0)
	ping_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	ping_lbl.add_theme_font_size_override("font_size", 16)
	ping_lbl.add_theme_color_override("font_color", _ping_color_for(id))
	hbox.add_child(ping_lbl)
	row.add_child(hbox)
	var p_node := players_root.get_node_or_null(str(id))
	# Cards as colored pills (empty for fresh players).
	if p_node and p_node.get("weapon") != null:
		var cards: Array = p_node.weapon.applied_cards
		if cards.is_empty():
			var empty_lbl := Label.new()
			empty_lbl.text = "    (no cards)"
			empty_lbl.add_theme_font_size_override("font_size", 12)
			empty_lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
			row.add_child(empty_lbl)
		else:
			var flow := HFlowContainer.new()
			flow.add_theme_constant_override("h_separation", 6)
			flow.add_theme_constant_override("v_separation", 4)
			for cid in cards:
				var cdata := CardLibrary.by_id(str(cid))
				if cdata.is_empty():
					continue
				flow.add_child(_tab_card_pill(str(cdata.get("name", cid)), cdata.get("color", Color.WHITE)))
			row.add_child(flow)
	return row


func _ping_label_for(id: int) -> String:
	if _is_bot_id(id):
		return "BOT"
	var ping := int(_ping_ms_by_player.get(id, -1))
	if ping < 0:
		return "-- ms"
	return "%d ms" % ping


func _ping_color_for(id: int) -> Color:
	if _is_bot_id(id):
		return Color(0.55, 0.55, 0.65)
	var ping := int(_ping_ms_by_player.get(id, -1))
	if ping < 0:
		return Color(0.65, 0.65, 0.75)
	if ping >= HIGH_PING_WARN_MS:
		return Color(1.0, 0.42, 0.35)
	if ping >= 100:
		return Color(1.0, 0.78, 0.35)
	return Color(0.55, 1.0, 0.65)

func _tab_card_pill(text: String, col: Color) -> Control:
	var pc := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(col.r * 0.22, col.g * 0.22, col.b * 0.22, 0.95)
	sb.border_color = col
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(3)
	sb.content_margin_left = 7
	sb.content_margin_right = 7
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	pc.add_theme_stylebox_override("panel", sb)
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.add_theme_color_override("font_color", col)
	pc.add_child(lbl)
	return pc

func _restart_match() -> void:
	if not multiplayer.is_server():
		return
	_hide_rematch_overlay.rpc()
	_set_game_state.rpc(State.WAITING)
	coop_wave = 1
	current_round = 1
	round_wins.clear()
	for pid in NetworkManager.players:
		round_wins[pid] = 0
	_broadcast_scores.rpc(round_wins)
	_maybe_start_match()
