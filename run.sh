#!/bin/sh
# Builds Domotica.app, installs it in /Applications and starts it. The log is
# ~/Library/Logs/Domotica.log.
#
# It has to run as an app launched through LaunchServices: macOS asks for the
# local network permission on behalf of the app that started a process, so a
# bare binary started from a terminal borrows the terminal's permission.
#
#   ./run.sh            build, install, (re)start, tail the log
#   ./run.sh --no-tail  same, without tailing the log
#   ./run.sh probe      build, install, print what the app finds, don't start it
#   ./run.sh stop       stop it
set -e
cd "$(dirname "$0")"

# Installed outside .build: macOS is shy about permission prompts for apps
# that live in hidden folders.
APP="/Applications/Domotica.app"
LOG="$HOME/Library/Logs/Domotica.log"

pkill -x home-control 2>/dev/null || true
[ "$1" = "stop" ] && exit 0

swift build -c release
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/home-control "$APP/Contents/MacOS/home-control"
cp Info.plist "$APP/Contents/Info.plist"
# Regenerate with: swift Icon/make-icon.swift Icon/AppIcon.icns
cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# macOS ties the local network permission and the keychain items to the
# signature. An ad-hoc one changes on every build, so each rebuild would lose
# them; a real certificate keeps them. HOMECONTROL_SIGN_IDENTITY picks one,
# otherwise the first Apple Development identity in the keychain, otherwise
# ad-hoc.
IDENTITY="${HOMECONTROL_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" "$APP" >/dev/null
# Make the Finder pick up a changed icon.
touch "$APP"

if [ "$1" = "probe" ]; then
  exec "$APP/Contents/MacOS/home-control" --probe
fi

open "$APP"
echo "started; log: $LOG"
[ "$1" = "--no-tail" ] || exec tail -n 20 -f "$LOG"
