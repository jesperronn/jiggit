#!/usr/bin/env bash

set -euo pipefail

: "${JIGGIT_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

if ! declare -F load_project_config >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "${JIGGIT_ROOT}/bin/lib/explore.sh"
fi

if ! declare -F require_program >/dev/null 2>&1 || ! declare -F jira_auth_args >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "${JIGGIT_ROOT}/bin/lib/jira_create.sh"
fi

if ! declare -F fetch_jira_releases >/dev/null 2>&1 || ! declare -F find_matching_releases >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "${JIGGIT_ROOT}/bin/lib/releases_command.sh"
fi

if ! declare -F fetch_project_environment_version >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "${JIGGIT_ROOT}/bin/lib/env_versions_command.sh"
fi

if ! declare -F default_target_git_ref >/dev/null 2>&1 || ! declare -F env_diff_resolve_operand >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "${JIGGIT_ROOT}/bin/lib/env_diff_command.sh"
fi

if ! declare -F compare_issue_keys >/dev/null 2>&1 || ! declare -F compare_normalize_version >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "${JIGGIT_ROOT}/bin/lib/compare_command.sh"
fi

if ! declare -F fetch_jira_issues_by_keys >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "${JIGGIT_ROOT}/bin/lib/release_notes_command.sh"
fi

if ! declare -F jira_issue_fix_version_display >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "${JIGGIT_ROOT}/bin/lib/jira_issues_command.sh"
fi

if ! declare -F next_release_issue_fix_version_state >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "${JIGGIT_ROOT}/bin/lib/next_release_command.sh"
fi

if ! declare -F print_markdown_h1 >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "${JIGGIT_ROOT}/bin/lib/common_output.sh"
fi

# Render help for assign-fix-version.
assign_fix_version_usage() {
  print_jiggit_usage_block <<'EOF'
Usage:
  jiggit assign-fix-version [<project|path>] --release <fixVersion> [--base <env|git-ref>] [--target <git-ref>]

Add a Jira fixVersion to issues in the base-to-target commit span when they do not already have it.
EOF
}

# Resolve the release argument to one canonical Jira release name, scoped to the current project when possible.
resolve_assign_fix_version_release() {
  local project_id="${1}"
  local jira_base_url_value="${2}"
  local jira_project_key="${3}"
  local release_query="${4}"
  local releases_json=""
  local scoped_releases_json=""
  local matching_releases=""
  local match_count="0"

  if ! releases_json="$(fetch_jira_releases "${jira_base_url_value}" "${jira_project_key}" 2>/dev/null)"; then
    printf 'error|unable to fetch Jira releases\n'
    return 0
  fi

  scoped_releases_json="$(project_scoped_releases_json "${project_id}" "${releases_json}")"
  matching_releases="$(find_matching_releases "${scoped_releases_json}" "${release_query}")"
  match_count="$(printf '%s\n' "${matching_releases}" | sed '/^$/d' | wc -l | tr -d ' ')"

  if [[ "${match_count}" -eq 1 ]]; then
    printf 'ok|%s\n' "$(printf '%s\n' "${matching_releases}" | jq -r '.name // "unknown"')"
    return 0
  fi

  if [[ "${match_count}" -gt 1 ]]; then
    printf 'ambiguous|%s\n' "$(printf '%s\n' "${matching_releases}" | jq -s -c '.')"
    return 0
  fi

  printf 'missing|%s\n' "${release_query}"
}

# Resolve a base operand into a normalized git ref.
assign_fix_version_resolve_base() {
  local project_id="${1}"
  local repo_path="${2}"
  local configured_environments="${3}"
  local base_operand="${4}"
  local resolved=""
  local base_kind=""
  local base_label=""
  local base_value=""
  local base_git_ref=""

  if ! resolved="$(env_diff_resolve_operand "${project_id}" "${repo_path}" "${configured_environments}" "${base_operand}")"; then
    printf '%s\n' "${resolved}"
    return 1
  fi

  IFS='|' read -r base_kind base_label base_value base_git_ref _ <<< "${resolved}"
  if [[ "${base_kind}" == "environment" ]]; then
    printf '%s|%s|%s|%s\n' "${base_kind}" "${base_label}" "${base_value}" "${base_git_ref}"
    return 0
  fi

  base_git_ref="$(compare_normalize_version "${repo_path}" "${base_value}" | tr -d '\n')"
  if [[ -z "${base_git_ref}" ]]; then
    printf 'Unable to normalize base ref: %s\n' "${base_value}"
    return 1
  fi

  printf '%s|%s|%s|%s\n' "${base_kind}" "${base_label}" "${base_value}" "${base_git_ref}"
}

# Update one Jira issue by adding a fixVersion name.
update_jira_issue_fix_version() {
  local jira_base_url_value="${1}"
  local issue_key="${2}"
  local release_name="${3}"
  local auth_reference="${4:-}"
  local payload=""
  local -a auth_args=()

  payload="$(jq -n --arg release_name "${release_name}" '{update:{fixVersions:[{add:{name:$release_name}}]}}')"
  mapfile -t auth_args < <(jira_auth_args "${auth_reference}")

  curl --silent --show-error --fail \
    "${auth_args[@]}" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -X PUT \
    "${jira_base_url_value%/}/rest/api/2/issue/${issue_key}" \
    --data "${payload}"
}

# Render ambiguous release candidates for assign-fix-version.
render_assign_fix_version_candidates() {
  local release_query="${1}"
  local matching_releases_json="${2}"
  local release_json

  print_markdown_h1 "jiggit assign-fix-version"
  printf '\n'
  printf 'Release "%s" matched multiple Jira releases.\n\n' "${release_query}"
  print_markdown_h2 "Matching Releases" "${C_CYAN}"
  printf '\n'
  while IFS= read -r release_json; do
    [[ -z "${release_json}" ]] && continue
    printf -- "- \`%s\`\n" "$(printf '%s\n' "${release_json}" | jq -r '.name // "unknown"')"
  done < <(printf '%s' "${matching_releases_json}" | jq -c '.[]')
}

# Render a failure report with a local next step.
render_assign_fix_version_failure() {
  local project_id="${1}"
  local repo_path="${2}"
  local status="${3}"
  local next_step_command="${4}"

  print_markdown_h1 "jiggit assign-fix-version"
  printf '\n'
  printf -- "- Project: \`%s\`\n" "${project_id}"
  printf -- "- Repo path: \`%s\`\n" "${repo_path:-missing}"
  printf -- "- Status: \`%s\`\n" "${status}"
  printf -- "- Next step: \`%s\`\n\n" "${next_step_command}"
}

# Render one issue in the assign-fix-version report.
render_assign_fix_version_issue_entry() {
  local issue_json="${1}"
  local expected_release="${2}"
  local issue_state=""
  local issue_key=""
  local title=""
  local status_name=""
  local fix_version=""
  local issue_color="${C_DIM}"

  issue_state="$(next_release_issue_fix_version_state "${issue_json}" "${expected_release}")"
  issue_key="$(printf '%s\n' "${issue_json}" | jq -r '.key // "unknown"')"
  title="$(printf '%s\n' "${issue_json}" | jq -r '.fields.summary // "unknown"')"
  status_name="$(printf '%s\n' "${issue_json}" | jq -r '.fields.status.name // "unknown"')"
  fix_version="$(jira_issue_fix_version_display "${issue_json}")"

  case "${issue_state}" in
    expected-fix-version) issue_color="${C_GREEN}" ;;
    missing-fix-version|other-fix-version) issue_color="${C_ORANGE}" ;;
  esac

  if use_color_output && [[ "${issue_color}" != "${C_DIM}" ]]; then
    print_colored_line "${issue_color}" "- \`${issue_key}\`"
  else
    printf -- "- \`%s\`\n" "${issue_key}"
  fi
  printf "  - title: \`%s\`\n" "${title}"
  printf "  - status: \`%s\`\n" "${status_name}"
  printf "  - fix_version: \`%s\`\n" "${fix_version}"
  printf "  - release_match: \`%s\`\n" "${issue_state}"
}

# Render the assign-fix-version summary and issue list.
render_assign_fix_version_summary() {
  local project_id="${1}"
  local repo_path="${2}"
  local base_label="${3}"
  local base_git_ref="${4}"
  local target_ref="${5}"
  local release_name="${6}"
  local issues_json="${7}"
  local issue_json=""
  local missing_count=0

  print_markdown_h1 "jiggit assign-fix-version"
  printf '\n'
  printf -- "- Project: \`%s\`\n" "${project_id}"
  printf -- "- Repo path: \`%s\`\n" "${repo_path}"
  printf -- "- Base: \`%s\`\n" "${base_label}"
  printf -- "- Base version: \`%s\`\n" "${base_git_ref}"
  printf -- "- Target: \`%s\`\n" "${target_ref}"
  printf -- "- Release: \`%s\`\n\n" "${release_name}"

  print_markdown_h2 "Issues" "${C_GREEN}"
  printf '\n'
  while IFS= read -r issue_json; do
    [[ -z "${issue_json}" ]] && continue
    render_assign_fix_version_issue_entry "${issue_json}" "${release_name}"
    printf '\n'
    case "$(next_release_issue_fix_version_state "${issue_json}" "${release_name}")" in
      missing-fix-version|other-fix-version)
        missing_count=$((missing_count + 1))
        ;;
    esac
  done < <(printf '%s\n' "${issues_json}" | jq -c '.issues[]?')

  if [[ "${missing_count}" -eq 0 ]]; then
    printf '_All issues already include this fixVersion._\n\n'
  else
    printf -- "- Missing selected fixVersion: \`%s\`\n\n" "${missing_count}"
  fi
}

# Add the chosen fixVersion to each issue that is missing it.
apply_assign_fix_version_updates() {
  local jira_base_url_value="${1}"
  local release_name="${2}"
  local issues_json="${3}"
  local issue_json=""
  local issue_key=""
  local applied_count=0

  while IFS= read -r issue_json; do
    [[ -z "${issue_json}" ]] && continue
    case "$(next_release_issue_fix_version_state "${issue_json}" "${release_name}")" in
      expected-fix-version)
        continue
        ;;
    esac
    issue_key="$(printf '%s\n' "${issue_json}" | jq -r '.key // empty')"
    [[ -z "${issue_key}" ]] && continue
    update_jira_issue_fix_version "${jira_base_url_value}" "${issue_key}" "${release_name}" >/dev/null
    applied_count=$((applied_count + 1))
  done < <(printf '%s\n' "${issues_json}" | jq -c '.issues[]?')

  printf '%s\n' "${applied_count}"
}

# Render local next steps for assign-fix-version.
render_assign_fix_version_next_steps() {
  local project_id="${1}"
  local release_name="${2}"

  print_markdown_h2 "Next Steps" "${C_CYAN}"
  printf '\n'
  printf -- "- review release issues: \`jiggit jira-issues %s --release %s\`\n" "${project_id}" "${release_name}"
  printf -- "- inspect the release summary: \`jiggit next-release %s\`\n" "${project_id}"
  printf -- "- review the production diff: \`jiggit env-diff %s --base prod\`\n\n" "${project_id}"
}

# Load config, resolve a Jira release, and add it to issues missing that fixVersion.
run_assign_fix_version_main() {
  local project_selector=""
  local release_query=""
  local base_operand="prod"
  local target_operand=""

  if [[ $# -gt 0 && "${1}" != -* ]]; then
    project_selector="${1}"
    shift || true
  fi

  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --release)
        release_query="${2:-}"
        shift 2
        ;;
      --base)
        base_operand="${2:-}"
        shift 2
        ;;
      --target)
        target_operand="${2:-}"
        shift 2
        ;;
      -h|--help)
        assign_fix_version_usage
        return 0
        ;;
      *)
        printf 'Unknown option: %s\n' "${1}" >&2
        assign_fix_version_usage >&2
        return 1
        ;;
    esac
  done

  require_program jq
  require_program curl
  load_project_config

  local project_id=""
  local repo_path=""
  local jira_project_key=""
  local jira_base_url_value=""
  local environments=""
  local target_ref=""
  local base_resolved=""
  local base_label=""
  local base_git_ref=""
  local release_resolution=""
  local release_resolution_state=""
  local release_resolution_detail=""
  local issue_keys_text=""
  local -a issue_keys=()
  local issues_json='{"issues":[]}'
  local missing_count=0
  local apply_choice=""
  local applied_count=0

  if [[ -z "${release_query}" ]]; then
    printf 'Missing required option: --release\n' >&2
    assign_fix_version_usage >&2
    return 1
  fi

  if ! project_selector="$(effective_single_project_selector "${project_selector}")"; then
    return 1
  fi
  project_id="$(resolve_project_selector "${project_selector}" || true)"
  if [[ -z "${project_id}" ]]; then
    printf 'Unknown project or path: %s\n' "${project_selector:-$PWD}" >&2
    return 1
  fi

  repo_path="$(project_repo_path "${project_id}")"
  jira_project_key="$(project_jira_project_key "${project_id}")"
  jira_base_url_value="$(jira_base_url "${project_id}")"
  environments=" $(project_environments "${project_id}") "

  if [[ -z "${repo_path}" || ! -d "${repo_path}" ]]; then
    render_assign_fix_version_failure "${project_id}" "${repo_path}" "missing local repo path" "jiggit config"
    return 1
  fi

  if [[ -z "${jira_project_key}" || -z "${jira_base_url_value}" ]]; then
    render_assign_fix_version_failure "${project_id}" "${repo_path}" "missing Jira config" "jiggit config"
    render_jira_config_diagnostic >&2
    return 1
  fi

  release_resolution="$(resolve_assign_fix_version_release "${project_id}" "${jira_base_url_value}" "${jira_project_key}" "${release_query}")"
  IFS='|' read -r release_resolution_state release_resolution_detail <<< "${release_resolution}"
  case "${release_resolution_state}" in
    ok) ;;
    ambiguous)
      render_assign_fix_version_candidates "${release_query}" "${release_resolution_detail}"
      return 1
      ;;
    missing)
      render_assign_fix_version_failure "${project_id}" "${repo_path}" "release not found" "jiggit releases ${project_id}"
      return 1
      ;;
    *)
      render_assign_fix_version_failure "${project_id}" "${repo_path}" "${release_resolution_detail:-unable to resolve release}" "jiggit jira-check ${project_id}"
      return 1
      ;;
  esac

  if [[ -z "${target_operand}" ]]; then
    if ! target_ref="$(default_target_git_ref "${repo_path}" 2>/dev/null)"; then
      render_assign_fix_version_failure "${project_id}" "${repo_path}" "unable to resolve target branch" "jiggit next-release ${project_id}"
      return 1
    fi
  else
    target_ref="${target_operand}"
  fi

  if ! base_resolved="$(assign_fix_version_resolve_base "${project_id}" "${repo_path}" "${environments}" "${base_operand}")"; then
    render_assign_fix_version_failure "${project_id}" "${repo_path}" "unable to resolve base" "jiggit env-versions ${project_id}"
    return 1
  fi
  IFS='|' read -r _ base_label _ base_git_ref <<< "${base_resolved}"

  issue_keys_text="$(compare_issue_keys "${repo_path}" "${base_git_ref}..${target_ref}" "${project_id}")"
  if [[ -n "${issue_keys_text}" ]]; then
    mapfile -t issue_keys < <(printf '%s\n' "${issue_keys_text}" | sed '/^$/d')
    issues_json="$(fetch_jira_issues_by_keys "${jira_base_url_value}" "" "${issue_keys[@]}")"
  fi

  render_assign_fix_version_summary "${project_id}" "${repo_path}" "${base_label}" "${base_git_ref}" "${target_ref}" "${release_resolution_detail}" "${issues_json}"

  while IFS= read -r issue_json; do
    [[ -z "${issue_json}" ]] && continue
    case "$(next_release_issue_fix_version_state "${issue_json}" "${release_resolution_detail}")" in
      missing-fix-version|other-fix-version)
        missing_count=$((missing_count + 1))
        ;;
    esac
  done < <(printf '%s\n' "${issues_json}" | jq -c '.issues[]?')

  if [[ "${missing_count}" -gt 0 ]]; then
    if can_prompt_interactively; then
      apply_choice="$(prompt_input_line "Add fixVersion ${release_resolution_detail} to ${missing_count} issue(s)? [y/N]: ")"
      case "${apply_choice}" in
        y|Y)
          applied_count="$(apply_assign_fix_version_updates "${jira_base_url_value}" "${release_resolution_detail}" "${issues_json}")"
          print_markdown_h2 "Update Result" "${C_MAGENTA}"
          printf '\n'
          printf -- "- applied: \`%s\`\n\n" "${applied_count}"
          ;;
      esac
    else
      print_markdown_h2 "Update Result" "${C_ORANGE}"
      printf '\n'
      printf -- "- status: \`interactive confirmation required\`\n\n"
    fi
  fi

  render_assign_fix_version_next_steps "${project_id}" "${release_resolution_detail}"
}
