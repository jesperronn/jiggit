#!/usr/bin/env bash
set -euo pipefail

pushd "$(dirname "$0")/../.." > /dev/null || exit 1

source bin/lib/bash_test.sh
source bin/lib/releases_command.sh

TEST_TMPDIR=""

setup_tmpdir() {
  TEST_TMPDIR="$(mktemp -d /tmp/jiggit-releases-test.XXXXXX)"
  unset JIRA_BASE_URL
  unset JIRA_API_TOKEN
  unset JIRA_BEARER_TOKEN
  unset JIRA_USER_EMAIL
}

cleanup_tmpdir() {
  if [[ -n "${TEST_TMPDIR}" && -d "${TEST_TMPDIR}" ]]; then
    rm -rf "${TEST_TMPDIR}"
  fi
}

create_repo_for_releases() {
  local repo_dir="${1}"

  mkdir -p "${repo_dir}"
  git init "${repo_dir}" >/dev/null 2>&1
  git -C "${repo_dir}" config user.name "Jiggit Test"
  git -C "${repo_dir}" config user.email "jiggit@example.com"
  printf 'one\n' > "${repo_dir}/README.md"
  git -C "${repo_dir}" add README.md
  git -C "${repo_dir}" commit -m "initial" >/dev/null 2>&1
  git -C "${repo_dir}" tag v2.1.0.26
}

# Override live Jira fetches so tests stay local and deterministic.
fetch_jira_releases() {
  local jira_base_url="${1}"
  local jira_project_key="${2}"
  printf '%s|%s\n' "${jira_base_url}" "${jira_project_key}" >> "${TEST_TMPDIR}/fetch.log"

  cat <<'EOF'
[
  {
    "name": "2.1.0.25",
    "released": true,
    "archived": false,
    "releaseDate": "2026-02-10",
    "issuesStatusForFixVersion": { "toDo": 0, "inProgress": 0, "done": 3 }
  },
  {
    "name": "2.1.0.26",
    "released": false,
    "archived": false,
    "releaseDate": "2026-03-30",
    "issuesStatusForFixVersion": { "toDo": 2, "inProgress": 1, "done": 4 }
  },
  {
    "name": "other_9.9.9",
    "released": false,
    "archived": false,
    "releaseDate": "2026-04-01",
    "issuesStatusForFixVersion": { "toDo": 1, "inProgress": 0, "done": 0 }
  }
]
EOF
}

test_run_releases_main_renders_releases_report() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local repo_dir="${TEST_TMPDIR}/releases-repo"
  create_repo_for_releases "${repo_dir}"

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
jira_release_prefix = ["2."]
environments = []
EOF

  local output
  output="$(
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    run_releases_main project-a
  )"

  assert_contains "${output}" "# jiggit releases" "render releases heading"
  assert_contains "${output}" "Project: \`project-a\`" "render project id"
  assert_contains "${output}" "\`2.1.0.26\`" "render release name"
  assert_contains "${output}" "release date: \`2026-03-30\`" "render release date"
  assert_contains "${output}" "issue count: \`7\`" "render issue count"
  assert_contains "${output}" "matches git tag: \`yes\`" "render git tag hint"
  assert_contains "${output}" "\`2.1.0.25\`" "render older release too"
  assert_contains "${output}" "next step: \`jiggit changes project-a --from-env prod --to 2.1.0.26\`" "render changes next step"
  if [[ "${output}" == *"other_9.9.9"* ]]; then
    fail "exclude releases outside the project prefix"
  else
    pass "exclude releases outside the project prefix"
  fi

  local fetch_log
  fetch_log="$(sed -n '1,20p' "${TEST_TMPDIR}/fetch.log")"
  assert_contains "${fetch_log}" "https://jira.example.test|JIRA" "fetch jira releases for configured project key"
}

test_run_releases_main_defaults_to_current_configured_repo() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local repo_dir="${TEST_TMPDIR}/releases-repo"
  create_repo_for_releases "${repo_dir}"

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
    cd "${repo_dir}"
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    run_releases_main
  )"

  assert_contains "${output}" "# jiggit releases" "render releases heading from current repo"
  assert_contains "${output}" "Project: \`project-a\`" "resolve releases project from current repo"
}

test_run_releases_main_renders_next_step_when_jira_project_key_is_missing() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local repo_dir="${TEST_TMPDIR}/releases-repo"
  create_repo_for_releases "${repo_dir}"

  local projects_file="${TEST_TMPDIR}/projects.toml"
  cat > "${projects_file}" <<EOF
[jira]
base_url = "https://jira.example.test"
bearer_token = "token"

[project-a]
repo_path = "${repo_dir}"
remote_url = "git@github.com:example/project-a.git"
environments = []
EOF

  local output=""
  if output="$(
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    run_releases_main project-a 2>&1
  )"; then
    fail "fail releases when jira project key is missing"
  else
    pass "fail releases when jira project key is missing"
    assert_contains "${output}" "# jiggit releases" "render releases heading on config failure"
    assert_contains "${output}" "status: \`missing jira project key\`" "render jira key failure status"
    assert_contains "${output}" "next step: \`jiggit config\`" "render config next step for missing jira key"
  fi
}

test_project_release_inventory_summary_scopes_by_jira_release_prefix() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local projects_file="${TEST_TMPDIR}/projects.toml"
  cat > "${projects_file}" <<'EOF'
[project-a]
jira_release_prefix = ["2."]
EOF

  local summary
  summary="$(
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    bash -lc '
      source bin/lib/releases_command.sh
      load_project_config
      project_release_inventory_summary "project-a" '"'"'[
        {"name":"2.1.0.25","released":true,"archived":false,"releaseDate":"2026-02-10"},
        {"name":"2.1.0.26","released":false,"archived":false,"releaseDate":"2026-03-30"},
        {"name":"other_9.9.9","released":false,"archived":false,"releaseDate":"2026-04-01"}
      ]'"'"'
    '
  )"

  assert_eq "1 released, 1 unreleased -- 2.1.0.26" "${summary}" "summarize only project-scoped releases"
}

run_tests "$@"
