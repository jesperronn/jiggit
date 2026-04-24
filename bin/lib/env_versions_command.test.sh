#!/usr/bin/env bash
set -euo pipefail

pushd "$(dirname "$0")/../.." > /dev/null || exit 1

source bin/lib/bash_test.sh
source bin/lib/env_versions_command.sh

TEST_TMPDIR=""

setup_tmpdir() {
  TEST_TMPDIR="$(mktemp -d /tmp/jiggit-env-versions-test.XXXXXX)"
}

cleanup_tmpdir() {
  if [[ -n "${TEST_TMPDIR}" && -d "${TEST_TMPDIR}" ]]; then
    rm -rf "${TEST_TMPDIR}"
  fi
}

default_target_git_ref() {
  local repo_path="${1}"
  printf '%s\n' "${JIGGIT_TEST_DEFAULT_TARGET_REF:-refs/remotes/origin/master}"
}

compare_issue_keys() {
  local repo_path="${1}"
  local range="${2}"
  local project_id="${3}"
  printf '%s|%s|%s\n' "${repo_path}" "${range}" "${project_id}" >> "${TEST_TMPDIR}/issue-keys.log"
  printf '%s' "${JIGGIT_TEST_ISSUE_KEYS:-}"
}

fetch_jira_issues_by_keys() {
  local jira_base_url="${1}"
  local auth_reference="${2:-}"
  shift 2 || true
  local issues_json="${JIGGIT_TEST_ISSUES_JSON:-}"
  if [[ -z "${issues_json}" ]]; then
    issues_json='{"issues":[]}'
  fi
  printf '%s|%s|%s\n' "${jira_base_url}" "${auth_reference}" "$*" >> "${TEST_TMPDIR}/jira-issues.log"
  printf '%s\n' "${issues_json}"
}

# Override the network fetcher so env-versions tests stay local and deterministic.
fetch_env_version_for_url() {
  local environment_name="${1}"
  local info_url="${2}"
  local version_expr="${3}"

  printf '%s|%s|%s\n' "${environment_name}" "${info_url}" "${version_expr}" >> "${TEST_TMPDIR}/fetch.log"

  case "${environment_name}" in
    prod)
      printf 'v1.2.3-0-gabc1234\n'
      ;;
    prep)
      printf 'v1.2.4-0-gdef5678\n'
      ;;
    *)
      printf 'ERROR: unknown test environment\n'
      return 1
      ;;
  esac
}

test_run_env_versions_main_renders_versions_for_configured_environments() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local projects_file="${TEST_TMPDIR}/projects.toml"
  cat > "${projects_file}" <<'EOF'
[project-a]
repo_path = "/tmp/project-a"
remote_url = "git@github.com:example/project-a.git"
jira_project_key = "JIRA"
jira_regexes = ["JIRA-[0-9]+"]
environments = ["prod", "prep"]
info_version_expr = "jq -r '.git.branch'"

[project-a.environment_info_urls]
prod = "https://prod.project-a.example.com/actuator/info"
prep = "https://prep.project-a.example.com/actuator/info"
EOF

  local output
  output="$(
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    run_env_versions_main project-a
  )"

  assert_contains "${output}" "# jiggit env-versions" "render env-versions heading"
  assert_contains "${output}" "Environments: \`prod prep\`" "render configured environments"
  assert_contains "${output}" "Version expr: \`jq -r '.git.branch'\`" "render version expression"
  assert_contains "${output}" "\`prod\`: \`v1.2.3\` from \`https://prod.project-a.example.com/actuator/info\`" "render normalized prod version"
  assert_contains "${output}" "\`prep\`: \`v1.2.4\` from \`https://prep.project-a.example.com/actuator/info\`" "render normalized prep version"
  assert_contains "${output}" "prep: ahead of prod within the same minor (v1.2.4 vs v1.2.3); new minor release needed" "render same-minor drift diagnostic"
  assert_contains "${output}" "jiggit changes project-a --base prod" "render changes next step"
  assert_contains "${output}" "jiggit next-release project-a" "render next-release next step"

  local fetch_log
  fetch_log="$(sed -n '1,20p' "${TEST_TMPDIR}/fetch.log")"
  assert_contains "${fetch_log}" "prod|https://prod.project-a.example.com/actuator/info|jq -r '.git.branch'" "call fetcher for prod"
  assert_contains "${fetch_log}" "prep|https://prep.project-a.example.com/actuator/info|jq -r '.git.branch'" "call fetcher for prep"
}

test_run_env_versions_main_can_force_colored_missing_and_drift_lines() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local projects_file="${TEST_TMPDIR}/projects.toml"
  cat > "${projects_file}" <<'EOF'
[project-a]
repo_path = "/tmp/project-a"
remote_url = "git@github.com:example/project-a.git"
jira_project_key = "JIRA"
jira_regexes = ["JIRA-[0-9]+"]
environments = ["prod", "ft"]

[project-a.environment_info_urls]
prod = "https://prod.project-a.example.com/actuator/info"
EOF

  local output=""
  if output="$(
    JIGGIT_COLOR_OUTPUT=always \
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    run_env_versions_main project-a 2>&1
  )"; then
    fail "fail when one configured environment has no info url"
  else
    pass "fail when one configured environment has no info url"
    assert_contains "${output}" $'\e[1m\e[38;5;202m- `ft  `: `ERROR: missing info URL in config` from `missing`\e[0m' "render missing environment in orange"
  fi
}

test_run_env_versions_main_fails_when_environment_url_is_missing() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local projects_file="${TEST_TMPDIR}/projects.toml"
  cat > "${projects_file}" <<'EOF'
[project-a]
repo_path = "/tmp/project-a"
remote_url = "git@github.com:example/project-a.git"
jira_project_key = "JIRA"
jira_regexes = ["JIRA-[0-9]+"]
environments = ["prod", "ft"]

[project-a.environment_info_urls]
prod = "https://prod.project-a.example.com/actuator/info"
EOF

  local output=""
  if output="$(
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    run_env_versions_main project-a 2>&1
  )"; then
    fail "fail when one configured environment has no info url"
  else
    pass "fail when one configured environment has no info url"
    assert_contains "${output}" "\`ft  \`: \`ERROR: missing info URL in config\` from \`missing\`" "report missing environment info url"
  fi
}

test_run_env_versions_main_defaults_to_current_configured_repo() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local repo_dir="${TEST_TMPDIR}/project-a"
  mkdir -p "${repo_dir}"
  git init "${repo_dir}" >/dev/null 2>&1

  local projects_file="${TEST_TMPDIR}/projects.toml"
  cat > "${projects_file}" <<EOF
[project-a]
repo_path = "${repo_dir}"
remote_url = "git@github.com:example/project-a.git"
jira_project_key = "JIRA"
jira_regexes = ["JIRA-[0-9]+"]
environments = ["prod"]
info_version_expr = "jq -r '.git.branch'"

[project-a.environment_info_urls]
prod = "https://prod.project-a.example.com/actuator/info"
EOF

  local output
  output="$(
    cd "${repo_dir}"
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    run_env_versions_main
  )"

  assert_contains "${output}" "# jiggit env-versions" "render env-versions heading from current repo"
  assert_contains "${output}" "Project: \`project-a\`" "resolve project from current repo"
  assert_contains "${output}" "\`prod\`: \`v1.2.3\` from \`https://prod.project-a.example.com/actuator/info\`" "render resolved version from current repo"
}

test_run_env_versions_main_renders_unreleased_issues_when_prod_drift_exists() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local repo_dir="${TEST_TMPDIR}/project-a"
  mkdir -p "${repo_dir}"
  git init "${repo_dir}" >/dev/null 2>&1

  local projects_file="${TEST_TMPDIR}/projects.toml"
  cat > "${projects_file}" <<EOF
[jira]
base_url = "https://jira.example.com"
bearer_token = "token"

[project-a]
repo_path = "${repo_dir}"
remote_url = "git@github.com:example/project-a.git"
jira_project_key = "JIRA"
jira_regexes = ["JIRA-[0-9]+"]
environments = ["prod", "prep"]
info_version_expr = "jq -r '.git.branch'"

[project-a.environment_info_urls]
prod = "https://prod.project-a.example.com/actuator/info"
prep = "https://prep.project-a.example.com/actuator/info"
EOF

  local issues_json
  issues_json="$(cat <<'EOF'
{"issues":[{"key":"JIRA-1","fields":{"summary":"Ship drift fix","status":{"name":"In Progress"},"fixVersions":[{"name":"1.3.0"}]}},{"key":"JIRA-2","fields":{"summary":"Missing release tag","status":{"name":"To Do"},"fixVersions":[]}}]}
EOF
)"

  local output
  output="$(
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    JIGGIT_TEST_ISSUE_KEYS=$'JIRA-1\nJIRA-2\n' \
    JIGGIT_TEST_ISSUES_JSON="${issues_json}" \
    run_env_versions_main project-a
  )"

  assert_contains "${output}" "## Unreleased Issues" "render unreleased issues section for prod drift"
  assert_contains "${output}" "\`JIRA-1\`" "render first unreleased issue"
  assert_contains "${output}" "fix_version: \`1.3.0\`" "render populated fix version in unreleased issue list"
  assert_contains "${output}" "fix_version: \`MISSING\`" "render missing fix version in unreleased issue list"
  assert_contains "${output}" "jiggit changes project-a --from-env prod --to 1.3.0" "render changes next step from drift section"

  local issue_key_log
  issue_key_log="$(sed -n '1,20p' "${TEST_TMPDIR}/issue-keys.log")"
  assert_contains "${issue_key_log}" "${repo_dir}|v1.2.3..refs/remotes/origin/master|project-a" "inspect prod drift span for unreleased issues"

  local jira_issues_log
  jira_issues_log="$(sed -n '1,20p' "${TEST_TMPDIR}/jira-issues.log")"
  assert_contains "${jira_issues_log}" "https://jira.example.com||JIRA-1 JIRA-2" "pass all unreleased issue keys with blank auth reference"
}

run_tests "$@"
