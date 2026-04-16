#!/usr/bin/env bash
set -euo pipefail

pushd "$(dirname "$0")/.." > /dev/null || exit 1

source bin/lib/bash_test.sh

setup_test_tmpdir() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  trap 'rm -rf "${TEST_TMPDIR}"' RETURN
}

create_fake_shellcheck() {
  mkdir -p "${TEST_TMPDIR}/bin"
  cat > "${TEST_TMPDIR}/bin/shellcheck" <<'EOF'
#!/usr/bin/env bash
printf 'fake shellcheck %s\n' "$*"
EOF
  chmod +x "${TEST_TMPDIR}/bin/shellcheck"
}

test_lint_help_mentions_verbose_flag() {
  local output
  output="$(bash bin/lint --help)"

  assert_contains "${output}" "Usage: bin/lint [--verbose] [file ...]" "lint help lists --verbose"
}

test_lint_verbose_runs_shellcheck_one_file_at_a_time() {
  setup_test_tmpdir
  create_fake_shellcheck

  local output
  output="$(PATH="${TEST_TMPDIR}/bin:${PATH}" bash bin/lint --verbose bin/lint 2>&1)"

  assert_contains "${output}" "syntax  bin/lint" "run syntax check"
  assert_contains "${output}" "shellcheck 1 files" "show shellcheck summary"
  assert_contains "${output}" "[lint] run: shellcheck -x bin/lint" "show verbose shellcheck command"
  assert_contains "${output}" "fake shellcheck -x bin/lint" "invoke stub shellcheck"
}

test_lint_accepts_multiple_explicit_files() {
  setup_test_tmpdir
  create_fake_shellcheck

  local output
  output="$(PATH="${TEST_TMPDIR}/bin:${PATH}" bash bin/lint --verbose bin/lint bin/setup 2>&1)"

  assert_contains "${output}" "syntax  bin/lint" "run syntax check for first file"
  assert_contains "${output}" "syntax  bin/setup" "run syntax check for second file"
  assert_contains "${output}" "shellcheck 2 files" "show shellcheck summary for multiple files"
  assert_contains "${output}" "[lint] run: shellcheck -x bin/lint bin/setup" "show batched shellcheck command"
  assert_contains "${output}" "fake shellcheck -x bin/lint bin/setup" "invoke stub shellcheck once for both files"

  local shellcheck_calls
  shellcheck_calls="$(printf '%s\n' "${output}" | grep -c '^fake shellcheck ' || true)"
  assert_eq "1" "${shellcheck_calls}" "run shellcheck once for multiple files"
}

run_tests "$@"
