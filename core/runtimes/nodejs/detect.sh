# shellcheck shell=bash
rt::detect() {
  [[ -f package.json && ! -f bun.lock && ! -f bun.lockb ]]
}
