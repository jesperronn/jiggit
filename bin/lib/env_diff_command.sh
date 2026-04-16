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

if ! declare -F changelog_commit_lines >/dev/null 2>&1 || ! declare -F render_changelog_section >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "${JIGGIT_ROOT}/bin/lib/changelog_command.sh"
fi

if ! declare -F print_markdown_h1 >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "${JIGGIT_ROOT}/bin/lib/common_output.sh"
fi

JIGGIT_ENV_DIFF_VERBOSE=0

# Print verbose env-diff logs when requested.
env_diff_debug() {
  if [[ "${JIGGIT_ENV_DIFF_VERBOSE:-0}" -eq 1 ]]; then
    printf '[env-diff] %s\n' "$*" >&2
  fi
}

# Render help for the env-diff subcommand.
env_diff_usage() {
  print_jiggit_usage_block <<'EOF'
Usage:
  jiggit env-diff [<project|path>] --base <env|git-ref> [--target <env|git-ref>] [--verbose]

Show the code difference between a base environment and a target environment or latest git ref.
EOF
}

# Return the best available git ref for the latest target branch.
default_target_git_ref() {
  local repo_path="${1}"
  local remote_head_ref=""
  local current_branch=""

  remote_head_ref="$(git -C "${repo_path}" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [[ -n "${remote_head_ref}" ]]; then
    printf '%s\n' "${remote_head_ref}"
    return 0
  fi

  if git -C "${repo_path}" show-ref --verify --quiet refs/remotes/origin/main; then
    printf 'refs/remotes/origin/main\n'
    return 0
  fi

  if git -C "${repo_path}" show-ref --verify --quiet refs/remotes/origin/master; then
    printf 'refs/remotes/origin/master\n'
    return 0
  fi

  current_branch="$(git -C "${repo_path}" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [[ -n "${current_branch}" ]]; then
    printf '%s\n' "${current_branch}"
    return 0
  fi

  printf 'HEAD\n'
}

# Convert a local git ref into a hosting-friendly compare ref when possible.
compare_ref_for_git_ref() {
  local git_ref="${1:-}"

  if [[ "${git_ref}" == refs/remotes/origin/* ]]; then
    printf 'refs/heads/%s\n' "${git_ref#refs/remotes/origin/}"
    return 0
  fi

  if [[ "${git_ref}" == refs/heads/* || "${git_ref}" == refs/tags/* ]]; then
    printf '%s\n' "${git_ref}"
    return 0
  fi

  if [[ "${git_ref}" == origin/* ]]; then
    printf 'refs/heads/%s\n' "${git_ref#origin/}"
    return 0
  fi

  printf '%s\n' "${git_ref}"
}

# Return a hosting-friendly compare ref using repo metadata to distinguish tags and branches.
env_diff_compare_ref() {
  local repo_path="${1}"
  local git_ref="${2}"

  if [[ "${git_ref}" == refs/* || "${git_ref}" == origin/* ]]; then
    compare_ref_for_git_ref "${git_ref}"
    return 0
  fi

  if git -C "${repo_path}" rev-parse --verify --quiet "refs/tags/${git_ref}" >/dev/null 2>&1; then
    printf 'refs/tags/%s\n' "${git_ref}"
    return 0
  fi

  if git -C "${repo_path}" show-ref --verify --quiet "refs/heads/${git_ref}"; then
    printf 'refs/heads/%s\n' "${git_ref}"
    return 0
  fi

  if git -C "${repo_path}" show-ref --verify --quiet "refs/remotes/origin/${git_ref}"; then
    printf 'refs/heads/%s\n' "${git_ref}"
    return 0
  fi

  compare_ref_for_git_ref "${git_ref}"
}

# Resolve an env-diff operand as either a configured environment or a git ref.
env_diff_resolve_operand() {
  local project_id="${1}"
  local repo_path="${2}"
  local configured_environments="${3}"
  local operand="${4}"
  local operand_kind="git-ref"
  local resolved_value="${operand}"
  local normalized_ref="${operand}"
  local compare_ref=""

  if [[ "${configured_environments}" == *" ${operand} "* ]]; then
    operand_kind="environment"
    env_diff_debug "Resolving ${operand} version for ${project_id}"
    if ! resolved_value="$(fetch_project_environment_version "${project_id}" "${operand}")"; then
      printf 'ERROR|Unable to resolve version for %s/%s: %s\n' "${project_id}" "${operand}" "${resolved_value}"
      return 1
    fi

    normalized_ref="$(compare_normalize_version "${repo_path}" "${resolved_value}" | tr -d '\n')"
    if [[ -z "${normalized_ref}" ]]; then
      printf 'ERROR|Unable to normalize environment version for %s/%s: %s\n' "${project_id}" "${operand}" "${resolved_value}"
      return 1
    fi

    compare_ref="refs/tags/${normalized_ref}"
  else
    compare_ref="$(env_diff_compare_ref "${repo_path}" "${operand}")"
  fi

  printf '%s|%s|%s|%s|%s\n' "${operand_kind}" "${operand}" "${resolved_value}" "${normalized_ref}" "${compare_ref}"
}

# Build grouped changelog buckets from a git range.
env_diff_grouped_commit_items() {
  local repo_path="${1}"
  local git_range="${2}"
  local line
  local commit_hash
  local subject_line
  local commit_type
  local entry

  JIGGIT_ENV_DIFF_FEAT_ITEMS=""
  JIGGIT_ENV_DIFF_FIX_ITEMS=""
  JIGGIT_ENV_DIFF_DOCS_ITEMS=""
  JIGGIT_ENV_DIFF_REFACTOR_ITEMS=""
  JIGGIT_ENV_DIFF_TEST_ITEMS=""
  JIGGIT_ENV_DIFF_CHORE_ITEMS=""
  JIGGIT_ENV_DIFF_OTHER_ITEMS=""

  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    commit_hash="${line%%$'\x1f'*}"
    subject_line="${line#*$'\x1f'}"
    commit_type="$(conventional_commit_type "${subject_line}")"
    entry="\`${commit_hash}\` ${subject_line}"

    case "${commit_type}" in
      feat)
        JIGGIT_ENV_DIFF_FEAT_ITEMS="${JIGGIT_ENV_DIFF_FEAT_ITEMS}${entry}"$'\n'
        ;;
      fix)
        JIGGIT_ENV_DIFF_FIX_ITEMS="${JIGGIT_ENV_DIFF_FIX_ITEMS}${entry}"$'\n'
        ;;
      docs)
        JIGGIT_ENV_DIFF_DOCS_ITEMS="${JIGGIT_ENV_DIFF_DOCS_ITEMS}${entry}"$'\n'
        ;;
      refactor)
        JIGGIT_ENV_DIFF_REFACTOR_ITEMS="${JIGGIT_ENV_DIFF_REFACTOR_ITEMS}${entry}"$'\n'
        ;;
      test)
        JIGGIT_ENV_DIFF_TEST_ITEMS="${JIGGIT_ENV_DIFF_TEST_ITEMS}${entry}"$'\n'
        ;;
      chore)
        JIGGIT_ENV_DIFF_CHORE_ITEMS="${JIGGIT_ENV_DIFF_CHORE_ITEMS}${entry}"$'\n'
        ;;
      *)
        JIGGIT_ENV_DIFF_OTHER_ITEMS="${JIGGIT_ENV_DIFF_OTHER_ITEMS}${entry}"$'\n'
        ;;
    esac
  done < <(changelog_commit_lines "${repo_path}" "${git_range}")
}

# Render a Markdown list of Jira keys or an explicit empty state.
render_env_diff_issue_keys() {
  local issue_keys="${1}"
  local issue_key

  print_markdown_h2 "Jira Keys" "${C_CYAN}"
  printf '\n'
  if [[ -z "${issue_keys}" ]]; then
    printf '_No Jira keys found in commit history for this range._\n\n'
    return 0
  fi

  while IFS= read -r issue_key; do
    [[ -z "${issue_key}" ]] && continue
    printf -- "- \`%s\`\n" "${issue_key}"
  done <<< "${issue_keys}"
  printf '\n'
}

# Render grouped commit sections for env-diff.
render_env_diff_commit_groups() {
  print_markdown_h2 "Commits By Type" "${C_MAGENTA}"
  printf '\n'
  render_changelog_section "feat" "${JIGGIT_ENV_DIFF_FEAT_ITEMS}"
  render_changelog_section "fix" "${JIGGIT_ENV_DIFF_FIX_ITEMS}"
  render_changelog_section "docs" "${JIGGIT_ENV_DIFF_DOCS_ITEMS}"
  render_changelog_section "refactor" "${JIGGIT_ENV_DIFF_REFACTOR_ITEMS}"
  render_changelog_section "test" "${JIGGIT_ENV_DIFF_TEST_ITEMS}"
  render_changelog_section "chore" "${JIGGIT_ENV_DIFF_CHORE_ITEMS}"
  render_changelog_section "other" "${JIGGIT_ENV_DIFF_OTHER_ITEMS}"
}

# Render the full env-diff report once both environment versions are resolved.
render_env_diff_summary() {
  local project_id="${1}"
  local repo_path="${2}"
  local base_label="${3}"
  local target_label="${4}"
  local base_value="${5}"
  local target_value="${6}"
  local base_norm="${7}"
  local target_norm="${8}"
  local commit_count="${9}"
  local compare_url="${10}"
  local issue_keys="${11}"

  print_markdown_h1 "jiggit env-diff"
  printf '\n'
  printf -- "- Project: \`%s\`\n" "${project_id}"
  printf -- "- Repo path: \`%s\`\n" "${repo_path}"
  printf -- "- Base: \`%s\`\n" "${base_label}"
  printf -- "- Target: \`%s\`\n" "${target_label}"
  printf -- "- Base resolved ref: \`%s\`\n" "${base_value}"
  printf -- "- Target resolved ref: \`%s\`\n" "${target_value}"
  printf -- "- Normalized range: \`%s..%s\`\n" "${base_norm}" "${target_norm}"
  printf -- '- Commit count: %s\n' "${commit_count}"
  printf -- "- Compare URL: \`%s\`\n\n" "${compare_url:-unavailable}"

  render_env_diff_issue_keys "${issue_keys}"
  render_env_diff_commit_groups
}

# Resolve both env/ref operands and print either an explicit no-diff result or a full report.
run_env_diff_main() {
  local project_selector=""
  if [[ $# -gt 0 && "${1}" != -* ]]; then
    project_selector="${1}"
    shift || true
  fi

  if [[ "${project_selector}" == "-h" || "${project_selector}" == "--help" ]]; then
    env_diff_usage
    return 0
  fi

  local base_input=""
  local target_input=""

  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --base)
        base_input="${2:-}"
        shift 2
        ;;
      --target)
        target_input="${2:-}"
        shift 2
        ;;
      --verbose)
        JIGGIT_ENV_DIFF_VERBOSE=1
        JIGGIT_ENV_VERSIONS_VERBOSE=1
        shift
        ;;
      -h|--help)
        env_diff_usage
        return 0
        ;;
      *)
        printf 'Unknown option: %s\n' "${1}" >&2
        env_diff_usage >&2
        return 1
        ;;
    esac
  done

  if [[ -z "${base_input}" ]]; then
    printf '--base is required.\n' >&2
    env_diff_usage >&2
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
  local configured_environments
  local base_resolution
  local target_resolution
  local base_label
  local target_label
  local base_value
  local target_value
  local base_norm
  local target_norm
  local base_compare_ref
  local target_compare_ref
  local target_ref=""
  local git_range
  local commit_count
  local issue_keys
  local compare_url=""

  repo_path="$(project_repo_path "${project_id}")"
  configured_environments=" $(project_environments "${project_id}") "

  if [[ ! -d "${repo_path}" ]]; then
    printf 'Project repo path does not exist: %s\n' "${repo_path}" >&2
    return 1
  fi

  base_resolution="$(env_diff_resolve_operand "${project_id}" "${repo_path}" "${configured_environments}" "${base_input}")" || {
    printf '%s\n' "${base_resolution#ERROR|}" >&2
    return 1
  }
  IFS='|' read -r _ base_label base_value base_norm base_compare_ref <<< "${base_resolution}"

  if [[ -n "${target_input}" ]]; then
    target_resolution="$(env_diff_resolve_operand "${project_id}" "${repo_path}" "${configured_environments}" "${target_input}")" || {
      printf '%s\n' "${target_resolution#ERROR|}" >&2
      return 1
    }
    IFS='|' read -r _ target_label target_value target_norm target_compare_ref <<< "${target_resolution}"
  else
    target_ref="$(default_target_git_ref "${repo_path}")"
    target_label="${target_ref}"
    target_value="${target_ref}"
    target_norm="${target_ref}"
    target_compare_ref="$(env_diff_compare_ref "${repo_path}" "${target_ref}")"
  fi

  if [[ -n "${target_input}" && "${base_norm}" == "${target_norm}" ]]; then
    print_markdown_h1 "jiggit env-diff"
    printf '\n'
    printf -- "- Project: \`%s\`\n" "${project_id}"
    printf -- "- Base: \`%s\`\n" "${base_label}"
    printf -- "- Target: \`%s\`\n" "${target_label}"
    printf -- "- Resolved ref: \`%s\`\n\n" "${base_value}"
    printf 'No difference: both operands resolve to the same ref.\n'
    return 0
  fi

  if [[ -z "${base_norm}" || -z "${target_norm}" ]]; then
    printf 'Unable to normalize env-diff operands for git comparison.\n' >&2
    return 1
  fi

  git_range="${base_norm}..${target_norm}"
  commit_count="$(compare_commit_count "${repo_path}" "${git_range}")"
  issue_keys="$(compare_issue_keys "${repo_path}" "${git_range}" "${project_id}")"
  compare_url="$(compare_url_for_project "${project_id}" "${repo_path}" "${base_compare_ref}" "${target_compare_ref}" || true)"
  env_diff_grouped_commit_items "${repo_path}" "${git_range}"

  render_env_diff_summary "${project_id}" "${repo_path}" "${base_label}" "${target_label}" "${base_value}" "${target_value}" "${base_norm}" "${target_norm}" "${commit_count}" "${compare_url}" "${issue_keys}"
}
