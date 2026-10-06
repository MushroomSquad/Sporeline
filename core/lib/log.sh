# shellcheck shell=bash
# Логирование: уровни, сворачиваемые секции, маскирование секретов.

_HCI_SECRETS=()

log::_color() {
  if [[ -t 2 || -n "${GITLAB_CI:-}" || -n "${GITHUB_ACTIONS:-}" ]] && [[ -z "${NO_COLOR:-}" ]]; then
    printf '\033[%sm' "$1"
  fi
}

log::_print() {
  local color="$1" label="$2"
  shift 2
  printf '%s[%s]%s %s\n' "$(log::_color "$color")" "$label" "$(log::_color 0)" "$(log::redact "$*")" >&2
}

log::info() { log::_print '1;34' 'hci' "$@"; }
log::ok() { log::_print '1;32' 'ok' "$@"; }
log::warn() { log::_print '1;33' 'warn' "$@"; }
log::error() { log::_print '1;31' 'error' "$@"; }

log::debug() {
  [[ "${HCI_DEBUG:-false}" == "true" ]] || return 0
  log::_print '0;37' 'debug' "$@"
}

log::die() {
  log::error "$@"
  exit 1
}

# Регистрирует значение как секрет: оно не попадёт в вывод log::* и log::cmd.
log::mask() {
  local value="$1"
  [[ -n "$value" && ${#value} -ge 4 ]] || return 0
  _HCI_SECRETS+=("$value")
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    printf '::add-mask::%s\n' "$value"
  fi
}

log::redact() {
  local text="$*" secret
  for secret in "${_HCI_SECRETS[@]+"${_HCI_SECRETS[@]}"}"; do
    text="${text//"$secret"/***}"
  done
  printf '%s' "$text"
}

log::section_start() {
  local id="$1" title="$2"
  id="${id//[^a-zA-Z0-9_]/_}"
  if [[ -n "${GITLAB_CI:-}" ]]; then
    printf '\e[0Ksection_start:%s:%s[collapsed=false]\r\e[0K%s\n' "$(date +%s)" "$id" "$title" >&2
  elif [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    printf '::group::%s\n' "$title" >&2
  else
    printf '%s==> %s%s\n' "$(log::_color '1;36')" "$title" "$(log::_color 0)" >&2
  fi
}

log::section_end() {
  local id="$1"
  id="${id//[^a-zA-Z0-9_]/_}"
  if [[ -n "${GITLAB_CI:-}" ]]; then
    printf '\e[0Ksection_end:%s:%s\r\e[0K\n' "$(date +%s)" "$id" >&2
  elif [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    printf '::endgroup::\n' >&2
  fi
}

# Печатает команду (с замаскированными секретами) и выполняет её.
log::cmd() {
  local rendered
  rendered="$(printf '%q ' "$@")"
  printf '%s+ %s%s\n' "$(log::_color '0;36')" "$(log::redact "${rendered% }")" "$(log::_color 0)" >&2
  "$@"
}
