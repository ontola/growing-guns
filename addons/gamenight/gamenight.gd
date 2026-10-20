extends Node
## GameNight SDK for Godot 4.
##
## Autoloaded as `GameNight` by the plugin. The integration contract:
##
## 1. Set [member game_id] (project settings or before the first frame).
## 2. Connect to [signal prepared]: load your level, bind inputs to the given
##    seats, then call [method notify_ready]. Don't show anything yet.
## 3. Connect to [signal started]: you are live — start the match instantly.
## 4. When the match ends, call [method notify_finished] and keep rendering
##    until [signal disposed], then tear the session down. A new `prepared`
##    may follow later in the night.
##
## Seats and players arrive as plain Dictionaries matching docs/protocol.md.

## Session lifecycle -----------------------------------------------------------

## Warm up: load everything for these seats, then call notify_ready().
signal prepared(session_id: String, seats: Array, players: Array)
## The transition landed on you. Start the match NOW.
signal started(session_id: String)
signal paused(session_id: String)
signal resumed(session_id: String)
## Tear the session down; the id will never be used again.
signal disposed(session_id: String)

## Connection ------------------------------------------------------------------

signal daemon_connected
signal daemon_disconnected
## Fresh party snapshot (players, seats, playlist, vote...).
signal party_updated(party: Dictionary)
signal controllers_changed(controllers: Array)
signal roster_changed(seats: Array, players: Array, presence: Array)
## The party changed one of the settings you declared with
## declare_settings(). Apply it live when safe, or at the next round boundary.
## State that timing in the label. `value` is a bool, int or String.
signal setting_changed(key: String, value: Variant)

const PROTOCOL := preload("protocol.gd")
const PROTOCOL_VERSION := PROTOCOL.PROTOCOL_VERSION
## This addon's version. GameNight's welcome names the version it ships
## (GODOT_SDK_VERSION in gamenight-protocol); an older copy warns, because a
## vendored addon that fell behind fails quietly. Bump both together.
const SDK_VERSION := PROTOCOL.GODOT_SDK_VERSION
const RECONNECT_DELAY := 2.0

## Which title this process runs. Must match the playlist entry's game id.
## Overridden by GAMENIGHT_GAME_ID when the daemon launched us.
@export var game_id: String = ProjectSettings.get_setting("application/config/name", "godot-game").to_lower()
@export var daemon_url: String = "ws://" + PROTOCOL.DEFAULT_ADDR
## Reconnect automatically while the daemon is away.
@export var auto_reconnect: bool = true
## A game started by hand (not by GameNight) stays offline, so a test run never
## joins the party on this machine. Set GAMENIGHT_ADDR, or turn this on, to
## connect a hand-started game to a development host anyway.
@export var connect_standalone: bool = false

var party: Dictionary = {}
var session := ""
var phase := "idle"
var _frames: Dictionary = {}
var _frame_at := -10000
## True when this process was launched by a GameNight daemon (GAMENIGHT=1).
## Games use this to skip their menu and boot straight into party mode.
var launched_by_daemon: bool = false

var _launch_token: String = ""

var _socket: WebSocketPeer
var _said_hello := false
var _reconnect_at := 0.0
var _performance_session := ""
var _performance_running := false
var _performance_last_us := 0
var _performance_sent_us := 0
var _performance: Dictionary = {}

func _reset_performance(session_id: String) -> void:
	_performance_session = session_id
	_performance_running = false
	_performance_last_us = 0
	_performance_sent_us = 0
	_performance = {"frames":0,"elapsed_us":0,"slow_frames":0,"max_frame_us":0,
		"cpu":OS.get_processor_name().left(128),"gpu":RenderingServer.get_video_adapter_name().left(128),
		"os":OS.get_name(),"memory_mib":int(OS.get_memory_info().get("physical",0)/1048576)}

func _sample_performance() -> void:
	var now_us := Time.get_ticks_usec()
	if not _performance_running or _performance_session.is_empty():
		_performance_last_us = 0
		return
	var elapsed_us := now_us - _performance_last_us if _performance_last_us > 0 else 0
	_performance_last_us = now_us
	# Skip OS suspension; report actual frame intervals rather than scaled game time.
	if elapsed_us <= 0 or elapsed_us > 2000000:
		return
	_performance.frames += 1
	_performance.elapsed_us += elapsed_us
	_performance.slow_frames += int(elapsed_us > 33333)
	_performance.max_frame_us = maxi(_performance.max_frame_us,elapsed_us)
	if _performance.elapsed_us - _performance_sent_us >= 10000000:
		var size := DisplayServer.window_get_size()
		_performance.width = size.x
		_performance.height = size.y
		_send({"type":PROTOCOL.MSG_PERFORMANCE,"session":_performance_session,"sample":_performance})
		_performance_sent_us = _performance.elapsed_us

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# The daemon passes the handshake via environment — same binary boots
	# into game-night mode when launched, runs standalone otherwise.
	launched_by_daemon = OS.get_environment(PROTOCOL.ENV_GAMENIGHT) == "1"
	var env_game_id := OS.get_environment(PROTOCOL.ENV_GAME_ID)
	if env_game_id != "":
		game_id = env_game_id
	var env_addr := OS.get_environment(PROTOCOL.ENV_ADDR)
	if env_addr != "":
		daemon_url = "ws://%s" % env_addr
	var env_overlay_url := OS.get_environment(PROTOCOL.ENV_OVERLAY_URL)
	if env_overlay_url != "":
		overlay_url = env_overlay_url
	_launch_token = OS.get_environment(PROTOCOL.ENV_TOKEN)
	if not launched_by_daemon and env_addr == "" and not connect_standalone:
		auto_reconnect = false
		return
	_open()

## Connect a hand-started game to the host at [member daemon_url] after all,
## for example from a debug menu. GameNight-launched games are always online.
func connect_to_host() -> void:
	auto_reconnect = true
	if _socket == null:
		_open()

func _open() -> void:
	_socket = WebSocketPeer.new()
	_socket.inbound_buffer_size = 16 * 1024 * 1024
	_socket.max_queued_packets = 256
	_said_hello = false
	var err := _socket.connect_to_url(daemon_url)
	if err != OK:
		push_warning("GameNight: cannot reach daemon at %s (%s)" % [daemon_url, err])
		_schedule_reconnect()

func _process(_delta: float) -> void:
	if _socket == null:
		if auto_reconnect and Time.get_ticks_msec() / 1000.0 >= _reconnect_at:
			_open()
		return
	_socket.poll()
	match _socket.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			_sample_performance()
			if not _said_hello:
				_said_hello = true
				var hello := {"type": PROTOCOL.MSG_HELLO, "role": PROTOCOL.ROLE_GAME, "game": game_id}
				if _launch_token != "":
					hello["token"] = _launch_token
				_send(hello)
			while _socket.get_available_packet_count() > 0:
				var text := _socket.get_packet().get_string_from_utf8()
				_handle(JSON.parse_string(text))
		WebSocketPeer.STATE_CLOSED:
			_frames.clear()
			_performance_running = false
			if _said_hello:
				daemon_disconnected.emit()
			_socket = null
			_schedule_reconnect()

func _schedule_reconnect() -> void:
	if launched_by_daemon:
		_frames.clear()
		phase = "idle"
		auto_reconnect = false
		get_tree().quit()
		return
	_reconnect_at = Time.get_ticks_msec() / 1000.0 + RECONNECT_DELAY

## Emitted the moment `ready` goes out, so anything that has been waiting for
## the load to finish can act on it — see screen.gd, which stops spending a
## core on a match nobody is watching yet.
signal ready_sent(session_id: String)

## Assets loaded, controllers mapped: the session can start instantly.
func notify_ready(session_id: String) -> void:
	if session_id != session or phase != "preparing": return
	phase = "ready"
	_send({"type": PROTOCOL.MSG_READY, "session": session_id})
	ready_sent.emit(session_id)

## Report a completed round. Keep your results screen and next-round flow in game.
func notify_finished(session_id: String) -> void:
	_send({"type": PROTOCOL.MSG_FINISHED, "session": session_id})

## Opt into live roster updates ([signal roster_changed]) for this session.
## Call it from [signal prepared], before [method notify_ready]. Pass
## `instant_join = true` only when a running match can take a new player at
## once; with false, newcomers wait for your next round.
func notify_participation(session_id: String, instant_join: bool) -> void:
	_send({"type": PROTOCOL.MSG_PARTICIPATION, "session": session_id, "instant_join": instant_join})

var _activity_at: Dictionary = {}

## Tell GameNight a person is really playing on this seat's controller, so the
## party does not mark them asleep. Call it on meaningful input (a press, a
## stick past its deadzone); it sends at most once a second per controller.
func report_activity(seat_index: int) -> void:
	if session.is_empty(): return
	var token := _controller_for_seat(seat_index)
	if token.is_empty(): return
	var now := Time.get_ticks_msec()
	if now - int(_activity_at.get(token, -100000)) < 1000: return
	_activity_at[token] = now
	_send({"type": PROTOCOL.MSG_CONTROLLER_INPUT, "session": session, "controller": token})

## Declare the match settings the party may change (items on/off, stock
## count, arena...). Call once, any time after _ready(); the addon re-declares
## automatically after every reconnect. Each entry is a Dictionary matching
## docs/protocol.md, e.g.:
##   { "key": "items", "label": "Items", "kind": "toggle", "default": true }
##   { "key": "stock", "label": "Stock", "kind": "number",
##     "default": 3, "min": 1, "max": 99 }
##   { "key": "arena", "label": "Arena", "kind": "choice",
##     "default": "meadow", "options": ["meadow", "volcano"] }
## Changes arrive via [signal setting_changed]; values the party already
## picked survive reconnects and are replayed right after declaring.
func declare_settings(settings: Array) -> void:
	_declared_settings = settings
	_send({"type": PROTOCOL.MSG_DECLARE_SETTINGS, "settings": settings})

var _declared_settings: Array = []

## Change one of this game's declared settings, for example from its own
## Start menu, so the party's apps (and an LLM) show the same value. The daemon
## validates it and answers with [signal setting_changed], like any other write.
func set_setting(key: String, value: Variant) -> void:
	_send({"type": PROTOCOL.MSG_SET_SETTING, "key": key, "value": value})

## Optional: give each player a screen of their own on their phone (see
## "Phone screens" in docs/protocol.md). `root` is an absolute directory the
## host's web server may serve, `entry` a page inside it, and `app` a native
## phone app: { "name": ..., "android": "com.example.app", "download":
## "file-in-root.apk" or "https://..." }. Pass a page, an app or both.
## Re-declared automatically after every reconnect.
func declare_companion(root: String = "", entry: String = "", app: Dictionary = {}) -> void:
	var msg := {"type": PROTOCOL.MSG_DECLARE_COMPANION}
	if not root.is_empty(): msg["root"] = root
	if not entry.is_empty(): msg["entry"] = entry
	if not app.is_empty(): msg["app"] = app
	_declared_companion = msg
	_send(msg)

var _declared_companion: Dictionary = {}

## Serve a folder of the game, such as "res://phone", as the phone screen.
## The host serves pages from a real directory, which an exported game does
## not have, so this copies the folder to user:// first and declares that copy.
## Keep raw files in the export: add the folder to the export preset's
## include filter, and set PNG and font files to the "Keep File" importer.
## Warns when the folder would not fit a hosted room (see docs/protocol.md).
func declare_companion_folder(folder: String = "res://phone", entry: String = "index.html", app: Dictionary = {}) -> String:
	var target := "user://gamenight-phone"
	var files := _companion_files(folder, "")
	if files.is_empty():
		push_warning("GameNight: no phone screen files found in %s" % folder)
		return ""
	DirAccess.make_dir_recursive_absolute(target)
	var total := 0
	for path in files:
		var data := FileAccess.get_file_as_bytes(folder.path_join(path))
		var encoded := int(ceil(data.size() / 3.0)) * 4
		total += encoded
		if encoded > 512 * 1024:
			push_warning("GameNight: phone file %s is %d KiB in a hosted room; the limit is 512 KiB" % [path, encoded >> 10])
		if not path.get_extension().to_lower() in COMPANION_TYPES:
			push_warning("GameNight: hosted rooms do not serve phone file %s (use HTML, JS, CSS, JSON, SVG, PNG, JPEG, WebP or WOFF2)" % path)
		DirAccess.make_dir_recursive_absolute(target.path_join(path.get_base_dir()))
		var out := FileAccess.open(target.path_join(path), FileAccess.WRITE)
		if out == null: continue
		out.store_buffer(data)
		out.close()
	if files.size() > 128 or total > 2 * 1024 * 1024:
		push_warning("GameNight: the phone screen is %d files, %d KiB in a hosted room; the limit is 128 files, 2048 KiB" % [files.size(), total >> 10])
	var root := ProjectSettings.globalize_path(target)
	declare_companion(root, entry, app)
	return root

const COMPANION_TYPES := ["html", "htm", "js", "mjs", "css", "json", "svg", "png", "jpg", "jpeg", "webp", "woff2", "apk"]

func _companion_files(folder: String, prefix: String) -> Array:
	var found: Array = []
	var dir := DirAccess.open(folder.path_join(prefix))
	if dir == null: return found
	for name in dir.get_files():
		if name.ends_with(".import"):
			if not dir.file_exists(name.trim_suffix(".import")):
				push_warning("GameNight: %s was imported, not exported raw; set its importer to Keep File" % prefix.path_join(name.trim_suffix(".import")))
			continue
		if name.ends_with(".uid") or name.ends_with(".remap"): continue
		found.append(prefix.path_join(name))
	for sub in dir.get_directories():
		found.append_array(_companion_files(folder, prefix.path_join(sub)))
	return found

## Send JSON to one player's phone page, or to every phone when `player_id`
## is empty. Answers arrive via [signal companion_message].
func send_companion_message(data: Variant, player_id: String = "") -> void:
	var msg := {"type": PROTOCOL.MSG_COMPANION_MESSAGE, "data": data}
	if not player_id.is_empty(): msg["player_id"] = player_id
	_send(msg)

## A player's phone page sent [param data]. Treat it as untrusted input.
signal companion_message(player_id: String, data: Variant)
## A player's phone page opened or closed; send them their view on connect.
signal companion_presence(player_id: String, connected: bool)

## Optional: how far along warming is (0-100), so the lobby's screen can show
## the party something truthful while they wait instead of an unchanging
## "loading". Send as often as is useful; the daemon keeps the latest. A game
## that loads instantly never needs to call this.
func notify_progress(session_id: String, percent: int, label: String = "") -> void:
	var msg := {"type": PROTOCOL.MSG_PROGRESS, "session": session_id, "percent": clampi(percent, 0, 100)}
	if label != "":
		msg["label"] = label
	_send(msg)


## A player asked to get back to the party. The daemon pauses this session and
## puts the lobby back on screen — the game does not have to do anything else.
##
## The one party command a game is allowed to send: a player stuck inside a
## game with no way out is the one failure the party cannot fix themselves.
func request_overlay() -> void:
	_send({"type": PROTOCOL.MSG_REQUEST_OVERLAY})


## A player reached for this window directly — Cmd+Tab, a Dock click, a click
## on the window — rather than going through the party. The pair to
## `request_overlay`: we report what the human did, the daemon decides what it
## means (start us if we're warm, resume us if we're paused, ignore it
## otherwise). Safe to send whenever focus arrives.
func request_start() -> void:
	_send({"type": PROTOCOL.MSG_REQUEST_START})


## ── Seats ──────────────────────────────────────────────────────────────────

## How many of `seats` hold a person on this machine. This, not the number of
## pads you can see, is your player count.
func local_seat_count(seats: Array) -> int:
	var n := 0
	for seat in seats:
		if typeof(seat) == TYPE_DICTIONARY \
				and str((seat.get("occupant", {}) as Dictionary).get("kind", "")) == PROTOCOL.SEAT_OCCUPANT_LOCAL:
			n += 1
	return n


## How many seats the party wants a bot in. The daemon fills empty seats up to
## your declared `min_players`, so this is usually all the fallback you need
## for "only one person turned up".
func ai_seat_count(seats: Array) -> int:
	var n := 0
	for seat in seats:
		if typeof(seat) == TYPE_DICTIONARY \
				and str((seat.get("occupant", {}) as Dictionary).get("kind", "")) == PROTOCOL.SEAT_OCCUPANT_AI:
			n += 1
	return n


## Standalone-only convenience. Managed games must use frame_for_seat instead.
func devices_for_local_seats(count: int) -> Array:
	if launched_by_daemon:
		push_warning("Use frame_for_seat: local device indices do not identify GameNight players.")
		return []
	var devices: Array = Array(Input.get_connected_joypads()).slice(0,count)
	if devices.size() < count: devices.append(-1)
	return devices

## Canonical host input for a seat index. Missing/disconnected/stale input is neutral.
## Input is empty while the session is not running; pass `any_phase = true`
## to read it anyway, for example for your own Start menu.
func frame_for_seat(index: int, any_phase: bool = false) -> Dictionary:
	if (phase != "running" and not any_phase) or Time.get_ticks_msec()-_frame_at >= 250: return {}
	var token := _controller_for_seat(index)
	return _frames.get(token,{}).duplicate(true) if not token.is_empty() else {}

func _controller_for_seat(index: int) -> String:
	for seat in party.get("seats",[]):
		if int(seat.get("index",-1)) == index:
			return str(seat.get("controller",""))
	return ""

## Button bits and axis indices of a controller frame (docs/protocol.md).
const BUTTON_A := 0
const BUTTON_B := 1
const BUTTON_X := 2
const BUTTON_Y := 3
const BUTTON_LB := 4
const BUTTON_RB := 5
const BUTTON_BACK := 6 ## Owned by GameNight: never bind it in a game.
const BUTTON_START := 7
const BUTTON_LS := 8
const BUTTON_RS := 9
const BUTTON_UP := 10
const BUTTON_DOWN := 11
const BUTTON_LEFT := 12
const BUTTON_RIGHT := 13
const AXIS_LEFT_X := 0
const AXIS_LEFT_Y := 1
const AXIS_RIGHT_X := 2
const AXIS_RIGHT_Y := 3
const AXIS_LEFT_TRIGGER := 4
const AXIS_RIGHT_TRIGGER := 5
## Deadzones our games settled on.
const STICK_DEADZONE := 0.15
const TRIGGER_DEADZONE := 0.06

## A stick as a Vector2 with a radial deadzone, rescaled so it starts at 0.
## `side` 0 is the left stick, 1 the right one. Up is negative y.
static func stick(frame: Dictionary, side: int = 0, deadzone: float = STICK_DEADZONE) -> Vector2:
	var v := Vector2(axis(frame, side * 2), axis(frame, side * 2 + 1))
	var length := v.length()
	if length <= deadzone: return Vector2.ZERO
	return v / length * minf((length - deadzone) / (1.0 - deadzone), 1.0)

## A trigger from 0 to 1 with a deadzone. `side` 0 is the left trigger.
static func trigger(frame: Dictionary, side: int = 0, deadzone: float = TRIGGER_DEADZONE) -> float:
	var t := maxf(axis(frame, AXIS_LEFT_TRIGGER + side), 0.0)
	return 0.0 if t <= deadzone else (t - deadzone) / (1.0 - deadzone)

var _buttons_now: Dictionary = {}
var _buttons_before: Dictionary = {}

## True on the physics tick a seat's button went down. Read it in
## _physics_process. After Start and Resume a button that is still held from
## the lobby must be released first, so one press never does two things.
func just_pressed(seat_index: int, button_index: int) -> bool:
	var bit := 1 << button_index
	return (int(_buttons_now.get(seat_index, 0)) & bit) != 0 and (int(_buttons_before.get(seat_index, 0)) & bit) == 0

func _physics_process(_delta: float) -> void:
	_buttons_before = _buttons_now.duplicate()
	_buttons_now = {}
	for seat in party.get("seats",[]):
		var index := int(seat.get("index",-1))
		_buttons_now[index] = int(frame_for_seat(index, true).get("buttons", 0))

func _hold_buttons() -> void:
	for index in _buttons_now.keys():
		_buttons_now[index] = 0x3FFF

static func axis(frame: Dictionary, index: int) -> float:
	var axes: Array = frame.get("axes",[])
	return clampf(float(axes[index])/32767.0,-1,1) if index>=0 and index<axes.size() else 0.0

static func button(frame: Dictionary, index: int) -> bool:
	return index>=0 and index<14 and (int(frame.get("buttons",0)) & (1<<index)) != 0


func _send(msg: Dictionary) -> void:
	if _socket != null and _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_socket.send_text(JSON.stringify(msg))

## Raise the real party overlay ---------------------------------------------
##
## Nobody should be stranded inside a game with no way back to the party.
## The controller Back/Select button (or F1) raises the *actual* browser
## overlay (overlay/index.html) rather than building a second, inevitably
## inconsistent copy of it inside every engine. Bringing that window to the
## front already pauses the game and opens the party UI on its own — see
## the `focus`/`blur` handling in overlay/index.html — so the game's only
## job here is to raise it.
##
## Deliberately NOT the Guide/Home button: iOS/macOS (GCController) and most
## consoles reserve that button at the OS/shell level and never deliver it to
## the app at all (on a Mac it opens Game Center/Arcade instead) — there's no
## portable way for an engine to intercept it. Back/Select is unclaimed by
## every integration so far and isn't reserved by any platform shell.
##
## Set [member overlay_url] (or `GAMENIGHT_OVERLAY_URL`) to the overlay's
## URL/file path once per machine. Left unset, this is a no-op — deliberately
## no in-game substitute gets built.
@export var overlay_url: String = ""

func _unhandled_input(event: InputEvent) -> void:
	var back: bool = false
	if event is InputEventJoypadButton:
		back = event.button_index == JOY_BUTTON_BACK and event.pressed
	var f1: bool = false
	if event is InputEventKey:
		f1 = event.pressed and not event.echo and event.keycode in [KEY_F1, KEY_F12]
	if not (back or f1):
		return
	# Under a daemon this is a real "back to the party": it pauses us and puts
	# the lobby on screen, which is the whole point — no second, inevitably
	# inconsistent copy of the party UI inside every engine. Only fall back to
	# opening the overlay URL when there is no daemon to ask.
	if launched_by_daemon:
		if f1: request_overlay() # The host already handles physical Back/Select.
	else:
		_raise_overlay()

func _raise_overlay() -> void:
	if overlay_url == "":
		push_warning("GameNight: overlay_url not set (GAMENIGHT_OVERLAY_URL) — cannot raise the party overlay")
		return
	OS.shell_open(overlay_url)

func _handle(msg: Variant) -> void:
	if typeof(msg) != TYPE_DICTIONARY:
		return
	var kind: String = msg.get("type", "")
	if kind in [PROTOCOL.MSG_START, PROTOCOL.MSG_PAUSE, PROTOCOL.MSG_RESUME, PROTOCOL.MSG_DISPOSE, PROTOCOL.MSG_PARTY_UPDATED] and (session.is_empty() or msg.get("session","") != session): return
	match kind:
		PROTOCOL.MSG_WELCOME:
			if int(msg.get("godot_sdk", 0)) > SDK_VERSION:
				push_warning("GameNight: this game's addons/gamenight (version %d) is older than GameNight's (%d). Update it with sdk/godot/sync.py." % [SDK_VERSION, int(msg.get("godot_sdk", 0))])
			party = msg.get("party", {})
			daemon_connected.emit()
			party_updated.emit(party)
			# A reconnect: re-declare so the daemon replays any values the
			# party changed while we were away.
			if not _declared_settings.is_empty():
				_send({"type": PROTOCOL.MSG_DECLARE_SETTINGS, "settings": _declared_settings})
			if not _declared_companion.is_empty():
				_send(_declared_companion)
		PROTOCOL.MSG_PARTY_STATE:
			party = msg.get("party", {})
			party_updated.emit(party)
		PROTOCOL.MSG_CONTROLLER_FRAME:
			_frames.clear()
			_frame_at = Time.get_ticks_msec()
			for frame in msg.get("controllers",[]):
				var token := str(frame.get("controller",""))
				if not token.is_empty() and not _frames.has(token): _frames[token] = frame
			controllers_changed.emit(msg.get("controllers",[]))
		PROTOCOL.MSG_PARTY_UPDATED:
			for key in ["seats","players","presence"]: party[key] = msg.get(key,[])
			roster_changed.emit(party.seats,party.players,party.presence)
			party_updated.emit(party)
		PROTOCOL.MSG_PREPARE:
			if msg.get("game", game_id) != game_id or msg.get("session", "").is_empty() or msg.get("session", "") == session: return
			if not session.is_empty(): disposed.emit(session)
			session = msg.session
			phase = "preparing"
			_frames.clear()
			party["seats"] = msg.get("seats",[])
			party["players"] = msg.get("players",[])
			_reset_performance(msg.get("session", ""))
			prepared.emit(msg.get("session", ""), msg.get("seats", []), msg.get("players", []))
		PROTOCOL.MSG_START:
			if phase != "ready": return
			phase = "running"
			_performance_running = msg.get("session", "") == _performance_session
			_hold_buttons()
			started.emit(msg.get("session", ""))
		PROTOCOL.MSG_PAUSE:
			if phase != "running": return
			phase = "paused"
			_performance_running = false
			_performance_last_us = 0
			paused.emit(msg.get("session", ""))
		PROTOCOL.MSG_RESUME:
			if phase != "paused": return
			phase = "running"
			_performance_running = msg.get("session", "") == _performance_session
			_hold_buttons()
			resumed.emit(msg.get("session", ""))
		PROTOCOL.MSG_DISPOSE:
			_performance_running = false
			disposed.emit(session)
			session = ""
			phase = "idle"
			_frames.clear()
		PROTOCOL.MSG_SETTING_CHANGED:
			var value: Variant = msg.get("value")
			if value is float:
				# JSON numbers parse as float; number settings are integers.
				value = int(value)
			setting_changed.emit(msg.get("key", ""), value)
		PROTOCOL.MSG_COMPANION_MESSAGE:
			companion_message.emit(str(msg.get("player_id", "")), msg.get("data"))
		PROTOCOL.MSG_COMPANION_PRESENCE:
			companion_presence.emit(str(msg.get("player_id", "")), bool(msg.get("connected", false)))
		PROTOCOL.MSG_ERROR:
			push_warning("GameNight daemon: %s" % msg.get("message", "unknown error"))
