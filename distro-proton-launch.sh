#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")" && pwd)"
BRIDGE="$DIR/distro-proton-bridge.py"

if [[ -z "${WINEDLLOVERRIDES:-}" ]]; then
  export WINEDLLOVERRIDES="version=n,b"
fi

if [[ -z "${STEAM_COMPAT_DATA_PATH:-}" ]]; then
  echo "Distro :: STEAM_COMPAT_DATA_PATH is unset; cannot locate Proton prefix" >&2
  exec "$@"
fi

IPC_DIR="${STEAM_COMPAT_DATA_PATH}/pfx/drive_c/users/steamuser/AppData/Local/Temp/distro-ipc"
mkdir -p "$IPC_DIR"
rm -f "$IPC_DIR"/req-*.json "$IPC_DIR"/rep-*.json "$IPC_DIR"/bridge.ready 2>/dev/null || true

if [[ ! -f "$BRIDGE" ]]; then
  echo "Distro :: missing bridge script: $BRIDGE" >&2
  exec "$@"
fi

python3 "$BRIDGE" --dir "$IPC_DIR" &
BRIDGE_PID=$!

cleanup() {
  kill "$BRIDGE_PID" 2>/dev/null || true
  wait "$BRIDGE_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

for _ in $(seq 1 50); do
  if [[ -f "$IPC_DIR/bridge.ready" ]]; then
    break
  fi
  sleep 0.05
done

exec "$@"
