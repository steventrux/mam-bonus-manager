#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="1.2.3"
CONFIG_FILE="${MAM_CONFIG:-/etc/mam-bonus-manager/config.env}"
DRY_RUN=0
COMMAND="run"
VERBOSITY=1
LOG_FILE=""

log_line() {
  local level="$1"
  local message="$2"
  local level_num=1
  local log_msg

  case "$level" in
    ERROR) level_num=0 ;;
    WARN)  level_num=1 ;;
    INFO)  level_num=1 ;;
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

log()   { log_line INFO "$*"; }
debug() { log_line DEBUG "$*"; }
warn()  { log_line WARN "$*"; }
fatal() { log_line ERROR "$*"; exit 1; }

usage() {
  cat <<USAGE
mam-bonus-manager v${VERSION}

Usage:
  ./mam-bonus-manager.sh [options] [command]

Commands:
  run             Run the automated cycle: session, VIP, wedge, upload credit. Default.
  manual          Interactive manual mode: choose VIP, wedges and upload credit step by step.
  interactive     Alias of manual.
  check-session   Validate or recreate the MAM session only.
  points          Show the current seedbonus balance only.
  help            Show this help message.

Options:
  --config FILE   Configuration file to use. Default: ${CONFIG_FILE}
  --dry-run       Do not buy anything; only print what would be done.
  --version       Show the version.

Examples:
  ./mam-bonus-manager.sh --dry-run
  ./mam-bonus-manager.sh --dry-run manual
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
      run|manual|interactive|check-session|points) COMMAND="$1"; shift ;;
      *) fatal "Unknown argument: $1" ;;
    esac
  done
}

truthy() {
  [[ "$1" == "1" || "$1" == "true" || "$1" == "yes" || "$1" == "on" ]]
}

vip_purchase_allowed() {
  local class_name="$1"
  case "$class_name" in
    VIP|"Power User") return 0 ;;
    *) return 1 ;;
  esac
}

load_config() {
  [[ -r "$CONFIG_FILE" ]] || fatal "Configuration file is not readable: $CONFIG_FILE. Copy config/config.env.example and set MAM_ID or MAM_ID_FILE."
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"

  DRY_RUN="${MAM_DRY_RUN:-${MAM_DRYRUN:-$DRY_RUN}}"
  VERBOSITY="${MAM_VERBOSITY:-${VERBOSITY:-1}}"
  LOG_FILE="${MAM_LOG_FILE:-${LOG_FILE:-}}"

  MAM_ID="${MAM_ID:-}"
  MAM_ID_FILE="${MAM_ID_FILE:-}"
  MAM_ID="${MAM_TOKEN:-${MAM_ID}}"
  MAM_ID_FILE="${MAM_TOKEN_FILE:-${MAM_ID_FILE}}"

  WORKDIR="${MAM_WORKDIR:-${WORKDIR:-/opt/MAM}}"
  BUFFER="${MAM_BUFFER:-${BUFFER:-55000}}"
  VIP="${MAM_VIP:-${VIP:-0}}"
  VIP_BLOCK_COST="${MAM_VIP_BLOCK_COST:-${VIP_BLOCK_COST:-${MAM_VIP_WEEK_COST:-${VIP_WEEK_COST:-5000}}}}"
  VIP_THRESHOLD_WEEKS="${MAM_VIP_THRESHOLD_WEEKS:-${MAM_VIP_THRESHOLD:-${VIP_THRESHOLD_WEEKS:-11}}}"
  WEDGE_HOURS="${MAM_WEDGE_HOURS:-${MAM_WEDGEHOURS:-${WEDGE_HOURS:-4}}}"
  WEDGE_COST="${MAM_WEDGE_COST:-${WEDGE_COST:-50000}}"
  WEDGE_RESERVE_AFTER="${MAM_WEDGE_RESERVE_AFTER:-${WEDGE_RESERVE_AFTER:-5000}}"
  CURL_TIMEOUT="${MAM_CURL_TIMEOUT:-${CURL_TIMEOUT:-30}}"
  CURL_RETRIES="${MAM_CURL_RETRIES:-${CURL_RETRIES:-3}}"
  USER_AGENT="${MAM_USER_AGENT:-${USER_AGENT:-Mozilla/5.0 mam-bonus-manager/${VERSION}}}"
  MIN_UPLOAD_GB="${MAM_MIN_UPLOAD_GB:-${MIN_UPLOAD_GB:-50}}"
  UPLOAD_PACKS="${MAM_UPLOAD_PACKS:-${UPLOAD_PACKS:-100 50}}"
  UPLOAD_RATIO_THRESHOLD="${MAM_UPLOAD_RATIO_THRESHOLD:-${UPLOAD_RATIO_THRESHOLD:-2.5}}"
  DONATIONS="${MAM_DONATIONS:-${DONATIONS:-0}}"
  DONATION_AMOUNT="${MAM_DONATION_AMOUNT:-${DONATION_AMOUNT:-100}}"
  DONATION_BUFFER="${MAM_DONATION_BUFFER:-${DONATION_BUFFER:-5000}}"
  DONATION_MAX_USERS_PER_RUN="${MAM_DONATION_MAX_USERS_PER_RUN:-${DONATION_MAX_USERS_PER_RUN:-5}}"
  DONATION_COOLDOWN_DAYS="${MAM_DONATION_COOLDOWN_DAYS:-${DONATION_COOLDOWN_DAYS:-30}}"

  HEARTBEAT_URL="${MAM_HEARTBEAT_URL:-${MAM_HEARTBEAT:-${HEARTBEAT_URL:-}}}"
  TELEGRAM_BOT_TOKEN="${MAM_TELEGRAM_BOT_TOKEN:-${TELEGRAM_BOT_TOKEN:-}}"
  TELEGRAM_CHAT_ID="${MAM_TELEGRAM_CHAT_ID:-${TELEGRAM_CHAT_ID:-}}"
  TELEGRAM_DAILY_SUMMARY="${MAM_TELEGRAM_DAILY_SUMMARY:-${TELEGRAM_DAILY_SUMMARY:-0}}"

  if [[ -n "$MAM_ID_FILE" ]]; then
    [[ -r "$MAM_ID_FILE" ]] || fatal "MAM_ID_FILE is not readable: $MAM_ID_FILE"
    MAM_ID="$(tr -d '[:space:]' < "$MAM_ID_FILE")"
  fi
  [[ -n "$MAM_ID" ]] || fatal "MAM_ID is missing. Set MAM_ID or MAM_ID_FILE in $CONFIG_FILE."

  BASE_URL="https://www.myanonamouse.net"
  COOKIE_FILE="${MAM_COOKIE_FILE:-${COOKIE_FILE:-${WORKDIR}/MAM.cookies}}"
  JSON_FILE="${MAM_JSON_FILE:-${JSON_FILE:-${WORKDIR}/MAM.json}}"
  LOCK_FILE="${MAM_LOCK_FILE:-${LOCK_FILE:-${WORKDIR}/mam-bonus-manager.lock}}"
  WEDGE_STATE_FILE="${MAM_WEDGE_STATE_FILE:-${WEDGE_STATE_FILE:-${WORKDIR}/wedge.last}}"
  DONATION_STATE_FILE="${MAM_DONATION_STATE_FILE:-${DONATION_STATE_FILE:-${WORKDIR}/donations.tsv}}"
  PURCHASE_LOG_FILE="${MAM_PURCHASE_LOG_FILE:-${PURCHASE_LOG_FILE:-${WORKDIR}/purchases.tsv}}"
  TELEGRAM_SENT_FILE="${MAM_TELEGRAM_SENT_FILE:-${TELEGRAM_SENT_FILE:-${WORKDIR}/telegram-summary.sent}}"

  mkdir -p "$WORKDIR"
  chmod 700 "$WORKDIR" 2>/dev/null || true
  touch "$COOKIE_FILE"
  chmod 600 "$COOKIE_FILE" 2>/dev/null || true
  if [[ -n "$LOG_FILE" ]]; then
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE" 2>/dev/null || true
  fi
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

valid_integer() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

int_part() {
  printf '%s\n' "$1" | sed -E 's/\..*$//'
}

number_lt() {
  local left="$1"
  local right="$2"
  jq -e -n --arg left "$left" --arg right "$right" '($left | tonumber) < ($right | tonumber)' >/dev/null 2>&1
}

number_le_zero() {
  local value="$1"
  jq -e -n --arg value "$value" '($value | tonumber) <= 0' >/dev/null 2>&1
}

ask_integer() {
  local prompt="$1"
  local max_value="$2"
  local answer

  while true; do
    read -r -p "$prompt" answer || answer=""
    answer="${answer:-0}"

    if ! valid_integer "$answer"; then
      warn "Please enter a number between 0 and ${max_value}."
      continue
    fi

    if [[ "$answer" -gt "$max_value" ]]; then
      warn "Maximum allowed value is ${max_value}."
      continue
    fi

    printf '%s\n' "$answer"
    return 0
  done
}

refresh_user_summary() {
  local response
  response="$(json_get "${BASE_URL}/jsonLoad.php?snatch_summary")" || return 1
  printf '%s' "$response" > "$JSON_FILE"
}

get_uid_from_summary() {
  local uid
  refresh_user_summary || return 1
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
  if uid="$(get_uid_from_summary 2>/dev/null)"; then
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

get_ratio() {
  local uid="$1" response ratio
  response="$(json_get "${BASE_URL}/jsonLoad.php?id=${uid}")" || return 1
  ratio="$(jq -r '.ratio // .ratio_real // .uploaded_downloaded_ratio // empty' <<< "$response" 2>/dev/null | head -n1 | tr -d ',' || true)"
  valid_number "$ratio" || return 1
  printf '%s\n' "$ratio"
}

record_purchase() {
  local type="$1"
  local quantity="$2"
  local cost="$3"

  [[ "$DRY_RUN" -eq 0 ]] || return 0
  [[ "$cost" =~ ^-?[0-9]+$ ]] || cost=0
  [[ "$cost" -gt 0 ]] || return 0

  mkdir -p "$(dirname "$PURCHASE_LOG_FILE")"
  printf '%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%d')" "$type" "$quantity" "$cost" >> "$PURCHASE_LOG_FILE"
  chmod 600 "$PURCHASE_LOG_FILE" 2>/dev/null || true
}

send_heartbeat() {
  [[ -n "${HEARTBEAT_URL:-}" ]] || return 0
  debug "Sending heartbeat notification."
  curl -fsS --max-time "$CURL_TIMEOUT" "$HEARTBEAT_URL" >/dev/null || warn "Heartbeat request failed."
}

send_telegram_message() {
  local text="$1"
  [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]] || return 0

  curl -fsS --max-time "$CURL_TIMEOUT" \
    -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${text}" >/dev/null || warn "Telegram notification failed."
}

send_daily_telegram_summary() {
  local target_date purchase_count=0 vip_count=0 vip_points=0 wedge_count=0 wedge_points=0 upload_gb=0 upload_points=0 total_points=0
  local date_field type quantity cost message

  truthy "${TELEGRAM_DAILY_SUMMARY:-0}" || return 0
  [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]] || return 0
  [[ -s "$PURCHASE_LOG_FILE" ]] || return 0

  target_date="$(date -d 'yesterday' '+%Y-%m-%d')"
  touch "$TELEGRAM_SENT_FILE"
  if grep -qx "$target_date" "$TELEGRAM_SENT_FILE"; then
    debug "Telegram daily summary for ${target_date} already sent."
    return 0
  fi

  while IFS=$'\t' read -r date_field type quantity cost; do
    [[ "$date_field" == "$target_date" ]] || continue
    [[ "$cost" =~ ^[0-9]+$ ]] || cost=0
    purchase_count=$((purchase_count + 1))
    total_points=$((total_points + cost))
    case "$type" in
      vip)
        vip_count=$((vip_count + 1))
        vip_points=$((vip_points + cost))
        ;;
      wedge)
        wedge_count=$((wedge_count + quantity))
        wedge_points=$((wedge_points + cost))
        ;;
      upload)
        upload_gb=$((upload_gb + quantity))
        upload_points=$((upload_points + cost))
        ;;
    esac
  done < "$PURCHASE_LOG_FILE"

  [[ "$purchase_count" -gt 0 ]] || return 0

  message="MAM bonus daily summary for ${target_date}
VIP purchases: ${vip_count}, points spent: ${vip_points}
Wedges: ${wedge_count}, points spent: ${wedge_points}
Upload credit: ${upload_gb}GB, points spent: ${upload_points}
Total points spent: ${total_points}"

  send_telegram_message "$message"
  printf '%s\n' "$target_date" >> "$TELEGRAM_SENT_FILE"
  chmod 600 "$TELEGRAM_SENT_FILE" 2>/dev/null || true
  log "Telegram daily summary sent for ${target_date}."
}

should_buy_vip() {
  local current_class vip_until expiry_ts now threshold_ts remaining_days

  refresh_user_summary || {
    warn "Could not refresh user summary before VIP check; skipping automatic VIP purchase."
    return 1
  }

  current_class="$(jq -r '.classname // empty' < "$JSON_FILE" 2>/dev/null || true)"
  vip_until="$(jq -r '.vip_until // empty' < "$JSON_FILE" 2>/dev/null || true)"

  if ! vip_purchase_allowed "$current_class"; then
    log "VIP step skipped for current class '${current_class:-unknown}'."
    return 1
  fi

  if [[ "$current_class" != "VIP" ]]; then
    log "Current class can buy VIP; purchase is eligible."
    return 0
  fi

  if [[ -z "$vip_until" || "$vip_until" == "null" ]]; then
    warn "Current class is VIP, but vip_until is missing; skipping automatic VIP purchase to avoid unnecessary spending."
    return 1
  fi

  expiry_ts="$(date -d "$vip_until" '+%s' 2>/dev/null || echo 0)"
  if [[ "$expiry_ts" -le 0 ]]; then
    warn "Could not parse vip_until='$vip_until'; skipping automatic VIP purchase."
    return 1
  fi

  now="$(date '+%s')"
  threshold_ts=$((now + VIP_THRESHOLD_WEEKS * 604800))
  remaining_days=$(((expiry_ts - now) / 86400))

  if [[ "$expiry_ts" -lt "$threshold_ts" ]]; then
    log "VIP expires within threshold (${remaining_days} days remaining, threshold ${VIP_THRESHOLD_WEEKS} weeks)."
    return 0
  fi

  log "VIP is still valid for about ${remaining_days} days; threshold is ${VIP_THRESHOLD_WEEKS} weeks. Skipping VIP purchase."
  return 1
}

buy_vip_if_enabled() {
  local points="$1" before now result success refreshed_points cost
  truthy "$VIP" || { printf '%s\n' "$points"; return 0; }

  log "VIP is enabled: checking whether purchase is needed."
  if ! should_buy_vip; then
    printf '%s\n' "$points"
    return 0
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: would buy VIP duration=max. Points are left unchanged because the real API decides the final cost."
    printf '%s\n' "$points"
    return 0
  fi

  before="$points"
  now="$(date +%s%3N)"
  result="$(json_get "${BASE_URL}/json/bonusBuy.php/?spendtype=VIP&duration=max&_=${now}")" || {
    warn "VIP purchase failed: curl/API error."
    printf '%s\n' "$points"
    return 0
  }
  success="$(jq -r '.success // empty' <<< "$result" 2>/dev/null || true)"
  if [[ "$success" == "true" ]]; then
    log "VIP purchased/extended. Refreshing points."
    refreshed_points="$(get_points "$MAM_UID")"
    cost=$((before - refreshed_points))
    [[ "$cost" -lt 0 ]] && cost=0
    record_purchase vip max "$cost"
    log "Points after VIP step: ${refreshed_points}"
    printf '%s\n' "$refreshed_points"
  else
    warn "VIP purchase was not confirmed: $result"
    printf '%s\n' "$points"
  fi
}

buy_wedge_if_needed() {
  local points="$1" now mins min_points result success refreshed_points

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
  record_purchase wedge 1 "$WEDGE_COST"
  log "Wedge purchased. Refreshing points."
  refreshed_points="$(get_points "$MAM_UID")"
  log "Points after wedge step: ${refreshed_points}"
  printf '%s\n' "$refreshed_points"
}

buy_upload_until_buffer() {
  local points="$1" pack required now response new_points error_message refreshed_points pack_cost current_ratio
  [[ "$MIN_UPLOAD_GB" =~ ^[0-9]+$ ]] || fatal "MIN_UPLOAD_GB must be numeric: $MIN_UPLOAD_GB"
  valid_number "$UPLOAD_RATIO_THRESHOLD" || fatal "UPLOAD_RATIO_THRESHOLD must be numeric: $UPLOAD_RATIO_THRESHOLD"

  if ! number_le_zero "$UPLOAD_RATIO_THRESHOLD"; then
    current_ratio="$(get_ratio "$MAM_UID")" || {
      warn "Could not read current ratio; skipping automated upload credit purchase for safety."
      printf '%s\n' "$points"
      return 0
    }

    if number_lt "$current_ratio" "$UPLOAD_RATIO_THRESHOLD"; then
      log "Current ratio ${current_ratio} is below threshold ${UPLOAD_RATIO_THRESHOLD}; upload credit purchase is allowed."
    else
      log "Current ratio ${current_ratio} is not below threshold ${UPLOAD_RATIO_THRESHOLD}; skipping upload credit purchase."
      printf '%s\n' "$points"
      return 0
    fi
  else
    log "UPLOAD_RATIO_THRESHOLD is ${UPLOAD_RATIO_THRESHOLD}; ratio guard is disabled."
  fi

  for pack in $UPLOAD_PACKS; do
    [[ "$pack" =~ ^[0-9]+$ ]] || fatal "UPLOAD_PACKS contains a non-numeric value: $pack"

    if [[ "$pack" -lt "$MIN_UPLOAD_GB" ]]; then
      log "Skipping ${pack}GB upload package because automated purchases require at least ${MIN_UPLOAD_GB}GB."
      continue
    fi

    pack_cost=$((pack * 500))
    required=$((pack_cost + BUFFER))
    log "Checking ${pack}GB upload package. Purchase threshold: > ${required} points."

    while [[ "$points" -gt "$required" ]]; do
      log "${points} > ${required}: buying ${pack}GB of upload credit."
      if [[ "$DRY_RUN" -eq 1 ]]; then
        log "DRY-RUN: would buy ${pack}GB. Estimated decrease: ${pack_cost} points."
        points=$((points - pack_cost))
        continue
      fi

      now="$(date +%s%3N)"
      response="$(json_get "${BASE_URL}/json/bonusBuy.php/?spendtype=upload&amount=${pack}&_=${now}")" || fatal "Upload purchase failed for ${pack}GB: curl/API error."
      error_message="$(jq -r '.error // empty' <<< "$response" 2>/dev/null || true)"
      new_points="$(jq -r '.seedbonus // empty' <<< "$response" 2>/dev/null || true)"
      valid_number "$new_points" || fatal "Upload purchase could not be verified for ${pack}GB. API error: ${error_message:-none}. Response: $response"
      new_points="$(int_part "$new_points")"

      if [[ "$new_points" -lt "$points" ]]; then
        points="$new_points"
        record_purchase upload "$pack" "$pack_cost"
        log "Purchase completed. Remaining points reported by API: ${points}."
      else
        fatal "Points did not decrease after the purchase. Before=${points}, After=${new_points}."
      fi
    done
  done

  if [[ "$DRY_RUN" -eq 0 ]]; then
    log "Refreshing points after upload step."
    refreshed_points="$(get_points "$MAM_UID")"
    log "Points after upload step: ${refreshed_points}"
    printf '%s\n' "$refreshed_points"
  else
    printf '%s\n' "$points"
  fi
}

manual_vip_step() {
  local points="$1" option cost now result success error_message before refreshed_points actual_cost current_class
  local max_suffix=""
  valid_integer "$VIP_BLOCK_COST" || fatal "VIP_BLOCK_COST must be numeric: $VIP_BLOCK_COST"

  refresh_user_summary || {
    warn "Could not refresh user summary before VIP step; skipping VIP purchase."
    printf '%s\n' "$points"
    return 0
  }
  current_class="$(jq -r '.classname // empty' < "$JSON_FILE" 2>/dev/null || true)"
  if ! vip_purchase_allowed "$current_class"; then
    log "Manual VIP step skipped for current class '${current_class:-unknown}'."
    printf '%s\n' "$points"
    return 0
  fi

  log "Manual step 1/3 - VIP"
  log "Current class: ${current_class}. Current points: ${points}. VIP options are 4, 8, 12 weeks, or max. Cost is ${VIP_BLOCK_COST} points per 4-week block."
  log "Purchasable VIP durations with the current balance:"
  if [[ "$points" -ge "$VIP_BLOCK_COST" ]]; then
    log " - 4 weeks: available, cost ${VIP_BLOCK_COST} points."
  else
    log " - 4 weeks: unavailable, requires ${VIP_BLOCK_COST} points."
  fi
  if [[ "$points" -ge $((VIP_BLOCK_COST * 2)) ]]; then
    log " - 8 weeks: available, cost $((VIP_BLOCK_COST * 2)) points."
  else
    log " - 8 weeks: unavailable, requires $((VIP_BLOCK_COST * 2)) points."
  fi
  if [[ "$points" -ge $((VIP_BLOCK_COST * 3)) ]]; then
    log " - 12 weeks: available, cost $((VIP_BLOCK_COST * 3)) points."
  else
    log " - 12 weeks: unavailable, requires $((VIP_BLOCK_COST * 3)) points."
  fi
  if [[ "$points" -ge "$VIP_BLOCK_COST" ]]; then
    log " - max: available; the API will buy the maximum valid duration up to the 90-day limit."
    max_suffix=", max"
  else
    log " - max: unavailable, requires at least ${VIP_BLOCK_COST} points."
  fi

  while true; do
    read -r -p "Choose VIP duration [0, 4, 8, 12${max_suffix}; Enter=0]: " option || option="0"
    option="${option:-0}"
    case "$option" in
      0)
        log "VIP skipped."
        printf '%s\n' "$points"
        return 0
        ;;
      4|8|12)
        cost=$((option * VIP_BLOCK_COST / 4))
        if [[ "$points" -lt "$cost" ]]; then
          warn "Not enough points for ${option} weeks. Required: ${cost}."
          continue
        fi
        break
        ;;
      max)
        cost=0
        if [[ "$points" -lt "$VIP_BLOCK_COST" ]]; then
          warn "Not enough points for max. Required minimum: ${VIP_BLOCK_COST}."
          continue
        fi
        break
        ;;
      *)
        warn "Please enter 0, 4, 8, 12 or max."
        ;;
    esac
  done

  if [[ "$DRY_RUN" -eq 1 ]]; then
    if [[ "$option" == "max" ]]; then
      log "DRY-RUN: would buy VIP duration=max. The API decides the final cost."
      printf '%s\n' "$points"
    else
      log "DRY-RUN: would buy ${option} VIP week(s). Estimated cost: ${cost} points."
      printf '%s\n' "$((points - cost))"
    fi
    return 0
  fi

  before="$points"
  now="$(date +%s%3N)"
  result="$(json_get "${BASE_URL}/json/bonusBuy.php/?spendtype=VIP&duration=${option}&_=${now}")" || fatal "VIP purchase failed: curl/API error."
  error_message="$(jq -r '.error // empty' <<< "$result" 2>/dev/null || true)"
  success="$(jq -r '.success // empty' <<< "$result" 2>/dev/null || true)"
  [[ "$success" == "true" ]] || fatal "VIP purchase was not confirmed. API error: ${error_message:-none}. Response: $result"
  refreshed_points="$(get_points "$MAM_UID")"
  actual_cost=$((before - refreshed_points))
  if [[ "$actual_cost" -lt 0 && "$option" != "max" ]]; then
    actual_cost="$cost"
  elif [[ "$actual_cost" -lt 0 ]]; then
    actual_cost=0
  fi
  record_purchase vip "$option" "$actual_cost"
  log "VIP purchased/extended: duration=${option}."
  printf '%s\n' "$refreshed_points"
}

manual_wedge_step() {
  local points="$1" spendable max_wedges count i now result success error_message estimated_cost
  valid_integer "$WEDGE_COST" || fatal "WEDGE_COST must be numeric: $WEDGE_COST"
  valid_integer "$WEDGE_RESERVE_AFTER" || fatal "WEDGE_RESERVE_AFTER must be numeric: $WEDGE_RESERVE_AFTER"

  log "Manual step 2/3 - Wedges"
  spendable=0
  [[ "$points" -gt "$WEDGE_RESERVE_AFTER" ]] && spendable=$((points - WEDGE_RESERVE_AFTER))
  max_wedges=$((spendable / WEDGE_COST))
  log "Current points: ${points}. Wedge cost: ${WEDGE_COST}. Reserve after wedge purchases: ${WEDGE_RESERVE_AFTER}. Purchasable wedges: ${max_wedges}."

  count="$(ask_integer "Buy how many wedge(s)? [0-${max_wedges}, Enter=0]: " "$max_wedges")"
  [[ "$count" -eq 0 ]] && { log "Wedges skipped."; printf '%s\n' "$points"; return 0; }

  estimated_cost=$((count * WEDGE_COST))
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: would buy ${count} wedge(s). Estimated cost: ${estimated_cost} points."
    printf '%s\n' "$((points - estimated_cost))"
    return 0
  fi

  for ((i = 1; i <= count; i++)); do
    now="$(date +%s%3N)"
    result="$(json_get "${BASE_URL}/json/bonusBuy.php/?spendtype=wedges&source=points&_=${now}")" || fatal "Wedge purchase ${i}/${count} failed: curl/API error."
    error_message="$(jq -r '.error // empty' <<< "$result" 2>/dev/null || true)"
    success="$(jq -r '.success // empty' <<< "$result" 2>/dev/null || true)"
    [[ "$success" == "true" ]] || fatal "Wedge purchase ${i}/${count} was not confirmed. API error: ${error_message:-none}. Response: $result"
    record_purchase wedge 1 "$WEDGE_COST"
    log "Wedge ${i}/${count} purchased."
  done
  touch "$WEDGE_STATE_FILE"
  printf '%s\n' "$(get_points "$MAM_UID")"
}

manual_upload_step() {
  local points="$1" pack pack_cost max_count chosen_pack chosen_count now response new_points error_message allowed_package=0 estimated_cost
  valid_integer "$MIN_UPLOAD_GB" || fatal "MIN_UPLOAD_GB must be numeric: $MIN_UPLOAD_GB"

  log "Manual step 3/3 - Upload credit"
  log "Current points: ${points}. Automated upload minimum: ${MIN_UPLOAD_GB}GB."
  log "Purchasable upload packages with the current balance:"

  for pack in $UPLOAD_PACKS; do
    valid_integer "$pack" || fatal "UPLOAD_PACKS contains a non-numeric value: $pack"
    if [[ "$pack" -lt "$MIN_UPLOAD_GB" ]]; then
      log " - ${pack}GB: unavailable for automated purchases, below ${MIN_UPLOAD_GB}GB minimum."
      continue
    fi
    pack_cost=$((pack * 500))
    max_count=$((points / pack_cost))
    log " - ${pack}GB: up to ${max_count} purchase(s), ${pack_cost} points each."
  done

  read -r -p "Choose upload package size in GB [0 to skip]: " chosen_pack || chosen_pack="0"
  chosen_pack="${chosen_pack:-0}"
  [[ "$chosen_pack" == "0" ]] && { log "Upload credit skipped."; printf '%s\n' "$points"; return 0; }
  valid_integer "$chosen_pack" || fatal "Upload package size must be numeric."

  for pack in $UPLOAD_PACKS; do
    if [[ "$pack" == "$chosen_pack" && "$pack" -ge "$MIN_UPLOAD_GB" ]]; then
      allowed_package=1
      break
    fi
  done
  [[ "$allowed_package" -eq 1 ]] || fatal "Upload package ${chosen_pack}GB is not allowed. Allowed automated packages: ${UPLOAD_PACKS}; minimum: ${MIN_UPLOAD_GB}GB."

  pack_cost=$((chosen_pack * 500))
  max_count=$((points / pack_cost))
  chosen_count="$(ask_integer "Buy how many ${chosen_pack}GB upload package(s)? [0-${max_count}, Enter=0]: " "$max_count")"
  [[ "$chosen_count" -eq 0 ]] && { log "Upload credit skipped."; printf '%s\n' "$points"; return 0; }

  estimated_cost=$((chosen_count * pack_cost))
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: would buy ${chosen_count} x ${chosen_pack}GB upload package(s). Estimated cost: ${estimated_cost} points."
    printf '%s\n' "$((points - estimated_cost))"
    return 0
  fi

  for ((i = 1; i <= chosen_count; i++)); do
    now="$(date +%s%3N)"
    response="$(json_get "${BASE_URL}/json/bonusBuy.php/?spendtype=upload&amount=${chosen_pack}&_=${now}")" || fatal "Upload purchase ${i}/${chosen_count} failed for ${chosen_pack}GB: curl/API error."
    error_message="$(jq -r '.error // empty' <<< "$response" 2>/dev/null || true)"
    new_points="$(jq -r '.seedbonus // empty' <<< "$response" 2>/dev/null || true)"
    valid_number "$new_points" || fatal "Upload purchase ${i}/${chosen_count} could not be verified. API error: ${error_message:-none}. Response: $response"
    new_points="$(int_part "$new_points")"
    record_purchase upload "$chosen_pack" "$pack_cost"
    log "Upload purchase ${i}/${chosen_count} completed. Remaining points reported by API: ${new_points}."
  done
  printf '%s\n' "$(get_points "$MAM_UID")"
}

run_manual_mode() {
  local points="$1"
  log "Interactive manual mode started. Each step shows the currently purchasable quantity before asking for input."
  log "Manual mode does not apply the automated upload buffer. It only prevents spending more points than currently available."
  [[ "$DRY_RUN" -eq 1 ]] && log "DRY-RUN is enabled: no purchase will be sent to MAM."

  points="$(manual_vip_step "$points" | tail -n1)"
  log "Points after VIP step: ${points}"
  points="$(manual_wedge_step "$points" | tail -n1)"
  log "Points after wedge step: ${points}"
  points="$(manual_upload_step "$points" | tail -n1)"
  log "Points after upload step: ${points}"
  log "Interactive manual mode completed. Final estimated/current points: ${points}"
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

  if [[ "$COMMAND" == "manual" || "$COMMAND" == "interactive" ]]; then
    run_manual_mode "$POINTS"
  else
    POINTS="$(buy_vip_if_enabled "$POINTS" | tail -n1)"
    log "Automated balance after VIP step: ${POINTS}"
    POINTS="$(buy_wedge_if_needed "$POINTS" | tail -n1)"
    log "Automated balance after wedge step: ${POINTS}"
    POINTS="$(buy_upload_until_buffer "$POINTS" | tail -n1)"
    log "Automated balance after upload step: ${POINTS}"
    log "Done. Final estimated/current points: ${POINTS}"
  fi

  if [[ "$DRY_RUN" -eq 0 ]]; then
    send_daily_telegram_summary
    send_heartbeat
  fi
}

parse_args "$@"
if [[ "$COMMAND" == "help" ]]; then
  usage
  exit 0
fi
run_main
