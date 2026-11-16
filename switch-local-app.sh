#!/bin/sh
# Switch a verified local build without relying on the terminal connection.
# The previous bundle remains beside the installation in a hidden backup folder.
set -eu

SOURCE_APP=${1:?Usage: switch-local-app.sh /path/to/CustomVPN.app}
TARGET_APP=/Applications/Tools/Network/CustomVPN.app
APP_ID=io.github.zelebo.customvpn
WORK_DIR=
QUIT_REQUESTED=0
COMPLETE=0

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
running() { /usr/bin/pgrep -x CustomVPN >/dev/null 2>&1; }
quit_app() {
    /usr/bin/osascript -e 'with timeout of 15 seconds' \
        -e 'tell application id "io.github.zelebo.customvpn" to quit' \
        -e 'end timeout'
    attempt=0
    while running; do
        attempt=$((attempt + 1))
        [ "$attempt" -lt 30 ] || return 1
        sleep 1
    done
}
network_works() {
    interface=$(/sbin/route -n get 1.1.1.1 | awk '/interface:/{print $2}')
    case "$interface" in utun*) ;; *) return 1 ;; esac
    /usr/bin/curl --noproxy '*' --fail --silent \
        --connect-timeout 3 --max-time 5 \
        https://www.apple.com/library/test/success.html --output /dev/null
}
recover() {
    result=$?
    trap - EXIT INT TERM
    if [ "$COMPLETE" -eq 0 ] && [ "$QUIT_REQUESTED" -eq 1 ]; then
        set +e
        log 'Switch failed; restoring the previous application.'
        if [ -d "$WORK_DIR/previous/CustomVPN.app" ]; then
            if running && ! quit_app; then
                log "Application did not stop; backup retained at $WORK_DIR/previous/CustomVPN.app"
                exit 1
            fi
            if [ -d "$TARGET_APP" ]; then mv "$TARGET_APP" "$WORK_DIR/failed.app"; fi
            mv "$WORK_DIR/previous/CustomVPN.app" "$TARGET_APP"
        fi
        if ! running; then /usr/bin/open -n -a "$TARGET_APP"; fi
        log 'Previous application is retained; launch requested if it was stopped.'
    fi
    exit "$result"
}
trap recover EXIT
trap 'exit 130' INT TERM

[ -d "$SOURCE_APP" ] && [ -d "$TARGET_APP" ]
[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$SOURCE_APP/Contents/Info.plist")" = "$APP_ID" ]
[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$TARGET_APP/Contents/Info.plist")" = "$APP_ID" ]
/usr/bin/codesign --verify --deep --strict "$SOURCE_APP"
network_works
WORK_DIR=$(mktemp -d '/Applications/Tools/Network/.customvpn-switch.XXXXXX')
mkdir "$WORK_DIR/incoming" "$WORK_DIR/previous"
/usr/bin/ditto "$SOURCE_APP" "$WORK_DIR/incoming/CustomVPN.app"
/usr/bin/codesign --verify --deep --strict "$WORK_DIR/incoming/CustomVPN.app"
log 'Verified new bundle; closing the running CustomVPN.'
QUIT_REQUESTED=1
if running; then quit_app; fi
mv "$TARGET_APP" "$WORK_DIR/previous/CustomVPN.app"
mv "$WORK_DIR/incoming/CustomVPN.app" "$TARGET_APP"
log 'Replaced bundle; launching the new CustomVPN.'
/usr/bin/open -n -a "$TARGET_APP"
attempt=0
while [ "$attempt" -lt 30 ]; do
    sleep 2
    if running && /usr/bin/pgrep -x FlClashCore >/dev/null && network_works; then
        COMPLETE=1
        log 'READY: new CustomVPN and its core are running; TUN route and HTTPS work.'
        log "Previous bundle: $WORK_DIR/previous/CustomVPN.app"
        exit 0
    fi
    attempt=$((attempt + 1))
done
log 'New application did not restore connectivity before the deadline.'
exit 1
