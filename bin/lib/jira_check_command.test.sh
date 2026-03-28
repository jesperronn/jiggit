#!/usr/bin/env bash
set -euo pipefail

pushd "$(dirname "$0")/../.." > /dev/null || exit 1

source bin/lib/bash_test.sh
source bin/lib/jira_check_command.sh

TEST_TMPDIR=""

setup_tmpdir() {
  TEST_TMPDIR="$(mktemp -d /tmp/jiggit-jira-check-test.XXXXXX)"
}

cleanup_tmpdir() {
  if [[ -n "${TEST_TMPDIR}" && -d "${TEST_TMPDIR}" ]]; then
    rm -rf "${TEST_TMPDIR}"
  fi
}

create_repo_for_jira_check() {
  local repo_dir="${1}"

  mkdir -p "${repo_dir}"
  git init "${repo_dir}" >/dev/null 2>&1
}

# Override live Jira project fetches so tests stay local and deterministic.
fetch_jira_project_metadata() {
  local jira_base_url="${1}"
  local jira_project_key="${2}"
  printf 'project|%s|%s\n' "${jira_base_url}" "${jira_project_key}" >> "${TEST_TMPDIR}/fetch.log"

  if [[ "${jira_project_key}" == "BROKEN" ]]; then
    printf 'simulated metadata failure\n' >&2
    return 1
  fi

  cat <<'EOF'
{
  "self": "https://jira.example.test/rest/api/2/project/JIRA",
  "key": "JIRA",
  "name": "Jira Project"
}
EOF
}

# Override live Jira release fetches so tests stay local and deterministic.
fetch_jira_releases() {
  local jira_base_url="${1}"
  local jira_project_key="${2}"
  printf 'releases|%s|%s\n' "${jira_base_url}" "${jira_project_key}" >> "${TEST_TMPDIR}/fetch.log"

  if [[ "${jira_project_key}" == "BROKEN" ]]; then
    printf 'simulated release failure\n' >&2
    return 1
  fi

  cat <<'EOF'
[
  { "name": "2.1.0.26" },
  { "name": "2.1.0.27" }
]
EOF
}

test_run_jira_check_main_renders_connectivity_report() {
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
      run_jira_check_main project-a
  )"

  assert_contains "${output}" "# jiggit jira-check" "render jira-check heading"
  assert_contains "${output}" "Jira project key: \`JIRA\`" "render jira project key"
  assert_contains "${output}" "Jira project name: \`Jira Project\`" "render jira project name"
  assert_contains "${output}" "Release count: \`2\`" "render release count"
  assert_contains "${output}" "Metadata URL: \`https://jira.example.test/rest/api/2/project/JIRA\`" "render metadata url"
  assert_contains "${output}" "Releases URL: \`https://jira.example.test/rest/api/2/project/JIRA/versions\`" "render releases url"
  assert_contains "${output}" "Auth: \`ok\`" "render auth status"
  assert_contains "${output}" "Connectivity: \`ok\`" "render connectivity status"

  local fetch_log
  fetch_log="$(sed -n '1,20p' "${TEST_TMPDIR}/fetch.log")"
  assert_contains "${fetch_log}" "project|https://jira.example.test|JIRA" "fetch jira project metadata"
  assert_contains "${fetch_log}" "releases|https://jira.example.test|JIRA" "fetch jira releases"
}

test_run_jira_check_main_all_checks_every_project_and_fails_at_end() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local repo_dir="${TEST_TMPDIR}/repo"
  mkdir -p "${repo_dir}"

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

[broken-project]
repo_path = "${repo_dir}"
remote_url = "git@github.com:example/broken-project.git"
jira_project_key = "BROKEN"
jira_regexes = ["BROKEN-[0-9]+"]
environments = []
EOF

  local output=""
  if output="$(
    JIGGIT_PROJECTS_FILE="${projects_file}" \
      JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
      run_jira_check_main --all 2>&1
  )"; then
    fail "fail at the end when one jira-check --all project fails"
  else
    pass "fail at the end when one jira-check --all project fails"
    assert_contains "${output}" "# jiggit jira-check" "render jira-check heading for --all"
    assert_contains "${output}" "## project-a" "render successful project section during --all"
    assert_contains "${output}" "## broken-project" "render failing project section during --all"
    assert_contains "${output}" "Connectivity: \`fail\`" "render failure state for broken project"
  fi

  assert_contains "${output}" "Jira project key: \`JIRA\`" "render healthy project jira key during --all"
  assert_contains "${output}" "Jira project key: \`BROKEN\`" "continue into broken project during --all"
}

test_run_jira_check_main_all_reports_missing_base_url_per_project() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local repo_dir="${TEST_TMPDIR}/repo"
  mkdir -p "${repo_dir}"

  local projects_file="${TEST_TMPDIR}/projects.toml"
  cat > "${projects_file}" <<EOF
[project-a]
repo_path = "${repo_dir}"
remote_url = "git@github.com:example/project-a.git"
jira_project_key = "JIRA"
jira_regexes = ["JIRA-[0-9]+"]
environments = []

[project-b]
repo_path = "${repo_dir}"
remote_url = "git@github.com:example/project-b.git"
jira_project_key = "API"
jira_regexes = ["API-[0-9]+"]
environments = []
EOF

  local output=""
  if output="$(
    JIGGIT_PROJECTS_FILE="${projects_file}" \
      JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
      run_jira_check_main --all 2>&1
  )"; then
    fail "fail at the end when jira-check --all has no Jira base URL"
  else
    pass "fail at the end when jira-check --all has no Jira base URL"
    assert_contains "${output}" "# jiggit jira-check" "render jira-check heading without Jira base URL"
    assert_contains "${output}" "## project-a" "render first project section without Jira base URL"
    assert_contains "${output}" "## project-b" "render second project section without Jira base URL"
    assert_contains "${output}" "Metadata URL: \`unknown\`" "render unknown metadata url when base url is missing"
    assert_contains "${output}" "Releases URL: \`unknown\`" "render unknown releases url when base url is missing"
    assert_contains "${output}" "Error: \`missing Jira base URL\`" "render per-project missing Jira base URL error"
  fi
}

test_run_jira_check_main_verbose_reports_per_project_urls() {
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
      JIGGIT_VERBOSE=1 VERBOSE=true \
      run_jira_check_main project-a 2>&1
  )"

  assert_contains "${output}" "[verbose] jira-check project=project-a key=JIRA" "render project verbose line"
  assert_contains "${output}" "[verbose] jira-check metadata https://jira.example.test/rest/api/2/project/JIRA" "render metadata verbose line"
  assert_contains "${output}" "[verbose] jira-check releases https://jira.example.test/rest/api/2/project/JIRA/versions" "render releases verbose line"
}

run_tests "$@"
