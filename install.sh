#!/usr/bin/env bash
#
# install.sh — build Coaxy.app, install it, optionally auto-start at login.
#
#   ./install.sh              build + install + launch now
#   ./install.sh --login      also install a LaunchAgent (starts at every login)
#   ./install.sh --dmg        build and package a distributable Coaxy.dmg
#   ./install.sh --uninstall  stop it, remove the app + LaunchAgent (keeps data)
#
# Coaxy is built as a real .app bundle rather than a bare binary because
# macOS only grants Automation permission (needed to read the frontmost
# browser tab) to bundled, signed applications.
#
set -euo pipefail

APP_NAME="Coaxy"
BUNDLE_ID="ai.coaxy.app"
VERSION="0.1.0"
APP_DIR="$HOME/Applications/$APP_NAME.app"
EXEC="$APP_DIR/Contents/MacOS/$APP_NAME"
CONF_DIR="$HOME/.coaxy"
LABEL="$BUNDLE_ID"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/Coaxy.swift"

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }

stop_running() {
  if [ -f "$PLIST" ]; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
  fi
  # legacy TaskHUD builds
  launchctl bootout "gui/$(id -u)/com.slowgrain.taskhud" 2>/dev/null || true
  pkill -x "$APP_NAME" 2>/dev/null || true
  pkill -x TaskHUD     2>/dev/null || true
  pkill -x taskhud     2>/dev/null || true
  sleep 0.4
}

if [ "${1:-}" = "--uninstall" ]; then
  stop_running
  rm -f "$PLIST" "$HOME/Library/LaunchAgents/com.slowgrain.taskhud.plist" "$HOME/bin/taskhud"
  rm -rf "$APP_DIR" "$HOME/Applications/TaskHUD.app"
  grn "Uninstalled. Your schedule and adherence log in $CONF_DIR were kept."
  info "Also remove $APP_NAME under System Settings > Privacy & Security > Automation."
  exit 0
fi

command -v swiftc >/dev/null 2>&1 || { red "swiftc not found."; info "Run: xcode-select --install"; exit 1; }
[ -f "$SRC" ] || { red "Coaxy.swift not found next to install.sh"; exit 1; }
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 12 ] || { red "macOS 12+ required."; exit 1; }

build_app() {
  local dest="$1"
  mkdir -p "$dest/Contents/MacOS" "$dest/Contents/Resources"

  cat > "$dest/Contents/Info.plist" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Slowgrain Labs Private Limited</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Coaxy checks the address of your frontmost browser tab so it can notice when you have drifted onto a site you asked it to watch. Addresses are read in memory only, never stored and never sent anywhere.</string>
</dict>
PLISTEOF
  echo '</plist>' >> "$dest/Contents/Info.plist"

  local tmp; tmp="$(mktemp -d)"
  swiftc -O -framework AppKit -framework Foundation "$SRC" -o "$tmp/$APP_NAME"
  install -m 755 "$tmp/$APP_NAME" "$dest/Contents/MacOS/$APP_NAME"
  rm -rf "$tmp"

  # Ad-hoc signature. Enough for macOS to offer the Automation prompt; not
  # enough to clear Gatekeeper, which is why users right-click > Open once.
  codesign --force --deep --sign - "$dest" 2>/dev/null || true
}

# ---- DMG packaging ---------------------------------------------------------
if [ "${1:-}" = "--dmg" ]; then
  echo "Building $APP_NAME.dmg…"
  STAGE="$(mktemp -d)/$APP_NAME"
  mkdir -p "$STAGE"
  build_app "$STAGE/$APP_NAME.app"
  ln -s /Applications "$STAGE/Applications"

  cat > "$STAGE/READ ME FIRST.txt" <<'TXTEOF'
Coaxy — installing

1. Drag Coaxy into the Applications folder shown here.
2. Open Applications, RIGHT-CLICK Coaxy, and choose Open.
   Then click Open again in the dialog.

Step 2 matters. Coaxy is not yet notarized by Apple, so a normal
double-click will be refused. Right-click > Open only has to be done once.

On first launch Coaxy writes an example day to ~/.coaxy/schedule.json.
Edit that file and save; Coaxy reloads within a second.

If you want the distraction watch to see browser tabs, accept the
permission prompt macOS shows the first time you land on a watched site.

Everything stays on your Mac. Coaxy has no account, no server, no telemetry.
TXTEOF

  OUT="$HERE/$APP_NAME-$VERSION.dmg"
  rm -f "$OUT"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
  rm -rf "$(dirname "$STAGE")"
  grn "Packaged → $OUT"
  info "Unsigned by Apple — recipients must right-click > Open the first time."
  exit 0
fi

echo "Building…"
stop_running
rm -rf "$APP_DIR"
build_app "$APP_DIR"
grn "Installed → $APP_DIR"

# Only seed when there is genuinely nothing — including no legacy TaskHUD
# data for the app itself to migrate on first launch.
if [ ! -f "$CONF_DIR/schedule.json" ] && [ ! -f "$HOME/.taskhud/schedule.json" ] \
   && [ -f "$HERE/schedule.example.json" ]; then
  mkdir -p "$CONF_DIR"
  cp "$HERE/schedule.example.json" "$CONF_DIR/schedule.json"
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
  <key>StandardErrorPath</key><string>$CONF_DIR/coaxy.log</string>
  <key>StandardOutPath</key><string>$CONF_DIR/coaxy.log</string>
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
info "Logs:           tail -f $CONF_DIR/coaxy.log"
info "Package a DMG:  ./install.sh --dmg"
info "Uninstall:      ./install.sh --uninstall"
