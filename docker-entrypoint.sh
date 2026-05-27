#!/usr/bin/env bash
set -Eeuo pipefail

COMMAND="${1:-scheduler}"
CONFIG_PATH="${MAM_CONFIG:-/config/config.env}"
INTERVAL_SECONDS="${MAM_INTERVAL_SECONDS:-3600}"

if [[ ! "$INTERVAL_SECONDS" =~ ^[0-9]+$ || "$INTERVAL_SECONDS" -le 0 ]]; then
  echo "[ERROR] MAM_INTERVAL_SECONDS must be a positive integer: $INTERVAL_SECONDS" >&2
  exit 1
fi

if [[ "$COMMAND" == "scheduler" ]]; then
  if [[ ! -f "$CONFIG_PATH" ]]; then
    echo "[ERROR] Missing config file: $CONFIG_PATH" >&2
    echo "[ERROR] Create it from config/config.env.example and set MAM_ID or MAM_ID_FILE." >&2
    exit 1
  fi

  echo "[INFO] Starting mam-bonus-manager scheduler"
  echo "[INFO] Interval: ${INTERVAL_SECONDS} seconds"
  echo "[INFO] Config: $CONFIG_PATH"

  while true; do
    echo "[INFO] Running mam-bonus-manager..."
    mam-bonus-manager --config "$CONFIG_PATH" run || echo "[ERROR] mam-bonus-manager failed" >&2

    echo "[INFO] Sleeping ${INTERVAL_SECONDS} seconds..."
    sleep "$INTERVAL_SECONDS"
  done
fi

exec mam-bonus-manager "$@"
