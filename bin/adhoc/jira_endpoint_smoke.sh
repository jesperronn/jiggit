#!/usr/bin/env bash

set -euo pipefail

# Shared Jira host copied from the usual TOML config.
readonly JIRA_BASE_URL="https://jira.stil.dk"

# Project key copied from the target project's TOML entry.
readonly JIRA_PROJECT_KEY="SKOLELOGIN"

# Numeric project id needed for POST /version.
readonly JIRA_PROJECT_NUMERIC_ID="10000"

# Example issue key used for issue reads and fixVersion updates.
readonly JIRA_EXAMPLE_ISSUE_KEY="SKOLELOGIN-13603"

# Example release name used for release searches and version creation.
readonly JIRA_EXAMPLE_RELEASE_NAME="Api-server_1.2.0"

# Token ref may be a literal token or a 1Password secret reference.
readonly JIRA_API_TOKEN_REF='op://JIRA_API_TOKEN_NINE_JRJ'

# Timeout values keep probes fast when Jira is unavailable.
readonly JIRA_CONNECT_TIMEOUT_SECONDS=2
readonly JIRA_MAX_TIME_SECONDS=10

JIRA_SMOKE_DRY_RUN=0
JIRA_SMOKE_VERBOSE=0

# Fail fast when a required external program is missing.
require_program() {
  local program="${1}"

  if ! command -v "${program}" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "${program}" >&2
    return 1
  fi
}

# Print a verbose message when verbose mode is enabled.
verbose_log() {
  local message="${1}"

  if [[ "${JIRA_SMOKE_VERBOSE}" -eq 1 ]]; then
    printf '[verbose] %s\n' "${message}" >&2
  fi
}

# URL-encode one string for JQL search requests.
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
        printf -v char '%%%02X' "'${char}"
        encoded+="${char}"
        ;;
    esac
  done

  printf '%s\n' "${encoded}"
}

# Resolve a literal token or a 1Password op:// reference.
resolve_secret() {
  local value="${1:-}"
  local item_name=""
  local item_id=""
  local output=""
  local stderr_file=""

  if [[ "${value}" == op://* ]]; then
    verbose_log "resolve secret via 1Password reference ${value}"
    require_program op
    stderr_file="$(mktemp "${TMPDIR:-/tmp}/jiggit-jira-smoke-op.XXXXXX")"
    if output="$(op read "${value}" 2>"${stderr_file}")"; then
      rm -f "${stderr_file}"
      verbose_log "resolved secret via op read"
      printf '%s\n' "${output}"
      return 0
    fi
    if [[ -s "${stderr_file}" ]]; then
      verbose_log "op read error: $(tr '\n' ' ' < "${stderr_file}" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
    fi

    item_name="${value#op://}"
    if [[ "${item_name}" != *"/"* ]]; then
      verbose_log "op read failed; trying item title lookup for ${item_name}"
      require_program jq
      if item_id="$(op item list --format json 2>"${stderr_file}" | jq -r --arg name "${item_name}" '.[] | select(.title == $name) | .id' | head -n 1)"; then
        if [[ -n "${item_id}" ]]; then
          verbose_log "resolved matching 1Password item id ${item_id}"
          if output="$(op item get "${item_id}" --fields token 2>"${stderr_file}")"; then
            rm -f "${stderr_file}"
            if [[ -n "${output}" ]]; then
              verbose_log "resolved secret via item token field"
              printf '%s\n' "${output}"
              return 0
            fi
          fi
          if [[ -s "${stderr_file}" ]]; then
            verbose_log "op item get error: $(tr '\n' ' ' < "${stderr_file}" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
          fi
        fi
      elif [[ -s "${stderr_file}" ]]; then
        verbose_log "op item list error: $(tr '\n' ' ' < "${stderr_file}" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
      fi
    fi

    rm -f "${stderr_file}"
    verbose_log "failed to resolve secret reference ${value}"
    printf 'Unable to resolve 1Password secret reference: %s\n' "${value}" >&2
    return 1
  fi

  verbose_log "using literal Jira token value"
  printf '%s\n' "${value}"
}

# Build the Authorization header from the configured token reference.
jira_auth_header() {
  local token=""

  token="$(resolve_secret "${JIRA_API_TOKEN_REF}")"
  if [[ -z "${token}" ]]; then
    printf 'Resolved Jira token is empty.\n' >&2
    return 1
  fi

  printf 'Authorization: Bearer %s\n' "${token}"
}

# Print a redacted curl example without resolving secrets.
print_dry_run_command() {
  local method="${1}"
  local url="${2}"
  local data="${3:-}"

  printf "curl --silent --show-error --fail --connect-timeout %s --max-time %s -X %s -H 'Authorization: Bearer <redacted>' -H 'Accept: application/json'" \
    "${JIRA_CONNECT_TIMEOUT_SECONDS}" \
    "${JIRA_MAX_TIME_SECONDS}" \
    "${method}"

  if [[ -n "${data}" ]]; then
    printf " -H 'Content-Type: application/json' --data %q" "${data}"
  fi

  printf ' %q\n' "${url}"
}

# Execute one Jira request or print it in dry-run mode.
run_request() {
  local method="${1}"
  local url="${2}"
  local data="${3:-}"
  local auth_header=""

  if [[ "${JIRA_SMOKE_DRY_RUN}" -eq 1 ]]; then
    print_dry_run_command "${method}" "${url}" "${data}"
    return 0
  fi

  require_program curl
  auth_header="$(jira_auth_header)"

  if [[ -n "${data}" ]]; then
    curl --silent --show-error --fail \
      --connect-timeout "${JIRA_CONNECT_TIMEOUT_SECONDS}" \
      --max-time "${JIRA_MAX_TIME_SECONDS}" \
      -X "${method}" \
      -H "${auth_header}" \
      -H "Accept: application/json" \
      -H "Content-Type: application/json" \
      "${url}" \
      --data "${data}"
    return 0
  fi

  curl --silent --show-error --fail \
    --connect-timeout "${JIRA_CONNECT_TIMEOUT_SECONDS}" \
    --max-time "${JIRA_MAX_TIME_SECONDS}" \
    -X "${method}" \
    -H "${auth_header}" \
    -H "Accept: application/json" \
    "${url}"
}

# Build the exact release search JQL used across jiggit commands.
build_release_search_jql() {
  printf 'project = "%s" AND (fixVersion = "%s" OR affectedVersion = "%s") ORDER BY key ASC\n' \
    "${JIRA_PROJECT_KEY}" \
    "${JIRA_EXAMPLE_RELEASE_NAME}" \
    "${JIRA_EXAMPLE_RELEASE_NAME}"
}

# Build the open-issues JQL used by the ad hoc probe flow.
build_open_issues_jql() {
  printf 'project = "%s" AND statusCategory != Done ORDER BY updated DESC\n' \
    "${JIRA_PROJECT_KEY}"
}

# Build the create-issue payload for POST /issue examples.
build_create_issue_payload() {
  printf '%s\n' \
    "{\"fields\":{\"project\":{\"key\":\"${JIRA_PROJECT_KEY}\"},\"issuetype\":{\"name\":\"Task\"},\"summary\":\"Example summary\",\"description\":\"Example description\"}}"
}

# Build the fixVersion update payload for PUT /issue/{key}.
build_fix_version_payload() {
  printf '%s\n' \
    "{\"update\":{\"fixVersions\":[{\"add\":{\"name\":\"${JIRA_EXAMPLE_RELEASE_NAME}\"}}]}}"
}

# Build the create-version payload for POST /version.
build_create_version_payload() {
  printf '%s\n' \
    "{\"projectId\":${JIRA_PROJECT_NUMERIC_ID},\"name\":\"${JIRA_EXAMPLE_RELEASE_NAME}\",\"archived\":false,\"released\":false}"
}

# Run GET /myself.
cmd_myself() {
  run_request "GET" "${JIRA_BASE_URL%/}/rest/api/2/myself"
}

# Run GET /project/{key}.
cmd_project() {
  run_request "GET" "${JIRA_BASE_URL%/}/rest/api/2/project/${JIRA_PROJECT_KEY}"
}

# Run GET /project/{key}/versions.
cmd_versions() {
  run_request "GET" "${JIRA_BASE_URL%/}/rest/api/2/project/${JIRA_PROJECT_KEY}/versions"
}

# Run GET /issue/{key}.
cmd_issue() {
  run_request "GET" "${JIRA_BASE_URL%/}/rest/api/2/issue/${JIRA_EXAMPLE_ISSUE_KEY}?fields=summary,status,labels,fixVersions"
}

# Run release-oriented GET /search.
cmd_search_release() {
  local encoded_jql=""

  encoded_jql="$(url_encode "$(build_release_search_jql)")"
  run_request "GET" "${JIRA_BASE_URL%/}/rest/api/2/search?jql=${encoded_jql}&fields=summary,status,labels,fixVersions"
}

# Run open-issues GET /search.
cmd_search_open() {
  local encoded_jql=""

  encoded_jql="$(url_encode "$(build_open_issues_jql)")"
  run_request "GET" "${JIRA_BASE_URL%/}/rest/api/2/search?jql=${encoded_jql}&fields=summary,status,labels,fixVersions&maxResults=10"
}

# Run POST /issue.
cmd_create_issue() {
  run_request "POST" "${JIRA_BASE_URL%/}/rest/api/2/issue" "$(build_create_issue_payload)"
}

# Run PUT /issue/{key}.
cmd_update_fix_version() {
  run_request "PUT" "${JIRA_BASE_URL%/}/rest/api/2/issue/${JIRA_EXAMPLE_ISSUE_KEY}" "$(build_fix_version_payload)"
}

# Run POST /version.
cmd_create_version() {
  run_request "POST" "${JIRA_BASE_URL%/}/rest/api/2/version" "$(build_create_version_payload)"
}

# Run every endpoint once in a practical read-then-write order.
cmd_all() {
  cmd_myself
  printf '\n'
  cmd_project
  printf '\n'
  cmd_versions
  printf '\n'
  cmd_issue
  printf '\n'
  cmd_search_release
  printf '\n'
  cmd_search_open
  printf '\n'
  cmd_create_issue
  printf '\n'
  cmd_update_fix_version
  printf '\n'
  cmd_create_version
}

# Print CLI usage for the standalone Jira smoke script.
usage() {
  cat <<'EOF'
Usage:
  jira_endpoint_smoke.sh [--dry-run] all
  jira_endpoint_smoke.sh [--dry-run] myself
  jira_endpoint_smoke.sh [--dry-run] project
  jira_endpoint_smoke.sh [--dry-run] versions
  jira_endpoint_smoke.sh [--dry-run] issue
  jira_endpoint_smoke.sh [--dry-run] search-release
  jira_endpoint_smoke.sh [--dry-run] search-open
  jira_endpoint_smoke.sh [--dry-run] create-issue
  jira_endpoint_smoke.sh [--dry-run] update-fix-version
  jira_endpoint_smoke.sh [--dry-run] create-version

This script is self-contained and supports literal tokens or op:// 1Password refs.
EOF
}

# Parse flags and dispatch to one standalone Jira endpoint probe.
main() {
  local command=""

  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --dry-run)
        JIRA_SMOKE_DRY_RUN=1
        shift
        ;;
      --verbose)
        JIRA_SMOKE_VERBOSE=1
        shift
        ;;
      -h|--help)
        command="${1}"
        shift
        ;;
      *)
        if [[ -z "${command}" ]]; then
          command="${1}"
        fi
        shift
        ;;
    esac
  done

  case "${command}" in
    all) cmd_all ;;
    myself) cmd_myself ;;
    project) cmd_project ;;
    versions) cmd_versions ;;
    issue) cmd_issue ;;
    search-release) cmd_search_release ;;
    search-open) cmd_search_open ;;
    create-issue) cmd_create_issue ;;
    update-fix-version) cmd_update_fix_version ;;
    create-version) cmd_create_version ;;
    -h|--help|"")
      usage
      [[ "${command}" == -h || "${command}" == --help ]]
      ;;
    *)
      printf 'Unknown command: %s\n' "${command}" >&2
      usage >&2
      return 1
      ;;
  esac
}

main "$@"
