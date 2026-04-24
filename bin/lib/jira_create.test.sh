#!/usr/bin/env bash
set -euo pipefail

pushd "$(dirname "$0")/../.." > /dev/null || exit 1

source bin/lib/bash_test.sh
source bin/lib/jira_create.sh

TEST_TMPDIR=""

setup_tmpdir() {
  TEST_TMPDIR="$(mktemp -d /tmp/jiggit-jira-create-test.XXXXXX)"
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

create_repo_with_commit() {
  local repo_dir="${1}"
  local commit_subject_line="${2}"
  local commit_body_text="${3:-}"

  mkdir -p "${repo_dir}"
  git init "${repo_dir}" >/dev/null 2>&1
  git -C "${repo_dir}" config user.name "Jiggit Test"
  git -C "${repo_dir}" config user.email "jiggit@example.com"
  printf 'hello\n' > "${repo_dir}/README.md"
  git -C "${repo_dir}" add README.md

  if [[ -n "${commit_body_text}" ]]; then
    git -C "${repo_dir}" commit -m "${commit_subject_line}" -m "${commit_body_text}" >/dev/null 2>&1
  else
    git -C "${repo_dir}" commit -m "${commit_subject_line}" >/dev/null 2>&1
  fi
}

test_derive_issue_summary_strips_leading_issue_key() {
  local actual
  actual="$(derive_issue_summary "ABC-123 feat: add worker command")"
  assert_eq "feat: add worker command" "${actual}" "derive summary from commit subject"
}

test_build_jira_issue_payload_includes_fields() {
  local payload
  payload="$(build_jira_issue_payload "PLAT" "Task" "Create worker" "Created from commit")"

  assert_contains "${payload}" '"key": "PLAT"' "payload includes jira project key"
  assert_contains "${payload}" '"name": "Task"' "payload includes issue type"
  assert_contains "${payload}" '"summary": "Create worker"' "payload includes summary"
}

test_run_jira_create_main_dry_run_uses_commit_message() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local repo_dir="${TEST_TMPDIR}/worker-repo"
  create_repo_with_commit "${repo_dir}" "PLAT-42 feat: add issue creator" "Body line one"

  local projects_file="${TEST_TMPDIR}/projects.toml"
  cat > "${projects_file}" <<EOF
[worker-project]
repo_path = "${repo_dir}"
remote_url = "git@example.com:worker/repo.git"
jira_project_key = "PLAT"
jira_regexes = ["PLAT-[0-9]+"]
EOF

  local output
  output="$(
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.sh" \
    run_jira_create_main "worker-project" --dry-run
  )"

  assert_contains "${output}" "Project: worker-project" "dry run prints project id"
  assert_contains "${output}" "Jira project: PLAT" "dry run prints jira project key"
  assert_contains "${output}" "Summary: feat: add issue creator" "dry run derives summary from commit"
  assert_contains "${output}" '"summary": "feat: add issue creator"' "dry run payload contains derived summary"
  assert_contains "${output}" 'Body line one' "dry run payload includes commit body"
}

test_run_jira_create_main_defaults_to_current_configured_repo() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local repo_dir="${TEST_TMPDIR}/worker-repo"
  create_repo_with_commit "${repo_dir}" "PLAT-42 feat: add issue creator" "Body line one"

  local projects_file="${TEST_TMPDIR}/projects.toml"
  cat > "${projects_file}" <<EOF
[worker-project]
repo_path = "${repo_dir}"
remote_url = "git@example.com:worker/repo.git"
jira_project_key = "PLAT"
jira_regexes = ["PLAT-[0-9]+"]
EOF

  local output
  output="$(
    cd "${repo_dir}"
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.sh" \
    run_jira_create_main --dry-run
  )"

  assert_contains "${output}" "Project: worker-project" "resolve jira-create project from current repo"
  assert_contains "${output}" "Summary: feat: add issue creator" "derive summary from current repo selector"
}

run_tests "$@"
