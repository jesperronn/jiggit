#!/usr/bin/env bash
set -euo pipefail

pushd "$(dirname "$0")/.." > /dev/null || exit 1

source bin/lib/bash_test.sh
source bin/git_diff_expr

test_build_compare_url_for_bitbucket() {
  parse_git_remote_url "git@stash.example.com:PROJ/widget-service.git"
  local actual
  actual="$(build_compare_url "refs/tags/v1.0.0" "refs/tags/v1.1.0")"
  assert_eq \
    "https://stash.example.com/projects/PROJ/repos/widget-service/compare/commits?sourceBranch=refs%2Ftags%2Fv1.1.0&targetBranch=refs%2Ftags%2Fv1.0.0" \
    "${actual}" \
    "build bitbucket compare url"
}

test_build_compare_url_for_github() {
  parse_git_remote_url "git@github.com:acme/widget-service.git"
  local actual
  actual="$(build_compare_url "refs/tags/v1.0.0" "refs/tags/v1.1.0")"
  assert_eq \
    "https://github.com/acme/widget-service/compare/refs%2Ftags%2Fv1.0.0...refs%2Ftags%2Fv1.1.0" \
    "${actual}" \
    "build github compare url"
}

test_build_compare_url_for_gitlab_subgroup() {
  parse_git_remote_url "https://gitlab.example.com/team/platform/widget-service.git"
  local actual
  actual="$(build_compare_url "refs/tags/v1.0.0" "refs/tags/v1.1.0")"
  assert_eq \
    "https://gitlab.example.com/team/platform/widget-service/-/compare/refs%2Ftags%2Fv1.0.0...refs%2Ftags%2Fv1.1.0" \
    "${actual}" \
    "build gitlab compare url"
}

run_tests "$@"
