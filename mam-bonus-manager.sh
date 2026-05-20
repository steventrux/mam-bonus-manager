#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="1.0.0"
CONFIG_FILE="${MAM_CONFIG:-/etc/mam-bonus-manager/config.env}"
DRY_RUN=0
COMMAND="run"

log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { printf '[%s] WARNING: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
fatal(){ printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; exit 1; }

usage() {
  cat <<USAGE
mam-bonus-manager v${VERSION}

Usage:
  ./mam-bonus-manager.sh [options] [command]

Commands:
  run             Run the full cycle: session, wedge, VIP, upload credit. Default.
  check-session   Validate or recreate the MAM session only.
  points          Show the current seedbonus balance only.
  help            Show this help message.

Options:
  --config FILE   Configuration file to use. Default: ${CONFIG_FILE}
  --dry-run       Do not buy anything; only print what would be done.
  --version       Show the version.

Examples:
  ./mam-bonus-manager.sh --dry-run
  MAM_CONFIG=./config.env ./mam-bonus-manager.sh run
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config) CONFIG_FILE="${2:-}"; [[ -n "$CONFIG_FILE" ]] || fatal "--config requires a file path"; shift 2 ;;
      --dry-run) DRY_RUN=1; shift ;;
      --version) echo "$VERSION"; exit 0 ;;
      -h|--help|help) COMMAND="help"; shift ;;
      run|check-session|points) COMMAND="$1"; shift ;;
      *) fatal "Unknown argument: $1" ;;
    esac
  done
}

load_config() {
  [[ -r "$CONFIG_FILE" ]] || fatal "Configuration file is not readable: $CONFIG_FILE. Copy config/config.env.example and set MAM_ID."
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"

  : "${MAM_ID:?MAM_ID is missing in $CONFIG_FILE}"
  : "${WORKDIR:=/opt/MAM}"
  : "${BUFFER:=55000}"
  : "${VIP:=0}"
  : "${WEDGE_HOURS:=4}"
  : "${WEDGE_COST:=50000}"
  : "${WEDGE_RESERVE_AFTER:=5000}"
  : "${CURL_TIMEOUT:=30}"
  : "${CURL_RETRIES:=3}"
  : "${USER_AGENT:=Mozilla/5.0 mam-bonus-manager/${VERSION}}"
  : "${UPLOAD_PACKS:=100 20 5 1}"

  BASE_URL="https://www.myanonamouse.net"
  COOKIE_FILE="${WORKDIR}/MAM.cookies"
  JSON_FILE="${WORKDIR}/MAM.json"
  LOCK_FILE="${WORKDIR}/mam-bonus-manager.lock"
  WEDGE_STATE_FILE="${WORKDIR}/wedge.last"

  mkdir -p "$WORKDIR"
  chmod 700 "$WORKDIR" 2>/dev/null || true
  touch "$COOKIE_FILE"
  chmod 600 "$COOKIE_FILE" 2>/dev/null || true
}

check_dependencies() {
  local missing=()
  for bin in curl jq date find flock; do
    command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
  done
  [[ ${#missing[@]} -eq 0 ]] || fatal "Missing dependencies: ${missing[*]}"
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

valid_number() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

int_part() {
  printf '%s\n' "$1" | sed -E 's/\..*$//'
}

get_uid_from_summary() {
  local response uid
  response="$(json_get "${BASE_URL}/jsonLoad.php?snatch_summary" 2>/dev/null)" || return 1
  printf '%s' "$response" > "$JSON_FILE"
  uid="$(jq -r '.uid // empty' < "$JSON_FILE" 2>/dev/null || true)"
  [[ -n "$uid" && "$uid" != "null" ]] || return 1
  printf '%s\n' "$uid"
}

create_session() {
  local response uid
  log "Session is invalid: trying to create a new one with MAM_ID."
  response="$(json_get_with_mamid "${BASE_URL}/jsonLoad.php?snatch_summary")" || return 1
  printf '%s' "$response" > "$JSON_FILE"
  uid="$(jq -r '.uid // empty' < "$JSON_FILE" 2>/dev/null || true)"
  [[ -n "$uid" && "$uid" != "null" ]] || return 1
  chmod 600 "$COOKIE_FILE" 2>/dev/null || true
  printf '%s\n' "$uid"
}

ensure_session() {
  local uid
  log "Checking existing cookie."
  if uid="$(get_uid_from_summary)"; then
    log "Existing session is valid. UID: ${uid}"
    printf '%s\n' "$uid"
    return 0
  fi

  uid="$(create_session)" || fatal "Could not create a new MAM session. Check MAM_ID."
  log "New session created. UID: ${uid}"
  printf '%s\n' "$uid"
}

get_points() {
  local uid="$1" response points
  response="$(json_get "${BASE_URL}/jsonLoad.php?id=${uid}")" || fatal "Could not read seedbonus balance."
  points="$(jq -r '.seedbonus // empty' <<< "$response" 2>/dev/null || true)"
  valid_number "$points" || fatal "Invalid seedbonus value in JSON response: ${points:-empty}"
  int_part "$points"
}

buy_wedge_if_needed() {
  local points="$1" now mins min_points result success

  [[ "$WEDGE_HOURS" -gt 0 ]] || { printf '%s\n' "$points"; return 0; }

  mins=$((WEDGE_HOURS * 60 - 10))
  [[ "$mins" -lt 1 ]] && mins=1

  if find "$WEDGE_STATE_FILE" -mmin "-${mins}" 2>/dev/null | grep -q .; then
    log "A wedge was bought recently: skipping."
    printf '%s\n' "$points"
    return 0
  fi

  min_points=$((WEDGE_COST + WEDGE_RESERVE_AFTER))
  if [[ "$points" -lt "$min_points" ]]; then
    log "A wedge is due, but there are not enough points: ${points}. Required minimum: ${min_points}."
    printf '%s\n' "$points"
    return 0
  fi

  log "A wedge is due. Current points: ${points}."
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: would buy one wedge and update ${WEDGE_STATE_FILE}."
    printf '%s\n' "$points"
    return 0
  fi

  now="$(date +%s%3N)"
  result="$(json_get "${BASE_URL}/json/bonusBuy.php/?spendtype=wedges&source=points&_=${now}")" || fatal "Wedge purchase failed: curl/API error."
  success="$(jq -r '.success // empty' <<< "$result" 2>/dev/null || true)"
  [[ "$success" == "true" ]] || warn "Wedge response does not report success=true: $result"
  touch "$WEDGE_STATE_FILE"
  log "Wedge purchased."
  printf '%s\n' "$(get_points "$MAM_UID")"
}

buy_vip_if_enabled() {
  local now result success
  [[ "$VIP" == "1" || "$VIP" == "true" || "$VIP" == "yes" ]] || return 0

  log "VIP is enabled: trying to maximize duration."
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: would buy VIP duration=max."
    return 0
  fi

  now="$(date +%s%3N)"
  result="$(json_get "${BASE_URL}/json/bonusBuy.php/?spendtype=VIP&duration=max&_=${now}")" || { warn "VIP purchase failed: curl/API error."; return 0; }
  success="$(jq -r '.success // empty' <<< "$result" 2>/dev/null || true)"
  if [[ "$success" == "true" ]]; then
    log "VIP purchased/extended."
  else
    warn "VIP purchase was not confirmed: $result"
  fi
}

buy_upload_until_buffer() {
  local points="$1" pack required now response new_points
  for pack in $UPLOAD_PACKS; do
    [[ "$pack" =~ ^[0-9]+$ ]] || fatal "UPLOAD_PACKS contains a non-numeric value: $pack"
    required=$((pack * 500 + BUFFER))
    log "Checking ${pack}GB upload package. Purchase threshold: > ${required} points."

    while [[ "$points" -gt "$required" ]]; do
      log "${points} > ${required}: buying ${pack}GB of upload credit."
      if [[ "$DRY_RUN" -eq 1 ]]; then
        log "DRY-RUN: would buy ${pack}GB. Estimated decrease: $((pack * 500)) points."
        points=$((points - pack * 500))
        continue
      fi

      now="$(date +%s%3N)"
      response="$(json_get "${BASE_URL}/json/bonusBuy.php/?spendtype=upload&amount=${pack}&_=${now}")" || fatal "Upload purchase failed for ${pack}GB: curl/API error."
      new_points="$(jq -r '.seedbonus // empty' <<< "$response" 2>/dev/null || true)"
      valid_number "$new_points" || fatal "Upload purchase could not be verified. Response: $response"
      new_points="$(int_part "$new_points")"

      if [[ "$new_points" -lt "$points" ]]; then
        points="$new_points"
        log "Purchase completed. Remaining points: ${points}."
      else
        fatal "Points did not decrease after the purchase. Before=${points}, After=${new_points}."
      fi
    done
  done
  printf '%s\n' "$points"
}

run_main() {
  check_dependencies
  load_config

  exec 9>"$LOCK_FILE"
  flock -n 9 || fatal "Another run is already in progress: $LOCK_FILE"

  MAM_UID="$(ensure_session | tail -n1)"
  [[ "$COMMAND" == "check-session" ]] && return 0

  log "Fetching current points."
  POINTS="$(get_points "$MAM_UID")"
  log "Current points: ${POINTS}"
  [[ "$COMMAND" == "points" ]] && return 0

  POINTS="$(buy_wedge_if_needed "$POINTS" | tail -n1)"
  buy_vip_if_enabled
  POINTS="$(buy_upload_until_buffer "$POINTS" | tail -n1)"
  log "Done. Final estimated/current points: ${POINTS}"
}

parse_args "$@"
if [[ "$COMMAND" == "help" ]]; then
  usage
  exit 0
fi
run_main
