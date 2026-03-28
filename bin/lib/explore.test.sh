#!/usr/bin/env bash
set -euo pipefail

pushd "$(dirname "$0")/../.." > /dev/null || exit 1

source bin/lib/bash_test.sh
source bin/lib/explore.sh

TEST_TMPDIR=""

setup_tmpdir() {
  TEST_TMPDIR="$(mktemp -d /tmp/jiggit-explore-test.XXXXXX)"
  JIGGIT_EXPLORE_VERBOSE=0
  JIGGIT_EXPLORE_DRY_RUN=0
  JIGGIT_EXPLORE_WRITE_MODE=""
  JIGGIT_PROMPT_INPUT_FILE=""
  JIGGIT_CAN_PROMPT_INTERACTIVELY="false"
}

cleanup_tmpdir() {
  if [[ -n "${TEST_TMPDIR}" && -d "${TEST_TMPDIR}" ]]; then
    rm -rf "${TEST_TMPDIR}"
  fi
}

create_repo() {
  local repo_dir="${1}"
  local remote_url="${2}"
  local commit_message="${3}"

  mkdir -p "${repo_dir}"
  git init "${repo_dir}" >/dev/null 2>&1
  git -C "${repo_dir}" config user.name "Jiggit Test"
  git -C "${repo_dir}" config user.email "jiggit@example.com"
  if [[ -n "${remote_url}" ]]; then
    git -C "${repo_dir}" remote add origin "${remote_url}"
  fi
  printf 'hello\n' > "${repo_dir}/README.md"
  git -C "${repo_dir}" add README.md
  git -C "${repo_dir}" commit -m "${commit_message}" >/dev/null 2>&1
  git -C "${repo_dir}" tag v1.2.3
}

test_slugify_repo_name() {
  local actual
  actual="$(slugify_repo_name 'My Cool_Repo')"
  assert_eq "my-cool-repo" "${actual}" "slugify repo names"
}

test_can_prompt_interactively_is_false_without_tty() {
  if JIGGIT_CAN_PROMPT_INTERACTIVELY="false" can_prompt_interactively; then
    fail "report non-interactive environment in tests"
  else
    pass "report non-interactive environment in tests"
  fi
}

test_detect_jira_regexes() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  create_repo "${TEST_TMPDIR}/alpha-service" "git@github.com:example/alpha-service.git" "ALPHA-123 first commit"
  git -C "${TEST_TMPDIR}/alpha-service" commit --allow-empty -m "ALPHA-456 second commit" >/dev/null 2>&1

  local actual
  actual="$(detect_jira_regexes "${TEST_TMPDIR}/alpha-service")"
  assert_eq "ALPHA-[0-9]+" "${actual}" "detect jira regexes from commits"
}

test_configured_status_for_repo_without_remote() {
  local actual
  reset_loaded_projects
  actual="$(configured_status_for_repo "/tmp/example-repo" "")"
  assert_eq "newly-discovered" "${actual}" "treat missing remote as unconfigured"
}

test_load_project_config_reads_toml_from_home_and_discovered_repo() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local home_dir="${TEST_TMPDIR}/home"
  local user_config_dir="${home_dir}/.jiggit/config"
  local user_shared_file="${home_dir}/.jiggit/config.toml"
  local repo_dir="${TEST_TMPDIR}/delta-api"
  mkdir -p "${user_config_dir}" "${repo_dir}/config"

  cat > "${user_shared_file}" <<'EOF'
[jira]
base_url = "https://jira.user.example.test"
bearer_token = "user-secret"
EOF

  cat > "${user_config_dir}/projects.toml" <<'EOF'

[home-api]
repo_path = "$HOME/src/home-api"
remote_url = "git@github.com:example/home-api.git"
jira_project_key = "HOME"
jira_regexes = ["HOME-[0-9]+", "PLAT-[0-9]+"]
environments = ["prod", "prep"]
EOF

  cat > "${repo_dir}/config/projects.toml" <<'EOF'
[delta-api]
repo_path = "~/src/delta-api"
remote_url = "git@github.com:example/delta-api.git"
jira_project_key = "DELTA"
jira_regexes = ["DELTA-[0-9]+"]
environments = ["prod"]
info_version_expr = "jq -r '.build.version'"

[delta-api.environment_info_urls]
prod = "https://prod.delta.example/actuator/info"
EOF

  HOME="${home_dir}" load_project_config "${repo_dir}"

  if project_exists "home-api"; then
    pass "load user TOML config"
  else
    fail "load user TOML config"
  fi

  if project_exists "delta-api"; then
    pass "load discovered repo TOML config"
  else
    fail "load discovered repo TOML config"
  fi

  assert_eq "${home_dir}/src/delta-api" "$(project_repo_path "delta-api")" "expand tilde repo path from repo config"
  assert_eq "HOME" "$(project_jira_project_key "home-api")" "read jira key from user config"
  assert_eq "${home_dir}/src/home-api" "$(project_repo_path "home-api")" "expand dollar-home repo path from user config"
  assert_eq "prod=https://prod.delta.example/actuator/info" "$(project_environment_info_urls "delta-api")" "read environment info urls from nested TOML table"
  assert_eq "jq -r '.build.version'" "$(project_info_version_expr "delta-api")" "read per-project version expression from TOML"
  assert_eq "https://jira.user.example.test" "$(jira_base_url)" "read shared jira base url from user config.toml"
  assert_eq "user-secret" "$(jira_bearer_token)" "read shared jira bearer token from user config.toml"
}

test_resolve_discovery_file_path_defaults_to_user_home() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local actual
  actual="$(HOME="${TEST_TMPDIR}/home" resolve_discovery_file_path)"
  assert_eq "${TEST_TMPDIR}/home/.jiggit/discovered_projects.toml" "${actual}" "default discovery path uses ~/.jiggit"
}

test_resolve_project_selector_accepts_project_id_path_and_current_directory() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local repo_dir="${TEST_TMPDIR}/selector-repo"
  create_repo "${repo_dir}" "git@github.com:example/selector-repo.git" "SEL-1 initial commit"

  local projects_file="${TEST_TMPDIR}/projects.toml"
  cat > "${projects_file}" <<EOF
[selector-project]
repo_path = "${repo_dir}"
remote_url = "git@github.com:example/selector-repo.git"
jira_project_key = "SEL"
jira_regexes = ["SEL-[0-9]+"]
EOF

  JIGGIT_PROJECTS_FILE="${projects_file}" \
  JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
  load_project_config

  assert_eq "selector-project" "$(resolve_project_selector "selector-project")" "resolve explicit project id"
  assert_eq "selector-project" "$(resolve_project_selector "${repo_dir}")" "resolve explicit repo path"

  local actual_from_cwd
  actual_from_cwd="$(
    cd "${repo_dir}"
    resolve_project_selector ""
  )"
  assert_eq "selector-project" "${actual_from_cwd}" "resolve current working directory"
}

test_effective_single_and_multi_project_selectors_follow_global_flags() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local repo_one="${TEST_TMPDIR}/alpha"
  local repo_two="${TEST_TMPDIR}/beta"
  local projects_file="${TEST_TMPDIR}/projects.toml"
  mkdir -p "${repo_one}" "${repo_two}"
  git init "${repo_one}" >/dev/null 2>&1
  git init "${repo_two}" >/dev/null 2>&1

  cat > "${projects_file}" <<EOF
[alpha]
repo_path = "${repo_one}"

[beta]
repo_path = "${repo_two}"
EOF

  JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    load_project_config

  assert_eq "alpha" "$(JIGGIT_PROJECT_SELECTORS="alpha" effective_single_project_selector "")" "single-project selector uses global --projects"

  local single_error=""
  if single_error="$(JIGGIT_PROJECT_SELECTORS="alpha,beta" effective_single_project_selector "" 2>&1)"; then
    fail "single-project selector rejects multiple global selectors"
  else
    pass "single-project selector rejects multiple global selectors"
    assert_contains "${single_error}" "accepts only one project" "render helpful multi-selector error"
  fi

  local multi_output
  # shellcheck disable=SC2119
  multi_output="$(JIGGIT_PROJECT_SELECTORS="alpha,beta" effective_multi_project_selectors)"
  assert_contains "${multi_output}" "alpha" "multi-project selectors include first global selector"
  assert_contains "${multi_output}" "beta" "multi-project selectors include second global selector"

  # shellcheck disable=SC2119
  multi_output="$(JIGGIT_ALL_PROJECTS=1 effective_multi_project_selectors)"
  assert_contains "${multi_output}" "alpha" "all-projects includes first configured project"
  assert_contains "${multi_output}" "beta" "all-projects includes second configured project"
}

test_run_explore_main_writes_candidate_file() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  create_repo "${TEST_TMPDIR}/beta-api" "git@github.com:example/beta-api.git" "BETA-7 initial commit"

  local projects_file="${TEST_TMPDIR}/projects.toml"
  local discovered_file="${TEST_TMPDIR}/home/.jiggit/discovered_projects.toml"
  : > "${projects_file}"

  local output
  output="$(
    HOME="${TEST_TMPDIR}/home" \
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${discovered_file}" \
    run_explore_main --append "${TEST_TMPDIR}"
  )"

  assert_contains "${output}" "Newly discovered: 1" "report discovered repo count"
  assert_contains "${output}" "beta-api" "report repo name"

  local discovered_contents
  discovered_contents="$(sed -n '1,120p' "${discovered_file}")"
  assert_contains "${discovered_contents}" "[beta-api]" "write TOML project table"
  assert_contains "${discovered_contents}" "jira_regexes = [\"BETA-[0-9]+\"]" "write inferred jira regex array"
  if grep -Fq 'display_name = "beta-api"' <<<"${discovered_contents}"; then
    fail "omit redundant display_name in discovered TOML"
  else
    pass "omit redundant display_name in discovered TOML"
  fi
}

test_run_explore_main_dry_run_does_not_write_candidate_file() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  create_repo "${TEST_TMPDIR}/gamma-api" "" "GAMMA-42 initial commit"

  local projects_file="${TEST_TMPDIR}/projects.toml"
  local discovered_file="${TEST_TMPDIR}/home/.jiggit/discovered_projects.toml"
  mkdir -p "$(dirname "${discovered_file}")"
  : > "${projects_file}"
  cat > "${discovered_file}" <<'EOF'
#!/usr/bin/env bash
# keep me
EOF

  local output
  output="$(
    HOME="${TEST_TMPDIR}/home" \
    JIGGIT_CAN_PROMPT_INTERACTIVELY="false" \
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${discovered_file}" \
    run_explore_main --dry-run --verbose "${TEST_TMPDIR}" 2>&1
  )"

  assert_contains "${output}" "Mode: \`dry-run\`" "report dry-run mode"
  assert_contains "${output}" "[explore] Dry run enabled; not writing" "emit verbose dry-run message"

  local discovered_contents
  discovered_contents="$(sed -n '1,120p' "${discovered_file}")"
  assert_contains "${discovered_contents}" "# keep me" "preserve discovered file during dry run"
}

test_write_discovery_file_requires_mode_when_file_exists_non_interactively() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local discovered_file="${TEST_TMPDIR}/home/.jiggit/discovered_projects.toml"
  mkdir -p "$(dirname "${discovered_file}")"
  cat > "${discovered_file}" <<'EOF'
# existing
EOF

  local output=""
  if output="$(
    HOME="${TEST_TMPDIR}/home" \
    JIGGIT_CAN_PROMPT_INTERACTIVELY="false" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${discovered_file}" \
    write_discovery_file "[alpha]" 2>&1
  )"; then
    fail "require explicit write mode when discovery file exists"
  else
    pass "require explicit write mode when discovery file exists"
    assert_contains "${output}" "Interactive append is the default." "explain interactive default"
  fi
}

test_explore_can_create_missing_shared_jira_config() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local repo_dir="${TEST_TMPDIR}/create-missing-repo"
  create_repo "${repo_dir}" "git@example.com:org/create-missing-repo.git" "ALPHA-1 feat: one"

  local projects_file="${TEST_TMPDIR}/projects.toml"
  cat > "${projects_file}" <<'EOF'
[alpha]
repo_path = "/tmp/alpha"
remote_url = "git@example.com:org/alpha.git"
jira_project_key = "ALPHA"
jira_regexes = ["ALPHA-[0-9]+"]
environments = []
EOF

  cat > "${TEST_TMPDIR}/explore-input.txt" <<'EOF'
https://jira.example.com
token-123
y


EOF

  JIGGIT_CAN_PROMPT_INTERACTIVELY=true \
    JIGGIT_PROMPT_INPUT_FILE="${TEST_TMPDIR}/explore-input.txt" \
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${TEST_TMPDIR}/discovered.toml" \
    run_explore_main --dry-run "${repo_dir}" >/dev/null

  local updated_file
  updated_file="$(cat "${projects_file}")"
  assert_contains "${updated_file}" "[jira]" "append jira table during default explore repair"
  assert_contains "${updated_file}" 'base_url = "https://jira.example.com"' "write jira base url during default explore repair"
  assert_contains "${updated_file}" 'bearer_token = "token-123"' "write jira bearer token during default explore repair"
}

test_explore_can_fill_discovered_candidate_details() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local repo_dir="${TEST_TMPDIR}/gamma-api"
  create_repo "${repo_dir}" "git@example.com:org/gamma-api.git" "GAMMA-1 feat: one"

  local projects_file="${TEST_TMPDIR}/projects.toml"
  cat > "${projects_file}" <<'EOF'
[jira]
base_url = "https://jira.example.com"
bearer_token = "token-123"
EOF

  local discovered_file="${TEST_TMPDIR}/discovered.toml"
  cat > "${TEST_TMPDIR}/explore-input.txt" <<'EOF'
GAMMA
prod prep
https://prod.example.com/actuator/info
https://prep.example.com/actuator/info
jq -r '.git.branch'
EOF

  JIGGIT_CAN_PROMPT_INTERACTIVELY=true \
    JIGGIT_PROMPT_INPUT_FILE="${TEST_TMPDIR}/explore-input.txt" \
    JIGGIT_PROJECTS_FILE="${projects_file}" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${discovered_file}" \
    run_explore_main --replace "${repo_dir}" >/dev/null

  local discovered_contents
  discovered_contents="$(cat "${discovered_file}")"
  assert_contains "${discovered_contents}" 'jira_project_key = "GAMMA"' "write prompted jira project key into candidate"
  assert_contains "${discovered_contents}" 'environments = ["prod", "prep"]' "write prompted environments into candidate"
  assert_contains "${discovered_contents}" 'info_version_expr = "jq -r '\''.git.branch'\''"' "write prompted version expression into candidate"
  assert_contains "${discovered_contents}" "[gamma-api.environment_info_urls]" "write nested environment info url table"
  assert_contains "${discovered_contents}" 'prod = "https://prod.example.com/actuator/info"' "write prompted prod info url"
  assert_contains "${discovered_contents}" 'prep = "https://prep.example.com/actuator/info"' "write prompted prep info url"
}

test_write_discovery_file_appends_when_requested() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local discovered_file="${TEST_TMPDIR}/home/.jiggit/discovered_projects.toml"
  mkdir -p "$(dirname "${discovered_file}")"
  cat > "${discovered_file}" <<'EOF'
[existing]
EOF

  HOME="${TEST_TMPDIR}/home" \
  JIGGIT_DISCOVERED_PROJECTS_FILE="${discovered_file}" \
  JIGGIT_EXPLORE_WRITE_MODE="append" \
  write_discovery_file "[beta-api]
repo_path = \"/tmp/beta-api\""

  local discovered_contents
  discovered_contents="$(sed -n '1,120p' "${discovered_file}")"
  assert_contains "${discovered_contents}" "[existing]" "preserve existing discovery content when appending"
  assert_contains "${discovered_contents}" "[beta-api]" "append new discovery content"
}

test_render_candidate_append_prompt_shows_section_preview() {
  local prompt

  prompt="$(render_candidate_append_prompt "/tmp/discovered_projects.toml" "[alpha-login]
repo_path = \"/tmp/alpha-login\"")"

  assert_contains "${prompt}" "About to append discovered project alpha-login to /tmp/discovered_projects.toml." "describe the target discovery append"
  assert_contains "${prompt}" "Do you want to add the following section? [y/N/q]:" "show the interactive preview question"
  assert_contains "${prompt}" "[alpha-login]" "include the discovered table header in the preview"
  assert_contains "${prompt}" "repo_path = \"/tmp/alpha-login\"" "include the discovered field lines in the preview"
}

run_tests "$@"
