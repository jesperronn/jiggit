#!/usr/bin/env bash

set -euo pipefail
set +u

JIGGIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly JIGGIT_ROOT
readonly JIGGIT_FALLBACK_JIRA_REGEX='[A-Z][A-Z0-9]+-[0-9]+'

JIGGIT_EXPLORE_VERBOSE=0
JIGGIT_EXPLORE_DRY_RUN=0
JIGGIT_EXPLORE_WRITE_MODE=""
declare -a JIGGIT_EXPLORE_DIRECTORIES=()

declare -a JIGGIT_CONFIGURED_IDS=()
declare -a JIGGIT_LOADED_CONFIG_FILES=()
declare -a JIGGIT_CONFIG_CONFLICTS=()
declare -A JIGGIT_PROJECT_REPO_PATH_BY_ID=()
declare -A JIGGIT_PROJECT_REMOTE_URL_BY_ID=()
declare -A JIGGIT_PROJECT_JIRA_NAME_BY_ID=()
declare -A JIGGIT_PROJECT_JIRA_PROJECT_KEY_BY_ID=()
declare -A JIGGIT_PROJECT_JIRA_REGEXES_BY_ID=()
declare -A JIGGIT_PROJECT_JIRA_RELEASE_PREFIX_BY_ID=()
declare -A JIGGIT_PROJECT_ENVIRONMENTS_BY_ID=()
declare -A JIGGIT_PROJECT_ENV_INFO_URLS_BY_ID=()
declare -A JIGGIT_PROJECT_INFO_VERSION_EXPR_BY_ID=()
declare -A JIGGIT_PROJECT_SOURCE_BY_ID=()
declare -A JIGGIT_PROJECT_REPO_PATH_SOURCE_BY_ID=()
declare -A JIGGIT_PROJECT_REMOTE_URL_SOURCE_BY_ID=()
declare -A JIGGIT_PROJECT_JIRA_NAME_SOURCE_BY_ID=()
declare -A JIGGIT_PROJECT_JIRA_PROJECT_KEY_SOURCE_BY_ID=()
declare -A JIGGIT_PROJECT_JIRA_REGEXES_SOURCE_BY_ID=()
declare -A JIGGIT_PROJECT_JIRA_RELEASE_PREFIX_SOURCE_BY_ID=()
declare -A JIGGIT_PROJECT_ENVIRONMENTS_SOURCE_BY_ID=()
declare -A JIGGIT_PROJECT_ENV_INFO_URLS_SOURCE_BY_ID=()
declare -A JIGGIT_PROJECT_INFO_VERSION_EXPR_SOURCE_BY_ID=()

declare -a JIGGIT_JIRA_NAMES=()
declare -A JIGGIT_JIRA_BASE_URL_BY_NAME=()
declare -A JIGGIT_JIRA_BEARER_TOKEN_BY_NAME=()
declare -A JIGGIT_JIRA_USER_EMAIL_BY_NAME=()
declare -A JIGGIT_JIRA_API_TOKEN_BY_NAME=()
declare -A JIGGIT_JIRA_SOURCE_BY_NAME=()
declare -A JIGGIT_JIRA_BASE_URL_SOURCE_BY_NAME=()
declare -A JIGGIT_JIRA_BEARER_TOKEN_SOURCE_BY_NAME=()
declare -A JIGGIT_JIRA_USER_EMAIL_SOURCE_BY_NAME=()
declare -A JIGGIT_JIRA_API_TOKEN_SOURCE_BY_NAME=()

JIGGIT_SHARED_JIRA_NAME="shared"

declare -a JIGGIT_DISCOVERED_REPOS=()
declare -a JIGGIT_DISCOVERY_WARNINGS=()

if ! declare -F print_markdown_h1 >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "${JIGGIT_ROOT}/bin/lib/common_output.sh"
fi

# Trim leading and trailing shell whitespace from a value.
trim() {
  local value="${1:-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "${value}"
}

# Print verbose explore logs when --verbose is enabled.
explore_debug() {
  if [[ "${JIGGIT_EXPLORE_VERBOSE:-0}" -eq 1 ]]; then
    printf '[explore] %s\n' "$*" >&2
  fi
}

# Print the concrete shell command being executed for traceability.
explore_run_log() {
  explore_debug "run: $*"
}

# Return success when explore can prompt through the controlling terminal.
can_prompt_interactively() {
  if [[ "${JIGGIT_CAN_PROMPT_INTERACTIVELY:-}" == "true" ]]; then
    return 0
  fi
  if [[ "${JIGGIT_CAN_PROMPT_INTERACTIVELY:-}" == "false" ]]; then
    return 1
  fi
  [[ -r /dev/tty && -w /dev/tty ]]
}

# Read one interactive input line from the controlling terminal or a test override.
prompt_input_line() {
  local prompt_text="${1:-}"
  local response=""
  local input_file="${JIGGIT_PROMPT_INPUT_FILE:-}"

  if [[ -n "${prompt_text}" && -z "${input_file}" ]]; then
    printf '%s' "${prompt_text}" >&2
  fi

  if [[ -n "${input_file}" ]]; then
    if [[ -f "${input_file}" ]]; then
      response="$(sed -n '1p' "${input_file}")"
      tail -n +2 "${input_file}" > "${input_file}.tmp"
      mv "${input_file}.tmp" "${input_file}"
    fi
  else
    IFS= read -r response < /dev/tty || true
  fi

  printf '%s\n' "${response}"
}

# Prompt for confirmation after showing the exact TOML snippet that would be written.
prompt_confirm_toml_preview() {
  local intro_text="${1:-}"
  local preview_text="${2:-}"
  local response=""

  [[ -n "${intro_text}" ]] && printf '%s\n' "${intro_text}" >&2
  [[ -n "${preview_text}" ]] && printf '%s\n' "${preview_text}" >&2
  response="$(prompt_input_line "Apply this change? [y/N]: ")"
  case "${response}" in
    y|Y) return 0 ;;
    *) return 1 ;;
  esac
}

# Render one minimal TOML block preview for shared Jira config.
render_shared_jira_config_preview() {
  local jira_name="${1}"
  local jira_base_url_value="${2}"
  local jira_bearer_token_value="${3}"
  local section_name="jira"

  if [[ -n "${jira_name}" && "${jira_name}" != "default" ]]; then
    section_name="jira.${jira_name}"
  fi

  printf '[%s]\n' "${section_name}"
  printf 'base_url = "%s"\n' "${jira_base_url_value}"
  printf 'bearer_token = "%s"\n' "${jira_bearer_token_value}"
}

# Return the existing raw value for one key in a named TOML section when present.
existing_toml_value_in_section() {
  local target_file="${1}"
  local section_name="${2}"
  local key_name="${3}"

  [[ -f "${target_file}" ]] || return 1

  awk \
    -v section_header="[${section_name}]" \
    -v key_name="${key_name}" '
      BEGIN {
        in_section = 0
        key_pattern = "^[[:space:]]*" key_name "[[:space:]]*="
      }
      $0 == section_header {
        in_section = 1
        next
      }
      in_section && $0 ~ /^\[/ {
        in_section = 0
      }
      in_section && $0 ~ key_pattern {
        sub("^[[:space:]]*" key_name "[[:space:]]*=[[:space:]]*", "", $0)
        print $0
        exit
      }
    ' "${target_file}"
}

# Render the exact TOML change that would be inserted or replaced in one section.
render_toml_upsert_preview() {
  local target_file="${1}"
  local section_name="${2}"
  local key_name="${3}"
  local raw_value="${4}"
  local existing_value=""

  existing_value="$(existing_toml_value_in_section "${target_file}" "${section_name}" "${key_name}" || true)"
  printf '%s\n' "[${section_name}]"
  if [[ -n "${existing_value}" ]]; then
    printf '# old: %s = %s\n' "${key_name}" "${existing_value}"
  fi
  printf '%s = %s\n' "${key_name}" "$(toml_quote_string "${raw_value}")"
}

# Render a TOML array literal from a space-separated word list.
toml_array_from_words() {
  local words_text="${1:-}"
  local word=""
  local first=1

  printf '['
  for word in ${words_text}; do
    if [[ "${first}" -eq 0 ]]; then
      printf ', '
    fi
    printf '%s' "$(toml_quote_string "${word}")"
    first=0
  done
  printf ']'
}

# Insert or replace one array key inside a named TOML section.
upsert_toml_array_in_section() {
  local target_file="${1}"
  local section_name="${2}"
  local key_name="${3}"
  local words_text="${4}"
  local temp_file="${target_file}.tmp"
  local rendered_line=""

  mkdir -p "$(dirname "${target_file}")"
  touch "${target_file}"

  rendered_line="${key_name} = $(toml_array_from_words "${words_text}")"

  awk \
    -v section_header="[${section_name}]" \
    -v key_name="${key_name}" \
    -v rendered_line="${rendered_line}" '
      BEGIN {
        found_section = 0
        in_section = 0
        inserted = 0
        key_pattern = "^[[:space:]]*" key_name "[[:space:]]*="
      }
      {
        if ($0 == section_header) {
          found_section = 1
          in_section = 1
          print
          next
        }

        if (in_section && $0 ~ /^\[/) {
          if (!inserted) {
            print rendered_line
            inserted = 1
          }
          in_section = 0
        }

        if (in_section && $0 ~ key_pattern) {
          if (!inserted) {
            print rendered_line
            inserted = 1
          }
          next
        }

        print
      }
      END {
        if (in_section && !inserted) {
          print rendered_line
        }

        if (!found_section) {
          if (NR > 0) {
            print ""
          }
          print section_header
          print rendered_line
        }
      }
    ' "${target_file}" > "${temp_file}"

  mv "${temp_file}" "${target_file}"
}

# Render the exact TOML array change that would be inserted or replaced in one section.
render_toml_array_upsert_preview() {
  local target_file="${1}"
  local section_name="${2}"
  local key_name="${3}"
  local words_text="${4}"
  local existing_value=""

  existing_value="$(existing_toml_value_in_section "${target_file}" "${section_name}" "${key_name}" || true)"
  printf '%s\n' "[${section_name}]"
  if [[ -n "${existing_value}" ]]; then
    printf '# old: %s = %s\n' "${key_name}" "${existing_value}"
  fi
  printf '%s = %s\n' "${key_name}" "$(toml_array_from_words "${words_text}")"
}

# Render help for the setup explore flow.
explore_usage() {
  print_jiggit_usage_block <<'EOF'
Usage: jiggit setup explore [--verbose] [--dry-run] [--append|--replace] <dir> [<dir> ...]

Options:
  --verbose   Print discovery progress and shell commands to stderr.
  --dry-run   Show the summary and candidate output path without writing the file.
  --append    Append discovered entries to an existing discovery file.
  --replace   Replace an existing discovery file without prompting.
EOF
}

# Return the repo-local curated config directory.
default_repo_config_dir() {
  printf '%s\n' "${JIGGIT_ROOT}/config"
}

# Return the base user config directory under ~/.jiggit unless overridden.
default_user_jiggit_dir() {
  printf '%s\n' "${JIGGIT_HOME:-${HOME}/.jiggit}"
}

# Return the user curated config directory that contains project config files.
default_user_config_dir() {
  printf '%s\n' "${JIGGIT_CONFIG_DIR:-$(default_user_jiggit_dir)/config}"
}

# Return the default user-level shared config TOML file.
default_user_shared_config_file() {
  printf '%s\n' "${JIGGIT_CONFIG_FILE:-$(default_user_jiggit_dir)/config.toml}"
}

# Return the default path for generated discovered project output.
default_user_discovered_file() {
  printf '%s\n' "${JIGGIT_DISCOVERED_PROJECTS_FILE:-$(default_user_jiggit_dir)/discovered_projects.toml}"
}

# Join non-empty words with spaces for storage in shell config structures.
join_space() {
  local output=""
  local item

  for item in "$@"; do
    if [[ -z "${item}" ]]; then
      continue
    fi
    if [[ -z "${output}" ]]; then
      output="${item}"
    else
      output="${output} ${item}"
    fi
  done

  printf '%s\n' "${output}"
}

# Expand a config path that uses $HOME or ~/ into an absolute user path.
expand_config_path() {
  local raw_path="${1:-}"
  local expanded_path="${raw_path}"

  if [[ -z "${expanded_path}" ]]; then
    printf '%s\n' ""
    return 0
  fi

  if [[ "${expanded_path}" == \~/* ]]; then
    expanded_path="${HOME}/${expanded_path#\~/}"
  fi

  expanded_path="${expanded_path//\$HOME/${HOME}}"
  printf '%s\n' "${expanded_path}"
}

# Register one project entry in the in-memory config indexes.
register_project() {
  local id="${1:-}"
  local repo_path="${2:-}"
  local remote_url="${3:-}"
  local jira_name="${4:-}"
  local jira_project_key="${5:-}"
  local jira_regexes="${6:-}"
  local jira_release_prefixes="${7:-}"
  local environments="${8:-}"
  local environment_info_urls="${9:-}"
  local info_version_expr="${10:-}"
  local source_file="${11:-unknown}"

  if [[ -z "${id}" ]]; then
    return 0
  fi

  if declare -F jiggit_verbose_log >/dev/null 2>&1; then
    jiggit_verbose_log "register project id=${id} source=${source_file} repo=${repo_path:-missing} jira=${jira_project_key:-missing} envs=${environments:-none}"
  fi

  set +u
  repo_path="$(expand_config_path "${repo_path}")"

  if [[ -n "${JIGGIT_PROJECT_SOURCE_BY_ID["${id}"]:-}" ]]; then
    local changed_fields=()

    [[ "${JIGGIT_PROJECT_REPO_PATH_BY_ID["${id}"]:-}" != "${repo_path}" ]] && changed_fields+=("repo_path")
    [[ "${JIGGIT_PROJECT_REMOTE_URL_BY_ID["${id}"]:-}" != "${remote_url}" ]] && changed_fields+=("remote_url")
    [[ "${JIGGIT_PROJECT_JIRA_NAME_BY_ID["${id}"]:-}" != "${jira_name}" ]] && changed_fields+=("jira")
    [[ "${JIGGIT_PROJECT_JIRA_PROJECT_KEY_BY_ID["${id}"]:-}" != "${jira_project_key}" ]] && changed_fields+=("jira_project_key")
    [[ "${JIGGIT_PROJECT_JIRA_REGEXES_BY_ID["${id}"]:-}" != "${jira_regexes}" ]] && changed_fields+=("jira_regexes")
    [[ "${JIGGIT_PROJECT_JIRA_RELEASE_PREFIX_BY_ID["${id}"]:-}" != "${jira_release_prefixes}" ]] && changed_fields+=("jira_release_prefix")
    [[ "${JIGGIT_PROJECT_ENVIRONMENTS_BY_ID["${id}"]:-}" != "${environments}" ]] && changed_fields+=("environments")
    [[ "${JIGGIT_PROJECT_ENV_INFO_URLS_BY_ID["${id}"]:-}" != "${environment_info_urls}" ]] && changed_fields+=("environment_info_urls")
    [[ "${JIGGIT_PROJECT_INFO_VERSION_EXPR_BY_ID["${id}"]:-}" != "${info_version_expr}" ]] && changed_fields+=("info_version_expr")

    if [[ ${#changed_fields[@]} -gt 0 && "${source_file}" != "${JIGGIT_PROJECT_SOURCE_BY_ID["${id}"]}" ]]; then
      JIGGIT_CONFIG_CONFLICTS+=(
        "Project ${id} overridden by ${source_file}; previous source ${JIGGIT_PROJECT_SOURCE_BY_ID["${id}"]}; changed fields: $(join_by ', ' "${changed_fields[@]}")"
      )
    fi
  else
    JIGGIT_CONFIGURED_IDS+=("${id}")
  fi

  JIGGIT_PROJECT_REPO_PATH_BY_ID["${id}"]="${repo_path}"
  JIGGIT_PROJECT_REMOTE_URL_BY_ID["${id}"]="${remote_url}"
  JIGGIT_PROJECT_JIRA_NAME_BY_ID["${id}"]="${jira_name}"
  JIGGIT_PROJECT_JIRA_PROJECT_KEY_BY_ID["${id}"]="${jira_project_key}"
  JIGGIT_PROJECT_JIRA_REGEXES_BY_ID["${id}"]="${jira_regexes}"
  JIGGIT_PROJECT_JIRA_RELEASE_PREFIX_BY_ID["${id}"]="${jira_release_prefixes}"
  JIGGIT_PROJECT_ENVIRONMENTS_BY_ID["${id}"]="${environments}"
  JIGGIT_PROJECT_ENV_INFO_URLS_BY_ID["${id}"]="${environment_info_urls}"
  JIGGIT_PROJECT_INFO_VERSION_EXPR_BY_ID["${id}"]="${info_version_expr}"
  JIGGIT_PROJECT_SOURCE_BY_ID["${id}"]="${source_file}"
  JIGGIT_PROJECT_REPO_PATH_SOURCE_BY_ID["${id}"]="${source_file}"
  JIGGIT_PROJECT_REMOTE_URL_SOURCE_BY_ID["${id}"]="${source_file}"
  JIGGIT_PROJECT_JIRA_NAME_SOURCE_BY_ID["${id}"]="${source_file}"
  JIGGIT_PROJECT_JIRA_PROJECT_KEY_SOURCE_BY_ID["${id}"]="${source_file}"
  JIGGIT_PROJECT_JIRA_REGEXES_SOURCE_BY_ID["${id}"]="${source_file}"
  JIGGIT_PROJECT_JIRA_RELEASE_PREFIX_SOURCE_BY_ID["${id}"]="${source_file}"
  JIGGIT_PROJECT_ENVIRONMENTS_SOURCE_BY_ID["${id}"]="${source_file}"
  JIGGIT_PROJECT_ENV_INFO_URLS_SOURCE_BY_ID["${id}"]="${source_file}"
  JIGGIT_PROJECT_INFO_VERSION_EXPR_SOURCE_BY_ID["${id}"]="${source_file}"

}

# Reset all loaded project metadata before reading config files again.
reset_loaded_projects() {
  if declare -F jiggit_verbose_log >/dev/null 2>&1; then
    jiggit_verbose_log "reset loaded project state"
  fi
  JIGGIT_CONFIGURED_IDS=()
  JIGGIT_LOADED_CONFIG_FILES=()
  JIGGIT_CONFIG_CONFLICTS=()
  JIGGIT_PROJECT_REPO_PATH_BY_ID=()
  JIGGIT_PROJECT_REMOTE_URL_BY_ID=()
  JIGGIT_PROJECT_JIRA_NAME_BY_ID=()
  JIGGIT_PROJECT_JIRA_PROJECT_KEY_BY_ID=()
  JIGGIT_PROJECT_JIRA_REGEXES_BY_ID=()
  JIGGIT_PROJECT_JIRA_RELEASE_PREFIX_BY_ID=()
  JIGGIT_PROJECT_ENVIRONMENTS_BY_ID=()
  JIGGIT_PROJECT_ENV_INFO_URLS_BY_ID=()
  JIGGIT_PROJECT_INFO_VERSION_EXPR_BY_ID=()
  JIGGIT_PROJECT_SOURCE_BY_ID=()
  JIGGIT_PROJECT_REPO_PATH_SOURCE_BY_ID=()
  JIGGIT_PROJECT_REMOTE_URL_SOURCE_BY_ID=()
  JIGGIT_PROJECT_JIRA_NAME_SOURCE_BY_ID=()
  JIGGIT_PROJECT_JIRA_PROJECT_KEY_SOURCE_BY_ID=()
  JIGGIT_PROJECT_JIRA_REGEXES_SOURCE_BY_ID=()
  JIGGIT_PROJECT_JIRA_RELEASE_PREFIX_SOURCE_BY_ID=()
  JIGGIT_PROJECT_ENVIRONMENTS_SOURCE_BY_ID=()
  JIGGIT_PROJECT_ENV_INFO_URLS_SOURCE_BY_ID=()
  JIGGIT_PROJECT_INFO_VERSION_EXPR_SOURCE_BY_ID=()
  JIGGIT_JIRA_NAMES=()
  JIGGIT_JIRA_BASE_URL_BY_NAME=()
  JIGGIT_JIRA_BEARER_TOKEN_BY_NAME=()
  JIGGIT_JIRA_USER_EMAIL_BY_NAME=()
  JIGGIT_JIRA_API_TOKEN_BY_NAME=()
  JIGGIT_JIRA_SOURCE_BY_NAME=()
  JIGGIT_JIRA_BASE_URL_SOURCE_BY_NAME=()
  JIGGIT_JIRA_BEARER_TOKEN_SOURCE_BY_NAME=()
  JIGGIT_JIRA_USER_EMAIL_SOURCE_BY_NAME=()
  JIGGIT_JIRA_API_TOKEN_SOURCE_BY_NAME=()
}

# Return the current shell variable type for one config container.
project_config_var_type() {
  local variable_name="${1:-}"
  local declaration=""

  declaration="$(declare -p "${variable_name}" 2>/dev/null || true)"
  case "${declaration}" in
    declare\ -A*) printf '%s\n' "assoc" ;;
    declare\ -a*) printf '%s\n' "array" ;;
    "") printf '%s\n' "unset" ;;
    *) printf '%s\n' "scalar" ;;
  esac
}

# Normalize a Jira config name, defaulting blank names to "default".
normalize_jira_name() {
  local jira_name="${1:-default}"

  if [[ -z "${jira_name}" ]]; then
    jira_name="default"
  fi

  printf '%s\n' "${jira_name}"
}

# Return the internal storage key for a Jira config name.
jiggit_jira_storage_name() {
  local jira_name="${1:-default}"

  if [[ -z "${jira_name}" || "${jira_name}" == "default" ]]; then
    printf '%s\n' "${JIGGIT_SHARED_JIRA_NAME}"
    return 0
  fi

  printf '%s\n' "${jira_name}"
}

# Return the user-facing Jira config name for a stored key.
jiggit_jira_display_name() {
  local jira_name="${1:-}"

  if [[ "${jira_name}" == "${JIGGIT_SHARED_JIRA_NAME}" ]]; then
    printf '%s\n' "default"
    return 0
  fi

  printf '%s\n' "${jira_name}"
}

# Register one effective Jira settings entry from a config file.
register_jira_config() {
  local jira_name
  local base_url="${2:-}"
  local bearer_token="${3:-}"
  local user_email="${4:-}"
  local api_token="${5:-}"
  local source_file="${6:-unknown}"
  local previous_source=""
  local previous_base_url=""
  local previous_bearer_token=""
  local previous_user_email=""
  local previous_api_token=""
  local jira_storage_name=""

  set +u
  jira_name="$(normalize_jira_name "${1:-default}")"
  jira_storage_name="$(jiggit_jira_storage_name "${jira_name}")"

  if [[ -n "${JIGGIT_JIRA_SOURCE_BY_NAME[${jira_storage_name}]+x}" ]]; then
    previous_source="${JIGGIT_JIRA_SOURCE_BY_NAME[${jira_storage_name}]}"
  fi

  if [[ -n "${previous_source}" ]]; then
    local changed_fields=()

    if [[ -n "${JIGGIT_JIRA_BASE_URL_BY_NAME[${jira_storage_name}]+x}" ]]; then
      previous_base_url="${JIGGIT_JIRA_BASE_URL_BY_NAME[${jira_storage_name}]}"
    fi
    if [[ -n "${JIGGIT_JIRA_BEARER_TOKEN_BY_NAME[${jira_storage_name}]+x}" ]]; then
      previous_bearer_token="${JIGGIT_JIRA_BEARER_TOKEN_BY_NAME[${jira_storage_name}]}"
    fi
    if [[ -n "${JIGGIT_JIRA_USER_EMAIL_BY_NAME[${jira_storage_name}]+x}" ]]; then
      previous_user_email="${JIGGIT_JIRA_USER_EMAIL_BY_NAME[${jira_storage_name}]}"
    fi
    if [[ -n "${JIGGIT_JIRA_API_TOKEN_BY_NAME[${jira_storage_name}]+x}" ]]; then
      previous_api_token="${JIGGIT_JIRA_API_TOKEN_BY_NAME[${jira_storage_name}]}"
    fi

    [[ "${previous_base_url}" != "${base_url}" ]] && changed_fields+=("base_url")
    [[ "${previous_bearer_token}" != "${bearer_token}" ]] && changed_fields+=("bearer_token")
    [[ "${previous_user_email}" != "${user_email}" ]] && changed_fields+=("user_email")
    [[ "${previous_api_token}" != "${api_token}" ]] && changed_fields+=("api_token")

    if [[ ${#changed_fields[@]} -gt 0 && "${source_file}" != "${previous_source}" ]]; then
      JIGGIT_CONFIG_CONFLICTS+=(
        "Jira ${jira_name} overridden by ${source_file}; previous source ${previous_source}; changed fields: $(join_by ', ' "${changed_fields[@]}")"
      )
    fi
  else
    JIGGIT_JIRA_NAMES+=("$(jiggit_jira_display_name "${jira_name}")")
  fi

  JIGGIT_JIRA_BASE_URL_BY_NAME["${jira_storage_name}"]="${base_url}"
  JIGGIT_JIRA_BEARER_TOKEN_BY_NAME["${jira_storage_name}"]="${bearer_token}"
  JIGGIT_JIRA_USER_EMAIL_BY_NAME["${jira_storage_name}"]="${user_email}"
  JIGGIT_JIRA_API_TOKEN_BY_NAME["${jira_storage_name}"]="${api_token}"
  JIGGIT_JIRA_SOURCE_BY_NAME["${jira_storage_name}"]="${source_file}"
  JIGGIT_JIRA_BASE_URL_SOURCE_BY_NAME["${jira_storage_name}"]="${source_file}"
  JIGGIT_JIRA_BEARER_TOKEN_SOURCE_BY_NAME["${jira_storage_name}"]="${source_file}"
  JIGGIT_JIRA_USER_EMAIL_SOURCE_BY_NAME["${jira_storage_name}"]="${source_file}"
  JIGGIT_JIRA_API_TOKEN_SOURCE_BY_NAME["${jira_storage_name}"]="${source_file}"
}

# Decode a minimal TOML string literal into plain text.
unquote_toml_string() {
  local value="${1:-}"

  value="${value#\"}"
  value="${value%\"}"
  value="${value//\\\\/\\}"
  value="${value//\\\"/\"}"
  printf '%s\n' "${value}"
}

# Decode a minimal TOML array of strings into a space-separated shell value.
parse_toml_array_to_words() {
  local value="${1:-}"
  local inner
  local item
  local -a items=()

  inner="${value#[}"
  inner="${inner%]}"
  inner="$(trim "${inner}")"

  if [[ -z "${inner}" ]]; then
    printf '%s\n' ""
    return 0
  fi

  while IFS= read -r item; do
    item="$(trim "${item}")"
    if [[ -z "${item}" ]]; then
      continue
    fi
    items+=("$(unquote_toml_string "${item}")")
  done < <(printf '%s\n' "${inner}" | tr ',' '\n')

  join_space "${items[@]}"
}

# Parse the supported TOML project format and register each discovered project table.
parse_projects_toml() {
  local config_file="${1}"
  local line
  local current_id=""
  local current_section="project"
  local current_jira_name=""
  local repo_path=""
  local remote_url=""
  local jira_name=""
  local jira_project_key=""
  local jira_regexes=""
  local jira_release_prefixes=""
  local environments=""
  local environment_info_urls=""
  local info_version_expr=""
  local jira_base_url=""
  local jira_bearer_token=""
  local jira_user_email=""
  local jira_api_token=""

  explore_debug "Parsing TOML config ${config_file}"

  flush_current_project() {
    if [[ -n "${current_id}" ]]; then
      register_project "${current_id}" "${repo_path}" "${remote_url}" "${jira_name}" "${jira_project_key}" "${jira_regexes}" "${jira_release_prefixes}" "${environments}" "${environment_info_urls}" "${info_version_expr}" "${config_file}"
    fi
  }

  flush_current_jira() {
    if [[ -n "${current_jira_name}" ]]; then
      register_jira_config "${current_jira_name}" "${jira_base_url}" "${jira_bearer_token}" "${jira_user_email}" "${jira_api_token}" "${config_file}"
    fi
  }

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="$(trim "${line}")"

    if [[ -z "${line}" || "${line}" == \#* ]]; then
      continue
    fi

    if [[ "${line}" =~ ^\[([^][]+)\.environment_info_urls\]$ ]]; then
      local nested_id="${BASH_REMATCH[1]}"

      if [[ -n "${current_id}" && "${nested_id}" != "${current_id}" ]]; then
        flush_current_project
        repo_path=""
        remote_url=""
        jira_project_key=""
        jira_regexes=""
        jira_release_prefixes=""
        environments=""
        environment_info_urls=""
        info_version_expr=""
      fi

      current_id="${nested_id}"
      current_section="environment_info_urls"
      continue
    fi

    if [[ "${line}" =~ ^\[jira\.(.+)\]$ ]]; then
      flush_current_project
      flush_current_jira
      current_id=""
      current_section="jira"
      current_jira_name="${BASH_REMATCH[1]}"
      current_jira_name="${current_jira_name#\"}"
      current_jira_name="${current_jira_name%\"}"
      current_jira_name="$(normalize_jira_name "${current_jira_name}")"
      jira_base_url=""
      jira_bearer_token=""
      jira_user_email=""
      jira_api_token=""
      continue
    fi

    if [[ "${line}" =~ ^\[(.*)\]$ ]]; then
      flush_current_project
      flush_current_jira
      current_id="${BASH_REMATCH[1]}"
      current_id="${current_id#\"}"
      current_id="${current_id%\"}"
      current_section="project"
      repo_path=""
      remote_url=""
      jira_name=""
      jira_project_key=""
      jira_regexes=""
      jira_release_prefixes=""
      environments=""
      environment_info_urls=""
      info_version_expr=""

      if [[ "${current_id}" == "jira" ]]; then
        current_id=""
        current_section="jira"
        current_jira_name="${JIGGIT_SHARED_JIRA_NAME}"
      fi
      continue
    fi

    if [[ "${line}" =~ ^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.+)$ ]]; then
      local key="${BASH_REMATCH[1]}"
      local value="${BASH_REMATCH[2]}"

      if [[ "${current_section}" == "environment_info_urls" ]]; then
        environment_info_urls="$(join_space "${environment_info_urls}" "${key}=$(unquote_toml_string "${value}")")"
        continue
      fi

      if [[ "${current_section}" == "jira" ]]; then
        case "${key}" in
          base_url)
            jira_base_url="$(unquote_toml_string "${value}")"
            ;;
          bearer_token)
            jira_bearer_token="$(unquote_toml_string "${value}")"
            ;;
          user_email)
            jira_user_email="$(unquote_toml_string "${value}")"
            ;;
          api_token)
            jira_api_token="$(unquote_toml_string "${value}")"
            ;;
        esac
        continue
      fi

      case "${key}" in
        repo_path)
          repo_path="$(unquote_toml_string "${value}")"
          ;;
        remote_url)
          remote_url="$(unquote_toml_string "${value}")"
          ;;
        jira)
          jira_name="$(normalize_jira_name "$(unquote_toml_string "${value}")")"
          ;;
        jira_project_key)
          jira_project_key="$(unquote_toml_string "${value}")"
          ;;
        jira_regexes)
          jira_regexes="$(parse_toml_array_to_words "${value}")"
          ;;
        jira_release_prefix)
          jira_release_prefixes="$(parse_toml_array_to_words "${value}")"
          ;;
        environments)
          environments="$(parse_toml_array_to_words "${value}")"
          ;;
        info_version_expr)
          info_version_expr="$(unquote_toml_string "${value}")"
          ;;
      esac
    fi
  done < "${config_file}"

  flush_current_project
  flush_current_jira
}

# Load one TOML config file into the in-memory project indexes.
load_project_config_file() {
  local config_file="${1}"

  if declare -F jiggit_verbose_log >/dev/null 2>&1; then
    jiggit_verbose_log "parse project config file ${config_file}"
  fi

  JIGGIT_LOADED_CONFIG_FILES+=("${config_file}")
  parse_projects_toml "${config_file}"
}

# Emit a config file path once when it exists on disk.
append_config_candidate() {
  local candidate="${1}"
  local seen_name="${2}"

  if [[ -f "${candidate}" && -z "$(eval "printf '%s' \"\${${seen_name}[\"\$candidate\"]+x}\"")" ]]; then
    eval "${seen_name}[\"\$candidate\"]=1"
    printf '%s\n' "${candidate}"
  fi
}

# Discover config files from the repo, ~/.jiggit, discovered repos, and discovery output.
discover_config_files() {
  local -a extra_repo_roots=("$@")
  local repo_config_dir
  local user_config_dir
  local user_discovered_file
  local repo_root
  local -A seen=()

  if [[ -n "${JIGGIT_PROJECTS_FILE:-}" ]]; then
    append_config_candidate "${JIGGIT_PROJECTS_FILE}" seen
  else
    repo_config_dir="$(default_repo_config_dir)"
    user_config_dir="$(default_user_config_dir)"

    append_config_candidate "${repo_config_dir}/projects.toml" seen
    append_config_candidate "$(default_user_shared_config_file)" seen
    append_config_candidate "${user_config_dir}/projects.toml" seen

    for repo_root in "${extra_repo_roots[@]}"; do
      append_config_candidate "${repo_root}/config/projects.toml" seen
    done
  fi

  if [[ -n "${JIGGIT_DISCOVERED_PROJECTS_FILE:-}" ]]; then
    append_config_candidate "${JIGGIT_DISCOVERED_PROJECTS_FILE}" seen
  else
    user_discovered_file="$(default_user_discovered_file)"
    append_config_candidate "${user_discovered_file}" seen
    append_config_candidate "${JIGGIT_ROOT}/discovered_projects.toml" seen
  fi
}

# Load project config from the configured search path into memory.
load_project_config() {
  local -a config_files=()
  local loaded_count_before=0
  local loaded_count_after=0
  mapfile -t config_files < <(discover_config_files "$@")

  reset_loaded_projects

  if declare -F jiggit_verbose_log >/dev/null 2>&1; then
    jiggit_verbose_log "loading project config from ${#config_files[@]} file(s)"
    jiggit_verbose_log "config var types ids=$(project_config_var_type JIGGIT_CONFIGURED_IDS) repo=$(project_config_var_type JIGGIT_PROJECT_REPO_PATH_BY_ID) source=$(project_config_var_type JIGGIT_PROJECT_SOURCE_BY_ID)"
  fi

  local config_file
  for config_file in "${config_files[@]}"; do
    loaded_count_before=${#JIGGIT_CONFIGURED_IDS[@]}
    if declare -F jiggit_verbose_log >/dev/null 2>&1; then
      jiggit_verbose_log "config file ${config_file}"
    fi
    load_project_config_file "${config_file}"
    loaded_count_after=${#JIGGIT_CONFIGURED_IDS[@]}
    if declare -F jiggit_verbose_log >/dev/null 2>&1; then
      jiggit_verbose_log "loaded ${config_file}: projects ${loaded_count_before} -> ${loaded_count_after}"
    fi
  done

  if declare -F jiggit_verbose_log >/dev/null 2>&1; then
    jiggit_verbose_log "loaded project ids: ${JIGGIT_CONFIGURED_IDS[*]:-none}"
  fi
}

# Check whether a project id exists in the loaded config.
project_exists() {
  local project_id="${1:-}"
  [[ -n "${project_id}" && -n "${JIGGIT_PROJECT_SOURCE_BY_ID["${project_id}"]+x}" ]]
}

# Return the configured repo path for a project id.
project_repo_path() {
  local project_id="${1:-}"
  [[ -n "${project_id}" ]] || { printf '%s\n' ""; return 0; }
  printf '%s\n' "${JIGGIT_PROJECT_REPO_PATH_BY_ID["${project_id}"]:-}"
}

# Return the configured Jira project key for a project id.
project_jira_project_key() {
  local project_id="${1:-}"
  [[ -n "${project_id}" ]] || { printf '%s\n' ""; return 0; }
  printf '%s\n' "${JIGGIT_PROJECT_JIRA_PROJECT_KEY_BY_ID["${project_id}"]:-}"
}

# Return the configured remote URL for a project id.
project_remote_url() {
  local project_id="${1:-}"
  [[ -n "${project_id}" ]] || { printf '%s\n' ""; return 0; }
  printf '%s\n' "${JIGGIT_PROJECT_REMOTE_URL_BY_ID["${project_id}"]:-}"
}

# Return the configured Jira name for a project id, defaulting to the shared default entry.
project_jira_name() {
  local project_id="${1:-}"
  if [[ -z "${project_id}" ]]; then
    if [[ -n "${JIGGIT_JIRA_SOURCE_BY_NAME[${JIGGIT_SHARED_JIRA_NAME}]+x}" ]]; then
      printf '%s\n' "default"
      return 0
    fi
    printf '%s\n' ""
    return 0
  fi
  local jira_name="${JIGGIT_PROJECT_JIRA_NAME_BY_ID["${project_id}"]:-}"

  if [[ -n "${jira_name}" ]]; then
    printf '%s\n' "${jira_name}"
    return 0
  fi

  if [[ -n "${JIGGIT_JIRA_SOURCE_BY_NAME[${JIGGIT_SHARED_JIRA_NAME}]+x}" ]]; then
    printf '%s\n' "default"
    return 0
  fi

  printf '%s\n' ""
}

# Return the configured Jira regexes for a project id as a space-separated string.
project_jira_regexes() {
  local project_id="${1:-}"
  [[ -n "${project_id}" ]] || { printf '%s\n' ""; return 0; }
  printf '%s\n' "${JIGGIT_PROJECT_JIRA_REGEXES_BY_ID["${project_id}"]:-}"
}

# Return the configured Jira release prefixes for a project id as a space-separated string.
project_jira_release_prefixes() {
  local project_id="${1:-}"
  [[ -n "${project_id}" ]] || { printf '%s\n' ""; return 0; }
  printf '%s\n' "${JIGGIT_PROJECT_JIRA_RELEASE_PREFIX_BY_ID["${project_id}"]:-}"
}

# Return the configured environments for a project id as a space-separated string.
project_environments() {
  local project_id="${1:-}"
  [[ -n "${project_id}" ]] || { printf '%s\n' ""; return 0; }
  printf '%s\n' "${JIGGIT_PROJECT_ENVIRONMENTS_BY_ID["${project_id}"]:-}"
}

# Return the configured environment info URL pairs for a project id as space-separated env=url values.
project_environment_info_urls() {
  local project_id="${1:-}"
  [[ -n "${project_id}" ]] || { printf '%s\n' ""; return 0; }
  printf '%s\n' "${JIGGIT_PROJECT_ENV_INFO_URLS_BY_ID["${project_id}"]:-}"
}

# Return the configured expression for extracting a version from actuator info.
project_info_version_expr() {
  local project_id="${1:-}"
  [[ -n "${project_id}" ]] || { printf '%s\n' ""; return 0; }
  printf '%s\n' "${JIGGIT_PROJECT_INFO_VERSION_EXPR_BY_ID["${project_id}"]:-}"
}

# Return the source file that supplied one effective project field.
project_field_source() {
  local project_id="${1:-}"
  local field_name="${2:-}"
  [[ -n "${project_id}" ]] || { printf '%s\n' "unknown"; return 0; }

  case "${field_name}" in
    repo_path)
      printf '%s\n' "${JIGGIT_PROJECT_REPO_PATH_SOURCE_BY_ID["${project_id}"]:-unknown}"
      ;;
    remote_url)
      printf '%s\n' "${JIGGIT_PROJECT_REMOTE_URL_SOURCE_BY_ID["${project_id}"]:-unknown}"
      ;;
    jira)
      printf '%s\n' "${JIGGIT_PROJECT_JIRA_NAME_SOURCE_BY_ID["${project_id}"]:-unknown}"
      ;;
    jira_project_key)
      printf '%s\n' "${JIGGIT_PROJECT_JIRA_PROJECT_KEY_SOURCE_BY_ID["${project_id}"]:-unknown}"
      ;;
    jira_regexes)
      printf '%s\n' "${JIGGIT_PROJECT_JIRA_REGEXES_SOURCE_BY_ID["${project_id}"]:-unknown}"
      ;;
    jira_release_prefix)
      printf '%s\n' "${JIGGIT_PROJECT_JIRA_RELEASE_PREFIX_SOURCE_BY_ID["${project_id}"]:-unknown}"
      ;;
    environments)
      printf '%s\n' "${JIGGIT_PROJECT_ENVIRONMENTS_SOURCE_BY_ID["${project_id}"]:-unknown}"
      ;;
    environment_info_urls)
      printf '%s\n' "${JIGGIT_PROJECT_ENV_INFO_URLS_SOURCE_BY_ID["${project_id}"]:-unknown}"
      ;;
    info_version_expr)
      printf '%s\n' "${JIGGIT_PROJECT_INFO_VERSION_EXPR_SOURCE_BY_ID["${project_id}"]:-unknown}"
      ;;
    *)
      printf '%s\n' "unknown"
      ;;
  esac
}

# Return the source file that supplied the effective project entry.
project_source_file() {
  local project_id="${1:-}"
  printf '%s\n' "${JIGGIT_PROJECT_SOURCE_BY_ID["${project_id}"]:-}"
}

# Return the effective shared Jira base URL from config.
# Resolve a Jira config name from either an explicit Jira name or a project id.
resolve_jira_name() {
  local reference="${1:-}"
  local jira_storage_name=""

  jira_storage_name="$(jiggit_jira_storage_name "${reference}")"

  if [[ -n "${reference}" && -n "${JIGGIT_JIRA_SOURCE_BY_NAME[${jira_storage_name}]+x}" ]]; then
    printf '%s\n' "${jira_storage_name}"
    return 0
  fi

  if [[ -n "${reference}" && -n "${JIGGIT_PROJECT_SOURCE_BY_ID["${reference}"]+x}" ]]; then
    printf '%s\n' "$(jiggit_jira_storage_name "$(project_jira_name "${reference}")")"
    return 0
  fi

  if [[ -n "${JIGGIT_JIRA_SOURCE_BY_NAME[${JIGGIT_SHARED_JIRA_NAME}]+x}" ]]; then
    printf '%s\n' "${JIGGIT_SHARED_JIRA_NAME}"
    return 0
  fi

  printf '%s\n' ""
}

# Return all configured Jira names, default-first.
jira_names() {
  printf '%s\n' "${JIGGIT_JIRA_NAMES[@]:-}"
}

# Return the effective Jira base URL from config.
jira_base_url() {
  local jira_name
  local jira_storage_name
  jira_name="$(resolve_jira_name "${1:-}")"
  [[ -n "${jira_name}" ]] || { printf '%s\n' ""; return 0; }
  jira_storage_name="$(jiggit_jira_storage_name "${jira_name}")"
  if [[ "${jira_storage_name}" == "${JIGGIT_SHARED_JIRA_NAME}" && -n "${JIRA_BASE_URL:-}" ]]; then
    printf '%s\n' "${JIRA_BASE_URL}"
    return 0
  fi
  printf '%s\n' "${JIGGIT_JIRA_BASE_URL_BY_NAME["${jira_storage_name}"]:-}"
}

# Return the effective Jira bearer token from config.
jira_bearer_token() {
  local jira_name
  local jira_storage_name
  jira_name="$(resolve_jira_name "${1:-}")"
  [[ -n "${jira_name}" ]] || { printf '%s\n' ""; return 0; }
  jira_storage_name="$(jiggit_jira_storage_name "${jira_name}")"
  if [[ "${jira_storage_name}" == "${JIGGIT_SHARED_JIRA_NAME}" && -n "${JIRA_BEARER_TOKEN:-}" ]]; then
    printf '%s\n' "${JIRA_BEARER_TOKEN}"
    return 0
  fi
  if [[ "${jira_storage_name}" == "${JIGGIT_SHARED_JIRA_NAME}" && -n "${JIRA_API_TOKEN:-}" ]]; then
    printf '%s\n' "${JIRA_API_TOKEN}"
    return 0
  fi
  if [[ -n "${JIGGIT_JIRA_BEARER_TOKEN_BY_NAME["${jira_storage_name}"]:-}" ]]; then
    printf '%s\n' "${JIGGIT_JIRA_BEARER_TOKEN_BY_NAME["${jira_storage_name}"]}"
    return 0
  fi
  printf '%s\n' ""
}

# Return the effective Jira user email from config.
jira_user_email() {
  local jira_name
  local jira_storage_name
  jira_name="$(resolve_jira_name "${1:-}")"
  [[ -n "${jira_name}" ]] || { printf '%s\n' ""; return 0; }
  jira_storage_name="$(jiggit_jira_storage_name "${jira_name}")"
  if [[ "${jira_storage_name}" == "${JIGGIT_SHARED_JIRA_NAME}" && -n "${JIRA_USER_EMAIL:-}" ]]; then
    printf '%s\n' "${JIRA_USER_EMAIL}"
    return 0
  fi
  if [[ -n "${JIGGIT_JIRA_USER_EMAIL_BY_NAME["${jira_storage_name}"]:-}" ]]; then
    printf '%s\n' "${JIGGIT_JIRA_USER_EMAIL_BY_NAME["${jira_storage_name}"]}"
    return 0
  fi
  printf '%s\n' ""
}

# Return the effective Jira API token from config.
jira_api_token() {
  local jira_name
  local jira_storage_name
  jira_name="$(resolve_jira_name "${1:-}")"
  [[ -n "${jira_name}" ]] || { printf '%s\n' ""; return 0; }
  jira_storage_name="$(jiggit_jira_storage_name "${jira_name}")"
  if [[ "${jira_storage_name}" == "${JIGGIT_SHARED_JIRA_NAME}" && -n "${JIRA_API_TOKEN:-}" ]]; then
    printf '%s\n' "${JIRA_API_TOKEN}"
    return 0
  fi
  if [[ -n "${JIGGIT_JIRA_API_TOKEN_BY_NAME["${jira_storage_name}"]:-}" ]]; then
    printf '%s\n' "${JIGGIT_JIRA_API_TOKEN_BY_NAME["${jira_storage_name}"]}"
    return 0
  fi
  printf '%s\n' ""
}

# Return the source for one effective Jira field, including env overrides.
jira_field_source() {
  local reference="${1:-}"
  local field_name="${2:-}"
  local jira_name=""
  local jira_storage_name=""

  jira_name="$(resolve_jira_name "${reference}")"
  [[ -n "${jira_name}" ]] || { printf '%s\n' "none"; return 0; }
  jira_storage_name="$(jiggit_jira_storage_name "${jira_name}")"

  case "${field_name}" in
    base_url)
      if [[ "${jira_storage_name}" == "${JIGGIT_SHARED_JIRA_NAME}" && -n "${JIRA_BASE_URL:-}" ]]; then
        printf '%s\n' "env: JIRA_BASE_URL"
        return 0
      fi
      printf '%s\n' "${JIGGIT_JIRA_BASE_URL_SOURCE_BY_NAME["${jira_storage_name}"]:-none}"
      ;;
    bearer_token)
      if [[ "${jira_storage_name}" == "${JIGGIT_SHARED_JIRA_NAME}" && -n "${JIRA_BEARER_TOKEN:-}" ]]; then
        printf '%s\n' "env: JIRA_BEARER_TOKEN"
        return 0
      fi
      if [[ "${jira_storage_name}" == "${JIGGIT_SHARED_JIRA_NAME}" && -n "${JIRA_API_TOKEN:-}" ]]; then
        printf '%s\n' "env: JIRA_API_TOKEN"
        return 0
      fi
      printf '%s\n' "${JIGGIT_JIRA_BEARER_TOKEN_SOURCE_BY_NAME["${jira_storage_name}"]:-none}"
      ;;
    user_email)
      if [[ "${jira_storage_name}" == "${JIGGIT_SHARED_JIRA_NAME}" && -n "${JIRA_USER_EMAIL:-}" ]]; then
        printf '%s\n' "env: JIRA_USER_EMAIL"
        return 0
      fi
      printf '%s\n' "${JIGGIT_JIRA_USER_EMAIL_SOURCE_BY_NAME["${jira_storage_name}"]:-none}"
      ;;
    api_token)
      if [[ "${jira_storage_name}" == "${JIGGIT_SHARED_JIRA_NAME}" && -n "${JIRA_API_TOKEN:-}" ]]; then
        printf '%s\n' "env: JIRA_API_TOKEN"
        return 0
      fi
      printf '%s\n' "${JIGGIT_JIRA_API_TOKEN_SOURCE_BY_NAME["${jira_storage_name}"]:-none}"
      ;;
    *)
      printf '%s\n' "${JIGGIT_JIRA_SOURCE_BY_NAME["${jira_storage_name}"]:-none}"
      ;;
  esac
}

# Return the effective Jira auth mode from config.
jira_auth_mode() {
  local reference="${1:-}"

  if [[ -n "$(jira_bearer_token "${reference}")" ]]; then
    printf '%s\n' 'bearer_token'
    return 0
  fi

  if [[ -n "$(jira_user_email "${reference}")" && -n "$(jira_api_token "${reference}")" ]]; then
    printf '%s\n' 'basic_auth'
    return 0
  fi

  printf '%s\n' 'missing'
}

# Return the effective shared Jira API token status from config.
jira_api_token_status() {
  local reference="${1:-}"

  if [[ -n "$(jira_api_token "${reference}")" ]]; then
    printf '%s\n' 'set'
    return 0
  fi

  printf '%s\n' 'missing'
}

# Return one Jira field value or a stable missing marker for display output.
jira_display_value() {
  local reference="${1:-}"
  local field_name="${2:-}"
  local value=""

  case "${field_name}" in
    base_url)
      value="$(jira_base_url "${reference}")"
      ;;
    bearer_token)
      value="$(jira_bearer_token "${reference}")"
      ;;
    user_email)
      value="$(jira_user_email "${reference}")"
      ;;
    api_token)
      value="$(jira_api_token "${reference}")"
      ;;
    *)
      value=""
      ;;
  esac

  printf '%s\n' "${value:-missing}"
}

# Render a compact Jira config diagnostic block for one Jira reference.
render_jira_config_diagnostic() {
  local reference="${1:-}"
  local jira_name=""
  local jira_base_url_value=""
  local jira_base_url_source=""
  local jira_bearer_token_value=""
  local jira_bearer_token_source=""
  local jira_user_email_value=""
  local jira_user_email_source=""
  local jira_auth_mode_value=""
  local jira_auth_mode_source=""
  local jira_api_token_value=""
  local jira_api_token_source=""

  jira_name="$(resolve_jira_name "${reference}")"
  jira_base_url_value="$(jira_display_value "${reference}" "base_url")"
  jira_base_url_source="$(jira_field_source "${reference}" "base_url")"
  jira_bearer_token_value="$(jira_display_value "${reference}" "bearer_token")"
  jira_bearer_token_source="$(jira_field_source "${reference}" "bearer_token")"
  jira_user_email_value="$(jira_display_value "${reference}" "user_email")"
  jira_user_email_source="$(jira_field_source "${reference}" "user_email")"
  jira_auth_mode_value="$(jira_auth_mode "${reference}")"
  jira_api_token_value="$(jira_display_value "${reference}" "api_token")"
  jira_api_token_source="$(jira_field_source "${reference}" "api_token")"

  if [[ "${jira_auth_mode_value}" == "bearer_token" ]]; then
    jira_auth_mode_source="$(jira_field_source "${reference}" "bearer_token")"
  elif [[ "${jira_auth_mode_value}" == "basic_auth" ]]; then
    jira_auth_mode_source="$(jira_field_source "${reference}" "user_email"), $(jira_field_source "${reference}" "api_token")"
  else
    jira_auth_mode_source="none"
  fi

  printf -- "- Jira config: \`%s\`\n" "${jira_name:-missing}"
  printf -- "- Jira base URL: \`%s\` (%s)\n" "${jira_base_url_value}" "${jira_base_url_source}"
  printf -- "- Jira bearer token: \`%s\` (%s)\n" "${jira_bearer_token_value}" "${jira_bearer_token_source}"
  printf -- "- Jira user email: \`%s\` (%s)\n" "${jira_user_email_value}" "${jira_user_email_source}"
  printf -- "- Jira API token: \`%s\` (%s)\n" "${jira_api_token_value}" "${jira_api_token_source}"
  printf -- "- Jira auth mode: \`%s\` (%s)\n" "${jira_auth_mode_value}" "${jira_auth_mode_source}"
  printf -- "- Jira config source: \`%s\`\n" "$(jira_config_source "${reference}")"
}

# Return the source file that supplied one Jira config.
jira_config_source() {
  local jira_name
  jira_name="$(resolve_jira_name "${1:-}")"
  [[ -n "${jira_name}" ]] || { printf '%s\n' "none"; return 0; }
  printf '%s\n' "${JIGGIT_JIRA_SOURCE_BY_NAME["${jira_name}"]:-none}"
}

# Return the config file explore should update when creating shared Jira config.
explore_shared_jira_target_file() {
  local source_file

  source_file="$(jira_config_source)"
  if [[ -n "${source_file}" && "${source_file}" != "none" ]]; then
    printf '%s\n' "${source_file}"
    return 0
  fi

  if [[ -n "${JIGGIT_PROJECTS_FILE:-}" ]]; then
    printf '%s\n' "${JIGGIT_PROJECTS_FILE}"
    return 0
  fi

  printf '%s\n' "$(default_user_config_dir)/projects.toml"
}

# Append a minimal shared Jira config block to the chosen TOML file.
append_shared_jira_config_block() {
  local target_file="${1}"
  local jira_name="${2}"
  local jira_base_url_value="${3}"
  local jira_bearer_token_value="${4}"
  local section_name="jira"

  if [[ -n "${jira_name}" && "${jira_name}" != "default" ]]; then
    section_name="jira.${jira_name}"
  fi

  mkdir -p "$(dirname "${target_file}")"
  if [[ -s "${target_file}" ]]; then
    printf '\n' >> "${target_file}"
  fi

  {
    printf '[%s]\n' "${section_name}"
    printf 'base_url = "%s"\n' "${jira_base_url_value}"
    if [[ -n "${jira_bearer_token_value}" ]]; then
      printf 'bearer_token = "%s"\n' "${jira_bearer_token_value}"
    else
      printf '%s\n' 'bearer_token = ""'
    fi
  } >> "${target_file}"
}

# Escape one string value for a minimal TOML double-quoted literal.
toml_quote_string() {
  local value="${1:-}"

  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"\n' "${value}"
}

# Insert or replace one string key inside a named TOML section.
upsert_toml_string_in_section() {
  local target_file="${1}"
  local section_name="${2}"
  local key_name="${3}"
  local raw_value="${4}"
  local temp_file="${target_file}.tmp"
  local quoted_value=""
  local rendered_line=""

  mkdir -p "$(dirname "${target_file}")"
  touch "${target_file}"

  quoted_value="$(toml_quote_string "${raw_value}")"
  rendered_line="${key_name} = ${quoted_value}"

  awk \
    -v section_header="[${section_name}]" \
    -v key_name="${key_name}" \
    -v rendered_line="${rendered_line}" '
      BEGIN {
        found_section = 0
        in_section = 0
        inserted = 0
        key_pattern = "^[[:space:]]*" key_name "[[:space:]]*="
      }
      {
        if ($0 == section_header) {
          found_section = 1
          in_section = 1
          print
          next
        }

        if (in_section && $0 ~ /^\[/) {
          if (!inserted) {
            print rendered_line
            inserted = 1
          }
          in_section = 0
        }

        if (in_section && $0 ~ key_pattern) {
          if (!inserted) {
            print rendered_line
            inserted = 1
          }
          next
        }

        print
      }
      END {
        if (in_section && !inserted) {
          print rendered_line
          inserted = 1
        }

        if (!found_section) {
          if (NR > 0) {
            print ""
          }
          print section_header
          print rendered_line
        }
      }
    ' "${target_file}" > "${temp_file}"

  mv "${temp_file}" "${target_file}"
}

# Interactively scaffold shared Jira config when explore detects it is missing.
explore_maybe_create_missing_shared_jira_config() {
  local target_file=""
  local jira_name="default"
  local jira_base_url_value=""
  local jira_bearer_token_value=""

  if [[ -n "$(jira_base_url)" ]]; then
    return 0
  fi

  if ! can_prompt_interactively; then
    return 0
  fi

  target_file="$(explore_shared_jira_target_file)"
  jira_base_url_value="$(prompt_input_line "Jira base URL for ${target_file} (leave empty to skip): ")"
  if [[ -n "${jira_base_url_value}" ]]; then
    jira_bearer_token_value="$(prompt_input_line "Jira bearer token (leave empty to fill later): ")"
    if prompt_confirm_toml_preview \
      "Shared Jira config is missing. About to append this block to ${target_file}:" \
      "$(render_shared_jira_config_preview "${jira_name}" "${jira_base_url_value}" "${jira_bearer_token_value}")"; then
      append_shared_jira_config_block "${target_file}" "${jira_name}" "${jira_base_url_value}" "${jira_bearer_token_value}"
    fi
  fi
}

# Canonicalize an existing directory path for stable project-path matching.
canonical_dir_path() {
  local input_path="${1:-}"

  if [[ -z "${input_path}" || ! -d "${input_path}" ]]; then
    return 1
  fi

  (
    cd "${input_path}" >/dev/null 2>&1 || exit 1
    pwd -P
  )
}

# Resolve the best repository-root-like path for a selector, preferring git top-level directories.
selector_repo_root_or_path() {
  local selector="${1:-}"
  local candidate_root=""

  if [[ -z "${selector}" ]]; then
    selector="."
  fi

  if [[ -d "${selector}" ]]; then
    candidate_root="$(git -C "${selector}" rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -n "${candidate_root}" ]]; then
      printf '%s\n' "${candidate_root}"
      return 0
    fi

    canonical_dir_path "${selector}"
    return 0
  fi

  return 1
}

# Print global project selectors configured through the top-level CLI.
global_project_selectors() {
  local raw_selectors="${JIGGIT_PROJECT_SELECTORS:-}"
  local selector=""
  local -a selectors=()

  if [[ -z "${raw_selectors}" ]]; then
    return 0
  fi

  IFS=',' read -r -a selectors <<< "${raw_selectors}"
  for selector in "${selectors[@]}"; do
    selector="$(trim "${selector}")"
    [[ -z "${selector}" ]] && continue
    printf '%s\n' "${selector}"
  done
}

# Return the default project scope when no explicit selectors were given.
default_project_scope() {
  local current_project_id=""

  current_project_id="$(resolve_project_selector "" || true)"
  if [[ -n "${current_project_id}" ]]; then
    if declare -F jiggit_verbose_log >/dev/null 2>&1; then
      jiggit_verbose_log "default project scope resolved current repo project ${current_project_id}"
    fi
    printf '%s\n' "${current_project_id}"
    return 0
  fi

  if declare -F jiggit_verbose_log >/dev/null 2>&1; then
    jiggit_verbose_log "default project scope falls back to all configured ids: ${JIGGIT_CONFIGURED_IDS[*]:-none}"
  fi
  printf '%s\n' "${JIGGIT_CONFIGURED_IDS[@]}"
}

# Resolve a configured project id from either a project id, a path selector, or the current directory.
resolve_project_selector() {
  local selector="${1:-}"
  local selector_root=""
  local project_id
  local configured_repo_path=""
  local configured_repo_root=""

  if [[ -n "${selector}" && "${selector}" != "." && "${selector}" != */* && -n "${JIGGIT_PROJECT_SOURCE_BY_ID["${selector}"]+x}" ]]; then
    printf '%s\n' "${selector}"
    return 0
  fi

  selector_root="$(selector_repo_root_or_path "${selector}")" || return 1
  for project_id in "${JIGGIT_CONFIGURED_IDS[@]}"; do
    configured_repo_path="$(project_repo_path "${project_id}")"
    [[ -z "${configured_repo_path}" ]] && continue

    configured_repo_root="$(selector_repo_root_or_path "${configured_repo_path}" || true)"
    if [[ -n "${configured_repo_root}" && "${configured_repo_root}" == "${selector_root}" ]]; then
      printf '%s\n' "${project_id}"
      return 0
    fi
  done

  return 1
}

# Resolve a single-project selector from explicit args, global flags, or cwd defaults.
effective_single_project_selector() {
  local explicit_selector="${1:-}"
  local -a global_selectors=()

  if [[ -n "${explicit_selector}" ]]; then
    printf '%s\n' "${explicit_selector}"
    return 0
  fi

  if [[ "${JIGGIT_ALL_PROJECTS:-0}" -eq 1 ]]; then
    printf 'This command does not support --all-projects.\n' >&2
    return 1
  fi

  mapfile -t global_selectors < <(global_project_selectors)
  if [[ ${#global_selectors[@]} -gt 1 ]]; then
    printf 'This command accepts only one project. Use a single selector in --projects=...\n' >&2
    return 1
  fi

  if [[ ${#global_selectors[@]} -eq 1 ]]; then
    printf '%s\n' "${global_selectors[0]}"
    return 0
  fi

  return 0
}

# Resolve multi-project targets from explicit args, global flags, or cwd defaults.
effective_multi_project_selectors() {
  local -a explicit_selectors=("$@")
  local -a global_selectors=()

  if [[ ${#explicit_selectors[@]} -gt 0 ]]; then
    if declare -F jiggit_verbose_log >/dev/null 2>&1; then
      jiggit_verbose_log "multi-project selectors from explicit args: ${explicit_selectors[*]}"
    fi
    printf '%s\n' "${explicit_selectors[@]}"
    return 0
  fi

  if [[ "${JIGGIT_ALL_PROJECTS:-0}" -eq 1 ]]; then
    if declare -F jiggit_verbose_log >/dev/null 2>&1; then
      jiggit_verbose_log "multi-project selectors from --all-projects: ${JIGGIT_CONFIGURED_IDS[*]:-none}"
    fi
    printf '%s\n' "${JIGGIT_CONFIGURED_IDS[@]}"
    return 0
  fi

  mapfile -t global_selectors < <(global_project_selectors)
  if [[ ${#global_selectors[@]} -gt 0 ]]; then
    if declare -F jiggit_verbose_log >/dev/null 2>&1; then
      jiggit_verbose_log "multi-project selectors from --projects: ${global_selectors[*]}"
    fi
    printf '%s\n' "${global_selectors[@]}"
    return 0
  fi

  if declare -F jiggit_verbose_log >/dev/null 2>&1; then
    jiggit_verbose_log "multi-project selectors from default scope"
  fi
  default_project_scope
}

# Convert a repository name into a stable lowercase project id.
slugify_repo_name() {
  local input="${1:-project}"
  local slug

  slug=$(printf '%s' "${input}" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-{2,}/-/g')

  if [[ -z "${slug}" ]]; then
    slug="project"
  fi

  printf '%s\n' "${slug}"
}

# Shell-quote a value for legacy shell config serialization.
shell_quote() {
  printf "%q" "${1:-}"
}

# Resolve a repository root from a discovered .git file or directory.
repo_root_from_git_entry() {
  local git_entry="${1}"
  local candidate
  local repo_root

  candidate="$(dirname "${git_entry}")"
  if repo_root=$(git -C "${candidate}" rev-parse --show-toplevel 2>/dev/null); then
    printf '%s\n' "${repo_root}"
    return 0
  fi

  return 1
}

# Recursively find git repositories below the provided directories.
find_git_repos() {
  local search_root
  local git_entry
  local repo_root
  local -A seen=()

  for search_root in "$@"; do
    explore_debug "Scanning ${search_root}"
    if [[ ! -d "${search_root}" ]]; then
      JIGGIT_DISCOVERY_WARNINGS+=("Skipping missing directory: ${search_root}")
      continue
    fi

    explore_run_log "find ${search_root} \\( -name .git -type d -o -name .git -type f \\) -print"
    while IFS= read -r git_entry; do
      if ! repo_root=$(repo_root_from_git_entry "${git_entry}"); then
        continue
      fi

      if [[ -z "${seen["${repo_root}"]+x}" ]]; then
        seen["${repo_root}"]=1
        explore_debug "Found git repo ${repo_root}"
        printf '%s\n' "${repo_root}"
      fi
    done < <(find "${search_root}" \( -name .git -type d -o -name .git -type f \) -print 2>/dev/null | sort)
  done
}

# Return the origin remote URL for a repository when available.
git_origin_url() {
  local repo="${1}"
  explore_run_log "git -C ${repo} remote get-url origin"
  git -C "${repo}" remote get-url origin 2>/dev/null || true
}

# Return up to five recent-looking tags for repository summary output.
sample_tags() {
  local repo="${1}"
  local tag
  local count=0
  local -a tags=()

  explore_run_log "git -C ${repo} tag --sort=-version:refname"
  while IFS= read -r tag; do
    tags+=("${tag}")
    count=$((count + 1))
    if [[ ${count} -ge 5 ]]; then
      break
    fi
  done < <(git -C "${repo}" tag --sort=-version:refname 2>/dev/null || true)

  IFS=, printf '%s\n' "${tags[*]:-}"
}

# Return up to two recent commit subjects for repository summary output.
sample_commits() {
  local repo="${1}"
  local commit_subject
  local count=0

  explore_run_log "git -C ${repo} log --format=%s -n 2"
  while IFS= read -r commit_subject; do
    printf '%s\n' "${commit_subject}"
    count=$((count + 1))
    if [[ ${count} -ge 2 ]]; then
      break
    fi
  done < <(git -C "${repo}" log --format='%s' -n 2 2>/dev/null || true)
}

# Infer likely Jira issue regexes from recent commit history.
detect_jira_regexes() {
  local repo="${1}"
  local matches
  local prefixes
  local regexes=()
  local prefix

  explore_run_log "git -C ${repo} log --format=%B -n 200"
  matches=$(git -C "${repo}" log --format='%B' -n 200 2>/dev/null \
    | grep -oE "${JIGGIT_FALLBACK_JIRA_REGEX}" \
    | sort -u || true)

  if [[ -z "${matches}" ]]; then
    printf '%s\n' ""
    return 0
  fi

  prefixes=$(printf '%s\n' "${matches}" | cut -d- -f1 | sort -u)
  while IFS= read -r prefix; do
    prefix="$(trim "${prefix}")"
    if [[ -z "${prefix}" ]]; then
      continue
    fi
    regexes+=("${prefix}-[0-9]+")
  done <<< "${prefixes}"

  printf '%s\n' "${regexes[*]}"
}

# Compare a repo against loaded config and classify it as new, configured, or ambiguous.
configured_status_for_repo() {
  local repo_path="${1}"
  local remote_url="${2}"
  local path_id=""
  local remote_id=""
  local project_id=""

  for project_id in "${JIGGIT_CONFIGURED_IDS[@]:-}"; do
    if [[ -z "${path_id}" && "$(project_repo_path "${project_id}")" == "${repo_path}" ]]; then
      path_id="${project_id}"
    fi

    if [[ -n "${remote_url}" && -z "${remote_id}" && "$(project_remote_url "${project_id}")" == "${remote_url}" ]]; then
      remote_id="${project_id}"
    fi

    if [[ -n "${path_id}" && -n "${remote_id}" ]]; then
      break
    fi
  done

  if [[ -n "${path_id}" && -n "${remote_id}" && "${path_id}" != "${remote_id}" ]]; then
    printf 'ambiguous\n'
    return 0
  fi

  if [[ -n "${path_id}" || -n "${remote_id}" ]]; then
    printf 'already-configured\n'
    return 0
  fi

  printf 'newly-discovered\n'
}

# Join arguments with a caller-provided separator.
join_by() {
  local separator="${1}"
  shift || true
  local first=1
  local item

  for item in "$@"; do
    if [[ ${first} -eq 1 ]]; then
      printf '%s' "${item}"
      first=0
    else
      printf '%s%s' "${separator}" "${item}"
    fi
  done
}

# Render one discovered project as TOML for the discovery file.
build_candidate_entry() {
  local repo_path="${1}"
  local remote_url="${2}"
  local repo_name="${3}"
  local jira_regexes="${4}"
  local jira_project_key="${5:-}"
  local environments="${6:-}"
  local environment_info_urls="${7:-}"
  local info_version_expr="${8:-}"

  local project_id
  local regex_field
  local environment_name
  local environment_url
  local pair
  local first_entry=1

  project_id="$(slugify_repo_name "${repo_name}")"
  regex_field="${jira_regexes:-${JIGGIT_FALLBACK_JIRA_REGEX}}"

  cat <<EOF
[${project_id}]
repo_path = "$(printf '%s' "${repo_path}" | sed 's/\\/\\\\/g; s/"/\\"/g')"
remote_url = "$(printf '%s' "${remote_url}" | sed 's/\\/\\\\/g; s/"/\\"/g')"
jira_project_key = "$(printf '%s' "${jira_project_key}" | sed 's/\\/\\\\/g; s/"/\\"/g')"
jira_regexes = ["$(printf '%s' "${regex_field}" | sed 's/\\/\\\\/g; s/"/\\"/g')"]
EOF

  if [[ -n "${environments}" ]]; then
    printf 'environments = ['
    for environment_name in ${environments}; do
      if [[ "${first_entry}" -eq 0 ]]; then
        printf ', '
      fi
      printf '"%s"' "$(printf '%s' "${environment_name}" | sed 's/\\/\\\\/g; s/"/\\"/g')"
      first_entry=0
    done
    printf ']\n'
  else
    printf '%s\n' 'environments = []'
  fi

  if [[ -n "${info_version_expr}" ]]; then
    printf 'info_version_expr = "%s"\n' "$(printf '%s' "${info_version_expr}" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  fi

  if [[ -n "${environment_info_urls}" ]]; then
    printf '\n[%s.environment_info_urls]\n' "${project_id}"
    for environment_name in ${environments}; do
      environment_url=""
      for pair in ${environment_info_urls}; do
        if [[ "${pair%%=*}" == "${environment_name}" ]]; then
          environment_url="${pair#*=}"
          break
        fi
      done
      if [[ -n "${environment_url}" ]]; then
        printf '%s = "%s"\n' "${environment_name}" "$(printf '%s' "${environment_url}" | sed 's/\\/\\\\/g; s/"/\\"/g')"
      fi
    done
  fi
}

# Prompt for additional config values for a newly discovered project candidate.
collect_candidate_completion() {
  local project_id="${1}"
  local jira_project_key=""
  local environments=""
  local environment_name=""
  local environment_url=""
  local environment_info_urls=""
  local info_version_expr=""
  if ! can_prompt_interactively; then
    printf '\n\n\n'
    return 0
  fi

  jira_project_key="$(prompt_input_line "Jira project key for ${project_id} (leave empty to skip): ")"

  environments="$(prompt_input_line "Configured environments for ${project_id} (space-separated, leave empty to skip): ")"
  environments="$(trim "${environments}")"

  for environment_name in ${environments}; do
    environment_url="$(prompt_input_line "Info URL for ${project_id} ${environment_name} (leave empty to skip): ")"
    if [[ -n "${environment_url}" ]]; then
      environment_info_urls="$(join_space "${environment_info_urls}" "${environment_name}=${environment_url}")"
    fi
  done

  if [[ -n "${environments}" ]]; then
    info_version_expr="$(prompt_input_line "Version extraction expression for ${project_id} [cat]: ")"
    info_version_expr="${info_version_expr:-cat}"
  fi

  printf '%s\n%s\n%s\n%s\n' "${jira_project_key}" "${environments}" "${environment_info_urls}" "${info_version_expr}"
}

# Extract a project id from the first TOML table line in a candidate entry.
candidate_project_id() {
  local entry="${1:-}"
  local first_line

  first_line="$(printf '%s\n' "${entry}" | sed -n '1p')"
  first_line="${first_line#[}"
  first_line="${first_line%]}"
  printf '%s\n' "${first_line}"
}

# Initialize the discovery file with a standard header when it does not exist yet.
ensure_discovery_file_header() {
  local output_file="${1}"

  if [[ -f "${output_file}" ]]; then
    return 0
  fi

  {
    printf '%s\n' '# Generated candidate project entries from jiggit explore.'
    printf '%s\n' '# Review before merging into a curated config file.'
    printf '\n'
  } > "${output_file}"
}

# Ask interactively whether a discovered entry should be appended to the discovery file.
render_candidate_append_prompt() {
  local output_file="${1}"
  local entry="${2}"
  local project_id

  project_id="$(candidate_project_id "${entry}")"
  printf 'About to append discovered project %s to %s.\n' "${project_id}" "${output_file}"
  printf 'Do you want to add the following section? [y/N/q]:\n'
  printf '%s\n' "${entry}"
}

# Ask interactively whether a discovered entry should be appended to the discovery file.
prompt_append_candidate_entry() {
  local output_file="${1}"
  local entry="${2}"
  local choice

  render_candidate_append_prompt "${output_file}" "${entry}" >&2
  choice="$(prompt_input_line)"

  case "${choice}" in
    y|Y)
      return 0
      ;;
    q|Q)
      return 2
      ;;
    *)
      return 1
      ;;
  esac
}

# Write or append the discovery TOML file, defaulting to interactive per-entry append.
write_discovery_file() {
  local output_file
  local -a candidate_entries=("$@")
  local entry
  local write_mode="${JIGGIT_EXPLORE_WRITE_MODE:-}"
  local wrote_any=0

  output_file="$(resolve_discovery_file_path)"
  if [[ ! -d "$(dirname "${output_file}")" ]]; then
    explore_debug "Creating discovery directory $(dirname "${output_file}")"
  fi
  mkdir -p "$(dirname "${output_file}")"

  if [[ -z "${write_mode}" ]]; then
    if can_prompt_interactively; then
      write_mode="interactive-append"
    else
      if [[ -f "${output_file}" && -s "${output_file}" ]]; then
        printf 'Discovery file already exists: %s\n' "${output_file}" >&2
      else
        printf 'Discovery file will be created at: %s\n' "${output_file}" >&2
      fi
      printf 'Interactive append is the default. Re-run interactively, or use --append, --replace, or --dry-run.\n' >&2
      return 1
    fi
  fi

  explore_debug "Writing discovery file ${output_file} with mode=${write_mode}"

  if [[ "${write_mode}" == "interactive-append" ]]; then
    ensure_discovery_file_header "${output_file}"
    for entry in "${candidate_entries[@]}"; do
      if prompt_append_candidate_entry "${output_file}" "${entry}"; then
        {
          printf '%s\n' "${entry}"
          printf '\n'
        } >> "${output_file}"
        wrote_any=1
      else
        case "$?" in
          2)
            printf 'Aborted.\n' >&2
            break
            ;;
        esac
      fi
    done
  elif [[ "${write_mode}" == "append" ]]; then
    ensure_discovery_file_header "${output_file}"
    {
      printf '\n'
      for entry in "${candidate_entries[@]}"; do
        printf '%s\n' "${entry}"
        printf '\n'
      done
    } >> "${output_file}"
    wrote_any=1
  else
    {
      printf '%s\n' '# Generated candidate project entries from jiggit explore.'
      printf '%s\n' '# Review before merging into a curated config file.'
      printf '\n'
      for entry in "${candidate_entries[@]}"; do
        printf '%s\n' "${entry}"
        printf '\n'
      done
    } > "${output_file}"
    wrote_any=1
  fi

  if [[ ${wrote_any} -eq 0 ]]; then
    explore_debug "No discovery entries were written"
  fi

  printf '%s\n' "${output_file}"
}

# Return the effective path that explore will use for discovery output.
resolve_discovery_file_path() {
  default_user_discovered_file
}

# Render the Markdown summary printed at the end of explore.
render_explore_summary() {
  local output_file="${1}"
  local discovered_count="${2}"
  local configured_count="${3}"
  local ambiguous_count="${4}"
  local dry_run="${5}"
  shift 5 || true
  local -a repo_lines=("$@")
  local warning
  local line

  print_markdown_h1 "jiggit setup explore"
  printf '\n'
  printf -- "- Discovery file: \`%s\`\n" "${output_file}"
  if [[ "${dry_run}" -eq 1 ]]; then
    printf -- "- Mode: \`dry-run\`\n"
  fi
  printf -- '- Newly discovered: %s\n' "${discovered_count}"
  printf -- '- Already configured: %s\n' "${configured_count}"
  printf -- '- Ambiguous: %s\n' "${ambiguous_count}"
  printf '\n'
  print_markdown_h2 "Repositories" "${C_BLUE}"
  printf '\n'

  if [[ ${#repo_lines[@]} -eq 0 ]]; then
    printf '_No repositories found._\n'
  else
    for line in "${repo_lines[@]}"; do
      printf '%s\n' "${line}"
    done
  fi

  if [[ ${#JIGGIT_DISCOVERY_WARNINGS[@]} -gt 0 ]]; then
    printf '\n'
    print_markdown_h2 "Warnings" "${C_ORANGE}"
    printf '\n'
    for warning in "${JIGGIT_DISCOVERY_WARNINGS[@]}"; do
      printf -- '- %s\n' "${warning}"
    done
  fi
}

# Parse explore flags and positional directory arguments.
parse_explore_args() {
  local arg

  JIGGIT_EXPLORE_VERBOSE=0
  JIGGIT_EXPLORE_DRY_RUN=0
  JIGGIT_EXPLORE_WRITE_MODE=""
  JIGGIT_EXPLORE_DIRECTORIES=()

  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "${arg}" in
      --verbose)
        JIGGIT_EXPLORE_VERBOSE=1
        ;;
      --dry-run)
        JIGGIT_EXPLORE_DRY_RUN=1
        ;;
      --append)
        JIGGIT_EXPLORE_WRITE_MODE="append"
        ;;
      --replace)
        JIGGIT_EXPLORE_WRITE_MODE="replace"
        ;;
      -h|--help)
        explore_usage
        return 2
        ;;
      --)
        shift
        while [[ $# -gt 0 ]]; do
          JIGGIT_EXPLORE_DIRECTORIES+=("$1")
          shift
        done
        break
        ;;
      -*)
        printf 'Unknown option for explore: %s\n' "${arg}" >&2
        explore_usage >&2
        return 1
        ;;
      *)
        JIGGIT_EXPLORE_DIRECTORIES+=("${arg}")
        ;;
    esac
    shift
  done

  if [[ ${#JIGGIT_EXPLORE_DIRECTORIES[@]} -eq 0 ]]; then
    explore_usage >&2
    return 1
  fi
}

# Execute repository discovery, config comparison, and optional discovery-file writing.
run_explore_main() {
  local parse_status=0
  parse_explore_args "$@" || parse_status=$?
  if [[ ${parse_status} -eq 2 ]]; then
    return 0
  fi
  if [[ ${parse_status} -ne 0 ]]; then
    return "${parse_status}"
  fi

  local repo
  local remote_url
  local repo_name
  local status
  local jira_regexes
  local tags
  local commits
  local candidate_entry
  local -a candidate_completion=()
  local candidate_jira_project_key
  local candidate_environments
  local candidate_environment_info_urls
  local candidate_info_version_expr
  local -a candidate_entries=()
  local -a repo_lines=()
  local discovered_count=0
  local configured_count=0
  local ambiguous_count=0
  local output_file

  JIGGIT_DISCOVERY_WARNINGS=()
  mapfile -t JIGGIT_DISCOVERED_REPOS < <(find_git_repos "${JIGGIT_EXPLORE_DIRECTORIES[@]}")
  load_project_config "${JIGGIT_DISCOVERED_REPOS[@]}"
  explore_maybe_create_missing_shared_jira_config
  load_project_config "${JIGGIT_DISCOVERED_REPOS[@]}"

  for repo in "${JIGGIT_DISCOVERED_REPOS[@]}"; do
    remote_url="$(git_origin_url "${repo}")"
    repo_name="$(basename "${repo}")"
    jira_regexes="$(detect_jira_regexes "${repo}")"
    status="$(configured_status_for_repo "${repo}" "${remote_url}")"
    tags="$(sample_tags "${repo}")"
    commits="$(sample_commits "${repo}" | paste -sd ' | ' -)"
    explore_debug "Inspecting ${repo_name}: status=${status} origin=${remote_url:-missing}"

    if [[ "${status}" == "already-configured" ]]; then
      configured_count=$((configured_count + 1))
    elif [[ "${status}" == "ambiguous" ]]; then
      ambiguous_count=$((ambiguous_count + 1))
      JIGGIT_DISCOVERY_WARNINGS+=("Ambiguous existing config match for ${repo}")
    else
      discovered_count=$((discovered_count + 1))
      mapfile -t candidate_completion < <(collect_candidate_completion "$(slugify_repo_name "${repo_name}")")
      candidate_jira_project_key="${candidate_completion[0]:-}"
      candidate_environments="${candidate_completion[1]:-}"
      candidate_environment_info_urls="${candidate_completion[2]:-}"
      candidate_info_version_expr="${candidate_completion[3]:-}"
      candidate_entry="$(build_candidate_entry "${repo}" "${remote_url}" "${repo_name}" "${jira_regexes}" "${candidate_jira_project_key}" "${candidate_environments}" "${candidate_environment_info_urls}" "${candidate_info_version_expr}")"
      candidate_entries+=("${candidate_entry}")
    fi

    if [[ -n "${jira_regexes}" && "${jira_regexes}" == *" "* ]]; then
      JIGGIT_DISCOVERY_WARNINGS+=("Multiple Jira key prefixes detected for ${repo}: ${jira_regexes}")
    fi

    repo_lines+=("- \`${repo_name}\`")
    repo_lines+=("  - status: \`${status}\`")
    repo_lines+=("  - path: \`${repo}\`")
    repo_lines+=("  - origin: \`${remote_url:-missing}\`")
    repo_lines+=("  - tags: \`${tags:-none}\`")
    repo_lines+=("  - jira regexes: \`${jira_regexes:-${JIGGIT_FALLBACK_JIRA_REGEX}}\`")
    repo_lines+=("  - sample commits: \`${commits:-none}\`")
  done

  output_file="$(resolve_discovery_file_path)"
  if [[ "${JIGGIT_EXPLORE_DRY_RUN}" -eq 0 ]]; then
    output_file="$(write_discovery_file "${candidate_entries[@]}")"
  else
    explore_debug "Dry run enabled; not writing ${output_file}"
  fi

  render_explore_summary "${output_file}" "${discovered_count}" "${configured_count}" "${ambiguous_count}" "${JIGGIT_EXPLORE_DRY_RUN}" "${repo_lines[@]}"
}
