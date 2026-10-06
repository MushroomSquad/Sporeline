# shellcheck shell=bash
# Retry for network operations with exponential backoff.

# retry [-n attempts] [-d delay_sec] command...
retry() {
  local attempts="${HCI_RETRY_ATTEMPTS:-3}" delay="${HCI_RETRY_DELAY:-5}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n) attempts="$2"; shift 2 ;;
      -d) delay="$2"; shift 2 ;;
      --) shift; break ;;
      *) break ;;
    esac
  done
  local try=1 rc=0
  while true; do
    "$@" && return 0
    rc=$?
    if (( try >= attempts )); then
      log::error "Команда завершилась с кодом $rc после $attempts попыток: $(log::redact "$*")"
      return "$rc"
    fi
    log::warn "Попытка $try/$attempts не удалась (код $rc), повтор через ${delay}с"
    sleep "$delay"
    try=$((try + 1))
    delay=$((delay * 2))
  done
}
