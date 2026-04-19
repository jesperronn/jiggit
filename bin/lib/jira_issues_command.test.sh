#!/usr/bin/env bash
set -euo pipefail

pushd "$(dirname "$0")/../.." > /dev/null || exit 1

source bin/lib/bash_test.sh
source bin/lib/jira_issues_command.sh

TEST_TMPDIR=""

setup_tmpdir() {
  TEST_TMPDIR="$(mktemp -d /tmp/jiggit-jira-issues-test.XXXXXX)"
}

cleanup_tmpdir() {
  if [[ -n "${TEST_TMPDIR}" && -d "${TEST_TMPDIR}" ]]; then
    rm -rf "${TEST_TMPDIR}"
  fi
}

create_repo_for_jira_issues() {
  local repo_dir="${1}"

  mkdir -p "${repo_dir}"
  git init "${repo_dir}" >/dev/null 2>&1
}

# Override live Jira release fetches so tests stay local and deterministic.
fetch_jira_releases() {
  local jira_base_url="${1}"
  local jira_project_key="${2}"
  printf 'releases|%s|%s\n' "${jira_base_url}" "${jira_project_key}" >> "${TEST_TMPDIR}/fetch.log"

  cat <<'EOF'
[
  { "name": "2.1.0.26", "released": true, "archived": false, "releaseDate": "2026-02-10" },
  { "name": "2.1.0.27-hotfix", "released": false, "archived": false, "releaseDate": "2026-03-11" },
  { "name": "3.0.0.1", "released": false, "archived": false, "releaseDate": "2026-04-01" }
]
EOF
}

# Override live Jira issue fetches so tests stay local and deterministic.
fetch_jira_issues_for_release() {
  local jira_base_url="${1}"
  local jira_project_key="${2}"
  local release_name="${3}"
  printf 'issues|%s|%s|%s\n' "${jira_base_url}" "${jira_project_key}" "${release_name}" >> "${TEST_TMPDIR}/fetch.log"

  cat <<'EOF'
{
  "issues": [
    {
      "key": "JIRA-123",
      "fields": {
        "summary": "Fix login flow",
        "status": { "name": "Done" },
        "labels": ["release", "login"],
        "fixVersions": [{ "name": "2.1.0.26" }]
      }
    },
    {
      "key": "JIRA-124",
      "fields": {
        "summary": "Adjust copy",
        "status": { "name": "In Progress" },
        "labels": [],
        "fixVersions": []
      }
    }
  ]
}
EOF
}

test_build_jira_release_issues_jql_queries_fix_and_affected_versions() {
  local actual
  actual="$(build_jira_release_issues_jql "SKOLELOGIN" "Api-server_1.2.0")"

  assert_eq \
    'project = "SKOLELOGIN" AND (fixVersion = "Api-server_1.2.0" OR affectedVersion = "Api-server_1.2.0") ORDER BY key ASC' \
    "${actual}" \
    "build release issues JQL with fixVersion and affectedVersion"
}

test_select_latest_registered_release_name_prefers_newest_unreleased_release() {
  local actual
  actual="$(
    select_latest_registered_release_name '[
      { "name": "1.0.0", "released": true, "archived": false, "releaseDate": "2026-01-01" },
      { "name": "1.1.0", "released": false, "archived": false, "releaseDate": "2026-02-01" },
      { "name": "1.2.0", "released": false, "archived": false, "releaseDate": "2026-03-01" }
    ]'
  )"

  assert_eq "1.2.0" "${actual}" "default latest release prefers newest unreleased release"
}

test_run_jira_issues_main_prints_matches_and_exits_when_fuzzy_query_is_ambiguous() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local projects_file="${TEST_TMPDIR}/projects.toml"
  cat > "${projects_file}" <<'EOF'
[jira]
base_url = "https://jira.example.test"
bearer_token = "token"

[project-a]
repo_path = "/tmp/project-a"
remote_url = "git@github.com:example/project-a.git"
jira_project_key = "JIRA"
jira_regexes = ["JIRA-[0-9]+"]
environments = []
EOF

  local output=""
  if output="$(
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    run_jira_issues_main project-a --release 2.1.0 2>&1
  )"; then
    fail "exit when fuzzy release query matches several releases"
  else
    pass "exit when fuzzy release query matches several releases"
    assert_contains "${output}" 'Multiple Jira releases match "2.1.0":' "report ambiguous release query"
    assert_contains "${output}" "- 2.1.0.26" "print first matching release"
    assert_contains "${output}" "- 2.1.0.27-hotfix" "print second matching release"
  fi
}

test_run_jira_issues_main_defaults_to_latest_registered_release() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local projects_file="${TEST_TMPDIR}/projects.toml"
  cat > "${projects_file}" <<'EOF'
[jira]
base_url = "https://jira.example.test"
bearer_token = "token"

[project-a]
repo_path = "/tmp/project-a"
remote_url = "git@github.com:example/project-a.git"
jira_project_key = "JIRA"
jira_regexes = ["JIRA-[0-9]+"]
environments = []
EOF

  local output
  output="$(
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    run_jira_issues_main project-a
  )"

  assert_contains "${output}" "Release: \`3.0.0.1\`" "default jira-issues to latest registered release"

  local fetch_log
  fetch_log="$(sed -n '1,20p' "${TEST_TMPDIR}/fetch.log")"
  assert_contains "${fetch_log}" "issues|https://jira.example.test|JIRA|3.0.0.1" "fetch issues for latest registered release by default"
}

test_run_jira_issues_main_renders_issues_for_single_fuzzy_match() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local projects_file="${TEST_TMPDIR}/projects.toml"
  cat > "${projects_file}" <<'EOF'
[jira]
base_url = "https://jira.example.test"
bearer_token = "token"

[project-a]
repo_path = "/tmp/project-a"
remote_url = "git@github.com:example/project-a.git"
jira_project_key = "JIRA"
jira_regexes = ["JIRA-[0-9]+"]
environments = []
EOF

  local output
  output="$(
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    run_jira_issues_main project-a --release 27-hot
  )"

  assert_contains "${output}" "# jiggit jira-issues" "render jira-issues heading"
  assert_contains "${output}" "Release: \`2.1.0.27-hotfix\`" "resolve single fuzzy release match"
  assert_contains "${output}" "\`JIRA-123\`" "render first issue key"
  assert_contains "${output}" "title: \`Fix login flow\`" "render issue summary"
  assert_contains "${output}" "status: \`Done\`" "render issue status"
  assert_contains "${output}" "labels: \`release, login\`" "render issue labels"
  assert_contains "${output}" "fix_version: \`2.1.0.26\`" "render populated fix version"
  assert_contains "${output}" "fix_version: \`MISSING\`" "render missing fix version"

  local fetch_log
  fetch_log="$(sed -n '1,20p' "${TEST_TMPDIR}/fetch.log")"
  assert_contains "${fetch_log}" "releases|https://jira.example.test|JIRA" "fetch releases before fuzzy matching"
  assert_contains "${fetch_log}" "issues|https://jira.example.test|JIRA|2.1.0.27-hotfix" "fetch issues for resolved release"
}

test_run_jira_issues_main_accepts_repo_path_selector() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local repo_dir="${TEST_TMPDIR}/project-a"
  create_repo_for_jira_issues "${repo_dir}"

  local projects_file="${TEST_TMPDIR}/projects.toml"
  cat > "${projects_file}" <<EOF
[jira]
base_url = "https://jira.example.test"
bearer_token = "token"

[project-a]
repo_path = "${repo_dir}"
remote_url = "git@github.com:example/project-a.git"
jira_project_key = "JIRA"
jira_regexes = ["JIRA-[0-9]+"]
environments = []
EOF

  local output
  output="$(
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    run_jira_issues_main "${repo_dir}" --release 27-hot
  )"

  assert_contains "${output}" "# jiggit jira-issues" "render jira-issues heading from repo path"
  assert_contains "${output}" "Project: \`project-a\`" "resolve jira-issues project from repo path"
}

test_run_jira_issues_main_renders_next_step_when_jira_base_url_is_missing() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local projects_file="${TEST_TMPDIR}/projects.toml"
  cat > "${projects_file}" <<'EOF'
[project-a]
repo_path = "/tmp/project-a"
remote_url = "git@github.com:example/project-a.git"
jira_project_key = "JIRA"
jira_regexes = ["JIRA-[0-9]+"]
environments = []
EOF

  local output=""
  if output="$(
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    run_jira_issues_main project-a --release 2.1.0 2>&1
  )"; then
    fail "fail jira-issues when jira base url is missing"
  else
    pass "fail jira-issues when jira base url is missing"
    assert_contains "${output}" "# jiggit jira-issues" "render jira-issues heading on config failure"
    assert_contains "${output}" "status: \`missing jira base url\`" "render jira base url failure status"
    assert_contains "${output}" "next step: \`jiggit config\`" "render config next step for missing jira base url"
  fi
}

run_tests "$@"
