# shellcheck shell=bash
rt::test() {
  if [[ -d .venv ]]; then
    # shellcheck disable=SC1091
    source .venv/bin/activate
  fi
  if ! python3 -c 'import pytest' 2>/dev/null; then
    log::cmd python3 -m pip install pytest pytest-cov
  fi
  mkdir -p "$HCI_OUT_DIR"
  local extra=()
  ci::words extra "${HCI_PYTHON_TEST_ARGS:-}"
  log::cmd python3 -m pytest --cov --cov-report=xml:coverage.xml --junitxml="$HCI_OUT_DIR/pytest.xml" "${extra[@]+"${extra[@]}"}"
}
