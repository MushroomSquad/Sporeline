# shellcheck shell=bash
rt::lint() {
  bun::has_script lint || ci::skip "нет скрипта lint"
  log::cmd bun run lint
}
