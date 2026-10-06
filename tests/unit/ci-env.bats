#!/usr/bin/env bats

load helper

setup() {
  hci_setup_workdir
  hci_source_libs
}
teardown() { hci_teardown_workdir; }

@test "GitLab: тег, проект, MR" {
  export GITLAB_CI=true CI_COMMIT_TAG=1.0.0 CI_COMMIT_REF_NAME=1.0.0 CI_COMMIT_SHA=0123456789abcdef \
    CI_PROJECT_PATH=grp/app CI_PROJECT_NAME=app CI_PROJECT_ROOT_NAMESPACE=grp CI_MERGE_REQUEST_IID=5 CI_PROJECT_DIR="$WORKDIR"
  ci_env::detect
  [ "$HCI_CI" = gitlab ]
  [ "$HCI_TAG" = 1.0.0 ]
  [ "$HCI_SHORT_SHA" = 01234567 ]
  [ "$HCI_PROJECT_NAMESPACE" = grp ]
  [ "$HCI_IS_MR" = true ]
}

@test "GitHub: pull request и ветка" {
  export GITHUB_ACTIONS=true GITHUB_REF_TYPE=branch GITHUB_REF_NAME=5/merge GITHUB_HEAD_REF=feature/x \
    GITHUB_SHA=fedcba9876543210 GITHUB_REPOSITORY=org/repo GITHUB_EVENT_NAME=pull_request GITHUB_WORKSPACE="$WORKDIR"
  ci_env::detect
  [ "$HCI_CI" = github ]
  [ -z "$HCI_TAG" ]
  [ "$HCI_BRANCH" = feature/x ]
  [ "$HCI_PROJECT_NAME" = repo ]
  [ "$HCI_IS_MR" = true ]
}

@test "Jenkins: путь проекта из GIT_URL" {
  export JENKINS_URL=http://j GIT_URL=git@gitlab.local:team/svc.git TAG_NAME=2.0 GIT_COMMIT=aaaaaaaaaaaa WORKSPACE="$WORKDIR"
  ci_env::detect
  [ "$HCI_CI" = jenkins ]
  [ "$HCI_PROJECT_PATH" = team/svc ]
  [ "$HCI_TAG" = 2.0 ]
}

@test "Локально: путь проекта из origin" {
  ci_env::detect
  [ "$HCI_CI" = local ]
  [ "$HCI_PROJECT_PATH" = group/sub/project ]
  [ "$HCI_PROJECT_NAMESPACE" = group ]
}
