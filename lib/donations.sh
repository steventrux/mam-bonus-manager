#!/usr/bin/env bash

# Donation helper functions for mam-bonus-manager.
# This module is intentionally not sourced by the main script yet.
# It provides candidate discovery, local history and dry-run donation planning.

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

get_new_users() {
  local response
  response="$(json_get "${BASE_URL}/newUsers.php")" || return 1

  printf '%s\n' "$response" \
    | tr '\n' ' ' \
    | grep -oE 'href="/u/[0-9]+"[^>]*>[^<]+' \
    | sed -E 's/.*href="\/u\/([0-9]+)"[^>]*>([^<]+).*/\1\t\2/' \
    | awk -F '\t' 'NF >= 2 && !seen[$1]++ { print $1 "\t" $2 }'
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

  log "Donation candidate: ${username} (uid=${uid}), amount=${amount}."
  return 0
}

send_donation() {
  local uid="$1"
  local username="$2"
  local amount="$3"

  # Real donation send will be added only after dry-run validation.
  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    log "DRY-RUN: would donate ${amount} bonus point(s) to ${username} (uid=${uid})."
    return 0
  fi

  warn "Real donation sending is not implemented yet. Skipping ${username} (uid=${uid})."
  return 1
}
