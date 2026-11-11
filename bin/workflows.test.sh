#!/usr/bin/env bash
set -euo pipefail

pushd "$(dirname "$0")/.." > /dev/null || exit 1

source bin/lib/bash_test.sh

# Every section appears when no workflow is named.
test_workflows_prints_every_section() {
  local output section
  output="$(bin/workflows)"
  for section in commands setup test lint release; do
    assert_contains "${output}" "== ${section} ==" "prints section ${section}"
  done
}

# Every top-level script and adhoc script is indexed with a description.
test_workflows_commands_lists_every_script_with_description() {
  local output script name
  output="$(bin/workflows commands)"
  for script in bin/* bin/adhoc/*; do
    [[ -f "${script}" && "$(head -c 2 "${script}")" == "#!" ]] || continue
    name="${script##*/}"
    [[ "${name}" == *.test.sh ]] && continue
    assert_contains "${output}" "${name}" "lists ${name}"
  done
  assert_not_contains "${output}" "(no description line)" "every script has a '# name — text' line"
}

# Unknown workflow exits 2 and prints usage.
test_workflows_unknown_name_exits_2() {
  local output status=0
  output="$(bin/workflows nope 2>&1)" || status=$?
  assert_eq "2" "${status}" "unknown workflow exits 2"
  assert_contains "${output}" "Usage: bin/workflows" "unknown workflow prints usage"
}

run_tests "$@"
