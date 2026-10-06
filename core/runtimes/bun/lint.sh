# shellcheck shell=bash
rt::lint() {
  bun::has_script lint || ci::skip "no lint script"
  log::cmd bun run lint
}
