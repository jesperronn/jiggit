#!/usr/bin/env bash

set -euo pipefail

if ! declare -F load_project_config >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/explore.sh"
fi

if ! declare -F print_markdown_h1 >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/common_output.sh"
fi

if ! declare -F require_program >/dev/null 2>&1 || ! declare -F jira_auth_args >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/jira_create.sh"
fi

if ! declare -F compare_issue_keys >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/compare_command.sh"
fi

: "${JIGGIT_DEFAULT_INFO_VERSION_EXPR:=cat}"
JIGGIT_ENV_VERSIONS_VERBOSE=0

# Print verbose logs for env-versions when requested.
env_versions_debug() {
  if [[ "${JIGGIT_ENV_VERSIONS_VERBOSE:-0}" -eq 1 ]]; then
    printf '[env-versions] %s\n' "$*" >&2
  fi
}

# Render help for the env-versions subcommand.
env_versions_usage() {
  print_jiggit_usage_block <<'EOF'
Usage:
  jiggit env-versions [<project|path>] [--verbose]

Show deployed versions for the project's configured environments.
EOF
}

# Return the info URL configured for one environment on a project.
project_environment_info_url() {
  local project_id="${1}"
  local environment_name="${2}"
  local pair
  local pairs

  pairs="$(project_environment_info_urls "${project_id}")"
  for pair in ${pairs}; do
    if [[ "${pair%%=*}" == "${environment_name}" ]]; then
      printf '%s\n' "${pair#*=}"
      return 0
    fi
  done

  printf '%s\n' ""
}

# Return the extraction command used to derive the version field for a project.
env_versions_expr_for_project() {
  local project_id="${1}"
  local version_expr

  version_expr="$(project_info_version_expr "${project_id}")"
  if [[ -n "${version_expr}" ]]; then
    printf '%s\n' "${version_expr}"
  else
    printf '%s\n' "${JIGGIT_DEFAULT_INFO_VERSION_EXPR}"
  fi
}

# Normalize info-endpoint version strings into comparable git tag refs.
# This trims git-describe suffixes like -0-ga44eff0 down to the tag portion.
normalize_info_version_string() {
  local raw_version="${1:-}"
  local trimmed_version

  trimmed_version="$(trim "${raw_version}")"
  if [[ "${trimmed_version}" == *-* ]]; then
    printf '%s\n' "${trimmed_version%%-*}"
  else
    printf '%s\n' "${trimmed_version}"
  fi
}

# Suggest the next minor version while preserving the original segment count.
env_versions_bump_minor_version() {
  local version_ref="${1:-}"
  local version_core="${version_ref#v}"
  local had_v_prefix=0
  local -a parts=()
  local index=0

  if [[ "${version_ref}" == v* ]]; then
    had_v_prefix=1
  fi

  IFS='.' read -r -a parts <<< "${version_core}"
  if [[ "${#parts[@]}" -eq 0 || ! "${parts[0]}" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  if [[ "${#parts[@]}" -lt 2 ]]; then
    parts+=(0)
  fi

  for index in "${!parts[@]}"; do
    if ! [[ "${parts[${index}]}" =~ ^[0-9]+$ ]]; then
      return 1
    fi
  done

  parts[1]=$((parts[1] + 1))
  for (( index=2; index<${#parts[@]}; index+=1 )); do
    parts[index]=0
  done

  if [[ "${had_v_prefix}" -eq 1 ]]; then
    printf 'v%s\n' "$(IFS=.; printf '%s' "${parts[*]}")"
  else
    printf '%s\n' "$(IFS=.; printf '%s' "${parts[*]}")"
  fi
}

# Return the best available git ref for the latest target branch.
default_target_git_ref() {
  local repo_path="${1}"
  local remote_head_ref=""
  local current_branch=""

  remote_head_ref="$(git -C "${repo_path}" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [[ -n "${remote_head_ref}" ]]; then
    printf '%s\n' "${remote_head_ref}"
    return 0
  fi

  if git -C "${repo_path}" show-ref --verify --quiet refs/remotes/origin/main; then
    printf 'refs/remotes/origin/main\n'
    return 0
  fi

  if git -C "${repo_path}" show-ref --verify --quiet refs/remotes/origin/master; then
    printf 'refs/remotes/origin/master\n'
    return 0
  fi

  current_branch="$(git -C "${repo_path}" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [[ -n "${current_branch}" ]]; then
    printf '%s\n' "${current_branch}"
    return 0
  fi

  printf 'HEAD\n'
}

# URL-encode a JQL fragment for Jira GET requests.
env_versions_url_encode() {
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

# Fetch Jira issue details for a list of issue keys.
fetch_jira_issues_by_keys() {
  local jira_base_url="${1}"
  local auth_reference="${2:-}"
  shift 2 || true
  local -a keys=("$@")
  local jql=""
  local joined_keys=""
  local encoded_jql=""
  local -a auth_args=()

  if [[ ${#keys[@]} -eq 0 ]]; then
    printf '{"issues":[]}\n'
    return 0
  fi

  joined_keys="$(printf '"%s",' "${keys[@]}")"
  joined_keys="${joined_keys%,}"
  jql="key in (${joined_keys}) ORDER BY key ASC"
  encoded_jql="$(env_versions_url_encode "${jql}")"
  mapfile -t auth_args < <(jira_auth_args "${auth_reference}")

  curl --silent --show-error --fail \
    "${auth_args[@]}" \
    -H "Accept: application/json" \
    "${jira_base_url%/}/rest/api/2/search?jql=${encoded_jql}&fields=summary,status,labels,fixVersions"
}

# Return the display value for one issue's fixVersion field.
jira_issue_fix_version_display() {
  local issue_json="${1}"

  printf '%s\n' "${issue_json}" | jq -r \
    'if (.fields.fixVersions // []) == [] then "MISSING" else (.fields.fixVersions | map(.name) | join(", ")) end'
}

# Fetch one deployed version from an environment info URL.
fetch_env_version_for_url() {
  local environment_name="${1}"
  local info_url="${2}"
  local version_expr="${3}"
  local response
  local version

  env_versions_debug "Fetching ${environment_name} from ${info_url}"
  if ! response="$(curl -fsS --max-time 10 "${info_url}" 2>/dev/null)"; then
    printf 'ERROR: unable to fetch %s\n' "${info_url}"
    return 1
  fi

  if ! version="$(printf '%s' "${response}" | eval "${version_expr}" 2>/dev/null)"; then
    printf 'ERROR: unable to parse response using expression %s\n' "${version_expr}"
    return 1
  fi

  if [[ -z "${version}" ]]; then
    printf 'ERROR: empty version value in %s\n' "${info_url}"
    return 1
  fi

  printf '%s\n' "${version}"
}

# Resolve one project's deployed version for a named environment using configured URL and jq settings.
fetch_project_environment_version() {
  local project_id="${1}"
  local environment_name="${2}"
  local version_expr
  local info_url

  version_expr="$(env_versions_expr_for_project "${project_id}")"
  info_url="$(project_environment_info_url "${project_id}" "${environment_name}")"

  if [[ -z "${info_url}" ]]; then
    printf 'ERROR: missing info URL in config\n'
    return 1
  fi

  local raw_version

  if ! raw_version="$(fetch_env_version_for_url "${environment_name}" "${info_url}" "${version_expr}")"; then
    printf '%s\n' "${raw_version}"
    return 1
  fi

  normalize_info_version_string "${raw_version}"
}

# Render one environment version line in the Markdown report.
render_env_version_entry() {
  local environment_name="${1}"
  local version_or_error="${2}"
  local info_url="${3}"
  local label_width="${4:-0}"
  local padded_name="${environment_name}"
  local rendered_line=""

  if [[ "${label_width}" -gt 0 ]]; then
    printf -v padded_name "%-${label_width}s" "${environment_name}"
  fi

  if [[ "${version_or_error}" == ERROR:* ]]; then
    printf -v rendered_line -- "- \`%s\`: \`%s\` from \`%s\`" "${padded_name}" "${version_or_error}" "${info_url}"
    if use_color_output; then
      print_colored_line "${C_ORANGE}" "${rendered_line}"
    else
      printf '%s\n' "${rendered_line}"
    fi
  else
    printf -v rendered_line -- "- \`%s\`: \`%s\` from \`%s\`" "${padded_name}" "${version_or_error}" "${info_url}"
    printf '%s\n' "${rendered_line}"
  fi
}

# Return the normalized numeric version core without a leading v prefix.
env_version_core() {
  local version="${1:-}"
  printf '%s\n' "${version#v}"
}

# Return the major.minor prefix for a normalized version string.
env_version_major_minor() {
  local version="${1:-}"
  local core=""
  local -a parts=()

  core="$(env_version_core "${version}")"
  IFS='.' read -r -a parts <<< "${core}"
  if [[ "${#parts[@]}" -lt 2 ]]; then
    return 1
  fi
  printf '%s.%s\n' "${parts[0]}" "${parts[1]}"
}

# Compare two major.minor strings numerically.
compare_major_minor_versions() {
  local left="${1:-}"
  local right="${2:-}"
  local left_major="${left%%.*}"
  local left_minor="${left#*.}"
  local right_major="${right%%.*}"
  local right_minor="${right#*.}"

  if (( left_major > right_major )); then
    printf '%s\n' "gt"
    return 0
  fi
  if (( left_major < right_major )); then
    printf '%s\n' "lt"
    return 0
  fi
  if (( left_minor > right_minor )); then
    printf '%s\n' "gt"
    return 0
  fi
  if (( left_minor < right_minor )); then
    printf '%s\n' "lt"
    return 0
  fi
  printf '%s\n' "eq"
}

# Classify how one environment version relates to production.
classify_env_version_against_prod() {
  local prod_version="${1:-}"
  local other_version="${2:-}"
  local prod_mm=""
  local other_mm=""
  local mm_cmp=""

  prod_mm="$(env_version_major_minor "${prod_version}" || true)"
  other_mm="$(env_version_major_minor "${other_version}" || true)"
  if [[ -z "${prod_mm}" || -z "${other_mm}" ]]; then
    printf '%s\n' "unknown"
    return 0
  fi

  mm_cmp="$(compare_major_minor_versions "${other_mm}" "${prod_mm}")"
  case "${mm_cmp}" in
    eq)
      if [[ "${other_version}" != "${prod_version}" ]]; then
        printf '%s\n' "same-minor-different-build"
      else
        printf '%s\n' "same-version"
      fi
      ;;
    gt)
      printf '%s\n' "ahead-major-minor"
      ;;
    lt)
      printf '%s\n' "behind-major-minor"
      ;;
  esac
}

# Render production-relative drift diagnostics for the configured environments.
render_env_version_diagnostics() {
  local project_id="${1}"
  local prod_version="${2:-}"
  shift 2
  local -a env_entries=("$@")
  local entry=""
  local environment_name=""
  local version=""
  local relation=""
  local showed_any=0

  if [[ -z "${prod_version}" ]]; then
    return 0
  fi

  print_markdown_h2 "Diagnostics" "${C_MAGENTA}"
  printf '\n'

  for entry in "${env_entries[@]}"; do
    environment_name="${entry%%=*}"
    version="${entry#*=}"
    [[ "${environment_name}" == "prod" ]] && continue
    [[ "${version}" == ERROR:* ]] && continue

    relation="$(classify_env_version_against_prod "${prod_version}" "${version}")"
    case "${relation}" in
      same-minor-different-build)
        print_colored_line "${C_RED}" "- ${environment_name}: ahead of prod within the same minor (${version} vs ${prod_version}); new minor release needed"
        showed_any=1
        ;;
      ahead-major-minor)
        print_colored_line "${C_ORANGE}" "- ${environment_name}: ahead of prod at major/minor level (${version} vs ${prod_version}); pending deployment"
        showed_any=1
        ;;
      behind-major-minor)
        print_colored_line "${C_CYAN}" "- ${environment_name}: behind prod at major/minor level (${version} vs ${prod_version})"
        showed_any=1
        ;;
    esac
  done

  if [[ "${showed_any}" -eq 0 ]]; then
    printf '_No production drift diagnostics._\n'
  fi
  printf '\n'
  print_markdown_h2 "Next Steps" "${C_CYAN}"
  printf '\n'
  printf -- "- compare production with the default target: \`jiggit changes %s --base prod\`\n" "${project_id}"
  printf -- "- review the next release suggestion: \`jiggit next-release %s\`\n\n" "${project_id}"
}

# Return success when any non-prod environment is ahead of production.
env_versions_has_release_drift() {
  local prod_version="${1:-}"
  shift || true
  local -a env_entries=("$@")
  local entry=""
  local environment_name=""
  local version=""
  local relation=""

  [[ -z "${prod_version}" ]] && return 1

  for entry in "${env_entries[@]}"; do
    environment_name="${entry%%=*}"
    version="${entry#*=}"
    [[ "${environment_name}" == "prod" ]] && continue
    [[ "${version}" == ERROR:* ]] && continue
    relation="$(classify_env_version_against_prod "${prod_version}" "${version}")"
    case "${relation}" in
      same-minor-different-build|ahead-major-minor)
        return 0
        ;;
    esac
  done

  return 1
}

# Classify one Jira issue relative to the expected next fixVersion.
env_versions_issue_fix_version_state() {
  local issue_json="${1}"
  local expected_release="${2}"
  local fix_version_display=""
  local normalized_expected=""
  local normalized_actual=""

  fix_version_display="$(jira_issue_fix_version_display "${issue_json}")"
  if [[ "${fix_version_display}" == "MISSING" ]]; then
    printf '%s\n' "missing-fix-version"
    return 0
  fi

  normalized_expected="${expected_release#v}"
  while IFS= read -r normalized_actual; do
    [[ -z "${normalized_actual}" ]] && continue
    normalized_actual="${normalized_actual#v}"
    if [[ "${normalized_actual}" == "${normalized_expected}" ]]; then
      printf '%s\n' "expected-fix-version"
      return 0
    fi
  done < <(printf '%s\n' "${fix_version_display}" | tr ',' '\n' | sed 's/^ *//; s/ *$//')

  printf '%s\n' "other-fix-version"
}

# Render unreleased Jira issues using the same state coloring as next-release.
render_env_versions_issue_summary() {
  local issues_json="${1}"
  local expected_release="${2}"
  local issue_json=""
  local rendered_any=0
  local issue_state=""
  local issue_key=""
  local title=""
  local status_name=""
  local status_name_lower=""
  local fix_version=""
  local issue_color="${C_DIM}"

  while IFS= read -r issue_json; do
    [[ -z "${issue_json}" ]] && continue
    issue_state="$(env_versions_issue_fix_version_state "${issue_json}" "${expected_release}")"
    issue_key="$(printf '%s\n' "${issue_json}" | jq -r '.key // "unknown"')"
    title="$(printf '%s\n' "${issue_json}" | jq -r '.fields.summary // "unknown"')"
    status_name="$(printf '%s\n' "${issue_json}" | jq -r '.fields.status.name // "unknown"')"
    status_name_lower="$(printf '%s\n' "${status_name}" | tr '[:upper:]' '[:lower:]')"
    fix_version="$(jira_issue_fix_version_display "${issue_json}")"

    case "${issue_state}" in
      expected-fix-version)
        if [[ "${status_name_lower}" == *resolved* || "${status_name_lower}" == *done* || "${status_name_lower}" == *closed* ]]; then
          issue_color="${C_GREEN}"
        else
          issue_color="${C_CYAN}"
        fi
        ;;
      missing-fix-version|other-fix-version)
        issue_color="${C_ORANGE}"
        ;;
      *)
        issue_color="${C_DIM}"
        ;;
    esac

    if use_color_output && [[ "${issue_color}" != "${C_DIM}" ]]; then
      print_colored_line "${issue_color}" "- \`${issue_key}\`"
      printf "  - title: \`%s\`\n" "${title}"
      printf "  - status: \`%s\`\n" "${status_name}"
      printf "  - fix_version: \`%s\`\n" "${fix_version}"
    else
      printf -- "- \`%s\`\n" "${issue_key}"
      printf "  - title: \`%s\`\n" "${title}"
      printf "  - status: \`%s\`\n" "${status_name}"
      printf "  - fix_version: \`%s\`\n" "${fix_version}"
    fi
    printf "  - release_match: \`%s\`\n" "${issue_state}"
    rendered_any=1
  done < <(printf '%s\n' "${issues_json}" | jq -c '.issues[]?')

  if [[ "${rendered_any}" -eq 0 ]]; then
    printf '_No Jira issues found for this unreleased span._\n'
  fi
  printf '\n'
}

# Render unreleased Jira issues for the production drift span when available.
render_env_versions_unreleased_issues() {
  local project_id="${1}"
  local repo_path="${2}"
  local prod_version="${3}"
  local suggested_version="${4}"
  local target_ref="${5}"
  local jira_base_url_value="${6}"
  local issue_keys_text=""
  local -a issue_keys=()
  local issues_json='{"issues":[]}'

  print_markdown_h2 "Unreleased Issues" "${C_GREEN}"
  printf '\n'

  if [[ -z "${jira_base_url_value}" || -z "$(project_jira_project_key "${project_id}")" ]]; then
    printf -- "- Status: \`missing jira config\`\n"
    printf -- "- Next step: \`jiggit config\`\n\n"
    return 0
  fi

  issue_keys_text="$(compare_issue_keys "${repo_path}" "${prod_version}..${target_ref}" "${project_id}" || true)"
  if [[ -z "${issue_keys_text}" ]]; then
    printf -- "- Status: \`no jira keys found in commit span\`\n"
    printf -- "- Next step: \`jiggit changes %s --base prod\`\n\n" "${project_id}"
    return 0
  fi

  mapfile -t issue_keys < <(printf '%s\n' "${issue_keys_text}" | sed '/^$/d')
  if [[ ${#issue_keys[@]} -eq 0 ]]; then
    printf -- "- Status: \`no jira keys found in commit span\`\n"
    printf -- "- Next step: \`jiggit changes %s --base prod\`\n\n" "${project_id}"
    return 0
  fi

  if ! issues_json="$(fetch_jira_issues_by_keys "${jira_base_url_value}" "" "${issue_keys[@]}" 2>/dev/null)"; then
    printf -- "- Status: \`unable to fetch jira issues\`\n"
    printf -- "- Next step: \`jiggit jira-check %s\`\n\n" "${project_id}"
    return 0
  fi

  render_env_versions_issue_summary "${issues_json}" "${suggested_version}"
  printf -- "- Next step: \`jiggit changes %s --from-env prod --to %s\`\n\n" "${project_id}" "${suggested_version#v}"
}

# Load config, query configured environments, and print the version report.
run_env_versions_main() {
  local project_selector=""
  if [[ $# -gt 0 && "${1}" != -* ]]; then
    project_selector="${1}"
    shift || true
  fi

  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --verbose)
        JIGGIT_ENV_VERSIONS_VERBOSE=1
        shift
        ;;
      -h|--help)
        env_versions_usage
        return 0
        ;;
      *)
        printf 'Unknown option: %s\n' "${1}" >&2
        env_versions_usage >&2
        return 1
        ;;
    esac
  done

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
  local environments
  local version_expr
  local environment_name
  local info_url
  local value
  local failed=0
  local prod_version=""
  local -a env_entries=()
  local saw_version_error=0
  local target_ref=""
  local suggested_version=""
  local jira_base_url_value=""
  local label_width=0

  repo_path="$(project_repo_path "${project_id}")"
  environments="$(project_environments "${project_id}")"
  version_expr="$(env_versions_expr_for_project "${project_id}")"

  if [[ -z "${environments}" ]]; then
    printf 'Project %s has no configured environments.\n' "${project_id}" >&2
    return 1
  fi

  print_markdown_h1 "jiggit env-versions"
  printf '\n'
  printf -- "- Project: \`%s\`\n" "${project_id}"
  printf -- "- Repo path: \`%s\`\n" "${repo_path:-missing}"
  printf -- "- Environments: \`%s\`\n" "${environments}"
  printf -- "- Version expr: \`%s\`\n\n" "${version_expr}"
  print_markdown_h2 "Versions" "${C_BLUE}"
  printf '\n'

  for environment_name in ${environments}; do
    if [[ ${#environment_name} -gt ${label_width} ]]; then
      label_width=${#environment_name}
    fi
  done

  for environment_name in ${environments}; do
    info_url="$(project_environment_info_url "${project_id}" "${environment_name}")"
    if [[ -z "${info_url}" ]]; then
      render_env_version_entry "${environment_name}" "ERROR: missing info URL in config" "missing" "${label_width}"
      failed=1
      saw_version_error=1
      env_entries+=("${environment_name}=ERROR: missing info URL in config")
      continue
    fi

    if value="$(fetch_project_environment_version "${project_id}" "${environment_name}")"; then
      render_env_version_entry "${environment_name}" "${value}" "${info_url}" "${label_width}"
      env_entries+=("${environment_name}=${value}")
      if [[ "${environment_name}" == "prod" ]]; then
        prod_version="${value}"
      fi
    else
      render_env_version_entry "${environment_name}" "${value}" "${info_url}" "${label_width}"
      env_entries+=("${environment_name}=${value}")
      failed=1
      saw_version_error=1
    fi
  done

  printf '\n'
  if [[ "${saw_version_error}" -eq 1 ]]; then
    print_markdown_h2 "Next Steps" "${C_CYAN}"
    printf '\n'
    printf -- "- retry environment version discovery: \`jiggit env-versions %s\`\n\n" "${project_id}"
  fi
  render_env_version_diagnostics "${project_id}" "${prod_version}" "${env_entries[@]}"

  if env_versions_has_release_drift "${prod_version}" "${env_entries[@]}"; then
    if [[ -n "${repo_path}" && -d "${repo_path}" ]]; then
      target_ref="$(default_target_git_ref "${repo_path}" 2>/dev/null || true)"
    fi
    suggested_version="$(env_versions_bump_minor_version "${prod_version}" || true)"
    jira_base_url_value="$(jira_base_url "${project_id}")"

    if [[ -n "${target_ref}" && -n "${suggested_version}" ]]; then
      render_env_versions_unreleased_issues "${project_id}" "${repo_path}" "${prod_version}" "${suggested_version}" "${target_ref}" "${jira_base_url_value}"
    fi
  fi

  if [[ ${failed} -ne 0 ]]; then
    return 1
  fi
}
