#!/usr/bin/env bash

set -euo pipefail

if ! declare -F load_project_config >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/explore.sh"
fi

if ! declare -F fetch_project_environment_version >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "${JIGGIT_ROOT}/bin/lib/env_versions_command.sh"
fi

if ! declare -F compare_normalize_version >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "${JIGGIT_ROOT}/bin/lib/compare_command.sh"
fi

if ! declare -F default_target_git_ref >/dev/null 2>&1 || ! declare -F env_diff_compare_ref >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "${JIGGIT_ROOT}/bin/lib/env_diff_command.sh"
fi

if ! declare -F jira_issue_fix_version_display >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "${JIGGIT_ROOT}/bin/lib/jira_issues_command.sh"
fi

if ! declare -F fetch_jira_issues_by_keys >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "${JIGGIT_ROOT}/bin/lib/release_notes_command.sh"
fi

if ! declare -F fetch_jira_project_metadata >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "${JIGGIT_ROOT}/bin/lib/jira_check_command.sh"
fi

if ! declare -F fetch_jira_releases >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "${JIGGIT_ROOT}/bin/lib/releases_command.sh"
fi

if ! declare -F print_colored_line >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "${JIGGIT_ROOT}/bin/lib/common_output.sh"
fi

# Render help for the next-release subcommand.
next_release_usage() {
  cat <<'EOF'
Usage:
  jiggit next-release [<project|path>] [--base <env|git-ref>] [--target <git-ref>]

Detect whether a project needs a new release and suggest the next minor version.
EOF
}

# Suggest the next minor version while preserving the original segment count.
bump_minor_version() {
  local version_ref="${1:-}"
  local version_core="${version_ref#v}"
  local had_v_prefix=0
  local -a parts=()
  local index=0

  if [[ "${version_ref}" == v* ]]; then
    had_v_prefix=1
  fi

  IFS='.' read -r -a parts <<< "${version_core}"
  if [[ "${#parts[@]}" -eq 0 || ! "${parts[0]}" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  if [[ "${#parts[@]}" -lt 2 ]]; then
    parts+=(0)
  fi

  for index in "${!parts[@]}"; do
    if ! [[ "${parts[${index}]}" =~ ^[0-9]+$ ]]; then
      return 1
    fi
  done

  parts[1]=$((parts[1] + 1))
  for (( index=2; index<${#parts[@]}; index+=1 )); do
    parts[index]=0
  done

  if [[ "${had_v_prefix}" -eq 1 ]]; then
    printf 'v%s\n' "$(IFS=.; printf '%s' "${parts[*]}")"
  else
    printf '%s\n' "$(IFS=.; printf '%s' "${parts[*]}")"
  fi
}

# Resolve a next-release base operand into a comparable git ref and display value.
next_release_resolve_base() {
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

# Render the next-release report.
render_next_release_summary() {
  local project_id="${1}"
  local repo_path="${2}"
  local base_label="${3}"
  local target_ref="${4}"
  local base_version="${5}"
  local commit_count="${6}"
  local suggested_version="${7}"
  local compare_url="${8}"
  local status="${9}"

  print_markdown_h1 "jiggit next-release"
  printf '\n'
  printf -- "- Project: \`%s\`\n" "${project_id}"
  printf -- "- Repo path: \`%s\`\n" "${repo_path}"
  printf -- "- Base: \`%s\`\n" "${base_label}"
  printf -- "- Base version: \`%s\`\n" "${base_version}"
  printf -- "- Target: \`%s\`\n" "${target_ref}"
  printf -- "- Commit count ahead: \`%s\`\n" "${commit_count}"
  printf -- "- Status: \`%s\`\n" "${status}"
  if [[ -n "${suggested_version}" ]]; then
    printf -- "- Suggested next release: \`%s\`\n" "${suggested_version}"
  fi
  if [[ -n "${compare_url}" ]]; then
    printf -- "- Compare URL: \`%s\`\n" "${compare_url}"
  fi
  printf '\n'
}

# Render a failure report with an adjacent investigation or repair command.
render_next_release_failure() {
  local project_id="${1}"
  local repo_path="${2}"
  local status="${3}"
  local next_step_command="${4}"

  print_markdown_h1 "jiggit next-release"
  printf '\n'
  printf -- "- Project: \`%s\`\n" "${project_id}"
  printf -- "- Repo path: \`%s\`\n" "${repo_path:-missing}"
  printf -- "- Status: \`%s\`\n" "${status}"
  printf -- "- Next step: \`%s\`\n\n" "${next_step_command}"
}

# Normalize a release/fixVersion name so v-prefixed and plain versions compare equally.
normalize_fix_version_name() {
  local value="${1:-}"

  while [[ "${value}" == [vV]* ]]; do
    value="${value#?}"
  done
  printf '%s\n' "${value}"
}

# Classify one Jira issue relative to the expected next fixVersion.
next_release_issue_fix_version_state() {
  local issue_json="${1}"
  local expected_release="${2}"
  local fix_version_display=""
  local normalized_expected=""
  local normalized_actual=""

  fix_version_display="$(jira_issue_fix_version_display "${issue_json}")"
  if [[ "${fix_version_display}" == "MISSING" ]]; then
    printf '%s\n' "missing-fix-version"
    return 0
  fi

  normalized_expected="$(normalize_fix_version_name "${expected_release}")"
  while IFS= read -r normalized_actual; do
    [[ -z "${normalized_actual}" ]] && continue
    if [[ "$(normalize_fix_version_name "${normalized_actual}")" == "${normalized_expected}" ]]; then
      printf '%s\n' "expected-fix-version"
      return 0
    fi
  done < <(printf '%s\n' "${fix_version_display}" | tr ',' '\n' | sed 's/^ *//; s/ *$//')

  printf '%s\n' "other-fix-version"
}

# Render Jira issues that appear in the unreleased commit span.
render_next_release_issue_summary() {
  local issues_json="${1}"
  local expected_release="${2}"
  local issue_json=""
  local rendered_any=0
  local issue_state=""
  local issue_key=""
  local title=""
  local status_name=""
  local status_name_lower=""
  local fix_version=""
  local issue_color="${C_DIM}"

  print_markdown_h2 "Unreleased Jira Issues" "${C_GREEN}"
  printf '\n'
  while IFS= read -r issue_json; do
    [[ -z "${issue_json}" ]] && continue
    issue_state="$(next_release_issue_fix_version_state "${issue_json}" "${expected_release}")"
    issue_key="$(printf '%s\n' "${issue_json}" | jq -r '.key // "unknown"')"
    title="$(printf '%s\n' "${issue_json}" | jq -r '.fields.summary // "unknown"')"
    status_name="$(printf '%s\n' "${issue_json}" | jq -r '.fields.status.name // "unknown"')"
    status_name_lower="$(printf '%s\n' "${status_name}" | tr '[:upper:]' '[:lower:]')"
    fix_version="$(jira_issue_fix_version_display "${issue_json}")"

    case "${issue_state}" in
      expected-fix-version)
        if [[ "${status_name_lower}" == *resolved* || "${status_name_lower}" == *done* || "${status_name_lower}" == *closed* ]]; then
          issue_color="${C_GREEN}"
        else
          issue_color="${C_CYAN}"
        fi
        ;;
      missing-fix-version|other-fix-version)
        issue_color="${C_ORANGE}"
        ;;
      *)
        issue_color="${C_DIM}"
        ;;
    esac

    if use_color_output && [[ "${issue_color}" != "${C_DIM}" ]]; then
      print_colored_line "${issue_color}" "- \`${issue_key}\`"
      printf "  - title: \`%s\`\n" "${title}"
      printf "  - status: \`%s\`\n" "${status_name}"
      printf "  - fix_version: \`%s\`\n" "${fix_version}"
    else
      printf -- "- \`%s\`\n" "${issue_key}"
      printf "  - title: \`%s\`\n" "${title}"
      printf "  - status: \`%s\`\n" "${status_name}"
      printf "  - fix_version: \`%s\`\n" "${fix_version}"
    fi
    printf "  - release_match: \`%s\`\n" "${issue_state}"
    rendered_any=1
  done < <(printf '%s\n' "${issues_json}" | jq -c '.issues[]?')

  if [[ "${rendered_any}" -eq 0 ]]; then
    printf '_No Jira issues found for this unreleased span._\n'
  fi
  printf '\n'
}

# Return success when a Jira releases payload already contains the requested release name.
jira_release_exists_named() {
  local releases_json="${1}"
  local candidate_name="${2}"
  local normalized_candidate=""
  local release_name=""

  normalized_candidate="$(normalize_fix_version_name "${candidate_name}")"
  while IFS= read -r release_name; do
    [[ -z "${release_name}" ]] && continue
    if [[ "$(normalize_fix_version_name "${release_name}")" == "${normalized_candidate}" ]]; then
      return 0
    fi
  done < <(printf '%s\n' "${releases_json}" | jq -r '.[]?.name // empty')

  return 1
}

# Build the JSON payload used to create a Jira release version.
build_jira_release_payload() {
  local project_id="${1}"
  local release_name="${2}"

  jq -n \
    --arg project_id "${project_id}" \
    --arg release_name "${release_name}" \
    '{
      projectId: ($project_id | tonumber),
      name: $release_name,
      archived: false,
      released: false
    }'
}

# Submit a new Jira release version and return the API response.
create_jira_release_version() {
  local jira_base_url="${1}"
  local payload="${2}"
  local auth_reference="${3:-}"
  local -a auth_args=()

  mapfile -t auth_args < <(jira_auth_args "${auth_reference}")

  curl --silent --show-error --fail \
    "${auth_args[@]}" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -X POST \
    "${jira_base_url%/}/rest/api/2/version" \
    --data "${payload}"
}

# Interactively create the suggested Jira release when it does not already exist.
maybe_create_next_jira_release() {
  local jira_base_url_value="${1}"
  local jira_project_key="${2}"
  local suggested_version="${3}"
  local releases_json=""
  local metadata_json=""
  local project_numeric_id=""
  local release_name_default=""
  local release_name=""
  local payload=""
  local response_json=""
  local choice=""

  if [[ -z "${jira_base_url_value}" || -z "${jira_project_key}" || -z "${suggested_version}" ]]; then
    printf '%s\n' "unavailable|missing jira config"
    return 0
  fi

  if ! releases_json="$(fetch_jira_releases "${jira_base_url_value}" "${jira_project_key}" 2>/dev/null)"; then
    printf '%s\n' "warn|unable to fetch existing releases"
    return 0
  fi

  if jira_release_exists_named "${releases_json}" "${suggested_version}"; then
    printf '%s\n' "already-exists|$(normalize_fix_version_name "${suggested_version}")"
    return 0
  fi

  if ! can_prompt_interactively; then
    printf '%s\n' "missing|run interactively to create it"
    return 0
  fi

  release_name_default="$(normalize_fix_version_name "${suggested_version}")"
  choice="$(prompt_input_line "Jira release ${release_name_default} is missing. Create it now? [y/N]: ")"
  case "${choice}" in
    y|Y)
      release_name="$(prompt_input_line "Jira release name [${release_name_default}]: ")"
      release_name="${release_name:-${release_name_default}}"
      ;;
    *)
      printf '%s\n' "missing|skipped interactive creation"
      return 0
      ;;
  esac

  if ! metadata_json="$(fetch_jira_project_metadata "${jira_base_url_value}" "${jira_project_key}" 2>/dev/null)"; then
    printf '%s\n' "warn|unable to fetch Jira project metadata"
    return 0
  fi

  project_numeric_id="$(printf '%s\n' "${metadata_json}" | jq -r '.id // empty')"
  if [[ -z "${project_numeric_id}" ]]; then
    printf '%s\n' "warn|missing Jira project id in metadata"
    return 0
  fi

  payload="$(build_jira_release_payload "${project_numeric_id}" "${release_name}")"
  if ! response_json="$(create_jira_release_version "${jira_base_url_value}" "${payload}" 2>/dev/null)"; then
    printf '%s\n' "warn|failed to create Jira release"
    return 0
  fi

  release_name="$(printf '%s\n' "${response_json}" | jq -r '.name // empty')"
  printf '%s\n' "created|${release_name:-${release_name_default}}"
}

# Render the Jira release creation or existence state for the suggested next release.
render_next_release_jira_release_status() {
  local jira_release_state="${1}"
  local jira_release_detail="${2}"

  print_markdown_h2 "Jira Release" "${C_MAGENTA}"
  printf '\n'
  printf -- "- status: \`%s\`\n" "${jira_release_state}"
  if [[ -n "${jira_release_detail}" ]]; then
    printf -- "- detail: \`%s\`\n" "${jira_release_detail}"
  fi
  printf '\n'
}

# Render follow-up commands that help the user continue the release workflow.
render_next_release_next_steps() {
  local project_id="${1}"
  local suggested_version="${2}"
  local jira_project_key="${3}"
  local jira_base_url_value="${4:-}"
  local jira_release_state="${5:-}"

  print_markdown_h2 "Next Steps" "${C_CYAN}"
  printf '\n'
  printf -- "- review existing Jira releases: \`jiggit releases %s\`\n" "${project_id}"
  printf -- "- inspect the production diff: \`jiggit env-diff %s --base prod\`\n" "${project_id}"
  if [[ -z "${jira_project_key}" || -z "${jira_base_url_value}" ]]; then
    printf -- "- review effective config: \`jiggit config\`\n"
  fi
  if [[ -n "${jira_project_key}" && -n "${suggested_version}" ]]; then
    printf -- "- inspect issues for the suggested release: \`jiggit jira-issues %s --release %s\`\n" "${project_id}" "${suggested_version#v}"
    printf -- "- assign the fixVersion across commit-linked issues: \`jiggit assign-fix-version %s --release %s\`\n" "${project_id}" "${suggested_version#v}"
  fi
  if [[ "${jira_release_state}" == "missing" || "${jira_release_state}" == "warn" ]]; then
    printf -- "- rerun interactively to create the Jira release: \`jiggit next-release %s\`\n" "${project_id}"
  fi
  printf '\n'
}

# Load config, compare a deployed base to the target branch, and suggest the next release.
run_next_release_main() {
  local project_selector=""
  local base_operand="prod"
  local target_operand=""

  if [[ $# -gt 0 && "${1}" != -* ]]; then
    project_selector="${1}"
    shift || true
  fi

  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --base)
        base_operand="${2:-}"
        shift 2
        ;;
      --target)
        target_operand="${2:-}"
        shift 2
        ;;
      -h|--help)
        next_release_usage
        return 0
        ;;
      *)
        printf 'Unknown option: %s\n' "${1}" >&2
        next_release_usage >&2
        return 1
        ;;
    esac
  done

  load_project_config

  local project_id=""
  local repo_path=""
  local environments=""
  local base_resolved=""
  local base_kind=""
  local base_label=""
  local base_value=""
  local base_git_ref=""
  local target_ref=""
  local compare_url=""
  local commit_count=""
  local suggested_version=""
  local base_compare_ref=""
  local target_compare_ref=""
  local jira_project_key=""
  local jira_base_url_value=""
  local issue_keys_text=""
  local jira_release_result=""
  local jira_release_state=""
  local jira_release_detail=""
  local -a issue_keys=()
  local issues_json='{"issues":[]}'

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
    render_next_release_failure "${project_id}" "${repo_path}" "missing local repo path" "jiggit config"
    return 1
  fi

  if [[ -z "${target_operand}" ]]; then
    if ! target_ref="$(default_target_git_ref "${repo_path}" 2>/dev/null)"; then
      render_next_release_failure "${project_id}" "${repo_path}" "unable to resolve target branch" "jiggit next-release ${project_id}"
      return 1
    fi
  else
    target_ref="${target_operand}"
  fi

  if ! base_resolved="$(next_release_resolve_base "${project_id}" "${repo_path}" "${environments}" "${base_operand}")"; then
    render_next_release_failure "${project_id}" "${repo_path}" "unable to resolve base" "jiggit env-versions ${project_id}"
    return 1
  fi

  IFS='|' read -r base_kind base_label base_value base_git_ref <<< "${base_resolved}"
  if ! commit_count="$(git -C "${repo_path}" rev-list --count "${base_git_ref}..${target_ref}" 2>/dev/null)"; then
    render_next_release_failure "${project_id}" "${repo_path}" "unable to compare refs" "jiggit env-diff ${project_id} --base ${base_operand}"
    return 1
  fi

  if [[ "${commit_count}" -gt 0 ]]; then
    suggested_version="$(bump_minor_version "${base_git_ref}" || true)"
  fi

  base_compare_ref="$(env_diff_compare_ref "${repo_path}" "${base_git_ref}")"
  target_compare_ref="$(env_diff_compare_ref "${repo_path}" "${target_ref}")"
  compare_url="$(compare_url_for_project "${project_id}" "${repo_path}" "${base_compare_ref}" "${target_compare_ref}" || true)"

  if [[ "${commit_count}" -gt 0 ]]; then
    render_next_release_summary "${project_id}" "${repo_path}" "${base_label}" "${target_ref}" "${base_git_ref}" "${commit_count}" "${suggested_version}" "${compare_url}" "release-needed"
    if [[ -n "${jira_project_key}" && -n "${jira_base_url_value}" ]]; then
      jira_release_result="$(maybe_create_next_jira_release "${jira_base_url_value}" "${jira_project_key}" "${suggested_version}")"
      IFS='|' read -r jira_release_state jira_release_detail <<< "${jira_release_result}"
      render_next_release_jira_release_status "${jira_release_state}" "${jira_release_detail}"
      issue_keys_text="$(compare_issue_keys "${repo_path}" "${base_git_ref}..${target_ref}" "${project_id}")"
      if [[ -n "${issue_keys_text}" ]]; then
        mapfile -t issue_keys < <(printf '%s\n' "${issue_keys_text}" | sed '/^$/d')
        issues_json="$(fetch_jira_issues_by_keys "${jira_base_url_value}" "${issue_keys[@]}")"
      fi
      render_next_release_issue_summary "${issues_json}" "${suggested_version}"
    else
      print_markdown_h2 "Jira Status" "${C_ORANGE}"
      printf '\n'
      if [[ -z "${jira_project_key}" ]]; then
        printf -- "- status: \`missing jira project key\`\n"
      else
        printf -- "- status: \`missing jira base url\`\n"
      fi
      render_jira_config_diagnostic
      printf -- "- next step: \`jiggit config\`\n\n"
    fi
    render_next_release_next_steps "${project_id}" "${suggested_version}" "${jira_project_key}" "${jira_base_url_value}" "${jira_release_state}"
  else
    render_next_release_summary "${project_id}" "${repo_path}" "${base_label}" "${target_ref}" "${base_git_ref}" "${commit_count}" "" "${compare_url}" "up-to-date"
    render_next_release_next_steps "${project_id}" "" "${jira_project_key}" "${jira_base_url_value}" ""
  fi
}
