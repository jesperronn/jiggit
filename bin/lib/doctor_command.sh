#!/usr/bin/env bash

set -euo pipefail

if ! declare -F load_project_config >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/explore.sh"
fi

if ! declare -F fetch_jira_project_metadata >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/jira_check_command.sh"
fi

if ! declare -F fetch_project_environment_version >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/env_versions_command.sh"
fi

if ! declare -F fetch_jira_releases >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/releases_command.sh"
fi

if ! declare -F print_markdown_h1 >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/common_output.sh"
fi

JIGGIT_DOCTOR_IGNORE_FAILURES=0
JIGGIT_DOCTOR_FAIL_FAST=0
# Render help for the doctor command.
doctor_usage() {
  print_jiggit_usage_block <<'EOF'
Usage:
  jiggit doctor [--global|--no-projects] [--fail-fast] [--ignore-failures] [<project|path> ...]

Run health checks for configured projects. Defaults to all configured projects.
EOF
}

# Emit one doctor check line and track failures unless ignore mode is enabled.
doctor_emit_check() {
  local label="${1}"
  local status="${2}"
  local detail="${3:-}"

  printf -- "- %s: \`%s\`" "${label}" "${status}"
  if [[ -n "${detail}" ]]; then
    printf " (%s)" "${detail}"
  fi
  printf '\n'

  if [[ "${status}" == "fail" ]]; then
    JIGGIT_DOCTOR_SAW_FAILURE=1
  fi
}

# Emit one copy-paste-friendly next-step line in doctor output.
doctor_emit_next_step() {
  local description="${1}"
  local command_text="${2}"

  printf -- "- %s: \`%s\`\n" "${description}" "${command_text}"
}

# Render the Jira access probe result once per doctor run using jira-check diagnostics.
render_doctor_jira_access() {
  local jira_output=""

  print_markdown_h2 "Jira Access" "${C_MAGENTA}"
  printf '\n'
  jira_output="$(render_jira_check_access_body)"
  printf '%s' "${jira_output}"
  if [[ "${jira_output}" == *"jira access: \`fail\`"* || "${jira_output}" == *"jira access: \`missing-prereq\`"* ]]; then
    JIGGIT_DOCTOR_SAW_FAILURE=1
  fi
  printf '\n'
}

# Return the config file doctor should update for one project-level repair.
doctor_project_target_file() {
  local project_id="${1}"
  local source_file=""

  source_file="$(project_source_file "${project_id}")"
  if [[ -n "${source_file}" && "${source_file}" != "unknown" ]]; then
    printf '%s\n' "${source_file}"
    return 0
  fi

  if [[ -n "${JIGGIT_PROJECTS_FILE:-}" ]]; then
    printf '%s\n' "${JIGGIT_PROJECTS_FILE}"
    return 0
  fi

  printf '%s\n' "$(default_user_config_dir)/projects.toml"
}

# Return the config file doctor should update when creating shared Jira config.
doctor_shared_jira_target_file() {
  local source_file

  source_file="$(jira_config_source)"
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

# Append a minimal shared Jira config block to the chosen TOML file.
doctor_append_shared_jira_config() {
  local target_file="${1}"
  local jira_name="${2}"
  local jira_base_url_value="${3}"
  local jira_bearer_token_value="${4}"

  append_shared_jira_config_block "${target_file}" "${jira_name}" "${jira_base_url_value}" "${jira_bearer_token_value}"
}

# Interactively scaffold shared Jira config when doctor detects it is missing.
doctor_maybe_create_missing_shared_jira_config() {
  local target_file=""
  local jira_name="default"
  local jira_base_url_value=""
  local jira_bearer_token_value=""

  if [[ -n "$(jira_base_url)" ]]; then
    return 0
  fi

  if ! can_prompt_interactively; then
    return 0
  fi

  target_file="$(doctor_shared_jira_target_file)"
  jira_base_url_value="$(prompt_input_line "Jira base URL for ${target_file} (leave empty to skip): ")"
  if [[ -n "${jira_base_url_value}" ]]; then
    jira_bearer_token_value="$(prompt_input_line "Jira bearer token (leave empty to fill later): ")"
    if prompt_confirm_toml_preview \
      "Shared Jira config is missing. About to append this block to ${target_file}:" \
      "$(render_shared_jira_config_preview "${jira_name}" "${jira_base_url_value}" "${jira_bearer_token_value}")"; then
      doctor_append_shared_jira_config "${target_file}" "${jira_name}" "${jira_base_url_value}" "${jira_bearer_token_value}"
    fi
  fi
}

# Prompt for missing per-project config and write it back into the owning TOML file.
doctor_maybe_repair_project_config() {
  local project_id="${1}"
  local target_file=""
  local repo_path=""
  local remote_url=""
  local inferred_remote_url=""
  local jira_project_key_value=""
  local jira_regexes=""
  local inferred_jira_regexes=""
  local environments=""
  local new_environments=""
  local inferred_environments=""
  local environment_info_urls=""
  local environment_name=""
  local environment_url=""
  local info_version_expr=""
  local new_info_version_expr=""
  local changed=0

  if ! can_prompt_interactively; then
    return 0
  fi

  target_file="$(doctor_project_target_file "${project_id}")"
  repo_path="$(project_repo_path "${project_id}")"
  remote_url="$(project_remote_url "${project_id}")"
  jira_project_key_value="$(project_jira_project_key "${project_id}")"
  jira_regexes="$(project_jira_regexes "${project_id}")"
  environments="$(project_environments "${project_id}")"
  environment_info_urls="$(project_environment_info_urls "${project_id}")"
  info_version_expr="$(project_info_version_expr "${project_id}")"

  if [[ -z "${remote_url}" && -n "${repo_path}" && -d "${repo_path}" ]]; then
    inferred_remote_url="$(git_origin_url "${repo_path}")"
    if [[ -n "${inferred_remote_url}" ]]; then
      if prompt_confirm_toml_preview \
        "Project ${project_id} is missing remote_url in ${target_file}. About to write:" \
        "$(render_toml_upsert_preview "${target_file}" "${project_id}" "remote_url" "${inferred_remote_url}")"; then
        upsert_toml_string_in_section "${target_file}" "${project_id}" "remote_url" "${inferred_remote_url}"
        changed=1
      fi
    fi
  fi

  if [[ -z "${jira_project_key_value}" ]]; then
    if [[ -n "${jira_regexes}" && "${jira_regexes}" != *" "* ]]; then
      jira_project_key_value="${jira_regexes%%-*}"
      if prompt_confirm_toml_preview \
        "Project ${project_id} is missing jira_project_key in ${target_file}. About to write:" \
        "$(render_toml_upsert_preview "${target_file}" "${project_id}" "jira_project_key" "${jira_project_key_value}")"; then
          upsert_toml_string_in_section "${target_file}" "${project_id}" "jira_project_key" "${jira_project_key_value}"
          changed=1
      else
        jira_project_key_value=""
      fi
    fi
  fi

  if [[ -z "${jira_project_key_value}" ]]; then
    jira_project_key_value="$(prompt_input_line "Jira project key for ${project_id} (leave empty to skip): ")"
    if [[ -n "${jira_project_key_value}" ]]; then
      if prompt_confirm_toml_preview \
        "Project ${project_id} is missing jira_project_key in ${target_file}. About to write:" \
        "$(render_toml_upsert_preview "${target_file}" "${project_id}" "jira_project_key" "${jira_project_key_value}")"; then
          upsert_toml_string_in_section "${target_file}" "${project_id}" "jira_project_key" "${jira_project_key_value}"
          changed=1
      fi
    fi
  fi

  if [[ -z "${jira_regexes}" && -n "${repo_path}" && -d "${repo_path}" ]]; then
    inferred_jira_regexes="$(detect_jira_regexes "${repo_path}")"
    if [[ -n "${inferred_jira_regexes}" ]]; then
      if prompt_confirm_toml_preview \
        "Project ${project_id} is missing jira_regexes in ${target_file}. About to write:" \
        "$(render_toml_array_upsert_preview "${target_file}" "${project_id}" "jira_regexes" "${inferred_jira_regexes}")"; then
        upsert_toml_array_in_section "${target_file}" "${project_id}" "jira_regexes" "${inferred_jira_regexes}"
        changed=1
      fi
    fi
  fi

  if [[ -z "${environments}" ]]; then
    if [[ -n "${environment_info_urls}" ]]; then
      inferred_environments="$(printf '%s\n' "${environment_info_urls}" | tr ' ' '\n' | sed 's/=.*//' | paste -sd' ' -)"
      inferred_environments="$(trim "${inferred_environments}")"
      if [[ -n "${inferred_environments}" ]]; then
        if prompt_confirm_toml_preview \
          "Project ${project_id} is missing environments in ${target_file}. About to write:" \
          "$(render_toml_array_upsert_preview "${target_file}" "${project_id}" "environments" "${inferred_environments}")"; then
          upsert_toml_array_in_section "${target_file}" "${project_id}" "environments" "${inferred_environments}"
          environments="${inferred_environments}"
          changed=1
        fi
      fi
    fi
  fi

  if [[ -z "${environments}" ]]; then
    new_environments="$(prompt_input_line "Environments for ${project_id} (space-separated, leave empty to skip): ")"
    new_environments="$(trim "${new_environments}")"
    if [[ -n "${new_environments}" ]]; then
      if prompt_confirm_toml_preview \
        "Project ${project_id} is missing environments in ${target_file}. About to write:" \
        "$(render_toml_array_upsert_preview "${target_file}" "${project_id}" "environments" "${new_environments}")"; then
        upsert_toml_array_in_section "${target_file}" "${project_id}" "environments" "${new_environments}"
        environments="${new_environments}"
        changed=1
      fi
    fi
  fi

  if [[ -n "${environments}" && -z "${info_version_expr}" ]]; then
    new_info_version_expr="$(prompt_input_line "Version extraction expression for ${project_id} [cat]: ")"
    new_info_version_expr="${new_info_version_expr:-cat}"
    if prompt_confirm_toml_preview \
      "Project ${project_id} is missing info_version_expr in ${target_file}. About to write:" \
      "$(render_toml_upsert_preview "${target_file}" "${project_id}" "info_version_expr" "${new_info_version_expr}")"; then
      upsert_toml_string_in_section "${target_file}" "${project_id}" "info_version_expr" "${new_info_version_expr}"
      info_version_expr="${new_info_version_expr}"
      changed=1
    fi
  fi

  for environment_name in ${environments}; do
    environment_url="$(project_environment_info_url "${project_id}" "${environment_name}")"
    if [[ -n "${environment_url}" ]]; then
      continue
    fi

    environment_url="$(prompt_input_line "Info URL for ${project_id} ${environment_name} (leave empty to skip): ")"
    if [[ -n "${environment_url}" ]]; then
      if prompt_confirm_toml_preview \
        "Project ${project_id} is missing an info URL for ${environment_name} in ${target_file}. About to write:" \
        "$(render_toml_upsert_preview "${target_file}" "${project_id}.environment_info_urls" "${environment_name}" "${environment_url}")"; then
          upsert_toml_string_in_section "${target_file}" "${project_id}.environment_info_urls" "${environment_name}" "${environment_url}"
          changed=1
      fi
    fi
  done

  if [[ "${changed}" -eq 1 ]]; then
    load_project_config
  fi
}

# Run prerequisite checks shared across all projects.
render_doctor_prereqs() {
  local program

  print_markdown_h2 "Prerequisites" "${C_CYAN}"
  printf '\n'
  for program in git curl jq; do
    if command -v "${program}" >/dev/null 2>&1; then
      doctor_emit_check "${program}" "ok"
    else
      doctor_emit_check "${program}" "fail" "missing command"
    fi
  done
  if command -v jiggit >/dev/null 2>&1; then
    doctor_emit_check "jiggit" "ok" "directly callable"
  else
    doctor_emit_check "jiggit" "warn" "not directly callable; run bin/setup"
    doctor_emit_next_step "make jiggit directly callable" "bin/setup"
  fi
  printf '\n'
}

# Run doctor checks for one configured project.
render_doctor_project() {
  local project_id="${1}"
  local repo_path
  local jira_project_key
  local environments
  local environment_name
  local metadata_json
  local releases_json
  local env_version
  local jira_base_url_value
  local jira_name
  local project_source=""
  local show_config_next_step=0
  local show_jira_next_step=0
  local show_env_next_step=0
  local access_result=""
  local access_state=""

  doctor_maybe_repair_project_config "${project_id}"
  repo_path="$(project_repo_path "${project_id}")"
  jira_name="$(project_jira_name "${project_id}")"
  jira_project_key="$(project_jira_project_key "${project_id}")"
  environments="$(project_environments "${project_id}")"
  jira_base_url_value="$(jira_base_url "${project_id}")"
  project_source="$(project_source_file "${project_id}")"
  access_result="$(jira_check_probe_access "${project_id}")"
  access_state="${access_result%%|*}"

  print_markdown_h2 "${project_id}" "${C_GREEN}"
  printf '\n'
  doctor_emit_check "command" "jiggit doctor ${project_id}"
  if [[ -n "${project_source}" ]]; then
    doctor_emit_check "config source" "info" "${project_source}"
  fi
  doctor_emit_check "jira config" "info" "${jira_name:-default}"

  if [[ -n "${repo_path}" && -d "${repo_path}" ]]; then
    doctor_emit_check "repo path" "ok" "${repo_path}"
  else
    doctor_emit_check "repo path" "fail" "${repo_path:-missing}"
    show_config_next_step=1
  fi

  if [[ -n "${jira_project_key}" && -n "${jira_base_url_value}" && "${access_state}" == "ok" ]]; then
    if metadata_json="$(fetch_jira_project_metadata "${jira_base_url_value}" "${jira_project_key}" "${project_id}" 2>/dev/null)"; then
      doctor_emit_check "jira project" "ok" "$(printf '%s\n' "${metadata_json}" | jq -r '.name // .key // "unknown"')"
    else
      doctor_emit_check "jira project" "fail" "${jira_project_key}"
      show_jira_next_step=1
    fi

    if releases_json="$(fetch_jira_releases "${jira_base_url_value}" "${jira_project_key}" "${project_id}" 2>/dev/null)"; then
      doctor_emit_check "jira releases" "ok" "$(printf '%s\n' "${releases_json}" | jq -r 'length') found"
    else
      doctor_emit_check "jira releases" "warn" "unable to fetch"
      show_jira_next_step=1
    fi
  elif [[ "${access_state}" == "failed" || "${access_state}" == "missing-prereq" ]]; then
    doctor_emit_check "jira project" "unknown" "skipped after Jira auth failure"
    doctor_emit_check "jira releases" "unknown" "skipped after Jira auth failure"
    show_jira_next_step=1
  else
    doctor_emit_check "jira project" "fail" "missing Jira config"
    doctor_emit_check "jira releases" "fail" "missing Jira config"
    show_config_next_step=1
  fi

  if [[ -z "${environments}" ]]; then
    doctor_emit_check "env versions" "warn" "no environments configured"
    show_config_next_step=1
  else
    for environment_name in ${environments}; do
      if env_version="$(fetch_project_environment_version "${project_id}" "${environment_name}" 2>/dev/null)"; then
        doctor_emit_check "env ${environment_name}" "ok" "${env_version}"
      else
        doctor_emit_check "env ${environment_name}" "warn" "unable to resolve"
        show_env_next_step=1
      fi
    done
  fi

  if [[ "${show_config_next_step}" -eq 1 || "${show_jira_next_step}" -eq 1 || "${show_env_next_step}" -eq 1 ]]; then
    printf '\n'
    print_markdown_h2 "Next Steps" "${C_CYAN}"
    printf '\n'
    if [[ "${show_config_next_step}" -eq 1 ]]; then
      doctor_emit_next_step "review effective config" "jiggit config"
    fi
    if [[ "${show_jira_next_step}" -eq 1 ]]; then
      doctor_emit_next_step "repair Jira setup" "jiggit setup jira"
      doctor_emit_next_step "verify Jira access" "jiggit jira-check ${project_id}"
    fi
    if [[ "${show_env_next_step}" -eq 1 ]]; then
      doctor_emit_next_step "inspect environment versions" "jiggit env-versions ${project_id}"
    fi
  fi

  printf '\n'
}

# Resolve the set of projects doctor should inspect.
doctor_target_projects() {
  local selector=""
  local project_id=""

  while IFS= read -r selector; do
    [[ -z "${selector}" ]] && continue
    project_id="$(resolve_project_selector "${selector}" || true)"
    if [[ -n "${project_id}" ]]; then
      printf '%s\n' "${project_id}"
    else
      printf '%s\n' "${selector}"
    fi
  done < <(effective_multi_project_selectors "$@")
}

# Load config, run doctor across requested or all projects, and return summary status.
run_doctor_main() {
  local -a requested_projects=()
  local project_id
  local saw_failure_before=0
  local saw_failure_after=0
  local global_only=0

  JIGGIT_DOCTOR_IGNORE_FAILURES=0
  JIGGIT_DOCTOR_FAIL_FAST=0

  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --global|--no-projects)
        global_only=1
        shift
        ;;
      --fail-fast)
        JIGGIT_DOCTOR_FAIL_FAST=1
        shift
        ;;
      --ignore-failures)
        JIGGIT_DOCTOR_IGNORE_FAILURES=1
        shift
        ;;
      -h|--help)
        doctor_usage
        return 0
        ;;
      *)
        requested_projects+=("${1}")
        shift
        ;;
    esac
  done

  load_project_config
  doctor_maybe_create_missing_shared_jira_config
  load_project_config
  JIGGIT_DOCTOR_SAW_FAILURE=0
  jira_check_reset_state

  print_markdown_h1 "jiggit doctor"
  printf '\n'
  render_doctor_prereqs
  render_doctor_jira_access

  if [[ "${global_only}" -eq 0 ]]; then
    while IFS= read -r project_id; do
      [[ -z "${project_id}" ]] && continue
      saw_failure_before="${JIGGIT_DOCTOR_SAW_FAILURE:-0}"
      if project_exists "${project_id}"; then
        render_doctor_project "${project_id}"
      else
        print_markdown_h2 "${project_id}" "${C_ORANGE}"
        printf '\n'
        doctor_emit_check "project config" "fail" "unknown project"
        printf '\n'
      fi
      saw_failure_after="${JIGGIT_DOCTOR_SAW_FAILURE:-0}"
      if [[ "${JIGGIT_DOCTOR_FAIL_FAST}" -eq 1 && "${saw_failure_after}" -ne "${saw_failure_before}" ]]; then
        break
      fi
    done < <(doctor_target_projects "${requested_projects[@]}")
  fi

  if [[ "${JIGGIT_DOCTOR_SAW_FAILURE:-0}" -ne 0 && "${JIGGIT_DOCTOR_IGNORE_FAILURES:-0}" -ne 1 ]]; then
    return 1
  fi
}
