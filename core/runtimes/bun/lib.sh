# shellcheck shell=bash
rt::setup() {
  ci::require bun
  tls::bundle >/dev/null
  export BUN_INSTALL_CACHE_DIR="${BUN_INSTALL_CACHE_DIR:-$HCI_CACHE_DIR/bun}"
  local cfg="${XDG_CONFIG_HOME:-$HCI_TMP}/.bunfig.toml" url token
  mkdir -p "$(dirname "$cfg")"
  if registry::has NPM; then
    url="$(registry::url NPM pull)/"
    token="$(printf '%s' "$(registry::user NPM):$(registry::password NPM)" | base64 -w0 2>/dev/null || printf '%s' "$(registry::user NPM):$(registry::password NPM)" | base64 | tr -d '\n')"
    printf '[install]\nregistry = { url = "%s", token = "%s" }\n' "$url" "$token" > "$cfg"
    chmod 600 "$cfg"
  fi
}

bun::has_script() {
  [[ -n "$(jq -r --arg n "$1" '.scripts[$n] // empty' package.json)" ]]
}

bun::install() {
  if ci::is_true "${HCI_NODE_IGNORE_LOCK:-false}"; then
    log::cmd bun install
  else
    [[ -f bun.lock || -f bun.lockb ]] || log::die "No bun.lock / bun.lockb. Set HCI_NODE_IGNORE_LOCK=true to continue."
    log::cmd bun install --frozen-lockfile
  fi
}

rt::sonar_params() {
  local cov
  cov="$(ci::first_file coverage/lcov.info || true)"
  [[ -n "$cov" ]] && printf '%s\n' "-Dsonar.javascript.lcov.reportPaths=$cov"
}

rt::detect_tools() { printf 'package_manager=bun\n'; }
