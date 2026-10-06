# shellcheck shell=bash
# Python: uv / poetry / pdm / pip. Index — a Nexus pypi-group with auth embedded in the URL.

python::pm() {
  case "${HCI_PYTHON_PACKAGE_MANAGER:-auto}" in
    uv | poetry | pdm | pip) printf '%s' "$HCI_PYTHON_PACKAGE_MANAGER"; return 0 ;;
  esac
  [[ -f uv.lock ]] && { printf uv; return 0; }
  [[ -f poetry.lock ]] && { printf poetry; return 0; }
  [[ -f pdm.lock ]] && { printf pdm; return 0; }
  printf pip
}

python::index() {
  registry::url_with_auth PYPI pull
}

rt::setup() {
  ci::require python3
  tls::bundle >/dev/null
  local idx
  if registry::has PYPI; then
    idx="$(python::index)"
    export PIP_INDEX_URL="$idx" UV_INDEX_URL="$idx"
    POETRY_HTTP_BASIC_HCI_USERNAME="$(registry::user PYPI)"
    export POETRY_HTTP_BASIC_HCI_USERNAME
    export PIP_DISABLE_PIP_VERSION_CHECK=1
    export UV_INDEX_STRATEGY=unsafe-best-match
  fi
  export PIP_CACHE_DIR="${PIP_CACHE_DIR:-$HCI_CACHE_DIR/pip}"
  export UV_CACHE_DIR="${UV_CACHE_DIR:-$HCI_CACHE_DIR/uv}"
}

python::export_reqs() {
  local out="${1:-requirements.txt}" pm
  pm="$(python::pm)"
  case "$pm" in
    uv)
      ci::require uv
      log::cmd uv export --frozen --no-emit-workspace --no-dev -o "$out"
      ;;
    poetry)
      ci::require poetry
      log::cmd poetry self add poetry-plugin-export >/dev/null 2>&1 || true
      log::cmd poetry export --without-hashes -f requirements.txt -o "$out"
      ;;
    pdm)
      ci::require pdm
      log::cmd pdm export -o "$out" --without-hashes
      ;;
    *)
      if [[ -f requirements.txt ]]; then
        [[ "$out" == requirements.txt ]] || cp requirements.txt "$out"
      elif [[ -f pyproject.toml ]]; then
        printf '# pyproject.toml\n' > "$out"
      else
        log::die "Нет requirements.txt / pyproject.toml"
      fi
      ;;
  esac
}

python::venv_install() {
  local reqs="${1:-requirements.txt}"
  if ci::has uv; then
    log::cmd uv venv .venv
    # shellcheck disable=SC1091
    source .venv/bin/activate
    log::cmd uv pip install -r "$reqs"
  else
    log::cmd python3 -m venv .venv
    # shellcheck disable=SC1091
    source .venv/bin/activate
    log::cmd pip install -U pip
    log::cmd pip install -r "$reqs"
  fi
}

rt::sonar_params() {
  [[ -f coverage.xml ]] && printf '%s\n' "-Dsonar.python.coverage.reportPaths=coverage.xml"
}

rt::detect_tools() { printf 'package_manager=%s\n' "$(python::pm)"; }
