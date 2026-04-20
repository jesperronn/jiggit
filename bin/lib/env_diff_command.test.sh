#!/usr/bin/env bash
set -euo pipefail

pushd "$(dirname "$0")/../.." > /dev/null || exit 1

source bin/lib/bash_test.sh
source bin/lib/env_diff_command.sh

TEST_TMPDIR=""

setup_tmpdir() {
  TEST_TMPDIR="$(mktemp -d /tmp/jiggit-env-diff-test.XXXXXX)"
}

cleanup_tmpdir() {
  if [[ -n "${TEST_TMPDIR}" && -d "${TEST_TMPDIR}" ]]; then
    rm -rf "${TEST_TMPDIR}"
  fi
}

create_repo_for_env_diff() {
  local repo_dir="${1}"

  mkdir -p "${repo_dir}"
  git init "${repo_dir}" >/dev/null 2>&1
  git -C "${repo_dir}" config user.name "Jiggit Test"
  git -C "${repo_dir}" config user.email "jiggit@example.com"
  git -C "${repo_dir}" remote add origin "git@github.com:example/env-diff-repo.git"

  printf 'one\n' > "${repo_dir}/README.md"
  git -C "${repo_dir}" add README.md
  git -C "${repo_dir}" commit -m "ALPHA-1 feat: initial feature" >/dev/null 2>&1
  git -C "${repo_dir}" tag v1.0.0

  printf 'two\n' >> "${repo_dir}/README.md"
  git -C "${repo_dir}" add README.md
  git -C "${repo_dir}" commit -m "ALPHA-2 fix: repair edge case" >/dev/null 2>&1

  printf 'three\n' >> "${repo_dir}/README.md"
  git -C "${repo_dir}" add README.md
  git -C "${repo_dir}" commit -m "docs: update setup notes" >/dev/null 2>&1
  git -C "${repo_dir}" tag v1.1.0

  git -C "${repo_dir}" branch -M main
  git -C "${repo_dir}" update-ref refs/remotes/origin/main "$(git -C "${repo_dir}" rev-parse main)"
  git -C "${repo_dir}" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
}

# Override live version fetches so env-diff tests stay local and deterministic.
fetch_env_version_for_url() {
  local environment_name="${1}"
  local info_url="${2}"
  local jq_expr="${3}"
  printf '%s|%s|%s\n' "${environment_name}" "${info_url}" "${jq_expr}" >> "${TEST_TMPDIR}/fetch.log"

  case "${environment_name}" in
    prod)
      printf 'v1.0.0-0-gabc1234\n'
      ;;
    prep)
      printf 'v1.1.0-0-gdef5678\n'
      ;;
    ft)
      printf 'v1.1.0-0-gdef5678\n'
      ;;
    *)
      printf 'ERROR: unknown test environment\n'
      return 1
      ;;
  esac
}

fetch_jira_issues_by_keys() {
  local jira_base_url="${1}"
  local auth_reference="${2:-}"
  shift 2 || true

  printf '%s|%s|%s\n' "${jira_base_url}" "${auth_reference}" "$*" >> "${TEST_TMPDIR}/jira-fetch.log"
  cat <<'EOF'
{
  "issues": [
    {
      "key": "ALPHA-2",
      "fields": {
        "summary": "Repair edge case",
        "status": {"name": "Done"},
        "fixVersions": []
      }
    }
  ]
}
EOF
}

test_run_env_diff_main_reports_no_difference_for_equal_versions() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local repo_dir="${TEST_TMPDIR}/env-diff-repo"
  create_repo_for_env_diff "${repo_dir}"

  local projects_file="${TEST_TMPDIR}/projects.toml"
  cat > "${projects_file}" <<EOF
[project_a]
repo_path = "${repo_dir}"
remote_url = "git@github.com:example/env-diff-repo.git"
jira_project_key = "ALPHA"
jira_regexes = ["ALPHA-[0-9]+"]
environments = ["prep", "ft"]
info_version_expr = "jq -r '.git.branch'"

[project_a.environment_info_urls]
prep = "https://prep.project-a.example.com/actuator/info"
ft = "https://ft.project-a.example.com/actuator/info"
EOF

  local output
  output="$(
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    run_env_diff_main project_a --base prep --target ft
  )"

  assert_contains "${output}" "No difference: both operands resolve to the same ref." "report equal-version no-diff case"
  assert_contains "${output}" "Base: \`prep\`" "render base environment in no-diff case"
  assert_contains "${output}" "Target: \`ft\`" "render target in no-diff case"
  assert_contains "${output}" "Resolved ref: \`v1.1.0\`" "render shared version in no-diff case"
}

test_run_env_diff_main_preserves_requested_base_and_target_environments() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local repo_dir="${TEST_TMPDIR}/env-diff-repo"
  create_repo_for_env_diff "${repo_dir}"

  local projects_file="${TEST_TMPDIR}/projects.toml"
  cat > "${projects_file}" <<EOF
[jira]
base_url = "https://jira.example.test"
bearer_token = "token"

[project_a]
repo_path = "${repo_dir}"
remote_url = "git@github.com:example/env-diff-repo.git"
jira_project_key = "ALPHA"
jira_regexes = ["ALPHA-[0-9]+"]
environments = ["prod", "prep"]
info_version_expr = "jq -r '.git.branch'"

[project_a.environment_info_urls]
prod = "https://prod.project-a.example.com/actuator/info"
prep = "https://prep.project-a.example.com/actuator/info"
EOF

  local output
  output="$(
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    run_env_diff_main project_a --base prod --target prep
  )"

  assert_contains "${output}" "# jiggit env-diff" "render env-diff heading"
  assert_contains "${output}" "Target: \`prep\`" "render requested target environment"
  assert_contains "${output}" "base version (prod): v1.0.0" "render base version"
  assert_contains "${output}" "target ref: v1.1.0" "render target version"
  assert_contains "${output}" 'commit count ahead: 2' "render commit count"
  assert_contains "${output}" '**suggested next release: v1.1.0**' "render suggested next release"
  assert_contains "${output}" 'suggested release link: https://github.com/example/env-diff-repo/compare/' "render suggested release link"
  assert_contains "${output}" '## Commits By Type' "render grouped commits heading"
  assert_contains "${output}" 'repair edge case ALPHA-2' "render enriched fix commit line"
  assert_contains "${output}" '## fix' "render fix section"
  assert_contains "${output}" '## docs' "render docs section"
  assert_contains "${output}" '## Jira Issues' "render jira issues section"
  assert_contains "${output}" '[ALPHA-2](https://jira.example.test/browse/ALPHA-2): status: Done, MISSING fix_version, subject: Repair edge case' "render linked jira issue with missing fix version"
  assert_contains "${output}" 'add missing fixVersion: jiggit assign-fix-version project_a --release 1.1.0' "suggest assign-fix-version from env diff"

  local fetch_log
  fetch_log="$(sed -n '1,20p' "${TEST_TMPDIR}/fetch.log")"
  assert_contains "${fetch_log}" "prod|https://prod.project-a.example.com/actuator/info|jq -r '.git.branch'" "resolve prod environment version"
  assert_contains "${fetch_log}" "prep|https://prep.project-a.example.com/actuator/info|jq -r '.git.branch'" "resolve prep environment version"
  local jira_fetch_log
  jira_fetch_log="$(sed -n '1,20p' "${TEST_TMPDIR}/jira-fetch.log")"
  assert_contains "${jira_fetch_log}" "https://jira.example.test||ALPHA-2" "fetch jira issues for extracted keys"
}

test_run_env_diff_main_defaults_target_to_remote_default_branch() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local repo_dir="${TEST_TMPDIR}/env-diff-repo"
  create_repo_for_env_diff "${repo_dir}"

  local projects_file="${TEST_TMPDIR}/projects.toml"
  cat > "${projects_file}" <<EOF
[project_a]
repo_path = "${repo_dir}"
remote_url = "git@github.com:example/env-diff-repo.git"
jira_project_key = "ALPHA"
jira_regexes = ["ALPHA-[0-9]+"]
environments = ["prod"]
info_version_expr = "jq -r '.git.branch'"

[project_a.environment_info_urls]
prod = "https://prod.project-a.example.com/actuator/info"
EOF

  local output
  output="$(
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    run_env_diff_main project_a --base prod
  )"

  assert_contains "${output}" "Target: \`refs/remotes/origin/main\`" "default target to remote default branch"
  assert_contains "${output}" "base version (prod): v1.0.0" "render base version with default target"
  assert_contains "${output}" "target ref: refs/remotes/origin/main" "render default target ref as target version"
}

test_run_env_diff_main_accepts_git_refs_for_base_and_target() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local repo_dir="${TEST_TMPDIR}/env-diff-repo"
  create_repo_for_env_diff "${repo_dir}"

  local projects_file="${TEST_TMPDIR}/projects.toml"
  cat > "${projects_file}" <<EOF
[project_a]
repo_path = "${repo_dir}"
remote_url = "git@github.com:example/env-diff-repo.git"
jira_project_key = "ALPHA"
jira_regexes = ["ALPHA-[0-9]+"]
environments = ["prod", "prep"]
info_version_expr = "jq -r '.git.branch'"

[project_a.environment_info_urls]
prod = "https://prod.project-a.example.com/actuator/info"
prep = "https://prep.project-a.example.com/actuator/info"
EOF

  local output
  output="$(
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    run_env_diff_main project_a --base prod --target main
  )"

  assert_contains "${output}" "Target: \`main\`" "treat non-environment target as git ref"
  assert_contains "${output}" "base version (prod): v1.0.0" "resolve base environment to deployed version"
  assert_contains "${output}" "target ref: main" "preserve target git ref"
  assert_contains "${output}" "suggested release link: https://github.com/example/env-diff-repo/compare/" "render release link for mixed env and git ref"
}

run_tests "$@"
