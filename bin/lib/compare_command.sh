#!/usr/bin/env bash

set -euo pipefail

if ! declare -F load_project_config >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/explore.sh"
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
  cat <<'EOF'
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

# Render the Markdown compare report for a project and range.
render_compare_summary() {
  local project_id="${1}"
  local repo_path="${2}"
  local from_norm="${3}"
  local to_norm="${4}"
  local commit_count="${5}"
  local compare_url="${6}"
  local issue_keys="${7}"
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
  if [[ -z "${issue_keys}" ]]; then
    printf '_No Jira keys found in commit history for this range._\n'
  else
    while IFS= read -r issue_key; do
      [[ -z "${issue_key}" ]] && continue
      printf -- "- \`%s\`\n" "${issue_key}"
    done <<< "${issue_keys}"
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
  compare_url="$(compare_url_for_project "${project_id}" "${repo_path}" "refs/tags/${from_norm}" "refs/tags/${to_norm}" || true)"

  render_compare_summary "${project_id}" "${repo_path}" "${from_norm}" "${to_norm}" "${commit_count}" "${compare_url}" "${issue_keys}"
}
