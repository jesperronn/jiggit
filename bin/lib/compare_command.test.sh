#!/usr/bin/env bash
set -euo pipefail

pushd "$(dirname "$0")/../.." > /dev/null || exit 1

source bin/lib/bash_test.sh
source bin/lib/compare_command.sh

TEST_TMPDIR=""

setup_tmpdir() {
  TEST_TMPDIR="$(mktemp -d /tmp/jiggit-compare-test.XXXXXX)"
}

cleanup_tmpdir() {
  if [[ -n "${TEST_TMPDIR}" && -d "${TEST_TMPDIR}" ]]; then
    rm -rf "${TEST_TMPDIR}"
  fi
}

create_repo_with_tags() {
  local repo_dir="${1}"

  mkdir -p "${repo_dir}"
  git init "${repo_dir}" >/dev/null 2>&1
  git -C "${repo_dir}" config user.name "Jiggit Test"
  git -C "${repo_dir}" config user.email "jiggit@example.com"
  git -C "${repo_dir}" remote add origin "git@github.com:example/compare-repo.git"

  printf 'one\n' > "${repo_dir}/README.md"
  git -C "${repo_dir}" add README.md
  git -C "${repo_dir}" commit -m "ALPHA-1 initial commit" >/dev/null 2>&1
  git -C "${repo_dir}" tag v1.0.0

  printf 'two\n' >> "${repo_dir}/README.md"
  git -C "${repo_dir}" add README.md
  git -C "${repo_dir}" commit -m "ALPHA-2 add feature" >/dev/null 2>&1

  printf 'three\n' >> "${repo_dir}/README.md"
  git -C "${repo_dir}" add README.md
  git -C "${repo_dir}" commit -m "misc cleanup" >/dev/null 2>&1
  git -C "${repo_dir}" tag v1.1.0
}

test_run_compare_main_renders_report() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local repo_dir="${TEST_TMPDIR}/compare-repo"
  create_repo_with_tags "${repo_dir}"

  local projects_file="${TEST_TMPDIR}/projects.toml"
  cat > "${projects_file}" <<EOF
[compare-project]
repo_path = "${repo_dir}"
remote_url = "git@github.com:example/compare-repo.git"
jira_project_key = "ALPHA"
jira_regexes = ["ALPHA-[0-9]+"]
EOF

  local output
  output="$(
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    run_compare_main compare-project --from v1.0.0 --to v1.1.0
  )"

  assert_contains "${output}" "# jiggit compare" "render compare heading"
  assert_contains "${output}" "compare-project" "render project id"
  assert_contains "${output}" "v1.0.0" "render normalized from ref"
  assert_contains "${output}" "v1.1.0" "render normalized to ref"
  assert_contains "${output}" "Commit count: 2" "render commit count"
  assert_contains "${output}" "ALPHA-2" "render extracted jira key"
  assert_contains "${output}" "github.com/example/compare-repo/compare/" "render compare url"
}

test_run_compare_main_defaults_to_current_configured_repo() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local repo_dir="${TEST_TMPDIR}/compare-repo"
  create_repo_with_tags "${repo_dir}"

  local projects_file="${TEST_TMPDIR}/projects.toml"
  cat > "${projects_file}" <<EOF
[compare-project]
repo_path = "${repo_dir}"
remote_url = "git@github.com:example/compare-repo.git"
jira_project_key = "ALPHA"
jira_regexes = ["ALPHA-[0-9]+"]
EOF

  local output
  output="$(
    cd "${repo_dir}"
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    run_compare_main --from v1.0.0 --to v1.1.0
  )"

  assert_contains "${output}" "# jiggit compare" "render compare heading from current repo"
  assert_contains "${output}" "Project: \`compare-project\`" "resolve compare project from current repo"
  assert_contains "${output}" "Range: \`v1.0.0..v1.1.0\`" "render compare range from current repo"
}

run_tests "$@"
