#!/usr/bin/env bash
set -euo pipefail

pushd "$(dirname "$0")/../.." > /dev/null || exit 1

source bin/lib/bash_test.sh
source bin/lib/next_release_command.sh

TEST_TMPDIR=""
declare -A JIGGIT_TEST_ENV_VERSION_BY_NAME=()
JIGGIT_TEST_NEXT_RELEASE_CREATE_LOG=""
JIGGIT_TEST_NEXT_RELEASE_FETCH_ISSUES_LOG=""

setup_tmpdir() {
  TEST_TMPDIR="$(mktemp -d /tmp/jiggit-next-release-test.XXXXXX)"
  JIGGIT_TEST_NEXT_RELEASE_CREATE_LOG="${TEST_TMPDIR}/create-release.log"
  JIGGIT_TEST_NEXT_RELEASE_FETCH_ISSUES_LOG="${TEST_TMPDIR}/fetch-issues.log"
  # shellcheck disable=SC2034
  JIGGIT_CAN_PROMPT_INTERACTIVELY="false"
  # shellcheck disable=SC2034
  JIGGIT_PROMPT_INPUT_FILE=""
}

cleanup_tmpdir() {
  if [[ -n "${TEST_TMPDIR}" && -d "${TEST_TMPDIR}" ]]; then
    rm -rf "${TEST_TMPDIR}"
  fi
}

create_repo_for_next_release() {
  local repo_dir="${1}"

  mkdir -p "${repo_dir}"
  git init "${repo_dir}" >/dev/null 2>&1
  git -C "${repo_dir}" config user.name "Jiggit Test"
  git -C "${repo_dir}" config user.email "jiggit@example.com"
  git -C "${repo_dir}" branch -M main
  git -C "${repo_dir}" remote add origin "git@github.com:example/next-release-repo.git"

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

# Override environment fetches so next-release tests stay local and deterministic.
fetch_project_environment_version() {
  local project_id="${1}"
  local environment_name="${2}"

  printf '%s\n' "${JIGGIT_TEST_ENV_VERSION_BY_NAME["${project_id}:${environment_name}"]:-}"
}

fetch_jira_issues_by_keys() {
  local jira_base_url="${1}"
  local auth_reference="${2:-}"
  shift 2 || true

  printf '%s|%s|%s\n' "${jira_base_url}" "${auth_reference}" "$*" >> "${JIGGIT_TEST_NEXT_RELEASE_FETCH_ISSUES_LOG}"
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

fetch_jira_project_metadata() {
  cat <<'EOF'
{
  "id": "12345",
  "key": "ALPHA",
  "name": "Alpha"
}
EOF
}

fetch_jira_releases() {
  cat <<'EOF'
[
  {
    "name": "1.2.0.0",
    "released": true,
    "archived": false,
    "releaseDate": "2026-02-10",
    "issuesStatusForFixVersion": { "toDo": 0, "inProgress": 0, "done": 3 }
  },
  {
    "name": "1.4.0.0",
    "released": false,
    "archived": false,
    "releaseDate": "2026-04-30",
    "issuesStatusForFixVersion": { "toDo": 2, "inProgress": 1, "done": 4 }
  }
]
EOF
}

create_jira_release_version() {
  local jira_base_url="${1}"
  local payload="${2}"

  printf '%s|%s\n' "${jira_base_url}" "${payload}" >> "${JIGGIT_TEST_NEXT_RELEASE_CREATE_LOG}"
  printf '%s\n' "${payload}" | jq '{name: .name}'
}

test_run_next_release_main_defaults_to_prod_and_suggests_minor_bump() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local repo_dir="${TEST_TMPDIR}/next-release-repo"
  create_repo_for_next_release "${repo_dir}"

  local projects_file="${TEST_TMPDIR}/projects.toml"
  cat > "${projects_file}" <<EOF
[jira]
base_url = "https://jira.example.test"
bearer_token = "token"

[next-release-project]
repo_path = "${repo_dir}"
remote_url = "git@github.com:example/next-release-repo.git"
jira_project_key = "ALPHA"
jira_regexes = ["ALPHA-[0-9]+"]
environments = ["prod"]
EOF

  JIGGIT_TEST_ENV_VERSION_BY_NAME["next-release-project:prod"]="v1.2.0.0"

  local output
  output="$(
    JIGGIT_PROJECTS_FILE="${projects_file}" \
      JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
      run_next_release_main next-release-project
  )"

  local fetch_log
  fetch_log="$(cat "${JIGGIT_TEST_NEXT_RELEASE_FETCH_ISSUES_LOG}")"

  assert_contains "${output}" "# jiggit next-release" "render next-release heading"
  assert_contains "${output}" "Base: \`prod\`" "default base to prod"
  assert_contains "${output}" "Base version: \`v1.2.0.0\`" "render base version"
  assert_contains "${output}" "Target: \`refs/remotes/origin/main\`" "default target to origin main"
  assert_contains "${output}" "Commit count ahead: \`2\`" "count commits ahead of prod"
  assert_contains "${output}" "Status: \`release-needed\`" "render release-needed status"
  assert_contains "${output}" "Suggested next release: \`v1.3.0.0\`" "suggest next minor release"
  assert_contains "${output}" "github.com/example/next-release-repo/compare/" "render compare url"
  assert_contains "${output}" "## Release Matrix" "render release matrix section"
  assert_contains "${output}" "combined state: \`missing-both\`" "render combined missing state"
  assert_contains "${output}" "## Jira Releases" "render jira release inventory"
  assert_contains "${output}" "\`1.4.0.0\`" "render jira release inventory entry"
  assert_contains "${output}" "## Jira Release" "render jira release creation status"
  assert_contains "${output}" "status: \`missing\`" "render jira release creation outcome"
  assert_contains "${output}" "detail: \`run interactively to create it\`" "render interactive creation next step"
  assert_contains "${output}" "## Unreleased Jira Issues" "render unreleased Jira issues section"
  assert_contains "${output}" "ALPHA-2" "render first unreleased jira issue"
  assert_contains "${output}" "release_match: \`expected-fix-version\`" "mark issue with expected fix version"
  assert_contains "${output}" "release_match: \`missing-fix-version\`" "mark issue with missing fix version"
  assert_contains "${output}" "## Next Steps" "render next-release next steps section"
  assert_contains "${output}" "jiggit releases next-release-project" "suggest releases command"
  assert_contains "${fetch_log}" "https://jira.example.test||ALPHA-2 ALPHA-3" "pass all unreleased issue keys with blank auth reference"
}

test_run_next_release_main_can_force_colored_issue_states() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local repo_dir="${TEST_TMPDIR}/next-release-repo"
  create_repo_for_next_release "${repo_dir}"

  local projects_file="${TEST_TMPDIR}/projects.toml"
  cat > "${projects_file}" <<EOF
[jira]
base_url = "https://jira.example.test"
bearer_token = "token"

[next-release-project]
repo_path = "${repo_dir}"
remote_url = "git@github.com:example/next-release-repo.git"
jira_project_key = "ALPHA"
jira_regexes = ["ALPHA-[0-9]+"]
environments = ["prod"]
EOF

  JIGGIT_TEST_ENV_VERSION_BY_NAME["next-release-project:prod"]="v1.2.0.0"

  local output
  output="$(
    JIGGIT_COLOR_OUTPUT=always \
    JIGGIT_PROJECTS_FILE="${projects_file}" \
      JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
      run_next_release_main next-release-project
  )"

  assert_contains "${output}" $'\e[1m\e[36m- `ALPHA-2`\e[0m' "render in-progress matching issue in cyan"
  assert_contains "${output}" $'\e[1m\e[38;5;202m- `ALPHA-3`\e[0m' "render missing-fix-version issue in orange"
}

test_run_next_release_main_can_create_missing_jira_release_interactively() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local repo_dir="${TEST_TMPDIR}/next-release-repo"
  create_repo_for_next_release "${repo_dir}"

  local projects_file="${TEST_TMPDIR}/projects.toml"
  cat > "${projects_file}" <<EOF
[jira]
base_url = "https://jira.example.test"
bearer_token = "token"

[next-release-project]
repo_path = "${repo_dir}"
remote_url = "git@github.com:example/next-release-repo.git"
jira_project_key = "ALPHA"
jira_regexes = ["ALPHA-[0-9]+"]
environments = ["prod"]
EOF

  JIGGIT_TEST_ENV_VERSION_BY_NAME["next-release-project:prod"]="v1.2.0.0"

  cat > "${TEST_TMPDIR}/next-release-input.txt" <<'EOF'
y

EOF

  local output
  output="$(
    JIGGIT_CAN_PROMPT_INTERACTIVELY=true \
    JIGGIT_PROMPT_INPUT_FILE="${TEST_TMPDIR}/next-release-input.txt" \
    JIGGIT_PROJECTS_FILE="${projects_file}" \
      JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
      run_next_release_main next-release-project
  )"

  local create_log
  create_log="$(cat "${JIGGIT_TEST_NEXT_RELEASE_CREATE_LOG}")"
  assert_contains "${output}" "## Jira Release" "render jira release section"
  assert_contains "${output}" "status: \`created\`" "report created jira release"
  assert_contains "${output}" "detail: \`1.3.0.0\`" "report created release name"
  assert_contains "${create_log}" "https://jira.example.test" "call Jira release creation endpoint"
  assert_contains "${create_log}" '"projectId": 12345' "send jira project id in release payload"
  assert_contains "${create_log}" '"name": "1.3.0.0"' "send suggested release name without v prefix"
}

test_run_next_release_main_accepts_repo_path_selector_and_reports_up_to_date() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local repo_dir="${TEST_TMPDIR}/next-release-repo"
  create_repo_for_next_release "${repo_dir}"
  git -C "${repo_dir}" tag v1.3.0.0

  local projects_file="${TEST_TMPDIR}/projects.toml"
  cat > "${projects_file}" <<EOF
[jira]
base_url = "https://jira.example.test"
bearer_token = "token"

[next-release-project]
repo_path = "${repo_dir}"
remote_url = "git@github.com:example/next-release-repo.git"
jira_project_key = "ALPHA"
jira_regexes = ["ALPHA-[0-9]+"]
environments = ["prod"]
EOF

  JIGGIT_TEST_ENV_VERSION_BY_NAME["next-release-project:prod"]="v1.3.0.0"

  local output
  output="$(
    JIGGIT_PROJECTS_FILE="${projects_file}" \
      JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
      run_next_release_main "${repo_dir}"
  )"

  assert_contains "${output}" "Project: \`next-release-project\`" "resolve next-release project from repo path"
  assert_contains "${output}" "Base version: \`v1.3.0.0\`" "render up-to-date base version"
  assert_contains "${output}" "Commit count ahead: \`0\`" "report no commits ahead"
  assert_contains "${output}" "Status: \`up-to-date\`" "render up-to-date status"
}

test_run_next_release_main_renders_config_guidance_when_jira_config_is_missing() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local repo_dir="${TEST_TMPDIR}/next-release-repo"
  create_repo_for_next_release "${repo_dir}"

  local projects_file="${TEST_TMPDIR}/projects.toml"
  cat > "${projects_file}" <<EOF
[next-release-project]
repo_path = "${repo_dir}"
remote_url = "git@github.com:example/next-release-repo.git"
environments = ["prod"]
EOF

  JIGGIT_TEST_ENV_VERSION_BY_NAME["next-release-project:prod"]="v1.2.0.0"

  local output
  output="$(
    JIGGIT_PROJECTS_FILE="${projects_file}" \
      JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
      run_next_release_main next-release-project
  )"

  assert_contains "${output}" "## Jira Status" "render jira status section when jira config is missing"
  assert_contains "${output}" "status: \`missing jira project key\`" "render missing jira key status"
  assert_contains "${output}" "next step: \`jiggit config\`" "suggest config as jira next step"
  assert_contains "${output}" "review effective config: \`jiggit config\`" "include config command in next steps"
}

test_run_next_release_main_fails_with_guidance_when_repo_path_is_missing() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local projects_file="${TEST_TMPDIR}/projects.toml"
  cat > "${projects_file}" <<'EOF'
[next-release-project]
repo_path = "/tmp/does-not-exist"
remote_url = "git@github.com:example/next-release-repo.git"
environments = ["prod"]
EOF

  local output=""
  if output="$(
    JIGGIT_PROJECTS_FILE="${projects_file}" \
      JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
      run_next_release_main next-release-project 2>&1
  )"; then
    fail "fail next-release when repo path is missing"
  else
    pass "fail next-release when repo path is missing"
    assert_contains "${output}" "# jiggit next-release" "render next-release heading on repo-path failure"
    assert_contains "${output}" "Status: \`missing local repo path\`" "render repo-path failure status"
    assert_contains "${output}" "Next step: \`jiggit config\`" "render config next step for missing repo path"
  fi
}

run_tests "$@"
