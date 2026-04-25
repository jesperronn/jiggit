#!/usr/bin/env bash
# you can test output of the colors by calling directly this file and it will call `_testcolors()` method


C_0="\e[0m"
C_BOLD="\e[1m"
C_U="\e[4m"
C_RED="\e[31m"
C_GREEN="\e[32m"
C_ORANGE="\e[38;5;202m"
C_MAGENTA="\e[35m"
C_BLUE="\e[34m"
C_CYAN="\e[36m"
C_DIM="\e[37m"

# Backward-compatible aliases kept for older scripts that still reference them.
# shellcheck disable=SC2034
ERROR="${C_RED}${C_BOLD}"
# shellcheck disable=SC2034
OK="${C_GREEN}"
# shellcheck disable=SC2034
WARN="${C_ORANGE}${C_BOLD}"
# shellcheck disable=SC2034
NORMAL="${C_0}"

# Return success when colored console output should be used.
use_color_output() {
  case "${JIGGIT_COLOR_OUTPUT:-auto}" in
    always) return 0 ;;
    never) return 1 ;;
  esac

  [[ -t 1 && "${TERM:-}" != "dumb" && -z "${NO_COLOR:-}" ]]
}

# Print one line using the requested color and bold styling when color is enabled.
print_colored_line() {
  local color_code="${1:-}"
  local text="${2:-}"

  if use_color_output; then
    printf '%b%s%b\n' "${C_BOLD}${color_code}" "${text}" "${C_0}"
  else
    printf '%s\n' "${text}"
  fi
}

# Print a first-level Markdown heading with console styling.
print_markdown_h1() {
  local text="${1:-}"
  print_colored_line "${C_BLUE}" "# ${text}"
}

# Print a second-level Markdown heading with console styling.
print_markdown_h2() {
  local text="${1:-}"
  local color_code="${2:-${C_CYAN}}"
  print_colored_line "${color_code}" "## ${text}"
}

# Print a third-level Markdown heading with console styling.
print_markdown_h3() {
  local text="${1:-}"
  local color_code="${2:-${C_BLUE}}"
  print_colored_line "${color_code}" "### ${text}"
}

# Print a highlighted project item line with console styling.
print_markdown_project_item() {
  local project_id="${1:-}"
  print_colored_line "${C_GREEN}" "- \`${project_id}\`"
}

# Print one Markdown key/value line with optional right-padding for the key.
print_markdown_kv() {
  local key="${1:-}"
  local value="${2:-}"
  local key_width="${3:-0}"
  local padded_key="${key}"

  if [[ "${key_width}" -gt 0 ]]; then
    printf -v padded_key "%-${key_width}s" "${key}"
  fi

  printf -- "- \`%s\`: \`%s\`\n" "${padded_key}" "${value}"
}

# Convert internal status tokens into user-facing status labels.
render_status_label() {
  local status="${1:-}"

  case "${status}" in
    ok)
      printf '✅ OK'
      ;;
    warn)
      printf '⚠️ WARN'
      ;;
    fail|failed)
      printf '❌ FAIL'
      ;;
    error)
      printf '❌ ERROR'
      ;;
    *)
      printf '%s' "${status}"
      ;;
  esac
}

# Print a usage line that bolds the jiggit subcommand token when present.
print_jiggit_usage_line() {
  local line="${1:-}"
  case "${line}" in
    "Usage: jiggit "*)
      if [[ "${JIGGIT_COLOR_ENABLED:-0}" -eq 1 ]]; then
        printf 'Usage: '
        jiggit_render_help_tokens "${line#Usage: }" "usage"
      else
        printf '%s\n' "${line}"
      fi
      ;;
    "  jiggit "*|"  --"*|"\t--"*)
      jiggit_render_help_tokens "${line}" "usage"
      ;;
    *)
      printf '%s\n' "${line}"
      ;;
  esac
}

# Print a heredoc usage block with consistent command-token styling.
print_jiggit_usage_block() {
  local line=""

  while IFS= read -r line; do
    print_jiggit_usage_line "${line}"
  done
}

# Return success when jiggit verbose troubleshooting output is enabled.
jiggit_is_verbose() {
  [[ "${JIGGIT_VERBOSE:-0}" == "1" || "${VERBOSE:-false}" == "true" ]]
}

# Print one verbose troubleshooting line to stderr when enabled.
jiggit_verbose_log() {
  [[ $# -eq 0 ]] && return 0
  if jiggit_is_verbose; then
    printf '[verbose] %s\n' "$*" >&2
  fi
}


_testcolors() {
  echo -e "${C_0}color C_0${C_0}"
  echo -e "${C_U}color C_U${C_0}"
  echo -e "${C_BOLD}color C_BOLD${C_0}"
  echo -e "${C_RED}color C_RED${C_0}"
  echo -e "${C_GREEN}color C_GREEN${C_0}"
  echo -e "${C_ORANGE}color C_ORANGE${C_0}"
  echo -e "${C_MAGENTA}color C_MAGENTA${C_0}"
  echo -e "${C_BLUE}color C_BLUE${C_0}"
  echo -e "${C_CYAN}color C_CYAN${C_0}"
  echo -e "${C_DIM}color C_DIM${C_0}"
  echo -e "${C_0}"

  info text printed as info
  ok text printed as ✅ OK
  warn text printed as ⚠️ WARN
  error text printed as ❌ ERROR
  ok text printed as ✅ OK
  debug debugtext THIS MUST BE HIDDEN
  VERBOSE=true debug debugtext which must be shown
  debug debugtext THIS MUST BE HIDDEN
  print_markdown_h1 "example"
  print_markdown_h2 "section" "${C_MAGENTA}"
  print_markdown_h3 "subsection" "${C_BLUE}"
  print_markdown_project_item "demo-project"
}

# redirected to stderr or else 'echo' will be part of what functions return
function debug {
  test "${VERBOSE:-false}" != true && return

  printf '%b\n' "${C_DIM}[DEBUG] $1${C_0}" >&2
}
function info {
  echo -e "[INFO] $1" >&2
}
function ok {
  echo -e "${C_BOLD}${C_GREEN}✅ [OK] $1${C_0}" >&2
}
function warn {
  echo -e "${C_BOLD}${C_ORANGE}⚠️ [WARN] $1${C_0}" >&2
}
function error {
  echo -e "${C_RED}${C_BOLD}❌ [ERROR] $1${C_0}" >&2
}


run_main() {
  _testcolors
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]
then
  run_main "$@"
fi
