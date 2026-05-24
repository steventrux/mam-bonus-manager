#!/usr/bin/env bash

# Donation helper functions for mam-bonus-manager.

record_donation() {
  local uid="$1"
  local username="$2"
  local amount="$3"

  [[ "${DRY_RUN:-0}" -eq 0 ]] || return 0
  mkdir -p "$(dirname "$DONATION_STATE_FILE")"
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date '+%s')" "$(date '+%Y-%m-%d')" "$uid" "$username" "$amount" >> "$DONATION_STATE_FILE"
  chmod 600 "$DONATION_STATE_FILE" 2>/dev/null || true
}

donation_recently_sent() {
  local uid="$1"
  local username="$2"
  local now cutoff ts date_field uid_field username_field amount_field

  [[ -s "$DONATION_STATE_FILE" ]] || return 1
  valid_integer "$DONATION_COOLDOWN_DAYS" || fatal "DONATION_COOLDOWN_DAYS must be numeric: $DONATION_COOLDOWN_DAYS"

  # A cooldown of 0 means never donate again to the same user.
  if [[ "$DONATION_COOLDOWN_DAYS" -eq 0 ]]; then
    cutoff=0
  else
    now="$(date '+%s')"
    cutoff=$((now - DONATION_COOLDOWN_DAYS * 86400))
  fi

  while IFS=$'\t' read -r ts date_field uid_field username_field amount_field; do
    [[ "$ts" =~ ^[0-9]+$ ]] || continue
    if [[ "$uid_field" == "$uid" || "$username_field" == "$username" ]]; then
      [[ "$ts" -ge "$cutoff" ]] && return 0
    fi
  done < "$DONATION_STATE_FILE"

  return 1
}

get_total_donated_to_user() {
  local uid="$1"
  local username="$2"
  local ts date_field uid_field username_field amount_field total=0

  [[ -s "$DONATION_STATE_FILE" ]] || { printf '0\n'; return 0; }

  while IFS=$'\t' read -r ts date_field uid_field username_field amount_field; do
    [[ "$amount_field" =~ ^[0-9]+$ ]] || continue
    if [[ "$uid_field" == "$uid" || "$username_field" == "$username" ]]; then
      total=$((total + amount_field))
    fi
  done < "$DONATION_STATE_FILE"

  printf '%s\n' "$total"
}

donation_user_limit_allowed() {
  local uid="$1"
  local username="$2"
  local amount="$3"
  local max_per_user already_donated remaining

  max_per_user="${DONATION_MAX_POINTS_PER_USER:-1000}"
  valid_integer "$max_per_user" || fatal "DONATION_MAX_POINTS_PER_USER must be numeric: $max_per_user"

  if [[ "$max_per_user" -le 0 ]]; then
    return 0
  fi

  already_donated="$(get_total_donated_to_user "$uid" "$username")"
  remaining=$((max_per_user - already_donated))

  if [[ "$remaining" -le 0 ]]; then
    log "Donation skipped for ${username} (uid=${uid}): user limit reached (${already_donated}/${max_per_user})."
    return 1
  fi

  if [[ "$amount" -gt "$remaining" ]]; then
    log "Donation skipped for ${username} (uid=${uid}): amount ${amount} would exceed user limit (${already_donated}/${max_per_user}, remaining ${remaining})."
    return 1
  fi

  debug "Donation user limit OK for ${username} (uid=${uid}): already=${already_donated}, amount=${amount}, max=${max_per_user}."
  return 0
}


get_max_donated_uid() {
  local ts date_field uid_field username_field amount_field max_uid=0

  [[ -s "$DONATION_STATE_FILE" ]] || { printf '0\n'; return 0; }

  while IFS=$'\t' read -r ts date_field uid_field username_field amount_field; do
    [[ "$uid_field" =~ ^[0-9]+$ ]] || continue
    if [[ "$uid_field" -gt "$max_uid" ]]; then
      max_uid="$uid_field"
    fi
  done < "$DONATION_STATE_FILE"

  printf '%s\n' "$max_uid"
}

get_donation_discovery_start_uid() {
  [[ "${MAM_UID:-}" =~ ^[0-9]+$ ]] || fatal "MAM_UID is missing or invalid before donation discovery."
  printf '%s\n' "$MAM_UID"
}

uid_profile_is_valid() {
  local uid="$1"
  local response profile_uid username

  response="$(json_get "${BASE_URL}/jsonLoad.php?id=${uid}" || true)"
  [[ "$response" != "[]" ]] || return 1

  profile_uid="$(jq -r '.uid // empty' <<< "$response" 2>/dev/null || true)"
  username="$(jq -r '.username // empty' <<< "$response" 2>/dev/null || true)"

  [[ "$profile_uid" =~ ^[0-9]+$ && -n "$username" && "$username" != "null" ]]
}

find_latest_valid_uid() {
  local start_uid step delay low high mid guard=0 max_guard=30

  start_uid="$(get_donation_discovery_start_uid)"
  step="${DONATION_LATEST_UID_STEP:-1000}"
  delay="$DONATION_SCAN_DELAY_SECONDS"

  valid_integer "$start_uid" || fatal "Latest UID discovery start must be numeric: $start_uid"
  valid_integer "$step" || fatal "DONATION_LATEST_UID_STEP must be numeric: $step"
  valid_integer "$delay" || fatal "DONATION_SCAN_DELAY_SECONDS must be numeric: $delay"
  [[ "$step" -gt 0 ]] || fatal "DONATION_LATEST_UID_STEP must be greater than zero: $step"

  log "Latest UID discovery: probing from start=${start_uid}, step=${step}, delay=${delay}s."

  if uid_profile_is_valid "$start_uid"; then
    low="$start_uid"
    high=$((start_uid + step))

    while uid_profile_is_valid "$high"; do
      low="$high"
      high=$((high + step))
      guard=$((guard + 1))
      [[ "$guard" -le "$max_guard" ]] || fatal "Latest UID discovery exceeded guard while searching upper empty UID."
      [[ "$delay" -gt 0 ]] && sleep "$delay"
    done
  else
    high="$start_uid"
    low=$((start_uid - step))
    [[ "$low" -lt 1 ]] && low=1

    while ! uid_profile_is_valid "$low"; do
      high="$low"
      low=$((low - step))
      [[ "$low" -lt 1 ]] && low=1
      guard=$((guard + 1))
      [[ "$guard" -le "$max_guard" ]] || fatal "Latest UID discovery exceeded guard while searching lower valid UID."
      [[ "$low" -eq 1 ]] && break
      [[ "$delay" -gt 0 ]] && sleep "$delay"
    done
  fi

  log "Latest UID discovery interval: valid_low=${low}, empty_high=${high}."

  while (( high - low > 1 )); do
    mid=$(( (low + high) / 2 ))

    if uid_profile_is_valid "$mid"; then
      low="$mid"
      debug "Latest UID discovery: valid ${mid}."
    else
      high="$mid"
      debug "Latest UID discovery: empty ${mid}."
    fi

    [[ "$delay" -gt 0 ]] && sleep "$delay"
  done

  printf '%s\n' "$low"
}

get_new_users_by_latest_uid() {
  local start_uid lookback max_candidates delay scanned=0 found=0 uid response username profile_uid

  start_uid="$(find_latest_valid_uid)"
  lookback="$DONATION_SCAN_LOOKBACK"
  max_candidates="$DONATION_SCAN_MAX_CANDIDATES"
  delay="$DONATION_SCAN_DELAY_SECONDS"

  valid_integer "$lookback" || fatal "DONATION_SCAN_LOOKBACK must be numeric: $lookback"
  valid_integer "$max_candidates" || fatal "DONATION_SCAN_MAX_CANDIDATES must be numeric: $max_candidates"
  valid_integer "$delay" || fatal "DONATION_SCAN_DELAY_SECONDS must be numeric: $delay"

  log "Latest UID discovery result: latest_valid_uid=${start_uid}. Scanning backward lookback=${lookback}, max_candidates=${max_candidates}, delay=${delay}s."

  uid="$start_uid"
  while [[ "$scanned" -lt "$lookback" && "$uid" -gt 0 && "$found" -lt "$max_candidates" ]]; do
    response="$(json_get "${BASE_URL}/jsonLoad.php?id=${uid}" || true)"

    if [[ "$response" != "[]" ]]; then
      profile_uid="$(jq -r '.uid // empty' <<< "$response" 2>/dev/null || true)"
      username="$(jq -r '.username // empty' <<< "$response" 2>/dev/null || true)"

      if [[ "$profile_uid" =~ ^[0-9]+$ && -n "$username" && "$username" != "null" ]]; then
        printf '%s\t%s\n' "$profile_uid" "$username" 2>/dev/null || return 0
        found=$((found + 1))
      fi
    fi

    scanned=$((scanned + 1))
    uid=$((uid - 1))

    if [[ "$delay" -gt 0 && "$scanned" -lt "$lookback" && "$found" -lt "$max_candidates" ]]; then
      sleep "$delay"
    fi
  done
}

get_new_users() {
  get_new_users_by_latest_uid
}

human_size_to_bytes() {
  local value="$1"

  awk '
    BEGIN { IGNORECASE = 1 }
    {
      amount = $1 + 0
      unit = $2

      if (unit == "KiB") multiplier = 1024
      else if (unit == "MiB") multiplier = 1024 * 1024
      else if (unit == "GiB") multiplier = 1024 * 1024 * 1024
      else if (unit == "TiB") multiplier = 1024 * 1024 * 1024 * 1024
      else if (unit == "B") multiplier = 1
      else exit 1

      printf "%.0f\n", amount * multiplier
    }
  ' <<< "$value"
}

get_recipient_uploaded_bytes() {
  local uid="$1"
  local response uploaded_bytes uploaded_text converted

  response="$(json_get "${BASE_URL}/jsonLoad.php?id=${uid}")" || return 1

  uploaded_bytes="$(jq -r '.uploaded_bytes // empty' <<< "$response" 2>/dev/null || true)"
  if valid_integer "$uploaded_bytes"; then
    printf '%s\n' "$uploaded_bytes"
    return 0
  fi

  uploaded_text="$(jq -r '.uploaded // empty' <<< "$response" 2>/dev/null || true)"
  if [[ -n "$uploaded_text" && "$uploaded_text" != "null" ]]; then
    converted="$(human_size_to_bytes "$uploaded_text")" || return 1
    valid_integer "$converted" || return 1
    printf '%s\n' "$converted"
    return 0
  fi

  return 1
}

donation_recipient_upload_allowed() {
  local uid="$1"
  local username="$2"
  local threshold uploaded_bytes

  threshold="${DONATION_MAX_RECIPIENT_UPLOADED_BYTES:-53687091200}"
  valid_integer "$threshold" || fatal "DONATION_MAX_RECIPIENT_UPLOADED_BYTES must be numeric: $threshold"

  if [[ "$threshold" -le 0 ]]; then
    return 0
  fi

  uploaded_bytes="$(get_recipient_uploaded_bytes "$uid")" || {
    warn "Could not read recipient uploaded bytes for ${username} (uid=${uid}); skipping for safety."
    return 1
  }

  if [[ "$uploaded_bytes" -le "$threshold" ]]; then
    debug "Donation candidate accepted for ${username} (uid=${uid}): uploaded_bytes ${uploaded_bytes} <= ${threshold}."
    return 0
  fi

  log "Donation candidate skipped for ${username} (uid=${uid}): uploaded_bytes ${uploaded_bytes} > ${threshold}."
  return 1
}


get_donation_candidates() {
  local uid username

  while IFS=$'\t' read -r uid username; do
    [[ -n "$uid" && -n "$username" ]] || continue
    if donation_recently_sent "$uid" "$username"; then
      debug "Donation candidate skipped for ${username} (uid=${uid}): cooldown active."
      continue
    fi
    if ! donation_recipient_upload_allowed "$uid" "$username"; then
      continue
    fi
    printf '%s\t%s\n' "$uid" "$username" 2>/dev/null || return 0
  done < <(get_new_users)
}

count_donation_candidates() {
  get_donation_candidates | awk 'END { print NR + 0 }'
}

plan_donation() {
  local uid="$1"
  local username="$2"
  local amount="$3"

  valid_integer "$amount" || fatal "DONATION_AMOUNT must be numeric: $amount"
  [[ "$amount" -gt 0 ]] || fatal "DONATION_AMOUNT must be greater than zero: $amount"

  if donation_recently_sent "$uid" "$username"; then
    log "Donation skipped for ${username} (uid=${uid}): already donated within cooldown."
    return 1
  fi

  if ! donation_recipient_upload_allowed "$uid" "$username"; then
    return 1
  fi

  if ! donation_user_limit_allowed "$uid" "$username" "$amount"; then
    return 1
  fi

  log "Donation candidate: ${username} (uid=${uid}), amount=${amount}."
  return 0
}

send_donation() {
  local uid="$1"
  local username="$2"
  local amount="$3"
  local now response success error_message refreshed_points before after actual_cost

  valid_integer "$amount" || fatal "Donation amount must be numeric: $amount"
  [[ "$amount" -gt 0 ]] || fatal "Donation amount must be greater than zero: $amount"

  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    log "DRY-RUN: would donate ${amount} bonus point(s) to ${username} (uid=${uid})."
    return 0
  fi

  before="$(get_points "$MAM_UID")"
  now="$(date +%s%3N)"
  response="$(json_get "${BASE_URL}/json/bonusBuy.php?spendtype=gift&amount=${amount}&giftTo=${uid}&_=${now}")" || {
    warn "Donation to ${username} (uid=${uid}) failed: curl/API error."
    return 1
  }

  success="$(jq -r '.success // empty' <<< "$response" 2>/dev/null || true)"
  error_message="$(jq -r '.error // empty' <<< "$response" 2>/dev/null || true)"

  if [[ "$success" != "true" ]]; then
    warn "Donation to ${username} (uid=${uid}) was not confirmed. API error: ${error_message:-none}. Response: $response"
    return 1
  fi

  refreshed_points="$(get_points "$MAM_UID")"
  after="$refreshed_points"
  actual_cost=$((before - after))
  [[ "$actual_cost" -lt 0 ]] && actual_cost="$amount"
  [[ "$actual_cost" -eq 0 ]] && actual_cost="$amount"

  record_donation "$uid" "$username" "$actual_cost"
  record_purchase donation "$username" "$actual_cost"
  log "Donation sent to ${username} (uid=${uid}): ${actual_cost} bonus point(s). Points after donation: ${after}."
  return 0
}

donate_to_new_users_if_enabled() {
  local points="$1"
  local uid username planned=0 spendable before after current_ratio

  truthy "${DONATIONS:-0}" || { printf '%s\n' "$points"; return 0; }

  valid_integer "$DONATION_AMOUNT" || fatal "DONATION_AMOUNT must be numeric: $DONATION_AMOUNT"
  valid_integer "$DONATION_MAX_USERS_PER_RUN" || fatal "DONATION_MAX_USERS_PER_RUN must be numeric: $DONATION_MAX_USERS_PER_RUN"
  valid_number "$UPLOAD_RATIO_THRESHOLD" || fatal "UPLOAD_RATIO_THRESHOLD must be numeric: $UPLOAD_RATIO_THRESHOLD"

  if ! number_le_zero "$UPLOAD_RATIO_THRESHOLD"; then
    current_ratio="$(get_ratio "$MAM_UID")" || {
      warn "Could not read current ratio; skipping automated donations for safety."
      printf '%s\n' "$points"
      return 0
    }

    if number_lt "$current_ratio" "$UPLOAD_RATIO_THRESHOLD"; then
      log "Donation step skipped: current ratio ${current_ratio} is below UPLOAD_RATIO_THRESHOLD ${UPLOAD_RATIO_THRESHOLD}; preserving points for upload credit."
      printf '%s\n' "$points"
      return 0
    fi
  fi

  if [[ "$points" -le "$BONUS_RESERVE_POINTS" ]]; then
    log "Donation step skipped: points ${points} are not above BONUS_RESERVE_POINTS ${BONUS_RESERVE_POINTS}."
    printf '%s\n' "$points"
    return 0
  fi

  spendable=$((points - BONUS_RESERVE_POINTS))
  log "Donation step enabled. Spendable points above global reserve: ${spendable}."

  while IFS=$'\t' read -r uid username; do
    [[ -n "$uid" && -n "$username" ]] || continue
    [[ "$planned" -lt "$DONATION_MAX_USERS_PER_RUN" ]] || break
    [[ "$spendable" -ge "$DONATION_AMOUNT" ]] || break

    if plan_donation "$uid" "$username" "$DONATION_AMOUNT"; then
      before="$points"
      if send_donation "$uid" "$username" "$DONATION_AMOUNT"; then
        planned=$((planned + 1))
        if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
          points=$((points - DONATION_AMOUNT))
        else
          points="$(get_points "$MAM_UID")"
        fi
        after="$points"
        spendable=$((points - BONUS_RESERVE_POINTS))
        [[ "$spendable" -lt 0 ]] && spendable=0
        debug "Donation balance update: before=${before}, after=${after}, spendable=${spendable}."
      fi
    fi
  done < <(get_donation_candidates)

  log "Donation step completed. Donations sent/planned: ${planned}. Estimated/current points: ${points}."
  printf '%s\n' "$points"
}

manual_donation_step() {
  local points="$1"
  local amount max_budget max_affordable max_total planned=0 spendable uid username before after
  local candidates=() candidate candidate_count

  log "Manual step 4/4 - Donations to new users"

  amount="$(ask_integer "Bonus points to donate to each new user? [0 to skip]: " "$points")"
  [[ "$amount" -eq 0 ]] && { log "Donations skipped."; printf '%s\n' "$points"; return 0; }

  max_affordable=$((points / amount * amount))
  log "Maximum affordable total with ${amount} point(s) per user: ${max_affordable}."
  max_budget="$(ask_integer "Maximum total points to spend on donations? [0-${max_affordable}, Enter=0]: " "$max_affordable")"
  [[ "$max_budget" -eq 0 ]] && { log "Donations skipped."; printf '%s\n' "$points"; return 0; }

  max_total=$((max_budget / amount * amount))
  if [[ "$max_total" -eq 0 ]]; then
    log "Donation budget is lower than the amount per user. Donations skipped."
    printf '%s\n' "$points"
    return 0
  fi

  log "Manual donations selected: ${amount} point(s) per user, maximum total ${max_total}."
  log "Discovering donation candidates."

  mapfile -t candidates < <(get_donation_candidates)
  candidate_count="${#candidates[@]}"
  log "New-user donation candidates after cooldown and upload filters: ${candidate_count}."

  if [[ "$candidate_count" -eq 0 ]]; then
    log "No donation candidates available."
    printf '%s\n' "$points"
    return 0
  fi

  spendable="$max_total"

  for candidate in "${candidates[@]}"; do
    IFS=$'\t' read -r uid username <<< "$candidate"
    [[ -n "$uid" && -n "$username" ]] || continue
    [[ "$spendable" -ge "$amount" ]] || break

    if plan_donation "$uid" "$username" "$amount"; then
      before="$points"
      if send_donation "$uid" "$username" "$amount"; then
        planned=$((planned + 1))
        if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
          points=$((points - amount))
        else
          points="$(get_points "$MAM_UID")"
        fi
        after="$points"
        spendable=$((spendable - (before - after)))
        [[ "$spendable" -lt 0 ]] && spendable=0
        debug "Manual donation balance update: before=${before}, after=${after}, remaining budget=${spendable}."
      fi
    fi
  done

  log "Manual donation step completed. Donations sent/planned: ${planned}. Estimated/current points: ${points}."
  printf '%s\n' "$points"
}
