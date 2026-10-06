# shellcheck shell=bash
rt::publish() {
  naming::is_release || ci::skip "package publish only runs on a tag"
  [[ -d dist ]] || python::export_reqs requirements.txt
  if [[ ! -d dist ]]; then
    if ci::has uv; then
      log::cmd uv build
    else
      python3 -m pip install -q build
      python3 -m build
    fi
  fi
  local url user pass
  url="$(registry::url PYPI push)/"
  user="$(registry::user PYPI)"
  pass="$(registry::password PYPI)"
  if ci::has uv; then
    retry log::cmd uv publish --index-url "$url" --username "$user" --password "$pass" dist/*
  else
    ci::require twine
    retry log::cmd twine upload --repository-url "$url" -u "$user" -p "$pass" dist/*
  fi
  local name ver
  name="$(sed -n 's/^name *= *"\([^"]*\)".*/\1/p' pyproject.toml | head -1)"
  name="${name:-package}"
  ver="$(naming::version)"
  manifest::add pypi "$name" "$ver" "$url"
}
