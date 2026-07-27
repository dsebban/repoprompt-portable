#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="RepoPrompt Portable"
PROCESS_NAME="repoprompt-linux-desktop"
BUNDLE_ID="com.repoprompt.portable.desktop"
MIN_SYSTEM_VERSION="13.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$PROCESS_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

pkill -x "$PROCESS_NAME" >/dev/null 2>&1 || true

SCUI_DEFAULT_BACKEND=AppKitBackend swift build \
	--package-path "$ROOT_DIR/LinuxDesktop" \
	--product "$PROCESS_NAME" \
	--disable-automatic-resolution
BUILD_BINARY="$(SCUI_DEFAULT_BACKEND=AppKitBackend swift build \
	--package-path "$ROOT_DIR/LinuxDesktop" \
	--show-bin-path)/$PROCESS_NAME"

if [[ -e "$APP_BUNDLE" ]]; then
	/usr/bin/trash "$APP_BUNDLE"
fi
mkdir -p "$APP_MACOS"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $PROCESS_NAME" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $BUNDLE_ID" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleName string $APP_NAME" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string $MIN_SYSTEM_VERSION" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :NSPrincipalClass string NSApplication" "$INFO_PLIST"

open_app() {
	/usr/bin/open -n "$APP_BUNDLE" --args --macos --root "$ROOT_DIR"
}

case "$MODE" in
	run)
		open_app
		;;
	--debug|debug)
		lldb -- "$APP_BINARY" --macos --root "$ROOT_DIR"
		;;
	--logs|logs)
		open_app
		/usr/bin/log stream --info --style compact --predicate "process == \"$PROCESS_NAME\""
		;;
	--telemetry|telemetry)
		open_app
		/usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
		;;
	--verify|verify)
		open_app
		sleep 1
		pgrep -x "$PROCESS_NAME" >/dev/null
		;;
	*)
		echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
		exit 2
		;;
esac
