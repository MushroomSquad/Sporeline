# shellcheck shell=bash
# Готовая статика без package.json (проекты с package.json определяются как nodejs; static задаётся явно).
rt::detect() {
  [[ -f index.html || -f dist/index.html || -f public/index.html ]]
}
