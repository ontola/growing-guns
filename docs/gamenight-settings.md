# GameNight settings

These options are declared over GameNight's typed settings protocol. The phone and lobby assistant discover the same keys, labels, ranges and current values. No game-specific model prompt is required.

| Key | Control and timing | Values | Default |
| --- | --- | --- | --- |
| `rounds_to_win` | Rounds to win (next match) | 1 to 30 | `10` |
| `modifier_chance` | Modifiers % (next round) | 0 to 100 | `30` |
| `card_pick_seconds` | Card time, s (next pick) | 3 to 30 | `10` |
| `gravity` | Gravity % (next round) | 25 to 175 | `100` |
| `bullet_drop` | Bullet drop % (next round) | 0 to 200 | `100` |
| `body_damage` | Body shot damage % (next round) | 50 to 200 | `100` |
| `pickup_rate` | Random pickup rate % (next round) | 0 to 200 | `100` |

The four physics/combat percentages multiply the active round modifiers. They do not replace weapon cards. The host applies one snapshot at round start and sends it to every peer, including late joiners. Body damage does not change the headshot multiplier. Random pickup rate affects timed spawns; scripted modifier rewards remain. Zero disables timed spawns. Changing card time does not extend an open card choice. As before, one human player has no card deadline. Modifier chance affects random versus modifiers; the developer menu's forced modifier takes precedence, and co-op rounds do not use random modifiers.

All numeric inputs are integers. Invalid types, unknown keys and values outside the declared range leave the previous value intact. Live options update without restarting; structural options wait for the boundary named in the label. Party choices use GameNight's existing saved configurations and Undo/Keep flow.

The lobby owns seats and controller bindings. These options cannot add human players, remap controllers or write arbitrary engine variables. Renderer/debug internals are not exposed as gameplay controls.

## Verification

The headless settings tests exercise validation and gameplay effects. The public `scripts/test-godot-settings.py` in the GameNight repo also runs the actual game against a real daemon and checks typed updates and Undo. These source checks do not certify older downloaded binaries.

Run `python3 tools/test_gamenight_settings.py --godot /path/to/godot`.

The SDK re-declares settings after reconnecting and the host replays party choices. The bridge keeps preferences across scene changes. Use `--settings-output settings.json` with the test runner to export the tested declaration. CI runs the suite before release exports.

Existing downloads need to be rebuilt and published, then referenced by archive and checksum in the GameNight catalog.
