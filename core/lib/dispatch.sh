# shellcheck shell=bash
# Диспетчер шагов: ci <шаг> [--ключ=значение ...]

declare -gA HCI_STEP_KIND=(
  [build]=runtime [test]=runtime [lint]=runtime [publish]=runtime
  [image:build]=common [image:scan]=common [image:publish]=common [sbom]=common
  [deps:scan]=common [sonar]=common [svace]=common [appscreener]=common [kcs]=common
  [helm:lint]=common [helm:publish]=common
  [cd:bump]=common [cd:notify]=common
)

declare -gA HCI_STEP_FILE=(
  [image:build]=image-build [image:scan]=image-scan [image:publish]=image-publish [sbom]=sbom
  [deps:scan]=deps-scan [sonar]=sonar [svace]=svace [appscreener]=appscreener [kcs]=kcs
  [helm:lint]=helm [helm:publish]=helm
  [cd:bump]=cd-bump [cd:notify]=cd-notify
)

# Шаги, падение которых при HCI_STRICT=false не валит пайплайн.
HCI_SOFT_STEPS=" test lint image:scan deps:scan sonar svace appscreener kcs "
# Шаги, перед которыми настраивается окружение рантайма (реестры, кэши, toolchain).
HCI_SETUP_STEPS=" build test lint publish sonar svace "

dispatch::usage() {
  cat <<'EOF'
Использование: ci <команда> [--ключ=значение ...]

Шаги сборки:
  build            сборка (и упаковка библиотеки при service_type=library)
  test             модульные тесты с покрытием
  lint             линтеры
  publish          публикация библиотеки в реестр пакетов
  image:build      сборка образа (режимы base | dockerfile | s2i | cekit)
  image:scan       анализ образа (Trivy) и SBOM
  image:publish    публикация, подпись и аттестация образа
  sbom             SBOM образа
  deps:scan        анализ зависимостей (Trivy fs)
  sonar            SonarQube
  svace            Svace
  appscreener      Solar appScreener
  kcs              Kaspersky Container Security
  helm:lint        проверка Helm-чарта
  helm:publish     публикация Helm-чарта
  cd:bump          бамп образа в GitOps-манифесте (git commit+push)
  cd:notify        webhook-триггер GitOps-контроллера (ArgoCD/Flux)

Служебные команды:
  config              итоговая конфигурация (секреты скрыты)
  detect              определить рантайм и инструменты
  images              образы сборки и запуска для текущего рантайма
  manifest:validate   проверить манифест артефактов
  run -- <команда>    выполнить команду в окружении рантайма
  version             версия ядра

Любой ключ конфигурации можно передать аргументом: --runtime-version=21 -> HCI_RUNTIME_VERSION=21.
EOF
}

dispatch::load_runtime() {
  [[ "${HCI_RUNTIME:-none}" != "none" ]] || return 0
  local lib="$HCI_HOME/runtimes/$HCI_RUNTIME/lib.sh"
  # shellcheck source=/dev/null
  [[ -f "$lib" ]] && source "$lib"
  return 0
}

dispatch::setup_runtime() {
  dispatch::load_runtime
  if declare -F rt::setup >/dev/null; then
    rt::setup
  fi
}

dispatch::_run() {
  local step="$1" kind="$2" cmd_var="$3" file fn

  trap 'log::error "Ошибка (код $?) в ${BASH_SOURCE[0]##*/}:${LINENO}: ${BASH_COMMAND}"' ERR

  if [[ "$HCI_SETUP_STEPS" == *" $step "* ]]; then
    dispatch::setup_runtime
  else
    dispatch::load_runtime
  fi

  hooks::run "$step" pre

  if [[ -n "${!cmd_var:-}" ]]; then
    log::info "Пользовательская команда из $cmd_var"
    eval "${!cmd_var}"
  elif [[ "$kind" == "runtime" ]]; then
    [[ "${HCI_RUNTIME:-none}" != "none" ]] || log::die "Рантайм не определён. Задайте HCI_RUNTIME или runtime: в .ci.yaml"
    file="$HCI_HOME/runtimes/$HCI_RUNTIME/$step.sh"
    [[ -f "$file" ]] || ci::skip "рантайм $HCI_RUNTIME не поддерживает шаг $step"
    # shellcheck source=/dev/null
    source "$file"
    "rt::$step"
    if [[ "$step" == "build" && "$HCI_SERVICE_TYPE" == "library" && -f "$HCI_HOME/runtimes/$HCI_RUNTIME/package.sh" ]]; then
      # shellcheck source=/dev/null
      source "$HCI_HOME/runtimes/$HCI_RUNTIME/package.sh"
      rt::package
    fi
  else
    file="$HCI_HOME/steps/${HCI_STEP_FILE[$step]}.sh"
    fn="step::${step//[:-]/_}"
    # shellcheck source=/dev/null
    source "$file"
    "$fn"
  fi

  hooks::run "$step" post
}

dispatch::step() {
  local step="$1" kind up rc strict
  kind="${HCI_STEP_KIND[$step]:-}"
  [[ -n "$kind" ]] || { dispatch::usage >&2; log::die "Неизвестная команда: $step"; }

  case "$HCI_SERVICE_TYPE" in
    image | library) ;;
    *) log::die "HCI_SERVICE_TYPE должен быть image или library, получено: $HCI_SERVICE_TYPE" ;;
  esac

  up="${step^^}"
  up="${up//[:-]/_}"
  local enabled_var="HCI_${up}_ENABLED" strict_var="HCI_${up}_STRICT"
  if [[ -n "${!enabled_var:-}" ]] && ! ci::is_true "${!enabled_var}"; then
    log::info "Шаг $step отключён ($enabled_var=${!enabled_var})"
    return 0
  fi

  log::section_start "hci_$up" "ci $step (runtime=${HCI_RUNTIME} version=${HCI_RUNTIME_VERSION:-auto} type=${HCI_SERVICE_TYPE})"
  set +e
  (
    set -Eeuo pipefail
    dispatch::_run "$step" "$kind" "HCI_${up}_CMD"
  )
  rc=$?
  set -e
  log::section_end "hci_$up"

  if [[ $rc -eq 0 ]]; then
    log::ok "Шаг $step выполнен"
    return 0
  fi
  if [[ $rc -eq $HCI_SKIP_CODE ]]; then
    return 0
  fi
  if [[ "$HCI_SOFT_STEPS" == *" $step "* ]]; then
    strict="${!strict_var:-$HCI_STRICT}"
    if ! ci::is_true "$strict"; then
      log::warn "Шаг $step завершился с ошибкой (код $rc), но строгий режим выключен"
      return "$HCI_SOFT_EXIT_CODE"
    fi
  fi
  log::error "Шаг $step завершился с ошибкой (код $rc)"
  return "$rc"
}

dispatch::images() {
  local kind img
  for kind in build runtime sonar svace; do
    if img="$(ci::meta_image "$kind" 2>/dev/null)"; then
      printf '%s=%s\n' "$kind" "$img"
    fi
  done
}

dispatch::main() {
  local cmd="${1:-help}"
  shift || true
  case "$cmd" in
    help | -h | --help) dispatch::usage; return 0 ;;
    version | --version) cat "$HCI_HOME/VERSION"; return 0 ;;
  esac

  config::_lock_env
  ci_env::detect
  config::parse_args "$@"
  set -- "${HCI_ARGS[@]+"${HCI_ARGS[@]}"}"

  cd "$HCI_ROOT"
  cd "${HCI_WORKDIR:-.}" || log::die "Рабочий каталог не найден: ${HCI_WORKDIR}"
  export HCI_WORKDIR_ABS="$PWD"

  HCI_TMP="$(mktemp -d "${TMPDIR:-/tmp}/hci.XXXXXX")"
  export HCI_TMP
  # shellcheck disable=SC2064
  trap "rm -rf '$HCI_TMP'" EXIT

  config::load
  mkdir -p "$HCI_OUT_DIR" "$HCI_CACHE_DIR"

  case "$cmd" in
    config) config::dump ;;
    detect)
      dispatch::load_runtime
      printf 'runtime=%s\nversion=%s\nservice_type=%s\n' "$HCI_RUNTIME" "${HCI_RUNTIME_VERSION:-}" "$HCI_SERVICE_TYPE"
      if declare -F rt::detect_tools >/dev/null; then rt::detect_tools; fi
      ;;
    images) dispatch::images ;;
    manifest:validate) manifest::validate "$@" ;;
    run)
      [[ $# -gt 0 ]] || log::die "Использование: ci run -- <команда>"
      dispatch::setup_runtime
      "$@"
      ;;
    *) dispatch::step "$cmd" ;;
  esac
}
