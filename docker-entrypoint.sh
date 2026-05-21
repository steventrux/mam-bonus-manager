#!/usr/bin/env bash
set -Eeuo pipefail

COMMAND="${1:-scheduler}"
CONFIG_PATH="${MAM_CONFIG:-/config/config.env}"

if [[ "$COMMAND" == "scheduler" ]]; then
  if [[ ! -f "$CONFIG_PATH" ]]; then
    echo "[ERROR] Missing config file: $CONFIG_PATH" >&2
    echo "[ERROR] Create it from config/config.env.example and set MAM_ID or MAM_ID_FILE." >&2
    exit 1
  fi

  echo "[INFO] Starting mam-bonus-manager scheduler"
  echo "[INFO] Interval: ${MAM_INTERVAL_SECONDS:-3600} seconds"
  echo "[INFO] Config: $CONFIG_PATH"

  while true; do
    echo "[INFO] Running mam-bonus-manager..."
    mam-bonus-manager run || echo "[ERROR] mam-bonus-manager failed" >&2

    echo "[INFO] Sleeping ${MAM_INTERVAL_SECONDS:-3600} seconds..."
    sleep "${MAM_INTERVAL_SECONDS:-3600}"
  done
fi

exec mam-bonus-manager "$@"
