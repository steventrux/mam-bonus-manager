#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="${MAM_CONFIG:-/etc/mam-bonus-manager/config.env}"
DRY_RUN=1
VERBOSITY=1
LOG_FILE=""

log_line() {
  local level="$1"
  local message="$2"
  local level_num=1
  local log_msg

  case "$level" in
    ERROR) level_num=0 ;;
    WARN) level_num=1 ;;
    INFO) level_num=1 ;;
    DEBUG) level_num=2 ;;
  esac

  if [[ "${VERBOSITY:-1}" -ge "$level_num" ]]; then
    log_msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message"
    printf '%s\n' "$log_msg" >&2
    if [[ -n "${LOG_FILE:-}" ]]; then
      printf '%s\n' "$log_msg" >> "$LOG_FILE"
    fi
  fi
}

log() { log_line INFO "$*"; }
debug() { log_line DEBUG "$*"; }
warn() { log_line WARN "$*"; }
fatal() { log_line ERROR "$*"; exit 1; }

truthy() {
  [[ "$1" == "1" || "$1" == "true" || "$1" == "yes" || "$1" == "on" ]]
}

valid_integer() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

json_get() {
  local url="$1"
  curl -fsS --retry "$CURL_RETRIES" --retry-delay 2 --connect-timeout 10 --max-time "$CURL_TIMEOUT" \
    -A "$USER_AGENT" -b "$COOKIE_FILE" -c "$COOKIE_FILE" "$url"
}

json_get_with_mamid() {
  local url="$1"
  curl -fsS --retry "$CURL_RETRIES" --retry-delay 2 --connect-timeout 10 --max-time "$CURL_TIMEOUT" \
    -A "$USER_AGENT" -b "mam_id=${MAM_ID}" -c "$COOKIE_FILE" "$url"
}

load_config() {
  [[ -r "$CONFIG_FILE" ]] || fatal "Configuration file is not readable: $CONFIG_FILE"
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"

  VERBOSITY="${MAM_VERBOSITY:-${VERBOSITY:-1}}"
  LOG_FILE="${MAM_LOG_FILE:-${LOG_FILE:-}}"

  MAM_ID="${MAM_TOKEN:-${MAM_ID:-}}"
  MAM_ID_FILE="${MAM_TOKEN_FILE:-${MAM_ID_FILE:-}}"
  WORKDIR="${MAM_WORKDIR:-${WORKDIR:-/opt/MAM}}"

  DONATIONS="${MAM_DONATIONS:-${DONATIONS:-0}}"
  BONUS_RESERVE_POINTS="${MAM_BONUS_RESERVE_POINTS:-${BONUS_RESERVE_POINTS:-55000}}"
  DONATION_AMOUNT="${MAM_DONATION_AMOUNT:-${DONATION_AMOUNT:-100}}"
  DONATION_MAX_USERS_PER_RUN="${MAM_DONATION_MAX_USERS_PER_RUN:-${DONATION_MAX_USERS_PER_RUN:-5}}"
  DONATION_MAX_POINTS_PER_USER="${MAM_DONATION_MAX_POINTS_PER_USER:-${DONATION_MAX_POINTS_PER_USER:-1000}}"
  DONATION_COOLDOWN_DAYS="${MAM_DONATION_COOLDOWN_DAYS:-${DONATION_COOLDOWN_DAYS:-30}}"
  DONATION_MAX_RECIPIENT_UPLOADED_BYTES="${MAM_DONATION_MAX_RECIPIENT_UPLOADED_BYTES:-${DONATION_MAX_RECIPIENT_UPLOADED_BYTES:-53687091200}}"
  DONATION_LATEST_UID_STEP="${MAM_DONATION_LATEST_UID_STEP:-${DONATION_LATEST_UID_STEP:-1000}}"
  DONATION_SCAN_LOOKBACK="${MAM_DONATION_SCAN_LOOKBACK:-${DONATION_SCAN_LOOKBACK:-100}}"
  DONATION_SCAN_DELAY_SECONDS="${MAM_DONATION_SCAN_DELAY_SECONDS:-${DONATION_SCAN_DELAY_SECONDS:-1}}"
  UPLOAD_RATIO_THRESHOLD="${MAM_UPLOAD_RATIO_THRESHOLD:-${UPLOAD_RATIO_THRESHOLD:-2.5}}"

  CURL_TIMEOUT="${MAM_CURL_TIMEOUT:-${CURL_TIMEOUT:-30}}"
  CURL_RETRIES="${MAM_CURL_RETRIES:-${CURL_RETRIES:-3}}"
  USER_AGENT="${MAM_USER_AGENT:-${USER_AGENT:-Mozilla/5.0 mam-bonus-manager donation-planner}}"

  if [[ -n "$MAM_ID_FILE" ]]; then
    [[ -r "$MAM_ID_FILE" ]] || fatal "MAM_ID_FILE is not readable: $MAM_ID_FILE"
    MAM_ID="$(tr -d '[:space:]' < "$MAM_ID_FILE")"
  fi
  [[ -n "$MAM_ID" ]] || fatal "MAM_ID is missing. Set MAM_ID or MAM_ID_FILE in $CONFIG_FILE."

  BASE_URL="https://www.myanonamouse.net"
  COOKIE_FILE="${MAM_COOKIE_FILE:-${COOKIE_FILE:-${WORKDIR}/MAM.cookies}}"
  JSON_FILE="${MAM_JSON_FILE:-${JSON_FILE:-${WORKDIR}/MAM.json}}"
  DONATION_STATE_FILE="${MAM_DONATION_STATE_FILE:-${DONATION_STATE_FILE:-${WORKDIR}/donations.tsv}}"
  DONATION_EXCLUSION_FILE="${MAM_DONATION_EXCLUSION_FILE:-${DONATION_EXCLUSION_FILE:-${WORKDIR}/donation-exclusions.tsv}}"
  MAM_BROWSER_PROFILE_DIR="${MAM_BROWSER_PROFILE_DIR:-${WORKDIR}/browser-profile}"
  MAM_BROWSER_TIMEOUT="${MAM_BROWSER_TIMEOUT:-30000}"
  MAM_LOGIN_EMAIL="${MAM_LOGIN_EMAIL:-}"
  MAM_LOGIN_PASSWORD_FILE="${MAM_LOGIN_PASSWORD_FILE:-}"
  MAM_LOGIN_PASSWORD="${MAM_LOGIN_PASSWORD:-}"

  mkdir -p "$WORKDIR"
  chmod 700 "$WORKDIR" 2>/dev/null || true
  touch "$COOKIE_FILE"
  chmod 600 "$COOKIE_FILE" 2>/dev/null || true
}

ensure_session() {
  local response uid

  response="$(json_get "${BASE_URL}/jsonLoad.php?snatch_summary" 2>/dev/null || true)"
  uid="$(jq -r '.uid // empty' <<< "$response" 2>/dev/null || true)"
  if [[ -n "$uid" && "$uid" != "null" ]]; then
    printf '%s\n' "$uid"
    return 0
  fi

  response="$(json_get_with_mamid "${BASE_URL}/jsonLoad.php?snatch_summary")" || return 1
  printf '%s' "$response" > "$JSON_FILE"
  uid="$(jq -r '.uid // empty' <<< "$response" 2>/dev/null || true)"
  [[ -n "$uid" && "$uid" != "null" ]] || return 1
  printf '%s\n' "$uid"
}

get_points() {
  local uid="$1" response points
  response="$(json_get "${BASE_URL}/jsonLoad.php?id=${uid}")" || fatal "Could not read seedbonus balance."
  points="$(jq -r '.seedbonus // empty' <<< "$response" 2>/dev/null || true)"
  [[ "$points" =~ ^[0-9]+([.][0-9]+)?$ ]] || fatal "Invalid seedbonus value: ${points:-empty}"
  printf '%s\n' "$points" | sed -E 's/\..*$//'
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../lib/donations.sh
source "${REPO_ROOT}/lib/donations.sh"

main() {
  local uid points planned=0 candidate_uid candidate_name spendable

  local missing=() bin

  for bin in curl jq date find grep sed awk tr; do
    command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
  done
  [[ ${#missing[@]} -eq 0 ]] || fatal "Missing dependencies: ${missing[*]}"

  load_config
  truthy "$DONATIONS" || { log "DONATIONS is disabled. Nothing to plan."; return 0; }

  valid_integer "$BONUS_RESERVE_POINTS" || fatal "BONUS_RESERVE_POINTS must be numeric: $BONUS_RESERVE_POINTS"
  valid_integer "$DONATION_AMOUNT" || fatal "DONATION_AMOUNT must be numeric: $DONATION_AMOUNT"
  valid_integer "$DONATION_MAX_USERS_PER_RUN" || fatal "DONATION_MAX_USERS_PER_RUN must be numeric: $DONATION_MAX_USERS_PER_RUN"
  valid_integer "$DONATION_MAX_POINTS_PER_USER" || fatal "DONATION_MAX_POINTS_PER_USER must be numeric: $DONATION_MAX_POINTS_PER_USER"
  valid_integer "$DONATION_COOLDOWN_DAYS" || fatal "DONATION_COOLDOWN_DAYS must be numeric: $DONATION_COOLDOWN_DAYS"
  valid_integer "$DONATION_MAX_RECIPIENT_UPLOADED_BYTES" || fatal "DONATION_MAX_RECIPIENT_UPLOADED_BYTES must be numeric: $DONATION_MAX_RECIPIENT_UPLOADED_BYTES"
  valid_integer "$DONATION_LATEST_UID_STEP" || fatal "DONATION_LATEST_UID_STEP must be numeric: $DONATION_LATEST_UID_STEP"
  valid_integer "$DONATION_SCAN_LOOKBACK" || fatal "DONATION_SCAN_LOOKBACK must be numeric: $DONATION_SCAN_LOOKBACK"
  valid_integer "$DONATION_SCAN_DELAY_SECONDS" || fatal "DONATION_SCAN_DELAY_SECONDS must be numeric: $DONATION_SCAN_DELAY_SECONDS"

  uid="$(ensure_session)" || fatal "Could not create or validate MAM session."
  MAM_UID="$uid"
  points="$(get_points "$uid")"
  log "Current points: ${points}. Bonus reserve: ${BONUS_RESERVE_POINTS}."

  if [[ "$points" -le "$BONUS_RESERVE_POINTS" ]]; then
    log "No donation planned: points are not above BONUS_RESERVE_POINTS."
    return 0
  fi

  spendable=$((points - BONUS_RESERVE_POINTS))
  log "Donation spendable points above reserve: ${spendable}."

  while IFS=$'\t' read -r candidate_uid candidate_name; do
    [[ -n "$candidate_uid" && -n "$candidate_name" ]] || continue
    [[ "$planned" -lt "$DONATION_MAX_USERS_PER_RUN" ]] || break
    [[ "$spendable" -ge "$DONATION_AMOUNT" ]] || break

    if plan_donation "$candidate_uid" "$candidate_name" "$DONATION_AMOUNT"; then
      log "DRY-RUN: would donate ${DONATION_AMOUNT} bonus point(s) to ${candidate_name} (uid=${candidate_uid})."
      planned=$((planned + 1))
      spendable=$((spendable - DONATION_AMOUNT))
    fi
  done < <(get_new_users)

  log "Donation dry-run planning completed. Planned donations: ${planned}."
}

main "$@"
