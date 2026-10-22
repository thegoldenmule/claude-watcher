#!/usr/bin/env bash
# Build, sign, notarize and publish a ClaudeWatcher release.
#
#   make release VERSION=1.2.3                      # full release
#   make release VERSION=1.2.3 DRY_RUN=1            # Developer ID-signed DMG + zip only;
#                                                   # nothing notarized, committed or published
#   make release VERSION=1.2.3 DRY_RUN=1 NOTARIZE=1 # signed, notarized and stapled DMG + zip;
#                                                   # nothing committed or published
#
# Mirrors claude-tray's scripts/release.sh. The app is built by scripts/build-app.sh with
# the hardened runtime and Resources/ClaudeWatcher.entitlements (Apple Events, for scripting
# Ghostty / Terminal.app), signed ad-hoc, then re-signed with Developer ID on export.
#
# Signing and notarization go through the Apple account signed into Xcode
# (Xcode > Settings > Accounts): the app is wrapped in an .xcarchive and exported with
# `xcodebuild -exportArchive -allowProvisioningUpdates` (method developer-id), which signs
# it with a cloud-managed Developer ID certificate and uploads it to Apple's notary
# service. No local Developer ID certificate, app-specific password or notarytool profile
# is needed. The account needs the Account Holder or Admin role (with access to
# cloud-managed Developer ID certificates) on the team.
#
# Assets: ClaudeWatcher-X.Y.Z.dmg (drag-to-Applications window, built by
# scripts/build-dmg.sh), ClaudeWatcher-X.Y.Z.zip (the same stapled app, for scripted
# installs), and ClaudeWatcher-X.Y.Z.sha256 covering both. The DMG itself is unsigned: the
# cloud-managed certificate can only sign through xcodebuild's export, which handles app
# archives, not disk images. Gatekeeper mounts an unsigned DMG without a prompt and checks
# the notarized, stapled app inside on first launch.
#
# Environment:
#   VERSION          required. X.Y.Z (a dry run also accepts X.Y.Z-suffix).
#   DRY_RUN=1        sign with Developer ID and package, but skip the version commit/tag,
#                    notarization, push and publish.
#   NOTARIZE=1       with DRY_RUN=1: also notarize, staple and verify like a real release
#                    (still no commit, tag, push or publish).
#   SCRATCH_PATH     SwiftPM scratch dir for the release build. Default: .build-release.
#   TEAM_ID          Apple developer team. Default: QKMK66X2FU.
#   NOTARY_TIMEOUT   seconds to wait for notarization. Default: 1800.
#   PYTHON           Python 3.10+ for dmgbuild (see scripts/build-dmg.sh); its venv lives in
#                    $SCRATCH_PATH/dmgbuild-venv.
#
# Build number (CFBundleVersion): the number of commits on main including the release
# commit (`git rev-list --count HEAD` + 1), bumped past the current value if that would
# not increase it. Monotonic as long as main's history is never rewritten.
#
# A failed run publishes nothing: the commit and tag are pushed only after notarization
# succeeds, and on failure before that the script deletes the tag and drops the release
# commit it created (only if HEAD and the tag still point at it), or restores Info.plist if
# it failed before committing. If `git push` fails, origin is asked whether the tag landed
# anyway; if it did, nothing is rolled back and the finishing `gh release create` is printed.

set -euo pipefail

APP_NAME=ClaudeWatcher
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFO_PLIST=Resources/Info.plist
ENTITLEMENTS=Resources/ClaudeWatcher.entitlements
HOOK_SCRIPT=Contents/Resources/claude-watcher-hook.sh
DIST_DIR=build/dist   # under build/, which is git-ignored (make clean removes it)
PLISTBUDDY=/usr/libexec/PlistBuddy

VERSION="${VERSION:-}"
DRY_RUN="${DRY_RUN:-}"
NOTARIZE="${NOTARIZE:-}"
TEAM_ID="${TEAM_ID:-QKMK66X2FU}"
NOTARY_TIMEOUT="${NOTARY_TIMEOUT:-1800}"
SCRATCH_PATH="${SCRATCH_PATH:-.build-release}"
NOTARY_POLL=30
case "$DRY_RUN" in 1|true|yes) DRY_RUN=1 ;; *) DRY_RUN=0 ;; esac
case "$NOTARIZE" in 1|true|yes) NOTARIZE=1 ;; *) NOTARIZE=0 ;; esac
if [[ $DRY_RUN -eq 0 ]]; then NOTARIZE=1; fi   # a real release always notarizes

cd "$REPO_ROOT"

# ---------------------------------------------------------------- output helpers

if [[ -t 1 ]]; then
    BOLD=$'\e[1m' RED=$'\e[31m' YELLOW=$'\e[33m' GREEN=$'\e[32m' RESET=$'\e[0m'
else
    BOLD="" RED="" YELLOW="" GREEN="" RESET=""
fi
step() { printf '\n%s==> %s%s\n' "$BOLD" "$*" "$RESET"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %sok%s  %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '    %swarning:%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
skip() { printf '    %s[DRY RUN] SKIPPED:%s %s\n' "$YELLOW" "$RESET" "$*"; }
note() { printf '    %s[DRY RUN]%s %s\n' "$YELLOW" "$RESET" "$*"; }
die()  { printf '\n%serror:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

# ---------------------------------------------------------------- failure handling

PREV_SHA=""      # HEAD before the release commit
RELEASE_SHA=""   # the release commit this run created
TAG=""
TAG_OBJ=""       # the annotated tag object this run created
GH_REPO=""       # owner/name of origin on GitHub, for gh --repo
PLIST_EDITED=0   # $INFO_PLIST was modified in the working tree
TAG_CREATED=0
PUSH_ATTEMPTED=0
PUSHED=0
RELEASED=0
VERIFY_MOUNT=""  # the DMG verification mount point while it is attached

# Prints the command that finishes a release whose commit and tag are on origin.
finish_hint() {
    cat >&2 <<EOF
    gh release create $TAG $DMG_PATH $ZIP_PATH $SUM_PATH --repo $GH_REPO --verify-tag \\
        --title "$APP_NAME $VERSION" --generate-notes --notes-file $NOTES_PATH
EOF
}

on_exit() {
    local rc=$?
    if [[ -n "$VERIFY_MOUNT" ]]; then
        hdiutil detach -force -quiet "$VERIFY_MOUNT" 2>/dev/null || true
    fi
    [[ $rc -eq 0 ]] && return

    if [[ $RELEASED -eq 1 ]]; then
        printf '\n%sReleased %s%s (interrupted afterwards; nothing left to do): https://github.com/%s/releases/tag/%s\n' \
            "$GREEN" "$TAG" "$RESET" "$GH_REPO" "$TAG" >&2
        return
    fi

    # The push may have reached origin even though git reported failure (interrupted,
    # connection dropped after the remote accepted it). Ask origin before rolling back.
    if [[ $PUSHED -eq 0 && $PUSH_ATTEMPTED -eq 1 ]]; then
        local remote
        if ! remote="$(git ls-remote origin "refs/tags/$TAG" 2>/dev/null)"; then
            cat >&2 <<EOF

${RED}git push failed and origin could not be checked;${RESET} left the release commit
${RELEASE_SHA:0:7} and tag $TAG in place. Check with: git ls-remote origin refs/tags/$TAG
  - if it prints ${TAG_OBJ:0:7}... (or ${RELEASE_SHA:0:7}...), the push went through. Finish it
    with the notarized DMG and zip in $DIST_DIR/:
EOF
            finish_hint
            cat >&2 <<EOF
  - if it prints nothing, undo the local release:
        git tag -d $TAG; git reset --keep $PREV_SHA
EOF
            return
        fi
        case "${remote%%[[:space:]]*}" in
            "") ;;   # tag not on origin: the push did not happen
            "$TAG_OBJ"|"$RELEASE_SHA")
                printf '\n%sgit push reported failure, but origin has %s;%s treating it as pushed.\n' \
                    "$YELLOW" "$TAG" "$RESET" >&2
                PUSHED=1 ;;
            *)
                warn "origin has a different $TAG (${remote:0:7}); left the local commit and tag alone. To undo them:"
                printf '        git tag -d %s; git reset --keep %s\n' "$TAG" "$PREV_SHA" >&2
                return ;;
        esac
    fi

    if [[ $PUSHED -eq 1 ]]; then
        printf '\n%sRelease failed after %s was pushed.%s The notarized DMG and zip are in %s/.\nFinish publishing by hand:\n' \
            "$RED" "$TAG" "$RESET" "$DIST_DIR" >&2
        finish_hint
        return
    fi

    if [[ -z "$RELEASE_SHA" ]]; then
        # Failed between editing Info.plist and committing it: restore it so the next run
        # passes the clean-tree preflight.
        if [[ $PLIST_EDITED -eq 1 ]]; then
            if git checkout --quiet HEAD -- "$INFO_PLIST"; then
                info "restored $INFO_PLIST" >&2
            else
                warn "could not restore $INFO_PLIST; run: git checkout HEAD -- $INFO_PLIST"
            fi
        fi
        return
    fi

    printf '\n%sRelease failed before anything was pushed; rolling back local changes.%s\n' "$RED" "$RESET" >&2
    if [[ $TAG_CREATED -eq 1 ]]; then
        if [[ "$(git rev-parse -q --verify "refs/tags/$TAG^{commit}" 2>/dev/null)" == "$RELEASE_SHA" ]]; then
            git tag -d "$TAG" >/dev/null && info "deleted local tag $TAG" >&2
        else
            warn "tag $TAG no longer points at the release commit; left it alone"
        fi
    fi
    if [[ "$(git rev-parse HEAD)" == "$RELEASE_SHA" ]] \
        && git reset --quiet --keep "$PREV_SHA"; then
        info "dropped release commit ${RELEASE_SHA:0:7}; HEAD is back at ${PREV_SHA:0:7}" >&2
    else
        warn "could not drop the release commit automatically. To undo it:"
        printf '        git tag -d %s 2>/dev/null; git reset --keep %s\n' "$TAG" "$PREV_SHA" >&2
    fi
}
trap on_exit EXIT
trap 'exit 130' INT TERM

# ---------------------------------------------------------------- preflight

step "Preflight"
if [[ $DRY_RUN -eq 1 && $NOTARIZE -eq 1 ]]; then
    info "${YELLOW}DRY RUN${RESET}: builds a signed, notarized and stapled DMG + zip; no commit, tag, push or release."
elif [[ $DRY_RUN -eq 1 ]]; then
    info "${YELLOW}DRY RUN${RESET}: builds a Developer ID-signed DMG + zip; no commit, tag, notarization, push or release."
fi

[[ -n "$VERSION" ]] || die "VERSION is required, e.g.: make release VERSION=1.2.3"
if [[ $DRY_RUN -eq 1 ]]; then
    [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] \
        || die "VERSION '$VERSION' must look like 1.2.3 (dry runs also accept 1.2.3-test)"
else
    [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || die "VERSION '$VERSION' must be MAJOR.MINOR.PATCH, e.g. 1.2.3 (CFBundleShortVersionString allows only digits and dots)"
fi
[[ "$NOTARY_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "NOTARY_TIMEOUT must be a positive number of seconds (no leading zeros)"
TAG="v$VERSION"
ok "version $VERSION (tag $TAG)"

for tool in swift codesign xcodebuild xcrun ditto hdiutil git gh shasum lipo spctl "$PLISTBUDDY"; do
    command -v "$tool" >/dev/null || die "required tool not found: $tool"
done
# scripts/build-dmg.sh installs dmgbuild with Python 3.10+ (not macOS's 3.9), using the same
# candidates as here; check now rather than after notarizing.
HAVE_PY310=0
for py in ${PYTHON:-} python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    if "$py" -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>/dev/null; then
        HAVE_PY310=1; break
    fi
done
[[ $HAVE_PY310 -eq 1 ]] || die "the DMG build (dmgbuild) needs Python 3.10+: brew install python, or set PYTHON"

# owner/name from origin (git@github.com:o/n.git, https://github.com/o/n, ssh://...), so gh
# targets origin even if another remote or GH_REPO would make it guess differently.
ORIGIN_URL="$(git remote get-url origin 2>/dev/null)" || die "no git remote named origin"
GH_REPO="${ORIGIN_URL%/}"; GH_REPO="${GH_REPO%.git}"
GH_REPO_NAME="${GH_REPO##*/}"; GH_REPO_OWNER="${GH_REPO%/*}"
[[ "$GH_REPO_OWNER" != "$GH_REPO" ]] || GH_REPO_OWNER=""   # no "/" in the URL
GH_REPO="${GH_REPO_OWNER##*[/:]}/$GH_REPO_NAME"
[[ "$GH_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
    || die "could not derive a GitHub owner/name from origin ($ORIGIN_URL)"
ok "GitHub repo $GH_REPO (origin)"

# Fatal for a real release; only a warning for a dry run.
check() {
    if [[ $DRY_RUN -eq 1 ]]; then warn "$1 (would stop a real release)"; else die "$1"; fi
}

if [[ -n "$(git status --porcelain)" ]]; then
    check "working tree is not clean; commit or stash your changes first (git status)"
else
    ok "working tree clean"
fi

BRANCH="$(git symbolic-ref --quiet --short HEAD || echo "(detached)")"
if [[ "$BRANCH" != main ]]; then
    check "on branch '$BRANCH'; releases are cut from main (git switch main)"
else
    ok "on main"
fi

if ! git fetch --quiet origin main; then
    check "could not fetch origin/main; check your network and remote"
elif [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]]; then
    check "main is not in sync with origin/main (ahead $(git rev-list --count origin/main..HEAD), behind $(git rev-list --count HEAD..origin/main)); pull/push first"
else
    ok "in sync with origin/main"
fi

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    check "tag $TAG already exists locally (git tag -d $TAG if it is stale)"
elif git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
    check "tag $TAG already exists on origin; pick a new VERSION"
else
    ok "tag $TAG is unused (local and origin)"
fi

# Signing and notarization need an Apple account in Xcode (fatal even for a dry run,
# which still signs with Developer ID). Only account identifiers are read, never emails.
XCODE_ACCOUNTS="$(defaults read com.apple.dt.Xcode DVTDeveloperAccountManagerAppleIDLists 2>/dev/null || true)"
if grep -q identifier <<<"$XCODE_ACCOUNTS"; then
    ok "Xcode has an Apple account signed in (team $TEAM_ID)"
else
    die "no Apple account in Xcode. Open Xcode > Settings > Accounts and sign in, then re-run."
fi

if gh auth status >/dev/null 2>&1; then
    ok "gh authenticated"
else
    check "gh is not authenticated; run: gh auth login"
fi

# ---------------------------------------------------------------- version

CURRENT_BUILD="$("$PLISTBUDDY" -c "Print :CFBundleVersion" "$INFO_PLIST")"
BUILD_NUMBER=$(( $(git rev-list --count HEAD) + 1 ))
if [[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]] && (( BUILD_NUMBER <= CURRENT_BUILD )); then
    BUILD_NUMBER=$(( CURRENT_BUILD + 1 ))
fi

step "Version $VERSION (build $BUILD_NUMBER)"
mkdir -p "$DIST_DIR"
if [[ $DRY_RUN -eq 1 ]]; then
    # Stamp a copy so the bundle carries the version without touching the repo.
    BUNDLE_PLIST="$DIST_DIR/Info.plist"
    cp "$INFO_PLIST" "$BUNDLE_PLIST"
    "$PLISTBUDDY" -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD_NUMBER" "$BUNDLE_PLIST"
    info "stamped a copy at $BUNDLE_PLIST"
    skip "commit of $INFO_PLIST and tag $TAG"
else
    BUNDLE_PLIST="$INFO_PLIST"
    PREV_SHA="$(git rev-parse HEAD)"
    PLIST_EDITED=1   # before the edit, so a failure from here on restores the file
    "$PLISTBUDDY" -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD_NUMBER" "$INFO_PLIST"
    git commit --quiet -m "Release $TAG" -- "$INFO_PLIST"
    RELEASE_SHA="$(git rev-parse HEAD)"
    git tag -a "$TAG" -m "$APP_NAME $VERSION"
    TAG_CREATED=1
    TAG_OBJ="$(git rev-parse "refs/tags/$TAG")"
    ok "committed ${RELEASE_SHA:0:7} \"Release $TAG\" and tagged $TAG (local only until notarized)"
fi

# ---------------------------------------------------------------- build + archive

WORK_DIR="$DIST_DIR/$APP_NAME-$VERSION"
ARCHIVE_PATH="$WORK_DIR/$APP_NAME.xcarchive"
ARCHIVED_APP="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"
EXPORT_DIR="$WORK_DIR/export"         # Developer ID-signed app (dry run without NOTARIZE)
NOTARIZED_DIR="$WORK_DIR/notarized"   # notarized, stapled app
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"
ZIP_PATH="$DIST_DIR/$APP_NAME-$VERSION.zip"
SUM_PATH="$DIST_DIR/$APP_NAME-$VERSION.sha256"   # covers the DMG and the zip
NOTES_PATH="$DIST_DIR/release-notes-$VERSION.md"
LOG_PATH="$WORK_DIR/xcodebuild.log"
rm -rf "$WORK_DIR" "$DMG_PATH" "$ZIP_PATH" "$SUM_PATH"
mkdir -p "$WORK_DIR"

step "Build universal app bundle"
# Signed ad-hoc with the hardened runtime and entitlements; xcodebuild re-signs it with
# Developer ID on export, keeping the entitlements and runtime flag (--preserve-metadata).
if ! SCRATCH_PATH="$SCRATCH_PATH" \
    APP_DIR="$ARCHIVE_PATH/Products/Applications" \
    ARCHS="arm64 x86_64" \
    INFO_PLIST="$BUNDLE_PLIST" \
    HARDENED_RUNTIME=1 \
    CODESIGN_IDENTITY=- \
    scripts/build-app.sh 2>&1 | sed 's/^/    /'; then
    die "scripts/build-app.sh failed"
fi
[[ -x "$ARCHIVED_APP/$HOOK_SCRIPT" ]] || die "bundle is missing an executable $HOOK_SCRIPT"
ok "hook script bundled at $HOOK_SCRIPT"

ARCHS_FOUND="$(lipo -archs "$ARCHIVED_APP/Contents/MacOS/$APP_NAME")"
[[ "$ARCHS_FOUND" == *arm64* && "$ARCHS_FOUND" == *x86_64* ]] \
    || die "expected a universal binary, got architectures: $ARCHS_FOUND"
ok "architectures: $ARCHS_FOUND"

BUNDLE_ID="$("$PLISTBUDDY" -c "Print :CFBundleIdentifier" "$ARCHIVED_APP/Contents/Info.plist")"
BUNDLE_VERSION="$("$PLISTBUDDY" -c "Print :CFBundleShortVersionString" "$ARCHIVED_APP/Contents/Info.plist")"
BUNDLE_BUILD="$("$PLISTBUDDY" -c "Print :CFBundleVersion" "$ARCHIVED_APP/Contents/Info.plist")"
[[ "$BUNDLE_VERSION" == "$VERSION" ]] || die "bundle version is $BUNDLE_VERSION, expected $VERSION"
ok "bundle $BUNDLE_ID $BUNDLE_VERSION ($BUNDLE_BUILD)"

step "Wrap in $ARCHIVE_PATH"
cat >"$ARCHIVE_PATH/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>ApplicationProperties</key>
	<dict>
		<key>ApplicationPath</key>
		<string>Applications/$APP_NAME.app</string>
		<key>Architectures</key>
		<array>
			<string>arm64</string>
			<string>x86_64</string>
		</array>
		<key>CFBundleIdentifier</key>
		<string>$BUNDLE_ID</string>
		<key>CFBundleShortVersionString</key>
		<string>$BUNDLE_VERSION</string>
		<key>CFBundleVersion</key>
		<string>$BUNDLE_BUILD</string>
		<key>SigningIdentity</key>
		<string>-</string>
		<key>Team</key>
		<string>$TEAM_ID</string>
	</dict>
	<key>ArchiveVersion</key>
	<integer>2</integer>
	<key>CreationDate</key>
	<date>$(date -u +%Y-%m-%dT%H:%M:%SZ)</date>
	<key>Name</key>
	<string>$APP_NAME</string>
	<key>SchemeName</key>
	<string>$APP_NAME</string>
</dict>
</plist>
EOF
plutil -lint -s "$ARCHIVE_PATH/Info.plist"
ok "archive ready"

# ---------------------------------------------------------------- sign + notarize

# Runs xcodebuild, appending its output to the log; prints the last lines on failure.
xcb() {
    printf '\n$ xcodebuild %s\n' "$*" >>"$LOG_PATH"
    if xcodebuild "$@" >>"$LOG_PATH" 2>&1; then
        return 0
    fi
    tail -n 20 "$LOG_PATH" | sed 's/^/    /' >&2
    return 1
}

export_options() {   # $1 = export|upload
    local plist="$WORK_DIR/ExportOptions-$1.plist"
    cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>destination</key>
	<string>$1</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
</dict>
</plist>
EOF
    printf '%s' "$plist"
}

if [[ $NOTARIZE -eq 0 ]]; then
    step "Sign with Developer ID (cloud-managed, via Xcode)"
    xcb -exportArchive -archivePath "$ARCHIVE_PATH" -exportPath "$EXPORT_DIR" \
        -exportOptionsPlist "$(export_options export)" -allowProvisioningUpdates \
        || die "Developer ID export failed (log: $LOG_PATH). If it mentions your account or role, check Xcode > Settings > Accounts."
    APP_PATH="$EXPORT_DIR/$APP_NAME.app"
    skip "upload to Apple's notary service and stapling"
else
    step "Sign with Developer ID (cloud-managed, via Xcode) and submit for notarization"
    xcb -exportArchive -archivePath "$ARCHIVE_PATH" -exportPath "$WORK_DIR/upload" \
        -exportOptionsPlist "$(export_options upload)" -allowProvisioningUpdates \
        || die "Developer ID signing/upload failed (log: $LOG_PATH). If it mentions your account or role, check Xcode > Settings > Accounts."
    ok "uploaded to Apple's notary service"

    info "waiting for notarization (usually a few minutes; timeout ${NOTARY_TIMEOUT}s)..."
    deadline=$(( SECONDS + NOTARY_TIMEOUT ))
    unexpected=0
    while :; do
        if out="$(xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE_PATH" -exportPath "$NOTARIZED_DIR" 2>&1)"; then
            printf '%s\n' "$out" >>"$LOG_PATH"
            break
        fi
        if grep -q "is processing and not ready" <<<"$out"; then
            unexpected=0
        else
            # Not "still processing": a rejection or a transient error. Allow a couple of
            # retries for the latter before giving up.
            unexpected=$(( unexpected + 1 ))
            printf '%s\n' "$out" >>"$LOG_PATH"
            if (( unexpected >= 3 )); then
                grep -Ev '^\s*$' <<<"$out" | tail -n 10 | sed 's/^/    /' >&2
                die "notarization failed (log: $LOG_PATH; Xcode's distribution logs are in \$TMPDIR/${APP_NAME}_*.xcdistributionlogs)"
            fi
        fi
        (( SECONDS < deadline )) || die "notarization did not finish within ${NOTARY_TIMEOUT}s. Once it does, run: xcodebuild -exportNotarizedApp -archivePath $ARCHIVE_PATH -exportPath $NOTARIZED_DIR"
        sleep "$NOTARY_POLL"
    done
    APP_PATH="$NOTARIZED_DIR/$APP_NAME.app"
    [[ -d "$APP_PATH" ]] || die "xcodebuild reported success but $APP_PATH is missing"
    ok "notarization accepted"
    xcrun stapler validate -q "$APP_PATH" || die "no notarization ticket stapled to $APP_PATH"
    ok "ticket stapled"
fi

codesign --verify --deep --strict "$APP_PATH"
SIGNATURE="$(codesign -dvv "$APP_PATH" 2>&1)"
grep -E '^(Authority|TeamIdentifier|Timestamp)' <<<"$SIGNATURE" | sed 's/^/    /' || true
grep -q "^Authority=Developer ID Application: .*($TEAM_ID)$" <<<"$SIGNATURE" \
    || die "$APP_PATH is not signed with a Developer ID Application certificate for team $TEAM_ID"
ok "signed with Developer ID ($TEAM_ID)"
grep -q 'flags=.*(runtime)' <<<"$SIGNATURE" || die "$APP_PATH is not signed with the hardened runtime"
ok "hardened runtime"
SIGNED_ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP_PATH" 2>/dev/null)"
grep -q 'com.apple.security.automation.apple-events' <<<"$SIGNED_ENTITLEMENTS" \
    || die "$APP_PATH lost the Apple Events entitlement from $ENTITLEMENTS"
if grep -q 'com.apple.security.get-task-allow' <<<"$SIGNED_ENTITLEMENTS"; then
    die "$APP_PATH carries com.apple.security.get-task-allow (notarization rejects it)"
fi
ok "entitlements: com.apple.security.automation.apple-events"

# ---------------------------------------------------------------- package + verify

step "Package $DMG_PATH"
# Unsigned on purpose (see the header). Never sign it with a non-Developer ID identity:
# Gatekeeper then refuses to open it ("Not Opened ... could not verify").
if ! DMG_VENV="$SCRATCH_PATH/dmgbuild-venv" scripts/build-dmg.sh "$APP_PATH" "$DMG_PATH" 2>&1 \
    | sed 's/^/    /'; then
    die "scripts/build-dmg.sh failed"
fi
ok "created $DMG_PATH ($(du -h "$DMG_PATH" | awk '{print $1}'))"

step "Package $ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
ok "created $ZIP_PATH ($(du -h "$ZIP_PATH" | awk '{print $1}'))"

step "Verify as a download"
# Mark copies as downloaded by Safari, mount / extract them, and assess the app inside like
# Gatekeeper would on first launch. Expected to be rejected in a dry run (not notarized).
gatekeeper() {
    if "$@" 2>&1 | sed 's/^/    /'; [[ ${PIPESTATUS[0]} -eq 0 ]]; then
        return 0
    elif [[ $NOTARIZE -eq 0 ]]; then
        note "expected rejection: dry-run builds are not notarized (add NOTARIZE=1)"
    else
        die "Gatekeeper rejected: $*"
    fi
}
quarantine() { xattr -w com.apple.quarantine "0083;$(printf %x "$(date +%s)");Safari;" "$1"; }
verify_app() {   # $1 = app bundle, $2 = where it came from (for messages)
    codesign --verify --deep --strict "$1"
    ok "$2: app signature verifies"
    [[ -x "$1/$HOOK_SCRIPT" ]] || die "$2: app is missing an executable $HOOK_SCRIPT"
    ok "$2: hook script is executable"
    gatekeeper spctl -a -vv -t exec "$1"
    if [[ $NOTARIZE -eq 1 ]]; then
        xcrun stapler validate -q "$1" || die "$2: app has no stapled ticket"
        ok "$2: app has a stapled ticket"
        if command -v syspolicy_check >/dev/null; then
            syspolicy_check distribution "$1" 2>&1 | sed 's/^/    /' \
                || die "$2: syspolicy_check distribution failed"
        fi
    fi
}
VERIFY_DIR="$WORK_DIR/verify"
rm -rf "$VERIFY_DIR" && mkdir -p "$VERIFY_DIR/extracted" "$VERIFY_DIR/mnt"

# DMG: must be unsigned (a foreign signature blocks opening it), hold the app and an
# Applications symlink, and the app inside must pass like the notarized app itself.
cp "$DMG_PATH" "$VERIFY_DIR/"
VERIFY_DMG="$VERIFY_DIR/$(basename "$DMG_PATH")"
quarantine "$VERIFY_DMG"
if codesign -d "$VERIFY_DMG" >/dev/null 2>&1; then
    die "$DMG_PATH is signed; Gatekeeper refuses to open a disk image signed with anything but a notarized Developer ID"
fi
ok "dmg: unsigned (the app inside carries the signature and ticket)"
hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$VERIFY_DIR/mnt" "$VERIFY_DMG"
VERIFY_MOUNT="$VERIFY_DIR/mnt"
[[ -d "$VERIFY_MOUNT/$APP_NAME.app" ]] || die "dmg does not contain $APP_NAME.app at its root"
[[ "$(readlink "$VERIFY_MOUNT/Applications")" == /Applications ]] \
    || die "dmg is missing the Applications -> /Applications symlink"
[[ -f "$VERIFY_MOUNT/.DS_Store" && -f "$VERIFY_MOUNT/.background.tiff" ]] \
    || die "dmg is missing its window layout (.DS_Store / .background.tiff)"
ok "dmg: app, Applications symlink and window layout present"
verify_app "$VERIFY_MOUNT/$APP_NAME.app" dmg
hdiutil detach -quiet "$VERIFY_MOUNT"
VERIFY_MOUNT=""

# Zip: extracted copy.
cp "$ZIP_PATH" "$VERIFY_DIR/"
quarantine "$VERIFY_DIR/$(basename "$ZIP_PATH")"
ditto -x -k "$VERIFY_DIR/$(basename "$ZIP_PATH")" "$VERIFY_DIR/extracted"
EXTRACTED_APP="$VERIFY_DIR/extracted/$APP_NAME.app"
[[ -d "$EXTRACTED_APP" ]] || die "zip does not contain $APP_NAME.app at its root"
xattr -p com.apple.quarantine "$EXTRACTED_APP" >/dev/null 2>&1 || quarantine "$EXTRACTED_APP"
verify_app "$EXTRACTED_APP" zip
rm -rf "$VERIFY_DIR"

(cd "$DIST_DIR" && shasum -a 256 "$(basename "$DMG_PATH")" "$(basename "$ZIP_PATH")" >"$(basename "$SUM_PATH")")
sed 's/^/    sha256 /' "$SUM_PATH"

# ---------------------------------------------------------------- publish

cat >"$NOTES_PATH" <<EOF
## Install

1. Download \`$APP_NAME-$VERSION.dmg\` below and open it.
2. Drag **$APP_NAME** onto the **Applications** folder in the window that opens, then eject
   the disk image.
3. Open $APP_NAME from Applications. It appears in the menu bar; the sidebar slides in from
   the left screen edge.
4. Optional: choose **Claude Code Hook > Install** in its menu for faster, more reliable
   Ghostty tab matching.

Requires macOS 26 or later, [Claude Code](https://claude.com/claude-code), and Ghostty 1.3+
or Terminal.app. macOS asks for Automation access to your terminal the first time you click
a session. The app is signed with Developer ID and notarized by Apple.
\`$APP_NAME-$VERSION.zip\` holds the same app for scripted installs. Verify a download with
\`shasum -a 256 -c --ignore-missing $APP_NAME-$VERSION.sha256\`.
EOF

step "Publish"
if [[ $DRY_RUN -eq 1 ]]; then
    skip "git push --atomic origin main $TAG"
    skip "gh release create $TAG $DMG_PATH $ZIP_PATH $SUM_PATH --repo $GH_REPO --title \"$APP_NAME $VERSION\" --generate-notes (notes: $NOTES_PATH)"
    if [[ $NOTARIZE -eq 1 ]]; then
        printf '\n%sDry run complete.%s Signed, notarized and stapled DMG + zip: %s, %s\n' "$GREEN" "$RESET" "$DMG_PATH" "$ZIP_PATH"
    else
        printf '\n%sDry run complete.%s Developer ID-signed (not notarized) DMG + zip: %s, %s\n' "$GREEN" "$RESET" "$DMG_PATH" "$ZIP_PATH"
    fi
    exit 0
fi

PUSH_ATTEMPTED=1
git push --atomic origin main "$TAG"
PUSHED=1
ok "pushed main and $TAG"
gh release create "$TAG" "$DMG_PATH" "$ZIP_PATH" "$SUM_PATH" --repo "$GH_REPO" --verify-tag \
    --title "$APP_NAME $VERSION" --generate-notes --notes-file "$NOTES_PATH"
RELEASED=1
RELEASE_URL="$(gh release view "$TAG" --repo "$GH_REPO" --json url -q .url 2>/dev/null || true)"
printf '\n%sReleased %s%s: %s\n' "$GREEN" "$TAG" "$RESET" \
    "${RELEASE_URL:-https://github.com/$GH_REPO/releases/tag/$TAG}"
