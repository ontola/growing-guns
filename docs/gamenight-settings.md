# GameNight settings

Growing Guns declares three party settings when launched by GameNight. They are
available to the lobby and phone once the game connects during preparation.
Standalone play keeps its existing defaults.

| Key | Values | Applies |
| --- | --- | --- |
| `rounds_to_win` | 1–30; default 10 | At the start of a new match. Does not shorten a match already in progress. |
| `modifier_chance` | 0–100%; default 30% | Next round. Zero disables random modifiers; 100 guarantees one. The developer menu's forced modifier still takes precedence. Co-op rounds do not use modifiers. |
| `card_pick_seconds` | 3–30 seconds; default 10 | Next card choice. An existing countdown keeps its deadline. As before, there is no deadline when only one human is playing. |

The bridge owns preferences across scene changes. `game.gd` reads them only at
these boundaries. The match goal uses the existing reliable RPC so remote peers
receive the same goal. Invalid values leave the previous accepted value intact.
The SDK re-declares controls after reconnecting; the host replays party choices.
GameNight's saved value can therefore be pending a future round or match.

Run the isolated engine tests:

```sh
python3 tools/test_gamenight_settings.py --godot /path/to/godot
```

They exercise declarations, setting signals, validation, the match-goal RPC,
card-deadline snapshots and the actual random-modifier selector. They do not
render a match or certify controllers. `--settings-output settings.json` exports
the tested declaration for lobby previews. CI runs this on pushes and pull
requests, and before release exports.

An existing downloadable build does not gain these settings until it is rebuilt
and published. GameNight's catalog must then reference the new archive/checksum.
