# shellcheck shell=bash
rt::build() {
  [[ -f Cargo.toml ]] || log::die "No Cargo.toml"
  if [[ "$HCI_SERVICE_TYPE" == "library" ]]; then
    grep -q '^\[package\]' Cargo.toml || log::die "Only the root crate with a [package] section is published"
    if naming::is_release; then
      local ver
      ver="$(naming::version)"
      if grep -q '^version.workspace = true' Cargo.toml; then
        sed -i "/^\[workspace.package\]/,/^\[/{s/^version = .*/version = \"$ver\"/;}" Cargo.toml
      else
        sed -i "0,/^version = .*/s//version = \"$ver\"/" Cargo.toml
      fi
    fi
    log::cmd cargo package --allow-dirty
    return 0
  fi
  local pkg="${HCI_RUST_PACKAGE:-}" bin="${HCI_RUST_BIN:-}" meta
  meta="$(rust::metadata)"
  if [[ -z "$pkg" ]]; then
    pkg="$(jq -r '
      . as $m
      | [ $m.packages[] | select($m.workspace_members | index(.id))
          | select([.targets[] | select(.kind | index("bin"))] | length > 0) ]
      | if length == 1 then .[0].name else empty end
    ' <<< "$meta")"
  fi
  [[ -n "$pkg" ]] || log::die "Could not pick a package. Set HCI_RUST_PACKAGE"
  if [[ -z "$bin" ]]; then
    bin="$(jq -r --arg p "$pkg" '
      .packages[] | select(.name == $p)
      | (.default_run // ([.targets[] | select(.kind | index("bin")) | .name] | if length == 1 then .[0] else empty end))
    ' <<< "$meta")"
  fi
  [[ -n "$bin" ]] || log::die "Could not pick a binary. Set HCI_RUST_BIN"
  local host
  host="$(rustc -vV | awk '/^host:/{print $2}')"
  mkdir -p "${CARGO_HOME:-$HCI_CACHE_DIR/cargo}"
  printf '\n[target.%s]\nrustflags = ["-C", "target-feature=+crt-static"]\n' "$host" >> "${CARGO_HOME:-$HCI_CACHE_DIR/cargo}/config.toml"
  log::cmd cargo build --release --package "$pkg" --bin "$bin"
  cp "target/release/$bin" "./${HCI_RUST_BINARY:-app}"
  export HCI_IMAGE_CONTEXT="${HCI_RUST_BINARY:-app}"
}
