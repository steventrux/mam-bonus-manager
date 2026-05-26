#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="1.4.1"
VIP_BLOCK_COST=5000
WEDGE_COST=50000
CONFIG_FILE="${MAM_CONFIG:-/etc/mam-bonus-manager/config.env}"
DRY_RUN=0
COMMAND="run"
CONFIG_ACTION="migrate"
VERBOSITY=1
LOG_FILE=""
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

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
  run             Run the automated cycle: session, VIP, upload credit, wedge, donations. Default.
  manual          Interactive manual mode: choose VIP, upload credit, wedges and donations step by step.
  interactive     Alias of manual.
  check-session   Validate or recreate the MAM session only.
  points          Show the current seedbonus balance only.
  config          Create or migrate the configuration file from config.env.example.
  config edit     Create/migrate the configuration file, then open it in an editor.
  help            Show this help message.

Options:
  --config FILE   Configuration file to use. Default: ${CONFIG_FILE}
  --dry-run       Do not buy anything; only print what would be done.
  --version       Show the version.
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config) CONFIG_FILE="${2:-}"; [[ -n "$CONFIG_FILE" ]] || fatal "--config requires a file path"; shift 2 ;;
      --dry-run) DRY_RUN=1; shift ;;
      --version) echo "$VERSION"; exit 0 ;;
      -h|--help|help) COMMAND="help"; shift ;;
      config)
        COMMAND="config"
        CONFIG_ACTION="${2:-migrate}"
        case "$CONFIG_ACTION" in
          migrate|edit) ;;
          *) fatal "Unknown config action: ${CONFIG_ACTION}. Supported: migrate, edit." ;;
        esac
        if [[ $# -gt 1 ]]; then
          shift 2
        else
          shift
        fi
        ;;
      run|manual|interactive|check-session|points) COMMAND="$1"; shift ;;
      *) fatal "Unknown argument: $1" ;;
    esac
  done
}

truthy() {
  [[ "$1" == "1" || "$1" == "true" || "$1" == "yes" || "$1" == "on" ]]
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

  CONFIG_VERSION="${MAM_CONFIG_VERSION:-${CONFIG_VERSION:-}}"
  DRY_RUN="${MAM_DRY_RUN:-${MAM_DRYRUN:-$DRY_RUN}}"
  VERBOSITY="${MAM_VERBOSITY:-${VERBOSITY:-1}}"
  LOG_FILE="${MAM_LOG_FILE:-${LOG_FILE:-}}"

  MAM_ID="${MAM_TOKEN:-${MAM_ID:-}}"
  MAM_ID_FILE="${MAM_TOKEN_FILE:-${MAM_ID_FILE:-}}"

  WORKDIR="${MAM_WORKDIR:-${WORKDIR:-/opt/MAM}}"
  BONUS_RESERVE_POINTS="${MAM_BONUS_RESERVE_POINTS:-${BONUS_RESERVE_POINTS:-55000}}"
  VIP="${MAM_VIP:-${VIP:-1}}"
  VIP_THRESHOLD_WEEKS="${MAM_VIP_THRESHOLD_WEEKS:-${MAM_VIP_THRESHOLD:-${VIP_THRESHOLD_WEEKS:-11}}}"
  WEDGE_HOURS="${MAM_WEDGE_HOURS:-${MAM_WEDGEHOURS:-${WEDGE_HOURS:-0}}}"
  CURL_TIMEOUT="${MAM_CURL_TIMEOUT:-${CURL_TIMEOUT:-30}}"
  CURL_RETRIES="${MAM_CURL_RETRIES:-${CURL_RETRIES:-3}}"
  USER_AGENT="${MAM_USER_AGENT:-${USER_AGENT:-Mozilla/5.0 mam-bonus-manager/${VERSION}}}"
  MIN_UPLOAD_GB="${MAM_MIN_UPLOAD_GB:-${MIN_UPLOAD_GB:-50}}"
  UPLOAD_PACKS="${MAM_UPLOAD_PACKS:-${UPLOAD_PACKS:-100 50}}"
  UPLOAD_RATIO_THRESHOLD="${MAM_UPLOAD_RATIO_THRESHOLD:-${UPLOAD_RATIO_THRESHOLD:-2.5}}"

  DONATIONS="${MAM_DONATIONS:-${DONATIONS:-0}}"
  DONATION_AMOUNT="${MAM_DONATION_AMOUNT:-${DONATION_AMOUNT:-100}}"
  DONATION_MAX_USERS_PER_RUN="${MAM_DONATION_MAX_USERS_PER_RUN:-${DONATION_MAX_USERS_PER_RUN:-5}}"
  DONATION_MAX_POINTS_PER_USER="${MAM_DONATION_MAX_POINTS_PER_USER:-${DONATION_MAX_POINTS_PER_USER:-1000}}"
  DONATION_COOLDOWN_DAYS="${MAM_DONATION_COOLDOWN_DAYS:-${DONATION_COOLDOWN_DAYS:-30}}"
  DONATION_MAX_RECIPIENT_UPLOADED_BYTES="${MAM_DONATION_MAX_RECIPIENT_UPLOADED_BYTES:-${DONATION_MAX_RECIPIENT_UPLOADED_BYTES:-53687091200}}"
  DONATION_LATEST_UID_STEP="${MAM_DONATION_LATEST_UID_STEP:-${DONATION_LATEST_UID_STEP:-1000}}"
  DONATION_SCAN_LOOKBACK="${MAM_DONATION_SCAN_LOOKBACK:-${DONATION_SCAN_LOOKBACK:-100}}"
  DONATION_SCAN_MAX_CANDIDATES="${MAM_DONATION_SCAN_MAX_CANDIDATES:-${DONATION_SCAN_MAX_CANDIDATES:-20}}"
  DONATION_SCAN_DELAY_SECONDS="${MAM_DONATION_SCAN_DELAY_SECONDS:-${DONATION_SCAN_DELAY_SECONDS:-1}}"

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
  for bin in curl jq date find flock grep sed awk mktemp; do
    command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
  done
  [[ ${#missing[@]} -eq 0 ]] || fatal "Missing dependencies: ${missing[*]}"
}

config_edit() {
  local editor

  config_migrate

  editor="${EDITOR:-}"
  if [[ -z "$editor" ]]; then
    if command -v nano >/dev/null 2>&1; then
      editor="nano"
    elif command -v vi >/dev/null 2>&1; then
      editor="vi"
    else
      fatal "No editor found. Set EDITOR or install nano/vi."
    fi
  fi

  log "Opening configuration file with: ${editor}"
  "$editor" "$CONFIG_FILE"
}

config_migrate() {
  local example_file target_file target_dir backup_file added_file obsolete_found=0
  local key value line existing_keys tmp_file

  example_file="${SCRIPT_DIR}/config/config.env.example"
  target_file="${CONFIG_FILE}"
  target_dir="$(dirname "$target_file")"

  [[ -r "$example_file" ]] || fatal "Example config not found or not readable: $example_file"

  mkdir -p "$target_dir"

  if [[ ! -e "$target_file" ]]; then
    cp "$example_file" "$target_file"
    chmod 600 "$target_file" 2>/dev/null || true
    log "Configuration file created: $target_file"
    log "Edit it and set MAM_ID or MAM_ID_FILE before running the script."
    return 0
  fi

  [[ -r "$target_file" ]] || fatal "Configuration file is not readable: $target_file"

  backup_file="${target_file}.bak.$(date +%Y%m%d_%H%M%S)"
  cp "$target_file" "$backup_file"
  chmod 600 "$backup_file" 2>/dev/null || true
  log "Backup created: $backup_file"

  tmp_file="$(mktemp)"
  added_file="$(mktemp)"

  example_keys="$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$example_file" | cut -d= -f1 | sort -u)"
  example_config_version="$(grep -E '^CONFIG_VERSION=' "$example_file" | head -n1 | cut -d= -f2- || true)"

  # Comment active KEY=VALUE lines that are no longer present in config.env.example.
  # The example file is the source of truth for user-configurable settings.
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      key="${line%%=*}"
      if ! grep -qx "$key" <<< "$example_keys"; then
        if [[ "$obsolete_found" -eq 0 ]]; then
          printf '%s\n' '# Obsolete settings commented by mam-bonus-manager config migration.' >> "$tmp_file"
          obsolete_found=1
        fi
        printf '# OBSOLETE: no longer present in config/config.env.example.\n' >> "$tmp_file"
        printf '# %s\n' "$line" >> "$tmp_file"
        continue
      fi

      if [[ "$key" == "CONFIG_VERSION" && -n "$example_config_version" ]]; then
        printf 'CONFIG_VERSION=%s\n' "$example_config_version" >> "$tmp_file"
        continue
      fi
    fi

    printf '%s\n' "$line" >> "$tmp_file"
  done < "$target_file"

  existing_keys="$(grep -E '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=' "$tmp_file" | sed -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=.*/\1/' | sort -u)"

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue

    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"

    if ! grep -qx "$key" <<< "$existing_keys"; then
      printf '%s=%s\n' "$key" "$value" >> "$added_file"
      existing_keys="${existing_keys}"$'\n'"${key}"
    fi
  done < "$example_file"

  if [[ -s "$added_file" ]]; then
    {
      printf '\n'
      printf '%s\n' '# Added by mam-bonus-manager config migration.'
      cat "$added_file"
    } >> "$tmp_file"
  fi

  cat "$tmp_file" > "$target_file"
  chmod 600 "$target_file" 2>/dev/null || true

  if [[ -s "$added_file" ]]; then
    log "Configuration migrated: $target_file"
    log "Added missing setting(s):"
    sed 's/^/ - /' "$added_file" >&2
  else
    log "Configuration already contains all current settings."
  fi

  if [[ "$obsolete_found" -eq 1 ]]; then
    warn "Obsolete setting(s) were commented out. Review $target_file before the next real run."
  fi

  rm -f "$tmp_file" "$added_file"
}


auto_migrate_config_if_needed() {
  local example_file example_version config_version

  example_file="${SCRIPT_DIR}/config/config.env.example"

  [[ -r "$CONFIG_FILE" ]] || return 0
  [[ -r "$example_file" ]] || {
    warn "Cannot auto-migrate config: example config not found at $example_file."
    return 0
  }

  example_version="$(grep -E '^CONFIG_VERSION=' "$example_file" | head -n1 | cut -d= -f2- | tr -d '"'\''[:space:]' || true)"
  config_version="$(grep -E '^CONFIG_VERSION=' "$CONFIG_FILE" | head -n1 | cut -d= -f2- | tr -d '"'\''[:space:]' || true)"

  [[ -n "$example_version" ]] || return 0

  if [[ "$config_version" != "$example_version" ]]; then
    log "Config version '${config_version:-missing}' differs from expected version '${example_version}'. Running config migration."
    config_migrate
  fi
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

# shellcheck source=lib/donations.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/donations.sh"

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

get_profile_json() {
  local uid="$1" response error_message
  response="$(json_get "${BASE_URL}/jsonLoad.php?id=${uid}")" || return 1

  error_message="$(jq -r '.error // empty' <<< "$response" 2>/dev/null || true)"
  if [[ -n "$error_message" && "$error_message" != "null" ]]; then
    warn "MAM profile API error for uid=${uid}: ${error_message}"
    return 1
  fi

  printf '%s' "$response"
}

get_points() {
  local uid="$1" response points

  if [[ "${uid}" == "${MAM_UID:-}" ]]; then
    response="$(json_get "${BASE_URL}/jsonLoad.php?snatch_summary")" || fatal "Could not read seedbonus balance from snatch summary."
    points="$(jq -r '.seedbonus // empty' <<< "$response" 2>/dev/null || true)"
    valid_number "$points" || fatal "Invalid seedbonus value in snatch summary JSON response: ${points:-empty}"
    int_part "$points"
    return 0
  fi

  response="$(get_profile_json "$uid")" || fatal "Could not read seedbonus balance."
  points="$(jq -r '.seedbonus // empty' <<< "$response" 2>/dev/null || true)"
  valid_number "$points" || fatal "Invalid seedbonus value in JSON response: ${points:-empty}"
  int_part "$points"
}

get_ratio() {
  local uid="$1" response ratio
  response="$(get_profile_json "$uid")" || return 1
  ratio="$(jq -r '.ratio // .ratio_real // .uploaded_downloaded_ratio // empty' <<< "$response" 2>/dev/null | head -n1 | tr -d ',' || true)"
  valid_number "$ratio" || {
    warn "MAM profile JSON for uid=${uid} does not contain a valid ratio."
    return 1
  }
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
  local target_date purchase_count=0 vip_count=0 vip_points=0 wedge_count=0 wedge_points=0 upload_gb=0 upload_points=0 donation_count=0 donation_points=0 total_points=0
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
      vip) vip_count=$((vip_count + 1)); vip_points=$((vip_points + cost)) ;;
      wedge) wedge_count=$((wedge_count + quantity)); wedge_points=$((wedge_points + cost)) ;;
      upload) upload_gb=$((upload_gb + quantity)); upload_points=$((upload_points + cost)) ;;
      donation) donation_count=$((donation_count + 1)); donation_points=$((donation_points + cost)) ;;
    esac
  done < "$PURCHASE_LOG_FILE"

  [[ "$purchase_count" -gt 0 ]] || return 0

  message="MAM bonus daily summary for ${target_date}
VIP purchases: ${vip_count}, points spent: ${vip_points}
Wedges: ${wedge_count}, points spent: ${wedge_points}
Upload credit: ${upload_gb}GB, points spent: ${upload_points}
Donations: ${donation_count}, points spent: ${donation_points}
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
  if ! truthy "$VIP"; then
    log "VIP step skipped: VIP=0."
    printf '%s\n' "$points"
    return 0
  fi

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
    refreshed_points="$(get_points "$MAM_UID")"
    cost=$((before - refreshed_points))
    [[ "$cost" -lt 0 ]] && cost=0
    record_purchase vip max "$cost"
    log "VIP purchased/extended. Points after VIP step: ${refreshed_points}"
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

  min_points=$((WEDGE_COST + BONUS_RESERVE_POINTS))
  if [[ "$points" -lt "$min_points" ]]; then
    log "A wedge is due, but there are not enough points above reserve: ${points}. Required minimum: ${min_points}."
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
  refreshed_points="$(get_points "$MAM_UID")"
  log "Wedge purchased. Points after wedge step: ${refreshed_points}"
  printf '%s\n' "$refreshed_points"
}

buy_upload_until_buffer() {
  local points="$1" pack required now response new_points error_message refreshed_points pack_cost current_ratio purchased_any=0
  valid_integer "$MIN_UPLOAD_GB" || fatal "MIN_UPLOAD_GB must be numeric: $MIN_UPLOAD_GB"
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
    valid_integer "$pack" || fatal "UPLOAD_PACKS contains a non-numeric value: $pack"

    if [[ "$pack" -lt "$MIN_UPLOAD_GB" ]]; then
      log "Skipping ${pack}GB upload package because automated purchases require at least ${MIN_UPLOAD_GB}GB."
      continue
    fi

    pack_cost=$((pack * 500))

    if [[ "$pack" -eq "$MIN_UPLOAD_GB" ]]; then
      if [[ "$purchased_any" -gt 0 ]]; then
        log "Skipping emergency minimum ${pack}GB upload package because upload credit was already purchased in this run."
        continue
      fi

      required="$pack_cost"
      log "Checking emergency minimum ${pack}GB upload package. Purchase threshold: >= ${required} points."

      if [[ "$points" -lt "$required" ]]; then
        log "Not enough points for emergency minimum ${pack}GB upload package: ${points}. Required minimum: ${required}."
        continue
      fi

      log "${points} >= ${required}: buying one emergency minimum ${pack}GB upload credit package."

      if [[ "$DRY_RUN" -eq 1 ]]; then
        log "DRY-RUN: would buy ${pack}GB. Estimated decrease: ${pack_cost} points."
        points=$((points - pack_cost))
        purchased_any=$((purchased_any + 1))
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
        purchased_any=$((purchased_any + 1))
        record_purchase upload "$pack" "$pack_cost"
        log "Purchase completed. Remaining points reported by API: ${points}."
      else
        fatal "Points did not decrease after the purchase. Before=${points}, After=${new_points}."
      fi

      continue
    fi

    required=$((pack_cost + BONUS_RESERVE_POINTS))
    log "Checking ${pack}GB upload package. Purchase threshold: > ${required} points."

    while [[ "$points" -gt "$required" ]]; do
      log "${points} > ${required}: buying ${pack}GB of upload credit."

      if [[ "$DRY_RUN" -eq 1 ]]; then
        log "DRY-RUN: would buy ${pack}GB. Estimated decrease: ${pack_cost} points."
        points=$((points - pack_cost))
        purchased_any=$((purchased_any + 1))
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
        purchased_any=$((purchased_any + 1))
        record_purchase upload "$pack" "$pack_cost"
        log "Purchase completed. Remaining points reported by API: ${points}."
      else
        fatal "Points did not decrease after the purchase. Before=${points}, After=${new_points}."
      fi
    done
  done

  if [[ "$DRY_RUN" -eq 0 ]]; then
    refreshed_points="$(get_points "$MAM_UID")"
    log "Points after upload step: ${refreshed_points}"
    printf '%s\n' "$refreshed_points"
  else
    printf '%s\n' "$points"
  fi
}

manual_vip_step() {
  local points="$1" option cost now result success error_message before refreshed_points actual_cost current_class max_suffix=""

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

  log "Manual step 1/4 - VIP"
  log "Current class: ${current_class}. Current points: ${points}. VIP options are 4, 8, 12 weeks, or max. Cost is ${VIP_BLOCK_COST} points per 4-week block."

  [[ "$points" -ge "$VIP_BLOCK_COST" ]] && max_suffix=", max"
  while true; do
    read -r -p "Choose VIP duration [0, 4, 8, 12${max_suffix}; Enter=0]: " option || option="0"
    option="${option:-0}"
    case "$option" in
      0) log "VIP skipped."; printf '%s\n' "$points"; return 0 ;;
      4|8|12)
        cost=$((option * VIP_BLOCK_COST / 4))
        [[ "$points" -ge "$cost" ]] || { warn "Not enough points for ${option} weeks. Required: ${cost}."; continue; }
        break
        ;;
      max)
        [[ "$points" -ge "$VIP_BLOCK_COST" ]] || { warn "Not enough points for max. Required minimum: ${VIP_BLOCK_COST}."; continue; }
        cost=0
        break
        ;;
      *) warn "Please enter 0, 4, 8, 12 or max." ;;
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
  [[ "$actual_cost" -lt 0 ]] && actual_cost=0
  record_purchase vip "$option" "$actual_cost"
  log "VIP purchased/extended: duration=${option}."
  printf '%s\n' "$refreshed_points"
}

manual_wedge_step() {
  local points="$1" spendable max_wedges count i now result success error_message estimated_cost

  log "Manual step 2/4 - Wedges"
  spendable="$points"
  max_wedges=$((spendable / WEDGE_COST))
  log "Current points: ${points}. Wedge cost: ${WEDGE_COST}. Manual mode does not apply the automated global reserve. Purchasable wedges: ${max_wedges}."

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
  local points="$1" pack pack_cost max_count chosen_pack chosen_count now response new_points error_message allowed_package=0 estimated_cost current_ratio
  valid_integer "$MIN_UPLOAD_GB" || fatal "MIN_UPLOAD_GB must be numeric: $MIN_UPLOAD_GB"

  log "Manual step 3/4 - Upload credit"
  if current_ratio="$(get_ratio "$MAM_UID")"; then
    log "Current ratio: ${current_ratio}. Configured automated threshold: ${UPLOAD_RATIO_THRESHOLD}. Manual mode does not block upload purchases by ratio."
  else
    warn "Could not read current ratio. Manual upload purchase remains available."
  fi
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
  log "Manual mode does not apply the automated global reserve. It only prevents spending more points than currently available."
  [[ "$DRY_RUN" -eq 1 ]] && log "DRY-RUN is enabled: no purchase will be sent to MAM."

  points="$(manual_vip_step "$points" | tail -n1)"
  log "Points after VIP step: ${points}"
  points="$(manual_upload_step "$points" | tail -n1)"
  log "Points after upload step: ${points}"
  points="$(manual_wedge_step "$points" | tail -n1)"
  log "Points after wedge step: ${points}"
  points="$(manual_donation_step "$points" | tail -n1)"
  log "Points after donation step: ${points}"
  log "Interactive manual mode completed. Final estimated/current points: ${points}"
}

run_main() {
  check_dependencies

  if [[ "$COMMAND" == "config" ]]; then
    case "$CONFIG_ACTION" in
      migrate) config_migrate ;;
      edit) config_edit ;;
      *) fatal "Unknown config action: ${CONFIG_ACTION}" ;;
    esac
    return 0
  fi

  auto_migrate_config_if_needed
  load_config

  exec 9>"$LOCK_FILE"
  flock -n 9 || fatal "Another run is already in progress: $LOCK_FILE"

  MAM_UID="$(ensure_session | tail -n1)"
  [[ "$COMMAND" == "check-session" ]] && return 0

  log "Fetching current points."
  valid_integer "$BONUS_RESERVE_POINTS" || fatal "BONUS_RESERVE_POINTS must be numeric: $BONUS_RESERVE_POINTS"

  POINTS="$(get_points "$MAM_UID")"
  log "Current points: ${POINTS}"
  [[ "$COMMAND" == "points" ]] && return 0

  if [[ "$COMMAND" == "manual" || "$COMMAND" == "interactive" ]]; then
    run_manual_mode "$POINTS"
  else
    POINTS="$(buy_vip_if_enabled "$POINTS" | tail -n1)"
    log "Automated balance after VIP step: ${POINTS}"
    POINTS="$(buy_upload_until_buffer "$POINTS" | tail -n1)"
    log "Automated balance after upload step: ${POINTS}"
    POINTS="$(buy_wedge_if_needed "$POINTS" | tail -n1)"
    log "Automated balance after wedge step: ${POINTS}"
    POINTS="$(donate_to_new_users_if_enabled "$POINTS" | tail -n1)"
    log "Automated balance after donation step: ${POINTS}"
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
