#!/usr/bin/env bash
#
# install.sh — build TaskHUD.app, install it, optionally auto-start at login.
#
#   ./install.sh              build + install + launch now
#   ./install.sh --login      also install a LaunchAgent (starts at every login)
#   ./install.sh --uninstall  stop it, remove the app + LaunchAgent (keeps data)
#
# TaskHUD is built as a real .app bundle rather than a bare binary because
# macOS only grants Automation permission (needed to read the frontmost
# browser tab) to bundled, signed applications.
#
set -euo pipefail

APP_NAME="TaskHUD"
BUNDLE_ID="com.slowgrain.taskhud"
APP_DIR="$HOME/Applications/$APP_NAME.app"
EXEC="$APP_DIR/Contents/MacOS/$APP_NAME"
CONF_DIR="$HOME/.taskhud"
LABEL="$BUNDLE_ID"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/TaskHUD.swift"

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }

stop_running() {
  if [ -f "$PLIST" ]; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
  fi
  pkill -x "$APP_NAME" 2>/dev/null || true
  pkill -x taskhud     2>/dev/null || true   # legacy bare-binary builds
  sleep 0.4
}

if [ "${1:-}" = "--uninstall" ]; then
  stop_running
  rm -f "$PLIST" "$HOME/bin/taskhud"
  rm -rf "$APP_DIR"
  grn "Uninstalled. Your schedule and adherence log in $CONF_DIR were kept."
  info "Also remove TaskHUD under System Settings ▸ Privacy & Security ▸ Automation."
  exit 0
fi

command -v swiftc >/dev/null 2>&1 || { red "swiftc not found."; info "Run: xcode-select --install"; exit 1; }
[ -f "$SRC" ] || { red "TaskHUD.swift not found next to install.sh"; exit 1; }
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 12 ] || { red "macOS 12+ required."; exit 1; }

echo "Building…"
mkdir -p "$CONF_DIR" "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cat > "$APP_DIR/Contents/Info.plist" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.4.0</string>
  <key>CFBundleVersion</key><string>140</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>TaskHUD checks the address of your frontmost browser tab so it can notice when you have drifted onto a site you asked it to watch. Addresses are read in memory only and never stored or sent anywhere.</string>
</dict>
</plist>
PLISTEOF

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
swiftc -O -framework AppKit -framework Foundation "$SRC" -o "$TMP/$APP_NAME"

stop_running
install -m 755 "$TMP/$APP_NAME" "$EXEC"

# Ad-hoc signature so macOS will offer the Automation prompt at all.
codesign --force --deep --sign - "$APP_DIR" 2>/dev/null \
  && info "Ad-hoc signed" \
  || info "codesign unavailable — site matching may not prompt"

grn "Installed → $APP_DIR"

if [ ! -f "$CONF_DIR/schedule.json" ] && [ -f "$(dirname "$SRC")/schedule.example.json" ]; then
  cp "$(dirname "$SRC")/schedule.example.json" "$CONF_DIR/schedule.json"
  info "Seeded $CONF_DIR/schedule.json"
fi

if [ "${1:-}" = "--login" ]; then
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$EXEC</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$CONF_DIR/taskhud.log</string>
  <key>StandardOutPath</key><string>$CONF_DIR/taskhud.log</string>
</dict>
</plist>
PLISTEOF
  launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load "$PLIST"
  grn "Login item installed"
else
  open -a "$APP_DIR"
  grn "Running."
fi

echo
info "Edit your day:  open $CONF_DIR/schedule.json   (hot-reloads on save)"
info "Logs:           tail -f $CONF_DIR/taskhud.log"
info "Uninstall:      ./install.sh --uninstall"
