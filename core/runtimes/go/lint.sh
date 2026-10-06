# shellcheck shell=bash
rt::lint() {
  if ci::has golangci-lint; then
    log::cmd golangci-lint run
  else
    log::cmd go vet ./...
  fi
}
