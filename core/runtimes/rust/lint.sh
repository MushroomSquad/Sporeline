# shellcheck shell=bash
rt::lint() {
  ci::require cargo
  local pkg extra=()
  pkg="${HCI_RUST_PACKAGE:-$(rust::root_package || true)}"
  ci::words extra "${HCI_RUST_EXTRA_PACKAGES:-}"
  if [[ -n "$pkg" ]]; then
    log::cmd cargo clippy --release --all-targets --all-features --package "$pkg" -- -D warnings
    local p
    for p in "${extra[@]+"${extra[@]}"}"; do
      [[ "$p" == "$pkg" ]] && continue
      log::cmd cargo clippy --release --all-targets --all-features --package "$p" -- -D warnings
    done
  else
    log::cmd cargo clippy --release --all-targets --all-features -- -D warnings
  fi
}
