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

if ! declare -F fetch_jira_issues_by_keys >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "${JIGGIT_ROOT}/bin/lib/release_notes_command.sh"
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

# Load next-release helpers lazily to avoid recursive sourcing during module load.
env_diff_require_next_release_helpers() {
  if declare -F bump_minor_version >/dev/null 2>&1 && declare -F render_next_release_issue_lines >/dev/null 2>&1; then
    return 0
  fi

  # shellcheck disable=SC1091
  source "${JIGGIT_ROOT}/bin/lib/next_release_command.sh"
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

# Return the parsed conventional commit type, scope, and subject.
env_diff_parse_commit_subject() {
  local subject_line="${1:-}"
  local conventional_regex='^([A-Z][A-Z0-9]+-[0-9]+[[:space:]]+)?([a-z]+)(\(([[:alnum:]_-]+)\))?(!)?:[[:space:]]+(.*)$'

  if [[ "${subject_line}" =~ ${conventional_regex} ]]; then
    printf '%s|%s|%s|%s\n' \
      "${BASH_REMATCH[2]}" \
      "${BASH_REMATCH[4]}" \
      "${BASH_REMATCH[6]}" \
      "${BASH_REMATCH[5]}"
    return 0
  fi

  printf 'other|||%s\n' "${subject_line}"
}

# Return success when a commit should be treated as breaking.
env_diff_is_breaking_commit() {
  local subject_line="${1:-}"
  local body_text="${2:-}"
  local parsed=""
  local breaking_marker=""

  parsed="$(env_diff_parse_commit_subject "${subject_line}")"
  IFS='|' read -r _ _ _ breaking_marker <<< "${parsed}"
  if [[ -n "${breaking_marker}" ]]; then
    return 0
  fi

  if printf '%s\n%s\n' "${subject_line}" "${body_text}" | grep -Eiq '(^|[^[:alpha:]])BREAKING([^[:alpha:]]|$)|(^|[^[:alpha:]])breaks([^[:alpha:]]|$)'; then
    return 0
  fi

  return 1
}

# Return the first Jira key found in a commit body, with subject fallback.
env_diff_commit_jira_key() {
  local project_id="${1}"
  local subject_line="${2:-}"
  local body_text="${3:-}"
  local pattern=""
  local key=""

  pattern="$(project_jira_regexes "${project_id}" | sed 's/ /|/g')"
  if [[ -n "${pattern}" ]]; then
    key="$(printf '%s\n' "${body_text}" | grep -Eo "${pattern}" | head -n 1 || true)"
    if [[ -z "${key}" ]]; then
      key="$(printf '%s\n' "${subject_line}" | grep -Eo "${pattern}" | head -n 1 || true)"
    fi
  fi

  if [[ -z "${key}" ]]; then
    key="$(printf '%s\n' "${body_text}" | grep -Eo "${JIGGIT_FALLBACK_JIRA_REGEX}" | head -n 1 || true)"
  fi
  if [[ -z "${key}" ]]; then
    key="$(printf '%s\n' "${subject_line}" | grep -Eo "${JIGGIT_FALLBACK_JIRA_REGEX}" | head -n 1 || true)"
  fi

  printf '%s\n' "${key}"
}

# Return a color for one commit type.
env_diff_commit_type_color() {
  local commit_type="${1:-other}"

  case "${commit_type}" in
    breaking) printf '%s\n' "${C_RED}" ;;
    feat) printf '%s\n' "${C_GREEN}" ;;
    fix) printf '%s\n' "${C_CYAN}" ;;
    docs) printf '%s\n' "${C_BLUE}" ;;
    refactor) printf '%s\n' "${C_MAGENTA}" ;;
    test) printf '%s\n' "${C_ORANGE}" ;;
    chore) printf '%s\n' "${C_DIM}" ;;
    *) printf '%s\n' "${C_DIM}" ;;
  esac
}

# Render one enriched commit line for env-diff.
env_diff_render_commit_entry() {
  local commit_type="${1}"
  local commit_scope="${2}"
  local commit_subject="${3}"
  local jira_key="${4}"
  local commit_hash="${5}"
  local type_color=""
  local type_label="${commit_type}"
  local scope_text=""
  local jira_text=""
  local sha_text=""

  type_color="$(env_diff_commit_type_color "${commit_type}")"
  if [[ -n "${commit_scope}" ]]; then
    scope_text="(${commit_scope}):"
  fi
  if [[ -n "${jira_key}" ]]; then
    jira_text="${jira_key}"
  fi
  sha_text="${commit_hash}"

  if ! use_color_output; then
    printf -- "- %s %s %s" "${type_label}" "${scope_text}" "${commit_subject}"
    if [[ -n "${jira_text}" ]]; then
      printf ' %s' "${jira_text}"
    fi
    printf ' %s\n' "${sha_text}"
    return 0
  fi

  printf -- '- %b%s%b ' "${C_BOLD}${type_color}" "${type_label}" "${C_0}"
  if [[ -n "${scope_text}" ]]; then
    printf '%b%s%b ' "${C_BOLD}${type_color}" "${scope_text}" "${C_0}"
  fi
  printf '%s' "${commit_subject}"
  if [[ -n "${jira_text}" ]]; then
    printf ' %b%s%b' "${C_BOLD}${C_CYAN}" "${jira_text}" "${C_0}"
  fi
  printf ' %b%s%b\n' "${C_DIM}" "${sha_text}" "${C_0}"
}

# Build grouped changelog buckets from a git range.
env_diff_grouped_commit_items() {
  local repo_path="${1}"
  local git_range="${2}"
  local project_id="${3}"
  local line
  local commit_hash
  local subject_line
  local commit_body=""
  local commit_type
  local commit_scope=""
  local commit_subject=""
  local breaking_marker=""
  local jira_key=""
  local entry

  JIGGIT_ENV_DIFF_BREAKING_ITEMS=""
  JIGGIT_ENV_DIFF_FEAT_ITEMS=""
  JIGGIT_ENV_DIFF_FIX_ITEMS=""
  JIGGIT_ENV_DIFF_DOCS_ITEMS=""
  JIGGIT_ENV_DIFF_REFACTOR_ITEMS=""
  JIGGIT_ENV_DIFF_TEST_ITEMS=""
  JIGGIT_ENV_DIFF_CHORE_ITEMS=""
  JIGGIT_ENV_DIFF_OTHER_ITEMS=""

  while IFS= read -r -d $'\036' line; do
    [[ -z "${line}" ]] && continue
    commit_hash="${line%%$'\x1f'*}"
    line="${line#*$'\x1f'}"
    subject_line="${line%%$'\x1f'*}"
    commit_body="${line#*$'\x1f'}"
    IFS='|' read -r commit_type commit_scope commit_subject breaking_marker <<< "$(env_diff_parse_commit_subject "${subject_line}")"
    jira_key="$(env_diff_commit_jira_key "${project_id}" "${subject_line}" "${commit_body}")"

    if env_diff_is_breaking_commit "${subject_line}" "${commit_body}"; then
      commit_type="breaking"
    fi

    entry="$(env_diff_render_commit_entry "${commit_type}" "${commit_scope}" "${commit_subject}" "${jira_key}" "${commit_hash}")"

    case "${commit_type}" in
      breaking)
        JIGGIT_ENV_DIFF_BREAKING_ITEMS="${JIGGIT_ENV_DIFF_BREAKING_ITEMS}${entry}"$'\n'
        ;;
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
  done < <(git -C "${repo_path}" log --format='%h%x1f%s%x1f%b%x1e' "${git_range}")
}

# Render grouped commit sections for env-diff.
render_env_diff_commit_groups() {
  print_markdown_h2 "Commits By Type" "${C_MAGENTA}"
  printf '\n'
  render_changelog_section "breaking" "${JIGGIT_ENV_DIFF_BREAKING_ITEMS}"
  render_changelog_section "feat" "${JIGGIT_ENV_DIFF_FEAT_ITEMS}"
  render_changelog_section "fix" "${JIGGIT_ENV_DIFF_FIX_ITEMS}"
  render_changelog_section "docs" "${JIGGIT_ENV_DIFF_DOCS_ITEMS}"
  render_changelog_section "refactor" "${JIGGIT_ENV_DIFF_REFACTOR_ITEMS}"
  render_changelog_section "test" "${JIGGIT_ENV_DIFF_TEST_ITEMS}"
  render_changelog_section "chore" "${JIGGIT_ENV_DIFF_CHORE_ITEMS}"
  render_changelog_section "other" "${JIGGIT_ENV_DIFF_OTHER_ITEMS}"
}

# Render Jira issues for env-diff using next-release fixVersion rules.
render_env_diff_jira_issues() {
  local project_id="${1}"
  local jira_base_url_value="${2}"
  local suggested_version="${3:-}"
  local issue_keys_text="${4:-}"
  local issues_json="${5:-}"
  local jira_fetch_status="${6:-ok}"
  local issue_json=""
  local missing_fix_version_count=0

  [[ -n "${issues_json}" ]] || issues_json='{"issues":[]}'
  env_diff_require_next_release_helpers

  print_markdown_h2 "Jira Issues" "${C_GREEN}"
  printf '\n'

  if [[ -z "${issue_keys_text}" ]]; then
    printf '_No Jira issues mentioned in commit history for this range._\n\n'
    return 0
  fi

  if [[ "${jira_fetch_status}" == "missing-config" ]]; then
    printf -- "- status: missing jira base url\n"
    printf -- "- next step: jiggit config\n\n"
    return 0
  fi

  if [[ "${jira_fetch_status}" == "fetch-failed" ]]; then
    printf -- "- status: unable to fetch jira issues\n"
    printf -- "- next step: jiggit jira-check %s\n\n" "${project_id}"
    return 0
  fi

  render_next_release_issue_lines "${issues_json}" "${suggested_version}" "${project_id}" "${jira_base_url_value}"

  while IFS= read -r issue_json; do
    [[ -z "${issue_json}" ]] && continue
    case "$(next_release_issue_fix_version_state "${issue_json}" "${suggested_version}" "${project_id}")" in
      missing-fix-version)
        missing_fix_version_count=$((missing_fix_version_count + 1))
        ;;
    esac
  done < <(printf '%s\n' "${issues_json}" | jq -c '.issues[]?')

  if [[ "${missing_fix_version_count}" -gt 0 ]]; then
    printf -- "- add missing fixVersion: jiggit assign-fix-version %s --release %s\n" "${project_id}" "${suggested_version#v}"
  fi
  printf '\n'
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
  local suggested_version="${10}"
  local suggested_release_url="${11}"
  local issue_keys_text="${12}"
  local issues_json="${13}"
  local jira_fetch_status="${14}"
  local jira_base_url_value="${15}"

  print_markdown_h1 "jiggit env-diff"
  printf '\n'
  printf -- "- Repo path: \`%s\`\n" "${repo_path}"
  printf -- "- Target: \`%s\`\n" "${target_label}"
  printf -- "- base version (%s): %s\n" "${base_label}" "${base_value}"
  printf -- "- target ref: %s\n" "${target_value}"
  printf -- "- commit count ahead: %s\n" "${commit_count}"
  if [[ -n "${suggested_version}" ]]; then
    printf -- "- **suggested next release: %s**\n" "${suggested_version}"
  fi
  if [[ -n "${suggested_release_url}" ]]; then
    printf -- "- suggested release link: %s\n" "${suggested_release_url}"
  fi
  printf '\n'

  render_env_diff_commit_groups
  render_env_diff_jira_issues "${project_id}" "${jira_base_url_value}" "${suggested_version}" "${issue_keys_text}" "${issues_json}" "${jira_fetch_status}"
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
  local -a issue_keys_array=()
  local issues_json='{"issues":[]}'
  local jira_fetch_status="ok"
  local jira_base_url_value=""
  local suggested_version=""
  local suggested_release_url=""

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
  jira_base_url_value="$(jira_base_url "${project_id}")"
  env_diff_require_next_release_helpers
  suggested_version="$(bump_minor_version "${base_norm}" || true)"
  if [[ -n "${suggested_version}" ]]; then
    suggested_release_url="$(compare_url_for_project "${project_id}" "${repo_path}" "refs/tags/${suggested_version}" "${target_compare_ref}" || true)"
  fi
  if [[ -n "${issue_keys}" ]]; then
    if [[ -z "${jira_base_url_value}" ]]; then
      jira_fetch_status="missing-config"
    elif ! mapfile -t issue_keys_array < <(printf '%s\n' "${issue_keys}" | sed '/^$/d'); then
      jira_fetch_status="fetch-failed"
    else
      if ! issues_json="$(fetch_jira_issues_by_keys "${jira_base_url_value}" "" "${issue_keys_array[@]}" 2>/dev/null)"; then
        jira_fetch_status="fetch-failed"
        issues_json='{"issues":[]}'
      fi
    fi
  fi
  env_diff_grouped_commit_items "${repo_path}" "${git_range}" "${project_id}"

  render_env_diff_summary "${project_id}" "${repo_path}" "${base_label}" "${target_label}" "${base_value}" "${target_value}" "${base_norm}" "${target_norm}" "${commit_count}" "${suggested_version}" "${suggested_release_url}" "${issue_keys}" "${issues_json}" "${jira_fetch_status}" "${jira_base_url_value}"
}
