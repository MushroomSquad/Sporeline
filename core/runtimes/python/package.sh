# shellcheck shell=bash
rt::package() {
  [[ -d dist ]] && return 0
  if ci::has uv; then
    log::cmd uv build
  else
    log::cmd python3 -m build
  fi
}
