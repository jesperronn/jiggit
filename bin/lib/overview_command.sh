#!/usr/bin/env bash

set -euo pipefail

: "${JIGGIT_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

if ! declare -F load_project_config >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "${JIGGIT_ROOT}/bin/lib/explore.sh"
fi

if ! declare -F print_markdown_h1 >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "${JIGGIT_ROOT}/bin/lib/common_output.sh"
fi

if ! declare -F fetch_project_environment_version >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "${JIGGIT_ROOT}/bin/lib/env_versions_command.sh"
fi

if ! declare -F fetch_jira_releases >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "${JIGGIT_ROOT}/bin/lib/releases_command.sh"
fi

if ! declare -F next_release_resolve_base >/dev/null 2>&1 || ! declare -F bump_minor_version >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "${JIGGIT_ROOT}/bin/lib/next_release_command.sh"
fi

if ! declare -F fetch_jira_issues_by_keys >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "${JIGGIT_ROOT}/bin/lib/release_notes_command.sh"
fi

if ! declare -F default_target_git_ref >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "${JIGGIT_ROOT}/bin/lib/env_diff_command.sh"
fi

if ! declare -F project_source_file >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "${JIGGIT_ROOT}/bin/lib/explore.sh"
fi

# Render help for the overview command.
overview_usage() {
  print_jiggit_usage_block <<'EOF'
Usage:
  jiggit dash [<project|path> ...]

Show a read-only dashboard for one configured project or all configured projects.
EOF
}

# Return the project ids overview should inspect.
overview_target_projects() {
  local selector=""
  local project_id=""

  if declare -F jiggit_verbose_log >/dev/null 2>&1; then
    jiggit_verbose_log "overview selectors input: ${*:-<default>}"
  fi

  while IFS= read -r selector; do
    [[ -z "${selector}" ]] && continue
    project_id="$(resolve_project_selector "${selector}" || true)"
    if [[ -n "${project_id}" ]]; then
      if declare -F jiggit_verbose_log >/dev/null 2>&1; then
        jiggit_verbose_log "overview selector ${selector} resolved to project ${project_id}"
      fi
      printf '%s\n' "${project_id}"
    else
      if declare -F jiggit_verbose_log >/dev/null 2>&1; then
        jiggit_verbose_log "overview selector ${selector} kept as-is"
      fi
      printf '%s\n' "${selector}"
    fi
  done < <(effective_multi_project_selectors "$@")
}

# Render one overview status line.
overview_emit_line() {
  local label="${1}"
  local value="${2}"
  local label_width="${3:-0}"
  : "${label_width}"

  printf -- "- %s: %s\n" "${label}" "${value}"
}

# Render one copy-paste-friendly next-step command.
overview_emit_next_step() {
  local description="${1}"
  local command_text="${2}"
  printf -- "- %s: %s\n" "${description}" "${command_text}"
}

# Render one plain dashboard bullet line.
overview_emit_plain_line() {
  local label="${1}"
  local value="${2}"
  printf -- "- %s: %s\n" "${label}" "${value}"
}

# Render one attention line with subtle color when color output is enabled.
overview_emit_attention_line() {
  local label="${1}"
  local value="${2}"
  local line="- ${label}: ${value}"

  if use_color_output; then
    printf '%b%s%b\n' "${C_BOLD}${C_SOFT_ACCENT}" "${line}" "${C_0}"
  else
    printf '%s\n' "${line}"
  fi
}

# Render one dashboard line where only the trailing suffix gets attention styling.
overview_emit_line_with_attention_suffix() {
  local label="${1}"
  local prefix="${2}"
  local suffix="${3}"

  if use_color_output; then
    printf -- '- %s: %s' "${label}" "${prefix}"
    printf '%b%s%b\n' "${C_BOLD}${C_SOFT_ACCENT}" "${suffix}" "${C_0}"
  else
    printf -- '- %s: %s%s\n' "${label}" "${prefix}" "${suffix}"
  fi
}

# Return success when dash is rendering multiple projects.
overview_is_multi_project() {
  [[ "${JIGGIT_OVERVIEW_PROJECT_COUNT:-0}" -gt 1 ]]
}

# Print a subsection heading for single-project dash output.
overview_print_subheading() {
  local text="${1}"

  if overview_is_multi_project; then
    print_markdown_h2 "${text}" "${C_CYAN}"
  else
    print_markdown_h3 "${text}" "${C_CYAN}"
  fi
}

# Print one grouped version line with optional prod-relative diagnostic suffix.
overview_emit_grouped_version_line() {
  local environment_names="${1}"
  local value="${2}"
  local prod_version="${3:-}"
  local relation=""
  local line=""

  line="- ${environment_names}: ${value}"
  if [[ -z "${prod_version}" || "${environment_names}" == *"prod"* || -z "${value}" || "${value}" == ERROR:* ]]; then
    printf '%s\n' "${line}"
    return 0
  fi

  relation="$(classify_env_version_against_prod "${prod_version}" "${value}")"
  case "${relation}" in
    same-minor-different-build)
      print_colored_line "${C_RED}" "${line}; ahead of prod within the same minor (vs ${prod_version}); new minor release needed"
      ;;
    ahead-major-minor)
      print_colored_line "${C_ORANGE}" "${line}; ahead of prod at major/minor level (vs ${prod_version}); pending deployment"
      ;;
    behind-major-minor)
      print_colored_line "${C_CYAN}" "${line}; behind prod at major/minor level (vs ${prod_version})"
      ;;
    *)
      printf '%s\n' "${line}"
      ;;
  esac
}

# Render grouped environment versions for the single-project view.
overview_render_grouped_versions() {
  local project_id="${1}"
  local environments="${2}"
  local environment_name=""
  local value=""
  local prod_version=""
  local group_value=""
  local rendered_any=0
  local saw_error=0
  local -a group_names=()

  if [[ -z "${environments}" ]]; then
    overview_emit_line "environments" "none"
    overview_emit_next_step "details" "jiggit config ${project_id}"
    return 0
  fi

  if prod_version="$(fetch_project_environment_version "${project_id}" "prod" 2>/dev/null)"; then
    if [[ "${prod_version}" == ERROR:* ]]; then
      prod_version=""
    fi
  else
    prod_version=""
  fi

  for environment_name in ${environments}; do
    if value="$(fetch_project_environment_version "${project_id}" "${environment_name}" 2>/dev/null)"; then
      :
    else
      value="$(printf '%s' "${value:-unable to resolve}" | tr '\n' ' ')"
      saw_error=1
    fi

    if [[ -z "${group_value}" ]]; then
      group_value="${value}"
      group_names=("${environment_name}")
      continue
    fi

    if [[ "${value}" == "${group_value}" ]]; then
      group_names+=("${environment_name}")
      continue
    fi

    overview_emit_grouped_version_line "$(IFS=,; printf '%s' "${group_names[*]}")" "${group_value}" "${prod_version}"
    rendered_any=1
    group_value="${value}"
    group_names=("${environment_name}")
  done

  if [[ "${rendered_any}" -eq 1 || -n "${group_value}" ]]; then
    overview_emit_grouped_version_line "$(IFS=,; printf '%s' "${group_names[*]}")" "${group_value}" "${prod_version}"
  fi

  if [[ "${saw_error}" -eq 1 ]]; then
    overview_emit_next_step "details" "jiggit env-versions ${project_id}"
  fi
  if [[ -n "${prod_version}" ]]; then
    overview_emit_next_step "changes" "jiggit changes ${project_id} --base prod"
  fi
}

# Return a compact environment-version summary for one project.
overview_versions_summary_text() {
  local project_id="${1}"
  local environments="${2}"
  local environment_name=""
  local value=""
  local group_value=""
  local rendered_any=0
  local -a group_names=()

  if [[ -z "${environments}" ]]; then
    printf 'none'
    return 0
  fi

  for environment_name in ${environments}; do
    if value="$(fetch_project_environment_version "${project_id}" "${environment_name}" 2>/dev/null)"; then
      if [[ "${value}" == ERROR:* ]]; then
        value="ERROR"
      fi
    else
      value="ERROR"
    fi

    if [[ -z "${group_value}" ]]; then
      group_value="${value}"
      group_names=("${environment_name}")
      continue
    fi

    if [[ "${value}" == "${group_value}" ]]; then
      group_names+=("${environment_name}")
      continue
    fi

    if [[ "${rendered_any}" -eq 1 ]]; then
      printf ', '
    fi
    printf '%s=%s' "$(IFS=,; printf '%s' "${group_names[*]}")" "${group_value}"
    rendered_any=1
    group_value="${value}"
    group_names=("${environment_name}")
  done

  if [[ "${rendered_any}" -eq 1 ]]; then
    printf ', '
  fi
  printf '%s=%s' "$(IFS=,; printf '%s' "${group_names[*]}")" "${group_value}"
  printf '\n'
}

# Return a compact lt-vs-prod drift summary for one project.
overview_lt_prod_drift_summary() {
  local project_id="${1}"
  local prod_version=""
  local lt_version=""
  local relation=""

  if ! prod_version="$(fetch_project_environment_version "${project_id}" "prod" 2>/dev/null)"; then
    return 0
  fi
  if ! lt_version="$(fetch_project_environment_version "${project_id}" "lt" 2>/dev/null)"; then
    return 0
  fi
  if [[ -z "${prod_version}" || -z "${lt_version}" || "${prod_version}" == ERROR:* || "${lt_version}" == ERROR:* ]]; then
    return 0
  fi

  relation="$(classify_env_version_against_prod "${prod_version}" "${lt_version}")"
  case "${relation}" in
    same-minor-different-build|ahead-major-minor)
      printf 'lt %s ahead of prod %s\n' "${lt_version}" "${prod_version}"
      ;;
    behind-major-minor)
      printf 'lt %s behind prod %s\n' "${lt_version}" "${prod_version}"
      ;;
  esac
}

# Render a short colored issue list for overview using the same fixVersion rules as next-release.
render_overview_issue_list() {
  local issues_json="${1}"
  local expected_release="${2}"
  local project_id="${3:-}"
  local jira_base_url="${4:-}"

  render_next_release_issue_lines "${issues_json}" "${expected_release}" "${project_id}" "${jira_base_url}"
}

# Render a compact unreleased-issue summary for the next-release section.
render_overview_next_release_issues() {
  local project_id="${1}"
  local repo_path="${2}"
  local base_git_ref="${3}"
  local target_ref="${4}"
  local suggested_version="${5}"
  local jira_base_url_value="${6}"
  local detail_mode="${7:-detailed}"
  local issue_keys_text=""
  local -a issue_keys=()
  local issues_json='{"issues":[]}'
  local issue_json=""
  local issue_state=""
  local total_count=0
  local missing_fix_version_count=0
  local fetch_failed=0

  if [[ -z "${suggested_version}" || -z "${jira_base_url_value}" ]]; then
    if [[ "${detail_mode}" == "detailed" ]]; then
      overview_emit_line "issues" "missing jira config"
      overview_emit_next_step "details" "jiggit config"
    else
      overview_emit_line "issues" "missing jira config"
    fi
    return 0
  fi

  issue_keys_text="$(compare_issue_keys "${repo_path}" "${base_git_ref}..${target_ref}" "${project_id}" || true)"
  if [[ -z "${issue_keys_text}" ]]; then
    if [[ "${detail_mode}" == "detailed" ]]; then
      overview_emit_line "issues" "no jira keys found in commit span"
      overview_emit_next_step "details" "jiggit changes ${project_id} --base prod"
    else
      overview_emit_line "issues" "no jira keys in commit span"
    fi
    return 0
  fi

  mapfile -t issue_keys < <(printf '%s\n' "${issue_keys_text}" | sed '/^$/d')
  if [[ ${#issue_keys[@]} -eq 0 ]]; then
    if [[ "${detail_mode}" == "detailed" ]]; then
      overview_emit_line "issues" "no jira keys found in commit span"
      overview_emit_next_step "details" "jiggit changes ${project_id} --base prod"
    else
      overview_emit_line "issues" "no jira keys in commit span"
    fi
    return 0
  fi

  if ! issues_json="$(fetch_jira_issues_by_keys "${jira_base_url_value}" "${project_id}" "${issue_keys[@]}" 2>/dev/null)"; then
    fetch_failed=1
  fi

  if [[ "${fetch_failed}" -eq 1 ]]; then
    if [[ "${detail_mode}" == "detailed" ]]; then
      overview_emit_line "issues" "unable to fetch jira issues"
      overview_emit_next_step "details" "jiggit jira-check ${project_id}"
    else
      overview_emit_line "issues" "unable to fetch jira issues"
    fi
    return 0
  fi

  while IFS= read -r issue_json; do
    [[ -z "${issue_json}" ]] && continue
    total_count=$((total_count + 1))
    issue_state="$(next_release_issue_fix_version_state "${issue_json}" "${suggested_version}" "${project_id}")"
    case "${issue_state}" in
      missing-fix-version)
        missing_fix_version_count=$((missing_fix_version_count + 1))
        ;;
    esac
  done < <(printf '%s\n' "${issues_json}" | jq -c '.issues[]?')

  if [[ "${total_count}" -eq 0 ]]; then
    if [[ "${detail_mode}" == "detailed" ]]; then
      overview_emit_line "issues" "0 unreleased issues"
    else
      overview_emit_line "issues" "0 unreleased issues"
    fi
    return 0
  fi

  if [[ "${detail_mode}" == "detailed" ]]; then
    overview_print_subheading "Unreleased Issues (${total_count})"
    printf '\n'
    render_overview_issue_list "${issues_json}" "${suggested_version}" "${project_id}" "${jira_base_url_value}"
    if [[ "${missing_fix_version_count}" -gt 0 ]]; then
      overview_emit_line "add missing fixVersion" "jiggit assign-fix-version ${project_id} --release ${suggested_version#v}"
    fi
  else
    if [[ "${missing_fix_version_count}" -gt 0 ]]; then
      overview_emit_attention_line "issues" "${total_count} unreleased, ${missing_fix_version_count} missing fixVersion"
      overview_emit_line "action" "jiggit assign-fix-version ${project_id} --release ${suggested_version#v}"
    else
      overview_emit_attention_line "issues" "${total_count} unreleased"
    fi
  fi
}

# Render the shared global config section in overview once.
render_overview_global_config_section() {
  local jira_base_url_value=""
  local jira_auth_mode_value=""

  jira_base_url_value="$(jira_base_url)"
  jira_auth_mode_value="$(jira_auth_mode)"

  print_markdown_h2 "Global Jira" "${C_CYAN}"
  printf '\n'
  if [[ -n "${jira_base_url_value}" && "${jira_auth_mode_value}" != "missing" ]]; then
    overview_emit_line "status" "configured"
    if ! overview_is_multi_project; then
      overview_emit_line "base url" "${jira_base_url_value}"
      overview_emit_line "auth mode" "${jira_auth_mode_value}"
      overview_emit_next_step "details" "jiggit config --global"
    fi
  else
    overview_emit_line "status" "missing jira config"
    overview_emit_next_step "details" "jiggit setup jira"
  fi
  printf '\n'
}

# Render the versions section in overview.
render_overview_versions() {
  local project_id="${1}"
  local environments="${2}"
  overview_render_grouped_versions "${project_id}" "${environments}"
  printf '\n'
}

# Render a compact next-release summary for one project.
render_overview_next_release() {
  local project_id="${1}"
  local repo_path="${2}"
  local environments="${3}"
  local detail_mode="${4:-detailed}"
  local base_resolved=""
  local base_label=""
  local base_git_ref=""
  local target_ref=""
  local commit_count=""
  local suggested_version=""
  local jira_base_url_value=""
  local releases_json=""
  local jira_release_summary=""
  local command_text=""
  local commit_label="commits"

  command_text="jiggit next-release ${project_id} --base prod"

  if [[ -z "${repo_path}" || ! -d "${repo_path}" ]]; then
    overview_emit_plain_line "release" "missing local repo"
    overview_emit_next_step "details" "jiggit config ${project_id}"
    printf '\n'
    return 0
  fi

  if [[ " ${environments} " != *" prod "* ]]; then
    overview_emit_plain_line "release" "missing prod base"
    overview_emit_next_step "details" "jiggit config ${project_id}"
    printf '\n'
    return 0
  fi

  if ! target_ref="$(default_target_git_ref "${repo_path}" 2>/dev/null)"; then
    overview_emit_plain_line "release" "unable to resolve target branch"
    overview_emit_next_step "details" "${command_text}"
    printf '\n'
    return 0
  fi

  if ! base_resolved="$(next_release_resolve_base "${project_id}" "${repo_path}" " ${environments} " "prod" 2>/dev/null)"; then
    overview_emit_plain_line "release" "missing prod base"
    overview_emit_next_step "details" "jiggit config ${project_id}"
    printf '\n'
    return 0
  fi

  IFS='|' read -r _ base_label _ base_git_ref <<< "${base_resolved}"
  if ! commit_count="$(git -C "${repo_path}" rev-list --count "${base_git_ref}..${target_ref}" 2>/dev/null)"; then
    overview_emit_plain_line "release" "unable to compare refs"
    overview_emit_next_step "details" "${command_text}"
    printf '\n'
    return 0
  fi
  if [[ "${commit_count}" == "1" ]]; then
    commit_label="commit"
  fi

  if [[ "${commit_count}" -gt 0 ]]; then
    suggested_version="$(bump_minor_version "${base_git_ref}" || true)"
    if [[ "${detail_mode}" == "detailed" ]]; then
      if [[ -n "${suggested_version}" ]]; then
        overview_emit_plain_line "release" "${commit_count} ${commit_label} ahead, next ${suggested_version}"
      else
        overview_emit_plain_line "release" "${commit_count} ${commit_label} ahead"
      fi
    else
      jira_base_url_value="$(jira_base_url "${project_id}")"
      if [[ -n "$(project_jira_project_key "${project_id}")" && -n "${jira_base_url_value}" && -n "${suggested_version}" ]]; then
        if releases_json="$(fetch_jira_releases "${jira_base_url_value}" "$(project_jira_project_key "${project_id}")" "${project_id}" 2>/dev/null)"; then
          if next_release_project_release_exists "${project_id}" "${suggested_version}" "${releases_json}"; then
            jira_release_summary=", Jira release created"
          else
            jira_release_summary=", Jira release missing"
          fi
        fi
      fi
      if [[ -n "${suggested_version}" ]]; then
        if [[ "${jira_release_summary}" == *"missing" ]]; then
          overview_emit_line_with_attention_suffix "release" "${commit_count} commit ahead, " "next ${suggested_version}${jira_release_summary}"
        else
          overview_emit_plain_line "release" "${commit_count} commit ahead, next ${suggested_version}${jira_release_summary}"
        fi
      else
        overview_emit_plain_line "release" "${commit_count} commit ahead"
      fi
    fi
    jira_base_url_value="$(jira_base_url "${project_id}")"
    if [[ -n "$(project_jira_project_key "${project_id}")" && -n "${jira_base_url_value}" ]]; then
      render_overview_next_release_issues "${project_id}" "${repo_path}" "${base_git_ref}" "${target_ref}" "${suggested_version}" "${jira_base_url_value}" "${detail_mode}"
    fi
    overview_emit_next_step "details" "${command_text}"
  else
    if [[ "${detail_mode}" == "detailed" ]]; then
      overview_emit_plain_line "release" "up-to-date at ${base_git_ref}"
    else
      overview_emit_plain_line "release" "up-to-date at ${base_git_ref}"
    fi
  fi
  printf '\n'
}

# Render one configured project in compact multi-project mode.
render_overview_project_multi() {
  local project_id="${1}"
  local repo_path=""
  local environments=""
  local jira_project_key=""
  local source_file=""

  repo_path="$(project_repo_path "${project_id}")"
  environments="$(project_environments "${project_id}")"
  jira_project_key="$(project_jira_project_key "${project_id}")"
  source_file="$(project_source_file "${project_id}")"

  print_markdown_h2 "${project_id}" "${C_CYAN}"
  printf '\n'
  overview_emit_line "versions" "$(overview_versions_summary_text "${project_id}" "${environments}")"
  local drift_summary=""
  drift_summary="$(overview_lt_prod_drift_summary "${project_id}")"
  if [[ -n "${drift_summary}" ]]; then
    overview_emit_attention_line "drift" "${drift_summary}"
  fi
  if [[ -z "${jira_project_key}" ]]; then
    overview_emit_line "config" "missing jira project key"
    overview_emit_line "source" "${source_file:-unknown}"
    overview_emit_next_step "details" "jiggit config ${project_id}"
    printf '\n'
    return 0
  fi
  render_overview_next_release "${project_id}" "${repo_path}" "${environments}" "compact"
}

# Render one configured project in detailed single-project mode.
render_overview_project_single() {
  local project_id="${1}"
  local repo_path=""
  local environments=""
  local jira_project_key=""
  local source_file=""

  repo_path="$(project_repo_path "${project_id}")"
  environments="$(project_environments "${project_id}")"
  jira_project_key="$(project_jira_project_key "${project_id}")"
  source_file="$(project_source_file "${project_id}")"

  print_markdown_h2 "${project_id}" "${C_CYAN}"
  printf '\n'
  if [[ -z "${jira_project_key}" ]]; then
    overview_emit_line "config" "missing jira project key"
    overview_emit_line "source" "${source_file:-unknown}"
    overview_emit_next_step "details" "jiggit config ${project_id}"
    printf '\n'
  fi
  render_overview_versions "${project_id}" "${environments}"
  render_overview_next_release "${project_id}" "${repo_path}" "${environments}" "detailed"
}

# Render one configured project's overview report.
render_overview_project() {
  local project_id="${1}"

  if overview_is_multi_project; then
    render_overview_project_multi "${project_id}"
  else
    render_overview_project_single "${project_id}"
  fi
}

# Load config, resolve overview targets, and render one dashboard section per project.
run_overview_main() {
  local -a selectors=()
  local -a project_ids=()
  local project_id=""

  while [[ $# -gt 0 ]]; do
    case "${1}" in
      -h|--help)
        overview_usage
        return 0
        ;;
      *)
        selectors+=("${1}")
        shift
        ;;
    esac
  done

  load_project_config
  mapfile -t project_ids < <(overview_target_projects "${selectors[@]}")
  JIGGIT_OVERVIEW_PROJECT_COUNT="${#project_ids[@]}"
  export JIGGIT_OVERVIEW_PROJECT_COUNT

  render_overview_global_config_section

  if declare -F jiggit_verbose_log >/dev/null 2>&1; then
    jiggit_verbose_log "overview project loop starting"
  fi

  for project_id in "${project_ids[@]}"; do
    [[ -z "${project_id}" ]] && continue
    if declare -F jiggit_verbose_log >/dev/null 2>&1; then
      jiggit_verbose_log "overview rendering project ${project_id}"
    fi
    if ! project_exists "${project_id}"; then
      if declare -F jiggit_verbose_log >/dev/null 2>&1; then
        jiggit_verbose_log "overview unknown project ${project_id}"
      fi
      print_markdown_h2 "${project_id}"
      printf '\n'
      overview_emit_line "status" "unknown project"
      printf '\n'
      continue
    fi
    render_overview_project "${project_id}"
  done
}
