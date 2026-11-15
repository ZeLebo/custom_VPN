#!/bin/sh

SUPERVISOR_PID=$1
ENGINE_PID=$2
CONTROLLER_PID=${3:-$SUPERVISOR_PID}

while kill -0 "$SUPERVISOR_PID" 2>/dev/null && kill -0 "$ENGINE_PID" 2>/dev/null && kill -0 "$CONTROLLER_PID" 2>/dev/null; do
    sleep 0.2
done

/bin/sh "$(/usr/bin/dirname "$0")/cleanup.sh"
kill "$ENGINE_PID" >/dev/null 2>&1 || true
kill "$SUPERVISOR_PID" >/dev/null 2>&1 || true
