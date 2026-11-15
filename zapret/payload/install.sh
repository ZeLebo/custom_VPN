#!/bin/sh
set -eu

SOURCE=$1
DATA_ROOT=$2
DEST='/Library/Application Support/ZapretMac'
PLIST=/Library/LaunchDaemons/io.github.flowseal.zapretmac.plist

case "$DATA_ROOT" in
    /Users/*/'Library/Application Support/ZapretMac') ;;
    *) echo 'invalid user data path'; exit 1 ;;
esac

[ -x "$SOURCE/bin/zapret-control" ] && [ -s "$SOURCE/CONTROL_VERSION" ] || exit 1
[ -d "$DATA_ROOT" ] && [ ! -L "$DATA_ROOT" ] || exit 1
USER_ID=$(/usr/bin/stat -f '%u' "$DATA_ROOT")
case "$USER_ID" in
    *[!0-9]*|''|0) exit 1 ;;
esac

/bin/sh "$SOURCE/stop.sh"
/bin/mkdir -p "$DEST"
/usr/bin/rsync -a --delete --exclude runtime --exclude runtime.previous --exclude control-status.json --exclude CONTROL_VERSION --exclude engine.log --exclude zapret.log "$SOURCE/" "$DEST/"
/usr/bin/touch "$DEST/ipset-any.txt"
/usr/sbin/chown -R root:wheel "$DEST"
/bin/chmod -R go-w "$DEST"
/bin/chmod 755 "$DEST/bin/zapret-control"
/bin/chmod 755 "$DEST/cleanup.sh"
/bin/chmod 755 "$DEST/install.sh" "$DEST/run.sh" "$DEST/restart.sh" "$DEST/stop.sh" "$DEST/test-strategies.sh" "$DEST/watchdog.sh" "$DEST/bin/utunws"
/bin/cp "$DEST/io.github.flowseal.zapretmac.plist.in" "$PLIST"
/usr/bin/plutil -remove ProgramArguments.2 "$PLIST"
/usr/bin/plutil -insert ProgramArguments.2 -string "$DATA_ROOT" "$PLIST"
/usr/bin/plutil -remove ProgramArguments.4 "$PLIST"
/usr/bin/plutil -insert ProgramArguments.4 -string "$USER_ID" "$PLIST"
/usr/sbin/chown root:wheel "$PLIST"
/bin/chmod 644 "$PLIST"
/bin/rm -f "$DEST/control.pid"
/bin/launchctl enable system/io.github.flowseal.zapretmac
I=0
while ! /bin/launchctl bootstrap system "$PLIST"; do
    I=$((I + 1))
    if [ "$I" -gt 10 ]; then
        /bin/sh "$DEST/stop.sh"
        exit 1
    fi
    sleep 0.5
done

I=0
while [ ! -s "$DEST/control.pid" ] || ! kill -0 "$(/bin/cat "$DEST/control.pid" 2>/dev/null)" 2>/dev/null; do
    I=$((I + 1))
    if [ "$I" -gt 100 ]; then
        /bin/sh "$DEST/stop.sh"
        echo 'Zapret controller did not stay running' >&2
        /usr/bin/tail -40 "$DEST/zapret.log" >&2 2>/dev/null || true
        exit 1
    fi
    sleep 0.1
done
/usr/bin/install -o root -g wheel -m 0644 "$SOURCE/CONTROL_VERSION" "$DEST/CONTROL_VERSION"
