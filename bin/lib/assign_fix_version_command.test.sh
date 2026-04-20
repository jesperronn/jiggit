#!/usr/bin/env bash
set -euo pipefail

pushd "$(dirname "$0")/../.." > /dev/null || exit 1

source bin/lib/bash_test.sh
source bin/lib/assign_fix_version_command.sh

TEST_TMPDIR=""
JIGGIT_TEST_ASSIGN_FIX_VERSION_UPDATE_LOG=""
JIGGIT_TEST_ASSIGN_FIX_VERSION_FETCH_LOG=""
declare -A JIGGIT_TEST_ENV_VERSION_BY_NAME=()

setup_tmpdir() {
  TEST_TMPDIR="$(mktemp -d /tmp/jiggit-assign-fix-version-test.XXXXXX)"
  JIGGIT_TEST_ASSIGN_FIX_VERSION_UPDATE_LOG="${TEST_TMPDIR}/update.log"
  JIGGIT_TEST_ASSIGN_FIX_VERSION_FETCH_LOG="${TEST_TMPDIR}/fetch.log"
  JIGGIT_PROMPT_INPUT_FILE=""
  JIGGIT_CAN_PROMPT_INTERACTIVELY=false
}

cleanup_tmpdir() {
  if [[ -n "${TEST_TMPDIR}" && -d "${TEST_TMPDIR}" ]]; then
    rm -rf "${TEST_TMPDIR}"
  fi
}

create_repo_for_assign_fix_version() {
  local repo_dir="${1}"

  mkdir -p "${repo_dir}"
  git init "${repo_dir}" >/dev/null 2>&1
  git -C "${repo_dir}" config user.name "Jiggit Test"
  git -C "${repo_dir}" config user.email "jiggit@example.com"
  git -C "${repo_dir}" branch -M main
  git -C "${repo_dir}" remote add origin "git@github.com:example/assign-fix-version-repo.git"

  printf 'one\n' > "${repo_dir}/README.md"
  git -C "${repo_dir}" add README.md
  git -C "${repo_dir}" commit -m "ALPHA-1 initial commit" >/dev/null 2>&1
  git -C "${repo_dir}" tag v1.2.0.0
  git -C "${repo_dir}" update-ref refs/remotes/origin/main "$(git -C "${repo_dir}" rev-parse HEAD)"
  git -C "${repo_dir}" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

  printf 'two\n' >> "${repo_dir}/README.md"
  git -C "${repo_dir}" add README.md
  git -C "${repo_dir}" commit -m "ALPHA-2 add feature" >/dev/null 2>&1

  printf 'three\n' >> "${repo_dir}/README.md"
  git -C "${repo_dir}" add README.md
  git -C "${repo_dir}" commit -m "ALPHA-3 add second feature" >/dev/null 2>&1
  git -C "${repo_dir}" update-ref refs/remotes/origin/main "$(git -C "${repo_dir}" rev-parse HEAD)"
}

fetch_project_environment_version() {
  local project_id="${1}"
  local environment_name="${2}"

  printf '%s\n' "${JIGGIT_TEST_ENV_VERSION_BY_NAME["${project_id}:${environment_name}"]:-}"
}

fetch_jira_releases() {
  cat <<'EOF'
[
  {"name": "1.3.0.0"},
  {"name": "1.4.0.0"}
]
EOF
}

fetch_jira_issues_by_keys() {
  local jira_base_url="${1}"
  local auth_reference="${2:-}"
  shift 2 || true

  printf '%s|%s|%s\n' "${jira_base_url}" "${auth_reference}" "$*" >> "${JIGGIT_TEST_ASSIGN_FIX_VERSION_FETCH_LOG}"
  cat <<'EOF'
{
  "issues": [
    {
      "key": "ALPHA-2",
      "fields": {
        "summary": "Add feature",
        "status": {"name": "In Progress"},
        "fixVersions": [{"name": "1.3.0.0"}]
      }
    },
    {
      "key": "ALPHA-3",
      "fields": {
        "summary": "Add second feature",
        "status": {"name": "Resolved"},
        "fixVersions": []
      }
    }
  ]
}
EOF
}

update_jira_issue_fix_version() {
  local jira_base_url_value="${1}"
  local issue_key="${2}"
  local release_name="${3}"

  printf '%s|%s|%s\n' "${jira_base_url_value}" "${issue_key}" "${release_name}" >> "${JIGGIT_TEST_ASSIGN_FIX_VERSION_UPDATE_LOG}"
}

test_run_assign_fix_version_main_can_apply_missing_fix_version_updates() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local repo_dir="${TEST_TMPDIR}/assign-fix-version-repo"
  create_repo_for_assign_fix_version "${repo_dir}"

  local projects_file="${TEST_TMPDIR}/projects.toml"
  cat > "${projects_file}" <<EOF
[jira]
base_url = "https://jira.example.test"
bearer_token = "token"

[project_a]
repo_path = "${repo_dir}"
remote_url = "git@github.com:example/assign-fix-version-repo.git"
jira_project_key = "ALPHA"
jira_regexes = ["ALPHA-[0-9]+"]
environments = ["prod"]
EOF

  JIGGIT_TEST_ENV_VERSION_BY_NAME["project_a:prod"]="v1.2.0.0"

  cat > "${TEST_TMPDIR}/assign-input.txt" <<'EOF'
y
EOF

  local output
  output="$(
    JIGGIT_CAN_PROMPT_INTERACTIVELY=true \
    JIGGIT_PROMPT_INPUT_FILE="${TEST_TMPDIR}/assign-input.txt" \
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    run_assign_fix_version_main project_a --release 1.3
  )"

  local update_log
  update_log="$(cat "${JIGGIT_TEST_ASSIGN_FIX_VERSION_UPDATE_LOG}")"
  local fetch_log
  fetch_log="$(cat "${JIGGIT_TEST_ASSIGN_FIX_VERSION_FETCH_LOG}")"
  assert_contains "${output}" "# jiggit assign-fix-version" "render assign-fix-version heading"
  assert_contains "${output}" "Release: \`1.3.0.0\`" "resolve canonical release name"
  assert_contains "${output}" "fix_version: \`1.3.0.0\`" "render existing fix version"
  assert_contains "${output}" "fix_version: \`MISSING\`" "render missing fix version"
  assert_contains "${output}" "Missing selected fixVersion: \`1\`" "count issues missing selected fix version"
  assert_contains "${output}" "## Update Result" "render update result section"
  assert_contains "${output}" "applied: \`1\`" "report applied update count"
  assert_contains "${update_log}" "https://jira.example.test|ALPHA-3|1.3.0.0" "update only the missing issue"
  assert_contains "${fetch_log}" "https://jira.example.test||ALPHA-2 ALPHA-3" "pass all issue keys with blank auth reference"
}

test_run_assign_fix_version_main_prints_matches_when_release_is_ambiguous() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local repo_dir="${TEST_TMPDIR}/assign-fix-version-repo"
  create_repo_for_assign_fix_version "${repo_dir}"

  local projects_file="${TEST_TMPDIR}/projects.toml"
  cat > "${projects_file}" <<EOF
[jira]
base_url = "https://jira.example.test"
bearer_token = "token"

[project_a]
repo_path = "${repo_dir}"
remote_url = "git@github.com:example/assign-fix-version-repo.git"
jira_project_key = "ALPHA"
jira_regexes = ["ALPHA-[0-9]+"]
environments = ["prod"]
EOF

  local output=""
  if output="$(
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    run_assign_fix_version_main project_a --release 1. 2>&1
  )"; then
    fail "exit when release query matches multiple releases"
  else
    pass "exit when release query matches multiple releases"
    assert_contains "${output}" "matched multiple Jira releases" "report ambiguous release query"
    assert_contains "${output}" "\`1.3.0.0\`" "print first matching release"
    assert_contains "${output}" "\`1.4.0.0\`" "print second matching release"
  fi
}

test_run_assign_fix_version_main_scopes_release_resolution_by_project_prefix() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local repo_dir="${TEST_TMPDIR}/assign-fix-version-repo"
  create_repo_for_assign_fix_version "${repo_dir}"

  local projects_file="${TEST_TMPDIR}/projects.toml"
  cat > "${projects_file}" <<EOF
[jira]
base_url = "https://jira.example.test"
bearer_token = "token"

[project_a]
repo_path = "${repo_dir}"
remote_url = "git@github.com:example/assign-fix-version-repo.git"
jira_project_key = "ALPHA"
jira_regexes = ["ALPHA-[0-9]+"]
jira_release_prefix = ["Udbyderportal_"]
environments = ["prod"]
EOF

  JIGGIT_TEST_ENV_VERSION_BY_NAME["project_a:prod"]="v1.2.0.0"

  # shellcheck disable=SC2329
  fetch_jira_releases() {
    cat <<'EOF'
[
  {"name": "Testtjeneste_1.23.0"},
  {"name": "Udbyderportal_1.23.0"}
]
EOF
  }

  local output
  output="$(
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    run_assign_fix_version_main project_a --release 1.23.0
  )"

  assert_contains "${output}" "Release: \`Udbyderportal_1.23.0\`" "resolve the project-scoped prefixed release"
  if [[ "${output}" == *"matched multiple Jira releases"* ]]; then
    fail "avoid ambiguous release output when only one project-scoped release matches"
  else
    pass "avoid ambiguous release output when only one project-scoped release matches"
  fi
}

run_tests "$@"
