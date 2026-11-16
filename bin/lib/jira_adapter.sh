#!/usr/bin/env bash

# Select one Jira read adapter for this invocation, after normal helpers load.
jiggit_select_jira_adapter() {
  local adapter="${JIGGIT_JIRA_ADAPTER:-legacy}"
  case "${adapter}" in
    legacy)
      return 0
      ;;
    jira-connect)
      if [[ "${JIRA_CONNECT_BIN:-}" != /* || ! -f "${JIRA_CONNECT_BIN}" || ! -x "${JIRA_CONNECT_BIN}" ]]; then
        printf 'jiggit: set JIRA_CONNECT_BIN to an absolute executable jira-connect path.\n' >&2
        return 1
      fi
      if [[ -z "${JIRA_CONNECT_BRIDGE_PATH:-}" || ! -f "${JIRA_CONNECT_BRIDGE_PATH}" || ! -r "${JIRA_CONNECT_BRIDGE_PATH}" ]]; then
        printf 'jiggit: set JIRA_CONNECT_BRIDGE_PATH to a readable bridges/jiggit.sh path.\n' >&2
        return 1
      fi
      # Child reads need the same explicit executable selected by the caller.
      export JIRA_CONNECT_BIN
      unset -f jiggit_bridge_read
      # shellcheck disable=SC1090
      if ! source "${JIRA_CONNECT_BRIDGE_PATH}"; then
        printf 'jiggit: unable to load JIRA_CONNECT_BRIDGE_PATH.\n' >&2
        return 1
      fi
      if ! declare -F jiggit_bridge_read >/dev/null 2>&1; then
        printf 'jiggit: JIRA_CONNECT_BRIDGE_PATH must provide the jira-connect read bridge.\n' >&2
        return 1
      fi
      ;;
    *)
      printf 'jiggit: JIGGIT_JIRA_ADAPTER must be legacy or jira-connect.\n' >&2
      return 2
      ;;
  esac
}
