extends Node
## Turns GameNight's controller stream into Godot joypads, one per local seat.
##
## Under a daemon the party's controllers belong to GameNight: a seat names an
## opaque controller token, not a Godot joystick index, and
## `GameNight.devices_for_local_seats` returns nothing. The game, though, reads
## a player's pad by device id everywhere (player movement and aim, the card
## pick, the input map). So each local seat gets a virtual device id, and every
## physics tick its host frame is replayed into `Input` as joypad events on
## that id. Seated players never read the physical pads, which also means the
## host decides who drives whom, not the order Windows enumerated them in.

## Well past any real joystick Godot will number.
const DEVICE_BASE := 64

## Host button bit (GameNight.BUTTON_*) -> Godot button. Back (6) belongs to
## GameNight and is left out.
const BUTTONS := {
	0: JOY_BUTTON_A,
	1: JOY_BUTTON_B,
	2: JOY_BUTTON_X,
	3: JOY_BUTTON_Y,
	4: JOY_BUTTON_LEFT_SHOULDER,
	5: JOY_BUTTON_RIGHT_SHOULDER,
	7: JOY_BUTTON_START,
	8: JOY_BUTTON_LEFT_STICK,
	9: JOY_BUTTON_RIGHT_STICK,
	10: JOY_BUTTON_DPAD_UP,
	11: JOY_BUTTON_DPAD_DOWN,
	12: JOY_BUTTON_DPAD_LEFT,
	13: JOY_BUTTON_DPAD_RIGHT,
}
## Host axis index -> Godot axis. Same order, spelled out so a reader can check.
const AXES := [
	JOY_AXIS_LEFT_X, JOY_AXIS_LEFT_Y, JOY_AXIS_RIGHT_X, JOY_AXIS_RIGHT_Y,
	JOY_AXIS_TRIGGER_LEFT, JOY_AXIS_TRIGGER_RIGHT,
]
const ACTIVITY_THRESHOLD := 0.3

## device id -> host seat index
var _seats: Dictionary = {}
## device id -> {"buttons": int, "axes": Array[float]} as last replayed
var _last: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


## A device id per local seat of `seats`, in seat order. Replaces any earlier
## binding (and releases its buttons).
func bind(seats: Array) -> Array:
	release_all()
	_seats.clear()
	var devices: Array = []
	for seat in seats:
		if typeof(seat) != TYPE_DICTIONARY:
			continue
		if str((seat.get("occupant", {}) as Dictionary).get("kind", "")) != "local":
			continue
		var device := DEVICE_BASE + devices.size()
		_seats[device] = int(seat.get("index", -1))
		# A button still held from the lobby (the A that pressed Start) must
		# be let go first, so one press never does two things.
		var held := int(GameNight.frame_for_seat(_seats[device], true).get("buttons", 0))
		_last[device] = {"buttons": held, "axes": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]}
		devices.append(device)
	return devices


func is_seat_device(device: int) -> bool:
	return _seats.has(device)


## Let go of everything, so nothing stays held across a pause or a new match.
func release_all() -> void:
	for device in _last.keys():
		_replay(device, {})
	_last.clear()


func _physics_process(_delta: float) -> void:
	for device in _seats.keys():
		var seat_index: int = _seats[device]
		# Empty while paused or when the host's input is stale: neutral.
		var frame := GameNight.frame_for_seat(seat_index)
		if _replay(device, frame):
			GameNight.report_activity(seat_index)


## Send what changed since the last frame. True while the person is doing
## something worth calling activity (a button held, or a stick or trigger
## pushed well in); GameNight sends that at most once a second.
func _replay(device: int, frame: Dictionary) -> bool:
	var last: Dictionary = _last.get(device, {"buttons": 0, "axes": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]})
	var buttons := int(frame.get("buttons", 0))
	var changed := buttons ^ int(last["buttons"])
	for bit in BUTTONS:
		if changed & (1 << bit) == 0:
			continue
		var event := InputEventJoypadButton.new()
		event.device = device
		event.button_index = BUTTONS[bit]
		event.pressed = buttons & (1 << bit) != 0
		event.pressure = 1.0 if event.pressed else 0.0
		Input.parse_input_event(event)
	last["buttons"] = buttons
	var active := buttons != 0
	var axes: Array = last["axes"]
	for i in AXES.size():
		var value := GameNight.axis(frame, i)
		active = active or absf(value) >= ACTIVITY_THRESHOLD
		if is_equal_approx(value, float(axes[i])):
			continue
		var event := InputEventJoypadMotion.new()
		event.device = device
		event.axis = AXES[i]
		event.axis_value = value
		Input.parse_input_event(event)
		axes[i] = value
	_last[device] = last
	return active
