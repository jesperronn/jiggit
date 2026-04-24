#!/usr/bin/env bash
set -euo pipefail

pushd "$(dirname "$0")/.." > /dev/null || exit 1

source bin/lib/bash_test.sh
source bin/setup

TEST_TMPDIR=""

# Create one temporary sandbox per test.
setup_tmpdir() {
  TEST_TMPDIR="$(mktemp -d /tmp/jiggit-setup-test.XXXXXX)"
}

# Clean up the temporary sandbox created for a test.
cleanup_tmpdir() {
  if [[ -n "${TEST_TMPDIR}" && -d "${TEST_TMPDIR}" ]]; then
    rm -rf "${TEST_TMPDIR}"
  fi
}

# Return the current repository root for assertions that depend on symlink targets.
repo_root() {
  pwd
}

test_setup_help_mentions_usage() {
  local output
  output="$(bash bin/setup --help)"

  assert_contains "${output}" "Usage: bin/setup" "setup help renders usage"
}

test_select_link_dir_uses_explicit_link_dir_override() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  mkdir -p "${TEST_TMPDIR}/bin"
  local actual
  actual="$(
    PATH="${TEST_TMPDIR}/bin:/usr/bin:/bin" \
      JIGGIT_LINK_DIR="${TEST_TMPDIR}/bin" \
      select_link_dir "$(repo_root)/bin/jiggit"
  )"

  assert_eq "${TEST_TMPDIR}/bin" "${actual}" "select explicit link dir override"
}

test_select_link_dir_returns_existing_link_dir_for_target() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  mkdir -p "${TEST_TMPDIR}/one" "${TEST_TMPDIR}/two"
  ln -s "$(repo_root)/bin/jiggit" "${TEST_TMPDIR}/two/jiggit"

  local actual
  actual="$(
    PATH="${TEST_TMPDIR}/one:${TEST_TMPDIR}/two:/usr/bin:/bin" \
      select_link_dir "$(repo_root)/bin/jiggit"
  )"

  assert_eq "${TEST_TMPDIR}/two" "${actual}" "reuse existing jiggit symlink directory"
}

test_run_setup_creates_symlink_in_single_writable_path_dir() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  mkdir -p "${TEST_TMPDIR}/bin"

  local output
  output="$(
    PATH="${TEST_TMPDIR}/bin:/usr/bin:/bin" \
      HOME="${TEST_TMPDIR}" \
      run_main
  )"

  assert_contains "${output}" "- status: \`linked\`" "setup reports linked status"
  assert_contains "${output}" "- link dir: \`${TEST_TMPDIR}/bin\`" "setup reports chosen PATH directory"
  if [[ -L "${TEST_TMPDIR}/bin/jiggit" ]]; then
    pass "setup creates the jiggit symlink"
    assert_eq "$(repo_root)/bin/jiggit" "$(readlink "${TEST_TMPDIR}/bin/jiggit")" "setup links to the current checkout"
  else
    fail "setup creates the jiggit symlink"
  fi
}

test_run_setup_reports_already_linked_when_symlink_exists() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  mkdir -p "${TEST_TMPDIR}/bin"
  ln -s "$(repo_root)/bin/jiggit" "${TEST_TMPDIR}/bin/jiggit"

  local output
  output="$(
    PATH="${TEST_TMPDIR}/bin:/usr/bin:/bin" \
      HOME="${TEST_TMPDIR}" \
      run_main
  )"

  assert_contains "${output}" "- status: \`already-linked\`" "setup reports existing symlink"
}

test_run_setup_prompts_for_path_selection_when_multiple_dirs_are_writable() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  mkdir -p "${TEST_TMPDIR}/one" "${TEST_TMPDIR}/two"
  local output
  output="$(
    printf '2\n' | PATH="${TEST_TMPDIR}/one:${TEST_TMPDIR}/two:/usr/bin:/bin" \
      HOME="${TEST_TMPDIR}" \
      bash bin/setup 2>&1
  )"

  assert_contains "${output}" "Choose a PATH directory for the \`jiggit\` symlink:" "setup prompts for PATH selection"
  assert_contains "${output}" "- link dir: \`${TEST_TMPDIR}/two\`" "setup uses the selected PATH directory"
}

test_run_setup_fails_when_no_writable_path_dir_exists() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  mkdir -p "${TEST_TMPDIR}/one" "${TEST_TMPDIR}/two"
  chmod 555 "${TEST_TMPDIR}/one" "${TEST_TMPDIR}/two"

  local output=""
  if output="$(
    PATH="${TEST_TMPDIR}/one:${TEST_TMPDIR}/two:/usr/bin:/bin" \
      HOME="${TEST_TMPDIR}" \
      bash bin/setup 2>&1
  )"; then
    fail "setup should fail without a writable PATH directory"
  else
    pass "setup should fail without a writable PATH directory"
    assert_contains "${output}" "No writable PATH directories are available for the \`jiggit\` symlink." "setup reports missing writable PATH directory"
  fi
}

run_tests "$@"
