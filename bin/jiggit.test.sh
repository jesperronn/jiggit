#!/usr/bin/env bash
set -euo pipefail

pushd "$(dirname "$0")/.." > /dev/null || exit 1

source bin/lib/bash_test.sh

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

run_tests "$@"
