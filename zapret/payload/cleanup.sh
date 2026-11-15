#!/bin/sh

ANCHOR=com.apple/zapret-macos
TOKEN_FILE=/var/run/zapret-macos.pf-token
KEEPINIT_FILE=/var/db/zapret-macos.keepinit

/sbin/pfctl -a "$ANCHOR" -F all >/dev/null 2>&1 || true
if [ -s "$TOKEN_FILE" ]; then
    TOKEN=$(/bin/cat "$TOKEN_FILE" 2>/dev/null || true)
    case "$TOKEN" in
        *[!0-9]*|'') ;;
        *) /sbin/pfctl -X "$TOKEN" >/dev/null 2>&1 || true ;;
    esac
    /bin/rm -f "$TOKEN_FILE"
fi
if [ -s "$KEEPINIT_FILE" ]; then
    KEEPINIT=$(/bin/cat "$KEEPINIT_FILE" 2>/dev/null || true)
    case "$KEEPINIT" in
        *[!0-9]*|'') ;;
        *) /usr/sbin/sysctl -w "net.inet.tcp.keepinit=$KEEPINIT" >/dev/null 2>&1 || true ;;
    esac
    /bin/rm -f "$KEEPINIT_FILE"
fi
