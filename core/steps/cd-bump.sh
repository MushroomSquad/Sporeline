# shellcheck shell=bash
# cd:bump — правка image-ref в GitOps-репозитории: clone --depth 1 -> yq -> commit -> push с ретраем.
# Секреты (HTTPS-токен, SSH-ключ) не попадают ни в URL, ни в argv, ни на диск вне $HCI_TMP.

# cd_bump::secret_file ЗНАЧЕНИЕ ПУТЬ — печатает путь к файлу.
# Значение может быть путём к существующему файлу ИЛИ самим содержимым (CI-переменная типа File
# или обычная). Содержимое пишется в subshell с umask 077: режим 0600 с момента создания,
# без окна между write и отдельным chmod.
cd_bump::secret_file() {
  local v="$1" f="$2"
  if [[ -f "$v" ]]; then printf '%s' "$v"; return 0; fi
  (umask 077; printf '%s\n' "$v" > "$f")
  printf '%s' "$f"
}

# Готовит аутентификацию для git до клона (клон сам её уже требует).
cd_bump::auth() {
  if [[ -n "${HCI_CD_GIT_TOKEN:-}" ]]; then
    log::mask "$HCI_CD_GIT_TOKEN"
    # дефолт oauth2 — конвенция GitLab; GitHub App ждёт x-access-token,
    # Bitbucket — x-token-auth; оператор переопределяет через HCI_CD_GIT_USER
    export HCI_CD_GIT_USER="${HCI_CD_GIT_USER:-oauth2}"
    export HCI_CD_GIT_TOKEN
    local askpass="$HCI_TMP/askpass.sh"
    # git вызывает askpass ДВА раза с разным $1 (Username..., Password...). Безусловная печать
    # токена отдаёт его во второй промпт: ответ первого промпта становится частью текста второго,
    # то есть попадает в argv askpass-процесса и виден через ps.
    cat > "$askpass" <<'EOF'
#!/bin/sh
case "$1" in
  Username*) printf '%s\n' "$HCI_CD_GIT_USER" ;;
  *) printf '%s\n' "$HCI_CD_GIT_TOKEN" ;;
esac
EOF
    chmod 700 "$askpass"
    # GIT_TERMINAL_PROMPT=0 обязателен: без него сломанный askpass уводит git
    # в интерактивный промпт, и джоб висит до таймаута CI вместо быстрого падения.
    export GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0
  elif [[ -n "${HCI_CD_GIT_SSH_KEY:-}" ]]; then
    local key kh insecure=false opts
    ci::is_true "${HCI_CD_GIT_SSH_INSECURE:-false}" && insecure=true
    key="$(cd_bump::secret_file "$HCI_CD_GIT_SSH_KEY" "$HCI_TMP/cd_id")"
    kh="$HCI_TMP/cd_known_hosts"
    if [[ -n "${HCI_CD_GIT_SSH_KNOWN_HOSTS:-}" ]]; then
      kh="$(cd_bump::secret_file "$HCI_CD_GIT_SSH_KNOWN_HOSTS" "$kh")"
    elif [[ "$insecure" == true ]]; then
      : > "$kh"
    else
      log::die "Не задана HCI_CD_GIT_SSH_KNOWN_HOSTS (путь или содержимое). Получите ключ хоста: ssh-keyscan -H <host>; либо явно задайте HCI_CD_GIT_SSH_INSECURE=true"
    fi
    opts="-i $key -o IdentitiesOnly=yes -o BatchMode=yes -o UserKnownHostsFile=$kh"
    [[ "$insecure" == true ]] && opts+=" -o StrictHostKeyChecking=accept-new"
    export GIT_SSH_COMMAND="ssh $opts"
  fi
}

# Правка манифеста + коммит. Вызывается на каждой итерации retry-цикла с уже вычисленным $ref.
cd_bump::apply_commit() {
  local f="$dir/$HCI_CD_YAML_FILE"
  # Для multi-document YAML (несколько `---`-разделённых манифестов в одном файле, типовой случай
  # для Argo/Flux) HCI_CD_YAML_PATH обязан быть select-guarded, иначе гейт 1 совпадёт не с тем
  # документом: select(.kind=="Deployment").spec.template.spec.containers[0].image

  # Гейт 1 — путь существует и не пуст ДО записи. Ловит опечатку в пути и неверный индекс массива:
  # `yq -i '<путь> = ...'` на несуществующем пути не падает, а создаёт путь и выходит с 0.
  yq -e "$HCI_CD_YAML_PATH" "$f" >/dev/null 2>&1 || log::die "путь $HCI_CD_YAML_PATH не найден или пуст в $HCI_CD_YAML_FILE"
  # strenv(REF), не интерполяция "\"$ref\"": значение с кавычкой или $ меняло бы само выражение yq
  REF="$ref" yq -i "$HCI_CD_YAML_PATH = strenv(REF)" "$f"
  # Гейт 2 — правка легла именно туда, куда задумано (путь может совпасть с чем-то не тем)
  [[ "$(yq "$HCI_CD_YAML_PATH" "$f")" == "$ref" ]] || log::die "правка не применилась: $HCI_CD_YAML_PATH ≠ $ref"
  # Гейт 3 — yq не тронул ничего, кроме строки образа. Гейты 1+2 смотрят только на один путь и
  # пропускают попутное переписывание соседних строк (живой пример: merge-key `<<: *def`
  # превращается в `!!merge <<: *def`). `-z` — идемпотентный повтор на уже применённый ref.
  local st; st="$(git -C "$dir" diff --numstat -- "$HCI_CD_YAML_FILE")"
  [[ -z "$st" || "$st" == $'1\t1\t'* ]] || log::die "yq изменил не только строку образа в $HCI_CD_YAML_FILE ($st) — отказ. Полный диф:
$(git -C "$dir" diff -- "$HCI_CD_YAML_FILE")"

  git -C "$dir" add -- "$HCI_CD_YAML_FILE"
  git -C "$dir" diff --cached --quiet && { log::ok "cd:bump — уже актуально, пропускаю коммит"; return 0; }
  git -C "$dir" -c user.name="${HCI_CD_GIT_USER_NAME:-hyperion-ci}" -c user.email="${HCI_CD_GIT_USER_EMAIL:-ci@localhost}" \
    commit -m "deploy: $ref"
}

# cd_bump::classify_push_error ФАЙЛ -> retryable-reapply | retryable-plain | fatal
# Якорь `HTTP 50[0-9]`/`error: RPC failed`, а не голый `50[0-9]`: прогресс пуша печатает
# байтовые счётчики вида "503 bytes" и ложно матчился бы на каждом пуше.
cd_bump::classify_push_error() {
  local f="$1"
  if grep -qE 'non-fast-forward|fetch first|stale info' "$f"; then
    printf 'retryable-reapply'
  elif grep -qE 'unable to access|Could not resolve host|Connection (timed out|refused)|TLS|HTTP 50[0-9]|error: RPC failed|kex_exchange_identification' "$f"; then
    printf 'retryable-plain'
  else
    printf 'fatal'
  fi
}

cd_bump::push_with_retry() {
  local attempts="${HCI_RETRY_ATTEMPTS:-3}" delay="${HCI_RETRY_DELAY:-5}" try=1
  cd_bump::apply_commit
  while true; do
    # LC_ALL=C форсирует английские сообщения git: формулировка `non-fast-forward` локализуется
    # в части каталогов переводов, и классификатор не должен зависеть от локали раннера
    if LC_ALL=C git -C "$dir" -c credential.helper= push origin "HEAD:refs/heads/$branch" 2>"$HCI_TMP/push.err"; then
      log::ok "cd:bump — запушено в $url ($branch)"
      return 0
    fi
    cat "$HCI_TMP/push.err" >&2
    local kind; kind="$(cd_bump::classify_push_error "$HCI_TMP/push.err")"
    [[ "$kind" != "fatal" ]] || log::die "push не удался (не ретраится): $(cat "$HCI_TMP/push.err")"
    (( try < attempts )) || log::die "push не удался после $attempts попыток"
    log::warn "push конфликт/ошибка ($kind), попытка $try/$attempts, повтор через ${delay}с"
    sleep "$delay"
    # retryable-plain — сетевой блип: локальное состояние валидно, нужен ровно тот же push заново.
    # Только ref-конфликт требует fetch+reset+повторной правки.
    if [[ "$kind" == "retryable-reapply" ]]; then
      LC_ALL=C git -C "$dir" -c credential.helper= fetch origin "$branch"
      git -C "$dir" reset --hard "origin/$branch"
      cd_bump::apply_commit
    fi
    try=$((try + 1))
  done
}

step::cd_bump() {
  # kind=common — rt::setup для этого шага не вызывается; без явного bundle HTTPS-git
  # не проверит сертификат за корпоративным CA, без внятной ошибки
  tls::bundle >/dev/null
  ci::require git yq jq

  local url="${HCI_CD_GIT_URL:-}"
  [[ -n "$url" ]] || log::die "Не задана HCI_CD_GIT_URL"
  # userinfo в http(s) всегда означает встроенный credential; в ssh://user@host:port это
  # обязательная часть адреса, поэтому гейт сужен до http*://*@*. ${url,,} — схема регистронезависима
  # и для git, и по RFC 3986; без lowercase "HTTPS://tok@host" проходил бы гейт, а токен,
  # не зарегистрированный через log::mask (он же не в HCI_CD_GIT_TOKEN), утёк бы и в лог
  # (log::cmd на clone), и навечно в artifacts.json (manifest::add, expire="never").
  [[ "${url,,}" != http*://*@* ]] || log::die "HCI_CD_GIT_URL содержит credential в URL — используйте HCI_CD_GIT_TOKEN или HCI_CD_GIT_SSH_KEY"
  [[ -n "${HCI_CD_YAML_FILE:-}" ]] || log::die "Не задана HCI_CD_YAML_FILE"
  [[ -n "${HCI_CD_YAML_PATH:-}" ]] || log::die "Не задана HCI_CD_YAML_PATH"

  # image-ref вычисляется ОДИН раз, в $HCI_WORKDIR_ABS, до клона; дальше используется только $ref
  local ref
  if [[ -n "${HCI_CD_IMAGE:-}" ]]; then
    ref="$HCI_CD_IMAGE"
  else
    local mf; mf="$(manifest::file)"
    [[ -f "$mf" ]] || log::die "digest недоступен: нет $mf — добавьте image:publish в needs или задайте HCI_CD_IMAGE"
    # проверяем не только digest, но и .registry/.name — иначе null/app@sha256:... проходит все
    # три yq-гейта (они проверяют "легло туда, куда надо", не "осмысленно ли значение") и уезжает
    # в чужой репозиторий, ломаясь только на ImagePullBackOff в кластере
    ref="$(jq -er '[.artifacts[]|select(.type=="oci" and (.registry//""|length>0) and (.name//""|length>0) and (.digest//""|test("^sha256:[a-f0-9]{64}$")))]|last|select(.)|"\(.registry)/\(.name)@\(.digest)"' "$mf")" \
      || log::die "digest недоступен: в $mf нет валидной oci-записи (registry/name/digest)"
  fi

  # безусловно, не только в token-ветке auth() — иначе на ssh-пути или при вовсе отсутствующих
  # credential'ах сломанный обмен уводит git в интерактивный промпт, джоб висит до таймаута CI
  export GIT_TERMINAL_PROMPT=0
  [[ -n "${HCI_CD_GIT_TOKEN:-}${HCI_CD_GIT_SSH_KEY:-}" ]] \
    || log::die "Не задана ни HCI_CD_GIT_TOKEN, ни HCI_CD_GIT_SSH_KEY — push невозможен (проверьте, что переменная доступна на этом ref: protected-переменные не видны непротектед-тегам/веткам)"
  cd_bump::auth

  local dir="$HCI_TMP/gitops" branch="${HCI_CD_GIT_BRANCH:-}"
  # всегда свежий --depth 1 клон в $HCI_TMP: чекаут самого пайплайна не трогаем.
  # credential.helper= сбрасывает унаследованный из системного gitconfig хелпер, который
  # иначе осадил бы токен в ~/.git-credentials после успешного askpass-обмена
  # shellcheck disable=SC2086
  log::cmd git -c credential.helper= clone --depth 1 ${branch:+--branch "$branch"} "$url" "$dir"
  # имя ветки резолвится один раз: HCI_CD_GIT_BRANCH по умолчанию пуст (= remote HEAD),
  # и origin/<пусто> ниже не собралось бы
  branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD)"
  # detached HEAD (клон указал на тег, а не на ветку) даёт литеральное "HEAD" — push в
  # несуществующую refs/heads/HEAD создаст мусорную ветку в чужом репозитории
  [[ "$branch" != "HEAD" ]] || log::die "HCI_CD_GIT_URL указывает на тег/detached HEAD, не на ветку — задайте HCI_CD_GIT_BRANCH явно"
  [[ -f "$dir/$HCI_CD_YAML_FILE" ]] || log::die "нет $HCI_CD_YAML_FILE в репозитории (ветка $branch)"

  log::info "cd:bump — $HCI_CD_YAML_FILE: $HCI_CD_YAML_PATH = $ref"
  cd_bump::push_with_retry

  local slug sha
  slug="${url##*/}"
  slug="${slug%.git}"
  sha="$(git -C "$dir" rev-parse HEAD)"
  manifest::add generic "$slug" "$sha" "$url"
}
