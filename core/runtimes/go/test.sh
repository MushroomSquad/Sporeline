# shellcheck shell=bash
rt::test() {
  local pkgs
  pkgs="$(go list ./... | grep -v /vendor/ || true)"
  [[ -n "$pkgs" ]] || ci::skip "нет пакетов для тестов"
  # shellcheck disable=SC2086
  log::cmd go test -short -coverprofile=coverage.out $pkgs
  log::cmd go tool cover -func=coverage.out
}
