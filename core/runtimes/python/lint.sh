# shellcheck shell=bash
rt::lint() {
  if [[ -f ruff.toml || -f .ruff.toml ]] || grep -q '\[tool.ruff\]' pyproject.toml 2>/dev/null; then
    ci::has ruff || log::cmd python3 -m pip install ruff
    log::cmd ruff check .
    return 0
  fi
  ci::skip "no ruff configuration"
}
