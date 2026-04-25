#!/usr/bin/env bash
# Common helpers for bash test scripts in this repository
# Intended to be sourced by test scripts (do not execute directly)
# Provides simple assert and runner helpers similar to bats' style but minimal

# Note: test scripts should set FAILED=0 at top-level before running tests.

TEST_COLOR_RESET=$'\033[0m'
TEST_COLOR_BOLD=$'\033[1m'
TEST_COLOR_GREEN=$'\033[32m'
TEST_COLOR_RED=$'\033[31m'

# Return success when test output should be colorized.
bash_test_color_output_enabled() {
  [[ "${NO_COLOR:-}" == "" ]]
}

# Wrap one label in color when supported.
colorize_test_label() {
  local color_code="${1:-}"
  local label_text="${2:-}"

  if bash_test_color_output_enabled; then
    printf '%b%s%b' "${color_code}" "${label_text}" "${TEST_COLOR_RESET}"
  else
    printf '%s' "${label_text}"
  fi
}

# Return success when per-test RUN lines should be printed.
bash_test_verbose_enabled() {
  [[ "${BASH_TEST_VERBOSE:-0}" == "1" ]]
}

# Print failure and increment FAILED counter (test scripts should define FAILED)
fail() {
  local msg="${1:-}";
  printf '%s %s\n' "$(colorize_test_label "${TEST_COLOR_BOLD}${TEST_COLOR_RED}" "[FAIL]")" "$msg" >&2
  if [[ -n "${FAILED+x}" ]]; then
    FAILED=$((FAILED+1))
  fi
}

pass() {
  local msg="${1:-}";
  printf '%s %s\n' "$(colorize_test_label "${TEST_COLOR_GREEN}" "[PASS]")" "$msg"
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local msg="${3:-}"
  if [[ "$expected" != "$actual" ]]; then
    printf 'ASSERT FAILED: %s\nExpected: %s\nActual:   %s\n' "$msg" "$expected" "$actual" >&2
    fail "$msg"
    return 2
  else
    pass "$msg"
    return 0
  fi
}

assert_contains() {
  local hay="$1"
  local needle="$2"
  local msg="${3:-}"
  if [[ "$hay" == *"$needle"* ]]; then
    pass "$msg"
    return 0
  else
    fail "$msg: expected to contain '$needle'"
    return 2
  fi
}

assert_not_contains() {
  local hay="$1"
  local needle="$2"
  local msg="${3:-}"
  if [[ "$hay" == *"$needle"* ]]; then
    fail "$msg: expected not to contain '$needle'"
    return 2
  else
    pass "$msg"
    return 0
  fi
}

# Run a syntax check on a script (bash -n)
syntax_check() {
  local script="$1"
  if bash -n "$script" 2>/dev/null; then
    pass "syntax check: $script"
    return 0
  else
    fail "syntax check: $script"
    return 2
  fi
}

# Run a script with -h and assert the output contains expected substring
help_check() {
  local script="$1"
  local expect_substring="${2:-Usage:}"
  local out
  out=$(bash "$script" -h 2>&1 || true)
  local rc=$?
  if [[ $rc -eq 0 && "$out" == *"$expect_substring"* ]]; then
    pass "help output: $script"
    return 0
  else
    printf '%s\n' "--- help output for $script (rc=$rc) ---" >&2
    printf '%s\n' "$out" >&2
    fail "help output: $script"
    return 2
  fi
}

# Run a command while temporarily unsetting a list of environment vars
# Usage: run_with_env_unset VAR1 VAR2 -- command args...
run_with_env_unset() {
  local -a envvars=()
  while [[ "$1" != "--" ]]; do
    envvars+=("$1"); shift || break
  done
  shift || true
  local -a env_cmd=(env)
  for v in "${envvars[@]}"; do
    env_cmd+=( -u "$v" )
  done
  env_cmd+=( "$@" )
  "${env_cmd[@]}"
}

# Simple runner: call functions named test_* in this script or provided list
run_tests() {
  local tests=()
  if [[ $# -gt 0 ]]; then
    tests=("$@")
  else
    # discover functions starting with test_
    mapfile -t tests < <(declare -F | awk '{print $3}' | grep '^test_' || true)
  fi
  if [[ ${#tests[@]} -eq 0 ]]; then
    printf 'No tests to run\n'
    return 1
  fi
  FAILED=0
  for t in "${tests[@]}"; do
    if bash_test_verbose_enabled; then
      printf '%s\n' "--- RUN $t ---"
    fi
    "$t"
  done
  if [[ $FAILED -eq 0 ]]; then
    return 0
  else
    printf '%s %d tests failed\n' "$(colorize_test_label "${TEST_COLOR_BOLD}${TEST_COLOR_RED}" "[FAIL]")" "$FAILED" >&2
    return 2
  fi
}
