#!/bin/sh

/bin/launchctl disable system/io.github.flowseal.zapretmac >/dev/null 2>&1 || true
/bin/launchctl bootout system/io.github.flowseal.zapretmac >/dev/null 2>&1 || true
/usr/bin/pkill -9 -x utunws >/dev/null 2>&1 || true
/bin/sh "$(/usr/bin/dirname "$0")/cleanup.sh"
