#!/usr/bin/env bash
set -euo pipefail

pushd "$(dirname "$0")/../.." > /dev/null || exit 1

source bin/lib/bash_test.sh
source bin/lib/release_notes_command.sh

TEST_TMPDIR=""

setup_tmpdir() {
  TEST_TMPDIR="$(mktemp -d /tmp/jiggit-release-notes-test.XXXXXX)"
}

cleanup_tmpdir() {
  if [[ -n "${TEST_TMPDIR}" && -d "${TEST_TMPDIR}" ]]; then
    rm -rf "${TEST_TMPDIR}"
  fi
}

create_repo_for_release_notes() {
  local repo_dir="${1}"

  mkdir -p "${repo_dir}"
  git init "${repo_dir}" >/dev/null 2>&1
  git -C "${repo_dir}" config user.name "Jiggit Test"
  git -C "${repo_dir}" config user.email "jiggit@example.com"
  git -C "${repo_dir}" remote add origin "git@github.com:example/release-notes-repo.git"

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
}

fetch_jira_releases() {
  local jira_base_url="${1}"
  local jira_project_key="${2}"
  printf 'releases|%s|%s\n' "${jira_base_url}" "${jira_project_key}" >> "${TEST_TMPDIR}/fetch.log"

  if [[ "${RELEASE_NOTES_TEST_RELEASE_MODE:-single}" == "ambiguous" ]]; then
    cat <<'EOF'
[
  { "name": "1.1.0" },
  { "name": "1.1.1" }
]
EOF
    return 0
  fi

  cat <<'EOF'
[
  { "name": "1.1.0" }
]
EOF
}

fetch_project_environment_version() {
  local project_id="${1}"
  local environment_name="${2}"
  printf 'env|%s|%s\n' "${project_id}" "${environment_name}" >> "${TEST_TMPDIR}/fetch.log"

  case "${environment_name}" in
    prod)
      printf 'v1.0.0\n'
      ;;
    *)
      return 1
      ;;
  esac
}

fetch_jira_issues_by_keys() {
  local jira_base_url="${1}"
  local auth_reference="${2:-}"
  shift 2 || true
  printf 'issues-by-key|%s|%s|%s\n' "${jira_base_url}" "${auth_reference}" "$*" >> "${TEST_TMPDIR}/fetch.log"

  cat <<'EOF'
{
  "issues": [
    {
      "key": "ALPHA-2",
      "fields": {
        "summary": "Repair edge case",
        "status": { "name": "Done" },
        "labels": ["release"],
        "fixVersions": [{ "name": "1.1.0" }]
      }
    },
    {
      "key": "ALPHA-3",
      "fields": {
        "summary": "Document the feature",
        "status": { "name": "Done" },
        "labels": [],
        "fixVersions": []
      }
    }
  ]
}
EOF
}

fetch_jira_issues_for_release() {
  local jira_base_url="${1}"
  local jira_project_key="${2}"
  local release_name="${3}"
  printf 'issues-for-release|%s|%s|%s\n' "${jira_base_url}" "${jira_project_key}" "${release_name}" >> "${TEST_TMPDIR}/fetch.log"

  cat <<'EOF'
{
  "issues": [
    {
      "key": "ALPHA-2",
      "fields": {
        "summary": "Repair edge case",
        "status": { "name": "Done" },
        "labels": ["release"],
        "fixVersions": [{ "name": "1.1.0" }]
      }
    },
    {
      "key": "ALPHA-99",
      "fields": {
        "summary": "Release-only issue",
        "status": { "name": "To Do" },
        "labels": [],
        "fixVersions": [{ "name": "1.1.0" }]
      }
    }
  ]
}
EOF
}

test_run_release_notes_main_renders_git_first_notes_enriched_with_jira() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local repo_dir="${TEST_TMPDIR}/release-notes-repo"
  create_repo_for_release_notes "${repo_dir}"

  local projects_file="${TEST_TMPDIR}/projects.toml"
  cat > "${projects_file}" <<EOF
[jira]
base_url = "https://jira.example.test"
bearer_token = "token"

[alpha]
repo_path = "${repo_dir}"
remote_url = "git@github.com:example/release-notes-repo.git"
jira_project_key = "ALPHA"
jira_regexes = ["ALPHA-[0-9]+"]
environments = ["prod"]
EOF

  local output
  output="$(
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    run_release_notes_main alpha --target 1.1.0 --from-env prod
  )"

  assert_contains "${output}" "# jiggit release-notes" "render release-notes heading"
  assert_contains "${output}" "From: \`v1.0.0\`" "resolve start ref from environment"
  assert_contains "${output}" "Target: \`v1.1.0\`" "resolve target release to git tag"
  assert_contains "${output}" "## fix" "render grouped fix section"
  assert_contains "${output}" "## docs" "render grouped docs section"
  assert_contains "${output}" "## Jira Issues" "render Jira issue section"
  assert_contains "${output}" "title: \`Repair edge case\`" "render Jira-enriched summary"
  assert_contains "${output}" "fix_version: \`1.1.0\`" "render populated fix version in release notes"
  assert_contains "${output}" "fix_version: \`MISSING\`" "render missing fix version in release notes"
  assert_contains "${output}" "## Commits Without Jira Keys" "render missing Jira key mismatch section"
  assert_contains "${output}" "## Jira Release Issues Missing From Git Evidence" "render release mismatch section"
  assert_contains "${output}" "\`ALPHA-99\`" "render Jira release issue missing from git evidence"

  local fetch_log
  fetch_log="$(sed -n '1,20p' "${TEST_TMPDIR}/fetch.log")"
  assert_contains "${fetch_log}" "env|alpha|prod" "fetch base version from environment"
  assert_contains "${fetch_log}" "releases|https://jira.example.test|ALPHA" "fetch releases to resolve target"
  assert_contains "${fetch_log}" "issues-by-key|https://jira.example.test||ALPHA-2" "fetch issue metadata for git evidence"
  assert_contains "${fetch_log}" "issues-for-release|https://jira.example.test|ALPHA|1.1.0" "fetch release issues for mismatch check"
}

test_run_release_notes_main_prints_matches_and_exits_when_target_is_ambiguous() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local repo_dir="${TEST_TMPDIR}/release-notes-repo"
  create_repo_for_release_notes "${repo_dir}"

  local projects_file="${TEST_TMPDIR}/projects.toml"
  cat > "${projects_file}" <<EOF
[jira]
base_url = "https://jira.example.test"
bearer_token = "token"

[alpha]
repo_path = "${repo_dir}"
remote_url = "git@github.com:example/release-notes-repo.git"
jira_project_key = "ALPHA"
jira_regexes = ["ALPHA-[0-9]+"]
environments = ["prod"]
EOF

  local output=""
  if output="$(
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    RELEASE_NOTES_TEST_RELEASE_MODE="ambiguous" \
    run_release_notes_main alpha --target 1.1 --from-env prod 2>&1
  )"; then
    fail "exit when release target matches several Jira releases"
  else
    pass "exit when release target matches several Jira releases"
    assert_contains "${output}" 'Target "1.1" matched multiple Jira releases.' "report ambiguous target query"
    assert_contains "${output}" "\`1.1.0\`" "print first matching release"
    assert_contains "${output}" "\`1.1.1\`" "print second matching release"
  fi
}

run_tests "$@"
