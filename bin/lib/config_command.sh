#!/usr/bin/env bash

set -euo pipefail

if ! declare -F load_project_config >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/explore.sh"
fi

if ! declare -F render_jira_check_access_body >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/jira_check_command.sh"
fi

if ! declare -F print_markdown_h1 >/dev/null 2>&1 || ! declare -F print_markdown_project_item >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/common_output.sh"
fi

# Render help for the config subcommand.
config_usage() {
  cat <<'EOF'
Usage:
  jiggit config [--global|--no-projects] [<project|path> ...]

Show the effective merged project configuration, including source files and override warnings.
EOF
}

# Render one project entry from the effective merged config.
render_project_config_entry() {
  local project_id="${1}"
  local repo_path
  local remote_url
  local jira_name
  local jira_project_key
  local jira_regexes
  local environments
  local environment_info_urls
  local info_version_expr
  local source_file

  repo_path="$(project_repo_path "${project_id}")"
  remote_url="$(project_remote_url "${project_id}")"
  jira_name="$(project_jira_name "${project_id}")"
  jira_project_key="$(project_jira_project_key "${project_id}")"
  jira_regexes="$(project_jira_regexes "${project_id}")"
  environments="$(project_environments "${project_id}")"
  environment_info_urls="$(project_environment_info_urls "${project_id}")"
  info_version_expr="$(project_info_version_expr "${project_id}")"
  source_file="$(project_source_file "${project_id}")"

  print_markdown_project_item "${project_id}"
  printf "  - repo path: \`%s\`\n" "${repo_path:-missing}"
  printf "  - remote url: \`%s\`\n" "${remote_url:-missing}"
  printf "  - jira config: \`%s\`\n" "${jira_name:-default}"
  if [[ -z "${jira_project_key}" ]]; then
    print_colored_line "${C_ORANGE}" "  - jira project key: \`missing\`"
  else
    printf "  - jira project key: \`%s\`\n" "${jira_project_key}"
  fi
  printf "  - jira regexes: \`%s\`\n" "${jira_regexes:-missing}"
  if [[ -z "${environments}" ]]; then
    print_colored_line "${C_ORANGE}" "  - environments: \`none\`"
  else
    printf "  - environments: \`%s\`\n" "${environments}"
  fi
  printf "  - environment info urls: \`%s\`\n" "${environment_info_urls:-none}"
  printf "  - info version expr: \`%s\`\n" "${info_version_expr:-${JIGGIT_DEFAULT_INFO_VERSION_EXPR:-cat}}"
  printf "  - source: \`%s\`\n" "${source_file:-unknown}"
}

# Render the merged config report, including loaded config files and overrides.
render_config_summary() {
  local show_projects="${1:-1}"
  shift || true
  local -a selectors=("$@")
  local project_id
  local selector
  local config_file
  local conflict
  local -a project_ids=()

  print_markdown_h1 "jiggit config"
  printf '\n'
  print_markdown_h2 "Loaded Config Files" "${C_CYAN}"
  printf '\n'
  if [[ ${#JIGGIT_LOADED_CONFIG_FILES[@]} -eq 0 ]]; then
    printf '_No config files were loaded._\n'
  else
    for config_file in "${JIGGIT_LOADED_CONFIG_FILES[@]}"; do
      printf -- "- \`%s\`\n" "${config_file}"
    done
  fi

  printf '\n'
  print_markdown_h2 "Jira" "${C_MAGENTA}"
  printf '\n'
  if [[ ${#selectors[@]} -gt 0 ]]; then
    for selector in "${selectors[@]}"; do
      project_id="$(resolve_project_selector "${selector}" || true)"
      if [[ -n "${project_id}" ]]; then
        project_ids+=("${project_id}")
      fi
    done
  else
    mapfile -t project_ids < <(effective_multi_project_selectors)
  fi
  render_jira_check_access_body "${project_ids[@]}"

  if [[ "${show_projects}" -eq 1 ]]; then
    printf '\n'
    print_markdown_h2 "Projects" "${C_BLUE}"
    printf '\n'

    if [[ ${#selectors[@]} -gt 0 ]]; then
      project_ids=()
      for selector in "${selectors[@]}"; do
        project_id="$(resolve_project_selector "${selector}" || true)"
        if [[ -z "${project_id}" ]]; then
          project_id="${selector}"
        fi
        project_ids+=("${project_id}")
      done
    else
      mapfile -t project_ids < <(effective_multi_project_selectors)
    fi

    if [[ ${#project_ids[@]} -eq 0 ]]; then
      printf '_No projects configured._\n'
    else
      for project_id in "${project_ids[@]}"; do
        render_project_config_entry "${project_id}"
      done
    fi
  fi

  if [[ ${#JIGGIT_CONFIG_CONFLICTS[@]} -gt 0 ]]; then
    printf '\n'
    print_markdown_h2 "Overrides" "${C_CYAN}"
    printf '\n'
    for conflict in "${JIGGIT_CONFIG_CONFLICTS[@]}"; do
      printf -- '- %s\n' "${conflict}"
    done
  fi
}

# Load config and print the effective merged view.
run_config_main() {
  local show_projects=1
  local -a selectors=()

  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    config_usage
    return 0
  fi

  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --global|--no-projects)
        show_projects=0
        shift
        ;;
      -h|--help)
        config_usage
        return 0
        ;;
      *)
        selectors+=("${1}")
        shift
        ;;
    esac
  done

  load_project_config
  render_config_summary "${show_projects}" "${selectors[@]}"
}
