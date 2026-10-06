# shellcheck shell=bash
# Pre-built static assets without a package.json (projects with package.json are detected as nodejs; static must be set explicitly).
rt::detect() {
  [[ -f index.html || -f dist/index.html || -f public/index.html ]]
}
