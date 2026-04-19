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

if ! declare -F fetch_jira_releases >/dev/null 2>&1 || ! declare -F find_matching_releases >/dev/null 2>&1 || ! declare -F select_latest_registered_release_name >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/releases_command.sh"
fi

if ! declare -F print_markdown_h1 >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/common_output.sh"
fi

# Render help for the jira-issues command.
jira_issues_usage() {
  print_jiggit_usage_block <<'EOF'
Usage:
  jiggit jira-issues [<project|path>] [--release <fixVersion>]

Show Jira issues belonging to a release/fixVersion.
Defaults to the latest registered Jira release when --release is omitted.
EOF
}

# URL-encode a JQL fragment for a GET request.
jira_issues_url_encode() {
  local raw="${1:-}"
  local encoded=""
  local i char

  for ((i = 0; i < ${#raw}; i++)); do
    char="${raw:i:1}"
    case "${char}" in
      [a-zA-Z0-9.~_-])
        encoded+="${char}"
        ;;
      ' ')
        encoded+='%20'
        ;;
      *)
        printf -v char_code '%%%02X' "'${char}"
        encoded+="${char_code}"
        ;;
    esac
  done

  printf '%s\n' "${encoded}"
}

# Build the Jira JQL used to fetch issues for one resolved release name.
build_jira_release_issues_jql() {
  local jira_project_key="${1}"
  local release_name="${2}"

  printf 'project = "%s" AND (fixVersion = "%s" OR affectedVersion = "%s") ORDER BY key ASC\n' \
    "${jira_project_key}" \
    "${release_name}" \
    "${release_name}"
}

# Fetch Jira issues for an exact fixVersion name.
fetch_jira_issues_for_release() {
  local jira_base_url="${1}"
  local jira_project_key="${2}"
  local release_name="${3}"
  local auth_reference="${4:-}"
  local encoded_jql
  local jql
  local -a auth_args=()

  jql="$(build_jira_release_issues_jql "${jira_project_key}" "${release_name}")"
  encoded_jql="$(jira_issues_url_encode "${jql}")"
  if declare -F jiggit_verbose_log >/dev/null 2>&1; then
    jiggit_verbose_log "fetch jira issues project=${jira_project_key} release=${release_name}"
    jiggit_verbose_log "jira jql ${jql}"
  fi
  mapfile -t auth_args < <(jira_auth_args "${auth_reference}")

  curl --silent --show-error --fail \
    "${auth_args[@]}" \
    -H "Accept: application/json" \
    "${jira_base_url%/}/rest/api/2/search?jql=${encoded_jql}&fields=summary,status,labels,fixVersions"
}

# Return the display value for one issue's fixVersion field.
jira_issue_fix_version_display() {
  local issue_json="${1}"

  printf '%s\n' "${issue_json}" | jq -r \
    'if (.fields.fixVersions // []) == [] then "MISSING" else (.fields.fixVersions | map(.name) | join(", ")) end'
}

# Print a compact ambiguity report when several releases match the user query.
render_release_match_candidates() {
  local query="${1}"
  local matches_json="${2}"
  local release_json

  printf 'Multiple Jira releases match "%s":\n' "${query}" >&2
  while IFS= read -r release_json; do
    [[ -z "${release_json}" ]] && continue
    printf -- '- %s\n' "$(printf '%s\n' "${release_json}" | jq -r '.name // "unknown"')" >&2
  done <<< "${matches_json}"
}

# Render the Jira issue report.
render_jira_issues_summary() {
  local project_id="${1}"
  local release_name="${2}"
  local issues_json="${3}"
  local issue_json
  local rendered_any=0

  print_markdown_h1 "jiggit jira-issues"
  printf '\n'
  printf -- "- Project: \`%s\`\n" "${project_id}"
  printf -- "- Release: \`%s\`\n\n" "${release_name}"
  print_markdown_h2 "Issues" "${C_BLUE}"
  printf '\n'

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
    printf '_No Jira issues found for this release._\n'
  fi
}

# Render a failure report with an adjacent investigation or repair command.
render_jira_issues_failure() {
  local project_id="${1}"
  local release_query="${2}"
  local status="${3}"
  local next_step_command="${4}"

  print_markdown_h1 "jiggit jira-issues"
  printf '\n'
  printf -- "- Project: \`%s\`\n" "${project_id}"
  printf -- "- Release query: \`%s\`\n\n" "${release_query}"
  print_markdown_h2 "Issues" "${C_BLUE}"
  printf '\n'
  printf -- "- status: \`%s\`\n" "${status}"
  printf -- "- next step: \`%s\`\n" "${next_step_command}"
}

# Load config, resolve a release by fuzzy name, fetch Jira issues, and render the report.
run_jira_issues_main() {
  local project_selector=""
  if [[ $# -gt 0 && "${1}" != -* ]]; then
    project_selector="${1}"
    shift || true
  fi

  if [[ "${project_selector}" == "-h" || "${project_selector}" == "--help" ]]; then
    jira_issues_usage
    return 0
  fi

  local release_query=""

  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --release)
        release_query="${2:-}"
        shift 2
        ;;
      -h|--help)
        jira_issues_usage
        return 0
        ;;
      *)
        printf 'Unknown option: %s\n' "${1}" >&2
        jira_issues_usage >&2
        return 1
        ;;
    esac
  done

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

  local jira_project_key
  local releases_json
  local matching_releases
  local match_count
  local release_name
  local issues_json
  local jira_base_url_value

  jira_project_key="$(project_jira_project_key "${project_id}")"
  if [[ -z "${jira_project_key}" ]]; then
    render_jira_issues_failure "${project_id}" "${release_query}" "missing jira project key" "jiggit config"
    return 1
  fi

  jira_base_url_value="$(jira_base_url "${project_id}")"
  if [[ -z "${jira_base_url_value}" ]]; then
    render_jira_issues_failure "${project_id}" "${release_query}" "missing jira base url" "jiggit config"
    render_jira_config_diagnostic >&2
    return 1
  fi

  if ! releases_json="$(fetch_jira_releases "${jira_base_url_value}" "${jira_project_key}" 2>/dev/null)"; then
    render_jira_issues_failure "${project_id}" "${release_query}" "unable to fetch releases" "jiggit jira-check ${project_id}"
    return 1
  fi

  if [[ -z "${release_query}" ]]; then
    release_name="$(select_latest_registered_release_name "${releases_json}")"
    if [[ -z "${release_name}" ]]; then
      printf 'No Jira releases are registered for project %s.\n' "${jira_project_key}" >&2
      return 1
    fi

    issues_json="$(fetch_jira_issues_for_release "${jira_base_url_value}" "${jira_project_key}" "${release_name}")"
    render_jira_issues_summary "${project_id}" "${release_name}" "${issues_json}"
    return 0
  fi

  matching_releases="$(find_matching_releases "${releases_json}" "${release_query}")"
  match_count="$(printf '%s\n' "${matching_releases}" | sed '/^$/d' | wc -l | tr -d ' ')"

  if [[ "${match_count}" -eq 0 ]]; then
    printf 'No Jira releases match "%s".\n' "${release_query}" >&2
    return 1
  fi

  if [[ "${match_count}" -gt 1 ]]; then
    render_release_match_candidates "${release_query}" "${matching_releases}"
    return 1
  fi

  release_name="$(printf '%s\n' "${matching_releases}" | jq -r '.name // "unknown"')"
  issues_json="$(fetch_jira_issues_for_release "${jira_base_url_value}" "${jira_project_key}" "${release_name}")"
  render_jira_issues_summary "${project_id}" "${release_name}" "${issues_json}"
}
