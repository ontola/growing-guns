#!/usr/bin/env bash
# Build macOS + Windows release packages for distribution and (optionally)
# push them to itch.io via butler.
#
# Outputs (relative to project root):
#   build/macos/MoreRounds.zip      — macOS .app bundle, double-clickable
#   build/windows/MoreRounds.zip    — Windows .exe + .pck, also runnable from a folder
#
# Requires:
#   - Godot 4.6 at GODOT_BIN (defaults to /Applications/Godot.app)
#   - Export templates installed for BOTH platforms — run
#     tools/install_export_templates.sh once if missing.
#   - For itch.io upload: butler at tools/bin/butler (auto-installed if you
#     ran tools/install_export_templates.sh's sister script, or manually:
#     curl -sL -o /tmp/b.zip "https://broth.itch.zone/butler/darwin-arm64/LATEST/archive/default" &&
#       unzip -o /tmp/b.zip -d tools/bin && chmod +x tools/bin/butler
#     Then `tools/bin/butler login` once to authenticate.
#
# Versioning:
#   The semver in the VERSION file at project root is passed to butler via
#   --userversion. Bump it before pushing with `--bump patch|minor|major` —
#   the script writes the new value back to VERSION and tags the git HEAD if
#   the working tree is clean.
#
# Usage:
#   tools/build_release.sh                              — build both platforms
#   tools/build_release.sh mac                          — macOS only
#   tools/build_release.sh win                          — Windows only
#   tools/build_release.sh all --itch user/game         — build both AND push
#   tools/build_release.sh all --itch user/game --bump patch
#                                                       — bump VERSION (patch|minor|major)
#                                                         then build + push the new version

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

GODOT_BIN="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
BUTLER_BIN="$ROOT/tools/bin/butler"

if [[ ! -x "$GODOT_BIN" ]]; then
	echo "ERROR: Godot binary not found at $GODOT_BIN" >&2
	echo "  Set GODOT_BIN env var or install Godot at /Applications/Godot.app" >&2
	exit 1
fi

TARGETS=()
ITCH_TARGET=""
BUMP=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		mac|macos|m)   TARGETS+=(mac); shift ;;
		win|windows|w) TARGETS+=(win); shift ;;
		all)           TARGETS=(mac win); shift ;;
		--itch)        ITCH_TARGET="$2"; shift 2 ;;
		--bump)        BUMP="$2"; shift 2 ;;
		-h|--help)     sed -n '2,/^$/p' "$0" | sed 's/^# \?//'; exit 0 ;;
		*) echo "Unknown arg: $1 (see --help)" >&2; exit 1 ;;
	esac
done
[[ ${#TARGETS[@]} -eq 0 ]] && TARGETS=(mac win)

# ── Version handling ──────────────────────────────────────────────────────
VERSION_FILE="$ROOT/VERSION"
if [[ ! -f "$VERSION_FILE" ]]; then
	echo "0.1.0" > "$VERSION_FILE"
fi
VERSION=$(tr -d ' \n\r\t' < "$VERSION_FILE")

if [[ -n "$BUMP" ]]; then
	IFS=. read -r MAJ MIN PAT <<< "$VERSION"
	case "$BUMP" in
		major) MAJ=$((MAJ + 1)); MIN=0; PAT=0 ;;
		minor) MIN=$((MIN + 1)); PAT=0 ;;
		patch) PAT=$((PAT + 1)) ;;
		*) echo "ERROR: --bump must be major|minor|patch (got: $BUMP)" >&2; exit 1 ;;
	esac
	VERSION="$MAJ.$MIN.$PAT"
	echo "$VERSION" > "$VERSION_FILE"
	# Mirror into project.godot's config/version so the running game can
	# read its own version via ProjectSettings.get_setting at boot.
	# No-op if the line isn't present (older trees pre-version-check).
	sed -i '' 's|^config/version="[^"]*"|config/version="'"$VERSION"'"|' "$ROOT/project.godot" 2>/dev/null || true
	echo "==> Bumped version to $VERSION"
	# Tag the commit if the working tree is clean. Skip silently if not in a
	# git repo or if there are uncommitted changes (don't get in the user's way).
	if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
		if [[ -z "$(git -C "$ROOT" status --porcelain)" ]]; then
			git -C "$ROOT" tag "v$VERSION" >/dev/null 2>&1 && echo "    git tag v$VERSION created (push with: git push --tags)"
		else
			echo "    (working tree dirty — skipping git tag; commit + tag manually if you want one)"
		fi
	fi
else
	echo "==> Version: $VERSION (use --bump patch|minor|major to roll forward)"
fi

build_mac() {
	echo "==> macOS"
	mkdir -p build/macos
	rm -f build/macos/MoreRounds.zip
	"$GODOT_BIN" --headless --path . --export-release "macOS LAN Debug" build/macos/MoreRounds.zip
	# Re-zip the .app bundle so itch.io / browsers don't end up with a quarantine flag
	# on a nested zip. (Godot exports macOS as .zip already; this is a no-op confirm.)
	ls -lh build/macos/MoreRounds.zip
}

build_win() {
	echo "==> Windows"
	# Detect missing export templates up-front and bail with a clear hint
	# instead of dumping a stack trace.
	local tpl_dir="$HOME/Library/Application Support/Godot/export_templates/4.6.2.stable"
	if [[ ! -f "$tpl_dir/windows_release_x86_64.exe" ]]; then
		echo "ERROR: Windows export template missing." >&2
		echo "  Expected: $tpl_dir/windows_release_x86_64.exe" >&2
		echo "  Install via: open Godot → Editor → Manage Export Templates → Download and Install" >&2
		echo "  (or: tools/install_export_templates.sh — see that script)" >&2
		return 1
	fi
	mkdir -p build/windows
	rm -f build/windows/MoreRounds.exe build/windows/MoreRounds.pck build/windows/MoreRounds.zip
	# Not --headless: the shader baker needs a real rendering device.
	"$GODOT_BIN" --path . --export-release "Windows LAN" build/windows/MoreRounds.exe
	# Zip exe + pck (and any DLLs Godot dropped) into one download.
	(cd build/windows && zip -q -r MoreRounds.zip MoreRounds.exe MoreRounds.pck ./*.dll 2>/dev/null || \
		zip -q -r MoreRounds.zip MoreRounds.exe MoreRounds.pck)
	ls -lh build/windows/MoreRounds.zip
}

for t in "${TARGETS[@]}"; do
	case "$t" in
		mac) build_mac ;;
		win) build_win ;;
	esac
done

echo
echo "Built artifacts:"
[[ -f build/macos/MoreRounds.zip   ]] && echo "  build/macos/MoreRounds.zip"
[[ -f build/windows/MoreRounds.zip ]] && echo "  build/windows/MoreRounds.zip"

# ── Itch.io upload ─────────────────────────────────────────────────────────
if [[ -n "$ITCH_TARGET" ]]; then
	if [[ ! -x "$BUTLER_BIN" ]]; then
		echo "ERROR: butler not found at $BUTLER_BIN" >&2
		echo "  Install: see header of this script." >&2
		exit 1
	fi
	echo
	echo "==> Uploading to itch.io: $ITCH_TARGET (v$VERSION)"
	for t in "${TARGETS[@]}"; do
		case "$t" in
			mac) "$BUTLER_BIN" push --userversion "$VERSION" build/macos/MoreRounds.zip   "$ITCH_TARGET:mac" ;;
			win) "$BUTLER_BIN" push --userversion "$VERSION" build/windows/MoreRounds.zip "$ITCH_TARGET:win" ;;
		esac
	done
fi
