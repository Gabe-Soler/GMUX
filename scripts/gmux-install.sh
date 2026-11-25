#!/usr/bin/env bash
# Build GMUX (Release) and install it as /Applications/GMUX.app for personal use.
#
# The installed app is named GMUX, signed locally (ad hoc), and forces these
# cmux policies through its Info.plist (see ManagedDevicePolicy.bundleForcedPolicies):
#   DisableTelemetry      no Sentry crash reports or PostHog analytics
#   DisableAutoUpdate     never offers to replace GMUX with official cmux
#   DisableCloud          hides cmux Cloud machines and the Cloud VPN
#   DisableRemoteControl  no iOS companion pairing
#
# It only ever touches the GMUX bundle (com.cmuxterm.app.debug.gmux); a
# regular cmux install is never quit or overwritten.
#
# Run it from Terminal.app, not a GMUX terminal: installing quits GMUX.
#
# Usage: ./scripts/gmux-install.sh [--no-open] [--skip-build]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ID="com.cmuxterm.app.debug.gmux"
DEST="/Applications/GMUX.app"
BUILT="$HOME/Library/Developer/Xcode/DerivedData/cmux-gmux/Build/Products/Release/cmux.app"
ZIG_DIR="${GMUX_ZIG_DIR:-$HOME/.local/zig/zig-aarch64-macos-0.16.0}"
POLICIES=(DisableTelemetry DisableAutoUpdate DisableCloud DisableRemoteControl)

OPEN_APP=1
BUILD=1
for arg in "$@"; do
  case "$arg" in
    --no-open) OPEN_APP=0 ;;
    --skip-build) BUILD=0 ;;
    -h|--help) sed -n 2,17p "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown option $arg" >&2; exit 1 ;;
  esac
done

if [[ "$BUILD" -eq 1 ]]; then
  echo "==> Building GMUX (Release); this takes several minutes"
  export PATH="$ZIG_DIR:$HOME/.cargo/bin:$PATH"
  export CMUX_ZIG="$ZIG_DIR/zig"
  export CMUX_GHOSTTYKIT_PREPROVISIONED=1
  export CMUX_DEV_BACKEND_MODE=local
  export CMUX_WIREGUARD_GO_REQUIRE=0
  (cd "$ROOT" && ./scripts/reload.sh --tag gmux --release --build-only --no-global-cli-links)
fi

[[ -d "$BUILT" ]] || { echo "error: no build found at $BUILT" >&2; exit 1; }
built_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$BUILT/Contents/Info.plist")"
if [[ "$built_id" != "$BUNDLE_ID" ]]; then
  echo "error: build has bundle ID $built_id, expected $BUNDLE_ID; refusing to install" >&2
  exit 1
fi
if [[ -d "$DEST" ]]; then
  dest_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$DEST/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$dest_id" != "$BUNDLE_ID" ]]; then
    echo "error: $DEST is not GMUX (bundle ID '$dest_id'); refusing to replace it" >&2
    exit 1
  fi
fi

if pgrep -f "$DEST/Contents/MacOS/" >/dev/null 2>&1; then
  if [[ "${__CFBundleIdentifier:-}" == "$BUNDLE_ID" || "${CMUX_BUNDLE_ID:-}" == "$BUNDLE_ID" ]]; then
    echo "error: this terminal is inside GMUX, and installing quits GMUX. Run this from Terminal.app instead." >&2
    exit 1
  fi
  echo "==> Quitting the running GMUX"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do
    pgrep -f "$DEST/Contents/MacOS/" >/dev/null 2>&1 || break
    /bin/sleep 0.2
  done
  if pgrep -f "$DEST/Contents/MacOS/" >/dev/null 2>&1; then
    echo "error: GMUX is still running; quit it and run again" >&2
    exit 1
  fi
fi

echo "==> Installing $DEST"
staging="$(mktemp -d "${TMPDIR:-/tmp}/gmux-install.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
cp -R "$BUILT" "$staging/GMUX.app"
plist="$staging/GMUX.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName GMUX" -c "Set :CFBundleDisplayName GMUX" "$plist"
/usr/libexec/PlistBuddy -c "Delete :GMUXForcedPolicies" "$plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :GMUXForcedPolicies dict" "$plist"
for key in "${POLICIES[@]}"; do
  /usr/libexec/PlistBuddy -c "Add :GMUXForcedPolicies:$key bool true" "$plist"
done
codesign --force --sign - --preserve-metadata=entitlements,requirements,flags,runtime "$staging/GMUX.app" 2>/dev/null
codesign --verify --deep --strict "$staging/GMUX.app"

rm -rf "$DEST"
mv "$staging/GMUX.app" "$DEST"
echo "==> Installed $DEST (policies: ${POLICIES[*]})"

if [[ "$OPEN_APP" -eq 1 ]]; then
  open "$DEST"
fi
