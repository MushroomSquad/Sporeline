# shellcheck shell=bash
rt::detect() {
  [[ -f pyproject.toml || -f setup.py || -f setup.cfg || -f requirements.txt || -f uv.lock || -f poetry.lock || -f pdm.lock ]]
}
