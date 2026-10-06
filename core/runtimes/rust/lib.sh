# shellcheck shell=bash
rt::setup() {
  ci::require cargo jq
  tls::bundle >/dev/null
  export CARGO_HOME="${CARGO_HOME:-$HCI_CACHE_DIR/cargo}"
  mkdir -p "$CARGO_HOME"
  if registry::has CARGO; then
    local token group hosted
    token="$(printf '%s' "$(registry::user CARGO):$(registry::password CARGO)" | base64 -w0 2>/dev/null || printf '%s' "$(registry::user CARGO):$(registry::password CARGO)" | base64 | tr -d '\n')"
    group="sparse+$(registry::url CARGO pull)/"
    hosted="sparse+$(registry::url CARGO push)/"
    cat > "$CARGO_HOME/config.toml" <<EOF
[registries.hci-group]
index = "${group}"
token = "Basic ${token}"
credential-provider = "cargo:token"
[registries.hci]
index = "${hosted}"
token = "Basic ${token}"
credential-provider = "cargo:token"
[source.crates-io]
replace-with = "hci-group"
EOF
    if tls::has_custom; then
      printf '\n[http]\ncainfo = "%s"\n' "$(tls::bundle)" >> "$CARGO_HOME/config.toml"
    fi
  fi
}

rust::metadata() {
  cargo metadata --no-deps --format-version 1
}

rust::root_package() {
  rust::metadata | jq -r --arg m "$HCI_WORKDIR_ABS/Cargo.toml" '.packages[] | select(.manifest_path == $m) | .name'
}

rt::detect_tools() { printf 'cargo=%s\n' "$(cargo --version 2>/dev/null || true)"; }
