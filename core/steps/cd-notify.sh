# shellcheck shell=bash
# cd:notify — HTTP webhook deploy trigger (Argo/Flux/Jenkins/arbitrary endpoint).
# The token only ever travels via curl's stdin config (-K -), never via -H in argv:
# argv is visible to any process via ps on a shared runner.

# Prints scheme://host/path of the webhook — without query or userinfo.
# A webhook URL often carries a secret in ?token=..., which no masking regex catches.
cd_notify::safe_url() {
  local u="$1" scheme="http" rest auth path=""
  # Without an explicit scheme, "${u%%://*}" would return the whole string, and query/userinfo wouldn't get stripped.
  if [[ "$u" == *://* ]]; then scheme="${u%%://*}"; rest="${u#*://}"; else rest="$u"; fi
  rest="${rest%%\?*}"
  rest="${rest%%#*}"
  auth="${rest%%/*}"
  [[ "$rest" == */* ]] && path="/${rest#*/}"
  # ##*@ (greedy), not #*@ — otherwise a password containing @ leaves a tail of itself in the output.
  printf '%s://%s%s' "$scheme" "${auth##*@}" "$path"
}

# A single request attempt. Reads curl_args, conf and safe from the caller's locals (dynamic scope).
# 2xx → 0; 4xx → log::die immediately, no retry (the webhook trigger isn't idempotent, retrying
# on a client config error is actively harmful); 5xx and network errors → non-zero code for retry().
cd_notify::attempt() {
  local out code body rc=0
  # no --fail/--fail-with-body: we need the status code itself, --fail discards it before we can read it
  out="$(curl -sS -w '\n%{http_code}' "${curl_args[@]}" -K - <<< "$conf")" || rc=$?
  if (( rc != 0 )); then
    log::warn "cd:notify — curl exited with code $rc (network error), $safe"
    return "$rc"
  fi
  code="${out##*$'\n'}"
  body="${out%$'\n'*}"
  case "$code" in
    2*) log::ok "cd:notify — $safe returned $code"; return 0 ;;
    4*) log::die "cd:notify — $safe returned $code (request error, not retrying): $body" ;;
    *) log::warn "cd:notify — $safe returned $code: $body"; return 1 ;;
  esac
}

step::cd_notify() {
  ci::require curl
  [[ -n "${HCI_CD_NOTIFY_URL:-}" ]] || log::die "HCI_CD_NOTIFY_URL is not set"

  local tls=() curl_args=() conf="" safe body hdr method
  tls::curl_args tls
  safe="$(cd_notify::safe_url "$HCI_CD_NOTIFY_URL")"
  method="${HCI_CD_NOTIFY_METHOD:-POST}"

  if [[ -n "${HCI_CD_NOTIFY_TOKEN:-}" ]]; then
    log::mask "$HCI_CD_NOTIFY_TOKEN"
    hdr="Authorization: Bearer $HCI_CD_NOTIFY_TOKEN"
    hdr="${hdr//\\/\\\\}"
    conf="$(printf 'header = "%s"' "${hdr//\"/\\\"}")"
  fi

  curl_args=(-X "$method" --connect-timeout 10 --max-time "${HCI_CD_NOTIFY_TIMEOUT:-30}" "${tls[@]+"${tls[@]}"}")
  body="${HCI_CD_NOTIFY_BODY:-}"
  if [[ -n "$body" ]]; then
    # the body is passed through as-is: no eval/ci::expand — tag and branch names are
    # controlled by whoever can push a tag, i.e. they're untrusted
    case "$body" in
      '{'* | '['*) curl_args+=(-H 'Content-Type: application/json') ;;
    esac
    curl_args+=(--data-raw "$body")
  fi
  curl_args+=("$HCI_CD_NOTIFY_URL")

  log::info "cd:notify — $method $safe"
  retry cd_notify::attempt
}
