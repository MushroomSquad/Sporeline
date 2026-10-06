# shellcheck shell=bash
rt::detect() {
  [[ -f bun.lock || -f bun.lockb ]] && [[ -f package.json ]]
}
