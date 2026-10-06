# shellcheck shell=bash
# cd:bump — edits an image-ref in a GitOps repository: clone --depth 1 -> yq -> commit -> push with retry.
# Secrets (HTTPS token, SSH key) never land in the URL, in argv, or on disk outside $HCI_TMP.

# cd_bump::secret_file VALUE PATH — prints the path to the file.
# VALUE can be either a path to an existing file OR the content itself (a File-type CI
# variable or a plain one). Content is written in a subshell under umask 077: mode 0600
# from the moment of creation, no window between the write and a separate chmod.
cd_bump::secret_file() {
  local v="$1" f="$2"
  if [[ -f "$v" ]]; then printf '%s' "$v"; return 0; fi
  (umask 077; printf '%s\n' "$v" > "$f")
  printf '%s' "$f"
}

# Sets up git authentication before the clone (the clone itself already needs it).
cd_bump::auth() {
  if [[ -n "${HCI_CD_GIT_TOKEN:-}" ]]; then
    log::mask "$HCI_CD_GIT_TOKEN"
    # oauth2 default is GitLab's convention; GitHub App expects x-access-token,
    # Bitbucket — x-token-auth; the operator overrides via HCI_CD_GIT_USER
    export HCI_CD_GIT_USER="${HCI_CD_GIT_USER:-oauth2}"
    export HCI_CD_GIT_TOKEN
    local askpass="$HCI_TMP/askpass.sh"
    # git calls askpass TWICE with a different $1 (Username..., Password...). Printing the
    # token unconditionally leaks it into the second prompt: the first prompt's answer becomes
    # part of the second prompt's text, i.e. it ends up in the askpass process's argv, visible via ps.
    cat > "$askpass" <<'EOF'
#!/bin/sh
case "$1" in
  Username*) printf '%s\n' "$HCI_CD_GIT_USER" ;;
  *) printf '%s\n' "$HCI_CD_GIT_TOKEN" ;;
esac
EOF
    chmod 700 "$askpass"
    # GIT_TERMINAL_PROMPT=0 is mandatory: without it, a broken askpass sends git into an
    # interactive prompt, and the job hangs until the CI timeout instead of failing fast.
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
      log::die "HCI_CD_GIT_SSH_KNOWN_HOSTS is not set (path or content). Get the host key: ssh-keyscan -H <host>; or explicitly set HCI_CD_GIT_SSH_INSECURE=true"
    fi
    opts="-i $key -o IdentitiesOnly=yes -o BatchMode=yes -o UserKnownHostsFile=$kh"
    [[ "$insecure" == true ]] && opts+=" -o StrictHostKeyChecking=accept-new"
    export GIT_SSH_COMMAND="ssh $opts"
  fi
}

# Edits the manifest + commits. Called on every iteration of the retry loop with $ref already computed.
cd_bump::apply_commit() {
  local f="$dir/$HCI_CD_YAML_FILE"
  # For multi-document YAML (several `---`-separated manifests in one file, typical for
  # Argo/Flux), HCI_CD_YAML_PATH must be select-guarded, otherwise gate 1 could match the
  # wrong document: select(.kind=="Deployment").spec.template.spec.containers[0].image

  # Gate 1 — the path exists and is non-empty BEFORE the write. Catches a typo in the path or a
  # wrong array index: `yq -i '<path> = ...'` on a non-existent path doesn't fail, it creates the path and exits 0.
  yq -e "$HCI_CD_YAML_PATH" "$f" >/dev/null 2>&1 || log::die "path $HCI_CD_YAML_PATH not found or empty in $HCI_CD_YAML_FILE"
  # strenv(REF), not "\"$ref\"" interpolation: a value containing a quote or $ would alter the yq expression itself
  REF="$ref" yq -i "$HCI_CD_YAML_PATH = strenv(REF)" "$f"
  # Gate 2 — the edit landed exactly where intended (the path could have matched the wrong thing)
  [[ "$(yq "$HCI_CD_YAML_PATH" "$f")" == "$ref" ]] || log::die "edit didn't apply: $HCI_CD_YAML_PATH ≠ $ref"
  # Gate 3 — yq touched nothing but the image line. Gates 1+2 only look at one path and miss
  # collateral rewrites of neighboring lines (a real example: a merge-key `<<: *def`
  # turns into `!!merge <<: *def`). `-z` makes a repeat call on an already-applied ref idempotent.
  local st; st="$(git -C "$dir" diff --numstat -- "$HCI_CD_YAML_FILE")"
  [[ -z "$st" || "$st" == $'1\t1\t'* ]] || log::die "yq changed more than just the image line in $HCI_CD_YAML_FILE ($st) — aborting. Full diff:
$(git -C "$dir" diff -- "$HCI_CD_YAML_FILE")"

  git -C "$dir" add -- "$HCI_CD_YAML_FILE"
  git -C "$dir" diff --cached --quiet && { log::ok "cd:bump — already up to date, skipping commit"; return 0; }
  git -C "$dir" -c user.name="${HCI_CD_GIT_USER_NAME:-hyperion-ci}" -c user.email="${HCI_CD_GIT_USER_EMAIL:-ci@localhost}" \
    commit -m "deploy: $ref"
}

# cd_bump::classify_push_error FILE -> retryable-reapply | retryable-plain | fatal
# Anchored on `HTTP 50[0-9]`/`error: RPC failed`, not bare `50[0-9]`: push progress output prints
# byte counters like "503 bytes" and would false-match on every push otherwise.
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
    # LC_ALL=C forces English git messages: the `non-fast-forward` wording is localized in
    # some translation catalogs, and the classifier must not depend on the runner's locale
    if LC_ALL=C git -C "$dir" -c credential.helper= push origin "HEAD:refs/heads/$branch" 2>"$HCI_TMP/push.err"; then
      log::ok "cd:bump — pushed to $url ($branch)"
      return 0
    fi
    cat "$HCI_TMP/push.err" >&2
    local kind; kind="$(cd_bump::classify_push_error "$HCI_TMP/push.err")"
    [[ "$kind" != "fatal" ]] || log::die "push failed (not retrying): $(cat "$HCI_TMP/push.err")"
    (( try < attempts )) || log::die "push failed after $attempts attempts"
    log::warn "push conflict/error ($kind), attempt $try/$attempts, retrying in ${delay}s"
    sleep "$delay"
    # retryable-plain — a network blip: local state is valid, the exact same push just needs
    # to be retried. Only a ref conflict requires fetch+reset+reapplying the edit.
    if [[ "$kind" == "retryable-reapply" ]]; then
      LC_ALL=C git -C "$dir" -c credential.helper= fetch origin "$branch"
      git -C "$dir" reset --hard "origin/$branch"
      cd_bump::apply_commit
    fi
    try=$((try + 1))
  done
}

step::cd_bump() {
  # kind=common — rt::setup isn't called for this step; without an explicit bundle, HTTPS git
  # wouldn't verify the certificate behind a corporate CA, and without a clear error either.
  tls::bundle >/dev/null
  ci::require git yq jq

  local url="${HCI_CD_GIT_URL:-}"
  [[ -n "$url" ]] || log::die "HCI_CD_GIT_URL is not set"
  # userinfo in http(s) always means an embedded credential; in ssh://user@host:port it's a
  # mandatory part of the address, so the gate is narrowed to http*://*@*. ${url,,} makes the
  # scheme case-insensitive, both for git and per RFC 3986; without lowercasing, "HTTPS://tok@host"
  # would pass the gate, and the token — never registered via log::mask (it isn't in
  # HCI_CD_GIT_TOKEN) — would leak both into the log (log::cmd on clone) and permanently
  # into artifacts.json (manifest::add, expire="never")
  [[ "${url,,}" != http*://*@* ]] || log::die "HCI_CD_GIT_URL contains a credential in the URL — use HCI_CD_GIT_TOKEN or HCI_CD_GIT_SSH_KEY instead"
  [[ -n "${HCI_CD_YAML_FILE:-}" ]] || log::die "HCI_CD_YAML_FILE is not set"
  [[ -n "${HCI_CD_YAML_PATH:-}" ]] || log::die "HCI_CD_YAML_PATH is not set"

  # The image-ref is computed ONCE, in $HCI_WORKDIR_ABS, before the clone; only $ref is used after that
  local ref
  if [[ -n "${HCI_CD_IMAGE:-}" ]]; then
    ref="$HCI_CD_IMAGE"
  else
    local mf; mf="$(manifest::file)"
    [[ -f "$mf" ]] || log::die "digest unavailable: $mf not found — add image:publish to needs or set HCI_CD_IMAGE"
    # Validate not just the digest but also .registry/.name — otherwise null/app@sha256:... would
    # pass all three yq gates (they check "did it land where intended", not "is the value
    # meaningful") and ship off to the wrong repository, only breaking as ImagePullBackOff in the cluster
    ref="$(jq -er '[.artifacts[]|select(.type=="oci" and (.registry//""|length>0) and (.name//""|length>0) and (.digest//""|test("^sha256:[a-f0-9]{64}$")))]|last|select(.)|"\(.registry)/\(.name)@\(.digest)"' "$mf")" \
      || log::die "digest unavailable: no valid oci entry (registry/name/digest) in $mf"
  fi

  # Unconditional, not just in the token branch of auth() — otherwise on the ssh path, or with
  # no credentials at all, a broken exchange sends git into an interactive prompt and the job
  # hangs until the CI timeout.
  export GIT_TERMINAL_PROMPT=0
  [[ -n "${HCI_CD_GIT_TOKEN:-}${HCI_CD_GIT_SSH_KEY:-}" ]] \
    || log::die "Neither HCI_CD_GIT_TOKEN nor HCI_CD_GIT_SSH_KEY is set — push is not possible (check that the variable is available on this ref: protected variables aren't visible to unprotected tags/branches)"
  cd_bump::auth

  local dir="$HCI_TMP/gitops" branch="${HCI_CD_GIT_BRANCH:-}"
  # Always a fresh --depth 1 clone into $HCI_TMP: the pipeline's own checkout is left untouched.
  # credential.helper= resets any helper inherited from the system gitconfig, which would
  # otherwise deposit the token into ~/.git-credentials after a successful askpass exchange
  # shellcheck disable=SC2086
  log::cmd git -c credential.helper= clone --depth 1 ${branch:+--branch "$branch"} "$url" "$dir"
  # The branch name is resolved once: HCI_CD_GIT_BRANCH defaults to empty (= remote HEAD),
  # and origin/<empty> below wouldn't resolve to anything
  branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD)"
  # Detached HEAD (the clone pointed at a tag, not a branch) yields the literal "HEAD" — pushing
  # to a non-existent refs/heads/HEAD would create a garbage branch in someone else's repository
  [[ "$branch" != "HEAD" ]] || log::die "HCI_CD_GIT_URL points at a tag/detached HEAD, not a branch — set HCI_CD_GIT_BRANCH explicitly"
  [[ -f "$dir/$HCI_CD_YAML_FILE" ]] || log::die "$HCI_CD_YAML_FILE not found in the repository (branch $branch)"

  log::info "cd:bump — $HCI_CD_YAML_FILE: $HCI_CD_YAML_PATH = $ref"
  cd_bump::push_with_retry

  local slug sha
  slug="${url##*/}"
  slug="${slug%.git}"
  sha="$(git -C "$dir" rev-parse HEAD)"
  manifest::add generic "$slug" "$sha" "$url"
}
