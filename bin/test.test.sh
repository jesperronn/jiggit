#!/usr/bin/env bash
set -euo pipefail

pushd "$(dirname "$0")/.." > /dev/null || exit 1

source bin/lib/bash_test.sh

test_passing_runner_output_contains_only_headers_and_markers() {
  local output
  output="$(NO_COLOR=1 bin/test bin/git_diff_expr.test.sh)"

  local unexpected_lines
  unexpected_lines="$(
    printf '%s\n' "${output}" |
      grep -Ev '^(==> bin/[^[:space:]]+\.test\.sh|\[PASS\] .+|\[FAIL\] .+)$' ||
      true
  )"

  assert_eq "" "${unexpected_lines}" "passing bin/test output contains only headers and markers"
  assert_not_contains "${output}" "TEST SUMMARY" "passing bin/test output omits summary lines"
}

run_tests "$@"
