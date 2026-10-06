# shellcheck shell=bash
rt::publish() {
  naming::is_release || ci::skip "публикация crate только по тегу"
  local name ver
  name="$(rust::root_package)"
  ver="$(naming::version)"
  [[ -n "$name" ]] || log::die "Не удалось определить имя crate"
  retry log::cmd cargo publish --allow-dirty --registry hci
  manifest::add cargo "$name" "$ver" "$(registry::url CARGO push)"
}
