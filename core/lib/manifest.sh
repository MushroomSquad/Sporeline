# shellcheck shell=bash
# Manifest of published artifacts (schemaVersion 2), see core/schema/artifacts.v2.json.

HCI_MANIFEST_TYPES=(oci maven npm nuget pypi cargo helm composer generic)

manifest::file() {
  printf '%s/artifacts.json' "${HCI_OUT_DIR:-hci-artifacts}"
}

manifest::init() {
  local file
  file="$(manifest::file)"
  mkdir -p "$(dirname "$file")"
  [[ -f "$file" ]] && return 0
  jq -n \
    --arg ci "${HCI_CI:-local}" \
    --arg id "${HCI_PIPELINE_ID:-}" \
    --arg job "${HCI_JOB_ID:-}" \
    --arg sha "${HCI_SHA:-}" \
    --arg ref "${HCI_REF:-}" \
    --arg project "${HCI_PROJECT_PATH:-}" \
    --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schemaVersion: 2,
      pipeline: {ci: $ci, id: $id, job: $job, sha: $sha, ref: $ref, project: $project, created: $created},
      artifacts: []}' > "$file"
}

manifest::_uri() { jq -rn --arg s "$1" '$s|@uri'; }

# manifest::purl TYPE NAME VERSION [DIGEST] [REGISTRY]
manifest::purl() {
  local type="$1" name="$2" version="$3" digest="${4:-}" registry="${5:-}"
  case "$type" in
    oci)
      local base="${name##*/}"
      printf 'pkg:oci/%s@%s?repository_url=%s&tag=%s' "${base,,}" "$(manifest::_uri "$digest")" "$(manifest::_uri "$registry/$name")" "$(manifest::_uri "$version")"
      ;;
    maven) printf 'pkg:maven/%s/%s@%s' "${name%%:*}" "${name#*:}" "$(manifest::_uri "$version")" ;;
    npm)
      if [[ "$name" == @*/* ]]; then
        printf 'pkg:npm/%s/%s@%s' "$(manifest::_uri "${name%%/*}")" "${name#*/}" "$(manifest::_uri "$version")"
      else
        printf 'pkg:npm/%s@%s' "$name" "$(manifest::_uri "$version")"
      fi
      ;;
    pypi)
      local n="${name,,}"
      printf 'pkg:pypi/%s@%s' "${n//_/-}" "$(manifest::_uri "$version")"
      ;;
    composer) printf 'pkg:composer/%s@%s' "${name,,}" "$(manifest::_uri "$version")" ;;
    nuget | cargo) printf 'pkg:%s/%s@%s' "$type" "$name" "$(manifest::_uri "$version")" ;;
    *) printf 'pkg:generic/%s@%s' "$(manifest::_uri "$name")" "$(manifest::_uri "$version")" ;;
  esac
}

# manifest::add TYPE NAME VERSION REGISTRY [key=value ...]
# true/false values are written as booleans.
manifest::add() {
  local type="$1" name="$2" version="$3" registry="$4"
  shift 4
  local known=0 t
  for t in "${HCI_MANIFEST_TYPES[@]}"; do [[ "$t" == "$type" ]] && known=1; done
  (( known )) || log::die "manifest::add: неизвестный тип '$type'"
  [[ -n "$name" && -n "$version" ]] || log::die "manifest::add: пустое имя или версия ($type '$name' '$version')"

  local digest="" kv
  for kv in "$@"; do [[ "$kv" == digest=* ]] && digest="${kv#digest=}"; done

  local obj
  obj="$(jq -n --arg type "$type" --arg name "$name" --arg version "$version" --arg registry "$registry" \
    --arg purl "$(manifest::purl "$type" "$name" "$version" "$digest" "$registry")" \
    '{type: $type, name: $name, version: $version, registry: $registry, purl: $purl}')"
  for kv in "$@"; do
    obj="$(jq --arg k "${kv%%=*}" --arg v "${kv#*=}" \
      '. + {($k): (if $v == "true" then true elif $v == "false" then false else $v end)}' <<< "$obj")"
  done

  manifest::init
  local file tmp
  file="$(manifest::file)"
  tmp="$(mktemp)"
  jq --argjson a "$obj" '.artifacts += [$a]' "$file" > "$tmp" && mv "$tmp" "$file"
  log::ok "Артефакт: $type $name@$version"
}

manifest::validate() {
  local file="${1:-$(manifest::file)}"
  [[ -f "$file" ]] || log::die "Манифест не найден: $file"
  jq -e --argjson types "$(printf '%s\n' "${HCI_MANIFEST_TYPES[@]}" | jq -R . | jq -s .)" '
    .schemaVersion == 2
    and (.pipeline | type == "object")
    and (.artifacts | type == "array")
    and all(.artifacts[];
      (.type as $t | $types | index($t) != null)
      and (.name | type == "string" and length > 0)
      and (.version | type == "string" and length > 0)
      and (.registry | type == "string")
      and (.purl | type == "string" and startswith("pkg:"))
      and (if .type == "oci" then (.digest | type == "string" and test("^sha256:[a-f0-9]{64}$")) else true end))
  ' "$file" >/dev/null || log::die "Манифест $file не соответствует схеме v2"
  log::ok "Манифест $file корректен ($(jq '.artifacts | length' "$file") артефактов)"
}
