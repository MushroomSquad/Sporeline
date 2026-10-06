# shellcheck shell=bash
# Solar appScreener: source archive -> scan/start -> wait with a timeout -> report.

appscreener::api() {
  local method="$1" path="$2"
  shift 2
  local tls=()
  tls::curl_args tls
  curl -sS --fail-with-body "${tls[@]+"${tls[@]}"}" -X "$method" \
    -H 'accept: application/json' -H "Authorization: Bearer $HCI_APPSCREENER_TOKEN" \
    "$@" "${HCI_APPSCREENER_URL%/}/app/api/v1/$path"
}

step::appscreener() {
  ci::require curl tar jq
  local v
  for v in HCI_APPSCREENER_URL HCI_APPSCREENER_TOKEN HCI_APPSCREENER_GROUP_UUID; do
    [[ -n "${!v:-}" ]] || log::die "$v is not set"
  done

  appscreener::api GET health >/dev/null || log::die "appScreener API unavailable: $HCI_APPSCREENER_URL"

  local name="${HCI_PROJECT_PATH:-$HCI_PROJECT_NAME}" archive excludes=() e tar_args=()
  archive="$HCI_TMP/$(ci::slug "$name").tar"
  ci::split excludes "${HCI_APPSCREENER_EXCLUDES:-}"
  for e in "${excludes[@]+"${excludes[@]}"}"; do tar_args+=("--exclude=./$e"); done
  log::cmd tar cf "$archive" "${tar_args[@]+"${tar_args[@]}"}" .

  local form=(-F "name=$name" -F "file=@$archive;type=application/tar" -F "groups=$HCI_APPSCREENER_GROUP_UUID")
  [[ -n "${HCI_APPSCREENER_PROJECT_UUID:-}" ]] && form+=(-F "uuid=$HCI_APPSCREENER_PROJECT_UUID")
  local resp scan proj
  resp="$(retry appscreener::api POST scan/start -H 'Content-Type: multipart/form-data' "${form[@]}")"
  scan="$(jq -r '.scanUuid // empty' <<< "$resp")"
  proj="$(jq -r '.projUuid // empty' <<< "$resp")"
  [[ -n "$scan" && -n "$proj" ]] || log::die "Response has no scanUuid/projUuid: $resp"
  log::info "Scan started: project=$proj scan=$scan"

  mkdir -p "$(dirname "$HCI_APPSCREENER_REPORT")"
  if ! ci::is_true "${HCI_APPSCREENER_WAIT:-true}"; then
    jq -n --arg p "$proj" --arg s "$scan" '{projectUuid: $p, scanUuid: $s}' > "$HCI_APPSCREENER_REPORT"
    log::info "Waiting disabled (HCI_APPSCREENER_WAIT=false)"
    return 0
  fi

  local deadline status report
  deadline=$(( $(date +%s) + ${HCI_APPSCREENER_TIMEOUT:-3600} ))
  while :; do
    report="$(appscreener::api GET "scans/$scan/compact")" || report='{}'
    status="$(jq -r '.status // "UNKNOWN"' <<< "$report")"
    case "$status" in
      COMPLETE) break ;;
      FAILED | ERROR | CANCELED | CANCELLED) log::die "Scan finished with status $status" ;;
    esac
    (( $(date +%s) < deadline )) || log::die "Scan did not finish within ${HCI_APPSCREENER_TIMEOUT}s (status $status)"
    log::info "Scan status: $status"
    sleep "${HCI_APPSCREENER_POLL_INTERVAL:-15}"
  done
  jq --arg p "$proj" --arg s "$scan" '{projectUuid: $p, scanUuid: $s, scan: .}' <<< "$report" > "$HCI_APPSCREENER_REPORT"
  log::ok "Scan finished, report: $HCI_APPSCREENER_REPORT"
}
