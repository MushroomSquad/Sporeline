# shellcheck shell=bash
# Общие утилиты.

readonly HCI_SKIP_CODE=86

ci::is_true() {
  case "${1,,}" in
    1 | true | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

# ci::split ИМЯ_МАССИВА СТРОКА — делит по переводам строк и запятым, обрезает пробелы.
ci::split() {
  local -n _split_out="$1"
  local _raw="${2:-}" _item
  _split_out=()
  _raw="${_raw//,/$'\n'}"
  while IFS= read -r _item; do
    _item="${_item#"${_item%%[![:space:]]*}"}"
    _item="${_item%"${_item##*[![:space:]]}"}"
    [[ -n "$_item" ]] && _split_out+=("$_item")
  done <<< "$_raw"
  return 0
}

# ci::split_lines ИМЯ_МАССИВА СТРОКА — делит только по переводам строк (для KEY=VALUE).
ci::split_lines() {
  local -n _lines_out="$1"
  local _raw="${2:-}" _item
  _lines_out=()
  while IFS= read -r _item; do
    _item="${_item#"${_item%%[![:space:]]*}"}"
    [[ -n "$_item" ]] && _lines_out+=("$_item")
  done <<< "$_raw"
  return 0
}

# ci::words ИМЯ_МАССИВА СТРОКА — делит по пробелам (для дополнительных аргументов).
ci::words() {
  local -n _words_out="$1"
  _words_out=()
  [[ -n "${2:-}" ]] || return 0
  read -r -a _words_out <<< "$2"
}

ci::require() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || log::die "Не найдена утилита '$cmd'. Используйте образ с ней или задайте другой образ для джоба."
  done
}

ci::has() { command -v "$1" >/dev/null 2>&1; }

# Пропуск шага: печатает причину и завершает шаг с кодом пропуска.
ci::skip() {
  log::info "Шаг пропущен: $*"
  exit "$HCI_SKIP_CODE"
}

ci::slug() {
  local s="${1,,}"
  s="${s//[^a-z0-9]/-}"
  while [[ "$s" == *--* ]]; do s="${s//--/-}"; done
  s="${s#-}"
  printf '%s' "${s%-}"
}

# Подстановка ${VAR} в строке из доверенных файлов (meta.yaml, defaults.env).
ci::expand() {
  local __s="$1"
  __s="${__s//\\/\\\\}"
  __s="${__s//\"/\\\"}"
  __s="${__s//\`/\\\`}"
  eval "printf '%s' \"$__s\""
}

ci::yaml_to_json() {
  local file="$1"
  if ci::has yq && yq --version 2>&1 | grep -qi mikefarah; then
    yq -o=json '.' "$file"
  elif ci::has python3 && python3 -c 'import yaml' 2>/dev/null; then
    python3 -c 'import json, sys, yaml; json.dump(yaml.safe_load(open(sys.argv[1])) or {}, sys.stdout)' "$file"
  else
    log::die "Для чтения $file нужен yq (mikefarah) или python3 с PyYAML"
  fi
}

ci::meta_file() {
  printf '%s/runtimes/%s/meta.yaml' "$HCI_HOME" "${1:-$HCI_RUNTIME}"
}

# ci::meta JQ_ВЫРАЖЕНИЕ [РАНТАЙМ] — читает поле meta.yaml рантайма.
ci::meta() {
  local expr="$1" file
  file="$(ci::meta_file "${2:-}")"
  [[ -f "$file" ]] || return 1
  ci::yaml_to_json "$file" | jq -r "$expr // empty"
}

# Образ рантайма из meta.yaml: ci::meta_image build|runtime|sonar|svace [версия]
ci::meta_image() {
  local kind="$1" version="${2:-${HCI_RUNTIME_VERSION:-}}" raw
  [[ -n "$version" ]] || version="$(ci::meta '.default_version')"
  raw="$(ci::meta ".versions[] | select(.id == \"$version\") | .$kind")"
  [[ -n "$raw" ]] || raw="$(ci::meta ".images.$kind")"
  [[ -n "$raw" && "$raw" != "build" ]] || return 1
  ci::expand "$raw"
}

ci::xml_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  s="${s//\'/&apos;}"
  printf '%s' "$s"
}

# Первый существующий файл из списка glob-шаблонов (или код 1).
ci::first_file() {
  local p f
  shopt -s nullglob globstar
  for p in "$@"; do
    for f in $p; do
      [[ -f "$f" ]] && { shopt -u nullglob globstar; printf '%s' "$f"; return 0; }
    done
  done
  shopt -u nullglob globstar
  return 1
}

# Все существующие файлы по glob-шаблонам через запятую.
ci::glob_join() {
  local p f out=()
  shopt -s nullglob globstar
  for p in "$@"; do
    for f in $p; do [[ -e "$f" ]] && out+=("$f"); done
  done
  shopt -u nullglob globstar
  local IFS=,
  printf '%s' "${out[*]}"
}

ci::pkg_json() {
  local expr="$1" file="${2:-package.json}"
  [[ -f "$file" ]] || return 1
  jq -r "$expr // empty" "$file"
}

ci::json_escape() {
  jq -Rn --arg s "$1" '$s'
}
