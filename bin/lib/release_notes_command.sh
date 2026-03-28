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

if ! declare -F compare_normalize_version >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "${JIGGIT_ROOT}/bin/lib/compare_command.sh"
fi

if ! declare -F changelog_commit_lines >/dev/null 2>&1 || ! declare -F conventional_commit_type >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "${JIGGIT_ROOT}/bin/lib/changelog_command.sh"
fi

if ! declare -F fetch_jira_releases >/dev/null 2>&1 || ! declare -F find_matching_releases >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "${JIGGIT_ROOT}/bin/lib/releases_command.sh"
fi

if ! declare -F fetch_project_environment_version >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "${JIGGIT_ROOT}/bin/lib/env_versions_command.sh"
fi

if ! declare -F jira_issue_fix_version_display >/dev/null 2>&1 || ! declare -F jira_issues_url_encode >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "${JIGGIT_ROOT}/bin/lib/jira_issues_command.sh"
fi

if ! declare -F print_markdown_h1 >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "${JIGGIT_ROOT}/bin/lib/common_output.sh"
fi

# Render help for release-notes.
release_notes_usage() {
  cat <<'EOF'
Usage:
  jiggit release-notes [<project|path>] --target <git-ref|release> [--from-env <env>] [--from <git-ref>]

Generate git-first release notes enriched with Jira metadata.
EOF
}

# Return 0 when the given input can be resolved locally as an exact git ref.
release_notes_has_exact_git_ref() {
  local repo_path="${1}"
  local ref_input="${2}"

  if git -C "${repo_path}" rev-parse --verify --quiet "${ref_input}^{commit}" >/dev/null 2>&1; then
    return 0
  fi

  if git -C "${repo_path}" rev-parse --verify --quiet "refs/tags/${ref_input}" >/dev/null 2>&1; then
    return 0
  fi

  if git -C "${repo_path}" rev-parse --verify --quiet "refs/heads/${ref_input}" >/dev/null 2>&1; then
    return 0
  fi

  if git -C "${repo_path}" rev-parse --verify --quiet "refs/remotes/origin/${ref_input}" >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

# Convert a release-notes ref into a hosting-friendly compare ref.
release_notes_compare_ref() {
  local repo_path="${1}"
  local ref_input="${2}"

  if [[ "${ref_input}" == refs/remotes/origin/* ]]; then
    printf 'refs/heads/%s\n' "${ref_input#refs/remotes/origin/}"
    return 0
  fi

  if [[ "${ref_input}" == refs/heads/* || "${ref_input}" == refs/tags/* ]]; then
    printf '%s\n' "${ref_input}"
    return 0
  fi

  if [[ "${ref_input}" == origin/* ]]; then
    printf 'refs/heads/%s\n' "${ref_input#origin/}"
    return 0
  fi

  if git -C "${repo_path}" rev-parse --verify --quiet "refs/tags/${ref_input}" >/dev/null 2>&1; then
    printf 'refs/tags/%s\n' "${ref_input}"
    return 0
  fi

  if git -C "${repo_path}" rev-parse --verify --quiet "refs/heads/${ref_input}" >/dev/null 2>&1; then
    printf 'refs/heads/%s\n' "${ref_input}"
    return 0
  fi

  if git -C "${repo_path}" rev-parse --verify --quiet "refs/remotes/origin/${ref_input}" >/dev/null 2>&1; then
    printf 'refs/heads/%s\n' "${ref_input}"
    return 0
  fi

  printf '%s\n' "${ref_input}"
}

# Resolve a start ref from either an explicit git ref or an environment name.
release_notes_resolve_start_ref() {
  local project_id="${1}"
  local from_env="${2:-}"
  local from_ref="${3:-}"

  if [[ -n "${from_ref}" ]]; then
    printf '%s\n' "${from_ref}"
    return 0
  fi

  if [[ -n "${from_env}" ]]; then
    fetch_project_environment_version "${project_id}" "${from_env}"
    return 0
  fi

  return 1
}

# Render ambiguous target candidates when a fuzzy Jira release query matches several releases.
render_release_notes_target_candidates() {
  local target_query="${1}"
  local matching_releases="${2}"
  local release_json

  printf 'Target "%s" matched multiple Jira releases.\n\n' "${target_query}"
  print_markdown_h2 "Matching Releases" "${C_CYAN}"
  printf '\n'
  while IFS= read -r release_json; do
    [[ -z "${release_json}" ]] && continue
    printf -- "- \`%s\`\n" "$(printf '%s\n' "${release_json}" | jq -r '.name // "unknown"')"
  done <<< "${matching_releases}"
}

# Resolve the target string as either an exact git ref, a unique Jira release, or an ambiguous match.
release_notes_resolve_target() {
  local repo_path="${1}"
  local jira_base_url="${2}"
  local jira_project_key="${3}"
  local target_input="${4}"
  local releases_json=""
  local matching_releases=""
  local match_count="0"
  local release_name=""

  if release_notes_has_exact_git_ref "${repo_path}" "${target_input}"; then
    printf 'git-ref|%s\n' "${target_input}"
    return 0
  fi

  if [[ -n "${jira_base_url}" && -n "${jira_project_key}" ]]; then
    releases_json="$(fetch_jira_releases "${jira_base_url}" "${jira_project_key}" 2>/dev/null || true)"
    if [[ -n "${releases_json}" ]]; then
      matching_releases="$(find_matching_releases "${releases_json}" "${target_input}")"
      match_count="$(printf '%s\n' "${matching_releases}" | sed '/^$/d' | wc -l | tr -d ' ')"
      if [[ "${match_count}" -eq 1 ]]; then
        release_name="$(printf '%s\n' "${matching_releases}" | jq -r '.name // "unknown"')"
        printf 'release|%s\n' "${release_name}"
        return 0
      fi
      if [[ "${match_count}" -gt 1 ]]; then
        printf 'ambiguous|%s\n' "$(printf '%s' "${matching_releases}" | jq -R -s '.')"
        return 0
      fi
    fi
  fi

  printf 'git-ref|%s\n' "${target_input}"
}

# Fetch Jira issue details for a list of issue keys.
fetch_jira_issues_by_keys() {
  local jira_base_url="${1}"
  local auth_reference="${2:-}"
  shift 2
  local -a keys=("$@")
  local jql=""
  local joined_keys
  local encoded_jql
  local -a auth_args=()

  if [[ ${#keys[@]} -eq 0 ]]; then
    printf '{"issues":[]}\n'
    return 0
  fi

  joined_keys="$(printf '"%s",' "${keys[@]}")"
  joined_keys="${joined_keys%,}"
  jql="key in (${joined_keys}) ORDER BY key ASC"
  encoded_jql="$(jira_issues_url_encode "${jql}")"
  mapfile -t auth_args < <(jira_auth_args "${auth_reference}")

  curl --silent --show-error --fail \
    "${auth_args[@]}" \
    -H "Accept: application/json" \
    "${jira_base_url%/}/rest/api/2/search?jql=${encoded_jql}&fields=summary,status,labels,fixVersions"
}

# Build grouped note buckets and mismatch lists from the git range.
build_release_notes_buckets() {
  local repo_path="${1}"
  local git_range="${2}"
  local project_id="${3}"
  local line
  local commit_hash
  local subject_line
  local issue_key
  local commit_type
  local entry

  RELEASE_NOTES_FEAT=""
  RELEASE_NOTES_FIX=""
  RELEASE_NOTES_DOCS=""
  RELEASE_NOTES_REFACTOR=""
  RELEASE_NOTES_TEST=""
  RELEASE_NOTES_CHORE=""
  RELEASE_NOTES_OTHER=""
  RELEASE_NOTES_WITHOUT_ISSUE=""
  RELEASE_NOTES_ISSUE_KEYS=""

  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    commit_hash="${line%%$'\x1f'*}"
    subject_line="${line#*$'\x1f'}"
    commit_type="$(conventional_commit_type "${subject_line}")"
    issue_key="$(printf '%s\n' "${subject_line}" | grep -Eo "$(project_jira_regexes "${project_id}" | sed 's/ /|/g')" | head -n 1 || true)"
    if [[ -z "${issue_key}" ]]; then
      issue_key="$(printf '%s\n' "${subject_line}" | grep -Eo "${JIGGIT_FALLBACK_JIRA_REGEX}" | head -n 1 || true)"
    fi

    entry="\`${commit_hash}\` ${subject_line}"
    if [[ -n "${issue_key}" ]]; then
      entry="${entry} [${issue_key}]"
      RELEASE_NOTES_ISSUE_KEYS="${RELEASE_NOTES_ISSUE_KEYS}${issue_key}"$'\n'
    else
      RELEASE_NOTES_WITHOUT_ISSUE="${RELEASE_NOTES_WITHOUT_ISSUE}${entry}"$'\n'
    fi

    case "${commit_type}" in
      feat) RELEASE_NOTES_FEAT="${RELEASE_NOTES_FEAT}${entry}"$'\n' ;;
      fix) RELEASE_NOTES_FIX="${RELEASE_NOTES_FIX}${entry}"$'\n' ;;
      docs) RELEASE_NOTES_DOCS="${RELEASE_NOTES_DOCS}${entry}"$'\n' ;;
      refactor) RELEASE_NOTES_REFACTOR="${RELEASE_NOTES_REFACTOR}${entry}"$'\n' ;;
      test) RELEASE_NOTES_TEST="${RELEASE_NOTES_TEST}${entry}"$'\n' ;;
      chore) RELEASE_NOTES_CHORE="${RELEASE_NOTES_CHORE}${entry}"$'\n' ;;
      *) RELEASE_NOTES_OTHER="${RELEASE_NOTES_OTHER}${entry}"$'\n' ;;
    esac
  done < <(changelog_commit_lines "${repo_path}" "${git_range}")

  RELEASE_NOTES_ISSUE_KEYS="$(printf '%s\n' "${RELEASE_NOTES_ISSUE_KEYS}" | sed '/^$/d' | sort -u)"
}

# Render Jira-enriched issue section from fetched issue metadata.
render_release_notes_issue_section() {
  local issues_json="${1}"
  local target_release_name="${2:-}"
  local issue_json
  local suspicious=""

  print_markdown_h2 "Jira Issues" "${C_GREEN}"
  printf '\n'
  while IFS= read -r issue_json; do
    [[ -z "${issue_json}" ]] && continue
    printf -- "- \`%s\`\n" "$(printf '%s\n' "${issue_json}" | jq -r '.key')"
    printf "  - title: \`%s\`\n" "$(printf '%s\n' "${issue_json}" | jq -r '.fields.summary // "unknown"')"
    printf "  - status: \`%s\`\n" "$(printf '%s\n' "${issue_json}" | jq -r '.fields.status.name // "unknown"')"
    printf "  - labels: \`%s\`\n" "$(printf '%s\n' "${issue_json}" | jq -r 'if (.fields.labels // []) == [] then "none" else (.fields.labels | join(", ")) end')"
    printf "  - fix_version: \`%s\`\n" "$(jira_issue_fix_version_display "${issue_json}")"

    if [[ -n "${target_release_name}" ]]; then
      if ! printf '%s\n' "${issue_json}" | jq -e --arg release_name "${target_release_name}" '(.fields.fixVersions // []) | any(.name == $release_name)' >/dev/null 2>&1; then
        suspicious="${suspicious}$(printf '%s\n' "${issue_json}" | jq -r '.key')"$'\n'
      fi
    fi
  done < <(printf '%s\n' "${issues_json}" | jq -c '.issues[]?')
  printf '\n'

  if [[ -n "${suspicious}" ]]; then
    print_markdown_h2 "Suspicious Jira Keys" "${C_ORANGE}"
    printf '\n'
    while IFS= read -r key; do
      [[ -z "${key}" ]] && continue
      printf -- "- \`%s\`\n" "${key}"
    done <<< "${suspicious}"
    printf '\n'
  fi
}

# Render mismatch sections for missing Jira evidence.
render_release_notes_mismatches() {
  local target_release_name="${1:-}"
  local release_issues_json="${2:-}"
  local release_issue_keys=""
  local missing_from_git=""
  local key

  if [[ -n "${RELEASE_NOTES_WITHOUT_ISSUE}" ]]; then
    print_markdown_h2 "Commits Without Jira Keys" "${C_MAGENTA}"
    printf '\n'
    while IFS= read -r item; do
      [[ -z "${item}" ]] && continue
      printf -- "- %s\n" "${item}"
    done <<< "${RELEASE_NOTES_WITHOUT_ISSUE}"
    printf '\n'
  fi

  if [[ -n "${target_release_name}" && -n "${release_issues_json}" ]]; then
    release_issue_keys="$(printf '%s\n' "${release_issues_json}" | jq -r '.issues[]?.key' | sed '/^$/d')"
    while IFS= read -r key; do
      [[ -z "${key}" ]] && continue
      if [[ "$(printf '%s\n' "${RELEASE_NOTES_ISSUE_KEYS}")" != *"${key}"* ]]; then
        missing_from_git="${missing_from_git}${key}"$'\n'
      fi
    done <<< "${release_issue_keys}"

    if [[ -n "${missing_from_git}" ]]; then
      print_markdown_h2 "Jira Release Issues Missing From Git Evidence" "${C_CYAN}"
      printf '\n'
      while IFS= read -r key; do
        [[ -z "${key}" ]] && continue
        printf -- "- \`%s\`\n" "${key}"
      done <<< "${missing_from_git}"
      printf '\n'
    fi
  fi
}

# Render the full release-notes report.
render_release_notes_summary() {
  local project_id="${1}"
  local repo_path="${2}"
  local from_ref="${3}"
  local to_ref="${4}"
  local commit_count="${5}"
  local compare_url="${6}"
  local issues_json="${7}"
  local target_release_name="${8:-}"
  local release_issues_json="${9:-}"

  print_markdown_h1 "jiggit release-notes"
  printf '\n'
  printf -- "- Project: \`%s\`\n" "${project_id}"
  printf -- "- Repo path: \`%s\`\n" "${repo_path}"
  printf -- "- From: \`%s\`\n" "${from_ref}"
  printf -- "- Target: \`%s\`\n" "${to_ref}"
  printf -- '- Commit count: %s\n' "${commit_count}"
  printf -- "- Compare URL: \`%s\`\n\n" "${compare_url:-unavailable}"

  render_changelog_section "feat" "${RELEASE_NOTES_FEAT}"
  render_changelog_section "fix" "${RELEASE_NOTES_FIX}"
  render_changelog_section "docs" "${RELEASE_NOTES_DOCS}"
  render_changelog_section "refactor" "${RELEASE_NOTES_REFACTOR}"
  render_changelog_section "test" "${RELEASE_NOTES_TEST}"
  render_changelog_section "chore" "${RELEASE_NOTES_CHORE}"
  render_changelog_section "other" "${RELEASE_NOTES_OTHER}"
  render_release_notes_issue_section "${issues_json}" "${target_release_name}"
  render_release_notes_mismatches "${target_release_name}" "${release_issues_json}"
}

# Generate git-first release notes for a target version or release.
run_release_notes_main() {
  local project_selector=""
  if [[ $# -gt 0 && "${1}" != -* ]]; then
    project_selector="${1}"
    shift || true
  fi

  if [[ "${project_selector}" == "-h" || "${project_selector}" == "--help" ]]; then
    release_notes_usage
    return 0
  fi

  local target_input=""
  local from_env=""
  local from_ref=""

  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --target)
        target_input="${2:-}"
        shift 2
        ;;
      --from-env)
        from_env="${2:-}"
        shift 2
        ;;
      --from)
        from_ref="${2:-}"
        shift 2
        ;;
      -h|--help)
        release_notes_usage
        return 0
        ;;
      *)
        printf 'Unknown option: %s\n' "${1}" >&2
        release_notes_usage >&2
        return 1
        ;;
    esac
  done

  if [[ -z "${target_input}" ]]; then
    printf '--target is required.\n' >&2
    release_notes_usage >&2
    return 1
  fi

  if [[ -z "${from_env}" && -z "${from_ref}" ]]; then
    printf 'Either --from-env or --from is required.\n' >&2
    release_notes_usage >&2
    return 1
  fi

  require_program git
  require_program jq
  require_program curl
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
  local jira_project_key
  local start_ref_raw
  local target_resolution
  local target_kind
  local target_value
  local target_payload=""
  local ambiguous_payload=""
  local from_norm
  local to_norm
  local git_range
  local commit_count
  local compare_url=""
  local from_compare_ref
  local to_compare_ref
  local -a issue_keys=()
  local issues_json='{"issues":[]}'
  local release_issues_json=""
  local jira_base_url_value=""

  repo_path="$(project_repo_path "${project_id}")"
  jira_project_key="$(project_jira_project_key "${project_id}")"
  jira_base_url_value="$(jira_base_url "${project_id}")"

  if [[ -z "${repo_path}" || ! -d "${repo_path}" ]]; then
    printf 'Project repo path does not exist: %s\n' "${repo_path}" >&2
    return 1
  fi

  start_ref_raw="$(release_notes_resolve_start_ref "${project_id}" "${from_env}" "${from_ref}")"
  target_resolution="$(release_notes_resolve_target "${repo_path}" "${jira_base_url_value}" "${jira_project_key}" "${target_input}")"
  IFS='|' read -r target_kind target_payload <<< "${target_resolution}"

  if [[ "${target_kind}" == "ambiguous" ]]; then
    ambiguous_payload="$(printf '%s\n' "${target_payload}" | jq -r '.')"
    render_release_notes_target_candidates "${target_input}" "${ambiguous_payload}"
    return 1
  fi
  target_value="${target_payload}"

  from_norm="$(compare_normalize_version "${repo_path}" "${start_ref_raw}" | tr -d '\n')"
  to_norm="$(compare_normalize_version "${repo_path}" "${target_value}" | tr -d '\n')"

  git_range="${from_norm}..${to_norm}"
  commit_count="$(compare_commit_count "${repo_path}" "${git_range}")"
  from_compare_ref="refs/tags/${from_norm}"
  to_compare_ref="$(release_notes_compare_ref "${repo_path}" "${target_value}")"
  compare_url="$(compare_url_for_project "${project_id}" "${repo_path}" "${from_compare_ref}" "${to_compare_ref}" || true)"

  build_release_notes_buckets "${repo_path}" "${git_range}" "${project_id}"
  if [[ -n "${RELEASE_NOTES_ISSUE_KEYS}" && -n "${jira_base_url_value}" ]]; then
    mapfile -t issue_keys < <(printf '%s\n' "${RELEASE_NOTES_ISSUE_KEYS}" | sed '/^$/d')
    issues_json="$(fetch_jira_issues_by_keys "${jira_base_url_value}" "${issue_keys[@]}")"
  fi

  if [[ "${target_kind}" == "release" ]]; then
    release_issues_json="$(fetch_jira_issues_for_release "${jira_base_url_value}" "${jira_project_key}" "${target_value}")"
  fi

  render_release_notes_summary "${project_id}" "${repo_path}" "${from_norm}" "${to_norm}" "${commit_count}" "${compare_url}" "${issues_json}" "${target_value:-}" "${release_issues_json}"
}
