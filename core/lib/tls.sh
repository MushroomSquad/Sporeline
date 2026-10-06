# shellcheck shell=bash
# Trusted certificates for tools across different ecosystems.

tls::_system_bundle() {
  local f
  for f in /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem /etc/ssl/cert.pem; do
    [[ -f "$f" ]] && { printf '%s' "$f"; return 0; }
  done
  return 1
}

# Builds the system bundle + corporate certificates into one PEM and exports
# the variables that curl, openssl, python, node, go, and git understand.
tls::bundle() {
  local out="$HCI_TMP/ca-bundle.pem" sys
  if [[ ! -f "$out" ]]; then
    : > "$out"
    if sys="$(tls::_system_bundle)"; then cat "$sys" >> "$out"; fi
    [[ -n "${HCI_CA_BUNDLE:-}" && -f "$HCI_CA_BUNDLE" ]] && cat "$HCI_CA_BUNDLE" >> "$out"
    [[ -n "${HCI_CA_CERT:-}" && -f "$HCI_CA_CERT" && "$HCI_CA_CERT" != "${HCI_CA_BUNDLE:-}" ]] && cat "$HCI_CA_CERT" >> "$out"
  fi
  export SSL_CERT_FILE="$out" CURL_CA_BUNDLE="$out" REQUESTS_CA_BUNDLE="$out" PIP_CERT="$out" GIT_SSL_CAINFO="$out"
  if [[ -n "${HCI_CA_BUNDLE:-}" && -f "$HCI_CA_BUNDLE" ]]; then
    export NODE_EXTRA_CA_CERTS="$HCI_CA_BUNDLE"
  fi
  printf '%s' "$out"
}

tls::has_custom() {
  [[ -n "${HCI_CA_BUNDLE:-}" && -f "$HCI_CA_BUNDLE" ]] || [[ -n "${HCI_CA_CERT:-}" && -f "$HCI_CA_CERT" ]]
}

# curl args for TLS verification (instead of -k).
tls::curl_args() {
  local -n _args="$1"
  _args=()
  if ci::is_true "${HCI_TLS_INSECURE:-false}"; then
    _args=(-k)
  elif tls::has_custom; then
    _args=(--cacert "$(tls::bundle)")
  fi
}

# Java truststore: system cacerts + corporate certificates.
# Exports HCI_TRUSTSTORE and HCI_JAVA_TLS_OPTS.
tls::java_truststore() {
  local store="$HCI_TMP/truststore.jks" pass="${HCI_TRUSTSTORE_PASSWORD:-changeit}" src cert i=0
  export HCI_JAVA_TLS_OPTS=""
  tls::has_custom || return 0
  ci::require keytool
  if [[ ! -f "$store" ]]; then
    for src in "${JAVA_HOME:-/nonexistent}/lib/security/cacerts" "${JAVA_HOME:-/nonexistent}/jre/lib/security/cacerts" /etc/pki/java/cacerts /etc/ssl/certs/java/cacerts; do
      if [[ -f "$src" ]]; then
        cp -f "$src" "$store"
        chmod u+w "$store"
        break
      fi
    done
    mkdir -p "$HCI_TMP/certs"
    awk -v dir="$HCI_TMP/certs" '/BEGIN CERTIFICATE/{n++} n{print > (dir "/cert" n ".pem")}' "${HCI_CA_BUNDLE:-$HCI_CA_CERT}"
    for cert in "$HCI_TMP"/certs/cert*.pem; do
      [[ -f "$cert" ]] || continue
      i=$((i + 1))
      keytool -importcert -noprompt -trustcacerts -alias "hci-ca-$i" -file "$cert" \
        -keystore "$store" -storepass "$pass" >/dev/null 2>&1 || log::warn "Не удалось импортировать $cert"
    done
    log::info "Truststore: импортировано сертификатов: $i"
  fi
  export HCI_TRUSTSTORE="$store"
  export HCI_JAVA_TLS_OPTS="-Djavax.net.ssl.trustStore=$store -Djavax.net.ssl.trustStorePassword=$pass"
}
