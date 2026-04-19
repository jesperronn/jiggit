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

if ! declare -F print_markdown_h1 >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/common_output.sh"
fi

# Render help for the releases command.
releases_usage() {
  print_jiggit_usage_block <<'EOF'
Usage:
  jiggit releases [<project|path>]

List Jira releases/fixVersions for the configured Jira project.
EOF
}

# Fetch Jira releases for a project key.
fetch_jira_releases() {
  local jira_base_url="${1}"
  local jira_project_key="${2}"
  local auth_reference="${3:-}"
  local -a auth_args=()
  local jira_name=""
  local auth_mode_value=""
  local auth_source_value=""

  if declare -F jiggit_verbose_log >/dev/null 2>&1; then
    jira_name="$(resolve_jira_name "${auth_reference}")"
    auth_mode_value="$(jira_auth_mode "${auth_reference}")"
    if [[ "${auth_mode_value}" == "bearer_token" ]]; then
      auth_source_value="$(jira_field_source "${auth_reference}" "bearer_token")"
    elif [[ "${auth_mode_value}" == "basic_auth" ]]; then
      auth_source_value="$(jira_field_source "${auth_reference}" "user_email"), $(jira_field_source "${auth_reference}" "api_token")"
    else
      auth_source_value="none"
    fi
    jiggit_verbose_log "fetch jira releases project=${jira_project_key} jira=${jira_name:-missing} auth=${auth_mode_value} auth-source=${auth_source_value} url=${jira_base_url%/}/rest/api/2/project/${jira_project_key}/versions"
  fi

  mapfile -t auth_args < <(jira_auth_args "${auth_reference}")

  curl --silent --show-error --fail \
    --connect-timeout 2 \
    "${auth_args[@]}" \
    -H "Accept: application/json" \
    "${jira_base_url%/}/rest/api/2/project/${jira_project_key}/versions"
}

# Normalize text for simple case-insensitive fuzzy matching.
lowercase_text() {
  local value="${1:-}"
  printf '%s\n' "${value}" | tr '[:upper:]' '[:lower:]'
}

# Return release JSON objects whose names fuzzy-match the query text.
find_matching_releases() {
  local releases_json="${1}"
  local query="${2}"
  local lowered_query

  lowered_query="$(lowercase_text "${query}")"
  printf '%s\n' "${releases_json}" \
    | jq -c '.[]' \
    | while IFS= read -r release_json; do
        local release_name
        release_name="$(printf '%s\n' "${release_json}" | jq -r '.name // ""')"
        if [[ "$(lowercase_text "${release_name}")" == *"${lowered_query}"* ]]; then
          printf '%s\n' "${release_json}"
        fi
      done
}

# Return one best-default Jira release JSON object from a versions payload.
select_latest_registered_release() {
  local releases_json="${1}"

  printf '%s\n' "${releases_json}" | jq -c '
    def latest_by_date_and_name:
      sort_by((.releaseDate // ""), (.name // "")) | last;

    def active_releases:
      map(select((.archived // false) != true));

    def unreleased_active_releases:
      active_releases | map(select((.released // false) != true));

    if (unreleased_active_releases | length) > 0 then
      unreleased_active_releases | latest_by_date_and_name
    elif (active_releases | length) > 0 then
      active_releases | latest_by_date_and_name
    elif length > 0 then
      latest_by_date_and_name
    else
      empty
    end
  '
}

# Return the default Jira release name from a versions payload.
select_latest_registered_release_name() {
  local releases_json="${1}"

  select_latest_registered_release "${releases_json}" | jq -r '.name // empty'
}

# Return success when one Jira release belongs to the current project namespace.
release_belongs_to_project() {
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

# Return only Jira releases relevant to the current project namespace.
project_scoped_releases_json() {
  local project_id="${1}"
  local releases_json="${2}"
  local release_json=""
  local release_name=""
  local filtered_json="[]"

  while IFS= read -r release_json; do
    [[ -z "${release_json}" ]] && continue
    release_name="$(printf '%s\n' "${release_json}" | jq -r '.name // empty')"
    if release_belongs_to_project "${project_id}" "${release_name}"; then
      filtered_json="$(printf '%s\n%s\n' "${filtered_json}" "${release_json}" | jq -s '.[0] + [.[1]]')"
    fi
  done < <(printf '%s\n' "${releases_json}" | jq -c '.[]?')

  printf '%s\n' "${filtered_json}"
}

# Return only latest released plus all unreleased active Jira releases for a project.
relevant_releases_json() {
  local project_id="${1}"
  local releases_json="${2}"
  local scoped_json=""
  local unreleased_json=""
  local latest_released_json=""

  scoped_json="$(project_scoped_releases_json "${project_id}" "${releases_json}")"
  unreleased_json="$(printf '%s\n' "${scoped_json}" | jq -c '
    map(select((.archived // false) != true and (.released // false) != true))
  ')"
  latest_released_json="$(printf '%s\n' "${scoped_json}" | jq -c '
    map(select((.archived // false) != true and (.released // false) == true))
    | sort_by((.releaseDate // ""), (.name // ""))
    | last // empty
  ')"

  if [[ -n "${latest_released_json}" ]]; then
    printf '%s\n%s\n' "${unreleased_json}" "${latest_released_json}" | jq -s '.[0] + [.[1]]'
    return 0
  fi

  printf '%s\n' "${unreleased_json}"
}

# Return success when a Jira release name appears to match a local git tag.
release_matches_git_tag() {
  local repo_path="${1}"
  local release_name="${2}"
  local normalized_name="${release_name}"

  if [[ -z "${repo_path}" || ! -d "${repo_path}" ]]; then
    return 1
  fi

  while [[ "${normalized_name:0:1}" == "v" || "${normalized_name:0:1}" == "V" ]]; do
    normalized_name="${normalized_name:1}"
  done

  if git -C "${repo_path}" rev-parse --verify --quiet "refs/tags/${release_name}" >/dev/null 2>&1; then
    return 0
  fi

  if git -C "${repo_path}" rev-parse --verify --quiet "refs/tags/v${normalized_name}" >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

# Render one Jira release entry in the Markdown report.
render_release_entry() {
  local repo_path="${1}"
  local release_json="${2}"
  local name
  local released
  local archived
  local release_date
  local issue_count
  local tag_hint="no"

  name="$(printf '%s\n' "${release_json}" | jq -r '.name // "unknown"')"
  released="$(printf '%s\n' "${release_json}" | jq -r '.released // false')"
  archived="$(printf '%s\n' "${release_json}" | jq -r '.archived // false')"
  release_date="$(printf '%s\n' "${release_json}" | jq -r '.releaseDate // "unknown"')"
  issue_count="$(printf '%s\n' "${release_json}" | jq -r 'if .issuesStatusForFixVersion then ((.issuesStatusForFixVersion.toDo // 0) + (.issuesStatusForFixVersion.inProgress // 0) + (.issuesStatusForFixVersion.done // 0)) else "unknown" end')"

  if release_matches_git_tag "${repo_path}" "${name}"; then
    tag_hint="yes"
  fi

  printf -- "- \`%s\`\n" "${name}"
  printf "  - released: \`%s\`\n" "${released}"
  printf "  - archived: \`%s\`\n" "${archived}"
  printf "  - release date: \`%s\`\n" "${release_date}"
  printf "  - issue count: \`%s\`\n" "${issue_count}"
  printf "  - matches git tag: \`%s\`\n" "${tag_hint}"
}

# Render the releases report from Jira JSON.
render_releases_summary() {
  local project_id="${1}"
  local repo_path="${2}"
  local releases_json="${3}"
  local next_step_command="${4:-}"
  local release_json
  local rendered_any=0

  print_markdown_h1 "jiggit releases"
  printf '\n'
  printf -- "- Project: \`%s\`\n" "${project_id}"
  printf -- "- Repo path: \`%s\`\n\n" "${repo_path:-missing}"
  print_markdown_h2 "Releases" "${C_BLUE}"
  printf '\n'

  while IFS= read -r release_json; do
    [[ -z "${release_json}" ]] && continue
    render_release_entry "${repo_path}" "${release_json}"
    rendered_any=1
  done < <(
    printf '%s\n' "${releases_json}" \
      | jq -c 'sort_by((.released // false), (.archived // false), (.releaseDate // ""), (.name // "")) | reverse[]'
  )

  if [[ ${rendered_any} -eq 0 ]]; then
    printf '_No Jira releases found._\n'
  fi

  if [[ -n "${next_step_command}" ]]; then
    printf '\n'
    printf -- "- next step: \`%s\`\n" "${next_step_command}"
  fi
}

# Render a failure report with an adjacent investigation or repair command.
render_releases_failure() {
  local project_id="${1}"
  local repo_path="${2}"
  local status="${3}"
  local next_step_command="${4}"

  print_markdown_h1 "jiggit releases"
  printf '\n'
  printf -- "- Project: \`%s\`\n" "${project_id}"
  printf -- "- Repo path: \`%s\`\n\n" "${repo_path:-missing}"
  print_markdown_h2 "Releases" "${C_BLUE}"
  printf '\n'
  printf -- "- status: \`%s\`\n" "${status}"
  printf -- "- next step: \`%s\`\n" "${next_step_command}"
}

# Load config, fetch Jira releases, and render the report.
run_releases_main() {
  local project_selector=""
  if [[ $# -gt 0 && "${1}" != -* ]]; then
    project_selector="${1}"
    shift || true
  fi

  if [[ "${project_selector}" == "-h" || "${project_selector}" == "--help" ]]; then
    releases_usage
    return 0
  fi

  if [[ $# -gt 0 ]]; then
    printf 'Unknown option: %s\n' "${1}" >&2
    releases_usage >&2
    return 1
  fi

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
  local repo_path
  local releases_json
  local relevant_json
  local latest_release_name=""
  local jira_base_url_value

  jira_project_key="$(project_jira_project_key "${project_id}")"
  repo_path="$(project_repo_path "${project_id}")"

  if [[ -z "${jira_project_key}" ]]; then
    render_releases_failure "${project_id}" "${repo_path}" "missing jira project key" "jiggit config"
    return 1
  fi

  jira_base_url_value="$(jira_base_url "${project_id}")"
  if [[ -z "${jira_base_url_value}" ]]; then
    render_releases_failure "${project_id}" "${repo_path}" "missing jira base url" "jiggit config"
    return 1
  fi

  if ! releases_json="$(fetch_jira_releases "${jira_base_url_value}" "${jira_project_key}" "${project_id}" 2>/dev/null)"; then
    render_releases_failure "${project_id}" "${repo_path}" "unable to fetch releases" "jiggit jira-check ${project_id}"
    return 1
  fi

  relevant_json="$(relevant_releases_json "${project_id}" "${releases_json}")"
  latest_release_name="$(select_latest_registered_release_name "${relevant_json}")"
  if [[ -n "${latest_release_name}" ]]; then
    render_releases_summary "${project_id}" "${repo_path}" "${relevant_json}" "jiggit jira-issues ${project_id} --release ${latest_release_name}"
  else
    render_releases_summary "${project_id}" "${repo_path}" "${relevant_json}" "jiggit next-release ${project_id}"
  fi
}
