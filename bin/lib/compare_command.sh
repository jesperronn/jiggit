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

if ! declare -F jira_issue_fix_version_display >/dev/null 2>&1 || ! declare -F jira_issues_url_encode >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/jira_issues_command.sh"
fi

if ! declare -F normalize_version >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/../git_diff_expr"
fi

if ! declare -F print_markdown_h1 >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/common_output.sh"
fi

# Render help for the compare subcommand.
compare_usage() {
  print_jiggit_usage_block <<'EOF'
Usage:
  jiggit compare [<project|path>] --from <git-ref> --to <git-ref>

Show a Markdown comparison report with normalized refs, commit count, Jira keys, and compare URL.
EOF
}

# Return a remote URL for the project, preferring configured metadata before reading git.
compare_remote_url() {
  local project_id="${1}"
  local repo_path="${2}"
  local remote_url

  remote_url="$(project_remote_url "${project_id}")"
  if [[ -n "${remote_url}" ]]; then
    printf '%s\n' "${remote_url}"
    return 0
  fi

  git_origin_url "${repo_path}"
}

# Normalize a ref into the v-prefixed tag shape using the target repository's tags.
compare_normalize_version() {
  local repo_path="${1}"
  local input_ref="${2}"
  local core="${input_ref}"
  local candidate_with_v

  while [[ "${core:0:1}" == "v" || "${core:0:1}" == "V" ]]; do
    core="${core:1}"
  done

  if [[ -z "${core}" ]]; then
    return 1
  fi

  candidate_with_v="v${core}"
  if git -C "${repo_path}" rev-parse --verify --quiet "refs/tags/${input_ref}" >/dev/null 2>&1; then
    printf '%s\n' "${candidate_with_v}"
    return 0
  fi

  if git -C "${repo_path}" rev-parse --verify --quiet "refs/tags/${candidate_with_v}" >/dev/null 2>&1; then
    printf '%s\n' "${candidate_with_v}"
    return 0
  fi

  printf '%s\n' "${candidate_with_v}"
}

# Extract unique Jira-like issue keys for a git range using project-specific regexes when present.
compare_issue_keys() {
  local repo_path="${1}"
  local git_range="${2}"
  local project_id="${3}"
  local regexes
  local regex
  local combined_pattern=""
  local matches=""

  regexes="$(project_jira_regexes "${project_id}")"
  if [[ -z "${regexes}" ]]; then
    combined_pattern="${JIGGIT_FALLBACK_JIRA_REGEX}"
  else
    for regex in ${regexes}; do
      if [[ -z "${combined_pattern}" ]]; then
        combined_pattern="(${regex})"
      else
        combined_pattern="${combined_pattern}|(${regex})"
      fi
    done
  fi

  matches="$(git -C "${repo_path}" log --format='%B' "${git_range}" 2>/dev/null | grep -Eo "${combined_pattern}" | sort -u || true)"
  printf '%s\n' "${matches}"
}

# Count commits in a git range for a configured project repository.
compare_commit_count() {
  local repo_path="${1}"
  local git_range="${2}"
  git -C "${repo_path}" rev-list --count "${git_range}"
}

# Fetch Jira issue details for a list of issue keys.
fetch_jira_issues_by_keys() {
  local jira_base_url="${1}"
  shift
  local -a keys=("$@")
  local jql=""
  local joined_keys=""
  local encoded_jql=""
  local -a auth_args=()

  if [[ ${#keys[@]} -eq 0 ]]; then
    printf '{"issues":[]}\n'
    return 0
  fi

  joined_keys="$(printf '"%s",' "${keys[@]}")"
  joined_keys="${joined_keys%,}"
  jql="key in (${joined_keys}) ORDER BY key ASC"
  encoded_jql="$(jira_issues_url_encode "${jql}")"
  mapfile -t auth_args < <(jira_auth_args)

  curl --silent --show-error --fail \
    "${auth_args[@]}" \
    -H "Accept: application/json" \
    "${jira_base_url%/}/rest/api/2/search?jql=${encoded_jql}&fields=summary,status,labels,fixVersions"
}

# Fetch Jira issue details for issue keys found in the compare range.
compare_fetch_issues_json() {
  local jira_base_url_value="${1}"
  shift
  local -a issue_keys=("$@")

  if [[ -z "${jira_base_url_value}" || ${#issue_keys[@]} -eq 0 ]]; then
    printf '{"issues":[]}\n'
    return 0
  fi

  fetch_jira_issues_by_keys "${jira_base_url_value}" "${issue_keys[@]}"
}

# Build a compare URL when a supported remote URL is available.
compare_url_for_project() {
  local project_id="${1}"
  local repo_path="${2}"
  local start_ref="${3}"
  local end_ref="${4}"
  local remote_url

  remote_url="$(compare_remote_url "${project_id}" "${repo_path}")"
  if [[ -z "${remote_url}" ]]; then
    return 0
  fi

  parse_git_remote_url "${remote_url}" >/dev/null
  build_compare_url "${start_ref}" "${end_ref}"
}

# Render detailed Jira issue entries for compare.
render_compare_issue_details() {
  local issues_json="${1}"
  local issue_json
  local rendered_any=0

  while IFS= read -r issue_json; do
    [[ -z "${issue_json}" ]] && continue
    printf -- "- \`%s\`\n" "$(printf '%s\n' "${issue_json}" | jq -r '.key // "unknown"')"
    printf "  - title: \`%s\`\n" "$(printf '%s\n' "${issue_json}" | jq -r '.fields.summary // "unknown"')"
    printf "  - status: \`%s\`\n" "$(printf '%s\n' "${issue_json}" | jq -r '.fields.status.name // "unknown"')"
    printf "  - labels: \`%s\`\n" "$(printf '%s\n' "${issue_json}" | jq -r 'if (.fields.labels // []) == [] then "none" else (.fields.labels | join(", ")) end')"
    printf "  - fix_version: \`%s\`\n" "$(jira_issue_fix_version_display "${issue_json}")"
    rendered_any=1
  done < <(printf '%s\n' "${issues_json}" | jq -c '.issues[]?')

  if [[ ${rendered_any} -eq 0 ]]; then
    printf '_No Jira issue details returned for these commit keys._\n'
  fi
}

# Render the Markdown compare report for a project and range.
render_compare_summary() {
  local project_id="${1}"
  local repo_path="${2}"
  local from_norm="${3}"
  local to_norm="${4}"
  local commit_count="${5}"
  local compare_url="${6}"
  local issue_keys_text="${7}"
  local issues_json="${8}"
  local jira_fetch_status="${9}"
  local issue_key

  print_markdown_h1 "jiggit compare"
  printf '\n'
  printf -- "- Project: \`%s\`\n" "${project_id}"
  printf -- "- Repo path: \`%s\`\n" "${repo_path}"
  printf -- "- From: \`%s\`\n" "${from_norm}"
  printf -- "- To: \`%s\`\n" "${to_norm}"
  printf -- "- Range: \`%s..%s\`\n" "${from_norm}" "${to_norm}"
  printf -- '- Commit count: %s\n' "${commit_count}"
  printf -- "- Compare URL: \`%s\`\n" "${compare_url:-unavailable}"

  printf '\n'
  print_markdown_h2 "Jira Keys" "${C_CYAN}"
  printf '\n'
  if [[ -z "${issue_keys_text}" ]]; then
    printf '_No Jira keys found in commit history for this range._\n'
  else
    while IFS= read -r issue_key; do
      [[ -z "${issue_key}" ]] && continue
      printf -- "- \`%s\`\n" "${issue_key}"
    done <<< "${issue_keys_text}"
  fi

  printf '\n'
  print_markdown_h2 "Jira Issues" "${C_GREEN}"
  printf '\n'
  if [[ -z "${issue_keys_text}" ]]; then
    printf '_No Jira issues mentioned in commit history for this range._\n'
  elif [[ "${jira_fetch_status}" == "missing-config" ]]; then
    printf -- "- status: \`missing jira base url\`\n"
    printf -- "- next step: \`jiggit config\`\n"
  elif [[ "${jira_fetch_status}" == "fetch-failed" ]]; then
    printf -- "- status: \`unable to fetch jira issues\`\n"
    printf -- "- next step: \`jiggit jira-check %s\`\n" "${project_id}"
  else
    render_compare_issue_details "${issues_json}"
  fi
}

# Parse compare arguments, validate project config, and print a comparison report.
run_compare_main() {
  local project_selector=""
  if [[ $# -gt 0 && "${1}" != -* ]]; then
    project_selector="${1}"
    shift || true
  fi

  if [[ "${project_selector}" == "-h" || "${project_selector}" == "--help" ]]; then
    compare_usage
    return 0
  fi

  local from_ref=""
  local to_ref=""

  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --from)
        from_ref="${2:-}"
        shift 2
        ;;
      --to)
        to_ref="${2:-}"
        shift 2
        ;;
      -h|--help)
        compare_usage
        return 0
        ;;
      *)
        printf 'Unknown option: %s\n' "${1}" >&2
        compare_usage >&2
        return 1
        ;;
    esac
  done

  if [[ -z "${from_ref}" || -z "${to_ref}" ]]; then
    printf 'Both --from and --to are required.\n' >&2
    compare_usage >&2
    return 1
  fi

  require_program jq
  load_project_config

  local project_id
  if ! project_selector="$(effective_single_project_selector "${project_selector}")"; then
    return 1
  fi
  project_id="$(resolve_project_selector "${project_selector}" || true)"
  if [[ -z "${project_id}" ]]; then
    printf 'Unknown project or path: %s\n' "${project_selector:-$PWD}" >&2
    return 1
  fi

  local repo_path
  repo_path="$(project_repo_path "${project_id}")"
  if [[ -z "${repo_path}" ]]; then
    printf 'Project %s is missing a repo path in config.\n' "${project_id}" >&2
    return 1
  fi
  if [[ ! -d "${repo_path}" ]]; then
    printf 'Project repo path does not exist: %s\n' "${repo_path}" >&2
    return 1
  fi

  local from_norm
  local to_norm
  local git_range
  local commit_count
  local issue_keys
  local jira_base_url_value=""
  local issues_json='{"issues":[]}'
  local jira_fetch_status="ok"
  local -a issue_key_list=()
  local compare_url=""

  from_norm="$(compare_normalize_version "${repo_path}" "${from_ref}" | tr -d '\n')"
  to_norm="$(compare_normalize_version "${repo_path}" "${to_ref}" | tr -d '\n')"

  if [[ -z "${from_norm}" || -z "${to_norm}" ]]; then
    printf 'Unable to normalize refs for compare.\n' >&2
    return 1
  fi

  git_range="${from_norm}..${to_norm}"
  commit_count="$(compare_commit_count "${repo_path}" "${git_range}")"
  issue_keys="$(compare_issue_keys "${repo_path}" "${git_range}" "${project_id}")"
  jira_base_url_value="$(jira_base_url "${project_id}")"
  if [[ -n "${issue_keys}" ]]; then
    mapfile -t issue_key_list < <(printf '%s\n' "${issue_keys}" | sed '/^$/d')
    if [[ ${#issue_key_list[@]} -gt 0 ]]; then
      if [[ -z "${jira_base_url_value}" ]]; then
        jira_fetch_status="missing-config"
      elif ! issues_json="$(compare_fetch_issues_json "${jira_base_url_value}" "${issue_key_list[@]}" 2>/dev/null)"; then
        jira_fetch_status="fetch-failed"
      fi
    fi
  fi
  compare_url="$(compare_url_for_project "${project_id}" "${repo_path}" "refs/tags/${from_norm}" "refs/tags/${to_norm}" || true)"

  render_compare_summary "${project_id}" "${repo_path}" "${from_norm}" "${to_norm}" "${commit_count}" "${compare_url}" "${issue_keys}" "${issues_json}" "${jira_fetch_status}"
}
