# shellcheck shell=bash
rt::setup() {
  ci::require go
  tls::bundle >/dev/null
  export GOCACHE="${GOCACHE:-$HCI_CACHE_DIR/go-build}"
  export GOMODCACHE="${GOMODCACHE:-$HCI_CACHE_DIR/gomod}"
  export CGO_ENABLED="${CGO_ENABLED:-0}"
  export GOOS="${GOOS:-linux}"
  export GOARCH="${GOARCH:-amd64}"
  if registry::has GO; then
    GOPROXY="$(registry::url GO pull)/"
    GOSUMDB="sum.golang.org $(registry::scheme)://$(registry::host GO)/$(registry::_field GO SUM_REPO)/"
    export GOPROXY GOSUMDB
    local netrc="$HCI_WORKDIR_ABS/.netrc"
    printf 'machine %s login %s password %s\n' "$(registry::host GO)" "$(registry::user GO)" "$(registry::password GO)" > "$netrc"
    chmod 600 "$netrc"
    export NETRC="$netrc"
  fi
}

rt::sonar_params() {
  [[ -f coverage.out ]] && printf '%s\n' "-Dsonar.go.coverage.reportPaths=coverage.out"
}

rt::svace_build_cmd() {
  printf 'go build -tags %q -ldflags %q -o %s %s' "${HCI_GO_TAGS:-}" "${HCI_GO_LDFLAGS:-}" "${HCI_GO_BINARY:-app}" "${HCI_GO_CONTEXT:-./}"
}

rt::detect_tools() { printf 'go=%s\n' "$(go version 2>/dev/null || true)"; }
