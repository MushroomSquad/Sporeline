# shellcheck shell=bash
# Step dispatcher: ci <step> [--key=value ...]

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

# Steps whose failure under HCI_STRICT=false doesn't fail the pipeline.
HCI_SOFT_STEPS=" test lint image:scan deps:scan sonar svace appscreener kcs "
# Steps before which the runtime environment is set up (registries, caches, toolchain).
HCI_SETUP_STEPS=" build test lint publish sonar svace "

dispatch::usage() {
  cat <<'EOF'
Usage: ci <command> [--key=value ...]

Build steps:
  build            build (and package a library when service_type=library)
  test             unit tests with coverage
  lint             linters
  publish          publish a library to a package registry
  image:build      build the image (modes: base | dockerfile | s2i | cekit)
  image:scan       image analysis (Trivy) and SBOM
  image:publish    publish, sign, and attest the image
  sbom             image SBOM
  deps:scan        dependency analysis (Trivy fs)
  sonar            SonarQube
  svace            Svace
  appscreener      Solar appScreener
  kcs              Kaspersky Container Security
  helm:lint        check a Helm chart
  helm:publish     publish a Helm chart
  cd:bump          bump the image in a GitOps manifest (git commit+push)
  cd:notify        webhook trigger for a GitOps controller (ArgoCD/Flux)

Service commands:
  config              final configuration (secrets hidden)
  detect              detect the runtime and tools
  images              build/runtime images for the current runtime
  manifest:validate   validate the artifact manifest
  run -- <command>    run a command inside the runtime environment
  version             core version

Any configuration key can be passed as an argument: --runtime-version=21 -> HCI_RUNTIME_VERSION=21.
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

  trap 'log::error "Error (code $?) at ${BASH_SOURCE[0]##*/}:${LINENO}: ${BASH_COMMAND}"' ERR

  if [[ "$HCI_SETUP_STEPS" == *" $step "* ]]; then
    dispatch::setup_runtime
  else
    dispatch::load_runtime
  fi

  hooks::run "$step" pre

  if [[ -n "${!cmd_var:-}" ]]; then
    log::info "Custom command from $cmd_var"
    eval "${!cmd_var}"
  elif [[ "$kind" == "runtime" ]]; then
    [[ "${HCI_RUNTIME:-none}" != "none" ]] || log::die "Runtime not detected. Set HCI_RUNTIME or runtime: in .ci.yaml"
    file="$HCI_HOME/runtimes/$HCI_RUNTIME/$step.sh"
    [[ -f "$file" ]] || ci::skip "runtime $HCI_RUNTIME does not support step $step"
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
  [[ -n "$kind" ]] || { dispatch::usage >&2; log::die "Unknown command: $step"; }

  case "$HCI_SERVICE_TYPE" in
    image | library) ;;
    *) log::die "HCI_SERVICE_TYPE must be image or library, got: $HCI_SERVICE_TYPE" ;;
  esac

  up="${step^^}"
  up="${up//[:-]/_}"
  local enabled_var="HCI_${up}_ENABLED" strict_var="HCI_${up}_STRICT"
  if [[ -n "${!enabled_var:-}" ]] && ! ci::is_true "${!enabled_var}"; then
    log::info "Step $step disabled ($enabled_var=${!enabled_var})"
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
    log::ok "Step $step completed"
    return 0
  fi
  if [[ $rc -eq $HCI_SKIP_CODE ]]; then
    return 0
  fi
  if [[ "$HCI_SOFT_STEPS" == *" $step "* ]]; then
    strict="${!strict_var:-$HCI_STRICT}"
    if ! ci::is_true "$strict"; then
      log::warn "Step $step failed (code $rc), but strict mode is off"
      return "$HCI_SOFT_EXIT_CODE"
    fi
  fi
  log::error "Step $step failed (code $rc)"
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
  cd "${HCI_WORKDIR:-.}" || log::die "Working directory not found: ${HCI_WORKDIR}"
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
      [[ $# -gt 0 ]] || log::die "Usage: ci run -- <command>"
      dispatch::setup_runtime
      "$@"
      ;;
    *) dispatch::step "$cmd" ;;
  esac
}
