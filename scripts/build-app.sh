#!/usr/bin/env bash
# Builds a release binary and assembles + signs build/ClaudeWatcher.app.
# Signing identity: $CODESIGN_IDENTITY, else first "Apple Development" identity, else ad-hoc.
#
# Dev builds (make app / make run) use the defaults. scripts/release.sh overrides:
#   SCRATCH_PATH       SwiftPM scratch dir (default .build).
#   APP_DIR            directory the bundle is written to (default build).
#   INFO_PLIST         Info.plist to copy into the bundle (default Resources/Info.plist).
#   ARCHS              e.g. "arm64 x86_64" for a universal binary (default: host arch).
#   HARDENED_RUNTIME=1 sign with the hardened runtime and Resources/ClaudeWatcher.entitlements
#                      (plus a secure timestamp unless ad-hoc), as notarization requires.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="ClaudeWatcher"
APP="${APP_DIR:-build}/${APP_NAME}.app"
INFO_PLIST="${INFO_PLIST:-Resources/Info.plist}"
ENTITLEMENTS="Resources/ClaudeWatcher.entitlements"
BUILD_ARGS=()
if [[ -n "${SCRATCH_PATH:-}" ]]; then
  BUILD_ARGS=(--scratch-path "$SCRATCH_PATH")
fi
for arch in ${ARCHS:-}; do
  BUILD_ARGS+=(--arch "$arch")
done

echo "==> swift build -c release ${BUILD_ARGS[*]:-}"
swift build -c release ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}
BIN_DIR="$(swift build -c release ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"} --show-bin-path)"

echo "==> Assembling ${APP}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$INFO_PLIST" "$APP/Contents/Info.plist"
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

# Dev builds: no hardened runtime (personal, unsandboxed app). Release builds add it, with
# the Apple Events entitlement it then needs to script Ghostty / Terminal.app.
SIGN_ARGS=()
if [[ "${HARDENED_RUNTIME:-}" == 1 ]]; then
  SIGN_ARGS=(--options runtime --entitlements "$ENTITLEMENTS")
  [[ "$IDENTITY" != "-" ]] && SIGN_ARGS+=(--timestamp)
  echo "==> Hardened runtime, entitlements: $ENTITLEMENTS"
fi
codesign --force --sign "$IDENTITY" --identifier com.thegoldenmule.ClaudeWatcher \
  ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} "$APP"
codesign --verify --verbose=1 "$APP"
[[ "$APP" == /* ]] || APP="$ROOT/$APP"
echo "==> Built $APP"
