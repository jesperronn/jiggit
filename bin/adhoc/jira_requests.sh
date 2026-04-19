#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "${SCRIPT_DIR}/_jira_variables.sh" ]]; then
  printf 'Missing local config file: %s\n' "${SCRIPT_DIR}/_jira_variables.sh" >&2
  printf 'Create it by copying %s\n' "${SCRIPT_DIR}/_jira_variables.sh.example" >&2
  exit 1
fi

# Load local Jira variables for manual testing.
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_jira_variables.sh"

# Default to a real run that stops at the first failure.
JIRA_REQUESTS_DRY_RUN=0
JIRA_REQUESTS_FAIL_FAST=1
JIRA_REQUESTS_RAW_OUTPUT=0
JIRA_REQUESTS_SHORT_OUTPUT=0
JIRA_REQUESTS_ISSUE_LIMIT=10

# Hardcoded Jira examples for adhoc manual probes.
readonly JIRA_EXAMPLE_ISSUE_KEY="SKOLELOGIN-13603"
readonly JIRA_EXAMPLE_RELEASE_NAME="Api-server_1.2.0"

# Fail fast when a required external program is missing.
require_program() {
  local program="${1}"

  if ! command -v "${program}" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "${program}" >&2
    return 1
  fi
}

# URL-encode a query string for Jira search requests.
url_encode() {
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

# Return the Authorization header when PAT auth is configured.
jira_auth_header() {
  if [[ -n "${JIRA_API_TOKEN:-}" ]]; then
    printf '%s\n' "Authorization: Bearer ${JIRA_API_TOKEN}"
    return 0
  fi

  printf 'Set JIRA_API_TOKEN in _jira_variables.sh\n' >&2
  return 1
}

# Render a redacted curl command for dry-run output.
print_dry_run_curl_command() {
  local url="${1}"
  printf "curl --silent --show-error --fail -H 'Authorization: Bearer \$JIRA_API_TOKEN' -H 'Accept: application/json' %q\n" "${url}"
}

# Run a Jira GET request against a fully qualified URL.
run_get_request() {
  local url="${1}"
  local auth_header=""

  if [[ "${JIRA_REQUESTS_DRY_RUN}" -eq 1 ]]; then
    print_dry_run_curl_command "${url}"
    return 0
  fi

  require_program curl
  auth_header="$(jira_auth_header)"
  curl --silent --show-error --fail \
    -H "${auth_header}" \
    -H "Accept: application/json" \
    "${url}"
}

# Print a standard next-step suggestion block for the outcome that actually happened.
print_next_steps() {
  local rc="${1}"
  local success_step="${2}"
  local failure_step="${3}"

  printf 'Next steps:\n'
  if [[ "${rc}" -eq 0 && -n "${success_step}" ]]; then
    printf '  %s\n' "${success_step}"
  elif [[ "${rc}" -ne 0 && -n "${failure_step}" ]]; then
    printf '  %s\n' "${failure_step}"
  fi
}

# Run the Jira project metadata probe.
run_project_probe() {
  local base_url="${1}"
  local project_key="${2}"
  run_get_request "${base_url%/}/rest/api/2/project/${project_key}"
}

# Run the Jira release list probe.
run_versions_probe() {
  local base_url="${1}"
  local project_key="${2}"
  run_get_request "${base_url%/}/rest/api/2/project/${project_key}/versions"
}

# Run the Jira current-user probe.
run_myself_probe() {
  local base_url="${1}"
  run_get_request "${base_url%/}/rest/api/2/myself"
}

# Run the Jira releases probe for a project.
run_releases_probe() {
  local base_url="${1}"
  local project_key="${2}"
  run_get_request "${base_url%/}/rest/api/2/project/${project_key}/versions"
}

# Run the Jira issue search probe for a fixed JQL expression.
run_search_probe() {
  local base_url="${1}"
  local project_key="${2}"
  local release_name="${3}"
  local jql="project = \"${project_key}\" AND (fixVersion = \"${release_name}\" OR affectedVersion = \"${release_name}\") ORDER BY key ASC"
  local encoded_jql

  encoded_jql="$(url_encode "${jql}")"
  run_get_request "${base_url%/}/rest/api/2/search?jql=${encoded_jql}&fields=summary,status,labels,fixVersions"
}

# Run a Jira issue lookup probe for a single issue key.
run_issue_probe() {
  local base_url="${1}"
  local issue_key="${2}"

  run_get_request "${base_url%/}/rest/api/2/issue/${issue_key}?fields=summary,status,labels,fixVersions"
}

# Run a Jira open-issue list probe for a project key.
run_issues_list_probe() {
  local base_url="${1}"
  local project_key="${2}"
  local issue_limit="${3}"
  local jql="project = \"${project_key}\" AND statusCategory != Done ORDER BY updated DESC"
  local encoded_jql
  local max_results

  if [[ "${issue_limit}" -eq 0 ]]; then
    max_results=20
  else
    max_results="${issue_limit}"
  fi

  encoded_jql="$(url_encode "${jql}")"
  run_get_request "${base_url%/}/rest/api/2/search?jql=${encoded_jql}&fields=summary,status,labels,fixVersions&maxResults=${max_results}"
}

# Return success when a value looks like a Jira issue key.
is_jira_issue_key() {
  local issue_key="${1}"

  [[ "${issue_key}" =~ ^[A-Z][A-Z0-9]+-[0-9]+$ ]]
}

# Return success when a value looks like a Jira project key.
is_jira_project_key() {
  local project_key="${1}"

  [[ "${project_key}" =~ ^[A-Z][A-Z0-9]+$ ]]
}

# Print an abbreviated payload when the full response is too large for the all probe.
print_excerpt_or_full_output_hint() {
  local output_text="${1}"
  local command_name="${2}"
  local max_chars="${3:-200}"
  local normalized_output

  normalized_output="$(printf '%s' "${output_text}" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
  if (( ${#normalized_output} > max_chars )); then
    printf '%s...\n' "${normalized_output:0:max_chars}"
    printf "Full output, run \`bin/adhoc/jira_requests.sh %s\`\n" "${command_name}"
  else
    printf '%s\n' "${normalized_output}"
  fi
}

# Print a short excerpt without the full-output hint for compact all-mode output.
print_short_output_excerpt() {
  local output_text="${1}"
  local max_chars="${2:-200}"
  local normalized_output

  normalized_output="$(printf '%s' "${output_text}" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
  if (( ${#normalized_output} > max_chars )); then
    printf '%s...\n' "${normalized_output:0:max_chars}"
  else
    printf '%s\n' "${normalized_output}"
  fi
}

# Print only the command to run next after a failed probe.
print_failure_next_step() {
  local failure_step="${1}"

  printf 'Next steps:\n'
  if [[ -n "${failure_step}" ]]; then
    printf '  %s\n' "${failure_step}"
  fi
}

# Run one probe and print next steps for both success and failure cases.
run_probe_step() {
  local success_step="${1}"
  local failure_step="${2}"
  shift 2
  local rc=0

  set +e
  "$@"
  rc=$?
  set -e

  if [[ "${JIRA_REQUESTS_RAW_OUTPUT}" -eq 1 ]]; then
    return "${rc}"
  fi

  print_next_steps "${rc}" "${success_step}" "${failure_step}"
  return "${rc}"
}

# Run one probe, print a shortened excerpt when needed, and still show next steps.
run_probe_step_excerpt() {
  local success_step="${1}"
  local failure_step="${2}"
  local command_name="${3}"
  local excerpt_max_chars="${4:-200}"
  shift 4
  local output=""
  local rc=0

  set +e
  output="$("$@" 2>&1)"
  rc=$?
  set -e

  if [[ "${JIRA_REQUESTS_RAW_OUTPUT}" -eq 1 ]]; then
    printf '%s\n' "${output}"
    return "${rc}"
  fi

  if [[ "${JIRA_REQUESTS_SHORT_OUTPUT}" -eq 1 ]]; then
    print_short_output_excerpt "${output}" "${excerpt_max_chars}"
  else
    print_excerpt_or_full_output_hint "${output}" "${command_name}"
  fi
  print_next_steps "${rc}" "${success_step}" "${failure_step}"
  return "${rc}"
}

# Run one probe in compact all-mode presentation.
run_all_probe_step() {
  local command_line="${1}"
  shift 1
  local output=""
  local rc=0
  local failure_step="${command_line% --short}"

  printf '%s --short\n' "${command_line}"
  set +e
  output="$("$@" 2>&1)"
  rc=$?
  set -e

  print_short_output_excerpt "${output}"
  if [[ "${rc}" -ne 0 ]]; then
    print_failure_next_step "${failure_step}"
  fi
  return "${rc}"
}

# Run the recommended request sequence once.
run_all_probes() {
  local base_url="${1}"
  local project_key="${2}"
  local rc=0
  local overall_rc=0

  if run_all_probe_step \
    "bin/adhoc/jira_requests.sh myself" \
    run_myself_probe "${base_url}"; then
    rc=0
  else
    rc=$?
  fi
  if [[ "${rc}" -ne 0 ]]; then
    overall_rc="${rc}"
  fi
  if [[ "${rc}" -ne 0 ]]; then
    return "${rc}"
  fi
  printf '\n'

  if run_all_probe_step \
    "bin/adhoc/jira_requests.sh project ${project_key}" \
    run_project_probe "${base_url}" "${project_key}"; then
    rc=0
  else
    rc=$?
  fi
  if [[ "${rc}" -ne 0 ]]; then
    overall_rc="${rc}"
  fi
  if [[ "${rc}" -ne 0 && "${JIRA_REQUESTS_FAIL_FAST}" -eq 1 ]]; then
    return "${rc}"
  fi
  printf '\n'

  if run_all_probe_step \
    "bin/adhoc/jira_requests.sh issues ${JIRA_EXAMPLE_ISSUE_KEY}" \
    run_issue_probe "${base_url}" "${JIRA_EXAMPLE_ISSUE_KEY}"; then
    rc=0
  else
    rc=$?
  fi
  if [[ "${rc}" -ne 0 ]]; then
    overall_rc="${rc}"
  fi
  if [[ "${rc}" -ne 0 && "${JIRA_REQUESTS_FAIL_FAST}" -eq 1 ]]; then
    return "${rc}"
  fi
  printf '\n'

  if run_all_probe_step \
    "bin/adhoc/jira_requests.sh search ${project_key} ${JIRA_EXAMPLE_RELEASE_NAME}" \
    run_search_probe "${base_url}" "${project_key}" "${JIRA_EXAMPLE_RELEASE_NAME}"; then
    rc=0
  else
    rc=$?
  fi
  if [[ "${rc}" -ne 0 ]]; then
    overall_rc="${rc}"
  fi
  if [[ "${rc}" -ne 0 && "${JIRA_REQUESTS_FAIL_FAST}" -eq 1 ]]; then
    return "${rc}"
  fi
  printf '\n'

  if run_all_probe_step \
    "bin/adhoc/jira_requests.sh releases ${project_key}" \
    run_releases_probe "${base_url}" "${project_key}"; then
    rc=0
  else
    rc=$?
  fi
  if [[ "${rc}" -ne 0 ]]; then
    overall_rc="${rc}"
  fi
  if [[ "${rc}" -ne 0 && "${JIRA_REQUESTS_FAIL_FAST}" -eq 1 ]]; then
    return "${rc}"
  fi

  return "${overall_rc}"
}

# Print usage for the manual Jira helper.
usage() {
  cat <<'EOF'
Usage:
  jira_requests.sh [--dry-run] [--short] [--fail-fast|--no-fail-fast] all
  jira_requests.sh [--dry-run] [--short] [--fail-fast|--no-fail-fast] myself
  jira_requests.sh [--dry-run] [--short] [--fail-fast|--no-fail-fast] project <project-key>
  jira_requests.sh [--dry-run] [--short] [--fail-fast|--no-fail-fast] versions <project-key>
  jira_requests.sh [--dry-run] [--short] [--fail-fast|--no-fail-fast] issues <project-key|issue-key> [--limit <n>]
  jira_requests.sh [--dry-run] [--short] [--fail-fast|--no-fail-fast] search <project-key> <release-name>
  jira_requests.sh [--dry-run] [--short] [--fail-fast|--no-fail-fast] releases <project-key>
  jira_requests.sh [--dry-run] [--raw] [--short] [--fail-fast|--no-fail-fast] <command> ...

The `all` command runs the recommended sequence once:
  myself -> project -> versions -> issues -> search -> releases

Issue list limits:
  --limit <n>    Limit `issues <project-key>` results. Use 0 for all.

Required local file:
  bin/adhoc/_jira_variables.sh

Expected variables:
  JIRA_BASE_URL
  JIRA_PROJECT_KEY
  JIRA_API_TOKEN

This helper runs requests by default. Use `--dry-run` to print commands only.
EOF
}

# Dispatch a manual Jira probe based on the requested subcommand.
main() {
  local command=""
  local -a command_args=()

  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --dry-run)
        JIRA_REQUESTS_DRY_RUN=1
        shift
        ;;
      --raw)
        JIRA_REQUESTS_RAW_OUTPUT=1
        shift
        ;;
      --short)
        JIRA_REQUESTS_SHORT_OUTPUT=1
        shift
        ;;
      --limit)
        if [[ -z "${2:-}" ]]; then
          printf 'Missing limit value.\n' >&2
          return 1
        fi
        if ! [[ "${2}" =~ ^[0-9]+$ ]]; then
          printf 'Invalid limit value: %s\n' "${2}" >&2
          return 1
        fi
        JIRA_REQUESTS_ISSUE_LIMIT="${2}"
        shift 2
        ;;
      --fail-fast)
        JIRA_REQUESTS_FAIL_FAST=1
        shift
        ;;
      --no-fail-fast)
        JIRA_REQUESTS_FAIL_FAST=0
        shift
        ;;
      -h|--help)
        usage
        return 0
        ;;
      *)
        if [[ -z "${command}" ]]; then
          command="${1}"
        else
          command_args+=("${1}")
        fi
        shift
        ;;
    esac
  done

  if [[ -z "${command}" ]]; then
    usage
    return 1
  fi

  case "${command}" in
    all)
      if run_all_probes "${JIRA_BASE_URL}" "${JIRA_PROJECT_KEY}"; then
        return 0
      else
        local rc=$?
        return "${rc}"
      fi
      ;;
    myself)
      if run_probe_step \
        "bin/adhoc/jira_requests.sh project ${JIRA_PROJECT_KEY} --short" \
        "bin/adhoc/jira_requests.sh myself --short" \
        run_myself_probe "${JIRA_BASE_URL}"; then
        return 0
      else
        local rc=$?
        return "${rc}"
      fi
      ;;
    project)
      if [[ -z "${command_args[0]:-}" ]]; then
        printf 'Missing project key.\n' >&2
        usage >&2
        return 1
      fi
      if [[ "${JIRA_REQUESTS_SHORT_OUTPUT}" -eq 1 ]]; then
        if run_probe_step_excerpt \
          "bin/adhoc/jira_requests.sh versions ${command_args[0]} --short" \
          "bin/adhoc/jira_requests.sh project ${command_args[0]} --short" \
          "project" \
          run_project_probe "${JIRA_BASE_URL}" "${command_args[0]}"; then
          return 0
        else
          local rc=$?
          return "${rc}"
        fi
      fi
      if run_probe_step \
        "bin/adhoc/jira_requests.sh versions ${command_args[0]} --short" \
        "bin/adhoc/jira_requests.sh project ${command_args[0]} --short" \
        run_project_probe "${JIRA_BASE_URL}" "${command_args[0]}"; then
        return 0
      else
        local rc=$?
        return "${rc}"
      fi
      ;;
    versions)
      if [[ -z "${command_args[0]:-}" ]]; then
        printf 'Missing project key.\n' >&2
        usage >&2
        return 1
      fi
      if [[ "${JIRA_REQUESTS_SHORT_OUTPUT}" -eq 1 ]]; then
        if run_probe_step_excerpt \
          "bin/adhoc/jira_requests.sh search ${command_args[0]} ${JIRA_EXAMPLE_RELEASE_NAME} --short" \
          "bin/adhoc/jira_requests.sh versions ${command_args[0]} --short" \
          "versions" \
          "120" \
          run_versions_probe "${JIRA_BASE_URL}" "${command_args[0]}"; then
          return 0
        else
          local rc=$?
          return "${rc}"
        fi
      fi
      if run_probe_step \
        "bin/adhoc/jira_requests.sh search ${command_args[0]} ${JIRA_EXAMPLE_RELEASE_NAME} --short" \
        "bin/adhoc/jira_requests.sh versions ${command_args[0]} --short" \
        run_versions_probe "${JIRA_BASE_URL}" "${command_args[0]}"; then
        return 0
      else
        local rc=$?
        return "${rc}"
      fi
      ;;
    issues)
      if [[ -z "${command_args[0]:-}" ]]; then
        printf 'Missing project key or issue key.\n' >&2
        usage >&2
        return 1
      fi
      if is_jira_issue_key "${command_args[0]}"; then
        if [[ "${JIRA_REQUESTS_SHORT_OUTPUT}" -eq 1 ]]; then
          if run_probe_step_excerpt \
            "bin/adhoc/jira_requests.sh issues ${command_args[0]} --short" \
            "bin/adhoc/jira_requests.sh issues ${command_args[0]} --short" \
            "issues" \
            run_issue_probe "${JIRA_BASE_URL}" "${command_args[0]}"; then
            return 0
          else
            local rc=$?
            return "${rc}"
          fi
        fi
        if run_probe_step \
          "bin/adhoc/jira_requests.sh issues ${command_args[0]} --short" \
          "bin/adhoc/jira_requests.sh issues ${command_args[0]} --short" \
          run_issue_probe "${JIRA_BASE_URL}" "${command_args[0]}"; then
          return 0
        else
          local rc=$?
          return "${rc}"
        fi
      fi
      if ! is_jira_project_key "${command_args[0]}"; then
        printf 'Expected a Jira project key like %s or an issue key like %s-123.\n' "${JIRA_PROJECT_KEY}" "${JIRA_PROJECT_KEY}" >&2
        return 1
      fi
      if [[ "${JIRA_REQUESTS_SHORT_OUTPUT}" -eq 1 ]]; then
        if run_probe_step_excerpt \
          "bin/adhoc/jira_requests.sh issues ${command_args[0]} --short" \
          "bin/adhoc/jira_requests.sh issues ${command_args[0]} --short" \
          "issues" \
          run_issues_list_probe "${JIRA_BASE_URL}" "${command_args[0]}" "${JIRA_REQUESTS_ISSUE_LIMIT}"; then
          return 0
        else
          local rc=$?
          return "${rc}"
        fi
      fi
      if run_probe_step \
        "bin/adhoc/jira_requests.sh issues ${command_args[0]} --short" \
        "bin/adhoc/jira_requests.sh issues ${command_args[0]} --short" \
        run_issues_list_probe "${JIRA_BASE_URL}" "${command_args[0]}" "${JIRA_REQUESTS_ISSUE_LIMIT}"; then
        return 0
      else
        local rc=$?
        return "${rc}"
      fi
      ;;
    search)
      if [[ -z "${command_args[0]:-}" || -z "${command_args[1]:-}" ]]; then
        printf 'Missing project key or release name.\n' >&2
        usage >&2
        return 1
      fi
      if [[ "${JIRA_REQUESTS_SHORT_OUTPUT}" -eq 1 ]]; then
        if run_probe_step_excerpt \
          "bin/adhoc/jira_requests.sh search ${command_args[0]} ${command_args[1]} --short" \
          "bin/adhoc/jira_requests.sh search ${command_args[0]} ${command_args[1]} --short" \
          "search" \
          run_search_probe "${JIRA_BASE_URL}" "${command_args[0]}" "${command_args[1]}"; then
          return 0
        else
          local rc=$?
          return "${rc}"
        fi
      fi
      if run_probe_step \
        "bin/adhoc/jira_requests.sh search ${command_args[0]} ${command_args[1]} --short" \
        "bin/adhoc/jira_requests.sh search ${command_args[0]} ${command_args[1]} --short" \
        run_search_probe "${JIRA_BASE_URL}" "${command_args[0]}" "${command_args[1]}"; then
        return 0
      else
        local rc=$?
        return "${rc}"
      fi
      ;;
    releases)
      if [[ -z "${command_args[0]:-}" ]]; then
        printf 'Missing project key.\n' >&2
        usage >&2
        return 1
      fi
      if [[ "${JIRA_REQUESTS_SHORT_OUTPUT}" -eq 1 ]]; then
        if run_probe_step_excerpt \
          "bin/adhoc/jira_requests.sh releases ${command_args[0]} --short" \
          "bin/adhoc/jira_requests.sh releases ${command_args[0]} --short" \
          "releases" \
          run_releases_probe "${JIRA_BASE_URL}" "${command_args[0]}"; then
          return 0
        else
          local rc=$?
          return "${rc}"
        fi
      fi
      if run_probe_step \
        "bin/adhoc/jira_requests.sh releases ${command_args[0]} --short" \
        "bin/adhoc/jira_requests.sh releases ${command_args[0]} --short" \
        run_releases_probe "${JIRA_BASE_URL}" "${command_args[0]}"; then
        return 0
      else
        local rc=$?
        return "${rc}"
      fi
      ;;
    *)
      usage >&2
      return 1
      ;;
  esac
}

main "$@"
