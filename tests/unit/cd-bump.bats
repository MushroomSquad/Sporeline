#!/usr/bin/env bats
# Юнит-тесты cd:bump: классификатор push-ошибок (с якорем HTTP 50[0-9] против
# ложного срабатывания на байтовый прогресс пуша), три yq-гейта apply_commit
# (включая регрессию на YAML merge-key `<<: *def` -> `!!merge <<: *def`),
# strenv-инъекция, askpass-контракт, URL-гейт на credential в HTTPS.

load helper

setup() {
  hci_setup_workdir
  hci_source_libs
  # shellcheck source=/dev/null
  source "$HCI_HOME/steps/cd-bump.sh"
}
teardown() { hci_teardown_workdir; }

# cd_bump::apply_commit баз vars (dir/ref/HCI_CD_YAML_FILE/HCI_CD_YAML_PATH) создаёт baseline-коммит
# с простым Deployment-манифестом в $WORKDIR (уже git-репозиторий из hci_setup_workdir).
_bump_baseline() {
  cat > "$WORKDIR/app.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      containers:
        - name: demo
          image: registry.local/demo:1.0.0
EOF
  git -C "$WORKDIR" add app.yaml
  git -C "$WORKDIR" commit -q -m baseline
}

# --- cd_bump::classify_push_error ---------------------------------------------------------

@test "classify_push_error: '[rejected] ... (fetch first)' -> retryable-reapply" {
  printf '%s\n' "! [rejected]        main -> main (fetch first)" > "$HCI_TMP/err"
  [ "$(cd_bump::classify_push_error "$HCI_TMP/err")" = "retryable-reapply" ]
}

@test "classify_push_error: non-fast-forward -> retryable-reapply" {
  printf '%s\n' "error: failed to push some refs" "hint: (non-fast-forward)" > "$HCI_TMP/err"
  [ "$(cd_bump::classify_push_error "$HCI_TMP/err")" = "retryable-reapply" ]
}

@test "classify_push_error: 'Could not resolve host' -> retryable-plain" {
  printf "fatal: unable to access 'https://x/y.git': Could not resolve host: x\n" > "$HCI_TMP/err"
  [ "$(cd_bump::classify_push_error "$HCI_TMP/err")" = "retryable-plain" ]
}

@test "classify_push_error: байтовый прогресс '503 bytes' не матчится как HTTP 50x (регрессия якоря)" {
  # Живой пример критика: прогресс пуша печатает "503 bytes", голый 50[0-9] ловил бы это как
  # retryable-plain. Якорь "HTTP 50[0-9]"/"error: RPC failed" не должен сработать на этот текст —
  # ни один из двух классов маркеров не совпадает, функция обязана вернуть fatal.
  printf '%s\n' \
    "Writing objects: 100% (3/3), 503 bytes | 503.00 KiB/s, done." \
    "remote: Permission denied" \
    > "$HCI_TMP/err"
  [ "$(cd_bump::classify_push_error "$HCI_TMP/err")" = "fatal" ]
}

@test "classify_push_error: pre-receive hook declined -> fatal" {
  printf '%s\n' "remote: pre-receive hook declined" > "$HCI_TMP/err"
  [ "$(cd_bump::classify_push_error "$HCI_TMP/err")" = "fatal" ]
}

@test "classify_push_error: Authentication failed -> fatal" {
  printf "fatal: Authentication failed for 'https://x/y.git'\n" > "$HCI_TMP/err"
  [ "$(cd_bump::classify_push_error "$HCI_TMP/err")" = "fatal" ]
}

# --- cd_bump::apply_commit: три yq-гейта ---------------------------------------------------

@test "apply_commit: happy path — single-doc YAML, меняется ровно одна строка" {
  _bump_baseline
  dir="$WORKDIR"
  ref="registry.local/demo:2.0.0"
  HCI_CD_YAML_FILE="app.yaml"
  HCI_CD_YAML_PATH=".spec.template.spec.containers[0].image"

  run cd_bump::apply_commit
  [ "$status" -eq 0 ]
  # закоммичено: ничего не осталось в staged diff, HEAD содержит новый ref
  git -C "$dir" diff --cached --quiet
  [[ "$(git -C "$dir" show HEAD:app.yaml)" == *"image: registry.local/demo:2.0.0"* ]]
  [ "$(git -C "$dir" log --oneline | wc -l)" -eq 2 ]
}

@test "apply_commit: гейт 1 — несуществующий путь падает ДО записи, файл не тронут" {
  _bump_baseline
  local before; before="$(cat "$WORKDIR/app.yaml")"
  dir="$WORKDIR"
  ref="registry.local/demo:2.0.0"
  HCI_CD_YAML_FILE="app.yaml"
  # индекс массива вне диапазона — типовая опечатка из живого эксплойта критика
  HCI_CD_YAML_PATH=".spec.template.spec.containers[5].image"

  run cd_bump::apply_commit
  [ "$status" -ne 0 ]
  [[ "$output" == *"не найден или пуст"* ]]
  [ "$(cat "$WORKDIR/app.yaml")" = "$before" ]
  git -C "$dir" diff --quiet -- app.yaml
  [ "$(git -C "$dir" log --oneline | wc -l)" -eq 1 ]
}

@test "apply_commit: гейт 3 — yq-переписывание YAML merge-key (<<: *def -> !!merge) отклоняется по numstat" {
  # Живой эксплойт критика раунда 5: yq корректно проставляет image, но заодно переписывает
  # соседний merge-key якорь. Гейты 1+2 (путь существует, значение верно) это пропускают —
  # ловит только гейт 3 (git diff --numstat != "1\t1\t").
  cat > "$WORKDIR/app.yaml" <<'EOF'
defs:
  commonLabels: &def
    app: demo
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo
spec:
  template:
    spec:
      containers:
        - name: demo
          <<: *def
          image: registry.local/demo:1.0.0
EOF
  git -C "$WORKDIR" add app.yaml
  git -C "$WORKDIR" commit -q -m baseline

  dir="$WORKDIR"
  ref="registry.local/demo:9.9.9"
  HCI_CD_YAML_FILE="app.yaml"
  HCI_CD_YAML_PATH='(select(.kind=="Deployment")|.spec.template.spec.containers[0].image)'

  run cd_bump::apply_commit
  [ "$status" -ne 0 ]
  # падение именно по причине numstat (гейт 3), не по какой-то другой — проверяем точный текст
  [[ "$output" == *"не только строку образа"* ]]
  # ничего не закоммичено и не застейджено из-за падения
  git -C "$dir" diff --cached --quiet
  [ "$(git -C "$dir" log --oneline | wc -l)" -eq 1 ]
}

@test "apply_commit: идемпотентность — повторный вызов с уже применённым ref проходит через гейт 3 (-z) и возвращает 0" {
  _bump_baseline
  dir="$WORKDIR"
  ref="registry.local/demo:2.0.0"
  HCI_CD_YAML_FILE="app.yaml"
  HCI_CD_YAML_PATH=".spec.template.spec.containers[0].image"

  run cd_bump::apply_commit
  [ "$status" -eq 0 ]
  [ "$(git -C "$dir" log --oneline | wc -l)" -eq 2 ]

  # второй вызов с тем же ref: working tree уже соответствует, numstat пуст -> гейт 3 проходит
  # по ветке "-z", git add ничего не меняет, diff --cached --quiet истинен -> return 0 без коммита
  run cd_bump::apply_commit
  [ "$status" -eq 0 ]
  [[ "$output" == *"уже актуально"* ]]
  [ "$(git -C "$dir" log --oneline | wc -l)" -eq 2 ]
}

# --- strenv-инъекция -----------------------------------------------------------------------

@test "apply_commit: strenv(REF) не даёт инъекцию — адверсариальное значение не создаёт лишних ключей" {
  _bump_baseline
  dir="$WORKDIR"
  # Живой эксплойт критика: значение с кавычкой и yq-выражением внутри. При интерполяции
  # "\"$ref\"" вместо strenv(REF) это сломало бы само выражение yq и создало бы ключ .pwned.
  ref='x" , .pwned = "yes'
  HCI_CD_YAML_FILE="app.yaml"
  HCI_CD_YAML_PATH=".spec.template.spec.containers[0].image"

  run cd_bump::apply_commit
  [ "$status" -eq 0 ]
  [ "$(yq '.pwned' "$WORKDIR/app.yaml")" = "null" ]
  [[ "$(yq '.spec.template.spec.containers[0].image' "$WORKDIR/app.yaml")" == "$ref" ]]
}

# --- askpass-контракт ------------------------------------------------------------------------

@test "auth: askpass-скрипт — Username и Password дают разные значения, токен не светится в username-вызове" {
  export HCI_CD_GIT_USER=myuser HCI_CD_GIT_TOKEN=supersecrettoken
  cd_bump::auth

  [ -f "$HCI_TMP/askpass.sh" ]
  local u p
  u="$(sh "$HCI_TMP/askpass.sh" "Username for 'https://host'")"
  p="$(sh "$HCI_TMP/askpass.sh" "Password for 'https://oauth2@host'")"

  [ "$u" = "myuser" ]
  [ "$p" = "supersecrettoken" ]
  [ "$u" != "$p" ]
  [[ "$u" != *"supersecrettoken"* ]]
}

# --- URL-гейт на credential в HTTPS ----------------------------------------------------------

@test "URL-гейт: https://user:pass@host отклоняется, ssh://git@host:порт — нет" {
  local url
  url='https://user:pass@host/group/repo.git'
  [[ "$url" == http*://*@* ]]     # гейт должен сработать (die в реальном коде)

  url='ssh://git@host:2222/group/repo.git'
  [[ "$url" != http*://*@* ]]     # нестандартный SSH-порт с userinfo — легитимен, не отклоняется

  url='https://host/group/repo.git'
  [[ "$url" != http*://*@* ]]     # обычный HTTPS без credential — тоже проходит
}

@test "URL-гейт: HTTPS:// в верхнем регистре тоже отклоняется (регрессия code-review HIGH-2)" {
  local url='HTTPS://tok@127.0.0.1/x.git'
  [[ "$url" != http*://*@* ]]     # без ${url,,} голый паттерн бы пропустил — это и есть баг
  [[ "${url,,}" == http*://*@* ]] # с нормализацией регистра гейт срабатывает верно
}
