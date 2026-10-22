#!/usr/bin/env bash
# Builds a release binary and assembles + signs build/ClaudeWatcher.app.
# Signing identity: $CODESIGN_IDENTITY, else first "Apple Development" identity, else ad-hoc.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="ClaudeWatcher"
APP="build/${APP_NAME}.app"
SCRATCH_ARGS=()
if [[ -n "${SCRATCH_PATH:-}" ]]; then
  SCRATCH_ARGS=(--scratch-path "$SCRATCH_PATH")
fi

echo "==> swift build -c release ${SCRATCH_ARGS[*]:-}"
swift build -c release ${SCRATCH_ARGS[@]+"${SCRATCH_ARGS[@]}"}
BIN_DIR="$(swift build -c release ${SCRATCH_ARGS[@]+"${SCRATCH_ARGS[@]}"} --show-bin-path)"

echo "==> Assembling ${APP}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Hook script, installed by HookInstaller.install(hookScriptSource:) from the bundle.
cp hooks/claude-watcher-hook.sh "$APP/Contents/Resources/claude-watcher-hook.sh"
chmod 755 "$APP/Contents/Resources/claude-watcher-hook.sh"

IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  # Use the SHA-1 hash so duplicate display names cannot be ambiguous.
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/"Apple Development/ { print $2; exit }')"
  if [[ -n "$IDENTITY" ]]; then
    NAME="$(security find-identity -v -p codesigning | grep "$IDENTITY" | sed -E 's/.*"(.*)".*/\1/')"
    echo "==> Signing with Apple Development identity: $NAME ($IDENTITY)"
  fi
else
  echo "==> Signing with \$CODESIGN_IDENTITY: $IDENTITY"
fi

if [[ -z "$IDENTITY" ]]; then
  IDENTITY="-"
  cat >&2 <<'WARN'
##################################################################
# WARNING: no signing identity found -- signing AD-HOC.
# TCC permission grants (Accessibility / Automation) are tied to the
# code signature and WILL RESET ON EVERY REBUILD.
# Set CODESIGN_IDENTITY or install an Apple Development certificate.
##################################################################
WARN
fi

# No hardened runtime (no --options runtime): personal, unsandboxed app.
codesign --force --sign "$IDENTITY" --identifier com.thegoldenmule.ClaudeWatcher "$APP"
codesign --verify --verbose=1 "$APP"
echo "==> Built $ROOT/$APP"
