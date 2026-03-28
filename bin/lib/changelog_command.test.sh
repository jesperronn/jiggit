#!/usr/bin/env bash
set -euo pipefail

pushd "$(dirname "$0")/../.." > /dev/null || exit 1

source bin/lib/bash_test.sh
source bin/lib/changelog_command.sh

TEST_TMPDIR=""

setup_tmpdir() {
  TEST_TMPDIR="$(mktemp -d /tmp/jiggit-changelog-test.XXXXXX)"
}

cleanup_tmpdir() {
  if [[ -n "${TEST_TMPDIR}" && -d "${TEST_TMPDIR}" ]]; then
    rm -rf "${TEST_TMPDIR}"
  fi
}

create_repo_for_changelog() {
  local repo_dir="${1}"

  mkdir -p "${repo_dir}"
  git init "${repo_dir}" >/dev/null 2>&1
  git -C "${repo_dir}" config user.name "Jiggit Test"
  git -C "${repo_dir}" config user.email "jiggit@example.com"
  git -C "${repo_dir}" remote add origin "git@github.com:example/changelog-repo.git"

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

  printf 'four\n' >> "${repo_dir}/README.md"
  git -C "${repo_dir}" add README.md
  git -C "${repo_dir}" commit -m "cleanup temp file" >/dev/null 2>&1
  git -C "${repo_dir}" tag v1.1.0
}

test_run_changelog_main_groups_commits() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local repo_dir="${TEST_TMPDIR}/changelog-repo"
  create_repo_for_changelog "${repo_dir}"

  local projects_file="${TEST_TMPDIR}/projects.toml"
  cat > "${projects_file}" <<EOF
[changelog-project]
repo_path = "${repo_dir}"
remote_url = "git@github.com:example/changelog-repo.git"
jira_project_key = "ALPHA"
jira_regexes = ["ALPHA-[0-9]+"]
EOF

  local output
  output="$(
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    run_changelog_main changelog-project --from v1.0.0 --to v1.1.0
  )"

  assert_contains "${output}" "# jiggit changelog" "render changelog heading"
  assert_contains "${output}" "## fix" "render fix section"
  assert_contains "${output}" "## docs" "render docs section"
  assert_contains "${output}" "## other" "render other section"
  assert_contains "${output}" "ALPHA-2 fix: repair edge case" "include fix commit"
  assert_contains "${output}" "docs: update setup notes" "include docs commit"
  assert_contains "${output}" "cleanup temp file" "include non-conventional commit in other section"
}

test_run_changelog_main_accepts_repo_path_selector() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local repo_dir="${TEST_TMPDIR}/changelog-repo"
  create_repo_for_changelog "${repo_dir}"

  local projects_file="${TEST_TMPDIR}/projects.toml"
  cat > "${projects_file}" <<EOF
[changelog-project]
repo_path = "${repo_dir}"
remote_url = "git@github.com:example/changelog-repo.git"
jira_project_key = "ALPHA"
jira_regexes = ["ALPHA-[0-9]+"]
EOF

  local output
  output="$(
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    run_changelog_main "${repo_dir}" --from v1.0.0 --to v1.1.0
  )"

  assert_contains "${output}" "# jiggit changelog" "render changelog heading from repo path selector"
  assert_contains "${output}" "Project: \`changelog-project\`" "resolve changelog project from repo path"
  assert_contains "${output}" "## fix" "render grouped changelog output from repo path"
}

run_tests "$@"
