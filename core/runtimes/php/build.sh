# shellcheck shell=bash
rt::build() {
  local dest="${HCI_PHP_VENDOR_DIR:-composer-build}"
  mkdir -p "$dest"
  if [[ -x /usr/libexec/s2i/assemble ]]; then
    local src="$HCI_TMP/s2i-src"
    mkdir -p "$src"
    tar -C "$HCI_WORKDIR_ABS" -cf - --exclude="$dest" --exclude=.git --exclude=.cache . | tar -C "$src" -xf -
    (cd "$src" && /usr/libexec/s2i/assemble)
    rm -rf "$dest"
    cp -a "$src" "$dest"
  else
    ci::require composer
    log::cmd composer install --no-interaction --prefer-dist --no-progress
    # Для образа: исходники + vendor.
    tar -C "$HCI_WORKDIR_ABS" -cf - --exclude="$dest" --exclude=.git --exclude=.cache . | tar -C "$dest" -xf -
  fi
}
