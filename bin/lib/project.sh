# shellcheck shell=bash
# Shared exit codes and usage helper for bin/changelog and bin/release. Source it; do not run it.

EX_FAILED=1
EX_USAGE=2

# Print a usage error for the calling script and exit with EX_USAGE.
die_usage() {
  printf '%s: %s\n' "$(basename "$0")" "$1" >&2
  printf "Try '%s --help'.\n" "$(basename "$0")" >&2
  exit "$EX_USAGE"
}
