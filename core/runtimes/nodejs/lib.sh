# shellcheck shell=bash
# Node.js: npm / yarn / pnpm через corepack. NPM_CONFIG_USERCONFIG в HCI_TMP.

node::pm() {
  local forced="${HCI_NODE_PACKAGE_MANAGER:-auto}"
  case "$forced" in
    npm | yarn | pnpm) printf '%s' "$forced"; return 0 ;;
  esac
  [[ -f yarn.lock ]] && { printf yarn; return 0; }
  [[ -f pnpm-lock.yaml ]] && { printf pnpm; return 0; }
  printf npm
}

node::has_script() {
  [[ -n "$(jq -r --arg n "$1" '.scripts[$n] // empty' package.json)" ]]
}

node::npmrc() {
  local file="$HCI_TMP/npmrc" host repo user pass auth url
  host="$(registry::host NPM)"
  repo="$(registry::_field NPM PULL_REPO)"
  user="$(registry::user NPM)"
  pass="$(registry::password NPM)"
  url="$(registry::url NPM pull)/"
  : > "$file"
  printf 'registry=%s\n' "$url" >> "$file"
  if [[ -n "$user" ]]; then
    auth="$(printf '%s' "$user:$pass" | base64 -w0 2>/dev/null || printf '%s' "$user:$pass" | base64 | tr -d '\n')"
    printf '//%s/%s/:_auth=%s\nalways-auth=true\n' "$host" "$repo" "$auth" >> "$file"
  fi
  tls::has_custom && printf 'cafile=%s\n' "$(tls::bundle)" >> "$file"
  export NPM_CONFIG_USERCONFIG="$file"
  export npm_config_userconfig="$file"
  printf '%s' "$file"
}

rt::setup() {
  node::setup
}

node::setup() {
  ci::require node
  tls::bundle >/dev/null
  export npm_config_cache="${npm_config_cache:-$HCI_CACHE_DIR/npm}"
  node::npmrc >/dev/null
  local pm
  pm="$(node::pm)"
  export HCI_NODE_PM="$pm"
  if [[ "$pm" != npm ]] && ci::has corepack; then
    export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
    case "$pm" in
      yarn) log::cmd corepack enable yarn ;;
      pnpm)
        local ver="${HCI_PNPM_VERSION:-}"
        [[ -z "$ver" ]] && ver="$(ci::pkg_json '.packageManager // empty' | sed -n 's/^pnpm@//p')"
        if [[ -n "$ver" ]]; then
          log::cmd corepack prepare "pnpm@$ver" --activate
        else
          log::cmd corepack enable pnpm
        fi
        ;;
    esac
  fi
}

node::install() {
  local frozen=()
  ci::is_true "${HCI_NODE_IGNORE_LOCK:-false}" || frozen=(--frozen-lockfile)
  case "${HCI_NODE_PM:-$(node::pm)}" in
    yarn)
      if [[ -f yarn.lock ]]; then
        local url
        url="$(registry::url NPM pull)"
        sed -i "s|https://registry.yarnpkg.com|${url}|g; s|https://registry.npmjs.org|${url}|g" yarn.lock || true
      fi
      if yarn --version 2>/dev/null | grep -q '^1\.'; then
        log::cmd yarn install --cache-folder "$HCI_CACHE_DIR/npm" --prefer-offline --no-progress ${frozen:+--frozen-lockfile}
      else
        log::cmd yarn install "${frozen[@]+"${frozen[@]}"}"
      fi
      ;;
    pnpm) log::cmd pnpm install "${frozen[@]+"${frozen[@]}"}" ;;
    *)
      if ci::is_true "${HCI_NODE_IGNORE_LOCK:-false}" || [[ ! -f package-lock.json ]]; then
        log::cmd npm install --no-audit --no-fund
      else
        log::cmd npm ci --no-audit --no-fund
      fi
      ;;
  esac
}

node::run_script() {
  local name="$1"
  case "${HCI_NODE_PM:-npm}" in
    yarn) log::cmd yarn run "$name" ;;
    pnpm) log::cmd pnpm run "$name" ;;
    *) log::cmd npm run "$name" ;;
  esac
}

rt::sonar_params() {
  local cov
  cov="$(ci::first_file coverage/lcov.info coverage/cobertura-coverage.xml || true)"
  [[ -n "$cov" ]] && printf '%s\n' "-Dsonar.javascript.lcov.reportPaths=$cov"
}

rt::svace_build_cmd() { printf 'true'; }

rt::detect_tools() { printf 'package_manager=%s\n' "$(node::pm)"; }

node::publish() {
  naming::is_release || ci::is_true "${HCI_PUBLISH_SNAPSHOTS:-false}" || ci::skip "публикация только по тегу"
  local root="${HCI_NODE_PUBLISH_PATH:-.}" names=() dir url host repo user pass auth registry
  [[ -d "$root" ]] || log::die "Каталог публикации не найден: $root (HCI_NODE_PUBLISH_PATH)"
  ci::split names "${HCI_NODE_PUBLISH_NAME:-}"
  url="$(registry::url NPM push)/"
  host="$(registry::host NPM)"
  repo="$(registry::_field NPM REPO)"
  user="$(registry::user NPM)"
  pass="$(registry::password NPM)"
  registry="$url"
  if [[ -n "$user" ]]; then
    auth="$(printf '%s' "$user:$pass" | base64 -w0 2>/dev/null || printf '%s' "$user:$pass" | base64 | tr -d '\n')"
    printf 'registry=%s\n//%s/%s/:_auth=%s\nalways-auth=true\n' "$url" "$host" "$repo" "$auth" > "$HCI_TMP/npmrc-publish"
    export NPM_CONFIG_USERCONFIG="$HCI_TMP/npmrc-publish"
  fi
  local targets=() t pj name ver
  if [[ ${#names[@]} -gt 0 ]]; then
    for t in "${names[@]}"; do targets+=("$root/$t"); done
  elif [[ -f "$root/package.json" ]]; then
    targets+=("$root")
  else
    for dir in "$root"/*/; do [[ -f "${dir}package.json" ]] && targets+=("${dir%/}"); done
  fi
  [[ ${#targets[@]} -gt 0 ]] || log::die "Нечего публиковать в $root"
  ci::require npm
  for t in "${targets[@]}"; do
    pj="$t/package.json"
    [[ -f "$pj" ]] || log::die "Нет $pj"
    if [[ "$(jq -r '.publishConfig.provenance // false' "$pj")" == "true" ]]; then
      jq '.publishConfig.provenance = false' "$pj" > "$pj.tmp" && mv "$pj.tmp" "$pj"
    fi
    retry log::cmd npm publish --ignore-scripts --registry "$url" "$t"
    name="$(jq -r '.name' "$pj")"
    ver="$(jq -r '.version' "$pj")"
    manifest::add npm "$name" "$ver" "$registry"
  done
}

