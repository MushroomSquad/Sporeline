# shellcheck shell=bash
# Загрузка конфигурации.
#
# Приоритет (от высшего к низшему):
#   1. аргументы командной строки (--key=value)
#   2. переменные окружения (в т.ч. заданные CI)
#   3. файл .ci.yaml проекта
#   4. runtimes/<runtime>/defaults.env
#   5. core/defaults.env
#
# Ключи .ci.yaml превращаются в переменные HCI_<ПУТЬ>: build.cmd -> HCI_BUILD_CMD.
# Секция env: экспортируется как есть (FOO: bar -> FOO=bar).

declare -gA _HCI_LOCKED=()

HCI_DETECT_ORDER=(maven gradle dotnet go rust python bun nodejs php static)

# Пустые значения не блокируют: пустой input CI означает «не задано».
config::_lock_env() {
  local name
  while IFS= read -r name; do
    if [[ -n "${!name}" ]]; then
      _HCI_LOCKED["$name"]=1
    else
      unset "$name"
    fi
  done < <(compgen -e | grep '^HCI_' || true)
}

config::is_locked() { [[ -n "${_HCI_LOCKED[$1]:-}" ]]; }

config::set() {
  local name="$1" value="$2"
  printf -v "$name" '%s' "$value"
  export "${name?}"
  _HCI_LOCKED["$name"]=1
}

# Применяет --key=value. Возвращает остаток аргументов в HCI_ARGS.
config::parse_args() {
  HCI_ARGS=()
  local arg key value
  while [[ $# -gt 0 ]]; do
    arg="$1"
    shift
    case "$arg" in
      --) HCI_ARGS+=("$@"); break ;;
      --*=*)
        key="${arg%%=*}"
        value="${arg#*=}"
        key="${key#--}"
        key="${key^^}"
        key="${key//-/_}"
        [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || log::die "Некорректный аргумент: $arg"
        config::set "HCI_$key" "$value"
        ;;
      *) HCI_ARGS+=("$arg") ;;
    esac
  done
}

config::_flatten_jq() {
  cat <<'JQ'
def emit($p; $v): {k: ($p | map(tostring) | join("_") | ascii_upcase | gsub("[^A-Z0-9_]"; "_")), v: $v};
def flat($p):
  if ($p == ["env"]) and type == "object" then
    to_entries[] | {env: true, k: .key, v: (.value | tostring)}
  elif type == "object" and ($p | length) > 1 and ($p[-1] | IN("labels", "build_args", "env")) then
    emit($p; (to_entries | map("\(.key)=\(.value | tostring)") | join("\n")))
  elif type == "object" then
    to_entries[] as $e | ($e.value | flat($p + [$e.key]))
  elif type == "array" then
    emit($p; (map(if type == "string" then . else tojson end) | join("\n")))
  elif type == "null" then empty
  elif type == "string" then emit($p; .)
  else emit($p; tostring) end;
flat([]) | [(if .env then "E" else "H" end), (if .env then .k else "HCI_" + .k end), (.v | @base64)] | @tsv
JQ
}

config::find_file() {
  local candidate
  if [[ -n "${HCI_CONFIG_FILE:-}" ]]; then
    [[ -f "$HCI_CONFIG_FILE" ]] || log::die "Файл конфигурации не найден: $HCI_CONFIG_FILE"
    printf '%s' "$HCI_CONFIG_FILE"
    return 0
  fi
  for candidate in .ci.yaml .ci.yml; do
    if [[ -f "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

config::load_file() {
  local file kind name b64 value
  file="$(config::find_file)" || return 0
  log::debug "Конфигурация из $file"
  while IFS=$'\t' read -r kind name b64; do
    value="$(printf '%s' "$b64" | base64 -d)"
    if [[ "$kind" == "E" ]]; then
      [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || log::die "Некорректное имя переменной в env: $name"
      if [[ -z "${!name+x}" ]]; then
        printf -v "$name" '%s' "$value"
        export "${name?}"
      fi
    elif ! config::is_locked "$name"; then
      config::set "$name" "$value"
    fi
  done < <(ci::yaml_to_json "$file" | jq -r "$(config::_flatten_jq)")
}

# Загружает файл KEY=VALUE (синтаксис bash, значения могут ссылаться на ${VAR:-}).
# Существующие незаблокированные значения перезаписываются: runtime-defaults важнее core-defaults.
config::load_defaults() {
  local file="$1" line name rhs
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
      name="${BASH_REMATCH[1]}"
      rhs="${BASH_REMATCH[2]}"
      config::is_locked "$name" && continue
      [[ "$name" != HCI_* && -n "${!name+x}" ]] && continue
      eval "export $name=$rhs"
    else
      log::die "Некорректная строка в $file: $line"
    fi
  done < "$file"
}

config::detect_runtime() {
  local rt
  for rt in "${HCI_DETECT_ORDER[@]}"; do
    [[ -f "$HCI_HOME/runtimes/$rt/detect.sh" ]] || continue
    if (
      # shellcheck source=/dev/null
      source "$HCI_HOME/runtimes/$rt/detect.sh"
      rt::detect
    ); then
      printf '%s' "$rt"
      return 0
    fi
  done
  printf 'none'
}

config::mask_secrets() {
  local name
  while IFS= read -r name; do
    log::mask "${!name:-}"
  done < <(compgen -v | grep -E '(PASSWORD|TOKEN|SECRET|_AUTH|API_KEY|SONAR_KEY|SSH_KEY)$' || true)
}

# Профили рантайма (HCI_PROFILE=quarkus,...) — runtimes/<runtime>/profiles/<name>.env поверх defaults.env.
config::load_profiles() {
  local profiles=() p file
  ci::split profiles "${HCI_PROFILE:-}"
  for p in "${profiles[@]+"${profiles[@]}"}"; do
    [[ -n "$p" && "$p" != "none" ]] || continue
    file="$HCI_HOME/runtimes/$HCI_RUNTIME/profiles/$p.env"
    [[ -f "$file" ]] || log::die "Профиль '$p' не найден для рантайма $HCI_RUNTIME"
    config::load_defaults "$file"
  done
}

config::load() {
  config::load_file

  if [[ -z "${HCI_RUNTIME:-}" ]]; then
    config::set HCI_RUNTIME "$(config::detect_runtime)"
  fi
  if [[ "$HCI_RUNTIME" != "none" && ! -d "$HCI_HOME/runtimes/$HCI_RUNTIME" ]]; then
    local available=("$HCI_HOME"/runtimes/*/)
    available=("${available[@]%/}")
    log::die "Неизвестный рантайм '$HCI_RUNTIME'. Доступны: ${available[*]##*/}"
  fi

  config::load_defaults "$HCI_HOME/defaults.env"
  if [[ "$HCI_RUNTIME" != "none" ]]; then
    config::load_defaults "$HCI_HOME/runtimes/$HCI_RUNTIME/defaults.env"
    config::load_profiles
  fi
  config::mask_secrets
}

# Печатает итоговую конфигурацию HCI_* с замаскированными секретами.
config::dump() {
  local name
  while IFS= read -r name; do
    printf '%s=%s\n' "$name" "$(log::redact "${!name}")"
  done < <(compgen -e | grep '^HCI_' | sort)
}
