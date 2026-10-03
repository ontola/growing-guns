extends Node
## Screen manners for a GameNight session: who is on the TV, and how much of
## the machine your game is allowed to use while nobody is looking at it.
##
## Autoloaded as `GameNightScreen` alongside `GameNight`, and entirely inert
## unless a daemon launched this process. Left to itself it needs no code from
## you at all: it goes quiet at boot, throttles once you report `ready`, takes
## the screen on `start` and `resume`, and gets out of the way on `pause` and
## `dispose`.
##
## It exists because this is the part every integration gets wrong, and it is
## not the part anybody wants to be an expert in. The rules aren't GameNight's
## — they're the window server's:
##
##  * Launching a process activates it, so a game warming behind the one being
##    played will steal the screen unless it hides itself.
##  * A background app cannot take focus from the frontmost one. Handing the
##    screen back is therefore cooperative: on `pause` you must actually leave,
##    or the lobby asks for the screen, is refused, and the party sits looking
##    at a game that has stopped.
##  * Every window-mode change is animated, and asking again mid-animation
##    restarts it — which looks exactly like being ignored.
##
## If your game wants to drive any of this itself, set [member automatic] to
## false and call [method go_quiet] / [method settle] / [method take_the_screen]
## when it suits you. The methods are the same ones the automatic path uses.

## Whether to follow the session lifecycle without being asked. Turn it off if
## your game needs to sequence the window against something of its own.
@export var automatic: bool = true

## Frames per second once warm *and loaded*. High enough to answer the daemon
## promptly, low enough that a game nobody is watching isn't spending a core
## on a still image. The lobby's own frame budget is what this protects.
@export var warm_max_fps: int = 10

## How long to let a window-mode change land before asking again.
const WINDOW_RETRY_MS := 250

## The same, for *leaving* fullscreen — by far the slowest of these, because
## macOS slides a whole Space away and Godot's fullscreen is that native one.
## Asked again too soon, the second request toggles fullscreen back on and the
## window flaps between the two states for as long as you keep asking.
const EXIT_FULLSCREEN_RETRY_MS := 1200

## How long to keep asking to get off the screen before giving up and parking
## the window somewhere nobody can see it. The window server is allowed to
## refuse; the party's lobby is not allowed to end up behind a game that was
## dismissed.
const OFF_SCREEN_DEADLINE_MS := 8000

## Bumped every time the window is asked to do something. Both loops below run
## across frames, so a `start` arriving mid-retry would otherwise be fighting a
## still-running "get off the screen" — the party would watch the game they
## just picked minimise itself. Whoever bumps this last wins.
var _epoch: int = 0

## The frame cap in force before we throttled — the player's own graphics
## setting, most likely, which is not ours to overwrite.
var _fps_before_warm: int = 0

## No window server, no window manners: the retry loops wait on a mode change
## that a headless run can never report. Tests and CI take this path.
var _headless: bool = DisplayServer.get_name() == "headless"


func _ready() -> void:
	# Everything here has to keep working while the rest of the tree is frozen,
	# or a game that pauses itself can never hear that it may resume.
	process_mode = Node.PROCESS_MODE_ALWAYS
	if not GameNight.launched_by_daemon:
		return
	GameNight.process_mode = Node.PROCESS_MODE_ALWAYS
	if not automatic:
		return
	go_quiet()
	# Reporting `ready` is the moment loading ends — and not one frame before,
	# which is why this is a signal rather than a timer.
	GameNight.ready_sent.connect(func(_session: String) -> void: settle())
	GameNight.started.connect(func(_session: String) -> void: take_the_screen("start"))
	GameNight.resumed.connect(func(_session: String) -> void: take_the_screen("resume"))
	GameNight.paused.connect(func(_session: String) -> void: go_quiet("pause"))
	GameNight.disposed.connect(func(_session: String) -> void: go_quiet())



## Get off the screen and shut up. Deliberately *not* a frame cap: warming is
## loading, and loading is what those frames are for — see [method settle].
func go_quiet(why: String = "warm") -> void:
	print("[gamenight][%s] %s: muted and off-screen until start" % [GameNight.game_id, why])
	AudioServer.set_bus_mute(AudioServer.get_bus_index(&"Master"), true)
	unthrottle()
	_epoch += 1
	if not _headless:
		_leave_the_screen(_epoch)


## Loaded, and nobody watching yet: stop spending a core on it.
##
## Called after `ready` has gone out, never before. Throttling during the load
## is self-defeating — a game that streams its world across frames takes ten
## times longer to reach `ready`, and the daemon is sitting waiting on it.
func settle() -> void:
	if Engine.max_fps != warm_max_fps:
		_fps_before_warm = Engine.max_fps
	Engine.max_fps = warm_max_fps


## Back to the frame budget the player's own settings asked for.
func unthrottle() -> void:
	if Engine.max_fps == warm_max_fps:
		Engine.max_fps = _fps_before_warm


## We're the game being played: full speed, sound on, screen ours.
func take_the_screen(why: String = "start") -> void:
	print("[gamenight][%s] %s: taking the screen" % [GameNight.game_id, why])
	AudioServer.set_bus_mute(AudioServer.get_bus_index(&"Master"), false)
	unthrottle()
	_epoch += 1
	if not _headless:
		_claim_the_screen(_epoch)


## Minimising is the portable "not on screen" — Godot has no equivalent of
## AppKit's app-level hide.
##
## Asked repeatedly until it takes, rather than once after a fixed wait: the
## window may not be realized yet, and anything set before it exists is
## silently dropped. A fixed wait is either too short (the request vanishes and
## a warm game sits on the party's screen all night) or too long — and it is
## always too long, because the window is up and visible for every frame of it.
func _leave_the_screen(epoch: int) -> void:
	var asked_at := -EXIT_FULLSCREEN_RETRY_MS
	var deadline := Time.get_ticks_msec() + OFF_SCREEN_DEADLINE_MS
	while epoch == _epoch:
		var mode := DisplayServer.window_get_mode()
		if mode == DisplayServer.WINDOW_MODE_MINIMIZED:
			return
		var now := Time.get_ticks_msec()
		if now >= deadline:
			_hide_by_force()
			return
		# One transition at a time, and fullscreen first. Miniaturising a
		# fullscreen window is a two-step move — out of the Space, then into
		# the Dock — and asking for the destination while the first step is
		# still animating gets the whole thing restarted.
		if OS.get_name() == "Windows":
			if now - asked_at >= WINDOW_RETRY_MS:
				DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MINIMIZED)
				asked_at = now
		elif mode == DisplayServer.WINDOW_MODE_FULLSCREEN \
				or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN:
			if now - asked_at >= EXIT_FULLSCREEN_RETRY_MS:
				DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
				asked_at = now
		elif now - asked_at >= WINDOW_RETRY_MS:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MINIMIZED)
			asked_at = now
		await get_tree().process_frame


## The window server won't put us in the Dock, so put ourselves where nobody
## has to look at us: no focus, parked off the side of the display.
##
## A poor substitute for minimising — the window still exists and still costs a
## compositor pass — but "a game the party dismissed is still on their TV" is
## the one outcome that must never survive a refusal.
func _hide_by_force() -> void:
	print("[gamenight][%s] could not minimise; parking the window off-screen" % GameNight.game_id)
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	var screen := DisplayServer.screen_get_size(DisplayServer.window_get_current_screen())
	DisplayServer.window_set_position(Vector2i(screen.x + 64, 0))


## The same "ask until it takes" shape in the other direction, and for the same
## reason it can't be a single call: deminiaturising is animated, and a
## fullscreen request that lands while the window is still climbing out of the
## Dock is dropped on the floor — which printed "taking the screen" and then
## left the party looking at whatever was behind us.
func _claim_the_screen(epoch: int) -> void:
	# Whatever `_hide_by_force` may have done to us, undone. A no-focus window
	# ignores every input except mouse clicks, which in a room full of
	# controllers is a game nobody can play. The same flag is how a project
	# should *launch* under a daemon (`display/window/size/no_focus=true`), so
	# that warming never steals the screen from the match in progress.
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, false)
	var asked_at := -WINDOW_RETRY_MS
	while epoch == _epoch:
		var mode := DisplayServer.window_get_mode()
		if mode == DisplayServer.WINDOW_MODE_FULLSCREEN \
				or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN:
			DisplayServer.window_move_to_foreground()
			return
		var now := Time.get_ticks_msec()
		if now - asked_at >= WINDOW_RETRY_MS:
			if mode == DisplayServer.WINDOW_MODE_MINIMIZED and OS.get_name() != "Windows":
				DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			else:
				# FULLSCREEN, not EXCLUSIVE: on macOS the exclusive one is a
				# native fullscreen Space, which hides the lobby somewhere the
				# party can't get back to.
				DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
			DisplayServer.window_move_to_foreground()
			asked_at = now
		await get_tree().process_frame


## OS focus never requests gameplay. Only Start/Resume messages can do that.
func _on_focus_in() -> void:
	pass
