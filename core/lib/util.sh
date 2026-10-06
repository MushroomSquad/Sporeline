# shellcheck shell=bash
# Shared utilities.

readonly HCI_SKIP_CODE=86

ci::is_true() {
  case "${1,,}" in
    1 | true | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

# ci::split ARRAY_NAME STRING — splits on newlines and commas, trims whitespace.
ci::split() {
  local -n _split_out="$1"
  local _raw="${2:-}" _item
  _split_out=()
  _raw="${_raw//,/$'\n'}"
  while IFS= read -r _item; do
    _item="${_item#"${_item%%[![:space:]]*}"}"
    _item="${_item%"${_item##*[![:space:]]}"}"
    [[ -n "$_item" ]] && _split_out+=("$_item")
  done <<< "$_raw"
  return 0
}

# ci::split_lines ARRAY_NAME STRING — splits only on newlines (for KEY=VALUE).
ci::split_lines() {
  local -n _lines_out="$1"
  local _raw="${2:-}" _item
  _lines_out=()
  while IFS= read -r _item; do
    _item="${_item#"${_item%%[![:space:]]*}"}"
    [[ -n "$_item" ]] && _lines_out+=("$_item")
  done <<< "$_raw"
  return 0
}

# ci::words ARRAY_NAME STRING — splits on whitespace (for extra arguments).
ci::words() {
  local -n _words_out="$1"
  _words_out=()
  [[ -n "${2:-}" ]] || return 0
  read -r -a _words_out <<< "$2"
}

ci::require() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || log::die "Tool '$cmd' not found. Use an image that has it, or set a different image for the job."
  done
}

ci::has() { command -v "$1" >/dev/null 2>&1; }

# Skips the step: prints the reason and exits with the skip code.
ci::skip() {
  log::info "Step skipped: $*"
  exit "$HCI_SKIP_CODE"
}

ci::slug() {
  local s="${1,,}"
  s="${s//[^a-z0-9]/-}"
  while [[ "$s" == *--* ]]; do s="${s//--/-}"; done
  s="${s#-}"
  printf '%s' "${s%-}"
}

# Substitutes ${VAR} in a string from trusted files (meta.yaml, defaults.env).
ci::expand() {
  local __s="$1"
  __s="${__s//\\/\\\\}"
  __s="${__s//\"/\\\"}"
  __s="${__s//\`/\\\`}"
  eval "printf '%s' \"$__s\""
}

ci::yaml_to_json() {
  local file="$1"
  if ci::has yq && yq --version 2>&1 | grep -qi mikefarah; then
    yq -o=json '.' "$file"
  elif ci::has python3 && python3 -c 'import yaml' 2>/dev/null; then
    python3 -c 'import json, sys, yaml; json.dump(yaml.safe_load(open(sys.argv[1])) or {}, sys.stdout)' "$file"
  else
    log::die "Reading $file requires yq (mikefarah) or python3 with PyYAML"
  fi
}

ci::meta_file() {
  printf '%s/runtimes/%s/meta.yaml' "$HCI_HOME" "${1:-$HCI_RUNTIME}"
}

# ci::meta JQ_EXPRESSION [RUNTIME] — reads a field from the runtime's meta.yaml.
ci::meta() {
  local expr="$1" file
  file="$(ci::meta_file "${2:-}")"
  [[ -f "$file" ]] || return 1
  ci::yaml_to_json "$file" | jq -r "$expr // empty"
}

# Runtime image from meta.yaml: ci::meta_image build|runtime|sonar|svace [version]
ci::meta_image() {
  local kind="$1" version="${2:-${HCI_RUNTIME_VERSION:-}}" raw
  [[ -n "$version" ]] || version="$(ci::meta '.default_version')"
  raw="$(ci::meta ".versions[] | select(.id == \"$version\") | .$kind")"
  [[ -n "$raw" ]] || raw="$(ci::meta ".images.$kind")"
  [[ -n "$raw" && "$raw" != "build" ]] || return 1
  ci::expand "$raw"
}

ci::xml_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  s="${s//\'/&apos;}"
  printf '%s' "$s"
}

# First existing file from a list of glob patterns (or exit code 1).
ci::first_file() {
  local p f
  shopt -s nullglob globstar
  for p in "$@"; do
    for f in $p; do
      [[ -f "$f" ]] && { shopt -u nullglob globstar; printf '%s' "$f"; return 0; }
    done
  done
  shopt -u nullglob globstar
  return 1
}

# All existing files matching the glob patterns, comma-joined.
ci::glob_join() {
  local p f out=()
  shopt -s nullglob globstar
  for p in "$@"; do
    for f in $p; do [[ -e "$f" ]] && out+=("$f"); done
  done
  shopt -u nullglob globstar
  local IFS=,
  printf '%s' "${out[*]}"
}

ci::pkg_json() {
  local expr="$1" file="${2:-package.json}"
  [[ -f "$file" ]] || return 1
  jq -r "$expr // empty" "$file"
}

ci::json_escape() {
  jq -Rn --arg s "$1" '$s'
}
