# shellcheck shell=bash
rt::publish() {
  naming::is_release || ci::skip "crate publish only runs on a tag"
  local name ver
  name="$(rust::root_package)"
  ver="$(naming::version)"
  [[ -n "$name" ]] || log::die "Could not determine the crate name"
  retry log::cmd cargo publish --allow-dirty --registry hci
  manifest::add cargo "$name" "$ver" "$(registry::url CARGO push)"
}
