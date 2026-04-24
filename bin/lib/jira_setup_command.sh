#!/usr/bin/env bash

set -euo pipefail

if ! declare -F load_project_config >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/explore.sh"
fi

if ! declare -F fetch_jira_current_user >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/jira_check_command.sh"
fi

if ! declare -F jira_auth_args >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/jira_create.sh"
fi

# Render help for the setup jira flow.
jira_setup_usage() {
  print_jiggit_usage_block <<'EOF'
Usage:
  jiggit setup jira [<jira-name>]

Interactively create or repair Jira auth config.
EOF
}

# Prompt for override, skip, or quit when a setup write would change an existing value.
jira_setup_conflict_choice() {
  local prompt_text="${1}"
  local response=""

  while true; do
    response="$(prompt_input_line "${prompt_text} [o]verride/[s]kip/[q]uit: ")"
    case "${response}" in
      o|O|override|OVERRIDE)
        printf '%s\n' "override"
        return 0
        ;;
      s|S|skip|SKIP|'')
        printf '%s\n' "skip"
        return 0
        ;;
      q|Q|quit|QUIT)
        printf '%s\n' "quit"
        return 0
        ;;
    esac
  done
}

# Return the TOML section name for a Jira config entry.
jira_setup_section_name() {
  local jira_name="${1:-default}"

  if [[ -z "${jira_name}" || "${jira_name}" == "default" ]]; then
    printf '%s\n' "jira"
    return 0
  fi

  printf 'jira.%s\n' "${jira_name}"
}

# Return the config file jira-setup should update.
jira_setup_target_file() {
  local jira_name="${1:-default}"
  local source_file=""

  source_file="$(jira_config_source "${jira_name}")"
  if [[ -n "${source_file}" && "${source_file}" != "none" ]]; then
    printf '%s\n' "${source_file}"
    return 0
  fi

  if [[ -n "${JIGGIT_PROJECTS_FILE:-}" ]]; then
    printf '%s\n' "${JIGGIT_PROJECTS_FILE}"
    return 0
  fi

  printf '%s\n' "$(default_user_shared_config_file)"
}

# Return the default .envrc path for jira-setup guidance or edits.
jira_setup_envrc_file() {
  printf '%s\n' "${PWD}/.envrc"
}

# Append one export to .envrc when the exact line is not present.
jira_setup_append_envrc_export() {
  local envrc_file="${1}"
  local export_line="${2}"

  mkdir -p "$(dirname "${envrc_file}")"
  touch "${envrc_file}"
  if grep -Fqx "${export_line}" "${envrc_file}"; then
    return 0
  fi
  printf '%s\n' "${export_line}" >> "${envrc_file}"
}

# Upsert one Jira key inside the target TOML section, asking before overrides.
jira_setup_write_toml_value() {
  local target_file="${1}"
  local jira_name="${2}"
  local key_name="${3}"
  local raw_value="${4}"
  local section_name=""
  local existing_value=""
  local conflict_choice=""

  section_name="$(jira_setup_section_name "${jira_name}")"
  existing_value="$(existing_toml_value_in_section "${target_file}" "${section_name}" "${key_name}" || true)"

  if [[ -z "${existing_value}" ]]; then
    if prompt_confirm_toml_preview \
      "About to write Jira config to ${target_file}:" \
      "$(render_toml_upsert_preview "${target_file}" "${section_name}" "${key_name}" "${raw_value}")"; then
      upsert_toml_string_in_section "${target_file}" "${section_name}" "${key_name}" "${raw_value}"
    fi
    return 0
  fi

  if [[ "$(unquote_toml_string "${existing_value}")" == "${raw_value}" ]]; then
    return 0
  fi

  conflict_choice="$(jira_setup_conflict_choice "Existing ${section_name}.${key_name} differs.")"
  case "${conflict_choice}" in
    override)
      if prompt_confirm_toml_preview \
        "About to override Jira config in ${target_file}:" \
        "$(render_toml_upsert_preview "${target_file}" "${section_name}" "${key_name}" "${raw_value}")"; then
        upsert_toml_string_in_section "${target_file}" "${section_name}" "${key_name}" "${raw_value}"
      fi
      ;;
    quit)
      return 1
      ;;
  esac
}

# Validate one Jira config entry once and render the result.
jira_setup_validate_once() {
  local jira_name="${1}"
  local jira_base_url_value=""

  jira_base_url_value="$(jira_base_url "${jira_name}")"
  if [[ -z "${jira_base_url_value}" || "$(jira_auth_mode "${jira_name}")" == "missing" ]]; then
    printf -- "- validation: \`warn\` (missing Jira auth or base URL)\n"
    printf -- "- next step: \`jiggit jira-check\`\n"
    return 0
  fi

  if fetch_jira_current_user "${jira_base_url_value}" "${jira_name}" >/dev/null 2>&1; then
    printf -- "- validation: \`ok\` (auth probe succeeded)\n"
    printf -- "- next step: \`jiggit jira-check\`\n"
    return 0
  fi

  printf -- "- validation: \`fail\` (auth probe failed)\n"
  printf -- "- next step: \`jiggit jira-check\`\n"
  return 1
}

# Run the interactive Jira setup flow.
run_jira_setup_main() {
  local jira_name="${1:-}"
  local target_file=""
  local envrc_file=""
  local base_url=""
  local auth_choice=""
  local bearer_token=""
  local user_email=""
  local api_token=""
  local env_export=""

  if [[ "${jira_name}" == "-h" || "${jira_name}" == "--help" ]]; then
    jira_setup_usage
    return 0
  fi

  if [[ $# -gt 1 ]]; then
    printf 'jiggit setup jira accepts at most one Jira name.\n' >&2
    return 1
  fi

  if ! can_prompt_interactively; then
    printf 'jiggit setup jira requires an interactive terminal.\n' >&2
    return 1
  fi

  load_project_config

  jira_name="$(normalize_jira_name "${jira_name:-$(prompt_input_line "Jira config name [default]: ")}")"
  target_file="$(jira_setup_target_file "${jira_name}")"
  envrc_file="$(jira_setup_envrc_file)"

  print_markdown_h1 "jiggit setup jira"
  printf '\n'
  printf -- "- Jira config: \`%s\`\n" "${jira_name}"
  printf -- "- target file: \`%s\`\n" "${target_file}"
  printf -- "- envrc file: \`%s\`\n\n" "${envrc_file}"

  base_url="$(prompt_input_line "Jira base URL [$(jira_base_url "${jira_name}")]: ")"
  base_url="${base_url:-$(jira_base_url "${jira_name}")}"
  if [[ -z "${base_url}" ]]; then
    printf 'Jira base URL is required.\n' >&2
    return 1
  fi

  auth_choice="$(prompt_input_line "Store auth in [c]onfig or [.envrc]? [c]: ")"
  auth_choice="${auth_choice:-c}"

  if [[ "${auth_choice}" == "c" || "${auth_choice}" == "C" || "${auth_choice}" == "config" ]]; then
    bearer_token="$(prompt_input_line "Jira bearer token (leave empty to use email + api token): ")"
    if [[ -n "${bearer_token}" ]]; then
      jira_setup_write_toml_value "${target_file}" "${jira_name}" "base_url" "${base_url}" || return 1
      jira_setup_write_toml_value "${target_file}" "${jira_name}" "bearer_token" "${bearer_token}" || return 1
    else
      user_email="$(prompt_input_line "Jira user email: ")"
      api_token="$(prompt_input_line "Jira API token: ")"
      jira_setup_write_toml_value "${target_file}" "${jira_name}" "base_url" "${base_url}" || return 1
      jira_setup_write_toml_value "${target_file}" "${jira_name}" "user_email" "${user_email}" || return 1
      jira_setup_write_toml_value "${target_file}" "${jira_name}" "api_token" "${api_token}" || return 1
    fi
  else
    if [[ "${jira_name}" != "default" ]]; then
      printf 'Named Jira configs currently support .envrc only for the default Jira.\n' >&2
      return 1
    fi
    api_token="$(prompt_input_line "JIRA_API_TOKEN value: ")"
    jira_setup_write_toml_value "${target_file}" "${jira_name}" "base_url" "${base_url}" || return 1
    env_export="export JIRA_API_TOKEN=$(shell_quote "${api_token}")"
    jira_setup_append_envrc_export "${envrc_file}" "${env_export}"
    printf -- "- updated: \`%s\`\n" "${envrc_file}"
    printf -- "- reminder: \`direnv allow\` or reload your shell before retrying\n"
  fi

  load_project_config
  jira_setup_validate_once "${jira_name}"
}
