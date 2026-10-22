#!/usr/bin/env bash
# Packages an app bundle into a drag-to-Applications disk image: a Finder window with the
# app, an Applications shortcut and a background arrow.
#
#   scripts/build-dmg.sh <path/to/ClaudeWatcher.app> <out.dmg>
#   make dmg                    # the dev app (build/ClaudeWatcher.app) -> build/ClaudeWatcher.dmg
#
# The window layout (.DS_Store) is written by dmgbuild, without Finder or AppleScript, so
# this runs headless (no Automation permission, no GUI session needed). dmgbuild is pure
# Python, pinned with hashes in scripts/dmg-requirements.txt, and installed into a private
# venv. It needs Python 3.10+, so not macOS's own /usr/bin/python3 (3.9): the first of
# $PYTHON, python3 on PATH, /opt/homebrew/bin/python3, /usr/local/bin/python3 that is new
# enough is used (`brew install python` if none is).
# The background is rendered by scripts/dmg-background.swift at 1x and 2x; the geometry
# lives in scripts/dmg-settings.py.
#
# The image is deliberately left unsigned: the app inside is Developer ID-signed, notarized
# and stapled, which is what Gatekeeper checks on first launch. Xcode's cloud-managed
# Developer ID certificate can't sign a disk image, and a disk image signed with any other
# identity (e.g. Apple Development) is refused on open ("Not Opened"), which is worse than
# unsigned. See "Releasing" in CLAUDE.md.
#
# Environment:
#   VOLUME_NAME  volume / window title. Default: ClaudeWatcher.
#   APP_ICON     .icns used as the volume icon when present. Default: Resources/AppIcon.icns.
#   DMG_VENV     where dmgbuild is installed. Default: .build/dmgbuild-venv.
#   PYTHON       Python 3.10+ to create that venv with (see above).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="${1:?usage: scripts/build-dmg.sh <app> <out.dmg>}"
OUT="${2:?usage: scripts/build-dmg.sh <app> <out.dmg>}"
VOLUME_NAME="${VOLUME_NAME:-ClaudeWatcher}"
APP_ICON="${APP_ICON:-Resources/AppIcon.icns}"
DMG_VENV="${DMG_VENV:-.build/dmgbuild-venv}"
REQUIREMENTS=scripts/dmg-requirements.txt
[[ -d "$APP" ]] || { echo "error: $APP is not an app bundle" >&2; exit 1; }

# dmgbuild in a private venv, (re)installed whenever the pinned requirements change.
want="$(shasum -a 256 "$REQUIREMENTS" | awk '{print $1}')"
if [[ ! -x "$DMG_VENV/bin/dmgbuild" || "$(cat "$DMG_VENV/.requirements.sha256" 2>/dev/null)" != "$want" ]]; then
  PY=""
  for candidate in ${PYTHON:-} python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    if "$candidate" -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>/dev/null; then
      PY="$candidate"; break
    fi
  done
  [[ -n "$PY" ]] || { echo "error: dmgbuild needs Python 3.10+ (brew install python, or set PYTHON)" >&2; exit 1; }
  echo "==> Installing dmgbuild into $DMG_VENV ($("$PY" --version))"
  rm -rf "${DMG_VENV:?}"
  "$PY" -m venv "$DMG_VENV"
  "$DMG_VENV/bin/python" -m pip install --quiet --disable-pip-version-check \
    --require-hashes --only-binary :all: -r "$REQUIREMENTS"
  printf '%s\n' "$want" >"$DMG_VENV/.requirements.sha256"
fi

ART="$(mktemp -d)"
MNT=""   # set while the built image is attached for the layout check
trap '[[ -z "$MNT" ]] || hdiutil detach -quiet -force "$MNT" || true; rm -rf "$ART"' EXIT
echo "==> Rendering background"
swift scripts/dmg-background.swift "$ART" >/dev/null

ARGS=(-s scripts/dmg-settings.py -D app="$APP" -D background="$ART/background.png")
if [[ -f "$APP_ICON" ]]; then
  ARGS+=(-D icon="$APP_ICON")
  echo "==> Volume icon: $APP_ICON"
fi

echo "==> dmgbuild $OUT"
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
"$DMG_VENV/bin/dmgbuild" "${ARGS[@]}" "$VOLUME_NAME" "$OUT"
hdiutil verify -quiet "$OUT"

# Finder silently drops the background if the layout is off, so check what dmgbuild wrote.
mkdir -p "$ART/mnt"
hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$ART/mnt" "$OUT"
MNT="$ART/mnt"
if ! "$DMG_VENV/bin/python" -I - "$MNT/.DS_Store" <<'PY'
import sys
from ds_store import DSStore
with DSStore.open(sys.argv[1], "r") as d:
    root = {e.code: e.value for e in d if e.filename == "."}
assert "backgroundImageAlias" in root.get(b"icvp", {}), "no background image in .DS_Store"
assert b"pBBk" not in root, "stale pBBk background bookmark (dmgbuild < 1.6.6)"
PY
then
  echo "error: $OUT has a broken window layout" >&2
  exit 1
fi
hdiutil detach -quiet "$MNT"
MNT=""
echo "==> Built $OUT ($(du -h "$OUT" | awk '{print $1}'))"
