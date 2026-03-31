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

# Return success when PAT auth is configured.
jira_auth_args() {
  if [[ -n "${JIRA_API_TOKEN:-}" ]]; then
    printf '%s\n' -H "Authorization: Bearer ${JIRA_API_TOKEN}"
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
  local -a auth_args=()

  if [[ "${JIRA_REQUESTS_DRY_RUN}" -eq 1 ]]; then
    print_dry_run_curl_command "${url}"
    return 0
  fi

  require_program curl
  mapfile -t auth_args < <(jira_auth_args)
  curl --silent --show-error --fail \
    "${auth_args[@]}" \
    -H "Accept: application/json" \
    "${url}"
}

# Print a standard next-step suggestion block.
print_next_steps() {
  local success_step="${1}"
  local failure_step="${2}"

  printf 'Next steps:\n'
  if [[ -n "${success_step}" ]]; then
    printf '  if successful: %s\n' "${success_step}"
  fi
  if [[ -n "${failure_step}" ]]; then
    printf '  if failing: %s\n' "${failure_step}"
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

# Run the Jira issue search probe for a fixed JQL expression.
run_search_probe() {
  local base_url="${1}"
  local project_key="${2}"
  local release_name="${3}"
  local jql="project = \"${project_key}\" AND fixVersion = \"${release_name}\" ORDER BY key ASC"
  local encoded_jql

  encoded_jql="$(url_encode "${jql}")"
  run_get_request "${base_url%/}/rest/api/2/search?jql=${encoded_jql}&fields=summary,status,labels,fixVersions"
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

  print_next_steps "${success_step}" "${failure_step}"
  return "${rc}"
}

# Run the recommended request sequence once.
run_all_probes() {
  local base_url="${1}"
  local project_key="${2}"
  local rc=0
  local overall_rc=0

  if run_probe_step \
    "bin/adhoc/jira_requests.sh project ${project_key}" \
    "refresh PAT and rerun myself" \
    run_myself_probe "${base_url}"; then
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

  if run_probe_step \
    "bin/adhoc/jira_requests.sh versions ${project_key}" \
    "check project key and permissions" \
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

  if run_probe_step \
    "run a search once you know a release name" \
    "check project key and permissions" \
    run_versions_probe "${base_url}" "${project_key}"; then
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
  jira_requests.sh [--dry-run] [--fail-fast|--no-fail-fast] all
  jira_requests.sh [--dry-run] [--fail-fast|--no-fail-fast] myself
  jira_requests.sh [--dry-run] [--fail-fast|--no-fail-fast] project <project-key>
  jira_requests.sh [--dry-run] [--fail-fast|--no-fail-fast] versions <project-key>
  jira_requests.sh [--dry-run] [--fail-fast|--no-fail-fast] search <project-key> <release-name>

The `all` command runs the recommended sequence once:
  myself -> project -> versions

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

  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --dry-run)
        JIRA_REQUESTS_DRY_RUN=1
        shift
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
        command="${1}"
        shift
        break
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
        "bin/adhoc/jira_requests.sh project ${JIRA_PROJECT_KEY}" \
        "refresh PAT and rerun myself" \
        run_myself_probe "${JIRA_BASE_URL}"; then
        return 0
      else
        local rc=$?
        return "${rc}"
      fi
      ;;
    project)
      if [[ -z "${1:-}" ]]; then
        printf 'Missing project key.\n' >&2
        usage >&2
        return 1
      fi
      if run_probe_step \
        "bin/adhoc/jira_requests.sh versions ${1}" \
        "check project key and permissions" \
        run_project_probe "${JIRA_BASE_URL}" "${1}"; then
        return 0
      else
        local rc=$?
        return "${rc}"
      fi
      ;;
    versions)
      if [[ -z "${1:-}" ]]; then
        printf 'Missing project key.\n' >&2
        usage >&2
        return 1
      fi
      if run_probe_step \
        "run a search once you know a release name" \
        "check project key and permissions" \
        run_versions_probe "${JIRA_BASE_URL}" "${1}"; then
        return 0
      else
        local rc=$?
        return "${rc}"
      fi
      ;;
    search)
      if [[ -z "${1:-}" || -z "${2:-}" ]]; then
        printf 'Missing project key or release name.\n' >&2
        usage >&2
        return 1
      fi
      if run_probe_step \
        "inspect the release name and rerun search" \
        "check project key and permissions" \
        run_search_probe "${JIRA_BASE_URL}" "${1}" "${2}"; then
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
