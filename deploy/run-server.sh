#!/bin/bash
# Example launch script for the Tiny Block dedicated server.
# Adjust the paths and arguments to match your setup.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -x "${SCRIPT_DIR}/tinyblock-server.x86_64" ]; then
    BINDIR="$SCRIPT_DIR"
else
    BINDIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi
SERVER_BIN="${BINDIR}/tinyblock-server.x86_64"
WORLD_ID="${WORLD_ID:-world_community_1}"
WORLD_NAME="${WORLD_NAME:-Tiny Block Community}"
WORLD_MODE="${WORLD_MODE:-skyblock}"
MAX_PLAYERS="${MAX_PLAYERS:-16}"

if [ ! -x "$SERVER_BIN" ]; then
    echo "Error: server binary not found at $SERVER_BIN"
    echo "Build it first: godot --headless --export-release 'Dedicated Server (Linux/X11)' build/tinyblock-server.x86_64"
    exit 1
fi

cd "$BINDIR"
exec "$SERVER_BIN" \
    --tinyblock-server \
    --world "$WORLD_ID" \
    --world-name "$WORLD_NAME" \
    --world-mode "$WORLD_MODE" \
    --max-players "$MAX_PLAYERS"
