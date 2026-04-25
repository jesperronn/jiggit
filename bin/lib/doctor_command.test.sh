#!/usr/bin/env bash
set -euo pipefail

pushd "$(dirname "$0")/../.." > /dev/null || exit 1

source bin/lib/bash_test.sh
source bin/lib/doctor_command.sh

TEST_TMPDIR=""

install_default_fetch_project_environment_version_mock() {
  eval '
fetch_project_environment_version() {
  local project_id="${1}"
  local environment_name="${2}"
  printf '\''env|%s|%s\n'\'' "${project_id}" "${environment_name}" >> "${TEST_TMPDIR}/fetch.log"

  case "${environment_name}" in
    prod)
      printf '\''v2.1.0.26\n'\''
      ;;
    *)
      return 1
      ;;
  esac
}
'
}

install_default_fetch_jira_mocks() {
  eval '
fetch_jira_project_metadata() {
  local jira_base_url="${1}"
  local jira_project_key="${2}"
  printf '\''project|%s|%s\n'\'' "${jira_base_url}" "${jira_project_key}" >> "${TEST_TMPDIR}/fetch.log"

  cat <<'"'"'EOF'"'"'
{
  "key": "JIRA",
  "name": "Jira Project"
}
EOF
}

fetch_jira_releases() {
  local jira_base_url="${1}"
  local jira_project_key="${2}"
  printf '\''releases|%s|%s\n'\'' "${jira_base_url}" "${jira_project_key}" >> "${TEST_TMPDIR}/fetch.log"

  cat <<'"'"'EOF'"'"'
[
  { "name": "2.1.0.26" }
]
EOF
}

fetch_jira_current_user() {
  local jira_base_url="${1}"
  printf '\''myself|%s\n'\'' "${jira_base_url}" >> "${TEST_TMPDIR}/fetch.log"

  cat <<'"'"'EOF'"'"'
{
  "name": "nine-jrj"
}
EOF
}
'
}

setup_tmpdir() {
  TEST_TMPDIR="$(mktemp -d /tmp/jiggit-doctor-test.XXXXXX)"
  install_default_fetch_project_environment_version_mock
  install_default_fetch_jira_mocks
  unset JIRA_BASE_URL
  unset JIRA_API_TOKEN
  unset JIRA_BEARER_TOKEN
  unset JIRA_USER_EMAIL
  # shellcheck disable=SC2034
  JIGGIT_CAN_PROMPT_INTERACTIVELY=false
  # shellcheck disable=SC2034
  JIGGIT_PROMPT_INPUT_FILE=""
}

cleanup_tmpdir() {
  if [[ -n "${TEST_TMPDIR}" && -d "${TEST_TMPDIR}" ]]; then
    rm -rf "${TEST_TMPDIR}"
  fi
}

# shellcheck disable=SC2329
fetch_jira_current_user() {
  local jira_base_url="${1}"
  printf 'myself|%s\n' "${jira_base_url}" >> "${TEST_TMPDIR}/fetch.log"

  cat <<'EOF'
{
  "name": "nine-jrj"
}
EOF
}

fetch_jira_current_user() {
  local jira_base_url="${1}"
  printf 'myself|%s\n' "${jira_base_url}" >> "${TEST_TMPDIR}/fetch.log"

  cat <<'EOF'
{
  "name": "nine-jrj"
}
EOF
}

install_default_fetch_project_environment_version_mock

test_run_doctor_main_defaults_to_all_projects() {
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
environments = ["prod"]

[project-b]
repo_path = "${repo_dir}"
remote_url = "git@github.com:example/project-b.git"
jira_project_key = "JIRA"
jira_regexes = ["JIRA-[0-9]+"]
environments = []
EOF

  local output
  output="$(
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    run_doctor_main
  )"

  assert_contains "${output}" "# jiggit doctor" "render doctor heading"
  assert_contains "${output}" "## project-a" "check first configured project"
  assert_contains "${output}" "## project-b" "default to all configured projects"
  assert_contains "${output}" "env prod: \`ok\` (v2.1.0.26)" "render environment version check"
  assert_contains "${output}" "jira releases: \`ok\` (0 released, 1 unreleased -- 2.1.0.26)" "render jira releases summary"
  assert_contains "${output}" "command: \`jiggit doctor project-a\`" "render per-project doctor command hint"
  assert_contains "${output}" "jiggit: \`warn\` (not directly callable; run bin/setup)" "render jiggit PATH warning"
  assert_contains "${output}" "make jiggit directly callable: \`bin/setup\`" "render jiggit setup next step"
}

test_run_doctor_main_can_force_colored_headings() {
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
EOF

  local output
  output="$(
    JIGGIT_COLOR_OUTPUT=always \
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    run_doctor_main --ignore-failures
  )"

  assert_contains "${output}" $'\e[1m\e[34m# jiggit doctor\e[0m' "render colored doctor top heading"
  assert_contains "${output}" $'\e[1m\e[36m## Prerequisites\e[0m' "render colored doctor prerequisite heading"
  assert_contains "${output}" $'\e[1m\e[32m## project-a\e[0m' "render colored doctor project heading"
}

test_run_doctor_main_scopes_release_summary_by_jira_release_prefix() {
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
jira_release_prefix = ["ProjectA_"]
jira_regexes = ["JIRA-[0-9]+"]
environments = []
EOF

  # shellcheck disable=SC2329
  fetch_jira_releases() {
    local jira_base_url="${1}"
    local jira_project_key="${2}"
    printf 'releases|%s|%s\n' "${jira_base_url}" "${jira_project_key}" >> "${TEST_TMPDIR}/fetch.log"

    cat <<'EOF'
[
  { "name": "ProjectA_2.1.0.25", "released": true, "archived": false, "releaseDate": "2026-02-10" },
  { "name": "ProjectA_2.1.0.26", "released": false, "archived": false, "releaseDate": "2026-03-30" },
  { "name": "Other_9.9.9", "released": false, "archived": false, "releaseDate": "2026-04-01" }
]
EOF
  }

  local output
  output="$(
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    run_doctor_main project-a
  )"

  assert_contains "${output}" "jira releases: \`ok\` (1 released, 1 unreleased -- ProjectA_2.1.0.26)" "summarize only project-scoped jira releases"
}

test_run_doctor_main_fail_fast_stops_after_first_project_failure() {
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
remote_url = "git@github.com:example/project-a.git"
jira_project_key = "JIRA"
jira_regexes = ["JIRA-[0-9]+"]
environments = []

[project-b]
repo_path = "${repo_dir}"
remote_url = "git@github.com:example/project-b.git"
jira_project_key = "JIRA"
jira_regexes = ["JIRA-[0-9]+"]
environments = []
EOF

  local output=""
  if output="$(
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    run_doctor_main --fail-fast 2>&1
  )"; then
    fail "doctor should fail when the first project fails"
  else
    pass "doctor should fail when the first project fails"
    assert_contains "${output}" "## project-a" "render first failing project"
    if grep -Fq "## project-b" <<<"${output}"; then
      fail "fail-fast should stop before the second project"
      return 1
    fi
    pass "fail-fast stops before the second project"
  fi

  local fetch_log
  fetch_log="$(cat "${TEST_TMPDIR}/fetch.log")"
  assert_contains "${fetch_log}" "myself|https://jira.example.test" "probe Jira access once before projects"
  if grep -Fq "project-b" <<<"${fetch_log}"; then
    fail "fail-fast should not fetch Jira data for the second project"
    return 1
  fi
  pass "fail-fast avoids Jira fetches for the second project"
}

test_run_doctor_main_fails_fast_on_jira_auth_probe_and_marks_remaining_jira_checks_unknown() {
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
environments = ["prod"]
EOF

  # shellcheck disable=SC2329
  fetch_jira_current_user() {
    local jira_base_url="${1}"
    printf 'myself|%s\n' "${jira_base_url}" >> "${TEST_TMPDIR}/fetch.log"
    printf 'unauthorized\n' >&2
    return 1
  }

  # shellcheck disable=SC2329
  fetch_jira_project_metadata() {
    printf 'metadata should not be called after auth failure\n' >&2
    return 1
  }

  # shellcheck disable=SC2329
  fetch_jira_releases() {
    printf 'releases should not be called after auth failure\n' >&2
    return 1
  }

  local output=""
  if output="$(
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    run_doctor_main 2>&1
  )"; then
    fail "doctor should fail when the shared Jira auth probe fails"
  else
    pass "doctor should fail when the shared Jira auth probe fails"
    assert_contains "${output}" "## Jira Access" "render Jira Access section"
    assert_contains "${output}" "jira access: \`fail\` (auth probe failed; later Jira checks skipped)" "render failed Jira auth probe"
    assert_contains "${output}" "verify Jira access once: \`bin/adhoc/jira_requests.sh myself\`" "suggest a single auth probe"
    assert_contains "${output}" "jira project: \`unknown\` (skipped after Jira auth failure)" "mark jira project check unknown after auth failure"
    assert_contains "${output}" "jira releases: \`unknown\` (skipped after Jira auth failure)" "mark jira releases check unknown after auth failure"
  fi

  local fetch_log
  fetch_log="$(cat "${TEST_TMPDIR}/fetch.log")"
  assert_contains "${fetch_log}" "myself|https://jira.example.test" "probe Jira auth exactly once"
  if grep -Fq "metadata should not be called after auth failure" <<<"${output}" || grep -Fq "releases should not be called after auth failure" <<<"${output}"; then
    fail "doctor should not call per-project Jira fetchers after auth failure"
  else
    pass "doctor does not call per-project Jira fetchers after auth failure"
  fi
}

test_run_doctor_main_can_ignore_unknown_project_failure() {
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

  local output
  output="$(
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    run_doctor_main --ignore-failures missing-project
  )"

  assert_contains "${output}" "## missing-project" "render explicit unknown project section"
  assert_contains "${output}" "project config: \`fail\` (unknown project)" "render unknown project failure"
}

test_run_doctor_main_fails_when_shared_jira_config_is_missing() {
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
EOF

  local output=""
  if output="$(
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    run_doctor_main 2>&1
  )"; then
    fail "fail doctor when shared jira config is missing"
  else
    pass "fail doctor when shared jira config is missing"
    assert_contains "${output}" "jira project: \`fail\` (missing Jira config)" "render missing shared jira config as failure"
    assert_contains "${output}" "jira releases: \`fail\` (missing Jira config)" "render missing shared jira release config as failure"
    assert_contains "${output}" "Next Steps" "render next steps heading for missing jira config"
  assert_contains "${output}" "review effective config: \`jiggit config\`" "suggest config command for missing jira config"
  fi
}

test_run_doctor_main_accepts_repo_path_selector() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local repo_dir="${TEST_TMPDIR}/project-a"
  mkdir -p "${repo_dir}"
  git init "${repo_dir}" >/dev/null 2>&1

  local projects_file="${TEST_TMPDIR}/projects.toml"
  cat > "${projects_file}" <<EOF
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
    run_doctor_main --ignore-failures "${repo_dir}"
  )"

  assert_contains "${output}" "# jiggit doctor" "render doctor heading from repo path"
  assert_contains "${output}" "## project-a" "resolve doctor project from repo path"
}

test_run_doctor_main_suggests_env_versions_when_environment_lookup_fails() {
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
environments = ["ft"]
EOF

  local output
  output="$(
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    run_doctor_main --ignore-failures
  )"

  assert_contains "${output}" "env ft: \`warn\` (unable to resolve)" "render unresolved environment warning"
  assert_contains "${output}" "inspect environment versions: \`jiggit env-versions project-a\`" "suggest env-versions follow-up"
}

test_run_doctor_main_global_only_hides_project_sections() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local projects_file="${TEST_TMPDIR}/projects.toml"
  cat > "${projects_file}" <<'EOF'
[jira]
base_url = "https://jira.example.test"
bearer_token = "token"

[project-a]
remote_url = "git@github.com:example/project-a.git"
jira_project_key = "JIRA"
environments = ["prod"]
EOF

  local output
  output="$(
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    run_doctor_main --global
  )"

  assert_contains "${output}" "# jiggit doctor" "render doctor heading in global mode"
  assert_contains "${output}" "## Prerequisites" "render prereqs in global mode"
  assert_contains "${output}" "## Jira Access" "render jira access in global mode"
  if grep -Fq "## project-a" <<<"${output}"; then
    fail "--global should hide project sections"
  else
    pass "--global hides project sections"
  fi
}

test_run_doctor_main_can_create_missing_shared_jira_config() {
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
EOF

  cat > "${TEST_TMPDIR}/doctor-input.txt" <<'EOF'
https://jira.example.test
token-123
y
EOF

  local output
  output="$(
    JIGGIT_CAN_PROMPT_INTERACTIVELY=true \
    JIGGIT_PROMPT_INPUT_FILE="${TEST_TMPDIR}/doctor-input.txt" \
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    run_doctor_main --ignore-failures
  )"

  local updated_file
  updated_file="$(cat "${projects_file}")"
  assert_contains "${updated_file}" "[jira]" "append jira table to config file"
  assert_contains "${updated_file}" 'base_url = "https://jira.example.test"' "write prompted jira base url"
  assert_contains "${updated_file}" 'bearer_token = "token-123"' "write prompted jira bearer token"
  assert_contains "${output}" "jira project: \`ok\` (Jira Project)" "reload config after creating jira block"
}

test_run_doctor_main_can_create_missing_project_jira_key() {
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
jira_regexes = ["JIRA-[0-9]+"]
environments = []
EOF

  cat > "${TEST_TMPDIR}/doctor-input.txt" <<'EOF'
y
EOF

  local output
  output="$(
    JIGGIT_CAN_PROMPT_INTERACTIVELY=true \
    JIGGIT_PROMPT_INPUT_FILE="${TEST_TMPDIR}/doctor-input.txt" \
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    run_doctor_main --ignore-failures
  )"

  local updated_file
  updated_file="$(cat "${projects_file}")"
  assert_contains "${updated_file}" 'jira_project_key = "JIRA"' "write prompted jira project key"
  assert_contains "${output}" "jira project: \`ok\` (Jira Project)" "reload config after creating jira project key"
}

test_run_doctor_main_can_create_missing_remote_url_from_git_origin() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local repo_dir="${TEST_TMPDIR}/repo"
  mkdir -p "${repo_dir}"
  git init "${repo_dir}" >/dev/null 2>&1
  git -C "${repo_dir}" remote add origin "git@github.com:example/project-a.git"

  local projects_file="${TEST_TMPDIR}/projects.toml"
  cat > "${projects_file}" <<EOF
[jira]
base_url = "https://jira.example.test"
bearer_token = "token"

[project-a]
repo_path = "${repo_dir}"
jira_project_key = "JIRA"
jira_regexes = ["JIRA-[0-9]+"]
environments = []
EOF

  cat > "${TEST_TMPDIR}/doctor-input.txt" <<'EOF'
y
EOF

  local output
  output="$(
    JIGGIT_CAN_PROMPT_INTERACTIVELY=true \
    JIGGIT_PROMPT_INPUT_FILE="${TEST_TMPDIR}/doctor-input.txt" \
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    run_doctor_main --ignore-failures
  )"

  local updated_file
  updated_file="$(cat "${projects_file}")"
  assert_contains "${updated_file}" 'remote_url = "git@github.com:example/project-a.git"' "write inferred remote url"
  assert_contains "${output}" "repo path: \`ok\` (${repo_dir})" "keep repo-path status after writing remote url"
}

test_run_doctor_main_can_create_missing_jira_regexes_from_git_history() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local repo_dir="${TEST_TMPDIR}/repo"
  mkdir -p "${repo_dir}"
  git init "${repo_dir}" >/dev/null 2>&1
  git -C "${repo_dir}" config user.name "Jiggit Test"
  git -C "${repo_dir}" config user.email "jiggit@example.com"
  printf 'one\n' > "${repo_dir}/README.md"
  git -C "${repo_dir}" add README.md
  git -C "${repo_dir}" commit -m "JIRA-123 add feature" >/dev/null 2>&1

  local projects_file="${TEST_TMPDIR}/projects.toml"
  cat > "${projects_file}" <<EOF
[jira]
base_url = "https://jira.example.test"
bearer_token = "token"

[project-a]
repo_path = "${repo_dir}"
remote_url = "git@github.com:example/project-a.git"
jira_project_key = "JIRA"
environments = []
EOF

  cat > "${TEST_TMPDIR}/doctor-input.txt" <<'EOF'
y
EOF

  local output
  output="$(
    JIGGIT_CAN_PROMPT_INTERACTIVELY=true \
    JIGGIT_PROMPT_INPUT_FILE="${TEST_TMPDIR}/doctor-input.txt" \
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    run_doctor_main --ignore-failures
  )"

  local updated_file
  updated_file="$(cat "${projects_file}")"
  assert_contains "${updated_file}" 'jira_regexes = ["JIRA-[0-9]+"]' "write inferred jira regexes"
  assert_contains "${output}" "jira project: \`ok\` (Jira Project)" "keep jira project status after writing jira regexes"
}

test_run_doctor_main_can_infer_jira_project_key_from_existing_regex() {
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
jira_regexes = ["JIRA-[0-9]+"]
environments = []
EOF

  cat > "${TEST_TMPDIR}/doctor-input.txt" <<'EOF'
y
EOF

  local output
  output="$(
    JIGGIT_CAN_PROMPT_INTERACTIVELY=true \
    JIGGIT_PROMPT_INPUT_FILE="${TEST_TMPDIR}/doctor-input.txt" \
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    run_doctor_main --ignore-failures
  )"

  local updated_file
  updated_file="$(cat "${projects_file}")"
  assert_contains "${updated_file}" 'jira_project_key = "JIRA"' "infer jira project key from jira regex"
  assert_contains "${output}" "jira project: \`ok\` (Jira Project)" "keep jira project status after inferring jira project key"
}

test_run_doctor_main_can_infer_environments_from_existing_info_urls() {
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

[project-a.environment_info_urls]
prod = "https://prod.example.com/actuator/info"
prep = "https://prep.example.com/actuator/info"
EOF

  cat > "${TEST_TMPDIR}/doctor-input.txt" <<'EOF'
y
cat
y
EOF

  local output
  output="$(
    JIGGIT_CAN_PROMPT_INTERACTIVELY=true \
    JIGGIT_PROMPT_INPUT_FILE="${TEST_TMPDIR}/doctor-input.txt" \
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    run_doctor_main --ignore-failures
  )"

  local updated_file
  updated_file="$(cat "${projects_file}")"
  assert_contains "${updated_file}" 'environments = ["prod", "prep"]' "infer environments from environment info urls"
  assert_contains "${output}" "env prod: \`ok\` (v2.1.0.26)" "reload config after inferring environments"
}

test_run_doctor_main_can_create_missing_environment_info_url() {
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
environments = ["prod"]
EOF

  # shellcheck disable=SC2329
  fetch_project_environment_version() {
    local project_id="${1}"
    local environment_name="${2}"
    local info_url=""

    info_url="$(project_environment_info_url "${project_id}" "${environment_name}")"
    if [[ -z "${info_url}" ]]; then
      printf 'ERROR: missing info URL in config\n'
      return 1
    fi

    printf 'v2.1.0.26\n'
  }

  cat > "${TEST_TMPDIR}/doctor-input.txt" <<'EOF'
cat
y
https://prod.example.com/actuator/info
y
EOF

  local output
  output="$(
    JIGGIT_CAN_PROMPT_INTERACTIVELY=true \
    JIGGIT_PROMPT_INPUT_FILE="${TEST_TMPDIR}/doctor-input.txt" \
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    run_doctor_main --ignore-failures
  )"

  local updated_file
  updated_file="$(cat "${projects_file}")"
  assert_contains "${updated_file}" "[project-a.environment_info_urls]" "create nested environment info table"
  assert_contains "${updated_file}" 'prod = "https://prod.example.com/actuator/info"' "write prompted environment info url"
  assert_contains "${output}" "env prod: \`ok\` (v2.1.0.26)" "reload config after creating environment info url"
}

test_run_doctor_main_can_create_missing_environments_and_info_expr() {
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
EOF

  cat > "${TEST_TMPDIR}/doctor-input.txt" <<'EOF'
prod prep
y
jq -r '.git.branch'
y
https://prod.example.com/actuator/info
y
https://prep.example.com/actuator/info
y
EOF

  local output
  output="$(
    JIGGIT_CAN_PROMPT_INTERACTIVELY=true \
    JIGGIT_PROMPT_INPUT_FILE="${TEST_TMPDIR}/doctor-input.txt" \
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    run_doctor_main --ignore-failures
  )"

  local updated_file
  updated_file="$(cat "${projects_file}")"
  assert_contains "${updated_file}" 'environments = ["prod", "prep"]' "write prompted environments"
  assert_contains "${updated_file}" 'info_version_expr = "jq -r '\''.git.branch'\''"' "write prompted info version expression"
  assert_contains "${updated_file}" 'prod = "https://prod.example.com/actuator/info"' "write prompted prod url after adding environments"
  assert_contains "${updated_file}" 'prep = "https://prep.example.com/actuator/info"' "write prompted prep url after adding environments"
  assert_contains "${output}" "env prod: \`ok\` (v2.1.0.26)" "reload config after creating environments and info expr"
}

run_tests "$@"
