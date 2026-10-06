# shellcheck shell=bash
# Image build. Modes (HCI_IMAGE_BUILD_MODE):
#   auto        dockerfile if a Containerfile/Dockerfile exists, otherwise the runtime's HCI_IMAGE_DEFAULT_MODE
#   base        HCI_RUNTIME_IMAGE + HCI_IMAGE_CONTEXT contents + HCI_IMAGE_RUN + config
#   dockerfile  buildah bud with layer caching
#   s2i         builder image + /usr/libexec/s2i/assemble
#   cekit       cekit build ... buildah
# Result: an OCI layout in HCI_OCI_DIR (multi-arch — an index with all platforms).

image::dockerfile() {
  local f
  if [[ -n "${HCI_IMAGE_DOCKERFILE:-}" ]]; then
    [[ -f "$HCI_IMAGE_DOCKERFILE" ]] || log::die "HCI_IMAGE_DOCKERFILE='$HCI_IMAGE_DOCKERFILE' не найден"
    printf '%s' "$HCI_IMAGE_DOCKERFILE"
    return 0
  fi
  for f in Containerfile Dockerfile; do
    [[ -f "$f" ]] && { printf '%s' "$f"; return 0; }
  done
  return 1
}

image::mode() {
  local mode="${HCI_IMAGE_BUILD_MODE:-auto}"
  if [[ "$mode" == "auto" ]]; then
    if image::dockerfile >/dev/null; then mode=dockerfile; else mode="${HCI_IMAGE_DEFAULT_MODE:-base}"; fi
  fi
  case "$mode" in
    base | dockerfile | s2i | cekit) printf '%s' "$mode" ;;
    *) log::die "Неизвестный режим сборки образа: $mode" ;;
  esac
}

image::runtime_image() {
  if [[ -n "${HCI_RUNTIME_IMAGE:-}" ]]; then
    printf '%s' "$HCI_RUNTIME_IMAGE"
  elif ci::meta_image runtime 2>/dev/null; then
    :
  else
    log::die "Не задан базовый образ: HCI_RUNTIME_IMAGE (или версия рантайма отсутствует в meta.yaml)"
  fi
}

image::labels() {
  local -n _labels="$1"
  _labels=(
    "org.opencontainers.image.revision=${HCI_SHA:-}"
    "org.opencontainers.image.version=$(naming::image_tag)"
    "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    "org.opencontainers.image.title=${HCI_PROJECT_NAME:-}"
  )
  [[ -n "${HCI_PROJECT_URL:-}" ]] && _labels+=("org.opencontainers.image.source=$HCI_PROJECT_URL")
  local extra=()
  ci::split_lines extra "${HCI_IMAGE_LABELS:-}"
  _labels+=("${extra[@]+"${extra[@]}"}")
}

# Applies container settings (cmd, entrypoint, user, env, ports, labels).
image::configure() {
  local c="$1" item args=()
  local labels=() envs=() ports=()
  image::labels labels
  for item in "${labels[@]}"; do args+=(--label "$item"); done
  ci::split_lines envs "${HCI_IMAGE_ENV:-}"
  for item in "${envs[@]+"${envs[@]}"}"; do args+=(--env "$item"); done
  ci::split ports "${HCI_IMAGE_PORTS:-}"
  for item in "${ports[@]+"${ports[@]}"}"; do args+=(--port "$item"); done
  [[ -n "${HCI_IMAGE_USER:-}" ]] && args+=(--user "$HCI_IMAGE_USER")
  [[ -n "${HCI_IMAGE_ENTRYPOINT:-}" ]] && args+=(--entrypoint "$HCI_IMAGE_ENTRYPOINT")
  [[ -n "${HCI_IMAGE_CMD:-}" ]] && args+=(--cmd "$HCI_IMAGE_CMD")
  log::cmd buildah config "${args[@]}" "$c"
}

# Expands HCI_IMAGE_CONTEXT (paths and globs separated by space/comma/newline), honoring exclusions.
image::context_files() {
  local -n _files="$1"
  local patterns=() excludes=() p f e skip
  ci::split patterns "${HCI_IMAGE_CONTEXT:-}"
  [[ ${#patterns[@]} -gt 0 ]] || log::die "HCI_IMAGE_CONTEXT пуст: нечего копировать в образ"
  ci::split excludes "${HCI_IMAGE_CONTEXT_EXCLUDE:-}"
  _files=()
  shopt -s nullglob globstar
  for p in "${patterns[@]}"; do
    # shellcheck disable=SC2206
    local matches=($p)
    for f in "${matches[@]}"; do
      skip=0
      for e in "${excludes[@]+"${excludes[@]}"}"; do
        # shellcheck disable=SC2053
        [[ "$f" == $e || "${f##*/}" == $e ]] && skip=1
      done
      (( skip )) || _files+=("$f")
    done
  done
  shopt -u nullglob globstar
  [[ ${#_files[@]} -gt 0 ]] || log::die "По HCI_IMAGE_CONTEXT='${HCI_IMAGE_CONTEXT}' ничего не найдено. Проверьте артефакты шага build."
}

image::_from() {
  local platform="$1" image="$2"
  buildah from --pull --platform "$platform" "$image"
}

image::build_base() {
  local platform="$1" iid="$2" c files=() f dest
  c="$(image::_from "$platform" "$(image::runtime_image)")"
  if ci::is_true "${HCI_IMAGE_PASSWD:-false}"; then
    printf 'appuser:x:1001:1001:App User:/:/sbin/nologin\n' > "$HCI_TMP/passwd"
    log::cmd buildah copy "$c" "$HCI_TMP/passwd" /etc/passwd
  fi
  image::context_files files
  dest="${HCI_IMAGE_WORKDIR%/}/"
  for f in "${files[@]}"; do
    if [[ -d "$f" ]]; then
      log::cmd buildah copy --chown "$HCI_IMAGE_CHOWN" "$c" "$f" "$dest"
    else
      log::cmd buildah copy --chown "$HCI_IMAGE_CHOWN" "$c" "$f" "$dest${f##*/}"
    fi
  done
  if [[ -n "${HCI_IMAGE_RUN:-}" ]]; then
    log::cmd buildah run "$c" -- sh -c "$HCI_IMAGE_RUN"
  fi
  image::configure "$c"
  buildah commit --rm --iidfile "$iid" "$c" >/dev/null
}

image::build_s2i() {
  local platform="$1" iid="$2" c files=() f
  c="$(image::_from "$platform" "${HCI_S2I_BUILDER_IMAGE:-$(image::runtime_image)}")"
  image::context_files files
  for f in "${files[@]}"; do
    if [[ -d "$f" ]]; then
      log::cmd buildah copy --chown "$HCI_IMAGE_CHOWN" "$c" "$f" /tmp/src/
    else
      log::cmd buildah copy --chown "$HCI_IMAGE_CHOWN" "$c" "$f" "/tmp/src/${f##*/}"
    fi
  done
  local envs=() e run_env=()
  ci::split_lines envs "${HCI_IMAGE_ENV:-}"
  for e in "${envs[@]+"${envs[@]}"}"; do run_env+=(--env "$e"); done
  log::cmd buildah run "${run_env[@]+"${run_env[@]}"}" "$c" -- /usr/libexec/s2i/assemble
  : "${HCI_IMAGE_CMD:=/usr/libexec/s2i/run}"
  image::configure "$c"
  buildah commit --rm --iidfile "$iid" "$c" >/dev/null
}

image::cache_repo() {
  if [[ -n "${HCI_IMAGE_CACHE_REPO:-}" ]]; then
    printf '%s' "$HCI_IMAGE_CACHE_REPO"
  else
    printf '%s/%s/buildcache' "$(registry::host OCI_PUSH)" "$(naming::image_repo)"
  fi
}

image::build_dockerfile() {
  local platform="$1" iid="$2" file args=() items=() item
  file="$(image::dockerfile)" || log::die "Режим dockerfile: не найден Containerfile/Dockerfile (HCI_IMAGE_DOCKERFILE)"
  args=(--layers --pull --platform "$platform" -f "$file" --iidfile "$iid"
    --build-arg "REGISTRY_HOST=$(registry::host OCI)"
    --build-arg "IMAGE_CONTEXT=${HCI_IMAGE_CONTEXT:-}"
    --build-arg "VERSION=$(naming::image_tag)")
  ci::split_lines items "${HCI_IMAGE_BUILD_ARGS:-}"
  for item in "${items[@]+"${items[@]}"}"; do args+=(--build-arg "$item"); done
  local labels=()
  image::labels labels
  for item in "${labels[@]}"; do args+=(--label "$item"); done
  if ci::is_true "${HCI_IMAGE_CACHE:-true}" && [[ -n "$(registry::host OCI_PUSH)" ]]; then
    local cache
    cache="$(image::cache_repo)"
    args+=(--cache-from "$cache" --cache-to "$cache")
  fi
  log::cmd buildah bud "${args[@]}" "${HCI_IMAGE_BUILD_CONTEXT:-.}"
}

image::build_cekit() {
  local platform="$1" iid="$2" tag="hci-cekit:${HCI_JOB_ID:-local}" args=()
  ci::require cekit
  args=(--descriptor "$HCI_CEKIT_DESCRIPTOR" build)
  [[ -n "${HCI_CEKIT_OVERRIDE:-}" ]] && args+=(--overrides-file "overrides/${HCI_CEKIT_OVERRIDE}.yaml")
  [[ "$platform" == "linux/amd64" ]] || log::warn "cekit собирает под платформу раннера, $platform игнорируется"
  log::cmd cekit "${args[@]}" buildah --tag "$tag"
  buildah inspect --type image --format '{{.FromImageID}}' "$tag" > "$iid"
}

step::image_build() {
  ci::require buildah
  if [[ "$HCI_SERVICE_TYPE" == "library" ]]; then
    ci::skip "service_type=library, образ не собирается"
  fi
  local mode out platforms=() p iid ids=()
  mode="$(image::mode)"
  ci::split platforms "${HCI_IMAGE_PLATFORMS:-linux/amd64}"
  out="$HCI_WORKDIR_ABS/$HCI_OCI_DIR"
  rm -rf "$out"
  log::info "Режим сборки: $mode; платформы: ${platforms[*]}"

  registry::oci_login OCI
  if [[ "$mode" == "dockerfile" ]] && ci::is_true "${HCI_IMAGE_CACHE:-true}"; then
    registry::oci_login OCI_PUSH
  fi

  for p in "${platforms[@]}"; do
    iid="$HCI_TMP/iid-$(ci::slug "$p")"
    log::section_start "image_$(ci::slug "$p")" "Сборка образа для $p"
    "image::build_$mode" "$p" "$iid"
    log::section_end "image_$(ci::slug "$p")"
    [[ -s "$iid" ]] || log::die "Сборка для $p не вернула идентификатор образа"
    ids+=("$(<"$iid")")
  done

  if [[ ${#ids[@]} -eq 1 ]]; then
    log::cmd buildah push "${ids[0]}" "oci:$out"
  else
    local list="hci-manifest-${HCI_JOB_ID:-local}"
    buildah manifest rm "$list" >/dev/null 2>&1 || true
    log::cmd buildah manifest create "$list"
    for iid in "${ids[@]}"; do log::cmd buildah manifest add "$list" "$iid"; done
    log::cmd buildah manifest push --all "$list" "oci:$out"
  fi
  log::ok "Образ сохранён в $HCI_OCI_DIR"
}
