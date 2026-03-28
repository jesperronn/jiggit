#!/usr/bin/env bash
set -euo pipefail

pushd "$(dirname "$0")/../.." > /dev/null || exit 1

source bin/lib/bash_test.sh
source bin/lib/explore.sh
source bin/lib/config_command.sh

TEST_TMPDIR=""

setup_tmpdir() {
  TEST_TMPDIR="$(mktemp -d /tmp/jiggit-config-test.XXXXXX)"
}

cleanup_tmpdir() {
  if [[ -n "${TEST_TMPDIR}" && -d "${TEST_TMPDIR}" ]]; then
    rm -rf "${TEST_TMPDIR}"
  fi
}

test_run_config_main_renders_loaded_files_projects_and_overrides() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local home_dir="${TEST_TMPDIR}/home"
  local repo_config_dir="${TEST_TMPDIR}/repo-config"
  mkdir -p "${home_dir}/.jiggit/config" "${repo_config_dir}"

  cat > "${repo_config_dir}/projects.toml" <<'EOF'
[alpha]
repo_path = "/tmp/alpha"
remote_url = "git@github.com:example/alpha.git"
jira_project_key = "ALPHA"
jira_regexes = ["ALPHA-[0-9]+"]
environments = ["prod"]
EOF

  cat > "${home_dir}/.jiggit/config/projects.toml" <<'EOF'
[alpha]
repo_path = "/tmp/alpha-override"
remote_url = "git@github.com:example/alpha.git"
jira_project_key = "ALPHA"
jira_regexes = ["ALPHA-[0-9]+"]
environments = ["prod", "prep"]
info_version_expr = "jq -r '.build.version'"

[alpha.environment_info_urls]
prod = "https://prod.alpha.example/actuator/info"
prep = "https://prep.alpha.example/actuator/info"

[beta]
repo_path = "/tmp/beta"
remote_url = "git@github.com:example/beta.git"
jira_project_key = "BETA"
jira_regexes = ["BETA-[0-9]+"]
environments = []
EOF

  local output
  output="$(
    HOME="${home_dir}" \
    JIGGIT_CONFIG_DIR="${home_dir}/.jiggit/config" \
    JIGGIT_PROJECTS_FILE="${repo_config_dir}/projects.toml" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${home_dir}/.jiggit/config/projects.toml" \
    run_config_main
  )"

  assert_contains "${output}" "## Loaded Config Files" "render loaded config files section"
  assert_contains "${output}" "/tmp/alpha-override" "render effective overridden repo path"
  assert_contains "${output}" "\`beta\`" "render additional project"
  assert_contains "${output}" "prod=https://prod.alpha.example/actuator/info prep=https://prep.alpha.example/actuator/info" "render environment info url pairs"
  assert_contains "${output}" "jq -r '.build.version'" "render info version expression"
  assert_contains "${output}" "Project alpha overridden by" "render override warning"
  if grep -Fq "display name:" <<<"${output}"; then
    fail "do not render removed display name field"
  else
    pass "do not render removed display name field"
  fi
}

test_run_config_main_can_force_colored_headings_and_project_items() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local home_dir="${TEST_TMPDIR}/home"
  local repo_config_dir="${TEST_TMPDIR}/repo-config"
  mkdir -p "${home_dir}/.jiggit/config" "${repo_config_dir}"

  cat > "${repo_config_dir}/projects.toml" <<'EOF'
[alpha]
repo_path = "/tmp/alpha"
remote_url = "git@github.com:example/alpha.git"
jira_regexes = ["ALPHA-[0-9]+"]
environments = []
EOF

  local output
  output="$(
    HOME="${home_dir}" \
    JIGGIT_COLOR_OUTPUT=always \
    JIGGIT_PROJECTS_FILE="${repo_config_dir}/projects.toml" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${home_dir}/.jiggit/discovered_projects.toml" \
    run_config_main
  )"

  assert_contains "${output}" $'\e[1m\e[34m# jiggit config\e[0m' "render colored top heading"
  assert_contains "${output}" $'\e[1m\e[36m## Loaded Config Files\e[0m' "render colored loaded-files heading"
  assert_contains "${output}" $'\e[1m\e[35m## Jira\e[0m' "render colored jira heading"
  assert_contains "${output}" "Jira base URL: \`missing\`" "render shared jira base url diagnostic"
  assert_contains "${output}" "Jira auth mode: \`missing\`" "render shared jira auth diagnostic"
  assert_contains "${output}" "Jira API token: \`missing\`" "render shared jira token diagnostic"
  assert_contains "${output}" $'\e[1m\e[34m## Projects\e[0m' "render colored projects heading"
  assert_contains "${output}" $'\e[1m\e[32m- `alpha`\e[0m' "render colored project item"
  assert_contains "${output}" $'\e[1m\e[38;5;202m  - jira project key: `missing`\e[0m' "render missing jira project key as orange warning"
  assert_contains "${output}" $'\e[1m\e[38;5;202m  - environments: `none`\e[0m' "render missing environments as orange warning"
}

test_run_config_main_can_show_named_projects_and_globals_only() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local home_dir="${TEST_TMPDIR}/home"
  local repo_config_dir="${TEST_TMPDIR}/repo-config"
  mkdir -p "${home_dir}/.jiggit/config" "${repo_config_dir}"

  cat > "${repo_config_dir}/projects.toml" <<'EOF'
[alpha]
repo_path = "/tmp/alpha"
remote_url = "git@github.com:example/alpha.git"
jira_project_key = "ALPHA"
jira_regexes = ["ALPHA-[0-9]+"]
environments = ["prod"]

[beta]
repo_path = "/tmp/beta"
remote_url = "git@github.com:example/beta.git"
jira_project_key = "BETA"
jira_regexes = ["BETA-[0-9]+"]
environments = ["prep"]
EOF

  local named_output
  named_output="$(
    HOME="${home_dir}" \
    JIGGIT_PROJECTS_FILE="${repo_config_dir}/projects.toml" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${home_dir}/.jiggit/discovered_projects.toml" \
    run_config_main alpha
  )"

  assert_contains "${named_output}" "## Projects" "render projects section for named lookup"
  assert_contains "${named_output}" "\`alpha\`" "render requested project"
  if grep -Fq "\`beta\`" <<<"${named_output}"; then
    fail "named config lookup should not include unrequested projects"
  else
    pass "named config lookup excludes unrequested projects"
  fi

  local global_output
  global_output="$(
    HOME="${home_dir}" \
    JIGGIT_PROJECTS_FILE="${repo_config_dir}/projects.toml" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${home_dir}/.jiggit/discovered_projects.toml" \
    run_config_main --global
  )"

  assert_contains "${global_output}" "## Loaded Config Files" "render globals when --global is used"
  if grep -Fq "## Projects" <<<"${global_output}"; then
    fail "--global should hide the projects section"
  else
    pass "--global hides the projects section"
  fi
}

run_tests "$@"
