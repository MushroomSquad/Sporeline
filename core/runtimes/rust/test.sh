# shellcheck shell=bash
rt::test() {
  local pkg extra=()
  pkg="${HCI_RUST_PACKAGE:-$(rust::root_package || true)}"
  ci::words extra "${HCI_RUST_EXTRA_PACKAGES:-}"
  if [[ -n "$pkg" ]]; then
    log::cmd cargo test --release --all-features --package "$pkg"
    local p
    for p in "${extra[@]+"${extra[@]}"}"; do
      [[ "$p" == "$pkg" ]] && continue
      log::cmd cargo test --release --all-features --package "$p"
    done
  else
    log::cmd cargo test --release --all-features
  fi
}
