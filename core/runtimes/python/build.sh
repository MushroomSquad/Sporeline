# shellcheck shell=bash
rt::build() {
  python::export_reqs requirements.txt
  if [[ "$HCI_SERVICE_TYPE" == "library" ]]; then
    if ci::has uv; then
      log::cmd uv build
    else
      log::cmd python3 -m pip install -q build
      log::cmd python3 -m build
    fi
    return 0
  fi
  python::venv_install requirements.txt
  cat > .hci-install.sh <<'EOF'
#!/bin/sh
set -eu
cd "${HCI_IMAGE_WORKDIR:-/opt/app-root/src}"
if [ -d .venv ]; then
  . .venv/bin/activate
fi
exec "$@"
EOF
  chmod +x .hci-install.sh
}
