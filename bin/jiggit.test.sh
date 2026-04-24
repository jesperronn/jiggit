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
  output="$(bin/jiggit help)"

  assert_contains "${output}" "jiggit jira-create [<project|path>]" "help lists jira-create command"
}

test_jiggit_help_lists_assign_fix_version_command() {
  local output
  output="$(bin/jiggit help)"

  assert_contains "${output}" "jiggit assign-fix-version [<project|path>] --release <fixVersion>" "help lists assign-fix-version command"
}

test_jiggit_help_lists_jira_check_command() {
  local output
  output="$(bin/jiggit help)"

  assert_contains "${output}" "jiggit jira-check [<project|path>] [--all]" "help lists jira-check command"
}

test_jiggit_help_lists_next_release_command() {
  local output
  output="$(bin/jiggit help)"

  assert_contains "${output}" "jiggit next-release [<project|path>] [--base <env|git-ref>] [--target <git-ref>]" "help lists next-release command"
}

test_jiggit_help_lists_dash_command() {
  local output
  output="$(bin/jiggit help)"

  assert_contains "${output}" "jiggit dash [<project|path> ...]" "help lists dash command"
}

test_jiggit_help_lists_env_versions_command() {
  local output
  output="$(bin/jiggit help)"

  assert_contains "${output}" "jiggit env-versions [<project|path>]" "help lists env-versions command"
}

test_jiggit_help_lists_changes_command() {
  local output
  output="$(bin/jiggit help)"

  assert_contains "${output}" "jiggit changes [<project|path>] --base <env|git-ref> [--target <env|git-ref>] [--verbose]" "help lists changes base mode"
  assert_contains "${output}" "jiggit changes [<project|path>] --from <git-ref> [--to <git-ref|release>] [--verbose]" "help lists changes range mode"
  assert_contains "${output}" "jiggit changes [<project|path>] --from-env <env> [--to <git-ref|release>] [--verbose]" "help lists changes release mode"
}

test_jiggit_help_lists_doctor_command() {
  local output
  output="$(bin/jiggit help)"

  assert_contains "${output}" "jiggit doctor [--global|--no-projects] [--fail-fast] [--ignore-failures] [<project|path> ...]" "help lists doctor command"
}

test_jiggit_help_lists_setup_command() {
  local output
  output="$(bin/jiggit help)"

  assert_contains "${output}" "jiggit setup" "help lists setup command"
  assert_contains "${output}" "jiggit setup jira [<jira-name>] [--verbose]" "help lists setup jira mode"
  assert_contains "${output}" "jiggit setup explore [--verbose] [--dry-run] [--append|--replace] <dir> [<dir> ...]" "help lists setup explore mode"
}

test_jiggit_help_lists_releases_command() {
  local output
  output="$(bin/jiggit help)"

  assert_contains "${output}" "jiggit releases [<project|path>]" "help lists releases command"
}

test_jiggit_help_lists_global_project_flags() {
  local output
  output="$(bin/jiggit help)"

  assert_contains "${output}" "--projects=a,b" "help lists global --projects flag"
  assert_contains "${output}" "--all-projects" "help lists global --all-projects flag"
}

test_jiggit_help_lists_global_verbose_flag() {
  local output
  output="$(bin/jiggit help)"

  assert_contains "${output}" "--verbose" "help lists global --verbose flag"
}

test_jiggit_help_lists_version_command() {
  local output
  output="$(bin/jiggit help)"

  assert_contains "${output}" "jiggit --version" "help lists --version"
  assert_contains "${output}" "jiggit version" "help lists version command"
}

test_usage_renders_colored_help_when_color_is_enabled() {
  reset_jiggit_state
  # shellcheck disable=SC2034
  JIGGIT_COLOR_ENABLED=1

  local output
  output="$(usage)"

  assert_contains "${output}" $'\033[1;36mUsage:\033[0m' "usage colors top-level headings"
  assert_contains "${output}" $'\033[1;95mjiggit\033[0m' "usage colors the jiggit command name purple"
  assert_contains "${output}" $'\033[1;36mchanges\033[0m' "usage colors subcommands separately"
  assert_contains "${output}" $'\033[2m[\033[0m\033[2m<\033[0m\033[35mproject|path\033[0m\033[2m>\033[0m\033[2m]\033[0m' "usage dims brackets around placeholders"
  assert_contains "${output}" $'\033[2m[\033[0m\033[1;32m--verbose\033[0m\033[2m]\033[0m' "usage keeps optional flags green inside brackets"
  assert_contains "${output}" $'\033[1;32m--verbose\033[0m' "usage colors option labels"
}

test_jiggit_usage_line_highlights_the_subcommand_token() {
  reset_jiggit_state
  # shellcheck disable=SC2034
  JIGGIT_COLOR_ENABLED=1

  local output
  output="$(setup_usage)"

  assert_contains "${output}" $'\033[1;95mjiggit\033[0m \033[1;36msetup\033[0m' "usage line styles jiggit and bolds the subcommand token"
  assert_contains "${output}" $'\033[2m<\033[0m\033[35mdir\033[0m\033[2m>\033[0m' "usage line colors parameter placeholders"
  assert_contains "${output}" $'\033[1;95mjiggit\033[0m \033[1;36msetup\033[0m explore' "usage lists setup explore mode"
}

test_jiggit_config_accepts_global_verbose_flag() {
  local tmpdir=""
  tmpdir="$(mktemp -d /tmp/jiggit-config-verbose.XXXXXX)"
  trap '[[ -n "${tmpdir:-}" ]] && rm -rf "${tmpdir}"' RETURN

  mkdir -p "${tmpdir}/bin" "${tmpdir}/home/.jiggit"

  cat > "${tmpdir}/projects.toml" <<'EOF'
[jira]
base_url = "https://jira.example.test"
bearer_token = "token"

[alpha]
repo_path = "/tmp/alpha"
remote_url = "git@github.com:example/alpha.git"
jira_project_key = "ALPHA"
jira_regexes = ["ALPHA-[0-9]+"]
environments = []
EOF

  cat > "${tmpdir}/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "__CURL_LOG__"
printf '{ "name": "Test User" }\n'
EOF

  sed -i.bak "s|__CURL_LOG__|${tmpdir}/curl.log|g" "${tmpdir}/bin/curl"
  rm -f "${tmpdir}/bin/curl.bak"
  chmod +x "${tmpdir}/bin/curl"

  local output
  output="$(
    HOME="${tmpdir}/home" \
    PATH="${tmpdir}/bin:${PATH}" \
    JIGGIT_PROJECTS_FILE="${tmpdir}/projects.toml" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${tmpdir}/discovered.toml" \
    bin/jiggit config --verbose 2>&1
  )"

  assert_contains "${output}" "[verbose] loading project config" "config accepts global --verbose"
  assert_contains "${output}" "# jiggit config" "config still renders normally with verbose"
  if [[ -f "${tmpdir}/curl.log" ]]; then
    fail "config should not call curl"
  else
    pass "config stays read-only and skips curl"
  fi
}

test_jiggit_config_help_lists_global_and_project_args() {
  local output
  output="$(bin/jiggit help)"

  assert_contains "${output}" "jiggit config [--global|--no-projects|--all] [<project|path> ...]" "help lists config project args and global flag"
}

test_jiggit_dash_dash_version_prints_version() {
  local output
  output="$(bin/jiggit --version)"

  assert_eq "jiggit $(cat VERSION)" "${output}" "--version prints tracked version"
}

test_jiggit_version_command_prints_version() {
  local output
  output="$(bin/jiggit version)"

  assert_eq "jiggit $(cat VERSION)" "${output}" "version command prints tracked version"
}

test_jiggit_can_be_sourced_without_running_main() {
  local output
  output="$(source bin/jiggit source >/dev/null 2>&1; printf '%s' "${JIGGIT_SOURCE_ONLY}")"

  assert_eq "1" "${output}" "source mode loads helpers without dispatch"
}

test_sourced_jiggit_keeps_project_indexes_global_for_config_loading() {
  local tmpdir=""
  tmpdir="$(mktemp -d /tmp/jiggit-source-state.XXXXXX)"
  trap '[[ -n "${tmpdir:-}" ]] && rm -rf "${tmpdir}"' RETURN

  local projects_file="${tmpdir}/projects.toml"
  cat > "${projects_file}" <<'EOF'
[alpha]
repo_path = "/tmp/alpha"
environments = ["lt"]
info_version_expr = "cat"

[alpha.environment_info_urls]
lt = "https://alpha.example.test/info"

[beta]
repo_path = "/tmp/beta"
environments = ["prod"]
info_version_expr = "jq -r '.version'"

[beta.environment_info_urls]
prod = "https://beta.example.test/info"
EOF

  local output=""
  # Use a plain shell so local login/profile hooks cannot stall the test.
  output="$(
    PATH="/opt/homebrew/bin:${PATH}" \
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${tmpdir}/discovered.toml" \
    /opt/homebrew/bin/bash -c '
      source bin/jiggit source
      fetch_env_version_for_url() {
        printf "mock-%s\n" "$1"
      }
      run_main env-versions alpha --verbose
    ' 2>&1
  )"

  assert_contains "${output}" "loaded ${projects_file}: projects 0 -> 2" "sourced jiggit keeps all configured project ids"
  assert_contains "${output}" "- Repo path: \`/tmp/alpha\`" "sourced jiggit keeps alpha repo path separate"
  assert_contains "${output}" "- Version expr: \`cat\`" "sourced jiggit keeps alpha version expression separate"
}

test_parse_opts_defaults_to_help_when_no_args_are_provided() {
  reset_jiggit_state
  parse_opts

  # shellcheck disable=SC2031
  assert_eq "help" "${JIGGIT_STRIPPED_ARGS[0]}" "parse_opts defaults to help"
}

test_parse_opts_extracts_global_project_selectors_before_command() {
  reset_jiggit_state
  parse_opts --projects alpha,beta dash
  parse_prereqs

  # shellcheck disable=SC2031
  assert_eq "dash" "${JIGGIT_STRIPPED_ARGS[0]}" "parse_opts keeps the command after global selectors"
  # shellcheck disable=SC2031
  assert_eq "alpha,beta" "${JIGGIT_PROJECT_SELECTORS}" "parse_prereqs exports project selectors"
}

test_parse_opts_strips_verbose_flags_from_remaining_args() {
  reset_jiggit_state
  parse_opts config --verbose

  # shellcheck disable=SC2031
  assert_eq "config" "${JIGGIT_STRIPPED_ARGS[0]}" "parse_opts keeps subcommand name"
  # shellcheck disable=SC2031
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
