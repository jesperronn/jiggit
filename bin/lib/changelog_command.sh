#!/usr/bin/env bash

set -euo pipefail

if ! declare -F load_project_config >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/explore.sh"
fi

if ! declare -F compare_normalize_version >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/compare_command.sh"
fi

if ! declare -F print_markdown_h1 >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/common_output.sh"
fi

# Render help for the changelog subcommand.
changelog_usage() {
  print_jiggit_usage_block <<'EOF'
Usage:
  jiggit changelog [<project|path>] --from <git-ref> --to <git-ref>

Show a Markdown changelog grouped by conventional commit type.
EOF
}

# Return commit lines encoded with a delimiter so they can be grouped safely in Bash.
changelog_commit_lines() {
  local repo_path="${1}"
  local git_range="${2}"
  git -C "${repo_path}" log --format='%h%x1f%s' "${git_range}"
}

# Extract the conventional commit type from a subject line, falling back to other.
conventional_commit_type() {
  local subject_line="${1:-}"
  local conventional_regex='^([A-Z][A-Z0-9]+-[0-9]+[[:space:]]+)?([a-z]+)(\([[:alnum:]_-]+\))?(!)?:[[:space:]]+'

  if [[ "${subject_line}" =~ ${conventional_regex} ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
  else
    printf 'other\n'
  fi
}

# Render the commits for one changelog section.
render_changelog_section() {
  local section_name="${1}"
  local section_items="${2:-}"
  local item

  [[ -z "${section_items}" ]] && return 0

  print_markdown_h2 "${section_name}" "${C_CYAN}"
  printf '\n'
  while IFS= read -r item; do
    [[ -z "${item}" ]] && continue
    printf -- '* %s\n' "${item}"
  done <<< "${section_items}"
  printf '\n'
}

# Build a grouped Markdown changelog from the repository commits in the range.
render_changelog_summary() {
  local project_id="${1}"
  local repo_path="${2}"
  local from_norm="${3}"
  local to_norm="${4}"
  local git_range="${5}"
  local commit_count="${6}"
  local compare_url="${7}"
  local line
  local commit_hash
  local subject_line
  local commit_type
  local jira_keys
  local entry

  local feat_items=""
  local fix_items=""
  local docs_items=""
  local chore_items=""
  local refactor_items=""
  local test_items=""
  local other_items=""

  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    commit_hash="${line%%$'\x1f'*}"
    subject_line="${line#*$'\x1f'}"
    commit_type="$(conventional_commit_type "${subject_line}")"
    jira_keys="$(printf '%s\n' "${subject_line}" | grep -Eo "${JIGGIT_FALLBACK_JIRA_REGEX}" | sort -u | paste -sd ', ' - || true)"
    entry="\`${commit_hash}\` ${subject_line}"
    if [[ -n "${jira_keys}" ]]; then
      entry="${entry} [${jira_keys}]"
    fi

    case "${commit_type}" in
      feat)
        feat_items="${feat_items}${entry}"$'\n'
        ;;
      fix)
        fix_items="${fix_items}${entry}"$'\n'
        ;;
      docs)
        docs_items="${docs_items}${entry}"$'\n'
        ;;
      chore)
        chore_items="${chore_items}${entry}"$'\n'
        ;;
      refactor)
        refactor_items="${refactor_items}${entry}"$'\n'
        ;;
      test)
        test_items="${test_items}${entry}"$'\n'
        ;;
      *)
        other_items="${other_items}${entry}"$'\n'
        ;;
    esac
  done < <(changelog_commit_lines "${repo_path}" "${git_range}")

  print_markdown_h1 "jiggit changelog"
  printf '\n'
  printf -- "- Project: \`%s\`\n" "${project_id}"
  printf -- "- Repo path: \`%s\`\n" "${repo_path}"
  printf -- "- From: \`%s\`\n" "${from_norm}"
  printf -- "- To: \`%s\`\n" "${to_norm}"
  printf -- "- Range: \`%s\`\n" "${git_range}"
  printf -- '- Commit count: %s\n' "${commit_count}"
  printf -- "- Compare URL: \`%s\`\n\n" "${compare_url:-unavailable}"

  render_changelog_section "feat" "${feat_items}"
  render_changelog_section "fix" "${fix_items}"
  render_changelog_section "docs" "${docs_items}"
  render_changelog_section "refactor" "${refactor_items}"
  render_changelog_section "test" "${test_items}"
  render_changelog_section "chore" "${chore_items}"
  render_changelog_section "other" "${other_items}"
}

# Parse arguments, validate project config, and print the grouped changelog.
run_changelog_main() {
  local project_selector=""
  if [[ $# -gt 0 && "${1}" != -* ]]; then
    project_selector="${1}"
    shift || true
  fi

  if [[ "${project_selector}" == "-h" || "${project_selector}" == "--help" ]]; then
    changelog_usage
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
        changelog_usage
        return 0
        ;;
      *)
        printf 'Unknown option: %s\n' "${1}" >&2
        changelog_usage >&2
        return 1
        ;;
    esac
  done

  if [[ -z "${from_ref}" || -z "${to_ref}" ]]; then
    printf 'Both --from and --to are required.\n' >&2
    changelog_usage >&2
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
  local compare_url=""

  from_norm="$(compare_normalize_version "${repo_path}" "${from_ref}" | tr -d '\n')"
  to_norm="$(compare_normalize_version "${repo_path}" "${to_ref}" | tr -d '\n')"
  if [[ -z "${from_norm}" || -z "${to_norm}" ]]; then
    printf 'Unable to normalize refs for changelog.\n' >&2
    return 1
  fi

  git_range="${from_norm}..${to_norm}"
  commit_count="$(compare_commit_count "${repo_path}" "${git_range}")"
  compare_url="$(compare_url_for_project "${project_id}" "${repo_path}" "refs/tags/${from_norm}" "refs/tags/${to_norm}" || true)"

  render_changelog_summary "${project_id}" "${repo_path}" "${from_norm}" "${to_norm}" "${git_range}" "${commit_count}" "${compare_url}"
}
