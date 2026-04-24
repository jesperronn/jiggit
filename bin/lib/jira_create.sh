#!/usr/bin/env bash

set -euo pipefail

if ! declare -F load_project_config >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/explore.sh"
fi

# Fail fast when a required external program is missing.
require_program() {
  local program="${1}"

  if ! command -v "${program}" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "${program}" >&2
    return 1
  fi
}

# Trim leading and trailing blank whitespace while preserving inner formatting.
trim_blank_edges() {
  local value="${1:-}"

  value="${value#"${value%%[!$'\n\r\t ']*}"}"
  value="${value%"${value##*[!$'\n\r\t ']}"}"
  printf '%s\n' "${value}"
}

# Remove a Jira issue key prefix from a commit subject when present.
strip_leading_issue_key() {
  local value="${1:-}"

  printf '%s\n' "${value}" | sed -E "s/^(${JIGGIT_FALLBACK_JIRA_REGEX})[[:space:]:_-]+//"
}

# Read the subject line for a commit reference from a repository.
commit_subject() {
  local repo_path="${1}"
  local commit_ref="${2}"

  git -C "${repo_path}" show -s --format=%s "${commit_ref}"
}

# Read the body text for a commit reference from a repository.
commit_body() {
  local repo_path="${1}"
  local commit_ref="${2}"

  git -C "${repo_path}" show -s --format=%b "${commit_ref}"
}

# Resolve the short hash for a commit reference from a repository.
commit_hash() {
  local repo_path="${1}"
  local commit_ref="${2}"

  git -C "${repo_path}" rev-parse --short "${commit_ref}"
}

# Build a Jira summary from a commit subject, falling back to the original text.
derive_issue_summary() {
  local commit_subject_line="${1:-}"
  local summary

  summary="$(strip_leading_issue_key "${commit_subject_line}")"
  summary="$(trim "${summary}")"

  if [[ -z "${summary}" ]]; then
    summary="${commit_subject_line}"
  fi

  printf '%s\n' "${summary}"
}

# Render a Jira issue description from commit metadata and project context.
build_issue_description() {
  local project_id="${1}"
  local project_name="${2}"
  local commit_ref="${3}"
  local short_hash="${4}"
  local subject_line="${5}"
  local body_text="${6:-}"
  local repo_path="${7}"

  cat <<EOF
Created from commit ${commit_ref} (${short_hash}) in project ${project_name} [${project_id}].

Repository: ${repo_path}
Commit subject: ${subject_line}
EOF

  body_text="$(trim_blank_edges "${body_text}")"
  if [[ -n "${body_text}" ]]; then
    printf '\nCommit body:\n%s\n' "${body_text}"
  fi
}

# Build the curl authentication arguments for the configured Jira auth method.
jira_auth_args() {
  local reference="${1:-}"
  local bearer_token=""
  local user_email=""
  local api_token=""
  local auth_mode_value=""
  local auth_source_value=""
  local jira_name=""

  bearer_token="$(jira_bearer_token "${reference}")"
  user_email="$(jira_user_email "${reference}")"
  api_token="$(jira_api_token "${reference}")"
  auth_mode_value="$(jira_auth_mode "${reference}")"
  jira_name="$(resolve_jira_name "${reference}")"

  if [[ -n "${bearer_token}" ]]; then
    if declare -F jiggit_verbose_log >/dev/null 2>&1; then
      auth_source_value="$(jira_field_source "${reference}" "bearer_token")"
      jiggit_verbose_log "jira auth reference=${reference:-default} jira=${jira_name:-missing} mode=${auth_mode_value} source=${auth_source_value}"
    fi
    printf '%s\n' "-H" "Authorization: Bearer ${bearer_token}"
    return 0
  fi

  if [[ -n "${user_email}" && -n "${api_token}" ]]; then
    if declare -F jiggit_verbose_log >/dev/null 2>&1; then
      auth_source_value="$(jira_field_source "${reference}" "user_email"), $(jira_field_source "${reference}" "api_token")"
      jiggit_verbose_log "jira auth reference=${reference:-default} jira=${jira_name:-missing} mode=${auth_mode_value} source=${auth_source_value}"
    fi
    printf '%s\n' "--user" "${user_email}:${api_token}"
    return 0
  fi

  printf '%s\n' \
    "Missing Jira auth. Configure jira.bearer_token or both jira.user_email and jira.api_token." >&2
  if declare -F render_jira_check_config_summary >/dev/null 2>&1; then
    render_jira_check_config_summary "${reference}" >&2
  fi
  return 1
}

# Construct the JSON payload used to create a Jira issue.
build_jira_issue_payload() {
  local jira_project_key="${1}"
  local issue_type="${2}"
  local summary="${3}"
  local description="${4}"

  jq -n \
    --arg project_key "${jira_project_key}" \
    --arg issue_type "${issue_type}" \
    --arg summary "${summary}" \
    --arg description "${description}" \
    '{
      fields: {
        project: { key: $project_key },
        issuetype: { name: $issue_type },
        summary: $summary,
        description: $description
      }
    }'
}

# Submit the prepared issue payload to Jira and return the API response.
create_jira_issue() {
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
    "${jira_base_url%/}/rest/api/2/issue" \
    --data "${payload}"
}

# Render help for the jira-create command.
jira_create_usage() {
  print_jiggit_usage_block <<'USAGE'
Usage:
  jiggit jira-create [<project|path>] [--commit <git-ref>] [--type <issue-type>] [--summary <text>] [--dry-run]

Config:
  [jira]
  base_url = "https://jira.example.com"
  bearer_token = "token"
  user_email = "user@example.com"
  api_token = "token"
USAGE
}

# Parse options, load project config, derive issue data, and create or preview a Jira issue.
run_jira_create_main() {
  local project_selector=""
  if [[ $# -gt 0 && "${1}" != -* ]]; then
    project_selector="${1}"
    shift || true
  fi

  if [[ "${project_selector}" == "-h" || "${project_selector}" == "--help" ]]; then
    jira_create_usage
    return 0
  fi

  local commit_ref="HEAD"
  local issue_type="Task"
  local summary_override=""
  local dry_run=0

  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --commit)
        commit_ref="${2:-}"
        shift 2
        ;;
      --type)
        issue_type="${2:-}"
        shift 2
        ;;
      --summary)
        summary_override="${2:-}"
        shift 2
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      -h|--help)
        jira_create_usage
        return 0
        ;;
      *)
        printf 'Unknown option: %s\n' "${1}" >&2
        jira_create_usage >&2
        return 1
        ;;
    esac
  done

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
  repo_path="$(project_repo_path "${project_id}")"
  if [[ -z "${repo_path}" ]]; then
    printf 'Project %s is missing a repo path in config.\n' "${project_id}" >&2
    return 1
  fi

  if [[ ! -d "${repo_path}" ]]; then
    printf 'Project repo path does not exist: %s\n' "${repo_path}" >&2
    return 1
  fi

  local jira_project_key
  jira_project_key="$(project_jira_project_key "${project_id}")"
  if [[ -z "${jira_project_key}" ]]; then
    printf 'Project %s is missing a Jira project key in config.\n' "${project_id}" >&2
    return 1
  fi

  local subject_line
  local body_text
  local short_hash
  local summary
  local description
  local payload

  subject_line="$(commit_subject "${repo_path}" "${commit_ref}")"
  body_text="$(commit_body "${repo_path}" "${commit_ref}")"
  short_hash="$(commit_hash "${repo_path}" "${commit_ref}")"
  summary="${summary_override:-$(derive_issue_summary "${subject_line}")}"
  description="$(build_issue_description "${project_id}" "${project_id}" "${commit_ref}" "${short_hash}" "${subject_line}" "${body_text}" "${repo_path}")"
  payload="$(build_jira_issue_payload "${jira_project_key}" "${issue_type}" "${summary}" "${description}")"

  if [[ "${dry_run}" -eq 1 ]]; then
    printf 'Project: %s\n' "${project_id}"
    printf 'Jira project: %s\n' "${jira_project_key}"
    printf 'Commit: %s (%s)\n' "${commit_ref}" "${short_hash}"
    printf 'Summary: %s\n' "${summary}"
    printf 'Issue type: %s\n' "${issue_type}"
    printf '%s\n' "${payload}"
    return 0
  fi

  local jira_base_url_value
  jira_base_url_value="$(jira_base_url "${project_id}")"
  if [[ -z "${jira_base_url_value}" ]]; then
    printf 'Missing Jira base URL. Configure jira.base_url in TOML.\n' >&2
    return 1
  fi

  local response
  response="$(create_jira_issue "${jira_base_url_value}" "${payload}" "${project_id}")"

  local issue_key
  local issue_self
  issue_key="$(printf '%s' "${response}" | jq -r '.key // empty')"
  issue_self="$(printf '%s' "${response}" | jq -r '.self // empty')"

  if [[ -z "${issue_key}" ]]; then
    printf '%s\n' "${response}"
    printf 'Jira did not return an issue key.\n' >&2
    return 1
  fi

  printf 'Created issue %s\n' "${issue_key}"
  if [[ -n "${issue_self}" ]]; then
    printf '%s\n' "${issue_self}"
  fi
}
