#!/usr/bin/env bash

set -euo pipefail

if ! declare -F load_project_config >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/explore.sh"
fi

if ! declare -F require_program >/dev/null 2>&1 || ! declare -F jira_auth_args >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/jira_create.sh"
fi

if ! declare -F fetch_jira_releases >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/releases_command.sh"
fi

if ! declare -F print_markdown_h1 >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/common_output.sh"
fi

declare -A JIGGIT_JIRA_CHECK_ACCESS_STATE_BY_NAME=()
declare -A JIGGIT_JIRA_CHECK_ACCESS_DETAIL_BY_NAME=()

# Render help for the jira-check command.
jira_check_usage() {
  print_jiggit_usage_block <<'EOF'
Usage:
  jiggit jira-check [<project|path> ...]
  jiggit jira-check --all

Verify Jira connectivity and project access for one or more configured projects.
Defaults to all configured projects.
EOF
}

# Reset cached Jira access state before each jira-check style run.
jira_check_reset_state() {
  JIGGIT_JIRA_CHECK_ACCESS_STATE_BY_NAME=()
  JIGGIT_JIRA_CHECK_ACCESS_DETAIL_BY_NAME=()
}

# Return the Jira project metadata URL for one project key.
jira_project_metadata_url() {
  local jira_base_url="${1}"
  local jira_project_key="${2}"
  printf '%s\n' "${jira_base_url%/}/rest/api/2/project/${jira_project_key}"
}

# Return the Jira releases URL for one project key.
jira_project_releases_url() {
  local jira_base_url="${1}"
  local jira_project_key="${2}"
  printf '%s\n' "${jira_base_url%/}/rest/api/2/project/${jira_project_key}/versions"
}

# Fetch lightweight Jira metadata for a project key.
fetch_jira_project_metadata() {
  local jira_base_url="${1}"
  local jira_project_key="${2}"
  local auth_reference="${3:-}"
  local -a auth_args=()
  local metadata_url=""
  local jira_name=""
  local auth_mode_value=""
  local auth_source_value=""

  metadata_url="$(jira_project_metadata_url "${jira_base_url}" "${jira_project_key}")"
  if declare -F jiggit_verbose_log >/dev/null 2>&1; then
    jira_name="$(resolve_jira_name "${auth_reference}")"
    auth_mode_value="$(jira_auth_mode "${auth_reference}")"
    if [[ "${auth_mode_value}" == "bearer_token" ]]; then
      auth_source_value="$(jira_field_source "${auth_reference}" "bearer_token")"
    elif [[ "${auth_mode_value}" == "basic_auth" ]]; then
      auth_source_value="$(jira_field_source "${auth_reference}" "user_email"), $(jira_field_source "${auth_reference}" "api_token")"
    else
      auth_source_value="none"
    fi
    jiggit_verbose_log "jira-check metadata jira=${jira_name:-missing} auth=${auth_mode_value} auth-source=${auth_source_value} url=${metadata_url}"
  fi
  mapfile -t auth_args < <(jira_auth_args "${auth_reference}")

  curl --silent --show-error --fail \
    --connect-timeout 1 \
    --max-time 2 \
    "${auth_args[@]}" \
    -H "Accept: application/json" \
    "${metadata_url}"
}

# Fetch the current Jira user once so callers can validate auth without retrying per project.
fetch_jira_current_user() {
  local jira_base_url="${1}"
  local auth_reference="${2:-}"
  local -a auth_args=()
  local jira_name=""
  local auth_mode_value=""
  local auth_source_value=""

  if declare -F jiggit_verbose_log >/dev/null 2>&1; then
    jira_name="$(resolve_jira_name "${auth_reference}")"
    auth_mode_value="$(jira_auth_mode "${auth_reference}")"
    if [[ "${auth_mode_value}" == "bearer_token" ]]; then
      auth_source_value="$(jira_field_source "${auth_reference}" "bearer_token")"
    elif [[ "${auth_mode_value}" == "basic_auth" ]]; then
      auth_source_value="$(jira_field_source "${auth_reference}" "user_email"), $(jira_field_source "${auth_reference}" "api_token")"
    else
      auth_source_value="none"
    fi
    jiggit_verbose_log "jira-check myself jira=${jira_name:-missing} auth=${auth_mode_value} auth-source=${auth_source_value} url=${jira_base_url%/}/rest/api/2/myself"
  fi

  mapfile -t auth_args < <(jira_auth_args "${auth_reference}")

  curl --silent --show-error --fail \
    --connect-timeout 1 \
    --max-time 2 \
    "${auth_args[@]}" \
    -H "Accept: application/json" \
    "${jira_base_url%/}/rest/api/2/myself"
}

# Print the project ids attached to one Jira config name.
jira_check_projects_for_jira() {
  local jira_name="${1}"
  local project_id

  for project_id in "${JIGGIT_CONFIGURED_IDS[@]}"; do
    if [[ "$(project_jira_name "${project_id}")" == "${jira_name}" ]]; then
      printf '%s\n' "${project_id}"
    fi
  done
}

# Resolve the set of Jira names referenced by the provided projects.
jira_check_jira_names_for_projects() {
  local -a project_ids=("$@")
  local jira_name
  local project_id
  local -A seen=()

  if [[ ${#project_ids[@]} -eq 0 ]]; then
    for jira_name in "${JIGGIT_JIRA_NAMES[@]}"; do
      [[ -n "${jira_name}" && -z "${seen["${jira_name}"]+x}" ]] || continue
      seen["${jira_name}"]=1
      printf '%s\n' "${jira_name}"
    done
    return 0
  fi

  for project_id in "${project_ids[@]}"; do
    jira_name="$(project_jira_name "${project_id}")"
    [[ -n "${jira_name}" && -z "${seen["${jira_name}"]+x}" ]] || continue
    seen["${jira_name}"]=1
    printf '%s\n' "${jira_name}"
  done
}

# Probe Jira auth once per Jira config and cache the result.
jira_check_probe_access() {
  local reference="${1:-}"
  local jira_name=""
  local jira_base_url_value=""
  local jira_auth_mode_value=""

  jira_name="$(resolve_jira_name "${reference}")"
  if [[ -z "${jira_name}" ]]; then
    printf '%s|%s\n' "missing-config" "missing Jira config"
    return 0
  fi

  if [[ -n "${JIGGIT_JIRA_CHECK_ACCESS_STATE_BY_NAME["${jira_name}"]+x}" ]]; then
    printf '%s|%s\n' \
      "${JIGGIT_JIRA_CHECK_ACCESS_STATE_BY_NAME["${jira_name}"]}" \
      "${JIGGIT_JIRA_CHECK_ACCESS_DETAIL_BY_NAME["${jira_name}"]}"
    return 0
  fi

  if ! command -v curl >/dev/null 2>&1; then
    JIGGIT_JIRA_CHECK_ACCESS_STATE_BY_NAME["${jira_name}"]="missing-prereq"
    JIGGIT_JIRA_CHECK_ACCESS_DETAIL_BY_NAME["${jira_name}"]="curl missing; skipped Jira auth probe"
    printf '%s|%s\n' "missing-prereq" "${JIGGIT_JIRA_CHECK_ACCESS_DETAIL_BY_NAME["${jira_name}"]}"
    return 0
  fi

  jira_base_url_value="$(jira_base_url "${jira_name}")"
  jira_auth_mode_value="$(jira_auth_mode "${jira_name}")"

  if [[ -z "${jira_base_url_value}" || "${jira_auth_mode_value}" == "missing" ]]; then
    JIGGIT_JIRA_CHECK_ACCESS_STATE_BY_NAME["${jira_name}"]="missing-config"
    JIGGIT_JIRA_CHECK_ACCESS_DETAIL_BY_NAME["${jira_name}"]="missing Jira config"
    printf '%s|%s\n' "missing-config" "missing Jira config"
    return 0
  fi

  if fetch_jira_current_user "${jira_base_url_value}" "${jira_name}" >/dev/null 2>&1; then
    JIGGIT_JIRA_CHECK_ACCESS_STATE_BY_NAME["${jira_name}"]="ok"
    JIGGIT_JIRA_CHECK_ACCESS_DETAIL_BY_NAME["${jira_name}"]="auth probe succeeded"
    printf '%s|%s\n' "ok" "auth probe succeeded"
    return 0
  fi

  JIGGIT_JIRA_CHECK_ACCESS_STATE_BY_NAME["${jira_name}"]="failed"
  JIGGIT_JIRA_CHECK_ACCESS_DETAIL_BY_NAME["${jira_name}"]="auth probe failed; later Jira checks skipped"
  printf '%s|%s\n' "failed" "auth probe failed; later Jira checks skipped"
}

# Return success when any cached Jira access probe failed.
jira_check_any_access_failures() {
  local jira_name

  for jira_name in "${!JIGGIT_JIRA_CHECK_ACCESS_STATE_BY_NAME[@]}"; do
    case "${JIGGIT_JIRA_CHECK_ACCESS_STATE_BY_NAME["${jira_name}"]}" in
      failed|missing-prereq)
        return 0
        ;;
    esac
  done

  return 1
}

# Print the read-only config summary lines for one Jira entry.
render_jira_check_config_summary() {
  local reference="${1:-}"
  local jira_name=""
  local jira_base_url_value=""
  local jira_bearer_token_value=""
  local jira_bearer_token_source=""
  local jira_user_email_value=""
  local jira_user_email_source=""
  local jira_auth_mode_value=""
  local jira_auth_mode_source=""
  local jira_api_token_value=""
  local jira_api_token_source=""
  local jira_config_source_value=""
  local projects_text=""
  local project_id=""

  jira_name="$(resolve_jira_name "${reference}")"
  jira_base_url_value="$(jira_display_value "${jira_name}" "base_url")"
  jira_bearer_token_value="$(jira_display_value "${jira_name}" "bearer_token")"
  jira_bearer_token_source="$(jira_field_source "${jira_name}" "bearer_token")"
  jira_user_email_value="$(jira_display_value "${jira_name}" "user_email")"
  jira_user_email_source="$(jira_field_source "${jira_name}" "user_email")"
  jira_auth_mode_value="$(jira_auth_mode "${jira_name}")"
  jira_api_token_value="$(jira_display_value "${jira_name}" "api_token")"
  jira_config_source_value="$(jira_config_source "${jira_name}")"

  if [[ "${jira_auth_mode_value}" == "bearer_token" ]]; then
    jira_auth_mode_source="$(jira_field_source "${jira_name}" "bearer_token")"
  elif [[ "${jira_auth_mode_value}" == "basic_auth" ]]; then
    jira_auth_mode_source="$(jira_field_source "${jira_name}" "user_email"), $(jira_field_source "${jira_name}" "api_token")"
  else
    jira_auth_mode_source="none"
  fi
  jira_api_token_source="$(jira_field_source "${jira_name}" "api_token")"

  while IFS= read -r project_id; do
    [[ -z "${project_id}" ]] && continue
    projects_text="$(join_space "${projects_text}" "${project_id}")"
  done < <(jira_check_projects_for_jira "${jira_name}")

  printf -- "- Jira config: \`%s\`\n" "${jira_name:-missing}"
  printf -- "- Jira base URL: \`%s\` (%s)\n" "${jira_base_url_value}" "$(jira_field_source "${jira_name}" "base_url")"
  printf -- "- Jira bearer token: \`%s\` (%s)\n" "${jira_bearer_token_value}" "${jira_bearer_token_source}"
  printf -- "- Jira user email: \`%s\` (%s)\n" "${jira_user_email_value}" "${jira_user_email_source}"
  printf -- "- Jira API token: \`%s\` (%s)\n" "${jira_api_token_value}" "${jira_api_token_source}"
  printf -- "- Jira auth mode: \`%s\` (%s)\n" "${jira_auth_mode_value}" "${jira_auth_mode_source}"
  printf -- "- Jira config source: \`%s\`\n" "${jira_config_source_value}"
  printf -- "- Jira projects: \`%s\`\n" "${projects_text:-none}"
}

# Render one Jira access subsection suitable for jira-check, config, or doctor.
render_jira_check_access_body() {
  local -a project_ids=("$@")
  local jira_name=""
  local access_result=""
  local access_state=""
  local access_detail=""
  local access_status_display=""
  local rendered_access_status=""
  local warn_status=""

  if [[ ${#JIGGIT_JIRA_NAMES[@]} -eq 0 ]]; then
    render_jira_check_config_summary
    warn_status="$(render_status_label "warn")"
    printf -- "- jira access: \`%s\` (missing Jira config)\n" "${warn_status}"
    printf -- "- next step: \`jiggit setup jira\`\n"
    return 0
  fi

  while IFS= read -r jira_name; do
    [[ -z "${jira_name}" ]] && continue
    print_markdown_h2 "${jira_name}" "${C_MAGENTA}"
    printf '\n'
    render_jira_check_config_summary "${jira_name}"
    access_result="$(jira_check_probe_access "${jira_name}")"
    access_state="${access_result%%|*}"
    access_detail="${access_result#*|}"
    access_status_display="${access_state}"
    if [[ "${access_status_display}" == "failed" ]]; then
      access_status_display="fail"
    fi
    rendered_access_status="$(render_status_label "${access_status_display}")"
    printf -- "- jira access: \`%s\` (%s)\n" "${rendered_access_status}" "${access_detail}"
    case "${access_state}" in
      missing-config|failed)
        printf -- "- next step: \`jiggit setup jira\`\n"
        if [[ "${access_state}" == "failed" ]]; then
          printf -- "- verify Jira access once: \`bin/adhoc/jira_requests.sh myself\`\n"
        fi
        ;;
      missing-prereq)
        printf -- "- next step: \`bin/setup\`\n"
        ;;
    esac
    printf '\n'
  done < <(jira_check_jira_names_for_projects "${project_ids[@]}")
}

# Render a successful Jira connectivity report.
render_jira_check_summary() {
  local project_id="${1}"
  local jira_name="${2}"
  local jira_project_key="${3}"
  local metadata_json="${4}"
  local releases_json="${5}"
  local metadata_url="${6}"
  local releases_url="${7}"
  local release_summary=""
  local project_name
  local project_self
  local ok_status=""

  ok_status="$(render_status_label "ok")"

  if [[ -n "${metadata_json}" ]]; then
    project_name="$(printf '%s\n' "${metadata_json}" | jq -r '.name // "unknown"')"
    project_self="$(printf '%s\n' "${metadata_json}" | jq -r '.self // "unknown"')"
  else
    project_name="unknown"
    project_self="unknown"
  fi
  release_summary="$(project_release_inventory_summary "${project_id}" "${releases_json}")"

  print_markdown_h2 "${project_id}" "${C_GREEN}"
  printf '\n'
  printf -- "- Jira config: \`%s\`\n" "${jira_name:-missing}"
  printf -- "- Jira project key: \`%s\`\n" "${jira_project_key}"
  printf -- "- Jira project name: \`%s\`\n" "${project_name}"
  printf -- "- Jira project URL: \`%s\`\n" "${project_self}"
  printf -- "- Metadata URL: \`%s\`\n" "${metadata_url}"
  printf -- "- Releases URL: \`%s\`\n" "${releases_url}"
  printf -- "- Releases: \`%s\`\n" "${release_summary}"
  printf -- "- Auth: \`%s\`\n" "${ok_status}"
  printf -- "- Connectivity: \`%s\`\n\n" "${ok_status}"
}

# Render a failed Jira connectivity report for one project.
render_jira_check_failure() {
  local project_id="${1}"
  local jira_name="${2:-missing}"
  local jira_project_key="${3:-missing}"
  local failure_message="${4}"
  local metadata_url="${5:-unknown}"
  local releases_url="${6:-unknown}"
  local auth_status="${7:-fail}"
  local next_step_command="${8:-jiggit setup jira}"
  local rendered_auth_status=""
  local fail_status=""

  rendered_auth_status="$(render_status_label "${auth_status}")"
  fail_status="$(render_status_label "fail")"

  print_markdown_h2 "${project_id}" "${C_ORANGE}"
  printf '\n'
  printf -- "- Jira config: \`%s\`\n" "${jira_name}"
  printf -- "- Jira project key: \`%s\`\n" "${jira_project_key}"
  printf -- "- Metadata URL: \`%s\`\n" "${metadata_url}"
  printf -- "- Releases URL: \`%s\`\n" "${releases_url}"
  printf -- "- Auth: \`%s\`\n" "${rendered_auth_status}"
  printf -- "- Connectivity: \`%s\`\n" "${fail_status}"
  printf -- "- Error: \`%s\`\n" "${failure_message}"
  printf -- "- Next step: \`%s\`\n\n" "${next_step_command}"
}

# Verify Jira access for one resolved project and render either success or failure details.
run_jira_check_for_project() {
  local project_id="${1}"
  local jira_name=""
  local jira_project_key=""
  local jira_base_url_value=""
  local metadata_url=""
  local releases_url=""
  local metadata_json=""
  local releases_json=""
  local metadata_error=""
  local releases_error=""
  local metadata_error_file=""
  local releases_error_file=""
  local access_result=""
  local access_state=""
  local access_detail=""

  jira_name="$(project_jira_name "${project_id}")"
  jira_project_key="$(project_jira_project_key "${project_id}")"
  jira_base_url_value="$(jira_base_url "${project_id}")"
  access_result="$(jira_check_probe_access "${project_id}")"
  access_state="${access_result%%|*}"
  access_detail="${access_result#*|}"

  if [[ -z "${jira_project_key}" ]]; then
    render_jira_check_failure "${project_id}" "${jira_name}" "missing" "missing Jira project key in config" "unknown" "unknown" "${access_state}" "jiggit config ${project_id}"
    return 1
  fi

  if [[ -z "${jira_name}" ]]; then
    render_jira_check_failure "${project_id}" "${jira_name}" "${jira_project_key}" "missing Jira base URL" "unknown" "unknown" "${access_state}" "jiggit setup jira"
    return 1
  fi

  if [[ -z "${jira_base_url_value}" ]]; then
    render_jira_check_failure "${project_id}" "${jira_name}" "${jira_project_key}" "missing Jira base URL" "unknown" "unknown" "${access_state}" "jiggit setup jira"
    return 1
  fi

  metadata_url="$(jira_project_metadata_url "${jira_base_url_value}" "${jira_project_key}")"
  releases_url="$(jira_project_releases_url "${jira_base_url_value}" "${jira_project_key}")"
  if declare -F jiggit_verbose_log >/dev/null 2>&1; then
    jiggit_verbose_log "jira-check project=${project_id} key=${jira_project_key}"
    jiggit_verbose_log "jira-check jira=${jira_name}"
    jiggit_verbose_log "jira-check metadata ${metadata_url}"
    jiggit_verbose_log "jira-check releases ${releases_url}"
  fi

  if [[ "${access_state}" == "missing-config" ]]; then
    render_jira_check_failure "${project_id}" "${jira_name}" "${jira_project_key}" "${access_detail}" "${metadata_url}" "${releases_url}" "${access_state}" "jiggit setup jira"
    return 1
  fi

  metadata_error_file="$(mktemp "${TMPDIR:-/tmp}/jiggit-jira-check-metadata.XXXXXX")"
  if ! metadata_json="$(fetch_jira_project_metadata "${jira_base_url_value}" "${jira_project_key}" "${project_id}" 2>"${metadata_error_file}")"; then
    metadata_error="$(tr '\n' ' ' < "${metadata_error_file}")"
    metadata_json=""
  fi
  rm -f "${metadata_error_file}"

  releases_error_file="$(mktemp "${TMPDIR:-/tmp}/jiggit-jira-check-releases.XXXXXX")"
  if ! releases_json="$(fetch_jira_releases "${jira_base_url_value}" "${jira_project_key}" "${project_id}" 2>"${releases_error_file}")"; then
    releases_error="$(tr '\n' ' ' < "${releases_error_file}")"
    rm -f "${releases_error_file}"
    render_jira_check_failure "${project_id}" "${jira_name}" "${jira_project_key}" "${releases_error}" "${metadata_url}" "${releases_url}" "ok" "jiggit jira-check ${project_id}"
    return 1
  fi
  rm -f "${releases_error_file}"

  render_jira_check_summary "${project_id}" "${jira_name}" "${jira_project_key}" "${metadata_json}" "${releases_json}" "${metadata_url}" "${releases_url}"
  if [[ -n "${metadata_error}" ]]; then
    printf -- "- Metadata probe: \`%s\` (%s)\n\n" "$(render_status_label "warn")" "${metadata_error}"
  fi
}

# Print the project ids jira-check should inspect.
jira_check_target_projects() {
  local selector=""
  local project_id=""
  local saw_any=0

  if [[ "${JIGGIT_JIRA_CHECK_ALL:-0}" -eq 1 ]]; then
    printf '%s\n' "${JIGGIT_CONFIGURED_IDS[@]}"
    return 0
  fi

  while IFS= read -r selector; do
    [[ -z "${selector}" ]] && continue
    saw_any=1
    project_id="$(resolve_project_selector "${selector}" || true)"
    if [[ -n "${project_id}" ]]; then
      printf '%s\n' "${project_id}"
    else
      printf '%s\n' "${selector}"
    fi
  done < <(effective_multi_project_selectors "$@")

  if [[ "${saw_any}" -eq 0 ]]; then
    printf '%s\n' "${JIGGIT_CONFIGURED_IDS[@]}"
  fi
}

# Load config, verify Jira auth and project access, and render the result.
run_jira_check_main() {
  local -a project_selectors=()
  local check_all=0
  local project_id=""
  local saw_failure=0
  local -a project_ids=()

  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --all)
        check_all=1
        shift
        ;;
      -h|--help)
        jira_check_usage
        return 0
        ;;
      *)
        project_selectors+=("${1}")
        shift
        ;;
    esac
  done

  require_program jq
  require_program curl
  load_project_config
  jira_check_reset_state

  JIGGIT_JIRA_CHECK_ALL="${check_all}"
  mapfile -t project_ids < <(jira_check_target_projects "${project_selectors[@]}")

  print_markdown_h1 "jiggit jira-check"
  printf '\n'
  print_markdown_h2 "Jira Access" "${C_MAGENTA}"
  printf '\n'
  render_jira_check_access_body "${project_ids[@]}"

  if [[ ${#project_ids[@]} -eq 0 ]]; then
    print_markdown_h2 "Projects" "${C_BLUE}"
    printf '\n'
    printf '_No projects configured._\n'
    return 0
  fi

  while IFS= read -r project_id; do
    [[ -z "${project_id}" ]] && continue
    if ! project_exists "${project_id}"; then
      render_jira_check_failure "${project_id}" "missing" "missing" "unknown project" "unknown" "unknown" "fail" "jiggit config"
      saw_failure=1
      continue
    fi

    if ! run_jira_check_for_project "${project_id}"; then
      saw_failure=1
    fi
  done < <(printf '%s\n' "${project_ids[@]}")

  if [[ "${saw_failure}" -ne 0 ]]; then
    return 1
  fi
}
