# shellcheck shell=bash
# Svace: build interception, remote analysis, SARIF report.
# Build command: HCI_SVACE_BUILD_CMD or the runtime's rt::svace_build_cmd.

step::svace() {
  ci::require svace
  local cmd="${HCI_SVACE_BUILD_CMD:-}" args=() res=".svace-dir/analyze-res/svace-report.svres"
  if [[ -z "$cmd" ]] && declare -F rt::svace_build_cmd >/dev/null; then
    cmd="$(rt::svace_build_cmd)"
  fi
  [[ -n "$cmd" ]] || log::die "Не задана команда сборки для Svace (HCI_SVACE_BUILD_CMD)"
  [[ -n "${HCI_SVACE_HOST:-}" ]] || log::die "Не задан HCI_SVACE_HOST (SVACE_HOST)"

  [[ -d .svace-dir ]] || log::cmd svace init
  ci::words args "${HCI_SVACE_ARGS:-}"
  log::cmd svace build "${args[@]+"${args[@]}"}" sh -c "$cmd"
  log::cmd svace remote --host "$HCI_SVACE_HOST" --login "$HCI_SVACE_LOGIN" --password "$HCI_SVACE_PASSWORD" \
    analyze --name svace-report

  [[ -f "$res" ]] || log::die "Svace не сформировал $res"
  log::cmd svace svres2sarif --out "$HCI_OUT_DIR/svace.sarif" "$res"
  log::ok "Отчёт: $HCI_OUT_DIR/svace.sarif"
}
