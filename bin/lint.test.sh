#!/usr/bin/env bash
set -euo pipefail

pushd "$(dirname "$0")/.." >/dev/null || exit 1

source bin/lib/bash_test.sh

# Create a scratch dir and remove it when the calling test returns.
setup_test_tmpdir() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  trap 'rm -rf "${TEST_TMPDIR}"' RETURN
}

# Install a stub tool in TEST_TMPDIR/bin that echoes its arguments and exits with a status.
create_fake_tool() {
  local name="${1}" status="${2:-0}"
  mkdir -p "${TEST_TMPDIR}/bin"
  printf '#!/usr/bin/env bash\nprintf "fake %s %%s\\n" "$*"\nexit %s\n' "${name}" "${status}" >"${TEST_TMPDIR}/bin/${name}"
  chmod +x "${TEST_TMPDIR}/bin/${name}"
}

# Run bin/lint with stubs first on PATH; sets lint_output and lint_status.
run_lint() {
  lint_status=0
  lint_output="$(PATH="${TEST_TMPDIR}/bin:${PATH}" JIGGIT_LINT_SHFMT="${TEST_TMPDIR}/bin/shfmt" bash bin/lint "$@" 2>&1)" || lint_status=$?
}

test_lint_help_mentions_flags() {
  local output
  output="$(bash bin/lint --help)"

  assert_contains "${output}" "Usage: bin/lint [--autofix] [--verbose] [file ...]" "help lists the flags"
}

test_lint_runs_each_tool_per_file_set() {
  setup_test_tmpdir
  create_fake_tool shellcheck
  create_fake_tool shfmt

  run_lint --verbose bin/lint bin/setup

  assert_eq "0" "${lint_status}" "clean run exits 0"
  assert_contains "${lint_output}" "syntax  bin/setup" "syntax check for each file"
  assert_contains "${lint_output}" "shellcheck 2 files" "shellcheck summary"
  assert_contains "${lint_output}" "fake shellcheck bin/lint" "shellcheck runs on the first file alone"
  assert_contains "${lint_output}" "fake shellcheck bin/setup" "shellcheck runs on the second file alone"
  assert_contains "${lint_output}" "fake shfmt -d bin/lint bin/setup" "shfmt checks both files in one call"
}

test_lint_autofix_runs_shfmt_write() {
  setup_test_tmpdir
  create_fake_tool shellcheck
  create_fake_tool shfmt

  run_lint --autofix bin/lint

  assert_contains "${lint_output}" "fake shfmt -w bin/lint" "autofix writes with shfmt"
  assert_not_contains "${lint_output}" "fake shfmt -d" "autofix does not also run the check"
}

test_lint_fails_when_shfmt_reports_diffs() {
  setup_test_tmpdir
  create_fake_tool shellcheck
  create_fake_tool shfmt 1

  run_lint bin/lint

  assert_eq "1" "${lint_status}" "shfmt diff fails lint"
  assert_contains "${lint_output}" "bin/lint --autofix fixes these" "failure points at --autofix"
  assert_contains "${lint_output}" "fake shellcheck bin/lint" "other checks still run"
}

test_lint_skips_shfmt_when_missing() {
  setup_test_tmpdir
  create_fake_tool shellcheck

  lint_status=0
  lint_output="$(PATH="${TEST_TMPDIR}/bin:${PATH}" JIGGIT_LINT_SHFMT="${TEST_TMPDIR}/bin/no-such-shfmt" bash bin/lint bin/lint 2>&1)" || lint_status=$?

  assert_eq "0" "${lint_status}" "missing shfmt is not a failure"
  assert_contains "${lint_output}" "shfmt not installed; skipping" "says shfmt was skipped"
}

test_lint_skips_non_shell_files_and_rejects_unknown_flags() {
  setup_test_tmpdir
  create_fake_tool shellcheck
  create_fake_tool shfmt

  run_lint README.md bin/lint
  assert_contains "${lint_output}" "skipping README.md (not a shell file)" "non-shell file is skipped"
  assert_not_contains "${lint_output}" "syntax  README.md" "non-shell file is not syntax-checked"

  run_lint --nope
  assert_eq "2" "${lint_status}" "unknown flag exits 2"
}

run_tests "$@"
