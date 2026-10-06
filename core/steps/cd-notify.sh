# shellcheck shell=bash
# cd:notify — HTTP-вебхук триггера деплоя (Argo/Flux/Jenkins/произвольный endpoint).
# Токен уходит только через stdin-конфиг curl (-K -), никогда через -H в argv:
# argv виден любому процессу через ps на общем раннере.

# Печатает scheme://host/path вебхука — без query и userinfo.
# Вебхук-URL часто несёт секрет в ?token=..., который не ловит ни один регэксп маскирования.
cd_notify::safe_url() {
  local u="$1" scheme="http" rest auth path=""
  # Без явной схемы "${u%%://*}" вернула бы строку целиком, и query/userinfo не отрезались бы.
  if [[ "$u" == *://* ]]; then scheme="${u%%://*}"; rest="${u#*://}"; else rest="$u"; fi
  rest="${rest%%\?*}"
  rest="${rest%%#*}"
  auth="${rest%%/*}"
  [[ "$rest" == */* ]] && path="/${rest#*/}"
  # ##*@ (жадно), не #*@ — password-с-@ иначе оставляет хвост пароля в выводе.
  printf '%s://%s%s' "$scheme" "${auth##*@}" "$path"
}

# Одна попытка запроса. Берёт curl_args, conf и safe из локалей вызывающего (динамический scope).
# 2xx → 0; 4xx → log::die сразу, без ретрая (вебхук-триггер не идемпотентен, повторять запрос
# при ошибке конфигурации клиента — активно вредно); 5xx и сетевая ошибка → ненулевой код для retry().
cd_notify::attempt() {
  local out code body rc=0
  # без --fail/--fail-with-body: нужен сам код ответа, --fail его теряет до того, как мы его прочтём
  out="$(curl -sS -w '\n%{http_code}' "${curl_args[@]}" -K - <<< "$conf")" || rc=$?
  if (( rc != 0 )); then
    log::warn "cd:notify — curl завершился с кодом $rc (сетевая ошибка), $safe"
    return "$rc"
  fi
  code="${out##*$'\n'}"
  body="${out%$'\n'*}"
  case "$code" in
    2*) log::ok "cd:notify — $safe вернул $code"; return 0 ;;
    4*) log::die "cd:notify — $safe вернул $code (ошибка запроса, без ретрая): $body" ;;
    *) log::warn "cd:notify — $safe вернул $code: $body"; return 1 ;;
  esac
}

step::cd_notify() {
  ci::require curl
  [[ -n "${HCI_CD_NOTIFY_URL:-}" ]] || log::die "Не задана HCI_CD_NOTIFY_URL"

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
    # тело передаётся как есть: никакого eval/ci::expand — имена тегов и веток
    # подконтрольны тому, кто может пушить тег, то есть не доверены
    case "$body" in
      '{'* | '['*) curl_args+=(-H 'Content-Type: application/json') ;;
    esac
    curl_args+=(--data-raw "$body")
  fi
  curl_args+=("$HCI_CD_NOTIFY_URL")

  log::info "cd:notify — $method $safe"
  retry cd_notify::attempt
}
