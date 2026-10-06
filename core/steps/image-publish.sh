# shellcheck shell=bash
# Publishes an image from an OCI layout: skopeo copy --all, extra tags, SBOM attestation, signing, manifest.

step::image_publish() {
  ci::require skopeo
  [[ "$HCI_SERVICE_TYPE" != "library" ]] || ci::skip "service_type=library"
  local oci="$HCI_WORKDIR_ABS/$HCI_OCI_DIR" host repo tag ref digest extra=() t
  [[ -d "$oci" ]] || log::die "No $HCI_OCI_DIR: step image:publish must receive the image:build step's artifact"

  host="$(registry::host OCI_PUSH)"
  [[ -n "$host" ]] || log::die "No publish registry set (HCI_REGISTRY_OCI_PUSH_HOST / REGISTRY_INT_HOST)"
  repo="$(naming::image_repo)"
  tag="$(naming::image_tag)"
  ref="$host/$repo"

  registry::oci_login OCI_PUSH
  local tls=()
  registry::is_insecure && tls=(--dest-tls-verify=false)

  retry log::cmd skopeo copy --all --retry-times 2 "${tls[@]+"${tls[@]}"}" \
    --digestfile "$HCI_TMP/digest" "oci:$oci" "docker://$ref:$tag"
  digest="$(<"$HCI_TMP/digest")"
  log::ok "Published $ref:$tag@$digest"

  ci::split extra "${HCI_IMAGE_EXTRA_TAGS:-}"
  if naming::is_release && ci::is_true "${HCI_IMAGE_TAG_LATEST:-false}"; then
    extra+=(latest)
  fi
  for t in "${extra[@]+"${extra[@]}"}"; do
    t="$(ci::expand "$t")"
    retry log::cmd skopeo copy --all "${tls[@]+"${tls[@]}"}" "docker://$ref@$digest" "docker://$ref:$t"
  done

  local signed=false
  if sign::enabled; then
    if [[ ! -f "$HCI_SBOM_FILE" ]]; then
      # shellcheck source=/dev/null
      source "$HCI_HOME/steps/sbom.sh"
      sbom::image
    fi
    sign::image "$ref@$digest" "$HCI_SBOM_FILE"
    signed=true
  fi

  manifest::add oci "$repo" "$tag" "$host" \
    "digest=$digest" "signed=$signed" "sbom=$([[ -f "$HCI_SBOM_FILE" ]] && echo true || echo false)" \
    "tags=$(IFS=,; echo "${tag}${extra[*]+,${extra[*]}}")"
}
