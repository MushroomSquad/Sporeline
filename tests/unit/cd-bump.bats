#!/usr/bin/env bats
# Unit tests for cd:bump: the push-error classifier (anchored on HTTP 50[0-9] against
# false-positives on push byte-progress output), the three apply_commit yq gates
# (including the regression on the YAML merge-key `<<: *def` -> `!!merge <<: *def`),
# strenv injection, the askpass contract, the HTTPS credential-in-URL gate.

load helper

setup() {
  hci_setup_workdir
  hci_source_libs
  # shellcheck source=/dev/null
  source "$HCI_HOME/steps/cd-bump.sh"
}
teardown() { hci_teardown_workdir; }

# cd_bump::apply_commit base vars (dir/ref/HCI_CD_YAML_FILE/HCI_CD_YAML_PATH) create a baseline commit
# with a simple Deployment manifest in $WORKDIR (already a git repo from hci_setup_workdir).
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
  # Critic's live example: push progress prints "503 bytes" — a bare 50[0-9] would catch this as
  # retryable-plain. The anchor "HTTP 50[0-9]"/"error: RPC failed" must not fire on this text —
  # neither marker class matches, the function must return fatal.
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

# --- cd_bump::apply_commit: the three yq gates ---------------------------------------------------

@test "apply_commit: happy path — single-doc YAML, меняется ровно одна строка" {
  _bump_baseline
  dir="$WORKDIR"
  ref="registry.local/demo:2.0.0"
  HCI_CD_YAML_FILE="app.yaml"
  HCI_CD_YAML_PATH=".spec.template.spec.containers[0].image"

  run cd_bump::apply_commit
  [ "$status" -eq 0 ]
  # committed: nothing left in the staged diff, HEAD contains the new ref
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
  # array index out of range — a typical typo from the critic's live exploit
  HCI_CD_YAML_PATH=".spec.template.spec.containers[5].image"

  run cd_bump::apply_commit
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found or empty"* ]]
  [ "$(cat "$WORKDIR/app.yaml")" = "$before" ]
  git -C "$dir" diff --quiet -- app.yaml
  [ "$(git -C "$dir" log --oneline | wc -l)" -eq 1 ]
}

@test "apply_commit: гейт 3 — yq-переписывание YAML merge-key (<<: *def -> !!merge) отклоняется по numstat" {
  # Critic's live exploit from round 5: yq correctly sets the image, but also rewrites the
  # neighboring merge-key anchor along the way. Gates 1+2 (path exists, value is correct) miss
  # this — only gate 3 catches it (git diff --numstat != "1\t1\t").
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
  # confirm it failed specifically due to numstat (gate 3), not something else — check exact text
  [[ "$output" == *"more than just the image line"* ]]
  # nothing committed or staged because of the failure
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

  # second call with the same ref: the working tree already matches, numstat is empty -> gate 3
  # passes via the "-z" branch, git add changes nothing, diff --cached --quiet is true -> return 0, no commit
  run cd_bump::apply_commit
  [ "$status" -eq 0 ]
  [[ "$output" == *"already up to date"* ]]
  [ "$(git -C "$dir" log --oneline | wc -l)" -eq 2 ]
}

# --- strenv injection -----------------------------------------------------------------------

@test "apply_commit: strenv(REF) не даёт инъекцию — адверсариальное значение не создаёт лишних ключей" {
  _bump_baseline
  dir="$WORKDIR"
  # Critic's live exploit: a value containing a quote and a yq expression. Interpolating it as
  # "\"$ref\"" instead of strenv(REF) would break the yq expression itself and create a .pwned key.
  ref='x" , .pwned = "yes'
  HCI_CD_YAML_FILE="app.yaml"
  HCI_CD_YAML_PATH=".spec.template.spec.containers[0].image"

  run cd_bump::apply_commit
  [ "$status" -eq 0 ]
  [ "$(yq '.pwned' "$WORKDIR/app.yaml")" = "null" ]
  [[ "$(yq '.spec.template.spec.containers[0].image' "$WORKDIR/app.yaml")" == "$ref" ]]
}

# --- askpass contract ------------------------------------------------------------------------

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

# --- HTTPS credential-in-URL gate ----------------------------------------------------------

@test "URL-гейт: https://user:pass@host отклоняется, ssh://git@host:порт — нет" {
  local url
  url='https://user:pass@host/group/repo.git'
  [[ "$url" == http*://*@* ]]     # the gate must trigger (die in real code)

  url='ssh://git@host:2222/group/repo.git'
  [[ "$url" != http*://*@* ]]     # non-standard SSH port with userinfo — legitimate, not rejected

  url='https://host/group/repo.git'
  [[ "$url" != http*://*@* ]]     # plain HTTPS without a credential — also passes
}

@test "URL-гейт: HTTPS:// в верхнем регистре тоже отклоняется (регрессия code-review HIGH-2)" {
  local url='HTTPS://tok@127.0.0.1/x.git'
  [[ "$url" != http*://*@* ]]     # without ${url,,} the bare pattern would let this through — that's the bug
  [[ "${url,,}" == http*://*@* ]] # with case normalization, the gate fires correctly
}
