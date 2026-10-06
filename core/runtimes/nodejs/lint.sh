# shellcheck shell=bash
node::lint() {
  if node::has_script lint; then
    node::run_script lint
    return 0
  fi
  local cfg
  cfg="$(ci::first_file eslint.config.js eslint.config.mjs eslint.config.cjs .eslintrc .eslintrc.js .eslintrc.json .eslintrc.yml || true)"
  [[ -n "$cfg" ]] || ci::skip "no lint script and no eslint config"
  ci::has eslint || log::cmd npm install --no-save eslint@"${HCI_ESLINT_VERSION:-8.56.0}"
  local extra=()
  ci::words extra "${HCI_ESLINT_ARGS:-src/}"
  log::cmd npx --no-install eslint "${extra[@]}"
}

rt::lint() { node::lint; }
