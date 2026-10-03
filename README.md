# Growing Guns

[Download on itch.io](https://joepio.itch.io/growing-guns)

- Fast paced Multiplayer FPS, the loser of the round picks a card that gives them an upgrade!
- Split-screen & online multiplayer (no-server, using iroh) 

## Development & Deployment

### Headless Compile & Export

To re-compile and export the project for macOS (e.g. for sharing with colleagues):

```bash
tools/build_release.sh         # builds mac + win → build/{macos,windows}/MoreRounds.zip
tools/build_release.sh mac     # macOS only
```

### Remote Playtesting

The build is exported to `build/macos/MoreRounds.zip`. This archive contains the `.app` bundle which can be distributed to other players on the local network.

- **Hosting:** Use the "HOST MATCH" button in the main menu.
- **Joining:** Colleagues can use the auto-discovery list or join via IP using the "JOIN BY IP" field.
- **Solo Play:** Use "VS BOT" to test mechanics without other players.

## GameNight customization

Parties can change rounds to win, round-modifier frequency and card-choice time. See [GameNight settings](docs/gamenight-settings.md) for ranges, timing and tests.

## Assistant controls

See [GameNight settings](docs/gamenight-settings.md) for all supported tweaks, their ranges and when they apply. The phone and lobby assistant discover these controls automatically from the running game.

## GameNight window and audio

Background preparation starts minimized. Only Play and Resume bring the game
into borderless fullscreen; focusing a window never starts a match.

When GameNight detects host music playing, Growing Guns mutes its soundtrack
buses and leaves sound effects audible. When that music pauses or stops, the
game soundtrack returns at the player's existing volume.

After importing the project, run `godot --headless --path . --script
res://tests/gamenight_window.gd` to check startup settings and audio bus behavior.
Windows window visibility and focus still need a rendered lifecycle test.
