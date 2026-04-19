#!/usr/bin/env bash
set -euo pipefail

pushd "$(dirname "$0")/../.." > /dev/null || exit 1

source bin/lib/bash_test.sh
source bin/lib/overview_command.sh

TEST_TMPDIR=""
declare -A JIGGIT_TEST_OVERVIEW_ENV_VERSION_BY_NAME=()

setup_tmpdir() {
  TEST_TMPDIR="$(mktemp -d /tmp/jiggit-overview-test.XXXXXX)"
}

cleanup_tmpdir() {
  if [[ -n "${TEST_TMPDIR}" && -d "${TEST_TMPDIR}" ]]; then
    rm -rf "${TEST_TMPDIR}"
  fi
}

create_repo_for_overview() {
  local repo_dir="${1}"
  local remote_url="${2}"

  mkdir -p "${repo_dir}"
  git init "${repo_dir}" >/dev/null 2>&1
  git -C "${repo_dir}" config user.name "Jiggit Test"
  git -C "${repo_dir}" config user.email "jiggit@example.com"
  git -C "${repo_dir}" branch -M main
  git -C "${repo_dir}" remote add origin "${remote_url}"

  printf 'one\n' > "${repo_dir}/README.md"
  git -C "${repo_dir}" add README.md
  git -C "${repo_dir}" commit -m "ALPHA-1 initial commit" >/dev/null 2>&1
  git -C "${repo_dir}" tag v1.2.0.0
  git -C "${repo_dir}" update-ref refs/remotes/origin/main "$(git -C "${repo_dir}" rev-parse HEAD)"
  git -C "${repo_dir}" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

  printf 'two\n' >> "${repo_dir}/README.md"
  git -C "${repo_dir}" add README.md
  git -C "${repo_dir}" commit -m "ALPHA-2 add feature" >/dev/null 2>&1
  git -C "${repo_dir}" update-ref refs/remotes/origin/main "$(git -C "${repo_dir}" rev-parse HEAD)"
}

# Override environment lookups so overview tests stay local and deterministic.
fetch_project_environment_version() {
  local project_id="${1}"
  local environment_name="${2}"

  printf '%s\n' "${JIGGIT_TEST_OVERVIEW_ENV_VERSION_BY_NAME["${project_id}:${environment_name}"]:-}"
}

# Override Jira releases so overview tests do not require network access.
fetch_jira_releases() {
  local jira_base_url="${1}"
  local jira_project_key="${2}"
  local auth_reference="${3:-}"

  printf '%s|%s|%s\n' "${jira_base_url}" "${jira_project_key}" "${auth_reference}" >> "${TEST_TMPDIR}/releases.log"
  cat <<'EOF'
[
  {"name":"v1.3.0.0","released":false,"archived":false,"releaseDate":"2026-03-28"},
  {"name":"v1.2.0.0","released":true,"archived":false,"releaseDate":"2026-03-01"}
]
EOF
}

fetch_jira_issues_by_keys() {
  local jira_base_url="${1}"
  local auth_reference="${2:-}"
  shift 2 || true

  printf '%s|%s|%s\n' "${jira_base_url}" "${auth_reference}" "$*" >> "${TEST_TMPDIR}/jira-issues.log"
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

test_run_overview_main_shows_unreleased_issue_fetch_failure() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local repo_dir="${TEST_TMPDIR}/project-a"
  local projects_file="${TEST_TMPDIR}/projects.toml"
  create_repo_for_overview "${repo_dir}" "git@github.com:example/project-a.git"
  cat > "${projects_file}" <<EOF
[jira]
base_url = "https://jira.example.com"
bearer_token = "token"

[project-a]
repo_path = "${repo_dir}"
remote_url = "git@github.com:example/project-a.git"
jira_project_key = "JIRA"
jira_regexes = ["ALPHA-[0-9]+"]
environments = ["prod"]
EOF

  JIGGIT_TEST_OVERVIEW_ENV_VERSION_BY_NAME["project-a:prod"]="v1.2.0.0"

  # shellcheck disable=SC2329
  fetch_jira_issues_by_keys() {
    return 1
  }

  local output
  output="$(
    JIGGIT_PROJECTS_FILE="${projects_file}" \
      JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
      run_overview_main project-a
  )"

  assert_contains "${output}" "Unreleased Issues" "render unreleased issues subsection on jira failure"
  assert_contains "${output}" "status: unable to fetch jira issues" "render explicit issue fetch failure"
  assert_contains "${output}" "next step: jiggit jira-check project-a" "suggest jira-check for issue fetch failure"
}

test_run_overview_main_renders_missing_shared_jira_config_diagnostic() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local repo_dir="${TEST_TMPDIR}/project-a"
  local projects_file="${TEST_TMPDIR}/projects.toml"
  create_repo_for_overview "${repo_dir}" "git@github.com:example/project-a.git"
  cat > "${projects_file}" <<EOF
[project-a]
repo_path = "${repo_dir}"
remote_url = "git@github.com:example/project-a.git"
jira_project_key = "JIRA"
jira_regexes = ["ALPHA-[0-9]+"]
environments = ["prod"]
EOF

  JIGGIT_TEST_OVERVIEW_ENV_VERSION_BY_NAME["project-a:prod"]="v1.2.0.0"

  local output
  output="$(
    JIGGIT_PROJECTS_FILE="${projects_file}" \
      JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
      run_overview_main project-a
  )"

  assert_contains "${output}" "Jira base URL: \`missing\`" "render missing shared jira base url diagnostic"
  assert_contains "${output}" "Jira auth mode: \`missing\`" "render missing shared jira auth diagnostic"
  assert_contains "${output}" "Jira API token: \`missing\`" "render missing shared jira token diagnostic"
}

test_run_overview_main_shows_no_jira_keys_for_commit_span() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local repo_dir="${TEST_TMPDIR}/docs-only"
  local projects_file="${TEST_TMPDIR}/projects.toml"

  mkdir -p "${repo_dir}"
  git init "${repo_dir}" >/dev/null 2>&1
  git -C "${repo_dir}" config user.name "Jiggit Test"
  git -C "${repo_dir}" config user.email "jiggit@example.com"
  git -C "${repo_dir}" branch -M main
  git -C "${repo_dir}" remote add origin "git@github.com:example/docs-only.git"
  printf 'one\n' > "${repo_dir}/README.md"
  git -C "${repo_dir}" add README.md
  git -C "${repo_dir}" commit -m "initial commit" >/dev/null 2>&1
  git -C "${repo_dir}" tag v1.2.0.0
  git -C "${repo_dir}" update-ref refs/remotes/origin/main "$(git -C "${repo_dir}" rev-parse HEAD)"
  git -C "${repo_dir}" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  printf 'two\n' >> "${repo_dir}/README.md"
  git -C "${repo_dir}" add README.md
  git -C "${repo_dir}" commit -m "docs: expand readme" >/dev/null 2>&1
  git -C "${repo_dir}" update-ref refs/remotes/origin/main "$(git -C "${repo_dir}" rev-parse HEAD)"

  cat > "${projects_file}" <<EOF
[jira]
base_url = "https://jira.example.com"
bearer_token = "token"

[docs-only]
repo_path = "${repo_dir}"
remote_url = "git@github.com:example/docs-only.git"
jira_project_key = "DOCS"
jira_regexes = ["DOCS-[0-9]+"]
environments = ["prod"]
EOF

  JIGGIT_TEST_OVERVIEW_ENV_VERSION_BY_NAME["docs-only:prod"]="v1.2.0.0"

  local output
  output="$(
    JIGGIT_PROJECTS_FILE="${projects_file}" \
      JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
      run_overview_main docs-only
  )"

  assert_contains "${output}" "Unreleased Issues" "render unreleased issues subsection without jira keys"
  assert_contains "${output}" "status: no jira keys found in commit span" "render explicit no-jira-keys status"
  assert_contains "${output}" "next step: jiggit env-diff docs-only --base prod" "suggest env-diff when no jira keys are found"
}

test_run_overview_main_defaults_to_current_configured_repo() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local repo_dir="${TEST_TMPDIR}/project-a"
  local projects_file="${TEST_TMPDIR}/projects.toml"
  create_repo_for_overview "${repo_dir}" "git@github.com:example/project-a.git"
  cat > "${projects_file}" <<EOF
[jira]
base_url = "https://jira.example.com"
bearer_token = "token"

[project-a]
repo_path = "${repo_dir}"
remote_url = "git@github.com:example/project-a.git"
jira_project_key = "ALPHA"
jira_regexes = ["ALPHA-[0-9]+"]
environments = ["prod", "prep"]
EOF

  JIGGIT_TEST_OVERVIEW_ENV_VERSION_BY_NAME["project-a:prod"]="v1.2.0.0"
  JIGGIT_TEST_OVERVIEW_ENV_VERSION_BY_NAME["project-a:prep"]="v1.2.0.0"

  local output
  output="$(
    cd "${repo_dir}"
    # shellcheck disable=SC2119
    JIGGIT_PROJECTS_FILE="${projects_file}" \
      JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
      run_overview_main
  )"

  assert_contains "${output}" "# jiggit overview" "render overview heading"
  assert_contains "${output}" "## project-a \`jiggit config\`" "default to current configured project with command in heading"
  assert_contains "${output}" "Jira base URL: \`https://jira.example.com\`" "render shared jira base url diagnostic"
  assert_contains "${output}" "Jira auth mode: \`bearer_token\`" "render shared jira auth diagnostic"
  assert_contains "${output}" "Jira API token: \`missing\`" "render shared jira token diagnostic"
  assert_contains "${output}" "## Versions \`jiggit env-versions project-a\`" "render versions section command in heading"
  assert_contains "${output}" "prod: v1.2.0.0" "render prod environment version"
  assert_contains "${output}" "prep: v1.2.0.0" "render prep environment version"
  assert_contains "${output}" "## Next Release \`jiggit next-release project-a --base prod\`" "render next-release section heading with command"
  assert_contains "${output}" "- base version (prod): v1.2.0.0" "render compact base version line"
  assert_contains "${output}" "- commit count ahead: 1" "render compact commit count line"
  assert_contains "${output}" "- **suggested next release: v1.3.0**" "render bold suggested next release line"
  assert_contains "${output}" "Unreleased Issues (2)" "render compact unreleased issues subsection with count"
  assert_contains "${output}" "issue count: 2" "render unreleased issue count"
  assert_contains "${output}" "issues with expected fixVersion: 1" "render matching fix version count"
  assert_contains "${output}" "issues missing expected fixVersion: 1" "render missing fix version count"
  assert_contains "${output}" "ALPHA-3: status: Resolved, fix_version: MISSING, subject: Add second feature" "render resolved unreleased issue detail"
  assert_contains "${output}" "ALPHA-2: status: In Progress, fix_version: 1.3.0.0, subject: Add feature" "render implement unreleased issue detail"
  assert_contains "${output}" "Next steps:" "render next steps label"
  assert_contains "${output}" "- jiggit env-diff project-a --base prod" "render next-release diff command"
  assert_contains "${output}" "- jiggit next-release project-a --base prod" "render next-release create command"

  local jira_issues_log
  jira_issues_log="$(sed -n '1,20p' "${TEST_TMPDIR}/jira-issues.log")"
  assert_contains "${jira_issues_log}" "https://jira.example.com|project-a|ALPHA-2" "pass the first unreleased issue key through overview issue fetch"
}

test_run_overview_main_defaults_to_all_projects_outside_configured_repo() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local repo_one="${TEST_TMPDIR}/alpha"
  local repo_two="${TEST_TMPDIR}/beta"
  local projects_file="${TEST_TMPDIR}/projects.toml"
  create_repo_for_overview "${repo_one}" "git@github.com:example/alpha.git"
  create_repo_for_overview "${repo_two}" "git@github.com:example/beta.git"
  cat > "${projects_file}" <<EOF
[jira]
base_url = "https://jira.example.com"
bearer_token = "token"

[alpha]
repo_path = "${repo_one}"
remote_url = "git@github.com:example/alpha.git"
jira_project_key = "ALPHA"
jira_regexes = ["ALPHA-[0-9]+"]
environments = ["prod"]

[beta]
repo_path = "${repo_two}"
remote_url = "git@github.com:example/beta.git"
jira_project_key = "BETA"
jira_regexes = ["BETA-[0-9]+"]
EOF

  JIGGIT_TEST_OVERVIEW_ENV_VERSION_BY_NAME["alpha:prod"]="v1.2.0.0"

  local output
  output="$(
    cd "${TEST_TMPDIR}"
    # shellcheck disable=SC2119
    JIGGIT_PROJECTS_FILE="${projects_file}" \
      JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
      run_overview_main
  )"

  assert_contains "${output}" "## alpha \`jiggit config\`" "render first project when outside configured repo"
  assert_contains "${output}" "## beta \`jiggit config\`" "render second project when outside configured repo"
  assert_contains "${output}" "environments: none" "render missing environment summary"
  assert_contains "${output}" "- status: missing prod base" "render next-release warning for project without prod"
  assert_contains "${output}" "Next steps:" "render next steps label when prod base is missing"
  assert_contains "${output}" "- jiggit config" "suggest config command when prod base is missing"
}

test_run_overview_main_shows_source_hint_for_missing_jira_project_key() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local repo_dir="${TEST_TMPDIR}/project-b"
  local projects_file="${TEST_TMPDIR}/projects.toml"
  create_repo_for_overview "${repo_dir}" "git@github.com:example/project-b.git"
  cat > "${projects_file}" <<EOF
[jira]
base_url = "https://jira.example.com"
bearer_token = "token"

[project-b]
repo_path = "${repo_dir}"
remote_url = "git@github.com:example/project-b.git"
environments = ["prod"]
EOF

  JIGGIT_TEST_OVERVIEW_ENV_VERSION_BY_NAME["project-b:prod"]="v1.2.0.0"

  local output
  output="$(
    JIGGIT_PROJECTS_FILE="${projects_file}" \
      JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
      run_overview_main project-b
  )"

  assert_contains "${output}" "jira project key: missing" "render missing jira project key"
  assert_contains "${output}" "source: ${projects_file}" "render project source file for missing jira key"
  assert_contains "${output}" "next step: jiggit config" "render config next step adjacent to missing jira key"
}

test_run_overview_main_renders_version_diagnostics_for_prod_drift() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local repo_dir="${TEST_TMPDIR}/project-b"
  local projects_file="${TEST_TMPDIR}/projects.toml"
  create_repo_for_overview "${repo_dir}" "git@github.com:example/project-b.git"
  cat > "${projects_file}" <<EOF
[jira]
base_url = "https://jira.example.com"
bearer_token = "token"

[project-b]
repo_path = "${repo_dir}"
remote_url = "git@github.com:example/project-b.git"
jira_project_key = "JIRA"
jira_regexes = ["JIRA-[0-9]+"]
environments = ["prod", "ft", "lt"]
EOF

  JIGGIT_TEST_OVERVIEW_ENV_VERSION_BY_NAME["project-b:prod"]="v1.21.0.132"
  JIGGIT_TEST_OVERVIEW_ENV_VERSION_BY_NAME["project-b:ft"]="v1.22.0.55"
  JIGGIT_TEST_OVERVIEW_ENV_VERSION_BY_NAME["project-b:lt"]="v1.21.0.200"

  local output
  output="$(
    JIGGIT_PROJECTS_FILE="${projects_file}" \
      JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
      run_overview_main project-b
  )"

  assert_contains "${output}" "Version Diagnostics" "render version diagnostics subsection"
  assert_contains "${output}" "ft: v1.22.0.55" "render environment version without padded key formatting"
  assert_contains "${output}" "ft: ahead of prod at major/minor level (v1.22.0.55 vs v1.21.0.132); pending deployment" "render pending deployment diagnostic"
  assert_contains "${output}" "lt: ahead of prod within the same minor (v1.21.0.200 vs v1.21.0.132); new minor release needed" "render same-minor release-needed diagnostic"
  assert_contains "${output}" "next step: jiggit env-diff project-b --base prod" "render version-drift next step"
}

test_run_overview_main_honors_global_project_selector() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local repo_one="${TEST_TMPDIR}/alpha"
  local repo_two="${TEST_TMPDIR}/beta"
  local projects_file="${TEST_TMPDIR}/projects.toml"
  create_repo_for_overview "${repo_one}" "git@github.com:example/alpha.git"
  create_repo_for_overview "${repo_two}" "git@github.com:example/beta.git"
  cat > "${projects_file}" <<EOF
[jira]
base_url = "https://jira.example.com"
bearer_token = "token"

[alpha]
repo_path = "${repo_one}"
remote_url = "git@github.com:example/alpha.git"
jira_project_key = "ALPHA"
environments = ["prod"]

[beta]
repo_path = "${repo_two}"
remote_url = "git@github.com:example/beta.git"
jira_project_key = "BETA"
environments = ["prod"]
EOF

  JIGGIT_TEST_OVERVIEW_ENV_VERSION_BY_NAME["alpha:prod"]="v1.2.0.0"
  JIGGIT_TEST_OVERVIEW_ENV_VERSION_BY_NAME["beta:prod"]="v1.2.0.0"

  local output
  output="$(
    cd "${TEST_TMPDIR}"
    JIGGIT_PROJECT_SELECTORS="beta" \
      JIGGIT_PROJECTS_FILE="${projects_file}" \
      JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
      run_overview_main
  )"

  assert_contains "${output}" "## beta" "overview uses global project selector"
  if [[ "${output}" == *"## alpha"* ]]; then
    fail "overview excludes unselected projects"
  else
    pass "overview excludes unselected projects"
  fi
}

run_tests "$@"
