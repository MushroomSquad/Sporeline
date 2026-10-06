#!/usr/bin/env bats
# Integration tests for cd:bump: step::cd_bump end-to-end against a real bare git repository
# (file:// transport) — happy path, push conflict (reapply/plain-retry), security negatives,
# the credential.helper= invariant on every clone/push (protection against ~/.git-credentials persistence).
# Unlike tests/unit/cd-bump.bats (individual functions, git mocked), this uses real git and
# a real repository — verifying their actual interaction through the whole step::cd_bump.

load ../unit/helper

REAL_GIT="$(command -v git)"

setup() {
  hci_clean_env
  BASEDIR="$(mktemp -d)"
  ORIGIN="$BASEDIR/origin.git"
  SEED="$BASEDIR/seed"
  WORKDIR="$BASEDIR/cwd"
  mkdir -p "$WORKDIR"

  git init -q --bare -b main "$ORIGIN"
  git init -q -b main "$SEED"
  mkdir -p "$SEED/deploy"
  printf 'image: registry.example/app@sha256:%s\n' "$(printf 'a%.0s' {1..64})" > "$SEED/deploy/app.yaml"
  git -C "$SEED" -c user.email=t@t -c user.name=t add deploy/app.yaml
  git -C "$SEED" -c user.email=t@t -c user.name=t commit -q -m seed
  git -C "$SEED" push -q "$ORIGIN" main

  cd "$WORKDIR" || return 1
  hci_source_libs
  # shellcheck source=/dev/null
  source "$HCI_HOME/steps/cd-bump.sh"

  export HCI_CD_GIT_URL="file://$ORIGIN"
  export HCI_CD_GIT_BRANCH=main
  export HCI_CD_YAML_FILE=deploy/app.yaml
  export HCI_CD_YAML_PATH=.image
  export HCI_CD_IMAGE="registry.example/app@sha256:$(printf 'b%.0s' {1..64})"
  export HCI_CD_GIT_TOKEN=UNIT-TEST-SECRET-TOKEN-ABCDEF
  export HCI_RETRY_DELAY=0
}

teardown() {
  cd / || true
  [[ -n "${BASEDIR:-}" ]] && rm -rf "$BASEDIR"
}

@test "integration: happy path — clone, правка, коммит и push в настоящий bare-репозиторий" {
  run step::cd_bump
  [ "$status" -eq 0 ]
  local check; check="$(mktemp -d)"
  git clone -q "file://$ORIGIN" "$check"
  grep -q "sha256:$(printf 'b%.0s' {1..64})" "$check/deploy/app.yaml"
  [[ -f "$(manifest::file)" ]]
  rm -rf "$check"
}

@test "integration: push-конфликт (fetch first) — fetch+reset+reapply восстанавливает и допушивает" {
  # A pre-receive hook rejects exactly the first push with a message from the retryable-reapply
  # classifier, simulating a race with another writer between the step's clone and its push.
  local flag="$BASEDIR/reject_once"
  cat > "$ORIGIN/hooks/pre-receive" <<HOOK
#!/bin/sh
if [ ! -f "$flag" ]; then
  touch "$flag"
  echo "fetch first" >&2
  exit 1
fi
exit 0
HOOK
  chmod +x "$ORIGIN/hooks/pre-receive"

  run step::cd_bump
  [ "$status" -eq 0 ]
  [[ "$output" == *"attempt 1/3"* ]]
  local check; check="$(mktemp -d)"
  git clone -q "file://$ORIGIN" "$check"
  grep -q "sha256:$(printf 'b%.0s' {1..64})" "$check/deploy/app.yaml"
  rm -rf "$check"
}

@test "integration: push-конфликт (сетевой блип) — plain-retry без fetch/reset, тот же коммит допушивается" {
  local shimdir="$BASEDIR/shim" calls="$BASEDIR/push_calls" fetches="$BASEDIR/fetch_calls"
  mkdir -p "$shimdir"; : > "$calls"; : > "$fetches"
  cat > "$shimdir/git" <<SHIM
#!/bin/bash
if [[ " \$* " == *" fetch "* ]]; then printf 'x\n' >> "$fetches"; fi
if [[ " \$* " == *" push "* ]]; then
  n=\$(wc -l < "$calls")
  printf 'x\n' >> "$calls"
  if [[ "\$n" -eq 0 ]]; then
    echo "Could not resolve host" >&2
    exit 1
  fi
fi
exec "$REAL_GIT" "\$@"
SHIM
  chmod +x "$shimdir/git"

  local oldpath="$PATH"
  export PATH="$shimdir:$PATH"
  run step::cd_bump
  export PATH="$oldpath"

  [ "$status" -eq 0 ]
  [ "$(wc -l < "$calls")" -eq 2 ]
  # plain-retry must not touch fetch/reset — only the reapply branch does that
  [ ! -s "$fetches" ]
  local check; check="$(mktemp -d)"
  "$REAL_GIT" clone -q "file://$ORIGIN" "$check"
  grep -q "sha256:$(printf 'b%.0s' {1..64})" "$check/deploy/app.yaml"
  rm -rf "$check"
}

@test "integration: security — гейт 1 (путь не найден) падает ДО push, токен не утекает в полный вывод" {
  export HCI_CD_YAML_PATH=.nonexistent.path
  run step::cd_bump
  [ "$status" -ne 0 ]
  [[ "$output" != *"UNIT-TEST-SECRET-TOKEN-ABCDEF"* ]]
}

@test "integration: security — push отклонён хуком навсегда (fatal, без ретрая), SSH-ключ не утекает" {
  unset HCI_CD_GIT_TOKEN
  export HCI_CD_GIT_SSH_KEY="-----BEGIN OPENSSH PRIVATE KEY-----
FAKE-KEY-MATERIAL-zzzz
-----END OPENSSH PRIVATE KEY-----"
  export HCI_CD_GIT_SSH_INSECURE=true
  cat > "$ORIGIN/hooks/pre-receive" <<'HOOK'
#!/bin/sh
echo "protected branch hook declined" >&2
exit 1
HOOK
  chmod +x "$ORIGIN/hooks/pre-receive"

  run step::cd_bump
  [ "$status" -ne 0 ]
  [[ "$output" != *"FAKE-KEY-MATERIAL-zzzz"* ]]
  # fatal classification isn't retried: the log must not contain a second attempt
  [[ "$output" != *"attempt 2"* ]]
}

@test "integration: credential.helper= передаётся git при clone и push (защита от персистентности в ~/.git-credentials)" {
  local shimdir="$BASEDIR/shim2" log="$BASEDIR/git_invocations.log"
  mkdir -p "$shimdir"; : > "$log"
  cat > "$shimdir/git" <<SHIM
#!/bin/bash
printf '%s\n' "\$*" >> "$log"
exec "$REAL_GIT" "\$@"
SHIM
  chmod +x "$shimdir/git"

  local oldpath="$PATH"
  export PATH="$shimdir:$PATH"
  run step::cd_bump
  export PATH="$oldpath"

  [ "$status" -eq 0 ]
  local clone_line push_line
  clone_line="$(grep -m1 ' clone ' "$log")"
  push_line="$(grep -m1 ' push ' "$log")"
  [[ -n "$clone_line" ]]
  [[ -n "$push_line" ]]
  [[ "$clone_line" == *"credential.helper="* ]]
  [[ "$push_line" == *"credential.helper="* ]]
}
