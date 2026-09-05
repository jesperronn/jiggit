#!/usr/bin/env bash

set -euo pipefail

if ! declare -F run_explore_main >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/explore.sh"
fi

if ! declare -F run_jira_setup_main >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/jira_setup_command.sh"
fi

# Render help for the setup command and its subcommands.
setup_usage() {
  print_jiggit_usage_block <<'EOF'
Usage:
  jiggit setup
  jiggit setup jira [<jira-name>] [--verbose]
  jiggit setup explore [--verbose] [--dry-run] [--append|--replace] <dir> [<dir> ...]

Run guided setup flows for Jira config and project discovery.
EOF
}

# Render an invalid setup mode with the command that exposes valid modes.
render_setup_failure() {
  local mode="${1}"

  print_markdown_h1 "jiggit setup"
  printf '\n'
  render_status_line "fail" "unknown setup mode: ${mode}"
  render_next_step_line "jiggit setup --help"
}

# Dispatch the requested setup flow to the existing implementation.
run_setup_main() {
  local mode="${1:-}"

  case "${mode}" in
    ""|-h|--help)
      setup_usage
      ;;
    jira)
      shift || true
      run_jira_setup_main "$@"
      ;;
    explore)
      shift || true
      run_explore_main "$@"
      ;;
    *)
      render_setup_failure "${mode}"
      return 1
      ;;
  esac
}
