#!/usr/bin/env bash
# Downloads static jq and yq into tools/bin for baking into images.
# In an air-gapped environment, override JQ_URL/YQ_URL with an internal mirror (the same
# file, e.g. a Nexus raw proxy) — GitHub Releases is only used as the default.
set -euo pipefail
DEST="$(cd "$(dirname "$0")/bin" && pwd)"
JQ_URL="${JQ_URL:-https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64}"
YQ_URL="${YQ_URL:-https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_amd64}"
mkdir -p "$DEST"
if [[ ! -x "$DEST/jq" ]]; then
  curl -fsSL -o "$DEST/jq" "$JQ_URL"
  chmod +x "$DEST/jq"
fi
if [[ ! -x "$DEST/yq" ]]; then
  curl -fsSL -o "$DEST/yq" "$YQ_URL"
  chmod +x "$DEST/yq"
fi
echo "jq=$("$DEST/jq" --version) yq=$("$DEST/yq" --version)"
