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

Uso:
  ./mam-bonus-manager.sh [opzioni] [comando]

Comandi:
  run             Esegue il ciclo: sessione, wedge, VIP, upload bonus. Default.
  check-session   Verifica/crea solo la sessione MAM.
  points          Mostra solo i punti seedbonus correnti.
  help            Mostra questo aiuto.

Opzioni:
  --config FILE   Configurazione da usare. Default: ${CONFIG_FILE}
  --dry-run       Non acquista nulla: stampa solo cosa farebbe.
  --version       Mostra la versione.

Esempi:
  ./mam-bonus-manager.sh --dry-run
  MAM_CONFIG=./config.env ./mam-bonus-manager.sh run
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config) CONFIG_FILE="${2:-}"; [[ -n "$CONFIG_FILE" ]] || fatal "--config richiede un file"; shift 2 ;;
      --dry-run) DRY_RUN=1; shift ;;
      --version) echo "$VERSION"; exit 0 ;;
      -h|--help|help) COMMAND="help"; shift ;;
      run|check-session|points) COMMAND="$1"; shift ;;
      *) fatal "Argomento sconosciuto: $1" ;;
    esac
  done
}

load_config() {
  [[ -r "$CONFIG_FILE" ]] || fatal "Config non leggibile: $CONFIG_FILE. Copia config/config.env.example e inserisci MAM_ID."
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"

  : "${MAM_ID:?MAM_ID mancante in $CONFIG_FILE}"
  : "${WORKDIR:=/opt/MAM}"
  : "${BUFFER:=55000}"
  : "${VIP:=0}"
  : "${WEDGE_HOURS:=4}"
  : "${WEDGE_COST:=50000}"
  : "${WEDGE_RESERVE_AFTER:=5000}"
  : "${CURL_TIMEOUT:=30}"
  : "${CURL_RETRIES:=3}"
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
  [[ ${#missing[@]} -eq 0 ]] || fatal "Dipendenze mancanti: ${missing[*]}"
}

json_get() {
  local url="$1"
  curl -fsS --retry "$CURL_RETRIES" --retry-delay 2 --connect-timeout 10 --max-time "$CURL_TIMEOUT" \
    -b "$COOKIE_FILE" -c "$COOKIE_FILE" "$url"
}

json_get_with_mamid() {
  local url="$1"
  curl -fsS --retry "$CURL_RETRIES" --retry-delay 2 --connect-timeout 10 --max-time "$CURL_TIMEOUT" \
    -b "mam_id=${MAM_ID}" -c "$COOKIE_FILE" "$url"
}

valid_number() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

int_part() {
  printf '%s\n' "$1" | sed -E 's/\..*$//'
}

get_uid_from_summary() {
  local response uid
  response="$(json_get "${BASE_URL}/jsonLoad.php?snatch_summary")" || return 1
  printf '%s' "$response" > "$JSON_FILE"
  uid="$(jq -r '.uid // empty' < "$JSON_FILE" 2>/dev/null || true)"
  [[ -n "$uid" && "$uid" != "null" ]] || return 1
  printf '%s\n' "$uid"
}

create_session() {
  local response uid
  log "Sessione non valida: provo a crearne una nuova con MAM_ID."
  response="$(json_get_with_mamid "${BASE_URL}/jsonLoad.php?snatch_summary")" || return 1
  printf '%s' "$response" > "$JSON_FILE"
  uid="$(jq -r '.uid // empty' < "$JSON_FILE" 2>/dev/null || true)"
  [[ -n "$uid" && "$uid" != "null" ]] || return 1
  chmod 600 "$COOKIE_FILE" 2>/dev/null || true
  printf '%s\n' "$uid"
}

ensure_session() {
  local uid
  log "Verifico cookie esistente."
  if uid="$(get_uid_from_summary)"; then
    log "Sessione esistente valida. UID: ${uid}"
    printf '%s\n' "$uid"
    return 0
  fi

  uid="$(create_session)" || fatal "Impossibile creare una nuova sessione MAM. Controlla MAM_ID."
  log "Nuova sessione creata. UID: ${uid}"
  printf '%s\n' "$uid"
}

get_points() {
  local uid="$1" response points
  response="$(json_get "${BASE_URL}/jsonLoad.php?id=${uid}")" || fatal "Impossibile leggere i seedbonus."
  points="$(jq -r '.seedbonus // empty' <<< "$response" 2>/dev/null || true)"
  valid_number "$points" || fatal "Seedbonus non valido nella risposta JSON: ${points:-vuoto}"
  int_part "$points"
}

buy_wedge_if_needed() {
  local points="$1" now mins min_points result success

  [[ "$WEDGE_HOURS" -gt 0 ]] || { printf '%s\n' "$points"; return 0; }

  mins=$((WEDGE_HOURS * 60 - 10))
  [[ "$mins" -lt 1 ]] && mins=1

  if find "$WEDGE_STATE_FILE" -mmin "-${mins}" 2>/dev/null | grep -q .; then
    log "Wedge già acquistato di recente: salto."
    printf '%s\n' "$points"
    return 0
  fi

  min_points=$((WEDGE_COST + WEDGE_RESERVE_AFTER))
  if [[ "$points" -lt "$min_points" ]]; then
    log "Wedge da acquistare, ma punti insufficienti: ${points}. Minimo richiesto: ${min_points}."
    printf '%s\n' "$points"
    return 0
  fi

  log "Wedge da acquistare. Punti attuali: ${points}."
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: comprerei un wedge e aggiornerei ${WEDGE_STATE_FILE}."
    printf '%s\n' "$points"
    return 0
  fi

  now="$(date +%s%3N)"
  result="$(json_get "${BASE_URL}/json/bonusBuy.php/?spendtype=wedges&source=points&_=${now}")" || fatal "Acquisto wedge fallito: errore curl/API."
  success="$(jq -r '.success // empty' <<< "$result" 2>/dev/null || true)"
  [[ "$success" == "true" ]] || warn "La risposta wedge non indica success=true: $result"
  touch "$WEDGE_STATE_FILE"
  log "Wedge acquistato."
  printf '%s\n' "$(get_points "$MAM_UID")"
}

buy_vip_if_enabled() {
  local now result success
  [[ "$VIP" == "1" || "$VIP" == "true" || "$VIP" == "yes" ]] || return 0

  log "VIP abilitato: provo a massimizzare la durata."
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: comprerei VIP duration=max."
    return 0
  fi

  now="$(date +%s%3N)"
  result="$(json_get "${BASE_URL}/json/bonusBuy.php/?spendtype=VIP&duration=max&_=${now}")" || { warn "Acquisto VIP fallito: errore curl/API."; return 0; }
  success="$(jq -r '.success // empty' <<< "$result" 2>/dev/null || true)"
  [[ "$success" == "true" ]] && log "VIP acquistato/esteso." || warn "Acquisto VIP non confermato: $result"
}

buy_upload_until_buffer() {
  local points="$1" pack required now response new_points
  for pack in $UPLOAD_PACKS; do
    [[ "$pack" =~ ^[0-9]+$ ]] || fatal "UPLOAD_PACKS contiene un valore non numerico: $pack"
    required=$((pack * 500 + BUFFER))
    log "Controllo pacchetto upload ${pack}GB. Soglia acquisto: > ${required} punti."

    while [[ "$points" -gt "$required" ]]; do
      log "${points} > ${required}: acquisto ${pack}GB di upload."
      if [[ "$DRY_RUN" -eq 1 ]]; then
        log "DRY-RUN: comprerei ${pack}GB. Stimo decremento di $((pack * 500)) punti."
        points=$((points - pack * 500))
        continue
      fi

      now="$(date +%s%3N)"
      response="$(json_get "${BASE_URL}/json/bonusBuy.php/?spendtype=upload&amount=${pack}&_=${now}")" || fatal "Acquisto upload ${pack}GB fallito: errore curl/API."
      new_points="$(jq -r '.seedbonus // empty' <<< "$response" 2>/dev/null || true)"
      valid_number "$new_points" || fatal "Acquisto upload non verificabile. Risposta: $response"
      new_points="$(int_part "$new_points")"

      if [[ "$new_points" -lt "$points" ]]; then
        points="$new_points"
        log "Acquisto completato. Punti residui: ${points}."
      else
        fatal "I punti non sono diminuiti dopo l'acquisto. Prima=${points}, Dopo=${new_points}."
      fi
    done
  done
  printf '%s\n' "$points"
}

run_main() {
  check_dependencies
  load_config

  exec 9>"$LOCK_FILE"
  flock -n 9 || fatal "Un'altra esecuzione è già in corso: $LOCK_FILE"

  MAM_UID="$(ensure_session | tail -n1)"
  [[ "$COMMAND" == "check-session" ]] && return 0

  log "Raccolgo punti correnti."
  POINTS="$(get_points "$MAM_UID")"
  log "Punti correnti: ${POINTS}"
  [[ "$COMMAND" == "points" ]] && return 0

  POINTS="$(buy_wedge_if_needed "$POINTS" | tail -n1)"
  buy_vip_if_enabled
  POINTS="$(buy_upload_until_buffer "$POINTS" | tail -n1)"
  log "Fine. Punti finali stimati/attuali: ${POINTS}"
}

parse_args "$@"
if [[ "$COMMAND" == "help" ]]; then
  usage
  exit 0
fi
run_main
