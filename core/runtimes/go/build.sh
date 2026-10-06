# shellcheck shell=bash
rt::build() {
  [[ -f go.mod ]] || log::die "В каталоге проекта нет go.mod"
  local tags=()
  [[ -n "${HCI_GO_TAGS:-}" ]] && tags=(-tags "$HCI_GO_TAGS")
  log::cmd go build "${tags[@]}" -ldflags "${HCI_GO_LDFLAGS:-}" -o "${HCI_GO_BINARY:-app}" "${HCI_GO_CONTEXT:-./}"
}
