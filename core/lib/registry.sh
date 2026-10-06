# shellcheck shell=bash
# Artifact registries. For each type (OCI, OCI_PUSH, MAVEN, NPM, NUGET, PYPI, CARGO, GO, HELM, COMPOSER)
# the fields are HCI_REGISTRY_<TYPE>_{HOST,USER,PASSWORD,PULL_REPO,REPO,SNAPSHOT_REPO}; missing
# HOST/USER/PASSWORD fall back to the shared HCI_REGISTRY_{HOST,USER,PASSWORD}.

registry::_field() {
  local type="${1^^}" field="${2^^}" name
  name="HCI_REGISTRY_${type}_${field}"
  if [[ -n "${!name:-}" ]]; then
    printf '%s' "${!name}"
    return 0
  fi
  case "$field" in
    HOST | USER | PASSWORD)
      name="HCI_REGISTRY_${field}"
      printf '%s' "${!name:-}"
      ;;
  esac
}

registry::host() { registry::_field "$1" HOST; }
registry::has() { [[ -n "$(registry::host "$1")" ]]; }
registry::user() { registry::_field "$1" USER; }
registry::password() { registry::_field "$1" PASSWORD; }
registry::scheme() { printf '%s' "${HCI_REGISTRY_SCHEME:-https}"; }
registry::is_insecure() { [[ "$(registry::scheme)" == "http" ]] || ci::is_true "${HCI_TLS_INSECURE:-false}"; }

# registry::url TYPE [pull|push|snapshot] -> scheme://host/repo
registry::url() {
  local type="$1" kind="${2:-pull}" host repo field
  host="$(registry::host "$type")"
  [[ -n "$host" ]] || log::die "Registry host not set for $type (HCI_REGISTRY_${type^^}_HOST or HCI_REGISTRY_HOST)"
  case "$kind" in
    pull) field=PULL_REPO ;;
    push) field=REPO ;;
    snapshot) field=SNAPSHOT_REPO ;;
    *) log::die "registry::url: unknown kind '$kind'" ;;
  esac
  repo="$(registry::_field "$type" "$field")"
  printf '%s://%s%s' "$(registry::scheme)" "$host" "${repo:+/$repo}"
}

# URL with embedded credentials (for tools that can't do separate auth).
registry::url_with_auth() {
  local type="$1" kind="${2:-pull}" url user pass
  url="$(registry::url "$type" "$kind")"
  user="$(registry::user "$type")"
  pass="$(registry::password "$type")"
  if [[ -n "$user" ]]; then
    local scheme="${url%%://*}" rest="${url#*://}"
    url="${scheme}://$(jq -rn --arg s "$user" '$s|@uri'):$(jq -rn --arg s "$pass" '$s|@uri')@${rest}"
  fi
  printf '%s' "$url"
}

# curl config with credentials passed via stdin (curl -K -), so the password never reaches ps.
registry::curl_auth() {
  local cred
  cred="$(registry::user "$1"):$(registry::password "$1")"
  cred="${cred//\\/\\\\}"
  printf 'user = "%s"\n' "${cred//\"/\\\"}"
}

registry::_containers_conf_dir() {
  printf '%s/containers' "${XDG_CONFIG_HOME:-${HOME:-/tmp}/.config}"
}

# Configures TLS/insecure for an OCI registry (buildah, skopeo, podman).
registry::oci_trust() {
  local host="$1" dir
  [[ -n "$host" ]] || return 0
  dir="$(registry::_containers_conf_dir)"
  mkdir -p "$dir"
  if registry::is_insecure; then
    if ! grep -qs "location = \"$host\"" "$dir/registries.conf"; then
      printf '[[registry]]\nlocation = "%s"\ninsecure = true\n\n' "$host" >> "$dir/registries.conf"
    fi
  elif [[ -n "${HCI_CA_BUNDLE:-}" && -f "$HCI_CA_BUNDLE" ]]; then
    mkdir -p "$dir/certs.d/$host"
    cp -f "$HCI_CA_BUNDLE" "$dir/certs.d/$host/ca.crt"
  fi
}

registry::_oci_login_once() {
  local tool="$1" host="$2" user="$3" pass="$4"
  "$tool" login --authfile "$REGISTRY_AUTH_FILE" -u "$user" --password-stdin "$host" <<< "$pass" >/dev/null
}

# registry::oci_login TYPE (OCI or OCI_PUSH)
registry::oci_login() {
  local type="$1" host user pass tool
  host="$(registry::host "$type")"
  user="$(registry::user "$type")"
  pass="$(registry::password "$type")"
  [[ -n "$host" ]] || { log::warn "Registry host $type not set, skipping authentication"; return 0; }
  export REGISTRY_AUTH_FILE="${REGISTRY_AUTH_FILE:-$HCI_TMP/auth.json}"
  registry::oci_trust "$host"
  if [[ -z "$user" ]]; then
    log::warn "No credentials for $host, proceeding anonymously"
    return 0
  fi
  for tool in buildah skopeo podman; do
    ci::has "$tool" && break
    tool=""
  done
  [[ -n "$tool" ]] || log::die "No buildah/skopeo/podman available to authenticate to $host"
  retry registry::_oci_login_once "$tool" "$host" "$user" "$pass"
  log::info "Authenticated to $host ($tool)"
}
