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
  jiggit overview [<project|path> ...]

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

# Render a short colored issue list for overview using the same fixVersion rules as next-release.
render_overview_issue_list() {
  local issues_json="${1}"
  local expected_release="${2}"

  render_next_release_issue_lines "${issues_json}" "${expected_release}"
}

# Render a compact unreleased-issue summary for the next-release section.
render_overview_next_release_issues() {
  local project_id="${1}"
  local repo_path="${2}"
  local base_git_ref="${3}"
  local target_ref="${4}"
  local suggested_version="${5}"
  local jira_base_url_value="${6}"
  local issue_keys_text=""
  local -a issue_keys=()
  local issues_json='{"issues":[]}'
  local issue_json=""
  local issue_state=""
  local total_count=0
  local expected_count=0
  local missing_count=0
  local fetch_failed=0

  if [[ -z "${suggested_version}" || -z "${jira_base_url_value}" ]]; then
    print_markdown_h2 "Unreleased Issues" "${C_GREEN}"
    printf '\n'
    overview_emit_line "status" "missing jira config"
    overview_emit_next_step "next step" "jiggit config"
    return 0
  fi

  issue_keys_text="$(compare_issue_keys "${repo_path}" "${base_git_ref}..${target_ref}" "${project_id}" || true)"
  if [[ -z "${issue_keys_text}" ]]; then
    print_markdown_h2 "Unreleased Issues" "${C_GREEN}"
    printf '\n'
    overview_emit_line "status" "no jira keys found in commit span"
    overview_emit_next_step "next step" "jiggit env-diff ${project_id} --base prod"
    return 0
  fi

  mapfile -t issue_keys < <(printf '%s\n' "${issue_keys_text}" | sed '/^$/d')
  if [[ ${#issue_keys[@]} -eq 0 ]]; then
    print_markdown_h2 "Unreleased Issues" "${C_GREEN}"
    printf '\n'
    overview_emit_line "status" "no jira keys found in commit span"
    overview_emit_next_step "next step" "jiggit env-diff ${project_id} --base prod"
    return 0
  fi

  if ! issues_json="$(fetch_jira_issues_by_keys "${jira_base_url_value}" "${project_id}" "${issue_keys[@]}" 2>/dev/null)"; then
    fetch_failed=1
  fi

  if [[ "${fetch_failed}" -eq 1 ]]; then
    print_markdown_h2 "Unreleased Issues" "${C_GREEN}"
    printf '\n'
    overview_emit_line "status" "unable to fetch jira issues"
    overview_emit_next_step "next step" "jiggit jira-check ${project_id}"
    return 0
  fi

  while IFS= read -r issue_json; do
    [[ -z "${issue_json}" ]] && continue
    total_count=$((total_count + 1))
    issue_state="$(next_release_issue_fix_version_state "${issue_json}" "${suggested_version}" "${project_id}")"
    case "${issue_state}" in
      expected-fix-version)
        expected_count=$((expected_count + 1))
        ;;
      missing-fix-version|other-fix-version)
        missing_count=$((missing_count + 1))
        ;;
    esac
  done < <(printf '%s\n' "${issues_json}" | jq -c '.issues[]?')

  if [[ "${total_count}" -eq 0 ]]; then
    print_markdown_h2 "Unreleased Issues (0)" "${C_GREEN}"
    printf '\n'
    overview_emit_line "status" "no jira issues returned for commit span"
    return 0
  fi

  print_markdown_h2 "Unreleased Issues (${total_count})" "${C_GREEN}"
  printf '\n'
  overview_emit_line "issue count" "${total_count}"
  overview_emit_line "issues with expected fixVersion" "${expected_count}"
  overview_emit_line "issues missing expected fixVersion" "${missing_count}"
  render_overview_issue_list "${issues_json}" "${suggested_version}" "${project_id}"
}

# Render the config section in overview.
render_overview_config_section() {
  local project_id="${1}"
  local section_command="jiggit config"
  local repo_path=""
  local jira_project_key=""
  local environments=""
  local source_file=""

  repo_path="$(project_repo_path "${project_id}")"
  jira_project_key="$(project_jira_project_key "${project_id}")"
  environments="$(project_environments "${project_id}")"
  source_file="$(project_source_file "${project_id}")"

  print_markdown_h2 "${project_id} \`${section_command}\`" "${C_GREEN}"
  printf '\n'
  overview_emit_line "repo path" "${repo_path:-missing}"
  overview_emit_line "jira project key" "${jira_project_key:-missing}"
  overview_emit_line "environments" "${environments:-none}"
  render_jira_config_diagnostic
  if [[ -z "${jira_project_key}" ]]; then
    overview_emit_line "source" "${source_file:-unknown}"
    overview_emit_next_step "next step" "${section_command}"
  fi
  printf '\n'
}

# Render the versions section in overview.
render_overview_versions() {
  local project_id="${1}"
  local environments="${2}"
  local environment_name=""
  local value=""
  local prod_version=""
  local relation=""
  local saw_error=0
  local label_width=0

  for environment_name in ${environments}; do
    if [[ ${#environment_name} -gt ${label_width} ]]; then
      label_width=${#environment_name}
    fi
  done

  print_markdown_h2 "Versions \`jiggit env-versions ${project_id}\`" "${C_CYAN}"
  printf '\n'

  if [[ -z "${environments}" ]]; then
    overview_emit_line "environments" "none"
    overview_emit_next_step "next step" "jiggit config"
    printf '\n'
    return 0
  fi

  for environment_name in ${environments}; do
    if value="$(fetch_project_environment_version "${project_id}" "${environment_name}" 2>/dev/null)"; then
      overview_emit_line "${environment_name}" "${value}" "${label_width}"
      if [[ "${environment_name}" == "prod" ]]; then
        prod_version="${value}"
      fi
    else
      value="$(printf '%s' "${value:-unable to resolve}" | tr '\n' ' ')"
      overview_emit_line "${environment_name}" "${value:-unable to resolve}" "${label_width}"
      saw_error=1
    fi
  done

  if [[ "${saw_error}" -eq 1 ]]; then
    overview_emit_next_step "next step" "jiggit env-versions ${project_id}"
  fi

  if [[ -n "${prod_version}" ]]; then
    printf '\n'
    print_markdown_h2 "Version Diagnostics" "${C_MAGENTA}"
    printf '\n'
    for environment_name in ${environments}; do
      [[ "${environment_name}" == "prod" ]] && continue
      value="$(fetch_project_environment_version "${project_id}" "${environment_name}" 2>/dev/null || true)"
      [[ -z "${value}" || "${value}" == ERROR:* ]] && continue
      relation="$(classify_env_version_against_prod "${prod_version}" "${value}")"
      case "${relation}" in
        same-minor-different-build)
          print_colored_line "${C_RED}" "- ${environment_name}: ahead of prod within the same minor (${value} vs ${prod_version}); new minor release needed"
          ;;
        ahead-major-minor)
          print_colored_line "${C_ORANGE}" "- ${environment_name}: ahead of prod at major/minor level (${value} vs ${prod_version}); pending deployment"
          ;;
        behind-major-minor)
          print_colored_line "${C_CYAN}" "- ${environment_name}: behind prod at major/minor level (${value} vs ${prod_version})"
          ;;
      esac
    done
    overview_emit_next_step "next step" "jiggit env-diff ${project_id} --base prod"
  fi
  printf '\n'
}

# Render a compact next-release summary for one project.
render_overview_next_release() {
  local project_id="${1}"
  local repo_path="${2}"
  local environments="${3}"
  local base_resolved=""
  local base_label=""
  local base_git_ref=""
  local target_ref=""
  local commit_count=""
  local suggested_version=""
  local jira_base_url_value=""
  local command_text=""

  command_text="jiggit next-release ${project_id} --base prod"
  print_markdown_h2 "Next Release \`${command_text}\`" "${C_MAGENTA}"
  printf '\n'

  if [[ -z "${repo_path}" || ! -d "${repo_path}" ]]; then
    overview_emit_plain_line "status" "missing local repo"
    printf '\nNext steps:\n'
    printf -- "- jiggit config\n"
    printf '\n'
    return 0
  fi

  if [[ " ${environments} " != *" prod "* ]]; then
    overview_emit_plain_line "status" "missing prod base"
    printf '\nNext steps:\n'
    printf -- "- jiggit config\n"
    printf '\n'
    return 0
  fi

  if ! target_ref="$(default_target_git_ref "${repo_path}" 2>/dev/null)"; then
    overview_emit_plain_line "status" "unable to resolve target branch"
    printf '\nNext steps:\n'
    printf -- "- %s\n" "${command_text}"
    printf '\n'
    return 0
  fi

  if ! base_resolved="$(next_release_resolve_base "${project_id}" "${repo_path}" " ${environments} " "prod" 2>/dev/null)"; then
    overview_emit_plain_line "status" "missing prod base"
    printf '\nNext steps:\n'
    printf -- "- jiggit config\n"
    printf '\n'
    return 0
  fi

  IFS='|' read -r _ base_label _ base_git_ref <<< "${base_resolved}"
  if ! commit_count="$(git -C "${repo_path}" rev-list --count "${base_git_ref}..${target_ref}" 2>/dev/null)"; then
    overview_emit_plain_line "status" "unable to compare refs"
    printf '\nNext steps:\n'
    printf -- "- %s\n" "${command_text}"
    printf '\n'
    return 0
  fi

  if [[ "${commit_count}" -gt 0 ]]; then
    suggested_version="$(bump_minor_version "${base_git_ref}" || true)"
    overview_emit_plain_line "base version (${base_label})" "${base_git_ref}"
    overview_emit_plain_line "commit count ahead" "${commit_count}"
    if [[ -n "${suggested_version}" ]]; then
      printf -- "- **suggested next release: %s**\n" "${suggested_version}"
    fi
    jira_base_url_value="$(jira_base_url "${project_id}")"
    if [[ -n "$(project_jira_project_key "${project_id}")" && -n "${jira_base_url_value}" ]]; then
      render_overview_next_release_issues "${project_id}" "${repo_path}" "${base_git_ref}" "${target_ref}" "${suggested_version}" "${jira_base_url_value}"
    fi
    printf '\nNext steps:\n'
    printf -- "- jiggit env-diff %s --base prod\n" "${project_id}"
    printf -- "- %s\n" "${command_text}"
  else
    overview_emit_plain_line "base version (${base_label})" "${base_git_ref}"
    overview_emit_plain_line "commit count ahead" "${commit_count}"
    overview_emit_plain_line "status" "up-to-date"
  fi
  printf '\n'
}

# Render one configured project's overview report.
render_overview_project() {
  local project_id="${1}"
  local repo_path=""
  local environments=""

  repo_path="$(project_repo_path "${project_id}")"
  environments="$(project_environments "${project_id}")"

  render_overview_config_section "${project_id}"
  render_overview_versions "${project_id}" "${environments}"
  render_overview_next_release "${project_id}" "${repo_path}" "${environments}"
}

# Load config, resolve overview targets, and render one dashboard section per project.
run_overview_main() {
  local -a selectors=()
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
  print_markdown_h1 "jiggit overview"
  printf '\n'

  if declare -F jiggit_verbose_log >/dev/null 2>&1; then
    jiggit_verbose_log "overview project loop starting"
  fi

  while IFS= read -r project_id; do
    [[ -z "${project_id}" ]] && continue
    if declare -F jiggit_verbose_log >/dev/null 2>&1; then
      jiggit_verbose_log "overview rendering project ${project_id}"
    fi
    if ! project_exists "${project_id}"; then
      if declare -F jiggit_verbose_log >/dev/null 2>&1; then
        jiggit_verbose_log "overview unknown project ${project_id}"
      fi
      print_markdown_h2 "${project_id}" "${C_ORANGE}"
      printf '\n'
      overview_emit_line "status" "unknown project"
      printf '\n'
      continue
    fi
    render_overview_project "${project_id}"
  done < <(overview_target_projects "${selectors[@]}")
}
