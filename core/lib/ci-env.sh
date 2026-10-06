# shellcheck shell=bash
# Нормализация окружения CI-системы в нейтральные переменные HCI_*.
#
# HCI_CI              gitlab | github | jenkins | local
# HCI_TAG             тег релиза (пусто, если сборка не по тегу)
# HCI_REF             имя ветки или тега
# HCI_BRANCH          имя ветки (пусто для тега)
# HCI_SHA, HCI_SHORT_SHA
# HCI_PROJECT_PATH    group/subgroup/project
# HCI_PROJECT_NAME    project
# HCI_PROJECT_NAMESPACE  корневая группа
# HCI_PROJECT_URL
# HCI_PIPELINE_ID, HCI_JOB_ID
# HCI_IS_MR           true, если сборка запущена для merge/pull request
# HCI_ROOT            корень репозитория в рабочей среде

ci_env::_set() {
  local name="$1" value="$2"
  if [[ -z "${!name:-}" ]]; then
    printf -v "$name" '%s' "$value"
  fi
  export "${name?}"
}

ci_env::_from_git_url() {
  local url="$1"
  url="${url%.git}"
  url="${url#*://}"
  url="${url#*@}"
  url="${url#*[:/]}"
  printf '%s' "$url"
}

ci_env::detect() {
  local ci="local"
  if [[ -n "${GITLAB_CI:-}" ]]; then
    ci="gitlab"
  elif [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    ci="github"
  elif [[ -n "${JENKINS_URL:-}" ]]; then
    ci="jenkins"
  fi
  ci_env::_set HCI_CI "$ci"

  case "$HCI_CI" in
    gitlab)
      ci_env::_set HCI_TAG "${CI_COMMIT_TAG:-}"
      ci_env::_set HCI_REF "${CI_COMMIT_REF_NAME:-}"
      ci_env::_set HCI_BRANCH "${CI_COMMIT_BRANCH:-${CI_MERGE_REQUEST_SOURCE_BRANCH_NAME:-}}"
      ci_env::_set HCI_SHA "${CI_COMMIT_SHA:-}"
      ci_env::_set HCI_PROJECT_PATH "${CI_PROJECT_PATH:-}"
      ci_env::_set HCI_PROJECT_NAME "${CI_PROJECT_NAME:-}"
      ci_env::_set HCI_PROJECT_NAMESPACE "${CI_PROJECT_ROOT_NAMESPACE:-}"
      ci_env::_set HCI_PROJECT_URL "${CI_PROJECT_URL:-}"
      ci_env::_set HCI_PIPELINE_ID "${CI_PIPELINE_ID:-}"
      ci_env::_set HCI_JOB_ID "${CI_JOB_ID:-}"
      ci_env::_set HCI_IS_MR "$([[ -n "${CI_MERGE_REQUEST_IID:-}" ]] && echo true || echo false)"
      ci_env::_set HCI_ROOT "${CI_PROJECT_DIR:-$PWD}"
      ;;
    github)
      local tag="" branch=""
      if [[ "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
        tag="${GITHUB_REF_NAME:-}"
      else
        branch="${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-}}"
      fi
      ci_env::_set HCI_TAG "$tag"
      ci_env::_set HCI_REF "${GITHUB_REF_NAME:-}"
      ci_env::_set HCI_BRANCH "$branch"
      ci_env::_set HCI_SHA "${GITHUB_SHA:-}"
      ci_env::_set HCI_PROJECT_PATH "${GITHUB_REPOSITORY:-}"
      ci_env::_set HCI_PROJECT_NAME "${GITHUB_REPOSITORY##*/}"
      ci_env::_set HCI_PROJECT_NAMESPACE "${GITHUB_REPOSITORY_OWNER:-${GITHUB_REPOSITORY%%/*}}"
      ci_env::_set HCI_PROJECT_URL "${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}"
      ci_env::_set HCI_PIPELINE_ID "${GITHUB_RUN_ID:-}"
      ci_env::_set HCI_JOB_ID "${GITHUB_RUN_ID:-}-${GITHUB_RUN_ATTEMPT:-1}-${GITHUB_JOB:-}"
      ci_env::_set HCI_IS_MR "$([[ "${GITHUB_EVENT_NAME:-}" == pull_request* ]] && echo true || echo false)"
      ci_env::_set HCI_ROOT "${GITHUB_WORKSPACE:-$PWD}"
      ;;
    jenkins)
      local path
      path="$(ci_env::_from_git_url "${GIT_URL:-}")"
      ci_env::_set HCI_TAG "${TAG_NAME:-}"
      ci_env::_set HCI_REF "${TAG_NAME:-${BRANCH_NAME:-${GIT_BRANCH:-}}}"
      ci_env::_set HCI_BRANCH "${CHANGE_BRANCH:-${BRANCH_NAME:-${GIT_BRANCH:-}}}"
      ci_env::_set HCI_SHA "${GIT_COMMIT:-}"
      ci_env::_set HCI_PROJECT_PATH "${path:-${JOB_NAME:-}}"
      ci_env::_set HCI_PROJECT_NAME "${HCI_PROJECT_PATH##*/}"
      ci_env::_set HCI_PROJECT_NAMESPACE "${HCI_PROJECT_PATH%%/*}"
      ci_env::_set HCI_PROJECT_URL "${GIT_URL:-}"
      ci_env::_set HCI_PIPELINE_ID "${BUILD_ID:-}"
      ci_env::_set HCI_JOB_ID "${BUILD_TAG:-${BUILD_ID:-}}"
      ci_env::_set HCI_IS_MR "$([[ -n "${CHANGE_ID:-}" ]] && echo true || echo false)"
      ci_env::_set HCI_ROOT "${WORKSPACE:-$PWD}"
      ;;
    local)
      local root path tag branch sha
      root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
      path="$(ci_env::_from_git_url "$(git config --get remote.origin.url 2>/dev/null || true)")"
      [[ -n "$path" ]] || path="local/$(basename "$root")"
      tag="$(git describe --tags --exact-match 2>/dev/null || true)"
      branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
      [[ "$branch" == "HEAD" ]] && branch=""
      sha="$(git rev-parse --verify -q HEAD 2>/dev/null || echo 0000000000000000000000000000000000000000)"
      ci_env::_set HCI_TAG "$tag"
      ci_env::_set HCI_REF "${tag:-$branch}"
      ci_env::_set HCI_BRANCH "$branch"
      ci_env::_set HCI_SHA "$sha"
      ci_env::_set HCI_PROJECT_PATH "$path"
      ci_env::_set HCI_PROJECT_NAME "${path##*/}"
      ci_env::_set HCI_PROJECT_NAMESPACE "${path%%/*}"
      ci_env::_set HCI_PROJECT_URL ""
      ci_env::_set HCI_PIPELINE_ID "local"
      ci_env::_set HCI_JOB_ID "local-$$"
      ci_env::_set HCI_IS_MR "false"
      ci_env::_set HCI_ROOT "$root"
      ;;
  esac

  ci_env::_set HCI_SHORT_SHA "${HCI_SHA:0:8}"
}
