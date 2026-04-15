#!/usr/bin/env bash
set -euo pipefail

pushd "$(dirname "$0")/.." > /dev/null || exit 1

source bin/lib/bash_test.sh

JIGGIT_TEST_SCRIPT_LOADED=0

# Source the jiggit entrypoint once so unit tests can call its helpers directly.
load_jiggit_script() {
  if [[ "${JIGGIT_TEST_SCRIPT_LOADED}" -eq 1 ]]; then
    return 0
  fi

  # shellcheck source=bin/jiggit
  source bin/jiggit source
  JIGGIT_TEST_SCRIPT_LOADED=1
}

# Reset top-level jiggit globals between unit tests.
reset_jiggit_state() {
  load_jiggit_script
  jiggit_reset_state
  unset JIGGIT_PROJECT_SELECTORS || true
  unset JIGGIT_VERBOSE || true
  unset VERBOSE || true
  unset JIGGIT_EXPLORE_VERBOSE || true
  unset JIGGIT_ENV_VERSIONS_VERBOSE || true
  unset JIGGIT_ENV_DIFF_VERBOSE || true
}

test_jiggit_help_lists_jira_create_command() {
  local output
  output="$(bash bin/jiggit help)"

  assert_contains "${output}" "jiggit jira-create [<project|path>]" "help lists jira-create command"
}

test_jiggit_help_lists_assign_fix_version_command() {
  local output
  output="$(bash bin/jiggit help)"

  assert_contains "${output}" "jiggit assign-fix-version [<project|path>] --release <fixVersion>" "help lists assign-fix-version command"
}

test_jiggit_help_lists_jira_check_command() {
  local output
  output="$(bash bin/jiggit help)"

  assert_contains "${output}" "jiggit jira-check [<project|path>] [--all]" "help lists jira-check command"
}

test_jiggit_help_lists_jira_issues_command() {
  local output
  output="$(bash bin/jiggit help)"

  assert_contains "${output}" "jiggit jira-issues [<project|path>] --release <fixVersion>" "help lists jira-issues command"
}

test_jiggit_help_lists_next_release_command() {
  local output
  output="$(bash bin/jiggit help)"

  assert_contains "${output}" "jiggit next-release [<project|path>] [--base <env|git-ref>] [--target <git-ref>]" "help lists next-release command"
}

test_jiggit_help_lists_overview_command() {
  local output
  output="$(bash bin/jiggit help)"

  assert_contains "${output}" "jiggit overview [<project|path> ...]" "help lists overview command"
}

test_jiggit_help_lists_dash_alias() {
  local output
  output="$(bash bin/jiggit help)"

  assert_contains "${output}" "jiggit dash [<project|path> ...]" "help lists dash alias"
}

test_jiggit_help_lists_release_notes_command() {
  local output
  output="$(bash bin/jiggit help)"

  assert_contains "${output}" "jiggit release-notes [<project|path>] --target <git-ref|release>" "help lists release-notes command"
}

test_jiggit_help_lists_env_versions_command() {
  local output
  output="$(bash bin/jiggit help)"

  assert_contains "${output}" "jiggit env-versions [<project|path>]" "help lists env-versions command"
}

test_jiggit_help_lists_env_diff_command() {
  local output
  output="$(bash bin/jiggit help)"

  assert_contains "${output}" "jiggit env-diff [<project|path>] --base <env|git-ref>" "help lists env-diff command"
}

test_jiggit_help_lists_doctor_command() {
  local output
  output="$(bash bin/jiggit help)"

  assert_contains "${output}" "jiggit doctor [--global|--no-projects] [--fail-fast] [--ignore-failures] [<project|path> ...]" "help lists doctor command"
}

test_jiggit_help_lists_diagnostics_alias() {
  local output
  output="$(bash bin/jiggit help)"

  assert_contains "${output}" "jiggit diagnostics [--global|--no-projects] [--fail-fast] [--ignore-failures] [<project|path> ...]" "help lists diagnostics alias"
}

test_jiggit_diagnostics_alias_runs_doctor_help() {
  local output
  output="$(bash bin/jiggit diagnostics --help)"

  assert_contains "${output}" "Run health checks for configured projects." "diagnostics alias dispatches to doctor"
  assert_contains "${output}" "jiggit diagnostics [--global|--no-projects] [--fail-fast] [--ignore-failures] [<project|path> ...]" "diagnostics help includes global flag"
}

test_jiggit_help_lists_releases_command() {
  local output
  output="$(bash bin/jiggit help)"

  assert_contains "${output}" "jiggit releases [<project|path>]" "help lists releases command"
}

test_jiggit_help_lists_global_project_flags() {
  local output
  output="$(bash bin/jiggit help)"

  assert_contains "${output}" "--projects=a,b" "help lists global --projects flag"
  assert_contains "${output}" "--all-projects" "help lists global --all-projects flag"
}

test_jiggit_help_lists_global_verbose_flag() {
  local output
  output="$(bash bin/jiggit help)"

  assert_contains "${output}" "--verbose" "help lists global --verbose flag"
}

test_jiggit_help_lists_version_command() {
  local output
  output="$(bash bin/jiggit help)"

  assert_contains "${output}" "jiggit --version" "help lists --version"
  assert_contains "${output}" "jiggit version" "help lists version command"
}

test_usage_renders_colored_help_when_color_is_enabled() {
  reset_jiggit_state
  JIGGIT_COLOR_ENABLED=1

  local output
  output="$(usage)"

  assert_contains "${output}" $'\033[1;36mUsage:\033[0m' "usage colors top-level headings"
  assert_contains "${output}" $'\033[1;32m    --verbose\033[0m' "usage colors option labels"
}

test_jiggit_config_accepts_global_verbose_flag() {
  local output
  output="$(bash bin/jiggit config --verbose 2>&1)"

  assert_contains "${output}" "[verbose] loading project config" "config accepts global --verbose"
  assert_contains "${output}" "# jiggit config" "config still renders normally with verbose"
}

test_jiggit_config_help_lists_global_and_project_args() {
  local output
  output="$(bash bin/jiggit help)"

  assert_contains "${output}" "jiggit config [--global|--no-projects] [<project|path> ...]" "help lists config project args and global flag"
}

test_jiggit_dash_dash_version_prints_version() {
  local output
  output="$(bash bin/jiggit --version)"

  assert_eq "jiggit $(cat VERSION)" "${output}" "--version prints tracked version"
}

test_jiggit_version_command_prints_version() {
  local output
  output="$(bash bin/jiggit version)"

  assert_eq "jiggit $(cat VERSION)" "${output}" "version command prints tracked version"
}

test_jiggit_can_be_sourced_without_running_main() {
  local output
  output="$(bash -lc 'cd /Users/jesper/src/jiggit && source bin/jiggit source && printf "%s" "${JIGGIT_SOURCE_ONLY}"')"

  assert_eq "1" "${output}" "source mode loads helpers without dispatch"
}

test_parse_opts_defaults_to_help_when_no_args_are_provided() {
  reset_jiggit_state
  parse_opts

  assert_eq "help" "${JIGGIT_STRIPPED_ARGS[0]}" "parse_opts defaults to help"
}

test_parse_opts_extracts_global_project_selectors_before_command() {
  reset_jiggit_state
  parse_opts --projects alpha,beta overview
  parse_prereqs

  assert_eq "overview" "${JIGGIT_STRIPPED_ARGS[0]}" "parse_opts keeps the command after global selectors"
  assert_eq "alpha,beta" "${JIGGIT_PROJECT_SELECTORS}" "parse_prereqs exports project selectors"
}

test_parse_opts_strips_verbose_flags_from_remaining_args() {
  reset_jiggit_state
  parse_opts config --verbose

  assert_eq "config" "${JIGGIT_STRIPPED_ARGS[0]}" "parse_opts keeps subcommand name"
  assert_eq "1" "${JIGGIT_FLAG_VERBOSE}" "parse_opts enables verbose mode"
}

test_parse_opts_rejects_unknown_global_options() {
  reset_jiggit_state

  set +e
  local output
  output="$(parse_opts --bogus 2>&1)"
  local status=$?
  set -e

  assert_eq "2" "${status}" "parse_opts rejects unknown global options"
  assert_contains "${output}" "Unknown option: --bogus" "parse_opts explains unknown options"
}

run_tests "$@"
