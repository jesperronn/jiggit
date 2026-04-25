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
  print_jiggit_usage_block <<'EOF'
Usage:
  jiggit next-release [<project|path>] [--base <env|git-ref>] [--target <git-ref>]

Detect whether a project needs a new release and suggest the next minor version.
EOF
}

# Suggest the next minor version as major.minor.0, without a build segment.
bump_minor_version() {
  local version_ref="${1:-}"
  local version_core="${version_ref#v}"
  local had_v_prefix=0
  local -a parts=()

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

  if ! [[ "${parts[0]}" =~ ^[0-9]+$ && "${parts[1]}" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  if [[ "${#parts[@]}" -ge 3 && ! "${parts[2]}" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  if [[ "${#parts[@]}" -gt 3 ]]; then
    local index=0
    for index in "${!parts[@]}"; do
      if ! [[ "${parts[${index}]}" =~ ^[0-9]+$ ]]; then
        return 1
      fi
    done
  fi

  parts[1]=$((parts[1] + 1))
  parts=("${parts[0]}" "${parts[1]}" "0")

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

# Render the release matrix for the suggested next version.
render_next_release_release_matrix() {
  local suggested_version="${1}"
  local jira_release_present="${2}"
  local git_tag_present="${3}"
  local combined_state="${4}"

  print_markdown_h2 "Release Matrix" "${C_CYAN}"
  printf '\n'
  printf -- "- suggested release: \`%s\`\n" "${suggested_version}"
  printf -- "- jira release present: \`%s\`\n" "${jira_release_present}"
  printf -- "- git tag present: \`%s\`\n" "${git_tag_present}"
  printf -- "- combined state: \`%s\`\n" "${combined_state}"
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

# Return a combined release-state label from Jira and git tag presence.
next_release_release_state() {
  local jira_release_present="${1}"
  local git_tag_present="${2}"

  if [[ "${jira_release_present}" == "yes" && "${git_tag_present}" == "yes" ]]; then
    printf '%s\n' "ready"
    return 0
  fi

  if [[ "${jira_release_present}" == "yes" ]]; then
    printf '%s\n' "git-tag-missing"
    return 0
  fi

  if [[ "${git_tag_present}" == "yes" ]]; then
    printf '%s\n' "jira-release-missing"
    return 0
  fi

  printf '%s\n' "missing-both"
}

# Normalize a release/fixVersion name so v-prefixed and plain versions compare equally.
normalize_fix_version_name() {
  local value="${1:-}"

  while [[ "${value}" == [vV]* ]]; do
    value="${value#?}"
  done
  while [[ "${value}" == *".0" ]]; do
    value="${value%".0"}"
  done
  printf '%s\n' "${value}"
}

# Return candidate version cores for one suggested release by trimming trailing .0 segments.
next_release_version_variants() {
  local value=""

  value="${1:-}"
  while [[ "${value}" == [vV]* ]]; do
    value="${value#?}"
  done
  while [[ -n "${value}" ]]; do
    printf '%s\n' "${value}"
    [[ "${value}" == *".0" ]] || break
    value="${value%".0"}"
  done
}

# Return Jira release name candidates for one project and suggested version.
next_release_project_release_name_candidates() {
  local project_id="${1}"
  local suggested_version="${2}"
  local prefixes=""
  local prefix=""
  local variant=""

  prefixes="$(project_jira_release_prefixes "${project_id}")"
  if [[ -z "${prefixes}" ]]; then
    next_release_version_variants "${suggested_version}"
    return 0
  fi

  for prefix in ${prefixes}; do
    while IFS= read -r variant; do
      [[ -z "${variant}" ]] && continue
      printf '%s%s\n' "${prefix}" "${variant}"
    done < <(next_release_version_variants "${suggested_version}")
  done
}

# Return success when one Jira release name matches a project-scoped release candidate.
next_release_name_matches_project_candidates() {
  local project_id="${1}"
  local suggested_version="${2}"
  local release_name="${3}"
  local candidate=""

  while IFS= read -r candidate; do
    [[ -z "${candidate}" ]] && continue
    if [[ "${release_name}" == "${candidate}" ]]; then
      return 0
    fi
  done < <(next_release_project_release_name_candidates "${project_id}" "${suggested_version}")

  return 1
}

# Return success when one Jira release belongs to the current project namespace.
next_release_release_belongs_to_project() {
  local project_id="${1}"
  local release_name="${2}"
  local prefixes=""
  local prefix=""

  prefixes="$(project_jira_release_prefixes "${project_id}")"
  if [[ -z "${prefixes}" ]]; then
    return 0
  fi

  for prefix in ${prefixes}; do
    if [[ "${release_name}" == "${prefix}"* ]]; then
      return 0
    fi
  done

  return 1
}

# Return only the project-relevant Jira releases.
next_release_project_releases_json() {
  local project_id="${1}"
  local releases_json="${3}"
  local release_json=""
  local release_name=""
  local filtered_json="[]"

  while IFS= read -r release_json; do
    [[ -z "${release_json}" ]] && continue
    release_name="$(printf '%s\n' "${release_json}" | jq -r '.name // empty')"
    if next_release_release_belongs_to_project "${project_id}" "${release_name}"; then
      filtered_json="$(printf '%s\n%s\n' "${filtered_json}" "${release_json}" | jq -s '.[0] + [.[1]]')"
    fi
  done < <(printf '%s\n' "${releases_json}" | jq -c '.[]?')

  printf '%s\n' "${filtered_json}"
}

# Return only active unreleased Jira releases from a versions payload.
jira_unreleased_releases_json() {
  local releases_json="${1}"

  printf '%s\n' "${releases_json}" | jq -c '
    map(select((.archived // false) != true and (.released // false) != true))
  '
}

# Return the newest active released Jira release from a versions payload.
jira_latest_released_release_json() {
  local releases_json="${1}"

  printf '%s\n' "${releases_json}" | jq -c '
    map(select((.archived // false) != true and (.released // false) == true))
    | sort_by((.releaseDate // ""), (.name // ""))
    | last // empty
  '
}

# Return one release inventory payload for next-release display.
jira_next_release_inventory_json() {
  local project_id="${1}"
  local suggested_version="${2}"
  local releases_json="${3}"
  local scoped_releases_json=""
  local unreleased_json=""
  local latest_released_json=""

  scoped_releases_json="$(next_release_project_releases_json "${project_id}" "" "${releases_json}")"
  unreleased_json="$(jira_unreleased_releases_json "${scoped_releases_json}")"
  if [[ "$(printf '%s\n' "${unreleased_json}" | jq -r 'length')" -gt 0 ]]; then
    printf '%s\n' "${unreleased_json}"
    return 0
  fi

  latest_released_json="$(jira_latest_released_release_json "${scoped_releases_json}")"
  if [[ -n "${latest_released_json}" ]]; then
    printf '[%s]\n' "${latest_released_json}"
    return 0
  fi

  printf '[]\n'
}

# Return the workflow bucket used for next-release issue grouping.
next_release_issue_status_bucket() {
  local status_name="${1:-}"
  local lowered_status=""

  lowered_status="$(printf '%s\n' "${status_name}" | tr '[:upper:]' '[:lower:]')"
  case "${lowered_status}" in
    *resolved*|*done*|*closed*)
      printf '%s\n' "resolved"
      ;;
    *business*validation*)
      printf '%s\n' "business-validation"
      ;;
    *quality*assurance*|qa)
      printf '%s\n' "quality-assurance"
      ;;
    *implement*|*in\ progress*)
      printf '%s\n' "implement"
      ;;
    *reopen*|*re-open*|*open*|*to\ do*)
      printf '%s\n' "open-reopen"
      ;;
    *)
      printf '%s\n' "open-reopen"
      ;;
  esac
}

# Return the sort rank for one next-release workflow bucket.
next_release_issue_status_rank() {
  local bucket="${1:-open-reopen}"

  case "${bucket}" in
    resolved)
      printf '%s\n' "1"
      ;;
    business-validation)
      printf '%s\n' "2"
      ;;
    quality-assurance)
      printf '%s\n' "3"
      ;;
    implement)
      printf '%s\n' "4"
      ;;
    *)
      printf '%s\n' "5"
      ;;
  esac
}

# Return the color used for one workflow bucket.
next_release_issue_status_color() {
  local bucket="${1:-open-reopen}"

  case "${bucket}" in
    resolved)
      printf '%s\n' "${C_GREEN}"
      ;;
    business-validation)
      printf '%s\n' "${C_CYAN}"
      ;;
    quality-assurance)
      printf '%s\n' "${C_BLUE}"
      ;;
    implement)
      printf '%s\n' "${C_MAGENTA}"
      ;;
    *)
      printf '%s\n' ""
      ;;
  esac
}

# Print one next-release issue line with inline segment colors.
print_next_release_issue_line() {
  local issue_key="${1}"
  local subject="${2}"
  local status_name="${3}"
  local fix_version="${4}"
  local fix_version_state="${5}"
  local status_bucket="${6}"
  local issue_url="${7:-}"
  local status_color=""
  local fix_color=""
  local fix_bold=""
  local issue_key_display="${issue_key}"

  if [[ -n "${issue_url}" ]]; then
    issue_key_display="[${issue_key}](${issue_url})"
  fi

  if ! use_color_output; then
    if [[ "${fix_version_state}" == "missing-fix-version" ]]; then
      printf '%s: status: %s, MISSING fix_version, subject: %s\n' \
        "${issue_key_display}" "${status_name}" "${subject}"
    else
      printf '%s: status: %s, fix_version: %s, subject: %s\n' \
        "${issue_key_display}" "${status_name}" "${fix_version}" "${subject}"
    fi
    return 0
  fi

  status_color="$(next_release_issue_status_color "${status_bucket}")"
  if [[ "${fix_version_state}" == "expected-fix-version" ]]; then
    fix_color="${C_DIM}"
    fix_bold=""
  else
    fix_color="${C_RED}"
    fix_bold="${C_BOLD}"
  fi

  if [[ -n "${issue_url}" ]]; then
    printf '%s: status: ' "${issue_key_display}"
  else
    printf '%b%s%b status: ' \
      "${C_BOLD}${C_CYAN}" "${issue_key_display}:" "${C_0}"
  fi
  if [[ -n "${status_color}" ]]; then
    printf '%b%s%b' "${C_BOLD}${status_color}" "${status_name}" "${C_0}"
  else
    printf '%s' "${status_name}"
  fi
  if [[ "${fix_version_state}" == "missing-fix-version" ]]; then
    printf ', %bMISSING fix_version%b, subject: %b%s%b\n' \
      "${C_BOLD}${C_RED}" "${C_0}" \
      "${C_GREEN}" "${subject}" "${C_0}"
  else
    printf ', fix_version: %b%s%b, subject: %b%s%b\n' \
      "${fix_bold}${fix_color}" "${fix_version}" "${C_0}" \
      "${C_GREEN}" "${subject}" "${C_0}"
  fi
}

# Return the Jira browse URL for one issue key.
next_release_issue_browse_url() {
  local jira_base_url="${1:-}"
  local issue_key="${2:-}"

  if [[ -z "${jira_base_url}" || -z "${issue_key}" ]]; then
    return 0
  fi

  printf '%s/browse/%s\n' "${jira_base_url%/}" "${issue_key}"
}

# Render one-line Jira issues sorted into workflow buckets.
render_next_release_issue_lines() {
  local issues_json="${1}"
  local expected_release="${2}"
  local project_id="${3:-}"
  local jira_base_url="${4:-}"
  local bucket_name=""
  local issue_json=""
  local rendered_any=0
  local issue_state=""
  local issue_key=""
  local title=""
  local status_name=""
  local status_bucket=""
  local fix_version=""
  local issue_url=""

  for bucket_name in resolved business-validation quality-assurance implement open-reopen; do
    while IFS= read -r issue_json; do
      [[ -z "${issue_json}" ]] && continue
      status_name="$(printf '%s\n' "${issue_json}" | jq -r '.fields.status.name // "unknown"')"
      status_bucket="$(next_release_issue_status_bucket "${status_name}")"
      [[ "${status_bucket}" == "${bucket_name}" ]] || continue
      issue_state="$(next_release_issue_fix_version_state "${issue_json}" "${expected_release}" "${project_id}")"
      issue_key="$(printf '%s\n' "${issue_json}" | jq -r '.key // "unknown"')"
      title="$(printf '%s\n' "${issue_json}" | jq -r '.fields.summary // "unknown"')"
      fix_version="$(jira_issue_fix_version_display "${issue_json}")"
      issue_url=""
      if [[ "${issue_state}" == "missing-fix-version" ]]; then
        issue_url="$(next_release_issue_browse_url "${jira_base_url}" "${issue_key}")"
      fi
      print_next_release_issue_line "${issue_key}" "${title}" "${status_name}" "${fix_version}" "${issue_state}" "${status_bucket}" "${issue_url}"
      rendered_any=1
    done < <(printf '%s\n' "${issues_json}" | jq -c '.issues | sort_by(.key)[]?')
  done

  if [[ "${rendered_any}" -eq 0 ]]; then
    printf '_No Jira issues found for this unreleased span._\n'
  fi
}

# Classify one Jira issue relative to the expected next fixVersion.
next_release_issue_fix_version_state() {
  local issue_json="${1}"
  local expected_release="${2}"
  local project_id="${3:-}"
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
    if [[ -n "${project_id}" ]] && next_release_name_matches_project_candidates "${project_id}" "${expected_release}" "${normalized_actual}"; then
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

  print_markdown_h2 "Unreleased Jira Issues" "${C_GREEN}"
  printf '\n'
  render_next_release_issue_lines "${issues_json}" "${expected_release}"
  printf '\n'
}

# Return success when a Jira releases payload already contains the requested release name.
next_release_project_release_exists() {
  local project_id="${1}"
  local suggested_version="${2}"
  local releases_json="${3}"
  local release_name=""

  while IFS= read -r release_name; do
    [[ -z "${release_name}" ]] && continue
    if next_release_name_matches_project_candidates "${project_id}" "${suggested_version}" "${release_name}"; then
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
    --connect-timeout 1 \
    --max-time 2 \
    "${auth_args[@]}" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -X POST \
    "${jira_base_url%/}/rest/api/2/version" \
    --data "${payload}"
}

# Interactively create the suggested Jira release when it does not already exist.
maybe_create_next_jira_release() {
  local project_id="${1}"
  local jira_base_url_value="${2}"
  local jira_project_key="${3}"
  local suggested_version="${4}"
  local auth_reference="${5:-}"
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

  if ! releases_json="$(fetch_jira_releases "${jira_base_url_value}" "${jira_project_key}" "${auth_reference}" 2>/dev/null)"; then
    printf '%s\n' "warn|unable to fetch existing releases"
    return 0
  fi

  if next_release_project_release_exists "${project_id}" "${suggested_version}" "${releases_json}"; then
    printf '%s\n' "already-exists|$(printf '%s\n' "${releases_json}" | jq -r '.[]?.name // empty' | while IFS= read -r release_name; do
      if next_release_name_matches_project_candidates "${project_id}" "${suggested_version}" "${release_name}"; then
        printf '%s\n' "${release_name}"
        break
      fi
    done)"
    return 0
  fi

  if ! can_prompt_interactively; then
    printf '%s\n' "missing|run interactively to create it"
    return 0
  fi

  release_name_default="$(next_release_project_release_name_candidates "${project_id}" "${suggested_version}" | head -n 1)"
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

  if ! metadata_json="$(fetch_jira_project_metadata "${jira_base_url_value}" "${jira_project_key}" "${auth_reference}" 2>/dev/null)"; then
    printf '%s\n' "warn|unable to fetch Jira project metadata"
    return 0
  fi

  project_numeric_id="$(printf '%s\n' "${metadata_json}" | jq -r '.id // empty')"
  if [[ -z "${project_numeric_id}" ]]; then
    printf '%s\n' "warn|missing Jira project id in metadata"
    return 0
  fi

  payload="$(build_jira_release_payload "${project_numeric_id}" "${release_name}")"
  if ! response_json="$(create_jira_release_version "${jira_base_url_value}" "${payload}" "${auth_reference}" 2>/dev/null)"; then
    printf '%s\n' "warn|failed to create Jira release"
    return 0
  fi

  release_name="$(printf '%s\n' "${response_json}" | jq -r '.name // empty')"
  printf '%s\n' "created|${release_name:-${release_name_default}}"
}

# Render the Jira release inventory and the suggested release lookup.
render_next_release_jira_release_status() {
  local project_id="${1}"
  local repo_path="${2}"
  local suggested_version="${3}"
  local jira_release_state="${4}"
  local jira_release_detail="${5}"
  local releases_json="${6}"
  local inventory_json='[]'
  local jira_release_present="no"
  local git_tag_present="no"
  local combined_state=""
  local release_json=""
  local rendered_any=0
  local unreleased_count="0"
  local latest_released_json=""
  local latest_released_name=""
  local rendered_jira_release_state=""

  rendered_jira_release_state="$(render_status_label "${jira_release_state}")"

  if [[ "${jira_release_state}" == "ok" ]]; then
    inventory_json="$(jira_next_release_inventory_json "${project_id}" "${suggested_version}" "${releases_json}")"
    unreleased_count="$(printf '%s\n' "$(next_release_project_releases_json "${project_id}" "${suggested_version}" "${releases_json}")" | jq -r '
      map(select((.archived // false) != true and (.released // false) != true)) | length
    ')"
    if next_release_project_release_exists "${project_id}" "${suggested_version}" "$(jira_unreleased_releases_json "$(next_release_project_releases_json "${project_id}" "${suggested_version}" "${releases_json}")")"; then
      jira_release_present="yes"
    fi
  else
    jira_release_present="unknown"
  fi

  if release_matches_git_tag "${repo_path}" "${suggested_version}"; then
    git_tag_present="yes"
  fi

  if [[ "${jira_release_present}" == "unknown" ]]; then
    combined_state="jira-unknown"
  else
    combined_state="$(next_release_release_state "${jira_release_present}" "${git_tag_present}")"
  fi

  print_markdown_h2 "Jira Releases" "${C_MAGENTA}"
  printf '\n'
  printf -- "- status: \`%s\`\n" "${rendered_jira_release_state}"
  if [[ -n "${jira_release_detail}" ]]; then
    printf -- "- detail: \`%s\`\n" "${jira_release_detail}"
  fi
  if [[ "${jira_release_state}" == "ok" ]]; then
    printf -- "- unreleased release count: \`%s\`\n" "${unreleased_count}"
    if [[ "${unreleased_count}" -eq 0 ]]; then
      latest_released_json="$(jira_latest_released_release_json "$(next_release_project_releases_json "${project_id}" "" "${releases_json}")")"
      latest_released_name="$(printf '%s\n' "${latest_released_json}" | jq -r '.name // empty')"
      if [[ -n "${latest_released_name}" ]]; then
        printf -- "- latest released version: \`%s\`\n" "${latest_released_name}"
        printf -- "- recommendation: \`create a new unreleased Jira release version\`\n"
      fi
    fi
  fi
  printf -- "- suggested release present: \`%s\`\n" "${jira_release_present}"
  printf -- "- git tag present: \`%s\`\n" "${git_tag_present}"
  printf -- "- combined state: \`%s\`\n\n" "${combined_state}"

  if [[ "${jira_release_state}" == "ok" ]]; then
    while IFS= read -r release_json; do
      [[ -z "${release_json}" ]] && continue
      render_release_entry "${repo_path}" "${release_json}"
      rendered_any=1
    done < <(
      printf '%s\n' "${inventory_json}" \
        | jq -c 'sort_by((.releaseDate // ""), (.name // "")) | reverse[]'
    )

    if [[ ${rendered_any} -eq 0 ]]; then
      printf '_No relevant Jira releases found._\n'
    fi
  fi

  printf '\n'
}

# Render the outcome of the interactive Jira release creation attempt.
render_next_release_jira_creation_status() {
  local jira_release_state="${1}"
  local jira_release_detail="${2}"
  local rendered_jira_release_state=""

  rendered_jira_release_state="$(render_status_label "${jira_release_state}")"

  print_markdown_h2 "Jira Release" "${C_MAGENTA}"
  printf '\n'
  printf -- "- status: \`%s\`\n" "${rendered_jira_release_state}"
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
  printf -- "- inspect the production diff: \`jiggit changes %s --base prod\`\n" "${project_id}"
  if [[ -z "${jira_project_key}" || -z "${jira_base_url_value}" ]]; then
    printf -- "- review effective config: \`jiggit config\`\n"
  fi
  if [[ -n "${jira_project_key}" && -n "${suggested_version}" ]]; then
    printf -- "- inspect issues for the suggested release: \`jiggit changes %s --from-env prod --to %s\`\n" "${project_id}" "${suggested_version#v}"
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
  local jira_release_fetch_state="warn"
  local jira_release_fetch_detail="unable to fetch existing releases"
  local jira_release_present="unknown"
  local git_tag_present="no"
  local release_matrix_state="unknown"
  local -a issue_keys=()
  local issues_json='{"issues":[]}'
  local releases_json='[]'

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
    render_next_release_failure "${project_id}" "${repo_path}" "unable to compare refs" "jiggit changes ${project_id} --base ${base_operand}"
    return 1
  fi

  if [[ "${commit_count}" -gt 0 ]]; then
    suggested_version="$(bump_minor_version "${base_git_ref}" || true)"
  fi

  if [[ -n "${jira_project_key}" && -n "${jira_base_url_value}" && -n "${suggested_version}" ]]; then
    if releases_json="$(fetch_jira_releases "${jira_base_url_value}" "${jira_project_key}" "${project_id}" 2>/dev/null)"; then
      jira_release_fetch_state="ok"
      jira_release_fetch_detail=""
    fi
  else
    jira_release_fetch_state="unavailable"
    jira_release_fetch_detail="missing jira config"
  fi

  base_compare_ref="$(env_diff_compare_ref "${repo_path}" "${base_git_ref}")"
  target_compare_ref="$(env_diff_compare_ref "${repo_path}" "${target_ref}")"
  compare_url="$(compare_url_for_project "${project_id}" "${repo_path}" "${base_compare_ref}" "${target_compare_ref}" || true)"

  if [[ "${commit_count}" -gt 0 ]]; then
    render_next_release_summary "${project_id}" "${repo_path}" "${base_label}" "${target_ref}" "${base_git_ref}" "${commit_count}" "${suggested_version}" "${compare_url}" "release-needed"
    if [[ -n "${jira_project_key}" && -n "${jira_base_url_value}" ]]; then
      if [[ "${jira_release_fetch_state}" == "ok" ]]; then
        if next_release_project_release_exists "${project_id}" "${suggested_version}" "${releases_json}"; then
          jira_release_present="yes"
        else
          jira_release_present="no"
        fi
      fi
      if release_matches_git_tag "${repo_path}" "${suggested_version}"; then
        git_tag_present="yes"
      fi
      if [[ "${jira_release_present}" == "unknown" ]]; then
        release_matrix_state="jira-unknown"
      else
        release_matrix_state="$(next_release_release_state "${jira_release_present}" "${git_tag_present}")"
      fi
      render_next_release_release_matrix "${suggested_version}" "${jira_release_present}" "${git_tag_present}" "${release_matrix_state}"
      render_next_release_jira_release_status "${project_id}" "${repo_path}" "${suggested_version}" "${jira_release_fetch_state}" "${jira_release_fetch_detail}" "${releases_json}"
      issue_keys_text="$(compare_issue_keys "${repo_path}" "${base_git_ref}..${target_ref}" "${project_id}")"
      if [[ -n "${issue_keys_text}" ]]; then
        mapfile -t issue_keys < <(printf '%s\n' "${issue_keys_text}" | sed '/^$/d')
        issues_json="$(fetch_jira_issues_by_keys "${jira_base_url_value}" "${project_id}" "${issue_keys[@]}")"
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
    render_next_release_next_steps "${project_id}" "${suggested_version}" "${jira_project_key}" "${jira_base_url_value}" ""
    jira_release_result="$(maybe_create_next_jira_release "${project_id}" "${jira_base_url_value}" "${jira_project_key}" "${suggested_version}" "${project_id}")"
    IFS='|' read -r jira_release_state jira_release_detail <<< "${jira_release_result}"
    render_next_release_jira_creation_status "${jira_release_state}" "${jira_release_detail}"
  else
    render_next_release_summary "${project_id}" "${repo_path}" "${base_label}" "${target_ref}" "${base_git_ref}" "${commit_count}" "" "${compare_url}" "up-to-date"
    render_next_release_next_steps "${project_id}" "" "${jira_project_key}" "${jira_base_url_value}" ""
  fi
}
